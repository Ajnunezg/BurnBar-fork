# Launch Packet Checklist (owner-only steps)

Every step below needs the owner's credentials, signature, or judgement. Each
one lists the exact command and the receipt that proves it ran. Do them in
order: later steps read the evidence earlier ones write. The end state is
`launch-evidence/final-launch-evidence.json` passing
`scripts/validate-launch-evidence-bundle.mjs --require-done-stamp` and
`scripts/commercial-launch-gate.mjs` reporting `LAUNCH_DONE`.

Rules that apply to every step:

- A receipt comes only from really running its command against the live
  project. Never hand-write or edit one. A failed run writes no receipt; fix the
  cause and re-run.
- `launch-evidence/` is gitignored. Commit a receipt with `git add -f <file>`,
  and only after reading it for UIDs, transaction IDs or tokens.
- A `NO_GO` launch-gate snapshot must not be committed
  (`scripts/ci/check-no-stale-launch-evidence.sh`).

State on 2026-09-28: production Functions last shipped 2026-06-18 (tag
`v1.0.40+repair.39`, commit `fd247f3a`). No live rollback, restore, or
paging-delivery receipt exists.

## 0. Release machine setup (once per session)

```bash
git fetch origin && git status --porcelain     # must print nothing
gcloud auth login && gcloud auth application-default login
gcloud config set project burnbar
gh auth status                                  # Imagine-That-Ai/BurnBar access
```

Expected: a clean tree and working `gcloud` and `gh` sessions.

## 1. Unblock the production deploy lane (decision)

Every `v1.0.40+repair.40/.41` tag push failed in the "BurnBar product release
preflight" step. `deploy-production.yml` needs the signed external-counsel
legal packet (see [production-deploy-boundaries.md](production-deploy-boundaries.md#product-preflight-signed-counsel-owner-emergency-profile-is-an-open-decision)).
Choose one:

- **A. Counsel signs.** Commit the counsel-signed
  `launch-evidence/latest-agpl-store-legal-packet.json`.
- **B. Owner-emergency profile.** Review and merge branch
  `remediation/diligence-85-ops-owner-emergency-option`. It runs the product
  preflight under the owner-attested profile, bound to the resolved tag.

Check it locally before tagging:

```bash
python3 scripts/ci/check_burnbar_release_preflight.py                      # option A
python3 scripts/ci/check_burnbar_release_preflight.py \
  --allow-owner-emergency-approval --allow-owner-emergency-runtime-hold \
  --expected-release-tag "<tag from step 3>"                             # option B
```

Expected: exit 0. Any error names the missing packet field.

## 2. Apply the 7-day image-retention floor (before any deploy)

Rollback can only pin a revision whose image still exists. Apply the floor
first so the images from step 3 survive.

```bash
node scripts/ops/apply-artifact-retention.mjs                                  # plan, read-only
node scripts/ops/apply-artifact-retention.mjs --apply --project burnbar-staging
node scripts/ops/apply-artifact-retention.mjs --apply --project burnbar
node scripts/ops/check-artifact-retention-drift.mjs
```

Needs `roles/artifactregistry.admin`. Expected: both applies re-read the live
policy and exit 0, and the drift check prints `MATCH` for both projects. The
receipt is the next green `ops-plane-verify.yml` `alert-plane-drift` run
(`gh workflow run ops-plane-verify.yml --ref main`).

## 3. Ship production, twice

The revision-pin drill in step 4 needs a servable N-1, so the service needs
two successful deploys after step 2. A `v*` tag push starts
`deploy-production.yml`, `deploy-cloud-run.yml`, `deploy-hosting.yml` and
`release.yml`.

```bash
git checkout --detach origin/main
git tag --sort=-creatordate | head -3          # choose the next free tag
TAG='v1.0.40+repair.42'                        # example; use the next free one
git tag -a "$TAG" -m "BurnBar $TAG" && git push origin "$TAG"
gh run watch -R Imagine-That-Ai/BurnBar \
  "$(gh run list -R Imagine-That-Ai/BurnBar --workflow deploy-production.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```

Approve the pending `production` environment deployment when asked. If the run
stops at "Verify dry-run attestations", follow
[existing-stable-tag-dry-run-recovery.md](existing-stable-tag-dry-run-recovery.md).
Repeat with the next tag for the second deploy.

Expected receipts:

- `deploy-production.yml` run `success` for both tags.
- `curl -s https://us-central1-burnbar.cloudfunctions.net/healthReady | jq '.version, .source.commit'`
  shows the new tag and its commit.
- `gh workflow run deploy-lane-health.yml --ref main` goes green (production
  no longer behind main), which closes the `deploy-health` issue.
- `gh workflow run ops-confidence.yml --ref main`: `deploy-freshness` goes
  green. It failed on 2026-09-28 with Functions 101.7 days old and three Cloud
  Run services 133-142 days old.

## 4. Rollback revision-pin drill

```bash
bash scripts/ops/rollback-revision.sh healthready --project burnbar --region us-central1 --dry-run
bash scripts/ops/rollback-revision.sh healthready --project burnbar --region us-central1 --yes \
  --drill --receipt "launch-evidence/rollback-drill-$(date -u +%F)-burnbar.json"
bash scripts/ops/rollback-revision.sh latestrouterrundown --project burnbar-staging --region us-central1 --yes \
  --drill --receipt "launch-evidence/rollback-drill-$(date -u +%F)-burnbar-staging.json"
```

The dry run must show the N-1 image as `verified`. If the restore cannot be
confirmed, the script exits non-zero and prints the exact restore command: run
it at once. Details: [rollback-automation.md](rollback-automation.md#revision-pin-drill-the-rollback-receipt).

Expected receipt: `launch-evidence/latest-rollback-revision-drill.json`
(`openburnbar.rollback-drill-receipt.v1`, `mode: live`, `ok: true`,
`drill.restore.confirmed: true`). The launch gate's `rollbackRevisionDrill`
check needs it to be at most 30 days old.

## 5. Firestore restore drill

```bash
GCLOUD_PROJECT=burnbar bash scripts/ops/run-firestore-restore-drill.sh
```

Clones production to a scratch database, compares entitlement, vault-key
wrapper and usage counts, then deletes the scratch database. Permissions and
the backup-restore variant: [firestore-disaster-recovery.md](firestore-disaster-recovery.md#restore-drill).

Expected receipt: `launch-evidence/latest-firestore-restore-drill.json`
(`liveDrill: true`, `ok: true`, every collection group matched, drill database
deleted). The gate's `firestoreRestoreDrill` check needs it to be at most 30
days old.

## 6. App Check enforcement probe

```bash
GCLOUD_PROJECT=burnbar bash scripts/ops/verify-firestore-app-check-enforcement.sh \
  --receipt "launch-evidence/app-check-enforcement-$(date -u +%F).json"
```

Expected: `PASS` for `firestore.googleapis.com`, `firebasestorage.googleapis.com`
and the Apple DeviceCheck key, plus a receipt
(`openburnbar.app-check-enforcement-receipt.v1`, both services `ENFORCED`,
`appleDeviceCheckKeySet: true`). No receipt is written unless everything
passes. The launch gate's `firebaseAppCheck` check also re-reads this live
when it runs. The last recorded probe is `ENFORCED` for both services on
2026-09-23, in `launch-evidence/ops-plane-2026-09-23.json`.

## 7. Single-region risk acceptance (signature)

`launch-evidence/ops-plane-2026-09-23.json` has `singleRegionAcceptance.status:
pending-signature`. Its proposed text overstates recovery ("redeploy ... RTO in
hours"). Moving Functions to another region does not move the Firestore
database, whose location is fixed when it is created
([region-strategy.md](../architecture/region-strategy.md)). Check the facts,
then sign the corrected text below.

```bash
gcloud firestore databases describe --database='(default)' --project=burnbar --format='value(locationId)'
```

If this prints a multi-region location (`nam5`, `eur3`), change the third
`accepts` line to say so before signing.

Prepared text (not signed):

> Statement: Single-region operation in us-central1 is accepted for the
> pre-launch and early-launch stage as a cost and complexity trade-off. No
> customer-facing multi-region SLA is claimed.
>
> Accepts:
> 1. All production Cloud Functions (200 on 2026-09-23) and the Cloud Run
>    services run in us-central1 only. There is no multi-region failover.
> 2. A us-central1 outage takes the BurnBar backend offline until Google
>    restores the region. Redeploying Functions to another region does not
>    help while the Firestore database is unavailable, so the recovery time is
>    the length of the outage and is not measured.
> 3. The Firestore `(default)` database is in `<locationId from the command
>    above>`. Point-in-time recovery and scheduled backups protect against
>    data loss inside that location, not against the loss of the region.
>    Cross-region replication is not purchased.
>
> Re-review: at paid launch, or when the monthly Functions bill passes $500,
> or after the first regional-outage post-mortem, whichever comes first.

Sign it (writes the text, signer and time, then an SSH signature over the file):

```bash
f=launch-evidence/ops-plane-2026-09-23.json
jq --arg at "$(date -u +%FT%TZ)" --arg loc "<locationId>" '
  .singleRegionAcceptance.statement = "Single-region operation in us-central1 is accepted for the pre-launch and early-launch stage as a cost and complexity trade-off. No customer-facing multi-region SLA is claimed."
  | .singleRegionAcceptance.accepts = [
      "All production Cloud Functions (200 on 2026-09-23) and the Cloud Run services run in us-central1 only. There is no multi-region failover.",
      "A us-central1 outage takes the BurnBar backend offline until Google restores the region. Redeploying Functions to another region does not help while the Firestore database is unavailable, so the recovery time is the length of the outage and is not measured.",
      ("The Firestore (default) database is in " + $loc + ". Point-in-time recovery and scheduled backups protect against data loss inside that location, not against the loss of the region. Cross-region replication is not purchased.")
    ]
  | .singleRegionAcceptance.reReview = "at paid launch, or when the monthly Functions bill passes $500, or after the first regional-outage post-mortem, whichever comes first"
  | .singleRegionAcceptance += {status: "signed", signer: "Alberto Nunez", signedAt: $at}
' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n file "$f"
git add -f "$f" "$f.sig"
```

Expected: `singleRegionAcceptance.status: signed` with `signer` and `signedAt`,
and `ops-plane-2026-09-23.json.sig` beside it.

## 8. Alert delivery drills (within 7 days of step 10)

Both routes, per [alert-delivery-drill.md](alert-delivery-drill.md). The Slack
secret `OPS_PAGING_SLACK_WEBHOOK` is already set; rotate it only if the
channel changed.

```bash
# Route A: GCP Monitoring
node scripts/ops/run-alert-delivery-drill.mjs
node scripts/ops/run-alert-delivery-drill.mjs --confirm-delivered --operator "Alberto Nunez"

# Route B: GitHub ops lanes to Slack
gh workflow run ops-paging-drill.yml -R Imagine-That-Ai/BurnBar --ref main
node scripts/ops/ops-paging-drill.mjs --confirm-delivered \
  --drill-id drill-<id from the page> --run-url <run url> \
  --webhook-fingerprint sha256:<from the run summary> --operator "Alberto Nunez"
```

Run the second route A command only once the canary alert has arrived, and
the `--confirm-delivered` for route B only once the Slack page is on your phone.

Expected receipts: `launch-evidence/alert-channel-verified.json` (every
required channel confirmed; the gate's `alertDeliverability` check allows 168
hours) and `launch-evidence/latest-ops-paging-drill.json`
(`deliveryConfirmed: true`).

## 9. Name the operators

Fill the `UNSET` operator slots in [HANDOVER.md](HANDOVER.md), or record the
solo-operator decision per [SOLO_OPERATOR_POLICY.md](../SOLO_OPERATOR_POLICY.md).
The final bundle's rollback report must state `onCallCanExecute: true`, and
that is only true once a named person holds the console access.

## 10. Commercial launch gate snapshot

```bash
node scripts/capture-commercial-launch-evidence.mjs
```

This runs `scripts/commercial-launch-gate.mjs` and writes
`launch-evidence/latest-commercial-launch-gate.json`. Expected:
`verdict.status` is `READY_FOR_LIVE_PAID_PROOF` once the App Store version is
live and every check is `ok`. That includes `rollbackRevisionDrill` (step 4),
`firestoreRestoreDrill` (step 5), `firebaseAppCheck` (step 6) and
`alertDeliverability` (step 8). A `NO_GO` names the failed checks, and each
drill check prints the command that fixes it. Do not commit a `NO_GO`
snapshot.

## 11. Final launch evidence bundle

Background: [LAUNCH_EVIDENCE_BUNDLE.md](../LAUNCH_EVIDENCE_BUNDLE.md). The
validator's required fields are in `scripts/validate-launch-evidence-bundle.mjs`.

1. **Skeleton for the release tag.**
   `node scripts/release/generate-final-launch-evidence.mjs --tag "$TAG"`.
   Receipt: `launch-evidence/final-launch-evidence.json`
   (`status: PRE_LAUNCH_SKELETON`).
2. **Eight live paid proofs** (`apple`/`google_play` × `cloud`/`cloud-pro`/`ultra`,
   `stripe` × `cloud`/`cloud-pro`), one real purchase each:

   ```bash
   npm --prefix functions run prove:paid-tier -- --uid "$PROOF_UID" --tier cloud --channel apple \
     | scripts/capture-commercial-launch-evidence.mjs --kind paid-proof-apple_cloud --input -
   ```

   Receipt: `launch-evidence/latest-paid-proof-<id>.json` with `ok: true`.
   List each one in `paidProofs[]` with its `id`, `channel`, `tier` and `path`.
3. **Cross-channel matrix.** `launch-evidence/cross-channel-paid-path-matrix.json`,
   ten rows each with evidence. Shape: [CROSS_CHANNEL_PAID_PATH_MATRIX.md](../CROSS_CHANNEL_PAID_PATH_MATRIX.md).
   Check: `scripts/validate-launch-evidence-bundle.mjs --stage paid-proof launch-evidence/final-launch-evidence.json`
   prints `ok: true`. The gate then reports `READY_FOR_CANARY`.
4. **Canary.** Remote Config at 10% (`paid_canary_percent: 10`,
   `public_paid_launch: false`) for 72 hours or 25 paid users. Receipt:
   `canary-report.json` with margins (Cloud at least 80%, Cloud Pro at least
   50%), App Check denials under 1%, entitlement failures under 0.5%,
   projected spend limits, and dashboard, COGS and incident-log evidence.
   Check: `--stage public-release` prints `ok: true`, and the gate reports
   `READY_FOR_PUBLIC_RELEASE`.
5. **Public release, refund/abuse, rollback tabletop, release IDs.** Receipts:
   `public-launch-report.json`, `refund-abuse-report.json`, `rollback-drill.json`
   (kill switch patched and halt verified, Hosting release list, Functions
   build, Cloud Run revision list, gate and ops readiness, console access for
   all three stores, `onCallCanExecute: true`), and `release.*` IDs in the
   manifest.
6. **Done stamp.** Write `launch-evidence/LAUNCH_DONE.md` citing the manifest
   and every artifact path above, then:

   ```bash
   scripts/validate-launch-evidence-bundle.mjs --require-done-stamp launch-evidence/final-launch-evidence.json
   node scripts/capture-commercial-launch-evidence.mjs
   ```

   Expected: `ok: true`, and the gate verdict `LAUNCH_DONE`.
