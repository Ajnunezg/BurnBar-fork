#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

script="scripts/ops/run-firestore-restore-drill.sh"
pass=0
fail=0
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/firestore-drill-test.XXXXXX")"
server_pid=""
trap 'if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$tmp_root"' EXIT

run_case() {
  local want="$1"
  local label="$2"
  shift 2
  local output="$tmp_root/${label}.out"
  local got
  set +e
  "$@" >"$output" 2>&1
  got=$?
  set -e
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  ok   (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL (exit %s, want %s) %s\n' "$got" "$want" "$label" >&2
    cat "$output" >&2
  fi
}

echo "run-firestore-restore-drill timeout validation self-test"

run_case 0 valid-default-timeouts \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 bash "$script"

run_case 0 valid-custom-timeouts \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=120 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=3600 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=5 \
    bash "$script"

run_case 64 arithmetic-expression-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS='1+1' \
    bash "$script"

run_case 64 zero-poll-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=0 \
    bash "$script"

run_case 64 oversized-cleanup-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=999999 \
    bash "$script"

run_case 64 zero-cleanup-poll-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_CLEANUP_POLL_SECONDS=0 \
    bash "$script"

backup_list='[
  {
    "name": "projects/burnbar/locations/us-central1/backups/wrong-newest",
    "database": "projects/burnbar/databases/staging",
    "state": "READY",
    "snapshotTime": "2026-06-17T20:00:00Z"
  },
  {
    "name": "projects/burnbar/locations/us-central1/backups/default-newest",
    "database": "projects/burnbar/databases/(default)",
    "state": "READY",
    "snapshotTime": "2026-06-17T19:00:00Z"
  },
  {
    "name": "projects/burnbar/locations/us-central1/backups/default-old",
    "database": "projects/burnbar/databases/(default)",
    "state": "READY",
    "snapshotTime": "2026-06-17T18:00:00Z"
  }
]'

run_case 0 backup-selection-filters-source-database \
  env FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY=1 \
    FIRESTORE_DRILL_MODE=backup \
    FIRESTORE_DRILL_BACKUP_LIST_JSON="$backup_list" \
    bash "$script"

run_case 2 explicit-wrong-database-backup-fails \
  env FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY=1 \
    FIRESTORE_DRILL_MODE=backup \
    FIRESTORE_DRILL_BACKUP_NAME="projects/burnbar/locations/us-central1/backups/wrong-newest" \
    FIRESTORE_DRILL_BACKUP_LIST_JSON="$backup_list" \
    bash "$script"

run_case 2 no-source-database-backup-fails \
  env FIRESTORE_DRILL_VALIDATE_BACKUP_SELECTION_ONLY=1 \
    FIRESTORE_DRILL_MODE=backup \
    FIRESTORE_DATABASE_ID=missing \
    FIRESTORE_DRILL_BACKUP_LIST_JSON="$backup_list" \
    bash "$script"

fake_bin="$tmp_root/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gcloud" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_GCLOUD_LOG:?}"
case "${FAKE_GCLOUD_MODE:-ga-success}:$*" in
  ga-success:firestore\ operations\ describe*)
    printf '{"name":"operations/test","done":true,"metadata":{"operationState":"SUCCESS"}}\n'
    ;;
  alpha-fallback:firestore\ operations\ describe*)
    exit 2
    ;;
  alpha-fallback:alpha\ firestore\ operations\ describe*)
    printf '{"name":"operations/test","done":true,"metadata":{"operationState":"SUCCESS","progressPercentage":{"completedWork":1,"estimatedWork":1}}}\n'
    ;;
  *)
    echo "unexpected fake gcloud invocation: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$fake_bin/gcloud"

operation_evidence="$tmp_root/operation-evidence"
gcloud_log="$tmp_root/gcloud.log"
run_case 0 operation-wait-prefers-ga-describe-and-persists-final-json \
  env PATH="$fake_bin:$PATH" \
    FAKE_GCLOUD_MODE=ga-success \
    FAKE_GCLOUD_LOG="$gcloud_log" \
    FIRESTORE_DRILL_VALIDATE_OPERATION_WAIT_ONLY=1 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=5 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=1 \
    FIRESTORE_DRILL_EVIDENCE_DIR="$operation_evidence" \
    FIRESTORE_DRILL_TS=ga \
    bash "$script"
if ! grep -q '"done":true' "$operation_evidence/firestore-restore-drill-ga.operation.json"; then
  fail=$((fail + 1))
  echo "FAIL: operation wait did not persist final GA operation JSON" >&2
fi

operation_evidence="$tmp_root/operation-evidence-alpha"
gcloud_log="$tmp_root/gcloud-alpha.log"
run_case 0 operation-wait-falls-back-to-alpha-describe \
  env PATH="$fake_bin:$PATH" \
    FAKE_GCLOUD_MODE=alpha-fallback \
    FAKE_GCLOUD_LOG="$gcloud_log" \
    FIRESTORE_DRILL_VALIDATE_OPERATION_WAIT_ONLY=1 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=5 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=1 \
    FIRESTORE_DRILL_EVIDENCE_DIR="$operation_evidence" \
    FIRESTORE_DRILL_TS=alpha \
    bash "$script"
if ! grep -q '^alpha firestore operations describe' "$gcloud_log"; then
  fail=$((fail + 1))
  echo "FAIL: operation wait did not use alpha fallback after GA describe failure" >&2
fi

echo "run-firestore-restore-drill end-to-end (fake gcloud, fake curl, fake Firestore REST)"

# Fake gcloud for whole drills: each database is a file under $FAKE_DRILL_STATE.
drill_bin="$tmp_root/drill-bin"
mkdir -p "$drill_bin"
cat >"$drill_bin/gcloud" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_GCLOUD_LOG:?}"
state="${FAKE_DRILL_STATE:?}"
flag() {
  local name="$1" arg
  shift
  for arg in "$@"; do
    case "$arg" in --"$name"=*) printf '%s\n' "${arg#*=}" ;; esac
  done
}
case "$*" in
  "auth print-access-token")
    echo "fake-drill-token"
    ;;
  "firestore databases clone "* | "firestore databases restore "*)
    database="$(flag destination-database "$@")"
    touch "$state/$database"
    printf '{"name":"projects/drill-test/databases/%s/operations/op-1","done":false}\n' "$database"
    ;;
  "firestore operations describe "*)
    if [[ "${FAKE_DRILL_OPERATION:-success}" == "error" ]]; then
      printf '{"name":"%s","done":true,"error":{"code":13,"message":"restore failed"}}\n' "$4"
    else
      printf '{"name":"%s","done":true,"metadata":{"operationState":"SUCCESSFUL"}}\n' "$4"
    fi
    ;;
  "firestore databases describe "*)
    database="$(flag database "$@")"
    if [[ "${FAKE_DRILL_CAPTURE:-ok}" != "ok" && "$*" == *--format=json* ]]; then
      echo "INTERNAL: describe failed" >&2
      exit 1
    fi
    if [[ ! -f "$state/$database" ]]; then
      echo "NOT_FOUND: database ${database}" >&2
      exit 1
    fi
    printf '{"name":"projects/drill-test/databases/%s","locationId":"nam5","type":"FIRESTORE_NATIVE"}\n' "$database"
    ;;
  "firestore indexes composite list "*)
    echo "[]"
    ;;
  "firestore databases update "*)
    ;;
  "firestore databases delete "*)
    if [[ "${FAKE_DRILL_DELETE:-ok}" != "ok" ]]; then
      echo "PERMISSION_DENIED: datastore.databases.delete" >&2
      exit 1
    fi
    rm "$state/$(flag database "$@")"
    ;;
  "firestore backups list "*)
    printf '%s\n' "${FAKE_DRILL_BACKUPS:?}"
    ;;
  *)
    echo "unexpected fake gcloud invocation: $*" >&2
    exit 2
    ;;
esac
SH
# Fake curl for the unmodified posture verifier, which reads the Admin API.
cat >"$drill_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  if [[ "$arg" == *fake-drill-token* ]]; then
    echo "bearer token leaked into curl argv" >&2
    exit 99
  fi
  url="$arg"
done
case "$url" in
  */backupSchedules)
    echo '{"backupSchedules":[{"name":"daily","retention":"604800s","dailyRecurrence":{}}]}'
    ;;
  *)
    pitr="POINT_IN_TIME_RECOVERY_ENABLED"
    if [[ "${FAKE_DRILL_POSTURE:-ok}" != "ok" ]]; then pitr="POINT_IN_TIME_RECOVERY_DISABLED"; fi
    printf '{"locationId":"nam5","pointInTimeRecoveryEnablement":"%s","deleteProtectionState":"DELETE_PROTECTION_ENABLED","versionRetentionPeriod":"604800s"}\n' "$pitr"
    ;;
esac
SH
chmod +x "$drill_bin/gcloud" "$drill_bin/curl"

# Fake Firestore REST: answers runAggregationQuery from $scenario, which each
# case rewrites, and logs every accepted request to $request_log.
cat >"$tmp_root/fake-firestore.mjs" <<'NODE'
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portFile, scenarioFile, requestLog] = process.argv.slice(2);
const ROUTE = /^\/v1\/projects\/([^/]+)\/databases\/([^/]+)\/documents:runAggregationQuery$/u;
const reply = (response, status, body) => {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
};
const server = createServer((request, response) => {
  let raw = "";
  request.on("data", (chunk) => {
    raw += chunk;
  });
  request.on("end", () => {
    const scenario = JSON.parse(readFileSync(scenarioFile, "utf8"));
    const route = ROUTE.exec(request.url);
    const body = JSON.parse(raw || "{}");
    const query = body.structuredAggregationQuery;
    const from = query?.structuredQuery?.from?.[0];
    const aggregation = query?.aggregations?.[0];
    if (request.method !== "POST" || !route || from?.allDescendants !== true || aggregation?.alias !== "count" || !aggregation.count) {
      return reply(response, 400, { error: { code: 400, status: "INVALID_ARGUMENT", message: `unexpected ${request.method} ${request.url}` } });
    }
    if (request.headers.authorization !== "Bearer fake-drill-token") {
      return reply(response, 401, { error: { code: 401, status: "UNAUTHENTICATED", message: "bad bearer token" } });
    }
    const database = decodeURIComponent(route[2]);
    const role = database.startsWith("dr-drill-") ? "restored" : "source";
    appendFileSync(requestLog, `${JSON.stringify({ role, project: route[1], database, collection: from.collectionId, readTime: body.readTime ?? null })}\n`);
    const error = scenario.errors?.[`${role}:${from.collectionId}`];
    if (error) return reply(response, error.code, { error });
    const counts = (role === "source" && scenario.sourceAt?.[body.readTime]) || scenario[role];
    return reply(response, 200, [
      { readTime: "2026-09-28T12:00:00Z" },
      { result: { aggregateFields: { count: { integerValue: String(counts[from.collectionId]) } } }, readTime: "2026-09-28T12:00:00Z" },
    ]);
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
NODE

# Receipt assertions shared by every end-to-end case.
cat >"$tmp_root/check-receipt.mjs" <<'NODE'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const { evaluateFirestoreRestoreDrillEvidence, validateFirestoreRestoreDrillReceipt } = await import(
  pathToFileURL(resolve("scripts/ops/firestore-restore-drill-verify.mjs")).href
);
const [dir, label, requestLog, expectations] = process.argv.slice(2);
const expected = JSON.parse(expectations);
const text = readFileSync(`${dir}/firestore-restore-drill-${label}.json`, "utf8");
const receipt = JSON.parse(text);

assert.deepEqual(validateFirestoreRestoreDrillReceipt(receipt), []);
assert.equal(readFileSync(`${dir}/latest-firestore-restore-drill.json`, "utf8"), text);
assert.equal(receipt.ok, expected.ok);
assert.equal(receipt.mode, expected.mode ?? "clone");
assert.equal(receipt.liveDrill, false);
assert.equal(receipt.restore.databaseId, `dr-drill-${label}`);
assert.equal(receipt.cleanup.requested, expected.cleanupRequested ?? true);
assert.equal(receipt.cleanup.databaseDeleted, expected.databaseDeleted ?? true);
// Redaction: no project ID, resource path, URL or token in a receipt meant for the repo.
assert.doesNotMatch(text, /drill-test|projects\/|https?:|fake-drill-token/u);
if (expected.failure) assert.match(receipt.failures.join("\n"), new RegExp(expected.failure, "mu"));
if (expected.counts) {
  assert.deepEqual(
    receipt.counts.map(({ collectionGroup, sourceCount, restoredCount }) => [collectionGroup, sourceCount, restoredCount]),
    expected.counts,
  );
}
if (expected.sourceReadTimes) {
  const requests = readFileSync(requestLog, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  const sourceReadTimes = [...new Set(requests.filter((request) => request.role === "source").map((request) => request.readTime))];
  assert.deepEqual(sourceReadTimes.sort(), expected.sourceReadTimes);
  assert.ok(requests.filter((request) => request.role === "restored").every((request) => request.readTime === null));
}
// The launch gate refuses fixture drills, even passing ones.
const verdict = evaluateFirestoreRestoreDrillEvidence(receipt, { now: new Date(receipt.generatedAt) });
assert.equal(verdict.ok, false);
assert.match(verdict.failures.join("\n"), /not a live drill/u);
NODE

scenario="$tmp_root/scenario.json"
request_log="$tmp_root/requests.jsonl"
port_file="$tmp_root/firestore.port"
echo '{}' >"$scenario"
node "$tmp_root/fake-firestore.mjs" "$port_file" "$scenario" "$request_log" &
server_pid=$!
for _ in $(seq 1 100); do
  if [[ -s "$port_file" ]]; then break; fi
  sleep 0.1
done
firestore_port="$(cat "$port_file")"

snapshot="2026-09-28T11:55:00Z"
matched_counts='{"entitlements":4,"cloud_vault_key_wrappers":2,"usage":9}'

# run_drill <want-exit> <label> <scenario-json> [VAR=value ...]
run_drill() {
  local want="$1"
  local label="$2"
  local evidence="$tmp_root/drill-$2"
  printf '%s\n' "$3" >"$scenario"
  shift 3
  : >"$request_log"
  mkdir -p "$evidence/state"
  run_case "$want" "drill-$label" env \
    PATH="$drill_bin:$PATH" \
    GCLOUD_PROJECT=drill-test \
    FAKE_GCLOUD_LOG="$evidence/gcloud.log" \
    FAKE_DRILL_STATE="$evidence/state" \
    FIRESTORE_DRILL_API_BASE="http://127.0.0.1:${firestore_port}/v1" \
    FIRESTORE_DRILL_EVIDENCE_DIR="$evidence" \
    FIRESTORE_DRILL_TS="$label" \
    FIRESTORE_DRILL_SNAPSHOT_TIME="$snapshot" \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=10 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=1 \
    FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=10 \
    "$@" \
    bash "$script"
}

# check_receipt <label> <expectations-json>
check_receipt() {
  run_case 0 "drill-$1-receipt" \
    node "$tmp_root/check-receipt.mjs" "$tmp_root/drill-$1" "$1" "$request_log" "$2"
}

# expect_file_check <label> <description> <command...>: extra assertion on a drill's side effects.
expect_file_check() {
  local label="$1"
  local description="$2"
  shift 2
  if "$@"; then
    pass=$((pass + 1))
    printf '  ok   %s: %s\n' "$label" "$description"
  else
    fail=$((fail + 1))
    printf '  FAIL %s: %s\n' "$label" "$description" >&2
  fi
}

run_drill 0 happy-clone "{\"source\":${matched_counts},\"restored\":${matched_counts}}"
check_receipt happy-clone "{\"ok\":true,\"counts\":[[\"entitlements\",4,4],[\"cloud_vault_key_wrappers\",2,2],[\"usage\",9,9]],\"sourceReadTimes\":[\"${snapshot}\"]}"
expect_file_check happy-clone "drill database deleted" test ! -e "$tmp_root/drill-happy-clone/state/dr-drill-happy-clone"

run_drill 1 mismatch "{\"source\":${matched_counts},\"restored\":{\"entitlements\":4,\"cloud_vault_key_wrappers\":2,\"usage\":8}}"
check_receipt mismatch '{"ok":false,"failure":"usage: restored count 8 does not match the source count 9"}'

zero_counts='{"entitlements":0,"cloud_vault_key_wrappers":0,"usage":0}'
run_drill 1 all-vacuous "{\"source\":${zero_counts},\"restored\":${zero_counts}}"
check_receipt all-vacuous '{"ok":false,"failure":"every collection group was empty at the snapshot time"}'

index_error='{"code":400,"status":"FAILED_PRECONDITION","message":"The query requires an index. You can create it here: https://console.firebase.google.com/v1/r/project/drill-test/firestore/indexes?create_composite=Cg"}'
run_drill 1 api-error "{\"source\":${matched_counts},\"restored\":${matched_counts},\"errors\":{\"restored:usage\":${index_error}}}"
check_receipt api-error '{"ok":false,"failure":"usage: restored count failed: FAILED_PRECONDITION \\(a collection-group index is missing"}'
expect_file_check api-error "Firestore's own message reaches the operator log" grep -q "create_composite" "$tmp_root/drill-api-error.out"

run_drill 1 cleanup-disabled "{\"source\":${matched_counts},\"restored\":${matched_counts}}" FIRESTORE_DRILL_CLEANUP=0
check_receipt cleanup-disabled '{"ok":false,"cleanupRequested":false,"databaseDeleted":false,"failure":"^cleanup-disabled: "}'
expect_file_check cleanup-disabled "drill database kept for incident inspection" test -e "$tmp_root/drill-cleanup-disabled/state/dr-drill-cleanup-disabled"

run_drill 1 delete-failure "{\"source\":${matched_counts},\"restored\":${matched_counts}}" \
  FAKE_DRILL_DELETE=fail FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=1 FIRESTORE_DRILL_CLEANUP_POLL_SECONDS=1
check_receipt delete-failure '{"ok":false,"databaseDeleted":false,"failure":"^the drill database was not deleted"}'

run_drill 1 restore-error "{\"source\":${matched_counts},\"restored\":${matched_counts}}" FAKE_DRILL_OPERATION=error
check_receipt restore-error '{"ok":false,"counts":[],"failure":"the restore operation did not finish cleanly"}'

# The index listing after the failed describe succeeds: the phase must still fail.
run_drill 1 capture-failure "{\"source\":${matched_counts},\"restored\":${matched_counts}}" FAKE_DRILL_CAPTURE=fail
check_receipt capture-failure '{"ok":false,"failure":"^could not describe the restored database"}'

run_drill 1 posture-failure "{\"source\":${matched_counts},\"restored\":${matched_counts}}" FAKE_DRILL_POSTURE=pitr-disabled
check_receipt posture-failure '{"ok":false,"failure":"source DR posture check failed"}'

backup_list='[{"name":"projects/drill-test/locations/nam5/backups/daily-1","database":"projects/drill-test/databases/(default)","state":"READY","snapshotTime":"2026-09-28T03:17:42.123456Z"}]'
run_drill 0 backup-range \
  "{\"sourceAt\":{\"2026-09-28T03:17:00Z\":{\"entitlements\":3,\"cloud_vault_key_wrappers\":2,\"usage\":10},\"2026-09-28T03:18:00Z\":{\"entitlements\":3,\"cloud_vault_key_wrappers\":2,\"usage\":12}},\"restored\":{\"entitlements\":3,\"cloud_vault_key_wrappers\":2,\"usage\":11}}" \
  FIRESTORE_DRILL_MODE=backup FAKE_DRILL_BACKUPS="$backup_list"
check_receipt backup-range '{"ok":true,"mode":"backup","counts":[["entitlements",{"floor":3,"ceil":3},3],["cloud_vault_key_wrappers",{"floor":2,"ceil":2},2],["usage",{"floor":10,"ceil":12},11]],"sourceReadTimes":["2026-09-28T03:17:00Z","2026-09-28T03:18:00Z"]}'

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: ${fail} Firestore restore-drill test(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} Firestore restore-drill checks"
