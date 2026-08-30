#!/usr/bin/env python3
"""Measure how much of the Swift engine layer the Rust transliteration accounts for, BY NAME.

A claim names the Swift DECLARATION it transliterates, not a line range:

    //! swift: Sources/FastDocReader/Render/Office/OfficeTextBuilder.swift   (module header)
    // swift: OfficeTextBuilder.build                                        (a declaration)
    // swift: OfficeBlock.swift#ParagraphAnchor.top                          (one in another file)
    // swift-range: Render/Office/DocxReader.swift:1-3                       (no declaration to name)

Line numbers are what the old form got wrong: they point into a file that keeps moving, so a claim
rots the moment Swift is edited and nothing says so. Seven checks existed to police that -- stale
aim, blanket width, a type claimed by everything inside it, bookkeeping blocks claiming code. A
name cannot drift, so those questions stop existing; what remains is whether the name resolves and
whether every declaration is spoken for.

The denominator is every TYPE and FUNCTION in the manifest's Swift files. Fields, cases and
constants are not counted: they are covered by the declaration that owns them, which is the same
rule the old boundary blocks were hand-maintaining one line at a time.

Run with --gate to make an incomplete port a non-zero exit.
"""
from __future__ import annotations
import argparse, re, sys, collections
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SWIFT_ROOT = REPO / "Sources" / "FastDocReader"
RUST_ROOT = REPO / "rust" / "crates" / "fastdoc-engine" / "src"
sys.path.insert(0, str(REPO / "Scripts"))
from swiftindex import declarations

UNIT = {"func", "struct", "enum", "class", "actor", "protocol", "typealias", "init", "subscript"}
NAMED = re.compile(r"^\s*//\s*swift:\s*(?:(\S+\.swift)#)?([A-Za-z_][\w.]*)\s*$")
RANGE = re.compile(r"^\s*//\s*swift-range:\s*(\S+?\.swift):(\d+)(?:-(\d+))?(?:\s|$)")
MODULE = re.compile(r"^\s*//!\s*swift:\s*(\S+\.swift)\s*$")
LEGACY = re.compile(r"^\s*//\s*swift:\s*\S+?\.swift:\d+")
RANGE_BUDGET = 4

MANIFEST = REPO / "rust" / "PORT-MANIFEST.txt"
PORT_EXCLUDE = re.compile(r"//\s*port-exclude:\s*(.+)$")
PORT_EXCLUDE_END = re.compile(r"//\s*port-exclude-end\b")
RANGE_SPAN_CAP = 300
MODULE_SPAN_CAP = 120


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


def swift_units():
    """{swift key: {qualified name: decl line}} for every file in the manifest, minus exclusions."""
    allowed, _keys = swift_files_in_scope()
    out = {}
    for key in allowed:
        lines = (SWIFT_ROOT / key).read_text(errors="replace").splitlines()
        excluded, _notes = excluded_lines(key, lines)
        out[key] = {q: n for q, k, n, _i in declarations(lines)
                    if k in UNIT and n not in excluded}
    return out


def claims():
    """[(swift key, name, site)] plus the range escapes and anything still in the old form."""
    named, ranges, legacy, outside = [], [], [], []
    for rs in sorted(RUST_ROOT.rglob("*.rs")):
        lines = rs.read_text(errors="replace").splitlines()
        module = next((m.group(1) for line in lines if (m := MODULE.match(line))), None)
        if module:
            module = module.replace("Sources/FastDocReader/", "")
        for n, text in enumerate(lines, 1):
            site = f"{rs.relative_to(REPO)}:{n}"
            if LEGACY.match(text):
                legacy.append(f"{site}  {text.strip()[:80]}")
                continue
            if (hit := RANGE.match(text)):
                ranges.append(f"{site}  {hit.group(1)}:{hit.group(2)}-{hit.group(3) or hit.group(2)}")
                continue
            if (hit := NAMED.match(text)):
                key = hit.group(1)
                if key:
                    match = next((k for k in swift_keys if Path(k).name == key), None)
                    if match is None:
                        outside.append(f"{site}  `{hit.group(2)}` in {key}")
                        continue        # a Swift file the manifest leaves out of scope
                    key = match
                named.append((key or module, hit.group(2), site))
    return named, ranges, legacy, outside


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--unclaimed", type=int, default=0)
    args = ap.parse_args()

    units = swift_units()
    global swift_keys
    swift_keys = list(units)
    named, ranges, legacy, outside = claims()

    claimed = collections.defaultdict(list)
    unresolved = []
    for key, name, site in named:
        if key is None or key not in units:
            unresolved.append(f"{site}  `{name}` — no Swift file for this module")
            continue
        if name not in units[key]:
            unresolved.append(f"{site}  `{name}` — {Path(key).name} declares no such thing")
            continue
        claimed[(key, name)].append(site)

    total = sum(len(v) for v in units.values())
    covered = len(claimed)
    pct = covered * 100.0 / total if total else 100.0
    for key in sorted(units):
        miss = [q for q in units[key] if (key, q) not in claimed]
        flag = "ok " if not miss else "GAP"
        print(f"{flag} {key:<52} {len(units[key]) - len(miss):5d}/{len(units[key]):<5d} "
              f"{(len(units[key]) - len(miss)) * 100.0 / max(1, len(units[key])):5.1f}%"
              + (f"   unclaimed: {', '.join(sorted(miss)[:args.unclaimed])}" if miss and args.unclaimed else ""))
    print(f"\ncoverage {covered}/{total} declarations = {pct:.2f}%")

    twice = {k: v for k, v in claimed.items() if len(v) > 1}
    if unresolved:
        print(f"UNRESOLVED claims (they name nothing): {len(unresolved)}")
        for u in unresolved[:12]:
            print(f"  {u}")
    if legacy:
        print(f"LEGACY line-range claims (the form this replaced): {len(legacy)}")
        for l in legacy[:8]:
            print(f"  {l}")
    if twice:
        print(f"split across Rust items: {len(twice)} declarations "
              f"(one Swift declaration ported as several Rust items -- a fact about the port, not a defect)")
        for (key, name), where in list(twice.items())[:6]:
            print(f"  {Path(key).name}#{name} — {', '.join(where)}")
    if outside:
        print(f"claims on files the manifest leaves out of scope: {len(outside)}")
        for o in outside[:6]:
            print(f"  {o}")
    if ranges:
        over = " — OVER BUDGET" if len(ranges) > RANGE_BUDGET else ""
        print(f"range escapes: {len(ranges)} (budget {RANGE_BUDGET}){over}")

    if args.gate and (pct < 100.0 or unresolved or legacy or len(ranges) > RANGE_BUDGET):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
