#!/usr/bin/env node
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { OPS_ALERT_POLICIES, OPS_SLO_ALERT_POLICIES } from "./ops-alert-policy-definitions.mjs";
import {
  FUNCTIONS_LOG_RESOURCE_TYPE,
  OPS_LOG_METRICS,
  planOpsLogMetricReconcile,
} from "./ops-log-metric-definitions.mjs";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));

function policy(name) {
  const found = OPS_SLO_ALERT_POLICIES.find((entry) => entry.displayName === name);
  assert.ok(found, `missing policy: ${name}`);
  return found;
}

function conditionFilters(entry) {
  return entry.conditions.map((condition) => condition.conditionThreshold?.filter ?? "");
}

const userMetricName = (filter) => /metric\.type="logging\.googleapis\.com\/user\/([^"]+)"/.exec(filter)?.[1];
const resourceType = (filter) => /resource\.type="([^"]+)"/.exec(filter)?.[1];

function sourceFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules" || entry === "lib" || entry === "__tests__") continue;
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) out.push(...sourceFiles(path));
    else if (entry.endsWith(".ts")) out.push(path);
  }
  return out;
}

{
  const rollupBreaker = policy("OpenBurnBar Rollup rebuild breaker open");
  const filters = conditionFilters(rollupBreaker);
  assert.equal(filters.length, 2);
  for (const filter of filters) {
    assert.match(filter, /resource\.type="cloud_run_revision"/);
    assert.doesNotMatch(filter, /resource\.type="cloud_function"/);
  }
  assert.ok(filters.some((filter) => filter.includes("openburnbar_rollup_breaker_open")));
  assert.ok(filters.some((filter) => filter.includes("openburnbar_rollup_rebuild_failed")));
}

{
  const deltaCapped = policy("OpenBurnBar Rollup delta drain capped");
  const [filter] = conditionFilters(deltaCapped);
  assert.match(filter, /resource\.type="cloud_run_revision"/);
  assert.doesNotMatch(filter, /resource\.type="cloud_function"/);
  assert.match(filter, /openburnbar_rollup_delta_drain_capped/);
}

{
  const deliveryDrill = policy("OpenBurnBar alert-delivery drill canary");
  assert.equal(deliveryDrill.conditions.length, 1);
  const threshold = deliveryDrill.conditions[0].conditionThreshold;
  assert.equal(threshold?.duration, "0s");
  assert.equal(threshold?.thresholdValue, 0);
  assert.equal(threshold?.aggregations?.[0]?.perSeriesAligner, "ALIGN_DELTA");
}

// Premise: every Functions codebase is 2nd gen, so "cloud_function" (1st gen) is
// never the resource type of any log entry this repo emits. If a v1 Function is
// ever added, this fails first and says why the filters below must change.
{
  const codebases = ["functions", "functions-identity", "functions-sync", "functions-media", "packages/functions-shared"];
  const v1 = codebases
    .flatMap((codebase) => sourceFiles(join(repoRoot, codebase, "src")))
    .filter((file) => /["']firebase-functions\/v1["']/.test(readFileSync(file, "utf8")));
  assert.deepEqual(v1, [], "a 1st-gen Function logs as cloud_function; update the resource-type contract before adding one");
}

// No metric or policy filter may target the 1st-gen resource type: it matches no
// live log entry, so the metric stays flat and the alert can never fire.
{
  for (const metric of OPS_LOG_METRICS) {
    assert.doesNotMatch(metric.filter, /cloud_function/, `${metric.name} filters on the 1st-gen resource type`);
  }
  for (const entry of OPS_ALERT_POLICIES) {
    for (const filter of conditionFilters(entry)) {
      assert.doesNotMatch(filter, /cloud_function/, `${entry.displayName} filters on the 1st-gen resource type`);
    }
  }
  const budgetTemplates = readFileSync(join(repoRoot, "scripts/create-computer-use-budget-alerts.mjs"), "utf8");
  assert.doesNotMatch(budgetTemplates, /resource\.type="cloud_function"/, "budget alert templates target a dead resource type");
}

// Every condition on a user log metric must (a) reference a metric this repo
// creates and (b) name the resource type that metric's log entries carry: the
// type its own filter pins, else cloud_run_revision — except the delivery drill,
// whose canary is written by `gcloud logging write` (resource.type="global").
{
  const metricsByName = new Map(OPS_LOG_METRICS.map((metric) => [metric.name, metric]));
  const writtenAs = { openburnbar_alert_delivery_drill: "global" };
  let checked = 0;
  for (const entry of OPS_ALERT_POLICIES) {
    for (const filter of conditionFilters(entry)) {
      const name = userMetricName(filter);
      if (!name) continue;
      const metric = metricsByName.get(name);
      assert.ok(metric, `${entry.displayName} alerts on ${name}, which create-ops-log-metrics.mjs never creates`);
      const expected = resourceType(metric.filter) ?? writtenAs[name] ?? FUNCTIONS_LOG_RESOURCE_TYPE;
      assert.equal(resourceType(filter), expected, `${entry.displayName}: ${name} series carry resource.type="${expected}"`);
      checked += 1;
    }
    for (const required of entry.requiredMetricTypes ?? []) {
      const name = /^logging\.googleapis\.com\/user\/(.+)$/.exec(required)?.[1];
      if (name) assert.ok(metricsByName.has(name), `${entry.displayName} requires undefined metric ${name}`);
    }
  }
  assert.ok(checked >= 8, `expected every log-metric condition to be checked, saw ${checked}`);
}

// The two conditions that were disarmed (codex diligence 2026-09): callable
// errors and resilience breaker trips now match 2nd-gen series.
{
  const [callable] = conditionFilters(policy("OpenBurnBar Callable error spike"));
  assert.equal(resourceType(callable), "cloud_run_revision");
  assert.equal(userMetricName(callable), "openburnbar_callable_error");
  const callableMetric = OPS_LOG_METRICS.find((metric) => metric.name === "openburnbar_callable_error");
  assert.equal(callableMetric?.filter, 'resource.type="cloud_run_revision" AND jsonPayload.event="callable_error"');
  const [breaker] = conditionFilters(policy("OpenBurnBar Circuit breaker open"));
  assert.equal(resourceType(breaker), "cloud_run_revision");
}

// A refused credential erasure pages a human: the metric counts the exact event
// providerSecretErasure.ts logs, and the policy is armed on 2nd-gen series.
{
  const erasureSource = readFileSync(join(repoRoot, "packages/functions-shared/src/providerSecretErasure.ts"), "utf8");
  assert.match(erasureSource, /event: "provider_secret_erasure_failed"/);
  const metric = OPS_LOG_METRICS.find((entry) => entry.name === "openburnbar_provider_secret_erasure_failed");
  assert.equal(
    metric?.filter,
    'resource.type="cloud_run_revision" AND jsonPayload.event="provider_secret_erasure_failed"',
  );
  const stuck = policy("OpenBurnBar Provider credential erasure stuck");
  const threshold = stuck.conditions[0].conditionThreshold;
  assert.equal(userMetricName(threshold.filter), "openburnbar_provider_secret_erasure_failed");
  assert.equal(threshold.comparison, "COMPARISON_GT");
  assert.equal(threshold.thresholdValue, 1);
  assert.equal(threshold.aggregations[0].alignmentPeriod, "3600s");
}

// Re-applying must CORRECT a live metric whose filter drifted (the old script
// skipped any metric that already existed, so a fixed definition never landed).
{
  const live = [
    {
      name: "projects/burnbar/metrics/openburnbar_callable_error",
      description: "Cloud Functions callable_error structured logs",
      filter: 'resource.type="cloud_function" AND jsonPayload.event="callable_error"',
    },
    ...OPS_LOG_METRICS.filter((metric) => !["openburnbar_callable_error", "openburnbar_alert_delivery_drill"].includes(metric.name)),
  ];
  const plan = planOpsLogMetricReconcile(live);
  assert.deepEqual(plan.update.map((metric) => metric.name), ["openburnbar_callable_error"]);
  assert.equal(plan.update[0].liveFilter, 'resource.type="cloud_function" AND jsonPayload.event="callable_error"');
  assert.deepEqual(plan.create.map((metric) => metric.name), ["openburnbar_alert_delivery_drill"]);
  assert.equal(plan.unchanged.length, OPS_LOG_METRICS.length - 2);
  assert.deepEqual(planOpsLogMetricReconcile(OPS_LOG_METRICS), {
    create: [],
    update: [],
    unchanged: OPS_LOG_METRICS,
  });
}

console.log("ops alert policy definition tests passed");
