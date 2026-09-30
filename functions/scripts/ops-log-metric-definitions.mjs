/**
 * Repo-owned user-defined log metrics that back ops-alert-policy-definitions.mjs.
 * Apply (create missing, correct drifted) with:
 *   node functions/scripts/create-ops-log-metrics.mjs [--check]
 *
 * Every Cloud Function in this repo is 2nd gen (firebase-functions/v2), which
 * runs on Cloud Run: its logs carry resource.type="cloud_run_revision". A filter
 * on the 1st-gen type "cloud_function" matches nothing, so the metric stays flat
 * and every alert built on it is silently disarmed.
 */

/** Monitored-resource type of every Functions (2nd gen) and Cloud Run service log entry. */
export const FUNCTIONS_LOG_RESOURCE_TYPE = "cloud_run_revision";

export const OPS_LOG_METRICS = [
  {
    name: "openburnbar_callable_error",
    description: "Cloud Functions (2nd gen) callable_error structured logs",
    filter: `resource.type="${FUNCTIONS_LOG_RESOURCE_TYPE}" AND jsonPayload.event="callable_error"`,
  },
  {
    name: "openburnbar_circuit_breaker_tripped",
    description: "Resilience circuit breaker open events",
    filter: 'jsonPayload.event="circuit_breaker_tripped"',
  },
  {
    name: "openburnbar_hosted_mcp_5xx",
    description: "Hosted MCP 5xx responses",
    filter: `resource.type="${FUNCTIONS_LOG_RESOURCE_TYPE}" AND resource.labels.service_name="openburnbar-hosted-mcp" AND httpRequest.status>=500`,
  },
  // Rollup full-rebuild health (P0-7). The pre-existing "Circuit breaker open"
  // policy watches the cockatiel resilience breakers (circuit_breaker_tripped),
  // a DIFFERENT family — the 2026-06-11 review found rollup breaker events had
  // no metric and no alert. Event keys must match functions/src exactly.
  {
    name: "openburnbar_rollup_breaker_open",
    description: "Per-user rollup full-rebuild circuit breaker opened/skipped",
    filter: 'jsonPayload.event="rollup.full_rebuild_circuit_open"',
  },
  {
    name: "openburnbar_rollup_rebuild_failed",
    description: "Rollup full-rebuild failures (in-process or stale attempt marker)",
    filter: 'jsonPayload.event="rollup.rebuild_failed"',
  },
  {
    name: "openburnbar_rollup_delta_drain_capped",
    description: "Pending-delta drains stopped by the per-invocation page cap (queue backlog)",
    filter: 'jsonPayload.event="rollup.delta_drain_capped"',
  },
  // Hosted provider credential erasure that Secret Manager refused
  // (packages/functions-shared/src/providerSecretErasure.ts): one event per
  // failed attempt, retried by reconcileAccountErasures with backoff.
  {
    name: "openburnbar_provider_secret_erasure_failed",
    description: "Hosted provider credential erasure attempts that left a Secret Manager version undestroyed",
    filter: `resource.type="${FUNCTIONS_LOG_RESOURCE_TYPE}" AND jsonPayload.event="provider_secret_erasure_failed"`,
  },
  {
    name: "openburnbar_alert_delivery_drill",
    description: "Synthetic alert-delivery drill log events used to prove human notification receipt",
    filter: 'jsonPayload.event="alert_delivery_drill"',
  },
];

/**
 * Decide what `create-ops-log-metrics.mjs` must do against the live metrics
 * (`gcloud logging metrics list --format=json`). A live metric whose filter or
 * description drifted is UPDATED, never skipped: skipping is how a stale
 * resource-type filter survived every re-apply.
 */
export function planOpsLogMetricReconcile(liveMetrics, desired = OPS_LOG_METRICS) {
  const liveByName = new Map(
    (Array.isArray(liveMetrics) ? liveMetrics : [])
      .filter((metric) => typeof metric?.name === "string")
      .map((metric) => [metric.name.split("/").pop(), metric]),
  );
  const plan = { create: [], update: [], unchanged: [] };
  for (const metric of desired) {
    const live = liveByName.get(metric.name);
    if (!live) plan.create.push(metric);
    else if ((live.filter ?? "").trim() !== metric.filter || (live.description ?? "") !== metric.description) {
      plan.update.push({ ...metric, liveFilter: live.filter ?? "" });
    } else plan.unchanged.push(metric);
  }
  return plan;
}
