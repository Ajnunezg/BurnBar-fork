#!/usr/bin/env bash
# Verify Firebase App Check enforcement for Cloud Firestore and Firebase Storage
# in the production project. For the canonical BurnBar project, also verifies
# that the Apple app has a complete DeviceCheck provider configuration. Fails
# closed when any required service or provider cannot be determined.
#
# Requires gcloud auth (or GOOGLE_APPLICATION_CREDENTIALS) and either
# GCLOUD_PROJECT / GOOGLE_CLOUD_PROJECT / OPENBURNBAR_FIREBASE_PROJECT.
#
# --receipt <file>  On a full pass only, also write a redaction-safe JSON
#                   receipt (services and modes, DeviceCheck key present; no
#                   project number, app ID or key ID). For the launch packet:
#   GCLOUD_PROJECT=burnbar bash scripts/ops/verify-firestore-app-check-enforcement.sh \
#     --receipt "launch-evidence/app-check-enforcement-$(date -u +%F).json"
#
set -euo pipefail

RECEIPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --receipt) RECEIPT="${2:?--receipt needs a file}"; shift 2 ;;
    --receipt=*) RECEIPT="${1#*=}"; shift ;;
    *) echo "ERROR: unknown argument: $1 (usage: $0 [--receipt <file>])" >&2; exit 64 ;;
  esac
done
if [[ -n "$RECEIPT" && "$RECEIPT" != /* ]]; then
  RECEIPT="$PWD/$RECEIPT"
fi

cd "$(dirname "$0")/../.."

# shellcheck source=scripts/lib/curl-bearer.sh
source scripts/lib/curl-bearer.sh

PROJECT="${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-${OPENBURNBAR_FIREBASE_PROJECT:-}}}"
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Set GCLOUD_PROJECT, GOOGLE_CLOUD_PROJECT, or OPENBURNBAR_FIREBASE_PROJECT." >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud is required for App Check enforcement verification." >&2
  exit 1
fi

project_number="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -z "$project_number" ]]; then
  echo "ERROR: Could not resolve project number for ${PROJECT}." >&2
  exit 1
fi

access_token="$(gcloud auth print-access-token 2>/dev/null || true)"
if [[ -z "$access_token" ]]; then
  echo "ERROR: gcloud auth print-access-token failed." >&2
  exit 1
fi

DEFAULT_SERVICES="firestore.googleapis.com,firebasestorage.googleapis.com"
DEFAULT_BURNBAR_APPLE_APP_ID="1:246956661961:ios:fe113f3ef2e1268d480118"
IFS=',' read -r -a requested_services <<< "${FIREBASE_APP_CHECK_SERVICES:-$DEFAULT_SERVICES}"
services=()
for raw_service in "${requested_services[@]}"; do
  # Strip leading/trailing whitespace via bash parameter expansion (no subprocess).
  service="${raw_service#"${raw_service%%[![:space:]]*}"}"
  service="${service%"${service##*[![:space:]]}"}"
  if [[ -n "$service" ]]; then
    services+=("$service")
  fi
done

if [[ "${#services[@]}" -eq 0 ]]; then
  echo "ERROR: No Firebase App Check services requested." >&2
  exit 1
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
failed=0
enforced_services=()
device_check_key_set=false

for service in "${services[@]}"; do
  service_name="projects/${project_number}/services/${service}"
  response="$(obb_curl_with_bearer_user_project \
    "${access_token}" \
    "${PROJECT}" \
    -fsS \
    "https://firebaseappcheck.googleapis.com/v1beta/${service_name}" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    echo "ERROR: Firebase App Check API request failed for ${service_name}." >&2
    failed=1
    continue
  fi

  enforcement_mode="$(python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(payload.get("enforcementMode") or "")
' <<< "$response" 2>/dev/null || true)"

  printf '%s\0%s\0%s\0%s\0' "$PROJECT" "$service" "${enforcement_mode:-}" "$timestamp" \
    | python3 -c '
import json, sys
project, service, mode, ts = sys.stdin.read().split("\0")[:4]
print(json.dumps({
    "project": project,
    "service": service,
    "enforcementMode": mode or "<unset>",
    "verifiedAt": ts,
}, separators=(",", ":")))
'

  if [[ "$enforcement_mode" != "ENFORCED" ]]; then
    echo "ERROR: ${service} App Check enforcementMode=${enforcement_mode:-<unset>} (expected ENFORCED)." >&2
    echo "Configure enforcement in Firebase Console → App Check → APIs before shipping." >&2
    failed=1
  else
    echo "PASS: ${service} App Check enforcementMode=ENFORCED for project ${PROJECT}."
    enforced_services+=("$service")
  fi
done

apple_app_id="${FIREBASE_APP_CHECK_DEVICECHECK_APP_ID:-}"
if [[ -z "$apple_app_id" && "$PROJECT" == "burnbar" ]]; then
  apple_app_id="$DEFAULT_BURNBAR_APPLE_APP_ID"
fi

if [[ -n "$apple_app_id" ]]; then
  device_check_name="projects/${project_number}/apps/${apple_app_id}/deviceCheckConfig"
  response="$(obb_curl_with_bearer_user_project \
    "${access_token}" \
    "${PROJECT}" \
    -fsS \
    "https://firebaseappcheck.googleapis.com/v1/${device_check_name}" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    echo "ERROR: Firebase App Check API request failed for ${device_check_name}." >&2
    failed=1
  else
    read -r key_id private_key_set < <(python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(payload.get("keyId") or "<unset>", str(payload.get("privateKeySet") is True).lower())
' <<< "$response" 2>/dev/null || true)

    printf '%s\0%s\0%s\0%s\0%s\0' \
      "$PROJECT" "$apple_app_id" "${key_id:-<unset>}" "${private_key_set:-false}" "$timestamp" \
      | python3 -c '
import json, sys
project, app_id, key_id, private_key_set, ts = sys.stdin.read().split("\0")[:5]
print(json.dumps({
    "project": project,
    "appleAppId": app_id,
    "deviceCheckKeyId": key_id,
    "deviceCheckPrivateKeySet": private_key_set == "true",
    "verifiedAt": ts,
}, separators=(",", ":")))
'

    if [[ "${key_id:-<unset>}" == "<unset>" || "${private_key_set:-false}" != "true" ]]; then
      echo "ERROR: Apple DeviceCheck provider is incomplete for ${apple_app_id}: keyId=${key_id:-<unset>}, privateKeySet=${private_key_set:-false}." >&2
      echo "Create a DeviceCheck private key in Apple Developer and upload it in Firebase Console -> App Check before shipping." >&2
      failed=1
    else
      echo "PASS: Apple DeviceCheck provider has a key for Firebase app ${apple_app_id}."
      device_check_key_set=true
    fi
  fi
elif [[ "${FIREBASE_APP_CHECK_REQUIRE_DEVICECHECK_CONFIG:-0}" == "1" ]]; then
  echo "ERROR: Set FIREBASE_APP_CHECK_DEVICECHECK_APP_ID when DeviceCheck config is required." >&2
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  [[ -z "$RECEIPT" ]] || echo "No receipt written: enforcement is not fully verified." >&2
  exit 1
fi

if [[ -n "$RECEIPT" ]]; then
  mkdir -p "$(dirname "$RECEIPT")"
  receipt_tmp="$(mktemp "${RECEIPT}.tmp.XXXXXX")"
  trap 'rm -f "$receipt_tmp"' EXIT
  python3 - "$receipt_tmp" "$PROJECT" "$timestamp" "$device_check_key_set" "${enforced_services[@]}" <<'PY'
import json
import sys

output, project, verified_at, device_check_key_set, *services = sys.argv[1:]
receipt = {
    "schema": "openburnbar.app-check-enforcement-receipt.v1",
    "schemaVersion": 1,
    "generatedAt": verified_at,
    "mode": "live",
    "ok": True,
    "project": project,
    "services": [{"service": service, "enforcementMode": "ENFORCED"} for service in services],
    "appleDeviceCheckKeySet": device_check_key_set == "true",
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2)
    handle.write("\n")
PY
  mv "$receipt_tmp" "$RECEIPT"
  trap - EXIT
  echo "RECEIPT: ${RECEIPT}"
fi
