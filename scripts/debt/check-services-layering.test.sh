#!/usr/bin/env bash
# Self-test for scripts/debt/services_layering.py (Services layering + acyclicity
# fitness gate, docs/SERVICES_DECOMPOSITION_PROGRAM.md).
#
# Builds a synthetic fixture repo in mktemp -d — a minimal services-layers.json
# manifest plus a handful of Swift files — baselines it with --update, then runs
# each case against a fresh copy and asserts the exit code plus a stdout/stderr
# substring. Prints one ok/FAIL line per case; exits non-zero if any case fails.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/services_layering.py"
pass=0
fail=0

# new_fixture <variant: clean|debt>
# Writes a fixture repo and echoes its path. "clean" has no debt; "debt" seeds
# one upward reference (Services/DataStore -> Services/FeatureA) for the
# grow/shrink cases.
new_fixture() {
  local variant="${1:-clean}"
  local r
  r="$(mktemp -d)"
  mkdir -p "${r}/config" "${r}/budgets" \
    "${r}/AgentLens/Services/Foundation" \
    "${r}/AgentLens/Services/DataStore" \
    "${r}/AgentLens/Services/FeatureA" \
    "${r}/AgentLens/Services/FeatureB" \
    "${r}/AgentLens/Views"
  cat >"${r}/config/services-layers.json" <<'JSON'
{
  "layers": ["foundation", "contracts", "persistence", "feature", "app"],
  "contractsDirectory": "Contracts",
  "contractsLayer": "contracts",
  "servicesRootComponent": "Services/(root)",
  "components": [
    { "name": "Services/Foundation", "layer": "foundation", "paths": ["AgentLens/Services/Foundation"] },
    { "name": "Services/DataStore", "layer": "persistence", "paths": ["AgentLens/Services/DataStore"] },
    { "name": "Services/FeatureA", "layer": "feature", "paths": ["AgentLens/Services/FeatureA"] },
    { "name": "Services/FeatureB", "layer": "feature", "paths": ["AgentLens/Services/FeatureB"] },
    { "name": "Views", "layer": "app", "paths": ["AgentLens/Views"] },
    { "name": "Services/(root)", "layer": "feature", "paths": [] }
  ]
}
JSON
  cat >"${r}/AgentLens/Services/Foundation/F.swift" <<'SWIFT'
import Foundation

struct FoundationThing {
    let id: String
}
SWIFT
  cat >"${r}/AgentLens/Services/FeatureA/A.swift" <<'SWIFT'
import Foundation

struct FeatureAThing {
    let store: DataStoreThing
}
SWIFT
  cat >"${r}/AgentLens/Services/FeatureB/B.swift" <<'SWIFT'
import Foundation

struct FeatureBThing {
    let id: String
}
SWIFT
  cat >"${r}/AgentLens/Views/V.swift" <<'SWIFT'
import Foundation

struct ViewThing {
    let feature: FeatureAThing
}
SWIFT
  if [[ "${variant}" == "debt" ]]; then
    cat >"${r}/AgentLens/Services/DataStore/D.swift" <<'SWIFT'
import Foundation

struct DataStoreThing {
    let base: FoundationThing
    let upward: FeatureAThing
}
SWIFT
  else
    cat >"${r}/AgentLens/Services/DataStore/D.swift" <<'SWIFT'
import Foundation

struct DataStoreThing {
    let base: FoundationThing
}
SWIFT
  fi
  printf '%s' "${r}"
}

# run_gate <fixture> — runs --check (the default) and echoes combined output.
run_gate() {
  local r="${1}"
  python3 "${tool}" --root "${r}" --check 2>&1
  return $?
}

# assert_case <label> <want_rc> <stream: stdout|stderr> <needle> <output> <got_rc>
assert_case() {
  local label="${1}" want="${2}" stream="${3}" needle="${4}" out="${5}" got="${6}"
  if [[ "${got}" -ne "${want}" ]]; then
    fail=$((fail + 1))
    printf 'FAIL: %s (expected exit %s, got %s)\n%s\n' "${label}" "${want}" "${got}" "${out}" >&2
    return
  fi
  if [[ -n "${needle}" ]] && ! echo "${out}" | grep -qF "${needle}"; then
    fail=$((fail + 1))
    printf 'FAIL: %s (%s does not contain "%s")\n%s\n' "${label}" "${stream}" "${needle}" "${out}" >&2
    return
  fi
  pass=$((pass + 1))
  printf 'ok: %s\n' "${label}"
}

# run_case <label> <want_rc> <stream> <needle> <variant> <mutator-fn>
run_case() {
  local label="${1}" want="${2}" stream="${3}" needle="${4}" variant="${5}" mutator="${6}"
  local r out rc
  r="$(new_fixture "${variant}")"
  python3 "${tool}" --root "${r}" --update >/dev/null 2>&1
  "${mutator}" "${r}"
  set +e
  out="$(run_gate "${r}")"
  rc=$?
  set -e
  assert_case "${label}" "${want}" "${stream}" "${needle}" "${out}" "${rc}"
  rm -rf "${r}"
}

noop() { :; }
mut_b() { cat >>"${1}/AgentLens/Services/DataStore/D.swift" <<'SWIFT'

struct DataStoreUsesFeatureA {
    let a: FeatureAThing
}
SWIFT
}
mut_c() {
  cat >>"${1}/AgentLens/Services/FeatureA/A.swift" <<'SWIFT'

struct ANeedsB {
    let b: FeatureBThing
}
SWIFT
  cat >>"${1}/AgentLens/Services/FeatureB/B.swift" <<'SWIFT'

struct BNeedsA {
    let a: FeatureAThing
}
SWIFT
}
mut_d() { cat >"${1}/AgentLens/Services/Loose.swift" <<'SWIFT'
import Foundation

struct LooseThing {
    let id: String
}
SWIFT
}
mut_e() {
  mkdir -p "${1}/AgentLens/Services/Undeclared"
  cat >"${1}/AgentLens/Services/Undeclared/X.swift" <<'SWIFT'
import Foundation

struct UndeclaredThing {
    let id: String
}
SWIFT
}
mut_f() { cat >"${1}/AgentLens/Services/DataStore/D2.swift" <<'SWIFT'
import Foundation

struct DataStoreAlsoUsesFeatureA {
    let a: FeatureAThing
}
SWIFT
}
mut_g() {
  # Remove the baselined upward reference entirely.
  cat >"${1}/AgentLens/Services/DataStore/D.swift" <<'SWIFT'
import Foundation

struct DataStoreThing {
    let base: FoundationThing
}
SWIFT
}
mut_h() { cat >"${1}/AgentLens/Services/DataStore/Nested.swift" <<'SWIFT'
import Foundation

// A NESTED declaration shadows the FeatureA top-level name: the file declares
// the identifier itself, so it never counts as a reference to FeatureA.
struct Outer {
    struct FeatureAThing {
        let id: String
    }
    let nested: FeatureAThing
}
SWIFT
}
mut_i() { cat >"${1}/AgentLens/Services/DataStore/Text.swift" <<'SWIFT'
import Foundation

// FeatureAThing appears here only inside comment and string-literal contexts.
struct DataStoreText {
    /* FeatureAThing in a block comment. */
    let label = "FeatureAThing in a string literal"
}
SWIFT
}
mut_j() {
  mkdir -p "${1}/AgentLens/Services/FeatureA/Contracts"
  cat >"${1}/AgentLens/Services/FeatureA/Contracts/C.swift" <<'SWIFT'
import Foundation

// Contracts sit BELOW persistence: a contracts file must not reach up into
// Services/DataStore.
struct FeatureAContract {
    let store: DataStoreThing
}
SWIFT
}

mut_k() {
  mkdir -p "${1}/AgentLens/Services/Rogue/Contracts"
  cat >"${1}/AgentLens/Services/Rogue/Contracts/X.swift" <<'SWIFT'
import Foundation

struct RogueContract {
    let id: String
}
SWIFT
}
mut_l() {
  cat >>"${1}/AgentLens/Services/FeatureA/A.swift" <<'SWIFT'

struct SharedName {
    let id: String
}
SWIFT
  cat >>"${1}/AgentLens/Services/FeatureB/B.swift" <<'SWIFT'

struct SharedName {
    let id: String
}
SWIFT
}

# run_base_case <label> <want_rc> <needle> <variant> <commit-baseline: yes|no> <mutator-fn> [base-ref]
# Commits the fixture to a throwaway git repo (with or without its baseline),
# applies the mutator, re-baselines with --update, then runs --check --base
# against the commit, so the committed baseline is held to the base's.
run_base_case() {
  local label="${1}" want="${2}" needle="${3}" variant="${4}" with_baseline="${5}" mutator="${6}" ref="${7:-}"
  local r out rc
  r="$(new_fixture "${variant}")"
  if [[ "${with_baseline}" == "yes" ]]; then
    python3 "${tool}" --root "${r}" --update >/dev/null 2>&1
  fi
  git -C "${r}" init -q
  git -C "${r}" add -A
  git -C "${r}" -c user.name=selftest -c user.email=selftest@example.invalid commit -qm base
  "${mutator}" "${r}"
  python3 "${tool}" --root "${r}" --update >/dev/null 2>&1
  set +e
  out="$(CI=true python3 "${tool}" --root "${r}" --check --base "${ref:-HEAD}" 2>&1)"
  rc=$?
  set -e
  assert_case "${label}" "${want}" "combined" "${needle}" "${out}" "${rc}"
  rm -rf "${r}"
}

echo "check-services-layering self-test"

run_case "clean tree passes" 0 stdout "services-layering: OK" clean noop
run_case "R1: persistence referencing a feature type fails" 1 stderr "R1 upward" clean mut_b
run_case "R2: same-layer feature<->feature cycle fails" 1 stderr "R2 cycle" clean mut_c
run_case "R3: new file in Services root fails" 1 stderr "R3 root" clean mut_d
run_case "R4: file in an undeclared Services dir fails" 1 stderr "R4 undeclared" clean mut_e
run_case "shrink-only: baselined debt edge grown by a second file fails" 1 stderr "grew" debt mut_f
run_case "retired baselined debt passes and reports improvement" 0 stdout "Improved" debt mut_g
run_case "nested type shadowing a feature type name is not an edge" 0 stdout "services-layering: OK" clean mut_h
run_case "type names in comments/strings are not edges" 0 stdout "services-layering: OK" clean mut_i
run_case "R1: contracts referencing persistence fails" 1 stderr "R1 upward" clean mut_j
run_case "R4: contracts-only dir under an undeclared feature fails" 1 stderr "R4 undeclared" clean mut_k
run_case "R5: a top-level type declared in two components fails" 1 stderr "R5 ambiguous" clean mut_l
run_base_case "base: baseline raised to cover a grown edge fails" 1 "shrink-only baseline raises upward" debt yes mut_f
run_base_case "base: baseline adding a new debt key fails" 1 "shrink-only baseline adds upward key" clean yes mut_b
run_base_case "base: baseline unchanged vs base passes" 0 "services-layering: OK" debt yes noop
run_base_case "base: baseline shrunk vs base passes" 0 "services-layering: OK" debt yes mut_g
run_base_case "base: baseline absent at base is allowed" 0 "is new relative to" clean no noop
run_base_case "base: unresolvable base fails closed in CI" 1 "does not resolve" clean yes noop 0000000000000000000000000000000000000000

mut_m() {
  mkdir -p "${1}/AgentLens/Persistence"
  cat >"${1}/AgentLens/Persistence/P.swift" <<'SWIFT'
import Foundation

struct PersistenceThing {
    let id: String
}
SWIFT
}
run_case "R4: file under an undeclared AgentLens root fails" 1 stderr "R4 undeclared" clean mut_m

# ── Regression: the gate is wired into the CI debt-budgets job ───────────────
workflow="${here}/../../.github/workflows/fast-feedback.yml"
if [[ -f "${workflow}" ]] && grep -q "check-services-layering.sh" "${workflow}"; then
  pass=$((pass + 1))
  printf 'ok: gate is wired into fast-feedback.yml debt-budgets job\n'
else
  fail=$((fail + 1))
  printf 'FAIL: gate is NOT wired into fast-feedback.yml debt-budgets job\n' >&2
fi

# ── Regression: baseline is in LINT_RATIONALE allowlist ──────────────────────
rationale="${here}/../../docs/LINT_RATIONALE.md"
if [[ -f "${rationale}" ]] && grep -q "services-layering-baseline.json" "${rationale}"; then
  pass=$((pass + 1))
  printf 'ok: baseline is in LINT_RATIONALE allowlist\n'
else
  fail=$((fail + 1))
  printf 'FAIL: baseline is NOT in LINT_RATIONALE allowlist\n' >&2
fi

echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
echo "check-services-layering self-test: all green"
exit 0
