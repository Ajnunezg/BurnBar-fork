import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel

/// A session that switches models is billed per model. Claude Code and the
/// Cline family used to fold every model's tokens into one row priced at
/// `models.min()`, so an Opus + Haiku session billed the Opus work at Haiku
/// rates.
final class ParserModelAttributionTests: XCTestCase {
    private static let opus = "claude-opus-4-8"
    private static let haiku = "claude-haiku-4-5"
    private static let thresholdBytes: Int64 = 8 * 1024 * 1024

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Claude Code

    func testClaudeMixedModelSessionYieldsOneRowPerModelAtItsOwnRate() async throws {
        let fixture = try ClaudeFixture(root: makeTemporaryDirectory(named: "claude-mixed"))
        try fixture.write([
            assistant(model: Self.opus, input: 1_000, output: 200, id: 1, second: 1),
            assistant(model: Self.opus, input: 1_000, output: 200, id: 2, second: 2),
            assistant(model: Self.haiku, input: 500, output: 100, id: 3, second: 3),
            assistant(model: Self.opus, input: 1_000, output: 200, id: 4, second: 4),
            assistant(model: Self.haiku, input: 500, output: 100, id: 5, second: 5)
        ])

        let usages = try await fixture.parser().parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(usages.map(\.model), [Self.haiku, Self.opus])
        XCTAssertEqual(Set(usages.map(\.sessionId)), [fixture.sessionID])
        let haikuRow = try XCTUnwrap(usages.first { $0.model == Self.haiku })
        let opusRow = try XCTUnwrap(usages.first { $0.model == Self.opus })
        XCTAssertEqual(haikuRow.inputTokens, 1_000)
        XCTAssertEqual(haikuRow.outputTokens, 200)
        XCTAssertEqual(opusRow.inputTokens, 3_000)
        XCTAssertEqual(opusRow.outputTokens, 600)

        let opusRate = try ModelPricing.lookup(model: Self.opus).cost(inputTokens: 3_000, outputTokens: 600)
        let haikuRateForOpusWork = try ModelPricing.lookup(model: Self.haiku)
            .cost(inputTokens: 3_000, outputTokens: 600)
        XCTAssertEqual(opusRow.costUSD, opusRate, accuracy: 1e-12)
        XCTAssertGreaterThan(
            opusRow.costUSD,
            haikuRateForOpusWork,
            "Opus work must not be billed at the Haiku rate"
        )
        XCTAssertEqual(
            haikuRow.costUSD,
            try ModelPricing.lookup(model: Self.haiku).cost(inputTokens: 1_000, outputTokens: 200),
            accuracy: 1e-12
        )

        // Each row's window is the time its model was active.
        XCTAssertEqual(opusRow.startTime, fixture.date(second: 1))
        XCTAssertEqual(opusRow.endTime, fixture.date(second: 4))
        XCTAssertEqual(haikuRow.startTime, fixture.date(second: 3))
        XCTAssertEqual(haikuRow.endTime, fixture.date(second: 5))
    }

    func testClaudeUsageWithoutAModelBelongsToTheModelThatServedIt() async throws {
        let fixture = try ClaudeFixture(root: makeTemporaryDirectory(named: "claude-carry"))
        try fixture.write([
            // Before any model is named: joins the first model that appears.
            assistant(model: nil, input: 7, output: 3, id: 1, second: 1),
            assistant(model: Self.opus, input: 100, output: 10, id: 2, second: 2),
            // A harness placeholder is not a model: the active model served it.
            assistant(model: "<synthetic>", input: 5, output: 5, id: 3, second: 3),
            assistant(model: Self.haiku, input: 40, output: 4, id: 4, second: 4),
            assistant(model: nil, input: 60, output: 6, id: 5, second: 5)
        ])

        let usages = try await fixture.parser().parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(usages.map(\.model), [Self.haiku, Self.opus])
        let opusRow = try XCTUnwrap(usages.first { $0.model == Self.opus })
        let haikuRow = try XCTUnwrap(usages.first { $0.model == Self.haiku })
        XCTAssertEqual(opusRow.inputTokens, 112)
        XCTAssertEqual(opusRow.outputTokens, 18)
        XCTAssertEqual(opusRow.startTime, fixture.date(second: 1))
        XCTAssertEqual(haikuRow.inputTokens, 100)
        XCTAssertEqual(haikuRow.outputTokens, 10)
    }

    func testClaudeSessionThatNeverNamesAModelKeepsTheLegacyRow() async throws {
        let fixture = try ClaudeFixture(root: makeTemporaryDirectory(named: "claude-unnamed"))
        try fixture.write([
            assistant(model: nil, input: 10, output: 20, id: 1, second: 1)
        ])

        let usages = try await fixture.parser().parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(usages.map(\.model), ["claude"])
        XCTAssertEqual(usages.first?.inputTokens, 10)
        XCTAssertEqual(usages.first?.outputTokens, 20)
    }

    func testClaudeZeroUsageModelDoesNotEmitAnEmptyRow() async throws {
        let fixture = try ClaudeFixture(root: makeTemporaryDirectory(named: "claude-zero"))
        try fixture.write([
            assistant(model: Self.opus, input: 0, output: 0, id: 1, second: 1),
            assistant(model: Self.haiku, input: 9, output: 1, id: 2, second: 2)
        ])

        let usages = try await fixture.parser().parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(usages.map(\.model), [Self.haiku])
    }

    func testClaudeCachedPassReturnsTheSamePerModelRows() async throws {
        let fixture = try ClaudeFixture(root: makeTemporaryDirectory(named: "claude-cached"))
        try fixture.write([
            assistant(model: Self.opus, input: 300, output: 30, id: 1, second: 1),
            assistant(model: Self.haiku, input: 200, output: 20, id: 2, second: 2)
        ])
        let parser = fixture.parser()

        let first = try await parser.parse(options: .init(includeConversationBodies: false)).usages
        let second = try await parser.parse(options: .init(includeConversationBodies: false)).usages
        let relaunched = try await fixture.parser().parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.map(\.model), first.map(\.model))
        XCTAssertEqual(second.map(\.inputTokens), first.map(\.inputTokens))
        XCTAssertEqual(second.map(\.costUSD), first.map(\.costUSD))
        XCTAssertEqual(relaunched.map(\.model), first.map(\.model))
        XCTAssertEqual(relaunched.map(\.inputTokens), first.map(\.inputTokens))
    }

    func testClaudeResumedLargeTranscriptKeepsPerModelTotalsAcrossAModelSwitch() async throws {
        let root = try makeTemporaryDirectory(named: "claude-resume-switch")
        let fixture = try ClaudeFixture(root: root)
        var lines: [String] = []
        lines.reserveCapacity(2_100)
        for turn in 1...2_000 {
            lines.append(userFiller(turn))
            lines.append(assistant(model: Self.opus, input: 10, output: 5, id: turn, second: 1))
        }
        try fixture.write(lines)
        XCTAssertGreaterThanOrEqual(try fileSize(of: fixture.transcript), Self.thresholdBytes)
        let parser = fixture.parser()

        let first = try await parser.parse(options: .init(includeConversationBodies: false)).usages
        XCTAssertEqual(first.map(\.model), [Self.opus])
        XCTAssertEqual(first.first?.inputTokens, 20_000)

        try fixture.append((1...5).map {
            assistant(model: Self.haiku, input: 100, output: 50, id: 10_000 + $0, second: 9)
        })
        let resumed = try await parser.parse(options: .init(includeConversationBodies: false)).usages
        let fresh = try await fixture.parser(supportName: "support-fresh")
            .parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(resumed.map(\.model), [Self.haiku, Self.opus])
        XCTAssertEqual(resumed.map(\.inputTokens), [500, 20_000])
        XCTAssertEqual(resumed.map(\.outputTokens), [250, 10_000])
        XCTAssertEqual(resumed.map(\.inputTokens), fresh.map(\.inputTokens))
        XCTAssertEqual(resumed.map(\.costUSD), fresh.map(\.costUSD))
    }

    // MARK: - Cline family

    func testClineMultiModelTaskSplitsRowsByTheModelThatServedEachMessage() async throws {
        let root = try makeTemporaryDirectory(named: "cline-mixed")
        let task = root.appendingPathComponent("task-mixed", isDirectory: true)
        try write(
            """
            [
              {"role":"user","content":"Plan it.","ts":1772323200000,"model":"\(Self.opus)"},
              {"role":"assistant","content":"Planned.","ts":1772323201000,"model":"\(Self.opus)","usage":{"input_tokens":1000,"output_tokens":200}},
              {"role":"user","content":"Now do the cheap part.","ts":1772323202000,"model":"\(Self.haiku)"},
              {"role":"assistant","content":"Done.","ts":1772323203000,"usage":{"input_tokens":500,"output_tokens":100}},
              {"role":"assistant","content":"More.","ts":1772323204000,"model":"\(Self.haiku)","usage":{"input_tokens":500,"output_tokens":100}}
            ]
            """,
            to: task.appendingPathComponent("api_conversation_history.json")
        )
        let parser = ClineFormatParser(provider: .cline, storagePaths: [root.path])

        let first = try await parser.parse(options: .init(includeConversationBodies: false)).usages
        let cached = try await parser.parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(first.map(\.model), [Self.haiku, Self.opus])
        XCTAssertEqual(first.map(\.inputTokens), [1_000, 1_000])
        XCTAssertEqual(first.map(\.outputTokens), [200, 200])
        let opusRow = try XCTUnwrap(first.first { $0.model == Self.opus })
        XCTAssertEqual(
            opusRow.costUSD,
            try ModelPricing.lookup(model: Self.opus).cost(inputTokens: 1_000, outputTokens: 200),
            accuracy: 1e-12
        )
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(cached.map(\.model), first.map(\.model))
        XCTAssertEqual(cached.map(\.costUSD), first.map(\.costUSD))
    }

    func testClineCharacterEstimateIsLabelledAsAnEstimate() async throws {
        let root = try makeTemporaryDirectory(named: "cline-estimate")
        let task = root.appendingPathComponent("task-estimate", isDirectory: true)
        try write(
            """
            [
              {"role":"user","content":"Explain the parser resume behaviour in detail.","ts":1772323200000,"model":"\(Self.haiku)"},
              {"role":"assistant","content":"It resumes from the last terminated line and keeps per-model totals.","ts":1772323201000}
            ]
            """,
            to: task.appendingPathComponent("api_conversation_history.json")
        )

        let usages = try await ClineFormatParser(provider: .cline, storagePaths: [root.path])
            .parse(options: .init(includeConversationBodies: false)).usages

        let usage = try XCTUnwrap(usages.first)
        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usage.model, Self.haiku)
        XCTAssertEqual(usage.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertFalse(usage.estimatorVersion.isEmpty)
    }

    // MARK: - Fixtures

    private struct ClaudeFixture {
        let root: URL
        let projectsRoot: URL
        let sessionID = "session-mixed"
        let transcript: URL
        private let epoch = Date(timeIntervalSince1970: 1_777_000_000)

        init(root: URL) throws {
            self.root = root
            projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
            transcript = projectsRoot
                .appendingPathComponent("-Users-test-Project", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            try FileManager.default.createDirectory(
                at: transcript.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        func date(second: Int) -> Date {
            epoch.addingTimeInterval(TimeInterval(second))
        }

        func parser(supportName: String = "support") -> ClaudeCodeParser {
            ClaudeCodeParser(
                fileManager: .default,
                appPaths: OpenBurnBarAppPaths(
                    applicationSupportRoot: root.appendingPathComponent(supportName, isDirectory: true)
                ),
                projectsDirectoryOverride: projectsRoot
            )
        }

        func write(_ lines: [String]) throws {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript, options: .atomic)
        }

        func append(_ lines: [String]) throws {
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }

    private func assistant(model: String?, input: Int, output: Int, id: Int, second: Int) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_777_000_000 + TimeInterval(second)))
        let modelField = model.map { #""model":""# + $0 + #"","# } ?? ""
        return #"{"type":"assistant","requestId":"req-\#(id)","timestamp":"\#(timestamp)","message":{"id":"msg-\#(id)","role":"assistant",\#(modelField)"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    private func userFiller(_ turn: Int) -> String {
        #"{"type":"user","timestamp":"2026-05-04T08:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Filler \#(turn) \#(String(repeating: "x", count: 4_000))"}]}}"#
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url, options: .atomic)
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
