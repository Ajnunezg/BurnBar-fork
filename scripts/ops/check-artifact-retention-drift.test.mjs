#!/usr/bin/env node
/**
 * Self-test for scripts/ops/check-artifact-retention-drift.mjs (offline).
 * Run: node --test scripts/ops/check-artifact-retention-drift.test.mjs
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { diffRetentionPolicies, faithfulSnapshot, loadCommitted, parseDurationSeconds } from "./check-artifact-retention-drift.mjs";

const CLI = join(dirname(fileURLToPath(import.meta.url)), "check-artifact-retention-drift.mjs");
const committed = loadCommitted();
const [firstProject] = committed.projects;

/** Diff a faithful snapshot after `apply(policies)` mutates the first project's live policy map. */
function diffAfter(apply) {
  const snapshot = faithfulSnapshot(committed);
  apply(snapshot[firstProject].cleanupPolicies);
  return diffRetentionPolicies(committed, snapshot);
}

test("committed contract names the gcf-artifacts repo, both projects, and two KEEP floors", () => {
  assert.equal(committed.repository, "gcf-artifacts");
  assert.equal(committed.location, "us-central1");
  assert.deepEqual(committed.projects, ["burnbar", "burnbar-staging"]);
  assert.deepEqual(committed.requiredPolicies, [
    { name: "rollback-retention", action: "KEEP", keepCount: 3 },
    { name: "rollback-retention-7d", action: "KEEP", newerThanSeconds: 604800 },
  ]);
});

test("a contract policy that is not a KEEP with exactly one positive floor is refused", () => {
  const dir = mkdtempSync(join(tmpdir(), "retention-contract-"));
  try {
    for (const policy of [
      { name: "both", action: "KEEP", keepCount: 3, newerThanSeconds: 604800 },
      { name: "neither", action: "KEEP" },
      { name: "delete", action: "DELETE", keepCount: 3 },
      { name: "zero", action: "KEEP", keepCount: 0 },
    ]) {
      const path = join(dir, `${policy.name}.json`);
      writeFileSync(path, JSON.stringify({ ...committed, requiredPolicies: [policy] }));
      assert.throws(() => loadCommitted(path), /must be a KEEP with exactly one positive integer/u, policy.name);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("durations parse from describe seconds and policy-file s/m/h/d suffixes", () => {
  assert.equal(parseDurationSeconds("604800s"), 604800);
  assert.equal(parseDurationSeconds("604800.0s"), 604800);
  assert.equal(parseDurationSeconds("7d"), 604800);
  assert.equal(parseDurationSeconds("168h"), 604800);
  assert.equal(parseDurationSeconds("10080m"), 604800);
  for (const unparseable of [undefined, "", "7 days", "-1s", "1w", 604800]) assert.equal(parseDurationSeconds(unparseable), null);
});

test("faithful snapshot matches; each keepCount mutation drifts with a named difference", () => {
  assert.equal(diffRetentionPolicies(committed, faithfulSnapshot(committed)).ok, true);
  assert.match(diffAfter((policies) => { delete policies["rollback-retention"]; }).differences[0], new RegExp(`^${firstProject}: required policy`, "u"));
  assert.match(diffAfter((policies) => { policies["rollback-retention"].mostRecentVersions.keepCount = 1; }).differences[0], /keepCount/u);
  assert.match(diffAfter((policies) => { policies["rollback-retention"].action = "DELETE"; }).differences[0], /action/u);
});

test("7-day window: shorter, missing, flipped, or removed drifts; longer still matches", () => {
  const window = (apply) => diffAfter((policies) => apply(policies["rollback-retention-7d"], policies));
  assert.match(window((policy) => { policy.condition.newerThan = "86400s"; }).differences[0], /newerThan is live 86400s, committed floor 604800s/u);
  assert.match(window((policy) => { delete policy.condition; }).differences[0], /has no condition\.newerThan live/u);
  assert.match(window((policy) => { policy.action = "DELETE"; }).differences[0], /action is live DELETE, committed KEEP/u);
  assert.match(window((policy, policies) => { delete policies["rollback-retention-7d"]; }).differences[0], /required policy "rollback-retention-7d" is missing live/u);
  assert.equal(window((policy) => { policy.condition.newerThan = "2592000s"; }).ok, true);
  assert.equal(window((policy) => { policy.condition.newerThan = "30d"; }).ok, true);
});

test("a floor scoped to a subset of images drifts", () => {
  assert.match(diffAfter((policies) => { policies["rollback-retention"].mostRecentVersions.packageNamePrefixes = ["burnbar__us--central1__health_ready"]; }).differences[0], /scoped by mostRecentVersions\.packageNamePrefixes/u);
  assert.match(diffAfter((policies) => { policies["rollback-retention-7d"].condition.tagState = "TAGGED"; }).differences[0], /scoped by condition\.tagState TAGGED/u);
  assert.match(diffAfter((policies) => { policies["rollback-retention-7d"].condition.olderThan = "3600s"; }).differences[0], /scoped by condition\.olderThan/u);
  assert.equal(diffAfter((policies) => { policies["rollback-retention"].mostRecentVersions.packageNamePrefixes = []; }).ok, true);
});

test("keepCount above the floor still matches; missing project drifts", () => {
  assert.equal(diffAfter((policies) => { policies["rollback-retention"].mostRecentVersions.keepCount = 10; }).ok, true);
  const missingProject = faithfulSnapshot(committed);
  delete missingProject[firstProject];
  assert.equal(diffRetentionPolicies(committed, missingProject).ok, false);
});

test("extra live policies beyond the contract do not drift", () => {
  assert.equal(diffAfter((policies) => { policies["future-experiment"] = { action: "DELETE" }; }).ok, true);
});

test("CLI: --self-test passes, --live matches exit 0 and drifts exit 1", () => {
  const selfTest = spawnSync(process.execPath, [CLI, "--self-test"], { encoding: "utf8" });
  assert.equal(selfTest.status, 0, selfTest.stderr);
  assert.match(selfTest.stdout, /PASS: artifact retention drift self-test \(3 positive controls \+ 12 drift controls\)/u);
  const dir = mkdtempSync(join(tmpdir(), "retention-drift-"));
  try {
    const good = join(dir, "good.json");
    writeFileSync(good, JSON.stringify(faithfulSnapshot(committed)));
    assert.equal(spawnSync(process.execPath, [CLI, "--live", good], { encoding: "utf8" }).status, 0);
    const shortened = faithfulSnapshot(committed);
    shortened[firstProject].cleanupPolicies["rollback-retention-7d"].condition.newerThan = "86400s";
    const bad = join(dir, "bad.json");
    writeFileSync(bad, JSON.stringify(shortened));
    const drift = spawnSync(process.execPath, [CLI, "--live", bad], { encoding: "utf8" });
    assert.equal(drift.status, 1);
    assert.match(drift.stdout, /DRIFT/u);
    assert.match(drift.stdout, /apply-artifact-retention\.mjs/u);
    assert.equal(spawnSync(process.execPath, [CLI, "--live", join(dir, "absent.json")], { encoding: "utf8" }).status, 2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
