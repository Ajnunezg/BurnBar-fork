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

Resolution is name based and deliberately conservative. TOP-LEVEL declarations
(class/struct/enum/actor/protocol/typealias/func/var/let, and `func <op>`)
own a name; `private`/`fileprivate` declarations are file-local and never
owned (R5 keeps ownership unique). A nested declaration shadows its name
inside its enclosing scope only: type members shadow the whole type body,
while `let`/`var` bindings in function or statement scopes shadow from the
end of their declaration — `let x = x()` still resolves the right-hand `x`
outward. A file never references a name it declares itself. Comments, string
literals and regex literals are stripped first, except the executable
expressions inside `\\( )` interpolation.

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
# of their own (`"\(String(format: "%@", X))"`). Regex literals are blanked the
# same way — `/FeatureAThing/` is pattern text, not a type reference.
_DECL = re.compile(r"\b(class|struct|enum|actor|protocol|typealias|func|var|let)\s+`?([A-Za-z_][A-Za-z0-9_]*)`?")
_OP_DECL = re.compile(r"\bfunc\s+([!<=>?^|~&%*+\-./]+)")
_OP_CHARS = set("!<=>?^|~&%*+-./")
# Standard library and syntax operators are never owned by a component, so
# indexing them would attribute stdlib call sites to whichever file happened to
# overload them.
_STDLIB_OPS = {
    "=",
    "==",
    "===",
    "!=",
    "<",
    ">",
    "<=",
    ">=",
    "&&",
    "||",
    "!",
    "?",
    "??",
    "?.",
    "+",
    "-",
    "*",
    "/",
    "%",
    "+=",
    "-=",
    "*=",
    "/=",
    "%=",
    "&",
    "|",
    "^",
    "<<",
    ">>",
    "<<=",
    ">>=",
    "&=",
    "|=",
    "^=",
    "&+",
    "&-",
    "&*",
    "&<<",
    "&>>",
    "->",
    "~>",
    "...",
    "..<",
}
_IDENT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
# Words that can legitimately continue a signature after a newline
# (`func f()\nwhere T: Equatable {`, `async`, `throws`).
_SIG_CONTINUATION = {"where", "async", "throws", "rethrows"}
_WHERE = re.compile(r"\bwhere\b")
_COND = re.compile(r"\b(if|while|for|case|catch|guard)\b")
_CASE = re.compile(r"\b(?:case|default)\b")
_TUPLE_DECL = re.compile(r"\b(let|var)\s*\.?\w*\(")
_PRIV = re.compile(r"\b(?:private|fileprivate)\b(?!\s*\()")
_SCOPE_KW = re.compile(r"\b(class|struct|enum|actor|protocol|extension|func|init|deinit|var|let)\b")
_TYPE_SCOPE_KW = {"class", "struct", "enum", "actor", "protocol", "extension"}
_EXPR_KW = {
    "return",
    "in",
    "where",
    "case",
    "if",
    "guard",
    "while",
    "for",
    "let",
    "var",
    "try",
    "await",
    "throw",
    "do",
    "else",
    "switch",
    "defer",
    "repeat",
    "catch",
    "any",
    "some",
}


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


def _is_regex_position(text: str, i: int) -> bool:
    """True when a `/` at `i` can begin a regex literal rather than division:
    expression position (start of input, or after punctuation/operators/keywords),
    not operand position (identifier, literal, `)`, `]`)."""
    j = i - 1
    while j >= 0 and text[j] in " \t\n":
        j -= 1
    if j < 0:
        return True
    c = text[j]
    if c in "=(:,[!&|?~<>{};+-*%^":
        return True
    if c.isalnum() or c in "_$)]'\"":
        match = re.search(r"[A-Za-z_][A-Za-z0-9_]*$", text[: j + 1])
        return bool(match and match.group(0) in _EXPR_KW)
    return False


def _scan_regex(text: str, start: int) -> tuple[int, list[tuple[int, int]]] | None:
    """End offset + `\\( )` code spans for the regex literal at `start`.

    `start` is on optional `#` markers then `/`. Bare `/.../` literals end at
    an unescaped `/` on the same line (returning None if none exists — the `/`
    was division, not a literal). Raw `#/.../#/` literals may span lines.
    Character classes `[...]` and escapes are skipped; `\\( )` interpolation
    is executable code and is returned for recursive stripping.
    """
    n = len(text)
    hashes = 0
    while start + hashes < n and text[start + hashes] == "#":
        hashes += 1
    escape = "\\" + "#" * hashes
    marker = escape + "("
    closer = "/" + "#" * hashes
    exprs: list[tuple[int, int]] = []
    in_class = False
    i = start + hashes + 1
    while i < n:
        c = text[i]
        if c == "\n" and not hashes:
            return None
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
                i += len(escape) + 1
            continue
        if c == "[":
            in_class = True
        elif c == "]":
            in_class = False
        elif c == "/" and not in_class and text.startswith(closer, i):
            return i + len(closer), exprs
        i += 1
    return (n, exprs) if hashes else None


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
        elif text[i] == "/" and _is_regex_position(text, i):
            scanned = _scan_regex(text, i)
            if scanned is None:
                i += 1
                continue
            end, exprs = scanned
            _blank(out, i, end)
            for a, b in exprs:
                out[a:b] = strip_source(text[a:b])
            i = end
        elif text[i] in '"#':
            j = i
            while j < n and text[j] == "#":
                j += 1
            if j >= n or text[j] not in '"/':
                i += 1
                continue
            if text[j] == "/":
                scanned = _scan_regex(text, i)
                if scanned is None:
                    i += 1
                    continue
                end, exprs = scanned
            else:
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
    shadow their name file-wide. The modifier check reads only the segment
    belonging to this declaration: after `private struct A {}; struct B {}`,
    `B` is public. `private(set)` restricts just the setter, so it never
    marks a declaration private at all.

    A nested declaration shadows its name only inside the body of the scope
    enclosing it — what makes `struct Outer { struct Foo {} }` different from
    a top-level `Foo`. Members of a type scope are visible throughout it, but
    a `let`/`var` binding inside a function or statement scope is not in
    scope before its declaration or inside its own initializer
    (`let x = x()` resolves the right-hand `x` outward), so those shadows
    start where the statement ends. Scope is resolved at each declaration's
    offset, so `{ let x: Int }` on one line never promotes `x` to a
    top-level owner. Top-level `func <~>` operator declarations own their
    operator name too.
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

    def is_type_scope(open_pos: int) -> bool:
        """Whether the `{` at open_pos opens a type/extension body: members
        are visible throughout it, unlike statement-scope bindings."""
        seg_start = max(stripped.rfind(c, 0, open_pos) for c in ";{}") + 1
        last = None
        for kw in _SCOPE_KW.finditer(stripped[seg_start:open_pos]):
            last = kw.group(1)
        return last in _TYPE_SCOPE_KW

    def statement_end(pos: int) -> int:
        """Offset where the declaration at `pos` completes: the first `;` or
        newline at balanced depth. The name enters scope only after this —
        references inside its own initializer still resolve outward. A
        newline after a depth-zero comma is continuation, not termination:
        `let a = 0,\\n b = { 42 }` binds `b` too."""
        depth, i, limit = 0, pos, len(stripped)
        while i < limit:
            c = stripped[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and c == "\n":
                j = i - 1
                while j >= pos and stripped[j] in " \t\r":
                    j -= 1
                if j < pos or stripped[j] != ",":
                    break
            elif depth == 0 and c == ";":
                break
            i += 1
        return i

    n = len(stripped)
    # name -> list of (kind, signature) so R5 can permit real overloads.
    top: dict[str, list[tuple[str, tuple | None]]] = collections.defaultdict(list)
    shadows: dict[str, list[tuple[int, int]]] = collections.defaultdict(list)

    def split_segments(region_start: int, region_end: int) -> list[tuple[int, int, int]]:
        """(seg_start, seg_end, head_end) per depth-0 comma-separated
        segment; head_end is the first depth-0 ':' (param annotation)."""

        def is_generic_open(pos: int) -> bool:
            # `<` begins a generic argument list when it follows a type-ish
            # token; `a < b` and `a <= b`/`a << b` do not.
            if pos + 1 >= len(stripped) or stripped[pos + 1] in "=<> \t":
                return False
            return pos > 0 and (stripped[pos - 1].isalnum() or stripped[pos - 1] in "_.>)]?")

        segments: list[tuple[int, int, int]] = []
        depth, angle, seg_start = 0, 0, region_start
        for i in range(region_start, region_end + 1):
            c = stripped[i] if i < region_end else ","
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "<" and is_generic_open(i):
                angle += 1
            elif c == ">" and angle:
                angle -= 1
            elif c == "," and depth == 0 and angle == 0:
                head_end = i
                head_depth, head_angle = 0, 0
                for p in range(seg_start, i):
                    c2 = stripped[p]
                    if c2 in "([{":
                        head_depth += 1
                    elif c2 in ")]}":
                        head_depth -= 1
                    elif c2 == "<" and is_generic_open(p):
                        head_angle += 1
                    elif c2 == ">" and head_angle:
                        head_angle -= 1
                    elif c2 == ":" and head_depth == 0 and head_angle == 0:
                        head_end = p
                        break
                segments.append((seg_start, i, head_end))
                seg_start = i + 1
        return segments

    def binding_spans(region_start: int, region_end: int) -> list[tuple[str, int, int]]:
        """(name, start, end) for each bound name in a comma-separated
        region — signature params, closure params. The bound name is the
        last identifier before the segment's first depth-0 ':' (an
        external label precedes the internal name, so the last wins)."""
        spans: list[tuple[str, int, int]] = []
        for seg_start, _seg_end, head_end in split_segments(region_start, region_end):
            ids = list(_IDENT.finditer(stripped[seg_start:head_end]))
            if ids:
                m = ids[-1]
                spans.append((m.group(0), seg_start + m.start(), seg_start + m.end()))
        return spans

    def param_sig(region_start: int, region_end: int) -> tuple[tuple[str, str], ...]:
        """(label, annotation) per parameter — the overload signature R5
        uses to tell legal overloads from a redeclaration. Whitespace is
        collapsed and default values are cut."""
        sig: list[tuple[str, str]] = []
        for seg_start, seg_end, head_end in split_segments(region_start, region_end):
            ids = _IDENT.findall(stripped[seg_start:head_end])
            label = ids[0] if ids else "_"
            anno_end = seg_end
            depth, angle = 0, 0
            for p in range(head_end + 1, seg_end):
                c = stripped[p]
                if c in "([{":
                    depth += 1
                elif c in ")]}":
                    depth -= 1
                elif c == "<" and p + 1 < seg_end and stripped[p + 1] not in "=<> \t":
                    angle += 1
                elif c == ">" and angle:
                    angle -= 1
                elif c == "=" and depth == 0 and angle == 0 and stripped[p - 1] not in "<>=!":
                    anno_end = p
                    break
            anno = " ".join(stripped[head_end + 1 : anno_end].split())
            sig.append((label, anno))
        return tuple(sig)

    def body_open(sig_end: int) -> int | None:
        """The `{` opening the body of the signature ending near sig_end.
        None when there is no body (protocol requirements)."""
        j = sig_end
        while j < n:
            c = stripped[j]
            if c == "{":
                return j
            if c in ";}":
                return None
            if c == "\n":
                k = j + 1
                while k < n and stripped[k] in " \t\r":
                    k += 1
                if k >= n:
                    return None
                if stripped[k] in "{-":
                    continue
                word = _IDENT.match(stripped, k)
                if word is None or word.group(0) not in _SIG_CONTINUATION:
                    return None
            j += 1
        return None

    def generic_params(pos: int) -> tuple[list[tuple[str, int, int]], int] | None:
        """`func map<Result>` — the bound type-parameter names plus the `>`
        position. Constraint types (`T: FeatureThing`) stay live references."""
        while pos < n and stripped[pos] in " \t":
            pos += 1
        if pos >= n or stripped[pos] != "<":
            return None
        end = pos + 1
        d = 1
        while end < n and d:
            d += stripped[end] == "<"
            d -= stripped[end] == ">"
            end += 1
        if d:
            return None
        names: list[tuple[str, int, int]] = []
        for seg_start, _seg_end, head_end in split_segments(pos + 1, end - 1):
            ids = list(_IDENT.finditer(stripped[seg_start:head_end]))
            if ids:
                m = ids[0]
                names.append((m.group(0), seg_start + m.start(), seg_start + m.end()))
        return names, end

    def record_params(sig_name_end: int) -> tuple[tuple[tuple[str, str], ...], str] | None:
        """Shadow parameter names: at their binding site and across the
        function's body. Parameter types stay live references. Returns the
        overload signature ((label, annotation) params, return type) so R5
        can tell real overloads from redeclarations."""
        j = sig_name_end
        while j < n and stripped[j] in " \t?!":
            j += 1
        generics = generic_params(j)
        if generics is not None:
            names, j = generics
            while j < n and stripped[j] in " \t":
                j += 1
        if j >= n or stripped[j] != "(":
            return None
        d, k = 1, j + 1
        while k < n and d:
            d += stripped[k] == "("
            d -= stripped[k] == ")"
            k += 1
        spans = binding_spans(j + 1, k - 1)
        open_pos = body_open(k)
        scope_end = close_of.get(open_pos, n) if open_pos is not None else k
        if generics is not None:
            # Each generic parameter name binds at its token and holds across
            # the signature and body (`func map<Result>(v: Result)`).
            for gname, gs, _ge in generics[0]:
                shadows[gname].append((gs, scope_end))
        for pname, ps, pe in spans:
            shadows[pname].append((ps, pe))
            if open_pos is not None:
                shadows[pname].append((open_pos, scope_end))
        ret_end = open_pos if open_pos is not None else min(k + 400, n)
        ret = ""
        arrow = stripped.find("->", k, ret_end)
        if arrow != -1:
            bound = ret_end
            w = _WHERE.search(stripped, arrow + 2, ret_end)
            if w:
                bound = w.start()
            ret = " ".join(stripped[arrow + 2 : bound].split())
        return param_sig(j + 1, k - 1), ret

    def branch_open(pos: int) -> int | None:
        """The `{` opening the branch of the statement at pos. `{`s preceded
        by `=(:,` are closures inside an initializer and are skipped."""
        depth, i = 0, pos
        while i < n:
            c = stripped[i]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            elif c == "{":
                if depth == 0:
                    p = i - 1
                    while p >= pos and stripped[p] in " \t\r\n":
                        p -= 1
                    if p >= pos and stripped[p] not in "=(:,{":
                        return i
                depth += 1
            elif c == "}":
                if depth == 0:
                    return None
                depth -= 1
            elif c == ";" and depth == 0:
                return None
            i += 1
        return None

    def cond_scope(let_pos: int) -> tuple[int, int] | None:
        """Scope for an if/while/catch/case conditional binding: its branch
        plus the else chain. `guard` and unrecognized shapes keep the
        default (statement -> enclosing scope) shadow."""
        ss = max(stripped.rfind(c, 0, let_pos) for c in ";{}") + 1
        lead = _COND.search(stripped, ss, let_pos)
        if lead is None or lead.group(1) == "guard":
            return None
        kw = lead.group(1)
        if kw == "case":
            # `case let .p(x):` — the binding holds until the next
            # case/default label or the switch's closing brace.
            colon = stripped.find(":", let_pos)
            if colon == -1:
                return None
            depth, j = 0, colon + 1
            while j < n:
                c = stripped[j]
                if depth == 0 and (c == "}" or _CASE.match(stripped, j)):
                    break
                if c in "([{":
                    depth += 1
                elif c in ")]}":
                    depth -= 1
                j += 1
            return (colon + 1, j)
        bo = branch_open(let_pos)
        if bo is None or bo not in close_of:
            return None
        scope_end = close_of[bo]
        if kw == "if":
            j = scope_end
            while True:
                while j < n and stripped[j] in " \t\r\n":
                    j += 1
                m = _IDENT.match(stripped, j)
                if m is None or m.group(0) != "else":
                    break
                j = m.end()
                while j < n and stripped[j] in " \t\r\n":
                    j += 1
                m2 = _IDENT.match(stripped, j)
                if m2 is not None and m2.group(0) == "if":
                    bo2 = branch_open(j)
                    if bo2 is None or bo2 not in close_of:
                        break
                    scope_end = close_of[bo2]
                    j = scope_end
                elif j < n and stripped[j] == "{" and j in close_of:
                    scope_end = close_of[j]
                    j = scope_end
                else:
                    break
        return (bo, scope_end)

    for match in _DECL.finditer(stripped):
        keyword, name = match.group(1), match.group(2)
        pair = enclosing(match.start())
        seg_start = max(stripped.rfind(c, 0, match.start()) for c in ";{}\n") + 1
        private = bool(_PRIV.search(stripped[seg_start : match.start()]))
        # `let a = 0, b = { 42 }` binds every name at depth 0, not just the
        # first: each is owned or shadows like the leading binding.
        bound = [(name, match.start(2), match.end(2))]
        end = statement_end(match.end())
        if keyword in ("let", "var"):
            depth, i = 0, match.end()
            while i < end:
                c = stripped[i]
                if c in "([{":
                    depth += 1
                elif c in ")]}" and depth:
                    depth -= 1
                elif c == "," and depth == 0:
                    j = i + 1
                    while j < end and stripped[j] in " \t\r\n":
                        j += 1
                    extra = re.match(r"[A-Za-z_][A-Za-z0-9_]*(?=\s*[:=,;]|$)", stripped[j:end])
                    if extra:
                        bound.append((extra.group(0), j, j + len(extra.group(0))))
                i += 1
        sig = record_params(match.end()) if keyword == "func" else None
        if keyword in _TYPE_SCOPE_KW and keyword != "extension":
            gp = generic_params(match.end())
            if gp is not None:
                bo = body_open(gp[1])
                gscope = close_of[bo] if bo is not None and bo in close_of else end
                for gname, gs, _ge in gp[0]:
                    shadows[gname].append((gs, gscope))
        cond = None
        if keyword in ("let", "var") and pair is not None and not is_type_scope(pair[0]):
            cond = cond_scope(match.start())
        for bound_name, bound_start, bound_end in bound:
            if pair is None:
                shadows[bound_name].append((0, n))
                if not private:
                    top[bound_name].append((keyword, sig))
            elif keyword in ("let", "var") and not is_type_scope(pair[0]):
                shadows[bound_name].append((bound_start, bound_end))
                shadows[bound_name].append(cond if cond is not None else (end, pair[1]))
            else:
                shadows[bound_name].append(pair)
    # Tuple and pattern destructuring: `let (a, b) = ...`,
    # `case let .p(x) = ...` — `_DECL` cannot see these names.
    for match in _TUPLE_DECL.finditer(stripped):
        keyword = match.group(1)
        pair = enclosing(match.start())
        seg_start = max(stripped.rfind(c, 0, match.start()) for c in ";{}\n") + 1
        private = bool(_PRIV.search(stripped[seg_start : match.start()]))
        p0 = stripped.find("(", match.start())
        d, k = 0, p0
        while k < n:
            d += stripped[k] == "("
            d -= stripped[k] == ")"
            k += 1
            if d == 0:
                break
        bound = [
            (m.group(0), m.start(), m.end()) for m in _IDENT.finditer(stripped, p0 + 1, k - 1) if m.group(0) != "_"
        ]
        end = statement_end(match.start())
        cond = None
        if pair is not None and not is_type_scope(pair[0]):
            cond = cond_scope(match.start())
        for bound_name, bound_start, bound_end in bound:
            if pair is None:
                shadows[bound_name].append((0, n))
                if not private:
                    top[bound_name].append((keyword, None))
            else:
                shadows[bound_name].append((bound_start, bound_end))
                shadows[bound_name].append(cond if cond is not None else (end, pair[1]))
    # Top-level operator functions own their operator name (`func <~>`).
    for match in _OP_DECL.finditer(stripped):
        name = match.group(1)
        sig = record_params(match.end())
        if name in _STDLIB_OPS:
            continue
        if enclosing(match.start()) is None:
            seg_start = max(stripped.rfind(c, 0, match.start()) for c in ";{}\n") + 1
            if not _PRIV.search(stripped[seg_start : match.start()]):
                top[name].append(("func", sig))
    # init parameters bind like func parameters (skipping `.init` call sites).
    for match in re.finditer(r"\binit\b", stripped):
        if match.start() > 0 and stripped[match.start() - 1] == ".":
            continue
        record_params(match.end())
    # Closure parameters: `{ x, y in` and `{ (a: Int, b: Int) in` bind inside
    # the closure body only.
    for match in re.finditer(r"\{(?:[ \t]*\[[^\]]*\][ \t]*)?([\w\s,()<>:.?!&@~*+\-]*?)\bin\b", stripped):
        region_start, region_end = match.start(1), match.end(1)
        depth, cut = 0, region_end
        for p in range(region_start, region_end - 1):
            c = stripped[p]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "-" and stripped[p + 1] == ">" and depth == 0:
                cut = p
                break
        # `{ (a: Int) in` wraps the parameter list in one paren layer.
        rs, re_ = region_start, cut
        while rs < re_ and stripped[rs] in " \t":
            rs += 1
        while re_ > rs and stripped[re_ - 1] in " \t":
            re_ -= 1
        if rs < re_ and stripped[rs] == "(" and stripped[re_ - 1] == ")":
            rs, re_ = rs + 1, re_ - 1
        body = close_of.get(match.start())
        for pname, ps, pe in binding_spans(rs, re_):
            shadows[pname].append((ps, pe))
            if body is not None:
                shadows[pname].append((match.end(), body))
    return top, shadows


def _call_labels(text: str, pos: int) -> tuple[str, ...] | None:
    """Argument labels at a call site: `f(x: 1, y: 2)` -> ('x', 'y');
    positional arguments label as `_`. None when `pos` isn't a `(`."""
    n = len(text)
    j = pos
    while j < n and text[j] in " \t?!":
        j += 1
    if j >= n or text[j] != "(":
        return None
    d, k = 1, j + 1
    while k < n and d:
        d += text[k] == "("
        d -= text[k] == ")"
        k += 1
    labels: list[str] = []
    depth, angle, seg_start = 0, 0, j + 1
    end = k - 1
    for i in range(seg_start, end + 1):
        c = text[i] if i < end else ","
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "<" and i + 1 < end and text[i + 1] not in "=<> \t":
            angle += 1
        elif c == ">" and angle:
            angle -= 1
        elif c == "," and depth == 0 and angle == 0:
            head_end, hd, ha = i, 0, 0
            for p in range(seg_start, i):
                c2 = text[p]
                if c2 in "([{":
                    hd += 1
                elif c2 in ")]}":
                    hd -= 1
                elif c2 == "<" and p + 1 < i and text[p + 1] not in "=<> \t":
                    ha += 1
                elif c2 == ">" and ha:
                    ha -= 1
                elif c2 == ":" and hd == 0 and ha == 0:
                    head_end = p
                    break
            if not text[seg_start:i].strip():
                seg_start = i + 1
                continue
            ids = _IDENT.findall(text[seg_start:head_end])
            labels.append(ids[0] if (head_end != i and ids) else "_")
            seg_start = i + 1
    return tuple(labels)


def _resolve_overload(text: str, pos: int, cand: list[tuple[str, tuple | None]]) -> set[str]:
    """The component a call through an overloaded name can bind to: a
    single owner when the call-site labels select one signature, else
    every candidate (legal overloads must not launder R1/R2 debt)."""
    labels = _call_labels(text, pos)
    if labels is not None:
        matched = {comp for comp, sig in cand if sig is not None and tuple(lbl for lbl, _anno in sig[0]) == labels}
        if len(matched) == 1:
            return matched
    return {comp for comp, _sig in cand}


class Manifest:
    def __init__(self, data: dict):
        self.layers: list[str] = data["layers"]
        self.rank = {name: index for index, name in enumerate(self.layers)}
        self.contracts_dir: str = data.get("contractsDirectory", "Contracts")
        self.contracts_layer: str = data["contractsLayer"]
        self.root_component: str = data["servicesRootComponent"]
        # Repo-relative paths the app target does not compile (project.yml
        # excludes) — they must not feed the graph.
        self.path_exclusions: list[str] = [p.rstrip("/") for p in data.get("pathExclusions", [])]
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
            if any(rel == e or rel.startswith(e + "/") for e in manifest.path_exclusions):
                continue
            if rel.startswith(SCAN_ROOT + "/Lab/"):
                continue  # Lab compiles only in the Lab configuration; lab-boundary gates it.
            sources[rel] = strip_source(path.read_text(encoding="utf-8", errors="ignore"))

        self.file_component: dict[str, str] = {}
        shadow_map: dict[str, dict[str, list[tuple[int, int]]]] = {}
        owners: dict[str, set[str]] = collections.defaultdict(set)
        declared_in: dict[str, set[str]] = collections.defaultdict(set)
        decl_entries: dict[str, list[tuple[str, str, tuple | None]]] = collections.defaultdict(list)
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
            for name, entries in top.items():
                owners[name].add(component)
                declared_in[name].add(rel)
                decl_entries[name].extend((component, kind, sig) for kind, sig in entries)
        # name -> files declaring it, for every name declared by more than
        # one component (R5). Valid overloads are exempt: same-named funcs
        # in different components are legal Swift as long as no (label,
        # annotation) signature repeats across components. Any non-callable
        # duplicate or a signature collision is still ambiguous — an edge
        # through the name cannot be attributed.
        self.ambiguous: dict[str, list[str]] = {}
        for name, entries in decl_entries.items():
            if len({comp for comp, _kind, _sig in entries}) <= 1:
                continue
            conflict = True
            if all(kind == "func" for _comp, kind, _sig in entries):
                seen: dict[tuple | None, str] = {}
                conflict = False
                for comp, _kind, sig in entries:
                    if sig in seen and seen[sig] != comp:
                        conflict = True
                        break
                    seen[sig] = comp
            if conflict:
                self.ambiguous[name] = sorted(declared_in[name])
        # Legal overloads keep their candidate owners: a use resolves by
        # call-site labels, and an unresolvable use edges to every
        # candidate, so overloads cannot launder R1/R2 debt.
        candidates: dict[str, list[tuple[str, tuple | None]]] = {
            name: [(comp, sig) for comp, _kind, sig in entries]
            for name, entries in decl_entries.items()
            if name not in self.ambiguous and len({comp for comp, _kind, _sig in entries}) > 1
        }
        owner = {name: next(iter(comps)) for name, comps in owners.items() if len(comps) == 1}
        # Custom operators (`func <~>`) carry dependencies too; `_IDENT`
        # cannot see them, so each owned operator is matched as a maximal
        # operator-char token.
        op_class = re.escape("".join(_OP_CHARS))
        op_patterns = {
            name: re.compile(rf"(?<![{op_class}]){re.escape(name)}(?![{op_class}])")
            for name in owner
            if not name[0].isalpha() and name[0] != "_"
        }

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
                if target is not None:
                    if target != component:
                        self.refs[(component, target)][name].add(rel)
                    continue
                for t in _resolve_overload(text, match.end(), candidates.get(name, [])):
                    if t != component:
                        self.refs[(component, t)][name].add(rel)
            for name, pattern in op_patterns.items():
                target = owner[name]
                if target != component and pattern.search(text):
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


def _show_at_ref(repo: Path, ref: str, rel: str) -> str | None:
    shown = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{rel}"], capture_output=True, text=True)
    return shown.stdout if shown.returncode == 0 else None


def base_regressions(
    repo: Path,
    ref: str,
    baseline_path: Path,
    baseline: dict,
    manifest_path: Path,
    manifest: dict,
) -> list[str]:
    """Where the committed baseline or manifest allows more debt than at `ref`."""
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
    raised: list[str] = []

    rel = baseline_path.resolve().relative_to(repo).as_posix()
    shown = _show_at_ref(repo, ref, rel)
    if shown is None:
        print(f"services-layering: {rel} is new relative to {ref}; allowed")
    else:
        old = json.loads(shown)
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

    # Reclassifying a component to a higher layer would launder debt the
    # baseline never had to record, so the layer map is pinned to base.
    manifest_rel = manifest_path.resolve().relative_to(repo).as_posix()
    shown = _show_at_ref(repo, ref, manifest_rel)
    if shown is None:
        print(f"services-layering: {manifest_rel} is new relative to {ref}; allowed")
    else:
        old_manifest = json.loads(shown)
        if old_manifest.get("layers") != manifest.get("layers"):
            raised.append("manifest layer order differs from base")
        for key in ("rootPrefix", "servicesRootComponent", "contractsDirectory", "contractsLayer", "pathExclusions"):
            if old_manifest.get(key) != manifest.get(key):
                raised.append(f"manifest setting {key} differs from base")
        old_layers = {c["name"]: c["layer"] for c in old_manifest.get("components", [])}
        old_paths = {c["name"]: sorted(c.get("paths", [])) for c in old_manifest.get("components", [])}
        for component in manifest.get("components", []):
            name = component["name"]
            if name in old_layers:
                if old_layers[name] != component["layer"]:
                    raised.append(
                        f"manifest reclassifies {name} {old_layers[name]} -> {component['layer']} (absent at base)"
                    )
                if old_paths[name] != sorted(component.get("paths", [])):
                    raised.append(f"manifest repaths {name} ({old_paths[name]} -> {component.get('paths', [])})")
                continue
            # A newly named component may only cover directories that were not
            # owned at base; a path under an existing component's root would
            # reclassify that component's files via longest-prefix matching.
            for path in component.get("paths", []):
                for base_name, base_list in old_paths.items():
                    for base_path in base_list:
                        if path == base_path or path.startswith(base_path + "/") or base_path.startswith(path + "/"):
                            raised.append(f"manifest adds component {name} at {path} overlapping {base_name} at base")
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
    manifest_path = Path(args.manifest) if args.manifest else repo / "config/services-layers.json"
    manifest_data = load_json(manifest_path)
    manifest = Manifest(manifest_data)
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
    base_failures = (
        base_regressions(repo, args.base, baseline_path, baseline, manifest_path, manifest_data) if args.base else []
    )
    return check(graph, baseline, base_failures)


if __name__ == "__main__":
    sys.exit(main())
