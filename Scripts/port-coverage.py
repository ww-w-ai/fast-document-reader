#!/usr/bin/env python3
"""Measure how much of the Swift engine layer the Rust transliteration accounts for.

A single number decides whether phase A is done: every line of every Swift file in the port
manifest must be claimed by a provenance comment in the Rust tree.

Provenance comes in two shapes:

    //! swift: Sources/FastDocReader/Render/Office/DocxReader.swift
    //! swift-range: 1-40

    // swift: Render/Office/DocxReader.swift:120-168

The module-level form names the file the whole Rust module transliterates; every later
`swift-range` in that file is read against it. The line form carries its own path, so a Rust
file may claim ranges from more than one Swift file.

A range wide enough to swallow a whole file proves nothing — it reads 100% over any hole — so a
claim past MODULE_SPAN_CAP (module form) or RANGE_SPAN_CAP (line form) is rejected rather than
counted, and named in the report. The module form exists for the file header only; the line form
is meant to sit on one declaration, comments included.

Parsing is not aiming. A claim whose numbers are stale still parses, is still counted, and is
invisible. So a claim is also checked against the Swift file it names: one that runs past the end
of that file, or names a file that is not there at all, is AIMLESS and reported the way MALFORMED
is — both are credited to nothing while looking exactly like a claim that works.

What is NOT aimless: a claim on a BLANK line. Every module here ends with a block of them, under a
comment saying so — closing braces and blank separators that the per-item markers did not restate,
claimed deliberately so the denominator is accounted for rather than quietly missed. Flagging those
would be telling the port to stop doing the one thing that makes its own number honest. A claim on
COMMENT lines is likewise fine: porting a doc block is a real thing to claim.

A range under the cap can still read 100% over a hole: a hundred-line TYPE claimed by every Rust
item that lives inside it covers itself many times over, so no single claim can be wrong enough to
show. A range of REPEATED_WIDE_LINES or more claimed from REPEATED_WIDE_SITES or more places is
rejected the way a blanket is -- a type is transliterated by ONE Rust item.

The boundary blocks are bookkeeping, not code: their entries name single blank lines and closing
braces. Nothing may widen them. An entry there spanning a declaration is claiming code under a
heading that says it is not.

Run with --gate to make an incomplete port a non-zero exit.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SWIFT_ROOT = REPO / "Sources" / "FastDocReader"
RUST_ROOT = REPO / "rust" / "crates" / "fastdoc-engine" / "src"
MANIFEST = REPO / "rust" / "PORT-MANIFEST.txt"

# `// swift: <path>:<start>-<end>` — the path may be given from the repo root or from
# Sources/FastDocReader, because a worker reading one file should not have to think about it.
# The `\b` at the end is load-bearing in one direction and blind in another: `231a` fails to
# match at all (MALFORMED, loud), but `22,30-34` matches the `22` and DROPS the rest without a
# word. So a claim that continues with a comma is rejected here rather than silently narrowed —
# write one range per line, which is the only form this file has ever really supported.
LINE_FORM = re.compile(r"//!?\s*swift:\s*(\S+?):(\d+)(?:-(\d+))?(?![,\d-])")
MODULE_FILE = re.compile(r"//!\s*swift:\s*(\S+?)\s*$")
MODULE_RANGE = re.compile(r"//!\s*swift-range:\s*(\d+)(?:-(\d+))?\b")
# A line that MEANT to claim lines: it names a path-with-digits or a swift-range. Prose annotations
# like `/// swift: \`borderColor(for:)\` read through base` claim nothing and are not malformed.
# What must never happen silently is a claim that looks right, parses as nothing, and counts as zero.
CLAIM_LIKE = re.compile(r"//!?\s*(swift-range:\s*\S|swift:\s*\S+\.swift:)")
TODO_CALL = re.compile(r"\btodo!\s*\(")
# A region the port is not answerable for, named where it lives. See `excluded_lines`.
PORT_EXCLUDE = re.compile(r"//\s*port-exclude:\s*(.+)$")
PORT_EXCLUDE_END = re.compile(r"//\s*port-exclude-end\b")
# The declaration a claim SITS ON, used to ask whether its Swift range mentions the same name.
SWIFT_DECL = re.compile(r"^\s*(?:private |public )?(?:static )?(?:func|struct|enum)\s+\w+", re.M)
RUST_DECL = re.compile(r"^\s*(?:pub\(crate\)\s+|pub\s+)?(?:const\s+|static\s+)?(?:struct|enum|fn)\s+(\w+)")
# How many claims currently fail that check. A RATCHET, not a target: this may only go down.
# Every one of these points at Swift code that is not what the Rust beside it transliterates, so
# it is credited to the wrong lines and hides a real hole somewhere else in the same file.
MISAIMED_BUDGET = 0

# A declaration plus its doc comment can be long; a file cannot be one declaration.
RANGE_SPAN_CAP = 300
MODULE_SPAN_CAP = 120
WILDCARD_TODO = re.compile(r"_\s*=>\s*todo!")


def normalize(path: str) -> str:
    """Resolve any of the three ways a worker may spell a Swift path to one key."""
    p = path.replace("\\", "/")
    for prefix in ("Sources/FastDocReader/", "./"):
        if p.startswith(prefix):
            p = p[len(prefix):]
    return p


def swift_files_in_scope() -> tuple[dict[str, set[int]], list[str]]:
    """Which LINE NUMBERS of each manifest file the port is answerable for, and what was excluded.

    A set of raw line numbers, not a count. A claim carries the number an author read in an editor,
    so scoring it against anything but raw numbers silently misaligns every claim below the first
    exclusion — which is what the count this replaced did.
    """
    if not MANIFEST.exists():
        sys.exit(f"port manifest missing: {MANIFEST}")
    scope: dict[str, set[int]] = {}
    notes: list[str] = []
    for raw in MANIFEST.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key = normalize(line)
        full = SWIFT_ROOT / key
        if not full.exists():
            sys.exit(f"port manifest names a file that does not exist: {key}")
        lines = full.read_text(errors="replace").splitlines()
        dropped, why = excluded_lines(key, lines)
        scope[key] = set(range(1, len(lines) + 1)) - dropped
        notes.extend(why)
    return scope, notes


def excluded_lines(key: str, lines: list[str]) -> tuple[set[int], list[str]]:
    """Lines the port is NOT answerable for, named one region at a time.

        // port-exclude: <reason>
        ...
        // port-exclude-end

    Both markers count as excluded. An unclosed region runs to the end of the file and says so, so
    a missing end-marker cannot quietly swallow the rest of a file's denominator.

    This is deliberately a MARKER and not an inference. The mechanism it replaces looked for
    `#if FMD_RUST_ENGINE` regions, which is how the bridge used to be spelled — and when the engine
    became unconditional and `546f379` deleted the flag from the source, the exclusion stopped
    excluding anything and nobody noticed, because a coverage number that quietly gets HARDER to
    reach reads exactly like work left to do. A marker has to be written down, so it can be argued
    with; a `#if` that no longer exists cannot be.
    """
    dropped: set[int] = set()
    notes: list[str] = []
    start: int | None = None
    reason = ""
    for n, text in enumerate(lines, 1):
        stripped = text.strip()
        if start is None:
            hit = PORT_EXCLUDE.match(stripped)
            if hit:
                start, reason = n, hit.group(1).strip()
            continue
        if PORT_EXCLUDE_END.match(stripped):
            dropped.update(range(start, n + 1))
            notes.append(f"{key}:{start}-{n}  ({n - start + 1} lines)  {reason}")
            start = None
    if start is not None:
        dropped.update(range(start, len(lines) + 1))
        notes.append(f"{key}:{start}-{len(lines)}  ({len(lines) - start + 1} lines)  "
                     f"{reason}  [UNCLOSED — no port-exclude-end]")
    return dropped, notes


def claimed_ranges():
    """Walk the Rust tree once, returning claimed line numbers per Swift file.

    `sites` carries every accepted line-form claim with the place that made it, so a later pass can
    ask whether the claim actually LANDS on anything — a question the ranges alone cannot answer
    once they have been merged into a set.
    """
    claimed: dict[str, set[int]] = {}
    wildcards: list[str] = []
    malformed: list[str] = []
    todos: list[str | None] = []
    blankets: list[str] = []
    sites: list[tuple[str, int, int, str]] = []
    # The declaration each claim site sits on, for `misaimed_claims`.
    decl_of: dict[str, str] = {}
    if not RUST_ROOT.exists():
        return claimed, todos, wildcards, blankets, malformed, sites, decl_of

    for rs in sorted(RUST_ROOT.rglob("*.rs")):
        module_target: str | None = None
        lines_after = rs.read_text(errors="replace").splitlines()
        for lineno, text in enumerate(lines_after, 1):
            stripped = text.lstrip()
            in_comment = stripped.startswith("//")
            if not in_comment:
                for _ in TODO_CALL.findall(text):
                    todos.append(module_target)
            if not in_comment and WILDCARD_TODO.search(text):
                wildcards.append((module_target, f"{rs.relative_to(REPO)}:{lineno}"))

            hit = LINE_FORM.search(text)
            if hit:
                key = normalize(hit.group(1))
                lo = int(hit.group(2))
                hi = int(hit.group(3)) if hit.group(3) else lo
                if hi - lo + 1 > RANGE_SPAN_CAP:
                    blankets.append((key, f"{rs.relative_to(REPO)}:{lineno}  claims {lo}-{hi} of {key}"))
                else:
                    claimed.setdefault(key, set()).update(range(lo, hi + 1))
                    site = f"{rs.relative_to(REPO)}:{lineno}"
                    sites.append((key, lo, hi, site))
                    # The declaration this claim SITS ON is the thing it is about. Doc comments,
                    # attributes and blank lines stand between the two often enough that a fixed
                    # four-line window silently missed them -- and a missed name is a claim the
                    # misaim check never judges, which is how a whole shifted region hid.
                    for ahead in lines_after[lineno:lineno + 15]:
                        stripped = ahead.strip()
                        if not stripped or stripped.startswith(("//", "#[")):
                            continue
                        found = RUST_DECL.match(ahead)
                        if found:
                            decl_of[site] = found.group(1)
                        break
                continue

            hit = MODULE_RANGE.search(text)
            if hit and module_target:
                lo = int(hit.group(1))
                hi = int(hit.group(2)) if hit.group(2) else lo
                if hi - lo + 1 > MODULE_SPAN_CAP:
                    blankets.append((module_target, f"{rs.relative_to(REPO)}:{lineno}  claims {lo}-{hi} of {module_target}"))
                else:
                    claimed.setdefault(module_target, set()).update(range(lo, hi + 1))
                continue

            hit = MODULE_FILE.search(text)
            if hit:
                module_target = normalize(hit.group(1))
                continue

            if CLAIM_LIKE.search(text):
                malformed.append(f"{rs.relative_to(REPO)}:{lineno}  {text.strip()[:90]}")
    return claimed, todos, wildcards, blankets, malformed, sites, decl_of


def misaimed_claims(sites, decl_of):
    """Claims whose Swift range never mentions the declaration the Rust beside them defines.

    A weaker question than "is this claim right", and deliberately so: it needs no judgement and no
    per-item review, which is what lets it run on every commit. A range that legitimately covers a
    body without restating the name is a false positive, and that is the price of a check that
    cannot be argued with.

    It exists because `aimless_claims` cannot see this class at all. A stale claim lands on REAL
    lines of a REAL file — it parses, it is credited, and the percentage never moves. Measured when
    this was added: 174 of 641 checkable claims, 27%, including whole files whose every claim was
    40-53 lines out. Fixing them made coverage go DOWN, because the lines they had been covering by
    accident were never ported.
    """
    def camel(name):
        head, *rest = name.split("_")
        return head + "".join(p.capitalize() for p in rest)

    cache: dict[str, list[str] | None] = {}
    out: list[str] = []
    unjudgeable = 0
    for key, lo, hi, site in sites:
        name = decl_of.get(site)
        if name is None:
            continue
        if key not in cache:
            full = SWIFT_ROOT / key
            cache[key] = full.read_text(errors="replace").splitlines() if full.exists() else None
        lines = cache[key]
        if lines is None or hi > len(lines):
            continue
        wanted = camel(name)
        decl_re = re.compile(
            r"^\s*(?:private |public |internal |fileprivate )?(?:static )?"
            r"(?:func|struct|enum|class|var|let)\s+" + re.escape(wanted) + r"\b", re.M)
        # A DECLARATION in range, not a mention. Prose says a name too: `EdgeBorders` appears in
        # `BorderDecl`'s doc comment, which is how a claim twenty lines out from the struct it
        # names read as correctly aimed for as long as a bare word search was the test. When the
        # file declares the name exactly once, that line is where the claim has to land.
        whole = "\n".join(lines)
        declared_at = [n for n, text in enumerate(lines, 1) if decl_re.match(text)]
        if len(declared_at) == 1:
            if lo <= declared_at[0] <= hi:
                continue
        elif re.search(r"\b" + re.escape(wanted) + r"\b", "\n".join(lines[lo - 1:hi])):
            continue
        # The name has to exist SOMEWHERE in that file for its absence here to mean anything.
        # A Rust `new` against a Swift `init`, or a helper split out of a longer Swift function,
        # has no twin to be aimed at — the check has no evidence either way and must not pretend
        # otherwise. Measured when this was tightened: 71 of 80 were this, and counting them made
        # the number look like a backlog eight times its real size.
        if not SWIFT_DECL.search(whole) or not declared_at:
            unjudgeable += 1
            continue
        span = f"{lo}-{hi}" if lo != hi else f"{lo}"
        out.append(f"{site}  claims {key}:{span} — no `{wanted}` in those lines")
    return out, unjudgeable


SWIFT_ANY_DECL = re.compile(
    r"^(\s*)(?:@\w+\s+)?"
    r"(?:(?:private|public|internal|fileprivate|open|static|final|mutating|nonmutating|override"
    r"|lazy|weak|unowned|indirect)\s+)*"
    r"(func|struct|enum|class|var|let)\s+(\w+)")

# A ratchet, like MISAIMED_BUDGET was: this many claims reach past the declaration they name, and
# the gate fails if that grows. Not zero, because it is not a defect this repair introduced —
# HEAD carries 114 of them and 2,108 lines of reach, against 58 and 1,092 here. The count is here
# so the backlog cannot get quietly bigger between the session that measured it and the session
# that clears it -- lower both numbers whenever you clear some.
OVERREACH_BUDGET = 58
# Counting entries alone is not a ratchet: widening a claim already counted leaves the number
# flat. The reach itself is held too, so growing one claim costs as much as adding one.
OVERREACH_SLACK_BUDGET = 1092
OVERREACH_SLACK = 5


def _swift_declaration_spans(key: str) -> dict[str, tuple[int, int, str]] | None:
    """Every uniquely-named Swift declaration in one file, as (doc start, closing brace, kind).

    A name declared twice maps to None: there is no single span to judge a claim against, and
    guessing which one was meant is how a repair pass once replaced a correct twenty-line claim
    with a one-line span somewhere else.
    """
    full = SWIFT_ROOT / key
    if not full.exists():
        return None
    lines = full.read_text(errors="replace").splitlines()
    out: dict[str, tuple[int, int, str] | None] = {}
    for n, text in enumerate(lines, 1):
        hit = SWIFT_ANY_DECL.match(text)
        if not hit:
            continue
        indent, kind, name = hit.group(1), hit.group(2), hit.group(3)
        if name in out:
            out[name] = None
            continue
        start = n
        while start - 1 >= 1 and lines[start - 2].lstrip().startswith("///"):
            start -= 1
        # A multi-line signature does not end on its own first line: `OfficeTextBuilder.build`
        # takes fifteen lines to state its parameters, and stopping at the first line reads as a
        # 5-line declaration with a 256-line claim around it -- the reach was the measurement.
        # The scan follows UNBALANCED PARENTHESES rather than a line budget, so a `let` with no
        # body cannot run on into the next declaration's brace and swallow it.
        head, depth = n, text.count("(") - text.count(")")
        while head < len(lines) and depth > 0 and head - n < 40:
            head += 1
            depth += lines[head - 1].count("(") - lines[head - 1].count(")")
        if lines[head - 1].rstrip().endswith("{"):
            close, end = indent + "}", head
            while end < len(lines) and lines[end - 1] != close:
                end += 1
        else:
            end = n
        out[name] = (start, end, kind)
    return {k: v for k, v in out.items() if v is not None}


def overreaching_claims(sites, decl_of) -> list[str]:
    """Claims that cover much more than the declaration they are written on.

    The misaim check asks whether a claim CONTAINS its declaration, which a seventy-line range
    around a four-line enum satisfies as easily as a right one. That is deliberate — a Rust item
    may legitimately transliterate a Swift function plus its private helpers — so this is a count
    with a budget rather than a rule, and it exists to keep the count from drifting upward.
    """
    cache: dict[str, dict[str, tuple[int, int, str]] | None] = {}

    def camel(name):
        head, *rest = name.split("_")
        return head + "".join(p.capitalize() for p in rest)

    out = []
    for key, lo, hi, site in sites:
        name = decl_of.get(site)
        if name is None:
            continue
        if key not in cache:
            cache[key] = _swift_declaration_spans(key)
        spans = cache[key]
        if not spans:
            continue
        span = spans.get(camel(name))
        if span is None:
            continue
        start, end, kind = span
        # `decl_of` only ever holds a Rust struct/enum/fn, so a Swift stored property is not the
        # twin of anything here — a Rust `fn width` beside a Swift `var width` is a name
        # collision, and measuring its reach would be measuring noise.
        if kind in ("var", "let"):
            continue
        slack = max(0, start - lo) + max(0, hi - end)
        if slack > OVERREACH_SLACK:
            out.append((slack, f"{site}  claims {key}:{lo}-{hi} for `{name}` "
                               f"(span {start}-{end}, +{slack})"))
    return out


BOUNDARY_HEADING = "// Boundary lines"
BOUNDARY_SPAN_CAP = 16


def overwide_boundary_claims() -> list[str]:
    """A boundary entry that grew wide enough to be claiming code.

    Each module ends with a block accounting for the lines the per-item markers did not restate:
    blank separators, closing braces, and the short field/case lines already covered in substance
    above. Every one of those is a line or a handful. A repair pass that walks claims out to their
    enclosing declaration will happily widen these too, and then the block is claiming whole
    functions under a heading that says it is bookkeeping — measured when this was added, one such
    pass turned 105 of 263 entries into declaration-sized ranges, the widest 53 lines.

    The cap is set from what the convention has always actually held: the widest legitimate entry
    in this tree is 13 lines, a run of closing braces and blank lines between two types.
    """
    out: list[str] = []
    for rs in sorted(RUST_ROOT.rglob("*.rs")):
        lines = rs.read_text(errors="replace").splitlines()
        for start, text in enumerate(lines):
            if not text.startswith(BOUNDARY_HEADING):
                continue
            n = start
            while n + 1 < len(lines) and (lines[n + 1].startswith("//") or not lines[n + 1].strip()):
                n += 1
                hit = LINE_FORM.search(lines[n])
                if not hit:
                    continue
                lo = int(hit.group(2))
                hi = int(hit.group(3) or lo)
                if hi - lo + 1 > BOUNDARY_SPAN_CAP:
                    out.append(f"{rs.relative_to(REPO)}:{n + 1}  {hit.group(1)}:{lo}-{hi} "
                               f"({hi - lo + 1} lines) — a boundary entry, not a claim on code")
    return out


REPEATED_WIDE_LINES = 100
REPEATED_WIDE_SITES = 3


def repeated_wide_claims(sites: list[tuple[str, int, int, str]]) -> list[str]:
    """One wide Swift range claimed over and over from inside itself.

    A `BLANKET` claim is caught by its width alone. This is the same defect under the cap: a
    hundred-line Swift TYPE claimed by every Rust item that lives inside it. Each claim looks
    modest, none trips the blanket rule, and together they cover the type many times over — so
    every line reads as ported and moving any one claim changes nothing. Measured when this was
    added: a growth pass that walked each claim out to its enclosing declaration produced 56
    claims all naming `MDAttr.swift:3-205` and drove the number to a 100% that no mutation could
    disturb. A range this wide is a TYPE, and a type is transliterated by ONE Rust item.
    """
    seen: dict[tuple[str, int, int], list[str]] = {}
    for key, lo, hi, site in sites:
        if hi - lo + 1 >= REPEATED_WIDE_LINES:
            seen.setdefault((key, lo, hi), []).append(site)
    return [f"{key}:{lo}-{hi}  ({hi - lo + 1} lines) claimed by {len(where)} sites, e.g. {where[0]}"
            for (key, lo, hi), where in sorted(seen.items())
            if len(where) >= REPEATED_WIDE_SITES]


def aimless_claims(sites: list[tuple[str, int, int, str]]) -> list[str]:
    """Claims that parse but can never be credited.

    Two ways a claim can be exactly as wrong as an unparseable one while costing nothing to notice:
    it names a Swift file that is not there, or it runs past the end of the file it names. Neither
    can put a single line in the covered set, and neither says so.

    Read against the RAW file, because a claim's numbers are what the author read in an editor —
    not the `#if FMD_RUST_ENGINE`-stripped view the percentage is scored against.

    BLANK and COMMENT lines are deliberately NOT flagged. Blank separators are claimed on purpose
    (see each module's "Boundary lines" block), and a doc block is a real thing for a port to claim.
    An earlier version of this check rejected blank-only claims and named 35 of them — every one
    correct by design.
    """
    cache: dict[str, list[str] | None] = {}
    out: list[str] = []
    for key, lo, hi, site in sites:
        if key not in cache:
            full = SWIFT_ROOT / key
            cache[key] = full.read_text(errors="replace").splitlines() if full.exists() else None
        lines = cache[key]
        span = f"{lo}-{hi}" if lo != hi else f"{lo}"
        if lines is None:
            out.append(f"{site}  claims {key}:{span} — no such Swift file")
        elif hi > len(lines):
            out.append(f"{site}  claims {key}:{span} — past the end ({len(lines)} lines)")
    return out


def as_ranges(numbers: list[int]) -> list[str]:
    out: list[str] = []
    start = prev = None
    for n in numbers:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            out.append(f"{start}-{prev}" if start != prev else f"{start}")
            start = prev = n
    if start is not None:
        out.append(f"{start}-{prev}" if start != prev else f"{start}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("only", nargs="*", help="limit the report to these Swift files")
    ap.add_argument("--gate", action="store_true", help="exit non-zero unless coverage is 100%%")
    ap.add_argument("--gaps", type=int, default=6, help="uncovered ranges to show per file")
    args = ap.parse_args()

    scope, exclusions = swift_files_in_scope()
    if args.only:
        wanted = {normalize(p) for p in args.only}
        scope = {k: v for k, v in scope.items() if k in wanted}
        if not scope:
            sys.exit("none of the named files are in the port manifest")

    claimed, todos, wildcards, blankets, malformed, sites, decl_of = claimed_ranges()
    # A worker gates on ITS OWN files; another sprint's unfinished file must not redden that check.
    if args.only:
        keys = set(scope)
        blankets = [m for k, m in blankets if k in keys]
        wildcards = [m for k, m in wildcards if k in keys]
        todos = [t for t in todos if t in keys]
    else:
        blankets = [m for _, m in blankets]
        wildcards = [m for _, m in wildcards]

    total = covered_total = 0
    rows = []
    for key in sorted(scope):
        allowed = scope[key]
        n = len(allowed)
        hit = claimed.get(key, set()) & allowed
        total += n
        covered_total += len(hit)
        missing = as_ranges(sorted(allowed - hit))
        rows.append((key, n, len(hit), missing))

    width = max((len(k) for k, *_ in rows), default=0)
    for key, n, hit, missing in rows:
        pct = 100.0 * hit / n if n else 100.0
        mark = "ok  " if not missing else "GAP "
        print(f"{mark}{key:<{width}}  {hit:>5}/{n:<5} {pct:6.1f}%", end="")
        if missing:
            shown = ", ".join(missing[: args.gaps])
            more = f" (+{len(missing) - args.gaps} more)" if len(missing) > args.gaps else ""
            print(f"   uncovered: {shown}{more}")
        else:
            print()

    pct = 100.0 * covered_total / total if total else 0.0
    print(f"\ncoverage {covered_total}/{total} lines = {pct:.2f}%   todo!() = {len(todos)}")
    if malformed:
        print(f"MALFORMED claims (announced but unparseable — silently counted for nothing): {len(malformed)}")
        for m in malformed[:12]:
            print(f"  {m}")
    if exclusions:
        dropped = sum(int(e.split("(")[1].split(" lines")[0]) for e in exclusions)
        print(f"\nEXCLUDED from the denominator ({dropped} lines the port is not answerable for):")
        for e in exclusions:
            print(f"  {e}")
    misaimed, unjudgeable = misaimed_claims(sites, decl_of)
    if misaimed or unjudgeable:
        over = " — OVER BUDGET" if len(misaimed) > MISAIMED_BUDGET else ""
        print(f"MISAIMED claims (credited to the wrong lines, budget {MISAIMED_BUDGET}): "
              f"{len(misaimed)}{over}")
        for m in misaimed[:8]:
            print(f"  {m}")
    if unjudgeable:
        print(f"  ({unjudgeable} further claims could not be judged — the Swift file declares no "
              f"such name, so their range proves nothing either way)")
    aimless = aimless_claims(sites)
    if aimless:
        print(f"AIMLESS claims (they parse, they look like claims, and they can credit nothing): {len(aimless)}")
        for a in aimless[:12]:
            print(f"  {a}")
    overreaching = overreaching_claims(sites, decl_of)
    reach = sum(slack for slack, _ in overreaching)
    over_ratchet = len(overreaching) > OVERREACH_BUDGET or reach > OVERREACH_SLACK_BUDGET
    if over_ratchet:
        print(f"OVERREACHING claims (they contain their declaration but cover far more): "
              f"{len(overreaching)} claims / {reach} lines of reach — OVER BUDGET "
              f"({OVERREACH_BUDGET} / {OVERREACH_SLACK_BUDGET})")
        for _, o in sorted(overreaching, reverse=True)[:8]:
            print(f"  {o}")
    elif overreaching:
        print(f"overreaching claims: {len(overreaching)} / {reach} lines of reach "
              f"(ratchet {OVERREACH_BUDGET} / {OVERREACH_SLACK_BUDGET} — lower both when you "
              f"clear some)")
    overwide = overwide_boundary_claims()
    if overwide:
        print(f"OVERWIDE boundary entries (bookkeeping blocks claiming code): {len(overwide)}")
        for o in overwide[:12]:
            print(f"  {o}")
    repeated = repeated_wide_claims(sites)
    if repeated:
        print(f"REPEATED-WIDE claims (a type claimed from inside itself — 100% over a hole): "
              f"{len(repeated)}")
        for r in repeated[:12]:
            print(f"  {r}")
    if blankets:
        print(f"BLANKET claims (rejected — a range this wide reads 100% over a hole): {len(blankets)}")
        for b in blankets[:12]:
            print(f"  {b}")
    if wildcards:
        print(f"WILDCARD todo! (forbidden — a dropped branch coverage cannot see): {len(wildcards)}")
        for w in wildcards[:10]:
            print(f"  {w}")

    if args.gate:
        unclosed = [e for e in exclusions if "UNCLOSED" in e]
        if (pct < 100.0 or wildcards or blankets or malformed or aimless or unclosed
                or repeated or overwide or len(misaimed) > MISAIMED_BUDGET
                or over_ratchet):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
