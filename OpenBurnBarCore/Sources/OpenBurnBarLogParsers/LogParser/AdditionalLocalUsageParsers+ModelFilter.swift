import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// MARK: Factory model-filtered providers (Z.ai / MiniMax)

public final class ModelFilterParser: LogParser, Sendable {
    public let provider: AgentProvider
    private let modelPatterns: [String]
    private let sessionsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<CompositeFileSignature<FileSignature>>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        modelPattern: String,
        provider: AgentProvider,
        sessionsOverride: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        // ParserRegistry passes alternatives ("zai,glm,zhipu,chatglm");
        // a session matches when its model contains any one of them.
        self.modelPatterns = modelPattern.lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.provider = provider
        self.sessionsOverride = sessionsOverride
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: LocalUsageParserSupport.idleCacheURL(
                overrideDirectory: sessionsOverride,
                live: appPaths.modelFilterParserCacheURL(for: provider),
                fileName: ".obb-\(provider.persistedToken)-parser-cache.plist"
            ),
            fileManager: fileManager,
            // v2: v1 cached every session as an empty non-match whenever
            // the pattern was a comma-separated list.
            schemaVersion: 2,
            logLabel: "ModelFilterParser"
        )
    }

    public var lastSessionScanCount: Int { sessionScanCount.read() }
    public var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let root = sessionsOverride ?? LocalUsageParserSupport.expanded("~/.factory/sessions")
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []; var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer { if cacheMutated { cacheStore.persist(parseCache) } }
        for file in LocalUsageParserSupport.files(in: root, extensions: ["jsonl"]) {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            let stem = file.deletingPathExtension()
            let settingsURL = stem.appendingPathExtension("settings.json")
            let metadataURL = stem.appendingPathExtension("metadata.json")
            var gateFiles = [file]
            if fileManager.fileExists(atPath: settingsURL.path) { gateFiles.append(settingsURL) }
            if fileManager.fileExists(atPath: metadataURL.path) { gateFiles.append(metadataURL) }
            guard try gate.shouldRead(gateFiles) else { continue }
            let signature = FileSignature(for: file, using: fileManager).map { primary in
                CompositeFileSignature(
                    primary: primary,
                    settings: FileSignature(for: settingsURL, using: fileManager),
                    metadata: FileSignature(for: metadataURL, using: fileManager)
                )
            }
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: provider) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            // Open every admitted input before parsing. One that exists but
            // cannot be read defers the whole session: no usage, no
            // transcript, no cache entry, and the admission rolls back so
            // the next pass retries instead of trusting a partial parse.
            var sidecarObjects: [LocalUsageJSONObject] = []
            let transcript: FileHandle
            do {
                for sidecar in gateFiles.dropFirst() {
                    if let object = try LocalUsageParserSupport.jsonObjectOrThrow(at: sidecar) {
                        sidecarObjects.append(object)
                    }
                }
                transcript = try FileHandle(forReadingFrom: file)
            } catch {
                gate.recordContentReadFailure(for: gateFiles)
                continue
            }
            defer { try? transcript.close() }
            let objects = transcript.readAllUTF8Lines().lazy.compactMap { line in
                parserAutoReleasePool { () -> LocalUsageJSONObject? in
                    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? LocalUsageJSONObject
                }
            }
            var input = 0, output = 0, cacheCreation = 0, cacheRead = 0, userChars = 0, assistantChars = 0; var model: String?; var start: Date?, end: Date?; var turns: [LocalUsageParserSupport.Turn] = []
            for sidecarObject in sidecarObjects {
                model = model ?? LocalUsageParserSupport.model(in: sidecarObject)
                if let usage = LocalUsageParserSupport.dictionary(sidecarObject["tokenUsage"] ?? sidecarObject["usage"]) {
                    let tokens = TokenExtractionUtility.extractUsageTokens(usage)
                    input += tokens.input; output += tokens.output; cacheCreation += tokens.cacheCreation; cacheRead += tokens.cacheRead
                }
            }
            for object in objects {
                let timestamp = LocalUsageParserSupport.date(object["timestamp"])
                start = start ?? timestamp
                end = timestamp ?? end
                model = model ?? LocalUsageParserSupport.model(in: object)
                let tokens = LocalUsageParserSupport.extracted(object)
                input += tokens.input
                output += tokens.output
                cacheCreation += tokens.cacheCreation
                cacheRead += tokens.cacheRead
                let message = LocalUsageParserSupport.dictionary(object["message"])
                let role = (LocalUsageParserSupport.string(message?["role"]) ?? "").lowercased()
                let text = LocalUsageParserSupport.contentText(message?["content"])
                if !text.isEmpty, ["user", "assistant"].contains(role) {
                    turns.append(.init(role: role, text: text, timestamp: timestamp))
                    if role == "user" {
                        userChars += text.count
                    } else {
                        assistantChars += text.count
                    }
                }
            }
            func persist(_ fileUsages: [TokenUsage]) {
                if let signature {
                    parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                        signature: signature,
                        usages: fileUsages
                    )
                    cacheMutated = true
                }
            }
            guard let resolvedModel = model,
                  modelPatterns.contains(where: { resolvedModel.lowercased().contains($0) }) else {
                persist([])
                continue
            }
            var method: UsageProvenanceMethod = .providerLog
            var confidence: UsageProvenanceConfidence = .exact
            if input == 0 && output == 0 {
                guard userChars + assistantChars > 0 else {
                    persist([])
                    continue
                }
                let estimate = TokenExtractionUtility.estimateFallbackTokens(
                    userVisibleChars: userChars,
                    assistantVisibleChars: assistantChars,
                    assistantReasoningChars: 0,
                    userMessageCount: 1,
                    assistantMessageCount: 1
                )
                input = estimate.input
                output = estimate.output
                method = .heuristicEstimate
                confidence = .lowConfidenceEstimate
            }
            let mtime = LocalUsageParserSupport.modificationDate(file) ?? Date()
            let startTime = start ?? mtime
            let endTime = end ?? startTime
            let project = file.deletingLastPathComponent().lastPathComponent
            let cost = (try? ModelPricing.lookup(model: resolvedModel).cost(
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreation,
                cacheReadTokens: cacheRead
            )) ?? 0
            let id = file.deletingPathExtension().lastPathComponent
            let estimatorVersion = method == .heuristicEstimate
                ? TokenExtractionUtility.currentEstimatorVersion
                : ""
            if let usage = LocalUsageParserSupport.usage(
                provider: provider,
                sessionID: id,
                project: project,
                model: resolvedModel,
                input: input,
                output: output,
                cacheCreation: cacheCreation,
                cacheRead: cacheRead,
                cost: cost,
                start: startTime,
                end: endTime,
                method: method,
                confidence: confidence,
                estimatorVersion: estimatorVersion
            ) {
                usages.append(usage)
                persist([usage])
            } else {
                persist([])
            }
            if options.includeConversationBodies, !turns.isEmpty {
                conversations.append(LocalUsageParserSupport.transcript(
                    provider: provider,
                    sessionID: id,
                    project: project,
                    turns: turns,
                    start: startTime,
                    end: endTime,
                    fileModifiedAt: mtime
                ))
            }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: conversations)
    }
}
