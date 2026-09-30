#!/usr/bin/env bash
# Prepare the Firebase Functions workspace on a CLEAN checkout.
#
# Every deploy codebase imports @openburnbar/functions-shared (and some import
# the entitlements / Signal envelope contract packages) through
# file:vendor/openburnbar/<pkg>. Those vendor copies are built output
# (packages/<pkg>/lib, never committed), so a job that only runs
# `npm ci --prefix functions` and then builds or tests fails on a fresh runner
# with TS2307 "Cannot find module '@openburnbar/functions-shared/...'" — the
# Full Harness Functions Integration and hermes-iroh-e2e jobs did exactly that
# on 99c2049e4b (run 36400161922), and `build:all` inside the functions test
# scripts also needs the other codebases installed.
#
# Order matches .github/workflows/fast-feedback.yml and
# scripts/build-functions-all.sh: install the shared package and every
# codebase, then build the local packages and sync them into each codebase's
# vendor/ dir. The codebase list is read from firebase.json so a new deploy
# codebase cannot silently fall out of the install.
#
# Usage: scripts/ci/setup-functions-workspace.sh [--print-codebases]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

codebases=()
while IFS= read -r codebase; do
  [[ -n "$codebase" ]] && codebases+=("$codebase")
done < <(node -e '
  const config = JSON.parse(require("node:fs").readFileSync("firebase.json", "utf8"));
  const entries = Array.isArray(config.functions) ? config.functions : [config.functions].filter(Boolean);
  for (const entry of entries) if (entry && typeof entry.source === "string") console.log(entry.source);
')

if [[ ${#codebases[@]} -eq 0 ]]; then
  echo "FAIL: firebase.json declares no functions codebases; refusing to report a prepared workspace." >&2
  exit 1
fi
for codebase in "${codebases[@]}"; do
  if [[ ! -f "$codebase/package.json" ]]; then
    echo "FAIL: firebase.json codebase '$codebase' has no package.json." >&2
    exit 1
  fi
done

if [[ "${1:-}" == "--print-codebases" ]]; then
  printf '%s\n' "${codebases[@]}"
  exit 0
fi

npm ci --prefix packages/functions-shared
for codebase in "${codebases[@]}"; do
  npm ci --prefix "$codebase"
done

# Build every local package explicitly (postinstall hooks only vendor-sync what
# is already built, so install order alone is not enough).
./scripts/build-signal-envelope-contracts.sh
./scripts/build-entitlements.sh
# Builds packages/functions-shared/lib and syncs every built package into each
# codebase's vendor/openburnbar/ (scripts/sync-functions-vendors.mjs).
./scripts/build-functions-shared.sh

missing=()
for codebase in "${codebases[@]}"; do
  if grep -q '"@openburnbar/functions-shared"' "$codebase/package.json" \
    && [[ ! -f "$codebase/vendor/openburnbar/functions-shared/package.json" ]]; then
    missing+=("$codebase")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "FAIL: functions-shared was not vendored into: ${missing[*]}" >&2
  exit 1
fi

echo "Functions workspace ready: ${#codebases[@]} codebases (${codebases[*]}) + packages/functions-shared."
