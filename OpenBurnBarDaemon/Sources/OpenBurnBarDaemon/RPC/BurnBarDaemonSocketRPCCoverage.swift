import OpenBurnBarEngine
import Foundation

/// Canonical mapping of socket RPC methods to daemon handler domains.
/// `BurnBarDaemonServer.responseData` routes through `domain(for:)`, and the IPC
/// canon generator and the domain-ceiling gate parse these `Set` literals, so keep
/// each domain a single `static let <name>: Set<BurnBarRPCMethod> = [...]`.
enum BurnBarDaemonSocketRPCCoverage {
    static let auth: Set<BurnBarRPCMethod> = [
        .linuxAuthStatus,
        .linuxAuthBegin,
        .linuxAuthCancel,
        .linuxAuthRotateIdentity,
        .linuxAuthSignOut,
        .linuxAccountCloudDataExport,
        .linuxAccountCloudDataDelete,
        .linuxTrustedDeviceList,
        .linuxTrustedDeviceApprove,
        .linuxTrustedDeviceRevoke,
        .linuxCloudSyncStatus,
        .linuxCloudSyncPolicyUpdate,
        .linuxCloudSyncRun
    ]

    static let lifecycle: Set<BurnBarRPCMethod> = [
        .health,
        .catalog,
        .authBootstrap,
        .linuxOnboardingSnapshot
    ]

    static let config: Set<BurnBarRPCMethod> = [
        .configGet,
        .configUpdate,
        .textExpansionGet,
        .textExpansionUpsert,
        .textExpansionDelete,
        .textExpansionConsentUpdate,
        .textExpansionEngineStatus,
        .textExpansionEngineStart,
        .textExpansionEngineStop,
        .textExpansionEngineExpand,
        .linuxOnboardingAction,
        .linuxOnboardingReset,
        .providerCredentialSlotUpsert,
        .providerCredentialSlotRemove,
        .providerModelVariantUpsert,
        .providerModelVariantRemove,
        .providerModelAliasUpsert,
        .providerModelAliasRemove,
        .providerCustomModelUpsert,
        .providerCustomModelRemove,
        .providerModelDisplayNameSet,
        .providerModelDisplayNameClear
    ]

    /// Linux data-rights lane. Its own domain because it has its own handler
    /// (`handleLinuxPrivacyRPC`) and answers `methodNotFound` on macOS.
    static let privacy: Set<BurnBarRPCMethod> = [
        .linuxPrivacyInventory,
        .linuxPrivacyDeletionPreview,
        .linuxPrivacyDeletionExecute,
        .linuxPrivacyExport,
        .linuxPrivacyRetentionStatus,
        .linuxPrivacyRetentionApply
    ]

    static let usage: Set<BurnBarRPCMethod> = [
        .usageRecord,
        .usageRecent,
        .usageProjection,
        .usageRecount,
        .usageHistory,
        .usageInsights
    ]

    static let chat: Set<BurnBarRPCMethod> = [
        .chatThreadList,
        .chatThreadGet,
        .chatMessageAppend,
        .chatThreadCreate
    ]

    static let observability: Set<BurnBarRPCMethod> = [
        .proxyRouteLogRecent,
        .proxyRouteLogClear,
        .quotaSignalsRecent,
        .quotaSignalsClear,
        .perfMeasure
    ]

    static let membership: Set<BurnBarRPCMethod> = [
        .membershipStatus,
        .membershipCheckoutURL,
        .membershipPortalURL,
        .membershipRestore
    ]

    static let tooling: Set<BurnBarRPCMethod> = [
        .connectorPlaneGet,
        .connectorConfigUpdate,
        .connectorAction,
        .browserToolingGet,
        .browserToolingUpdate,
        .browserAction
    ]

    static let computerUse: Set<BurnBarRPCMethod> = [
        .computerUseCapabilityStateUpdate,
        .computerUseSessionGrantReadiness,
        .computerUseSessionGrantAcquire,
        .computerUseSessionGrantStatus,
        .computerUseSessionStart,
        .computerUseInvoke,
        .computerUseApprovalPending,
        .computerUseApprovalRespond,
        .computerUsePanicHalt,
        .computerUseAuditExport,
        .phoneControlPinProvision
    ]

    static let media: Set<BurnBarRPCMethod> = [
        .daemonMediaSessionState,
        .daemonMediaCallAccept,
        .daemonMediaCallDecline,
        .daemonMediaCallEnd,
        .daemonMediaCapabilityGet,
        .daemonMediaStatus,
        .daemonMediaFileOfferList,
        .daemonMediaFileAccept,
        .daemonMediaFileDecline,
        .daemonMediaFileSend
    ]

    static let missionControl: Set<BurnBarRPCMethod> = [
        .controllerSummary,
        .controllerRuntimeSnapshot,
        .controllerProjectsList,
        .controllerProjectGet,
        .controllerProjectUpsert,
        .controllerProjectDelete,
        .controllerProjectReassign,
        .reviewRunRecord,
        .questionCreate,
        .questionGet,
        .questionsList,
        .questionAnswer,
        .followupCreate,
        .followupsList,
        .followupDone,
        .followupSnooze,
        .followupCalendar,
        .missionCreate,
        .missionsList,
        .missionGet,
        .missionHealth,
        .missionApprove,
        .missionCancel,
        .missionDispatchPacket,
        .missionRecordResult,
        .missionAuthorizeRemote,
        .notificationConfigGet,
        .notificationConfigUpdate,
        .notificationHealth,
        .notificationCommand,
        .simulatorRun,
        .simulatorList,
        .simulatorReplay,
        .projectionRebuild
    ]

    static let client: Set<BurnBarRPCMethod> = [
        .clientAttach,
        .clientClaimControl,
        .clientDetach
    ]

    static let runWorkspaceApproval: Set<BurnBarRPCMethod> = [
        .runCreate,
        .runList,
        .runGet,
        .runPoll,
        .runCancel,
        .runRetry,
        .runResume,
        .subscriptionStart,
        .subscriptionResume,
        .subscriptionStop,
        .workspaceExecuteTool,
        .workspaceToolResult,
        .approvalRespond
    ]

    static let search: Set<BurnBarRPCMethod> = [
        .searchQuery,
        .searchSQL,
        .searchVectorSnapshotUpsert,
        .searchIndexApply
    ]

    static let switcher: Set<BurnBarRPCMethod> = [
        .switcherActiveProfileApply
    ]

    static let memory: Set<BurnBarRPCMethod> = [
        .memoryRemember,
        .memoryRecall,
        .memoryReviewStatus,
        .memoryForget,
        .memoryAuditTrail,
        .memoryAnalytics,
        .memoryModelPolicy,
        .memorySyncInboxList,
        .memorySyncInboxAck,
        .memorySnapshotUpsert,
        .memorySnapshotDelete,
        .memorySnapshotDeleteAll,
        .memoryAuthorityApply
    ]

    static let code: Set<BurnBarRPCMethod> = [
        .codeIndexProject,
        .codeWatchProject,
        .codeSearch,
        .codeContextPack,
        .codeGetSymbol,
        .codeFindReferences,
        .codeCallGraph,
        .codeDiagnostics,
        .codeIndexStatus,
        .codeExplore,
        .codeOpsDiagnostics,
        .codeDatabaseSnapshot,
        .codeDatabaseRestore
    ]

    static let databaseRecovery: Set<BurnBarRPCMethod> = [
        .databaseRecoveryStatus,
        .databaseRecoveryBundleExport,
        .databaseRecoveryBundleImport
    ]

    static let fleet: Set<BurnBarRPCMethod> = [
        .fleetSnapshot,
        .fleetOrchestratorGet,
        .fleetOrchestratorSet,
        .fleetDirectiveRecord
    ]

    /// War Room, the Flame. Kept separate from `fleet` because the two answer
    /// different questions: `fleet` reports what the agents on this machine are
    /// doing, `warRoom` decides which machine should do a thing next.
    static let warRoom: Set<BurnBarRPCMethod> = [
        .warFlameRoute,
        .warFlameDistillList,
        .warFlameDistillSettle
    ]

    static let inbox: Set<BurnBarRPCMethod> = [
        .inboxList,
        .inboxGet,
        .inboxRunsRecent,
        .inboxConfigGet,
        .inboxConfigUpdate,
        .inboxRunNow,
        .inboxThreadGet,
        .inboxReply,
        .inboxPlansList,
        .inboxPlansGet,
        .inboxPlansAccept,
        .inboxPlansUpdateStep,
        .inboxPlansGrade,
        .inboxMemoryExport
    ]

    static var allHandled: Set<BurnBarRPCMethod> {
        BurnBarDaemonRPCDomain.allCases.reduce(into: Set<BurnBarRPCMethod>()) { $0.formUnion($1.methods) }
    }

    /// Built once: every RPC resolves its domain on the hot path.
    private static let domainByMethod: [BurnBarRPCMethod: BurnBarDaemonRPCDomain] = {
        var map: [BurnBarRPCMethod: BurnBarDaemonRPCDomain] = [:]
        for domain in BurnBarDaemonRPCDomain.allCases {
            for method in domain.methods {
                map[method] = domain
            }
        }
        return map
    }()

    static func domain(for method: BurnBarRPCMethod) -> BurnBarDaemonRPCDomain? {
        domainByMethod[method]
    }
}

/// The daemon's RPC surface, partitioned by the handler that owns each method.
///
/// The socket router dispatches on this type, not on individual methods, so a
/// method only becomes reachable once it is assigned to exactly one domain. The
/// raw value is the wire-level domain name emitted into the BurnBarRPC IPC canon
/// (`tools/ipc/generate-burnbarrpc-canon.mjs`). Per-domain method ceilings live
/// in `budgets/daemon-rpc-domain-ceiling.json` and are enforced by
/// `scripts/debt/check-rpc-domain-ceiling.sh`.
enum BurnBarDaemonRPCDomain: String, CaseIterable, Sendable {
    case auth
    case lifecycle
    case config
    case privacy
    case usage
    case chat
    case observability
    case membership
    case tooling
    case computerUse = "computer_use"
    case media
    case missionControl = "mission_control"
    case client
    case runWorkspaceApproval = "run_workspace_approval"
    case search
    case switcher
    case memory
    case code
    case databaseRecovery = "database_recovery"
    case inbox
    case fleet
    case warRoom = "war_room"

    var methods: Set<BurnBarRPCMethod> {
        switch self {
        case .auth: BurnBarDaemonSocketRPCCoverage.auth
        case .lifecycle: BurnBarDaemonSocketRPCCoverage.lifecycle
        case .config: BurnBarDaemonSocketRPCCoverage.config
        case .privacy: BurnBarDaemonSocketRPCCoverage.privacy
        case .usage: BurnBarDaemonSocketRPCCoverage.usage
        case .chat: BurnBarDaemonSocketRPCCoverage.chat
        case .observability: BurnBarDaemonSocketRPCCoverage.observability
        case .membership: BurnBarDaemonSocketRPCCoverage.membership
        case .tooling: BurnBarDaemonSocketRPCCoverage.tooling
        case .computerUse: BurnBarDaemonSocketRPCCoverage.computerUse
        case .media: BurnBarDaemonSocketRPCCoverage.media
        case .missionControl: BurnBarDaemonSocketRPCCoverage.missionControl
        case .client: BurnBarDaemonSocketRPCCoverage.client
        case .runWorkspaceApproval: BurnBarDaemonSocketRPCCoverage.runWorkspaceApproval
        case .search: BurnBarDaemonSocketRPCCoverage.search
        case .switcher: BurnBarDaemonSocketRPCCoverage.switcher
        case .memory: BurnBarDaemonSocketRPCCoverage.memory
        case .code: BurnBarDaemonSocketRPCCoverage.code
        case .databaseRecovery: BurnBarDaemonSocketRPCCoverage.databaseRecovery
        case .inbox: BurnBarDaemonSocketRPCCoverage.inbox
        case .fleet: BurnBarDaemonSocketRPCCoverage.fleet
        case .warRoom: BurnBarDaemonSocketRPCCoverage.warRoom
        }
    }
}
