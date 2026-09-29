import Foundation
import OpenBurnBarKernel

// MARK: - Cline Format Parser

/// Shared parser for Cline-family VS Code extensions (Cline, Kilo Code, Roo Code).
/// All three use the same `tasks/*/api_conversation_history.json` format.
///
/// Idle usage ticks resume unchanged task histories from a mtime+size disk cache
/// (token totals only — never conversation bodies).
///
/// A task that switches models mid-way yields one usage row per model, each
/// priced at its own rate: usage on a message belongs to the model named on
/// that message, or to the most recent model the history named before it.
public final class ClineFormatParser: LogParser, Sendable {
    public let provider: AgentProvider
    private let storagePaths: [String]
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        provider: AgentProvider,
        storagePaths: [String],
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.provider = provider
        self.storagePaths = storagePaths
        self.fileManager = fileManager
        let cacheURL: URL
        if storagePaths.count == 1, let path = storagePaths.first {
            cacheURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .appendingPathComponent(".obb-parser-cache.plist")
        } else {
            cacheURL = appPaths.clineFormatParserCacheURL(for: provider)
        }
        // v3: per-model bundle entries; v2 single-row entries priced a
        // multi-model task at one model and are dropped on load.
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 3,
            logLabel: "ClineFormatParser.\(provider.persistedToken)"
        )
    }

    public var lastSessionScanCount: Int { sessionScanCount.read() }
    public var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var seenTaskIds = Set<String>()
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        for storagePath in storagePaths {
            let expanded = (storagePath as NSString).expandingTildeInPath
            guard fileManager.fileExists(atPath: expanded) else { continue }

            let tasksURL = URL(fileURLWithPath: expanded)
            guard let taskDirs = try? fileManager.contentsOfDirectory(
                at: tasksURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            let dirs = taskDirs.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            for taskDir in dirs {
                let taskId = taskDir.lastPathComponent
                let historyFile = taskDir.appendingPathComponent("api_conversation_history.json")
                guard fileManager.fileExists(atPath: historyFile.path) else { continue }
                let cacheKey = historyFile.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard seenTaskIds.insert(taskId).inserted else { continue }
                guard try gate.shouldRead(historyFile) else { continue }

                let signature = FileSignature(for: historyFile, using: fileManager)
                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: provider) })
                    continue
                }

                sessionScanCount.withLock { $0 += 1 }
                if let parsed = try parseTask(
                    taskId: taskId,
                    historyFile: historyFile,
                    includeConversationBodies: options.includeConversationBodies
                ), !parsed.usages.isEmpty {
                    usages.append(contentsOf: parsed.usages)
                    if options.includeConversationBodies, let conv = parsed.conversation {
                        conversations.append(conv)
                    }
                    if let signature {
                        parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                            signature: signature,
                            usages: parsed.usages
                        )
                        cacheMutated = true
                    }
                }
            }
        }

        let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                parseCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Task Parsing

    /// Token totals and activity window for one model inside one task. The
    /// window spans every message exchanged while the model was active.
    private struct ModelTokens {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        var hasTokens: Bool {
            inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0
        }

        mutating func touch(_ timestamp: Date?) {
            guard let timestamp else { return }
            if firstTimestamp == nil { firstTimestamp = timestamp }
            lastTimestamp = timestamp
        }

        mutating func add(input: Int, output: Int, cacheCreation: Int, cacheRead: Int) {
            inputTokens += input
            outputTokens += output
            cacheCreationTokens += cacheCreation
            cacheReadTokens += cacheRead
        }

        mutating func absorb(_ other: ModelTokens) {
            add(
                input: other.inputTokens,
                output: other.outputTokens,
                cacheCreation: other.cacheCreationTokens,
                cacheRead: other.cacheReadTokens
            )
            firstTimestamp = [firstTimestamp, other.firstTimestamp].compactMap { $0 }.min()
            lastTimestamp = [lastTimestamp, other.lastTimestamp].compactMap { $0 }.max()
        }
    }

    private static let unattributedModelID = "unknown"

    private func parseTask(
        taskId: String,
        historyFile: URL,
        includeConversationBodies: Bool
    ) throws -> (usages: [TokenUsage], conversation: ConversationRecord?)? {
        guard let data = try? Data(contentsOf: historyFile), // try?-ok(skip unreadable log)
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { // try?-ok(malformed log skip)
            return nil
        }

        let mtime = modificationDate(of: historyFile)

        // Session totals seed the input/output split hint for total-only usage
        // payloads; the per-model buckets always sum to them.
        var inputTokens = 0
        var outputTokens = 0
        var tokensByModel: [String: ModelTokens] = [:]
        // Usage seen before the history named any model joins the first model
        // that appears.
        var unattributed = ModelTokens()
        var currentModel: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        var fullText = ""
        var firstUserText: String?
        var lastAssistantText = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        for message in array {
            let role = (message["role"] as? String ?? "").lowercased()

            // Timestamp: ts is milliseconds since epoch
            var messageTimestamp: Date?
            if let ts = message["ts"] as? Double {
                messageTimestamp = Date(timeIntervalSince1970: ts / 1000.0)
            } else if let ts = message["ts"] as? Int {
                messageTimestamp = Date(timeIntervalSince1970: Double(ts) / 1000.0)
            }
            if let messageTimestamp {
                if firstTimestamp == nil { firstTimestamp = messageTimestamp }
                lastTimestamp = messageTimestamp
            }

            // Model detection; harness placeholders (`<synthetic>`) are rejected.
            if let model = message["model"] as? String,
               !TokenExtractionUtility.isPlaceholderModelName(model) {
                currentModel = TokenExtractionUtility.normalizeModelName(model)
            }

            // Every message belongs to the active model; usage on an assistant
            // message is billed to it.
            var bucket: ModelTokens
            if let currentModel {
                bucket = tokensByModel[currentModel] ?? ModelTokens()
                bucket.absorb(unattributed)
                unattributed = ModelTokens()
            } else {
                bucket = unattributed
            }
            bucket.touch(messageTimestamp)
            if role == "assistant", let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(
                    usage,
                    inputHint: inputTokens,
                    outputHint: outputTokens
                )
                inputTokens += extracted.input
                outputTokens += extracted.output
                bucket.add(
                    input: extracted.input,
                    output: extracted.output,
                    cacheCreation: extracted.cacheCreation,
                    cacheRead: extracted.cacheRead
                )
            }
            if let currentModel {
                tokensByModel[currentModel] = bucket
            } else {
                unattributed = bucket
            }

            // Content extraction for conversation record
            let contentText = extractText(from: message["content"])
            guard !contentText.isEmpty else { continue }

            let words = contentText.split { $0.isWhitespace || $0.isNewline }.count

            if role == "user" {
                userWords += words
                messageCount += 1
                if includeConversationBodies {
                    if firstUserText == nil {
                        firstUserText = String(contentText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    appendText(&fullText, contentText)
                }
            } else if role == "assistant" {
                assistantWords += words
                messageCount += 1
                if includeConversationBodies {
                    lastAssistantText = contentText
                    appendText(&fullText, contentText)
                }
            }
        }

        if unattributed.hasTokens {
            tokensByModel[Self.unattributedModelID, default: ModelTokens()].absorb(unattributed)
        }
        tokensByModel = tokensByModel.filter { $0.value.hasTokens }

        // Without per-message usage the task's totals cannot be split by
        // model; they belong to the model the history last named.
        let fallbackModel = currentModel ?? Self.unattributedModelID
        var usedHeuristicEstimate = false

        // Check ui_messages.json for exact token telemetry if not present in conversation history
        if tokensByModel.isEmpty {
            let uiMessagesFile = historyFile.deletingLastPathComponent().appendingPathComponent("ui_messages.json")
            if let uiData = try? Data(contentsOf: uiMessagesFile),
               let uiArray = try? JSONSerialization.jsonObject(with: uiData) as? [[String: Any]] {
                var telemetry = ModelTokens()
                for msg in uiArray {
                    if let say = msg["say"] as? String, say == "api_req_started" || say == "api_req_finished",
                       let text = msg["text"] as? String,
                       let textData = text.data(using: .utf8),
                       let reqJson = BurnBarJSONValue.dictionary(fromJSONData: textData) {
                        telemetry.add(
                            input: reqJson["tokensIn"] as? Int ?? 0,
                            output: reqJson["tokensOut"] as? Int ?? 0,
                            cacheCreation: reqJson["cacheWrites"] as? Int ?? 0,
                            cacheRead: reqJson["cacheReads"] as? Int ?? 0
                        )
                    }
                }
                if telemetry.hasTokens {
                    tokensByModel[fallbackModel] = telemetry
                }
            }
        }

        // Fallback estimation if still no usage data
        if tokensByModel.isEmpty {
            let userChars = userWords * 5
            let assistantChars = assistantWords * 5
            guard userChars + assistantChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userChars,
                assistantVisibleChars: assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: messageCount / 2,
                assistantMessageCount: messageCount / 2
            )
            var estimate = ModelTokens()
            estimate.add(input: estimated.input, output: estimated.output, cacheCreation: 0, cacheRead: 0)
            guard estimate.hasTokens else { return nil }
            tokensByModel[fallbackModel] = estimate
            usedHeuristicEstimate = true
        }

        let startTime = firstTimestamp ?? Date()
        let endTime = lastTimestamp ?? startTime

        let usages = try tokensByModel.sorted { $0.key < $1.key }.map { model, tokens in
            let pricing = ModelPricing.lookup(model: model)
            let cost = try pricing.cost(
                inputTokens: tokens.inputTokens,
                outputTokens: tokens.outputTokens,
                cacheCreationTokens: tokens.cacheCreationTokens,
                cacheReadTokens: tokens.cacheReadTokens
            )
            let modelStart = tokens.firstTimestamp ?? startTime
            return TokenUsage(
                provider: provider,
                sessionId: taskId,
                projectName: taskId,
                model: model,
                inputTokens: tokens.inputTokens,
                outputTokens: tokens.outputTokens,
                cacheCreationTokens: tokens.cacheCreationTokens,
                cacheReadTokens: tokens.cacheReadTokens,
                costUSD: cost,
                startTime: modelStart,
                endTime: tokens.lastTimestamp ?? max(endTime, modelStart),
                provenanceMethod: usedHeuristicEstimate ? .heuristicEstimate : .providerLog,
                provenanceConfidence: usedHeuristicEstimate ? .lowConfidenceEstimate : .exact,
                estimatorVersion: usedHeuristicEstimate ? TokenExtractionUtility.currentEstimatorVersion : ""
            )
        }

        let conversation = includeConversationBodies
            ? ConversationRecord(
                id: ConversationRecord.stableId(provider: provider, sessionId: taskId),
                provider: provider,
                sessionId: taskId,
                projectName: taskId,
                startTime: startTime,
                endTime: endTime,
                messageCount: messageCount,
                userWordCount: userWords,
                assistantWordCount: assistantWords,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: firstUserText ?? taskId,
                lastAssistantMessage: lastAssistantText,
                fullText: fullText,
                indexedAt: Date(),
                fileModifiedAt: mtime,
                summary: nil
            )
            : nil

        return (usages, conversation)
    }

    // MARK: - Helpers

    /// Extract plain text from a content field that may be a String or array of content blocks.
    private func extractText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }

    private func appendText(_ full: inout String, _ chunk: String) {
        if !full.isEmpty { full += "\n\n" }
        full += chunk
    }

    private func modificationDate(of url: URL) -> Date? {
        // try?-ok(optional mtime metadata)
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
