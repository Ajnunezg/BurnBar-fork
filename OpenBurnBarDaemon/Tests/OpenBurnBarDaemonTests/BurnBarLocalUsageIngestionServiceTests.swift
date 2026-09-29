import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
@testable import OpenBurnBarDaemon
import OpenBurnBarEngine

final class BurnBarLocalUsageIngestionServiceTests: XCTestCase {
    func testLinuxDefaultConfiguresEveryCoreParserAndXDGExtensionRoot() {
        let home = URL(fileURLWithPath: "/home/test-user", isDirectory: true)
        let parsers = BurnBarLocalUsageIngestionService.linuxDefaultParsers(
            environment: ["XDG_CONFIG_HOME": "/srv/test-config"],
            homeDirectoryURL: home
        )

        XCTAssertEqual(parsers.count, 32)
        XCTAssertEqual(Set(parsers.map(\.provider)), [
            .factory, .claudeCode, .copilot, .cursorAgent, .codex, .windsurf,
            .warp, .kimi, .xAI, .cline, .kiloCode, .rooCode, .forgeDev,
            .augment, .hermes, .geminiCLI, .antigravity, .goose, .aider,
            .cursor, .openCode, .piAgent, .openClaw, .ollama, .junie, .zai,
            .minimax, .omp, .openClaude, .primeAgent, .muse, .fx
        ])

        let paths = BurnBarLocalUsageIngestionService.linuxClineStoragePaths(
            environment: ["XDG_CONFIG_HOME": "/srv/test-config"],
            homeDirectoryURL: home
        )
        XCTAssertEqual(paths[.cline]?.count, 4)
        XCTAssertEqual(paths[.kiloCode]?.count, 4)
        XCTAssertEqual(paths[.rooCode]?.count, 8)
        XCTAssertTrue(paths.values.flatMap { $0 }.allSatisfy { $0.hasPrefix("/srv/test-config/") })

        let fallbackPaths = BurnBarLocalUsageIngestionService.linuxClineStoragePaths(
            environment: ["XDG_CONFIG_HOME": "relative-path-is-invalid"],
            homeDirectoryURL: home
        )
        XCTAssertTrue(fallbackPaths.values.flatMap { $0 }.allSatisfy { $0.hasPrefix("/home/test-user/.config/") })
    }

    func testLinuxDefaultParserMembershipAndOrderFollowGeneratedIngestionCatalog() {
        let parsers = BurnBarLocalUsageIngestionService.linuxDefaultParsers(
            environment: [:],
            homeDirectoryURL: URL(fileURLWithPath: "/home/test-user", isDirectory: true)
        )
        let expected = AgentProviderIngestionCatalog.entries
            .filter { $0.ingestion == .localParser }
            .map(\.provider)

        XCTAssertEqual(parsers.map(\.provider), expected)
        XCTAssertEqual(
            Set(parsers.map(\.provider)),
            AgentProviderIngestionCatalog.localParserProviders
        )
    }

    func testRefreshPersistsOnlyCumulativeDeltasAcrossRestartAndModelTransition() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let first = fixture.usage(model: "model-a", input: 10, output: 5, cost: 0.15, start: 100, end: 200)
        let firstService = fixture.service(usages: [first])

        let initial = await firstService.refresh()
        let unchanged = await firstService.refresh()

        XCTAssertEqual(initial.insertedDeltas, 1)
        XCTAssertEqual(unchanged.unchangedRows, 1)
        XCTAssertTrue(initial.failures.isEmpty)

        let grown = fixture.usage(model: "model-b", input: 17, output: 8, cost: 0.25, start: 100, end: 300)
        let restarted = fixture.service(usages: [grown])
        let growth = await restarted.refresh()

        XCTAssertEqual(growth.insertedDeltas, 1)
        XCTAssertTrue(growth.failures.isEmpty, growth.failures.joined(separator: "\n"))
        let records = try await fixture.recorder.records()
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        XCTAssertEqual(records[1].event.modelID, "model-b")
        XCTAssertEqual(records[1].event.inputTokens, 7)
        XCTAssertEqual(records[1].event.outputTokens, 3)
        XCTAssertEqual(records[1].event.cost, 0.10, accuracy: 0.000_000_001)
        let projection = try await fixture.recorder.projection()
        XCTAssertEqual(projection.totals.inputTokens, 17)
        XCTAssertEqual(projection.totals.outputTokens, 8)

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.checkpointURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
    }

    func testTransientRegressionRetainsHighWaterButNewGenerationImportsFromZero() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        _ = await fixture.service(usages: [
            fixture.usage(model: "model", input: 100, output: 20, cost: 1.2, start: 100, end: 200)
        ]).refresh()

        let truncated = await fixture.service(usages: [
            fixture.usage(model: "model", input: 10, output: 2, cost: 0.12, start: 100, end: 250)
        ]).refresh()
        XCTAssertEqual(truncated.unchangedRows, 1)
        let truncatedRecords = try await fixture.recorder.records()
        XCTAssertEqual(truncatedRecords.count, 1)

        let recovered = await fixture.service(usages: [
            fixture.usage(model: "model", input: 120, output: 25, cost: 1.45, start: 100, end: 300)
        ]).refresh()
        XCTAssertEqual(recovered.insertedDeltas, 1)
        let recoveredRecords = try await fixture.recorder.records()
        XCTAssertEqual(recoveredRecords.count, 2)
        guard recoveredRecords.count == 2 else { return }
        XCTAssertEqual(recoveredRecords[1].event.inputTokens, 20)
        XCTAssertEqual(recoveredRecords[1].event.outputTokens, 5)

        let reset = await fixture.service(usages: [
            fixture.usage(model: "model", input: 7, output: 3, cost: 0.1, start: 400, end: 500)
        ]).refresh()
        XCTAssertEqual(reset.insertedDeltas, 1)
        let resetRecords = try await fixture.recorder.records()
        XCTAssertEqual(resetRecords.count, 3)
        guard resetRecords.count == 3 else { return }
        XCTAssertEqual(resetRecords[2].event.inputTokens, 7)
        XCTAssertEqual(resetRecords[2].event.outputTokens, 3)
    }

    func testPerModelSessionRowsRecordPerModelDeltasWithoutDoubleCounting() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let firstPass = [
            fixture.usage(provider: .claudeCode, model: "claude-opus-4-8", input: 100, output: 10, cost: 0.75, start: 100, end: 200),
            fixture.usage(provider: .claudeCode, model: "claude-haiku-4-5", input: 50, output: 5, cost: 0.075, start: 150, end: 250)
        ]

        let initial = await fixture.service(provider: .claudeCode, usages: firstPass).refresh()
        let unchanged = await fixture.service(provider: .claudeCode, usages: firstPass).refresh()

        XCTAssertEqual(initial.insertedDeltas, 2)
        XCTAssertTrue(initial.failures.isEmpty, initial.failures.joined(separator: "\n"))
        XCTAssertEqual(unchanged.insertedDeltas, 0)
        XCTAssertEqual(unchanged.unchangedRows, 2)
        let initialRecords = try await fixture.recorder.records()
        XCTAssertEqual(initialRecords.map(\.event.modelID).sorted(), ["claude-haiku-4-5", "claude-opus-4-8"])

        // Only the Opus row grew: one Opus delta, nothing for Haiku.
        let grown = await fixture.service(provider: .claudeCode, usages: [
            fixture.usage(provider: .claudeCode, model: "claude-opus-4-8", input: 130, output: 14, cost: 0.95, start: 100, end: 300),
            fixture.usage(provider: .claudeCode, model: "claude-haiku-4-5", input: 50, output: 5, cost: 0.075, start: 150, end: 250)
        ]).refresh()

        XCTAssertEqual(grown.insertedDeltas, 1)
        let records = try await fixture.recorder.records()
        XCTAssertEqual(records.count, 3)
        guard records.count == 3 else { return }
        XCTAssertEqual(records[2].event.modelID, "claude-opus-4-8")
        XCTAssertEqual(records[2].event.inputTokens, 30)
        XCTAssertEqual(records[2].event.outputTokens, 4)
        XCTAssertEqual(records[2].event.cost, 0.2, accuracy: 0.000_000_001)
        let projection = try await fixture.recorder.projection()
        XCTAssertEqual(projection.totals.inputTokens, 180)
        XCTAssertEqual(projection.totals.outputTokens, 19)
    }

    func testLegacySessionCheckpointUpgradesToPerModelRowsWithoutReimport() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        // Before per-model rows the parser folded both models into one row
        // priced at `models.min()`; the v1 checkpoint holds that session total.
        let legacyRow = fixture.usage(provider: .claudeCode, model: "claude-haiku-4-5", input: 150, output: 15, cost: 0.225, start: 100, end: 250)
        _ = await fixture.service(provider: .claudeCode, usages: [legacyRow]).refresh()
        let v2 = try Data(contentsOf: fixture.checkpointURL)
        let legacySessions = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: v2) as? [String: Any])?["sessions"] as? [String: Any]
        )
        var legacyRows: [String: Any] = [:]
        for (key, value) in legacySessions {
            legacyRows[key] = (value as? [String: Any])?["total"]
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "rows": legacyRows])
            .write(to: fixture.checkpointURL)

        let perModel = [
            fixture.usage(provider: .claudeCode, model: "claude-opus-4-8", input: 100, output: 10, cost: 0.75, start: 100, end: 200),
            fixture.usage(provider: .claudeCode, model: "claude-haiku-4-5", input: 50, output: 5, cost: 0.075, start: 150, end: 250)
        ]
        let upgraded = await fixture.service(provider: .claudeCode, usages: perModel).refresh()

        // Same tokens: no token re-import. The repriced session records only
        // the cost the min()-priced row under-billed.
        XCTAssertTrue(upgraded.failures.isEmpty, upgraded.failures.joined(separator: "\n"))
        let afterUpgrade = try await fixture.recorder.projection()
        XCTAssertEqual(afterUpgrade.totals.inputTokens, 150)
        XCTAssertEqual(afterUpgrade.totals.outputTokens, 15)
        XCTAssertEqual(afterUpgrade.totals.cost, 0.825, accuracy: 0.000_000_001)

        let grown = await fixture.service(provider: .claudeCode, usages: [
            fixture.usage(provider: .claudeCode, model: "claude-opus-4-8", input: 100, output: 10, cost: 0.75, start: 100, end: 200),
            fixture.usage(provider: .claudeCode, model: "claude-haiku-4-5", input: 70, output: 7, cost: 0.105, start: 150, end: 400)
        ]).refresh()

        XCTAssertEqual(grown.insertedDeltas, 1)
        let records = try await fixture.recorder.records()
        let last = try XCTUnwrap(records.last)
        XCTAssertEqual(last.event.modelID, "claude-haiku-4-5")
        XCTAssertEqual(last.event.inputTokens, 20)
        XCTAssertEqual(last.event.outputTokens, 2)
        let projection = try await fixture.recorder.projection()
        XCTAssertEqual(projection.totals.inputTokens, 170)
        XCTAssertEqual(projection.totals.outputTokens, 17)
    }

    func testUnchangedLegacySessionAdoptsPerModelBreakdownForTheNextDelta() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "rows": [
                fixture.legacyCheckpointKey(provider: .claudeCode): [
                    "inputTokens": 150, "outputTokens": 15, "cacheCreationTokens": 0,
                    "cacheReadTokens": 0, "reasoningTokens": 0, "cost": 1.0,
                    "startTime": 100.0, "endTime": 250.0
                ]
            ]
        ]).write(to: fixture.checkpointURL)

        // The min()-priced row over-billed this session: same tokens, lower
        // cost. Nothing to record, but the per-model breakdown is adopted.
        let adopted = await fixture.service(provider: .claudeCode, usages: [
            fixture.usage(provider: .claudeCode, model: "claude-opus-4-8", input: 100, output: 10, cost: 0.75, start: 100, end: 200),
            fixture.usage(provider: .claudeCode, model: "claude-sonnet-4-5", input: 50, output: 5, cost: 0.2, start: 150, end: 250)
        ]).refresh()
        XCTAssertEqual(adopted.insertedDeltas, 0)
        XCTAssertTrue(adopted.failures.isEmpty, adopted.failures.joined(separator: "\n"))

        // Opus grew while Sonnet was active more recently: the gain is still Opus's.
        let grown = await fixture.service(provider: .claudeCode, usages: [
            fixture.usage(provider: .claudeCode, model: "claude-opus-4-8", input: 120, output: 12, cost: 0.9, start: 100, end: 220),
            fixture.usage(provider: .claudeCode, model: "claude-sonnet-4-5", input: 50, output: 5, cost: 0.2, start: 150, end: 250)
        ]).refresh()

        XCTAssertEqual(grown.insertedDeltas, 1)
        let records = try await fixture.recorder.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.event.modelID, "claude-opus-4-8")
        XCTAssertEqual(records.first?.event.inputTokens, 20)
        XCTAssertEqual(records.first?.event.outputTokens, 2)
    }

    func testCorruptCheckpointFailsClosedBeforeParserOrLedgerMutation() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.checkpointURL)

        let report = await fixture.service(usages: [
            fixture.usage(model: "model", input: 10, output: 2, cost: 0.1, start: 100, end: 200)
        ]).refresh()

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].hasPrefix("checkpoint:"))
        let records = try await fixture.recorder.records()
        XCTAssertTrue(records.isEmpty)
    }
}

private struct FixedUsageParser: LogParser {
    var provider: AgentProvider = .copilot
    let usages: [TokenUsage]

    func parse(options: LogParseOptions) async throws -> ParseResult {
        ParseResult(usages: usages, conversations: [])
    }
}

private final class IngestionFixture {
    private static let epochBase: TimeInterval = 1_700_000_000
    let root: URL
    let checkpointURL: URL
    let recorder: BurnBarUsageRecorder

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-usage-ingestion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        checkpointURL = root.appendingPathComponent("checkpoint.json")
        recorder = BurnBarUsageRecorder(
            fileURL: root.appendingPathComponent("ledger.jsonl"),
            projectionFileURL: root.appendingPathComponent("projection.json")
        )
    }

    func service(
        provider: AgentProvider = .copilot,
        usages: [TokenUsage]
    ) -> BurnBarLocalUsageIngestionService {
        BurnBarLocalUsageIngestionService(
            parsers: [FixedUsageParser(provider: provider, usages: usages)],
            usageRecorder: recorder,
            checkpointURL: checkpointURL
        )
    }

    func usage(
        provider: AgentProvider = .copilot,
        model: String,
        input: Int,
        output: Int,
        cost: Double,
        start: TimeInterval,
        end: TimeInterval
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: "session-1",
            projectName: "Copilot",
            model: model,
            inputTokens: input,
            outputTokens: output,
            costUSD: cost,
            startTime: Date(timeIntervalSince1970: Self.epochBase + start),
            endTime: Date(timeIntervalSince1970: Self.epochBase + end),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
    }

    /// The v1 checkpoint key: SHA-256 of `providerID \u{1f} sessionId`.
    func legacyCheckpointKey(provider: AgentProvider, sessionID: String = "session-1") -> String {
        SHA256.hash(data: Data("\(provider.providerID.rawValue)\u{1f}\(sessionID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
