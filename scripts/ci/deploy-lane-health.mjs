#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { classifyFailure } = require("../../.github/actions/ops-failure-issue/escalation.cjs");

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_OUTPUT = path.join(repositoryRoot, "ci/deploy-lane-health.json");
const GITHUB_API_DEFAULT = "https://api.github.com";
const DEFAULT_LIMIT = 10;
// Same 14-day window the WIF deploy-freshness lane applies to function ages.
const DEFAULT_BEHIND_MAX_DAYS = 14;
// GitHub's compare API lists at most 300 changed files.
const COMPARE_FILES_CAP = 300;
const FUNCTIONS_RELEVANT_PATHS = Object.freeze([
  "functions/",
  "functions-identity/",
  "functions-sync/",
  "functions-media/",
  "packages/",
  "firebase.json",
  "firestore.rules",
  "firestore.indexes.json",
  "storage.rules",
]);
const FULL_SHA = /^[0-9a-f]{40}$/u;

export const DEPLOY_LANES = Object.freeze([
  Object.freeze({
    lane: "deploy-production",
    workflow: "deploy-production.yml",
    label: "Production Cloud Functions",
    freshness: true,
    healthUrls: ["functionsReady", "functionsLive"],
    healthExpectations: {
      functionsReady: { status: "ready" },
      functionsLive: { status: "alive" },
    },
  }),
  Object.freeze({
    lane: "deploy-cloud-run",
    workflow: "deploy-cloud-run.yml",
    label: "Production hosted MCP Cloud Run",
    healthUrls: ["cloudRunReady"],
    healthExpectations: {
      cloudRunReady: { ok: true },
    },
  }),
]);

function parseArguments(argv) {
  const values = {
    out: DEFAULT_OUTPUT,
    fixture: process.env.DEPLOY_LANE_HEALTH_FIXTURE || null,
    apiBase: process.env.GITHUB_API_URL || GITHUB_API_DEFAULT,
    repo: process.env.GITHUB_REPOSITORY || null,
    token: process.env.GH_TOKEN || process.env.GITHUB_TOKEN || null,
    limit: DEFAULT_LIMIT,
    behindMaxDays: Number(process.env.DEPLOY_LANE_BEHIND_MAX_DAYS || DEFAULT_BEHIND_MAX_DAYS),
    functionsReady: process.env.FUNCTIONS_HEALTH_READY_URL || "https://us-central1-burnbar.cloudfunctions.net/healthReady",
    functionsLive: process.env.FUNCTIONS_HEALTH_LIVE_URL || "https://us-central1-burnbar.cloudfunctions.net/healthLive",
    cloudRunReady: process.env.CLOUD_RUN_HEALTH_READY_URL || "https://mcp.burnbar.ai/readyz",
  };
  const supported = new Set([
    "--out",
    "--fixture",
    "--api-base",
    "--repo",
    "--limit",
    "--functions-ready",
    "--functions-live",
    "--cloud-run-ready",
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!supported.has(argument)) throw new Error(`unsupported argument ${argument}`);
    if (index + 1 >= argv.length) throw new Error(`${argument} requires a value`);
    const value = argv[index + 1];
    index += 1;
    if (argument === "--out") values.out = path.resolve(value);
    if (argument === "--fixture") values.fixture = path.resolve(value);
    if (argument === "--api-base") values.apiBase = value.replace(/\/+$/u, "");
    if (argument === "--repo") values.repo = value;
    if (argument === "--limit") {
      values.limit = Number.parseInt(value, 10);
      if (!Number.isInteger(values.limit) || values.limit < 1 || values.limit > 100) {
        throw new Error("--limit must be an integer between 1 and 100");
      }
    }
    if (argument === "--functions-ready") values.functionsReady = value;
    if (argument === "--functions-live") values.functionsLive = value;
    if (argument === "--cloud-run-ready") values.cloudRunReady = value;
  }
  if (!Number.isFinite(values.behindMaxDays) || values.behindMaxDays <= 0) {
    throw new Error("DEPLOY_LANE_BEHIND_MAX_DAYS must be a positive number of days");
  }
  return values;
}

function repositoryName(repo) {
  if (!repo || !/^[^/]+\/[^/]+$/u.test(repo)) {
    throw new Error("GITHUB_REPOSITORY or --repo must be owner/repository");
  }
  return repo;
}

async function requestJson(url, token) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/vnd.github+json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      "X-GitHub-Api-Version": "2022-11-28",
    },
    signal: AbortSignal.timeout(30_000),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`GitHub API returned ${response.status} for ${url}: ${body.slice(0, 240)}`);
  }
  try {
    return body ? JSON.parse(body) : null;
  } catch (error) {
    throw new Error(`GitHub API returned invalid JSON for ${url}: ${error.message}`);
  }
}

async function probeHealth(url, expectation = {}) {
  const startedAt = Date.now();
  try {
    const response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(15_000),
    });
    const body = await response.text();
    let parsed = null;
    try {
      parsed = body ? JSON.parse(body) : null;
    } catch {
      // The semantic expectation below intentionally fails closed when a
      // health endpoint returns a non-JSON or malformed response.
    }
    const semanticOk = Object.entries(expectation).every(([key, expected]) => (
      parsed?.[key] === expected
    ));
    return {
      url,
      statusCode: response.status,
      ok: response.ok && semanticOk,
      durationMs: Date.now() - startedAt,
      responseOk: response.ok,
      bodyOk: parsed?.ok ?? null,
      bodyStatus: parsed?.status ?? null,
      sourceCommit: FULL_SHA.test(parsed?.source?.commit ?? "") ? parsed.source.commit : null,
      version: typeof parsed?.version === "string" ? parsed.version : null,
    };
  } catch (error) {
    return {
      url,
      statusCode: null,
      ok: false,
      durationMs: Date.now() - startedAt,
      responseOk: false,
      bodyOk: null,
      error: String(error?.message || error).slice(0, 240),
    };
  }
}

function sortRuns(runs) {
  const timestamp = (run) => {
    const value = Date.parse(run?.created_at || run?.updated_at || "");
    return Number.isFinite(value) ? value : Number.POSITIVE_INFINITY;
  };
  return [...runs].sort((left, right) => (
    timestamp(right) - timestamp(left)
    || Number(right.id || 0) - Number(left.id || 0)
  ));
}

// A production deployment is a tag push, or a manual dispatch that the deploy
// workflow accepted as an existing-tag retry (its run-name carries
// "existing-tag-retry"). Dry runs and plain dispatches — which the workflows
// deliberately reject — are not deployments and must not sort ahead of the
// last real one.
function isProductionRun(run) {
  if (!run) return false;
  const descriptor = `${run.name || ""} ${run.display_title || ""}`.toLowerCase();
  if (descriptor.includes("dry-run") || descriptor.includes("dry run")) return false;
  if (run.event === "push") return true;
  if (run.event === "workflow_dispatch") return descriptor.includes("existing-tag-retry");
  return false;
}

// A break-glass existing-tag retry ships only healthReady/healthLive/healthCheck.
// It never anchors fleet freshness: healthReady then reports the retried commit
// while every other function keeps its older source (2026-09-14 did exactly this).
export function isBreakGlassRun(run) {
  return `${run?.name || ""} ${run?.display_title || ""}`
    .toLowerCase()
    .includes("existing-tag-retry-break-glass");
}

// run-name: release-control/deploy-production/<mode>/<tag>/<candidate_sha>/<control_sha>.
// For an existing-tag retry head_sha is the main control commit, not the payload.
export function deployedCommit(run) {
  const segments = String(run?.display_title || "").split("/");
  if (segments[0] === "release-control" && FULL_SHA.test(segments[4] || "")) return segments[4];
  return FULL_SHA.test(run?.head_sha || "") ? run.head_sha : null;
}

export function latestFullDeploy(rawRuns) {
  const run = sortRuns(rawRuns.filter(isProductionRun)).find(
    (candidate) => candidate?.conclusion === "success" && !isBreakGlassRun(candidate),
  );
  if (!run) return null;
  return {
    run_id: run.id ?? null,
    commit: deployedCommit(run),
    created_at: run.created_at ?? null,
    url: run.html_url ?? null,
  };
}

/**
 * Production freshness: how far main has moved past the commit the Functions
 * fleet runs. Anchors on the latest successful non-break-glass deploy, falling
 * back to healthReady's source.commit. Red only when main carries unshipped
 * Functions-relevant changes and the deployed commit is older than maxDays, so
 * a quiet main never pages; an unknown commit or comparison fails closed.
 */
export function evaluateProductionFreshness({
  fleetDeploy = null,
  servingCommit = null,
  comparison = null,
  now = new Date(),
  maxDays = DEFAULT_BEHIND_MAX_DAYS,
} = {}) {
  const anchor = fleetDeploy?.commit ? "fleet" : servingCommit ? "serving" : null;
  const commit = fleetDeploy?.commit || servingCommit || null;
  const base = { anchor, commit, servingCommit, fleetDeploy, maxDays };
  if (!commit) {
    return { ...base, status: "red", reasonCode: "deployed-commit-unknown" };
  }
  if (!comparison || comparison.error) {
    return { ...base, status: "red", reasonCode: "github-api-error", error: comparison?.error ?? "no comparison" };
  }
  const files = Array.isArray(comparison.files) ? comparison.files : [];
  const touched = files.some((file) => FUNCTIONS_RELEVANT_PATHS.some((prefix) => (
    prefix.endsWith("/") ? file.startsWith(prefix) : file === prefix
  )));
  const functionsChanged = touched ? true : files.length >= COMPARE_FILES_CAP ? "unknown" : false;
  const commitTime = Date.parse(comparison.commitDate ?? "");
  const ageDays = Number.isFinite(commitTime)
    ? Math.max(0, (now.getTime() - commitTime) / 86_400_000)
    : null;
  const behindBy = Number.isInteger(comparison.behindBy) ? comparison.behindBy : null;
  const result = {
    ...base,
    mainCommit: comparison.mainCommit ?? null,
    behindBy,
    functionsChanged,
    commitDate: comparison.commitDate ?? null,
    ageDays: ageDays === null ? null : Math.round(ageDays * 10) / 10,
  };
  if (behindBy === null || ageDays === null) {
    return { ...result, status: "red", reasonCode: "github-api-error", error: "compare response lacked ahead_by or commit date" };
  }
  if (behindBy > 0 && functionsChanged !== false && ageDays > maxDays) {
    return { ...result, status: "red", reasonCode: "behind-main" };
  }
  return { ...result, status: "green", reasonCode: null };
}

async function compareWithMain(options, commit) {
  try {
    const main = await requestJson(`${options.apiBase}/repos/${options.repo}/commits/main`, options.token);
    const compare = await requestJson(
      `${options.apiBase}/repos/${options.repo}/compare/${commit}...${main?.sha}`,
      options.token,
    );
    return {
      mainCommit: main?.sha ?? null,
      behindBy: compare?.ahead_by,
      files: (compare?.files || []).map((file) => file?.filename).filter(Boolean),
      commitDate: compare?.base_commit?.commit?.committer?.date ?? null,
    };
  } catch (error) {
    return { error: String(error?.message || error).slice(0, 240) };
  }
}

function applyFreshness(lane, freshness) {
  lane.freshness = freshness;
  if (freshness.status !== "red" || lane.red) return lane;
  lane.red = true;
  lane.status = "failed";
  lane.conclusion = freshness.reasonCode;
  lane.classification = freshness.reasonCode === "behind-main" ? "budget" : "infra";
  lane.failureClass = lane.classification;
  lane.reasonCode = freshness.reasonCode;
  return lane;
}

function normalizeRun(run) {
  const conclusion = run?.conclusion || null;
  const runId = run?.id ?? null;
  const hasRunMetadata = Number.isSafeInteger(Number(runId))
    && Number(runId) > 0
    && String(run?.status).toLowerCase() === "completed"
    && Number.isFinite(Date.parse(run?.created_at || ""));
  const reasonCode = run?.reasonCode
    || run?.reason_code
    || (hasRunMetadata ? null : "run-metadata-missing");
  const classification = classifyFailure({
    status: run?.status,
    conclusion,
    reasonCode,
    skipped: conclusion === "skipped",
  });
  return {
    run_id: runId,
    run_attempt: run?.run_attempt ?? null,
    status: classification.classification === "healthy"
      ? "success"
      : classification.classification === "infra" ? "infra-failed" : "failed",
    conclusion: conclusion || "unknown",
    classification: classification.classification,
    failureClass: classification.failureClass,
    reasonCode: classification.reasonCode,
    created_at: run?.created_at || null,
    updated_at: run?.updated_at || null,
    url: run?.html_url || null,
    event: run?.event || null,
    head_sha: run?.head_sha || null,
  };
}

function latestProductionRun(rawRuns, limit) {
  const productionRuns = sortRuns(rawRuns.filter(isProductionRun)).slice(0, limit);
  const normalized = productionRuns.map(normalizeRun);
  let consecutiveRed = 0;
  for (const run of normalized) {
    if (run.classification === "healthy") break;
    consecutiveRed += 1;
  }
  return {
    latest: normalized[0] || {
      run_id: null,
      run_attempt: null,
      status: "infra-failed",
      conclusion: "unknown",
      classification: "infra",
      failureClass: "infra",
      reasonCode: "no-production-deploy-run",
      created_at: null,
      updated_at: null,
      url: null,
      event: null,
      head_sha: null,
    },
    runs: normalized,
    consecutive_red: consecutiveRed || (normalized[0]?.classification !== "healthy" ? 1 : 0),
  };
}

function fixtureRunsForLane(fixture, definition) {
  if (Array.isArray(fixture?.lanes)) {
    const row = fixture.lanes.find((candidate) => (
      candidate?.lane === definition.lane || candidate?.workflow === definition.workflow
    ));
    return row?.runs || row?.workflow_runs || [];
  }
  const row = fixture?.lanes?.[definition.lane]
    || fixture?.lanes?.[definition.workflow]
    || fixture?.[definition.lane]
    || fixture?.[definition.workflow];
  return Array.isArray(row) ? row : row?.runs || row?.workflow_runs || [];
}

function fixtureProbe(fixture, key, fallbackUrl) {
  const value = fixture?.probes?.[key];
  if (!value) return { url: fallbackUrl, ok: false, statusCode: null, error: "missing-probe-fixture" };
  return {
    url: value.url || fallbackUrl,
    ok: value.ok === true,
    statusCode: value.statusCode ?? null,
    durationMs: value.durationMs ?? 0,
    responseOk: value.responseOk ?? value.ok === true,
    bodyOk: value.bodyOk ?? null,
    ...(value.error ? { error: String(value.error).slice(0, 240) } : {}),
  };
}

function laneReport(definition, runHistory, probes) {
  const probeRed = probes.some((probe) => !probe.ok);
  const latest = runHistory.latest;
  const deployRed = latest.classification !== "healthy";
  const red = deployRed || probeRed;
  const probeOnlyRed = !deployRed && probeRed;
  const classification = deployRed
    ? latest.classification
    : probeRed ? "infra" : "healthy";
  const reasonCode = deployRed
    ? latest.reasonCode
    : probeRed ? (probes.find((probe) => !probe.ok)?.error ? "health-probe-error" : "health-check-failed") : null;
  return {
    lane: definition.lane,
    workflow: definition.workflow,
    label: definition.label,
    status: red ? (probeOnlyRed ? "infra-failed" : latest.status) : "success",
    conclusion: red
      ? (probeOnlyRed || latest.conclusion === "success" ? "health-check-failed" : latest.conclusion)
      : "success",
    classification,
    failureClass: red ? (classification === "infra" ? "infra" : latest.failureClass) : null,
    reasonCode,
    red,
    // Counts consecutive failed deployment runs only; runHistory holds
    // deployments, not probe observations, so a probe-only outage stays 0
    // here and is reported through status/reasonCode instead.
    consecutive_red: deployRed ? Math.max(1, runHistory.consecutive_red) : 0,
    run_id: latest.run_id,
    run_attempt: latest.run_attempt,
    url: latest.url,
    created_at: latest.created_at,
    updated_at: latest.updated_at,
    probes,
    runs: runHistory.runs,
  };
}

function freshnessLine(freshness) {
  const short = (sha) => (sha ? `\`${sha.slice(0, 10)}\`` : "`unknown`");
  if (!freshness.commit) {
    return "Production freshness: **RED** — no deployed commit could be identified (no full deploy run and no healthReady source.commit).";
  }
  const anchor = freshness.anchor === "fleet"
    ? `fleet commit ${short(freshness.commit)} (last full deploy run ${freshness.fleetDeploy?.run_id ?? "?"})`
    : `healthReady commit ${short(freshness.commit)} (no full deploy run in history; may describe only the health endpoints)`;
  const serving = freshness.servingCommit && freshness.servingCommit !== freshness.commit
    ? ` healthReady serves ${short(freshness.servingCommit)}, which a break-glass health-only deploy can move without refreshing the fleet.`
    : "";
  if (freshness.behindBy === null || freshness.behindBy === undefined) {
    return `Production freshness: **${freshness.status.toUpperCase()}** — ${anchor}; comparison with main unavailable (${freshness.error ?? freshness.reasonCode}).${serving}`;
  }
  const changed = freshness.functionsChanged === "unknown" ? "unknown (compare truncated)" : freshness.functionsChanged ? "yes" : "no";
  return `Production freshness: **${freshness.status.toUpperCase()}** — ${anchor} is ${freshness.behindBy} commit(s) behind main ${short(freshness.mainCommit)}; Functions paths changed: ${changed}; deployed commit is ${freshness.ageDays} day(s) old (limit ${freshness.maxDays}).${serving}`;
}

function markdownSummary(report) {
  const lines = [
    "## Deploy lane health",
    "",
    `Status: **${report.status.toUpperCase()}**`,
    "",
    "| Lane | Latest deploy | Health probes | Consecutive red deploys |",
    "| --- | --- | --- | ---: |",
  ];
  for (const lane of report.lanes) {
    const probeStatus = lane.probes.every((probe) => probe.ok) ? "green" : "red";
    lines.push(
      `| \`${lane.lane}\` | \`${lane.conclusion}\` | \`${probeStatus}\` | ${lane.consecutive_red} |`,
    );
  }
  for (const lane of report.lanes) {
    if (lane.freshness) lines.push("", freshnessLine(lane.freshness));
  }
  if (report.blockers.length > 0) {
    lines.push("", `Blockers: ${report.blockers.map((blocker) => `\`${blocker}\``).join(", ")}`);
  }
  lines.push(
    "",
    "Automated path: red opens/updates the deploy-health issue and remains non-zero.",
    "Human queue path: assign a release owner, record the blocker and expiry, then use the approved main-only release control; do not rerun a tag workflow blindly.",
  );
  if (report.source.mode === "offline-fixture") {
    lines.push("", "> Offline fixture mode: no GitHub token was used; this is not a live-green claim.");
  }
  return `${lines.join("\n")}\n`;
}

function buildReport(lanes, source, generatedAt, blockers = []) {
  const laneBlockers = lanes
    .filter((lane) => lane.red && lane.reasonCode)
    .map((lane) => `${lane.lane}:${lane.reasonCode}`);
  return {
    schemaVersion: 1,
    generatedAt,
    status: lanes.some((lane) => lane.red) ? "red" : "green",
    source,
    lanes,
    blockers: [...new Set([...blockers, ...laneBlockers])],
    human_queue: {
      required_on_red: true,
      owner: "release owner",
      exit_path: "record named blocker and expiry, then use approved main-only release control",
    },
    markdown: "",
  };
}

async function loadFixture(fixturePath) {
  if (!fixturePath) return { generatedAt: new Date().toISOString(), lanes: [], probes: {} };
  return JSON.parse(await readFile(fixturePath, "utf8"));
}

async function collectLive(options) {
  const lanes = [];
  const blockers = [];
  for (const definition of DEPLOY_LANES) {
    let runHistory;
    let rawRuns = null;
    try {
      // Fetch the maximum bounded page before filtering dry runs. A burst of
      // manual dry-runs must not hide the latest real tag deploy outside the
      // first `limit` raw results.
      const rawRunPageSize = "100";
      const query = new URLSearchParams({ event: "push", per_page: rawRunPageSize });
      const response = await requestJson(
        `${options.apiBase}/repos/${options.repo}/actions/workflows/${encodeURIComponent(definition.workflow)}/runs?${query}`,
        options.token,
      );
      if (!Array.isArray(response?.workflow_runs)) {
        throw new Error(`no workflow_runs array for ${definition.workflow}`);
      }
      // A tag push is the ordinary real deploy path. A manually approved
      // existing-tag retry is queried separately because GitHub's workflow-run
      // list cannot filter its input payload.
      const dispatchQuery = new URLSearchParams({ event: "workflow_dispatch", per_page: rawRunPageSize });
      const dispatchResponse = await requestJson(
        `${options.apiBase}/repos/${options.repo}/actions/workflows/${encodeURIComponent(definition.workflow)}/runs?${dispatchQuery}`,
        options.token,
      );
      const dispatchRuns = Array.isArray(dispatchResponse?.workflow_runs)
        ? dispatchResponse.workflow_runs
        : [];
      rawRuns = [...response.workflow_runs, ...dispatchRuns];
      runHistory = latestProductionRun(rawRuns, options.limit);
    } catch (error) {
      runHistory = latestProductionRun([], options.limit);
      runHistory.latest = {
        ...runHistory.latest,
        status: "infra-failed",
        conclusion: "infra-failed",
        classification: "infra",
        failureClass: "infra",
        reasonCode: "github-api-error",
        observation_error: String(error?.message || error).slice(0, 240),
      };
      blockers.push(`${definition.lane}:github-api-error`);
    }
    const probeUrls = definition.healthUrls.map((key) => options[key]);
    const probes = await Promise.all(probeUrls.map((url, index) => (
      probeHealth(url, definition.healthExpectations[definition.healthUrls[index]])
    )));
    const report = laneReport(definition, runHistory, probes);
    if (definition.freshness) {
      const fleetDeploy = rawRuns ? latestFullDeploy(rawRuns) : null;
      const servingCommit = probes.find((probe) => probe.sourceCommit)?.sourceCommit ?? null;
      const commit = fleetDeploy?.commit || servingCommit;
      const comparison = commit ? await compareWithMain(options, commit) : null;
      const freshness = evaluateProductionFreshness({
        fleetDeploy,
        servingCommit,
        comparison,
        maxDays: options.behindMaxDays,
      });
      applyFreshness(report, freshness);
      if (freshness.status === "red") blockers.push(`${definition.lane}:${freshness.reasonCode}`);
    }
    lanes.push(report);
    if (report.red && report.reasonCode) blockers.push(`${definition.lane}:${report.reasonCode}`);
  }
  return { lanes, blockers };
}

export async function collectDeployLaneHealth(options) {
  const source = {
    mode: options.token ? "github" : "offline-fixture",
    api: "GitHub Actions workflow-runs + public deployment health probes",
    repository: options.repo || null,
    events: ["push", "workflow_dispatch"],
  };
  if (!options.token) {
    const fixture = await loadFixture(options.fixture);
    const lanes = DEPLOY_LANES.map((definition) => {
      const runs = fixtureRunsForLane(fixture, definition);
      const history = latestProductionRun(runs, options.limit);
      const probes = definition.healthUrls.map((key) => fixtureProbe(fixture, key, options[key]));
      const lane = laneReport(definition, history, probes);
      // Offline fixtures evaluate freshness only when they carry a comparison;
      // the report already says offline mode is not a live-green claim.
      if (definition.freshness && fixture?.freshness) {
        applyFreshness(lane, evaluateProductionFreshness({
          fleetDeploy: latestFullDeploy(runs),
          servingCommit: fixture.freshness.servingCommit ?? null,
          comparison: fixture.freshness.comparison ?? null,
          now: new Date(fixture.freshness.now ?? fixture.generatedAt ?? Date.now()),
          maxDays: options.behindMaxDays ?? DEFAULT_BEHIND_MAX_DAYS,
        }));
      }
      return lane;
    });
    const report = buildReport(
      lanes,
      { ...source, fixture: options.fixture || "built-in" },
      fixture.generatedAt || new Date().toISOString(),
      fixture.blockers || [],
    );
    report.markdown = markdownSummary(report);
    return report;
  }
  const live = await collectLive(options);
  const report = buildReport(live.lanes, source, new Date().toISOString(), live.blockers);
  report.markdown = markdownSummary(report);
  return report;
}

async function writeReport(outputPath, report) {
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  if (process.env.GITHUB_STEP_SUMMARY) {
    await writeFile(process.env.GITHUB_STEP_SUMMARY, report.markdown, { encoding: "utf8", flag: "a" });
  }
  if (process.env.GITHUB_OUTPUT) {
    await writeFile(
      process.env.GITHUB_OUTPUT,
      `status=${report.status}\nred=${report.status === "red"}\n` +
      `blockers=${report.blockers.join(",") || "none"}\n`,
      { encoding: "utf8", flag: "a" },
    );
  }
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (!options.token && !options.fixture) {
    process.stderr.write("GH_TOKEN unavailable; using the explicit offline fixture mode.\n");
  }
  const report = await collectDeployLaneHealth({
    ...options,
    repo: options.repo ? repositoryName(options.repo) : null,
  });
  await writeReport(options.out, report);
  process.stdout.write(report.markdown);
  if (report.status !== "green") process.exitCode = 1;
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (error) {
    process.stderr.write(`deploy-lane-health failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
