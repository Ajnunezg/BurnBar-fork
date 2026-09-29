import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  SCANNED_ROOTS,
  collectScannedFiles,
  countHandMaintainedSchemaSurface,
} from "./check-legacy-budget.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function fixtureRepo(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "legacy-budget-"));
  for (const [relative, text] of Object.entries(files)) {
    const full = path.join(root, relative);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, text);
  }
  return root;
}

test("every scanned root in the repo matches at least one .ts file", () => {
  for (const root of SCANNED_ROOTS) {
    const files = collectScannedFiles(repoRoot, [root]);
    assert.ok(files.length > 0, `${root} matched zero files`);
  }
});

test("the scan covers the legacy types moved into functions-shared", () => {
  const scanned = new Set(collectScannedFiles().map((file) => path.relative(repoRoot, file)));
  const legacyDir = path.join(repoRoot, "packages/functions-shared/src/types/legacy");
  const legacyFiles = fs.readdirSync(legacyDir).filter((name) => name.endsWith(".ts"));
  assert.ok(legacyFiles.length > 0, "types/legacy has no .ts files");
  for (const name of legacyFiles) {
    assert.ok(scanned.has(path.join("packages/functions-shared/src/types/legacy", name)), `${name} not scanned`);
  }
});

test("a scanned root that matches zero .ts files fails closed", () => {
  const root = fixtureRepo({ "empty/src/README.md": "no code here\n" });
  assert.throws(() => collectScannedFiles(root, ["empty/src"]), /matched zero \.ts files/);
});

test("a scanned root that no longer exists fails closed", () => {
  const root = fixtureRepo({ "kept/src/a.ts": "export const a = 1;\n" });
  assert.throws(() => collectScannedFiles(root, ["kept/src", "moved/src"]), /moved\/src does not exist/);
});

test("generated, emitted and security subtrees are excluded under every root", () => {
  const root = fixtureRepo({
    "pkg/src/types/generated/doc.ts": "export interface Emitted { a: string }\n",
    "pkg/src/generated/catalog.ts": "export type Catalog = string;\n",
    "pkg/src/security/matrix.ts": "export type Matrix = string;\n",
    "pkg/src/types/legacy/doc.ts": "export interface Legacy {\n  a: string;\n  b?: number;\n}\n",
  });
  const files = collectScannedFiles(root, ["pkg/src"]).map((file) => path.relative(root, file));
  assert.deepEqual(files, [path.join("pkg/src/types/legacy/doc.ts")]);
  assert.deepEqual(countHandMaintainedSchemaSurface(collectScannedFiles(root, ["pkg/src"])), {
    loc: 4,
    exportedInterfaces: 1,
    files: 1,
  });
});
