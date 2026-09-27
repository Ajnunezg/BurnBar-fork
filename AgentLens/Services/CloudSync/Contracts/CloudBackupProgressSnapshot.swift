import Foundation

// MARK: - Manual backup progress (real counters, not simulated)

/// Live snapshot emitted while a manual backup drains pending session logs and chat threads.
struct CloudBackupProgressSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable, Equatable {
        case idle
        case preparing
        case facetBackfill
        case sessionLogs
        case chatThreads
        case complete
        case failed
    }

    var phase: Phase = .idle
    var startedAt: Date?
    var updatedAt: Date = .init()

    var pendingSessionLogs: Int = 0
    var processedSessionLogs: Int = 0
    var uploadedSessionLogs: Int = 0
    var skippedSessionLogs: Int = 0
    var facetRefreshSessionLogs: Int = 0

    var pendingChatThreads: Int = 0
    var processedChatThreads: Int = 0

    var plaintextBytes: Int64 = 0
    var encryptedBytes: Int64 = 0
    var storageUploads: Int = 0
    var firestoreWrites: Int = 0
    var searchIndexCommits: Int = 0

    var currentLabel: String?
    var currentOperation: String?
    var errorMessage: String?

    var totalWorkItems: Int { pendingSessionLogs + pendingChatThreads }

    var completedWorkItems: Int { processedSessionLogs + processedChatThreads }

    var overallFraction: Double {
        guard totalWorkItems > 0 else {
            switch phase {
            case .complete: return 1
            default: return 0
            }
        }
        return min(1, Double(completedWorkItems) / Double(totalWorkItems))
    }

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, updatedAt.timeIntervalSince(startedAt))
    }

    var recordsPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(completedWorkItems) / elapsedSeconds
    }

    var uploadBytesPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(encryptedBytes) / elapsedSeconds
    }

    var phaseTitle: String {
        switch phase {
        case .idle: return "Ready"
        case .preparing: return "Preparing backup"
        case .facetBackfill: return "Refreshing cockpit facets"
        case .sessionLogs: return "Uploading session logs"
        case .chatThreads: return "Syncing chat threads"
        case .complete: return "Backup complete"
        case .failed: return "Backup failed"
        }
    }

    var detailLine: String {
        switch phase {
        case .sessionLogs:
            if pendingSessionLogs == 0 {
                return "No pending session logs."
            }
            return "\(processedSessionLogs) of \(pendingSessionLogs) conversations processed"
        case .chatThreads:
            if pendingChatThreads == 0 {
                return "No chat threads to sync."
            }
            return "\(processedChatThreads) of \(pendingChatThreads) threads synced"
        case .complete:
            return "\(uploadedSessionLogs) uploaded · \(skippedSessionLogs + facetRefreshSessionLogs) already current"
        case .failed:
            return errorMessage ?? "Unknown error"
        default:
            if let currentOperation, !currentOperation.isEmpty {
                return currentOperation
            }
            return phaseTitle
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    static func formatRate(bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(formatBytes(Int64(bytesPerSecond)))/s"
    }

    static func formatRate(recordsPerSecond: Double) -> String {
        guard recordsPerSecond > 0 else { return "—" }
        if recordsPerSecond >= 10 {
            return String(format: "%.0f rec/s", recordsPerSecond)
        }
        return String(format: "%.1f rec/s", recordsPerSecond)
    }
}
