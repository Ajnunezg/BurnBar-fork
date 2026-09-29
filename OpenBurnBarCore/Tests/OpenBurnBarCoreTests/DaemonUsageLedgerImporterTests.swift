import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel

/// The app imported daemon spend two ways: the newest 20 events over RPC,
/// keyed on session/run id, and the whole ledger file, keyed on idempotency
/// key. Two requests in one session collapsed to the last one, events outside
/// the RPC window never arrived, and the two identities double counted. The
/// importer reads the ledger once, by watermark, keyed on the idempotency key,
/// and sums events per row.
final class DaemonUsageLedgerImporterTests: XCTestCase {
    private var root: URL!
    private var ledgerURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-ledger-importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledgerURL = root.appendingPathComponent("usage-events.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRequestsSharingASessionAddUpInsteadOfTheLastOneWinning() throws {
        try appendLedger([
            line(key: "k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            line(key: "k2", session: "chat-1", input: 300, output: 30, cost: 0.30, second: 2)
        ])
        var importer = DaemonUsageLedgerImporter()

        let pass = importer.importNewRecords(from: ledgerURL)

        let row = try XCTUnwrap(pass.changedRows.first)
        XCTAssertEqual(pass.changedRows.count, 1)
        XCTAssertEqual(row.sessionId, "chat-1")
        XCTAssertEqual(row.inputTokens, 400)
        XCTAssertEqual(row.outputTokens, 40)
        XCTAssertEqual(row.cost, 0.40, accuracy: 1e-12)
        XCTAssertEqual(row.startTime, date(second: 1))
        XCTAssertEqual(row.endTime, date(second: 2))
        XCTAssertEqual(row.usageSource, .daemon)
        XCTAssertEqual(pass.recordCount, 2)
    }

    func testEveryEventIsImportedNotOnlyTheNewestTwenty() throws {
        try appendLedger((1...45).map {
            try line(key: "k\($0)", session: "s\($0)", input: 10, output: 1, cost: 0.01, second: $0)
        })
        var importer = DaemonUsageLedgerImporter()

        let pass = importer.importNewRecords(from: ledgerURL)

        XCTAssertEqual(pass.changedRows.count, 45)
        XCTAssertEqual(pass.changedRows.map(\.inputTokens).reduce(0, +), 450)
    }

    func testWatermarkReadsOnlyAppendedLinesAndRowsKeepFullSums() throws {
        try appendLedger([
            line(key: "k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            line(key: "k2", session: "chat-2", input: 50, output: 5, cost: 0.05, second: 2)
        ])
        var importer = DaemonUsageLedgerImporter()
        _ = importer.importNewRecords(from: ledgerURL)

        let idle = importer.importNewRecords(from: ledgerURL)
        XCTAssertTrue(idle.changedRows.isEmpty, "no new bytes, nothing to write")
        XCTAssertFalse(idle.rebuilt)

        try appendLedger([line(key: "k3", session: "chat-1", input: 7, output: 3, cost: 0.02, second: 3)])
        let grown = importer.importNewRecords(from: ledgerURL)

        XCTAssertFalse(grown.rebuilt)
        XCTAssertEqual(grown.changedRows.map(\.sessionId), ["chat-1"])
        XCTAssertEqual(grown.changedRows.first?.inputTokens, 107)
        XCTAssertEqual(grown.changedRows.first?.outputTokens, 13)
        XCTAssertEqual(grown.changedRows.first?.cost ?? 0, 0.12, accuracy: 1e-12)
    }

    func testReimportAfterRestartRederivesIdenticalRowsNotDoubledOnes() throws {
        try appendLedger([
            line(key: "k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            line(key: "k2", session: "chat-1", input: 300, output: 30, cost: 0.30, second: 2)
        ])
        var first = DaemonUsageLedgerImporter()
        let original = first.importNewRecords(from: ledgerURL).changedRows

        var restarted = DaemonUsageLedgerImporter()
        let replay = restarted.importNewRecords(from: ledgerURL)

        XCTAssertTrue(replay.rebuilt)
        XCTAssertEqual(replay.changedRows.map(summary), original.map(summary))
        XCTAssertEqual(replay.changedRows.first?.inputTokens, 400)
    }

    func testAnIdempotencyKeyCountsOnce() throws {
        let duplicated = try line(key: "same-key", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1)
        try appendLedger([duplicated, duplicated])
        var importer = DaemonUsageLedgerImporter()

        let pass = importer.importNewRecords(from: ledgerURL)

        XCTAssertEqual(pass.recordCount, 1)
        XCTAssertEqual(pass.changedRows.first?.inputTokens, 100)
    }

    func testEventWithoutSessionOrRunIsItsOwnRowAndNamesTheRowItSupersedes() throws {
        try appendLedger([line(key: "gateway:abc", session: nil, input: 12, output: 4, cost: 0.02, second: 5)])
        var importer = DaemonUsageLedgerImporter()

        let pass = importer.importNewRecords(from: ledgerURL)

        XCTAssertEqual(pass.changedRows.first?.sessionId, "gateway:abc")
        XCTAssertEqual(
            pass.supersededRows,
            [.init(provider: .zai, sessionId: "\(AgentProvider.zai.rawValue.lowercased())-\(date(second: 5).timeIntervalSince1970)", model: "glm-5")]
        )
    }

    func testReplacedLedgerIsReadFromTheStart() throws {
        try appendLedger([line(key: "k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1)])
        var importer = DaemonUsageLedgerImporter()
        _ = importer.importNewRecords(from: ledgerURL)

        try FileManager.default.removeItem(at: ledgerURL)
        try appendLedger([line(key: "k9", session: "chat-9", input: 1, output: 1, cost: 0.01, second: 9)])
        let pass = importer.importNewRecords(from: ledgerURL)

        XCTAssertTrue(pass.rebuilt)
        XCTAssertEqual(pass.changedRows.map(\.sessionId), ["chat-9"])
        XCTAssertEqual(pass.recordCount, 1)
    }

    func testHalfWrittenTrailingLineWaitsForItsNewline() throws {
        let complete = try line(key: "k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1)
        let partial = try line(key: "k2", session: "chat-1", input: 5, output: 5, cost: 0.05, second: 2)
        try Data((complete + "\n" + partial.prefix(40)).utf8).write(to: ledgerURL)
        var importer = DaemonUsageLedgerImporter()

        let first = importer.importNewRecords(from: ledgerURL)
        XCTAssertEqual(first.changedRows.first?.inputTokens, 100)

        try Data((complete + "\n" + partial + "\n").utf8).write(to: ledgerURL)
        let second = importer.importNewRecords(from: ledgerURL)
        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(second.changedRows.first?.inputTokens, 105)
    }

    func testRowIsOnlyAsCertainAsItsWeakestEventAndSaysHowItWasPriced() throws {
        try appendLedger([
            line(key: "k1", session: "chat-1", input: 10, output: 1, cost: 0.01, second: 1),
            line(key: "k2", session: "chat-1", input: 10, output: 1, cost: 0.01, second: 2, confidence: "low_confidence_estimate"),
            line(key: "k3", session: "chat-2", input: 10, output: 1, cost: 0.01, second: 3, model: "no-such-model-anywhere-7")
        ])
        var importer = DaemonUsageLedgerImporter()

        let rows = importer.importNewRecords(from: ledgerURL).changedRows

        let mixed = try XCTUnwrap(rows.first { $0.sessionId == "chat-1" })
        XCTAssertEqual(mixed.tokenConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(mixed.pricingSource, .catalog)
        let unpriced = try XCTUnwrap(rows.first { $0.sessionId == "chat-2" })
        XCTAssertEqual(unpriced.pricingSource, .fallback)
        XCTAssertEqual(unpriced.provenanceConfidence, .lowConfidenceEstimate)
    }

    func testInvalidateMakesTheNextPassRebuildEveryRow() throws {
        try appendLedger([line(key: "k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1)])
        var importer = DaemonUsageLedgerImporter()
        _ = importer.importNewRecords(from: ledgerURL)

        importer.invalidate()
        let pass = importer.importNewRecords(from: ledgerURL)

        XCTAssertTrue(pass.rebuilt)
        XCTAssertEqual(pass.changedRows.map(\.inputTokens), [100])
    }

    func testRecentRecordsAreTheNewestByRecordedAt() throws {
        try appendLedger((1...8).map {
            try line(key: "k\($0)", session: "s\($0)", input: 1, output: 1, cost: 0, second: $0)
        })
        var importer = DaemonUsageLedgerImporter()

        let recent = importer.importNewRecords(from: ledgerURL).recentRecords

        XCTAssertEqual(recent.map(\.idempotencyKey), ["k8", "k7", "k6", "k5", "k4", "k3"])
    }

    func testFusionParentFallsBackToTheIdempotencyKeySignature() throws {
        try appendLedger([line(key: "elderwand-run-1|panel|glm-5|0", session: "fusion", input: 5, output: 5, cost: 0.01, second: 1)])
        var importer = DaemonUsageLedgerImporter()

        let row = try XCTUnwrap(importer.importNewRecords(from: ledgerURL).changedRows.first)

        XCTAssertEqual(row.parentRequestID, "elderwand-run-1")
        XCTAssertNil(DaemonUsageLedgerImporter.fusionParentRequestID(fromIdempotencyKey: "gateway:abc|panel"))
    }

    // MARK: - Fixtures

    /// Everything the upsert writes except `createdAt` (stamped per pass).
    private func summary(_ usage: TokenUsage) -> String {
        [
            usage.id.uuidString, usage.sessionId, usage.model,
            "\(usage.inputTokens)", "\(usage.outputTokens)", "\(usage.cost)",
            "\(usage.startTime.timeIntervalSince1970)", "\(usage.endTime.timeIntervalSince1970)",
            usage.pricingSource.rawValue, usage.tokenConfidence.rawValue
        ].joined(separator: "|")
    }

    private func date(second: Int) -> Date {
        Date(timeIntervalSince1970: 1_760_000_000 + TimeInterval(second))
    }

    private func line(
        key: String,
        session: String?,
        input: Int,
        output: Int,
        cost: Double,
        second: Int,
        confidence: String = "exact",
        model: String = "glm-5"
    ) throws -> String {
        var event: [String: Any] = [
            "providerID": "zai",
            "modelID": model,
            "inputTokens": input,
            "outputTokens": output,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "reasoningTokens": 0,
            "cost": cost,
            "recordedAt": date(second: second).timeIntervalSinceReferenceDate,
            "confidence": confidence
        ]
        if let session { event["sessionID"] = session }
        let data = try JSONSerialization.data(withJSONObject: ["idempotencyKey": key, "event": event], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func appendLedger(_ lines: [String]) throws {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let handle = try FileHandle(forWritingTo: ledgerURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: ledgerURL)
        }
    }
}
