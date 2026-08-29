#!/bin/bash
# Markdown: what the PORTED renderer costs against the host one, on the same document.
#
# The office comparison already exists — `--extract` runs both readers over one file and reports
# both. Markdown had no such pair, because the app never called the engine for it and the ported
# `MarkdownRenderer` had never been RUN outside the app at all. This is that pair.
#
#   ./Scripts/md-engine-compare.sh demo/moby-dick.md
#
# Both halves do the SAME two things, in the same order, on the same file:
#
#   parseMinMs   the parse alone, minimum of three — cmark-gfm through `swift-markdown` on one
#                side, comrak through `markdown_package` on the other
#   renderMs     parse PLUS the attributed-string build, i.e. everything a first paint pays
#
# RELEASE ONLY, both sides. A debug Rust build reported this engine's markdown producer at
# 1,102 ms against a true 63.7 — a number that was carried into a report before it was caught.
# The script refuses to run a debug build rather than let that happen twice.
#
# What this comparison canNOT say: the Rust side runs against a single-face font world (a Rust
# integration test has no AppKit), so it never pays for font substitution and never measures font
# CHOICE. It is a floor for the Rust side, not a like-for-like on typography.

set -u
if [ $# -ne 1 ]; then echo "usage: $0 <markdown file>" >&2; exit 2; fi
DOC="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ -f "$DOC" ] || { echo "no such file: $DOC" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "document: $DOC ($(wc -c < "$DOC" | tr -d ' ') bytes)"
echo
echo "== host (Swift, swift-markdown) =="
FMD_MD_PARSE_PROBE="$DOC" swift test -c release \
    --filter MarkdownParseCostProbeTests 2>&1 | grep -E "^MDPARSE |error:" || true
echo
echo "== engine (Rust, transliterated MarkdownRenderer + comrak) =="
( cd "$ROOT/rust" && FMD_MD_PARSE_PROBE="$DOC" cargo test --release \
    -p fastdoc-engine --test markdown_renderer_port \
    what_the_ported_renderer_costs_on_a_real_document -- --nocapture 2>&1 \
    | grep -E "^MDPARSE-RUST |^error" ) || true
