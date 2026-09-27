import Foundation

// MARK: - Backup plan limits + usage

/// User-facing backup limits. Values are intentionally expressed as product
/// entitlements, not infrastructure costs.
struct CloudBackupPlanLimits: Equatable, Sendable {
    static let defaultIncludedTranscriptBytes: Int64 = 250 * 1024 * 1024
    static let defaultIncludedSearchIndexBytes: Int64 = 1024 * 1024 * 1024
    static let defaultMaxConversations = 50_000

    static let standard = CloudBackupPlanLimits(
        transcriptByteLimit: defaultIncludedTranscriptBytes,
        searchableIndexByteLimit: defaultIncludedSearchIndexBytes,
        conversationLimit: defaultMaxConversations
    )

    var transcriptByteLimit: Int64
    var searchableIndexByteLimit: Int64
    var conversationLimit: Int
}

/// Local, pre-upload estimate used to present backup usage and block uploads
/// before a user exceeds their included product limits.
struct CloudBackupUsageSnapshot: Equatable, Sendable {
    static let searchChunkMaxBytes = 16_000
    static let perConversationEnvelopeBytes: Int64 = 512
    static let estimatedIndexBytesPerChunk: Int64 = 24 * 1024

    var conversationCount: Int
    var pendingConversationCount: Int
    var rawTranscriptBytes: Int64
    var pendingRawTranscriptBytes: Int64
    var estimatedSearchIndexBytes: Int64
    var pendingEstimatedSearchIndexBytes: Int64
    var searchChunkCount: Int
    var pendingSearchChunkCount: Int
    var limits: CloudBackupPlanLimits

    var transcriptUsageFraction: Double {
        fraction(rawTranscriptBytes, of: limits.transcriptByteLimit)
    }

    var searchIndexUsageFraction: Double {
        fraction(estimatedSearchIndexBytes, of: limits.searchableIndexByteLimit)
    }

    var isWithinLimits: Bool {
        blockingReason == nil
    }

    var blockingReason: String? {
        if conversationCount > limits.conversationLimit {
            return "Backup limit reached: \(conversationCount) conversations of \(limits.conversationLimit) included."
        }
        if rawTranscriptBytes > limits.transcriptByteLimit {
            return "Backup storage limit reached: \(Self.formatBytes(rawTranscriptBytes)) of \(Self.formatBytes(limits.transcriptByteLimit)) included."
        }
        if estimatedSearchIndexBytes > limits.searchableIndexByteLimit {
            return "Searchable backup limit reached: \(Self.formatBytes(estimatedSearchIndexBytes)) of \(Self.formatBytes(limits.searchableIndexByteLimit)) included."
        }
        return nil
    }

    static func estimateSearchIndexBytes(rawTranscriptBytes: Int64, searchChunkCount: Int) -> Int64 {
        rawTranscriptBytes + (Int64(max(0, searchChunkCount)) * estimatedIndexBytesPerChunk)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        CloudBackupProgressSnapshot.formatBytes(bytes)
    }

    private func fraction(_ numerator: Int64, of denominator: Int64) -> Double {
        guard denominator > 0 else { return 1 }
        return min(1, max(0, Double(numerator) / Double(denominator)))
    }
}
