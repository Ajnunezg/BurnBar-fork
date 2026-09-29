#!/usr/bin/env node
/**
 * Gate hand-maintained exported TypeScript schema/type surface area.
 *
 * Runtime Cloud Functions code should be allowed to grow when the product grows.
 * This check exists to ratchet down hand-maintained schema mirrors that should
 * move to TypeSpec emitters under tools/schema-sync/.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const baselinePath = path.join(repoRoot, "budgets/hand-maintained-ts-baseline.json");

// The 2026-09 decomposition (32b5d9bafa) split the old functions/src tree into
// four Firebase codebases plus the shared runtime package, and moved the legacy
// types to packages/functions-shared/src/types/legacy/. Scan every one of them:
// a root list that misses the moved code measures nothing and passes blind.
export const SCANNED_ROOTS = [
  "functions/src",
  "functions-identity/src",
  "functions-sync/src",
  "functions-media/src",
  "packages/functions-shared/src",
];

// Excluded per root: emitted TypeSpec bindings, generated catalogs, and the
// non-schema security matrix.
const EXCLUDED_SUBDIRS = [path.join("types", "generated"), "generated", "security"];

const EXPORTED_DECLARATION_RE = /^\s*export\s+(interface|type)\s+\w+\b/;

function walkTsFiles(dir, excluded, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!excluded.includes(full)) walkTsFiles(full, excluded, out);
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) {
      out.push(full);
    }
  }
  return out;
}

/** Lists the scanned .ts files; fails closed when a root is gone or empty. */
export function collectScannedFiles(root = repoRoot, roots = SCANNED_ROOTS) {
  const files = [];
  for (const relative of roots) {
    const dir = path.join(root, relative);
    if (!fs.statSync(dir, { throwIfNoEntry: false })?.isDirectory()) {
      throw new Error(`scanned root ${relative} does not exist; update SCANNED_ROOTS`);
    }
    const excluded = EXCLUDED_SUBDIRS.map((subdir) => path.join(dir, subdir));
    const found = walkTsFiles(dir, excluded, []);
    if (found.length === 0) {
      throw new Error(`scanned root ${relative} matched zero .ts files; the budget would measure nothing`);
    }
    files.push(...found);
  }
  return files;
}

function braceDelta(line) {
  let delta = 0;
  for (const char of line) {
    if (char === "{") delta += 1;
    if (char === "}") delta -= 1;
  }
  return delta;
}

function declarationSpan(lines, startIndex, kind) {
  if (kind === "interface") {
    let depth = 0;
    let sawBrace = false;
    for (let index = startIndex; index < lines.length; index += 1) {
      const line = lines[index] ?? "";
      const delta = braceDelta(line);
      if (line.includes("{")) sawBrace = true;
      depth += delta;
      if (sawBrace && depth <= 0) return index;
    }
    return startIndex;
  }

  let depth = 0;
  for (let index = startIndex; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    depth += braceDelta(line);
    if (line.includes(";") && depth <= 0) return index;
  }
  return startIndex;
}

export function countHandMaintainedSchemaSurface(files) {
  let loc = 0;
  let exportedInterfaces = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const lines = text.split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const match = lines[index]?.match(EXPORTED_DECLARATION_RE);
      if (!match) continue;
      const endIndex = declarationSpan(lines, index, match[1]);
      loc += endIndex - index + 1;
      exportedInterfaces += 1;
      index = endIndex;
    }
  }
  return { loc, exportedInterfaces, files: files.length };
}

function main() {
  const live = countHandMaintainedSchemaSurface(collectScannedFiles());

  let baseline;
  try {
    baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") {
      console.error(`Missing checked-in baseline: ${baselinePath}`);
      process.exit(1);
    }
    throw error;
  }
  console.log(
    `Hand-maintained TS schema surface: live loc=${live.loc} baseline=${baseline.loc} declarations=${live.exportedInterfaces} files=${live.files}`,
  );

  if (live.loc > baseline.loc) {
    console.error(`Hand-maintained exported schema/type LOC increased by ${live.loc - baseline.loc}.`);
    console.error("Add new shared types via TypeSpec emit under tools/schema-sync/.");
    process.exit(1);
  }

  if (live.loc < baseline.loc) {
    console.log(`Hand-maintained TS improved by ${baseline.loc - live.loc}; update baseline intentionally.`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
