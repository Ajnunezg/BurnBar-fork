#!/usr/bin/env node
/**
 * Fail when an agent contract cites a repository path that does not exist.
 *
 * Agent contracts are the files agents load as instructions: every tracked
 * AGENTS.md, CLAUDE.md and SKILL.md. In an agent-driven repo a stale citation is
 * a live defect (diligence 2026-09-28: AGENTS.md named a deleted
 * functions/src/types.ts "THE CANONICAL SCHEMA" six times).
 *
 * Checked citations (prose only; fenced code blocks hold commands whose paths
 * are relative to whatever directory they `cd` into):
 *   - Markdown links `[text](target)`, resolved relative to the contract file
 *     (http(s)/mailto/anchor-only links skipped; `#fragment` dropped).
 *   - Inline code that names a repository file or directory: no whitespace,
 *     templates, globs or ellipses, a `/` in it, a file extension or a trailing
 *     `/`, and a first segment that is a tracked top-level entry (or an entry
 *     next to the contract, such as a skill's references/). Firestore paths
 *     (`users/{uid}`), home paths (`~/.codex/...`), URLs, MCP method names
 *     (`tools/list`) and commands never qualify.
 * Vendored, repo-agnostic skills (no mention of BurnBar) are checked for links
 * only: their inline paths describe whatever project they are applied to.
 *
 * A citation resolves when git tracks the path (file) or something under it
 * (directory). A gitignored path counts as intentionally absent only when the
 * citing line says so ("never committed", "gitignored", "local-only"), as for
 * android/app/google-services.json; the build outputs in GENERATED_OUTPUTS are
 * also reported, not failed. Everything else that git does not track fails.
 *
 * Usage: node scripts/ci/check-agent-contract-paths.mjs [--root <git work tree>]
 */
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CONTRACT_NAMES = new Set(["AGENTS.md", "CLAUDE.md", "SKILL.md"]);
const EXCLUDED_PREFIXES = ["Vendor/", "third_party/", "node_modules/"];
// Build outputs a contract legitimately names before they exist.
const GENERATED_OUTPUTS = new Map([
  ["Vendor/opus-android.aar", "built by scripts/build_opus_android.sh"],
]);
const PATH_TOKEN = /^(?:\.\/)?[A-Za-z0-9_.@-][A-Za-z0-9_.@+/-]*$/u;
const LOCAL_ONLY_NOTE = /\b(?:never|not)\s+committed\b|\bgit-?ignored\b|\blocal[- ]only\b/iu;
const HAS_EXTENSION = /\.[A-Za-z0-9]{1,10}$/u;

function parseArgs(argv) {
  const args = { root: path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..") };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--root" && argv[index + 1]) {
      args.root = path.resolve(argv[index + 1]);
      index += 1;
    } else {
      console.error(`unknown argument: ${argv[index]}`);
      process.exit(2);
    }
  }
  return args;
}

function trackedFiles(root) {
  return execFileSync("git", ["-C", root, "ls-files", "-z"], { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 })
    .split("\0")
    .filter(Boolean);
}

function gitIgnored(root, repoPath) {
  return spawnSync("git", ["-C", root, "check-ignore", "-q", "--no-index", "--", repoPath]).status === 0;
}

export function buildIndex(files) {
  const fileSet = new Set(files);
  const dirSet = new Set();
  const topLevel = new Set();
  for (const file of files) {
    const parts = file.split("/");
    topLevel.add(parts[0]);
    for (let depth = 1; depth < parts.length; depth += 1) {
      dirSet.add(parts.slice(0, depth).join("/"));
    }
  }
  return { fileSet, dirSet, topLevel };
}

function exists(index, repoPath) {
  const normalized = repoPath.replace(/\/+$/u, "");
  return normalized === "" || index.fileSet.has(normalized) || index.dirSet.has(normalized);
}

function normalizeRelative(contractDir, target) {
  const joined = path.posix.normalize(path.posix.join(contractDir, target));
  return joined === ".." || joined.startsWith("../") ? null : joined.replace(/^\.\//u, "");
}

function stripLocation(token) {
  // `path/to/file.swift:123` or `:12-40` line citations point at the file.
  return token.replace(/:(?:L?\d+)(?:-L?\d+)?$/u, "");
}

/** Yields { line, target, kind } for every citation candidate outside fenced code. */
export function* citations(text) {
  const lines = text.split("\n");
  let fenced = false;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (/^\s*(```|~~~)/u.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    for (const match of line.matchAll(/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/gu)) {
      yield { line: lineIndex + 1, target: match[1], kind: "link" };
    }
    for (const match of line.matchAll(/`([^`]+)`/gu)) {
      yield { line: lineIndex + 1, target: match[1], kind: "code" };
    }
  }
}

/** Returns the repo-relative path a citation must resolve to, or null to skip it. */
export function resolveCitation(citation, contractDir, index) {
  const { target, kind } = citation;
  if (kind === "link") {
    if (/^(?:[a-z][a-z0-9+.-]*:|#|\/\/)/iu.test(target)) return null;
    const withoutFragment = target.split("#")[0].split("?")[0];
    if (!withoutFragment) return null;
    let decoded;
    try {
      decoded = decodeURIComponent(withoutFragment);
    } catch {
      decoded = withoutFragment;
    }
    return normalizeRelative(contractDir, stripLocation(decoded));
  }
  const token = stripLocation(target.replace(/[.,:;]+$/u, ""));
  if (
    !PATH_TOKEN.test(token) ||
    !token.includes("/") ||
    token.includes("//") ||
    token.includes("...") ||
    !(HAS_EXTENSION.test(token) || token.endsWith("/"))
  ) {
    return null;
  }
  const bare = token.replace(/^\.\//u, "");
  const first = bare.split("/")[0];
  if (index.topLevel.has(first)) return bare;
  if (contractDir) {
    const anchor = `${contractDir}/${first}`;
    if (index.dirSet.has(anchor) || index.fileSet.has(anchor)) return `${contractDir}/${bare}`;
  }
  return null;
}

export function scanContracts(root, files = trackedFiles(root)) {
  const index = buildIndex(files);
  const contracts = files.filter(
    (file) =>
      CONTRACT_NAMES.has(path.posix.basename(file)) &&
      !EXCLUDED_PREFIXES.some((prefix) => file.startsWith(prefix)),
  );
  const missing = [];
  const intentionallyAbsent = [];
  let checked = 0;
  for (const contract of contracts) {
    const rawDir = path.posix.dirname(contract);
    const contractDir = rawDir === "." ? "" : rawDir;
    const text = readFileSync(path.join(root, contract), "utf8");
    const lines = text.split("\n");
    const repoSpecific = contractDir === "" || /burnbar/iu.test(text);
    const seen = new Set();
    for (const citation of citations(text)) {
      if (!repoSpecific && citation.kind !== "link") continue;
      const repoPath = resolveCitation(citation, contractDir, index);
      if (repoPath === null) continue;
      const key = `${citation.line}:${repoPath}`;
      if (seen.has(key)) continue;
      seen.add(key);
      checked += 1;
      if (exists(index, repoPath)) continue;
      const entry = { contract, line: citation.line, path: repoPath, kind: citation.kind };
      if (GENERATED_OUTPUTS.has(repoPath)) {
        intentionallyAbsent.push({ ...entry, reason: GENERATED_OUTPUTS.get(repoPath) });
      } else if (gitIgnored(root, repoPath) && LOCAL_ONLY_NOTE.test(lines[citation.line - 1] ?? "")) {
        // e.g. "`android/app/google-services.json` — never committed". An
        // ignored path the contract does not call local is absent from every
        // clone, so it still fails.
        intentionallyAbsent.push({ ...entry, reason: "gitignored local file the contract marks as never committed" });
      } else {
        missing.push(entry);
      }
    }
  }
  return { contracts: contracts.length, checked, missing, intentionallyAbsent };
}

function main() {
  const { root } = parseArgs(process.argv.slice(2));
  const { contracts, checked, missing, intentionallyAbsent } = scanContracts(root);
  if (contracts === 0 || checked === 0) {
    console.error(`FAIL: found ${contracts} agent contracts and ${checked} path citations; the scan matched nothing.`);
    process.exit(1);
  }
  for (const item of intentionallyAbsent) {
    console.log(`note: ${item.contract}:${item.line}: ${item.path} is absent by design (${item.reason})`);
  }
  if (missing.length > 0) {
    console.error(`FAIL: ${missing.length} agent-contract path citation(s) do not exist in the tracked tree:`);
    for (const item of missing) {
      console.error(`  ${item.contract}:${item.line}: ${item.path} (${item.kind})`);
    }
    console.error("Fix the citation (or restore the file) so agents do not follow a dead contract.");
    process.exit(1);
  }
  console.log(`PASS: ${checked} path citations across ${contracts} agent contracts all resolve`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
