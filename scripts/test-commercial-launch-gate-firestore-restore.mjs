#!/usr/bin/env node
/**
 * Unit tests for the commercial launch gate's Firestore restore-drill evidence check.
 * Run: node scripts/test-commercial-launch-gate-firestore-restore.mjs
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  checkFirestoreRestoreDrill,
  evaluateFirestoreRestoreDrillEvidence,
  verdict,
} from "./commercial-launch-gate.mjs";
import {
  RESTORE_DRILL_COMMAND,
  createFirestoreRestoreDrillReceipt,
  evaluateFirestoreRestoreDrillEvidence as evaluateFromDrillModule,
} from "./ops/firestore-restore-drill-verify.mjs";

const NOW = new Date("2026-09-28T12:00:00.000Z");
const DAY_MS = 24 * 60 * 60 * 1000;

function liveReceipt({ generatedAt = new Date(NOW.getTime() - DAY_MS), ...facts } = {}) {
  return createFirestoreRestoreDrillReceipt(
    {
      mode: "clone",
      sourceDatabaseId: "(default)",
      restoreDatabaseId: "dr-drill-20260927120000",
      snapshotTime: "2026-09-27T11:55:00Z",
      postureOk: true,
      restoreStarted: true,
      operationDone: true,
      elapsedSeconds: 1800,
      captureOk: true,
      counts: [
        { collectionGroup: "entitlements", sourceCount: 12, restoredCount: 12, errors: [] },
        { collectionGroup: "cloud_vault_key_wrappers", sourceCount: 5, restoredCount: 5, errors: [] },
        { collectionGroup: "usage", sourceCount: 480, restoredCount: 480, errors: [] },
      ],
      cleanupRequested: true,
      databaseDeleted: true,
      ...facts,
    },
    { live: true, now: generatedAt },
  );
}

function evaluate(receipt, options = {}) {
  return evaluateFirestoreRestoreDrillEvidence(receipt, { now: NOW, maxAgeDays: 30, ...options });
}

// Every refusal names the one command that produces a fresh receipt.
function failuresOf(receipt, options) {
  const result = evaluate(receipt, options);
  assert.equal(result.ok, false);
  assert.equal(result.command, RESTORE_DRILL_COMMAND);
  return result.failures.join("\n");
}

const launchGateSource = readFileSync(new URL("./commercial-launch-gate.mjs", import.meta.url), "utf8");
assert.match(launchGateSource, /firestoreDisasterRecovery: checkFirestoreDisasterRecovery\(\),/);
assert.match(launchGateSource, /firestoreRestoreDrill: checkFirestoreRestoreDrill\(\),/);
assert.equal(evaluateFirestoreRestoreDrillEvidence, evaluateFromDrillModule);
assert.equal(RESTORE_DRILL_COMMAND, "GCLOUD_PROJECT=burnbar bash scripts/ops/run-firestore-restore-drill.sh");

{
  assert.deepEqual(evaluate(liveReceipt()), {
    ok: true,
    generatedAt: "2026-09-27T12:00:00.000Z",
    ageDays: 1,
    maxAgeDays: 30,
    mode: "clone",
    failures: [],
  });
  assert.equal(verdict({ appStore: { state: "READY_FOR_SALE" }, firestoreRestoreDrill: { ok: true } }).status, "READY_FOR_LIVE_PAID_PROOF");
  assert.deepEqual(verdict({ appStore: { state: "READY_FOR_SALE" }, firestoreRestoreDrill: { ok: false } }), {
    status: "NO_GO",
    reason: "failed checks: firestoreRestoreDrill",
  });
}

{
  assert.match(failuresOf(undefined), /the receipt is missing or is not a JSON object/);
  assert.match(failuresOf([]), /the receipt is missing or is not a JSON object/);
}

{
  const stale = liveReceipt({ generatedAt: new Date(NOW.getTime() - 31 * DAY_MS) });
  assert.match(failuresOf(stale), /the receipt is 31 days old; re-run the drill at least every 30 days/);
  assert.equal(evaluate(stale, { maxAgeDays: 90 }).ok, true);
  assert.match(failuresOf(liveReceipt(), { maxAgeDays: Number("thirty") }), /TTL must be a positive number of days/);
  assert.match(failuresOf(liveReceipt({ generatedAt: new Date(NOW.getTime() + DAY_MS) })), /generatedAt is in the future/);
}

{
  const kept = failuresOf(liveReceipt({ cleanupRequested: false, databaseDeleted: false }));
  assert.match(kept, /the drill did not pass: cleanup-disabled: /);
  assert.match(kept, /the drill did not delete its drill database/);
  assert.match(failuresOf(liveReceipt({ postureOk: false })), /the drill did not pass: the source DR posture check failed/);
}

{
  assert.match(failuresOf({ ...liveReceipt(), liveDrill: false }), /not a live drill/);
  assert.match(
    failuresOf({ ...liveReceipt(), schema: "openburnbar.rollback-drill-receipt.v1" }),
    /schema is "openburnbar\.rollback-drill-receipt\.v1" v1; expected openburnbar\.firestore-restore-drill-receipt\.v1 v1/,
  );
  assert.match(failuresOf({ ...liveReceipt(), project: "burnbar" }), /unexpected property project/);
}

// Hand-edited receipts that still claim ok: true are refused on their facts.
{
  const mismatched = liveReceipt();
  mismatched.counts[2] = { ...mismatched.counts[2], restoredCount: 479, match: false };
  const failures = failuresOf(mismatched);
  assert.match(failures, /restored counts did not match the source for: usage/);
  assert.match(failures, /does not conform to docs\/schemas\/firestore-restore-drill-receipt\.schema\.json: \$\.counts\[2\]\.match must be true/);

  const empty = liveReceipt();
  empty.counts = empty.counts.map((entry) => ({ ...entry, sourceCount: 0, restoredCount: 0, vacuous: true }));
  assert.match(failuresOf(empty), /no verified collection group held data; an all-empty restore proves nothing/);

  const unverified = liveReceipt();
  unverified.counts = [];
  assert.match(failuresOf(unverified), /no collection group was verified/);

  const kept = liveReceipt();
  kept.cleanup.databaseDeleted = false;
  assert.match(failuresOf(kept), /the drill did not delete its drill database/);

  const unfinished = liveReceipt();
  unfinished.restore.operationDone = false;
  assert.match(failuresOf(unfinished), /the restore operation did not complete/);
}

const dir = mkdtempSync(join(tmpdir(), "launch-gate-restore-drill-"));
try {
  const path = join(dir, "latest-firestore-restore-drill.json");
  const missing = checkFirestoreRestoreDrill({ path, now: NOW });
  assert.equal(missing.ok, false);
  assert.deepEqual(missing.failures, [`missing ${path}`]);
  assert.equal(missing.command, RESTORE_DRILL_COMMAND);

  writeFileSync(path, "{not json");
  const unreadable = checkFirestoreRestoreDrill({ path, now: NOW });
  assert.equal(unreadable.ok, false);
  assert.match(unreadable.failures[0], /^unreadable /);

  writeFileSync(path, JSON.stringify(liveReceipt()));
  const present = checkFirestoreRestoreDrill({ path, now: NOW });
  assert.equal(present.ok, true);
  assert.equal(present.path, path);

  // main() calls checkFirestoreRestoreDrill() bare: the path and TTL come from the environment.
  writeFileSync(path, JSON.stringify(liveReceipt({ generatedAt: new Date(Date.now() - DAY_MS) })));
  const gateUrl = new URL("./commercial-launch-gate.mjs", import.meta.url).href;
  const checkViaEnv = (extraEnv) => {
    const child = spawnSync(
      process.execPath,
      [
        "--input-type=module",
        "-e",
        `const { checkFirestoreRestoreDrill } = await import(${JSON.stringify(gateUrl)});
         console.log(JSON.stringify(checkFirestoreRestoreDrill()));`,
      ],
      { encoding: "utf8", env: { ...process.env, OPENBURNBAR_FIRESTORE_RESTORE_DRILL_EVIDENCE: path, ...extraEnv } },
    );
    assert.equal(child.status, 0, child.stderr);
    return JSON.parse(child.stdout);
  };
  const byDefault = checkViaEnv({ OPENBURNBAR_FIRESTORE_RESTORE_DRILL_TTL_DAYS: "" });
  assert.equal(byDefault.path, path);
  assert.equal(byDefault.maxAgeDays, 30);
  assert.equal(byDefault.ok, true);
  const tightTtl = checkViaEnv({ OPENBURNBAR_FIRESTORE_RESTORE_DRILL_TTL_DAYS: "0.5" });
  assert.equal(tightTtl.maxAgeDays, 0.5);
  assert.equal(tightTtl.ok, false);
  assert.match(tightTtl.failures.join("\n"), /re-run the drill at least every 0\.5 days/);
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log("commercial-launch-gate Firestore restore-drill evidence tests passed");
