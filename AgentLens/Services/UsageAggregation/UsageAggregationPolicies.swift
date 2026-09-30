import Foundation
import OpenBurnBarLogParsers

enum SummaryEndpointCooldownPolicy {
    static let localEndpointFailureCooldown: TimeInterval = 5 * 60
}

/// Resource bounds for usage-refresh and conversation-indexing parse passes.
///
/// The limits live on `ParserResourceLimits` (`.usageRefresh`,
/// `.conversationIndexing`) so the daemon's local ingestion governs its passes
/// with the same numbers; see the incident sizing note there.
enum ParserResourcePolicy {
    /// Bytes of new (uncached) log content one usage-refresh pass may read.
    static let refreshFileByteBudget = ParserResourceLimits.usageRefreshFileByteBudget
    /// Bytes of new content one conversation-indexing pass may read.
    static let indexingFileByteBudget = ParserResourceLimits.conversationIndexingFileByteBudget
    /// Process physical footprint at which any governed pass hard-aborts.
    /// Generous versus the app's normal few-hundred-MB footprint, but far
    /// below the level that pushes a 64GB machine into swap death.
    static let memoryCeilingBytes = ParserResourceLimits.passMemoryCeilingBytes
    /// Footprint that logs a warning once per pass.
    static let memorySoftLimitBytes = ParserResourceLimits.passMemorySoftLimitBytes

    static func makeRefreshGovernor() -> ParserResourceGovernor {
        makeGovernor(limits: .usageRefresh, label: "usage_refresh")
    }

    static func makeIndexingGovernor() -> ParserResourceGovernor {
        makeGovernor(limits: .conversationIndexing, label: "conversation_indexing")
    }

    private static func makeGovernor(limits: ParserResourceLimits, label: String) -> ParserResourceGovernor {
        ParserResourceGovernor(
            limits: limits,
            onSoftLimit: { footprint in
                AppLogger.parser.notice(
                    "parse_pass_memory_soft_limit",
                    metadata: [
                        "pass": label,
                        "footprint_mb": String(footprint / (1024 * 1024))
                    ]
                )
            }
        )
    }
}

enum ProjectionWorkerPolicy {
    /// Process indexing incrementally to keep UI work responsive. Normal
    /// refreshes stay small; once the queue crosses the stale-insight threshold,
    /// use a wider sweep so rebuild-sized queues drain during the same session.
    static let maxJobsPerPass = 4
    static let catchUpMaxJobsPerPass = ProjectionPipelineRuntimeTuning.defaultSweepMaxJobs * 4
    /// Brief pause between catch-up passes. `runSweep` yields internally while
    /// processing leased jobs, so backlog mode only needs a short handoff delay
    /// before claiming the next batch.
    static let backlogDelayNanoseconds: UInt64 = 20_000_000
    /// Hard cap on automatic consecutive backlog passes. New manual/periodic
    /// refreshes can request another pass, but one request can still drain a
    /// rebuild-sized local queue instead of leaving stale insights for days.
    static let maxContinuousBacklogPasses = 128
    /// Coalesce rapid-fire queue requests.
    static let coalesceDelayNanoseconds: UInt64 = 750_000_000
    /// Avoid rebuilding workflow insights on every tiny pass.
    static let insightRefreshCooldown: TimeInterval = 10
    /// Trim redundant queued conversation jobs when backlog explodes.
    static let backlogCompactionThreshold = 400

    /// Grace horizon before terminal (`completed`/`canceled`) projection jobs are reaped.
    /// The work queue never re-reads terminal rows, so they are pure dead weight that
    /// bloats the table and its indexes forever (the audit measured 99.9% dead rows).
    /// We keep one day so recently-finished rows stay inspectable for idempotency/debugging,
    /// then delete them on the next refresh tick.
    /// Settings can later expose this as a user-tunable retention window.
    static let terminalJobRetention: TimeInterval = 24 * 60 * 60

    static func shouldContinueBacklogProcessing(afterCompletedPasses completedPasses: Int) -> Bool {
        completedPasses < maxContinuousBacklogPasses
    }
}

enum AutoSummaryPolicy {
    /// Keep automatic summaries lightweight so background refreshes do not
    /// churn through entire historical backlogs or oversized prompts.
    static let maxPromptChars = 18_000
    static let maxOutputTokens = 220
    static let maxBatchSize = 8
    static let maxFirstLoadBatchSize = 16
    static let maxConcurrency = 2
    /// Pause summary churn while projection queue is already overloaded.
    static let pauseWhenProjectionQueueExceeds = 300
}
