#!/usr/bin/env bash
# Reject tracked, failed commercial launch-gate evidence.
#
# A commercial launch-gate artifact is recognized by CONTENT, not filename, in
# both shapes the repo produces:
#   raw      `node scripts/commercial-launch-gate.mjs > x.json`
#            -> { generatedAt, verdict: { status, reason }, checks }
#   captured scripts/capture-commercial-launch-evidence.mjs
#            -> { capturedAt, kind: "commercial-launch-gate", payload: <raw> }
# The previous version only read a top-level `verdict` on files whose NAME
# contained "commercial-launch-gate", so a captured NO_GO record (verdict under
# `payload`) passed, and a renamed raw verdict was never looked at.
#
# Fails when a tracked artifact's verdict is NO_GO, or when a file that claims
# to be launch-gate evidence (by name or `kind`) cannot be parsed as one. Every
# tracked launch-evidence/*.json file is scanned and the counts are printed, so
# "0 artifacts" is visible rather than silent.
#
# Test/fixture override: OPENBURNBAR_LAUNCH_EVIDENCE_REPO=<git work tree>
# (see scripts/ci/check-no-stale-launch-evidence.test.mjs).
set -euo pipefail

repo_root="${OPENBURNBAR_LAUNCH_EVIDENCE_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$repo_root"

exec python3 - <<'PY'
import json
import subprocess
import sys

GATE_KIND = "commercial-launch-gate"
GATE_STATUSES = {
    "NO_GO",
    "WAITING_ON_APPLE",
    "READY_FOR_MANUAL_RELEASE",
    "READY_FOR_LIVE_PAID_PROOF",
    "READY_FOR_CANARY",
    "READY_FOR_PUBLIC_RELEASE",
    "LAUNCH_DONE",
}

tracked = subprocess.run(
    ["git", "ls-files", "-z", "--", "launch-evidence"],
    capture_output=True,
    text=True,
    check=True,
).stdout.split("\0")
candidates = sorted(path for path in tracked if path.endswith(".json"))


def gate_verdict(document):
    """Return the launch-gate verdict dict of a raw or captured artifact, else None."""
    if not isinstance(document, dict):
        return None
    for body in (document, document.get("payload")):
        if not isinstance(body, dict):
            continue
        verdict = body.get("verdict")
        if isinstance(verdict, dict) and verdict.get("status") in GATE_STATUSES and isinstance(body.get("checks"), dict):
            return verdict
    return None


violations = []
artifacts = 0
for path in candidates:
    claims_gate = GATE_KIND in path
    try:
        raw = subprocess.run(["git", "show", f":{path}"], capture_output=True, text=True, check=True).stdout
        document = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        if claims_gate:
            violations.append(f"{path}: unreadable launch-gate JSON ({exc})")
        continue
    claims_gate = claims_gate or (isinstance(document, dict) and document.get("kind") == GATE_KIND)
    verdict = gate_verdict(document)
    if verdict is None:
        if claims_gate:
            violations.append(f"{path}: named/kinded as commercial launch-gate evidence but carries no gate verdict")
        continue
    artifacts += 1
    if verdict["status"] == "NO_GO":
        violations.append(f"{path}: verdict.status=NO_GO ({verdict.get('reason', 'no reason')})")

if violations:
    print("FAIL: stale failed commercial launch evidence is tracked:", file=sys.stderr)
    for item in violations:
        print(f"  {item}", file=sys.stderr)
    print(
        "Regenerate fresh GO evidence locally/CI, but do not commit stale NO_GO launch-gate artifacts.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"PASS: scanned {len(candidates)} tracked launch-evidence JSON file(s); "
    f"{artifacts} commercial launch-gate artifact(s), none NO_GO"
)
PY
