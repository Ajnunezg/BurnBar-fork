import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore
import OpenBurnBarData

@MainActor
final class ChartFactRowSQLTests: XCTestCase {
    func test_factRows_matchTokenUsageSnapshot_last7DaysCoveringScan() async throws {
        let (usageStore, now) = try await seededStore()
        let recent = ChartsDataService.recentRange(now: now)
        let requested = try XCTUnwrap(TimeRange.last7Days.dateRange(now: now))

        let usages = try await usageStore.fetchUsage(in: recent, limit: Int.max)
        let facts = try await usageStore.fetchChartFactRows(in: recent)
        XCTAssertEqual(facts.count, usages.count)
        XCTAssertEqual(facts.map(\.sessionId), usages.map(\.sessionId))

        let usageWindows = ChartsDataService.deriveWindows(
            coveringRows: usages,
            requestedRange: requested,
            recentRange: recent
        )
        let factWindows = ChartsDataService.deriveWindows(
            coveringRows: facts,
            requestedRange: requested,
            recentRange: recent
        )
        XCTAssertEqual(factWindows.selected.map(\.sessionId), usageWindows.selected.map(\.sessionId))
        XCTAssertEqual(factWindows.recent.map(\.sessionId), usageWindows.recent.map(\.sessionId))

        let fromUsage = ChartsSnapshot.build(
            rows: usageWindows.selected,
            recentRows: usageWindows.recent,
            timeRange: .last7Days,
            usagesVersion: 3,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: factWindows.selected,
            recentRows: factWindows.recent,
            timeRange: .last7Days,
            usagesVersion: 3,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
    }

    func test_factRows_matchTokenUsageSnapshot_allTimeWithoutDecodeUsage() async throws {
        let (usageStore, now) = try await seededStore()
        let recent = ChartsDataService.recentRange(now: now)

        let usages = try await usageStore.fetchAllUsage()
        let facts = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(facts.count, usages.count)

        let usageWindows = ChartsDataService.deriveWindows(
            coveringRows: usages,
            requestedRange: nil,
            recentRange: recent
        )
        let factWindows = ChartsDataService.deriveWindows(
            coveringRows: facts,
            requestedRange: nil,
            recentRange: recent
        )

        let fromUsage = ChartsSnapshot.build(
            rows: usageWindows.selected,
            recentRows: usageWindows.recent,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: factWindows.selected,
            recentRows: factWindows.recent,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.cacheReadTokens, fromUsage.cacheReadTokens)
        XCTAssertEqual(fromFacts.exactShare, fromUsage.exactShare, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.remoteCost, fromUsage.remoteCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.apiCost, fromUsage.apiCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.subscriptionCost, fromUsage.subscriptionCost, accuracy: 1e-12)
        XCTAssertEqual(fromFacts.unknownBillingCost, fromUsage.unknownBillingCost, accuracy: 1e-12)
    }

    func test_factRows_clampsCrossingSessionToRangeLowerBound() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        let startOfToday = calendar.startOfDay(for: now)
        let row = TokenUsage(
            provider: .claudeCode,
            sessionId: "crossing",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 2.0,
            startTime: startOfToday.addingTimeInterval(-300),
            endTime: startOfToday.addingTimeInterval(300)
        )
        try await usageStore.insert(row)

        let today = try XCTUnwrap(TimeRange.today.dateRange(now: now))
        let usages = try await usageStore.fetchUsage(in: today, limit: Int.max)
        let facts = try await usageStore.fetchChartFactRows(in: today)
        XCTAssertEqual(facts.map(\.sessionId), ["crossing"])

        let fromUsage = ChartsSnapshot.build(
            rows: usages,
            recentRows: usages,
            timeRange: .today,
            usagesVersion: 0,
            now: now,
            calendar: calendar
        )
        let fromFacts = ChartsSnapshot.build(
            rows: facts,
            recentRows: facts,
            timeRange: .today,
            usagesVersion: 0,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.burnSeries.reduce(0) { $0 + $1.value }, 2.0, accuracy: 1e-9)
    }

    func test_factRows_stampedApiBillingKind_doesNotReclassifyToSubscription() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        // Claude Code is subscription-first. A stamped `.api` row must stay
        // API after the fact-row scan or Spend Lens would silently rebucket.
        let stamped = TokenUsage(
            provider: .claudeCode,
            sessionId: "stamped-api",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 4.0,
            startTime: now.addingTimeInterval(-3_600),
            endTime: now.addingTimeInterval(-1_800),
            billingKind: .api
        )
        let unclassified = TokenUsage(
            provider: .openCode,
            sessionId: "unclassified",
            projectName: "",
            model: "mystery-model",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: 7.5,
            startTime: now.addingTimeInterval(-2 * 3_600),
            endTime: now.addingTimeInterval(-1.5 * 3_600),
            provenanceConfidence: .lowConfidenceEstimate
        )
        try await usageStore.insert([stamped, unclassified])

        let usages = try await usageStore.fetchAllUsage()
        let facts = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(facts.first { $0.sessionId == "stamped-api" }?.billingKind, .api)

        let fromUsage = ChartsSnapshot.build(
            rows: usages,
            recentRows: usages,
            timeRange: .last7Days,
            usagesVersion: 1,
            now: now
        )
        let fromFacts = ChartsSnapshot.build(
            rows: facts,
            recentRows: facts,
            timeRange: .last7Days,
            usagesVersion: 1,
            now: now
        )
        XCTAssertEqual(fromFacts, fromUsage)
        XCTAssertEqual(fromFacts.apiCost, 4.0, accuracy: 1e-9)
        XCTAssertEqual(fromFacts.unknownBillingCost, 7.5, accuracy: 1e-9)
        XCTAssertEqual(
            fromFacts.apiCost + fromFacts.subscriptionCost + fromFacts.unknownBillingCost,
            fromFacts.totalCost,
            accuracy: 0.0001
        )
    }

    // MARK: - All-time SQL aggregates

    func test_allTimeAggregates_matchPerRowSnapshot_withFactsBoundedBySlotAndDimensions() async throws {
        let (usageStore, now) = try await aggregateSeededStore()
        let recent = ChartsDataService.recentRange(now: now)
        let perRow = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(perRow.count, 1_560)
        let windows = ChartsDataService.deriveWindows(coveringRows: perRow, requestedRange: nil, recentRange: recent)
        let fromRows = ChartsSnapshot.build(
            rows: windows.selected, recentRows: windows.recent, timeRange: .allTime, usagesVersion: 4, now: now
        )

        let aggregates = try await usageStore.fetchChartAggregates(recentRange: recent)
        let fromAggregates = ChartsSnapshot.build(
            facts: aggregates.facts,
            recentFacts: aggregates.recentFacts,
            sessions: aggregates.sessions,
            timeRange: .allTime,
            usagesVersion: 4,
            now: now
        )

        // One fact per (15-minute slot, every chart dimension, recent 31-day
        // membership): the grain is pinned exactly, and it is bounded by time ×
        // dimensions — a fraction of the 1,560 rows / 1,400 sessions.
        struct Grain: Hashable {
            let slot: Int, project: String, model: String, provider: AgentProvider
            let billing: BurnBarBillingKind, source: UsageSource, provenance: UsageProvenanceConfidence
            let isRemote: Bool, pricing: UsagePricingSource, inRecent: Bool
        }
        let grains = Set(perRow.map {
            Grain(
                slot: Int(($0.startTime.timeIntervalSince1970 / Double(UsageStore.chartAggregateSlotSeconds)).rounded(.down)),
                project: $0.projectName, model: $0.model, provider: $0.provider,
                billing: $0.billingKind, source: $0.usageSource, provenance: $0.provenanceConfidence,
                isRemote: $0.isRemote, pricing: $0.pricingSource, inRecent: $0.intersects(dateRange: recent)
            )
        })
        XCTAssertEqual(aggregates.facts.count, grains.count)
        XCTAssertLessThan(aggregates.facts.count, perRow.count / 5)
        XCTAssertEqual(aggregates.recentFacts.count, grains.filter(\.inRecent).count)
        XCTAssertEqual(aggregates.sessions.count, 1_400)
        XCTAssertEqual(aggregates.sessions.costs.count, 1_400)
        XCTAssertEqual(
            fromAggregates.outlierSessions.map(\.sessionId),
            ["agg-session-1391", "agg-session-1392", "agg-session-1393", "agg-session-1394", "agg-session-1370"]
        )

        Self.assertEquivalent(fromAggregates, fromRows)
    }

    func test_allTimeAggregates_dropTheRowsThePerRowScanCannotDecode() async throws {
        let (usageStore, now) = try await aggregateSeededStore()
        try await usageStore.dbQueue.write { db in
            try db.execute(sql: "UPDATE token_usage SET provider = 'retired-provider' WHERE sessionId = 'agg-session-707'")
            try db.execute(sql: "UPDATE token_usage SET startTime = 'not-a-date' WHERE sessionId = 'agg-session-911'")
        }
        let recent = ChartsDataService.recentRange(now: now)
        let perRow = try await usageStore.fetchChartFactRows(in: nil)
        XCTAssertEqual(perRow.count, 1_558)
        let windows = ChartsDataService.deriveWindows(coveringRows: perRow, requestedRange: nil, recentRange: recent)
        let fromRows = ChartsSnapshot.build(
            rows: windows.selected, recentRows: windows.recent, timeRange: .allTime, usagesVersion: 5, now: now
        )
        let aggregates = try await usageStore.fetchChartAggregates(recentRange: recent)
        XCTAssertEqual(aggregates.sessions.count, 1_398)

        Self.assertEquivalent(
            ChartsSnapshot.build(
                facts: aggregates.facts,
                recentFacts: aggregates.recentFacts,
                sessions: aggregates.sessions,
                timeRange: .allTime,
                usagesVersion: 5,
                now: now
            ),
            fromRows
        )
    }

    func test_emptyLedger_allTimeAggregatesBuildTheEmptySnapshot() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        let aggregates = try await usageStore.fetchChartAggregates(recentRange: ChartsDataService.recentRange(now: now))
        XCTAssertTrue(aggregates.facts.isEmpty)
        XCTAssertEqual(aggregates.sessions, ChartSessionTotals(count: 0, costs: [], outlierSessions: []))
        let snapshot = ChartsSnapshot.build(
            facts: aggregates.facts,
            recentFacts: aggregates.recentFacts,
            sessions: aggregates.sessions,
            timeRange: .allTime,
            usagesVersion: 0,
            now: now
        )
        XCTAssertEqual(snapshot, ChartsSnapshot.build(rows: [ChartFactRow](), recentRows: [], timeRange: .allTime, usagesVersion: 0, now: now))
    }

    func test_selectColumnOrder_matchesIndexEnums() {
        XCTAssertEqual(
            UsageStore.usageDecodeSelectColumns[UsageStore.UsageDecodeCol.id.rawValue],
            "id"
        )
        XCTAssertEqual(
            UsageStore.usageDecodeSelectColumns[UsageStore.UsageDecodeCol.billingKind.rawValue],
            "billingKind"
        )
        XCTAssertEqual(
            UsageStore.usageDecodeSelectColumns.count,
            UsageStore.UsageDecodeCol.billingKind.rawValue + 1
        )
        XCTAssertEqual(
            UsageStore.chartFactSelectColumns[UsageStore.ChartFactCol.startTime.rawValue],
            "startTime"
        )
        XCTAssertEqual(
            UsageStore.chartFactSelectColumns[UsageStore.ChartFactCol.isRemote.rawValue],
            "isRemote"
        )
        XCTAssertEqual(
            UsageStore.chartFactSelectColumns[UsageStore.ChartFactCol.pricingSource.rawValue],
            "pricingSource"
        )
        XCTAssertEqual(
            UsageStore.chartFactSelectColumns.count,
            UsageStore.ChartFactCol.pricingSource.rawValue + 1
        )
        XCTAssertEqual(
            UsageStore.chartAggregateSelectColumns[UsageStore.ChartFactCol.pricingSource.rawValue],
            "pricingSource"
        )
        XCTAssertEqual(
            UsageStore.chartSessionSelectColumns[UsageStore.ChartSessionCol.provider.rawValue],
            "provider"
        )
        XCTAssertEqual(
            UsageStore.chartSessionSelectColumns.count,
            UsageStore.ChartSessionCol.provider.rawValue + 1
        )
        XCTAssertEqual(
            UsageStore.chartAggregateSelectColumns.count,
            UsageStore.chartAggregateBilledTotalColumn + 1
        )
        XCTAssertEqual(UsageStore.chartAggregateRecentWindowColumn, UsageStore.chartAggregateBilledTotalColumn + 1)
    }

    func test_chartFactIndexDecode_matchesNamedColumnOracle() async throws {
        let (usageStore, _) = try await seededStore()
        let (named, indexed) = try await usageStore.dbQueue.read { db -> ([ChartFactRow], [ChartFactRow]) in
            let sql = """
                SELECT \(UsageStore.chartFactSelectColumns.joined(separator: ", "))
                FROM token_usage
                ORDER BY startTime DESC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return (rows.compactMap(Self.namedChartFact), rows.compactMap(UsageStore.decodeChartFactRow))
        }
        XCTAssertFalse(indexed.isEmpty)
        XCTAssertEqual(indexed, named)
    }

    func test_usageIndexDecode_matchesNamedColumnOracle() async throws {
        let (usageStore, _) = try await seededStore()
        let fromStore = try await usageStore.fetchAllUsage()
        let (named, indexed) = try await usageStore.dbQueue.read { db -> ([TokenUsage], [TokenUsage]) in
            let sql = """
                SELECT \(UsageStore.usageDecodeSelectColumns.joined(separator: ", "))
                FROM token_usage
                ORDER BY startTime DESC
                """
            let rows = try Row.fetchAll(db, sql: sql)
            return (rows.compactMap(Self.namedUsage), rows.compactMap(UsageStore.decodeUsage))
        }
        XCTAssertEqual(indexed, named)
        XCTAssertEqual(indexed.map(\.sessionId), fromStore.map(\.sessionId))
    }

    func test_databasePoolTuning_appliesReaderCountAndBusyTimeout() {
        var config = Configuration()
        OpenBurnBarDatabase.applyPoolTuning(&config)
        XCTAssertEqual(config.maximumReaderCount, OpenBurnBarDatabase.PoolTuning.maximumReaderCount)
        XCTAssertEqual(OpenBurnBarDatabase.PoolTuning.maximumReaderCount, 8)
        XCTAssertEqual(OpenBurnBarDatabase.PoolTuning.busyTimeoutSeconds, 5)
    }

    func test_explainQueryPlan_onDiskPool_unsyncedUsesSyncPendingIndex() async throws {
        let (pool, _, _) = try await makeOnDiskPoolStore()
        defer { try? pool.close() }
        try await pool.write { db in
            try db.execute(sql: "ANALYZE")
        }
        let plan = try await pool.read { db in
            try Self.explainQueryPlan(
                db,
                sql: """
                    SELECT \(UsageStore.usageDecodeSelectColumns.joined(separator: ", "))
                    FROM token_usage
                    WHERE syncedAt IS NULL AND isRemote = 0
                    ORDER BY startTime ASC LIMIT 400
                    """
            )
        }
        XCTAssertTrue(
            plan.localizedCaseInsensitiveContains("token_usage_sync_pending_idx"),
            "unsynced path must use the existing sync-pending index; got:\n\(plan)"
        )
        let indexes = try await pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'token_usage'"
            )
        }
        XCTAssertFalse(
            indexes.contains { $0.localizedCaseInsensitiveContains("covering") },
            "covering-index migration is out of this PR; indexes=\(indexes)"
        )
    }

    func test_explainQueryPlan_onDiskPool_chartIntersectionNeedsNoNewCoveringIndex() async throws {
        let (pool, _, now) = try await makeOnDiskPoolStore()
        defer { try? pool.close() }
        try await pool.write { db in
            try db.execute(sql: "ANALYZE")
        }
        let recent = ChartsDataService.recentRange(now: now)
        let predicate = UsageStore.dateRangePredicate(recent)
        let plan = try await pool.read { db in
            try Self.explainQueryPlan(
                db,
                sql: """
                    SELECT \(UsageStore.chartFactSelectColumns.joined(separator: ", "))
                    FROM token_usage
                    \(predicate.whereSQL)
                    ORDER BY startTime DESC
                    """,
                arguments: predicate.arguments
            )
        }
        XCTAssertTrue(plan.localizedCaseInsensitiveContains("token_usage"), plan)
        XCTAssertFalse(
            plan.localizedCaseInsensitiveContains("token_usage_chart_fact_covering"),
            "no chart covering-index migration this round; got:\n\(plan)"
        )
    }

    // GRDB `DatabasePool.read` / `DatabaseQueue.read` closures are nonisolated.
    // Keep these oracles off MainActor so compactMap/EXPLAIN stay valid after
    // the suite itself is isolated for DataStore inits.
    nonisolated private static func explainQueryPlan(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) throws -> String {
        let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
        return rows.map { row in
            if let detail: String = row["detail"] {
                return detail
            }
            return (0..<row.count).compactMap { row[$0] as? String }.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private func makeOnDiskPoolStore() async throws -> (DatabasePool, UsageStore, Date) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-eqp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("openburnbar.sqlite").path
        var config = Configuration()
        OpenBurnBarDatabase.applyPoolTuning(&config)
        let pool = try DatabasePool(path: path, configuration: config)
        XCTAssertEqual(pool.configuration.maximumReaderCount, OpenBurnBarDatabase.PoolTuning.maximumReaderCount)
        _ = try DataStore(databaseQueue: pool, runMigrations: true, refreshOnInit: false)
        try OpenBurnBarDatabase.configureWALMode(pool)
        let usageStore = UsageStore(dbQueue: pool)
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(
            TokenUsage(
                provider: .openCode,
                sessionId: "session-unclassified",
                projectName: "",
                model: "mystery-model",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 7.5,
                startTime: now.addingTimeInterval(-3 * 3_600),
                endTime: now.addingTimeInterval(-2.5 * 3_600),
                provenanceConfidence: .lowConfidenceEstimate
            )
        )
        for index in 0..<400 {
            rows.append(
                TokenUsage(
                    provider: .codex,
                    sessionId: "eqp-unsynced-\(index)",
                    projectName: "eqp",
                    model: "gpt-5.6",
                    inputTokens: 1,
                    outputTokens: 1,
                    startTime: now.addingTimeInterval(Double(-index) * 60),
                    endTime: now.addingTimeInterval(Double(-index) * 60 + 30)
                )
            )
        }
        try await usageStore.insert(rows)
        return (pool, usageStore, now)
    }

    nonisolated private static func namedChartFact(_ row: Row) -> ChartFactRow? {
        guard let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"]),
              let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"]),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String,
              let model = row["model"] as? String,
              let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw) else {
            return nil
        }
        let inputTokens = UsageStore.intValue(row["inputTokens"])
        let outputTokens = UsageStore.intValue(row["outputTokens"])
        let cacheCreationTokens = UsageStore.intValue(row["cacheCreationTokens"])
        let cacheReadTokens = UsageStore.intValue(row["cacheReadTokens"])
        let reasoningTokens = UsageStore.intValue(row["reasoningTokens"])
        return ChartFactRow(
            startTime: startTime,
            endTime: endTime,
            cost: UsageStore.doubleValue(row["cost"]),
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            provider: provider,
            billingKind: (row["billingKind"] as? String)
                .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown,
            usageSource: (row["usageSource"] as? String)
                .flatMap(UsageSource.init(rawValue:)) ?? .unknown,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: TokenUsage.billedTotalTokens(
                input: inputTokens,
                output: outputTokens,
                cacheCreation: cacheCreationTokens,
                cacheRead: cacheReadTokens,
                reasoning: reasoningTokens
            ),
            provenanceConfidence: (row["provenanceConfidence"] as? String)
                .flatMap(UsageProvenanceConfidence.init(rawValue:)) ?? .unknown,
            isRemote: UsageStore.intValue(row["isRemote"]) != 0,
            pricingSource: (row["pricingSource"] as? String)
                .flatMap(UsagePricingSource.init(rawValue:)) ?? .unknown
        )
    }

    nonisolated private static func namedUsage(_ row: Row) -> TokenUsage? {
        guard let idString = row["id"] as? String,
              let id = UUID(uuidString: idString),
              let providerString = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerString),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String,
              let model = row["model"] as? String else { return nil }
        let inputTokens = UsageStore.intValue(row["inputTokens"])
        let outputTokens = UsageStore.intValue(row["outputTokens"])
        let cacheCreationTokens = UsageStore.intValue(row["cacheCreationTokens"])
        let cacheReadTokens = UsageStore.intValue(row["cacheReadTokens"])
        let reasoningTokens = UsageStore.intValue(row["reasoningTokens"])
        let usageSource = (row["usageSource"] as? String).flatMap(UsageSource.init(rawValue:)) ?? .unknown
        let executionSourceKind = (row["executionSourceKind"] as? String)
            .flatMap(UsageExecutionSourceKind.init(rawValue:))
        let executionSourceConfidence = (row["executionSourceConfidence"] as? String)
            .flatMap(UsageProvenanceConfidence.init(rawValue:))
        let provenanceMethod = (row["provenanceMethod"] as? String)
            .flatMap(UsageProvenanceMethod.init(rawValue:)) ?? .unknown
        let provenanceConfidence = (row["provenanceConfidence"] as? String)
            .flatMap(UsageProvenanceConfidence.init(rawValue:)) ?? .unknown
        let estimatorVersion = row["estimatorVersion"] as? String ?? ""
        let cost: Double = row["cost"] ?? 0
        let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"])
        let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"])
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        guard let startTime, let endTime else { return nil }
        let providerID = (row["providerID"] as? String).map(ProviderID.init(rawValue:)) ?? provider.providerID
        let providerAccountSourceRaw = row["providerAccountSource"] as? String
        return TokenUsage(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            createdAt: createdAt,
            usageSource: usageSource,
            executionSourceID: row["executionSourceID"] as? String,
            executionSourceName: row["executionSourceName"] as? String,
            executionSourceKind: executionSourceKind,
            executionSourceConfidence: executionSourceConfidence,
            sourceDeviceId: row["sourceDeviceId"] as? String,
            sourceDeviceName: row["sourceDeviceName"] as? String,
            isRemote: UsageStore.intValue(row["isRemote"]) != 0,
            providerID: providerID,
            providerAccountID: row["providerAccountID"] as? String,
            providerAccountLabel: row["providerAccountLabel"] as? String,
            providerAccountSource: providerAccountSourceRaw.flatMap(ProviderAccountStorageScope.init(rawValue:)),
            provenanceMethod: provenanceMethod,
            provenanceConfidence: provenanceConfidence,
            estimatorVersion: estimatorVersion,
            parentRequestID: row["parentRequestID"] as? String,
            billingKind: (row["billingKind"] as? String)
                .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown
        )
    }

    /// 1,400 sessions (160 with a second model row) packed into 26 fifteen-
    /// minute bursts from 30 minutes to ~83 days ago, plus a row just after
    /// `now` that shares `now`'s slot and dimensions with one just before it,
    /// one session spanning the 31-day edge, and rows that straddle the edge
    /// inside one slot. Like real traffic, a burst mostly works one provider
    /// and project; every grouped dimension varies inside it. Costs are
    /// multiples of 1/8 so every sum is exact in any grouping or order. The four
    /// costliest sessions are distinct and 21 tie for fifth, so the session-id
    /// tie-break decides the last outlier.
    private func aggregateSeededStore() async throws -> (UsageStore, Date) {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let slotSeconds = TimeInterval(UsageStore.chartAggregateSlotSeconds)
        // Mid-slot, so a row just before `now` and one just after share a slot.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / slotSeconds).rounded(.down) * slotSeconds + 450)
        let burstHoursAgo: [Double] = [
            0.5, 2, 5, 9, 26, 30, 49, 73, 97, 121, 150, 200, 260,
            330, 400, 480, 560, 640, 720, 745, 760, 900, 1_100, 1_300, 1_500, 2_000
        ]
        let providers: [(AgentProvider, [String])] = [
            (.claudeCode, ["claude-opus-4-8", "claude-sonnet-4-6"]),
            (.codex, ["gpt-5.6", "gpt-5.6-mini"]),
            (.cursor, ["cursor-fast", "cursor-max"])
        ]
        let projects = ["alpha", "beta", ""]
        let provenance: [UsageProvenanceConfidence] = [.exact, .highConfidenceEstimate, .lowConfidenceEstimate]
        let topCosts: [Int: Double] = [1_391: 400, 1_392: 350, 1_393: 300, 1_394: 250]
        let tiedForFifth = 1_370..<1_391
        var rows: [TokenUsage] = []
        func row(_ index: Int, burst: Int, secondModel: Bool = false, start: Date, end: Date) -> TokenUsage {
            // Each dimension also flips for a sparse subset of rows, so a burst
            // splits into several facts and every GROUP BY key is exercised.
            func flip(_ modulus: Int) -> Int { index % modulus == 0 ? 1 : 0 }
            // A flipped provider keeps the burst's models: one model name can
            // bill through two providers.
            let provider = providers[(burst + flip(37)) % providers.count].0
            let models = providers[burst % providers.count].1
            return TokenUsage(
                provider: provider,
                sessionId: "agg-session-\(index)",
                projectName: projects[(burst / 3 + flip(29)) % projects.count],
                model: models[secondModel ? 1 : 0],
                inputTokens: (index % 50) * 10 + 1,
                outputTokens: (index % 17) * 3,
                cacheCreationTokens: index % 4 == 0 ? 100 : 0,
                cacheReadTokens: (index % 9) * 20,
                reasoningTokens: index % 6 == 0 ? 40 : 0,
                costUSD: topCosts[index] ?? (tiedForFifth.contains(index) ? 200 : Double((index * 7) % 29 + 1) / 8),
                pricingSource: flip(43) == 1 ? .fallback : .catalog,
                startTime: start,
                endTime: end,
                usageSource: flip(41) == 1 ? .billingAPI : .providerLog,
                isRemote: index % 11 == 1,
                provenanceConfidence: provenance[(burst + flip(31)) % provenance.count],
                billingKind: (burst + flip(17)) % 4 == 0 ? .api : .unknown
            )
        }
        for index in 0..<1_396 {
            let burst = index % burstHoursAgo.count
            let ordinal = index / burstHoursAgo.count
            let hoursAgo = burstHoursAgo[burst]
            let slotStart = ((now.timeIntervalSince1970 - hoursAgo * 3_600) / slotSeconds).rounded(.down) * slotSeconds
            let start = Date(timeIntervalSince1970: slotStart + Double(ordinal % 840))
            // In the 745h burst (just past the 31-day edge) every other row
            // runs into the recent window: same slot, different membership.
            let end = start.addingTimeInterval(hoursAgo == 745 && ordinal.isMultiple(of: 2) ? 7_200 : 30)
            rows.append(row(index, burst: burst, start: start, end: end))
            if index < 160 {
                rows.append(row(index, burst: burst, secondModel: true, start: start.addingTimeInterval(2), end: end))
            }
        }
        rows.append(row(1_396, burst: 0, start: now.addingTimeInterval(300), end: now.addingTimeInterval(360)))
        rows.append(row(1_397, burst: 0, start: now.addingTimeInterval(-120), end: now.addingTimeInterval(-60)))
        rows.append(row(1_398, burst: 2, start: now.addingTimeInterval(-3 * 3_600), end: now.addingTimeInterval(-2 * 3_600)))
        rows.append(row(1_399, burst: 3, start: now.addingTimeInterval(-32 * 86_400), end: now.addingTimeInterval(-30 * 86_400)))
        try await usageStore.insert(rows)
        return (usageStore, now)
    }

    /// Field-by-field snapshot equality. Keyed mixes compare as dictionaries
    /// (a cost tie may order differently when the fold sees facts instead of
    /// rows); the two sums over dictionary values allow last-bit error.
    private static func assertEquivalent(
        _ lhs: ChartsSnapshot,
        _ rhs: ChartsSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.isEmpty, rhs.isEmpty, file: file, line: line)
        XCTAssertEqual(lhs.totalCost, rhs.totalCost, file: file, line: line)
        XCTAssertEqual(lhs.totalTokens, rhs.totalTokens, file: file, line: line)
        XCTAssertEqual(lhs.sessionCount, rhs.sessionCount, file: file, line: line)
        XCTAssertEqual(lhs.burnSeries, rhs.burnSeries, file: file, line: line)
        XCTAssertEqual(lhs.burnTrendPercent, rhs.burnTrendPercent, file: file, line: line)
        XCTAssertEqual(lhs.apiBurnSeries, rhs.apiBurnSeries, file: file, line: line)
        XCTAssertEqual(lhs.subscriptionBurnSeries, rhs.subscriptionBurnSeries, file: file, line: line)
        XCTAssertEqual(lhs.unknownBurnSeries, rhs.unknownBurnSeries, file: file, line: line)
        XCTAssertEqual(lhs.apiCost, rhs.apiCost, file: file, line: line)
        XCTAssertEqual(lhs.subscriptionCost, rhs.subscriptionCost, file: file, line: line)
        XCTAssertEqual(lhs.unknownBillingCost, rhs.unknownBillingCost, file: file, line: line)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: lhs.providerShares.map { ($0.provider, $0.cost) }),
            Dictionary(uniqueKeysWithValues: rhs.providerShares.map { ($0.provider, $0.cost) }),
            file: file, line: line
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: lhs.modelCosts.map { ($0.label, $0.value) }),
            Dictionary(uniqueKeysWithValues: rhs.modelCosts.map { ($0.label, $0.value) }),
            file: file, line: line
        )
        XCTAssertEqual(lhs.cacheHitRateSeries, rhs.cacheHitRateSeries, file: file, line: line)
        XCTAssertEqual(lhs.cacheHitRate, rhs.cacheHitRate, file: file, line: line)
        XCTAssertEqual(lhs.cacheReadTokens, rhs.cacheReadTokens, file: file, line: line)
        XCTAssertEqual(lhs.cacheSavingsEstimate, rhs.cacheSavingsEstimate, file: file, line: line)
        XCTAssertEqual(lhs.reasoningShareSeries, rhs.reasoningShareSeries, file: file, line: line)
        XCTAssertEqual(lhs.reasoningShare, rhs.reasoningShare, file: file, line: line)
        XCTAssertEqual(lhs.hourWeekdayCost, rhs.hourWeekdayCost, file: file, line: line)
        XCTAssertEqual(lhs.peakWeekdayIndex, rhs.peakWeekdayIndex, file: file, line: line)
        XCTAssertEqual(lhs.peakHour, rhs.peakHour, file: file, line: line)
        XCTAssertEqual(lhs.thisWeekDaily, rhs.thisWeekDaily, file: file, line: line)
        XCTAssertEqual(lhs.lastWeekDaily, rhs.lastWeekDaily, file: file, line: line)
        XCTAssertEqual(lhs.weekOverWeekPercent, rhs.weekOverWeekPercent, file: file, line: line)
        XCTAssertEqual(lhs.sessionCostBins, rhs.sessionCostBins, file: file, line: line)
        XCTAssertEqual(lhs.medianSessionCost, rhs.medianSessionCost, file: file, line: line)
        XCTAssertEqual(lhs.outlierSessions, rhs.outlierSessions, file: file, line: line)
        XCTAssertEqual(lhs.projectDayStarts, rhs.projectDayStarts, file: file, line: line)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: lhs.projectSeries.map { ($0.projectName, $0.dailyCosts) }),
            Dictionary(uniqueKeysWithValues: rhs.projectSeries.map { ($0.projectName, $0.dailyCosts) }),
            file: file, line: line
        )
        XCTAssertEqual(lhs.projectEntropy, rhs.projectEntropy, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(lhs.forecast, rhs.forecast, file: file, line: line)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: lhs.provenanceShares.map { ($0.label, $0.value) }),
            Dictionary(uniqueKeysWithValues: rhs.provenanceShares.map { ($0.label, $0.value) }),
            file: file, line: line
        )
        XCTAssertEqual(lhs.exactShare, rhs.exactShare, file: file, line: line)
        XCTAssertEqual(lhs.modelConcentrationIndex, rhs.modelConcentrationIndex, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(lhs.remoteCost, rhs.remoteCost, file: file, line: line)
        XCTAssertEqual(lhs.localCost, rhs.localCost, file: file, line: line)
    }

    private func seededStore() async throws -> (UsageStore, Date) {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(
            TokenUsage(
                provider: .openCode,
                sessionId: "session-unclassified",
                projectName: "",
                model: "mystery-model",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 7.5,
                startTime: now.addingTimeInterval(-3 * 3_600),
                endTime: now.addingTimeInterval(-2.5 * 3_600),
                provenanceConfidence: .lowConfidenceEstimate
            )
        )
        try await usageStore.insert(rows)
        return (usageStore, now)
    }
}
