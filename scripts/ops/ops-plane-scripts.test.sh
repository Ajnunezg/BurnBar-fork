#!/usr/bin/env bash
# Offline behavior controls for the production ops-plane scripts that
# scripts/ci/verify-ops-readiness.sh used to check with `bash -n` only.
# A syntax check proves nothing about a verifier; these cases prove each one
# PASSes on a healthy fixture and FAILs (or refuses to run) on a bad one.
#
# Every external dependency (gcloud, curl, firebase, npm, node) is a stub on
# PATH or the script runs from a scratch copy, so no case can reach GCP,
# Firebase or GitHub, and no deploy/apply path can execute.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
cases=0

expect() {
  local desc="$1" want="$2" rc="$3" out="$4" needle="${5:-}"
  cases=$((cases + 1))
  if [[ "$rc" -ne "$want" ]]; then
    echo "FAIL: $desc: expected exit $want, got $rc" >&2
    printf '%s\n' "$out" >&2
    fail=1
    return
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: $desc: output missing '$needle'" >&2
    printf '%s\n' "$out" >&2
    fail=1
    return
  fi
  echo "ok: $desc (exit $rc)"
}

# ── verify-firestore-disaster-recovery.sh ──────────────────────────────────
# Stub gcloud (token) and curl (serves the database or backupSchedules JSON by
# URL suffix) so the posture verifier's decision logic runs end to end.
dr_bin="$tmp/dr-bin"
mkdir -p "$dr_bin"
cat >"$dr_bin/gcloud" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "auth print-access-token" ]] && { echo "fixture-token"; exit 0; }
echo "unexpected gcloud call: $*" >&2
exit 97
EOF
cat >"$dr_bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  */backupSchedules) cat "$DR_FIXTURE_DIR/schedules.json" ;;
  https://firestore.googleapis.com/v1/projects/*/databases/*) cat "$DR_FIXTURE_DIR/database.json" ;;
  *) echo "unexpected curl url: $url" >&2; exit 97 ;;
esac
EOF
chmod +x "$dr_bin/gcloud" "$dr_bin/curl"

dr_case() {
  local desc="$1" want="$2" needle="$3" database="$4" schedules="$5"
  local dir="$tmp/dr-$cases"
  mkdir -p "$dir"
  printf '%s\n' "$database" >"$dir/database.json"
  printf '%s\n' "$schedules" >"$dir/schedules.json"
  local out rc
  if out="$(PATH="$dr_bin:$PATH" DR_FIXTURE_DIR="$dir" GCLOUD_PROJECT=fixture-project \
    bash "$repo_root/scripts/ops/verify-firestore-disaster-recovery.sh" 2>&1)"; then rc=0; else rc=$?; fi
  expect "DR verifier: $desc" "$want" "$rc" "$out" "$needle"
}

healthy_db='{"locationId":"nam5","pointInTimeRecoveryEnablement":"POINT_IN_TIME_RECOVERY_ENABLED","deleteProtectionState":"DELETE_PROTECTION_ENABLED","versionRetentionPeriod":"604800s","earliestVersionTime":"2026-09-21T00:00:00Z"}'
healthy_schedules='{"backupSchedules":[{"name":"projects/fixture-project/databases/(default)/backupSchedules/daily","retention":"1209600s","dailyRecurrence":{}}]}'

dr_case "healthy PITR + delete protection + daily backups passes" 0 "PASS: Firestore disaster-recovery posture" \
  "$healthy_db" "$healthy_schedules"
dr_case "PITR disabled fails" 1 "pointInTimeRecoveryEnablement is not POINT_IN_TIME_RECOVERY_ENABLED" \
  "${healthy_db/POINT_IN_TIME_RECOVERY_ENABLED/POINT_IN_TIME_RECOVERY_DISABLED}" "$healthy_schedules"
dr_case "delete protection off fails" 1 "deleteProtectionState is not DELETE_PROTECTION_ENABLED" \
  "${healthy_db/DELETE_PROTECTION_ENABLED/DELETE_PROTECTION_DISABLED}" "$healthy_schedules"
dr_case "retention under 7 days fails" 1 "versionRetentionPeriod is below 7 days" \
  "${healthy_db/604800s/3600s}" "$healthy_schedules"
dr_case "no backup schedule fails" 1 "no Firestore backup schedules configured" \
  "$healthy_db" '{"backupSchedules":[]}'
dr_case "schedule without recurrence fails" 1 "none have recurrence and retention" \
  "$healthy_db" '{"backupSchedules":[{"name":"x","retention":"1209600s"}]}'

nogcloud_bin="$tmp/nogcloud-bin"
mkdir -p "$nogcloud_bin"
for tool in bash python3 dirname; do ln -sf "$(command -v "$tool")" "$nogcloud_bin/$tool"; done
if out="$(PATH="$nogcloud_bin" bash "$repo_root/scripts/ops/verify-firestore-disaster-recovery.sh" 2>&1)"; then rc=0; else rc=$?; fi
expect "DR verifier: missing gcloud fails closed" 1 "$rc" "$out" "gcloud CLI is required"

# ── resolve-functions-base-url.sh ──────────────────────────────────────────
# Offline topology mode plus the Firebase function-list fixture path.
if out="$(env -u FUNCTIONS_BASE_URL -u FUNCTIONS_LIST_JSON FIREBASE_PROJECT=fixture-project FIREBASE_RC=/nonexistent \
  bash "$repo_root/scripts/ops/resolve-functions-base-url.sh" --print-json 2>&1)"; then rc=0; else rc=$?; fi
expect "URL resolver: --print-json derives the default regional base" 0 "$rc" "$out" \
  '"baseUrl": "https://us-central1-fixture-project.cloudfunctions.net"'
expect "URL resolver: emulator project allowlist stays closed" 0 "$rc" "$out" \
  '"emulatorProjectIds": ['

list_json='{"result":[{"id":"healthLive","uri":"https://healthlive-abc123-uc.a.run.app"},{"id":"healthReady","uri":"https://healthready-abc123-uc.a.run.app"}]}'
if out="$(env -u FUNCTIONS_BASE_URL FIREBASE_PROJECT=fixture-project FIREBASE_RC=/nonexistent FUNCTIONS_LIST_JSON="$list_json" \
  bash "$repo_root/scripts/ops/resolve-functions-base-url.sh" 2>&1)"; then rc=0; else rc=$?; fi
expect "URL resolver: deployed healthLive URI wins over the default base" 0 "$rc" "$out" \
  "FUNCTIONS_BASE_URL=https://healthlive-abc123-uc.a.run.app"
if out="$(FIREBASE_RC=/nonexistent bash "$repo_root/scripts/ops/resolve-functions-base-url.sh" --bogus 2>&1)"; then rc=0; else rc=$?; fi
expect "URL resolver: unknown argument is rejected" 1 "$rc" "$out" "unknown argument: --bogus"

# ── scripts that must refuse to run unconfigured ───────────────────────────
# Run scratch copies (their `cd ../..` lands in the scratch tree) with deploy
# and apply tools stubbed to record any call, so a regression in the guard can
# never reach Firebase or GCP from this test.
guard_root="$tmp/guard"
mkdir -p "$guard_root/scripts/ops" "$guard_root/functions" "$guard_root/bin"
cp "$repo_root/scripts/ops/activate-production-ops-plane.sh" "$repo_root/scripts/ops/deploy-health-functions.sh" \
  "$guard_root/scripts/ops/"
for tool in firebase npm gcloud node; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/invoked.log"\nexit 0\n' "$tool" "$guard_root" >"$guard_root/bin/$tool"
  chmod +x "$guard_root/bin/$tool"
done

if out="$(env -u OPS_ALERT_CHANNELS PATH="$guard_root/bin:$PATH" bash "$guard_root/scripts/ops/activate-production-ops-plane.sh" 2>&1)"; then rc=0; else rc=$?; fi
expect "activate ops plane: refuses without OPS_ALERT_CHANNELS" 1 "$rc" "$out" "Set OPS_ALERT_CHANNELS"

if out="$(PATH="$guard_root/bin:$PATH" OPENBURNBAR_SOURCE_COMMIT=0000000 FUNCTION_VERSION=v0.0.0-test \
  bash "$guard_root/scripts/ops/deploy-health-functions.sh" 2>&1)"; then rc=0; else rc=$?; fi
expect "deploy health functions: refuses without the production runtime config" 1 "$rc" "$out" \
  "refusing to deploy health functions with empty production runtime config"

cases=$((cases + 1))
if [[ -s "$guard_root/invoked.log" ]]; then
  echo "FAIL: a refused script still invoked a deploy/apply tool:" >&2
  cat "$guard_root/invoked.log" >&2
  fail=1
else
  echo "ok: refused scripts invoked no firebase/npm/gcloud/node"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "ops-plane-scripts.test.sh: FAILED" >&2
  exit 1
fi
echo "PASS: $cases ops-plane script behavior controls"
