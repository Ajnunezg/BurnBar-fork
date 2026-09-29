#!/usr/bin/env bash
# Run a Firestore disaster-recovery drill against a throwaway database.
#
# Default mode uses PITR clone because it exercises the live point-in-time
# recovery path without restoring over production. Set FIRESTORE_DRILL_MODE=backup
# to restore from the newest READY backup instead.
#
# The drill verifies the restored data, not only the restore operation: it
# counts each collection group in FIRESTORE_DRILL_COLLECTION_GROUPS (default
# entitlements,cloud_vault_key_wrappers,usage) in the source at the snapshot
# time and in the restored database. Every run that gets past preflight writes
# a redaction-safe receipt (docs/schemas/firestore-restore-drill-receipt.schema.json)
# to ${EVIDENCE_DIR}/firestore-restore-drill-<ts>.json and
# latest-firestore-restore-drill.json, which scripts/commercial-launch-gate.mjs
# requires. The script exits non-zero unless that receipt is ok.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-burnbar}}"
DATABASE_ID="${FIRESTORE_DATABASE_ID:-(default)}"
MODE="${FIRESTORE_DRILL_MODE:-clone}"
DRILL_TS="${FIRESTORE_DRILL_TS:-$(date -u +%Y%m%d%H%M%S)}"
RESTORE_DATABASE_ID="${FIRESTORE_RESTORE_DATABASE_ID:-dr-drill-${DRILL_TS}}"
EVIDENCE_DIR="${FIRESTORE_DRILL_EVIDENCE_DIR:-launch-evidence}"
CLEANUP="${FIRESTORE_DRILL_CLEANUP:-1}"
VERIFY="scripts/ops/firestore-restore-drill-verify.mjs"

positive_integer_env() {
  local name="$1"
  local default_value="$2"
  local max_value="$3"
  local value="${!name:-$default_value}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "Invalid ${name}: expected a positive integer number of seconds, got '${value}'." >&2
    exit 64
  fi
  if (( value < 1 || value > max_value )); then
    echo "Invalid ${name}: expected 1..${max_value} seconds, got ${value}." >&2
    exit 64
  fi
  printf '%s\n' "$value"
}

validate_timeout_environment() {
  positive_integer_env FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS 900 86400 >/dev/null
  positive_integer_env FIRESTORE_DRILL_CLEANUP_POLL_SECONDS 30 3600 >/dev/null
  positive_integer_env FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS 14400 604800 >/dev/null
  positive_integer_env FIRESTORE_DRILL_WAIT_POLL_SECONDS 30 3600 >/dev/null
}

if [[ "${FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY:-0}" == "1" ]]; then
  validate_timeout_environment
  exit 0
fi

validate_timeout_environment

if [[ ! "$RESTORE_DATABASE_ID" =~ ^dr-drill-[a-z0-9-]+$ ]]; then
  echo "Refusing to operate on non-drill database id: ${RESTORE_DATABASE_ID}" >&2
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"

operation_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.operation.json"
database_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.database.json"
indexes_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.indexes.json"
posture_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.posture.json"
counts_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.counts.json"
summary_path="${EVIDENCE_DIR}/firestore-restore-drill-${DRILL_TS}.json"
latest_path="${EVIDENCE_DIR}/latest-firestore-restore-drill.json"

SOURCE_DATABASE_RESOURCE="projects/${PROJECT}/databases/${DATABASE_ID}"
SNAPSHOT_TIME="${FIRESTORE_DRILL_SNAPSHOT_TIME:-}"
BACKUP_NAME="${FIRESTORE_DRILL_BACKUP_NAME:-}"

list_firestore_backups_json() {
  if [[ -n "${FIRESTORE_DRILL_BACKUP_LIST_JSON:-}" ]]; then
    printf '%s\n' "$FIRESTORE_DRILL_BACKUP_LIST_JSON"
    return
  fi
  gcloud firestore backups list \
    --project="$PROJECT" \
    --format=json
}

select_ready_backup_for_source_database() {
  local requested_backup_name="${1:-}"
  local backups_json
  backups_json="$(list_firestore_backups_json)"
  BACKUPS_JSON="$backups_json" \
    SOURCE_DATABASE_RESOURCE="$SOURCE_DATABASE_RESOURCE" \
    REQUESTED_BACKUP_NAME="$requested_backup_name" \
    node - <<'NODE'
const sourceDatabase = process.env.SOURCE_DATABASE_RESOURCE;
const requested = process.env.REQUESTED_BACKUP_NAME || "";
let backups;
try {
  backups = JSON.parse(process.env.BACKUPS_JSON || "");
} catch (error) {
  console.error(`FAIL: invalid Firestore backup list JSON: ${error.message}`);
  process.exit(2);
}
if (!Array.isArray(backups)) {
  console.error("FAIL: Firestore backup list JSON must be an array.");
  process.exit(2);
}
const backupDatabase = (backup) => (typeof backup.database === "string" ? backup.database : "");
const backupName = (backup) => (typeof backup.name === "string" ? backup.name : "");
const readyForSource = (backup) => backup.state === "READY" && backupDatabase(backup) === sourceDatabase;
// Prints "<name>\t<snapshotTime>": the drill counts the source at the backup's snapshot time.
const printSelected = (backup) =>
  console.log(`${backupName(backup)}\t${typeof backup.snapshotTime === "string" ? backup.snapshotTime : ""}`);
if (requested) {
  const match = backups.find((backup) => backupName(backup) === requested);
  if (!match) {
    console.error(`FAIL: requested Firestore backup was not found: ${requested}`);
    process.exit(2);
  }
  if (match.state !== "READY") {
    console.error(`FAIL: requested Firestore backup is ${match.state || "UNKNOWN"}, not READY: ${requested}`);
    process.exit(2);
  }
  if (backupDatabase(match) !== sourceDatabase) {
    console.error(
      `FAIL: requested Firestore backup belongs to ${backupDatabase(match) || "<missing database>"}, expected ${sourceDatabase}.`,
    );
    process.exit(2);
  }
  printSelected(match);
  process.exit(0);
}
const candidates = backups
  .filter(readyForSource)
  .sort((a, b) => String(b.snapshotTime || "").localeCompare(String(a.snapshotTime || ""))
    || backupName(b).localeCompare(backupName(a)));
if (candidates.length === 0) {
  console.error(`FAIL: no READY Firestore backup found for ${sourceDatabase}.`);
  process.exit(2);
}
printSelected(candidates[0]);
NODE
}

if [[ "${FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY:-0}" == "1" ]]; then
  select_ready_backup_for_source_database "$BACKUP_NAME" >/dev/null
  exit 0
fi

portable_snapshot_time() {
  date -u -v-5M +%Y-%m-%dT%H:%M:00Z 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:00Z
}

# Succeeds only when this drill deleted its database: that is exactly what the
# receipt's cleanup.databaseDeleted claims.
cleanup_drill_database() {
  if [[ "$CLEANUP" != "1" ]]; then
    return
  fi
  if [[ ! "$RESTORE_DATABASE_ID" =~ ^dr-drill- ]]; then
    echo "Refusing cleanup for non-drill database id: ${RESTORE_DATABASE_ID}" >&2
    return 1
  fi
  local cleanup_timeout
  local cleanup_poll_seconds
  cleanup_timeout="$(positive_integer_env FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS 900 86400)"
  cleanup_poll_seconds="$(positive_integer_env FIRESTORE_DRILL_CLEANUP_POLL_SECONDS 30 3600)"
  local cleanup_deadline=$(( $(date +%s) + cleanup_timeout ))
  while gcloud firestore databases describe --database="$RESTORE_DATABASE_ID" --project="$PROJECT" >/dev/null 2>&1; do
    gcloud firestore databases update \
      --database="$RESTORE_DATABASE_ID" \
      --project="$PROJECT" \
      --no-delete-protection \
      --quiet >/dev/null 2>&1 || true
    if gcloud firestore databases delete \
      --database="$RESTORE_DATABASE_ID" \
      --project="$PROJECT" \
      --quiet >/dev/null 2>&1; then
      echo "==> deleted drill database ${RESTORE_DATABASE_ID}"
      return
    fi
    if (( $(date +%s) >= cleanup_deadline )); then
      echo "FAIL: timed out cleaning up drill database ${RESTORE_DATABASE_ID}" >&2
      return 1
    fi
    sleep "$cleanup_poll_seconds"
  done
  echo "==> drill database ${RESTORE_DATABASE_ID} not found; nothing was deleted" >&2
  return 1
}

wait_firestore_operation() {
  local operation="$1"
  local operation_snapshot_path="${2:-}"
  local wait_timeout
  local poll_seconds
  wait_timeout="$(positive_integer_env FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS 14400 604800)"
  poll_seconds="$(positive_integer_env FIRESTORE_DRILL_WAIT_POLL_SECONDS 30 3600)"
  local deadline=$(( $(date +%s) + wait_timeout ))
  while true; do
    local operation_json
    operation_json="$(describe_firestore_operation_json "$operation")"
    if [[ -n "$operation_snapshot_path" ]]; then
      printf '%s\n' "$operation_json" >"$operation_snapshot_path"
    fi
    local status
    status="$(
      OPERATION_JSON="$operation_json" python3 - <<'PY'
import json
import os
operation = json.loads(os.environ["OPERATION_JSON"])
done = operation.get("done") is True
error = operation.get("error")
metadata = operation.get("metadata", {})
state = metadata.get("operationState", "UNKNOWN")
progress = metadata.get("progressPercentage", {})
completed = progress.get("completedWork", "?")
estimated = progress.get("estimatedWork", "?")
print(json.dumps({
    "done": done,
    "state": state,
    "completed": completed,
    "estimated": estimated,
    "error": error,
}, separators=(",", ":")))
PY
    )"
    echo "    operation status: ${status}" >&2
    if [[ "$(STATUS="$status" python3 - <<'PY'
import json
import os
print("1" if json.loads(os.environ["STATUS"])["done"] else "0")
PY
)" == "1" ]]; then
      if [[ "$(STATUS="$status" python3 - <<'PY'
import json
import os
print("1" if json.loads(os.environ["STATUS"])["error"] else "0")
PY
)" == "1" ]]; then
        echo "FAIL: Firestore restore operation failed: ${status}" >&2
        return 1
      fi
      return
    fi
    if (( $(date +%s) >= deadline )); then
      echo "FAIL: Firestore restore operation did not finish within ${wait_timeout}s: ${operation}" >&2
      return 1
    fi
    sleep "$poll_seconds"
  done
}

describe_firestore_operation_json() {
  local operation="$1"
  local operation_json
  if operation_json="$(gcloud firestore operations describe "$operation" --project="$PROJECT" --format=json 2>/dev/null)"; then
    printf '%s\n' "$operation_json"
    return 0
  fi
  gcloud alpha firestore operations describe "$operation" --project="$PROJECT" --format=json
}

if [[ "${FIRESTORE_DRILL_VALIDATE_OPERATION_WAIT_ONLY:-0}" == "1" ]]; then
  wait_firestore_operation "${FIRESTORE_DRILL_OPERATION_NAME:-operations/test}" "$operation_path"
  exit 0
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "FAIL: gcloud CLI is required to run the Firestore restore drill" >&2
  exit 1
fi

case "$MODE" in
  clone)
    SNAPSHOT_TIME="${SNAPSHOT_TIME:-$(portable_snapshot_time)}"
    ;;
  backup)
    selected_backup="$(select_ready_backup_for_source_database "$BACKUP_NAME")"
    IFS=$'\t' read -r BACKUP_NAME SNAPSHOT_TIME <<<"$selected_backup"
    ;;
  *)
    echo "Unknown FIRESTORE_DRILL_MODE: ${MODE}; expected clone or backup" >&2
    exit 64
    ;;
esac

# Reject a bad collection-group list, API base, database ID or snapshot time
# now rather than after a multi-hour restore.
node "$VERIFY" preflight \
  --mode "$MODE" \
  --source-database "$DATABASE_ID" \
  --restore-database "$RESTORE_DATABASE_ID" \
  --snapshot-time "$SNAPSHOT_TIME"

phase_status=0

# Run one drill phase in a subshell with errexit on and record its exit status
# instead of aborting, so a failed phase still ends in a receipt. Call it as a
# plain command: inside an `if` or `||` list bash ignores errexit in the phase.
run_phase() {
  set +e
  ( set -e; "$@" )
  phase_status=$?
  set -e
  if [[ "$phase_status" -ne 0 ]]; then
    echo "FAIL: drill phase $1 exited ${phase_status}; the receipt records it" >&2
  fi
}

phase_passed() {
  if [[ "$phase_status" -eq 0 ]]; then echo true; else echo false; fi
}

verify_source_posture() {
  FIRESTORE_DR_JSON_ONLY=1 \
    GCLOUD_PROJECT="$PROJECT" \
    FIRESTORE_DATABASE_ID="$DATABASE_ID" \
    bash scripts/ops/verify-firestore-disaster-recovery.sh >"$posture_path"
}

start_restore() {
  if [[ "$MODE" == "clone" ]]; then
    echo "==> PITR clone ${SOURCE_DATABASE_RESOURCE} @ ${SNAPSHOT_TIME} -> ${RESTORE_DATABASE_ID}"
    gcloud firestore databases clone \
      --project="$PROJECT" \
      --source-database="$SOURCE_DATABASE_RESOURCE" \
      --destination-database="$RESTORE_DATABASE_ID" \
      --snapshot-time="$SNAPSHOT_TIME" \
      --format=json \
      >"$operation_path"
  else
    echo "==> backup restore ${BACKUP_NAME} (snapshot ${SNAPSHOT_TIME:-unknown}) -> ${RESTORE_DATABASE_ID}"
    gcloud firestore databases restore \
      --project="$PROJECT" \
      --source-backup="$BACKUP_NAME" \
      --destination-database="$RESTORE_DATABASE_ID" \
      --format=json \
      >"$operation_path"
  fi
}

wait_for_restore() {
  local operation
  operation="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).name)' "$operation_path")"
  echo "==> wait for ${operation}"
  wait_firestore_operation "$operation" "$operation_path"
}

capture_restored_database() {
  gcloud firestore databases describe --database="$RESTORE_DATABASE_ID" \
    --project="$PROJECT" \
    --format=json \
    >"$database_path"
  gcloud firestore indexes composite list \
    --project="$PROJECT" \
    --database="$RESTORE_DATABASE_ID" \
    --format=json \
    >"$indexes_path"
}

# The token reaches node through the environment only, never argv.
count_collection_groups() {
  local access_token
  access_token="$(gcloud auth print-access-token)"
  FIRESTORE_DRILL_ACCESS_TOKEN="$access_token" node "$VERIFY" counts \
    --project "$PROJECT" \
    --mode "$MODE" \
    --source-database "$DATABASE_ID" \
    --restore-database "$RESTORE_DATABASE_ID" \
    --snapshot-time "$SNAPSHOT_TIME" \
    --out "$counts_path"
}

cleanup_completed=false
trap 'if [[ "$cleanup_completed" != "true" ]]; then cleanup_drill_database || true; fi' EXIT

echo "==> verify production Firestore DR posture"
run_phase verify_source_posture
posture_ok="$(phase_passed)"

operation_done=false
capture_ok=false
elapsed_seconds=""
restore_started_at="$(date +%s)"
run_phase start_restore
restore_started="$(phase_passed)"
if [[ "$restore_started" == "true" ]]; then
  run_phase wait_for_restore
  operation_done="$(phase_passed)"
fi

if [[ "$operation_done" == "true" ]]; then
  elapsed_seconds=$(( $(date +%s) - restore_started_at ))
  echo "==> capture restored database and indexes"
  run_phase capture_restored_database
  capture_ok="$(phase_passed)"
  echo "==> count collection groups in the source snapshot and the restored database"
  rm -f "$counts_path"
  run_phase count_collection_groups
fi

cleanup_requested=false
database_deleted=false
if [[ "$CLEANUP" == "1" ]]; then
  cleanup_requested=true
  run_phase cleanup_drill_database
  database_deleted="$(phase_passed)"
fi
cleanup_completed=true

node "$VERIFY" receipt \
  --mode "$MODE" \
  --source-database "$DATABASE_ID" \
  --snapshot-time "$SNAPSHOT_TIME" \
  --restore-database "$RESTORE_DATABASE_ID" \
  --posture-ok "$posture_ok" \
  --restore-started "$restore_started" \
  --operation-done "$operation_done" \
  --elapsed-seconds "$elapsed_seconds" \
  --capture-ok "$capture_ok" \
  --counts "$counts_path" \
  --cleanup-requested "$cleanup_requested" \
  --database-deleted "$database_deleted" \
  --out "$summary_path" \
  --latest "$latest_path"
