import Foundation
import OpenBurnBarEngine

/// Process-wide RPC counters surfaced on `GET /metrics`.
///
/// Intentionally lock-based (not actor-isolated) so hot RPC paths can increment
/// without awaiting. See `docs/runbooks/slos.md` for SLO probe names.
public enum BurnBarDaemonMetricsCounters {
    private static let lock = NSLock()
    // guarded by `lock`
    private nonisolated(unsafe) static var rpcRequestsTotal = 0
    // guarded by `lock`
    private nonisolated(unsafe) static var rpcErrorsTotal = 0
    // guarded by `lock`
    private nonisolated(unsafe) static var rpcLatencyMsSamples: [Int] = []
    private static let maxLatencySamples = 256

    /// Tri-state listener bind health: `nil` when the gateway has not attempted
    /// to bind, `true` once the socket is ready, `false` when the bind failed
    /// (e.g. the port is already in use). Surfaced on `GET /metrics` so a
    /// "gateway port bound but not serving" condition is visible, not silent.
    ///
    /// `nonisolated(unsafe)`: guarded by `lock`.
    private nonisolated(unsafe) static var gatewayListenerBound: Bool?
    // guarded by `lock`
    private nonisolated(unsafe) static var gatewayListenerErrorMessage: String?

    // Usage-ledger write health (`BurnBarUsageRecorder.recordDurably`), all
    // guarded by `lock`. Spend whose ledger append failed is deferred, not
    // dropped; these make every non-clean write visible on `GET /metrics`.
    private nonisolated(unsafe) static var usageLedgerDeferredTotal = 0
    private nonisolated(unsafe) static var usageLedgerReplayedTotal = 0
    private nonisolated(unsafe) static var usageLedgerRejectedTotal = 0
    private nonisolated(unsafe) static var usageLedgerDroppedTotal = 0
    private nonisolated(unsafe) static var usageLedgerSpoolWriteFailuresTotal = 0
    private nonisolated(unsafe) static var usageLedgerPending = 0

    /// Records that the gateway TCP listener reached the `.ready` state.
    public static func recordGatewayListenerReady() {
        lock.lock()
        gatewayListenerBound = true
        gatewayListenerErrorMessage = nil
        lock.unlock()
    }

    /// Records that the gateway TCP listener failed to bind, with a
    /// human-readable reason (e.g. address-in-use) for operator surfacing.
    public static func recordGatewayListenerFailure(_ message: String) {
        lock.lock()
        gatewayListenerBound = false
        gatewayListenerErrorMessage = message
        lock.unlock()
    }

    /// The most recent gateway listener bind failure message, if the listener
    /// is currently in a failed state. `nil` when unknown or healthy.
    public static func gatewayListenerError() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return gatewayListenerBound == false ? gatewayListenerErrorMessage : nil
    }

    /// `1` when the listener is bound, `0` when it failed to bind. Omitted from
    /// the counters map (returns `nil`) until the gateway attempts to bind.
    public static func gatewayListenerBoundCounter() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let gatewayListenerBound else { return nil }
        return gatewayListenerBound ? 1 : 0
    }

    /// An event whose ledger append failed went to the retry spool;
    /// `dropped` counts spool-overflow evictions of the oldest events.
    public static func recordUsageLedgerDeferred(pending: Int, dropped: Int) {
        lock.lock()
        usageLedgerDeferredTotal &+= 1
        usageLedgerDroppedTotal &+= max(0, dropped)
        usageLedgerPending = max(0, pending)
        lock.unlock()
    }

    public static func recordUsageLedgerReplay(replayed: Int, rejected: Int, pending: Int) {
        lock.lock()
        usageLedgerReplayedTotal &+= max(0, replayed)
        usageLedgerRejectedTotal &+= max(0, rejected)
        usageLedgerPending = max(0, pending)
        lock.unlock()
    }

    /// An event that can never be recorded (invalid, or its idempotency key
    /// belongs to a different event).
    public static func recordUsageLedgerRejected() {
        lock.lock()
        usageLedgerRejectedTotal &+= 1
        lock.unlock()
    }

    public static func recordUsageLedgerSpoolWriteFailure() {
        lock.lock()
        usageLedgerSpoolWriteFailuresTotal &+= 1
        lock.unlock()
    }

    public static func setUsageLedgerPending(_ pending: Int) {
        lock.lock()
        usageLedgerPending = max(0, pending)
        lock.unlock()
    }

    public static func recordRPCRequest() {
        lock.lock()
        rpcRequestsTotal &+= 1
        lock.unlock()
    }

    public static func recordRPCError() {
        lock.lock()
        rpcErrorsTotal &+= 1
        lock.unlock()
    }

    /// Records one RPC round-trip latency sample for p95 SLO probes.
    public static func recordRPCLatency(milliseconds: Int) {
        let clamped = max(0, milliseconds)
        lock.lock()
        rpcLatencyMsSamples.append(clamped)
        if rpcLatencyMsSamples.count > maxLatencySamples {
            rpcLatencyMsSamples.removeFirst(rpcLatencyMsSamples.count - maxLatencySamples)
        }
        lock.unlock()
    }

    public static func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var counters = [
            "rpc_requests_total": rpcRequestsTotal,
            "rpc_errors_total": rpcErrorsTotal,
            "usage_ledger_deferred_total": usageLedgerDeferredTotal,
            "usage_ledger_replayed_total": usageLedgerReplayedTotal,
            "usage_ledger_rejected_total": usageLedgerRejectedTotal,
            "usage_ledger_dropped_total": usageLedgerDroppedTotal,
            "usage_ledger_spool_write_failures_total": usageLedgerSpoolWriteFailuresTotal,
            "usage_ledger_pending": usageLedgerPending
        ]
        if let p95 = percentile(rpcLatencyMsSamples, p: 0.95) {
            counters["rpc_latency_ms_p95"] = p95
        }
        return counters
    }

    private static func percentile(_ values: [Int], p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Double(sorted.count - 1) * p
        let lower = Int(index)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = index - Double(lower)
        let value = Double(sorted[lower]) * (1 - fraction) + Double(sorted[upper]) * fraction
        return Int(value.rounded())
    }

    #if DEBUG
    /// Resets counters for unit tests only.
    public static func _resetForTesting() {
        lock.lock()
        rpcRequestsTotal = 0
        rpcErrorsTotal = 0
        rpcLatencyMsSamples = []
        gatewayListenerBound = nil
        gatewayListenerErrorMessage = nil
        usageLedgerDeferredTotal = 0
        usageLedgerReplayedTotal = 0
        usageLedgerRejectedTotal = 0
        usageLedgerDroppedTotal = 0
        usageLedgerSpoolWriteFailuresTotal = 0
        usageLedgerPending = 0
        lock.unlock()
    }
    #endif
}

/// Loopback metrics snapshot for the HTTP gateway `GET /metrics` stub.
///
/// **Counter contract** (stable names for SLO probes — see `docs/runbooks/slos.md`):
/// - `gateway_enabled` — `1` when the gateway is configured on; `0` when disabled.
/// - `daemon_heartbeat_present` — `1` when the on-disk heartbeat file decodes; else `0`.
/// - `heartbeat_stale` — `1` when heartbeat age exceeds `BurnBarDaemonHeartbeat.defaultStaleThreshold` (20s).
/// - `usage_ledger_pending` — spend events waiting in the retry spool; `> 0`
///   means the usage ledger is failing writes and the meter is behind.
/// - `usage_ledger_deferred_total` / `_replayed_total` — ledger appends that
///   failed and were spooled, and spooled events later recorded.
/// - `usage_ledger_rejected_total` — events that can never be recorded.
/// - `usage_ledger_dropped_total` — spooled events evicted by the spool cap.
/// - `usage_ledger_spool_write_failures_total` — spool rewrites that failed
///   (pending events then live only in memory until the next success).
///
/// Counters are intentionally minimal in Phase 5; expand as `metrics.jsonl` lands.
public struct BurnBarGatewayMetricsSnapshot: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let daemonVersion: String
    public let protocolVersion: Int
    public let uptimeSeconds: Int
    public let heartbeat: BurnBarDaemonHeartbeatSnapshot?
    public let heartbeatStale: Bool
    public let gatewayEnabled: Bool
    public let counters: [String: Int]
    /// Human-readable reason the gateway TCP listener is not bound (e.g. the
    /// port is already in use). `nil` when the listener is healthy or has not
    /// attempted to bind. Lets operators see "8317 down but socket up" instead
    /// of a silent failure.
    public let gatewayListenerError: String?

    public init(
        generatedAt: Date = Date(),
        daemonVersion: String = BurnBarDaemonVersion.current,
        protocolVersion: Int = BurnBarProtocolVersion.current,
        uptimeSeconds: Int,
        heartbeat: BurnBarDaemonHeartbeatSnapshot?,
        heartbeatStale: Bool,
        gatewayEnabled: Bool,
        counters: [String: Int] = [:],
        gatewayListenerError: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.uptimeSeconds = uptimeSeconds
        self.heartbeat = heartbeat
        self.heartbeatStale = heartbeatStale
        self.gatewayEnabled = gatewayEnabled
        self.counters = counters
        self.gatewayListenerError = gatewayListenerError
    }

    public static let processStartDate = Date()

    public static func live(
        gatewayEnabled: Bool
    ) -> BurnBarGatewayMetricsSnapshot {
        let heartbeat = BurnBarDaemonHeartbeat.readSnapshot()
        let heartbeatStale = BurnBarDaemonHeartbeat.isStale(snapshot: heartbeat)
        let uptime = max(0, Int(Date().timeIntervalSince(processStartDate)))
        var counters = [
            "daemon_heartbeat_present": heartbeat == nil ? 0 : 1,
            "gateway_enabled": gatewayEnabled ? 1 : 0,
            "heartbeat_stale": heartbeatStale ? 1 : 0
        ].merging(BurnBarDaemonMetricsCounters.snapshot()) { current, _ in current }
        if let listenerBound = BurnBarDaemonMetricsCounters.gatewayListenerBoundCounter() {
            counters["gateway_listener_bound"] = listenerBound
        }
        return BurnBarGatewayMetricsSnapshot(
            uptimeSeconds: uptime,
            heartbeat: heartbeat,
            heartbeatStale: heartbeatStale,
            gatewayEnabled: gatewayEnabled,
            counters: counters,
            gatewayListenerError: BurnBarDaemonMetricsCounters.gatewayListenerError()
        )
    }
}
