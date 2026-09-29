import Foundation
import OpenBurnBarKernel

/// Turns the daemon's append-only usage ledger (`usage-events.jsonl`) into
/// `token_usage` rows. It is the one path daemon-recorded spend takes into the
/// app's database; the `daemon.usage.recent` RPC only feeds the "recent usage"
/// list.
///
/// - **One identity.** Every ledger line carries an idempotency key. A key
///   counts once no matter how many passes (or which process) read it.
/// - **Sums, not snapshots.** Events are summed per row identity
///   (provider, session, model, account) — the `token_usage` upsert key — so
///   two requests in one session add up instead of the later one replacing
///   the earlier.
/// - **Watermark.** A pass reads only the bytes appended since the previous
///   pass. The first pass, or one that finds the ledger truncated or its head
///   rewritten, rebuilds from byte 0. Rows always carry full sums, so a
///   rebuild re-derives identical rows and re-importing is idempotent. (The
///   daemon never rotates this ledger — `BurnBarUsageRecorder` — so a rebuild
///   sees every event the previous pass saw.)
///
/// A value type: one owner (or one lock) serializes `importNewRecords`.
public struct DaemonUsageLedgerImporter: Sendable {
    public struct Pass: Sendable {
        /// Rows whose sums changed this pass, with their complete totals.
        public let changedRows: [TokenUsage]
        /// Rows the retired `daemon.usage.recent` import keyed differently
        /// (events with neither session nor run id); the caller deletes them
        /// so the same spend is not counted twice.
        public let supersededRows: [SupersededRow]
        /// Distinct ledger records known so far.
        public let recordCount: Int
        /// The newest records by `recordedAt` (at most `recentLimit`), for the
        /// "recent usage" list when the daemon cannot be asked over RPC.
        public let recentRecords: [LedgerRecord]
        /// True when this pass read the ledger from byte 0.
        public let rebuilt: Bool
    }

    /// A pre-importer `token_usage` identity for the same ledger event.
    public struct SupersededRow: Hashable, Sendable {
        public let provider: AgentProvider
        public let sessionId: String
        public let model: String
    }

    private struct RowKey: Hashable, Sendable {
        let provider: AgentProvider
        let sessionId: String
        let model: String
        let providerAccountID: String?
    }

    private struct RowTotals: Sendable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var reasoningTokens = 0
        var cost = 0.0
        var startTime: Date
        var endTime: Date
        var tokenConfidence: UsageProvenanceConfidence
        var latest: LedgerRecord
    }

    /// One `usage-events.jsonl` line.
    public struct LedgerRecord: Decodable, Sendable {
        public let idempotencyKey: String
        public let event: BurnBarUsageEvent
    }

    static let headDigestSpan = 4_096
    public static let recentLimit = 6

    private var byteOffset: UInt64 = 0
    /// Digest of the ledger's first `headDigestLength` bytes when last read:
    /// a different head means the file was replaced, not appended to.
    private var headDigest: String?
    private var headDigestLength = 0
    private var seenKeys: Set<String> = []
    private var rows: [RowKey: RowTotals] = [:]
    private var recentRecords: [LedgerRecord] = []
    private let decoder = JSONDecoder()

    public init() {}

    /// Reads what the ledger gained since the last pass. A missing ledger
    /// yields an empty pass (and resets, so a recreated ledger is read whole).
    public mutating func importNewRecords(from ledgerURL: URL) -> Pass {
        guard let handle = try? FileHandle(forReadingFrom: ledgerURL) else { // try?-ok(absent ledger = no daemon spend yet)
            reset()
            return Pass(changedRows: [], supersededRows: [], recordCount: 0, recentRecords: [], rebuilt: false)
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        let size = (try? handle.seekToEnd()) ?? 0 // try?-ok(size probe; 0 re-reads nothing)
        var rebuilt = false
        if headDigest == nil
            || size < byteOffset
            || size < UInt64(headDigestLength)
            || ParserScanDigest.headDigestHex(handle: handle, length: headDigestLength) != headDigest {
            // First pass, or the ledger was compacted/replaced underneath us.
            reset()
            rebuilt = true
        }
        headDigestLength = Int(min(UInt64(Self.headDigestSpan), size))
        headDigest = ParserScanDigest.headDigestHex(handle: handle, length: headDigestLength)

        var changed = Set<RowKey>()
        var superseded = Set<SupersededRow>()
        try? handle.seek(toOffset: byteOffset) // try?-ok(seek failure re-reads from the watermark next pass)
        let reader = BufferedLineReader(fileHandle: handle, startOffset: Int64(byteOffset))
        while let line = reader.nextLine() {
            // A half-written trailing line is read again once complete.
            guard line.isTerminated else { break }
            byteOffset = UInt64(clamping: line.endOffset)
            guard let record = try? decoder.decode(LedgerRecord.self, from: Data(line.text.utf8)) else { // try?-ok(unreadable line skipped, as the daemon's own reader would reject it)
                continue
            }
            guard seenKeys.insert(record.idempotencyKey).inserted,
                  let key = Self.rowKey(for: record) else { continue }
            add(record, to: key)
            noteRecent(record)
            changed.insert(key)
            if let legacy = Self.legacyRecentUsageRow(for: record.event, provider: key.provider) {
                superseded.insert(legacy)
            }
        }

        let changedRows = changed.compactMap { key in rows[key].map { usage(for: key, totals: $0) } }
            .sorted { ($0.startTime, $0.sessionId, $0.model) < ($1.startTime, $1.sessionId, $1.model) }
        return Pass(
            changedRows: changedRows,
            supersededRows: superseded.sorted { ($0.sessionId, $0.model) < ($1.sessionId, $1.model) },
            recordCount: seenKeys.count,
            recentRecords: recentRecords,
            rebuilt: rebuilt
        )
    }

    private mutating func noteRecent(_ record: LedgerRecord) {
        recentRecords.append(record)
        recentRecords.sort { $0.event.recordedAt > $1.event.recordedAt }
        if recentRecords.count > Self.recentLimit {
            recentRecords.removeLast(recentRecords.count - Self.recentLimit)
        }
    }

    private mutating func reset() {
        byteOffset = 0
        headDigest = nil
        headDigestLength = 0
        seenKeys = []
        rows = [:]
        recentRecords = []
    }

    /// Forgets the watermark so the next pass rebuilds every row from byte 0
    /// — for a caller whose write of the last pass's rows failed.
    public mutating func invalidate() {
        reset()
    }

    private mutating func add(_ record: LedgerRecord, to key: RowKey) {
        let event = record.event
        let eventConfidence = Self.tokenConfidence(event.confidence)
        guard var totals = rows[key] else {
            rows[key] = RowTotals(
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheCreationTokens: event.cacheCreationTokens,
                cacheReadTokens: event.cacheReadTokens,
                reasoningTokens: event.reasoningTokens,
                cost: event.cost,
                startTime: event.recordedAt,
                endTime: event.recordedAt,
                tokenConfidence: eventConfidence,
                latest: record
            )
            return
        }
        totals.inputTokens += event.inputTokens
        totals.outputTokens += event.outputTokens
        totals.cacheCreationTokens += event.cacheCreationTokens
        totals.cacheReadTokens += event.cacheReadTokens
        totals.reasoningTokens += event.reasoningTokens
        totals.cost += event.cost
        totals.startTime = min(totals.startTime, event.recordedAt)
        // A row is only as certain as its least certain event.
        totals.tokenConfidence = min(totals.tokenConfidence, eventConfidence)
        if event.recordedAt >= totals.endTime {
            totals.endTime = event.recordedAt
            totals.latest = record
        }
        rows[key] = totals
    }

    private func usage(for key: RowKey, totals: RowTotals) -> TokenUsage {
        let event = totals.latest.event
        return TokenUsage(
            provider: key.provider,
            sessionId: key.sessionId,
            projectName: event.projectName ?? Self.defaultProjectName(for: key.provider),
            model: key.model,
            inputTokens: totals.inputTokens,
            outputTokens: totals.outputTokens,
            cacheCreationTokens: totals.cacheCreationTokens,
            cacheReadTokens: totals.cacheReadTokens,
            reasoningTokens: totals.reasoningTokens,
            costUSD: totals.cost,
            // The daemon priced these with the same bundled catalog; say
            // whether that model has a listed rate or took the fallback table.
            pricingSource: ModelPricing.lookup(model: key.model, providerID: event.providerID).source,
            startTime: totals.startTime,
            endTime: totals.endTime,
            usageSource: .daemon,
            executionSourceID: event.executionSourceID,
            executionSourceName: event.executionSourceName,
            executionSourceKind: event.executionSourceKind,
            executionSourceConfidence: event.executionSourceConfidence.map(Self.tokenConfidence),
            providerAccountID: key.providerAccountID,
            providerAccountLabel: event.providerAccountLabel,
            providerAccountSource: key.providerAccountID == nil ? nil : .deviceKeychain,
            provenanceMethod: Self.provenanceMethod(for: key.provider, confidence: totals.tokenConfidence),
            provenanceConfidence: totals.tokenConfidence,
            // Ledger lines older than the explicit field carry the fusion
            // parent only in their idempotency key.
            parentRequestID: event.parentRequestID
                ?? Self.fusionParentRequestID(fromIdempotencyKey: totals.latest.idempotencyKey),
            // A ledger line that says `.subscription` must not be imported as
            // API dollars; unstamped lines use the legacy classifier.
            billingKind: BurnBarBillingProvenance.effectiveKind(of: event)
        )
    }

    private static func rowKey(for record: LedgerRecord) -> RowKey? {
        let event = record.event
        guard let provider = agentProvider(for: event.providerID) else { return nil }
        let account = event.providerAccountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RowKey(
            provider: provider,
            sessionId: event.sessionID ?? event.runID?.rawValue ?? record.idempotencyKey,
            model: event.modelID,
            providerAccountID: account?.isEmpty == false ? account : nil
        )
    }

    /// Extracts the Elder Wand fusion `parentRequestID` from a recorded
    /// idempotency key whose signature is `<parentRequestID>|<stage>|<model>|<index>`.
    /// Returns `nil` unless the leading segment is an `elderwand-` parent, so a
    /// normal request's key never masquerades as a fusion row.
    public static func fusionParentRequestID(fromIdempotencyKey key: String) -> String? {
        let head = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key
        return head.hasPrefix(FusionUsageRow.fusionParentPrefix) ? head : nil
    }

    /// The `daemon.usage.recent` import keyed an event with neither session
    /// nor run id as `<provider>-<recordedAt epoch>`.
    private static func legacyRecentUsageRow(for event: BurnBarUsageEvent, provider: AgentProvider) -> SupersededRow? {
        guard event.sessionID == nil, event.runID == nil else { return nil }
        return SupersededRow(
            provider: provider,
            sessionId: "\(provider.rawValue.lowercased())-\(event.recordedAt.timeIntervalSince1970)",
            model: event.modelID
        )
    }

    static func agentProvider(for providerID: String) -> AgentProvider? {
        let normalized = ProviderID.normalize(providerID)
        return AgentProvider.fromProviderID(ProviderID(rawValue: normalized))
            ?? AgentProvider.fromCatalogProviderID(normalized)
    }

    private static func defaultProjectName(for provider: AgentProvider) -> String {
        provider == .hermes ? "Hermes" : "OpenBurnBar Daemon"
    }

    private static func provenanceMethod(
        for provider: AgentProvider,
        confidence: UsageProvenanceConfidence
    ) -> UsageProvenanceMethod {
        guard provider == .hermes else { return .daemonBridge }
        switch confidence {
        case .exact, .derivedExact: return .providerLog
        case .highConfidenceEstimate, .lowConfidenceEstimate: return .heuristicEstimate
        case .unknown: return .daemonBridge
        }
    }

    private static func tokenConfidence(_ confidence: BurnBarUsageConfidence) -> UsageProvenanceConfidence {
        switch confidence {
        case .exact: return .exact
        case .derivedExact: return .derivedExact
        case .highConfidenceEstimate: return .highConfidenceEstimate
        case .lowConfidenceEstimate: return .lowConfidenceEstimate
        case .unknown: return .unknown
        }
    }
}
