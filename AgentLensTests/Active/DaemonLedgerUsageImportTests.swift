import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Daemon spend reaches `token_usage` from the ledger file alone, summed per
/// row and keyed on each event's idempotency key. These run the real sync
/// service against the real store: the store is where the old paths collapsed
/// same-session requests (upsert replaced the counts) and double counted (the
/// RPC and file paths keyed one event two ways).
@MainActor
final class DaemonLedgerUsageImportTests: XCTestCase {
    private var rootURL: URL!
    private var paths: OpenBurnBarDaemonRuntimePaths!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonLedgerUsageImportTests-\(UUID().uuidString)", isDirectory: true)
        let daemonDirectory = rootURL.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
        paths = OpenBurnBarDaemonRuntimePaths(
            supportDirectory: rootURL,
            daemonDirectory: daemonDirectory,
            frameworksDirectory: rootURL.appendingPathComponent("Frameworks", isDirectory: true),
            installedBinaryURL: daemonDirectory.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
            socketURL: rootURL.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false),
            logURL: daemonDirectory.appendingPathComponent("openburnbar-daemon.log", isDirectory: false),
            launchAgentPlistURL: rootURL.appendingPathComponent("com.openburnbar.daemon.plist", isDirectory: false)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func test_requestsSharingASessionAreStoredAsTheirSum() async throws {
        try writeLedger([
            record("k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            record("k2", session: "chat-1", input: 300, output: 30, cost: 0.30, second: 2)
        ])
        let store = try makeStore()

        try await importLedger(OpenBurnBarDaemonUsageSyncService(paths: paths), into: store)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inputTokens, 400)
        XCTAssertEqual(rows.first?.outputTokens, 40)
        XCTAssertEqual(rows.first?.cost ?? 0, 0.40, accuracy: 1e-9)
    }

    func test_reimportAfterRestartStoresTheSameTotalsNotDoubled() async throws {
        try writeLedger([
            record("k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            record("k2", session: "chat-2", input: 50, output: 5, cost: 0.05, second: 2)
        ])
        let store = try makeStore()
        try await importLedger(OpenBurnBarDaemonUsageSyncService(paths: paths), into: store)

        // A new service is an app relaunch: it rebuilds from byte 0.
        try await importLedger(OpenBurnBarDaemonUsageSyncService(paths: paths), into: store)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.inputTokens).reduce(0, +), 150)
        XCTAssertEqual(rows.map(\.cost).reduce(0, +), 0.15, accuracy: 1e-9)
    }

    /// What the retired RPC import left behind: the session row holding only
    /// its newest event, and an id-less event under `<provider>-<epoch>`.
    /// Importing the ledger must end at the ledger's totals, counted once.
    func test_rowsFromTheRetiredRPCImportAreReplacedNotAddedTo() async throws {
        try writeLedger([
            record("k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            record("k2", session: "chat-1", input: 300, output: 30, cost: 0.30, second: 2),
            record("gateway:abc", session: nil, input: 12, output: 4, cost: 0.02, second: 5)
        ])
        let store = try makeStore()
        try await store.insert([
            daemonRow(session: "chat-1", input: 300, output: 30, cost: 0.30, second: 2),
            daemonRow(
                session: "\(AgentProvider.zai.rawValue.lowercased())-\(date(second: 5).timeIntervalSince1970)",
                input: 12, output: 4, cost: 0.02, second: 5
            )
        ])

        try await importLedger(OpenBurnBarDaemonUsageSyncService(paths: paths), into: store)

        let rows = try await store.fetchAllUsage()
        XCTAssertEqual(Set(rows.map(\.sessionId)), ["chat-1", "gateway:abc"])
        XCTAssertEqual(rows.map(\.inputTokens).reduce(0, +), 412)
        XCTAssertEqual(rows.map(\.cost).reduce(0, +), 0.42, accuracy: 1e-9)
    }

    /// A partial daemon row stamped `exact` must still take the full sum when
    /// one of the session's later events is an estimate — the ladder would
    /// otherwise keep the smaller, stale total. Another source's more
    /// confident row for the same identity still wins.
    func test_daemonSumReplacesAStaleMoreConfidentDaemonRowOnly() async throws {
        try writeLedger([
            record("k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            record("k2", session: "chat-1", input: 20, output: 2, cost: 0.02, second: 2, confidence: "low_confidence_estimate"),
            record("k3", session: "chat-2", input: 7, output: 1, cost: 0.01, second: 3, confidence: "low_confidence_estimate")
        ])
        let store = try makeStore()
        try await store.insert([
            daemonRow(session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1),
            daemonRow(session: "chat-2", input: 999, output: 99, cost: 9.99, second: 3, usageSource: .providerLog)
        ])

        try await importLedger(OpenBurnBarDaemonUsageSyncService(paths: paths), into: store)

        let rows = try await store.fetchAllUsage()
        let daemonSession = try XCTUnwrap(rows.first { $0.sessionId == "chat-1" })
        XCTAssertEqual(daemonSession.inputTokens, 120)
        XCTAssertEqual(daemonSession.tokenConfidence, .lowConfidenceEstimate)
        let otherSource = try XCTUnwrap(rows.first { $0.sessionId == "chat-2" })
        XCTAssertEqual(otherSource.inputTokens, 999)
        XCTAssertEqual(otherSource.usageSource, .providerLog)
    }

    func test_aFailedWriteIsRebuiltOnTheNextPass() throws {
        try writeLedger([record("k1", session: "chat-1", input: 100, output: 10, cost: 0.10, second: 1)])
        let service = OpenBurnBarDaemonUsageSyncService(paths: paths)
        struct WriteFailed: Error {}

        _ = service.refreshState(insertUsages: { _ in throw WriteFailed() })
        var written: [TokenUsage] = []
        _ = service.refreshState(insertUsages: { written.append(contentsOf: $0) })

        XCTAssertEqual(written.map(\.inputTokens), [100])
    }

    // MARK: - Fixtures

    private func makeStore() throws -> DataStore {
        try DataStore(databaseQueue: DatabaseQueue(path: ":memory:"), runMigrations: true, refreshOnInit: false)
    }

    private func importLedger(_ service: OpenBurnBarDaemonUsageSyncService, into store: DataStore) async throws {
        let snapshot = service.refreshState()
        try await store.replaceDaemonLedgerUsage(snapshot.importedUsages, superseding: snapshot.supersededUsages)
    }

    private func date(second: Int) -> Date {
        Date(timeIntervalSince1970: 1_760_000_000 + TimeInterval(second))
    }

    private func daemonRow(
        session: String,
        input: Int,
        output: Int,
        cost: Double,
        second: Int,
        usageSource: UsageSource = .daemon
    ) -> TokenUsage {
        TokenUsage(
            provider: .zai,
            sessionId: session,
            projectName: "OpenBurnBar Daemon",
            model: "glm-5",
            inputTokens: input,
            outputTokens: output,
            costUSD: cost,
            startTime: date(second: second),
            endTime: date(second: second),
            usageSource: usageSource,
            provenanceMethod: .daemonBridge,
            provenanceConfidence: .exact
        )
    }

    private func record(
        _ key: String,
        session: String?,
        input: Int,
        output: Int,
        cost: Double,
        second: Int,
        confidence: String = "exact"
    ) -> String {
        var event: [String: Any] = [
            "providerID": "zai",
            "modelID": "glm-5",
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
        let data = try! JSONSerialization.data(withJSONObject: ["idempotencyKey": key, "event": event], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func writeLedger(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: paths.usageLedgerURL)
    }
}
