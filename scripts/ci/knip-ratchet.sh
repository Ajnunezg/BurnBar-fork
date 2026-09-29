#!/usr/bin/env bash
# Ratchet gate for knip findings (unused files/deps/exports).
#
# The previous "Unused Dependencies" lanes piped knip to `|| true` — findings
# accumulated invisibly and the green check asserted nothing (diligence
# 2026-06-11, quality-gate theater). Raw enforcement would flip the lane red
# on ~119 pre-existing findings, so this uses the repo's established budget
# idiom: the TOTAL finding count may only go down. New debt fails the PR;
# paying debt down lets you lower the baseline in budgets/knip-baseline.json.
#
# Usage: scripts/ci/knip-ratchet.sh <package-dir> <baseline-key>
set -euo pipefail

package_dir="$1"
baseline_key="$2"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
baseline_file="$repo_root/budgets/knip-baseline.json"
if [[ ! -d "$repo_root/$package_dir" ]]; then
  echo "::error::knip-ratchet: package dir $package_dir does not exist" >&2
  exit 1
fi

# Admin harnesses import compiled `lib/*.js` from every 3.5 codebase plus the
# shared runtime; knip must see those edges on CI checkouts (no warm lib/).
# Build everything first so the ratchet matches local dev, skipping when all
# outputs are already present so repeated lanes stay cheap. Non-functions
# lanes (extension) never pay for this.
case "$package_dir" in
  functions | functions-identity | functions-sync | functions-media | packages/functions-shared)
    needs_build=false
    for lib in \
      packages/functions-shared/lib \
      functions/lib \
      functions-identity/lib \
      functions-sync/lib \
      functions-media/lib; do
      [[ -d "$repo_root/$lib" ]] || needs_build=true
    done
    if [[ "$needs_build" == "true" ]]; then
      for codebase in functions functions-identity functions-sync functions-media; do
        if [[ ! -x "$repo_root/$codebase/node_modules/.bin/tsc" ]]; then
          npm ci --prefix "$repo_root/$codebase"
        fi
      done
      bash "$repo_root/scripts/build-functions-all.sh" >/dev/null
    fi
    ;;
esac

# knip exits 0 when clean, 1 when it reports issues, and 2 or higher when it
# could not run (bad config, crash). The old `|| true` read a knip that never
# ran, or a missing package dir, as "0 findings" and passed the ratchet.
knip_status=0
output="$(cd "$repo_root/$package_dir" && npx knip --reporter compact 2>&1)" || knip_status=$?
printf '%s\n' "$output"
if [[ "$knip_status" -gt 1 ]]; then
  echo "::error::knip did not run cleanly for $baseline_key (exit $knip_status); a crash is not a clean scan."
  exit 1
fi

# knip's compact reporter prints one section header per issue type with the
# count in trailing parens; the sum is the total finding count.
total=0
while IFS= read -r count; do
  total=$((total + count))
done < <(printf '%s\n' "$output" | sed -n 's/.*(\([0-9][0-9]*\))$/\1/p')
if [[ "$knip_status" -eq 1 && "$total" -eq 0 ]]; then
  echo "::error::knip reported issues for $baseline_key (exit 1) but no section counts parsed; the compact reporter format changed."
  exit 1
fi

baseline="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$baseline_file" "$baseline_key")"

echo ""
echo "knip[$baseline_key]: findings=$total baseline=$baseline"
if [[ "$total" -gt "$baseline" ]]; then
  echo "::error::knip findings for $baseline_key rose from $baseline to $total. Remove the new unused code/deps, or — if a finding is a knip false positive — configure it in the package's knip config rather than raising the baseline."
  exit 1
fi
if [[ "$total" -lt "$baseline" ]]; then
  echo "::notice::knip findings for $baseline_key dropped to $total — lower the baseline in budgets/knip-baseline.json to lock the improvement in."
fi
echo "knip ratchet OK ($baseline_key)"
