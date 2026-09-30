#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const workflow = readFileSync(new URL("../../.github/workflows/code-quality.yml", import.meta.url), "utf8");
const block = workflow.split("      - name: Run dependency-analysis buildHealth\n")[1]?.split("\n      - name:")[0];
assert.ok(block, "dependency-analysis step must exist");
const script = block.split("        run: |\n")[1]?.split("\n").map((line) => line.replace(/^ {10}/u, "")).join("\n");
assert.ok(script, "dependency-analysis step must have an executable shell body");

for (const { name, message, code, expected } of [
  { name: "complete project analysis succeeds", message: "BUILD SUCCESSFUL", code: 0, expected: 0 },
  { name: "nonzero Gradle status fails without a BUILD FAILED marker", message: "compiler process terminated", code: 42, expected: 42 },
  { name: "terminated compiler fails without a BUILD FAILED marker", message: "killed", code: 137, expected: 137 },
  { name: "a failure marker remains fail-closed", message: "BUILD FAILED", code: 0, expected: 1 },
]) {
  test(name, () => {
    const root = mkdtempSync(path.join(tmpdir(), "obb-dep-health-"));
    try {
      mkdirSync(path.join(root, "android"));
      writeFileSync(path.join(root, "android/gradlew"), `#!/usr/bin/env bash\nprintf '%s\\n' "$@" > ../gradle-args.txt\nprintf '%s\\n' '${message}'\nexit ${code}\n`, { mode: 0o755 });
      const result = spawnSync("bash", ["-c", script], { cwd: root, encoding: "utf8" });
      assert.equal(result.status, expected, result.stdout + result.stderr);
      assert.equal(readFileSync(path.join(root, "android-dep-health.txt"), "utf8"), `${message}\n`);
      assert.deepEqual(readFileSync(path.join(root, "gradle-args.txt"), "utf8").trim().split("\n"), [
        ":app:projectHealth", "--no-daemon", "--max-workers=1", "-Dorg.gradle.jvmargs=-Xmx6g", "-Pkotlin.compiler.execution.strategy=in-process",
      ]);
      assert.equal(result.stdout.includes("Android dependency health check complete."), expected === 0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}
