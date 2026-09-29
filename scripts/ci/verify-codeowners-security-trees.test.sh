#!/usr/bin/env bash
# Regression test for scripts/ci/verify-codeowners-security-trees.sh.
#
# Verifies that the verifier:
#   1. PASSES against the current CODEOWNERS file.
#   2. Fails closed on a missing security rule (.gitleaks.toml, .gitleaksignore,
#      a moved Cloud Functions security module).
#   3. Fails on a dead path: a CODEOWNERS rule, or a REQUIRED rule, that names a
#      file which no longer exists (the pre-2026-09-28 functions/src/*.ts state).
#   4. Fails when a required path loses its specific owner (a later catch-all
#      shadows it, or the rule drops the security owner).
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$SOURCE_ROOT/scripts/ci/verify-codeowners-security-trees.sh"
CODEOWNERS="$SOURCE_ROOT/.github/CODEOWNERS"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0

expect_pass() {
  local name="$1"
  shift
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  if "$@" >"$log" 2>&1; then
    echo "  ok   $name"
    passed=$((passed + 1))
  else
    echo "  FAIL $name (expected pass)" >&2
    cat "$log" >&2
    failed=$((failed + 1))
  fi
}

# expect_fail NAME EXPECTED_MESSAGE CMD... — the command must exit nonzero AND
# print EXPECTED_MESSAGE, so an unrelated failure cannot satisfy the case.
expect_fail() {
  local name="$1"
  local expected="$2"
  shift 2
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  if "$@" >"$log" 2>&1; then
    echo "  FAIL $name (expected failure)" >&2
    cat "$log" >&2
    failed=$((failed + 1))
  elif ! grep -qF -- "$expected" "$log"; then
    echo "  FAIL $name (failed without: $expected)" >&2
    cat "$log" >&2
    failed=$((failed + 1))
  else
    echo "  ok   $name"
    passed=$((passed + 1))
  fi
}

# run_with CODEOWNERS_COPY [VERIFIER] — check the real tree's tracked paths
# against a mutated CODEOWNERS (and optionally a mutated verifier).
run_with() {
  CODEOWNERS_REPO_ROOT="$SOURCE_ROOT" CODEOWNERS_FILE="$1" bash "${2:-$VERIFY}"
}

mutate() {
  local name="$1"
  shift
  local out="$TMP_ROOT/$name.CODEOWNERS"
  "$@" "$CODEOWNERS" >"$out"
  if cmp -s "$CODEOWNERS" "$out"; then
    echo "  FAIL mutation $name did not change CODEOWNERS" >&2
    exit 1
  fi
  echo "$out"
}

echo "Self-test: verify-codeowners-security-trees.sh"
echo

expect_pass "current CODEOWNERS passes verifier" bash "$VERIFY"

no_gitleaks="$(mutate no-gitleaks sed '/^\.gitleaks\.toml /d')"
expect_fail "missing .gitleaks.toml entry caught by verifier" \
  "missing explicit CODEOWNERS rule for .gitleaks.toml" run_with "$no_gitleaks"

no_gitleaksignore="$(mutate no-gitleaksignore sed '/^\.gitleaksignore /d')"
expect_fail "missing .gitleaksignore entry caught by verifier" \
  "missing explicit CODEOWNERS rule for .gitleaksignore" run_with "$no_gitleaksignore"

no_auth="$(mutate no-auth sed '/^packages\/functions-shared\/src\/auth\.ts /d')"
expect_fail "missing owner rule for a moved security module caught" \
  "missing explicit CODEOWNERS rule for packages/functions-shared/src/auth.ts" run_with "$no_auth"

dead_rule="$(mutate dead-rule awk '{ print } END { print "functions/src/auth.ts @Ajnunezg @emilio3435" }')"
expect_fail "dead CODEOWNERS path caught" \
  "rule 'functions/src/auth.ts' matches no tracked path" run_with "$dead_rule"

# The pre-fix state: verifier and CODEOWNERS both still name the old path.
stale_verify="$TMP_ROOT/stale-verify.sh"
sed 's#"packages/functions-shared/src/ssrfGuard.ts"#"functions/src/ssrfGuard.ts"#' "$VERIFY" >"$stale_verify"
if cmp -s "$VERIFY" "$stale_verify"; then
  echo "  FAIL mutation stale-verify did not change the verifier" >&2
  exit 1
fi
stale_codeowners="$(mutate stale-required sed 's#^packages/functions-shared/src/ssrfGuard\.ts #functions/src/ssrfGuard.ts #')"
expect_fail "dead REQUIRED path caught even when CODEOWNERS agrees" \
  "required rule functions/src/ssrfGuard.ts matches no tracked path" run_with "$stale_codeowners" "$stale_verify"

catch_all="$(mutate catch-all awk '{ print } END { print "* @Ajnunezg @emilio3435" }')"
expect_fail "required path shadowed by a trailing catch-all caught" \
  "resolves to non-security rule '*'" run_with "$catch_all"

no_owner="$(mutate no-owner sed 's#^\(packages/functions-shared/src/logging\.ts\) .*#\1 @emilio3435#')"
expect_fail "required rule without the security owner caught" \
  "packages/functions-shared/src/logging.ts is present but lacks required security/platform owner(s)" run_with "$no_owner"

echo
if [ "$failed" -eq 0 ]; then
  echo "PASS: ${passed} passed, ${failed} failed"
  exit 0
else
  echo "FAIL: ${passed} passed, ${failed} failed"
  exit 1
fi
