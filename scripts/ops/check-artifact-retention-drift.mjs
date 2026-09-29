#!/usr/bin/env node
/**
 * Fail-closed drift check: the LIVE Artifact Registry cleanup policies vs the
 * committed contract in governance/ops-artifact-retention.json (Wave 1.5).
 *
 * Cloud Run revision-pin rollback needs the previous revision's container
 * image to still exist. The Firebase-default firebase-functions-cleanup
 * policy deletes every image older than 24h, so without KEEP policies the
 * rollback path silently rots within a day; the 2026-09-23 drill measured
 * zero servable previous revisions in both projects. The contract holds two
 * KEEP floors (the newest versions of each image, and every version from the
 * last 7 days). If either is removed, weakened, or scoped to a subset of
 * images out of band, rollback is silently dead; this check makes that a loud
 * red. scripts/ops/apply-artifact-retention.mjs applies the contract.
 *
 * Modes:
 *   (default, CI)  `gcloud artifacts repositories describe gcf-artifacts
 *                  --location=us-central1 --project=<each committed project>
 *                  --format=json`, then diff. Needs gcloud auth with
 *                  roles/artifactregistry.reader on gcf-artifacts in every
 *                  committed project (governance/ops-plane-verifier-sa.json).
 *   --live <file>  Diff a saved JSON snapshot instead (offline, used by the self-test).
 *                  Shape: { "<project>": <describe-json>, ... }.
 *   --self-test    Prove the diff reports MATCH for a faithful snapshot and DRIFT for
 *                  every mutation this guard exists to catch.
 *
 * Exit codes: 0 MATCH · 1 DRIFT · 2 could not read live/committed state.
 */
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const COMMITTED_PATH = join(HERE, "..", "..", "governance", "ops-artifact-retention.json");
const FLOOR_KEYS = ["keepCount", "newerThanSeconds"];
const DURATION_UNIT_SECONDS = { s: 1, m: 60, h: 3600, d: 86400 };

/** Loads the contract; every required policy must be a KEEP with exactly one positive-integer floor. */
export function loadCommitted(path = COMMITTED_PATH) {
  const committed = JSON.parse(readFileSync(path, "utf8"));
  for (const required of committed.requiredPolicies ?? []) {
    const floors = FLOOR_KEYS.filter((key) => required[key] !== undefined);
    if (required.action !== "KEEP" || floors.length !== 1 || !Number.isInteger(required[floors[0]]) || required[floors[0]] < 1) {
      throw new Error(`${path}: policy "${required.name}" must be a KEEP with exactly one positive integer ${FLOOR_KEYS.join(" or ")}`);
    }
  }
  return committed;
}

/** Cleanup-policy durations: describe returns seconds ("604800s"); policy files may use s/m/h/d. */
export function parseDurationSeconds(value) {
  const match = /^(\d+(?:\.\d+)?)([smhd])$/u.exec(typeof value === "string" ? value.trim() : "");
  return match ? Number(match[1]) * DURATION_UNIT_SECONDS[match[2]] : null;
}

/** A committed floor as the describe-shaped live policy that satisfies it exactly. */
export function contractPolicy(required) {
  const policy = { id: required.name, action: required.action };
  if (required.keepCount !== undefined) policy.mostRecentVersions = { keepCount: required.keepCount };
  else policy.condition = { tagState: "ANY", newerThan: `${required.newerThanSeconds}s` };
  return policy;
}

/** Filters that narrow a KEEP policy to some images; a floor has to cover all of them. */
function scopingFilters(policy) {
  const condition = policy.condition ?? {};
  const scopes = ["tagPrefixes", "versionNamePrefixes", "packageNamePrefixes"]
    .filter((key) => (condition[key] ?? []).length > 0)
    .map((key) => `condition.${key}`);
  if (condition.olderThan !== undefined) scopes.push("condition.olderThan");
  if (condition.tagState !== undefined && String(condition.tagState).toUpperCase() !== "ANY") scopes.push(`condition.tagState ${condition.tagState}`);
  if ((policy.mostRecentVersions?.packageNamePrefixes ?? []).length > 0) scopes.push("mostRecentVersions.packageNamePrefixes");
  return scopes;
}

/** Why one live policy does not satisfy one committed floor; empty when it does. */
export function policyDifferences(required, livePolicy) {
  const label = `policy "${required.name}"`;
  if (!livePolicy) return [`required ${label} is missing live`];
  const liveAction = String(livePolicy.action ?? "").toUpperCase();
  if (liveAction !== required.action) return [`${label} action is live ${liveAction || "unset"}, committed ${required.action}`];
  const differences = [];
  if (required.keepCount !== undefined) {
    const liveKeep = Number(livePolicy.mostRecentVersions?.keepCount);
    if (!Number.isFinite(liveKeep)) differences.push(`${label} has no mostRecentVersions.keepCount live`);
    else if (liveKeep < required.keepCount) differences.push(`${label} keepCount is live ${liveKeep}, committed floor ${required.keepCount}`);
  } else if (required.newerThanSeconds !== undefined) {
    const liveWindow = parseDurationSeconds(livePolicy.condition?.newerThan);
    if (liveWindow === null) differences.push(`${label} has no condition.newerThan live`);
    else if (liveWindow < required.newerThanSeconds) differences.push(`${label} newerThan is live ${liveWindow}s, committed floor ${required.newerThanSeconds}s`);
  } else {
    differences.push(`committed ${label} defines no floor`);
  }
  const scopes = scopingFilters(livePolicy);
  if (scopes.length > 0) differences.push(`${label} is scoped by ${scopes.join(", ")} live; a floor must cover every image`);
  return differences;
}

export function diffRetentionPolicies(committed, liveByProject) {
  const projects = committed.projects ?? [];
  if (projects.length === 0) return { ok: false, differences: ["committed contract names no projects"] };
  if ((committed.requiredPolicies ?? []).length === 0) return { ok: false, differences: ["committed contract requires no policies"] };
  const differences = [];
  for (const project of projects) {
    const policies = liveByProject?.[project]?.cleanupPolicies ?? null;
    if (policies === null || typeof policies !== "object") {
      differences.push(`${project}: live repository describe is missing cleanupPolicies`);
      continue;
    }
    for (const required of committed.requiredPolicies) {
      differences.push(...policyDifferences(required, policies[required.name]).map((difference) => `${project}: ${difference}`));
    }
  }
  return { ok: differences.length === 0, differences };
}

export function formatResult(committed, result) {
  if (result.ok) {
    return `MATCH: live gcf-artifacts cleanup policies satisfy governance/ops-artifact-retention.json (${committed.projects.join(", ")})`;
  }
  return [
    `DRIFT: live gcf-artifacts cleanup policies vs governance/ops-artifact-retention.json`,
    ...result.differences.map((difference) => `  - ${difference}`),
    "  The committed file wins: plan with `node scripts/ops/apply-artifact-retention.mjs`, apply with `--apply`, or change the file in a reviewed PR.",
  ].join("\n");
}

/** A live describe-output that is faithful to the committed contract (test fixture). */
export function faithfulSnapshot(committed) {
  const snapshot = {};
  for (const project of committed.projects) {
    const cleanupPolicies = {
      "firebase-functions-cleanup": {
        id: "firebase-functions-cleanup",
        action: "DELETE",
        condition: { olderThan: "86400s", tagState: "ANY" },
      },
    };
    for (const required of committed.requiredPolicies) cleanupPolicies[required.name] = contractPolicy(required);
    snapshot[project] = { name: `projects/${project}/locations/${committed.location}/repositories/${committed.repository}`, cleanupPolicies };
  }
  return snapshot;
}

/** Runs `gcloud <args>`; callers take it as a parameter so tests never reach a real project. */
export function runGcloud(args) {
  return spawnSync("gcloud", args, { encoding: "utf8" });
}

/** Describes the committed repository in one project: { ok, repository } or { ok: false, error }. */
export function describeRepository(committed, project, run = runGcloud) {
  const result = run(["artifacts", "repositories", "describe", committed.repository, `--location=${committed.location}`, `--project=${project}`, "--format=json"]);
  if (result.status !== 0) {
    return { ok: false, error: `${project}: ${result.stderr || result.stdout || result.error?.message || "gcloud failed"}` };
  }
  try {
    return { ok: true, repository: JSON.parse(result.stdout || "{}") };
  } catch (error) {
    return { ok: false, error: `${project}: unparseable gcloud output: ${error.message}` };
  }
}

function fetchLive(committed) {
  const liveByProject = {};
  for (const project of committed.projects) {
    const described = describeRepository(committed, project);
    if (!described.ok) return described;
    liveByProject[project] = described.repository;
  }
  return { ok: true, liveByProject };
}

function selfTest() {
  const committed = loadCommitted();
  const count = committed.requiredPolicies?.find((policy) => policy.keepCount !== undefined)?.name;
  const window = committed.requiredPolicies?.find((policy) => policy.newerThanSeconds !== undefined)?.name;
  if (!count || !window) {
    console.error("FAIL: artifact retention drift self-test: the contract lost its keepCount or newerThanSeconds floor");
    return 1;
  }
  const [firstProject] = committed.projects;
  const mutate = (apply) => { const snapshot = faithfulSnapshot(committed); apply(snapshot[firstProject].cleanupPolicies, snapshot); return snapshot; };
  const controls = [
    ["faithful snapshot", faithfulSnapshot(committed), true],
    // Floors, not exact values: more retention still matches.
    ["keepCount raised", mutate((policies) => { policies[count].mostRecentVersions.keepCount = 10; }), true],
    ["7-day window lengthened to 30d", mutate((policies) => { policies[window].condition.newerThan = "30d"; }), true],
    ["count policy removed", mutate((policies) => { delete policies[count]; }), false],
    ["keepCount lowered", mutate((policies) => { policies[count].mostRecentVersions.keepCount = 1; }), false],
    ["count action flipped to DELETE", mutate((policies) => { policies[count].action = "DELETE"; }), false],
    ["keepCount missing", mutate((policies) => { delete policies[count].mostRecentVersions; }), false],
    ["count scoped to one package", mutate((policies) => { policies[count].mostRecentVersions.packageNamePrefixes = ["burnbar__us--central1__health_ready"]; }), false],
    ["7-day policy removed", mutate((policies) => { delete policies[window]; }), false],
    ["7-day window shortened to 24h", mutate((policies) => { policies[window].condition.newerThan = "86400s"; }), false],
    ["7-day condition missing", mutate((policies) => { delete policies[window].condition; }), false],
    ["7-day action flipped to DELETE", mutate((policies) => { policies[window].action = "DELETE"; }), false],
    ["7-day window scoped to tagged images", mutate((policies) => { policies[window].condition.tagState = "TAGGED"; }), false],
    ["cleanupPolicies block missing", mutate((policies, snapshot) => { delete snapshot[firstProject].cleanupPolicies; }), false],
    ["project describe missing", mutate((policies, snapshot) => { delete snapshot[firstProject]; }), false],
  ];
  const failures = [];
  for (const [label, live, expectOk] of controls) {
    const result = diffRetentionPolicies(committed, live);
    if (result.ok !== expectOk) failures.push(`${label}: expected ${expectOk ? "MATCH" : "DRIFT"}, got ${result.ok ? "MATCH" : "DRIFT"}`);
  }
  if (failures.length > 0) {
    console.error("FAIL: artifact retention drift self-test");
    for (const failure of failures) console.error(`  - ${failure}`);
    return 1;
  }
  const positive = controls.filter(([, , expectOk]) => expectOk).length;
  console.log(`PASS: artifact retention drift self-test (${positive} positive controls + ${controls.length - positive} drift controls)`);
  return 0;
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--self-test") args.selfTest = true;
    else if (argv[index] === "--live") args.live = argv[index + 1], index += 1;
    else { console.error(`unknown argument: ${argv[index]}`); process.exit(2); }
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.selfTest) process.exit(selfTest());
  let committed;
  try {
    committed = loadCommitted();
  } catch (error) {
    console.error(`could not read committed contract: ${error.message}`);
    process.exit(2);
  }
  let liveByProject;
  if (args.live) {
    try {
      liveByProject = JSON.parse(readFileSync(args.live, "utf8"));
    } catch (error) {
      console.error(`could not read live snapshot: ${error.message}`);
      process.exit(2);
    }
  } else {
    const fetched = fetchLive(committed);
    if (!fetched.ok) {
      console.error(`could not read live cleanup policies: ${fetched.error}`);
      process.exit(2);
    }
    liveByProject = fetched.liveByProject;
  }
  const result = diffRetentionPolicies(committed, liveByProject);
  console.log(formatResult(committed, result));
  process.exit(result.ok ? 0 : 1);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) main();
