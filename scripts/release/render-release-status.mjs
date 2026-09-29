#!/usr/bin/env node

/**
 * Render the generated release-status ledger and its README block.
 *
 * This intentionally reads only committed repository files. In particular it
 * never asks Git for tags: the release checkout is allowed to be blob-only and
 * tagless. The macOS version comes from project.yml, while parity and
 * operator-owned fields come from committed ledgers/templates.
 *
 * The headline is derived, never typed: it reads "Commercial launch candidate"
 * only when launch-evidence/final-launch-evidence.json exists and passes
 * scripts/validate-launch-evidence-bundle.mjs at the `done` stage with its
 * done stamp. Otherwise it states the honest posture from
 * docs/TECHNICAL_READINESS.md: source-ready with named launch blockers. The
 * operator clause comes from the docs/runbooks/HANDOVER.md backup slot, so the
 * README says "single operator" until a backup is actually named there.
 *
 * The readiness page must agree: docs/TECHNICAL_READINESS.md states exactly one
 * commercial verdict sentence (LAUNCH_VERDICTS), recorded as `launchVerdict`,
 * and rendering fails when that verdict and the launch evidence disagree.
 *
 * Usage:
 *   node scripts/release/render-release-status.mjs
 *   node scripts/release/render-release-status.mjs --check
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { validateLaunchEvidenceBundle } from "../validate-launch-evidence-bundle.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const START_MARKER = "<!-- release-status:start -->";
const END_MARKER = "<!-- release-status:end -->";
const LAUNCH_EVIDENCE = "launch-evidence/final-launch-evidence.json";
const LAUNCH_DONE_STAMP = "launch-evidence/LAUNCH_DONE.md";
const READINESS_DOC = "docs/TECHNICAL_READINESS.md";
const HANDOVER_DOC = "docs/runbooks/HANDOVER.md";
// The README headline and the readiness page's verdict sentence must never
// disagree (diligence 2026-09-28: README said "Commercial launch candidate"
// while TECHNICAL_READINESS.md said "Commercial GO is not present"). Exactly one
// of these markers must appear on the readiness page.
export const LAUNCH_VERDICTS = Object.freeze([
  Object.freeze({
    value: "source-ready-with-blockers",
    marker: "**Commercial GO is not present:**",
    headline: "Source-ready with named launch blockers",
  }),
  Object.freeze({
    value: "commercial-go",
    marker: "**Commercial GO is present:**",
    headline: "Commercial launch candidate",
  }),
]);
const REQUIRED_INPUT_FIELDS = [
  "macAppStoreReviewState",
  "iosReviewState",
  "manualReleaseEnabled",
  "windowsChannelClaim",
];
const REQUIRED_SURFACES = [
  "macos",
  "ios",
  "android",
  "windows",
  "linux",
  "daemon",
  "extension",
  "cli",
];

function repoPaths(root) {
  return {
    readme: path.join(root, "README.md"),
    project: path.join(root, "project.yml"),
    input: path.join(root, "docs/status/release-status.input.json"),
    output: path.join(root, "docs/status/release-status.json"),
    surfaces: path.join(root, "docs/status/surfaces.json"),
    mobileLedger: path.join(root, "docs/mobile-parity/mobile-parity-ledger.json"),
    windowsLedger: path.join(root, "docs/windows-port/WINDOWS_PARITY_LEDGER.yml"),
    readiness: path.join(root, READINESS_DOC),
    launchEvidence: path.join(root, LAUNCH_EVIDENCE),
    launchDoneStamp: path.join(root, LAUNCH_DONE_STAMP),
    handover: path.join(root, HANDOVER_DOC),
  };
}

function readText(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function readJson(filePath) {
  return JSON.parse(readText(filePath));
}

function oneLine(value, label) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`${label} must be a non-empty string`);
  }
  if (/[\r\n`]/.test(value)) {
    throw new Error(`${label} must be a single line without backticks`);
  }
  return value.trim().replace(/\s+/g, " ");
}

function readMarketingVersion(paths) {
  const match = readText(paths.project).match(
    /^\s+MARKETING_VERSION:\s*["']?([0-9]+\.[0-9]+\.[0-9]+)["']?\s*$/m,
  );
  if (!match) throw new Error("project.yml has no X.Y.Z MARKETING_VERSION");
  return match[1];
}

function readWindowsLedgerSchemaVersion(paths) {
  const match = readText(paths.windowsLedger).match(
    /^version:\s*([0-9]+)\s*$/m,
  );
  if (!match) throw new Error("Windows parity ledger has no schema version");
  return Number(match[1]);
}

function validateInput(input) {
  if (input.schemaVersion !== 1) throw new Error("release-status.input.json schemaVersion must be 1");
  const lastConfirmed = oneLine(input.lastConfirmed, "lastConfirmed");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(lastConfirmed)) {
    throw new Error("lastConfirmed must be YYYY-MM-DD");
  }
  const storeFacing = {};
  for (const field of REQUIRED_INPUT_FIELDS) {
    storeFacing[field] = oneLine(input[field], field);
  }
  return { lastConfirmed, storeFacing };
}

function validateSurfaces(document, root) {
  if (!Array.isArray(document)) {
    throw new Error("surfaces.json must be an array");
  }
  if (document.length !== REQUIRED_SURFACES.length) {
    throw new Error(`surfaces.json must contain exactly ${REQUIRED_SURFACES.length} surfaces`);
  }
  const ids = document.map((surface) => surface?.id);
  if (
    ids.some((id) => !REQUIRED_SURFACES.includes(id)) ||
    new Set(ids).size !== REQUIRED_SURFACES.length
  ) {
    throw new Error(`surfaces.json ids must be exactly ${REQUIRED_SURFACES.join(", ")}`);
  }
  for (const surface of document) {
    const tier = oneLine(surface.tier, `${surface.id}.tier`);
    const evidence = oneLine(surface.evidence, `${surface.id}.evidence`);
    if (path.isAbsolute(evidence) || evidence.split("/").includes("..")) {
      throw new Error(`${surface.id}.evidence must be repository-relative`);
    }
    const evidencePath = path.resolve(root, evidence);
    if (!fs.existsSync(evidencePath)) {
      throw new Error(`${surface.id}.evidence is missing: ${evidence}`);
    }
    surface.tier = tier;
    surface.evidence = evidence;
  }
  return document;
}

/**
 * Commercial GO is present only when the final launch evidence bundle exists
 * AND validates at the `done` stage with its done stamp. Anything else —
 * missing, unreadable, or invalid — is "no GO", with the reason recorded.
 */
function readLaunchPosture(paths) {
  const base = { evidence: LAUNCH_EVIDENCE, readiness: READINESS_DOC };
  if (!fs.existsSync(paths.launchEvidence)) {
    return { ...base, commercialGo: false, reason: `${LAUNCH_EVIDENCE} is missing` };
  }
  let manifest;
  try {
    manifest = readJson(paths.launchEvidence);
  } catch (error) {
    return { ...base, commercialGo: false, reason: `${LAUNCH_EVIDENCE} is unreadable (${error.message})` };
  }
  const result = validateLaunchEvidenceBundle(manifest, {
    manifestPath: paths.launchEvidence,
    donePath: paths.launchDoneStamp,
    stage: "done",
    requireDoneStamp: true,
  });
  if (!result.ok) {
    return {
      ...base,
      commercialGo: false,
      reason: `${LAUNCH_EVIDENCE} fails validation (${result.errors.length} error(s))`,
    };
  }
  return { ...base, commercialGo: true, reason: `${LAUNCH_EVIDENCE} validates at the done stage` };
}

/**
 * The readiness page's single verdict sentence. A GO verdict is accepted only
 * when the final launch evidence validates (see readLaunchPosture).
 */
export function readLaunchVerdict(readinessText, { launchEvidenceValidates = false } = {}) {
  const found = LAUNCH_VERDICTS.filter((verdict) => readinessText.includes(verdict.marker));
  if (found.length !== 1) {
    throw new Error(
      `${READINESS_DOC} must state exactly one commercial verdict (${LAUNCH_VERDICTS.map((verdict) => verdict.marker).join(" or ")}); found ${found.length}`,
    );
  }
  if (found[0].value === "commercial-go" && !launchEvidenceValidates) {
    throw new Error(`a commercial GO verdict requires ${LAUNCH_EVIDENCE} to validate at the done stage`);
  }
  if (found[0].value !== "commercial-go" && launchEvidenceValidates) {
    throw new Error(`${LAUNCH_EVIDENCE} validates but ${READINESS_DOC} still states no commercial GO`);
  }
  return found[0];
}

/**
 * Read one value from the HANDOVER.md "Required slots" table. A missing row is
 * an error: the README must not guess the operator model.
 */
function readHandoverSlot(markdown, slot) {
  for (const line of markdown.split(/\r?\n/)) {
    const cells = line.split("|").map((cell) => cell.trim());
    if (cells.length >= 4 && cells[1] === slot) return cells[2];
  }
  throw new Error(`${HANDOVER_DOC} has no "${slot}" row in its slot table`);
}

/** A slot counts as filled only when it names someone; UNSET / NEEDS ALBERTO do not. */
function isUnfilledSlot(value) {
  const text = value.replace(/[*_`]/g, "").trim();
  return text === "" || /^[—-]$/.test(text) || /\bUNSET\b|\bNONE\b|NEEDS ALBERTO/i.test(text);
}

function readOperatorPosture(paths) {
  const handover = readText(paths.handover);
  const backup = readHandoverSlot(handover, "Backup operator");
  const singleOperator = isUnfilledSlot(backup);
  return {
    model: singleOperator ? "single-operator" : "primary-and-backup",
    backupOperatorNamed: !singleOperator,
    evidence: HANDOVER_DOC,
    risk: "AR-008",
  };
}

export function buildReleaseStatus(root = REPO_ROOT) {
  const paths = repoPaths(root);
  const version = readMarketingVersion(paths);
  const input = validateInput(readJson(paths.input));
  const surfaces = validateSurfaces(readJson(paths.surfaces), root);
  const mobileLedger = readJson(paths.mobileLedger);
  const productParityClaim = mobileLedger.semantics?.productParityClaim;
  if (typeof productParityClaim !== "boolean") {
    throw new Error("mobile parity ledger semantics.productParityClaim must be boolean");
  }
  const programStatus = oneLine(
    mobileLedger.semantics?.programStatus,
    "mobile parity ledger semantics.programStatus",
  );
  const windowsSchemaVersion = readWindowsLedgerSchemaVersion(paths);
  const launch = readLaunchPosture(paths);
  const launchVerdict = readLaunchVerdict(readText(paths.readiness), {
    launchEvidenceValidates: launch.commercialGo,
  });

  const storeFacing = Object.fromEntries(
    REQUIRED_INPUT_FIELDS.map((field) => [
      field,
      {
        value: input.storeFacing[field],
        claim: `operator-asserted (last confirmed ${input.lastConfirmed})`,
      },
    ]),
  );

  return {
    schemaVersion: 1,
    generatedFrom: [
      "project.yml",
      READINESS_DOC,
      "docs/status/release-status.input.json",
      "docs/status/surfaces.json",
      "docs/mobile-parity/mobile-parity-ledger.json",
      "docs/windows-port/WINDOWS_PARITY_LEDGER.yml",
      LAUNCH_EVIDENCE,
      HANDOVER_DOC,
    ],
    launchVerdict: {
      value: launchVerdict.value,
      evidence: READINESS_DOC,
    },
    launch,
    operators: readOperatorPosture(paths),
    macOS: {
      marketingVersion: version,
      evidence: "project.yml",
    },
    windows: {
      ledgerSchemaVersion: windowsSchemaVersion,
      evidence: "docs/windows-port/WINDOWS_PARITY_LEDGER.yml",
    },
    mobileParity: {
      productParityClaim,
      programStatus,
      evidence: "docs/mobile-parity/mobile-parity-ledger.json",
    },
    storeFacing,
    surfaces,
  };
}

function renderHeadline(status) {
  const { launch } = status;
  const { headline } = LAUNCH_VERDICTS.find((verdict) => verdict.value === status.launchVerdict.value);
  return launch.commercialGo
    ? `${headline} — validated launch evidence is committed (\`${launch.evidence}\`)`
    : `${headline}; commercial GO is not present (${launch.reason}; see [${path.basename(launch.readiness)}](${launch.readiness}))`;
}

function renderOperators(operators) {
  return operators.backupOperatorNamed
    ? `a primary and a backup operator are named in [HANDOVER.md](${operators.evidence})`
    : `run by a single operator with no named backup (risk ${operators.risk}; [HANDOVER.md](${operators.evidence}))`;
}

export function renderBlock(status) {
  const asserted = (field) =>
    `${status.storeFacing[field].claim} — ${status.storeFacing[field].value}`;
  return [
    START_MARKER,
    `**Status:** ${renderHeadline(status)}. OpenBurnBar is ${renderOperators(status.operators)}. macOS \`${status.macOS.marketingVersion}\` is the committed product version; mobile parity claim is \`${status.mobileParity.productParityClaim}\` (${status.mobileParity.programStatus}); Mac App Store review: ${asserted("macAppStoreReviewState")}; iOS review: ${asserted("iosReviewState")}; manual release: ${asserted("manualReleaseEnabled")}; Windows channel: ${asserted("windowsChannelClaim")}.`,
    END_MARKER,
  ].join("\n");
}

function expectedReadme(readme, block) {
  const markerPattern = new RegExp(
    `${START_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[\\s\\S]*?${END_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`,
    "g",
  );
  const matches = readme.match(markerPattern) ?? [];
  if (matches.length !== 1) {
    throw new Error("README.md must contain exactly one release-status marker block");
  }
  return readme.replace(markerPattern, block);
}

function main() {
  const check = process.argv.includes("--check");
  if (process.argv.length !== (check ? 3 : 2) || (check && process.argv[2] !== "--check")) {
    console.error("Usage: node scripts/release/render-release-status.mjs [--check]");
    process.exit(2);
  }

  const paths = repoPaths(REPO_ROOT);
  const status = buildReleaseStatus(REPO_ROOT);
  const generatedJson = `${JSON.stringify(status, null, 2)}\n`;
  const renderedBlock = renderBlock(status);
  const currentJson = fs.existsSync(paths.output) ? readText(paths.output) : "";
  const currentReadme = readText(paths.readme);
  const renderedReadme = expectedReadme(currentReadme, renderedBlock);

  if (check) {
    let failed = false;
    if (currentJson !== generatedJson) {
      console.error("FAIL: docs/status/release-status.json is stale; run the renderer without --check.");
      failed = true;
    }
    if (currentReadme !== renderedReadme) {
      console.error("FAIL: README.md release-status block is stale; run the renderer without --check.");
      failed = true;
    }
    if (failed) process.exit(1);
    console.log("PASS: generated release status and README block are current");
    return;
  }

  fs.writeFileSync(paths.output, generatedJson, "utf8");
  fs.writeFileSync(paths.readme, renderedReadme, "utf8");
  console.log("Wrote docs/status/release-status.json and README.md release-status block");
}

// Compare real paths: the maintainer checkout is reached through a symlink, and a
// plain string compare would silently skip main() there.
function invokedDirectly() {
  if (!process.argv[1]) return false;
  try {
    return fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  main();
}
