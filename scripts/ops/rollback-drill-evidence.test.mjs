#!/usr/bin/env node
/**
 * Offline tests for the launch gate's Cloud Run rollback-drill receipt check.
 * The live receipt comes from the exact Python writer in
 * scripts/ops/rollback-revision.sh, so writer and gate cannot drift apart.
 * Run: node --test scripts/ops/rollback-drill-evidence.test.mjs
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { checkRollbackRevisionDrill, verdict } from "../commercial-launch-gate.mjs";
import {
  DEFAULT_ROLLBACK_DRILL_TTL_DAYS,
  ROLLBACK_DRILL_COMMAND,
  evaluateRollbackRevisionDrillEvidence,
} from "./rollback-drill-evidence.mjs";

const NOW = new Date("2026-09-28T12:00:00.000Z");
const DAY_MS = 24 * 60 * 60 * 1000;
const DRILL_SCRIPT = readFileSync(new URL("./rollback-revision.sh", import.meta.url), "utf8");

// Run the receipt writer embedded in rollback-revision.sh (its python3 heredoc).
function writerReceipt(previousMode = "latest", previousRevision = "") {
  const writer = DRILL_SCRIPT.match(/python3 - "\$receipt_tmp"[^\n]*<<'PY'\n([\s\S]*?)\nPY\n/u);
  assert.ok(writer, "rollback-revision.sh no longer has the receipt writer heredoc");
  const dir = mkdtempSync(join(tmpdir(), "rollback-drill-evidence-"));
  try {
    const out = join(dir, "receipt.json");
    const run = spawnSync(
      "python3",
      ["-", out, "healthready", "us-central1", "healthready-00017-abc", "passed", previousMode, previousRevision],
      { input: writer[1], encoding: "utf8" },
    );
    assert.equal(run.status, 0, run.stderr);
    return JSON.parse(readFileSync(out, "utf8"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function aged(receipt, ageDays) {
  return { ...receipt, generatedAt: new Date(NOW.getTime() - ageDays * DAY_MS).toISOString() };
}

function evaluate(receipt, options = {}) {
  return evaluateRollbackRevisionDrillEvidence(receipt, { now: NOW, ...options });
}

// Every refusal names the one command that produces a fresh receipt.
function failuresOf(receipt, options) {
  const result = evaluate(receipt, options);
  assert.equal(result.ok, false);
  assert.equal(result.command, ROLLBACK_DRILL_COMMAND);
  return result.failures.join("\n");
}

test("the launch gate runs the rollback drill check and the command matches the runbook", () => {
  const gate = readFileSync(new URL("../commercial-launch-gate.mjs", import.meta.url), "utf8");
  assert.match(gate, /rollbackRevisionDrill: checkRollbackRevisionDrill\(\),/);
  const runbook = readFileSync(new URL("../../docs/runbooks/rollback-automation.md", import.meta.url), "utf8");
  // The runbook wraps the same command before --drill.
  assert.ok(runbook.includes(ROLLBACK_DRILL_COMMAND.replace(" --drill", " \\\n  --drill")), ROLLBACK_DRILL_COMMAND);
});

test("a fresh live receipt from the script's writer passes", () => {
  for (const [mode, revision] of [["latest", ""], ["revision", "healthready-00016-nuq"]]) {
    const result = evaluate(aged(writerReceipt(mode, revision), 2));
    assert.deepEqual(result, {
      ok: true,
      serviceName: "healthready",
      targetRevision: "healthready-00017-abc",
      generatedAt: new Date(NOW.getTime() - 2 * DAY_MS).toISOString(),
      ageDays: 2,
      maxAgeDays: DEFAULT_ROLLBACK_DRILL_TTL_DAYS,
      failures: [],
    });
  }
  assert.equal(verdict({ appStore: { state: "READY_FOR_SALE" }, rollbackRevisionDrill: { ok: false } }).status, "NO_GO");
});

test("a stale or future-dated receipt is refused", () => {
  assert.match(failuresOf(aged(writerReceipt(), 31)), /drill is 31\.0 days old \(max 30\)/);
  assert.match(failuresOf(aged(writerReceipt(), 3), { maxAgeDays: 2 }), /max 2/);
  assert.match(failuresOf(aged(writerReceipt(), -1)), /generatedAt is in the future/);
  assert.match(failuresOf({ ...writerReceipt(), generatedAt: "yesterday" }), /generatedAt is missing or unparseable/);
});

test("a fixture receipt is not launch evidence", () => {
  const live = aged(writerReceipt(), 1);
  const fixture = {
    ...live,
    mode: "fixture",
    liveDrill: false,
    drill: { ...live.drill, healthProbe: "not-run" },
    checks: { revisionListLoaded: true, trafficPinned: false, liveGcloudSession: false },
  };
  delete fixture.drill.imagePreflight;
  delete fixture.drill.restore;
  delete fixture.drill.previousServing;
  const failures = failuresOf(fixture);
  assert.match(failures, /receipt must come from a live drill, not a fixture/);
  assert.match(failures, /health probe did not pass/);
  assert.match(failures, /image was not verified/);
  assert.match(failures, /traffic restore was not confirmed/);
});

test("a live receipt missing any round-trip proof is refused", () => {
  const live = aged(writerReceipt(), 1);
  assert.match(
    failuresOf({ ...live, checks: { ...live.checks, trafficRestored: false } }),
    /traffic restore was not confirmed \(a one-way pin is not a drill\)/,
  );
  assert.match(failuresOf({ ...live, drill: { ...live.drill, healthProbe: "warning" } }), /health probe did not pass/);
  assert.match(failuresOf({ ...live, checks: { ...live.checks, imageVerified: false } }), /image was not verified/);
  assert.match(failuresOf({ ...live, ok: false }), /drill did not pass/);
  assert.match(failuresOf({ ...live, drill: { ...live.drill, host: "x.run.app" } }), /\$\.drill has unexpected property host/);
});

test("the 2026-09-23 finding and a Firestore receipt are the wrong schema", () => {
  const finding = JSON.parse(
    readFileSync(new URL("../../launch-evidence/rollback-drill-2026-09-23.json", import.meta.url), "utf8"),
  );
  assert.match(failuresOf(finding), /schema must be openburnbar\.rollback-drill-receipt\.v1/);
  assert.match(failuresOf({ ...aged(writerReceipt(), 1), schema: "openburnbar.firestore-restore-drill-receipt.v1" }), /schema must be/);
  assert.match(failuresOf([]), /receipt is not a JSON object/);
});

test("checkRollbackRevisionDrill reads the receipt file and names the command when it is absent", () => {
  const dir = mkdtempSync(join(tmpdir(), "rollback-drill-gate-"));
  try {
    const path = join(dir, "latest-rollback-revision-drill.json");
    const missing = checkRollbackRevisionDrill({ path, now: NOW });
    assert.deepEqual(missing, { ok: false, path, failures: [`missing ${path}`], command: ROLLBACK_DRILL_COMMAND });
    writeFileSync(path, "{not json");
    assert.match(checkRollbackRevisionDrill({ path, now: NOW }).failures[0], /^cannot read /);
    writeFileSync(path, JSON.stringify(aged(writerReceipt(), 1)));
    assert.equal(checkRollbackRevisionDrill({ path, now: NOW }).ok, true);
    assert.equal(checkRollbackRevisionDrill({ path, now: NOW, maxAgeDays: 0.5 }).ok, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
