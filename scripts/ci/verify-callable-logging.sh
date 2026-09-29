#!/usr/bin/env bash
# Verify every v2 onCall / onRequest export in every Firebase deploy codebase is
# structured-logged (callable_start/success/error + Sentry capture):
#   export const x = onCall(opts, wrapCallableHandler("x", ...))   (or loggedOnCall)
#   export const x = onCallProduction("x", ...)                     (wrapped by construction)
#   export const x = onRequest(opts, wrapRequestHandler("x", ...))
#
# The codebase list comes from firebase.json `functions[].source`, not a
# hard-coded path: this gate used to scan functions/src only, so after the
# 3.5 codebase split it saw 12 of 157 callables and failed its own floor on
# every Ops Confidence run (36408399456). Scanning the deployed set keeps the
# scope honest, and the floors below fail loudly if the scan ever shrinks again.
#
# Test/fixture override: OPENBURNBAR_CALLABLE_LOGGING_ROOT=<dir> (see
# scripts/ci/verify-callable-logging.test.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="${OPENBURNBAR_CALLABLE_LOGGING_ROOT:-$PWD}"

ROOT="$ROOT" python3 <<'PY'
import json
import os
import re
import sys
from pathlib import Path

# Floors are the recognized export counts on 2026-09-28 (155 callables across
# functions, functions-identity, functions-sync, functions-media; 10 onRequest
# handlers). Deleting handlers may lower them in the same change; a scan that
# silently loses a codebase or a wrapper form cannot.
MIN_CALLABLES = 155
MIN_REQUEST_HANDLERS = 10

root = Path(os.environ["ROOT"])
config = json.loads((root / "firebase.json").read_text())
entries = config.get("functions") or []
if isinstance(entries, dict):
    entries = [entries]
codebases = [entry["source"] for entry in entries if isinstance(entry, dict) and isinstance(entry.get("source"), str)]
if not codebases:
    sys.exit("FAIL: firebase.json declares no functions codebases; nothing would be verified.")

CALL_EXPORT = re.compile(r"export const (\w+)\s*=\s*onCall\(")
PRODUCTION_EXPORT = re.compile(r"export const (\w+)\s*=\s*onCallProduction\(")
REQUEST_EXPORT = re.compile(r"export const (\w+)\s*=\s*onRequest\(")
RAW_CALL = re.compile(r"\bonCall\(")
RAW_REQUEST = re.compile(r"\bonRequest\(")


def code_lines(text: str) -> str:
    """Drop comment and import lines so prose/imports never count as usages."""
    kept = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(("//", "*", "/*", "import ")):
            continue
        kept.append(line)
    return "\n".join(kept)


callables = 0
request_handlers = 0
missing: list[str] = []
unrecognized: list[str] = []
per_codebase: dict[str, int] = {}

for codebase in codebases:
    src = root / codebase / "src"
    files = [
        path
        for path in sorted(src.rglob("*.ts"))
        if "/__tests__/" not in path.as_posix() and not path.name.endswith((".test.ts", ".d.ts"))
    ]
    if not files:
        missing.append(f"{codebase}: firebase.json lists this codebase but {codebase}/src has no TypeScript sources")
        continue
    found = 0
    for path in files:
        code = code_lines(path.read_text())
        rel = path.relative_to(root).as_posix()

        call_exports = CALL_EXPORT.findall(code)
        for name in call_exports:
            if re.search(rf'(wrapCallableHandler|loggedOnCall)\s*\(\s*"{re.escape(name)}"', code):
                continue
            missing.append(f"{rel}:{name} (onCall without wrapCallableHandler(\"{name}\", ...))")
        production_exports = PRODUCTION_EXPORT.findall(code)
        raw_calls = len(RAW_CALL.findall(code))
        if raw_calls > len(call_exports):
            unrecognized.append(
                f"{rel}: {raw_calls - len(call_exports)} onCall( usage(s) outside `export const x = onCall(` — "
                "use onCallProduction(...) or extend this verifier"
            )

        request_exports = REQUEST_EXPORT.findall(code)
        for name in request_exports:
            if re.search(rf'wrapRequestHandler\s*\(\s*"{re.escape(name)}"', code):
                continue
            missing.append(f"{rel}:{name} (onRequest without wrapRequestHandler(\"{name}\", ...))")
        raw_requests = len(RAW_REQUEST.findall(code))
        if raw_requests > len(request_exports):
            unrecognized.append(
                f"{rel}: {raw_requests - len(request_exports)} onRequest( usage(s) outside "
                "`export const x = onRequest(` — wrap them or extend this verifier"
            )

        count = len(call_exports) + len(production_exports)
        callables += count
        request_handlers += len(request_exports)
        found += count + len(request_exports)
    per_codebase[codebase] = found

print("codebases (firebase.json): " + ", ".join(f"{name}={per_codebase.get(name, 0)}" for name in codebases))
print(f"callable exports: {callables} (floor {MIN_CALLABLES}); onRequest exports: {request_handlers} (floor {MIN_REQUEST_HANDLERS})")

failed = False
if missing or unrecognized:
    failed = True
    print("FAIL: handlers that are not structured-logged or not recognized:")
    for item in missing + unrecognized:
        print(f"  {item}")
if callables < MIN_CALLABLES:
    failed = True
    print(f"FAIL: expected >= {MIN_CALLABLES} callables, got {callables} — the scan lost scope (moved codebase? new wrapper form?).")
if request_handlers < MIN_REQUEST_HANDLERS:
    failed = True
    print(f"FAIL: expected >= {MIN_REQUEST_HANDLERS} onRequest handlers, got {request_handlers}.")
if failed:
    sys.exit(1)
print(f"PASS: {callables} callables and {request_handlers} onRequest handlers structured-logged across {len(codebases)} codebases")
PY
