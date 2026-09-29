#!/usr/bin/env bash
# Fail closed if security-sensitive paths lose explicit CODEOWNERS coverage.
#
# Every required rule must exist with a security owner AND match at least one
# tracked path, every tracked file a required rule matches must end on a
# required rule (not the blanket `*`), and no CODEOWNERS rule may be dead. A
# rule naming a moved file protects nothing, so a dead path fails the gate.
#
# Test hooks: CODEOWNERS_REPO_ROOT (tree whose `git ls-files` is checked) and
# CODEOWNERS_FILE (CODEOWNERS to read, relative to that root or absolute).
set -euo pipefail
cd "${CODEOWNERS_REPO_ROOT:-$(dirname "$0")/../..}"

python3 <<'PY'
from __future__ import annotations

import fnmatch
import os
import subprocess
import sys
from pathlib import Path

CODEOWNERS = Path(os.environ.get("CODEOWNERS_FILE", ".github/CODEOWNERS"))
SECURITY_OWNERS = {"@Ajnunezg"}

REQUIRED_RULES = [
    ".github/CODEOWNERS",
    ".github/workflows/",
    ".github/actions/",
    "packages/functions-shared/src/",
    "packages/functions-shared/src/auth.ts",
    "packages/functions-shared/src/appCheckAttestation.ts",
    "packages/functions-shared/src/ssrfGuard.ts",
    "packages/functions-shared/src/logging.ts",
    "packages/functions-shared/src/secrets.ts",
    "packages/functions-shared/src/guards.ts",
    "packages/functions-shared/src/resilienceHelpers.ts",
    "packages/functions-shared/src/providers/httpClient.ts",
    "packages/functions-shared/src/providerAccountIsolation.ts",
    "packages/functions-shared/src/publicHttpSecurityHeaders.ts",
    "packages/functions-shared/src/remoteMcpGrant.ts",
    "packages/functions-shared/src/accountDeletion*.ts",
    "packages/functions-shared/src/accountErasure*.ts",
    "packages/functions-shared/src/hermesGateway*.ts",
    "packages/functions-shared/src/validation/",
    "packages/functions-shared/src/callables/publicRateLimit.ts",
    "packages/functions-shared/src/callables/callableRatePolicy.ts",
    "packages/functions-shared/src/callables/highRiskOwnerAction.ts",
    "packages/functions-shared/src/callables/computerUseSecurity*.ts",
    "packages/functions-shared/src/shared/validators.ts",
    "packages/functions-shared/src/shared/auditLog.ts",
    "packages/functions-shared/src/shared/entitlementWriteGuards.ts",
    "packages/functions-shared/src/shared/linuxAppCheckHosts.ts",
    "packages/functions-shared/src/shared/stripeTopUpReversal.ts",
    "functions/src/security/",
    "functions/src/domains/compliance/",
    "functions/src/domains/audit/auditLog.ts",
    "functions/src/domains/lifecycle/accountDeletionReconciler.ts",
    "functions/src/hermesGatewayComplianceSurface.ts",
    "functions-identity/src/",
    "functions-identity/src/domains/app-check/",
    "functions-identity/src/domains/identity/",
    "functions-identity/src/domains/billing/",
    "functions-identity/src/domains/devices/",
    "functions-identity/src/callables/stripe*",
    "functions-identity/src/shared/stripe*",
    "functions-sync/src/computerUseRemoteConfig.ts",
    "functions-sync/src/domains/computer-use/computerUseSecurity.ts",
    "functions-sync/src/callables/agentGrant*.ts",
    "functions-sync/src/callables/irohControllerRouteSecurity.ts",
    "functions-media/src/callables/hermesGatewayCrypto.ts",
    "functions-media/src/hermesGatewaySignalPrekeys.ts",
    "functions-media/src/domains/hermes/hermesGateway.ts",
    "services/hosted-mcp/src/auth.ts",
    "services/hermes-realtime-relay/src/auth.ts",
    "AgentLens/Services/DataStore/DatabaseEncryptionService.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/",
    "OpenBurnBarCore/Sources/OpenBurnBarVaultModels/",
    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/",
    "OpenBurnBarCore/Sources/OpenBurnBarSignalSessionTransport/",
    "packages/libsignal-bridge/",
    "packages/libsignal-protocol/",
    "packages/e2ee-backend-policy/",
    "packages/signal-envelope-contracts/",
    "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift",
    "scripts/ci/",
    "scripts/ci/check-privacy-invariants.mjs",
    "scripts/ci/prepare-firebase-tools.sh",
    "scripts/ci/write-firebase-hosting-ci-config.mjs",
    "scripts/ci/verify-production-deploy-auth.sh",
    "scripts/ci/verify-production-deploy-auth.test.sh",
    "Vendor/libsignal",
    "Vendor/GRDB-SQLCipher/",
    "budgets/",
    "docs/security/",
    "firebase.json",
    ".firebaserc",
    ".github/workflows/deploy-hosting.yml",
    ".github/workflows/deploy-production.yml",
    ".github/workflows/deploy-firestore.yml",
    "website/package.json",
    "apps/console/package.json",
    "functions/package.json",
    "functions/package-lock.json",
    "functions-identity/package.json",
    "functions-identity/package-lock.json",
    "functions-sync/package.json",
    "functions-sync/package-lock.json",
    "functions-media/package.json",
    "functions-media/package-lock.json",
    "packages/functions-shared/package.json",
    "packages/functions-shared/package-lock.json",
    "firestore.rules",
    "firestore.indexes.json",
    "storage.rules",
    "project.yml",
    ".gitleaks.toml",
    ".gitleaksignore",
]

# Spot checks that the most specific rule wins for representative files. Each
# path must be tracked, so a stale entry fails instead of passing blind.
EXPECTED_FINAL_RULES = {
    ".github/CODEOWNERS": ".github/CODEOWNERS",
    ".github/workflows/security-pr.yml": ".github/workflows/",
    "functions/src/security/endpointAuthorizationMatrix.ts": "functions/src/security/",
    "functions/src/domains/compliance/dataExport.ts": "functions/src/domains/compliance/",
    "packages/functions-shared/src/auth.ts": "packages/functions-shared/src/auth.ts",
    "packages/functions-shared/src/types/legacy/providers.ts": "packages/functions-shared/src/",
    "packages/functions-shared/src/accountDeletion.ts": "packages/functions-shared/src/accountDeletion*.ts",
    "functions-identity/src/callables/stripeTopUps.ts": "functions-identity/src/callables/stripe*",
    "functions-identity/src/domains/billing/stripe.ts": "functions-identity/src/domains/billing/",
    "functions-identity/src/teamKeyEnvelopes.ts": "functions-identity/src/",
    "scripts/ci/verify-ops-readiness.sh": "scripts/ci/",
    "scripts/ci/prepare-firebase-tools.sh": "scripts/ci/prepare-firebase-tools.sh",
    "scripts/ci/write-firebase-hosting-ci-config.mjs": "scripts/ci/write-firebase-hosting-ci-config.mjs",
    "scripts/ci/verify-production-deploy-auth.sh": "scripts/ci/verify-production-deploy-auth.sh",
    "scripts/ci/verify-production-deploy-auth.test.sh": "scripts/ci/verify-production-deploy-auth.test.sh",
    "Vendor/libsignal": "Vendor/libsignal",
    "Vendor/GRDB-SQLCipher/Package.swift": "Vendor/GRDB-SQLCipher/",
    "firebase.json": "firebase.json",
    ".firebaserc": ".firebaserc",
    ".github/workflows/deploy-hosting.yml": ".github/workflows/deploy-hosting.yml",
    ".github/workflows/deploy-production.yml": ".github/workflows/deploy-production.yml",
    ".github/workflows/deploy-firestore.yml": ".github/workflows/deploy-firestore.yml",
    "website/package.json": "website/package.json",
    "apps/console/package.json": "apps/console/package.json",
    "functions/package.json": "functions/package.json",
    "functions/package-lock.json": "functions/package-lock.json",
    "firestore.rules": "firestore.rules",
    "project.yml": "project.yml",
    ".gitleaks.toml": ".gitleaks.toml",
    ".gitleaksignore": ".gitleaksignore",
    "AgentLens/Services/DataStore/DatabaseEncryptionService.swift": "AgentLens/Services/DataStore/DatabaseEncryptionService.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedSocketTrust.swift": "OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/",
    "OpenBurnBarCore/Sources/OpenBurnBarVaultModels/CloudVaultCrypto.swift": "OpenBurnBarCore/Sources/OpenBurnBarVaultModels/",
    "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift": "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift",
}


class Rule:
    def __init__(self, line_no: int, pattern: str, owners: list[str]) -> None:
        self.line_no = line_no
        self.pattern = pattern
        self.owners = owners


def parse_codeowners(path: Path) -> list[Rule]:
    rules: list[Rule] = []
    if not path.is_file():
        raise SystemExit(f"FAIL: {path} is missing")

    for line_no, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            raise SystemExit(f"FAIL: {path}:{line_no} has a pattern without an owner")
        rules.append(Rule(line_no=line_no, pattern=parts[0], owners=parts[1:]))
    return rules


def rule_matches_path(pattern: str, repo_path: str) -> bool:
    normalized = pattern.lstrip("/")
    if normalized.endswith("/"):
        directory = normalized.rstrip("/")
        return repo_path.startswith(directory + "/")
    if any(ch in normalized for ch in "*?"):
        return fnmatch.fnmatchcase(repo_path, normalized)
    # A bare path owns the file itself or, for a directory, everything below it.
    return repo_path == normalized or repo_path.startswith(normalized + "/")


def tracked_paths() -> list[str]:
    listed = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True, text=True).stdout
    paths = [path for path in listed.split("\0") if path]
    if not paths:
        raise SystemExit("FAIL: git ls-files returned no tracked paths")
    return paths


def final_rule(repo_path: str) -> Rule | None:
    matching = [rule for rule in rules if rule_matches_path(rule.pattern, repo_path)]
    return matching[-1] if matching else None


rules = parse_codeowners(CODEOWNERS)
tracked = tracked_paths()
tracked_set = set(tracked)
required_set = set(REQUIRED_RULES)
failures: list[str] = []

# No dead rules anywhere: a pattern that matches nothing is routing nobody.
for rule in rules:
    if not any(rule_matches_path(rule.pattern, path) for path in tracked):
        failures.append(
            f"CODEOWNERS line {rule.line_no} rule {rule.pattern!r} matches no tracked path "
            "(moved or deleted?); repoint it to the current path"
        )

for required in REQUIRED_RULES:
    matching_rules = [rule for rule in rules if rule.pattern == required]
    if not matching_rules:
        failures.append(f"missing explicit CODEOWNERS rule for {required}")
        continue
    if not any(SECURITY_OWNERS.issubset(set(rule.owners)) for rule in matching_rules):
        owners = ", ".join(" ".join(rule.owners) for rule in matching_rules)
        failures.append(f"{required} is present but lacks required security/platform owner(s): {owners}")
    covered = [path for path in tracked if rule_matches_path(required, path)]
    if not covered:
        failures.append(f"required rule {required} matches no tracked path; update REQUIRED_RULES and CODEOWNERS")
        continue
    # Every file the required rule covers must end on a required (specific)
    # rule, never on the blanket default or another catch-all appended later.
    for path in covered:
        winner = final_rule(path)
        if winner is None or winner.pattern not in required_set:
            pattern = winner.pattern if winner else None
            failures.append(
                f"{path} (required via {required}) resolves to non-security rule {pattern!r}; "
                "keep security-sensitive rules last"
            )
            break

for path, expected_pattern in EXPECTED_FINAL_RULES.items():
    if path not in tracked_set:
        failures.append(f"spot-check path {path} is not tracked; update EXPECTED_FINAL_RULES")
        continue
    winner = final_rule(path)
    if winner is None:
        failures.append(f"{path} has no CODEOWNERS match")
        continue
    if winner.pattern != expected_pattern:
        failures.append(
            f"{path} final owner rule is {winner.pattern!r} on line {winner.line_no}; "
            f"expected {expected_pattern!r}. Keep security-sensitive rules last."
        )
    if not SECURITY_OWNERS.issubset(set(winner.owners)):
        failures.append(
            f"{path} final rule {winner.pattern!r} lacks required security/platform owner(s): "
            + " ".join(winner.owners)
        )

if failures:
    print("FAIL: security-sensitive CODEOWNERS coverage drifted:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

print(
    f"PASS: {len(REQUIRED_RULES)} security-sensitive CODEOWNERS rules are explicit, live and final-match "
    f"effective; {len(rules)} rules checked against {len(tracked)} tracked paths."
)
PY
