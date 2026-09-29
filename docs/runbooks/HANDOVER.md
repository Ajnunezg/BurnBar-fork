# Operator handover

This is the public handover record for OpenBurnBar and its solo-operator
incident policy. It records ownership and verification slots without storing
credentials, recovery codes, private keys, tokens, or personal device
identifiers. Put secrets in the approved provider vaults and link the access
procedure here after a human owner confirms it.

**Operator model:** OpenBurnBar has exactly one human operator, Alberto Nunez
(`@Ajnunezg`). No backup operator exists. Risk AR-008 in
[`docs/governance/RISK_REGISTER.md`](../governance/RISK_REGISTER.md) accepts this
as an organizational constraint; this page states what that means during an
incident.

**Policy status: DRAFT, unsigned.** The policy below was drafted on 2026-09-28
from the committed repository and live GitHub settings. It takes effect only
when Alberto fills the "Human confirmation" column and signs the policy
(`NEEDS ALBERTO` markers below). Until then it is a description of how things
work today, not a commitment.

**Schema status:** every required slot is populated or explicitly `UNSET`.
**Last schema review:** 2026-09-28.

## Required slots

| Slot | Value | Scope | Human confirmation |
| --- | --- | --- | --- |
| Primary operator | Alberto Nunez (@Ajnunezg), sole operator | Release, production, and emergency approval | UNSET |
| Backup operator | UNSET | Independent second-person coverage | UNSET |
| Release approver | Primary operator (solo model) | macOS, iOS, Android, Windows, and Linux release decisions | UNSET |
| Security incident owner | Primary operator (solo model) | Vulnerability triage and disclosure coordination | UNSET |
| Production deploy approver | Primary operator (solo model) | Firebase, GCP, hosted services, and rollback authority | UNSET |
| Emergency communications owner | Primary operator (solo model) | User-facing incident updates and status communication | UNSET |
| Next handover date | UNSET | Human-confirmed transfer checkpoint | UNSET |

`NEEDS ALBERTO`: confirm each populated row (write the confirmation date in the
last column), and either name a backup operator or leave the row `UNSET`. Do not
fill the backup row with a GitHub account that is not an independent human who
has accepted the duty.

## Solo-operator incident policy

### What "solo" means in practice

- Every subsystem lists Alberto as primary and no one as backup
  ([`docs/engineering/OWNERSHIP_AND_BUS_FACTOR.md`](../engineering/OWNERSHIP_AND_BUS_FACTOR.md)).
- Other GitHub accounts with write access, and AI reviewers, are not operators.
  They are not paged, hold no production credentials under this policy, and
  cannot approve a production action. A second account approving a pull request
  is not a second person ([`docs/SOLO_OPERATOR_POLICY.md`](../SOLO_OPERATOR_POLICY.md)).
- Nothing reaches production without the operator. The `production`,
  `release`, and `staging` GitHub environments require `@Ajnunezg` as reviewer
  (read from the GitHub API on 2026-09-28). While the operator is unreachable,
  production is frozen, not unattended.

### How an incident reaches the operator (verified 2026-09-28)

- **CI and ops-lane failures.** `.github/actions/ops-failure-issue` opens a P0
  issue and posts it to the Slack webhook stored in the `OPS_PAGING_SLACK_WEBHOOK`
  repository secret. The `paged:ops` label is added only after Slack returns a
  2xx response; 19 issues carry it, the most recent on 2026-09-28. Delivery to
  Slack is proven. A human reading Slack at that moment is not.
- **Production alert policies.** GCP Cloud Monitoring notifies the channels
  configured in `OPS_ALERT_CHANNELS` ([`oncall.md`](oncall.md)). The last
  committed delivery drill reached one email channel:
  `launch-evidence/alert-channel-verified-alert-delivery-drill-2026-08-01T22-10-58-333Z.json`.
  It is older than the launch gate's 168-hour freshness window and does not
  count as current proof.
- **No recorded pager escalation.** The repository records no phone-paging
  service and no second recipient. An alert that arrives while the operator is
  asleep waits. `NEEDS ALBERTO`: confirm, or record the escalation path that
  exists.

### Response targets

`NEEDS ALBERTO`: replace these proposals with numbers you can actually keep, or
delete them. They are drafts, not commitments.

- P0 (production down, data exposure, runaway spend): acknowledge within 4 hours
  while awake; freeze merges and deploys first, then diagnose.
- P1 (degraded feature, failing deploy lane): acknowledge within 1 business day.
- P2 (SLO warning burn): triage at the next Monday red-run review
  ([`docs/SOLO_OPERATOR_POLICY.md`](../SOLO_OPERATOR_POLICY.md)).

### What the operator does first

1. Stop the bleeding before diagnosing: freeze merges and deploys, and flip the
   relevant Remote Config kill switch (for example `computer_use_kill_switch`,
   listed in [`config/feature-flags.json`](../../config/feature-flags.json)).
2. Follow the severity matrix in [`oncall.md`](oncall.md).
3. Roll back through the path that works today. The fast revision-pin rollback
   failed its 2026-09-23 drill because previous images were pruned
   (`launch-evidence/rollback-drill-2026-09-23.json`), so the working path is a
   source rebuild through `scripts/rollback.sh` (tens of minutes) per
   [`docs/RELEASE_ROLLBACK.md`](../RELEASE_ROLLBACK.md) and
   [`functions-break-glass.md`](functions-break-glass.md). Re-run
   `scripts/ops/rollback-revision.sh --drill` after the next successful deploy.
4. Tell users. Status and incident updates are the operator's job; there is no
   one else to do it.

### Limits this policy does not remove

- **No coverage during absence.** Time to recover is unbounded while the
  operator is unreachable. The controls above keep production frozen and
  switchable; they do not recover it.
- **No independent human review.** Security-sensitive changes merge after the
  required review count is met, but no second human has reviewed them.
- **No restore receipt.** The Firestore restore drill in
  [`firestore-disaster-recovery.md`](firestore-disaster-recovery.md) has no
  committed receipt yet.
- **Credentials live with one person.** If the operator's devices or accounts
  are lost, recovery depends on provider account-recovery flows, not on a
  second holder. `NEEDS ALBERTO`: record, privately, where recovery codes live
  and who may use them if you are incapacitated; do not put them here.

### Planned absence

`NEEDS ALBERTO`: sign or amend.

1. Before an absence longer than 24 hours, do not merge, tag, or deploy in the
   final 24 hours, and leave `main` green.
2. Confirm the kill switches and the Slack paging channel are reachable from the
   device you will carry.
3. Record the absence window in the private operations log.

### When this policy retires

When a second human is named in the Backup operator row, has accepted, holds
least-privilege access recorded in
[`docs/ops/ACCESS_INVENTORY.md`](../ops/ACCESS_INVENTORY.md), and has run the
quarterly restore drill unaided — the definition of done in
[`OWNERSHIP_AND_BUS_FACTOR.md`](../engineering/OWNERSHIP_AND_BUS_FACTOR.md).

### Sign-off

`NEEDS ALBERTO`: sign here by replacing this line with your name, the date, and
the commit you reviewed. An agent must never fill this line.

## Transfer checklist

1. Confirm the primary and backup operators are distinct people.
2. Review the access inventory and replace each applicable `UNSET` with an
   owner or approved group, never with a credential.
3. Run the relevant release, deploy, and rollback verification commands from
   their committed runbooks.
4. Record the date and approver in the private operational log; do not add
   private incident details to this public document.

## Escalation

- A missing owner blocks the corresponding release or production action.
- A suspected credential exposure pauses the affected action and follows
  `SECURITY.md`; do not paste the secret into an issue, PR, or this runbook.
- There is no second human to escalate to. If the primary operator is
  unavailable, production stays frozen behind the environment approval gate;
  leave slots `UNSET` rather than inventing a bypass.
