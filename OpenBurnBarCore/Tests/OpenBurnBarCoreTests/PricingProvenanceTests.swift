import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel

/// A dollar figure priced at the fallback table ($2.50 / $10 / $1.25 per M)
/// is an estimate. It used to be indistinguishable from a listed rate — the
/// catalog decoded a missing `pricing` block as the fallback table, the lookup
/// fell back silently, and parsers stamped the row `.exact`.
final class PricingProvenanceTests: XCTestCase {
    /// Catalog entries that ship without a published rate. Pinned so a new
    /// unpriced model is a decision, not an accident: price it from a
    /// published source, or add it here knowing its spend shows as estimated.
    private static let unlistedModelIDs: Set<String> = [
        "opencode-kimi-k2.6-family", "opencode-kimi-k2.5-family",
        "opencode-glm-5.1-family", "opencode-glm-5-family",
        "opencode-minimax-m2.7-family", "opencode-minimax-m2.5-family",
        "opencode-deepseek-v4-pro-family", "opencode-deepseek-v4-flash-family",
        "opencode-qwen3.6-plus-family", "opencode-qwen3.5-plus-family",
        "opencode-mimo-v2.5-pro-family", "opencode-mimo-v2.5-family",
        "opencode-mimo-v2-pro-family", "opencode-mimo-v2-omni-family",
        "opencode-hy3-preview-family"
    ]

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Catalog

    func testCatalogMarksEntriesWithoutAPricingBlockAsUnlisted() throws {
        let unpriced = try JSONDecoder().decode(
            BurnBarCatalogModel.self,
            from: Data(#"{"id":"unpriced","displayName":"Unpriced","visibility":"public"}"#.utf8)
        )
        let explicitNull = try JSONDecoder().decode(
            BurnBarCatalogModel.self,
            from: Data(#"{"id":"null-priced","displayName":"Null","visibility":"public","pricing":null}"#.utf8)
        )
        let priced = try JSONDecoder().decode(
            BurnBarCatalogModel.self,
            from: Data(#"{"id":"priced","displayName":"Priced","visibility":"public","pricing":{"inputPerMToken":1,"outputPerMToken":2,"cacheReadPerMToken":0.1}}"#.utf8)
        )

        XCTAssertFalse(unpriced.hasListedPricing)
        XCTAssertFalse(explicitNull.hasListedPricing)
        XCTAssertTrue(priced.hasListedPricing)
        // Routing still gets a number to rank by.
        XCTAssertEqual(unpriced.pricing, .defaultFallback)
    }

    func testUnlistedPricingSurvivesAnEncodeDecodeRoundTrip() throws {
        let unpriced = try JSONDecoder().decode(
            BurnBarCatalogModel.self,
            from: Data(#"{"id":"unpriced","displayName":"Unpriced","visibility":"public"}"#.utf8)
        )

        let roundTripped = try JSONDecoder().decode(BurnBarCatalogModel.self, from: JSONEncoder().encode(unpriced))

        XCTAssertFalse(roundTripped.hasListedPricing, "a round trip must not launder the fallback table into a rate")
        XCTAssertEqual(roundTripped, unpriced)
    }

    func testBundledCatalogUnlistedModelsArePinned() {
        let unlisted = Set(
            BurnBarCatalogLoader.bundledCatalog.providers
                .flatMap(\.models)
                .filter { !$0.hasListedPricing }
                .map(\.id)
        )

        XCTAssertEqual(unlisted, Self.unlistedModelIDs)
    }

    // MARK: - ModelPricing

    func testListedModelPricesFromTheCatalogAndSaysSo() throws {
        let pricing = ModelPricing.lookup(model: "claude-opus-4-8")

        XCTAssertEqual(pricing.source, .catalog)
        XCTAssertEqual(pricing.inputPerMToken, 5)
        XCTAssertTrue(ModelPricing.hasCatalogPricing(model: "claude-opus-4-8"))
    }

    func testUnknownModelPricesAtFallbackRatesAndSaysSo() {
        let pricing = ModelPricing.lookup(model: "no-such-model-anywhere-7")

        XCTAssertEqual(pricing.source, .fallback)
        XCTAssertEqual(pricing.inputPerMToken, BurnBarModelPricing.defaultFallback.inputPerMToken)
        XCTAssertFalse(ModelPricing.hasCatalogPricing(model: "no-such-model-anywhere-7"))
    }

    func testCatalogEntryWithoutAListedRateIsAFallbackNotACatalogPrice() {
        // OpenCode's Kimi K2.6 family is in the catalog but carries no rate.
        let pricing = ModelPricing.lookup(model: "kimi-k2.6", providerID: "opencode")

        XCTAssertEqual(pricing.source, .fallback)
        XCTAssertFalse(ModelPricing.hasCatalogPricing(model: "kimi-k2.6", providerID: "opencode"))
        // Moonshot publishes a rate for the same model; the vendor lookup is listed.
        XCTAssertEqual(ModelPricing.lookup(model: "kimi-k2.6").source, .catalog)
    }

    // MARK: - TokenUsage

    func testFallbackPricedRowNeverClaimsExact() {
        let usage = makeUsage(pricingSource: .fallback, confidence: .exact)

        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(usage.tokenConfidence, .exact)
        XCTAssertTrue(usage.pricingSource.isEstimated)
    }

    func testListedOrReportedPricingKeepsTheTokenConfidence() {
        XCTAssertEqual(makeUsage(pricingSource: .catalog, confidence: .exact).provenanceConfidence, .exact)
        XCTAssertEqual(makeUsage(pricingSource: .reported, confidence: .exact).provenanceConfidence, .exact)
        XCTAssertEqual(makeUsage(pricingSource: .unknown, confidence: .derivedExact).provenanceConfidence, .derivedExact)
        // Already below the cap: unchanged.
        XCTAssertEqual(makeUsage(pricingSource: .fallback, confidence: .unknown).provenanceConfidence, .unknown)
    }

    func testPricingProvenanceSurvivesCodableAndLegacyRowsDecodeAsUnknown() throws {
        let usage = makeUsage(pricingSource: .fallback, confidence: .exact)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(usage))

        XCTAssertEqual(decoded.pricingSource, .fallback)
        XCTAssertEqual(decoded.tokenConfidence, .exact)
        XCTAssertEqual(decoded.provenanceConfidence, .lowConfidenceEstimate)

        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeUsage(pricingSource: .catalog, confidence: .exact)))
                as? [String: Any]
        )
        legacy.removeValue(forKey: "pricingSource")
        legacy.removeValue(forKey: "tokenConfidence")
        let legacyDecoded = try JSONDecoder().decode(
            TokenUsage.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(legacyDecoded.pricingSource, .unknown)
        XCTAssertEqual(legacyDecoded.tokenConfidence, .exact)
        XCTAssertEqual(legacyDecoded.provenanceConfidence, .exact)
    }

    // MARK: - Parsers

    func testClaudeRowsCarryTheirPricingSource() async throws {
        let root = try makeTemporaryDirectory(named: "claude-pricing")
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let transcript = projectsRoot
            .appendingPathComponent("-Users-test-Project", isDirectory: true)
            .appendingPathComponent("pricing.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((
            [
                assistantLine(model: "claude-opus-4-8", id: 1),
                assistantLine(model: "zz-local-unpriced-model", id: 2)
            ].joined(separator: "\n") + "\n"
        ).utf8).write(to: transcript)
        let parser = ClaudeCodeParser(
            fileManager: .default,
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)),
            projectsDirectoryOverride: projectsRoot
        )

        let fresh = try await parser.parse(options: .init(includeConversationBodies: false)).usages
        let cached = try await parser.parse(options: .init(includeConversationBodies: false)).usages

        for usages in [fresh, cached] {
            let listed = try XCTUnwrap(usages.first { $0.model == "claude-opus-4-8" })
            let unlisted = try XCTUnwrap(usages.first { $0.model == "zz-local-unpriced-model" })
            XCTAssertEqual(listed.pricingSource, .catalog)
            XCTAssertEqual(listed.provenanceConfidence, .exact)
            XCTAssertEqual(unlisted.pricingSource, .fallback)
            XCTAssertEqual(unlisted.tokenConfidence, .exact)
            XCTAssertEqual(unlisted.provenanceConfidence, .lowConfidenceEstimate)
        }
    }

    func testCachedRowsKeepPricingSourceAndTokenConfidence() async throws {
        let root = try makeTemporaryDirectory(named: "cline-pricing")
        let task = root.appendingPathComponent("task-pricing", isDirectory: true)
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
        try Data(
            #"[{"role":"assistant","content":"ok","ts":1772323200000,"model":"no-such-model-anywhere-7","usage":{"input_tokens":10,"output_tokens":5}}]"#.utf8
        ).write(to: task.appendingPathComponent("api_conversation_history.json"))
        let parser = ClineFormatParser(provider: .cline, storagePaths: [root.path])

        _ = try await parser.parse(options: .init(includeConversationBodies: false))
        let cached = try await parser.parse(options: .init(includeConversationBodies: false)).usages

        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        let usage = try XCTUnwrap(cached.first)
        XCTAssertEqual(usage.pricingSource, .fallback)
        XCTAssertEqual(usage.tokenConfidence, .exact)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
    }

    func testParserCacheWrittenBeforeRowFormatEpochsIsDropped() throws {
        let root = try makeTemporaryDirectory(named: "cache-epoch")
        let cacheURL = root.appendingPathComponent("cache.plist")
        let store = ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>(
            cacheURL: cacheURL,
            schemaVersion: 7,
            logLabel: "epoch-test"
        )
        var cache = ParserDiskCache<CachedUsageBundleEntry<FileSignature>>.empty(schemaVersion: 7)
        cache.fileEntries["/tmp/x"] = CachedUsageBundleEntry(
            signature: FileSignature(modifiedAt: 1, sizeBytes: 2),
            usages: [makeUsage(pricingSource: .catalog, confidence: .exact)]
        )
        store.persist(cache)
        XCTAssertEqual(store.load().fileEntries.count, 1)

        // Strip the epoch, as every cache written before this change lacks it.
        let data = try Data(contentsOf: cacheURL)
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        plist.removeValue(forKey: "rowFormatEpoch")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: cacheURL)

        XCTAssertTrue(store.load().fileEntries.isEmpty)
    }

    // MARK: - Fixtures

    private func makeUsage(pricingSource: UsagePricingSource, confidence: UsageProvenanceConfidence) -> TokenUsage {
        TokenUsage(
            provider: .claudeCode,
            sessionId: "session",
            projectName: "Project",
            model: "model",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 0.01,
            pricingSource: pricingSource,
            startTime: Date(timeIntervalSince1970: 1_777_000_000),
            endTime: Date(timeIntervalSince1970: 1_777_000_010),
            provenanceMethod: .providerLog,
            provenanceConfidence: confidence
        )
    }

    private func assistantLine(model: String, id: Int) -> String {
        #"{"type":"assistant","requestId":"req-\#(id)","timestamp":"2026-05-04T08:00:0\#(id)Z","message":{"id":"msg-\#(id)","role":"assistant","model":"\#(model)","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":100,"output_tokens":10}}}"#
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
