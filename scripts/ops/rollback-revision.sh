#!/usr/bin/env bash
# Fast revision-pin rollback (sub-minute — no rebuild, no redeploy).
#
# Gen2 Cloud Functions ARE Cloud Run services, so a bad deploy can be reverted
# by flipping 100% of traffic back to a previous-good revision in seconds. Use
# this as the PRIMARY rollback path. The slow source rollback (git checkout +
# rebuild + firebase deploy) lives at scripts/rollback.sh and is the fallback.
#
# A revision can only serve while its container image still exists, so the
# target's image is checked in Artifact Registry before any traffic change (the
# 2026-09-23 drill found every previous image pruned while the revisions still
# read Ready). An ordinary rollback warns and still tries: Cloud Run refuses the
# pin atomically when the image is gone. A drill refuses.
#
# Usage:
#   ./scripts/ops/rollback-revision.sh <cloud-run-service> [target-revision]
#
# Flags:
#   --yes               Non-interactive: skip the confirmation prompt.
#   --dry-run           Print the plan and the gcloud command; change nothing.
#   --revisions-json <file>
#                       Use a checked-in/offline revisions fixture; never calls gcloud.
#   --drill             Round trip, then write a receipt (requires --receipt): pin
#                       the target to 100%, read it back, health-probe it, restore
#                       the pre-drill traffic (LATEST or the pinned revision) and
#                       read that back. Any failure restores and records nothing.
#   --receipt <file>    Receipt path for --drill (or ROLLBACK_DRILL_RECEIPT). A
#                       receipt under launch-evidence/ for the production project
#                       (.firebaserc default) is also copied to
#                       launch-evidence/latest-rollback-revision-drill.json.
#   --region <r>        Cloud Run region (default us-central1).
#   --project <p>       GCP project (default from .firebaserc / gcloud config).
#
# Examples:
#   # Pin <service> back to the most-recent non-serving revision (interactive):
#   ./scripts/ops/rollback-revision.sh searchknowledge
#
#   # Pin to an explicit revision, non-interactive:
#   ./scripts/ops/rollback-revision.sh searchknowledge searchknowledge-00041-abc --yes
#
#   # Preview only:
#   ./scripts/ops/rollback-revision.sh searchknowledge --dry-run
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login / ADC)
#   - Caller has roles/run.admin (or run.services.update + run.revisions.list/get)
#   - Caller can read the image: roles/artifactregistry.reader on gcf-artifacts
set -euo pipefail
cd "$(dirname "$0")/../.."

SERVICE=""
TARGET_REVISION=""
REGION="${FUNCTIONS_REGION:-us-central1}"
PROJECT=""
ASSUME_YES=false
DRY_RUN=false
REVISIONS_JSON_FILE=""
REVISIONS_JSON_INPUT="${ROLLBACK_REVISIONS_JSON:-}"
TRAFFIC_JSON="${ROLLBACK_TRAFFIC_JSON:-}"
DRILL=false
DRILL_RECEIPT="${ROLLBACK_DRILL_RECEIPT:-}"
LATEST_DRILL_POINTER="latest-rollback-revision-drill.json"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# The .firebaserc project for an alias ("default" is production); empty if none.
firebaserc_project() {
  [[ -f .firebaserc ]] || return 0
  python3 - "$1" <<'PY' 2>/dev/null || true
import json
import sys

with open(".firebaserc") as handle:
    print(json.load(handle).get("projects", {}).get(sys.argv[1], ""))
PY
}

# Prints how a traffic readback is served: "latest <revision>" when 100%
# follows LATEST, "revision <revision>" when 100% is pinned, otherwise "split".
traffic_state() {
  python3 - "$1" <<'PY'
import json
import sys

traffic = json.loads(sys.argv[1] or "{}")
entries = (traffic.get("status", {}) or {}).get("traffic")
if entries is None:
    entries = traffic.get("traffic", [])
serving = [entry for entry in entries or [] if int(entry.get("percent") or 0) > 0]
if len(serving) == 1 and int(serving[0].get("percent") or 0) == 100:
    mode = "latest" if serving[0].get("latestRevision") else "revision"
    print(f"{mode} {serving[0].get('revisionName') or ''}")
else:
    print("split")
PY
}

# Reads live traffic back; succeeds when 100% follows LATEST (mode "latest") or
# is pinned to <revision> (mode "revision").
live_traffic_is() {
  local mode="$1" revision="$2" traffic_json state
  traffic_json="$(gcloud run services describe "$SERVICE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format='json(status.traffic)')" || return 1
  state="$(traffic_state "$traffic_json")" || return 1
  if [[ "$mode" == "latest" ]]; then
    [[ "$state" == "latest "* ]]
  else
    [[ "$state" == "revision ${revision}" ]]
  fi
}

# Sets IMAGE_PREFLIGHT (verified | missing | unverifiable) and TARGET_IMAGE for
# TARGET_REVISION. Cloud Run pulls a revision by the digest it resolved at
# deploy time (status.imageDigest), so that digest is what has to exist.
image_preflight() {
  local revision_json
  IMAGE_PREFLIGHT="unverifiable"
  TARGET_IMAGE=""
  revision_json="$(gcloud run revisions describe "$TARGET_REVISION" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format=json)" || return 0
  TARGET_IMAGE="$(python3 - "$revision_json" <<'PY'
import json
import sys

revision = json.loads(sys.argv[1] or "{}")
digest = (revision.get("status", {}) or {}).get("imageDigest") or ""
containers = (revision.get("spec", {}) or {}).get("containers") or [{}]
print(digest if "@sha256:" in digest else (containers[0] or {}).get("image") or "")
PY
)" || TARGET_IMAGE=""
  # Only Artifact Registry references can be checked (and all gen2 function
  # images live there).
  if [[ ! "$TARGET_IMAGE" =~ ^[a-z][a-z0-9-]*-docker\.pkg\.dev/[^[:space:]]+$ ]]; then
    return 0
  fi
  if gcloud artifacts docker images describe "$TARGET_IMAGE" --format=json >/dev/null; then
    IMAGE_PREFLIGHT="verified"
  else
    IMAGE_PREFLIGHT="missing"
  fi
}

# Sets HEALTH_PROBE_STATUS: passed (a 2xx), warning (no 2xx), not-run (no URL).
probe_health() {
  local service_url probe_path status
  HEALTH_PROBE_STATUS="not-run"
  echo ""
  echo "==> Health check"
  service_url="$(gcloud run services describe "$SERVICE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format='value(status.url)' 2>/dev/null || echo "")"
  if [[ -z "$service_url" ]]; then
    echo "WARN: could not resolve service URL — skipping health probe." >&2
    return 0
  fi
  # Try a couple of common health paths; fall back to the service root.
  for probe_path in "/healthLive" "/healthCheck" "/"; do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${service_url%/}${probe_path}" 2>/dev/null)" || status="000"
    echo "    GET ${service_url%/}${probe_path} -> HTTP ${status}"
    if [[ "$status" =~ ^2 ]]; then
      HEALTH_PROBE_STATUS="passed"
      return 0
    fi
  done
  HEALTH_PROBE_STATUS="warning"
  echo "WARN: health probe did not return 2xx — verify manually before declaring the incident resolved." >&2
}

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --revisions-json) REVISIONS_JSON_FILE="${2:?--revisions-json needs a file}"; shift 2 ;;
    --revisions-json=*) REVISIONS_JSON_FILE="${1#*=}"; shift ;;
    --drill) DRILL=true; shift ;;
    --receipt) DRILL_RECEIPT="${2:?--receipt needs a file}"; shift 2 ;;
    --receipt=*) DRILL_RECEIPT="${1#*=}"; shift ;;
    --region) REGION="${2:?--region needs a value}"; shift 2 ;;
    --region=*) REGION="${1#*=}"; shift ;;
    --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown flag: $1" >&2; usage; exit 1 ;;
    *)
      if [[ -z "$SERVICE" ]]; then
        SERVICE="$1"
      elif [[ -z "$TARGET_REVISION" ]]; then
        TARGET_REVISION="$1"
      else
        echo "ERROR: unexpected positional argument: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SERVICE" ]]; then
  echo "ERROR: <cloud-run-service> is required." >&2
  usage
  exit 1
fi
if [[ ! "$SERVICE" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
  echo "ERROR: service must be a Cloud Run service name, not a resource path or URL." >&2
  exit 1
fi
if [[ ! "$REGION" =~ ^[a-z]+-[a-z0-9]+$ ]]; then
  echo "ERROR: region must be a Cloud Run region name." >&2
  exit 1
fi

if [[ -n "$REVISIONS_JSON_FILE" && -n "$REVISIONS_JSON_INPUT" ]]; then
  echo "ERROR: use only one of --revisions-json and ROLLBACK_REVISIONS_JSON." >&2
  exit 1
fi

# A fixture is an offline plan input. It must never be allowed to flow into a
# traffic mutation or a live drill receipt, even if an operator forgets
# --dry-run.
FIXTURE_MODE=false
if [[ -n "$REVISIONS_JSON_FILE" || -n "$REVISIONS_JSON_INPUT" ]]; then
  FIXTURE_MODE=true
fi
if [[ "$DRILL" == "true" && "$FIXTURE_MODE" == "true" ]]; then
  echo "ERROR: --drill requires a real gcloud session; fixture revisions are offline only." >&2
  exit 1
fi
if [[ "$DRILL" == "true" && -z "$DRILL_RECEIPT" ]]; then
  echo "ERROR: --drill requires --receipt <file> or ROLLBACK_DRILL_RECEIPT." >&2
  exit 1
fi
if [[ "$DRILL" != "true" && -n "$DRILL_RECEIPT" ]]; then
  echo "ERROR: --receipt is only valid with --drill; no receipt is recorded for an ordinary rollback." >&2
  exit 1
fi
if [[ "$(basename "${DRILL_RECEIPT:-none}")" == "$LATEST_DRILL_POINTER" ]]; then
  echo "ERROR: write a dated receipt (launch-evidence/rollback-drill-<date>-<project>.json); the script maintains ${LATEST_DRILL_POINTER} itself." >&2
  exit 1
fi
if [[ "$DRILL" == "true" && "$DRY_RUN" == "true" ]]; then
  echo "ERROR: --drill cannot be combined with --dry-run." >&2
  exit 1
fi

if [[ "$FIXTURE_MODE" != "true" ]] && ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud CLI not found. Install Cloud SDK and authenticate, or pass --revisions-json <file>." >&2
  exit 1
fi

# ── Resolve project (flag → environment → .firebaserc → gcloud config) ─────
if [[ -z "$PROJECT" ]]; then
  PROJECT="${FIREBASE_PROJECT:-${GCLOUD_PROJECT:-}}"
fi
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(firebaserc_project default)"
fi
if [[ -z "$PROJECT" && "$FIXTURE_MODE" != "true" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || echo "")"
fi
if [[ -z "$PROJECT" && "$FIXTURE_MODE" == "true" ]]; then
  PROJECT="burnbar"
fi
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: could not resolve GCP project. Pass --project <p> or set the .firebaserc default." >&2
  exit 1
fi

if [[ "$FIXTURE_MODE" == "true" ]]; then
  if [[ -n "$REVISIONS_JSON_FILE" ]]; then
    if [[ ! -f "$REVISIONS_JSON_FILE" ]]; then
      echo "ERROR: revisions fixture not found: ${REVISIONS_JSON_FILE}" >&2
      exit 1
    fi
    REVISIONS_JSON="$(cat "$REVISIONS_JSON_FILE")"
  elif [[ -f "$REVISIONS_JSON_INPUT" ]]; then
    REVISIONS_JSON="$(cat "$REVISIONS_JSON_INPUT")"
  else
    REVISIONS_JSON="$REVISIONS_JSON_INPUT"
  fi

  fixture_payload="$REVISIONS_JSON"
  # Accept either the raw gcloud revisions-list array or an object carrying a
  # `revisions`/`result` array. The latter makes fixtures self-describing
  # without changing the production gcloud response contract. An optional
  # `traffic` object lets an offline fixture exercise automatic target
  # selection with the same service readback shape as gcloud.
  if ! REVISIONS_JSON="$(python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError) as exc:
    print(f"invalid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

if isinstance(payload, list):
    revisions = payload
elif isinstance(payload, dict):
    revisions = payload.get("revisions", payload.get("result", payload.get("items", [])))
else:
    revisions = []

if not isinstance(revisions, list):
    print("fixture must contain a revisions array", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps(revisions))
 ' <<<"$REVISIONS_JSON"
)"; then
    echo "ERROR: invalid revisions fixture." >&2
    exit 1
  fi
  if [[ -z "$TRAFFIC_JSON" ]]; then
    if ! TRAFFIC_JSON="$(python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(1)

traffic = payload.get("traffic", {}) if isinstance(payload, dict) else {}
print(json.dumps(traffic if isinstance(traffic, dict) else {}))
 ' <<<"$fixture_payload"
)"; then
      echo "ERROR: invalid revisions fixture." >&2
      exit 1
    fi
  fi
else
  REVISIONS_JSON="$(gcloud run revisions list \
    --service "$SERVICE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --sort-by='~metadata.creationTimestamp' \
    --format=json)"

  # Current per-revision traffic split lives on the service, not the revisions.
  TRAFFIC_JSON="$(gcloud run services describe "$SERVICE" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format='json(status.traffic)')"
fi

echo "==> Fast revision-pin rollback"
echo "    service=${SERVICE}"
echo "    region=${REGION}"
echo "    project=${PROJECT}"
if [[ "$FIXTURE_MODE" == "true" ]]; then
  echo "    source=fixture (offline; no traffic mutation)"
fi

# ── List revisions (most recent first) ────────────────────────────────────
# Columns: name + the traffic percent currently routed to each revision.
echo ""
echo "==> Listing revisions for ${SERVICE} (most recent first)"

if [[ -z "$REVISIONS_JSON" || "$REVISIONS_JSON" == "[]" ]]; then
  echo "ERROR: no revisions found for service '${SERVICE}' in ${REGION}/${PROJECT}." >&2
  exit 1
fi

# Human-readable table: revision name + live traffic percent.
python3 - "$REVISIONS_JSON" "$TRAFFIC_JSON" <<'PY'
import json, sys
revisions = json.loads(sys.argv[1] or "[]")
traffic = json.loads(sys.argv[2] or "{}")
pct = {}
entries = (traffic.get("status", {}) or {}).get("traffic")
if entries is None:
    entries = traffic.get("traffic", [])
for t in entries or []:
    name = t.get("revisionName")
    if name:
        pct[name] = pct.get(name, 0) + int(t.get("percent") or 0)
print(f"    {'REVISION':<44} {'TRAFFIC':>8}")
for r in revisions:
    name = (r.get("metadata", {}) or {}).get("name", "")
    share = pct.get(name, 0)
    marker = "  <- serving" if share >= 100 else ""
    print(f"    {name:<44} {str(share)+'%':>8}{marker}")
PY

# ── Resolve target revision if not supplied ───────────────────────────────
if [[ -z "$TARGET_REVISION" ]]; then
  echo ""
  echo "==> No target revision given — selecting the most recent revision NOT serving 100% traffic"
  TARGET_REVISION="$(python3 - "$REVISIONS_JSON" "$TRAFFIC_JSON" <<'PY'
import json, sys
revisions = json.loads(sys.argv[1] or "[]")
traffic = json.loads(sys.argv[2] or "{}")
pct = {}
entries = (traffic.get("status", {}) or {}).get("traffic")
if entries is None:
    entries = traffic.get("traffic", [])
for t in entries or []:
    name = t.get("revisionName")
    if name:
        pct[name] = pct.get(name, 0) + int(t.get("percent") or 0)
# revisions are already sorted newest-first; pick the first one not serving 100%.
for r in revisions:
    name = (r.get("metadata", {}) or {}).get("name", "")
    if not name:
        continue
    if pct.get(name, 0) < 100:
        print(name)
        break
PY
)"
  if [[ -z "$TARGET_REVISION" ]]; then
    echo "ERROR: could not find a previous revision to roll back to (only one revision, or all share traffic)." >&2
    echo "       Pass an explicit <target-revision>, or use the slow source rollback (scripts/rollback.sh)." >&2
    exit 1
  fi
else
  # Validate the explicitly-requested revision actually exists.
  if ! python3 - "$TARGET_REVISION" "$REVISIONS_JSON" <<'PY'
import json
import sys

target = sys.argv[1]
revisions = json.loads(sys.argv[2] or "[]")
names = {
    (revision.get("metadata", {}) or {}).get("name", "")
    for revision in revisions
    if isinstance(revision, dict)
}
raise SystemExit(0 if target in names else 1)
PY
  then
    echo "ERROR: revision '${TARGET_REVISION}' not found for service '${SERVICE}'." >&2
    exit 1
  fi
fi

if [[ ! "$TARGET_REVISION" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
  echo "ERROR: target revision must be a Cloud Run revision name." >&2
  exit 1
fi

UPDATE_CMD=(gcloud run services update-traffic "$SERVICE"
  --region "$REGION"
  --project "$PROJECT"
  "--to-revisions=${TARGET_REVISION}=100")

# ── Drill: capture the pre-drill traffic so it can be restored exactly ─────
if [[ "$DRILL" == "true" ]]; then
  PREVIOUS_SERVING="$(traffic_state "$TRAFFIC_JSON")"
  PREVIOUS_MODE="${PREVIOUS_SERVING%% *}"
  PREVIOUS_REVISION="${PREVIOUS_SERVING#* }"
  if [[ "$PREVIOUS_MODE" == "latest" ]]; then
    RESTORE_FLAG="--to-latest"
  elif [[ "$PREVIOUS_MODE" == "revision" && "$PREVIOUS_REVISION" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
    RESTORE_FLAG="--to-revisions=${PREVIOUS_REVISION}=100"
  else
    echo "ERROR: --drill needs ${SERVICE} serving 100% on LATEST or on one pinned revision, so the drill can restore it exactly; live traffic is split." >&2
    exit 1
  fi
  if [[ "$TARGET_REVISION" == "$PREVIOUS_REVISION" ]]; then
    echo "ERROR: ${TARGET_REVISION} already serves 100%; a drill has to move traffic to another revision." >&2
    exit 1
  fi
  RESTORE_CMD=(gcloud run services update-traffic "$SERVICE"
    --region "$REGION"
    --project "$PROJECT"
    "$RESTORE_FLAG")
fi

# ── Image preflight (read-only; before any traffic change) ────────────────
IMAGE_PREFLIGHT="not-run"
TARGET_IMAGE=""
if [[ "$FIXTURE_MODE" != "true" ]]; then
  image_preflight
fi

echo ""
echo "=== Revision-pin rollback plan ==="
echo "    service:  ${SERVICE}"
echo "    target:   ${TARGET_REVISION}  (will receive 100% traffic)"
echo "    image:    ${IMAGE_PREFLIGHT}${TARGET_IMAGE:+  (${TARGET_IMAGE})}"
echo "    command:  ${UPDATE_CMD[*]}"
if [[ "$DRILL" == "true" ]]; then
  echo "    restore:  ${RESTORE_CMD[*]}  (pre-drill: ${PREVIOUS_SERVING})"
fi
echo ""

if [[ "$FIXTURE_MODE" != "true" && "$IMAGE_PREFLIGHT" != "verified" ]]; then
  if [[ "$DRILL" == "true" ]]; then
    echo "ERROR: the image for ${TARGET_REVISION} is ${IMAGE_PREFLIGHT} in Artifact Registry; refusing the drill before any traffic change." >&2
    echo "       A revision without its image cannot serve. Rollback today is the slow source path: scripts/rollback.sh" >&2
    echo "       Keep rollback images with the retention floors in governance/ops-artifact-retention.json, then re-drill after the next deploy." >&2
    exit 1
  fi
  echo "WARN: the image for ${TARGET_REVISION} is ${IMAGE_PREFLIGHT} in Artifact Registry. Cloud Run refuses the pin if the image is gone (traffic stays put); if it does, use the slow source path: scripts/rollback.sh" >&2
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: no traffic changed."
  exit 0
fi
if [[ "$FIXTURE_MODE" == "true" ]]; then
  echo "FIXTURE INPUT: no traffic changed and no live receipt recorded."
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────
if [[ "$ASSUME_YES" != "true" ]]; then
  prompt="Pin 100% traffic to ${TARGET_REVISION}?"
  if [[ "$DRILL" == "true" ]]; then
    prompt="Drill: pin 100% traffic to ${TARGET_REVISION}, then restore ${PREVIOUS_SERVING}?"
  fi
  read -r -p "${prompt} [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Rollback cancelled."
    exit 0
  fi
fi

# ── Flip traffic ──────────────────────────────────────────────────────────
echo "==> Flipping 100% traffic to ${TARGET_REVISION} (no rebuild)"
if [[ "$DRILL" != "true" ]]; then
  "${UPDATE_CMD[@]}"
  echo "PASS: traffic pinned to ${TARGET_REVISION}"
  probe_health
  echo ""
  echo "=== Revision-pin rollback complete ==="
  echo "    Serving: ${TARGET_REVISION} (100%)"
  echo ""
  echo "Next steps:"
  echo "  1. Confirm error rate recovers (Cloud Monitoring / firebase functions:log)."
  echo "  2. Fix forward on a branch; redeploy via the normal release path."
  echo "  3. If revisions are unusable, fall back to the slow source rollback: scripts/rollback.sh"
  exit 0
fi

# Drill: once the pin has been attempted, every path restores the pre-drill
# traffic before exiting, and only a fully proven round trip writes a receipt.
drill_failure=""
if ! "${UPDATE_CMD[@]}"; then
  drill_failure="Cloud Run refused the pin to ${TARGET_REVISION}"
elif ! live_traffic_is revision "$TARGET_REVISION"; then
  drill_failure="live traffic readback did not confirm 100% on ${TARGET_REVISION}"
else
  echo "PASS: live traffic readback confirmed 100% on ${TARGET_REVISION}"
  probe_health
  if [[ "$HEALTH_PROBE_STATUS" != "passed" ]]; then
    drill_failure="the health probe on ${TARGET_REVISION} did not pass (${HEALTH_PROBE_STATUS})"
  fi
fi

echo ""
echo "==> Restoring pre-drill traffic (${PREVIOUS_SERVING})"
if ! "${RESTORE_CMD[@]}" || ! live_traffic_is "$PREVIOUS_MODE" "$PREVIOUS_REVISION"; then
  echo "ERROR: the restore of pre-drill traffic (${PREVIOUS_SERVING}) was not confirmed; ${SERVICE} may still be pinned to ${TARGET_REVISION}. No drill receipt recorded." >&2
  echo "       Restore it by hand now:" >&2
  echo "       ${RESTORE_CMD[*]}" >&2
  exit 1
fi
echo "PASS: live traffic readback confirmed the restore (${PREVIOUS_SERVING})"
if [[ -n "$drill_failure" ]]; then
  echo "ERROR: drill failed: ${drill_failure}. Pre-drill traffic is restored; no drill receipt recorded." >&2
  exit 1
fi

receipt_directory="$(dirname "$DRILL_RECEIPT")"
mkdir -p "$receipt_directory"
receipt_tmp="$(mktemp "${DRILL_RECEIPT}.tmp.XXXXXX")"
trap 'rm -f "$receipt_tmp"' EXIT
python3 - "$receipt_tmp" "$SERVICE" "$REGION" "$TARGET_REVISION" "$HEALTH_PROBE_STATUS" "$PREVIOUS_MODE" "$PREVIOUS_REVISION" <<'PY'
import json
import sys
from datetime import datetime, timezone

output, service, region, target_revision, health_status, previous_mode, previous_revision = sys.argv[1:]
previous_serving = {"mode": previous_mode}
if previous_revision:
    previous_serving["revision"] = previous_revision
receipt = {
    "schema": "openburnbar.rollback-drill-receipt.v1",
    "schemaVersion": 1,
    "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "mode": "live",
    "liveDrill": True,
    "ok": True,
    "drill": {
        "kind": "cloud-run-revision-pin",
        "serviceName": service,
        "region": region,
        "targetRevision": target_revision,
        "trafficPercent": 100,
        "healthProbe": health_status,
        "imagePreflight": "verified",
        "previousServing": previous_serving,
        "restore": {"mode": previous_mode, "confirmed": True},
    },
    "checks": {
        "revisionListLoaded": True,
        "trafficPinned": True,
        "liveGcloudSession": True,
        "imageVerified": True,
        "trafficRestored": True,
    },
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2)
    handle.write("\n")
PY
mv "$receipt_tmp" "$DRILL_RECEIPT"
trap - EXIT
echo "LIVE DRILL RECEIPT: ${DRILL_RECEIPT}"

pointer="${receipt_directory}/${LATEST_DRILL_POINTER}"
if [[ "$(basename "$receipt_directory")" == "launch-evidence" ]]; then
  if [[ "$PROJECT" == "$(firebaserc_project default)" ]]; then
    cp "$DRILL_RECEIPT" "$pointer"
    echo "LATEST PRODUCTION DRILL: ${pointer}"
  else
    echo "NOTE: ${pointer} tracks the production project only; left unchanged for ${PROJECT}."
  fi
fi

echo ""
echo "=== Revision-pin rollback drill complete ==="
echo "    Pinned ${TARGET_REVISION} (100%, health ${HEALTH_PROBE_STATUS}), then restored ${PREVIOUS_SERVING}."
