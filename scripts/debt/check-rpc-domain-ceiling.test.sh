#!/usr/bin/env bash
#
# Self-test for scripts/debt/check-rpc-domain-ceiling.sh.
#
# Copies the live coverage map, generated method enum, isolated handlers and
# budget into throwaway trees, mutates them, and asserts the gate's exit code,
# so the ceiling is proven to catch growth rather than pass vacuously. No
# network; self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
gate="${here}/check-rpc-domain-ceiling.sh"
coverage_rel="OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonSocketRPCCoverage.swift"
domains_rel="OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/Domains"
methods_rel="OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCMethod.generated.swift"
budget_rel="budgets/daemon-rpc-domain-baseline.json"

pass=0
fail=0
tmp_roots=()
cleanup() {
  [[ "${#tmp_roots[@]}" -gt 0 ]] && for r in "${tmp_roots[@]}"; do rm -rf "${r}"; done
  true
}
trap cleanup EXIT

new_tree() {
  local r
  r="$(mktemp -d "${TMPDIR:-/tmp}/rpc-domain-ceiling-test.XXXXXX")"
  tmp_roots+=("${r}")
  mkdir -p "${r}/$(dirname "${coverage_rel}")" "${r}/$(dirname "${methods_rel}")" "${r}/budgets"
  cp "${repo}/${coverage_rel}" "${r}/${coverage_rel}"
  cp -R "${repo}/${domains_rel}" "${r}/${domains_rel}"
  cp "${repo}/${methods_rel}" "${r}/${methods_rel}"
  cp "${repo}/${budget_rel}" "${r}/${budget_rel}"
  printf '%s' "${r}"
}

# add_method <tree> <case> <set-name...>: registers a new enum case and adds it
# to each named domain set.
add_method() {
  local r="${1}" case_name="${2}"
  shift 2
  python3 - "${r}/${methods_rel}" "${r}/${coverage_rel}" "${case_name}" "$@" <<'PY'
import re, sys
methods, coverage, case, *sets = sys.argv[1:]
text = open(methods).read()
text = re.sub(r"(\n\s*case \w+ = \"[^\"]+\")", lambda m: f'{m.group(1)}\n    case {case} = "test.{case}"', text, count=1)
open(methods, "w").write(text)
text = open(coverage).read()
for name in sets:
    text = re.sub(rf"(static let {name}: Set<BurnBarRPCMethod> = \[)", lambda m: f"{m.group(1)}\n        .{case},", text, count=1)
open(coverage, "w").write(text)
PY
}

set_budget() {
  python3 - "${1}/${budget_rel}" "${2}" "${3}" <<'PY'
import json, sys
path, key, value = sys.argv[1:]
budget = json.load(open(path))
budget[key] = int(value)
json.dump(budget, open(path, "w"), indent=2)
PY
}

expect() {
  local want="${1}" label="${2}" tree="${3}"
  shift 3
  local got=0
  REPO_ROOT="${tree}" bash "${gate}" "$@" >/dev/null 2>&1 || got=$?
  if { [[ "${want}" == pass && "${got}" -eq 0 ]]; } || { [[ "${want}" == fail && "${got}" -ne 0 ]]; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: ${label} (expected ${want}, exit ${got})" >&2
  fi
}

t="$(new_tree)"
expect pass "live tree passes" "${t}"

t="$(new_tree)"
add_method "${t}" testActorBoundGrowth usage
expect fail "new method in an actor-bound domain" "${t}"

t="$(new_tree)"
add_method "${t}" testIsolatedGrowth chat
expect fail "new isolated-domain method with no handler case" "${t}"
python3 - "${t}/${domains_rel}/BurnBarChatRPCHandler.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read().replace("        default:\n", "        case .testIsolatedGrowth:\n            unhandled(call)\n        default:\n", 1)
open(path, "w").write(text)
PY
expect pass "new isolated-domain method with a handler case" "${t}"

t="$(new_tree)"
cat > "${t}/${domains_rel}/BurnBarSwitcherRPCHandler.swift" <<'SWIFT'
struct BurnBarSwitcherRPCHandler {
    static let domain: BurnBarDaemonRPCDomain = .switcher
    func handle(_ call: BurnBarDaemonRPCCall) {
        switch call.method {
        case .switcherActiveProfileApply:
            break
        default:
            break
        }
    }
}
SWIFT
expect fail "domain moved off the actor without ratcheting the budget" "${t}"
REPO_ROOT="${t}" bash "${gate}" --update >/dev/null
expect pass "domain moved off the actor after --update" "${t}"

t="$(new_tree)"
add_method "${t}" testUnrouted
expect fail "enum case in no domain" "${t}"

t="$(new_tree)"
add_method "${t}" testTwoDomains chat fleet
expect fail "method in two domains" "${t}"

t="$(new_tree)"
set_budget "${t}" maxMethodsPerDomain 20
expect fail "domain over the structural cap" "${t}"

t="$(new_tree)"
set_budget "${t}" maxTotalMethods 150
expect fail "surface over the total ceiling" "${t}"

t="$(new_tree)"
rm "${t}/${domains_rel}/BurnBarChatRPCHandler.swift"
expect fail "domain turned actor-bound without a budget entry" "${t}"

t="$(new_tree)"
add_method "${t}" testRaise usage
expect fail "--update refuses to raise a ceiling" "${t}" --update

t="$(new_tree)"
python3 - "${t}/${coverage_rel}" "${t}/${methods_rel}" <<'PY'
import re, sys
coverage, methods = sys.argv[1:]
for path, pattern in ((coverage, r"\n\s*\.usageInsights,?"), (methods, r"\n\s*case usageInsights = \"[^\"]+\"")):
    text = re.sub(pattern, "", open(path).read())
    open(path, "w").write(text)
PY
expect fail "retired actor-bound method leaves a stale ceiling" "${t}"
REPO_ROOT="${t}" bash "${gate}" --update >/dev/null
if python3 -c "import json,sys; b=json.load(open(sys.argv[1])); sys.exit(0 if b['actorBoundDomains']['usage']==5 and b['maxActorBoundMethods']==171 else 1)" "${t}/${budget_rel}"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: --update shrinks the actor-bound ceilings" >&2
fi
expect pass "shrunk budget still passes" "${t}"

echo "check-rpc-domain-ceiling self-test: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
