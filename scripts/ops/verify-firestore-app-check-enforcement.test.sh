#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-appcheck-provider-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin"

cat > "$fixture/bin/gcloud" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "projects describe") printf '246956661961\n' ;;
  "auth print-access-token") printf 'fixture-access-token\n' ;;
  *) exit 2 ;;
esac
SH

cat > "$fixture/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
  */services/firestore.googleapis.com)
    printf '{"enforcementMode":"ENFORCED"}\n'
    ;;
  */services/firebasestorage.googleapis.com)
    printf '{"enforcementMode":"ENFORCED"}\n'
    ;;
  */deviceCheckConfig)
    if [[ "${MOCK_DEVICECHECK_CONFIG:-missing}" == "configured" ]]; then
      printf '{"keyId":"DEVICE1234","privateKeySet":true,"tokenTtl":"3600s"}\n'
    else
      printf '{"tokenTtl":"3600s"}\n'
    fi
    ;;
  *) exit 22 ;;
esac
SH

chmod +x "$fixture/bin/gcloud" "$fixture/bin/curl"

common_env=(
  env -i
  HOME="${HOME}"
  PATH="$fixture/bin:/usr/bin:/bin"
  OPENBURNBAR_FIREBASE_PROJECT=burnbar
)

if "${common_env[@]}" bash "$repo_root/scripts/ops/verify-firestore-app-check-enforcement.sh" \
  >"$fixture/missing.out" 2>"$fixture/missing.err"; then
  echo "expected missing DeviceCheck credentials to fail" >&2
  exit 1
fi
grep -Fq 'Apple DeviceCheck provider is incomplete' "$fixture/missing.err"

"${common_env[@]}" MOCK_DEVICECHECK_CONFIG=configured \
  bash "$repo_root/scripts/ops/verify-firestore-app-check-enforcement.sh" \
  >"$fixture/configured.out" 2>"$fixture/configured.err"
grep -Fq 'PASS: Apple DeviceCheck provider has a key' "$fixture/configured.out"

# --receipt: written only on a full pass, and redaction-safe.
if "${common_env[@]}" bash "$repo_root/scripts/ops/verify-firestore-app-check-enforcement.sh" \
  --receipt "$fixture/refused.json" >/dev/null 2>"$fixture/refused.err"; then
  echo "expected missing DeviceCheck credentials to fail with --receipt" >&2
  exit 1
fi
grep -Fq 'No receipt written' "$fixture/refused.err"
[[ ! -e "$fixture/refused.json" ]] || { echo "a failed probe must not write a receipt" >&2; exit 1; }

"${common_env[@]}" MOCK_DEVICECHECK_CONFIG=configured \
  bash "$repo_root/scripts/ops/verify-firestore-app-check-enforcement.sh" \
  --receipt "$fixture/evidence/app-check.json" >/dev/null 2>&1
python3 - "$fixture/evidence/app-check.json" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1]))
assert receipt["schema"] == "openburnbar.app-check-enforcement-receipt.v1", receipt
assert receipt["ok"] is True and receipt["mode"] == "live", receipt
assert receipt["appleDeviceCheckKeySet"] is True, receipt
assert [s["service"] for s in receipt["services"]] == ["firestore.googleapis.com", "firebasestorage.googleapis.com"], receipt
assert all(s["enforcementMode"] == "ENFORCED" for s in receipt["services"]), receipt
text = json.dumps(receipt)
for secret in ("246956661961", "DEVICE1234", ":ios:"):
    assert secret not in text, f"receipt leaks {secret}"
PY

if "${common_env[@]}" bash "$repo_root/scripts/ops/verify-firestore-app-check-enforcement.sh" --bogus >/dev/null 2>&1; then
  echo "expected an unknown argument to be refused" >&2
  exit 1
fi

echo "PASS: App Check verifier rejects missing DeviceCheck credentials, accepts a complete provider, and writes a receipt only on a full pass."
