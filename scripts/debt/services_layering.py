#!/usr/bin/env python3
"""AgentLens/Services layering + acyclicity fitness function.

docs/SERVICES_DECOMPOSITION_PROGRAM.md explains why this exists: the app's
Services tree has no god files but one strongly connected dependency graph, so
it can only be decomposed once edges point one way. This gate measures that
graph from source and holds it to five rules:

  R1 layering   A component may reference only components on a strictly lower
                layer, or its own layer (then R2 governs). Upward references are
                debt.
  R2 acyclic    Every reference whose component edge lies inside a dependency
                cycle is debt.
  R3 root       No new file may land in AgentLens/Services/ root.
  R4 declared   Every scanned Swift file must be owned by a declared component:
                an AgentLens/Services/<Dir> missing from the manifest (including
                one holding only <Dir>/Contracts), or any file under an
                AgentLens root the manifest does not cover, would be silently
                ungated — and every edge through its types would vanish.
  R5 unique     No top-level type name may be declared in two components. The
                resolver cannot own such a name, so every edge through it would
                vanish from the graph and baselined debt would look retired.

Resolution is name based and deliberately conservative: TOP-LEVEL declarations
(class/struct/enum/actor/protocol/typealias/func/var/let outside any brace)
own a name, `private`/`fileprivate` declarations are file-local and never owned
(R5 keeps ownership unique); a nested declaration shadows its name only inside
its enclosing scope, never file-wide; a file never references a name it declares itself at any depth (nested-type
, and its own top-level name file-wide. Comments and string literals are
stripped first, except the executable expressions inside `\\( )` string
interpolation.

Debt is keyed `src -> dst : Symbol` with the number of referencing files, so a
move inside a component never churns the baseline, a new debt edge fails, and a
known debt edge may carry fewer references but never more. With --base REF the
committed baseline itself is compared against the one at REF, so a change
cannot raise the allowance it is checked against.

Usage:
  services_layering.py [--check]           compare against the baseline (CI)
  services_layering.py --check --base REF  also hold the baseline to REF's
  services_layering.py --update            rewrite the baseline (shrink review)
  services_layering.py --report [--json]   summarise the graph
  services_layering.py --explain COMPONENT list a component's outgoing debt
  services_layering.py --simulate PLAN     apply {"files": {old: new}} first
Options: --root DIR (repo root), --baseline PATH, --manifest PATH.
"""

from __future__ import annotations

import argparse
import bisect
import collections
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCAN_ROOT = "AgentLens"
SERVICES = "AgentLens/Services"
EXCLUDED_PARTS = {".build", ".derived-data", ".swiftpm"}

# Strings keep their interpolation: `"\(Type.member)"` is executable code the
# linker must resolve, so blanking the whole literal would erase real edges.
# Comments and literals are removed by a depth-aware scanner, not regex: Swift
# block comments nest, and a literal's `\( )` expressions can contain literals
# of their own (`"\(String(format: "%@", X))"`).
_DECL = re.compile(r"\b(?:class|struct|enum|actor|protocol|typealias|func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)")
_IDENT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
_PRIV = re.compile(r"\b(?:private|fileprivate)\b")


def _scan_block_comment(text: str, start: int) -> int:
    """End offset of the `/*` comment at `start` (Swift nests them)."""
    depth, i, n = 1, start + 2, len(text)
    while i < n - 1 and depth:
        if text.startswith("/*", i):
            depth += 1
            i += 2
        elif text.startswith("*/", i):
            depth -= 1
            i += 2
        else:
            i += 1
    return i


def _scan_literal(text: str, start: int) -> tuple[int, list[tuple[int, int]]]:
    """End offset of the literal at `start`, plus its `\\( )` code spans.

    `start` is on the literal itself: optional `#` markers then a single or
    triple quote. Raw strings need `\\#`-style escapes and `\\#( )`
    interpolation; nested literals inside an interpolation are skipped
    recursively so an inner quote is never mistaken for the outer close.
    """
    n = len(text)
    hashes = 0
    while start + hashes < n and text[start + hashes] == "#":
        hashes += 1
    quote_at = start + hashes
    triple = text.startswith('"""', quote_at)
    opener, closer = ('"""', '"""' + "#" * hashes) if triple else ('"', '"' + "#" * hashes)
    escape = "\\" + "#" * hashes
    marker = escape + "("
    exprs: list[tuple[int, int]] = []
    i = quote_at + len(opener)
    while i < n:
        if text.startswith(escape, i):
            if text.startswith(marker, i):
                depth, j = 1, i + len(marker)
                while j < n and depth:
                    if text.startswith(escape, j):
                        j += len(escape) + 1
                    elif text.startswith("//", j):
                        eol = text.find("\n", j)
                        j = n if eol < 0 else eol
                    elif text.startswith("/*", j):
                        j = _scan_block_comment(text, j)
                    elif text[j] == '"':
                        j, _ = _scan_literal(text, j)
                    else:
                        depth += text[j] == "("
                        depth -= text[j] == ")"
                        j += 1
                exprs.append((i + len(marker), j - 1))
                i = j
            else:
                i += len(escape) + 1  # escaped character
        elif text.startswith(closer, i):
            return i + len(closer), exprs
        else:
            i += 1
    return n, exprs


def _blank(out: list[str], start: int, end: int) -> None:
    for k in range(start, end):
        if out[k] != "\n":
            out[k] = " "


def strip_source(text: str) -> str:
    """Blank comments and string literals, preserving line structure."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            _blank(out, i, end)
            i = end
        elif text.startswith("/*", i):
            end = _scan_block_comment(text, i)
            _blank(out, i, end)
            i = end
        elif text[i] in '"#':
            j = i
            while j < n and text[j] == "#":
                j += 1
            if j >= n or text[j] != '"':
                i += 1
                continue
            end, exprs = _scan_literal(text, i)
            _blank(out, i, end)
            for a, b in exprs:
                out[a:b] = strip_source(text[a:b])  # literals/comments inside blank too
            i = end
        else:
            i += 1
    return "".join(out)


def declarations(stripped: str) -> tuple[set[str], dict[str, list[tuple[int, int]]]]:
    """(top-level owned names, name -> lexical shadow ranges) for one file.

    Ranges are character offsets. A file only owns names it declares outside
    every brace, and only names it can hand to another component, so
    `private`/`fileprivate` declarations are never owned — but they still
    shadow their name file-wide. A nested declaration shadows its name only
    inside the body of the scope enclosing it, which is what makes
    `struct Outer { struct Foo {} }` different from a top-level `Foo`: outside
    `Outer`, `Foo` still refers to the other component's type. Scope is
    resolved at each declaration's offset, so `{ let x: Int }` on one line
    never promotes `x` to a top-level owner.
    """
    # Every brace pair in the file, as (open, close) character offsets.
    stack: list[int] = []
    close_of: dict[int, int] = {}
    for pos, ch in enumerate(stripped):
        if ch == "{":
            stack.append(pos)
        elif ch == "}" and stack:
            close_of[stack.pop()] = pos
    opens = sorted(close_of)

    def enclosing(pos: int) -> tuple[int, int] | None:
        """Innermost pair containing pos; pairs nest properly, so the greatest
        open before pos whose close is after pos is the innermost enclosing."""
        i = bisect.bisect_right(opens, pos) - 1
        while i >= 0:
            if close_of[opens[i]] > pos:
                return opens[i], close_of[opens[i]]
            i -= 1
        return None

    n = len(stripped)
    top: set[str] = set()
    shadows: dict[str, list[tuple[int, int]]] = collections.defaultdict(list)
    for match in _DECL.finditer(stripped):
        name = match.group(1)
        pair = enclosing(match.start())
        if pair is None:
            shadows[name].append((0, n))
            line_start = stripped.rfind("\n", 0, match.start()) + 1
            if not _PRIV.search(stripped[line_start : match.start()]):
                top.add(name)
        else:
            shadows[name].append(pair)
    return top, shadows


class Manifest:
    def __init__(self, data: dict):
        self.layers: list[str] = data["layers"]
        self.rank = {name: index for index, name in enumerate(self.layers)}
        self.contracts_dir: str = data.get("contractsDirectory", "Contracts")
        self.contracts_layer: str = data["contractsLayer"]
        self.root_component: str = data["servicesRootComponent"]
        self.components: dict[str, str] = {}
        self.prefixes: list[tuple[str, str]] = []
        for component in data["components"]:
            name, layer = component["name"], component["layer"]
            if layer not in self.rank:
                raise SystemExit(f"manifest: component {name} names unknown layer {layer}")
            self.components[name] = layer
            for prefix in component["paths"]:
                self.prefixes.append((prefix.rstrip("/") + "/", name))
        self.prefixes.sort(key=lambda item: -len(item[0]))
        self.declared_dirs = {prefix for prefix, _ in self.prefixes}
        if self.root_component not in self.components:
            raise SystemExit(f"manifest: servicesRootComponent {self.root_component} is not declared")

    def component(self, rel: str) -> str | None:
        """Map a repo-relative path to its component; None means undeclared."""
        parts = rel.split("/")
        # <Feature>/Contracts/** is the feature's contract component, by convention,
        # but only for a declared feature: contracts cannot smuggle in a new directory.
        if (
            rel.startswith(SERVICES + "/")
            and len(parts) > 4
            and parts[3] == self.contracts_dir
            and f"{SERVICES}/{parts[2]}/" in self.declared_dirs
        ):
            return f"{parts[2]}.{self.contracts_dir}"
        for prefix, name in self.prefixes:
            if rel.startswith(prefix):
                return name
        if rel.startswith(SERVICES + "/") and len(parts) == 3:
            return self.root_component
        return None

    def layer(self, component: str) -> str:
        if component.endswith("." + self.contracts_dir):
            return self.contracts_layer
        return self.components[component]


class Graph:
    """References between components, resolved from source."""

    def __init__(self, repo: Path, manifest: Manifest, moves: dict[str, str]):
        self.manifest = manifest
        self.undeclared: set[str] = set()
        self.root_files: list[str] = []
        sources: dict[str, str] = {}
        for path in sorted((repo / SCAN_ROOT).rglob("*.swift")):
            if EXCLUDED_PARTS.intersection(path.parts):
                continue
            rel = path.relative_to(repo).as_posix()
            rel = moves.get(rel, rel)
            if rel.startswith(SCAN_ROOT + "/Lab/"):
                continue  # Lab compiles only in the Lab configuration; lab-boundary gates it.
            sources[rel] = strip_source(path.read_text(encoding="utf-8", errors="ignore"))

        self.file_component: dict[str, str] = {}
        shadow_map: dict[str, dict[str, list[tuple[int, int]]]] = {}
        owners: dict[str, set[str]] = collections.defaultdict(set)
        declared_in: dict[str, set[str]] = collections.defaultdict(set)
        for rel, text in sources.items():
            component = manifest.component(rel)
            if component is None:
                # Any scanned file the manifest does not own is ungated: its
                # declarations and edges would vanish from the graph.
                self.undeclared.add("/".join(rel.split("/")[:-1]))
                continue
            if component == manifest.root_component:
                self.root_files.append(rel)
            self.file_component[rel] = component
            top, shadows = declarations(text)
            shadow_map[rel] = shadows
            for name in top:
                owners[name].add(component)
                declared_in[name].add(rel)
        # name -> files declaring it, for every name owned by more than one component (R5).
        self.ambiguous = {name: sorted(declared_in[name]) for name, comps in sorted(owners.items()) if len(comps) > 1}
        owner = {name: next(iter(comps)) for name, comps in owners.items() if len(comps) == 1}

        # refs[(src, dst)][symbol] = set(files)
        self.refs: dict[tuple[str, str], dict[str, set[str]]] = collections.defaultdict(
            lambda: collections.defaultdict(set)
        )
        for rel, component in self.file_component.items():
            text = sources[rel]
            shadows = shadow_map[rel]
            for match in _IDENT.finditer(text):
                name = match.group(0)
                ranges = shadows.get(name)
                if ranges and any(start <= match.start() <= end for start, end in ranges):
                    continue
                target = owner.get(name)
                if target is not None and target != component:
                    self.refs[(component, target)][name].add(rel)

        self.components = sorted(set(self.file_component.values()))
        self.cycles = self._strongly_connected()
        self.cycle_of = {c: index for index, scc in enumerate(self.cycles) for c in scc}

    def _strongly_connected(self) -> list[list[str]]:
        adjacency: dict[str, set[str]] = collections.defaultdict(set)
        for src, dst in self.refs:
            adjacency[src].add(dst)
        index: dict[str, int] = {}
        low: dict[str, int] = {}
        stack: list[str] = []
        on_stack: set[str] = set()
        found: list[list[str]] = []
        counter = 0
        for start in self.components:
            if start in index:
                continue
            # Iterative Tarjan: (node, iterator over successors).
            work = [(start, iter(sorted(adjacency[start])))]
            index[start] = low[start] = counter
            counter += 1
            stack.append(start)
            on_stack.add(start)
            while work:
                node, successors = work[-1]
                advanced = False
                for succ in successors:
                    if succ not in index:
                        index[succ] = low[succ] = counter
                        counter += 1
                        stack.append(succ)
                        on_stack.add(succ)
                        work.append((succ, iter(sorted(adjacency[succ]))))
                        advanced = True
                        break
                    if succ in on_stack:
                        low[node] = min(low[node], index[succ])
                if advanced:
                    continue
                work.pop()
                if work:
                    parent = work[-1][0]
                    low[parent] = min(low[parent], low[node])
                if low[node] == index[node]:
                    scc = []
                    while True:
                        member = stack.pop()
                        on_stack.discard(member)
                        scc.append(member)
                        if member == node:
                            break
                    if len(scc) > 1:
                        found.append(sorted(scc))
        return sorted(found, key=lambda scc: (-len(scc), scc))

    def classify(self, src: str, dst: str) -> tuple[bool, bool]:
        """(upward, cyclic) for one component edge."""
        rank, layer = self.manifest.rank, self.manifest.layer
        upward = rank[layer(dst)] > rank[layer(src)]
        cyclic = src in self.cycle_of and self.cycle_of.get(dst) == self.cycle_of[src]
        return upward, cyclic

    def debt(self) -> dict[str, dict[str, int]]:
        """Current debt: rule -> {"src -> dst : Symbol": referencing-file count}."""
        upward: dict[str, int] = {}
        cyclic: dict[str, int] = {}
        for (src, dst), symbols in self.refs.items():
            is_upward, is_cyclic = self.classify(src, dst)
            for symbol, files in symbols.items():
                key = f"{src} -> {dst} : {symbol}"
                if is_upward:
                    upward[key] = len(files)
                if is_cyclic:
                    cyclic[key] = len(files)
        return {"upward": dict(sorted(upward.items())), "cyclic": dict(sorted(cyclic.items()))}

    def summary(self) -> dict:
        debt = self.debt()
        return {
            "components": len(self.components),
            "largestCycle": len(self.cycles[0]) if self.cycles else 0,
            "componentsInCycles": sum(len(scc) for scc in self.cycles),
            "upwardReferences": sum(debt["upward"].values()),
            "cyclicReferences": sum(debt["cyclic"].values()),
            "servicesRootFiles": len(self.root_files),
            "ambiguousNames": len(self.ambiguous),
        }


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_baseline(graph: Graph, path: Path) -> None:
    debt = graph.debt()
    summary = graph.summary()
    baseline = {
        "note": (
            "Generated by scripts/debt/services_layering.py --update. Shrink-only: a new key or a "
            "higher count fails CI. See docs/SERVICES_DECOMPOSITION_PROGRAM.md."
        ),
        "summary": {
            key: summary[key]
            for key in (
                "largestCycle",
                "componentsInCycles",
                "upwardReferences",
                "cyclicReferences",
                "servicesRootFiles",
            )
        },
        "servicesRootFiles": sorted(graph.root_files),
        "upward": debt["upward"],
        "cyclic": debt["cyclic"],
    }
    path.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")


def base_regressions(repo: Path, ref: str, baseline_path: Path, baseline: dict) -> list[str]:
    """Where the committed baseline allows more debt than the baseline at `ref` did."""
    resolved = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
        capture_output=True,
        text=True,
    )
    if resolved.returncode != 0:
        if os.environ.get("CI"):
            return [f"base: {ref} does not resolve, so the baseline cannot be held to it"]
        print(f"services-layering: base {ref} does not resolve; base-relative check skipped")
        return []
    rel = baseline_path.resolve().relative_to(repo).as_posix()
    shown = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{rel}"], capture_output=True, text=True)
    if shown.returncode != 0:
        print(f"services-layering: {rel} is new relative to {ref}; allowed")
        return []
    old = json.loads(shown.stdout)
    raised: list[str] = []
    for rule in ("upward", "cyclic"):
        before = old.get(rule, {})
        for key, count in baseline.get(rule, {}).items():
            if key not in before:
                raised.append(f"baseline adds {rule} key {key} (absent at base)")
            elif count > before[key]:
                raised.append(f"baseline raises {rule} {key} {before[key]} -> {count}")
    for key, value in baseline.get("summary", {}).items():
        if key in old.get("summary", {}) and value > old["summary"][key]:
            raised.append(f"baseline raises summary {key} {old['summary'][key]} -> {value}")
    for rel_file in sorted(set(baseline.get("servicesRootFiles", [])) - set(old.get("servicesRootFiles", []))):
        raised.append(f"baseline adds Services root file {rel_file} (absent at base)")
    return raised


def check(graph: Graph, baseline: dict, base_failures: list[str]) -> int:
    failures: list[str] = [f"shrink-only {line}" for line in base_failures]
    improvements: list[str] = []
    for directory in sorted(graph.undeclared):
        failures.append(f"R4 undeclared: {directory} has no layer. Declare it in config/services-layers.json.")
    for name, files in graph.ambiguous.items():
        failures.append(
            f"R5 ambiguous: {name} is declared at top level in {', '.join(files)}. Rename one or "
            "nest it so exactly one component owns the name."
        )
    known_root = set(baseline.get("servicesRootFiles", []))
    for rel in sorted(set(graph.root_files) - known_root):
        failures.append(
            f"R3 root: {rel} is a new file in AgentLens/Services/ root. Home it in the feature directory that owns it."
        )
    if known_root - set(graph.root_files):
        improvements.append(f"{len(known_root - set(graph.root_files))} Services root file(s) rehomed")

    current = graph.debt()
    labels = {"upward": "R1 upward", "cyclic": "R2 cycle"}
    for rule, label in labels.items():
        allowed = baseline.get(rule, {})
        for key, count in current[rule].items():
            if key not in allowed:
                failures.append(f"{label}: new reference {key} ({count} file(s))")
            elif count > allowed[key]:
                failures.append(f"{label}: {key} grew {allowed[key]} -> {count} file(s)")
        retired = sum(allowed.values()) - sum(min(allowed[k], v) for k, v in current[rule].items() if k in allowed)
        if retired > 0:
            improvements.append(f"{label}: {retired} reference(s) retired")

    summary = graph.summary()
    print("services-layering: " + ", ".join(f"{key}={value}" for key, value in summary.items()))
    if failures:
        print(f"FAIL: {len(failures)} layering violation(s):", file=sys.stderr)
        for line in failures:
            print(f"  - {line}", file=sys.stderr)
        print(
            "Fix the dependency direction (move the type to a lower layer or a <Feature>/Contracts "
            "directory, or invert the call), then re-run. docs/SERVICES_DECOMPOSITION_PROGRAM.md "
            "lists the remedies.",
            file=sys.stderr,
        )
        return 1
    if improvements:
        print("Improved: " + "; ".join(improvements) + ". Run with --update to ratchet the baseline down.")
    print("services-layering: OK")
    return 0


def report(graph: Graph, as_json: bool) -> None:
    debt = graph.debt()
    per_component = collections.Counter()
    for rule in ("upward", "cyclic"):
        for key, count in debt[rule].items():
            per_component[key.split(" -> ")[0]] += count
    data = {
        "summary": graph.summary(),
        "cycles": graph.cycles,
        "undeclared": sorted(graph.undeclared),
        "debtBySourceComponent": dict(per_component.most_common()),
        "layers": {c: graph.manifest.layer(c) for c in graph.components},
    }
    if as_json:
        print(json.dumps(data, indent=2))
        return
    for key, value in data["summary"].items():
        print(f"{key:>20}: {value}")
    for scc in graph.cycles:
        print(f"\ncycle ({len(scc)}): {', '.join(scc)}")
    print("\ndebt references by source component:")
    for component, count in per_component.most_common():
        print(f"  {count:5d}  {component}  [{graph.manifest.layer(component)}]")


def explain(graph: Graph, component: str) -> None:
    for (src, dst), symbols in sorted(graph.refs.items()):
        if src != component:
            continue
        upward, cyclic = graph.classify(src, dst)
        tags = ",".join(tag for tag, on in (("UPWARD", upward), ("CYCLE", cyclic)) if on) or "ok"
        print(f"{src} -> {dst} [{graph.manifest.layer(dst)}] {tags}")
        for symbol, files in sorted(symbols.items()):
            print(f"    {symbol}: {', '.join(sorted(files))}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--update", action="store_true")
    mode.add_argument("--report", action="store_true")
    mode.add_argument("--explain", metavar="COMPONENT")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--simulate", metavar="PLAN")
    parser.add_argument("--base", metavar="REF", help="with --check, hold the baseline to the one at REF")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--manifest")
    parser.add_argument("--baseline")
    args = parser.parse_args()

    repo = Path(args.root).resolve()
    manifest = Manifest(load_json(Path(args.manifest) if args.manifest else repo / "config/services-layers.json"))
    baseline_path = Path(args.baseline) if args.baseline else repo / "budgets/services-layering-baseline.json"
    moves = load_json(Path(args.simulate)).get("files", {}) if args.simulate else {}
    graph = Graph(repo, manifest, moves)

    if args.update:
        if graph.undeclared:
            print(
                "Refusing to baseline undeclared directories: " + ", ".join(sorted(graph.undeclared)), file=sys.stderr
            )
            return 1
        if graph.ambiguous:
            print("Refusing to baseline ambiguous type names: " + ", ".join(graph.ambiguous), file=sys.stderr)
            return 1
        write_baseline(graph, baseline_path)
        print(
            f"services-layering: baseline written to {baseline_path.relative_to(repo) if baseline_path.is_relative_to(repo) else baseline_path}"
        )
        return 0
    if args.report:
        report(graph, args.json)
        return 0
    if args.explain:
        explain(graph, args.explain)
        return 0
    if not baseline_path.exists():
        print(f"missing baseline {baseline_path}; run --update", file=sys.stderr)
        return 1
    baseline = load_json(baseline_path)
    base_failures = base_regressions(repo, args.base, baseline_path, baseline) if args.base else []
    return check(graph, baseline, base_failures)


if __name__ == "__main__":
    sys.exit(main())
