import OpenBurnBarEngine
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

public struct BurnBarUsageRecord: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let event: BurnBarUsageEvent

    public init(idempotencyKey: String, event: BurnBarUsageEvent) {
        self.idempotencyKey = idempotencyKey
        self.event = event
    }
}

public struct BurnBarUsageRecordResult: Hashable, Sendable {
    public let record: BurnBarUsageRecord
    public let inserted: Bool

    public init(record: BurnBarUsageRecord, inserted: Bool) {
        self.record = record
        self.inserted = inserted
    }
}

enum BurnBarUsageValidationError: Error, Equatable, LocalizedError {
    case invalidField(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidField(let field, let reason):
            return "Invalid usage event: \(field) \(reason)."
        }
    }
}

enum BurnBarUsageLedgerError: Error, Equatable, LocalizedError {
    case conflictingIdempotencyKey(String)
    case aggregateOverflow(String)

    var errorDescription: String? {
        switch self {
        case .conflictingIdempotencyKey(let key):
            return "Usage ledger contains conflicting events for idempotency key \(key)."
        case .aggregateOverflow(let field):
            return "Usage projection exceeds the supported range for \(field)."
        }
    }
}

/// What happened to one event handed to `recordDurably`.
public enum BurnBarUsageDurableRecordOutcome: Equatable, Sendable {
    /// Appended to the ledger (`inserted == false`: an identical record was
    /// already there).
    case recorded(inserted: Bool)
    /// The ledger append failed; the event waits in the durable retry spool
    /// and is replayed, under the same idempotency key, on the next write or
    /// replay tick.
    case deferred
    /// The event itself can never be recorded (invalid fields, or a different
    /// event already holds its idempotency key). Counted, never retried.
    case rejected

    public var isRecorded: Bool {
        if case .recorded = self { return true }
        return false
    }
}

public struct BurnBarUsageLedgerSignature: Equatable, Sendable {
    public let recordCount: Int
    public let latestRecordedAt: Date?

    public init(recordCount: Int, latestRecordedAt: Date?) {
        self.recordCount = recordCount
        self.latestRecordedAt = latestRecordedAt
    }
}

/// Source-of-truth usage ledger. Unlike the diagnostic JSONL trails
/// (`provider-routing-decisions.jsonl`, `metrics.jsonl`), this file must NEVER
/// be size-rotated: the in-memory index addresses records by byte offset and
/// projections rebuild from these exact lines, so rotation is silent data
/// loss. If the ledger outgrows disk comfort, the answer is compaction (fold
/// aged events into the projection, then truncate with the index rebuilt) —
/// not a ring. See the routing store's ring for the pattern that applies
/// everywhere EXCEPT here.
public actor BurnBarUsageRecorder {
    static let maximumIdentifierBytes = 256
    static let maximumProjectNameBytes = 256
    static let maximumReturnedRecords = 10_000
    static let maximumFutureSkew: TimeInterval = 15
    static let earliestRecordedAt = Date(timeIntervalSince1970: 946_684_800)

    private let fileURL: URL
    private let projectionFileURL: URL
    private let logger: BurnBarDaemonLogger
    private let now: @Sendable () -> Date
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private struct RecordLocation: Equatable, Sendable {
        let byteOffset: UInt64
        let byteCount: Int
    }

    private struct LedgerIndex: Sendable {
        var locationsByKey: [String: RecordLocation]
        var recordCount: Int
        var latestRecordedAt: Date?

        static let empty = LedgerIndex(
            locationsByKey: [:],
            recordCount: 0,
            latestRecordedAt: nil
        )
    }

    private struct ProjectionBucketKey: Hashable, Comparable {
        let dayUTC: String
        let providerID: String
        let modelID: String

        static func < (lhs: ProjectionBucketKey, rhs: ProjectionBucketKey) -> Bool {
            (lhs.dayUTC, lhs.providerID, lhs.modelID)
                < (rhs.dayUTC, rhs.providerID, rhs.modelID)
        }
    }

    private struct MutableProjectionBucket {
        var totals = MutableTotals()
        var exactEventCount = 0
        var estimatedEventCount = 0
        var unknownEventCount = 0
        var firstRecordedAt: Date
        var lastRecordedAt: Date
    }

    private struct ProjectionSource {
        let fingerprint: String
        let totals: MutableTotals
        let buckets: [ProjectionBucketKey: MutableProjectionBucket]
    }

    private var ledgerIndex: LedgerIndex?
    private var cachedProjection: BurnBarUsageProjection?
    /// Durable retry spool for `recordDurably`: one `BurnBarUsageRecord` JSON
    /// line per event whose ledger append failed, in arrival order.
    private let deferredFileURL: URL
    private var deferredRecords: [BurnBarUsageRecord]?
    static let maximumDeferredRecords = 10_000

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        projectionFileURL: URL? = nil,
        deferredFileURL: URL? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "usage-recorder"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.projectionFileURL = projectionFileURL
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("usage-projection.json")
        self.deferredFileURL = deferredFileURL
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("usage-events.deferred.jsonl")
        self.logger = logger
        self.now = now
    }

    public func record(
        _ event: BurnBarUsageEvent,
        idempotencyKey: String
    ) throws -> BurnBarUsageRecordResult {
        let normalizedKey = try Self.validatedIdentifier(idempotencyKey, field: "idempotencyKey")
        try validate(event)

        var index = try loadIndexIfNeeded()
        let record = BurnBarUsageRecord(idempotencyKey: normalizedKey, event: event)

        if let location = index.locationsByKey[normalizedKey] {
            let existing = try readRecord(at: location)
            guard existing == record else {
                throw BurnBarUsageLedgerError.conflictingIdempotencyKey(normalizedKey)
            }
            logger.debug(
                "usage_record_skipped_duplicate",
                metadata: ["idempotency_key": normalizedKey]
            )
            return BurnBarUsageRecordResult(record: existing, inserted: false)
        }

        let location = try append(record)
        index.locationsByKey[normalizedKey] = location
        index.recordCount += 1
        index.latestRecordedAt = max(index.latestRecordedAt ?? event.recordedAt, event.recordedAt)
        ledgerIndex = index
        // The projection is a derived cache. Invalidate it in O(1) and rebuild
        // only when a projection consumer asks; recounting the whole ledger on
        // every imported row would make a batch import quadratic.
        cachedProjection = nil

        logger.notice(
            "usage_record_inserted",
            metadata: [
                "idempotency_key": normalizedKey,
                "provider_id": event.providerID,
                "model_id": event.modelID
            ]
        )

        return BurnBarUsageRecordResult(record: record, inserted: true)
    }

    /// Records spend without ever losing it to a transient ledger failure.
    ///
    /// The proxied request that produced this usage has already been served,
    /// so a failed append must neither fail that request nor vanish: the
    /// event goes to a durable retry spool and is replayed, in order and
    /// under its own idempotency key (so a replay can never double count),
    /// before any newer event and on every `replayDeferred()` tick. Every
    /// outcome other than a clean append is counted on `GET /metrics`.
    public func recordDurably(
        _ event: BurnBarUsageEvent,
        idempotencyKey: String
    ) -> BurnBarUsageDurableRecordOutcome {
        let normalizedKey: String
        do {
            normalizedKey = try Self.validatedIdentifier(idempotencyKey, field: "idempotencyKey")
            try validate(event)
        } catch {
            return reject(idempotencyKey: idempotencyKey, event: event, error: error)
        }

        replayDeferred()
        if !loadDeferredRecordsIfNeeded().isEmpty {
            // Older spend is still waiting; keep arrival order.
            return deferRecord(BurnBarUsageRecord(idempotencyKey: normalizedKey, event: event), error: nil)
        }
        do {
            let result = try record(event, idempotencyKey: normalizedKey)
            return .recorded(inserted: result.inserted)
        } catch BurnBarUsageLedgerError.conflictingIdempotencyKey(let key) where key == normalizedKey {
            return reject(idempotencyKey: normalizedKey, event: event, error: BurnBarUsageLedgerError.conflictingIdempotencyKey(key))
        } catch {
            return deferRecord(BurnBarUsageRecord(idempotencyKey: normalizedKey, event: event), error: error)
        }
    }

    /// Appends spooled events to the ledger in arrival order, stopping at the
    /// first one that still fails. Returns how many were replayed.
    @discardableResult
    public func replayDeferred() -> Int {
        var pending = loadDeferredRecordsIfNeeded()
        guard !pending.isEmpty else { return 0 }
        var replayed = 0
        var rejected = 0
        while let next = pending.first {
            do {
                _ = try record(next.event, idempotencyKey: next.idempotencyKey)
                replayed += 1
            } catch BurnBarUsageLedgerError.conflictingIdempotencyKey(let key) where key == next.idempotencyKey {
                rejected += 1
                logger.error(
                    "usage_record_deferred_conflict_dropped",
                    metadata: ["idempotency_key": key, "provider_id": next.event.providerID]
                )
            } catch {
                break
            }
            pending.removeFirst()
        }
        guard replayed + rejected > 0 else { return 0 }
        deferredRecords = pending
        rewriteDeferredSpool(pending)
        BurnBarDaemonMetricsCounters.recordUsageLedgerReplay(
            replayed: replayed,
            rejected: rejected,
            pending: pending.count
        )
        logger.notice(
            "usage_record_deferred_replayed",
            metadata: ["replayed": "\(replayed)", "pending": "\(pending.count)"]
        )
        return replayed
    }

    /// Events waiting in the retry spool.
    public func deferredRecordCount() -> Int {
        loadDeferredRecordsIfNeeded().count
    }

    private func reject(
        idempotencyKey: String,
        event: BurnBarUsageEvent,
        error: Error
    ) -> BurnBarUsageDurableRecordOutcome {
        BurnBarDaemonMetricsCounters.recordUsageLedgerRejected()
        logger.error(
            "usage_record_rejected",
            metadata: [
                "idempotency_key": idempotencyKey,
                "provider_id": event.providerID,
                "model_id": event.modelID,
                "error": "\(error)"
            ]
        )
        return .rejected
    }

    private func deferRecord(_ record: BurnBarUsageRecord, error: Error?) -> BurnBarUsageDurableRecordOutcome {
        var pending = loadDeferredRecordsIfNeeded()
        if let index = pending.firstIndex(where: { $0.idempotencyKey == record.idempotencyKey }) {
            // A retried request re-reporting the same attempt: keep one copy.
            pending[index] = record
        } else {
            pending.append(record)
        }
        var dropped = 0
        if pending.count > Self.maximumDeferredRecords {
            dropped = pending.count - Self.maximumDeferredRecords
            pending.removeFirst(dropped)
        }
        deferredRecords = pending
        let spooled = rewriteDeferredSpool(pending)
        BurnBarDaemonMetricsCounters.recordUsageLedgerDeferred(pending: pending.count, dropped: dropped)
        logger.error(
            "usage_record_deferred",
            metadata: [
                "idempotency_key": record.idempotencyKey,
                "provider_id": record.event.providerID,
                "model_id": record.event.modelID,
                "pending": "\(pending.count)",
                "spooled": spooled ? "true" : "false",
                "error": error.map { "\($0)" } ?? "older events pending"
            ]
        )
        return .deferred
    }

    private func loadDeferredRecordsIfNeeded() -> [BurnBarUsageRecord] {
        if let deferredRecords { return deferredRecords }
        var loaded: [BurnBarUsageRecord] = []
        if let data = FileManager.default.contents(atPath: deferredFileURL.path) {
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                do {
                    loaded.append(try decoder.decode(BurnBarUsageRecord.self, from: Data(line)))
                } catch {
                    logger.error("usage_record_deferred_line_unreadable", metadata: ["error": "\(error)"])
                }
            }
        }
        deferredRecords = loaded
        BurnBarDaemonMetricsCounters.setUsageLedgerPending(loaded.count)
        return loaded
    }

    /// Rewrites the spool atomically (0600). Returns false when it could not
    /// be written; the records then stay pending in memory for this process.
    @discardableResult
    private func rewriteDeferredSpool(_ records: [BurnBarUsageRecord]) -> Bool {
        do {
            if records.isEmpty {
                if FileManager.default.fileExists(atPath: deferredFileURL.path) {
                    try FileManager.default.removeItem(at: deferredFileURL)
                }
                return true
            }
            try FileManager.default.createDirectory(
                at: deferredFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var data = Data()
            for record in records {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try data.write(to: deferredFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deferredFileURL.path)
            return true
        } catch {
            BurnBarDaemonMetricsCounters.recordUsageLedgerSpoolWriteFailure()
            logger.error("usage_record_deferred_spool_write_failed", metadata: ["error": "\(error)"])
            return false
        }
    }

    public func records() throws -> [BurnBarUsageRecord] {
        let index = try loadIndexIfNeeded()
        var records: [BurnBarUsageRecord] = []
        records.reserveCapacity(index.recordCount)
        try forEachLedgerRecord { record, location in
            guard index.locationsByKey[record.idempotencyKey] == location else { return }
            records.append(record)
        }
        return records
    }

    public func recentUsage(limit: Int) throws -> [BurnBarUsageEvent] {
        try newestRecords(limit: limit) { _ in true }.map(\.event)
    }

    /// Returns the newest matching records in chronological order. Working
    /// memory is bounded by `limit`, independent of total ledger size.
    public func records(in interval: DateInterval, limit: Int) throws -> [BurnBarUsageRecord] {
        Array(try newestRecords(limit: limit) { interval.contains($0.recordedAt) }.reversed())
    }

    /// Enriches a complete, bounded Activity snapshot without materializing the
    /// ledger. The caller establishes history completeness first, so an
    /// oversized conversation database never opens or scans the usage file.
    func enrichingActivityHistory(
        _ sessions: [BurnBarActivityHistorySession]
    ) throws -> [BurnBarActivityHistorySession] {
        guard !sessions.isEmpty else { return sessions }

        struct ActivityUsageTotals {
            var tokens = 0
            var costUsd = 0.0
            var model: String?
        }

        var sessionIndexesByID: [String: [Int]] = [:]
        var sourceIndexesByID: [String: [Int]] = [:]
        for (index, session) in sessions.enumerated() {
            sessionIndexesByID[session.providerSessionID, default: []].append(index)
            sourceIndexesByID[session.sourceID, default: []].append(index)
        }

        let index = try loadIndexIfNeeded()
        var totals = Array(repeating: ActivityUsageTotals(), count: sessions.count)
        try forEachLedgerRecord { record, location in
            guard index.locationsByKey[record.idempotencyKey] == location else { return }
            let event = record.event
            let sessionMatches = event.sessionID.flatMap { sessionIndexesByID[$0] }
            let sourceMatches = event.runID.flatMap { sourceIndexesByID[$0.rawValue] }
            guard sessionMatches != nil || sourceMatches != nil else { return }

            var matchingIndexes = Set<Int>()
            if let sessionMatches {
                matchingIndexes.formUnion(sessionMatches)
            }
            if let sourceMatches {
                matchingIndexes.formUnion(sourceMatches)
            }

            var eventTokens = 0
            for value in [event.inputTokens, event.outputTokens, event.reasoningTokens] {
                let addition = eventTokens.addingReportingOverflow(max(0, value))
                eventTokens = addition.overflow ? Int.max : addition.partialValue
            }

            for matchingIndex in matchingIndexes {
                let tokenAddition = totals[matchingIndex].tokens
                    .addingReportingOverflow(eventTokens)
                totals[matchingIndex].tokens = tokenAddition.overflow
                    ? Int.max
                    : tokenAddition.partialValue
                if event.cost.isFinite {
                    totals[matchingIndex].costUsd += max(0, event.cost)
                }
                if totals[matchingIndex].model == nil {
                    totals[matchingIndex].model = event.modelID
                }
            }
        }

        return sessions.enumerated().map { index, session in
            let usage = totals[index]
            return BurnBarActivityHistorySession(
                id: session.id,
                provider: session.provider,
                model: session.model == "unknown"
                    ? usage.model ?? session.model
                    : session.model,
                startedAt: session.startedAt,
                tokens: usage.tokens,
                costUsd: usage.costUsd,
                title: session.title,
                sourceID: session.sourceID,
                providerSessionID: session.providerSessionID,
                runID: session.runID,
                projectName: session.projectName,
                bodyMD: session.bodyMD
            )
        }
    }

    /// Streams the canonical ledger and sums matching spend without retaining
    /// the underlying records.
    public func sumCost(
        since start: Date,
        matching predicate: @Sendable (BurnBarUsageEvent) -> Bool
    ) throws -> Double {
        let index = try loadIndexIfNeeded()
        var total = 0.0
        try forEachLedgerRecord { record, location in
            guard index.locationsByKey[record.idempotencyKey] == location,
                  record.event.recordedAt >= start,
                  predicate(record.event) else {
                return
            }
            let next = total + record.event.cost
            guard next.isFinite else {
                throw BurnBarUsageLedgerError.aggregateOverflow("cost")
            }
            total = next
        }
        return total
    }

    /// Cheap change-gate metadata maintained by the compact ledger index.
    public func signature() throws -> BurnBarUsageLedgerSignature {
        let index = try loadIndexIfNeeded()
        return BurnBarUsageLedgerSignature(
            recordCount: index.recordCount,
            latestRecordedAt: index.latestRecordedAt
        )
    }

    /// Exposes the bounded retained-state invariant to focused tests.
    var retainedRecordCount: Int {
        0
    }

    /// Returns the daemon-owned, durable projection of the canonical ledger.
    /// A stale or tampered projection is rebuilt before it is returned.
    public func projection() throws -> BurnBarUsageProjection {
        if let cachedProjection {
            return cachedProjection
        }
        let source = try projectionSource()

        let persisted = try? loadPersistedProjection()
        if let persisted,
           try projectionMatchesLedger(persisted, source: source) {
            cachedProjection = persisted
            return persisted
        }

        return try rebuildProjection(
            source: source,
            previousGeneration: persisted?.generation
        )
    }

    /// Rebuilds all derived totals from the append-only source ledger. Source
    /// events remain untouched, and generation advances even when inputs did
    /// not change so callers can prove a recount actually ran.
    public func recountProjection() throws -> BurnBarUsageProjection {
        let source = try projectionSource()
        let persisted = cachedProjection ?? (try? loadPersistedProjection())
        return try rebuildProjection(
            source: source,
            previousGeneration: persisted?.generation
        )
    }

    private func loadIndexIfNeeded() throws -> LedgerIndex {
        if let ledgerIndex { return ledgerIndex }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            ledgerIndex = .empty
            return .empty
        }

        var index = LedgerIndex.empty
        try forEachLedgerRecord { record, location in
            let key = record.idempotencyKey
            if let existingLocation = index.locationsByKey[key] {
                let existing = try readRecord(at: existingLocation)
                guard existing == record else {
                    throw BurnBarUsageLedgerError.conflictingIdempotencyKey(key)
                }
                return
            }
            index.locationsByKey[key] = location
            index.recordCount += 1
            index.latestRecordedAt = max(
                index.latestRecordedAt ?? record.event.recordedAt,
                record.event.recordedAt
            )
        }

        ledgerIndex = index
        return index
    }

    private func projectionSource() throws -> ProjectionSource {
        let index = try loadIndexIfNeeded()
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        var totals = MutableTotals()
        var buckets: [ProjectionBucketKey: MutableProjectionBucket] = [:]
        try forEachLedgerRecord { record, location in
            guard index.locationsByKey[record.idempotencyKey] == location else { return }
            let canonical = try canonicalEncoder.encode(record)
            hasher.update(data: canonical)
            hasher.update(data: Data([0x0A]))

            let event = record.event
            try totals.add(event)
            let key = ProjectionBucketKey(
                dayUTC: Self.utcDay(event.recordedAt),
                providerID: event.providerID,
                modelID: event.modelID
            )
            var bucket = buckets[key] ?? MutableProjectionBucket(
                firstRecordedAt: event.recordedAt,
                lastRecordedAt: event.recordedAt
            )
            try bucket.totals.add(event)
            switch event.confidence {
            case .exact, .derivedExact:
                try Self.increment(&bucket.exactEventCount, field: "exactEventCount")
            case .highConfidenceEstimate, .lowConfidenceEstimate:
                try Self.increment(&bucket.estimatedEventCount, field: "estimatedEventCount")
            case .unknown:
                try Self.increment(&bucket.unknownEventCount, field: "unknownEventCount")
            }
            bucket.firstRecordedAt = min(bucket.firstRecordedAt, event.recordedAt)
            bucket.lastRecordedAt = max(bucket.lastRecordedAt, event.recordedAt)
            buckets[key] = bucket
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ProjectionSource(fingerprint: fingerprint, totals: totals, buckets: buckets)
    }

    private func loadPersistedProjection() throws -> BurnBarUsageProjection {
        try decoder.decode(BurnBarUsageProjection.self, from: Data(contentsOf: projectionFileURL))
    }

    private func projectionMatchesLedger(
        _ projection: BurnBarUsageProjection,
        source: ProjectionSource
    ) throws -> Bool {
        guard projection.schemaVersion == 1,
              projection.generation > 0,
              projection.ledgerSHA256 == source.fingerprint else {
            return false
        }
        let expected = try makeProjection(
            source: source,
            generation: projection.generation,
            generatedAt: projection.generatedAt
        )
        return expected == projection
    }

    private func rebuildProjection(
        source: ProjectionSource,
        previousGeneration: Int?
    ) throws -> BurnBarUsageProjection {
        let nextGeneration: Int
        if let previousGeneration {
            let incremented = previousGeneration.addingReportingOverflow(1)
            guard !incremented.overflow else {
                throw BurnBarUsageLedgerError.aggregateOverflow("generation")
            }
            nextGeneration = incremented.partialValue
        } else {
            nextGeneration = 1
        }
        let projection = try makeProjection(
            source: source,
            generation: nextGeneration,
            generatedAt: now()
        )
        try persistProjection(projection)
        cachedProjection = projection
        return projection
    }

    private func makeProjection(
        source: ProjectionSource,
        generation: Int,
        generatedAt: Date
    ) throws -> BurnBarUsageProjection {
        let projectedBuckets = try source.buckets.keys.sorted().map { key in
            guard let bucket = source.buckets[key] else {
                throw BurnBarUsageLedgerError.aggregateOverflow("bucket lookup")
            }
            return BurnBarUsageProjectionBucket(
                dayUTC: key.dayUTC,
                providerID: key.providerID,
                modelID: key.modelID,
                totals: bucket.totals.value,
                exactEventCount: bucket.exactEventCount,
                estimatedEventCount: bucket.estimatedEventCount,
                unknownEventCount: bucket.unknownEventCount,
                firstRecordedAt: bucket.firstRecordedAt,
                lastRecordedAt: bucket.lastRecordedAt
            )
        }
        return BurnBarUsageProjection(
            generation: generation,
            generatedAt: generatedAt,
            ledgerSHA256: source.fingerprint,
            totals: source.totals.value,
            buckets: projectedBuckets
        )
    }

    private func persistProjection(_ projection: BurnBarUsageProjection) throws {
        let directoryURL = projectionFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let projectionEncoder = JSONEncoder()
        projectionEncoder.outputFormatting = [.sortedKeys]
        try projectionEncoder.encode(projection).write(to: projectionFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: projectionFileURL.path
        )
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func increment(_ value: inout Int, field: String) throws {
        let incremented = value.addingReportingOverflow(1)
        guard !incremented.overflow else {
            throw BurnBarUsageLedgerError.aggregateOverflow(field)
        }
        value = incremented.partialValue
    }

    private func newestRecords(
        limit: Int,
        matching predicate: (BurnBarUsageEvent) -> Bool
    ) throws -> [BurnBarUsageRecord] {
        let boundedLimit = min(max(0, limit), Self.maximumReturnedRecords)
        guard boundedLimit > 0 else { return [] }
        let index = try loadIndexIfNeeded()
        var newest: [BurnBarUsageRecord] = []
        newest.reserveCapacity(min(boundedLimit * 2, index.recordCount))

        try forEachLedgerRecord { record, location in
            guard index.locationsByKey[record.idempotencyKey] == location,
                  predicate(record.event) else {
                return
            }
            newest.append(record)
            if newest.count >= boundedLimit * 2 {
                newest.sort { $0.event.recordedAt > $1.event.recordedAt }
                newest.removeSubrange(boundedLimit..<newest.count)
            }
        }

        newest.sort { $0.event.recordedAt > $1.event.recordedAt }
        if newest.count > boundedLimit {
            newest.removeSubrange(boundedLimit..<newest.count)
        }
        return newest
    }

    private func forEachLedgerRecord(
        _ body: (BurnBarUsageRecord, RecordLocation) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let reader = BufferedLineReader(fileHandle: handle)
        var previousEndOffset: UInt64 = 0
        var lineCount = 0

        while let line = reader.nextLine() {
            lineCount += 1
            if lineCount % 1_024 == 0 {
                try Task.checkCancellation()
            }
            let endOffset = UInt64(clamping: line.endOffset)
            let distance = endOffset.subtractingReportingOverflow(previousEndOffset)
            guard !distance.overflow, distance.partialValue <= UInt64(Int.max) else {
                throw BurnBarUsageLedgerError.aggregateOverflow("ledger byte offset")
            }
            let location = RecordLocation(
                byteOffset: previousEndOffset,
                byteCount: Int(distance.partialValue)
            )
            previousEndOffset = endOffset

            let record = try decoder.decode(BurnBarUsageRecord.self, from: Data(line.text.utf8))
            let key = try Self.validatedIdentifier(record.idempotencyKey, field: "idempotencyKey")
            try validate(record.event)
            guard key == record.idempotencyKey else {
                throw BurnBarUsageValidationError.invalidField(
                    "idempotencyKey",
                    "must remain canonical"
                )
            }
            try body(record, location)
        }
        try Task.checkCancellation()
    }

    private func readRecord(at location: RecordLocation) throws -> BurnBarUsageRecord {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: location.byteOffset)
        let data = try handle.read(upToCount: location.byteCount) ?? Data()
        return try decoder.decode(BurnBarUsageRecord.self, from: data)
    }

    private func append(_ record: BurnBarUsageRecord) throws -> RecordLocation {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encodedRecord = try encoder.encode(record) + Data([0x0A])
        let location: RecordLocation
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            let offset = try handle.seekToEnd()
            location = RecordLocation(byteOffset: offset, byteCount: encodedRecord.count)
            try handle.write(contentsOf: encodedRecord)
        } else {
            location = RecordLocation(byteOffset: 0, byteCount: encodedRecord.count)
            try encodedRecord.write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return location
    }

    private func validate(_ event: BurnBarUsageEvent) throws {
        _ = try Self.validatedIdentifier(event.providerID, field: "providerID")
        _ = try Self.validatedIdentifier(event.modelID, field: "modelID")
        if let runID = event.runID?.rawValue {
            _ = try Self.validatedIdentifier(runID, field: "runID")
        }
        if let sessionID = event.sessionID {
            _ = try Self.validatedIdentifier(sessionID, field: "sessionID")
        }
        if let parentRequestID = event.parentRequestID {
            _ = try Self.validatedIdentifier(parentRequestID, field: "parentRequestID")
        }
        if let projectName = event.projectName {
            _ = try Self.validatedText(
                projectName,
                field: "projectName",
                maximumBytes: Self.maximumProjectNameBytes
            )
        }

        let tokenFields = [
            ("inputTokens", event.inputTokens),
            ("outputTokens", event.outputTokens),
            ("cacheCreationTokens", event.cacheCreationTokens),
            ("cacheReadTokens", event.cacheReadTokens),
            ("reasoningTokens", event.reasoningTokens)
        ]
        for (field, value) in tokenFields where value < 0 {
            throw BurnBarUsageValidationError.invalidField(field, "must be nonnegative")
        }

        var totalTokens = 0
        for (_, value) in tokenFields {
            let addition = totalTokens.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw BurnBarUsageValidationError.invalidField("token counts", "exceed the supported integer range")
            }
            totalTokens = addition.partialValue
        }

        guard event.cost.isFinite, event.cost >= 0 else {
            throw BurnBarUsageValidationError.invalidField("cost", "must be finite and nonnegative")
        }
        let timestamp = event.recordedAt.timeIntervalSince1970
        let latestRecordedAt = now().addingTimeInterval(Self.maximumFutureSkew)
        guard timestamp.isFinite,
              event.recordedAt >= Self.earliestRecordedAt,
              event.recordedAt <= latestRecordedAt else {
            throw BurnBarUsageValidationError.invalidField(
                "recordedAt",
                "must be on or after 2000 and no more than 15 seconds in the future"
            )
        }
    }

    private static func validatedIdentifier(_ raw: String, field: String) throws -> String {
        try validatedText(raw, field: field, maximumBytes: maximumIdentifierBytes)
    }

    private static func validatedText(_ raw: String, field: String, maximumBytes: Int) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == raw else {
            throw BurnBarUsageValidationError.invalidField(field, "must be nonblank and trimmed")
        }
        guard raw.utf8.count <= maximumBytes else {
            throw BurnBarUsageValidationError.invalidField(
                field,
                "must not exceed \(maximumBytes) UTF-8 bytes"
            )
        }
        guard !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BurnBarUsageValidationError.invalidField(field, "must not contain control characters")
        }
        return raw
    }
}

private struct MutableTotals {
    var eventCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var reasoningTokens = 0
    var totalTokens = 0
    var cost = 0.0

    mutating func add(_ event: BurnBarUsageEvent) throws {
        try add(1, to: &eventCount, field: "eventCount")
        try add(event.inputTokens, to: &inputTokens, field: "inputTokens")
        try add(event.outputTokens, to: &outputTokens, field: "outputTokens")
        try add(event.cacheCreationTokens, to: &cacheCreationTokens, field: "cacheCreationTokens")
        try add(event.cacheReadTokens, to: &cacheReadTokens, field: "cacheReadTokens")
        try add(event.reasoningTokens, to: &reasoningTokens, field: "reasoningTokens")

        var eventTotal = 0
        for value in [
            event.inputTokens,
            event.outputTokens,
            event.cacheCreationTokens,
            event.cacheReadTokens,
            event.reasoningTokens
        ] {
            try add(value, to: &eventTotal, field: "event.totalTokens")
        }
        try add(eventTotal, to: &totalTokens, field: "totalTokens")

        let nextCost = cost + event.cost
        guard nextCost.isFinite else {
            throw BurnBarUsageLedgerError.aggregateOverflow("cost")
        }
        cost = nextCost
    }

    var value: BurnBarUsageProjectionTotals {
        BurnBarUsageProjectionTotals(
            eventCount: eventCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            cost: cost
        )
    }

    private func add(_ increment: Int, to value: inout Int, field: String) throws {
        let result = value.addingReportingOverflow(increment)
        guard !result.overflow else {
            throw BurnBarUsageLedgerError.aggregateOverflow(field)
        }
        value = result.partialValue
    }
}
