# Docs index and ownership rules

Where documentation lives, who owns it, how it stays fresh, and which files are
frozen records. Agents: [`AGENTS.md`](../AGENTS.md) points here; follow these
rules when you add, move, or correct a doc.

## Rules

1. **Placement.** One README per app or package, beside its code. Everything
   else lives under `docs/`, in the area directory that matches its subject
   (table below). New top-level files at the repository root are blocked by the
   root-inventory ratchet (`bash scripts/ci/check-root-inventory.sh`).
2. **Ownership.** Every live doc has an owner. OpenBurnBar has one operator
   ([`docs/runbooks/HANDOVER.md`](runbooks/HANDOVER.md)), so every area below is owned
   by the primary operator until that page names someone else. Change the Owner
   column only when a named person has accepted the area.
3. **Freshness.** A live doc must be linked from an index or another live doc.
   `bash scripts/ci/check-docs-freshness.sh` counts orphaned docs untouched for
   more than 90 days; the count is a shrink-only ratchet
   (`budgets/docs-freshness-baseline.json`). Fix a stale doc by linking it,
   refreshing it, or archiving it — never by raising the ceiling.
4. **Frozen records.** Audits, diligence reports, reviews, legal packets,
   evidence bundles, and the archive are point-in-time records. A correction is a
   new dated file that supersedes the old one; the old body is never edited. A
   frozen record may gain a dated STALE banner at the top that points at the
   newer evidence, as long as the banner changes no signature and no verdict.
5. **Evidence freezes.** A dated, one-off evidence capture (a drill, a
   certification run, a screenshot set proving a fix) goes under
   `docs/archive/evidence/YYYY-MM-DD-<slug>/` with a README that names the
   commit, the command that produced it, and the verdict. Commit structured
   results (JSON, Markdown); raw `*.log` streams are ignored by `.gitignore`
   unless an integrity manifest hashes them. Launch-gate receipts stay in
   `launch-evidence/`, where the launch gate reads them. The existing port
   evidence trees (`docs/windows-port/evidence/`, `docs/linux-port/evidence/`)
   stay where they are: parity-ledger gates and certification manifests
   reference their paths and hash their files. Do not add new raw captures there.
6. **Generated docs are never hand-edited.** Regenerate them instead:
   `docs/SCHEMA_SQLITE.sql` (`OpenBurnBarSchemaExport`),
   `docs/TECH_DEBT_METRICS.md` (`scripts/ci/update-tech-debt-metrics.sh`),
   `docs/status/release-status.json` and the README status block
   (`node scripts/release/render-release-status.mjs`), and the Droid wiki under
   `droid-wiki/` (local wiki generation; see [`AGENTS.md`](../AGENTS.md)).

## Areas

| Area | Holds | Owner | Index / freshness |
| --- | --- | --- | --- |
| `docs/*.md` (top level) | Product, subsystem, and program docs | Primary operator | Linked from [README.md](../README.md), [ONBOARDING.md](ONBOARDING.md), or this page; freshness ratchet |
| [`docs/architecture/`](architecture/README.md) | Numbered ADRs and architecture notes | Primary operator | [architecture/README.md](architecture/README.md) |
| `docs/adr/`, `docs/decisions/` | Dated decision records | Primary operator | Frozen once accepted; supersede with a new record |
| [`docs/runbooks/`](runbooks/oncall.md) | Operator runbooks, including [runbooks/HANDOVER.md](runbooks/HANDOVER.md) and [oncall.md](runbooks/oncall.md) | Primary operator | Linked from [oncall.md](runbooks/oncall.md) and [ONBOARDING.md](ONBOARDING.md) |
| `docs/ops/` | Access inventory, alert rules, event catalog, staging notes | Primary operator | `bash scripts/ops/verify-access-inventory.sh --schema` |
| `docs/security/` | Threat models, privacy invariants, assurance and sign-off pages | Primary operator | Confidentiality guard (`node scripts/security/scan-internal-content.mjs`) |
| `docs/governance/` | Risk register and security register | Primary operator | Accepted risks carry a review date |
| `docs/engineering/` | Ownership and bus factor, extraction plans | Primary operator | Freshness ratchet |
| [`docs/data-room/`](data-room/INDEX.md) | Diligence data-room index | Primary operator | `node scripts/ci/verify-data-room.mjs --check` |
| `docs/status/` | Generated release status and its inputs | Primary operator | `node scripts/release/render-release-status.mjs --check` |
| [`docs/mobile-parity/`](mobile-parity/README.md) | Mobile parity ledger and evidence scaffolding | Primary operator | `node scripts/mobile-parity/validate-mobile-parity.mjs --allow-blocked` |
| `docs/windows-port/` | Windows port plans, ledger, runbooks, certification evidence | Primary operator | `bash scripts/ci/verify-windows-parity-ledger.sh` |
| [`docs/linux-port/`](linux-port/README.md) | Linux port plans, ledger, mission evidence | Primary operator | `node scripts/linux-port/validate-parity-ledger.mjs` |
| `docs/legal/` | AGPL and licensing packets | Primary operator | Frozen record per release |
| [`docs/audits/`](audits/INDEX.md), `docs/diligence/`, `docs/reviews/`, `docs/rca/` | Audits, diligence reports, reviews, incident analyses | Primary operator | Frozen records; [audits/INDEX.md](audits/INDEX.md) |
| `docs/evidence/`, `docs/macos-ui-automation/` | Dated evidence captures | Primary operator | Frozen records; new captures follow rule 5 |
| [`docs/archive/`](archive/README.md) | Retired docs and dated evidence freezes | Primary operator | [archive/README.md](archive/README.md); excluded from the freshness ratchet |
| `docs/plans/`, `docs/superpowers/`, `docs/product-focus/`, `docs/fleet/`, `docs/signalification/` | Program plans, specs, and handoffs | Primary operator | Freshness ratchet; archive when shipped |
| `docs/analytics/`, `docs/api/`, `docs/ci/`, `docs/contracts/`, `docs/schemas/`, `docs/qa/`, `docs/analysis/` | Reference material for one subsystem each | Primary operator | Freshness ratchet |
