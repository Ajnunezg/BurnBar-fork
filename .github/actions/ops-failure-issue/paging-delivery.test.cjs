// Undelivered paging must be a loud failure of the ops job, never a warning.
// Covers the pure decision (evaluatePagingDelivery) and pins how action.yml
// applies it, including a syntax check of the github-script body.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const {
  P0_LABEL,
  PAGED_LABEL,
  UNDELIVERED_LABEL,
  evaluatePagingDelivery,
} = require("./escalation.cjs");

const ACTION_YML = fs.readFileSync(path.join(__dirname, "action.yml"), "utf8");
const WEBHOOK_SHAPE = /hooks\.slack\.com|https?:\/\//u;

test("a due page with no webhook fails the job, labels the issue, and comments once", () => {
  const first = evaluatePagingDelivery({ mode: "open", labels: [P0_LABEL], webhookConfigured: false, pageDue: true });
  assert.equal(first.failJob, true);
  assert.equal(first.reason, "webhook-unset");
  assert.equal(first.addUndeliveredLabel, true);
  assert.match(first.comment, /^Paging NOT delivered: .*OPS_PAGING_SLACK_WEBHOOK/u);
  const streak = evaluatePagingDelivery({
    mode: "open",
    labels: [P0_LABEL, UNDELIVERED_LABEL],
    webhookConfigured: false,
    pageDue: true,
  });
  assert.equal(streak.failJob, true, "every run of the streak stays red");
  assert.equal(streak.comment, null, "only the first failure of a streak comments");
  assert.equal(streak.addUndeliveredLabel, false);
  assert.match(streak.detail, /OPS_PAGING_SLACK_WEBHOOK/u);
});

test("an already-paged P0 lane without a webhook still fails: its next page would be dropped", () => {
  const verdict = evaluatePagingDelivery({
    mode: "open",
    labels: [P0_LABEL, PAGED_LABEL],
    webhookConfigured: false,
    pageDue: false,
  });
  assert.equal(verdict.failJob, true);
  assert.match(verdict.detail, /next P0 page for this lane would be dropped/u);
});

test("non-2xx and network failures fail the job and never echo the webhook", () => {
  const http = evaluatePagingDelivery({
    mode: "open",
    labels: [{ name: P0_LABEL }],
    webhookConfigured: true,
    pageDue: true,
    delivery: { ok: false, status: 404 },
  });
  assert.equal(http.failJob, true);
  assert.equal(http.reason, "http-404");
  const network = evaluatePagingDelivery({
    mode: "open",
    labels: [P0_LABEL],
    webhookConfigured: true,
    pageDue: true,
    delivery: { ok: false, status: null, errorName: "TimeoutError" },
  });
  assert.equal(network.reason, "post-failed");
  assert.match(network.detail, /TimeoutError/u);
  for (const verdict of [http, network]) {
    assert.doesNotMatch(`${verdict.detail} ${verdict.comment}`, WEBHOOK_SHAPE);
  }
});

test("a delivered page passes and clears a previous undelivered streak", () => {
  const cleared = evaluatePagingDelivery({
    mode: "open",
    labels: [P0_LABEL, UNDELIVERED_LABEL],
    webhookConfigured: true,
    pageDue: true,
    delivery: { ok: true, status: 200 },
  });
  assert.deepEqual(
    { failJob: cleared.failJob, reason: cleared.reason, remove: cleared.removeUndeliveredLabel, comment: cleared.comment },
    { failJob: false, reason: "delivered", remove: true, comment: null },
  );
  const quiet = evaluatePagingDelivery({ mode: "open", labels: [P0_LABEL, PAGED_LABEL], webhookConfigured: true, pageDue: false });
  assert.equal(quiet.failJob, false);
  assert.equal(quiet.reason, "no-page-due");
});

test("close mode and non-P0 lanes never fail on paging", () => {
  for (const params of [
    { mode: "close", labels: [P0_LABEL], webhookConfigured: false, pageDue: false },
    { mode: "open", labels: ["P2 - Medium"], webhookConfigured: false, pageDue: false },
  ]) {
    const verdict = evaluatePagingDelivery(params);
    assert.equal(verdict.failJob, false);
    assert.equal(verdict.reason, "not-applicable");
  }
});

test("action.yml applies the verdict loudly and no longer documents a silent skip", () => {
  assert.doesNotMatch(ACTION_YML, /paging is silently skipped/u);
  assert.doesNotMatch(ACTION_YML, /core\.warning\([^)]*OPS_PAGING_SLACK_WEBHOOK is not configured/u);
  const call = ACTION_YML.indexOf("const verdict = evaluatePagingDelivery({");
  assert.ok(call > 0, "the page path must consult evaluatePagingDelivery");
  const body = ACTION_YML.slice(call);
  for (const marker of [
    "if (verdict.removeUndeliveredLabel)",
    "labels: [UNDELIVERED_LABEL]",
    "if (verdict.comment)",
    "if (verdict.failJob)",
    "core.setFailed(",
  ]) {
    assert.ok(body.includes(marker), `action.yml must apply ${marker}`);
  }
  assert.match(ACTION_YML, /errorName: oneLine\(pageError\?\.name, 'Error'\)/u, "only the error class may reach the issue text");
});

test("the github-script body is valid JavaScript", () => {
  const start = ACTION_YML.indexOf("        script: |\n");
  assert.ok(start > 0);
  const script = ACTION_YML.slice(start + "        script: |\n".length)
    .split("\n")
    .map((line) => line.replace(/^ {10}/u, ""))
    .join("\n");
  // github-script wraps the body in an async function; compile it the same way.
  assert.doesNotThrow(() => new vm.Script(`(async () => {\n${script}\n})`));
});

// Execute the real github-script body against in-memory GitHub/Slack fakes.
function scriptBody() {
  const start = ACTION_YML.indexOf("        script: |\n");
  return ACTION_YML.slice(start + "        script: |\n".length)
    .split("\n")
    .map((line) => line.replace(/^ {10}/u, ""))
    .join("\n");
}

async function runAction({ issues = [], webhook = "", webhookStatus = 200, labels = "P0 - Critical,area: infra", repage = "false" }) {
  const calls = { failed: [], notices: [], comments: [], addedLabels: [], removedLabels: [], created: [], posts: 0 };
  const github = {
    paginate: async () => issues,
    rest: {
      issues: {
        listForRepo: () => {},
        getLabel: async () => ({}),
        createLabel: async () => ({}),
        create: async ({ labels: created }) => {
          calls.created.push(created);
          return { data: { number: 77, created_at: new Date().toISOString() } };
        },
        createComment: async ({ issue_number: number, body }) => { calls.comments.push({ number, body }); },
        addLabels: async ({ labels: added }) => { calls.addedLabels.push(...added); },
        removeLabel: async ({ name }) => { calls.removedLabels.push(name); },
        update: async () => {},
      },
    },
  };
  const core = {
    info: () => {},
    notice: (message) => calls.notices.push(message),
    warning: () => {},
    setFailed: (message) => calls.failed.push(message),
  };
  const context = {
    repo: { owner: "Imagine-That-Ai", repo: "BurnBar" },
    runId: 4242,
    serverUrl: "https://github.com",
    workflow: "Scheduled deploy lane health",
    ref: "refs/heads/main",
  };
  const env = {
    GITHUB_WORKSPACE: path.resolve(__dirname, "..", "..", ".."),
    OPS_MODE: "open",
    OPS_LANE: "deploy-health",
    OPS_TITLE_PREFIX: "Scheduled deploy lane health is red",
    OPS_SUMMARY: "red",
    OPS_DETAILS: "",
    OPS_LABELS: labels,
    OPS_PAGING_SLACK_WEBHOOK: webhook,
    OPS_REPAGE_UNTIL_GREEN: repage,
  };
  const fetchFake = async () => {
    calls.posts += 1;
    return new Response("ok", { status: webhookStatus });
  };
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const run = new AsyncFunction("github", "context", "core", "require", "process", "fetch", scriptBody());
  await run(github, context, core, require, { env, cwd: () => env.GITHUB_WORKSPACE }, fetchFake);
  return calls;
}

test("executed action: a new P0 issue with no webhook fails the job and records it on the issue", async () => {
  const calls = await runAction({ webhook: "" });
  assert.equal(calls.created.length, 1, "the issue is still created first");
  assert.equal(calls.posts, 0);
  assert.equal(calls.failed.length, 1);
  assert.match(calls.failed[0], /paging not delivered \(webhook-unset\)/u);
  assert.ok(calls.addedLabels.includes(UNDELIVERED_LABEL));
  assert.ok(calls.comments.some(({ body }) => body.startsWith("Paging NOT delivered:")));
});

test("executed action: repage-until-green with a failing webhook fails the job", async () => {
  const standing = [{
    number: 2491,
    created_at: new Date(Date.now() - 3_600_000).toISOString(),
    labels: [{ name: "lane:deploy-health" }, { name: P0_LABEL }, { name: PAGED_LABEL }, { name: "failures:27" }],
  }];
  const calls = await runAction({ issues: standing, webhook: "https://hooks.example.invalid/x", webhookStatus: 500, repage: "true" });
  assert.equal(calls.posts, 1);
  assert.equal(calls.failed.length, 1);
  assert.match(calls.failed[0], /\(http-500\)/u);
  assert.ok(calls.addedLabels.includes(UNDELIVERED_LABEL));
  for (const { body } of calls.comments) assert.doesNotMatch(body, /hooks\.example\.invalid/u);
});

test("executed action: a delivered page stays green and clears the undelivered streak", async () => {
  const standing = [{
    number: 2491,
    created_at: new Date(Date.now() - 3_600_000).toISOString(),
    labels: [{ name: "lane:deploy-health" }, { name: P0_LABEL }, { name: PAGED_LABEL }, { name: UNDELIVERED_LABEL }],
  }];
  const calls = await runAction({ issues: standing, webhook: "https://hooks.example.invalid/x", webhookStatus: 200, repage: "true" });
  assert.equal(calls.failed.length, 0);
  assert.ok(calls.removedLabels.includes(UNDELIVERED_LABEL));
  assert.ok(calls.notices.some((message) => message.includes("re-paged P0 issue #2491")));
});

test("executed action: a non-P0 lane without a webhook never fails on paging", async () => {
  const calls = await runAction({ webhook: "", labels: "P2 - Medium,area: infra" });
  assert.equal(calls.failed.length, 0);
  assert.equal(calls.addedLabels.includes(UNDELIVERED_LABEL), false);
});
