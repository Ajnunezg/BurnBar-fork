#!/usr/bin/env node
/**
 * Offline tests for scripts/ops/apply-artifact-retention.mjs. A fake gcloud
 * (written to a temp dir) holds one in-memory gcf-artifacts per project; no
 * test reaches a real project.
 * Run: node --test scripts/ops/apply-artifact-retention.test.mjs
 */
import assert from "node:assert/strict";
import { after, test } from "node:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describeRepository, diffRetentionPolicies, faithfulSnapshot, loadCommitted } from "./check-artifact-retention-drift.mjs";
import { planProject, reconcile } from "./apply-artifact-retention.mjs";

const CLI = join(dirname(fileURLToPath(import.meta.url)), "apply-artifact-retention.mjs");
const committed = loadCommitted();
const scratch = mkdtempSync(join(tmpdir(), "apply-retention-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

// set-cleanup-policies REPLACES the map (gcloud read-modify-updates the whole
// cleanupPolicies field). `setBehavior` scripts a broken set: "fail" exits 1,
// "ignore" returns success without changing anything, "drop:<id>" loses a policy.
// bin/gcloud is a sh wrapper so PATH lookup finds it; the .cjs body stays
// CommonJS whatever package.json sits above the temp dir.
const fakeBin = join(scratch, "bin");
const fakeGcloud = join(fakeBin, "gcloud");
const fakeGcloudBody = join(scratch, "fake-gcloud.cjs");
mkdirSync(fakeBin);
writeFileSync(fakeGcloud, `#!/bin/sh\nexec '${process.execPath}' '${fakeGcloudBody}' "$@"\n`);
writeFileSync(fakeGcloudBody, `const fs = require("node:fs");
const args = process.argv.slice(2);
const statePath = process.env.FAKE_GCLOUD_STATE;
fs.appendFileSync(statePath + ".calls", JSON.stringify(args) + "\\n");
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
const project = (args.find((arg) => arg.startsWith("--project=")) || "").slice("--project=".length);
if (args[2] === "describe") {
  process.stdout.write(JSON.stringify(state.projects[project]));
} else if (args[2] === "set-cleanup-policies") {
  const behavior = state.setBehavior || "replace";
  if (behavior === "fail") { process.stderr.write("PERMISSION_DENIED: artifactregistry.repositories.update\\n"); process.exit(1); }
  const entries = JSON.parse(fs.readFileSync(args.find((arg) => arg.startsWith("--policy=")).slice("--policy=".length), "utf8"));
  state.sentPolicies = entries;
  if (behavior !== "ignore") {
    const repository = state.projects[project];
    repository.cleanupPolicies = Object.fromEntries(entries.map((entry) => [entry.name, {
      id: entry.name,
      action: entry.action.type,
      ...(entry.condition ? { condition: entry.condition } : { mostRecentVersions: entry.mostRecentVersions }),
    }]));
    if (behavior.startsWith("drop:")) delete repository.cleanupPolicies[behavior.slice("drop:".length)];
    repository.cleanupPolicyDryRun = args.includes("--dry-run");
  }
  fs.writeFileSync(statePath, JSON.stringify(state));
} else {
  process.stderr.write("unexpected gcloud " + args.join(" ") + "\\n");
  process.exit(1);
}
`);
chmodSync(fakeGcloud, 0o755);

/** Live state after the 2026-09-23 hand fix: Firebase cleanup + the count floor, no 7-day window. */
function liveBeforeApply() {
  const snapshot = faithfulSnapshot(committed);
  for (const project of committed.projects) delete snapshot[project].cleanupPolicies["rollback-retention-7d"];
  return snapshot;
}

/** One fake-gcloud state file: reconcile() wired to it, plus what gcloud saw and holds. */
function world(projects, setBehavior) {
  const statePath = join(mkdtempSync(join(scratch, "state-")), "state.json");
  writeFileSync(statePath, JSON.stringify({ projects, setBehavior }));
  const run = (args) => spawnSync(fakeGcloud, args, { encoding: "utf8", env: { ...process.env, FAKE_GCLOUD_STATE: statePath } });
  const state = () => JSON.parse(readFileSync(statePath, "utf8"));
  const calls = () => (existsSync(`${statePath}.calls`) ? readFileSync(`${statePath}.calls`, "utf8").trim().split("\n").map((line) => JSON.parse(line)) : []);
  const logs = [];
  const reconcileWith = (options) => reconcile({
    committed, run, readLive: (project) => describeRepository(committed, project, run),
    log: (line) => logs.push(line), warn: (line) => logs.push(line), ...options,
  });
  return { state, calls, logs, statePath, reconcileWith };
}

const firebaseCleanup = { name: "firebase-functions-cleanup", action: { type: "DELETE" }, condition: { olderThan: "86400s", tagState: "ANY" } };
const sevenDayFloor = { name: "rollback-retention-7d", action: { type: "KEEP" }, condition: { tagState: "ANY", newerThan: "604800s" } };

test("plan renders the full map: live policies carried over verbatim, the missing 7-day floor added", () => {
  const plan = planProject(committed, liveBeforeApply().burnbar);
  assert.deepEqual(plan.policies, [
    firebaseCleanup,
    { name: "rollback-retention", action: { type: "KEEP" }, mostRecentVersions: { keepCount: 3 } },
    sevenDayFloor,
  ]);
  assert.deepEqual(plan.carriedOver, ["firebase-functions-cleanup", "rollback-retention"]);
  assert.deepEqual(plan.changes, ['required policy "rollback-retention-7d" is missing live']);
  assert.equal(plan.dryRun, false);
});

test("merge keeps foreign policies and a stronger live floor, and replaces only a weaker one", () => {
  const live = liveBeforeApply().burnbar;
  live.cleanupPolicies["keep-release-tags"] = { id: "keep-release-tags", action: "KEEP", condition: { tagState: "TAGGED", tagPrefixes: ["release"] } };
  live.cleanupPolicies["rollback-retention"].mostRecentVersions.keepCount = 10;
  live.cleanupPolicies["rollback-retention-7d"] = { id: "rollback-retention-7d", action: "KEEP", condition: { tagState: "ANY", newerThan: "86400s" } };
  const plan = planProject(committed, live);
  assert.deepEqual(plan.policies.map((policy) => policy.name), ["firebase-functions-cleanup", "keep-release-tags", "rollback-retention", "rollback-retention-7d"]);
  assert.deepEqual(plan.policies[1], { name: "keep-release-tags", action: { type: "KEEP" }, condition: { tagState: "TAGGED", tagPrefixes: ["release"] } });
  assert.equal(plan.policies[2].mostRecentVersions.keepCount, 10);
  assert.deepEqual(plan.policies[3], sevenDayFloor);
  assert.deepEqual(plan.carriedOver, ["firebase-functions-cleanup", "rollback-retention", "keep-release-tags"]);
  assert.match(plan.changes.join("\n"), /newerThan is live 86400s, committed floor 604800s/u);
});

test("a live policy the rewrite could not carry over is refused, never silently dropped", () => {
  const live = liveBeforeApply();
  live.burnbar.cleanupPolicies["firebase-functions-cleanup"].condition.versionAge = "86400s";
  assert.throws(() => planProject(committed, live.burnbar), /cannot carry over: condition\.versionAge/u);
  const { calls, reconcileWith } = world(live);
  assert.equal(reconcileWith({ projects: ["burnbar"], apply: true }), 2);
  assert.deepEqual(calls().map((args) => args[2]), ["describe"]);
});

test("apply sends the merged map with the exact argv, then verifies the live re-read", () => {
  const { calls, state, logs, reconcileWith } = world(liveBeforeApply());
  assert.equal(reconcileWith({ projects: ["burnbar-staging"], apply: true }), 0, logs.join("\n"));
  const [describe, set, reread] = calls();
  assert.deepEqual(describe, ["artifacts", "repositories", "describe", "gcf-artifacts", "--location=us-central1", "--project=burnbar-staging", "--format=json"]);
  assert.deepEqual(set.slice(0, 6), ["artifacts", "repositories", "set-cleanup-policies", "gcf-artifacts", "--project=burnbar-staging", "--location=us-central1"]);
  assert.match(set[6], /^--policy=.*gcf-artifacts-burnbar-staging\.cleanup-policies\.json$/u);
  assert.equal(set[7], "--no-dry-run");
  assert.equal(set.length, 8);
  assert.deepEqual(reread, describe);
  assert.equal(existsSync(set[6].slice("--policy=".length)), false, "the temp policy file is removed");
  assert.deepEqual(state().sentPolicies, planProject(committed, liveBeforeApply()["burnbar-staging"]).policies);
  assert.equal(diffRetentionPolicies({ ...committed, projects: ["burnbar-staging"] }, state().projects).ok, true);
  assert.deepEqual(state().projects.burnbar, liveBeforeApply().burnbar, "--project leaves the other project alone");
  assert.match(logs.at(-1), /^PASS: burnbar-staging .* 2 carried-over policies unchanged$/u);
});

test("a repository in cleanup dry-run mode keeps --dry-run and says so", () => {
  const live = liveBeforeApply();
  live.burnbar.cleanupPolicyDryRun = true;
  const { calls, logs, reconcileWith } = world(live);
  assert.equal(reconcileWith({ projects: ["burnbar"], apply: true }), 0, logs.join("\n"));
  assert.equal(calls()[1].at(-1), "--dry-run");
  assert.match(logs.join("\n"), /WARN: .* cleanup dry-run mode/u);
});

test("live that already satisfies the contract makes no set call", () => {
  const { calls, logs, reconcileWith } = world(faithfulSnapshot(committed));
  assert.equal(reconcileWith({ projects: committed.projects, apply: true }), 0);
  assert.deepEqual(calls().map((args) => args[2]), ["describe", "describe"]);
  assert.match(logs.join("\n"), /nothing to apply/u);
});

test("post-apply verification fails closed when the re-read lacks the floor or lost a carried-over policy", () => {
  const ignored = world(liveBeforeApply(), "ignore");
  assert.equal(ignored.reconcileWith({ projects: ["burnbar"], apply: true }), 1);
  assert.match(ignored.logs.join("\n"), /DRIFT[\s\S]*required policy "rollback-retention-7d" is missing live/u);
  const dropped = world(liveBeforeApply(), "drop:firebase-functions-cleanup");
  assert.equal(dropped.reconcileWith({ projects: ["burnbar"], apply: true }), 1);
  assert.match(dropped.logs.join("\n"), /carried-over policy "firebase-functions-cleanup" changed during apply/u);
});

test("a failed set exits 2 without a re-read or a PASS", () => {
  const { calls, logs, reconcileWith } = world(liveBeforeApply(), "fail");
  assert.equal(reconcileWith({ projects: ["burnbar", "burnbar-staging"], apply: true }), 2);
  assert.deepEqual(calls().map((args) => args[2]), ["describe", "set-cleanup-policies"], "stops at the first failed project");
  assert.match(logs.join("\n"), /set-cleanup-policies failed: PERMISSION_DENIED/u);
  assert.doesNotMatch(logs.join("\n"), /PASS/u);
});

test("CLI: offline plan prints each project's file and exact command; --apply drives gcloud on PATH", () => {
  const snapshot = join(scratch, "live.json");
  writeFileSync(snapshot, JSON.stringify(liveBeforeApply()));
  const plan = spawnSync(process.execPath, [CLI, "--live", snapshot], { encoding: "utf8" });
  assert.equal(plan.status, 0, plan.stderr);
  for (const project of committed.projects) {
    assert.match(plan.stdout, new RegExp(`gcloud artifacts repositories set-cleanup-policies gcf-artifacts --project=${project} --location=us-central1 --policy=gcf-artifacts-${project}\\.cleanup-policies\\.json --no-dry-run`, "u"));
  }
  assert.match(plan.stdout, /"name": "firebase-functions-cleanup"/u);
  assert.match(plan.stdout, /"newerThan": "604800s"/u);

  const { state, statePath } = world(liveBeforeApply());
  const env = { ...process.env, FAKE_GCLOUD_STATE: statePath, PATH: [fakeBin, process.env.PATH].join(delimiter) };
  const applied = spawnSync(process.execPath, [CLI, "--apply", "--project", "burnbar-staging"], { encoding: "utf8", env });
  assert.equal(applied.status, 0, applied.stderr);
  assert.equal(diffRetentionPolicies({ ...committed, projects: ["burnbar-staging"] }, state().projects).ok, true);

  for (const argv of [["--apply", "--live", snapshot], ["--project", "some-other-project"], ["--project"], ["--bogus"]]) {
    assert.equal(spawnSync(process.execPath, [CLI, ...argv], { encoding: "utf8", env }).status, 2, argv.join(" "));
  }
});
