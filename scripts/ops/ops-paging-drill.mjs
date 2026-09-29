#!/usr/bin/env node
/**
 * Ops paging drill for the GitHub ops lanes' Slack route (OPS_PAGING_SLACK_WEBHOOK).
 *
 * The scheduled ops lanes page through .github/actions/ops-failure-issue, but a
 * 2xx from Slack proves only that the webhook accepted a POST. This drill sends
 * one clearly labelled test page and records a HUMAN confirmation that it
 * arrived, mirroring scripts/ops/run-alert-delivery-drill.mjs for the GCP side.
 *
 *   send (CI, .github/workflows/ops-paging-drill.yml):
 *     OPS_PAGING_SLACK_WEBHOOK=<secret> node scripts/ops/ops-paging-drill.mjs
 *     Fails when the webhook is unset or answers non-2xx. Prints the drill id
 *     and a sha256 fingerprint of the webhook URL, never the URL.
 *   confirm (release machine, after the page arrived on a phone):
 *     node scripts/ops/ops-paging-drill.mjs --confirm-delivered --drill-id <id> \
 *       --run-url <actions run URL> --operator <name> [--webhook-fingerprint <fp>] [--evidence-url <url>]
 *     Writes launch-evidence/ops-paging-drill-<timestamp>.json and
 *     launch-evidence/latest-ops-paging-drill.json.
 */
import { createHash, randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const DRILL_SCHEMA = "openburnbar.ops-paging-drill.v1";
const DRILL_ID = /^drill-[0-9a-f]{12}$/u;
const RUN_URL = /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/actions\/runs\/\d+(?:\/attempts\/\d+)?$/u;

export function webhookFingerprint(webhook) {
  return `sha256:${createHash("sha256").update(String(webhook)).digest("hex").slice(0, 16)}`;
}

export function newDrillId() {
  return `drill-${randomUUID().replaceAll("-", "").slice(0, 12)}`;
}

export function buildDrillMessage({ drillId, runUrl }) {
  return [
    `🧪 *OpenBurnBar ops paging DRILL ${drillId}* — not an incident, no action on production.`,
    runUrl ? `Run: ${runUrl}` : null,
    `If this reached your phone, record it: node scripts/ops/ops-paging-drill.mjs --confirm-delivered --drill-id ${drillId} --run-url <run> --operator <name>`,
  ].filter(Boolean).join("\n");
}

export async function sendDrill({ webhook, drillId, runUrl, fetchImpl = fetch }) {
  if (!webhook) {
    return { ok: false, error: "OPS_PAGING_SLACK_WEBHOOK is not configured; ops lanes cannot page anyone." };
  }
  let response;
  try {
    response = await fetchImpl(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: buildDrillMessage({ drillId, runUrl }) }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (error) {
    return { ok: false, error: `webhook request failed (${error?.name || "Error"})` };
  }
  if (!response.ok) return { ok: false, status: response.status, error: `webhook returned HTTP ${response.status}` };
  return { ok: true, status: response.status, drillId, webhookFingerprint: webhookFingerprint(webhook) };
}

export function buildConfirmation({ drillId, runUrl, operator, webhookFingerprint: fingerprint = null, evidenceUrl = null, now = new Date() }) {
  const problems = [];
  if (!DRILL_ID.test(drillId || "")) problems.push("--drill-id must be the drill-<12 hex> id the page showed");
  if (!RUN_URL.test(runUrl || "")) problems.push("--run-url must be the https://github.com/<owner>/<repo>/actions/runs/<id> run that sent the page");
  if (!operator || !operator.trim()) problems.push("--operator is required (who received the page)");
  if (fingerprint !== null && !/^sha256:[0-9a-f]{16}$/u.test(fingerprint)) problems.push("--webhook-fingerprint must be sha256:<16 hex> from the run summary");
  if (problems.length > 0) return { ok: false, problems };
  const deliveredAt = now.toISOString();
  return {
    ok: true,
    receipt: {
      schema: DRILL_SCHEMA,
      schemaVersion: 1,
      generatedAt: deliveredAt,
      ok: true,
      route: "github-ops-lanes/OPS_PAGING_SLACK_WEBHOOK",
      drillId,
      runUrl,
      webhookFingerprint: fingerprint,
      deliveryConfirmed: true,
      deliveredAt,
      confirmedBy: operator.trim(),
      evidenceUrl: evidenceUrl || null,
    },
  };
}

function parseArgs(argv) {
  const args = { confirm: false };
  const valueFlags = new Map([
    ["--drill-id", "drillId"],
    ["--run-url", "runUrl"],
    ["--operator", "operator"],
    ["--webhook-fingerprint", "webhookFingerprint"],
    ["--evidence-url", "evidenceUrl"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === "--confirm-delivered") args.confirm = true;
    else if (valueFlags.has(flag)) {
      if (index + 1 >= argv.length) throw new Error(`${flag} requires a value`);
      args[valueFlags.get(flag)] = argv[++index];
    } else throw new Error(`unknown argument: ${flag}`);
  }
  return args;
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const args = parseArgs(argv);
  if (args.confirm) {
    const result = buildConfirmation(args);
    if (!result.ok) {
      for (const problem of result.problems) console.error(`FAIL: ${problem}`);
      return 2;
    }
    const directory = env.OPENBURNBAR_OPS_PAGING_DRILL_DIR || "launch-evidence";
    mkdirSync(directory, { recursive: true });
    const stamp = result.receipt.deliveredAt.replace(/[:.]/gu, "-");
    const body = `${JSON.stringify(result.receipt, null, 2)}\n`;
    writeFileSync(join(directory, `ops-paging-drill-${stamp}.json`), body);
    writeFileSync(join(directory, "latest-ops-paging-drill.json"), body);
    console.log(`Recorded human-confirmed ops paging drill ${result.receipt.drillId} in ${directory}/latest-ops-paging-drill.json`);
    return 0;
  }
  const drillId = newDrillId();
  const runUrl = env.GITHUB_SERVER_URL && env.GITHUB_REPOSITORY && env.GITHUB_RUN_ID
    ? `${env.GITHUB_SERVER_URL}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}`
    : null;
  const sent = await sendDrill({ webhook: env.OPS_PAGING_SLACK_WEBHOOK, drillId, runUrl });
  if (!sent.ok) {
    console.error(`::error::Ops paging drill not delivered: ${sent.error}`);
    return 1;
  }
  const summary = [
    "## Ops paging drill sent",
    "",
    `- Drill id: \`${drillId}\``,
    `- Webhook fingerprint: \`${sent.webhookFingerprint}\` (sha256 prefix; the URL is never printed)`,
    `- Slack answered HTTP ${sent.status}. That proves acceptance, not that a human saw it.`,
    "",
    "Once the page is on your phone, record it from the release machine:",
    "",
    "```bash",
    `node scripts/ops/ops-paging-drill.mjs --confirm-delivered --drill-id ${drillId} --run-url ${runUrl ?? "<run URL>"} --webhook-fingerprint ${sent.webhookFingerprint} --operator "<name>"`,
    "```",
  ].join("\n");
  console.log(summary);
  if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, `${summary}\n`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().then(
    (code) => { process.exitCode = code; },
    (error) => {
      console.error(`FAIL: ${error.message}`);
      process.exitCode = 2;
    },
  );
}
