// Positive/negative controls for check-no-stale-launch-evidence.sh.
//
// Fixtures come from the real producers: verdict() from
// scripts/commercial-launch-gate.mjs and the real capture helper
// (scripts/capture-commercial-launch-evidence.mjs), so a change to either
// artifact shape that the gate cannot read fails here instead of turning the
// gate into a check that matches nothing.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { verdict } from "../commercial-launch-gate.mjs";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const gateScript = join(repoRoot, "scripts/ci/check-no-stale-launch-evidence.sh");
const captureScript = join(repoRoot, "scripts/capture-commercial-launch-evidence.mjs");

function git(cwd, ...args) {
  const result = spawnSync("git", ["-c", "maintenance.auto=false", ...args], { cwd, encoding: "utf8" });
  assert.equal(result.status, 0, `git ${args.join(" ")} failed: ${result.stderr}`);
  return result.stdout;
}

function makeRepo(t) {
  const dir = mkdtempSync(join(tmpdir(), "obb-launch-evidence-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  git(dir, "init", "-q");
  mkdirSync(join(dir, "launch-evidence"));
  return dir;
}

function track(repo, relativePath, content) {
  writeFileSync(join(repo, relativePath), typeof content === "string" ? content : `${JSON.stringify(content, null, 2)}\n`);
  git(repo, "add", "-f", "--", relativePath);
}

function runGate(repo) {
  return spawnSync("bash", [gateScript], {
    encoding: "utf8",
    env: { ...process.env, OPENBURNBAR_LAUNCH_EVIDENCE_REPO: repo },
  });
}

function rawGateResult(checks) {
  return { generatedAt: "2026-09-28T00:00:00.000Z", verdict: verdict(checks), checks };
}

const failingChecks = {
  repo: { ok: false, error: "fixture: dirty tree" },
  appStore: { ok: true, state: "PREPARE_FOR_SUBMISSION" },
};
const waitingChecks = { repo: { ok: true }, appStore: { ok: true, state: "WAITING_FOR_REVIEW" } };

function captureWithRealHelper(t, repo, raw) {
  const inputDir = mkdtempSync(join(tmpdir(), "obb-launch-input-"));
  t.after(() => rmSync(inputDir, { recursive: true, force: true }));
  const input = join(inputDir, "gate.json");
  writeFileSync(input, JSON.stringify(raw));
  const result = spawnSync(
    process.execPath,
    [captureScript, "--input", input, "--dir", join(repo, "launch-evidence")],
    { cwd: repo, encoding: "utf8" },
  );
  assert.equal(result.status, 0, `capture helper failed: ${result.stderr}`);
  const written = readdirSync(join(repo, "launch-evidence")).filter((name) => name.endsWith(".json"));
  assert.ok(written.length >= 2, `capture helper should write a timestamped and a latest record, wrote ${written}`);
  for (const name of written) git(repo, "add", "-f", "--", `launch-evidence/${name}`);
  return written;
}

test("the fixture verdicts come from the real launch gate", () => {
  assert.equal(verdict(failingChecks).status, "NO_GO");
  assert.equal(verdict(waitingChecks).status, "WAITING_ON_APPLE");
});

test("a captured NO_GO record from the real capture helper fails the gate", (t) => {
  const repo = makeRepo(t);
  const written = captureWithRealHelper(t, repo, rawGateResult(failingChecks));
  assert.ok(written.includes("latest-commercial-launch-gate.json"));
  const result = runGate(repo);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /latest-commercial-launch-gate\.json: verdict\.status=NO_GO \(failed checks: repo\)/);
});

test("a raw NO_GO verdict under an innocuous filename fails the gate", (t) => {
  const repo = makeRepo(t);
  track(repo, "launch-evidence/gate-output.json", rawGateResult(failingChecks));
  const result = runGate(repo);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /gate-output\.json: verdict\.status=NO_GO/);
});

test("a captured non-failing verdict passes and is counted", (t) => {
  const repo = makeRepo(t);
  captureWithRealHelper(t, repo, rawGateResult(waitingChecks));
  const result = runGate(repo);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /2 commercial launch-gate artifact\(s\), none NO_GO/);
});

test("a file named as launch-gate evidence without a verdict fails closed", (t) => {
  const repo = makeRepo(t);
  track(repo, "launch-evidence/latest-commercial-launch-gate.json", { note: "hand-edited summary" });
  const result = runGate(repo);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /carries no gate verdict/);
});

test("a record kinded commercial-launch-gate without a payload verdict fails closed", (t) => {
  const repo = makeRepo(t);
  track(repo, "launch-evidence/capture.json", { kind: "commercial-launch-gate", payload: { ok: false } });
  const result = runGate(repo);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /capture\.json: named\/kinded as commercial launch-gate evidence/);
});

test("unreadable launch-gate JSON fails closed", (t) => {
  const repo = makeRepo(t);
  track(repo, "launch-evidence/commercial-launch-gate-broken.json", "{ not json");
  const result = runGate(repo);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /unreadable launch-gate JSON/);
});

test("unrelated evidence passes and the scan count is printed", (t) => {
  const repo = makeRepo(t);
  track(repo, "launch-evidence/rollback-drill.json", { ok: false, drill: "revision-pin" });
  const result = runGate(repo);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /scanned 1 tracked launch-evidence JSON file\(s\); 0 commercial launch-gate artifact\(s\)/);
});

test("untracked local proof is not tracked evidence", (t) => {
  const repo = makeRepo(t);
  writeFileSync(join(repo, "launch-evidence/local-no-go.json"), JSON.stringify(rawGateResult(failingChecks)));
  const result = runGate(repo);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /scanned 0 tracked/);
});

test("the live repository passes", () => {
  const result = spawnSync("bash", [gateScript], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /^PASS: scanned \d+ tracked launch-evidence JSON file/);
});
