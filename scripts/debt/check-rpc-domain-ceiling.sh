#!/usr/bin/env bash
# Daemon RPC domain ceiling (diligence 2026-09-26, hidden rewrite risk #2).
#
# The daemon's socket RPC surface is partitioned into handler domains in
# BurnBarDaemonSocketRPCCoverage.swift (one `static let <name>: Set<...>` per
# domain). Domains whose handler lives in RPC/Domains/ (a type declaring
# `static let domain: BurnBarDaemonRPCDomain = .<case>`) run off the
# BurnBarDaemonServer actor; every other domain is "actor-bound".
#
# Fails when:
#   * the domain sets do not partition the generated BurnBarRPCMethod enum
#     exactly (a method in no domain, in two domains, or not in the enum),
#   * any domain exceeds maxMethodsPerDomain (split it),
#   * the total surface exceeds maxTotalMethods,
#   * an isolated handler does not name every method of its domain in a
#     `case .<method>` arm (the router would reach its `unhandled` precondition),
#   * the actor-bound surface exceeds maxActorBoundMethods, an actor-bound domain
#     exceeds its frozen count, or a domain becomes actor-bound without a budget
#     entry. New methods therefore land in an isolated domain handler.
#   * a frozen ceiling sits above the live count (a retired or relocated method
#     left a slot that could be refilled); run --update to ratchet it down.
#
# Modes:
#   (none)        check against budgets/daemon-rpc-domain-baseline.json
#   --print-live  print the live partition as JSON
#   --update      shrink the actor-bound ceilings to live counts (never raises;
#                 drops entries for domains that became isolated)
#
# Pure python3; no Swift toolchain. REPO_ROOT overrides the root for self-tests.
set -euo pipefail

repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
mode="${1:-}"

exec python3 - "${repo_root}" "${mode}" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
mode = sys.argv[2]
coverage_path = root / "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonSocketRPCCoverage.swift"
handlers_dir = root / "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/Domains"
methods_path = root / "OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCMethod.generated.swift"
budget_path = root / "budgets/daemon-rpc-domain-baseline.json"


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


for path in (coverage_path, methods_path):
    if not path.exists():
        fail(f"Missing input: {path.relative_to(root)}")

coverage = coverage_path.read_text(encoding="utf-8")

enum_match = re.search(r"enum BurnBarDaemonRPCDomain\b[^{]*\{([\s\S]*?)\n    var methods", coverage)
if not enum_match:
    fail("Could not find enum BurnBarDaemonRPCDomain in BurnBarDaemonSocketRPCCoverage.swift")
wire_name = {}
for case in re.finditer(r"^\s*case (\w+)(?:\s*=\s*\"([^\"]+)\")?\s*$", enum_match.group(1), re.M):
    wire_name[case.group(1)] = case.group(2) or case.group(1)

domains = {}
for match in re.finditer(r"static let (\w+): Set<BurnBarRPCMethod> = \[([\s\S]*?)\]", coverage):
    name = match.group(1)
    if name not in wire_name:
        fail(f"Domain set '{name}' has no BurnBarDaemonRPCDomain case")
    domains[wire_name[name]] = re.findall(r"\.(\w+)", match.group(2))
missing_sets = sorted(set(wire_name.values()) - set(domains))
if missing_sets:
    fail(f"BurnBarDaemonRPCDomain cases without a method set: {', '.join(missing_sets)}")

enum_methods = re.findall(r"^\s*case (\w+)\s*=\s*\"", methods_path.read_text(encoding="utf-8"), re.M)

owners = {}
for domain, methods in domains.items():
    for method in methods:
        owners.setdefault(method, []).append(domain)
problems = []
for method, owned_by in sorted(owners.items()):
    if len(owned_by) > 1:
        problems.append(f"{method} is in several domains: {', '.join(sorted(owned_by))}")
    if method not in enum_methods:
        problems.append(f"{method} is in domain {owned_by[0]} but not in BurnBarRPCMethod")
for method in enum_methods:
    if method not in owners:
        problems.append(f"{method} is in BurnBarRPCMethod but in no handler domain")
if problems:
    fail("RPC domains do not partition BurnBarRPCMethod:\n  " + "\n  ".join(problems))

case_by_wire = {wire: case for case, wire in wire_name.items()}
isolated = set()
handled_by = {}
if handlers_dir.is_dir():
    for handler in sorted(handlers_dir.glob("*.swift")):
        source = handler.read_text(encoding="utf-8")
        arms = set()
        for arm in re.findall(r"^\s*case\s+(\.\w+(?:\s*,\s*\.\w+)*)\s*:", source, re.M):
            arms.update(re.findall(r"\.(\w+)", arm))
        for case in re.findall(r"static let domain: BurnBarDaemonRPCDomain = \.(\w+)", source):
            if case not in wire_name:
                fail(f"{handler.relative_to(root)} declares unknown domain .{case}")
            isolated.add(wire_name[case])
            handled_by[wire_name[case]] = (handler, arms)

unimplemented = []
for domain, (handler, arms) in sorted(handled_by.items()):
    for method in sorted(set(domains[domain]) - arms):
        unimplemented.append(f"{method} is in domain '{domain}' but {handler.relative_to(root)} has no `case .{method}`")
if unimplemented:
    fail("Isolated handlers do not implement every method of their domain:\n  " + "\n  ".join(unimplemented))

counts = {domain: len(methods) for domain, methods in sorted(domains.items())}
actor_bound = {domain: count for domain, count in counts.items() if domain not in isolated}
live = {
    "totalMethods": len(enum_methods),
    "actorBoundMethods": sum(actor_bound.values()),
    "isolatedDomains": sorted(isolated),
    "domains": counts,
}

if mode == "--print-live":
    print(json.dumps(live, indent=2))
    sys.exit(0)

if not budget_path.exists():
    fail(f"Missing budget {budget_path.relative_to(root)}; seed it from --print-live")
budget = json.loads(budget_path.read_text(encoding="utf-8"))
frozen = budget.get("actorBoundDomains", {})

if mode == "--update":
    raised = [d for d, c in actor_bound.items() if c > frozen.get(d, -1)]
    if raised or live["actorBoundMethods"] > budget["maxActorBoundMethods"]:
        fail("--update only shrinks the actor-bound ceilings; move the new methods to an isolated domain instead")
    budget["actorBoundDomains"] = dict(sorted(actor_bound.items()))
    budget["maxActorBoundMethods"] = live["actorBoundMethods"]
    budget_path.write_text(json.dumps(budget, indent=2) + "\n", encoding="utf-8")
    print(f"Updated {budget_path.relative_to(root)}: actor-bound ceiling {live['actorBoundMethods']}")
    sys.exit(0)

errors = []
cap = budget["maxMethodsPerDomain"]
for domain, count in counts.items():
    if count > cap:
        errors.append(f"domain '{domain}' has {count} methods (structural cap {cap}); split it into smaller domains")
if live["totalMethods"] > budget["maxTotalMethods"]:
    errors.append(
        f"daemon RPC surface has {live['totalMethods']} methods (ceiling {budget['maxTotalMethods']}); "
        "retire methods before adding more"
    )
for domain, count in actor_bound.items():
    if domain not in frozen:
        errors.append(
            f"domain '{domain}' is served on the BurnBarDaemonServer actor but has no actorBoundDomains entry; "
            f"give it a handler in RPC/Domains/ (static let domain: BurnBarDaemonRPCDomain = .{case_by_wire[domain]})"
        )
    elif count > frozen[domain]:
        errors.append(
            f"actor-bound domain '{domain}' grew {frozen[domain]} -> {count}; "
            "new methods go in an isolated domain handler under RPC/Domains/"
        )
if live["actorBoundMethods"] > budget["maxActorBoundMethods"]:
    errors.append(
        f"actor-bound RPC surface grew to {live['actorBoundMethods']} (ceiling {budget['maxActorBoundMethods']})"
    )

stale = [
    f"'{d}' frozen at {frozen[d]} but live is {actor_bound.get(d, 0)}"
    for d in sorted(frozen)
    if frozen[d] > actor_bound.get(d, 0)
]
if budget["maxActorBoundMethods"] > live["actorBoundMethods"]:
    stale.append(f"maxActorBoundMethods {budget['maxActorBoundMethods']} but live is {live['actorBoundMethods']}")
if stale:
    errors.append(
        "actor-bound ceilings are stale (" + "; ".join(stale) + "); "
        "run scripts/debt/check-rpc-domain-ceiling.sh --update so the freed slots cannot be refilled"
    )

print(
    f"Daemon RPC domains: total={live['totalMethods']}/{budget['maxTotalMethods']} "
    f"actor-bound={live['actorBoundMethods']}/{budget['maxActorBoundMethods']} "
    f"isolated={len(isolated)}/{len(counts)} domains, largest={max(counts.values())}/{cap}"
)
if errors:
    fail("Daemon RPC domain ceiling exceeded:\n  " + "\n  ".join(errors))

print("Daemon RPC domain ceiling OK.")
PY
