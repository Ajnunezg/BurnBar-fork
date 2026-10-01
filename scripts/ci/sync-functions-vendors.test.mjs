import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = fileURLToPath(
  new URL("../sync-functions-vendors.mjs", import.meta.url),
);
const codebases = [
  "functions",
  "functions-identity",
  "functions-sync",
  "functions-media",
];
const packages = [
  "entitlements",
  "signal-envelope-contracts",
  "functions-shared",
];

function write(path, contents) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "functions-vendor-sync-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, "scripts"));
  copyFileSync(script, join(root, "scripts/sync-functions-vendors.mjs"));
  for (const name of packages) {
    const source = join(root, "packages", name);
    write(
      join(source, "package.json"),
      JSON.stringify({
        name: `@openburnbar/${name}`,
        version: "0.1.0",
        dependencies: { "@vendor-sync/runtime-probe": "1.0.0" },
      }),
    );
    write(
      join(source, "lib/probe.js"),
      'module.exports = require("@vendor-sync/runtime-probe");\n',
    );
    write(
      join(source, "lib/probe.test.js"),
      "throw new Error('test output must not ship');\n",
    );
  }
  return root;
}

function sync(root) {
  const result = spawnSync(
    process.execPath,
    [join(root, "scripts/sync-functions-vendors.mjs")],
    {
      encoding: "utf8",
    },
  );
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /synced 12 package/);
}

test("vendor sync preserves installed runtime dependencies while replacing compiled output", (t) => {
  const root = fixture(t);
  for (const codebase of codebases) {
    for (const name of packages) {
      const target = join(root, codebase, "vendor/openburnbar", name);
      const dependency = join(
        target,
        "node_modules/@vendor-sync/runtime-probe",
      );
      write(
        join(dependency, "package.json"),
        JSON.stringify({
          name: "@vendor-sync/runtime-probe",
          main: "index.js",
        }),
      );
      write(
        join(dependency, "index.js"),
        `module.exports = ${JSON.stringify(`${codebase}/${name}`)};\n`,
      );
      write(join(target, "lib/obsolete.js"), "obsolete\n");
    }
  }
  for (let round = 0; round < 2; round += 1) {
    sync(root);
    for (const codebase of codebases) {
      for (const name of packages) {
        const target = join(root, codebase, "vendor/openburnbar", name);
        const runtime = spawnSync(
          process.execPath,
          [
            "-e",
            "process.stdout.write(require(process.argv[1]));",
            join(target, "lib/probe.js"),
          ],
          { encoding: "utf8" },
        );
        assert.ifError(runtime.error);
        assert.equal(
          runtime.status,
          0,
          `${codebase}/${name}: ${runtime.stderr}`,
        );
        assert.equal(runtime.stdout, `${codebase}/${name}`);
        assert.equal(existsSync(join(target, "lib/obsolete.js")), false);
        assert.equal(existsSync(join(target, "lib/probe.test.js")), false);
      }
    }
    for (const codebase of codebases) {
      for (const name of packages) {
        write(
          join(root, codebase, "vendor/openburnbar", name, "lib/obsolete.js"),
          "obsolete again\n",
        );
      }
    }
  }
});

test("vendor sync creates missing vendor directories on a clean checkout", (t) => {
  const root = fixture(t);
  sync(root);
  for (const codebase of codebases) {
    for (const name of packages) {
      const target = join(root, codebase, "vendor/openburnbar", name);
      assert.equal(
        readFileSync(join(target, "lib/probe.js"), "utf8"),
        'module.exports = require("@vendor-sync/runtime-probe");\n',
      );
      assert.equal(
        JSON.parse(readFileSync(join(target, "package.json"), "utf8")).name,
        `@openburnbar/${name}`,
      );
    }
  }
});
