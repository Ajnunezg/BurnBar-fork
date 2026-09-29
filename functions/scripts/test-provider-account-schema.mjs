#!/usr/bin/env node
/**
 * Guardrail: legacy provider-account exports must stay aligned with schema-sync
 * generated provider-account contracts.
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..");

function extractInterfaceFields(source, interfaceName) {
  const pattern = new RegExp(
    `(?:export )?interface ${interfaceName}\\s*\\{([\\s\\S]*?)\\n\\}`,
    "m"
  );
  const match = source.match(pattern);
  if (!match) {
    throw new Error(`Could not parse interface ${interfaceName}`);
  }
  return new Set([...match[1].matchAll(/^\s*(\w+)\??:/gm)].map((m) => m[1]));
}

function extractLegacyFields(source, interfaceName, generatedFields) {
  const generatedAliasPattern = new RegExp(
    `export type ${interfaceName}\\s*=\\s*import\\("../generated/provider-account\\.js"\\)\\.${interfaceName};`,
    "m"
  );
  if (generatedAliasPattern.test(source)) {
    return generatedFields;
  }
  return extractInterfaceFields(source, interfaceName);
}

const generated = readFileSync(
  join(repoRoot, "packages/functions-shared/src/types/generated/provider-account.ts"),
  "utf8"
);
// types/legacy.ts was split into cohesive sub-modules under types/legacy/ (re-
// exported byte-identically from legacy.ts). Concatenate the barrel + every
// sub-module so the hand-maintained interface declarations are found wherever
// the split relocated them (e.g. ProviderAccountDoc -> legacy/providers.ts,
// ProviderAccountConnectContext -> legacy/config.ts).
let handMaintained = readFileSync(
  join(repoRoot, "packages/functions-shared/src/types/legacy.ts"),
  "utf8"
);
// The shared types live in packages/functions-shared since the 3.5 codebase split.
const legacyDir = join(repoRoot, "packages/functions-shared/src/types/legacy");
const legacyModules = existsSync(legacyDir) ? readdirSync(legacyDir).filter((file) => file.endsWith(".ts")) : [];
if (legacyModules.length === 0) {
  throw new Error(`no legacy type modules found under ${legacyDir}; the parity check would compare against nothing`);
}
for (const file of legacyModules) {
  handMaintained += "\n" + readFileSync(join(legacyDir, file), "utf8");
}

const generatedDoc = extractInterfaceFields(generated, "ProviderAccountDoc");
const handDoc = extractLegacyFields(
  handMaintained,
  "ProviderAccountDoc",
  generatedDoc
);
const generatedConnect = extractInterfaceFields(
  generated,
  "ProviderAccountConnectContext"
);
const handConnect = extractLegacyFields(
  handMaintained,
  "ProviderAccountConnectContext",
  generatedConnect
);

function assertSuperset(label, generatedFields, handFields) {
  const missing = [...generatedFields].filter((field) => !handFields.has(field));
  if (missing.length > 0) {
    throw new Error(
      `${label} missing in packages/functions-shared/src/types/legacy.ts: ${missing.join(", ")}`
    );
  }
}

assertSuperset("ProviderAccountDoc", generatedDoc, handDoc);
assertSuperset("ProviderAccountConnectContext", generatedConnect, handConnect);

console.log("provider-account schema parity check passed");
