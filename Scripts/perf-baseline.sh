#!/bin/bash
# What the port cost, measured against the build that shipped before it.
#
# `--extract` is the one comparison that isolates the transport. Both builds run the SAME Swift
# serializer over the same document; the ONLY thing that differs is the path a block travelled to
# reach it — the old build's in-process reader, or the engine's JSON+base64 round trip. So a
# difference here is the round trip, not "Rust versus Swift".
#
#   FMD_BASELINE_APP=~/Documents/DEV/ww-w-ai/.baselines/FastDocReader-preRustCutover-2026-08-19.app \
#     ./Scripts/perf-baseline.sh testdocs/tables/2025_행정업무운영편람_최종.hwp
#
# Without FMD_BASELINE_APP this prints why it cannot run and exits 0 — the baseline is a 30MB
# bundle that this repo does not carry, and a missing bundle is not a failing gate.
#
# ONLY `--extract` belongs in this script, and the reason is not taste. The two bundles have
# different identifiers (`ai.ww-w.fast-md-reader` and `…dev`), so they do not share a preferences
# domain — measured 2026-08-30, the baseline had a reading size of 17 and the dev build 10. Nothing
# in either build's output says so. `--extract` never lays anything out and is immune; a `--pdf`
# comparison across the two is NOT, and an unpaged document (markdown, txt, csv) paginates by the
# reading size alone — the same file came out 16 pages against 9, which reads as a rendering
# regression and is a preference. Equalise both domains first, or do not compare.
#
# The bundle is required WHOLE. Its executable alone prints nothing and exits 0 (invariant 116),
# which would read as a baseline agreeing with everything.

set -u
REPEATS="${FMD_BASELINE_REPEATS:-3}"
CURRENT="${FMD_CURRENT_APP:-$(cd "$(dirname "$0")/.." && pwd)/FastDocReader.app}"

if [ $# -eq 0 ]; then echo "usage: $0 <document> [document...]" >&2; exit 2; fi

if [ -z "${FMD_BASELINE_APP:-}" ]; then
  echo "skipped: set FMD_BASELINE_APP to the pre-cutover .app bundle (the whole bundle, not its executable)"
  exit 0
fi
for bundle in "$FMD_BASELINE_APP" "$CURRENT"; do
  if [ ! -x "$bundle/Contents/MacOS/FastDocReader" ]; then
    echo "FAIL: $bundle is not a runnable app bundle" >&2; exit 1
  fi
done

# min-of-N wall clock for one bundle on one document, in milliseconds, with the output kept.
run_extract() {  # $1=bundle $2=document $3=output-file  -> echoes ms
  local best=""
  for _ in $(seq "$REPEATS"); do
    local t0 t1 ms
    t0=$(python3 -c 'import time;print(time.time())')
    "$1/Contents/MacOS/FastDocReader" --extract "$2" > "$3" 2>/dev/null
    t1=$(python3 -c 'import time;print(time.time())')
    ms=$(python3 -c "print(int(($t1-$t0)*1000))")
    if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
  done
  echo "$best"
}

printf '%10s %10s %9s  %11s %11s  %s\n' "before ms" "after ms" "ratio" "before B" "after B" "document"
status=0
for doc in "$@"; do
  [ -f "$doc" ] || { echo "missing: $doc" >&2; status=1; continue; }
  before_out=$(mktemp); after_out=$(mktemp)
  before=$(run_extract "$FMD_BASELINE_APP" "$doc" "$before_out")
  after=$(run_extract "$CURRENT" "$doc" "$after_out")
  bb=$(wc -c < "$before_out" | tr -d ' '); ab=$(wc -c < "$after_out" | tr -d ' ')
  ratio=$(python3 -c "print(f'{$after/max($before,1):.2f}x')")
  printf '%10s %10s %9s  %11s %11s  %s\n' "$before" "$after" "$ratio" "$bb" "$ab" "$(basename "$doc")"
  # An empty extract on either side means the comparison measured nothing. Say so loudly.
  if [ "$bb" -lt 100 ] || [ "$ab" -lt 100 ]; then
    echo "  FAIL: one side produced no document text — this comparison is meaningless" >&2
    status=1
  fi
  rm -f "$before_out" "$after_out"
done
exit $status
