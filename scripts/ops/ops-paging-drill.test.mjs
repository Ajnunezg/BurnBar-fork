#!/usr/bin/env node
/**
 * Offline tests for scripts/ops/ops-paging-drill.mjs against a local fake
 * Slack webhook. No real webhook is ever contacted.
 * Run: node --test scripts/ops/ops-paging-drill.test.mjs
 */
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  DRILL_SCHEMA,
  buildConfirmation,
  buildDrillMessage,
  main,
  sendDrill,
  webhookFingerprint,
} from "./ops-paging-drill.mjs";

const RUN_URL = "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/123456";

async function withWebhook(status, run) {
  const received = [];
  const server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      received.push(JSON.parse(body));
      response.writeHead(status).end("ok");
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}/services/T000/B000/secret-path`;
  try {
    return await run(url, received);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test("send posts one labelled drill page and reports only a fingerprint", async () => {
  await withWebhook(200, async (url, received) => {
    const sent = await sendDrill({ webhook: url, drillId: "drill-0123456789ab", runUrl: RUN_URL });
    assert.equal(sent.ok, true);
    assert.equal(sent.webhookFingerprint, webhookFingerprint(url));
    assert.match(sent.webhookFingerprint, /^sha256:[0-9a-f]{16}$/u);
    assert.equal(received.length, 1);
    assert.match(received[0].text, /ops paging DRILL drill-0123456789ab/u);
    assert.match(received[0].text, /not an incident/u);
    assert.ok(received[0].text.split("\n").includes(`Run: ${RUN_URL}`));
  });
});

test("send fails loudly when the webhook is unset or answers non-2xx", async () => {
  assert.equal((await sendDrill({ webhook: "", drillId: "drill-0123456789ab" })).ok, false);
  await withWebhook(404, async (url) => {
    const sent = await sendDrill({ webhook: url, drillId: "drill-0123456789ab" });
    assert.equal(sent.ok, false);
    assert.equal(sent.status, 404);
    assert.doesNotMatch(sent.error, /secret-path/u);
  });
  const offline = await sendDrill({
    webhook: "http://127.0.0.1:9/services/T000/B000/secret-path",
    drillId: "drill-0123456789ab",
    fetchImpl: async () => { throw new TypeError("fetch failed http://127.0.0.1:9/services/T000/B000/secret-path"); },
  });
  assert.equal(offline.ok, false);
  assert.doesNotMatch(offline.error, /secret-path/u, "network errors must not echo the webhook URL");
});

test("CLI send exits non-zero without a webhook and never prints one", async () => {
  const errors = [];
  const original = console.error;
  console.error = (line) => errors.push(String(line));
  try {
    assert.equal(await main([], {}), 1);
  } finally {
    console.error = original;
  }
  assert.match(errors.join("\n"), /::error::Ops paging drill not delivered: OPS_PAGING_SLACK_WEBHOOK is not configured/u);
});

test("confirmation requires a real drill id, run URL, and operator", () => {
  const bad = buildConfirmation({ drillId: "drill-1", runUrl: "https://example.com", operator: "" });
  assert.equal(bad.ok, false);
  assert.equal(bad.problems.length, 3);
  const good = buildConfirmation({
    drillId: "drill-0123456789ab",
    runUrl: RUN_URL,
    operator: "Alberto",
    webhookFingerprint: "sha256:0123456789abcdef",
    now: new Date("2026-09-28T12:00:00Z"),
  });
  assert.equal(good.ok, true);
  assert.equal(good.receipt.schema, DRILL_SCHEMA);
  assert.equal(good.receipt.deliveredAt, "2026-09-28T12:00:00.000Z");
  assert.equal(good.receipt.deliveryConfirmed, true);
});

test("CLI confirm writes a dated receipt and the latest pointer", async () => {
  const directory = mkdtempSync(join(tmpdir(), "ops-paging-drill-"));
  try {
    const code = await main(
      ["--confirm-delivered", "--drill-id", "drill-0123456789ab", "--run-url", RUN_URL, "--operator", "Alberto"],
      { OPENBURNBAR_OPS_PAGING_DRILL_DIR: directory },
    );
    assert.equal(code, 0);
    const files = readdirSync(directory).sort();
    assert.equal(files.length, 2);
    assert.ok(files.includes("latest-ops-paging-drill.json"));
    const latest = JSON.parse(readFileSync(join(directory, "latest-ops-paging-drill.json"), "utf8"));
    assert.equal(latest.ok, true);
    assert.equal(latest.drillId, "drill-0123456789ab");
    assert.equal(latest.confirmedBy, "Alberto");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("the drill message tells the receiver how to confirm", () => {
  const text = buildDrillMessage({ drillId: "drill-0123456789ab", runUrl: RUN_URL });
  assert.match(text, /--confirm-delivered --drill-id drill-0123456789ab/u);
});
