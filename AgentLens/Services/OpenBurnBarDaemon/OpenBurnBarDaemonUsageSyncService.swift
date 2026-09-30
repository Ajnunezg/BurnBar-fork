import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel
import OpenBurnBarLogParsers
import OpenBurnBarUI

struct OpenBurnBarDaemonProviderConfiguration: Equatable, Identifiable {

    struct CredentialSlot: Equatable, Identifiable {
        let slotID: String
        let label: String
        let isEnabled: Bool
        let status: BurnBarProviderCredentialSlotStatus
        let cooldownUntil: Date?
        let lastSelectedAt: Date?
        let lastQuotaRemainingPercent: Double?
        let lastQuotaResetsAt: Date?
        let lastStatusMessage: String?
        var updatedAt = Date()

        var id: String { slotID }
    }

    let providerID: String
    let provider: AgentProvider?
    let displayName: String
    let isEnabled: Bool
    let baseURL: String
    let preferredModelIDs: [String]
    let preferredCredentialSlotID: String?
    let credentialSlots: [CredentialSlot]
    let ollamaEndpoints: [BurnBarOllamaEndpointConfig]
    let customModels: [BurnBarCustomModel]

    init(
        providerID: String,
        provider: AgentProvider?,
        displayName: String,
        isEnabled: Bool,
        baseURL: String,
        preferredModelIDs: [String],
        preferredCredentialSlotID: String?,
        credentialSlots: [CredentialSlot],
        ollamaEndpoints: [BurnBarOllamaEndpointConfig] = [],
        customModels: [BurnBarCustomModel] = []
    ) {
        self.providerID = providerID
        self.provider = provider
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.preferredModelIDs = preferredModelIDs
        self.preferredCredentialSlotID = preferredCredentialSlotID
        self.credentialSlots = credentialSlots
        self.ollamaEndpoints = ollamaEndpoints
        self.customModels = customModels
    }

    var id: String { providerID }
}

extension OpenBurnBarDaemonProviderConfiguration.CredentialSlot {
    func effectiveRoutingStatus(now: Date = Date()) -> BurnBarProviderCredentialSlotStatus {
        BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(
            status: status,
            isEnabled: isEnabled,
            cooldownUntil: cooldownUntil,
            lastQuotaRemainingPercent: lastQuotaRemainingPercent,
            lastQuotaResetsAt: lastQuotaResetsAt,
            lastStatusMessage: lastStatusMessage,
            updatedAt: updatedAt,
            now: now
        )
    }

    func canAttemptRoute(hasCredential: Bool = true, now: Date = Date()) -> Bool {
        BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(
            status: status,
            isEnabled: isEnabled,
            hasCredential: hasCredential,
            cooldownUntil: cooldownUntil,
            lastQuotaRemainingPercent: lastQuotaRemainingPercent,
            lastQuotaResetsAt: lastQuotaResetsAt,
            lastStatusMessage: lastStatusMessage,
            updatedAt: updatedAt,
            now: now
        )
    }
}

struct OpenBurnBarDaemonRecentUsage: Equatable, Identifiable {
    let idempotencyKey: String
    let provider: AgentProvider
    let model: String
    let totalTokens: Int
    let cost: Double
    let recordedAt: Date

    var id: String { idempotencyKey }
}

struct OpenBurnBarDaemonRuntimeSnapshot: Equatable {
    static let empty = OpenBurnBarDaemonRuntimeSnapshot(
        providerConfigurations: [],
        recentUsage: [],
        ledgerRecordCount: 0
    )

    let providerConfigurations: [OpenBurnBarDaemonProviderConfiguration]
    let recentUsage: [OpenBurnBarDaemonRecentUsage]
    let ledgerRecordCount: Int
    /// Rows whose ledger sums changed since the last import, with full totals.
    let importedUsages: [TokenUsage]
    /// Rows the retired RPC import keyed differently for the same events;
    /// deleted when `importedUsages` is written.
    let supersededUsages: [DaemonUsageLedgerImporter.SupersededRow]

    init(
        providerConfigurations: [OpenBurnBarDaemonProviderConfiguration],
        recentUsage: [OpenBurnBarDaemonRecentUsage],
        ledgerRecordCount: Int,
        importedUsages: [TokenUsage] = [],
        supersededUsages: [DaemonUsageLedgerImporter.SupersededRow] = []
    ) {
        self.providerConfigurations = providerConfigurations
        self.recentUsage = recentUsage
        self.ledgerRecordCount = ledgerRecordCount
        self.importedUsages = importedUsages
        self.supersededUsages = supersededUsages
    }
}

/// Daemon spend reaches `token_usage` one way: the append-only ledger file,
/// read by watermark through `DaemonUsageLedgerImporter` (one identity per
/// event — its idempotency key — and summed rows). The `daemon.usage.recent`
/// RPC only feeds the recent-usage list; importing its newest-20 window as
/// well collapsed same-session requests and double counted against the file.
final class OpenBurnBarDaemonUsageSyncService {
    private let paths: OpenBurnBarDaemonRuntimePaths
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let ledgerImporter = Locked(DaemonUsageLedgerImporter())

    init(
        paths: OpenBurnBarDaemonRuntimePaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    /// Local fallback: provider configuration and recent usage come from the
    /// daemon's files.
    @discardableResult
    func refreshState(
        insertUsages: (([TokenUsage]) throws -> Void)? = nil,
        refreshUsageCache: (() -> Void)? = nil
    ) -> OpenBurnBarDaemonRuntimeSnapshot {
        let pass = importLedger(insertUsages: insertUsages, refreshUsageCache: refreshUsageCache)
        return OpenBurnBarDaemonRuntimeSnapshot(
            providerConfigurations: providerConfigurations(from: loadProviderConfigurationSnapshot()),
            recentUsage: pass.recentRecords.compactMap { recentUsage(from: $0) },
            ledgerRecordCount: pass.recordCount,
            importedUsages: pass.changedRows,
            supersededUsages: pass.supersededRows
        )
    }

    /// Healthy daemon: provider configuration and recent usage come over RPC;
    /// spend is still imported from the ledger.
    @discardableResult
    func runtimeSnapshot(
        from configSnapshot: BurnBarProviderConfigurationSnapshot,
        usageEvents: [BurnBarUsageEvent],
        insertUsages: (([TokenUsage]) throws -> Void)? = nil,
        refreshUsageCache: (() -> Void)? = nil
    ) -> OpenBurnBarDaemonRuntimeSnapshot {
        let pass = importLedger(insertUsages: insertUsages, refreshUsageCache: refreshUsageCache)
        return OpenBurnBarDaemonRuntimeSnapshot(
            providerConfigurations: providerConfigurations(from: configSnapshot),
            recentUsage: Array(usageEvents
                .compactMap { recentUsage(from: $0) }
                .sorted { $0.recordedAt > $1.recordedAt }
                .prefix(DaemonUsageLedgerImporter.recentLimit)),
            ledgerRecordCount: pass.recordCount,
            importedUsages: pass.changedRows,
            supersededUsages: pass.supersededRows
        )
    }

    /// The last pass's rows were not stored: rebuild every row next pass.
    func invalidateLedgerImport() {
        ledgerImporter.withLock { $0.invalidate() }
    }

    private func importLedger(
        insertUsages: (([TokenUsage]) throws -> Void)?,
        refreshUsageCache: (() -> Void)?
    ) -> DaemonUsageLedgerImporter.Pass {
        let ledgerURL = paths.usageLedgerURL
        let pass = ledgerImporter.withLock { $0.importNewRecords(from: ledgerURL) }
        if let insertUsages, !pass.changedRows.isEmpty {
            do {
                try insertUsages(pass.changedRows)
                refreshUsageCache?()
            } catch {
                invalidateLedgerImport()
                AppLogger.dataStore.silentFailure("insertUsages(daemonLedger)", error: error)
            }
        }
        return pass
    }

    private func loadProviderConfigurationSnapshot() -> BurnBarProviderConfigurationSnapshot {
        guard fileManager.fileExists(atPath: paths.providerConfigURL.path) else {
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        guard let data = try? Data(contentsOf: paths.providerConfigURL) else { // try?-ok(best-effort config read)
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        if let directSnapshot = try? decoder.decode(BurnBarProviderConfigurationSnapshot.self, from: data) { // try?-ok(optional snapshot decode)
            return directSnapshot
        }

        guard let snapshot = try? decoder.decode(StoredProviderConfigurationSnapshot.self, from: data) else { // try?-ok(optional legacy decode)
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        return BurnBarProviderConfigurationSnapshot(
            providers: snapshot.providers.map { settings in
                BurnBarProviderSettings(
                    providerID: settings.providerID,
                    isEnabled: settings.isEnabled,
                    baseURL: settings.baseURL,
                    preferredModelIDs: settings.preferredModelIDs,
                    preferredCredentialSlotID: settings.preferredCredentialSlotID,
                    credentialSlots: settings.credentialSlots
                )
            }
        )
    }

    private func providerConfigurations(
        from snapshot: BurnBarProviderConfigurationSnapshot
    ) -> [OpenBurnBarDaemonProviderConfiguration] {
        snapshot.providers.map { settings in
            let provider = agentProvider(for: settings.providerID)
            let catalogName = BurnBarCatalogLoader.bundledCatalog.provider(id: settings.providerID)?.displayName
                ?? settings.providerID.capitalized
            return OpenBurnBarDaemonProviderConfiguration(
                providerID: settings.providerID,
                provider: provider,
                displayName: catalogName,
                isEnabled: settings.isEnabled,
                baseURL: settings.baseURL,
                preferredModelIDs: settings.preferredModelIDs,
                preferredCredentialSlotID: settings.preferredCredentialSlotID,
                credentialSlots: settings.credentialSlots.map { slot in
                        OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                            slotID: slot.slotID,
                            label: slot.label,
                            isEnabled: slot.isEnabled,
                            status: slot.status,
                            cooldownUntil: slot.cooldownUntil,
                            lastSelectedAt: slot.lastSelectedAt,
                            lastQuotaRemainingPercent: slot.lastQuotaRemainingPercent,
                            lastQuotaResetsAt: slot.lastQuotaResetsAt,
                            lastStatusMessage: slot.lastStatusMessage,
                            updatedAt: slot.updatedAt
                        )
                    },
                ollamaEndpoints: settings.ollamaEndpoints,
                customModels: settings.customModels
                )
            }
            .sorted { providerSortOrder($0.provider) < providerSortOrder($1.provider) }
    }

    private func recentUsage(from event: BurnBarUsageEvent) -> OpenBurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: event.providerID) else {
            return nil
        }

        return OpenBurnBarDaemonRecentUsage(
            idempotencyKey: event.runID?.rawValue ?? "\(event.providerID)|\(event.modelID)|\(event.recordedAt.timeIntervalSince1970)",
            provider: provider,
            model: event.modelID,
            totalTokens: event.inputTokens + event.outputTokens + event.cacheCreationTokens + event.cacheReadTokens,
            cost: event.cost,
            recordedAt: event.recordedAt
        )
    }

    private func recentUsage(from record: DaemonUsageLedgerImporter.LedgerRecord) -> OpenBurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: record.event.providerID) else {
            return nil
        }

        return OpenBurnBarDaemonRecentUsage(
            idempotencyKey: record.idempotencyKey,
            provider: provider,
            model: record.event.modelID,
            totalTokens: record.event.inputTokens + record.event.outputTokens + record.event.cacheCreationTokens + record.event.cacheReadTokens,
            cost: record.event.cost,
            recordedAt: record.event.recordedAt
        )
    }

    private func agentProvider(for providerID: String) -> AgentProvider? {
        let normalized = ProviderID.normalize(providerID)
        return AgentProvider.fromProviderID(ProviderID(rawValue: normalized))
            ?? AgentProvider.fromCatalogProviderID(normalized)
    }

    private func providerSortOrder(_ provider: AgentProvider?) -> Int {
        switch provider {
        case .zai:
            return 0
        case .minimax:
            return 1
        default:
            return 2
        }
    }
}

struct StoredProviderConfigurationSnapshot: Codable {
    let providers: [StoredProviderSettings]
}

struct StoredProviderSettings: Codable {
    let providerID: String
    let isEnabled: Bool
    let baseURL: String
    let preferredModelIDs: [String]
    let preferredCredentialSlotID: String?
    let credentialSlots: [BurnBarProviderCredentialSlot]

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isEnabled
        case baseURL
        case preferredModelIDs
        case preferredCredentialSlotID
        case credentialSlots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        preferredModelIDs = try container.decode([String].self, forKey: .preferredModelIDs)
        preferredCredentialSlotID = try container.decodeIfPresent(String.self, forKey: .preferredCredentialSlotID)
        credentialSlots = try container.decodeIfPresent([BurnBarProviderCredentialSlot].self, forKey: .credentialSlots) ?? []
    }
}
