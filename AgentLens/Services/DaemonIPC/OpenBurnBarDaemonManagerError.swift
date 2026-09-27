import Foundation

enum OpenBurnBarDaemonManagerError: Error, LocalizedError {
    case daemonBinaryUnavailable
    case daemonBinarySignatureInvalid(path: String, reason: String)
    case daemonResourceBundleUnavailable(expectedPath: String)
    case daemonProjectCodeMemoryResourceUnavailable(expectedPath: String)
    case launchctlFailed(String)
    case timedOutWaitingForHealth(logTail: String?, logFilePath: String)
    case daemonSocketAuthTokenUnavailable
    case emptyResponse
    case rpcError(String)
    /// A `-32004` conflict: the daemon refused a mutation whose precondition
    /// moved (the 2.1c-iii reseal compare-and-swap). Nothing was applied;
    /// the caller re-reads and retries instead of surfacing an error.
    case rpcConflict(String)
    case rpcTimedOut(seconds: Int)
    case lifecycleStepFailed(step: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .daemonBinaryUnavailable:
            return "OpenBurnBarDaemon binary is not available in the current build products."
        case let .daemonBinarySignatureInvalid(path, reason):
            return "OpenBurnBarDaemon binary failed code-signature verification at \(path): \(reason)"
        case .daemonResourceBundleUnavailable(let expectedPath):
            return """
            OpenBurnBarDaemon resources are missing (OpenBurnBarCore_OpenBurnBarCore.bundle \
            and/or OpenBurnBarCore_OpenBurnBarKernel.bundle).
            Expected bundle at: \(expectedPath)
            Rebuild OpenBurnBar and run Install again.
            """
        case .daemonProjectCodeMemoryResourceUnavailable(let expectedPath):
            return """
            OpenBurnBarDaemon Project Code Memory resources are missing (secret-pattern-corpus.json).
            Expected corpus at: \(expectedPath)
            Rebuild OpenBurnBar and run Install again.
            """
        case .launchctlFailed(let message):
            return "launchctl failed: \(message)"
        case .timedOutWaitingForHealth(let logTail, let logFilePath):
            var message = "Timed out waiting for OpenBurnBarDaemon to become healthy."
            if let tail = logTail?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
                message += "\n\n\(tail)"
            } else {
                message += " Rebuild the OpenBurnBar scheme (OpenBurnBarDaemon helper must exist), or check \(logFilePath)."
            }
            return message
        case .daemonSocketAuthTokenUnavailable:
            return "OpenBurnBar couldn't prepare a daemon socket auth token."
        case .emptyResponse:
            return "OpenBurnBarDaemon returned an empty response."
        case .rpcError(let message):
            return "OpenBurnBarDaemon RPC error: \(message)"
        case .rpcConflict(let message):
            return "OpenBurnBarDaemon RPC conflict (retry with a fresh read): \(message)"
        case .rpcTimedOut(let seconds):
            return "OpenBurnBarDaemon RPC timed out after \(seconds) seconds."
        case .lifecycleStepFailed(let step, let underlying):
            return "OpenBurnBarDaemon \(step) failed: \(underlying)"
        }
    }
}
