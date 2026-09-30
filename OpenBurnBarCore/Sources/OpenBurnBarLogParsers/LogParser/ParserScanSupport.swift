import Foundation
import OpenBurnBarParserSupport

// Keep the parser module's historical public surface stable while the shared
// read gate, options, and scan primitives live in the lower-level support leaf.
public typealias LogParseOptions = OpenBurnBarParserSupport.LogParseOptions
public typealias ParserFileReadGate = OpenBurnBarParserSupport.ParserFileReadGate
public typealias ParserDiscoveredFile = OpenBurnBarParserSupport.ParserDiscoveredFile
public typealias ParserFileDiscoveryTracker = OpenBurnBarParserSupport.ParserFileDiscoveryTracker
public typealias ParserDeferredReason = OpenBurnBarParserSupport.ParserDeferredReason
public typealias ParserPassMetricSnapshot = OpenBurnBarParserSupport.ParserPassMetricSnapshot
public typealias ParserPassMetrics = OpenBurnBarParserSupport.ParserPassMetrics
public typealias ParserResourceLimits = OpenBurnBarParserSupport.ParserResourceLimits
public typealias ParserResourceExceeded = OpenBurnBarParserSupport.ParserResourceExceeded
public typealias ParserResourceGovernor = OpenBurnBarParserSupport.ParserResourceGovernor
public typealias ParserScanDigest = OpenBurnBarParserSupport.ParserScanDigest

@inlinable
public func parserAutoReleasePool<Result>(
    _ body: () throws -> Result
) rethrows -> Result {
    try OpenBurnBarParserSupport.parserAutoReleasePool(body)
}

// Pass presets sit above the support leaf, which is at its target size ceiling.
extension ParserResourceLimits {
    // Sized for the 2026-07-16 incident corpus (21GB of Codex rollouts, 4.2GB
    // of Claude transcripts on one machine): a cold cache converges over a
    // handful of ticks instead of one unbounded 80-minute, 25GB pass, and
    // steady-state ticks (incremental tail scans) never come near the budget.
    // Shared by the Mac app (`ParserResourcePolicy`) and the daemon's local
    // ingestion so neither usage path can drift back to an ungoverned pass.

    /// Bytes of new (uncached) log content one usage-refresh pass may read.
    public static let usageRefreshFileByteBudget: Int64 = 256 * 1024 * 1024
    /// Bytes of new content one conversation-indexing pass may read — bodies
    /// re-read whole changed files, so this pass gets more headroom.
    public static let conversationIndexingFileByteBudget: Int64 = 512 * 1024 * 1024
    /// Process physical footprint at which any governed pass hard-aborts.
    public static let passMemoryCeilingBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// Footprint that logs a warning once per pass.
    public static let passMemorySoftLimitBytes: Int64 = 1536 * 1024 * 1024

    public static let usageRefresh = ParserResourceLimits(
        fileByteBudget: usageRefreshFileByteBudget,
        memoryCeilingBytes: passMemoryCeilingBytes,
        memorySoftLimitBytes: passMemorySoftLimitBytes
    )

    public static let conversationIndexing = ParserResourceLimits(
        fileByteBudget: conversationIndexingFileByteBudget,
        memoryCeilingBytes: passMemoryCeilingBytes,
        memorySoftLimitBytes: passMemorySoftLimitBytes
    )
}
