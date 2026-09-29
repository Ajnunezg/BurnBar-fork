// Controls for the README status headline <-> TECHNICAL_READINESS.md verdict
// coupling in render-release-status.mjs.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { LAUNCH_VERDICTS, readLaunchVerdict } from "./render-release-status.mjs";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const noGo = "Posture. **Commercial GO is not present:** the final manifest is missing.";
const go = "Posture. **Commercial GO is present:** see the manifest.";

test("a no-GO readiness page yields the source-ready headline", () => {
  const verdict = readLaunchVerdict(noGo);
  assert.equal(verdict.value, "source-ready-with-blockers");
  assert.doesNotMatch(verdict.headline, /launch candidate|launch-ready/iu);
});

test("a GO verdict requires the final launch evidence manifest", () => {
  assert.throws(() => readLaunchVerdict(go), /requires launch-evidence\/final-launch-evidence\.json/u);
  assert.equal(readLaunchVerdict(go, { finalEvidenceExists: true }).value, "commercial-go");
});

test("the readiness page must state exactly one verdict", () => {
  assert.throws(() => readLaunchVerdict("No verdict sentence here."), /exactly one commercial verdict/u);
  assert.throws(() => readLaunchVerdict(`${noGo}\n${go}`, { finalEvidenceExists: true }), /found 2/u);
});

test("the committed README headline matches the committed readiness verdict", () => {
  const readiness = readFileSync(join(repoRoot, "docs/TECHNICAL_READINESS.md"), "utf8");
  const readme = readFileSync(join(repoRoot, "README.md"), "utf8");
  const status = JSON.parse(readFileSync(join(repoRoot, "docs/status/release-status.json"), "utf8"));
  const expected = LAUNCH_VERDICTS.find((verdict) => readiness.includes(verdict.marker));
  assert.ok(expected, "TECHNICAL_READINESS.md states a verdict");
  assert.equal(status.launchVerdict.value, expected.value);
  const block = readme.split("<!-- release-status:start -->")[1].split("<!-- release-status:end -->")[0];
  assert.ok(block.includes(`**Status:** ${expected.headline}`), block);
  const check = spawnSync(process.execPath, [join(repoRoot, "scripts/release/render-release-status.mjs"), "--check"], {
    encoding: "utf8",
  });
  assert.equal(check.status, 0, check.stdout + check.stderr);
});
