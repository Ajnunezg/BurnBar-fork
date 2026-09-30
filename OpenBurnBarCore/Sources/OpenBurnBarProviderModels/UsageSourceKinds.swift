import Foundation

// Usage-source/provenance enums (3.2: extracted from TokenUsage so provider contracts can reference them without a UsageModels edge).

// MARK: - Usage Provenance Confidence

public enum UsageProvenanceConfidence: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case exact = "exact"
    case derivedExact = "derived_exact"
    case highConfidenceEstimate = "high_confidence_estimate"
    case lowConfidenceEstimate = "low_confidence_estimate"
    case unknown = "unknown"

    public var precedence: Int {
        switch self {
        case .exact: return 4
        case .derivedExact: return 3
        case .highConfidenceEstimate: return 2
        case .lowConfidenceEstimate: return 1
        case .unknown: return 0
        }
    }

    public static func < (lhs: UsageProvenanceConfidence, rhs: UsageProvenanceConfidence) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

// MARK: - Usage Pricing Source

/// Where a usage row's dollar cost came from — independent of how its tokens
/// were counted (`UsageProvenanceMethod`, token confidence).
public enum UsagePricingSource: String, Codable, Hashable, CaseIterable, Sendable {
    /// Priced locally at a rate the bundled catalog lists for the model.
    case catalog
    /// Priced locally at the catalog's default rates because no rate is
    /// listed for the model. An estimate, never exact.
    case fallback
    /// Reported by the source itself (the tool's own log, a provider billing
    /// API, the daemon ledger), not priced locally.
    case reported
    /// Not recorded: rows written before pricing provenance existed.
    case unknown

    /// True when the dollar figure is a default-rate guess.
    public var isEstimated: Bool { self == .fallback }

    /// A row's overall confidence given the confidence of its token counts:
    /// a fallback-priced dollar figure is at best a low-confidence estimate,
    /// however exact the tokens are.
    public func rowConfidence(tokenConfidence: UsageProvenanceConfidence) -> UsageProvenanceConfidence {
        isEstimated ? min(tokenConfidence, .lowConfidenceEstimate) : tokenConfidence
    }
}

// MARK: - Usage Source

public enum UsageSource: String, Codable, Hashable, CaseIterable, Sendable {
    case providerLog = "provider_log"
    case inAppChat = "in_app_chat"
    case cursorBridge = "cursor_bridge"
    case billingAPI = "billing_api"
    case daemon = "daemon"
    case unknown = "unknown"
}

// MARK: - Execution Source

/// The product surface that executed a model request. This is intentionally
/// separate from `UsageSource`, which describes how BurnBar ingested the row.
public enum UsageExecutionSourceKind: String, Codable, Hashable, CaseIterable, Sendable {
    case ide
    case cli
    case desktopApp = "desktop_app"
    case service
    case automation
    case unknown
}
