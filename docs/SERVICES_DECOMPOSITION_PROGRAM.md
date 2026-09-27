# AgentLens/Services decomposition program

**Status:** Wave 0 (fitness gate) and Wave 1 (persistence becomes a leaf) landed together.
Waves 2–6 are specified below and gated by the same instrument.
**Decision record:** [ADR 017 — Services layering and composition root](architecture/017-services-layering-and-composition-root.md).
**Predecessor:** [OpenBurnBarCore decomposition program](CORE_DECOMPOSITION_PROGRAM.md) (complete; its
remaining-work item (c) names the app targets as the next program).
**Instrument:** [`scripts/debt/services_layering.py`](../scripts/debt/services_layering.py) +
[`config/services-layers.json`](../config/services-layers.json), enforced by
`scripts/debt/check-services-layering.sh` in the fast-feedback `debt-budgets` job.

## TL;DR

`AgentLens/Services` is 182k lines in 579 files. No file is a god file. The problem is the
graph: measured on `origin/main` (32b5d9bafa), **37 of the app's 47 components form one strongly
connected component**, and that includes `DataStore`, `Models`, `App` and `Views`. Nothing can
leave that knot for a package, because the compiler would drag the other 36 along.

The Core program could move files mechanically because its graph was already acyclic. This one
has to straighten the edges first, and only then modularize. So the program goes:

1. **Measure and freeze** (Wave 0). A fitness function resolves every type reference in
   AgentLens to a component and fails CI on any new upward or cycle-forming reference.
2. **Straighten bottom-up** (Waves 1–4). Sink foundation and persistence, dissolve the
   `Services/` root, move construction into a composition root, then put interfaces in front of
   the hub features.
3. **Modularize** (Wave 5). Carve SwiftPM targets bottom-up, once each layer is acyclic and
   `swift test` on the PR door can cover it.

Every wave preserves behaviour and is judged by the gate's numbers, not by prose.

## Measured state

| Metric (`--report`) | origin/main 32b5d9bafa | after Wave 1 | end state |
|---|---:|---:|---:|
| Components | 47 | 57 | — |
| Largest dependency cycle (components) | **37** | **34** | 0 |
| Components in any cycle | 37 | 34 | 0 |
| Upward-layer references (R1) | 157 | 60 | 0 |
| References along a cycle (R2) | 3,054 | 1,637 | 0 |
| Files in `Services/` root (R3) | 62 | 58 | 0 |

Singletons, measured the same day (they are edges too, since `Foo.shared` references `Foo`):
**59** `static let/var shared` declarations in AgentLens (**52** in Services), **49** app-owned
types read through `.shared`, **571** reads. `Analytics.shared` alone accounts for 174 of them.

The source of the knot is specific and small. Before Wave 1, `DataStore` (the persistence layer,
27.5k LOC) referenced ten higher components. Most of those references were value types filed in
the wrong directory: `ProjectionIdentity`, `SearchResult`, `EmbeddingIdentity`, chart rows,
operating-layer enums, the dashboard usage snapshot. A few were real calls: the daemon socket
transport, `SearchQueryCache`, and team-memory identity helpers.

## Target architecture

### Layers

A component may reference its own layer or any lower one. Same-layer references are allowed
only while they stay acyclic.

| Layer | Contains | Rule of thumb |
|---|---|---|
| `foundation` | `Services/Foundation` (logging, keychain, JSON aliases), `Services/LogParser` (engine aliases), `Models`, `Utilities`, `Support` | No I/O orchestration and no knowledge of features |
| `contracts` | `Services/<Feature>/Contracts/**`, `Services/Protocols` | Value types and protocols only: no singletons, no I/O |
| `persistence` | `Services/DataStore`, `Services/DaemonIPC` | GRDB stores, read models, daemon single-writer transport |
| `platform` | `Analytics`, `Telemetry`, `Diagnostics`, `Performance` | Cross-cutting infrastructure used by features |
| `feature` | every other `Services/<Feature>`, plus the legacy `Services/(root)` | Owns behaviour, depends downward |
| `app` | `App`, `Views`, `Theme` | Composition root and presentation |

### `<Feature>/Contracts/`

A type moves into its feature's `Contracts/` directory **only when something below the feature
needs it**. Contracts exist to break cycles, not to add ceremony. The directory is the future
interface module of that feature (the Tuist µFeature "Interface" target): consumers depend on the
contract, and only the composition root sees the implementation.

### Composition root

`OpenBurnBarRuntimeContext` (today in `Services/OpenBurnBarStartupRecovery.swift`) is the app's
service locator: about 40 optional slots, filled after construction and started lazily. The end
state is a phased composition root in `App/`. Each runtime phase (core → foreground → relay →
Mercury → smart display → War Room) is a plain struct built with constructor injection, and each
phase receives only what the previous phases produced. The graph is checked by the compiler.
There are no optional slots and no DI framework (TCA is ruled out by the 2026-09-13 audit, and a
property-wrapper locator would just be a nicer-looking locator).

### Module end state (Wave 5)

| SwiftPM target (new, app-side) | From | Door-tested |
|---|---|---|
| `AgentLensFoundation` | `Services/Foundation`, `Services/LogParser`, `Models`, `Utilities` | yes |
| `<Feature>Contracts` | each `Services/<Feature>/Contracts` | yes |
| `AgentLensPersistence` | `Services/DataStore`, `Services/DaemonIPC` | yes (GRDB-SQLCipher is already a Core dependency) |
| feature targets | `Services/<Feature>` minus Firebase/AppKit adapters | per feature |
| app target | `App`, `Views`, `Theme`, Firebase/AppKit adapters | post-merge `app-pr-gate` |

Firebase-importing files (96 today) and AppKit/SwiftUI-importing files (57) stay out of
door-tested targets. They sit behind contracts as adapters that the app target composes.

## The gate

`scripts/debt/check-services-layering.sh` (the `--check` mode) enforces five rules against
`budgets/services-layering-baseline.json`:

| Rule | Fails when |
|---|---|
| **R1 layering** | a component references a component on a higher layer |
| **R2 acyclic** | a reference lies on a component-level dependency cycle |
| **R3 root** | a new file appears directly in `AgentLens/Services/` |
| **R4 declared** | a scanned Swift file has no declared component: an `AgentLens/Services/<Dir>` missing from the manifest (including one that holds only `<Dir>/Contracts`), or any file under an AgentLens root the manifest does not cover — its edges would vanish silently |
| **R5 unique** | a top-level type name is declared in two components (the resolver could not own it, so its edges would vanish and baselined debt would look retired) |

Debt is keyed `src -> dst : Symbol` with the number of referencing files. A new key fails, a
count may only shrink, and moves inside a component never touch the baseline. When a change
retires debt, the gate prints `Improved:` and asks for `--update`. The committed baseline is
itself held to the base commit's (`--base`, fed by CI from the PR or merge-group base): a key
absent at base, a higher count, or a new root file fails, so running `--update` cannot launder
new debt into the same change.

Resolution is conservative. Only top-level declarations own a name, a file never references a
name it declares itself, and comments and string literals are stripped. The analyzer runs over
all of AgentLens in under a second.

Useful modes:

```bash
python3 scripts/debt/services_layering.py --report          # summary, cycles, debt by component
python3 scripts/debt/services_layering.py --explain Services/CloudSync
python3 scripts/debt/services_layering.py --simulate plan.json --report   # {"files": {old: new}}
bash scripts/debt/check-services-layering.test.sh           # rule self-test on a synthetic repo
```

### Remedies, in order of preference

1. **Move a pure type down.** A value type or protocol with no service dependencies goes to the
   owning feature's `Contracts/`, or to `Services/Foundation` if it is infrastructure.
2. **Move the owner.** If a file is really part of the lower component (a read model the store
   owns, a cache the writer invalidates), move the file.
3. **Split presentation off.** `Color`, `DesignSystem` and SF Symbol members go into an
   `extension` under `Views/` or `Theme/`.
4. **Invert.** Put a protocol in the lower layer's `Contracts/`, have the higher feature conform,
   and inject the conformance from the composition root. Never add a new `.shared` or a
   `configureShared` hook to do this.

## Waves

Each wave is one folded PR (CHEAP_FAST), from a fresh worktree on `origin/main`, and preserves
behaviour. Exit criteria are gate numbers.

| Wave | Theme | Exit criterion (gate) | Status |
|---|---|---|---|
| **0** | Fitness gate, manifest, baseline, CI wiring, self-test | gate green on main; self-test covers R1–R5, growth, shrink, shadowing, stripping, contracts, base-relative ratchet | ✅ landed with W1 |
| **1** | Persistence becomes a leaf | `--explain Services/DataStore` all `ok`; DataStore, Models, Foundation, DaemonIPC, `*.Contracts` in no cycle | ✅ see §Wave 1 |
| **2** | Dissolve `Services/` root; composition root → `App/` | `servicesRootFiles` = 0; `OpenBurnBarRuntimeContext` lives in `App/` | planned |
| **3** | Singletons → phased composition root | widen `check-singleton-budget.sh` to Core + Daemon sources first; `static shared` in Services ≤ 10 (from 52) | planned |
| **4** | Interfaces in front of the hubs (CLIBridge, ComputerUse, CloudSync, OpenBurnBarDaemon, Settings) | `largestCycle` among Services components = 0; Services → `Views`/`App` references = 0 | planned |
| **5** | Carve SwiftPM targets bottom-up | Foundation, Contracts, Persistence build and test under `swift test` on the PR door | planned |
| **6** | Views/App | `largestCycle` = 0 app-wide; `upwardReferences` = 0 | planned |

### Wave 2 placement plan (`Services/` root, 62 files)

The gate confirms each placement at execution time. A file whose move would add R1/R2 debt goes
back to this table for a decision; nobody forces it through.

| Destination | Root files |
|---|---|
| `App/` (composition) | `OpenBurnBarStartupRecovery.swift` (`OpenBurnBarRuntimeContext`), `NavigationCoordinator.swift` |
| `Views/` | `DataControlCenterViewModel.swift` |
| `Services/Account/` (new) | `AccountManager.swift`, `OpenBurnBarAppCheckProviderFactory.swift`, `OpenBurnBarSecureToken.swift` |
| `Services/Settings/` | `SettingsManager.swift`, `SettingsManager+Memory.swift` |
| `Services/Updates/` (new) | `DirectDownload*` (5), `HomebrewUpdateChannel.swift`, `SourceUpdateChannel.swift`, `UpdateModels.swift` |
| `Services/Switcher/` (new) | `SwitcherDiscoveryService.swift`, `SwitcherCLIAuthCoordinator.swift`, `SwitcherCLIFallbackPlanner.swift`, `SwitcherAuthStore.swift` |
| `Services/CloudSync/` | `CloudSyncService.swift`, `CloudSyncSharedArtifactModels.swift`, `CloudBudgetService.swift`, `MacCloudEntitlementStore.swift`, `ICloudSessionMirrorService.swift`, `CloudVault*` (2), `MacCloudVaultSignalPayloads.swift` |
| `Services/Hermes/` (new) | `HermesRealtimeRelayHostClient.swift`, `HermesRuntimeLauncher.swift`, `HermesInventoryImportService.swift`, `HermesRelaySenderTrustResolver.swift`, `HermesDataFolder.swift` |
| `Services/Chat/` | `ContextBuilder.swift`, `ContextPackService.swift`, `ContextPackExporter.swift`, `ConversationBundleExporter.swift`, `SessionTranscriptPreparation.swift`, `SessionLogMarkdownFormatter+App.swift`, `OpenBurnBarChatWorkspaceConfigurator.swift` |
| `Services/Search/` | `CrossEncoderReranker.swift`, `CrossEncoderConfiguration.swift`, `ConversationIndexer.swift` |
| `Services/CLIBridge/` | `CLIAgentRelayChatExecutor.swift`, `CLIBridgeStreamRuntimeCoordinator.swift` |
| `Services/UsageAggregation/` | `UsageAggregator.swift`, `UsageAggregatorParsers*.swift` (3), `RefreshOrchestrator.swift`, `LocalMetricsAggregator.swift` |
| `Services/Artifacts/` (new) | `ArtifactDiscoveryService.swift`, `ArtifactAuthoringService.swift` |
| other features | `InsightEngine.swift` → `Insights/`, `ReceiptBuilder.swift` → `Receipts/`, `DailyDigestManager.swift` → `Insights/`, `DatabaseWorkspaceSnapshotBuilder.swift` → `DataStore/`, `RestrictedLogPathValidator.swift` → `Foundation/` |

Wave 1 already moved `AppLogger`, `SearchQueryCache`, `DashboardRollupService` and
`TranscriptBlockParser` out of the root.

### Wave 3 notes

The singleton gate hardcodes the `AgentLens/` scan root. Moving a file into a package would lower
the count without retiring a singleton, so widening the scan root to
`OpenBurnBarCore/Sources` and `OpenBurnBarDaemon/Sources` is Wave 3's first commit, before any
Wave 5 carve. `CLIAgentSessionMirror.configureShared(accountManager:)` inside the runtime-context
initializer is the pattern to retire: configuration through a global hook is the locator in
disguise.

## Constraints

- **Cheap door.** The Mac app build stays post-merge (`app-pr-gate`) and nightly
  (`headless-app-build`). Each wave PR runs the gate, the pbxproj drift check and the fast door.
  The wave author runs the headless app build and targeted tests locally and records them in the
  PR.
- **XcodeGen 2.45.4 is pinned.** The pbxproj lists files individually, so every move regenerates
  it with the pinned version (see `pr-native-fast.yml` → `xcodegen-drift`).
- **No renames inside move waves.** Renames churn every call site and hide real moves in review.
  They get their own commit or wave.
- **Dated audit snapshots are not path-swept.** `docs/audits`, `docs/diligence`, `docs/archive`
  and `plans` describe the tree on their date.

## Non-goals

A rewrite, a DI framework, TCA, moving `Views` into `OpenBurnBarUI` in this program (that belongs
to the Core program's K4 line), and changing observation timing on the dashboard's perf-tuned
paths.

## Wave 1 — persistence becomes a leaf

After-state (`services_layering.py --report`): **57 components, largest cycle 34
(37 → 34), 34 components in cycles, 60 upward references (157 → 60), 1,637 cyclic
references (3,054 → 1,637), 58 Services-root files (62 → 58).**
`Services/DataStore`, `Models`, `Services/Foundation`, `Services/DaemonIPC` and
every `<Feature>.Contracts` component are members of no dependency cycle, and
`--explain Services/DataStore` shows every outgoing edge `ok`.

Move ledger (one app target; `git mv` preserves history; splits are verbatim
extractions with only the imports the compiler needs):

| Old path | New path |
|---|---|
| `Services/AppLogger.swift` | `Services/Foundation/AppLogger.swift` |
| `Services/CursorConnector/KeychainStore.swift` | `Services/Foundation/KeychainStore.swift` |
| `Services/CLIBridge/MCPClientWiring.swift` (`UntypedJSONObject`) | `Services/Foundation/UntypedJSONObject.swift` (split) |
| `Services/OpenBurnBarDaemon/OpenBurnBarDaemonSocketClient.swift` | `Services/DaemonIPC/` |
| `Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager.swift` (`OpenBurnBarDaemonRuntimePaths`, `OpenBurnBarDaemonManagerError`) | `Services/DaemonIPC/` (split, one file per type) |
| `Services/Fleet/BurnBarFleetClientError.swift` | `Services/Fleet/Contracts/` |
| `Services/OpenBurnBarOperating/OpenBurnBarOperatingModels.swift` | `Services/OpenBurnBarOperating/Contracts/` |
| `Services/DataStore/DataStoreTypes.swift` | `Services/DataStore/Contracts/` |
| `Services/DataStore/DeviceHardwareIcon.swift` | `Services/Foundation/` |
| `Services/ProjectionPipeline/ProjectionPipelineCore.swift` | `Services/ProjectionPipeline/Contracts/` |
| `Services/Search/{SearchTypes,Embedding/EmbeddingTypes,RetrievalQueryTypes}.swift` | `Services/Search/Contracts/` |
| `Services/SearchQueryCache.swift` | `Services/DataStore/` |
| `Services/Charts/{ChartFactRow,ChartSessionAnalytics,ChartsSnapshot}.swift` | `Services/Charts/Contracts/` |
| `Services/CloudSync/CloudSyncTypes.swift` (`CloudBackupPlanLimits`, `CloudBackupUsageSnapshot`, `CloudBackupProgressSnapshot`) | `Services/CloudSync/Contracts/` (split) |
| `Services/CloudSync/{TeamMemoryPullService,TeamMemorySyncService}.swift` (team-memory identity statics) | `Services/CloudSync/Contracts/TeamMemoryIdentity.swift` (new `enum TeamMemoryIdentity`) |
| `Services/Memory/ChatTranscriptExtractor.swift` (`AgentConversationExtractionSource`, `ChatExtractionTranscriptReading`, `ChatTranscriptMessage`) | `Services/Memory/Contracts/ChatTranscriptContracts.swift` (split) |
| `Services/Memory/MemoryRecallBudget.swift` | `Services/Memory/Contracts/` |
| `Services/ContextBuilder.swift` (`PromptTokenSection`, `PromptTokenArbiter`) | `Services/Memory/Contracts/PromptTokenArbiter.swift` (split) |
| `Services/ConversationIndexer.swift` (`IndexedConversationWrite`) | `Services/DataStore/IndexedConversationWrite.swift` (split) |
| `Services/DashboardRollupService.swift` | `Services/DataStore/` |
| `Views/Dashboard/DashboardUsageViewModel.swift` | `Services/DataStore/` (`moodColor` split to `Views/Dashboard/DashboardUsageViewModel+Appearance.swift`) |
| `Views/Dashboard/OrgRollupView.swift` (`OrgGroupBy`, `OrgRollupRow`) | `Services/DataStore/OrgRollupTypes.swift` (`OrgGroupBy.tint` stays as a view-side extension) |
| `Services/DataStore/BudgetSettings+AgentLens.swift`, `Services/DataStore/BudgetGate+AgentLens.swift` | `Services/Settings/Stores/` |
| `Models/ActivationChecklistModel.swift` | `Views/Dashboard/` |
| `Services/TranscriptBlockParser.swift` | `Models/` |
| `Models/ProviderBrand.swift` | `Theme/` (`OpenBurnBarDaemonProviderConfiguration.brand` moved with it as an extension) |
| `Models/ChatBackendID.swift` (`gradient`, `activeForeground`) | `Theme/ChatBackendID+Appearance.swift` (split) |

`TeamMemoryIdentity` also carries `convergenceKey` (moved byte-identical with
its callers repointed): `teamLocalEngineMemoryID` depends on it, and leaving it
on `TeamMemorySyncService` would have put a `CloudSync.Contracts -> CloudSync`
upward edge back into the graph.

Reading the numbers: `Services/ProviderUsageAPI` left the cycle as a side effect (37 → 34 is
DataStore, Models and ProviderUsageAPI). Most of the cycle-reference drop is `Views`: its references
to persistence stopped counting once persistence left the cycle. The component count rises 47 → 57
because the new layers (`Services/Foundation`, `Services/DaemonIPC`, eight `*.Contracts`) are
components, which is the point.

No logic changed. Apart from import lines, the only non-verbatim lines are call sites repointed to
`TeamMemoryIdentity`, and the `PromptTokenArbiter` split. That split drops a redundant
`OpenBurnBarCore.` qualifier so that it resolves through the existing `TokenExtractionUtility` alias
instead of adding an umbrella import.

Validation: headless app build `BUILD SUCCEEDED`; `build-for-testing` `TEST BUILD SUCCEEDED`; gate
self-test green (12 cases); pbxproj regenerated with pinned XcodeGen 2.45.4; umbrella-imports
baseline and `check-budget-fork-drift.sh` repointed at the moved paths. Every
`scripts/debt/check-*.sh` passes except `check-string-any-boundary-budget.test.sh` and
`check-domain-core-freeze.sh`, which fail identically on a pristine `origin/main` export. The PR
records the targeted app tests over the moved types.

**What Wave 1 deliberately left alone.** `DataStoreCoordinator` is still the `@Observable` facade
that owns the dashboard read model and is referenced app-wide as `DataStore`. Splitting it into a
persistence facade and a read model is a Wave 3/4 job, because it is the locator's hub.
