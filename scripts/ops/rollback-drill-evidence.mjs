/**
 * Launch-gate verdict on the Cloud Run revision-pin rollback drill receipt
 * (docs/schemas/rollback-drill-receipt.schema.json) that
 * scripts/ops/rollback-revision.sh --drill copies to
 * launch-evidence/latest-rollback-revision-drill.json for the production
 * project. The 2026-09-23 drill found no servable previous revision, so fast
 * rollback only counts once a live pin-and-restore round trip has passed.
 */
import { readFileSync } from "node:fs";
import { isObject, validateAgainstSchema } from "../lib/json-schema-subset.mjs";

export const ROLLBACK_DRILL_COMMAND =
  'bash scripts/ops/rollback-revision.sh healthready --project burnbar --region us-central1 --yes --drill --receipt "launch-evidence/rollback-drill-$(date -u +%F)-burnbar.json"';
/** Fresh for launch, and each production deploy reshapes which N-1 exists. */
export const DEFAULT_ROLLBACK_DRILL_TTL_DAYS = 30;

const RECEIPT_SCHEMA = "openburnbar.rollback-drill-receipt.v1";
const DAY_MS = 24 * 60 * 60 * 1000;
const FUTURE_SKEW_MS = 5 * 60 * 1000;

let receiptSchema;

function schemaErrors(receipt) {
  receiptSchema ??= JSON.parse(
    readFileSync(new URL("../../docs/schemas/rollback-drill-receipt.schema.json", import.meta.url), "utf8"),
  );
  return validateAgainstSchema(receipt, receiptSchema);
}

export function evaluateRollbackRevisionDrillEvidence(
  receipt,
  { now = new Date(), maxAgeDays = DEFAULT_ROLLBACK_DRILL_TTL_DAYS } = {},
) {
  const failures = [];
  if (!isObject(receipt)) {
    return { ok: false, failures: ["receipt is not a JSON object"], command: ROLLBACK_DRILL_COMMAND };
  }
  failures.push(...schemaErrors(receipt));
  if (receipt.schema !== RECEIPT_SCHEMA) failures.push(`schema must be ${RECEIPT_SCHEMA}`);
  if (receipt.mode !== "live" || receipt.liveDrill !== true) failures.push("receipt must come from a live drill, not a fixture");
  if (receipt.ok !== true) failures.push("drill did not pass");
  const drill = isObject(receipt.drill) ? receipt.drill : {};
  const checks = isObject(receipt.checks) ? receipt.checks : {};
  if (drill.healthProbe !== "passed") failures.push("the pinned revision's health probe did not pass");
  if (drill.imagePreflight !== "verified" || checks.imageVerified !== true) {
    failures.push("the target revision's image was not verified in Artifact Registry");
  }
  if (drill.restore?.confirmed !== true || checks.trafficRestored !== true) {
    failures.push("the pre-drill traffic restore was not confirmed (a one-way pin is not a drill)");
  }
  const generatedAt = Date.parse(receipt.generatedAt ?? "");
  let ageDays = null;
  if (!Number.isFinite(generatedAt)) {
    failures.push("generatedAt is missing or unparseable");
  } else if (generatedAt - now.getTime() > FUTURE_SKEW_MS) {
    failures.push("generatedAt is in the future");
  } else {
    ageDays = Math.max(0, (now.getTime() - generatedAt) / DAY_MS);
    if (ageDays > maxAgeDays) failures.push(`drill is ${ageDays.toFixed(1)} days old (max ${maxAgeDays})`);
  }
  return {
    ok: failures.length === 0,
    serviceName: drill.serviceName ?? null,
    targetRevision: drill.targetRevision ?? null,
    generatedAt: receipt.generatedAt ?? null,
    ageDays: ageDays === null ? null : Math.round(ageDays * 10) / 10,
    maxAgeDays,
    failures,
    ...(failures.length ? { command: ROLLBACK_DRILL_COMMAND } : {}),
  };
}

export function readRollbackRevisionDrillEvidence(path, options = {}) {
  let receipt;
  try {
    receipt = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    const missing = error?.code === "ENOENT";
    return {
      ok: false,
      path,
      failures: [missing ? `missing ${path}` : `cannot read ${path}: ${error.message}`],
      command: ROLLBACK_DRILL_COMMAND,
    };
  }
  return { path, ...evaluateRollbackRevisionDrillEvidence(receipt, options) };
}
