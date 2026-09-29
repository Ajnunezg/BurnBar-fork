import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(new URL("./generate-final-launch-evidence.mjs", import.meta.url));
const REPO_ROOT = fileURLToPath(new URL("../..", import.meta.url));

function generate(out, ...flags) {
  return spawnSync(process.execPath, [SCRIPT, "--tag", "HEAD", "--out", out, ...flags], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
}

function scratchOut(t) {
  const directory = mkdtempSync(join(tmpdir(), "final-launch-evidence-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return join(directory, "final-launch-evidence.json");
}

test("writes a fresh skeleton and refuses to replace it without --force", (t) => {
  const out = scratchOut(t);
  const first = generate(out);
  assert.equal(first.status, 0, first.stderr);
  const written = readFileSync(out, "utf8");
  assert.equal(JSON.parse(written).status, "PRE_LAUNCH_SKELETON");

  const again = generate(out);
  assert.equal(again.status, 1);
  assert.match(again.stderr, /refusing to overwrite .* without --force/u);
  assert.equal(readFileSync(out, "utf8"), written);
});

test("--force rewrites a skeleton in place, including a longer one, and creates a missing file", (t) => {
  const out = scratchOut(t);
  const longer = { status: "PRE_LAUNCH_SKELETON", padding: "x".repeat(4096) };
  writeFileSync(out, `${JSON.stringify(longer)}\n`);
  const forced = generate(out, "--force");
  assert.equal(forced.status, 0, forced.stderr);
  const rewritten = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(rewritten.status, "PRE_LAUNCH_SKELETON");
  assert.equal(rewritten.padding, undefined);

  const created = scratchOut(t);
  const fresh = generate(created, "--force");
  assert.equal(fresh.status, 0, fresh.stderr);
  assert.equal(JSON.parse(readFileSync(created, "utf8")).status, "PRE_LAUNCH_SKELETON");
});

test("--force never clobbers a manifest that is no longer a skeleton", (t) => {
  const out = scratchOut(t);
  const collected = `${JSON.stringify({ status: "COLLECTED", evidence: ["canary.json"] })}\n`;
  writeFileSync(out, collected);
  const forced = generate(out, "--force");
  assert.equal(forced.status, 1);
  assert.match(forced.stderr, /status is "COLLECTED", not PRE_LAUNCH_SKELETON/u);
  assert.equal(readFileSync(out, "utf8"), collected);
});
