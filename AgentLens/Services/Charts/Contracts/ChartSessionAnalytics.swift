import Foundation
import OpenBurnBarKernel

/// Heatmap, session outliers, and project entropy for the Charts page.
///
/// These three cards need per-session (or per-event) values rather than the
/// covering `GROUP BY` that feeds burn / provider / model totals. The fold is
/// calendar-local — SQLite `strftime` is UTC — so SQL loads a narrow column
/// projection and this type applies the same clamp + weekday/hour math as
/// `ChartsSnapshot.build`. Production Charts now builds the full snapshot from
/// `ChartFactRow`; this type remains the shared heatmap / outlier / entropy
/// fold and the dedicated SQL twin.
struct ChartSessionAnalytics: Equatable, Sendable {
    let hourWeekdayCost: [[Double]]
    let outlierSessions: [ChartsSnapshot.OutlierSession]
    let projectEntropy: Double

    struct Event: Sendable {
        let startTime: Date
        let cost: Double
        let sessionId: String
        let projectName: String
        let model: String
        let provider: AgentProvider
    }

    static func from(
        rows: [TokenUsage],
        range: ClosedRange<Date>,
        calendar: Calendar
    ) -> ChartSessionAnalytics {
        from(rows: rows.map(ChartFactRow.init), range: range, calendar: calendar)
    }

    static func from(
        rows: [ChartFactRow],
        range: ClosedRange<Date>,
        calendar: Calendar
    ) -> ChartSessionAnalytics {
        from(events: rows.map(Event.init), range: range, calendar: calendar)
    }

    static func from(
        events: [Event],
        range: ClosedRange<Date>,
        calendar: Calendar
    ) -> ChartSessionAnalytics {
        ChartSessionAnalytics(
            hourWeekdayCost: hourWeekdayCost(of: events, in: range, calendar: calendar),
            outlierSessions: ChartSessionTotals(events: events).outlierSessions,
            projectEntropy: projectEntropy(of: events)
        )
    }

    /// Heatmap and project focus read no session identity, so they also fold
    /// the all-time snapshot's SQL-aggregated facts.
    static func hourWeekdayCost(
        of events: [Event],
        in range: ClosedRange<Date>,
        calendar: Calendar
    ) -> [[Double]] {
        let costEvents = events.map {
            (date: ChartsSnapshot.attributionDate(for: $0.startTime, in: range), value: $0.cost)
        }
        return ChartBucketing.hourWeekdayMatrix(events: costEvents, calendar: calendar)
    }

    static func projectEntropy(of events: [Event]) -> Double {
        var projectCosts: [String: Double] = [:]
        for event in events {
            let project = event.projectName.isEmpty ? "Unassigned" : event.projectName
            projectCosts[project, default: 0] += event.cost
        }
        return ChartBucketing.entropyIndex(Array(projectCosts.values))
    }
}

extension ChartSessionAnalytics.Event {
    init(_ row: ChartFactRow) {
        self.init(
            startTime: row.startTime,
            cost: row.cost,
            sessionId: row.sessionId,
            projectName: row.projectName,
            model: row.model,
            provider: row.provider
        )
    }
}

/// The Charts inputs that need per-session values: the session count, one
/// cost per session (histogram + median), and the five costliest sessions.
///
/// Folded from per-row events for bounded windows, or computed by one
/// `GROUP BY sessionId` for the all-time snapshot so session identity never
/// has to ride along with every aggregated fact.
struct ChartSessionTotals: Equatable, Sendable {
    static let outlierLimit = 5

    let count: Int
    let costs: [Double]
    let outlierSessions: [ChartsSnapshot.OutlierSession]

    init(count: Int, costs: [Double], outlierSessions: [ChartsSnapshot.OutlierSession]) {
        self.count = count
        self.costs = costs
        self.outlierSessions = outlierSessions
    }

    /// Costliest first; equal costs order by session id, so a tie ranks the
    /// same in both folds and in every process (dictionary order is seeded).
    static func ranksAbove(_ lhs: (cost: Double, sessionId: String), _ rhs: (cost: Double, sessionId: String)) -> Bool {
        lhs.cost != rhs.cost ? lhs.cost > rhs.cost : lhs.sessionId < rhs.sessionId
    }

    /// A session's label comes from its first event — the newest one under the
    /// chart scan's `startTime DESC` order.
    init(events: [ChartSessionAnalytics.Event]) {
        var sessionCosts: [String: Double] = [:]
        var sessionMeta: [String: (project: String, model: String, provider: AgentProvider)] = [:]
        for event in events {
            sessionCosts[event.sessionId, default: 0] += event.cost
            if sessionMeta[event.sessionId] == nil {
                sessionMeta[event.sessionId] = (event.projectName, event.model, event.provider)
            }
        }
        self.init(
            count: sessionCosts.count,
            costs: Array(sessionCosts.values),
            outlierSessions: sessionCosts
                .sorted { Self.ranksAbove(($0.value, $0.key), ($1.value, $1.key)) }
                .prefix(Self.outlierLimit)
                .compactMap { entry -> ChartsSnapshot.OutlierSession? in
                    guard let meta = sessionMeta[entry.key] else { return nil }
                    return ChartsSnapshot.OutlierSession(
                        sessionId: entry.key,
                        projectName: meta.project,
                        model: meta.model,
                        provider: meta.provider,
                        cost: entry.value
                    )
                }
        )
    }
}
