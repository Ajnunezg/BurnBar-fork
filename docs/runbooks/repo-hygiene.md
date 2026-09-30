# Repository hygiene runbook

How to keep the BurnBar clone and checkout light without destroying evidence.
Three layers, from safe to destructive:

1. **Local object store** — reclaim temporary pack files an interrupted repack
   left behind. Local to one machine, no history change. Safe.
2. **Tracked tree** — stop tracking regenerable debris. A normal commit;
   history keeps the old blobs.
3. **History** — rewrite history to drop large blobs. Breaks every commit SHA.
   Optional, and only as a deliberate, scheduled event.

Steps marked `NEEDS ALBERTO` touch the maintainer's machine, GitHub settings,
or published history. An agent writes the plan; it does not run those steps.

## Measurements (2026-09-28)

Base repository `/Volumes/DevSSD/Developer/BurnBar`, read-only commands only.

| Measure | Value | Command |
| --- | --- | --- |
| Packed objects | 517,423 objects in 4 packs, 8.72 GiB | `git count-objects -vH` |
| Garbage | 55 entries, 128.40 GiB | `git count-objects -vH` |
| Temp pack files | 51 `tmp_pack_*` / `tmp_idx_*` / `tmp_rev_*` files in `.git/objects/pack/`, all written 2026-09-27 13:16–13:17; 16 of them are about 9.3 GB each, the size of the main pack | `ls -la .git/objects/pack/` |
| Temp loose objects | 3 `tmp_obj_*` files | `git count-objects -vH` warnings |
| Worktrees sharing the store | 42 | `git worktree list` |
| Tracked `*.log` files | 313 before this sweep; 311 after | `git ls-files '*.log'` |
| Port evidence | `docs/windows-port/` 704 files / 86K lines; `docs/linux-port/` 871 files / 323K lines | `git ls-files` + `wc -l` |

Sixteen repack-sized temp packs written in the same minute point to several
full repacks running at once and dying — the pattern concurrent automatic
maintenance from many worktrees produces. Treat that as the likely cause, not a
proven one.

## Layer 1 — reclaim the temp packs (`NEEDS ALBERTO`)

The temp files are unreachable garbage: no ref, index, or pack points into
them. Removing them frees about 128 GiB on DevSSD and changes no object.

1. Stop every agent and editor session that runs git against this repository or
   any of its worktrees, then confirm nothing is running:

   ```bash
   pgrep -fl 'git( |-)' || echo "no git processes"
   ```

2. Record the before state, delete only temp files older than an hour, and
   record the after state:

   ```bash
   cd /Volumes/DevSSD/Developer/BurnBar
   git count-objects -vH
   find .git/objects -type f \
     \( -name 'tmp_pack_*' -o -name 'tmp_idx_*' -o -name 'tmp_rev_*' -o -name 'tmp_obj_*' \) \
     -mmin +60 -print -delete
   git count-objects -vH          # size-garbage should now read 0
   git fsck --connectivity-only   # must report no missing objects
   ```

3. Keep it from recurring. Pick one maintainer for the shared object store
   instead of letting every worktree auto-repack:

   ```bash
   git config --local gc.auto 0
   git config --local maintenance.auto false
   git maintenance start          # one scheduled maintenance job for this repo
   ```

   `git gc --prune=now` also clears the garbage, but it repacks all 8.7 GiB and
   can delete objects another process is writing at that moment. Use it only
   with every worktree idle.

## Layer 2 — tracked tree (done in this branch)

Every candidate was checked for references before removal: its full path, and
every path suffix down to its file name, across all tracked files
(`git grep -F`), plus the gates that read the directory.

Removed (39 files, about 41 MB of checkout):

| Path | Why it could go |
| --- | --- |
| `.appstore-screenshots/downloaded/` (5 PNG, 21.9 MB) | Copies downloaded from App Store Connect, which remains the source. Nothing reads them. |
| `.appstore-screenshots/insights-editorial/` (12 PNG, 2.8 MB) | Output of `IntelligenceBriefSnapshotTests` (iOS) and `IntelligenceBriefScreenTest` (Android); rewritten on every run and read by nothing. Now ignored. |
| `.playwright-cli/` (13 files, 2.0 MB) | Playwright CLI session snapshots from July; already in `.gitignore`. |
| `test/fixtures/ios-fix/` (9 files, 14.6 MB) | Pre-fix device captures of a Mercury bug, including personal device names. No test reads them. Retrievable from history at `1ac238efc5`. |

The root-inventory ratchet (`governance/root-inventory.json`) was lowered from
64 to 62 directories in the same change, because `.playwright-cli/` and `test/`
left the tree.

Kept on purpose:

| Path | Why it stays |
| --- | --- |
| 308 logs under `docs/windows-port/evidence/` and 2 ledger-cited logs under `docs/linux-port/evidence/` | Every one is referenced from inside its own evidence bundle: hashed in `SHA256SUMS`, listed in a receipt, manifest, or evidence summary, or cited by the bundle's evidence documents (the two Linux logs back parity-ledger rows VAL-OPS-002 and VAL-EXTENSION-001). Deleting a hashed log breaks `node scripts/windows-port/validate-release-certification-evidence.mjs <bundle>` for that bundle and erases part of a recorded failure. `.gitignore` already ignores every other `*.log`. |
| `docs/linux-port/evidence/mission-002-reanchor/smoke/*.log` (2 files) | Removed in the first pass, restored in review: they are the point-in-time capture behind the recorded blocked-rollback verdict. Frozen evidence is superseded by a dated record, never deleted, even when no gate cites it. |
| The rest of `docs/windows-port/` and `docs/linux-port/` | Parity-ledger gates (`scripts/ci/verify-windows-parity-ledger.py`, `scripts/linux-port/validate-parity-ledger.mjs`) require the cited evidence files to exist. |
| `Vendor/*.aar` (95 MB at HEAD) | Android build inputs, verified by `Vendor/CHECKSUMS.sha256`. |
| `.appstore-screenshots/*.png`, `.appstore-screenshots/review-final/` | Upload inputs for `tools/app-store-connect/`. |
| `OpenBurnBarCore/Sources/OpenBurnBarG2ParserParity/Fixtures/ParserContract/pc-warp-basic.log` | A parser contract fixture, not a log stream. |

`NEEDS ALBERTO`: if the port evidence should leave the main tree anyway, move
whole certification bundles (never single logs) to an evidence store — a
release asset or a separate evidence repository — and leave a tombstone index
in `docs/archive/evidence/` that records each bundle's source commit and the
SHA-256 of its `SHA256SUMS`. That changes where an auditor finds the record, so
it is a decision, not a cleanup. Rules for future evidence live in
[`docs/INDEX.md`](../INDEX.md).

## Layer 3 — history (optional, destructive, `NEEDS ALBERTO`)

Largest blobs in history (raw blob size, blobs over 5 MB, from
`git rev-list --objects --all | git cat-file --batch-check`; packed size is
smaller for text and about the same for zip, pack, and pcm content):

| Path | Versions | Raw size | At HEAD? |
| --- | --- | --- | --- |
| `Vendor/openburnbar-iroh.aar` | 38 | 2.57 GB | yes (one version) |
| `.xcode-source-packages-audit/` (SwiftPM repository packs; the largest single blob, 226 MB, lives here) | 11 | 759 MB | no |
| `.lane-logs/` (DerivedData SDK stat caches and `.pcm` module caches) | 34 | 280 MB | no |
| `.factory/validation/` (DerivedData from validation runs) | 27 | 214 MB | no |
| `website/public/downloads/*.dmg`, `*.zip` (pre-LFS release binaries) | 2 | 125 MB | no |
| `Vendor/openburnbar-domain-core.aar` | 21 | 122 MB | yes (one version) |
| `.lane-modulecache/` | 13 | 113 MB | no |
| `Vendor/burnbar-remote.aar` | 12 | 111 MB | yes (one version) |
| `atropos/atropos-sandbox.sif` | 1 | 80 MB | no |

Before deciding, measure the packed impact on a mirror clone:

```bash
brew install git-filter-repo
git clone --mirror https://github.com/Imagine-That-Ai/BurnBar.git /Volumes/DevSSD/BuildCache/burnbar-analyze.git
cd /Volumes/DevSSD/BuildCache/burnbar-analyze.git
git filter-repo --analyze        # writes filter-repo/analysis/*.txt; changes nothing
```

A rewrite has costs that outlast the saved gigabytes:

- Every commit SHA changes. Open pull requests, forks, local worktrees, CI
  caches keyed by SHA, and links to commits all break; every clone must be
  re-made.
- Release tags are protected by rulesets, so re-pointing them needs a
  temporary ruleset bypass.
- Release workflows attest build provenance (`actions/attest-build-provenance`
  and cosign bundles published as `*.sigstore.json` release assets), and that
  provenance records the source commit SHA. After a rewrite those commits no
  longer exist in the repository, so tracing a past release back to its source
  commit fails.
- GitHub keeps old objects reachable through pull-request refs and cached views
  until Support purges them.

If the rewrite is worth it, do it once, during a freeze, and fold in the
confidential-path purge from
[`docs/security/PUBLIC_REPO_HISTORY_PURGE_RUNBOOK.md`](../security/PUBLIC_REPO_HISTORY_PURGE_RUNBOOK.md),
which already covers the backup, force-push, re-clone, and Support steps. The
size-only part of the path list (none of these paths exist at HEAD, so HEAD is
unchanged):

```bash
git filter-repo --invert-paths \
  --path .xcode-source-packages-audit/ \
  --path .lane-logs/ \
  --path .lane-modulecache/ \
  --path .factory/validation/ \
  --path atropos/atropos-sandbox.sif \
  --path-glob 'website/public/downloads/*.dmg' \
  --path-glob 'website/public/downloads/*.zip'
```

The AAR versions are a separate decision because HEAD needs the current AAR:
either migrate them to Git LFS (`git lfs migrate import --include='Vendor/*.aar' --everything`,
which needs LFS storage and makes `git-lfs` mandatory for every clone), or
publish each AAR as a release asset fetched by checksum against
`Vendor/CHECKSUMS.sha256` and then strip `Vendor/*.aar` from history.

## Prevention

- `.gitignore` ignores `*.log` (except hash-bound certification logs), build and
  module caches (`.lane-logs*/`, `.lane-modulecache/`, `*.pcm`, DerivedData from
  validation runs), `.xcode-source-packages-audit/`, `launch-evidence/` (receipts
  are force-added deliberately), and now the regenerable screenshot output under
  `.appstore-screenshots/`.
- The pre-commit `check-added-large-files` hook rejects files over 2 MB when
  hooks are installed (`pre-commit install`, see
  [`CONTRIBUTING.md`](../../CONTRIBUTING.md)).
- `scripts/ci/check-no-committed-build-artifacts.sh` blocks tracked module
  caches, DerivedData, and `.pcm` files.
- New evidence follows the placement rules in [`docs/INDEX.md`](../INDEX.md).
