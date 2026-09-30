#!/usr/bin/env node
/**
 * Plan or apply the Artifact Registry retention contract
 * (governance/ops-artifact-retention.json) to gcf-artifacts in the committed
 * projects without disturbing any other live cleanup policy.
 *
 * `gcloud artifacts repositories set-cleanup-policies --policy=<file>` writes
 * the repository's whole cleanup-policy map: gcloud read-modify-updates the
 * repository and swaps in the file's map (read from the SDK 562 source; the
 * docs do not say whether it merges). So the file sent is always the full
 * desired set. Every live policy, notably Firebase's own
 * firebase-functions-cleanup (DELETE olderThan 24h), is carried over
 * verbatim, and a committed floor replaces its live namesake only when that
 * one does not already satisfy it, so a stronger live floor is never
 * weakened. After a set the repository is described again, and the run fails
 * unless the contract matches, every carried-over policy is unchanged, and
 * the cleanup dry-run mode is unchanged.
 *
 * Modes:
 *   (default)      Plan: describe each project (read-only) and print the
 *                  policy file and the exact gcloud command. Changes nothing.
 *   --live <file>  Plan from a saved describe snapshot instead; fully offline.
 *                  Shape: { "<project>": <describe-json>, ... }.
 *   --apply        Plan, run set-cleanup-policies where a floor is unmet, then
 *                  describe again and verify.
 *   --project <p>  Only this committed project (apply burnbar-staging first).
 *
 * Plan needs roles/artifactregistry.reader; apply needs
 * artifactregistry.repositories.update (roles/artifactregistry.admin).
 * Exit codes: 0 planned, or applied and verified · 1 live does not satisfy
 * the contract after apply · 2 could not read, render, or apply.
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  contractPolicy,
  describeRepository,
  diffRetentionPolicies,
  formatResult,
  loadCommitted,
  policyDifferences,
  runGcloud,
} from "./check-artifact-retention-drift.mjs";

const POLICY_KEYS = new Set(["id", "action", "condition", "mostRecentVersions"]);
const CONDITION_KEYS = new Set(["tagState", "tagPrefixes", "versionNamePrefixes", "packageNamePrefixes", "olderThan", "newerThan"]);
const MOST_RECENT_KEYS = new Set(["packageNamePrefixes", "keepCount"]);

/**
 * A describe-shaped policy as one entry of a set-cleanup-policies file. Enum
 * values keep their API names (KEEP/DELETE/ANY), the shape gcloud's own
 * list-cleanup-policies prints, so live policies round-trip unchanged. A
 * field this script does not know would be dropped by the rewrite, so it is
 * refused instead.
 */
function toPolicyFileEntry(id, policy) {
  const unknown = [
    ...Object.keys(policy ?? {}).filter((key) => !POLICY_KEYS.has(key)),
    ...Object.keys(policy?.condition ?? {}).filter((key) => !CONDITION_KEYS.has(key)).map((key) => `condition.${key}`),
    ...Object.keys(policy?.mostRecentVersions ?? {}).filter((key) => !MOST_RECENT_KEYS.has(key)).map((key) => `mostRecentVersions.${key}`),
  ];
  if (unknown.length > 0) throw new Error(`policy "${id}" has fields this script cannot carry over: ${unknown.join(", ")}`);
  if (!["KEEP", "DELETE"].includes(policy.action)) throw new Error(`policy "${id}" has action ${policy.action ?? "unset"}`);
  if ((policy.condition == null) === (policy.mostRecentVersions == null)) throw new Error(`policy "${id}" needs exactly one of condition or mostRecentVersions`);
  const entry = { name: id, action: { type: policy.action } };
  if (policy.condition != null) entry.condition = structuredClone(policy.condition);
  else entry.mostRecentVersions = structuredClone(policy.mostRecentVersions);
  return entry;
}

/** The full policy file for one repository: live policies carried over, unmet floors written from the contract. */
export function planProject(committed, repository) {
  const live = repository?.cleanupPolicies ?? {};
  const entries = new Map(Object.entries(live).map(([id, policy]) => [id, toPolicyFileEntry(id, policy)]));
  const replaced = [];
  const changes = [];
  for (const required of committed.requiredPolicies) {
    const reasons = policyDifferences(required, live[required.name]);
    if (reasons.length === 0) continue;
    entries.set(required.name, toPolicyFileEntry(required.name, contractPolicy(required)));
    replaced.push(required.name);
    changes.push(...reasons);
  }
  return {
    policies: [...entries.values()].sort((left, right) => left.name.localeCompare(right.name)),
    carriedOver: Object.keys(live).filter((id) => !replaced.includes(id)),
    changes,
    dryRun: repository?.cleanupPolicyDryRun === true,
  };
}

/** Keeps the repository's cleanup mode: `--no-dry-run` leaves deletion on, `--dry-run` leaves it off. */
function setCleanupPoliciesArgs(committed, project, policyFile, dryRun) {
  return [
    "artifacts", "repositories", "set-cleanup-policies", committed.repository,
    `--project=${project}`, `--location=${committed.location}`, `--policy=${policyFile}`,
    dryRun ? "--dry-run" : "--no-dry-run",
  ];
}

const canonical = (value) => JSON.stringify(value, (_, inner) => (
  inner && typeof inner === "object" && !Array.isArray(inner)
    ? Object.fromEntries(Object.entries(inner).sort(([left], [right]) => left.localeCompare(right)))
    : inner
));

/** After a set: the contract matches live, carried-over policies are untouched, the dry-run mode held. */
function verifyApplied(committed, project, plan, before, after) {
  const { differences } = diffRetentionPolicies({ ...committed, projects: [project] }, { [project]: after });
  for (const id of plan.carriedOver) {
    if (canonical(after?.cleanupPolicies?.[id]) !== canonical(before.cleanupPolicies[id])) {
      differences.push(`${project}: carried-over policy "${id}" changed during apply`);
    }
  }
  if ((after?.cleanupPolicyDryRun === true) !== plan.dryRun) differences.push(`${project}: cleanupPolicyDryRun changed during apply`);
  return { ok: differences.length === 0, differences };
}

/**
 * Plans each project and, with `apply`, sets and verifies it. `readLive(project)`
 * returns describeRepository's shape; `run` executes gcloud argv. Stops at the
 * first project that fails. Returns the exit code.
 */
export function reconcile({ committed, projects, apply, readLive, run = runGcloud, log = console.log, warn = console.error }) {
  for (const project of projects) {
    const target = `${project} ${committed.location}/${committed.repository}`;
    const before = readLive(project);
    if (!before.ok) {
      warn(`could not read live cleanup policies: ${before.error}`);
      return 2;
    }
    let plan;
    try {
      plan = planProject(committed, before.repository);
    } catch (error) {
      warn(`${target}: ${error.message}; refusing to rewrite the cleanup-policy map`);
      return 2;
    }
    if (plan.changes.length === 0) {
      log(`${target}: live already satisfies governance/ops-artifact-retention.json; nothing to apply`);
      continue;
    }
    log(`${target}: ${plan.changes.length} unmet floor(s)`);
    for (const change of plan.changes) log(`  - ${change}`);
    if (plan.dryRun) warn(`WARN: ${target} is in cleanup dry-run mode (nothing is deleted); the set keeps --dry-run. Turning deletion on is a separate owner decision.`);
    const fileName = `${committed.repository}-${project}.cleanup-policies.json`;
    const policyJson = `${JSON.stringify(plan.policies, null, 2)}\n`;
    if (!apply) {
      log(`policy file ${fileName} (the whole map: live policies carried over, unmet floors from the contract):`);
      log(policyJson.trimEnd());
      log(`command:\n  gcloud ${setCleanupPoliciesArgs(committed, project, fileName, plan.dryRun).join(" ")}`);
      continue;
    }
    const directory = mkdtempSync(join(tmpdir(), "artifact-retention-"));
    let applied;
    try {
      const file = join(directory, fileName);
      writeFileSync(file, policyJson);
      const args = setCleanupPoliciesArgs(committed, project, file, plan.dryRun);
      log(`==> gcloud ${args.join(" ")}`);
      applied = run(args);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
    if (applied.status !== 0) {
      warn(`${target}: set-cleanup-policies failed: ${applied.stderr || applied.stdout || applied.error?.message || "gcloud failed"}`);
      return 2;
    }
    const after = readLive(project);
    if (!after.ok) {
      warn(`could not re-read live cleanup policies after apply: ${after.error}`);
      return 2;
    }
    const verified = verifyApplied(committed, project, plan, before.repository, after.repository);
    if (!verified.ok) {
      log(formatResult({ ...committed, projects: [project] }, verified));
      return 1;
    }
    log(`PASS: ${target} re-read after apply satisfies the contract; ${plan.carriedOver.length} carried-over policies unchanged`);
  }
  return 0;
}

function parseArgs(argv) {
  const args = { apply: false };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === "--apply") {
      args.apply = true;
    } else if (flag === "--live" || flag === "--project") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) throw new Error(`${flag} needs a value`);
      args[flag.slice(2)] = value;
      index += 1;
    } else {
      throw new Error(`unknown argument: ${flag}`);
    }
  }
  if (args.apply && args.live) throw new Error("--apply reads live state itself; --live is plan-only");
  return args;
}

function main() {
  let args;
  let committed;
  let readLive;
  try {
    args = parseArgs(process.argv.slice(2));
    committed = loadCommitted();
    if (args.project && !committed.projects.includes(args.project)) {
      throw new Error(`--project must be one of the committed projects: ${committed.projects.join(", ")}`);
    }
    if (args.live) {
      const snapshot = JSON.parse(readFileSync(args.live, "utf8"));
      readLive = (project) => (snapshot[project] ? { ok: true, repository: snapshot[project] } : { ok: false, error: `${project}: not in ${args.live}` });
    } else {
      readLive = (project) => describeRepository(committed, project);
    }
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
  process.exit(reconcile({ committed, projects: args.project ? [args.project] : committed.projects, apply: args.apply, readLive }));
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) main();
