import Foundation

// MARK: - Types

enum OrgGroupBy: String, CaseIterable, Identifiable {
    case user
    case project
    case credential
    case provider

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: return "User / Seat"
        case .project: return "Project"
        case .credential: return "Credential"
        case .provider: return "Provider"
        }
    }

    var icon: String {
        switch self {
        case .user: return "person.2.fill"
        case .project: return "folder.fill"
        case .credential: return "key.fill"
        case .provider: return "server.rack"
        }
    }
}

struct OrgRollupRow: Identifiable {
    let id = UUID()
    let label: String
    let totalCost: Double
    let totalTokens: Double
    let sessionCount: Int
    let deviceCount: Int
}
