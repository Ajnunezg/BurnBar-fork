#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

script="scripts/ops/rollback-revision.sh"
schema="docs/schemas/rollback-drill-receipt.schema.json"
pass=0
fail=0
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollback-revision-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

run_case() {
  local want="$1"
  local label="$2"
  shift 2
  local output="$tmp_root/${label}.out"
  local got
  set +e
  "$@" >"$output" 2>&1
  got=$?
  set -e
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  ok   (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL (exit %s, want %s) %s\n' "$got" "$want" "$label" >&2
    cat "$output" >&2
  fi
}

# check <label> <command...>: one assertion about a case's effects.
check() {
  local label="$1"
  shift
  if "$@" >"$tmp_root/check.out" 2>&1; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$label" >&2
    cat "$tmp_root/check.out" >&2
  fi
}

echo "rollback-revision fixture/self-test"

revisions_json="$tmp_root/revisions.json"
no_gcloud_bin="$tmp_root/no-gcloud-bin"
mkdir -p "$no_gcloud_bin"
cat >"$revisions_json" <<'JSON'
[
  {
    "metadata": {
      "name": "searchknowledge-00042-new"
    }
  },
  {
    "metadata": {
      "name": "searchknowledge-00041-good"
    }
  }
]
JSON

run_case 0 fixture-file-is-offline-and-does-not-need-gcloud \
  env PATH="/usr/bin:/bin" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --revisions-json "$revisions_json" --dry-run

run_case 0 fixture-file-never-mutates-even-without-dry-run \
  env PATH="/usr/bin:/bin" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --revisions-json "$revisions_json"

run_case 1 fixture-cannot-record-live-drill \
  env PATH="/usr/bin:/bin" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --revisions-json "$revisions_json" \
    --drill --receipt "$tmp_root/fixture-live.json"

fixture_json="$(cat "$revisions_json")"
run_case 0 fixture-env-is-offline-and-does-not-need-gcloud \
  env PATH="/usr/bin:/bin" \
    ROLLBACK_REVISIONS_JSON="$fixture_json" \
    bash "$script" searchknowledge searchknowledge-00041-good \
    --project burnbar --dry-run

run_case 1 missing-gcloud-and-fixture-fails-closed \
  env PATH="$no_gcloud_bin" \
    /bin/bash "$script" searchknowledge --project burnbar

run_case 1 live-drill-without-gcloud-fails-closed \
  env PATH="$no_gcloud_bin" \
    /bin/bash "$script" searchknowledge --project burnbar \
    --drill --receipt "$tmp_root/no-gcloud-live.json"

# ── Live paths against a fake gcloud + curl (no network, no real project) ──
# The fake keeps one service's traffic, revisions, and registry images in a
# per-case state directory and appends every invocation to calls.log.
# updates.json scripts the Nth update-traffic call: "fail" or "ignore"
# (reports success, changes nothing); health holds the probe's HTTP status.
fake_bin="$tmp_root/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gcloud" <<'FAKE'
#!/usr/bin/env python3
import json
import os
import sys

state = os.environ["FAKE_GCLOUD_STATE"]
args = sys.argv[1:]


def read(name, default):
    try:
        with open(os.path.join(state, name)) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def write(name, value):
    with open(os.path.join(state, name), "w") as handle:
        json.dump(value, handle)


with open(os.path.join(state, "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
revisions = read("revisions.json", [])
command = args[:3]
if command == ["run", "revisions", "list"]:
    print(json.dumps(revisions))
elif command == ["run", "revisions", "describe"]:
    match = [revision for revision in revisions if revision["metadata"]["name"] == args[3]]
    if not match:
        sys.exit("ERROR: revision not found")
    print(json.dumps(match[0]))
elif command == ["run", "services", "describe"]:
    if "--format=value(status.url)" in args:
        print("https://healthready.example.invalid")
    else:
        print(json.dumps({"status": {"traffic": read("traffic.json", [])}}))
elif command == ["run", "services", "update-traffic"]:
    count = read("update-count.json", 0) + 1
    write("update-count.json", count)
    behavior = read("updates.json", {}).get(str(count), "apply")
    if behavior == "fail":
        sys.exit("ERROR: Revision is not ready and cannot serve traffic. Container import failed.")
    if behavior == "apply" and "--to-latest" in args:
        write("traffic.json", [{"latestRevision": True, "percent": 100, "revisionName": revisions[0]["metadata"]["name"]}])
    elif behavior == "apply":
        name, percent = [arg for arg in args if arg.startswith("--to-revisions=")][0].split("=", 1)[1].rsplit("=", 1)
        write("traffic.json", [{"percent": int(percent), "revisionName": name}])
elif command == ["artifacts", "docker", "images"] and args[3] == "describe":
    if args[4] not in read("images.json", []):
        sys.exit("ERROR: (gcloud.artifacts.docker.images.describe) NOT_FOUND: " + args[4])
    print("{}")
else:
    sys.exit("fake gcloud: unexpected " + " ".join(args))
FAKE
cat >"$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_GCLOUD_STATE/health"
FAKE
chmod +x "$fake_bin/gcloud" "$fake_bin/curl"

image="us-central1-docker.pkg.dev/burnbar/gcf-artifacts/burnbar__us--central1__health_ready"

# new_state <name> [serving]: healthready with revisions 00003 (newest) to
# 00001, every image present, healthy, and 100% on LATEST (or on <serving>).
new_state() {
  local dir="$tmp_root/state-$1"
  mkdir -p "$dir"
  cat >"$dir/revisions.json" <<JSON
[
  {"metadata": {"name": "healthready-00003-new"}, "spec": {"containers": [{"image": "${image}:version_1"}]}, "status": {"imageDigest": "${image}@sha256:3333"}},
  {"metadata": {"name": "healthready-00002-good"}, "spec": {"containers": [{"image": "${image}:version_1"}]}, "status": {"imageDigest": "${image}@sha256:2222"}},
  {"metadata": {"name": "healthready-00001-old"}, "spec": {"containers": [{"image": "${image}:version_1"}]}, "status": {"imageDigest": "${image}@sha256:1111"}}
]
JSON
  printf '["%s@sha256:3333", "%s@sha256:2222", "%s@sha256:1111"]\n' "$image" "$image" "$image" >"$dir/images.json"
  if [[ -n "${2:-}" ]]; then
    printf '[{"percent": 100, "revisionName": "%s"}]\n' "$2" >"$dir/traffic.json"
  else
    echo '[{"latestRevision": true, "percent": 100, "revisionName": "healthready-00003-new"}]' >"$dir/traffic.json"
  fi
  echo 200 >"$dir/health"
  echo "$dir"
}

# with_fake <state> <command...>: run with the fakes first on PATH.
with_fake() {
  local state="$1"
  shift
  env PATH="$fake_bin:/usr/bin:/bin" FAKE_GCLOUD_STATE="$state" "$@"
}

# The update-traffic flags a case sent, in order (the flag is the last argv).
traffic_updates() {
  { grep 'run services update-traffic' "$1/calls.log" || true; } | awk '{ printf "%s ", $NF }'
}

cat >"$tmp_root/validate_receipt.py" <<'PY'
"""Validate a receipt against the draft-07 subset the receipt schema uses
(type/const/enum/pattern/required/properties/additionalProperties/allOf/if-then),
then check any dotted.path=value expectations."""
import json
import re
import sys


def errors(schema, value, path="$"):
    found = []
    if "const" in schema and value != schema["const"]:
        found.append(f"{path}: expected {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        found.append(f"{path}: {value!r} not in {schema['enum']}")
    expected_type = {"object": dict, "string": str, "boolean": bool}.get(schema.get("type"))
    if expected_type and not isinstance(value, expected_type):
        return found + [f"{path}: expected {schema['type']}"]
    if isinstance(value, str) and "pattern" in schema and not re.search(schema["pattern"], value):
        found.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        found += [f"{path}: missing {key}" for key in schema.get("required", []) if key not in value]
        for key, item in value.items():
            if key in properties:
                found += errors(properties[key], item, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                found.append(f"{path}: unexpected {key}")
    for branch in schema.get("allOf", []):
        found += errors(branch, value, path)
    if "if" in schema and not errors(schema["if"], value, path):
        found += errors(schema.get("then", {}), value, path)
    return found


schema_path, receipt_path, *expectations = sys.argv[1:]
with open(schema_path) as handle:
    schema = json.load(handle)
with open(receipt_path) as handle:
    receipt = json.load(handle)
problems = errors(schema, receipt)
for expectation in expectations:
    dotted, expected = expectation.split("=", 1)
    actual = receipt
    for key in dotted.split("."):
        actual = actual.get(key) if isinstance(actual, dict) else None
    if expected not in (str(actual), json.dumps(actual)):
        problems.append(f"{dotted}: expected {expected}, got {json.dumps(actual)}")
for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
validate() {
  python3 "$tmp_root/validate_receipt.py" "$schema" "$@"
}
rejects() {
  ! validate "$1"
}

# The validator must reject what the schema forbids, or its passes mean nothing.
python3 - "$tmp_root" <<'PY'
import json
import os
import sys

drill = {"kind": "cloud-run-revision-pin", "serviceName": "healthready", "region": "us-central1",
         "targetRevision": "healthready-00002-good", "trafficPercent": 100, "healthProbe": "passed",
         "imagePreflight": "verified", "previousServing": {"mode": "latest"},
         "restore": {"mode": "latest", "confirmed": True}}
checks = {"revisionListLoaded": True, "trafficPinned": True, "liveGcloudSession": True,
          "imageVerified": True, "trafficRestored": True}
base = {"schema": "openburnbar.rollback-drill-receipt.v1", "schemaVersion": 1,
        "generatedAt": "2026-09-28T00:00:00Z", "mode": "live", "liveDrill": True, "ok": True}
variants = {
    "good": {**base, "drill": drill, "checks": checks},
    "no-restore": {**base, "drill": {k: v for k, v in drill.items() if k != "restore"}, "checks": checks},
    "restore-unconfirmed": {**base, "drill": {**drill, "restore": {"mode": "latest", "confirmed": False}}, "checks": checks},
    "unhealthy": {**base, "drill": {**drill, "healthProbe": "warning"}, "checks": checks},
    "pinned-without-revision": {**base, "drill": {**drill, "previousServing": {"mode": "revision"}}, "checks": checks},
    "traffic-not-restored": {**base, "drill": drill, "checks": {**checks, "trafficRestored": False}},
}
for name, receipt in variants.items():
    with open(os.path.join(sys.argv[1], f"variant-{name}.json"), "w") as handle:
        json.dump(receipt, handle)
PY
check validator-accepts-a-complete-live-receipt validate "$tmp_root/variant-good.json"
for variant in no-restore restore-unconfirmed unhealthy pinned-without-revision traffic-not-restored; do
  check "validator-rejects-live-receipt-${variant}" rejects "$tmp_root/variant-${variant}.json"
done
check committed-fixture-receipt-still-matches-schema \
  validate launch-evidence/rollback-drill-2026-09-02.fixture-dry-run.json

# Happy round trip from LATEST: pin N-1, read back, probe, restore LATEST.
state="$(new_state round-trip-latest)"
evidence="$tmp_root/prod/launch-evidence"
receipt="$evidence/rollback-drill-test-burnbar.json"
run_case 0 drill-round-trip-from-latest-writes-receipt \
  with_fake "$state" bash "$script" healthready --project burnbar --yes --drill --receipt "$receipt"
check drill-pinned-n-1-then-restored-latest \
  test "$(traffic_updates "$state")" = "--to-revisions=healthready-00002-good=100 --to-latest "
check drill-receipt-matches-schema-and-records-the-round-trip \
  validate "$receipt" drill.targetRevision=healthready-00002-good drill.healthProbe=passed \
  drill.imagePreflight=verified drill.previousServing.mode=latest \
  drill.previousServing.revision=healthready-00003-new drill.restore.mode=latest \
  drill.restore.confirmed=true checks.imageVerified=true checks.trafficRestored=true
check production-drill-updates-latest-pointer cmp "$receipt" "$evidence/latest-rollback-revision-drill.json"

# Round trip from a pinned revision restores that pin, not LATEST; a staging
# receipt never becomes the production pointer.
state="$(new_state round-trip-pinned healthready-00002-good)"
evidence="$tmp_root/staging/launch-evidence"
receipt="$evidence/rollback-drill-test-burnbar-staging.json"
run_case 0 drill-round-trip-from-pinned-revision-writes-receipt \
  with_fake "$state" bash "$script" healthready healthready-00001-old --project burnbar-staging --yes --drill --receipt "$receipt"
check drill-restored-the-pre-drill-pin \
  test "$(traffic_updates "$state")" = "--to-revisions=healthready-00001-old=100 --to-revisions=healthready-00002-good=100 "
check drill-receipt-records-the-pinned-restore \
  validate "$receipt" drill.previousServing.mode=revision drill.previousServing.revision=healthready-00002-good drill.restore.mode=revision
check staging-drill-leaves-production-pointer-alone test ! -e "$evidence/latest-rollback-revision-drill.json"

# Pruned image: the drill refuses before any traffic change.
state="$(new_state pruned-drill)"
printf '["%s@sha256:3333"]\n' "$image" >"$state/images.json"
receipt="$tmp_root/pruned/rollback-drill.json"
run_case 1 drill-refuses-pruned-image \
  with_fake "$state" bash "$script" healthready --project burnbar --yes --drill --receipt "$receipt"
check pruned-image-drill-sent-no-update-traffic test -z "$(traffic_updates "$state")"
check pruned-image-drill-wrote-no-receipt test ! -e "$receipt"
check pruned-image-drill-names-the-slow-path \
  grep -q 'scripts/rollback.sh[[:space:]]*$' "$tmp_root/drill-refuses-pruned-image.out"
check pruned-image-drill-names-the-retention-contract \
  grep -q 'governance/ops-artifact-retention.json' "$tmp_root/drill-refuses-pruned-image.out"

# The pin "succeeds" but the readback disagrees: restore, record nothing.
state="$(new_state readback-mismatch)"
echo '{"1": "ignore"}' >"$state/updates.json"
receipt="$tmp_root/mismatch/rollback-drill.json"
run_case 1 drill-readback-mismatch-records-nothing \
  with_fake "$state" bash "$script" healthready --project burnbar --yes --drill --receipt "$receipt"
check readback-mismatch-still-restores \
  test "$(traffic_updates "$state")" = "--to-revisions=healthready-00002-good=100 --to-latest "
check readback-mismatch-wrote-no-receipt test ! -e "$receipt"

# An unhealthy pinned revision is not a rollback target: restore, record nothing.
state="$(new_state unhealthy)"
echo 503 >"$state/health"
receipt="$tmp_root/unhealthy/rollback-drill.json"
run_case 1 drill-unhealthy-pin-records-nothing \
  with_fake "$state" bash "$script" healthready --project burnbar --yes --drill --receipt "$receipt"
check unhealthy-pin-still-restores \
  test "$(traffic_updates "$state")" = "--to-revisions=healthready-00002-good=100 --to-latest "
check unhealthy-pin-wrote-no-receipt test ! -e "$receipt"

# The restore itself fails: non-zero, no receipt, the exact manual command.
state="$(new_state restore-fails)"
echo '{"2": "fail"}' >"$state/updates.json"
receipt="$tmp_root/restore-fails/rollback-drill.json"
run_case 1 drill-restore-failure-exits-nonzero \
  with_fake "$state" bash "$script" healthready --project burnbar --yes --drill --receipt "$receipt"
check restore-failure-wrote-no-receipt test ! -e "$receipt"
check restore-failure-prints-the-manual-restore-command \
  grep -qF 'gcloud run services update-traffic healthready --region us-central1 --project burnbar --to-latest' \
  "$tmp_root/drill-restore-failure-exits-nonzero.out"

# A split service cannot be restored exactly, so the drill never starts.
state="$(new_state split)"
echo '[{"percent": 50, "revisionName": "healthready-00003-new"}, {"percent": 50, "revisionName": "healthready-00002-good"}]' >"$state/traffic.json"
run_case 1 drill-refuses-split-traffic \
  with_fake "$state" bash "$script" healthready healthready-00001-old --project burnbar --yes --drill \
  --receipt "$tmp_root/split/rollback-drill.json"
check split-traffic-drill-sent-no-update-traffic test -z "$(traffic_updates "$state")"

run_case 1 receipt-cannot-name-the-latest-pointer \
  with_fake "$(new_state pointer-name)" bash "$script" healthready --project burnbar --yes --drill \
  --receipt "$tmp_root/launch-evidence/latest-rollback-revision-drill.json"

# An ordinary rollback with a pruned image warns loudly and still tries: Cloud
# Run refuses the pin atomically when the image is really gone.
state="$(new_state pruned-rollback)"
printf '["%s@sha256:3333"]\n' "$image" >"$state/images.json"
run_case 0 ordinary-rollback-with-pruned-image-proceeds \
  with_fake "$state" bash "$script" healthready --project burnbar --yes
check ordinary-rollback-warns-about-the-pruned-image \
  grep -q 'WARN: the image for healthready-00002-good is missing' "$tmp_root/ordinary-rollback-with-pruned-image-proceeds.out"
check ordinary-rollback-sent-the-pin \
  test "$(traffic_updates "$state")" = "--to-revisions=healthready-00002-good=100 "

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: ${fail} rollback-revision test case(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} rollback-revision fixture checks"
