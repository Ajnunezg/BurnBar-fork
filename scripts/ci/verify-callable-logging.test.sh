#!/usr/bin/env bash
# Positive/negative controls for verify-callable-logging.sh: prove the gate can
# fail for each defect it claims to catch, including losing scan scope (the
# failure mode that left it red on every Ops Confidence run after the Functions
# codebase split).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

script="scripts/ci/verify-callable-logging.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# Build a fixture repo with two deploy codebases holding the floor counts
# (155 wrapped callables: 100 onCall+wrapCallableHandler, 55 onCallProduction;
# 10 wrapped onRequest handlers).
make_fixture() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/alpha/src/callables" "$root/beta/src/domains/__tests__"
  cat >"$root/firebase.json" <<'EOF'
{"functions": [{"source": "alpha", "codebase": "a"}, {"source": "beta", "codebase": "b"}]}
EOF
  local i
  {
    echo 'import { onCall } from "firebase-functions/v2/https";'
    echo '// A comment that mentions onCall( must never count as a usage.'
    for ((i = 0; i < 100; i++)); do
      printf 'export const call%d = onCall(\n  { region: "us-central1" },\n  wrapCallableHandler("call%d", async () => ({})),\n);\n' "$i" "$i"
    done
  } >"$root/alpha/src/callables/wrapped.ts"
  {
    for ((i = 0; i < 55; i++)); do
      printf 'export const prod%d = onCallProduction("prod%d", { region: "us-central1" }, async () => ({}));\n' "$i" "$i"
    done
  } >"$root/beta/src/domains/production.ts"
  {
    for ((i = 0; i < 10; i++)); do
      printf 'export const http%d = onRequest({}, wrapRequestHandler("http%d", async () => {}));\n' "$i" "$i"
    done
  } >"$root/beta/src/domains/http.ts"
  # Test sources never count toward (or against) the inventory.
  echo 'export const unwrappedInTest = onCall({}, async () => ({}));' >"$root/beta/src/domains/__tests__/fixture.test.ts"
}

run_case() {
  local desc="$1" root="$2" want="$3" needle="${4:-}"
  local out rc
  if out="$(OPENBURNBAR_CALLABLE_LOGGING_ROOT="$root" bash "$script" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ "$rc" -ne "$want" ]]; then
    echo "FAIL: $desc: expected exit $want, got $rc" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL: $desc: output missing '$needle'" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  echo "ok: $desc (exit $rc)"
}

make_fixture "$tmp/ok"
run_case "fully wrapped inventory at the floor passes" "$tmp/ok" 0 "PASS: 155 callables and 10 onRequest handlers"

make_fixture "$tmp/unwrapped"
printf 'export const naked = onCall({}, async () => ({}));\n' >>"$tmp/unwrapped/alpha/src/callables/wrapped.ts"
run_case "onCall export without wrapCallableHandler fails" "$tmp/unwrapped" 1 "alpha/src/callables/wrapped.ts:naked"

make_fixture "$tmp/comment-wrap"
printf '// wrapCallableHandler("ghost", ...) lives only in this comment\nexport const ghost = onCall({}, async () => ({}));\n' >>"$tmp/comment-wrap/alpha/src/callables/wrapped.ts"
run_case "a wrapper named only in a comment does not count" "$tmp/comment-wrap" 1 "wrapped.ts:ghost"

make_fixture "$tmp/request"
printf 'export const rawHttp = onRequest({}, async (_req, res) => { res.end(); });\n' >>"$tmp/request/beta/src/domains/http.ts"
run_case "onRequest export without wrapRequestHandler fails" "$tmp/request" 1 "http.ts:rawHttp"

make_fixture "$tmp/factory"
printf 'function makeCallable() {\n  return onCall({}, async () => ({}));\n}\n' >>"$tmp/factory/alpha/src/callables/wrapped.ts"
run_case "raw onCall( outside the export form is unrecognized" "$tmp/factory" 1 "outside \`export const x = onCall(\`"

make_fixture "$tmp/lost-codebase"
rm -rf "$tmp/lost-codebase/beta/src"
mkdir -p "$tmp/lost-codebase/beta/src"
run_case "a firebase.json codebase with no sources fails" "$tmp/lost-codebase" 1 "beta: firebase.json lists this codebase"

make_fixture "$tmp/empty-codebase"
mkdir -p "$tmp/empty-codebase/gamma/src"
echo 'export const helper = () => 1;' >"$tmp/empty-codebase/gamma/src/helper.ts"
echo '{"functions": [{"source": "alpha"}, {"source": "beta"}, {"source": "gamma"}]}' >"$tmp/empty-codebase/firebase.json"
run_case "a codebase whose sources export no handlers fails" "$tmp/empty-codebase" 1 "gamma: no onCall/onCallProduction/onRequest exports found"

make_fixture "$tmp/shrunk"
sed -i.bak '/^export const prod54 /d' "$tmp/shrunk/beta/src/domains/production.ts"
run_case "scan below the callable floor fails loudly" "$tmp/shrunk" 1 "expected >= 155 callables, got 154"

make_fixture "$tmp/no-codebases"
echo '{"functions": []}' >"$tmp/no-codebases/firebase.json"
run_case "firebase.json without codebases fails" "$tmp/no-codebases" 1 "declares no functions codebases"

run_case "live repository passes" "$PWD" 0 "PASS:"

if [[ "$fail" -ne 0 ]]; then
  echo "verify-callable-logging.test.sh: FAILED" >&2
  exit 1
fi
echo "verify-callable-logging.test.sh: all controls passed"
