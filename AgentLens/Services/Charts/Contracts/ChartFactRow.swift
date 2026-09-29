import Foundation
import OpenBurnBarKernel

/// Window membership used to split one covering Charts fetch into the selected
/// range and the trailing 31-day heatmap / forecast window.
protocol ChartWindowRow: Sendable {
    var sessionId: String { get }
    func intersects(dateRange: ClosedRange<Date>) -> Bool
}

extension TokenUsage: ChartWindowRow {}

/// Narrow covering-scan row for the Charts page.
///
/// Enough columns to build `ChartsSnapshot` bit-identically to `[TokenUsage]`,
/// without decoding UUIDs, accounts, execution source, or other ledger identity.
struct ChartFactRow: Sendable, Equatable {
    let startTime: Date
    let endTime: Date
    let cost: Double
    let sessionId: String
    let projectName: String
    let model: String
    let provider: AgentProvider
    let billingKind: BurnBarBillingKind
    let usageSource: UsageSource
    let inputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let provenanceConfidence: UsageProvenanceConfidence
    let isRemote: Bool
}

extension ChartFactRow: ChartWindowRow {
    init(_ usage: TokenUsage) {
        startTime = usage.startTime
        endTime = usage.endTime
        cost = usage.cost
        sessionId = usage.sessionId
        projectName = usage.projectName
        model = usage.model
        provider = usage.provider
        billingKind = usage.billingKind
        usageSource = usage.usageSource
        inputTokens = usage.inputTokens
        cacheCreationTokens = usage.cacheCreationTokens
        cacheReadTokens = usage.cacheReadTokens
        reasoningTokens = usage.reasoningTokens
        totalTokens = usage.totalTokens
        provenanceConfidence = usage.provenanceConfidence
        isRemote = usage.isRemote
    }

    func intersects(dateRange: ClosedRange<Date>) -> Bool {
        let s = min(startTime, endTime)
        let e = max(startTime, endTime)
        return s <= dateRange.upperBound && e >= dateRange.lowerBound
    }
}

/// All-time Charts inputs aggregated in SQL (`UsageStore.fetchChartAggregates`).
///
/// Each fact sums the rows sharing a 15-minute UTC slot and every dimension a
/// chart splits by (project, model, provider, billing, source, provenance,
/// remote, 31-day window membership). Every IANA offset in use is a multiple
/// of 15 minutes, so a slot never straddles a local hour or day boundary and
/// the builder buckets a fact exactly where it would bucket each row. The
/// fact count is bounded by elapsed time × active dimensions, not by how many
/// sessions or requests the ledger holds. `sessionId` is empty on facts: the
/// session cards read `sessions`.
struct ChartAggregates: Sendable {
    /// Every slot fact — the all-time window.
    let facts: [ChartFactRow]
    /// Facts whose rows intersect the trailing 31-day window.
    let recentFacts: [ChartFactRow]
    let sessions: ChartSessionTotals
}
