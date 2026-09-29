# Contributing to OpenBurnBar

## Repository layout (high level)

OpenBurnBar is more than the macOS app:

| Area | Path | Notes |
|------|------|--------|
| macOS app | `AgentLens/` | Menu bar UI, dashboard, app services |
| Shared core | `OpenBurnBarCore/` | Shared models, GRDB database + migrator, log parsers, app ↔ daemon wire types |
| Daemon + CLI | `OpenBurnBarDaemon/` | JSON-RPC daemon, `OpenBurnBarCLI`, mission control, runs |
| Cloud Functions | `functions/`, `functions-identity/`, `functions-sync/`, `functions-media/`, `packages/functions-shared/` | Four deploy codebases over one shared runtime package |
| Schema canon | `tools/schema-sync/` | TypeSpec → TypeScript / Swift / Kotlin emitters and drift gates |
| Editor extension | `extensions/openburnbar/` | Cursor / VS Code |
| MCP helper (optional) | `tools/openburnbar-mcp/` | Read-only SQLite bridge for MCP clients |

Canonical architecture: [docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md](docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md).  
Support tiers (core vs experimental): [README.md](README.md). Test folder contract: [AgentLensTests/README.md](AgentLensTests/README.md).

**AI coding agents** (Cursor, Claude Code, Codex, etc.): read **[AGENTS.md](AGENTS.md)** first — completion standard, testing and documentation expectations, and scope discipline. **[CLAUDE.md](CLAUDE.md)** mirrors the same bar for tools that prefer that filename.

**Who reviews and operates:** OpenBurnBar has one operator (see [docs/runbooks/HANDOVER.md](docs/runbooks/HANDOVER.md) and risk AR-008 in [docs/governance/RISK_REGISTER.md](docs/governance/RISK_REGISTER.md)). Review and merge rules are in [docs/SOLO_OPERATOR_POLICY.md](docs/SOLO_OPERATOR_POLICY.md).

## Project structure (app + core)

```
AgentLens/
  App/                          App entry point, menu bar setup (LSUIElement)
  Models/                       App-side models
  Services/
    DataStore/                  GRDB-backed stores (the database spine lives in OpenBurnBarCore)
    UsageAggregator.swift       Orchestrates parsers, stores results
    UsageAggregation/           ParserRegistry.swift (provider → parser map) and refresh coordinators
    UsageAggregatorParsers.swift  App-side parser glue
    ArtifactDiscoveryService.swift  Skill/agent doc discovery + projection queue
    SettingsManager.swift       User preferences
  Theme/
    DesignSystem.swift          Color, typography, spacing, radius, animation tokens
    ProviderTheme.swift         Per-provider color mappings
    ThemeManager.swift          Theme state management
  Views/
    Dashboard/                  Main dashboard, per-provider detail, session detail
    Popover/                    Menu bar popover view
    Settings/                   Settings panel
OpenBurnBarCore/Sources/
  OpenBurnBarProviderModels/AgentProvider.swift   The AgentProvider enum
  OpenBurnBarLogParsers/LogParser/                LogParser protocol + provider parsers
  OpenBurnBarData/                                OpenBurnBarDatabase + the ordered GRDB migrator
```

## Build and tests

- **Xcode project** is generated from **`project.yml`** (XcodeGen). After editing `project.yml`, run `xcodegen generate` if you maintain `OpenBurnBar.xcodeproj` locally.
- **Swift packages**: `swift test --package-path OpenBurnBarCore`, `swift test --package-path OpenBurnBarDaemon` (or `./scripts/test-openburnbar-swift.sh`).
- **App tests**: `./scripts/test-openburnbar-app.sh` runs **`OpenBurnBarTests` only** — the target compiles `AgentLensTests/Active/`, `AgentLensTests/Support/`, and `AgentLensTests/Fixtures/`. A suite that stops compiling moves to `AgentLensTests/Archive/` with a row in `AgentLensTests/Quarantine/QUARANTINE_MANIFEST.md`; both folders currently hold no Swift sources.
- **Mobile tests**: `./scripts/test-openburnbar-mobile.sh` (connected physical iPhone locally; Simulator in CI, `OpenBurnBarMobileTests`). Override with `OPENBURNBAR_IOS_DESTINATION`.
- **Android tests**: `./scripts/test-openburnbar-android.sh`.
- **Full CI locally**: `make ci` (Functions, Firestore rules, extension evals, supply chain audit, all unit test surfaces).
- **Diff coverage**: `./scripts/diff-coverage-all.sh origin/main` after tests with `OPENBURNBAR_ENABLE_COVERAGE=YES`.

### Stale Xcode caches after shared-core migrations

After large `OpenBurnBarCore` migrations (new public types, fields, or
provider/account contracts), Xcode and SwiftPM occasionally hold stale
binary artifacts that surface as ghost errors like *"value of type 'X' has
no member 'Y'"* or XCFramework symbol mismatches between the macOS and
iOS targets. If the on-disk source clearly defines the missing member but
the build keeps failing, run:

```sh
./scripts/clear-xcode-caches.sh            # full reset (DerivedData + SwiftPM + device support)
./scripts/clear-xcode-caches.sh --dry-run  # preview the plan first
./scripts/clear-xcode-caches.sh --derived-only
./scripts/clear-xcode-caches.sh --packages
./scripts/clear-xcode-caches.sh --xcframeworks
```

Every cache the script touches is recreated by Xcode on the next build;
the operation is safe and idempotent.

## Adding a New Provider

A provider is a cross-platform identity, not just a parser. Missing one peer is how the Windows enum fell behind the Swift one.

1. **Add the `AgentProvider` case** in `OpenBurnBarCore/Sources/OpenBurnBarProviderModels/AgentProvider.swift`. Keep declaration order stable; `persistedToken` and `providerID` derive from the raw value unless you add an explicit arm.
2. **Register ingestion metadata** in `contracts/provider-ingestion-catalog.json`, then regenerate `AgentProviderIngestionCatalog.generated.swift` with `node scripts/generate-provider-ingestion-catalog.mjs` (`--check` verifies it is current).
3. **Write the parser** in `OpenBurnBarCore/Sources/OpenBurnBarLogParsers/LogParser/`, conforming to `LogParser`:
   ```swift
   public protocol LogParser: LogParserProtocol {   // LogParserProtocol: var provider: AgentProvider { get }
       func parse(options: LogParseOptions) async throws -> ParseResult
   }
   ```
   Honor the incremental boundary and the resource governor in `LogParseOptions` before any content I/O. Return an empty `ParseResult` if the log directory doesn't exist; don't throw for missing data.
4. **Register the parser** in `ParserRegistry.defaultParsers()` (`AgentLens/Services/UsageAggregation/ParserRegistry.swift`), wrapped in `RegisteredLogParser(...)`.
5. **Add provider colors** in `DesignSystem.Colors` (`AgentLens/Theme/DesignSystem.swift`): `primary(for:)`, `accent(for:)`, and `chartPalette(for:)` (4 colors).
6. **Update the platform peers** in the same change: Android `android/app/src/main/java/com/openburnbar/data/models/AgentProvider.kt`, Windows `windows/app/OpenBurnBar.App.Settings/AgentProvider.cs` (identity subset) and `windows/app/OpenBurnBar.App/Theme/ProviderBrand.cs` (brand colors), and the Linux desktop registry `apps/linux-desktop/src/providerPathRegistry.ts`.
7. **Test with real log files** and add a parser golden-fixture test under `AgentLensTests/Active/Parsers/`.

Quota adapters (live quota rather than log parsing) follow the separate checklist in [docs/PROVIDERS.md](docs/PROVIDERS.md#adding-a-new-provider).

## Coding Conventions

- **SwiftUI with `@Observable`** (not `ObservableObject`/`@Published`)
- **GRDB** for local persistence (not Core Data, not UserDefaults for structured data)
- **All styling through `DesignSystem` tokens** -- don't use raw colors, font sizes, or spacing values in views
- Parsers must be `Sendable` (they run in async contexts)
- Each parser handles missing directories gracefully (return an empty result, don't crash)

## How to Test (manual)

1. Build and run the app
2. Open Settings (gear icon in the popover)
3. Verify provider log paths are correct for your machine
4. Click the refresh button to scan
5. Check the dashboard for parsed sessions and cost totals

---

## Contribution License

New contributions are accepted under `AGPL-3.0-only`, matching the current
OpenBurnBar license in [LICENSE](LICENSE). By contributing, you agree that your
contribution may be distributed as part of OpenBurnBar under `AGPL-3.0-only`.

Historical OpenBurnBar snapshots released under MIT keep their original license
notice in [LICENSES/MIT-legacy.txt](LICENSES/MIT-legacy.txt). Do not remove prior
copyright or attribution notices when modifying older files.

## Dependency update policy

### Minimum release age

New dependency versions must be at least **3 days old** before they are merged into `main`. This policy provides supply chain protection — it gives the ecosystem time to detect and report malicious packages before we adopt them.

- **Enforcement is manual today.** The Renovate config that once enforced `minimumReleaseAge` was deleted (commit `312a925a35`), and the Dependabot config in `.github/dependabot.yml` sets no cooldown. Reviewers must check the publish date.
- **Manual dependency bumps** must include the release date in the PR description and must not be merged until the 3-day window passes.
- **Security vulnerabilities** are exempt: zero-day CVE fixes can be merged immediately after review.

### Version drift

All shared dependencies (TypeScript, ESLint, Prettier) must use the same version range across all packages. Run `npx syncpack list-mismatches` to check, and `npx syncpack fix-mismatches` to auto-correct. CI will warn on drift.

---

## Code quality

### Pre-commit hooks

Install pre-commit hooks before your first commit:

```bash
brew install pre-commit
pre-commit install
```

The hooks (`.pre-commit-config.yaml`) run SwiftLint, SwiftFormat, ESLint, Prettier, ktlint, shellcheck, the confidentiality guard, gitleaks, and detect-secrets on each commit.

### Formatters

| Language | Tool | Command |
|----------|------|---------|
| TypeScript (functions) | Prettier | `npm --prefix functions run format` |
| TypeScript (extension) | Prettier | `npm --prefix extensions/openburnbar run format` |
| TypeScript (website) | Prettier | `npm --prefix website run format` |
| Swift | SwiftLint | `swiftlint lint --fix` |
| Kotlin | ktlint | `cd android && ./gradlew ktlintFormat` |
