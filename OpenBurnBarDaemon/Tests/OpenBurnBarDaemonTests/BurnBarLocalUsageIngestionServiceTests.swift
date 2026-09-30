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

    // MARK: - Resource governance

    func testEveryParserInAPassSharesOneFreshUsageRefreshGovernor() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let observed = Locked<[ObservedParse]>([])
        let service = BurnBarLocalUsageIngestionService(
            parsers: [
                OptionsProbeParser(provider: .copilot, probesBudget: true, observed: observed),
                OptionsProbeParser(provider: .codex, probesBudget: false, observed: observed)
            ],
            usageRecorder: fixture.recorder,
            checkpointURL: fixture.checkpointURL
        )

        _ = await service.refresh()
        _ = await service.refresh()

        let parses = observed.withLock { $0 }
        XCTAssertEqual(parses.count, 4)
        guard parses.count == 4 else { return }
        XCTAssertNotNil(parses[0].governor, "daemon ingestion must never parse ungoverned")
        XCTAssertIdentical(parses[0].governor, parses[1].governor, "one governor bounds the whole pass")
        XCTAssertIdentical(parses[2].governor, parses[3].governor)
        XCTAssertNotIdentical(parses[0].governor, parses[2].governor, "every pass gets a fresh budget")
        XCTAssertTrue(parses.allSatisfy(\.isUsageAccounting))
        // Admission is soft at the boundary: budget-1 then 1 byte fit exactly,
        // the next byte is deferred. Pins the Mac app's refresh budget.
        XCTAssertEqual(parses[0].budgetProbe, [true, true, false])
        XCTAssertEqual(parses[2].budgetProbe, [true, true, false])
    }

    func testByteBudgetDefersTranscriptsToLaterPassesWithoutLosingUsage() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let transcripts = try ClaudeTranscriptFixture(root: fixture.root)
        let first = try transcripts.writeSession("session-a", contents: ClaudeTranscriptFixture.line(
            id: "a", input: 100, output: 20, timestamp: "2026-09-01T10:00:00.000Z"
        ) + "\n")
        let second = try transcripts.writeSession("session-b", contents: ClaudeTranscriptFixture.line(
            id: "b", input: 300, output: 40, timestamp: "2026-09-01T11:00:00.000Z"
        ) + "\n")
        // The first admitted transcript exhausts the budget; the second waits.
        let budget = min(try Self.fileSize(first), try Self.fileSize(second))
        let service = BurnBarLocalUsageIngestionService(
            parsers: [transcripts.parser()],
            usageRecorder: fixture.recorder,
            checkpointURL: fixture.checkpointURL,
            resourceLimits: ParserResourceLimits(fileByteBudget: budget)
        )

        let firstPass = await service.refresh()
        XCTAssertTrue(firstPass.failures.isEmpty, firstPass.failures.joined(separator: "\n"))
        XCTAssertEqual(firstPass.insertedDeltas, 1)
        XCTAssertEqual(firstPass.deferredFiles, 1)

        let secondPass = await service.refresh()
        XCTAssertTrue(secondPass.failures.isEmpty, secondPass.failures.joined(separator: "\n"))
        XCTAssertEqual(secondPass.insertedDeltas, 1)
        XCTAssertEqual(secondPass.unchangedRows, 1)
        XCTAssertEqual(secondPass.deferredFiles, 0)

        let projection = try await fixture.recorder.projection()
        XCTAssertEqual(projection.totals.inputTokens, 400)
        XCTAssertEqual(projection.totals.outputTokens, 60)
    }

    // MARK: - Checkpoint persistence

    func testColdImportWritesTheCheckpointDocumentOncePerPassNotOncePerRow() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let rowCount = 1_000
        let usages = (0..<rowCount).map { index in
            fixture.usage(session: "session-\(index)", model: "model", input: index + 1, output: 1, cost: 0.5, start: 100, end: 200)
        }
        let countingFileManager = DocumentWriteCountingFileManager(documentPath: fixture.checkpointURL.path)
        let service = BurnBarLocalUsageIngestionService(
            parsers: [FixedUsageParser(usages: usages)],
            usageRecorder: fixture.recorder,
            checkpointURL: fixture.checkpointURL,
            fileManager: countingFileManager
        )

        let report = await service.refresh()

        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
        XCTAssertEqual(report.insertedDeltas, rowCount)
        // One rewrite per pass. Rewriting the whole document per row made
        // this import write ~rowCount²/2 checkpoint entries.
        XCTAssertEqual(countingFileManager.documentWrites, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.checkpointJournalURL.path))

        let restarted = await fixture.service(usages: usages).refresh()
        XCTAssertEqual(restarted.insertedDeltas, 0)
        XCTAssertEqual(restarted.unchangedRows, rowCount)
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.checkpointURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
    }

    func testTornJournalTailIsSkippedWhileCompleteAdvancesReplayWithoutDoubleCounting() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let first = fixture.usage(session: "session-1", model: "model", input: 10, output: 5, cost: 0.25, start: 100, end: 200)
        let second = fixture.usage(session: "session-2", model: "model", input: 40, output: 8, cost: 0.5, start: 100, end: 200)

        // A pass that journaled both advances and died before folding them…
        let crashed = await fixture.service(usages: [first, second]).refresh(compactingCheckpointJournal: false)
        XCTAssertEqual(crashed.insertedDeltas, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        // …after a third append was torn mid-write.
        let journal = try FileHandle(forWritingTo: fixture.checkpointJournalURL)
        try journal.seekToEnd()
        try journal.write(contentsOf: Data(#"{"key":"torn","checkpoint":{"inputTok"#.utf8))
        try journal.close()

        let grown = fixture.usage(session: "session-1", model: "model", input: 16, output: 7, cost: 0.375, start: 100, end: 300)
        let recovered = await fixture.service(usages: [grown, second]).refresh()

        XCTAssertTrue(recovered.failures.isEmpty, recovered.failures.joined(separator: "\n"))
        XCTAssertEqual(recovered.insertedDeltas, 1)
        XCTAssertEqual(recovered.unchangedRows, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.checkpointJournalURL.path))
        let records = try await fixture.recorder.records()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.last?.event.inputTokens, 6, "only the growth past the replayed high-water mark")
        XCTAssertEqual(records.last?.event.outputTokens, 2)
        let projection = try await fixture.recorder.projection()
        XCTAssertEqual(projection.totals.inputTokens, 56)
        XCTAssertEqual(projection.totals.outputTokens, 15)
    }

    func testReplayedJournalKeepsThePerModelBreakdownForTheNextDelta() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let opus = fixture.usage(provider: .claudeCode, model: "claude-opus-4-8", input: 100, output: 10, cost: 0.75, start: 100, end: 400)
        let haiku = fixture.usage(provider: .claudeCode, model: "claude-haiku-4-5", input: 50, output: 5, cost: 0.075, start: 150, end: 250)

        // A pass that journaled the per-model session and died before folding it.
        let crashed = await fixture.service(provider: .claudeCode, usages: [opus, haiku])
            .refresh(compactingCheckpointJournal: false)
        XCTAssertEqual(crashed.insertedDeltas, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        // Only Haiku grew. With the replayed breakdown the gain lands on Haiku;
        // a journal that dropped it would book it on Opus, the latest row.
        let grownHaiku = fixture.usage(provider: .claudeCode, model: "claude-haiku-4-5", input: 70, output: 6, cost: 0.105, start: 150, end: 260)
        let recovered = await fixture.service(provider: .claudeCode, usages: [opus, grownHaiku]).refresh()

        XCTAssertTrue(recovered.failures.isEmpty, recovered.failures.joined(separator: "\n"))
        XCTAssertEqual(recovered.insertedDeltas, 1)
        let records = try await fixture.recorder.records()
        XCTAssertEqual(records.count, 3)
        guard records.count == 3 else { return }
        XCTAssertEqual(records[2].event.modelID, "claude-haiku-4-5")
        XCTAssertEqual(records[2].event.inputTokens, 20)
        XCTAssertEqual(records[2].event.outputTokens, 1)
    }

    func testCorruptCompleteJournalLineFailsClosedBeforeParserOrLedgerMutation() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        try Data("not-json\n".utf8).write(to: fixture.checkpointJournalURL)

        let report = await fixture.service(usages: [
            fixture.usage(model: "model", input: 10, output: 2, cost: 0.1, start: 100, end: 200)
        ]).refresh()

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].hasPrefix("checkpoint:"))
        let records = try await fixture.recorder.records()
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - Unterminated trailing transcript line

    /// Pass one sees a record a live writer is still appending. The parser's
    /// persisted offset must stop before that line so pass two re-reads it
    /// whole: the ledger then totals every line exactly once.
    func testTornTrailingTranscriptLineIsCountedOnceItCompletes() async throws {
        let lineB = ClaudeTranscriptFixture.line(id: "b", input: 300, output: 40, timestamp: "2026-09-01T10:05:00.000Z")
        let splitIndex = lineB.index(lineB.startIndex, offsetBy: lineB.count / 2)
        try await assertTrailingLineCountedOnce(
            pendingTail: String(lineB[..<splitIndex]),
            completion: String(lineB[splitIndex...]),
            firstPassInputTokens: 100
        )
    }

    /// Same contract when the pending record is complete JSON still waiting
    /// for its newline: it counts toward pass one's totals, never toward the
    /// persisted offset, so pass two adds only the newer line.
    func testUnterminatedCompleteTranscriptRecordIsCountedOnceAcrossPasses() async throws {
        try await assertTrailingLineCountedOnce(
            pendingTail: ClaudeTranscriptFixture.line(id: "b", input: 300, output: 40, timestamp: "2026-09-01T10:05:00.000Z"),
            completion: "",
            firstPassInputTokens: 400
        )
    }

    private func assertTrailingLineCountedOnce(
        pendingTail: String,
        completion: String,
        firstPassInputTokens: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let transcripts = try ClaudeTranscriptFixture(root: fixture.root)
        let lineA = ClaudeTranscriptFixture.line(id: "a", input: 100, output: 20, timestamp: "2026-09-01T10:00:00.000Z")
        let lineC = ClaudeTranscriptFixture.line(id: "c", input: 7, output: 3, timestamp: "2026-09-01T10:10:00.000Z")
        // Past the parser's 8 MiB incremental-scan threshold, so pass two
        // resumes from the persisted byte offset instead of re-reading.
        let session = try transcripts.writeSession(
            "session-live",
            contents: ClaudeTranscriptFixture.filler(minimumBytes: 9 * 1024 * 1024) + lineA + "\n" + pendingTail
        )
        let service = BurnBarLocalUsageIngestionService(
            parsers: [transcripts.parser()],
            usageRecorder: fixture.recorder,
            checkpointURL: fixture.checkpointURL
        )

        let firstPass = await service.refresh()
        XCTAssertTrue(firstPass.failures.isEmpty, firstPass.failures.joined(separator: "\n"), file: file, line: line)
        var records = try await fixture.recorder.records()
        XCTAssertEqual(records.map(\.event.inputTokens), [firstPassInputTokens], file: file, line: line)

        let writer = try FileHandle(forWritingTo: session)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data((completion + "\n" + lineC + "\n").utf8))
        try writer.close()

        let secondPass = await service.refresh()
        XCTAssertTrue(secondPass.failures.isEmpty, secondPass.failures.joined(separator: "\n"), file: file, line: line)
        XCTAssertEqual(secondPass.insertedDeltas, 1, file: file, line: line)
        records = try await fixture.recorder.records()
        XCTAssertEqual(records.map(\.event.inputTokens), [firstPassInputTokens, 407 - firstPassInputTokens], file: file, line: line)
        let projection = try await fixture.recorder.projection()
        XCTAssertEqual(projection.totals.inputTokens, 407, file: file, line: line)
        XCTAssertEqual(projection.totals.outputTokens, 63, file: file, line: line)
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

private struct FixedUsageParser: LogParser {
    var provider: AgentProvider = .copilot
    let usages: [TokenUsage]

    func parse(options: LogParseOptions) async throws -> ParseResult {
        ParseResult(usages: usages, conversations: [])
    }
}

private struct ObservedParse: Sendable {
    /// Retained so a finished pass's governor cannot be freed and its address
    /// reused by the next pass's.
    let governor: ParserResourceGovernor?
    let isUsageAccounting: Bool
    let budgetProbe: [Bool]
}

/// Records the options each pass hands a parser and, when asked, probes the
/// governor's byte budget at its exact boundary.
private struct OptionsProbeParser: LogParser {
    let provider: AgentProvider
    let probesBudget: Bool
    let observed: Locked<[ObservedParse]>

    func parse(options: LogParseOptions) async throws -> ParseResult {
        let governor = options.resourceGovernor
        let budget = ParserResourceLimits.usageRefreshFileByteBudget
        let probe = probesBudget ? [
            governor?.admitFile(estimatedBytes: budget - 1) ?? true,
            governor?.admitFile(estimatedBytes: 1) ?? true,
            governor?.admitFile(estimatedBytes: 1) ?? true
        ] : []
        observed.withLock {
            $0.append(ObservedParse(
                governor: governor,
                isUsageAccounting: !options.includeConversationBodies
                    && options.minimumFileModificationDate == nil
                    && options.fileDiscoveryTracker == nil,
                budgetProbe: probe
            ))
        }
        return ParseResult(usages: [], conversations: [])
    }
}

/// Counts rewrites of the checkpoint document: each one ends by re-applying
/// its 0600 permissions.
private final class DocumentWriteCountingFileManager: FileManager, @unchecked Sendable {
    private let documentPath: String
    private let writes = Locked(0)

    init(documentPath: String) {
        self.documentPath = documentPath
        super.init()
    }

    var documentWrites: Int { writes.withLock { $0 } }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if path == documentPath {
            writes.withLock { $0 += 1 }
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

/// A Claude Code projects tree plus an isolated parser cache.
private struct ClaudeTranscriptFixture {
    let projectDirectory: URL
    let projectsDirectory: URL
    let appPaths: OpenBurnBarAppPaths

    init(root: URL) throws {
        projectsDirectory = root.appendingPathComponent("claude-projects", isDirectory: true)
        projectDirectory = projectsDirectory.appendingPathComponent("-home-test-project", isDirectory: true)
        appPaths = OpenBurnBarAppPaths(applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true))
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    }

    func parser() -> ClaudeCodeParser {
        ClaudeCodeParser(appPaths: appPaths, projectsDirectoryOverride: projectsDirectory)
    }

    func writeSession(_ sessionID: String, contents: String) throws -> URL {
        let url = projectDirectory.appendingPathComponent("\(sessionID).jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func line(id: String, input: Int, output: Int, timestamp: String) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req-\#(id)","message":{"id":"msg-\#(id)","role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    /// User turns with no usage key: skipped by the usage prefilter, but they
    /// push the transcript past the incremental-scan threshold.
    static func filler(minimumBytes: Int) -> String {
        let turn = #"{"type":"user","message":{"role":"user","content":""# + String(repeating: "x", count: 1_000) + "\"}}\n"
        return String(repeating: turn, count: minimumBytes / turn.utf8.count + 1)
    }
}

private final class IngestionFixture {
    private static let epochBase: TimeInterval = 1_700_000_000
    let root: URL
    let checkpointURL: URL
    let recorder: BurnBarUsageRecorder

    var checkpointJournalURL: URL { checkpointURL.appendingPathExtension("journal") }

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
        session: String = "session-1",
        model: String,
        input: Int,
        output: Int,
        cost: Double,
        start: TimeInterval,
        end: TimeInterval
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: session,
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
