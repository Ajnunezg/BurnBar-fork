import Foundation

// MARK: - Types

enum OrgGroupBy: String, CaseIterable, Identifiable {
    case user
    case project
    case credential
    case provider

    var id: String { rawValue }
}

struct OrgRollupRow: Identifiable {
    let id = UUID()
    let label: String
    let totalCost: Double
    let totalTokens: Double
    let sessionCount: Int
    let deviceCount: Int
}
