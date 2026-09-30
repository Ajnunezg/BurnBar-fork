#!/usr/bin/env node
/**
 * Reconciles the user-defined log metrics required by ops-alert-policy-definitions.mjs
 * (definitions: ops-log-metric-definitions.mjs). Idempotent: creates missing
 * metrics and UPDATES any whose live filter or description drifted — a live
 * metric is never skipped just because it exists.
 *
 *   node functions/scripts/create-ops-log-metrics.mjs           # apply
 *   node functions/scripts/create-ops-log-metrics.mjs --check   # report drift, exit 1 if any
 *
 * env GCLOUD_PROJECT / GOOGLE_CLOUD_PROJECT (default: burnbar)
 */
import { execFileSync } from "node:child_process";

import { OPS_LOG_METRICS, planOpsLogMetricReconcile } from "./ops-log-metric-definitions.mjs";

const project = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "burnbar";
const checkOnly = process.argv.includes("--check");

function listLiveMetrics() {
  // A failed listing must stop the run: treating it as "no metrics" would try to
  // re-create every metric and, in --check mode, report a false plan.
  const out = execFileSync("gcloud", ["logging", "metrics", "list", `--project=${project}`, "--format=json"], {
    encoding: "utf8",
  });
  return JSON.parse(out || "[]");
}

const plan = planOpsLogMetricReconcile(listLiveMetrics(), OPS_LOG_METRICS);
for (const metric of plan.unchanged) console.error(`ok: ${metric.name}`);
for (const metric of plan.create) console.error(`missing: ${metric.name}`);
for (const metric of plan.update) {
  console.error(`drifted: ${metric.name}\n  live:    ${metric.liveFilter}\n  desired: ${metric.filter}`);
}

if (checkOnly) {
  process.exit(plan.create.length + plan.update.length > 0 ? 1 : 0);
}

for (const metric of plan.create) {
  console.error(`create: ${metric.name}`);
  execFileSync(
    "gcloud",
    [
      "logging",
      "metrics",
      "create",
      metric.name,
      `--description=${metric.description}`,
      `--log-filter=${metric.filter}`,
      `--project=${project}`,
    ],
    { stdio: "inherit" },
  );
}
for (const metric of plan.update) {
  console.error(`update: ${metric.name}`);
  execFileSync(
    "gcloud",
    [
      "logging",
      "metrics",
      "update",
      metric.name,
      `--description=${metric.description}`,
      `--log-filter=${metric.filter}`,
      `--project=${project}`,
    ],
    { stdio: "inherit" },
  );
}
