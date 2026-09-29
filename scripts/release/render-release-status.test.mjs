#!/usr/bin/env node
// Behavior tests for the README release-status renderer: the headline and the
// operator clause are derived from committed evidence, never typed by hand.
// Run: node --test scripts/release/render-release-status.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { buildReleaseStatus, renderBlock } from "./render-release-status.mjs";

const SURFACES = ["macos", "ios", "android", "windows", "linux", "daemon", "extension", "cli"];

function handover(backupValue) {
  return [
    "# Operator handover",
    "",
    "## Required slots",
    "",
    "| Slot | Value | Scope | Human confirmation |",
    "| --- | --- | --- | --- |",
    "| Primary operator | Primary (sole operator) | Release | UNSET |",
    `| Backup operator | ${backupValue} | Second-person coverage | UNSET |`,
    "",
  ].join("\n");
}

const tempRoots = [];
after(() => {
  for (const root of tempRoots) fs.rmSync(root, { recursive: true, force: true });
});

function makeRepo({ backup = "UNSET", launchEvidence } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "release-status-"));
  tempRoots.push(root);
  const write = (relative, content) => {
    const target = path.join(root, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content);
  };
  write("project.yml", "targets:\n  App:\n    settings:\n      MARKETING_VERSION: 9.8.7\n");
  write(
    "docs/status/release-status.input.json",
    JSON.stringify({
      schemaVersion: 1,
      lastConfirmed: "2026-01-02",
      macAppStoreReviewState: "UNSET",
      iosReviewState: "UNSET",
      manualReleaseEnabled: "UNSET",
      windowsChannelClaim: "UNSET",
    }),
  );
  write(
    "docs/status/surfaces.json",
    JSON.stringify(SURFACES.map((id) => ({ id, tier: "tier", evidence: `evidence/${id}.md` }))),
  );
  for (const id of SURFACES) write(`evidence/${id}.md`, "evidence\n");
  write(
    "docs/mobile-parity/mobile-parity-ledger.json",
    JSON.stringify({ semantics: { productParityClaim: false, programStatus: "in progress" } }),
  );
  write("docs/windows-port/WINDOWS_PARITY_LEDGER.yml", "version: 1\n");
  write("docs/runbooks/HANDOVER.md", handover(backup));
  if (launchEvidence !== undefined) write("launch-evidence/final-launch-evidence.json", launchEvidence);
  return root;
}

test("without a launch evidence bundle the headline states source-ready, not a launch candidate", () => {
  const status = buildReleaseStatus(makeRepo());
  assert.equal(status.launch.commercialGo, false);
  assert.match(status.launch.reason, /final-launch-evidence\.json is missing/);
  const block = renderBlock(status);
  assert.match(block, /\*\*Status:\*\* Source-ready with named launch blockers; commercial GO is not present/);
  assert.doesNotMatch(block, /Commercial launch candidate/);
  assert.match(block, /macOS `9\.8\.7`/);
});

test("an evidence bundle that fails validation still reports no commercial GO", () => {
  const unreadable = buildReleaseStatus(makeRepo({ launchEvidence: "{not json" }));
  assert.equal(unreadable.launch.commercialGo, false);
  assert.match(unreadable.launch.reason, /unreadable/);

  const invalid = buildReleaseStatus(makeRepo({ launchEvidence: JSON.stringify({ schemaVersion: 1 }) }));
  assert.equal(invalid.launch.commercialGo, false);
  assert.match(invalid.launch.reason, /fails validation \(\d+ error\(s\)\)/);
  assert.doesNotMatch(renderBlock(invalid), /Commercial launch candidate/);
});

test("an UNSET backup slot renders the single-operator clause with the AR-008 risk", () => {
  const status = buildReleaseStatus(makeRepo({ backup: "UNSET" }));
  assert.deepEqual(status.operators, {
    model: "single-operator",
    backupOperatorNamed: false,
    evidence: "docs/runbooks/HANDOVER.md",
    risk: "AR-008",
  });
  assert.match(renderBlock(status), /run by a single operator with no named backup \(risk AR-008/);
});

test("a NEEDS ALBERTO placeholder never counts as a named backup", () => {
  const status = buildReleaseStatus(makeRepo({ backup: "NEEDS ALBERTO: name a backup" }));
  assert.equal(status.operators.backupOperatorNamed, false);
});

test("a filled backup slot switches the clause to primary-and-backup", () => {
  const status = buildReleaseStatus(makeRepo({ backup: "@backup-operator-handle" }));
  assert.equal(status.operators.model, "primary-and-backup");
  assert.match(renderBlock(status), /a primary and a backup operator are named/);
});

test("a handover page without a backup row fails closed instead of guessing", () => {
  const root = makeRepo();
  fs.writeFileSync(path.join(root, "docs/runbooks/HANDOVER.md"), "# Operator handover\n\nNo table.\n");
  assert.throws(() => buildReleaseStatus(root), /no "Backup operator" row/);
});
