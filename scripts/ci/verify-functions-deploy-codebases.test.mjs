#!/usr/bin/env node
/**
 * Wave 3.5 (2026-09-24) split Cloud Functions into several deploy codebases
 * built over packages/functions-shared. The production deploy lane and the
 * slow source rollback must follow firebase.json instead of assuming a single
 * `functions/` codebase: the first tag cut after the split would have died in
 * tsc (functions-shared never built) and again in the portable Firebase config
 * writer (only functions/ staged). This suite pins that wiring and proves the
 * staging guard can still fail.
 *
 * Run: node --test scripts/ci/verify-functions-deploy-codebases.test.mjs
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const workflow = readFileSync(join(root, ".github/workflows/deploy-production.yml"), "utf8");
const rollback = readFileSync(join(root, "scripts/rollback.sh"), "utf8");
const buildAll = readFileSync(join(root, "scripts/build-functions-all.sh"), "utf8");
const firebaseFunctions = JSON.parse(readFileSync(join(root, "firebase.json"), "utf8")).functions;
const codebaseEntries = Array.isArray(firebaseFunctions) ? firebaseFunctions : [firebaseFunctions];
const codebaseDirs = codebaseEntries.map((entry) => entry.source ?? "functions");

const REVIEWED_CODEBASES = ["functions", "functions-identity", "functions-sync", "functions-media"];
const REVIEWED_CASE = `${REVIEWED_CODEBASES.join("|")}) ;;`;
const JQ_CODEBASES = `jq -er '.functions | if type == "array" then . else [.] end | .[].source'`;

function job(name) {
  const start = workflow.indexOf(`\n  ${name}:\n`);
  assert.notEqual(start, -1, `deploy-production.yml must define job ${name}`);
  const rest = workflow.slice(start + 1);
  const next = rest.slice(1).search(/^ {2}[A-Za-z0-9_-]+:\n/mu);
  return next === -1 ? rest : rest.slice(0, next + 1);
}

function step(jobText, name) {
  const marker = `      - name: ${name}\n`;
  const start = jobText.indexOf(marker);
  assert.notEqual(start, -1, `job must define step ${name}`);
  const rest = jobText.slice(start + marker.length);
  const next = rest.search(/^ {6}- /mu);
  return next === -1 ? jobText.slice(start) : jobText.slice(start, start + marker.length + next);
}

const prepare = job("prepare-functions-deploy");
const deploy = job("deploy-functions");
const build = step(prepare, "Install and build selected Functions artifact");
const stage = step(prepare, "Stage immutable prepared deploy artifact");
const tools = step(deploy, "Select verified deploy tools");
const release = step(deploy, "Deploy Cloud Functions");

test("every firebase.json codebase is reviewed, built, and has a production env file", () => {
  assert.ok(codebaseDirs.length > 0, "firebase.json must declare at least one Functions codebase");
  for (const dir of codebaseDirs) {
    assert.ok(REVIEWED_CODEBASES.includes(dir), `${dir} must be in the reviewed codebase allowlist`);
    assert.ok(existsSync(join(root, dir, ".env.burnbar.production")), `${dir}/.env.burnbar.production must exist`);
    assert.match(buildAll, new RegExp(`for codebase in [^\\n]*\\b${dir}\\b`, "u"), `build-functions-all.sh must build ${dir}`);
  }
  for (const text of [build, tools]) assert.ok(text.includes(REVIEWED_CASE), "workflow must pin the reviewed codebase dirs");
  assert.ok(rollback.includes(`REVIEWED_CODEBASES="${REVIEWED_CODEBASES.join(" ")}"`), "rollback.sh must pin the same reviewed dirs");
});

test("prepare derives codebases from the tag payload and builds the shared runtime first", () => {
  assert.ok(build.includes(`${JQ_CODEBASES} firebase.json`), "build must read the codebase list from firebase.json");
  const shared = build.indexOf("npm ci --prefix packages/functions-shared");
  const perCodebase = build.indexOf('npm ci --prefix "$codebase"');
  const buildAllCall = build.indexOf("bash scripts/build-functions-all.sh");
  assert.ok(shared > 0 && perCodebase > shared && buildAllCall > perCodebase, "install shared, then every codebase, then build all");
  // Pre-3.5 tag payloads (existing-tag retry, rollback profile) keep the legacy path.
  assert.match(build, /elif \[\[ "\$\{codebases\[\*\]\}" == "functions" \]\]; then\n\s+npm ci --prefix functions\n\s+npm run build --prefix functions/u);
  assert.ok(build.includes('echo "codebases=${codebases[*]}" >> "$GITHUB_OUTPUT"'));
});

test("prepare stages every codebase before the portable config is written", () => {
  assert.ok(stage.includes("FUNCTIONS_CODEBASES: ${{ steps.domain-core-build.outputs.codebases }}"));
  const loop = stage.indexOf('for codebase in "${codebases[@]}"; do');
  const configWriter = stage.indexOf("node scripts/ci/write-firebase-hosting-ci-config.mjs");
  assert.ok(loop > 0 && configWriter > loop, "codebases must be staged before the config writer runs");
  const body = stage.slice(loop, configWriter);
  for (const marker of [
    '"$codebase/" "$stage/$codebase/"',
    '--functions-dir "$stage/$codebase"',
    '"$stage/$codebase/node_modules/.bin/firebase-functions"',
    'install -m 0600 "$codebase/.env.burnbar.production" "$stage/$codebase-production.env"',
  ]) {
    assert.ok(body.includes(marker), `stage loop must include ${marker}`);
  }
  assert.doesNotMatch(stage, /--functions-dir "\$stage\/functions"/u, "no functions-only staging left behind");
});

test("deploy shims and configures every staged codebase", () => {
  assert.ok(tools.includes(`${JQ_CODEBASES} firebase-functions.ci.json`), "deploy must read codebases from the verified artifact");
  assert.ok(tools.includes('> "$codebase/node_modules/.bin/firebase-functions"'));
  assert.ok(tools.includes('echo "FUNCTIONS_CODEBASES=${codebases[*]}"'));
  assert.match(tools, /echo "SENTRY_CLI_BIN=[^\n]*\n\s*\} >> "\$GITHUB_ENV"/);
  assert.ok(release.includes('cat "${codebase}-production.env"'));
  assert.ok(release.includes('} > "${codebase}/.env.burnbar"'));
  assert.doesNotMatch(release, /ENV_FILE="functions\/\.env\.burnbar"/u, "no functions-only env writer left behind");
});

function writeConfig(stageDir) {
  return spawnSync(
    process.execPath,
    [
      "scripts/ci/write-firebase-hosting-ci-config.mjs",
      "--mode",
      "functions",
      "--output",
      join(stageDir, "firebase-functions.ci.json"),
      "--portable-functions-source",
      "--check",
    ],
    { cwd: root, encoding: "utf8" },
  );
}

test("portable config resolves only when every codebase is staged (negative control)", () => {
  const scratch = mkdtempSync(join(tmpdir(), "functions-codebases-"));
  try {
    const full = join(scratch, "full");
    for (const dir of codebaseDirs) mkdirSync(join(full, dir), { recursive: true });
    const ok = writeConfig(full);
    assert.equal(ok.status, 0, ok.stderr);
    const written = JSON.parse(readFileSync(join(full, "firebase-functions.ci.json"), "utf8")).functions;
    const writtenDirs = (Array.isArray(written) ? written : [written]).map((entry) => entry.source);
    assert.deepEqual(writtenDirs, codebaseDirs);

    if (codebaseDirs.length > 1) {
      // The pre-fix lane staged only functions/: that must still be refused.
      const partial = join(scratch, "partial");
      mkdirSync(join(partial, "functions"), { recursive: true });
      const refused = writeConfig(partial);
      assert.notEqual(refused.status, 0, "a functions-only stage must not produce a deployable config");
      assert.match(refused.stderr, /portable functions\.source does not resolve beside the output config/u);
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("break-glass names the codebase that owns the health endpoints", () => {
  const program = release.match(/health_codebase="\$\(jq -r '([^']+)' "\$FIREBASE_FUNCTIONS_CI_CONFIG"\)"/u)?.[1];
  assert.ok(program, "break-glass must derive the health codebase from the prepared config");
  assert.ok(release.includes('prefix="functions:${health_codebase:+${health_codebase}:}"'));
  const healthOwner = codebaseEntries.find((entry) => (entry.source ?? "functions") === "functions");
  assert.ok(healthOwner, "firebase.json must keep the functions/ codebase");
  assert.match(
    readFileSync(join(root, "functions/src/index.ts"), "utf8"),
    /export \{[^}]*\bhealthReady\b[^}]*\} from/u,
    "the functions/ codebase must export healthReady",
  );
  const run = (config) => {
    const result = spawnSync("jq", ["-r", program], { input: JSON.stringify(config), encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  // Firebase CLI 15.x resolves an unqualified functions:<name> to the implicit
  // `default` codebase, so a multi-codebase payload needs the owner's name.
  assert.equal(run({ functions: codebaseEntries }), healthOwner.codebase ?? "");
  assert.equal(run({ functions: { source: "functions", runtime: "nodejs22" } }), "");
});
