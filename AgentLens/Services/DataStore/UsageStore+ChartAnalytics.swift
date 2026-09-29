import Foundation
import GRDB
import OpenBurnBarData
import OpenBurnBarKernel

extension UsageStore {
    func fetchChartFactRows(
        in dateRange: ClosedRange<Date>?
    ) async throws -> [ChartFactRow] {
        try await dbQueue.read { db in
            try Self.fetchChartFactRows(db: db, dateRange: dateRange)
        }
    }

    /// Narrow `token_usage` projection for the full Charts snapshot.
    /// Window membership matches `fetchUsage(in:)` (intersection). Does not
    /// decode UUIDs, accounts, or execution source.
    static func fetchChartFactRows(
        db: Database,
        dateRange: ClosedRange<Date>?
    ) throws -> [ChartFactRow] {
        let predicate = dateRangePredicate(dateRange)
        return try compactMapCachedRows(
            db: db,
            sql: """
                SELECT \(chartFactSelectColumns.joined(separator: ", "))
                FROM token_usage
                \(predicate.whereSQL)
                ORDER BY startTime DESC
                """,
            arguments: predicate.arguments,
            transform: Self.decodeChartFactRow
        )
    }

    func fetchChartAggregates(recentRange: ClosedRange<Date>) async throws -> ChartAggregates {
        try await dbQueue.read { db in
            try Self.fetchChartAggregates(db: db, recentRange: recentRange)
        }
    }

    /// Bucket width of an aggregated all-time fact; see `ChartAggregates`.
    static let chartAggregateSlotSeconds = 900

    /// `ChartFactCol` layout, summed per slot, plus the billed total summed per
    /// row (`billedTotalTokens` clamps each row, so it cannot be derived from
    /// the summed token columns).
    static let chartAggregateSelectColumns = [
        "MIN(startTime)",
        "MAX(endTime)",
        "SUM(cost)",
        "''",
        "projectName",
        "model",
        "provider",
        "billingKind",
        "usageSource",
        "SUM(inputTokens)",
        "SUM(outputTokens)",
        "SUM(cacheCreationTokens)",
        "SUM(cacheReadTokens)",
        "SUM(reasoningTokens)",
        "provenanceConfidence",
        "isRemote",
        """
        SUM(MAX(inputTokens, 0) + MAX(outputTokens, 0) + MAX(cacheCreationTokens, 0) \
        + MAX(cacheReadTokens, 0) + MAX(reasoningTokens, 0))
        """
    ]
    static let chartAggregateBilledTotalColumn = ChartFactCol.isRemote.rawValue + 1
    static let chartAggregateRecentWindowColumn = ChartFactCol.isRemote.rawValue + 2

    /// All-time Charts inputs aggregated in SQL instead of one `ChartFactRow`
    /// per ledger row plus a full-table sort (see `ChartAggregates`). Rows are
    /// the ones `fetchChartFactRows(in: nil)` decodes; the recent window uses
    /// the `fetchUsage(in:)` intersection per row. That window ends at `now`,
    /// so its key also keeps a future-stamped row out of the facts that feed
    /// the forecast's month-to-date cut.
    static func fetchChartAggregates(
        db: Database,
        recentRange: ClosedRange<Date>
    ) throws -> ChartAggregates {
        let decodable = try chartDecodableRowsPredicate(db: db)
        var arguments = intersectionArguments(recentRange)
        arguments += decodable.arguments
        let statement = try db.cachedStatement(sql: """
            SELECT \(chartAggregateSelectColumns.joined(separator: ", ")),
                   \(intersectionSQL) AS inRecentWindow
            FROM token_usage
            WHERE \(decodable.sql)
            GROUP BY CAST(strftime('%s', startTime) AS INTEGER) / \(chartAggregateSlotSeconds),
                     projectName, model, provider, billingKind, usageSource,
                     provenanceConfidence, isRemote, inRecentWindow
            """)
        var facts: [ChartFactRow] = []
        var recentFacts: [ChartFactRow] = []
        let cursor = try Row.fetchCursor(statement, arguments: arguments)
        while let row = try cursor.next() {
            guard let fact = decodeChartFact(row, billedTotalColumn: chartAggregateBilledTotalColumn) else {
                continue
            }
            facts.append(fact)
            if intValue(indexed(row, chartAggregateRecentWindowColumn)) != 0 {
                recentFacts.append(fact)
            }
        }
        return ChartAggregates(
            facts: facts,
            recentFacts: recentFacts,
            sessions: try fetchChartSessionTotals(db: db, decodable: decodable)
        )
    }

    /// The rows `decodeChartFactRow` keeps — parseable timestamps and a
    /// provider `AgentProvider.resolve` accepts — so SQL aggregates drop
    /// exactly what the per-row scan's `compactMap` drops.
    static func chartDecodableRowsPredicate(
        db: Database
    ) throws -> (sql: String, arguments: StatementArguments) {
        let providers = try String.fetchAll(db, sql: "SELECT DISTINCT provider FROM token_usage")
        let resolvable = providers.filter { AgentProvider.resolve($0) != nil }
        let timestamps = "julianday(startTime) IS NOT NULL AND julianday(endTime) IS NOT NULL"
        guard resolvable.count < providers.count else {
            return (timestamps, StatementArguments())
        }
        return (
            "\(timestamps) AND provider IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: resolvable.count)))",
            StatementArguments(resolvable)
        )
    }

    /// One `GROUP BY sessionId` scan: the session count, one cost per session,
    /// and the costliest sessions labeled from their newest row (SQLite takes
    /// bare columns from the `MAX(startTime)` row). Only top-five candidates
    /// decode their label strings.
    static func fetchChartSessionTotals(
        db: Database,
        decodable: (sql: String, arguments: StatementArguments)
    ) throws -> ChartSessionTotals {
        let statement = try db.cachedStatement(sql: """
            SELECT SUM(cost), MAX(startTime), sessionId, projectName, model, provider
            FROM token_usage
            WHERE \(decodable.sql)
            GROUP BY sessionId
            """)
        var costs: [Double] = []
        var outliers: [ChartsSnapshot.OutlierSession] = []
        let cursor = try Row.fetchCursor(statement, arguments: decodable.arguments)
        while let row = try cursor.next() {
            let cost = doubleValue(indexed(row, 0))
            costs.append(cost)
            guard let sessionId = indexed(row, 2) as? String else { continue }
            if outliers.count == ChartSessionTotals.outlierLimit, let floor = outliers.last,
               !ChartSessionTotals.ranksAbove((cost, sessionId), (floor.cost, floor.sessionId)) {
                continue
            }
            guard let projectName = indexed(row, 3) as? String,
                  let model = indexed(row, 4) as? String,
                  let providerRaw = indexed(row, 5) as? String,
                  let provider = AgentProvider.resolve(providerRaw) else {
                continue
            }
            outliers.insert(
                ChartsSnapshot.OutlierSession(
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    provider: provider,
                    cost: cost
                ),
                at: outliers.firstIndex { ChartSessionTotals.ranksAbove((cost, sessionId), ($0.cost, $0.sessionId)) }
                    ?? outliers.endIndex
            )
            if outliers.count > ChartSessionTotals.outlierLimit {
                outliers.removeLast()
            }
        }
        return ChartSessionTotals(count: costs.count, costs: costs, outlierSessions: outliers)
    }

    static func decodeChartFactRow(_ row: Row) -> ChartFactRow? {
        decodeChartFact(row, billedTotalColumn: nil)
    }

    /// `billedTotalColumn` holds an aggregate row's pre-summed billed total;
    /// nil derives it from the row's own token columns.
    private static func decodeChartFact(_ row: Row, billedTotalColumn: Int?) -> ChartFactRow? {
        guard let startTime = OpenBurnBarDatabase.parseDateValue(indexed(row, ChartFactCol.startTime.rawValue)),
              let endTime = OpenBurnBarDatabase.parseDateValue(indexed(row, ChartFactCol.endTime.rawValue)),
              let sessionId = indexed(row, ChartFactCol.sessionId.rawValue) as? String,
              let projectName = indexed(row, ChartFactCol.projectName.rawValue) as? String,
              let model = indexed(row, ChartFactCol.model.rawValue) as? String,
              let providerRaw = indexed(row, ChartFactCol.provider.rawValue) as? String,
              let provider = AgentProvider.resolve(providerRaw) else {
            return nil
        }
        let inputTokens = intValue(indexed(row, ChartFactCol.inputTokens.rawValue))
        let outputTokens = intValue(indexed(row, ChartFactCol.outputTokens.rawValue))
        let cacheCreationTokens = intValue(indexed(row, ChartFactCol.cacheCreationTokens.rawValue))
        let cacheReadTokens = intValue(indexed(row, ChartFactCol.cacheReadTokens.rawValue))
        let reasoningTokens = intValue(indexed(row, ChartFactCol.reasoningTokens.rawValue))
        return ChartFactRow(
            startTime: startTime,
            endTime: endTime,
            cost: doubleValue(indexed(row, ChartFactCol.cost.rawValue)),
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            provider: provider,
            billingKind: (indexed(row, ChartFactCol.billingKind.rawValue) as? String)
                .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown,
            usageSource: (indexed(row, ChartFactCol.usageSource.rawValue) as? String)
                .flatMap(UsageSource.init(rawValue:)) ?? .unknown,
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: billedTotalColumn.map { intValue(indexed(row, $0)) } ?? TokenUsage.billedTotalTokens(
                input: inputTokens,
                output: outputTokens,
                cacheCreation: cacheCreationTokens,
                cacheRead: cacheReadTokens,
                reasoning: reasoningTokens
            ),
            provenanceConfidence: (indexed(row, ChartFactCol.provenanceConfidence.rawValue) as? String)
                .flatMap(UsageProvenanceConfidence.init(rawValue:)) ?? .unknown,
            isRemote: intValue(indexed(row, ChartFactCol.isRemote.rawValue)) != 0
        )
    }

    func fetchChartSessionAnalytics(
        timeRange: TimeRange,
        now: Date,
        calendar: Calendar = .current
    ) async throws -> ChartSessionAnalytics {
        try await dbQueue.read { db in
            try Self.fetchChartSessionAnalytics(
                db: db,
                timeRange: timeRange,
                now: now,
                calendar: calendar
            )
        }
    }

    /// Narrow `token_usage` projection for heatmap / outliers / entropy.
    /// Window membership matches `fetchUsage(in:)` (intersection). Attribution
    /// still clamps `startTime` into the resolved chart range — not exploded
    /// onto every overlapped day.
    static func fetchChartSessionAnalytics(
        db: Database,
        timeRange: TimeRange,
        now: Date,
        calendar: Calendar
    ) throws -> ChartSessionAnalytics {
        let requested = timeRange.dateRange(now: now)
        let predicate = dateRangePredicate(requested)
        let events = try compactMapCachedRows(
            db: db,
            sql: """
                SELECT \(chartSessionSelectColumns.joined(separator: ", "))
                FROM token_usage
                \(predicate.whereSQL)
                ORDER BY startTime DESC
                """,
            arguments: predicate.arguments,
            transform: Self.decodeChartSessionEvent
        )
        let range = ChartsSnapshot.resolvedRange(
            for: timeRange,
            earliestStart: events.map(\.startTime).min(),
            now: now,
            calendar: calendar
        )
        return ChartSessionAnalytics.from(events: events, range: range, calendar: calendar)
    }

    static func decodeChartSessionEvent(_ row: Row) -> ChartSessionAnalytics.Event? {
        guard let startTime = OpenBurnBarDatabase.parseDateValue(indexed(row, ChartSessionCol.startTime.rawValue)),
              let sessionId = indexed(row, ChartSessionCol.sessionId.rawValue) as? String,
              let projectName = indexed(row, ChartSessionCol.projectName.rawValue) as? String,
              let model = indexed(row, ChartSessionCol.model.rawValue) as? String,
              let providerRaw = indexed(row, ChartSessionCol.provider.rawValue) as? String,
              let provider = AgentProvider.resolve(providerRaw) else {
            return nil
        }
        return ChartSessionAnalytics.Event(
            startTime: startTime,
            cost: doubleValue(indexed(row, ChartSessionCol.cost.rawValue)),
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            provider: provider
        )
    }
}
