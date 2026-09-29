# Alert Delivery Drill

A green alert plane proves that alerts are *configured*. Only a drill proves
that one reached a human. BurnBar has two paging routes and each needs its own
receipt. The only input the owner supplies is the Slack webhook URL (and only
when it is set or rotated); everything else is a command below.

| Route | Who pages | Secret / channel | Receipt | Freshness the launch gate demands |
|---|---|---|---|---|
| A. GCP Monitoring | Cloud Monitoring alert policies (errors, uptime, budgets) | Monitoring notification channels (email today) | `launch-evidence/alert-channel-verified.json` | 168 h (`OPENBURNBAR_ALERT_DELIVERY_TTL_HOURS`) |
| B. GitHub ops lanes | `.github/actions/ops-failure-issue` on P0 lanes (deploy-health, deploy-production, nightly-health, ...) | repo secret `OPS_PAGING_SLACK_WEBHOOK` | `launch-evidence/latest-ops-paging-drill.json` | recorded for the launch packet; re-run with route A |

State on 2026-09-28: route A's newest receipt is the 2026-08-01 email drill,
about 58 days old, so `scripts/commercial-launch-gate.mjs` fails
`alertDeliverability` (TTL 168 h, roughly 8x stale). Route B's secret exists
(set 2026-07-17) and the deploy-health lane logs a successful Slack POST on
every red run, but no human has confirmed receipt.

## Route B failure behaviour (since this change)

A P0 lane whose page is due and cannot be delivered (secret unset, non-2xx,
timeout, network error) now **fails the ops job**, labels the issue
`paging:undelivered`, and comments once per streak. A P0 lane with the secret
unset fails even when no page is due, because its next page would be dropped.
The label clears on the next delivered page. Non-P0 lanes do not page.

## Route B: set or rotate the webhook, then drill

1. Create a Slack Incoming Webhook for the channel that wakes the on-call
   (Slack app → Incoming Webhooks → Add New Webhook to Workspace). Keep the URL
   out of chat, tickets, and shell history.
2. Store it (reads the value from stdin, never from argv):

   ```bash
   pbpaste | gh secret set OPS_PAGING_SLACK_WEBHOOK -R Imagine-That-Ai/BurnBar
   ```

   Skip this step if the existing secret should stay; it has been set since
   2026-07-17.
3. Send the drill page:

   ```bash
   gh workflow run ops-paging-drill.yml -R Imagine-That-Ai/BurnBar --ref main
   gh run watch -R Imagine-That-Ai/BurnBar "$(gh run list -R Imagine-That-Ai/BurnBar --workflow ops-paging-drill.yml --limit 1 --json databaseId -q '.[0].databaseId')"
   ```

   The run fails if the secret is unset or Slack rejects the POST. Its summary
   prints the drill id, the webhook fingerprint (sha256 prefix), and the exact
   confirm command.
4. When the page is on your phone, record it from the release machine:

   ```bash
   node scripts/ops/ops-paging-drill.mjs --confirm-delivered \
     --drill-id drill-<12 hex from the page> \
     --run-url https://github.com/Imagine-That-Ai/BurnBar/actions/runs/<run id> \
     --webhook-fingerprint sha256:<16 hex from the run summary> \
     --operator "<your name>"
   ```

   Expected receipt (`launch-evidence/latest-ops-paging-drill.json`, plus a
   dated copy): `schema: openburnbar.ops-paging-drill.v1`, `ok: true`,
   `deliveryConfirmed: true`, `deliveredAt`, `confirmedBy`, `drillId`,
   `runUrl`, `webhookFingerprint`. `launch-evidence/` is gitignored; attach
   it to the launch packet deliberately.

## Route A: GCP Monitoring drill (inside 7 days of the launch gate)

Needs gcloud auth on the release machine with Monitoring and Logging access to
`burnbar`.

```bash
node scripts/ops/run-alert-delivery-drill.mjs
# wait for the "OpenBurnBar alert-delivery drill canary" notification to arrive
node scripts/ops/run-alert-delivery-drill.mjs --confirm-delivered --operator "<your name>" [--evidence-url <screenshot link>]
```

The first command lists the verifiable channels, writes the canary log event,
and records `launch-evidence/alert-delivery-pending.json`. The second writes
`launch-evidence/alert-channel-verified.json` with one confirmed entry per
required channel. Run `node scripts/commercial-launch-gate.mjs` within 168
hours of the confirmation; `checks.alertDeliverability.ok` must be `true`.

To add Slack as a Monitoring channel as well, create the channel in Cloud
Monitoring, attach it to the policies in
`functions/scripts/ops-alert-policy-definitions.mjs`, and re-run this drill so
the new channel carries its own confirmation.
