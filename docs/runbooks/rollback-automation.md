# Cloud Functions Rollback Runbook

## Overview

This runbook describes how to roll back the OpenBurnBar Cloud Functions deployment to a previous release in case of a production incident.

There are **two** rollback paths. Reach for the fast one first.

| Path | Script | What it does | MTTR |
|------|--------|--------------|------|
| **Fast revision-pin** (primary) | `scripts/ops/rollback-revision.sh` | Flips 100% of traffic back to a previous-good Cloud Run revision. No git checkout, no build, no redeploy. | **sub-minute** |
| Full source rollback (fallback) | `scripts/rollback.sh` | Checks out a release tag, rebuilds Functions, and runs `firebase deploy`. | **tens of minutes** |

**Why the fast path works:** Gen2 Cloud Functions ARE Cloud Run services. Every deploy creates an immutable Cloud Run *revision*, and traffic is a separate, instantly re-routable pointer. Rolling back a bad deploy is just pointing traffic at the prior revision — no artifact rebuild required. Prefer this for any deploy-introduced regression where a known-good revision still exists.

**When to fall back to source rollback:** the bug is in committed source you must actually revert, the prior revision's image was pruned (the script's image preflight says so before any traffic change), or no good revision exists. Expect tens of minutes of MTTR because it rebuilds and redeploys.

**The fast path is unproven today.** The last live drill ([`launch-evidence/rollback-drill-2026-09-23.json`](../../launch-evidence/rollback-drill-2026-09-23.json), `ok: false`) found every previous revision's image pruned in both projects. The fix is [Keep Rollback Images](#keep-rollback-images-artifact-registry-retention), then [Revision-Pin Drill](#revision-pin-drill-the-rollback-receipt).

## Prerequisites

**Fast revision-pin:**

- gcloud CLI: installed and authenticated (`gcloud auth login`, or ADC)
- Caller has `roles/run.admin` (or `run.services.get` + `run.services.update` + `run.revisions.list` + `run.revisions.get`)
- Caller has `roles/artifactregistry.reader` on the `gcf-artifacts` repository (the image preflight)

**Full source rollback:**

- Firebase CLI: `npm install -g firebase-tools && firebase login`
- gcloud CLI: installed and authenticated for the live-source guard. The guard
  reads the deployed `OPENBURNBAR_SOURCE_COMMIT` and refuses a rollback when
  that commit is on no tag or remote branch (a deploy from an unpublished
  checkout, #2195) or when the target is not an ancestor of it (not a
  rollback). Use `--force` only after human verification.
- Git tags synced: `git fetch --tags`
- Authenticated with Firebase project (`firebase use --add`)

## Fast Revision-Pin Rollback (sub-minute — PRIMARY)

```bash
# 1. Preview the plan + the exact gcloud command (changes nothing)
./scripts/ops/rollback-revision.sh <cloud-run-service> --dry-run

# 2. Roll back to the most recent revision NOT currently serving 100% traffic
./scripts/ops/rollback-revision.sh <cloud-run-service>

# 3. Roll back to a specific revision, non-interactive (CI / paged at 3am)
./scripts/ops/rollback-revision.sh <cloud-run-service> <revision> --yes
```

The script lists revisions newest-first, picks the previous-good one (unless you
name one), checks that the target's image still exists in Artifact Registry,
prints the plan, flips traffic, then health-checks the service URL (non-2xx is a
warning, not a failure). The image check reads the digest Cloud Run pulls
(`status.imageDigest`) and runs `gcloud artifacts docker images describe` on
it. A missing image is a loud `WARN` on a rollback: the pin is still attempted,
Cloud Run refuses it atomically, traffic stays put, and you use the slow path.
Region defaults to `us-central1`; project defaults to the `.firebaserc` default
(`burnbar`). Override with `--region` / `--project`.

The exact command it runs under the hood:

```bash
gcloud run services update-traffic <cloud-run-service> \
  --region us-central1 \
  --project burnbar \
  --to-revisions=<revision>=100
```

For an offline rehearsal, pass a revisions-list JSON fixture with
`--revisions-json <file>` (or `ROLLBACK_REVISIONS_JSON`). Fixture mode only
prints the plan; it cannot change traffic and cannot produce a live receipt.
The live drill is deliberately separate and requires an authenticated gcloud
session: see [Revision-Pin Drill](#revision-pin-drill-the-rollback-receipt).

To list candidate revisions by hand:

```bash
gcloud run revisions list \
  --service <cloud-run-service> \
  --region us-central1 \
  --project burnbar \
  --sort-by='~metadata.creationTimestamp'
```

## Keep Rollback Images (Artifact Registry retention)

A revision can serve only while its image is in Artifact Registry. Firebase's
default `firebase-functions-cleanup` policy on `us-central1/gcf-artifacts`
deletes every function image older than 24 hours. A KEEP policy wins over a
DELETE for the same image, so
[`governance/ops-artifact-retention.json`](../../governance/ops-artifact-retention.json)
commits two KEEP floors for both projects:

| Policy | Keeps | Why |
|--------|-------|-----|
| `rollback-retention` | the newest 3 versions of each function image | N-1 survives even when deploys are more than a week apart |
| `rollback-retention-7d` | every version uploaded in the last 7 days | nothing from the last week is pruned |

Apply them with the script, never by hand. `set-cleanup-policies` rewrites the
repository's whole policy map, so the script sends every live policy
(`firebase-functions-cleanup` included) along with the contract's floors. It
never weakens a stronger live floor, keeps the repository's dry-run mode, and
describes the repository again afterwards; a mismatch exits non-zero.

```bash
# 1. Plan: read-only describe; prints each project's policy file and the exact gcloud command
node scripts/ops/apply-artifact-retention.mjs

# 2. Apply staging first, then production (each run re-reads and verifies live)
node scripts/ops/apply-artifact-retention.mjs --apply --project burnbar-staging
node scripts/ops/apply-artifact-retention.mjs --apply --project burnbar

# 3. The same check CI runs weekly (ops-plane-verify.yml, alert-plane-drift)
node scripts/ops/check-artifact-retention-drift.mjs
```

- **IAM:** planning and the drift check need `roles/artifactregistry.reader`
  on `gcf-artifacts`. The ops-verifier WIF is granted it per
  [`governance/ops-plane-verifier-sa.json`](../../governance/ops-plane-verifier-sa.json).
  Applying needs `roles/artifactregistry.admin` on the project, the documented
  role for cleanup policies (`artifactregistry.repositories.update`).
- **Until applied**, the weekly drift check reports DRIFT (`rollback-retention-7d`
  missing live). That red is correct.
- **Retention is prospective.** It cannot restore pruned images. The 2026-09-23
  drill measured an empty repository, so even today's serving revisions have no
  image. A pinnable N-1 therefore needs **two** successful deploys of a service
  after 2026-09-23: after one, N-1 is still an image-less revision. The drill's
  image preflight tells you which case you are in before touching traffic.

## Revision-Pin Drill (the rollback receipt)

`--drill` is a round trip, and a receipt is written only when every step is
proven:

1. Check the N-1 target's image (missing or unverifiable: refuse, no traffic change).
2. Record the pre-drill traffic: 100% on LATEST, or 100% pinned to one revision
   (a split service is refused).
3. Pin the target to 100% and read the traffic back.
4. Health-probe it; a 2xx is required.
5. Restore the pre-drill traffic (`--to-latest`, or `--to-revisions=<orig>=100`)
   and read it back.

Once the pin is attempted, every failure path restores first and writes no
receipt. If the restore itself cannot be confirmed, the script exits non-zero
and prints the exact restore command: run it immediately.

**When:** after the retention floors are applied and the service has two
successful deploys since 2026-09-23 (see above). Production uses `healthready`,
the public readiness function. Staging does not deploy `healthReady`
([`functions/staging-deploy-targets.json`](../../functions/staging-deploy-targets.json)),
so use `latestrouterrundown`. Its GET returns 2xx only when staging Firestore
has a `router_rundowns/latest` document.

```bash
# Production, after the next successful production deploys
bash scripts/ops/rollback-revision.sh healthready --project burnbar --region us-central1 --dry-run
bash scripts/ops/rollback-revision.sh healthready --project burnbar --region us-central1 --yes \
  --drill --receipt "launch-evidence/rollback-drill-$(date -u +%F)-burnbar.json"

# Staging, after the next staging deploys
bash scripts/ops/rollback-revision.sh latestrouterrundown --project burnbar-staging --region us-central1 --dry-run
bash scripts/ops/rollback-revision.sh latestrouterrundown --project burnbar-staging --region us-central1 --yes \
  --drill --receipt "launch-evidence/rollback-drill-$(date -u +%F)-burnbar-staging.json"
```

The `--dry-run` preview is read-only. It shows the chosen N-1, its image
verdict, and the pin command.

**Receipts:** `launch-evidence/rollback-drill-<YYYY-MM-DD>-<project>.json`,
schema [`docs/schemas/rollback-drill-receipt.schema.json`](../schemas/rollback-drill-receipt.schema.json).
A production-project receipt (the `.firebaserc` default) under
`launch-evidence/` is also copied by the script to
`launch-evidence/latest-rollback-revision-drill.json`. Staging receipts never
become that pointer, and `--receipt` cannot name it. Commit the dated receipt
and, for production, the pointer.

**IAM:** `roles/run.admin` (or the `run.services.get/update` and
`run.revisions.list/get` permissions) plus `roles/artifactregistry.reader` on
`gcf-artifacts`.

**Status (2026-09-28): none of this has run against a live project.** The
image preflight, the round trip, and the retention apply are proven only
offline, against fake `gcloud` binaries
(`scripts/ops/rollback-revision.test.sh`, `scripts/ops/apply-artifact-retention.test.mjs`).
The fast path stays unproven until a receipt from this procedure is committed.

## Full Source Rollback (slow — FALLBACK)

Use only when no good revision exists (see "When to fall back" above).

```bash
# 1. Preview what will change (dry run)
./scripts/rollback.sh --dry-run

# 2. Roll back to the previous release tag
./scripts/rollback.sh

# 3. Roll back to a specific tag
./scripts/rollback.sh v0.1.2-beta.11

# 4. Non-interactive (skip confirmation)
./scripts/rollback.sh --yes
```

The source rollback refuses a target tag that is behind the live
`OPENBURNBAR_SOURCE_COMMIT`; this protects fixes deployed from an uncommitted
checkout. Verify the deployed source before using `--force` to override that
guard.

## Manual Rollback Steps

If the script fails, follow these manual steps:

1. **Identify the target version:**
   ```bash
   git tag --list "v*" --sort=-version:refname | head -10
   ```

2. **Checkout the target tag:**
   ```bash
   git checkout -b rollback/v0.1.2-beta.11 v0.1.2-beta.11
   ```

3. **Build and deploy:**
   ```bash
   npm ci --prefix functions
   npm run build --prefix functions
   firebase deploy --only functions --project burnbar
   ```

4. **Verify health:**
   ```bash
   curl https://us-central1-burnbar.cloudfunctions.net/healthCheck
   # Expected: { "status": "ok", ... }
   ```

## Verification After Rollback

```bash
# 1. Health check
curl https://us-central1-${PROJECT_ID}.cloudfunctions.net/healthCheck

# 2. Liveness probe
curl https://us-central1-${PROJECT_ID}.cloudfunctions.net/healthLive

# 3. Check Firebase Console logs for errors
firebase functions:log --limit 50 --project ${PROJECT_ID}

# 4. Monitor error rate for 10 minutes
```

## Rollback Decision Matrix

| Symptom | Action |
|---------|--------|
| 5xx error rate > 1% sustained | Roll back immediately |
| Cold start latency > 10s | Roll back if affecting users |
| Critical callable returning errors | Roll back immediately |
| Single quota function failing | Hotfix preferred over rollback |
| Firestore data corruption | Roll back + restore from backup |

## Post-Rollback

1. File a production incident in GitHub Issues with `P0 - Critical` + `area: functions` labels
2. Document root cause in `docs/runbooks/` as `incident-YYYY-MM-DD.md`
3. Create a hotfix PR targeting the rolled-back version
4. Do not merge new features until the hotfix is confirmed stable

## Feature Flag Rollback — Visual Capture Source Toggle

Local-only `UserDefaults` flag `visualCaptureSourceToggleEnabled` (default `false`) gates the per-provider Visual Capture toggle UI and engine branching. No Firestore collection or DB migration. To disable without reverting code:

```bash
defaults write com.openburnbar.app visualCaptureSourceToggleEnabled -bool NO
# or via SettingsManager: SettingsManager.shared.visualCaptureSourceToggleEnabled = false
```

Also stored per-launch via `SettingsPersistenceCoordinator` keys: `visualCaptureGlobalDefault` (`cli_pty`|`desktop_app`) and `visualCapturePerProvider` (JSON `[persistedToken: rawValue]`). Clearing `visualCapturePerProvider` resets all per-provider overrides to the global default. No Cloud Run revision pin needed for this flag — it is local-only.

**E2E capture/UI rollback (Subagent E):** flipping the flag off instantly restores the pre-toggle
behavior with no code revert or build: `ScreenCapturePipeline` stays idle (`stream == nil`, no
`SCShareableContent`/`SCStream`/`CVDisplayLink` wake) and `MediaSessionCoordinator` skips
`MediaBudgetStatusStore` debit; Settings → Providers shows no toggle (row height unchanged) and
the session header pill is hidden. Verify with `defaults read com.openburnbar.app visualCaptureSourceToggleEnabled` → `0`.

## Related Runbooks

- [SLO thresholds](slos.md)
- [Computer Use budget](computer-use-budget.md)
- [Cloud Functions deployment](../OPENBURNBAR_RELEASE_ARCHITECTURE.md)
