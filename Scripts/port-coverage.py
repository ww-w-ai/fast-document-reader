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
LINE_FORM = re.compile(r"//!?\s*swift:\s*(\S+?):(\d+)(?:-(\d+))?\b")
MODULE_FILE = re.compile(r"//!\s*swift:\s*(\S+?)\s*$")
MODULE_RANGE = re.compile(r"//!\s*swift-range:\s*(\d+)(?:-(\d+))?\b")
# A line that MEANT to claim lines: it names a path-with-digits or a swift-range. Prose annotations
# like `/// swift: \`borderColor(for:)\` read through base` claim nothing and are not malformed.
# What must never happen silently is a claim that looks right, parses as nothing, and counts as zero.
CLAIM_LIKE = re.compile(r"//!?\s*(swift-range:\s*\S|swift:\s*\S+\.swift:)")
TODO_CALL = re.compile(r"\btodo!\s*\(")

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


def swift_files_in_scope() -> dict[str, int]:
    if not MANIFEST.exists():
        sys.exit(f"port manifest missing: {MANIFEST}")
    scope: dict[str, int] = {}
    for raw in MANIFEST.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key = normalize(line)
        full = SWIFT_ROOT / key
        if not full.exists():
            sys.exit(f"port manifest names a file that does not exist: {key}")
        scope[key] = len(full.read_text(errors="replace").splitlines())
    return scope


def claimed_ranges() -> tuple[dict[str, set[int]], int, list[str], list[str]]:
    """Walk the Rust tree once, returning claimed line numbers per Swift file."""
    claimed: dict[str, set[int]] = {}
    wildcards: list[str] = []
    malformed: list[str] = []
    todos: list[str | None] = []
    blankets: list[str] = []
    if not RUST_ROOT.exists():
        return claimed, todos, wildcards, blankets, malformed

    for rs in sorted(RUST_ROOT.rglob("*.rs")):
        module_target: str | None = None
        for lineno, text in enumerate(rs.read_text(errors="replace").splitlines(), 1):
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
    return claimed, todos, wildcards, blankets, malformed


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

    scope = swift_files_in_scope()
    if args.only:
        wanted = {normalize(p) for p in args.only}
        scope = {k: v for k, v in scope.items() if k in wanted}
        if not scope:
            sys.exit("none of the named files are in the port manifest")

    claimed, todos, wildcards, blankets, malformed = claimed_ranges()
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
        n = scope[key]
        hit = {ln for ln in claimed.get(key, set()) if 1 <= ln <= n}
        total += n
        covered_total += len(hit)
        missing = as_ranges(sorted(set(range(1, n + 1)) - hit))
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
    if blankets:
        print(f"BLANKET claims (rejected — a range this wide reads 100% over a hole): {len(blankets)}")
        for b in blankets[:12]:
            print(f"  {b}")
    if wildcards:
        print(f"WILDCARD todo! (forbidden — a dropped branch coverage cannot see): {len(wildcards)}")
        for w in wildcards[:10]:
            print(f"  {w}")

    if args.gate:
        if pct < 100.0 or wildcards or blankets or malformed:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
