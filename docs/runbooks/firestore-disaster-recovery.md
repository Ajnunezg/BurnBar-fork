# Firestore Disaster Recovery

Production Firestore must be recoverable before any commercial launch or paid-data rollout. The database holds entitlements, vault-key wrappers, audit logs, usage, and hosted control-plane state, so DR proof is a launch blocker rather than a best-effort ops note.

## Required State

- Point-in-time recovery: `POINT_IN_TIME_RECOVERY_ENABLED`
- PITR retention window: at least 7 days (`versionRetentionPeriod >= 604800s`)
- Delete protection: `DELETE_PROTECTION_ENABLED`
- Backup schedules: at least one daily or weekly schedule with retention
- Verification: `bash scripts/ops/verify-firestore-disaster-recovery.sh`
- A passing restore drill no older than 30 days: `launch-evidence/latest-firestore-restore-drill.json` (see [Restore Drill](#restore-drill))

The production ops plane runs this verifier as part of:

```bash
bash scripts/ops/verify-production-ops-plane.sh
```

Do not accept docs-only evidence for this control. The verifier reads the Firestore Admin API for the live project selected by `GCLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT` and `FIRESTORE_DATABASE_ID`. It checks posture only; it never restores anything. Only the restore drill proves that a restore works.

## Status

**No live restore drill has been run.** As of 2026-09-28, `launch-evidence/` holds no Firestore restore receipt, so the launch gate's `firestoreRestoreDrill` check is `NO_GO`. The count verification, the receipt and the gate check are proven only against fakes (a fake `gcloud`, a fake `curl`, and a local fake Firestore REST server) by `bash scripts/ops/run-firestore-restore-drill.test.sh`, `node --test scripts/ops/firestore-restore-drill-verify.test.mjs`, and `node scripts/test-commercial-launch-gate-firestore-restore.mjs`. Closing this blocker takes one real drill against production by an operator with the permissions below.

## Restore Drill

Run quarterly and before commercial launch, from a non-primary machine, as an operator with the [permissions](#operator-permissions) below. PITR clone (the default):

```bash
GCLOUD_PROJECT=burnbar bash scripts/ops/run-firestore-restore-drill.sh
```

Backup restore of the newest READY scheduled backup of `(default)`:

```bash
GCLOUD_PROJECT=burnbar FIRESTORE_DRILL_MODE=backup bash scripts/ops/run-firestore-restore-drill.sh
```

The runner:

1. **Preflight.** Rejects a bad `FIRESTORE_DRILL_COLLECTION_GROUPS`, API base, database ID, or snapshot time before anything is restored. In backup mode it selects the backup here and refuses backups whose `database` is not `projects/${PROJECT}/databases/${DATABASE_ID}`; `FIRESTORE_DRILL_BACKUP_NAME` pins one.
2. **Posture.** Runs `verify-firestore-disaster-recovery.sh` against `(default)`.
3. **Restore.** PITR-clones `(default)` at a whole-minute snapshot five minutes ago (`FIRESTORE_DRILL_SNAPSHOT_TIME` overrides), or restores the selected backup, into a throwaway `dr-drill-<timestamp>` database, then waits for the operation (`FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS`, default 4 hours).
4. **Capture.** Describes the restored database and lists its composite indexes.
5. **Verify the data.** Runs a COUNT aggregation (`documents:runAggregationQuery`, collection-group scope) for each collection group, against the source at the snapshot time (`readTime`) and against the restored database. The defaults are `entitlements`, `cloud_vault_key_wrappers`, and `usage` (all under `users/{uid}/`); `FIRESTORE_DRILL_COLLECTION_GROUPS=a,b` overrides them.
   - Clone: the snapshot is a whole minute, so the source read is exact and the counts must be equal.
   - Backup: a backup's `snapshotTime` is sub-minute, but PITR reads older than one hour must use a whole minute. The runner reads the source at the minute before and the minute after the snapshot, records both, and requires the restored count to lie between them.
6. **Clean up.** Disables delete protection on the drill database and deletes it.
7. **Receipt.** Writes `launch-evidence/firestore-restore-drill-<timestamp>.json` and the `latest-firestore-restore-drill.json` pointer, then exits non-zero unless the receipt is ok.

The drill passes (`ok: true`) only when the posture check passed, the restore finished without an error, every collection group matched, at least one of them held data (an all-empty restore proves nothing), and the drill deleted its own database. A failed step is recorded in the receipt's `failures` rather than aborting the run, so a failed drill still leaves a receipt. For a Firestore API error the failure names the status and a hint, for example `FAILED_PRECONDITION` for a missing collection-group index or a read time outside the PITR window. Firestore's own message, which can include project paths and console links, goes to the terminal only.

`FIRESTORE_DRILL_CLEANUP=0` keeps the restored database for incident inspection. That run's receipt is `ok: false` with a `cleanup-disabled` failure: a retained production clone never counts as a passed drill. Delete the database afterwards with the [cleanup command](#cleanup).

### Receipt

The receipt follows [`docs/schemas/firestore-restore-drill-receipt.schema.json`](../schemas/firestore-restore-drill-receipt.schema.json) (`openburnbar.firestore-restore-drill-receipt.v1`). It is redaction-safe by construction: database IDs, timestamps, counts, booleans, and fixed failure text only. It never holds a project ID, resource path, backup name, access token, or operator identity. `liveDrill` is true only when the counts were read from `firestore.googleapis.com`; the test suite's loopback server produces `liveDrill: false`, which the gate rejects. `restore.elapsedSeconds` is the drill's measured restore time against the RTO below.

Illustrative shape only, not a drill result:

```json
{
  "schema": "openburnbar.firestore-restore-drill-receipt.v1",
  "schemaVersion": 1,
  "generatedAt": "2026-10-01T14:40:00.000Z",
  "mode": "clone",
  "liveDrill": true,
  "ok": true,
  "source": { "databaseId": "(default)", "snapshotTime": "2026-10-01T13:55:00Z" },
  "restore": { "databaseId": "dr-drill-20261001140000", "operationDone": true, "elapsedSeconds": 1500 },
  "counts": [
    { "collectionGroup": "entitlements", "sourceCount": 1000, "restoredCount": 1000, "match": true, "vacuous": false },
    { "collectionGroup": "cloud_vault_key_wrappers", "sourceCount": 200, "restoredCount": 200, "match": true, "vacuous": false },
    { "collectionGroup": "usage", "sourceCount": 50000, "restoredCount": 50000, "match": true, "vacuous": false }
  ],
  "cleanup": { "requested": true, "databaseDeleted": true },
  "posture": { "ok": true },
  "failures": []
}
```

In backup mode each `sourceCount` is `{ "floor": n, "ceil": m }`.

`launch-evidence/` is gitignored. The raw captures next to the receipt (`.operation.json`, `.database.json`, `.indexes.json`, `.posture.json`, `.counts.json`) carry resource paths and stay local. Commit only the receipt and the pointer:

```bash
git add -f launch-evidence/firestore-restore-drill-<timestamp>.json \
  launch-evidence/latest-firestore-restore-drill.json
```

### Operator permissions

Permission and role names are from the Firestore IAM reference. `gcloud auth login` as the operator first; the runner passes `gcloud auth print-access-token` to the count step through the environment, never the command line.

| Step | Permissions | Predefined role |
| --- | --- | --- |
| Posture | `datastore.databases.getMetadata`, `datastore.backupSchedules.list` | `roles/datastore.viewer`, `roles/datastore.backupSchedulesViewer` |
| PITR clone | `datastore.databases.clone`, `datastore.databases.create`, `datastore.operations.get` | `roles/datastore.cloneAdmin` |
| Backup restore | `datastore.backups.list`, `datastore.backups.restoreDatabase`, `datastore.databases.create`, `datastore.operations.get` | `roles/datastore.restoreAdmin` |
| Capture | `datastore.databases.getMetadata`, `datastore.schemas.list` | `roles/datastore.viewer` |
| Count verification | `datastore.entities.get`, `datastore.entities.list` on both databases | `roles/datastore.viewer` |
| Cleanup | `datastore.databases.update`, `datastore.databases.delete` | `roles/datastore.owner`, or a custom role with both |

## Restore Procedure

Firestore restores create a new database. Never restore over `(default)`. For BurnBar, run drills in the same `burnbar` project because there is no separate staging project with production-equivalent data. Always use a throwaway database ID and delete it after evidence capture.

During an incident, `FIRESTORE_DRILL_CLEANUP=0 GCLOUD_PROJECT=burnbar bash scripts/ops/run-firestore-restore-drill.sh` restores and verifies counts in one step and keeps the database. The manual commands below do the same restore by hand.

Set the defaults:

```bash
export PROJECT="${GCLOUD_PROJECT:-burnbar}"
export DATABASE_ID="${FIRESTORE_DATABASE_ID:-(default)}"
export DRILL_TS="$(date -u +%Y%m%d%H%M%S)"
export RESTORE_DATABASE_ID="dr-drill-${DRILL_TS}"
```

PITR clone mode:

```bash
# Choose a timestamp inside the PITR window. Five minutes ago avoids the most
# recent-version edge while staying inside the 7-day retention window.
export SNAPSHOT_TIME="$(date -u -v-5M +%Y-%m-%dT%H:%M:00Z 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:00Z)"

gcloud firestore databases clone \
  --project="$PROJECT" \
  --source-database="projects/${PROJECT}/databases/${DATABASE_ID}" \
  --destination-database="$RESTORE_DATABASE_ID" \
  --snapshot-time="$SNAPSHOT_TIME" \
  --format=json \
  >"launch-evidence/firestore-restore-drill-${DRILL_TS}.operation.json"
```

Backup restore mode:

```bash
export BACKUP_NAME="projects/${PROJECT}/locations/<location>/backups/<backup-id>"

gcloud firestore databases restore \
  --project="$PROJECT" \
  --source-backup="$BACKUP_NAME" \
  --destination-database="$RESTORE_DATABASE_ID" \
  --format=json \
  >"launch-evidence/firestore-restore-drill-${DRILL_TS}.operation.json"
```

Wait for the restore operation, replacing the operation name with the `name` field from the JSON above:

```bash
export RESTORE_OPERATION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).name)' "launch-evidence/firestore-restore-drill-${DRILL_TS}.operation.json")"
gcloud alpha firestore operations wait "$RESTORE_OPERATION" --project="$PROJECT"
```

A hand-run restore produces no receipt. Only the drill runner writes launch evidence.

### Cleanup

```bash
gcloud firestore databases update --database="$RESTORE_DATABASE_ID" \
  --project="$PROJECT" \
  --no-delete-protection \
  --quiet
gcloud firestore databases delete --database="$RESTORE_DATABASE_ID" \
  --project="$PROJECT" \
  --quiet
```

## RTO / RPO

- RTO target: less than 4 hours for a full production restore into a replacement database. Each receipt's `restore.elapsedSeconds` measures it.
- RPO target: no more than 1 hour for operator-initiated recovery, backed by PITR and scheduled backups.
- Hard PITR ceiling: 7 days. The verifier fails if Firestore reports a shorter `versionRetentionPeriod`.
- Backup recovery: daily or weekly backup schedule with retention must exist; backups are the long-window recovery path when PITR is not old enough.

## Launch Gate

`scripts/commercial-launch-gate.mjs` reports two Firestore DR checks, and either one failing makes the verdict `NO_GO`:

- `firestoreDisasterRecovery` shells `verify-firestore-disaster-recovery.sh` and fails on any posture drift.
- `firestoreRestoreDrill` reads `launch-evidence/latest-firestore-restore-drill.json` (`OPENBURNBAR_FIRESTORE_RESTORE_DRILL_EVIDENCE` overrides the path). It fails unless the receipt conforms to the schema, has `liveDrill: true` and `ok: true`, is at most `OPENBURNBAR_FIRESTORE_RESTORE_DRILL_TTL_DAYS` days old (default 30: fresh for launch, well inside the quarterly cadence) and not future-dated, matched every collection group with at least one holding data, finished the restore, passed posture, and deleted the drill database. Each failure includes the command to run: `GCLOUD_PROJECT=burnbar bash scripts/ops/run-firestore-restore-drill.sh`.

The release run also requires fresh alert-delivery evidence because DR and human paging are paired launch blockers.

Related policy:

- `docs/SOLO_OPERATOR_POLICY.md` for the quarterly restore drill cadence.
- `docs/RELEASE_ROLLBACK.md` for app, functions, hosting, and Cloud Run rollback.

## Remediation

Use Google Cloud Console or `gcloud firestore databases update` to enable PITR and delete protection for the production database. Configure Firestore backup schedules from the Firestore Backup and Restore page, then rerun the verifier and attach the JSON output to the incident or release evidence.
