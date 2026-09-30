# OpenBurnBar event catalog (ops)

Stable `event` field names for log-based SLOs, alerts, and incident correlation. See [OBSERVABILITY.md](../OBSERVABILITY.md) and [runbooks/slos.md](../runbooks/slos.md).

Every Cloud Function is 2nd gen, so its log entries carry `resource.type="cloud_run_revision"`, as do the Cloud Run services. A metric or alert filter on `cloud_function` matches nothing. Log metrics live in [ops-log-metric-definitions.mjs](../../functions/scripts/ops-log-metric-definitions.mjs); `functions/scripts/test-ops-alert-policy-definitions.mjs` enforces the pairing.

| Event | Severity | Alert policy | Runbook |
|-------|----------|--------------|---------|
| `callable_start` | INFO | — | — |
| `callable_success` | INFO | — | — |
| `callable_error` | ERROR | OpenBurnBar Callable error spike | [RUNBOOK.md](../RUNBOOK.md) |
| `circuit_breaker_tripped` | ERROR | OpenBurnBar Circuit breaker open | [oncall.md](../runbooks/oncall.md) |
| `resilience_failure` | ERROR | — (not counted by any metric; inspect it during a Circuit breaker open incident) | [oncall.md](../runbooks/oncall.md) |
| `health_ready_ok` | INFO | — | — |
| `health_ready_failed` | ERROR | OpenBurnBar healthReady degraded | [rollback-automation.md](../runbooks/rollback-automation.md) |
| `scheduled_job_start` | INFO | — | — |
| `scheduled_job_failed` | ERROR | — (no metric counts it; the callable error metric filters on `callable_error` only) | [oncall.md](../runbooks/oncall.md) |
| `provider_secret_erasure_failed` | ERROR | OpenBurnBar Provider credential erasure stuck | [account-erasure.md](../runbooks/account-erasure.md#provider-credential-deletion-and-replacement) |
| `computer_use_budget_evaluated` | INFO | — | [computer-use-budget.md](../runbooks/computer-use-budget.md) |
| `computer_use_budget_evaluate_failed` | ERROR | — | [computer-use-budget.md](../runbooks/computer-use-budget.md) |
| `rollup.rebuild_failed` | ERROR | OpenBurnBar Rollup rebuild breaker open | [RUNBOOK.md](../RUNBOOK.md) |
| `rollup.full_rebuild_circuit_open` | WARNING | OpenBurnBar Rollup rebuild breaker open | [RUNBOOK.md](../RUNBOOK.md) |
| `rollup.delta_drain_capped` | WARNING | OpenBurnBar Rollup delta drain capped | [RUNBOOK.md](../RUNBOOK.md) |

Hosted MCP and billing events: [REMOTE_MCP_RUNBOOK.md](../REMOTE_MCP_RUNBOOK.md), [functions/scripts/ops-alert-policy-definitions.mjs](../../functions/scripts/ops-alert-policy-definitions.mjs).

**Outbound HTTP:** Provider adapters use `providerFetch` (`packages/functions-shared/src/providers/httpClient.ts`). Stripe **webhook** signature verification intentionally uses raw request body handling (not `resilientFetch`) — do not wrap the webhook HTTP handler with outbound fetch resilience.
