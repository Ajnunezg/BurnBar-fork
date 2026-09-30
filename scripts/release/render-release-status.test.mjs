#!/usr/bin/env node
// Behavior tests for the README release-status renderer: the headline and the
// operator clause are derived from committed evidence, never typed by hand, and
// the headline is coupled to the TECHNICAL_READINESS.md verdict sentence.
// Run: node --test scripts/release/render-release-status.test.mjs

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  LAUNCH_VERDICTS,
  buildReleaseStatus,
  readLaunchVerdict,
  renderBlock,
} from "./render-release-status.mjs";

const repoRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const noGo = "Posture. **Commercial GO is not present:** the final manifest is missing.";
const go = "Posture. **Commercial GO is present:** see the manifest.";

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
  write("docs/TECHNICAL_READINESS.md", `${noGo}\n`);
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


test("a no-GO readiness page yields the source-ready headline", () => {
  const verdict = readLaunchVerdict(noGo);
  assert.equal(verdict.value, "source-ready-with-blockers");
  assert.doesNotMatch(verdict.headline, /launch candidate|launch-ready/iu);
});

test("a GO verdict requires the final launch evidence manifest", () => {
  assert.throws(() => readLaunchVerdict(go), /requires launch-evidence\/final-launch-evidence\.json to validate/u);
  assert.equal(readLaunchVerdict(go, { launchEvidenceValidates: true }).value, "commercial-go");
});

test("a validated launch bundle with a no-GO readiness page fails instead of disagreeing", () => {
  assert.throws(
    () => readLaunchVerdict(noGo, { launchEvidenceValidates: true }),
    /validates but docs\/TECHNICAL_READINESS\.md still states no commercial GO/u,
  );
});

test("the readiness page must state exactly one verdict", () => {
  assert.throws(() => readLaunchVerdict("No verdict sentence here."), /exactly one commercial verdict/u);
  assert.throws(() => readLaunchVerdict(`${noGo}\n${go}`, { launchEvidenceValidates: true }), /found 2/u);
});

test("the committed README headline matches the committed readiness verdict", () => {
  const readiness = fs.readFileSync(path.join(repoRoot, "docs/TECHNICAL_READINESS.md"), "utf8");
  const readme = fs.readFileSync(path.join(repoRoot, "README.md"), "utf8");
  const status = JSON.parse(fs.readFileSync(path.join(repoRoot, "docs/status/release-status.json"), "utf8"));
  const expected = LAUNCH_VERDICTS.find((verdict) => readiness.includes(verdict.marker));
  assert.ok(expected, "TECHNICAL_READINESS.md states a verdict");
  assert.equal(status.launchVerdict.value, expected.value);
  const block = readme.split("<!-- release-status:start -->")[1].split("<!-- release-status:end -->")[0];
  assert.ok(block.includes(`**Status:** ${expected.headline}`), block);
  const check = spawnSync(process.execPath, [path.join(repoRoot, "scripts/release/render-release-status.mjs"), "--check"], {
    encoding: "utf8",
  });
  assert.equal(check.status, 0, check.stdout + check.stderr);
});
