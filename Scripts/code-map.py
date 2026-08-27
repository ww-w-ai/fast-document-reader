#!/usr/bin/env python3
"""Regenerate the facts a sprint keeps re-deriving.

Measured on this repository's own migration run: exploration was the single largest cost
(12.4 h of 24.3 h of active work), and a large share of it was the SAME questions asked again by
each fresh agent — `todo!(` inventoried 20 times, one call-site census counted three times in one
sprint by three different readers.

These facts go stale the moment code moves, so they must never be hand-written into a document.
This script derives them from the tree every time it runs.

    python3 Scripts/code-map.py            # writes .ww-w-ai/cowork-sprint/code-map.md
    python3 Scripts/code-map.py --stdout   # prints instead

Give the output to a reviewer or an implementer with the task, so neither has to re-count.
"""
from __future__ import annotations
import argparse, os, re, subprocess, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP = re.compile(r"/(target|\.build|\.git|node_modules|Vendor)/")


def walk(sub: str, ext: str) -> list[str]:
    out = []
    for base, dirs, files in os.walk(os.path.join(ROOT, sub)):
        if SKIP.search(base + "/"):
            dirs[:] = []
            continue
        out += [os.path.join(base, f) for f in files if f.endswith(ext)]
    return sorted(out)


def rel(p: str) -> str:
    return os.path.relpath(p, ROOT)


def read(p: str) -> list[str]:
    with open(p, errors="ignore") as f:
        return f.read().split("\n")


CODE_ONLY = re.compile(r"^\s*(//|/\*|\*|#\s|///)")


def is_code(line: str) -> bool:
    """A mention inside a comment is not a call. Counting them is how a census lies."""
    return not CODE_ONLY.match(line)


def rust_public_surface(files):
    """Every `pub fn`, and its call sites split by WHERE they are.

    A function called only from its own file, or only from `#[cfg(test)]`, is not wired into
    anything — which is the state this migration has now found by hand three times.
    """
    defs = {}
    for p in files:
        for i, line in enumerate(read(p), 1):
            m = re.match(r"\s*pub (?:unsafe )?(?:extern \"C\" )?fn (\w+)", line)
            if m:
                defs.setdefault(m.group(1), []).append(f"{rel(p)}:{i}")
    if not defs:
        return defs, {}
    alt = re.compile(r"\b(" + "|".join(map(re.escape, defs)) + r")\s*\(")
    calls = defaultdict(list)
    for p in files:
        lines = read(p)
        in_test = False
        for i, line in enumerate(lines, 1):
            if re.match(r"\s*#\[cfg\(test\)\]", line):
                in_test = True
            if not is_code(line):
                continue
            for m in alt.finditer(line):
                name = m.group(1)
                if re.match(rf"\s*pub .*fn {name}\b", line):
                    continue
                calls[name].append((f"{rel(p)}:{i}", rel(p), in_test))
    return defs, calls


def swift_symbol_census(files, symbols):
    """Call sites for the symbols this migration keeps counting by hand.

    Split into PRODUCTION and TEST, and comments dropped: the number a design decision turns on
    is "how many places in `Sources/` call this", and a census that quietly folds in tests and
    doc comments answers a different question while looking like an answer.
    """
    out = {s: {"prod": [], "test": []} for s in symbols}
    for p in files:
        where = "test" if rel(p).startswith("Tests/") else "prod"
        for i, line in enumerate(read(p), 1):
            if not is_code(line):
                continue
            for s in symbols:
                if s in line and not re.search(rf"(func|var)\s+{re.escape(s.split('.')[-1])}\b", line):
                    out[s][where].append(f"{rel(p)}:{i}")
    return out


def grep(files, pattern):
    rx = re.compile(pattern)
    hits = []
    for p in files:
        for i, line in enumerate(read(p), 1):
            if rx.search(line):
                hits.append((f"{rel(p)}:{i}", line.strip()[:100]))
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--symbols", default="PagePagination.pitch,PagePagination.sheets,"
                    "PagePagination.tablesToPush,PagePagination.oversizedPieces,"
                    "PageBandGeometry.measure,PageBandGeometry.bandHeight,"
                    "TableBlockBuilder.resizeTables,PageGrid.build",
                    help="comma-separated Swift symbols to census")
    args = ap.parse_args()

    rust = walk("rust/crates", ".rs")
    swift = walk("Sources", ".swift") + walk("Tests", ".swift")
    head = os.popen("git -C %s rev-parse --short HEAD" % ROOT).read().strip()

    defs, calls = rust_public_surface(rust)
    own = {n: {d.rsplit(":", 1)[0] for d in ds} for n, ds in defs.items()}
    dead, test_only = [], []
    for n in defs:
        every = calls.get(n, [])
        outside = [c for c in every if c[1] not in own[n]]
        if not [c for c in every if not c[2]]:
            dead.append(n)                      # 어디서도(자기 파일 포함) 비테스트 호출이 없다
        elif outside and all(c[2] for c in outside):
            test_only.append(n)                 # 밖에서는 테스트만 부른다
    dead, test_only = sorted(dead), sorted(test_only)
    todos = [(w, t) for w, t in grep(list(rust), r"todo!\(") if not CODE_ONLY.match(t)]
    gated = sorted({rel(p) for p in swift if any("#if FMD_RUST_ENGINE" in l for l in read(p))})
    exports = [n for n in defs if n.startswith("fastdoc_")]
    swift_calls_ffi = {n: [h[0] for h in grep(swift, rf"\b{n}\s*\(") if is_code(h[1])]
                       for n in exports}
    census = swift_symbol_census(swift, [s for s in args.symbols.split(",") if s])

    L = []
    A = L.append
    A(f"# Code map — generated, do not hand-edit\n")
    A(f"`Scripts/code-map.py` at `{head}`. Regenerate rather than trusting a copy: every number "
      f"below goes stale the moment code moves.\n")

    A(f"\n## Rust public functions with NO production caller anywhere ({len(dead)})\n")
    A("Not one non-test call site, including inside their own file.\n")
    A("**This number IS the not-yet-wired surface of the engine**, and it is expected to be large "
      "mid-migration: the engine is built, the host does not call most of it yet. Watch it FALL as "
      "S6→S9 wire the host — a sprint that claims to have wired something and does not move this "
      "number has not wired it. It is also where the recurring defect hides: a finished function "
      "nothing calls was found by hand three times (`page_pagination.rs`, `page_grid.rs`, "
      "`RustEngineMeasure`) before this list existed.\n")
    for n in dead:
        A(f"- `{n}` — {', '.join(defs[n])}")
    A(f"\n## Rust public functions whose only outside callers are tests ({len(test_only)})\n")
    A("Alive in the suite, dead in the product — the shape S5B2b's single-table export took.\n")
    for n in test_only:
        A(f"- `{n}` — {', '.join(defs[n])}")

    A(f"\n## `todo!()` still standing ({len(todos)})\n")
    for where, text in todos:
        A(f"- `{where}` — {text}")

    A(f"\n## FFI exports and whether Swift calls them ({len(exports)})\n")
    for n in sorted(exports):
        c = swift_calls_ffi.get(n) or []
        A(f"- `{n}` — {'**no Swift caller**' if not c else ', '.join(c[:4]) + ('' if len(c) <= 4 else f' (+{len(c)-4})')}")

    A(f"\n## Swift call-site census ({len(census)} symbols)\n")
    A("The count the plan reviewer, the researcher and the leader each derived separately.\n")
    for s in sorted(census):
        prod, test = census[s]["prod"], census[s]["test"]
        A(f"- `{s}` — **{len(prod)} in Sources/**, {len(test)} in Tests/")
        for c in prod:
            A(f"    - {c}")

    A(f"\n## Files behind `#if FMD_RUST_ENGINE` ({len(gated)})\n")
    A("A shipping build contains none of these — `Package.swift` reads the flag at "
      "manifest-evaluation time.\n")
    for f in gated:
        A(f"- `{f}`")

    text = "\n".join(L) + "\n"
    if args.stdout:
        sys.stdout.write(text)
        return 0
    out = os.path.join(ROOT, ".ww-w-ai/cowork-sprint/code-map.md")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write(text)
    print(f"wrote {rel(out)}  ({len(text.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
