// Positive/negative controls for check-agent-contract-paths.mjs.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { scanContracts } from "./check-agent-contract-paths.mjs";

const script = join(dirname(fileURLToPath(import.meta.url)), "check-agent-contract-paths.mjs");

function repo(t, files, { track = Object.keys(files), gitignore = "" } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "obb-contract-paths-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  spawnSync("git", ["-c", "maintenance.auto=false", "init", "-q"], { cwd: dir });
  if (gitignore) files[".gitignore"] = gitignore;
  for (const [name, content] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, name)), { recursive: true });
    writeFileSync(join(dir, name), content);
  }
  const toTrack = gitignore ? [...track, ".gitignore"] : track;
  const added = spawnSync("git", ["add", "-f", "--", ...toTrack], { cwd: dir, encoding: "utf8" });
  assert.equal(added.status, 0, added.stderr);
  return dir;
}

// Citations are only checked under tracked top-level entries, so the fixture
// tree carries the roots the cases cite.
const base = {
  "scripts/tool.sh": "#!/bin/sh\n",
  "docs/guide.md": "# guide\n",
  "docs/architecture/README.md": "# adr\n",
  "AgentLens/Services/Meter.swift": "// meter\n",
  "functions/package.json": "{}\n",
  "android/app/build.gradle": "\n",
  ".factory/README.md": "# factory\n",
};

function missingPaths(dir) {
  return scanContracts(dir).missing.map((item) => `${item.contract}:${item.line}:${item.path}`);
}

test("existing link, inline path, directory and line-suffixed citations pass", (t) => {
  const dir = repo(t, {
    ...base,
    "AGENTS.md": [
      "# BurnBar agents",
      "Run `scripts/tool.sh` and read [the guide](docs/guide.md#setup).",
      "Meter lives in `AgentLens/Services/Meter.swift:12` under `AgentLens/Services/`.",
    ].join("\n"),
  });
  const result = scanContracts(dir);
  assert.deepEqual(result.missing, []);
  assert.equal(result.checked, 4);
});

test("a deleted file cited in prose fails with contract:line", (t) => {
  const dir = repo(t, {
    ...base,
    "AGENTS.md": "# BurnBar\n\n`functions/src/types.ts` IS THE CANONICAL SCHEMA\n",
  });
  assert.deepEqual(missingPaths(dir), ["AGENTS.md:3:functions/src/types.ts"]);
});

test("case must match the tracked path", (t) => {
  const dir = repo(t, { ...base, "AGENTS.md": "# BurnBar\n[ADRs](docs/ARCHITECTURE/README.md)\n" });
  assert.deepEqual(missingPaths(dir), ["AGENTS.md:2:docs/ARCHITECTURE/README.md"]);
});

test("an untracked file on disk does not satisfy a citation", (t) => {
  const dir = repo(
    t,
    { ...base, "scripts/local-only.sh": "#!/bin/sh\n", "CLAUDE.md": "# BurnBar\nUse `scripts/local-only.sh`.\n" },
    { track: [...Object.keys(base), "CLAUDE.md"] },
  );
  assert.deepEqual(missingPaths(dir), ["CLAUDE.md:2:scripts/local-only.sh"]);
});

test("non-path code spans and fenced commands are not citations", (t) => {
  const dir = repo(t, {
    ...base,
    "AGENTS.md": [
      "# BurnBar",
      "Firestore `users/{uid}/usage/{doc}`, home `~/.codex/sessions/`, method `tools/list`,",
      "elided `AgentLens/.../Gone.swift`, url `https://example.com/a/b.md`, flag `--out/x.json`.",
      "```bash",
      "npm --prefix extensions/openburnbar run test:unit -- test/controller.test.ts",
      "```",
    ].join("\n"),
  });
  const result = scanContracts(dir);
  assert.deepEqual(result.missing, []);
  assert.equal(result.checked, 0);
});

test("relative links resolve from the contract's own directory", (t) => {
  const dir = repo(t, {
    ...base,
    "tools/mcp/references/api.md": "# api\n",
    "tools/mcp/SKILL.md": "# BurnBar MCP\n[api](references/api.md) and `references/api.md`; [gone](references/gone.md)\n",
  });
  assert.deepEqual(missingPaths(dir), ["tools/mcp/SKILL.md:2:tools/mcp/references/gone.md"]);
});

test("repo-agnostic skills are checked for links only", (t) => {
  const dir = repo(t, {
    ...base,
    ".agents/skills/design/SKILL.md": "# Design review\nWrite plans to `docs/designs/`.\n[ref](missing-ref.md)\n",
  });
  assert.deepEqual(missingPaths(dir), [".agents/skills/design/SKILL.md:3:.agents/skills/design/missing-ref.md"]);
});

test("gitignored paths pass only when the contract says they are never committed", (t) => {
  const dir = repo(
    t,
    {
      ...base,
      "AGENTS.md": [
        "# BurnBar",
        "**Real config:** `android/app/google-services.json` — **never committed**.",
        "Schema drift is handled by `.factory/skills/firestore-worker/SKILL.md`.",
      ].join("\n"),
    },
    { gitignore: "android/app/google-services.json\n.factory/skills/firestore-worker/\n" },
  );
  const result = scanContracts(dir);
  assert.deepEqual(
    result.missing.map((item) => item.path),
    [".factory/skills/firestore-worker/SKILL.md"],
  );
  assert.deepEqual(result.intentionallyAbsent.map((item) => item.path), ["android/app/google-services.json"]);
});

test("the CLI fails when nothing is scanned and names missing citations", (t) => {
  const empty = repo(t, { ...base });
  const none = spawnSync(process.execPath, [script, "--root", empty], { encoding: "utf8" });
  assert.equal(none.status, 1);
  assert.match(none.stderr, /matched nothing/);

  const stale = repo(t, { ...base, "AGENTS.md": "# BurnBar\n`functions/src/logging.ts`\n" });
  const result = spawnSync(process.execPath, [script, "--root", stale], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /AGENTS\.md:2: functions\/src\/logging\.ts \(code\)/);

  const good = repo(t, { ...base, "AGENTS.md": "# BurnBar\n`scripts/tool.sh`\n" });
  const pass = spawnSync(process.execPath, [script, "--root", good], { encoding: "utf8" });
  assert.equal(pass.status, 0, pass.stderr);
  assert.match(pass.stdout, /PASS: 1 path citations across 1 agent contracts/);
});
