import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// A proxied request's spend must survive a failed ledger write: it is
/// deferred to a durable spool, replayed exactly once, and every non-clean
/// write is counted on `GET /metrics` instead of vanishing into a log line.
final class BurnBarUsageRecorderDurabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BurnBarDaemonMetricsCounters._resetForTesting()
    }

    func testFailedLedgerWriteIsDeferredThenReplayedExactlyOnceAcrossRestart() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        try fixture.makeLedgerUnwritable()

        let first = fixture.event(input: 100, output: 40, cost: 0.5)
        let second = fixture.event(input: 7, output: 3, cost: 0.05)
        let recorder = fixture.recorder()

        let firstOutcome = await recorder.recordDurably(first, idempotencyKey: "gateway:first")
        let secondOutcome = await recorder.recordDurably(second, idempotencyKey: "gateway:second")

        XCTAssertEqual(firstOutcome, .deferred)
        XCTAssertEqual(secondOutcome, .deferred)
        let pendingCount = await recorder.deferredRecordCount()
        XCTAssertEqual(pendingCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.spoolURL.path))
        var counters = BurnBarDaemonMetricsCounters.snapshot()
        XCTAssertEqual(counters["usage_ledger_pending"], 2)
        XCTAssertEqual(counters["usage_ledger_deferred_total"], 2)

        // The ledger recovers and the daemon restarts: the spool replays in
        // arrival order under the original idempotency keys.
        try fixture.restoreLedger()
        let restarted = fixture.recorder()
        let replayed = await restarted.replayDeferred()
        XCTAssertEqual(replayed, 2)
        let records = try await restarted.records()
        XCTAssertEqual(records.map(\.idempotencyKey), ["gateway:first", "gateway:second"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.spoolURL.path))
        counters = BurnBarDaemonMetricsCounters.snapshot()
        XCTAssertEqual(counters["usage_ledger_pending"], 0)
        XCTAssertEqual(counters["usage_ledger_replayed_total"], 2)

        // A client retry of an already-replayed attempt is not billed twice.
        let retry = await restarted.recordDurably(first, idempotencyKey: "gateway:first")
        XCTAssertEqual(retry, .recorded(inserted: false))
        let projection = try await restarted.projection()
        XCTAssertEqual(projection.totals.inputTokens, 107)
        XCTAssertEqual(projection.totals.outputTokens, 43)
    }

    func testNewSpendWaitsBehindDeferredSpendAndDrainsOnTheNextWrite() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        try fixture.makeLedgerUnwritable()
        let recorder = fixture.recorder()
        let deferred = await recorder.recordDurably(fixture.event(input: 1, output: 1, cost: 0.01), idempotencyKey: "k1")
        XCTAssertEqual(deferred, .deferred)

        try fixture.restoreLedger()
        let outcome = await recorder.recordDurably(fixture.event(input: 2, output: 2, cost: 0.02), idempotencyKey: "k2")

        XCTAssertEqual(outcome, .recorded(inserted: true))
        let records = try await recorder.records()
        XCTAssertEqual(records.map(\.idempotencyKey), ["k1", "k2"])
        let pendingCount = await recorder.deferredRecordCount()
        XCTAssertEqual(pendingCount, 0)
    }

    func testInvalidSpendIsRejectedAndCountedWithoutSpooling() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let recorder = fixture.recorder()

        let outcome = await recorder.recordDurably(fixture.event(input: -5, output: 1, cost: 0.01), idempotencyKey: "bad")

        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(BurnBarDaemonMetricsCounters.snapshot()["usage_ledger_rejected_total"], 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.spoolURL.path))
        let records = try await recorder.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testConflictingIdempotencyKeyIsRejectedNotRetriedForever() async throws {
        let fixture = try DurabilityFixture()
        defer { fixture.remove() }
        let recorder = fixture.recorder()
        let original = await recorder.recordDurably(fixture.event(input: 10, output: 1, cost: 0.1), idempotencyKey: "same")
        XCTAssertEqual(original, .recorded(inserted: true))

        let conflicting = await recorder.recordDurably(fixture.event(input: 99, output: 9, cost: 0.9), idempotencyKey: "same")

        XCTAssertEqual(conflicting, .rejected)
        let pendingCount = await recorder.deferredRecordCount()
        XCTAssertEqual(pendingCount, 0)
    }
}

private final class DurabilityFixture {
    let root: URL
    let ledgerDirectory: URL
    let ledgerURL: URL
    let spoolURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-durability-\(UUID().uuidString)", isDirectory: true)
        ledgerDirectory = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
        ledgerURL = ledgerDirectory.appendingPathComponent("usage-events.jsonl")
        spoolURL = root.appendingPathComponent("spool/usage-events.deferred.jsonl")
    }

    func recorder() -> BurnBarUsageRecorder {
        BurnBarUsageRecorder(
            fileURL: ledgerURL,
            deferredFileURL: spoolURL,
            logger: BurnBarDaemonLogger(category: "usage-durability-tests")
        )
    }

    /// A directory where the ledger file should be: every read and append fails.
    func makeLedgerUnwritable() throws {
        try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: true)
    }

    func restoreLedger() throws {
        try FileManager.default.removeItem(at: ledgerURL)
    }

    func event(input: Int, output: Int, cost: Double) -> BurnBarUsageEvent {
        BurnBarUsageEvent(
            providerID: "zai",
            modelID: "glm-5",
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cost: cost,
            recordedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
