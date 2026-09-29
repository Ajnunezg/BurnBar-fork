import Foundation
import OpenBurnBarEngine
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Imports local agent logs into the daemon ledger as cumulative deltas.
///
/// Each pass is governed like the Mac app's usage refresh: one
/// `ParserResourceGovernor` per pass, shared by every parser, bounds the bytes
/// of new log content read and aborts on the memory ceiling, so a cold
/// multi-gigabyte corpus converges over ticks instead of one unbounded pass.
///
/// Checkpoints (per-session high-water marks) advance in an append-only
/// journal — one small line per ingested session, written right after its
/// ledger records — and fold into the checkpoint document once per pass. Rewriting the
/// whole document per row made a cold import O(rows²) bytes.
public actor BurnBarLocalUsageIngestionService {
    public struct RefreshReport: Equatable, Sendable {
        public let parsedRows: Int
        public let insertedDeltas: Int
        public let unchangedRows: Int
        /// Files the pass's byte budget pushed to a later tick.
        public let deferredFiles: Int
        public let failures: [String]
    }

    /// Cumulative counters of one parser row (or of a whole session) at the
    /// last recorded delta.
    private struct Checkpoint: Codable, Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let reasoningTokens: Int
        let cost: Double
        let startTime: Date
        let endTime: Date

        init(
            inputTokens: Int,
            outputTokens: Int,
            cacheCreationTokens: Int,
            cacheReadTokens: Int,
            reasoningTokens: Int,
            cost: Double,
            startTime: Date,
            endTime: Date
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.cacheReadTokens = cacheReadTokens
            self.reasoningTokens = reasoningTokens
            self.cost = cost
            self.startTime = startTime
            self.endTime = endTime
        }

        init(_ usage: TokenUsage) {
            self.init(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens,
                reasoningTokens: usage.reasoningTokens,
                cost: usage.cost,
                startTime: usage.startTime,
                endTime: usage.endTime
            )
        }

        /// Field-wise sum; the window spans both.
        func adding(_ other: Checkpoint) -> Checkpoint {
            Checkpoint(
                inputTokens: inputTokens + other.inputTokens,
                outputTokens: outputTokens + other.outputTokens,
                cacheCreationTokens: cacheCreationTokens + other.cacheCreationTokens,
                cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
                reasoningTokens: reasoningTokens + other.reasoningTokens,
                cost: cost + other.cost,
                startTime: min(startTime, other.startTime),
                endTime: max(endTime, other.endTime)
            )
        }

        func regressed(from previous: Checkpoint) -> Bool {
            inputTokens < previous.inputTokens
                || outputTokens < previous.outputTokens
                || cacheCreationTokens < previous.cacheCreationTokens
                || cacheReadTokens < previous.cacheReadTokens
                || reasoningTokens < previous.reasoningTokens
        }

        /// Counters gained since `baseline` (all of them when there is none).
        func delta(since baseline: Checkpoint?) -> TokenDelta {
            TokenDelta(
                input: inputTokens - (baseline?.inputTokens ?? 0),
                output: outputTokens - (baseline?.outputTokens ?? 0),
                cacheCreation: cacheCreationTokens - (baseline?.cacheCreationTokens ?? 0),
                cacheRead: cacheReadTokens - (baseline?.cacheReadTokens ?? 0),
                reasoning: reasoningTokens - (baseline?.reasoningTokens ?? 0),
                cost: max(cost - (baseline?.cost ?? 0), 0)
            )
        }
    }

    private struct TokenDelta: Equatable {
        var input = 0
        var output = 0
        var cacheCreation = 0
        var cacheRead = 0
        var reasoning = 0
        var cost = 0.0

        var isPositive: Bool {
            input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0 || reasoning > 0 || cost > 0
        }

        var hasNegativeTokens: Bool {
            input < 0 || output < 0 || cacheCreation < 0 || cacheRead < 0 || reasoning < 0
        }

        func sameTokens(as other: TokenDelta) -> Bool {
            input == other.input && output == other.output && cacheCreation == other.cacheCreation
                && cacheRead == other.cacheRead && reasoning == other.reasoning
        }

        static func + (lhs: TokenDelta, rhs: TokenDelta) -> TokenDelta {
            TokenDelta(
                input: lhs.input + rhs.input,
                output: lhs.output + rhs.output,
                cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
                cacheRead: lhs.cacheRead + rhs.cacheRead,
                reasoning: lhs.reasoning + rhs.reasoning,
                cost: lhs.cost + rhs.cost
            )
        }
    }

    /// High-water mark for one (provider, session). The session total is the
    /// cumulative scope: Copilot counters are session-scoped even when the
    /// selected model changes, and a per-model parser (Claude Code, Cline)
    /// partitions one session into several rows. `models` keeps the per-row
    /// breakdown so a per-model session records per-model deltas.
    private struct SessionCheckpoint: Codable, Equatable {
        let total: Checkpoint
        let models: [String: Checkpoint]
    }

    /// v2 stores `SessionCheckpoint`s under `sessions`; a v1 document's `rows`
    /// were single-row session totals and load as sessions without a
    /// per-model breakdown.
    private struct CheckpointDocument: Codable {
        let schemaVersion: Int
        var sessions: [String: SessionCheckpoint]?
        var rows: [String: Checkpoint]?
    }

    private struct CheckpointJournalEntry: Codable {
        let key: String
        let checkpoint: SessionCheckpoint
    }

    private static let checkpointSchemaVersion = 2

    private let parsers: [any LogParser]
    private let usageRecorder: BurnBarUsageRecorder
    private let checkpointURL: URL
    private let checkpointJournalURL: URL
    private let fileManager: FileManager
    private let resourceLimits: ParserResourceLimits
    private let logger: BurnBarDaemonLogger
    private var checkpoints: [String: SessionCheckpoint]?
    private var checkpointJournal: FileHandle?
    private var journaledCheckpoints = 0

    public init(
        parsers: [any LogParser],
        usageRecorder: BurnBarUsageRecorder,
        checkpointURL: URL,
        fileManager: FileManager = .default,
        resourceLimits: ParserResourceLimits? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "local-usage-ingestion")
    ) {
        self.parsers = parsers
        self.usageRecorder = usageRecorder
        self.checkpointURL = checkpointURL
        self.checkpointJournalURL = checkpointURL.appendingPathExtension("journal")
        self.fileManager = fileManager
        // The Mac app's usage-refresh bounds unless a caller supplies its own.
        self.resourceLimits = resourceLimits ?? .usageRefresh
        self.logger = logger
    }

    public static func linuxDefault(usageRecorder: BurnBarUsageRecorder) -> BurnBarLocalUsageIngestionService {
        let paths = OpenBurnBarAppPaths.live()
        return BurnBarLocalUsageIngestionService(
            parsers: linuxDefaultParsers(),
            usageRecorder: usageRecorder,
            checkpointURL: paths.supportDirectory.appendingPathComponent("local-usage-ingestion-checkpoints.json")
        )
    }

    static func linuxDefaultParsers(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [any LogParser] {
        let clinePaths = linuxClineStoragePaths(
            environment: environment,
            homeDirectoryURL: homeDirectoryURL
        )
        // Keep parser construction local to the daemon, but let the generated
        // provider-ingestion catalog own membership and ordering. The catalog
        // is also consumed by Linux discovery and the renderer; filtering this
        // factory map through it prevents a newly declared provider from being
        // silently omitted (or an API-only provider from being parsed locally).
        let factories: [AgentProvider: () -> any LogParser] = [
            .factory: { FactoryDroidParser() },
            .claudeCode: { ClaudeCodeParser() },
            .openClaude: { ClaudeCodeParser(provider: .openClaude) },
            .copilot: { CopilotParser() },
            .cursorAgent: { CursorAgentParser() },
            .codex: { CodexParser() },
            .windsurf: { WindsurfParser() },
            .warp: { WarpParser() },
            .kimi: { KimiParser() },
            .xAI: { GrokParser() },
            .cline: { ClineFormatParser(provider: .cline, storagePaths: clinePaths[.cline] ?? []) },
            .kiloCode: { ClineFormatParser(provider: .kiloCode, storagePaths: clinePaths[.kiloCode] ?? []) },
            .rooCode: { ClineFormatParser(provider: .rooCode, storagePaths: clinePaths[.rooCode] ?? []) },
            .forgeDev: { ForgeDevParser() },
            .augment: { AugmentParser() },
            .hermes: { HermesParser() },
            .geminiCLI: { GeminiCLIParser() },
            .antigravity: { AntigravityParser() },
            .goose: { GooseParser() },
            .aider: { AiderParser() },
            .cursor: { CursorParser() },
            .openCode: { OpenCodeParser() },
            .piAgent: { PiAgentParser() },
            .omp: { OMPParser() },
            .openClaw: { OpenClawParser() },
            .ollama: { OllamaParser() },
            .junie: { JunieParser() },
            .primeAgent: { PrimeAgentParser() },
            .muse: { MuseParser() },
            .fx: { FxParser() },
            .zai: { ModelFilterParser(modelPattern: "zai", provider: .zai) },
            .minimax: { ModelFilterParser(modelPattern: "minimax", provider: .minimax) }
        ]

        return AgentProviderIngestionCatalog.entries.compactMap { entry in
            guard entry.ingestion == .localParser else { return nil }
            guard let factory = factories[entry.provider] else {
                preconditionFailure(
                    "Missing Linux parser factory for catalog provider \(entry.provider.rawValue)"
                )
            }
            return factory()
        }
    }

    static func linuxClineStoragePaths(
        environment: [String: String],
        homeDirectoryURL: URL
    ) -> [AgentProvider: [String]] {
        let configuredRoot = environment["XDG_CONFIG_HOME"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { value -> URL? in
                guard value.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        let configRoot = configuredRoot
            ?? homeDirectoryURL.appendingPathComponent(".config", isDirectory: true)
        let editorDirectories = ["Code", "VSCodium", "Cursor", "Windsurf"]

        func taskPaths(extensionIDs: [String]) -> [String] {
            editorDirectories.flatMap { editor in
                extensionIDs.map { extensionID in
                    configRoot
                        .appendingPathComponent(editor, isDirectory: true)
                        .appendingPathComponent("User", isDirectory: true)
                        .appendingPathComponent("globalStorage", isDirectory: true)
                        .appendingPathComponent(extensionID, isDirectory: true)
                        .appendingPathComponent("tasks", isDirectory: true)
                        .path
                }
            }
        }

        return [
            .cline: taskPaths(extensionIDs: ["saoudrizwan.claude-dev"]),
            .kiloCode: taskPaths(extensionIDs: ["kilocode.kilo-code"]),
            .rooCode: taskPaths(extensionIDs: [
                "rooveterinaryinc.roo-cline",
                "roo-inc.roo-code"
            ])
        ]
    }

    public func refresh() async -> RefreshReport {
        await refresh(compactingCheckpointJournal: true)
    }

    /// `compactingCheckpointJournal: false` lets tests stand in for a process
    /// that died after journaling a pass but before folding it.
    func refresh(compactingCheckpointJournal: Bool) async -> RefreshReport {
        var parsedRows = 0
        var insertedDeltas = 0
        var unchangedRows = 0
        var failures: [String] = []
        do {
            try loadCheckpointsIfNeeded()
        } catch {
            return RefreshReport(
                parsedRows: 0,
                insertedDeltas: 0,
                unchangedRows: 0,
                deferredFiles: 0,
                failures: ["checkpoint: \(error)"]
            )
        }

        // One governor per pass, shared by every parser, so the byte budget
        // bounds the pass rather than each parser and resets every tick.
        let governor = ParserResourceGovernor(
            limits: resourceLimits,
            onSoftLimit: { [logger] footprint in
                logger.notice(
                    "local_usage_ingestion_memory_soft_limit",
                    metadata: ["footprint_mb": String(footprint / (1024 * 1024))]
                )
            }
        )
        let options = LogParseOptions.usageAccounting(resourceGovernor: governor)
        for parser in parsers {
            do {
                let result = try await parser.parse(options: options)
                parsedRows += result.usages.count
                for sessionRows in Self.groupedBySession(result.usages) {
                    do {
                        let recorded = try await ingest(sessionRows)
                        if recorded > 0 {
                            insertedDeltas += recorded
                        } else {
                            unchangedRows += sessionRows.count
                        }
                    } catch {
                        failures.append("\(parser.provider.rawValue)/\(sessionRows[0].sessionId): \(error)")
                    }
                }
            } catch {
                failures.append("\(parser.provider.rawValue): \(error)")
            }
        }
        if compactingCheckpointJournal {
            do {
                try compactCheckpointJournal()
            } catch {
                failures.append("checkpoint: \(error)")
            }
        }
        return RefreshReport(
            parsedRows: parsedRows,
            insertedDeltas: insertedDeltas,
            unchangedRows: unchangedRows,
            deferredFiles: governor.deferredFileCount,
            failures: failures.sorted()
        )
    }

    /// Rows of one parse pass grouped by cumulative scope, in first-seen order.
    private static func groupedBySession(_ usages: [TokenUsage]) -> [[TokenUsage]] {
        var order: [String] = []
        var groups: [String: [TokenUsage]] = [:]
        for usage in usages {
            let key = checkpointKey(for: usage)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(usage)
        }
        return order.compactMap { groups[$0] }
    }

    /// Records the counters one session gained since its checkpoint and
    /// returns how many ledger events that took (0 when nothing changed).
    private func ingest(_ sessionRows: [TokenUsage]) async throws -> Int {
        guard let first = sessionRows.first else { return 0 }
        let checkpointKey = Self.checkpointKey(for: first)
        var rowsByModel: [String: TokenUsage] = [:]
        var modelCheckpoints: [String: Checkpoint] = [:]
        for usage in sessionRows {
            let row = Checkpoint(usage)
            modelCheckpoints[usage.model] = modelCheckpoints[usage.model].map { $0.adding(row) } ?? row
            rowsByModel[usage.model] = rowsByModel[usage.model] ?? usage
        }
        let models = modelCheckpoints.keys.sorted()
        guard let total = models.compactMap({ modelCheckpoints[$0] }).reduce(nil, { partial, next in
            partial.map { $0.adding(next) } ?? next
        }) else { return 0 }
        let current = SessionCheckpoint(total: total, models: modelCheckpoints)

        let previous = checkpoints?[checkpointKey]
        let countersRegressed = previous.map { total.regressed(from: $0.total) } ?? false
        if let previous, countersRegressed, total.startTime <= previous.total.endTime {
            // An overlapping/truncated read is not a new generation. Retain the
            // high-water mark so a transient rotation gap cannot be re-imported.
            return 0
        }
        let baseline = countersRegressed ? nil : previous
        let sessionDelta = total.delta(since: baseline?.total)
        guard sessionDelta.isPositive else {
            // Same counters, new per-model breakdown (a v1 checkpoint, or a
            // parser that now splits the session by model): adopt it so the
            // next gain is attributed to the model that earned it.
            if let baseline, baseline.models != current.models {
                checkpoints?[checkpointKey] = current
                try journalCheckpoint(key: checkpointKey, checkpoint: current)
            }
            return 0
        }

        // Per-model deltas when every model's breakdown accounts for the
        // session's gain exactly (a first import, or a per-model parser whose
        // rows each grew). Otherwise — a Copilot session whose model label
        // changed, or a checkpoint written before per-model breakdowns — the
        // gain is one event on the model that was active most recently, which
        // keeps the ledger sum exact.
        var deltas: [(model: String, delta: TokenDelta)] = models.compactMap { model in
            guard let row = modelCheckpoints[model] else { return nil }
            return (model, row.delta(since: baseline?.models[model]))
        }
        let splitIsExact = !deltas.contains { $0.delta.hasNegativeTokens }
            && deltas.map(\.delta).reduce(TokenDelta(), +).sameTokens(as: sessionDelta)
        if !splitIsExact {
            let latest = models.max { lhs, rhs in
                let lhsEnd = modelCheckpoints[lhs]?.endTime ?? .distantPast
                let rhsEnd = modelCheckpoints[rhs]?.endTime ?? .distantPast
                return (lhsEnd, lhs) < (rhsEnd, rhs)
            } ?? first.model
            deltas = [(latest, sessionDelta)]
        }

        var recorded = 0
        for (model, delta) in deltas where delta.isPositive {
            guard let row = rowsByModel[model] else { continue }
            let snapshot = deltas.count == 1 ? total : (modelCheckpoints[model] ?? total)
            let event = BurnBarUsageEvent(
                providerID: row.providerID.rawValue,
                modelID: model,
                inputTokens: delta.input,
                outputTokens: delta.output,
                cacheCreationTokens: delta.cacheCreation,
                cacheReadTokens: delta.cacheRead,
                reasoningTokens: delta.reasoning,
                cost: delta.cost,
                recordedAt: snapshot.endTime,
                sessionID: row.sessionId,
                projectName: row.projectName,
                confidence: Self.confidence(for: row.provenanceConfidence)
            )
            // Single-event sessions keep the v1 key (session + totals) so a
            // replay across the upgrade still dedupes; per-model events key
            // on the model's own counters.
            let scopeKey = deltas.count == 1 ? checkpointKey : "\(checkpointKey)\u{1f}\(model)"
            let snapshotKey = Self.snapshotKey(checkpointKey: scopeKey, checkpoint: snapshot)
            _ = try await usageRecorder.record(event, idempotencyKey: "local-usage:\(snapshotKey)")
            recorded += 1
        }

        checkpoints?[checkpointKey] = current
        try journalCheckpoint(key: checkpointKey, checkpoint: current)
        return recorded
    }

    private func loadCheckpointsIfNeeded() throws {
        guard checkpoints == nil else { return }
        var sessions: [String: SessionCheckpoint] = [:]
        if fileManager.fileExists(atPath: checkpointURL.path) {
            let data = try Data(contentsOf: checkpointURL)
            let document = try JSONDecoder().decode(CheckpointDocument.self, from: data)
            switch document.schemaVersion {
            case 1:
                guard let rows = document.rows else { throw CocoaError(.coderReadCorrupt) }
                sessions = rows.mapValues { SessionCheckpoint(total: $0, models: [:]) }
            case Self.checkpointSchemaVersion:
                guard let stored = document.sessions else { throw CocoaError(.coderReadCorrupt) }
                sessions = stored
            default:
                throw CocoaError(.coderReadCorrupt)
            }
        }
        if fileManager.fileExists(atPath: checkpointJournalURL.path) {
            // A previous process journaled advances it never folded. Fold them
            // before anything appends: a torn final line must not end up in
            // the middle of the journal.
            try replayCheckpointJournal(into: &sessions)
            try writeCheckpointDocument(sessions)
            try fileManager.removeItem(at: checkpointJournalURL)
        }
        checkpoints = sessions
    }

    /// Applies every complete journal line. A torn final line — the process
    /// died mid-append — is skipped, the way a parser never advances its offset
    /// past an unterminated line; that session keeps its previous checkpoint
    /// and its snapshot-keyed ledger record makes the re-read idempotent. Any
    /// other undecodable line fails closed before a parser or the ledger runs.
    private func replayCheckpointJournal(into sessions: inout [String: SessionCheckpoint]) throws {
        let data = try Data(contentsOf: checkpointJournalURL)
        let decoder = JSONDecoder()
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let entry = try decoder.decode(CheckpointJournalEntry.self, from: data[lineStart..<newline])
            sessions[entry.key] = entry.checkpoint
            lineStart = data.index(after: newline)
        }
    }

    /// Durably records one checkpoint advance in O(1): a single journal line,
    /// appended after the ledger records it covers.
    private func journalCheckpoint(key: String, checkpoint: SessionCheckpoint) throws {
        var line = try JSONEncoder().encode(CheckpointJournalEntry(key: key, checkpoint: checkpoint))
        line.append(0x0A)
        try openCheckpointJournal().write(contentsOf: line)
        journaledCheckpoints += 1
    }

    private func openCheckpointJournal() throws -> FileHandle {
        if let checkpointJournal { return checkpointJournal }
        try prepareCheckpointDirectory()
        if !fileManager.fileExists(atPath: checkpointJournalURL.path) {
            guard fileManager.createFile(atPath: checkpointJournalURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            #if !os(Windows)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointJournalURL.path)
            #endif
        }
        let handle = try FileHandle(forWritingTo: checkpointJournalURL)
        try handle.seekToEnd()
        checkpointJournal = handle
        return handle
    }

    /// Folds the pass's journal into the checkpoint document — one atomic
    /// rewrite per pass. The document is replaced before the journal is
    /// removed, so a crash between the two only replays entries it holds.
    private func compactCheckpointJournal() throws {
        guard journaledCheckpoints > 0 else { return }
        try checkpointJournal?.close()
        checkpointJournal = nil
        try writeCheckpointDocument(checkpoints ?? [:])
        try fileManager.removeItem(at: checkpointJournalURL)
        journaledCheckpoints = 0
    }

    private func writeCheckpointDocument(_ sessions: [String: SessionCheckpoint]) throws {
        try prepareCheckpointDirectory()
        let document = CheckpointDocument(
            schemaVersion: Self.checkpointSchemaVersion,
            sessions: sessions,
            rows: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: checkpointURL, options: .atomic)
        #if !os(Windows)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
        #endif
    }

    private func prepareCheckpointDirectory() throws {
        let directory = checkpointURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if !os(Windows)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
    }

    private static func checkpointKey(for usage: TokenUsage) -> String {
        // Copilot counters are session-scoped even when the selected model
        // changes mid-session. Model must not create a fresh cumulative scope.
        digest("\(usage.providerID.rawValue)\u{1f}\(usage.sessionId)")
    }

    private static func snapshotKey(checkpointKey: String, checkpoint: Checkpoint) -> String {
        digest([
            checkpointKey,
            String(checkpoint.inputTokens),
            String(checkpoint.outputTokens),
            String(checkpoint.cacheCreationTokens),
            String(checkpoint.cacheReadTokens),
            String(checkpoint.reasoningTokens),
            String(checkpoint.cost.bitPattern),
            String(checkpoint.startTime.timeIntervalSinceReferenceDate.bitPattern),
            String(checkpoint.endTime.timeIntervalSinceReferenceDate.bitPattern)
        ].joined(separator: "\u{1f}"))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func confidence(for value: UsageProvenanceConfidence) -> BurnBarUsageConfidence {
        switch value {
        case .exact: .exact
        case .derivedExact: .derivedExact
        case .highConfidenceEstimate: .highConfidenceEstimate
        case .lowConfidenceEstimate: .lowConfidenceEstimate
        case .unknown: .unknown
        }
    }
}
