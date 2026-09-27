import Foundation
import OpenBurnBarKernel

struct OpenBurnBarDaemonRuntimePaths: Hashable {
    static let launchAgentLabel = "com.openburnbar.daemon"

    let supportDirectory: URL
    let daemonDirectory: URL
    let frameworksDirectory: URL
    let installedBinaryURL: URL
    let socketURL: URL
    let logURL: URL
    let launchAgentPlistURL: URL

    var socketAuthTokenFileURL: URL {
        supportDirectory.appendingPathComponent("daemon-socket-auth-token", isDirectory: false)
    }

    /// Owner-only copy of the SQLCipher key for LaunchAgent / adhoc Debug
    /// daemons that cannot satisfy the Keychain ACL (`errSecAuthFailed`).
    var databaseEncryptionKeyFileURL: URL {
        supportDirectory.appendingPathComponent(
            "daemon-database-encryption-key",
            isDirectory: false
        )
    }

    var providerConfigURL: URL {
        supportDirectory.appendingPathComponent("provider-config.json", isDirectory: false)
    }

    var usageLedgerURL: URL {
        supportDirectory.appendingPathComponent("usage-events.jsonl", isDirectory: false)
    }

    var controllerActivitySnapshotURL: URL {
        supportDirectory.appendingPathComponent("controller-activity-snapshot.json", isDirectory: false)
    }

    var heartbeatURL: URL {
        daemonDirectory.appendingPathComponent("openburnbar-daemon.heartbeat.json", isDirectory: false)
    }

    /// Atomically replaced sibling of `daemon.fleet.snapshot`. The app reads
    /// this file when the control socket returns an empty or undecodable body
    /// so a live fleet tick is not stranded behind a peer-auth or decode miss.
    var fleetSnapshotFileURL: URL {
        supportDirectory.appendingPathComponent("fleet-snapshot.json", isDirectory: false)
    }

    /// Resolves the daemon's Application Support root, running the hardening
    /// migration first.
    ///
    /// `OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory` does more than hand back a
    /// URL: it migrates legacy support directories into the canonical location,
    /// creates the directory with owner-only (`0o700`) permissions, and
    /// re-enforces those permissions on an existing directory. The daemon's
    /// support tree holds the control socket, provider config (which can carry
    /// routed credentials), the usage ledger, and the installed daemon binary —
    /// so a failure to apply that hardening is a security-relevant degradation,
    /// not a no-op.
    ///
    /// We cannot fail closed by refusing to produce a path (the runtime-paths
    /// value is non-optional and every caller's `.live()` default depends on it),
    /// so we degrade to the canonical, *unhardened* support URL — but we surface
    /// the failure instead of swallowing it, turning a silent permission loss
    /// into an observable `daemon`-category event. Replaces a bare `try?` that
    /// hid migration/permission faults entirely.
    static func resolveSupportDirectory(
        prepare: () throws -> URL,
        fallback: () -> URL,
        logger: AppLogger = .daemon
    ) -> URL {
        do {
            return try prepare()
        } catch {
            logger.error(
                "openburnbar.daemon.runtimePaths.prepareSupportDirectory.failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return fallback()
        }
    }

    static func live(fileManager: FileManager = .default) -> OpenBurnBarDaemonRuntimePaths {
        let supportDirectory = resolveSupportDirectory(
            prepare: { try OpenBurnBarKernel.OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager) },
            fallback: { OpenBurnBarKernel.OpenBurnBarAppPaths.live(fileManager: fileManager).supportDirectory }
        )
        let daemonDirectory = supportDirectory.appendingPathComponent("daemon", isDirectory: true)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser

        return OpenBurnBarDaemonRuntimePaths(
            supportDirectory: supportDirectory,
            daemonDirectory: daemonDirectory,
            frameworksDirectory: supportDirectory.appendingPathComponent("Frameworks", isDirectory: true),
            installedBinaryURL: daemonDirectory.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
            socketURL: supportDirectory.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false),
            logURL: daemonDirectory.appendingPathComponent("openburnbar-daemon.log", isDirectory: false),
            launchAgentPlistURL: homeDirectory
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
        )
    }
}
