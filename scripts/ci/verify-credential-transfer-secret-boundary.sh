#!/usr/bin/env bash
# Credential-transfer decryption secrets must never be server-observable.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Every Functions deploy codebase plus the shared package: the credential
# transfer implementation lives in functions-identity since the codebase split,
# which the old functions/src-only list never scanned.
scan_paths=(
  android/app/src/main
  functions/src
  functions/scripts
  functions-identity/src
  functions-sync/src
  functions-media/src
  packages/functions-shared/src
  firestore.rules
)
for scan_path in "${scan_paths[@]}"; do
  if [[ ! -e "$scan_path" ]]; then
    echo "FAIL: scan path ${scan_path} does not exist (moved?); the boundary would go unscanned" >&2
    exit 1
  fi
done
if ! rg -q 'credential_transfers' "${scan_paths[@]}"; then
  echo "FAIL: no scan path mentions credential_transfers; the implementation moved out of scope" >&2
  exit 1
fi

failures=0

check_absent() {
  local label="$1"
  local pattern="$2"
  local status=0
  rg -n --pcre2 "$pattern" "${scan_paths[@]}" || status=$?
  case "$status" in
    0) echo "FAIL: ${label}" >&2; failures=$((failures + 1)) ;;
    1) echo "PASS: ${label}" ;;
    # rg exits 2 on errors (unreadable path, bad pattern), even after printing
    # matches; never read that as "absent".
    *) echo "FAIL: ${label}: rg exited ${status}" >&2; failures=$((failures + 1)) ;;
  esac
}

check_absent "no Firestore document(code) credential-transfer writes" 'document\s*\(\s*code\s*\)'
check_absent "no credential_transfers/\${code} Admin paths" 'credential_transfers/\$\{code\}'
check_absent "no legacy optional request.data?.code lookup" 'request\.data\?\.\s*code'
check_absent "no legacy Firestore rules code validator" 'validCredentialTransferCode'
check_absent "no transferCode/secretCode fields in production boundary" '\b(transferCode|secretCode)\b\s*[:=]'

rules_block="$(
  awk '
    /match \/credential_transfers\/\{/ { in_block = 1 }
    in_block { print }
    in_block && /--- Public read-only model-landscape metadata ---/ { in_block = 0 }
  ' firestore.rules
)"

if [[ -z "$rules_block" ]]; then
  # No block means Firestore's default deny: clients get nothing. Say so
  # instead of printing the generic PASS for a block that was never read.
  echo "PASS: credential_transfers has no rules block (default deny for clients)"
elif printf "%s\n" "$rules_block" | rg -n --pcre2 'allow\s+create|allow\s+(read,\s*write|read|write):\s*if\s+(?!false\b)'; then
  echo "FAIL: credential_transfers must not allow client create/read/write" >&2
  failures=$((failures + 1))
else
  echo "PASS: credential_transfers has no client create/read/write allowance"
fi

if (( failures > 0 )); then
  echo "FAIL: credential-transfer secret boundary regression detected" >&2
  exit 1
fi

echo "PASS: credential-transfer secret boundary"
