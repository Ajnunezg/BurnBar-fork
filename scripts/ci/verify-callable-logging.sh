#!/usr/bin/env bash
# Verify every v2 onCall export uses wrapCallableHandler (callable_start/success/error)
# and every onRequest export uses wrapRequestHandler, across ALL Functions deploy
# codebases. The callable_error log is what openburnbar_callable_error counts, so
# an unwrapped callable is invisible to the "Callable error spike" alert.
#
# Codebase split 3.5 moved most callables out of functions/src; scanning only that
# directory saw 12 of 111 callables and failed its own floor on every run.
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 <<'PY'
import re
from pathlib import Path

# Every Firebase Functions deploy codebase (firebase.json "functions" entries).
CODEBASES = ["functions", "functions-identity", "functions-sync", "functions-media"]
MIN_CALLABLES = 100
MIN_REQUEST_HANDLERS = 10


def exports(kind):
    found = []
    for codebase in CODEBASES:
        src = Path(codebase) / "src"
        if not src.is_dir():
            raise SystemExit(f"FAIL: codebase source directory missing: {src}")
        for path in sorted(src.rglob("*.ts")):
            if "/__tests__/" in str(path) or path.name.endswith(".test.ts"):
                continue
            text = path.read_text()
            for m in re.finditer(rf"export const (\w+) = {kind}\(", text):
                found.append((codebase, m.group(1), path))
    return found


def unwrapped(found, wrappers):
    missing = []
    for _codebase, name, path in found:
        text = path.read_text()
        if any(re.search(rf'{wrapper}\s*\(\s*"{re.escape(name)}"', text) for wrapper in wrappers):
            continue
        missing.append(f"{path}:{name}")
    return missing


callables = exports("onCall")
per_codebase = {codebase: sum(1 for entry in callables if entry[0] == codebase) for codebase in CODEBASES}
print("onCall exports per codebase: " + ", ".join(f"{name}={count}" for name, count in per_codebase.items()))
empty = [name for name, count in per_codebase.items() if count == 0]
if empty:
    raise SystemExit(f"FAIL: no onCall exports found in {', '.join(empty)} (codebase moved or scan pattern drifted)")
if len(callables) < MIN_CALLABLES:
    raise SystemExit(f"FAIL: expected >= {MIN_CALLABLES} callables, got {len(callables)}")
missing = unwrapped(callables, ["wrapCallableHandler", "onCallProduction", "loggedOnCall"])
print(f"structured-log wrapped: {len(callables) - len(missing)}/{len(callables)}")
if missing:
    print("FAIL: missing wrap for:")
    for m in missing:
        print(f"  {m}")
    raise SystemExit(1)
print("PASS: all callables structured-logged")

request_handlers = exports("onRequest")
request_missing = unwrapped(request_handlers, ["wrapRequestHandler"])
print(f"onRequest exports: {len(request_handlers)}")
print(f"request-log wrapped: {len(request_handlers) - len(request_missing)}/{len(request_handlers)}")
if len(request_handlers) < MIN_REQUEST_HANDLERS:
    raise SystemExit(f"FAIL: expected >= {MIN_REQUEST_HANDLERS} onRequest handlers, got {len(request_handlers)}")
if request_missing:
    print("FAIL: missing wrapRequestHandler for:")
    for m in request_missing:
        print(f"  {m}")
    raise SystemExit(1)
print("PASS: all onRequest handlers structured-logged")
PY
