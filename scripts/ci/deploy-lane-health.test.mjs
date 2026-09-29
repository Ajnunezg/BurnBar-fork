import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  DEPLOY_LANES,
  collectDeployLaneHealth,
  deployedCommit,
  evaluateProductionFreshness,
  isBreakGlassRun,
  latestFullDeploy,
  main,
} from "./deploy-lane-health.mjs";

const timestamp = "2026-09-01T00:00:00.000Z";
const DEPLOYED = "a".repeat(40);
const MAIN = "b".repeat(40);
const HEALTH_ONLY = "c".repeat(40);

function jsonResponse(body) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function compareBody({ aheadBy, files, commitDate = timestamp }) {
  return {
    status: aheadBy > 0 ? "ahead" : "identical",
    ahead_by: aheadBy,
    files: files.map((filename) => ({ filename })),
    base_commit: { commit: { committer: { date: commitDate } } },
  };
}

function successRun(id, event = "push") {
  return {
    id,
    event,
    status: "completed",
    conclusion: "success",
    created_at: timestamp,
    updated_at: timestamp,
    html_url: `https://github.com/Imagine-That-Ai/BurnBar/actions/runs/${id}`,
  };
}

function greenFixture() {
  return {
    generatedAt: timestamp,
    lanes: DEPLOY_LANES.map((definition, index) => ({
      lane: definition.lane,
      runs: [successRun(index + 1)],
    })),
    probes: {
      functionsReady: { ok: true, statusCode: 200 },
      functionsLive: { ok: true, statusCode: 200 },
      cloudRunReady: { ok: true, statusCode: 200 },
    },
  };
}

test("deploy scoreboard contains exactly the Functions and Cloud Run lanes", () => {
  assert.deepEqual(
    DEPLOY_LANES.map((definition) => definition.lane),
    ["deploy-production", "deploy-cloud-run"],
  );
});

test("offline deploy fixture is green only with both successful deploys and probes", async () => {
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(greenFixture()));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 4,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    assert.equal(report.status, "green");
    assert.equal(report.lanes.length, 2);
    assert.ok(report.lanes.every((lane) => lane.red === false));
    assert.match(report.markdown, /Automated path: red opens\/updates/u);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("missing production run and health probe are red with explicit blocker reasons", async () => {
  const report = await collectDeployLaneHealth({
    apiBase: "https://api.github.test",
    fixture: null,
    limit: 2,
    repo: null,
    token: null,
    functionsReady: "https://functions.test/ready",
    functionsLive: "https://functions.test/live",
    cloudRunReady: "https://cloud.test/ready",
  });
  assert.equal(report.status, "red");
  assert.equal(report.lanes.length, 2);
  assert.ok(report.lanes.every((lane) => lane.red === true));
  assert.ok(report.blockers.length >= 2);
  assert.match(report.markdown, /Human queue path:/u);
});

test("a successful deploy without identity metadata is red infrastructure", async () => {
  const fixture = greenFixture();
  fixture.lanes[0].runs = [{
    id: 11,
    event: "push",
    status: "completed",
    conclusion: "success",
  }];
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 4,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const functions = report.lanes.find((lane) => lane.lane === "deploy-production");
    assert.equal(functions.red, true);
    assert.equal(functions.failureClass, "infra");
    assert.equal(functions.reasonCode, "run-metadata-missing");
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("a failed deploy stays red even when public probes are healthy", async () => {
  const fixture = greenFixture();
  fixture.lanes[1].runs = [{
    ...successRun(9),
    conclusion: "failure",
  }, successRun(8)];
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 4,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const cloudRun = report.lanes.find((lane) => lane.lane === "deploy-cloud-run");
    assert.equal(cloudRun.red, true);
    assert.equal(cloudRun.failureClass, "budget");
    assert.equal(cloudRun.reasonCode, "budget-failed");
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("dry-run history is excluded without hiding the latest real deploy", async () => {
  const fixture = greenFixture();
  fixture.lanes[0].runs = [
    {
      ...successRun(50, "2026-09-03T00:00:00.000Z"),
      event: "workflow_dispatch",
      display_title: "release-control/deploy-production/dry-run/v1.0.0",
    },
    {
      ...successRun(49, "2026-09-02T00:00:00.000Z"),
      event: "push",
    },
  ];
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 1,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const functions = report.lanes.find((lane) => lane.lane === "deploy-production");
    assert.equal(functions.red, false);
    assert.equal(functions.run_id, 49);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("live mode queries both deploy workflow events and health endpoints", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(String(url));
    if (String(url).includes("/actions/workflows/")) {
      return new Response(JSON.stringify({ workflow_runs: [{ ...successRun(100), head_sha: DEPLOYED }] }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    if (String(url).endsWith("/commits/main")) return jsonResponse({ sha: MAIN });
    if (String(url).includes(`/compare/${DEPLOYED}...${MAIN}`)) {
      return jsonResponse(compareBody({ aheadBy: 0, files: [] }));
    }
    const body = String(url).includes("functions.test/ready")
      ? { status: "ready", source: { commit: DEPLOYED } }
      : String(url).includes("functions.test/live")
        ? { status: "alive" }
        : { ok: true };
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  try {
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: null,
      limit: 2,
      repo: "Imagine-That-Ai/BurnBar",
      token: "test-token",
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    assert.equal(report.source.mode, "github");
    assert.equal(report.status, "green");
    const functions = report.lanes.find((lane) => lane.lane === "deploy-production");
    assert.equal(functions.freshness.status, "green");
    assert.equal(functions.freshness.anchor, "fleet");
    assert.equal(functions.freshness.behindBy, 0);
    assert.equal(requests.filter((url) => url.includes("/compare/")).length, 1);
    assert.equal(requests.filter((url) => url.includes("event=push")).length, 2);
    assert.equal(requests.filter((url) => url.includes("event=workflow_dispatch")).length, 2);
    const origin = (url) => new URL(url).origin;
    assert.equal(requests.filter((url) => origin(url) === "https://functions.test").length, 2);
    assert.equal(requests.filter((url) => origin(url) === "https://cloud.test").length, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("CLI persists a deploy report and returns non-zero for red fixture", async () => {
  const fixture = greenFixture();
  fixture.probes.cloudRunReady = { ok: false, statusCode: 503, error: "service unavailable" };
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    const outputPath = path.join(tempDirectory, "deploy-lane-health.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await main(["--fixture", fixturePath, "--out", outputPath]);
    assert.equal(report.status, "red");
    assert.equal(JSON.parse(await readFile(outputPath, "utf8")).lanes.length, 2);
  } finally {
    process.exitCode = 0;
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("manual dispatches count as deploy history only when they are existing-tag retries", async () => {
  const fixture = greenFixture();
  fixture.lanes[0].runs = [
    {
      ...successRun(52, "2026-09-04T00:00:00.000Z"),
      event: "workflow_dispatch",
      conclusion: "failure",
      display_title: "release-control/deploy-production/workflow_dispatch/v1.0.0",
    },
    {
      ...successRun(51, "2026-09-03T00:00:00.000Z"),
      event: "workflow_dispatch",
      display_title: "release-control/deploy-production/existing-tag-retry/v1.0.0",
    },
    {
      ...successRun(50, "2026-09-02T00:00:00.000Z"),
      event: "push",
    },
  ];
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 1,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const functions = report.lanes.find((lane) => lane.lane === "deploy-production");
    assert.equal(functions.red, false, "a rejected plain dispatch is not a deployment");
    assert.equal(functions.run_id, 51, "the approved existing-tag retry is the latest deployment");
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("probe-only red keeps consecutive_red at zero because it counts failed deployment runs", async () => {
  const fixture = greenFixture();
  fixture.probes.cloudRunReady = { ok: false, statusCode: 503, error: "service unavailable" };
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 1,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const cloudRun = report.lanes.find((lane) => lane.lane === "deploy-cloud-run");
    assert.equal(cloudRun.red, true);
    assert.equal(cloudRun.status, "infra-failed");
    assert.equal(cloudRun.consecutive_red, 0);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

function productionRun(id, { title, conclusion = "success", event = "push", createdAt = timestamp } = {}) {
  return {
    ...successRun(id, event),
    conclusion,
    created_at: createdAt,
    display_title: title,
  };
}

test("production freshness is red when main carries unshipped Functions changes past the window", () => {
  const freshness = evaluateProductionFreshness({
    fleetDeploy: { run_id: 7, commit: DEPLOYED },
    servingCommit: DEPLOYED,
    comparison: { mainCommit: MAIN, behindBy: 100, files: ["functions/src/index.ts", "README.md"], commitDate: "2026-09-02T00:00:00Z" },
    now: new Date("2026-09-28T00:00:00Z"),
    maxDays: 14,
  });
  assert.equal(freshness.status, "red");
  assert.equal(freshness.reasonCode, "behind-main");
  assert.equal(freshness.behindBy, 100);
  assert.equal(freshness.functionsChanged, true);
  assert.equal(freshness.ageDays, 26);
});

test("production freshness reports but stays green for docs-only drift or a fresh deploy", () => {
  const docsOnly = evaluateProductionFreshness({
    fleetDeploy: { run_id: 7, commit: DEPLOYED },
    comparison: { mainCommit: MAIN, behindBy: 40, files: ["docs/readme.md"], commitDate: "2026-06-18T00:00:00Z" },
    now: new Date("2026-09-28T00:00:00Z"),
  });
  assert.equal(docsOnly.status, "green");
  assert.equal(docsOnly.behindBy, 40);
  assert.equal(docsOnly.functionsChanged, false);
  const recent = evaluateProductionFreshness({
    fleetDeploy: { run_id: 7, commit: DEPLOYED },
    comparison: { mainCommit: MAIN, behindBy: 3, files: ["functions/src/index.ts"], commitDate: "2026-09-25T00:00:00Z" },
    now: new Date("2026-09-28T00:00:00Z"),
  });
  assert.equal(recent.status, "green");
  assert.equal(recent.functionsChanged, true);
});

test("production freshness fails closed on an unknown commit, a failed compare, or a truncated file list", () => {
  assert.equal(evaluateProductionFreshness({}).reasonCode, "deployed-commit-unknown");
  assert.equal(
    evaluateProductionFreshness({ servingCommit: DEPLOYED, comparison: { error: "HTTP 404" } }).reasonCode,
    "github-api-error",
  );
  const truncated = evaluateProductionFreshness({
    servingCommit: DEPLOYED,
    comparison: {
      mainCommit: MAIN,
      behindBy: 900,
      files: Array.from({ length: 300 }, (_, index) => `docs/page-${index}.md`),
      commitDate: "2026-06-18T00:00:00Z",
    },
    now: new Date("2026-09-28T00:00:00Z"),
  });
  assert.equal(truncated.functionsChanged, "unknown");
  assert.equal(truncated.status, "red");
});

test("a break-glass health-only success never anchors fleet freshness", () => {
  const runs = [
    productionRun(3, {
      event: "workflow_dispatch",
      title: `release-control/deploy-production/existing-tag-retry-break-glass/v1.0.40+repair.39/${HEALTH_ONLY}/${MAIN}`,
      createdAt: "2026-09-14T00:00:00Z",
    }),
    productionRun(2, {
      title: `release-control/deploy-production/push/v1.0.40+repair.41/${MAIN}/${MAIN}`,
      conclusion: "failure",
      createdAt: "2026-09-13T00:00:00Z",
    }),
    productionRun(1, {
      event: "workflow_dispatch",
      title: `release-control/deploy-production/existing-tag-retry/v1.0.39/${DEPLOYED}/${MAIN}`,
      createdAt: "2026-06-18T00:00:00Z",
    }),
  ];
  assert.equal(isBreakGlassRun(runs[0]), true);
  assert.equal(deployedCommit(runs[0]), HEALTH_ONLY);
  const fleet = latestFullDeploy(runs);
  assert.equal(fleet.run_id, 1);
  assert.equal(fleet.commit, DEPLOYED, "existing-tag retries deploy the candidate SHA, not the main control SHA");
});

test("offline fixture with a stale fleet turns the Functions lane red and names the blocker", async () => {
  const fixture = greenFixture();
  fixture.lanes[0].runs = [{
    ...successRun(12),
    display_title: `release-control/deploy-production/push/v1.0.40/${DEPLOYED}/${DEPLOYED}`,
  }];
  fixture.freshness = {
    now: "2026-09-28T00:00:00Z",
    servingCommit: HEALTH_ONLY,
    comparison: { mainCommit: MAIN, behindBy: 120, files: ["functions-sync/src/index.ts"], commitDate: "2026-06-18T00:00:00Z" },
  };
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 4,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const functions = report.lanes.find((lane) => lane.lane === "deploy-production");
    assert.equal(report.status, "red");
    assert.equal(functions.reasonCode, "behind-main");
    assert.ok(report.blockers.includes("deploy-production:behind-main"));
    assert.match(report.markdown, /fleet commit `aaaaaaaaaa` \(last full deploy run 12\) is 120 commit\(s\) behind main/u);
    assert.match(report.markdown, /break-glass health-only deploy can move without refreshing the fleet/u);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});
