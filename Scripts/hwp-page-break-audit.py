#!/usr/bin/env python3
"""Compare HWP page-break declarations with rhwp's recorded page starts."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


PARAGRAPH = re.compile(r"--- 문단 (\d+)\.(\d+) ---.*\[(쪽나누기|구역나누기)\]")
PAGE = re.compile(r"=== 페이지 \d+ .*section=(\d+)")
FIRST_ITEM = re.compile(
    r"\s+(?:FullParagraph|PartialParagraph|Table|PartialTable|Shape|HiddenEmptyPara)\s+pi=(\d+)"
)


def run(rhwp: Path, command: str, document: Path) -> list[str]:
    result = subprocess.run(
        [str(rhwp), command, str(document)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"rhwp {command} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.splitlines()


def declarations(lines: list[str]) -> list[tuple[int, int, str]]:
    found = []
    for line in lines:
        if match := PARAGRAPH.match(line):
            found.append((int(match[1]), int(match[2]), match[3]))
    return found


def recorded_page_starts(lines: list[str]) -> set[tuple[int, int]]:
    found: set[tuple[int, int]] = set()
    section: int | None = None
    awaiting_first_item = False
    for line in lines:
        if match := PAGE.match(line):
            section = int(match[1])
            awaiting_first_item = True
            continue
        if awaiting_first_item and (match := FIRST_ITEM.match(line)):
            if section is None:
                raise RuntimeError("page item appeared without a section")
            found.add((section, int(match[1])))
            awaiting_first_item = False
    if awaiting_first_item:
        raise RuntimeError("last page had no recognized first item")
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("document", type=Path)
    parser.add_argument(
        "--rhwp",
        type=Path,
        default=Path("Vendor/rhwp-src/target/release/rhwp"),
    )
    args = parser.parse_args()
    if not args.document.is_file():
        parser.error(f"document not found: {args.document}")
    if not args.rhwp.is_file():
        parser.error(f"rhwp not found: {args.rhwp}")

    declared = declarations(run(args.rhwp, "dump", args.document))
    starts = recorded_page_starts(run(args.rhwp, "dump-pages", args.document))
    if not declared or not starts:
        raise RuntimeError("rhwp output contract drifted: declarations or page starts were empty")

    matched = [row for row in declared if (row[0], row[1]) in starts]
    unmatched = [row for row in declared if (row[0], row[1]) not in starts]
    page = sum(kind == "쪽나누기" for _, _, kind in declared)
    section = sum(kind == "구역나누기" for _, _, kind in declared)
    print(f"HWP_PAGE_BREAK declarations={len(declared)} page={page} section={section}")
    print(f"HWP_PAGE_BREAK recorded_starts={len(matched)} unmatched={len(unmatched)}")
    print("HWP_PAGE_BREAK unmatched_keys=" + ",".join(f"{s}.{p}" for s, p, _ in unmatched))
    return 0 if not unmatched else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"hwp-page-break-audit: {error}", file=sys.stderr)
        raise SystemExit(2)
