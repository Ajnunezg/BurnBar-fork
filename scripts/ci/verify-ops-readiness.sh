#!/usr/bin/env bash
# Meta gate: callable logging, resilience wiring, ops policy manifests, and the
# production ops-plane scripts.
#
# Every script this gate vouches for is exercised by a behavior test with
# positive and negative controls (stubbed gcloud/curl/gh, never live GCP). A
# script that cannot be exercised offline is listed as PARSE-ONLY and counted
# separately in the final line, so a syntax check is never reported as
# verification (diligence 2026-09-28: 17 `bash -n` + 11 `node --check` read as
# ops readiness).
set -euo pipefail
cd "$(dirname "$0")/../.."

behavior_suites=0
parse_only=()

behavior() {
  local label="$1"
  shift
  echo "==> ${label}"
  "$@"
  behavior_suites=$((behavior_suites + 1))
}

# Syntax check only; no behavior claim. Keep this list short and justified.
parse_only_check() {
  local reason="$1" path="$2"
  case "$path" in
    *.sh) bash -n "$path" ;;
    *.mjs) node --check "$path" ;;
    *) echo "unsupported parse-only target: $path" >&2; return 1 ;;
  esac
  parse_only+=("${path} (${reason})")
}

behavior "verify-callable-logging controls + live scan" \
  bash scripts/ci/verify-callable-logging.test.sh

behavior "verify-resilience-wiring" bash scripts/ci/verify-resilience-wiring.sh

behavior "verify-agpl-compliance" bash scripts/ci/verify-agpl-compliance.sh

# F5: the on-host Hermes agent runtime ships as bytecode; this gate proves it
# corresponds to the reviewed source AND that the C-4 command-guard hardening is
# present (manifest.pendingHardening.blocking == false). Pre-beta ops-readiness
# MUST NOT pass while the agent can't be trusted to refuse destructive/exfil
# commands. Requires a hermes-agent checkout (HERMES_AGENT_SRC, default
# ~/.hermes/hermes-agent); the verify script fails closed if it is missing.
behavior "verify-vendored-agent-source (agent runtime provenance + command-guard gate)" \
  bash scripts/ci/verify-vendored-agent-source.sh

behavior "ops alert policy manifest" node functions/scripts/test-ops-alert-policy-definitions.mjs
parse_only_check "applies live GCP alert policies; manifest content is tested above" functions/scripts/apply-ops-alert-policies.mjs
parse_only_check "creates live GCP log metrics; no offline mode" functions/scripts/create-ops-log-metrics.mjs

# Both drift checks gate LIVE state == committed source of truth in CI (they need
# creds). Here their creds-free self-tests prove the DIFF LOGIC can still detect
# drift: a broken drift check that can no longer detect drift must fail loud.
behavior "branch-protection drift self-test" node --test scripts/ops/check-branch-protection-drift.test.mjs
behavior "ops alert-plane drift self-test" node --test scripts/ops/check-ops-alert-plane-drift.test.mjs
behavior "billing budget drift self-test" node --test scripts/ops/check-billing-budget-drift.test.mjs
behavior "artifact retention drift self-test" node --test scripts/ops/check-artifact-retention-drift.test.mjs

behavior "post-deploy health gate (stubbed probes)" bash scripts/ci/post-deploy-health-gate.test.sh
behavior "hosted MCP deploy health" bash scripts/ci/verify-hosted-mcp-deploy-health.sh

behavior "rollback.sh" bash scripts/rollback.test.sh
behavior "rollback-revision.sh" bash scripts/ops/rollback-revision.test.sh
behavior "rollback-macos-appcast.sh" bash scripts/ops/rollback-macos-appcast.test.sh
behavior "Firestore restore drill validation" bash scripts/ops/run-firestore-restore-drill.test.sh
behavior "Firestore App Check enforcement verifier" bash scripts/ops/verify-firestore-app-check-enforcement.test.sh
behavior "ops-plane scripts: DR posture verifier, URL resolver, fail-closed deploy/activate guards" \
  bash scripts/ops/ops-plane-scripts.test.sh
parse_only_check "orchestrates the gates above against live production; recursion-safe only as a parse" \
  scripts/ops/verify-production-ops-plane.sh
parse_only_check "live gh governance read; its drift logic is the self-test above" scripts/ops/verify-github-governance.sh
parse_only_check "operator discovery printout, never a gate" scripts/ops/discover-gcp-access.sh
parse_only_check "live GCP read; alert checks are covered by ops-alerts-gate tests" scripts/ops/check-ops-alerts.mjs

behavior "ops alerts gate library" node --test scripts/lib/ops-alerts-gate.test.mjs
behavior "alert delivery drill library" node --test scripts/lib/alert-delivery-drill.test.mjs
parse_only_check "sends a live alert; drill logic is the library test above" scripts/ops/run-alert-delivery-drill.mjs

behavior "release attestation verifier" bash scripts/ci/verify-release-attestations.test.sh

behavior "Phase 1 security register structural gates" bash scripts/ci/verify-phase1-security-gates.sh

behavior "privacy invariants gate (run-09) self-test" node scripts/ci/check-privacy-invariants.test.mjs
behavior "privacy invariants gate (run-09) enforce" node scripts/ci/check-privacy-invariants.mjs

behavior "credential-transfer secret boundary" bash scripts/ci/verify-credential-transfer-secret-boundary.sh

echo "Parse-only (no behavior claim):"
for item in "${parse_only[@]}"; do
  echo "  - ${item}"
done
echo "PASS: ops readiness — ${behavior_suites} behavior suites passed; ${#parse_only[@]} scripts parse-only"
