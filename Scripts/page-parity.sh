#!/usr/bin/env bash
# page-parity.sh — per document page count and first block per page, macOS vs Avalonia host.
#
#   Scripts/page-parity.sh <out-dir> [document ...]
#
# No documents given: every .docx/.odt/.hwp/.hwpx under testdocs/ (the paged corpus).
#
# macOS    : FastDocReader --pdf (the reader's own pagination, invariant 59), page count from its
#            stdout, first text line per page from the PDF (pdftotext).
# Avalonia : `--sheets` with FMD_SHEETS_PAGES=1 (the PageLayout the GUI and --pdf use), page count
#            and the first block's RenderTree node id per page. FMD_PARITY_AVALONIA_PDF=1 also exports
#            the host PDF so its first text line per page can be diffed against macOS.
#
# Writes <out-dir>/<name>.mac.txt (page<TAB>first line), <name>.avalonia.tsv (page<TAB>node id) and
# summary.tsv (name, macOS pages, Avalonia pages). Prints the summary table. The macOS app and the
# host build are used as they are: build them first (make-app.sh, dotnet build -c Release,
# build-engine-xplat.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
MAC_APP="${FMD_PARITY_MAC_APP:-$REPO_ROOT/FastDocReader.app/Contents/MacOS/FastDocReader}"
HOST_DLL="$REPO_ROOT/hosts/avalonia/FastDoc.Avalonia/bin/Release/net9.0/FastDoc.Avalonia.dll"
export FASTDOC_ENGINE_LIB="${FASTDOC_ENGINE_LIB:-$REPO_ROOT/rust/dist/xplat/macos-arm64/libfastdoc_engine_ffi.dylib}"

if [ $# -lt 1 ]; then
  echo "usage: $0 <out-dir> [document ...]" >&2
  exit 2
fi
OUT_DIR="$1"
shift
mkdir -p "$OUT_DIR"

if [ $# -gt 0 ]; then
  DOCS=("$@")
else
  DOCS=()
  while IFS= read -r f; do DOCS+=("$f"); done < <(
    find "$REPO_ROOT/testdocs" -type f \( -name '*.docx' -o -name '*.odt' -o -name '*.hwp' -o -name '*.hwpx' \) | LC_ALL=C sort)
fi

# first non-empty text line of every page of a PDF -> "page<TAB>line"
first_lines() {
  pdftotext -layout "$1" - | awk 'BEGIN { RS = "\f"; FS = "\n" }
    NF > 0 { n = 0; for (i = 1; i <= NF; i++) { if ($i ~ /[^[:space:]]/) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i); printf "%d\t%s\n", NR, $i; n = 1; break } }
             if (!n) printf "%d\t-\n", NR }'
}

SUMMARY="$OUT_DIR/summary.tsv"
: > "$SUMMARY"
for doc in "${DOCS[@]}"; do
  name="$(basename "$doc")"
  mac_pdf="$OUT_DIR/$name.mac.pdf"
  mac_out="$("$MAC_APP" --pdf "$doc" -o "$mac_pdf" -f 2>/dev/null || true)"
  mac_pages="$(printf '%s\n' "$mac_out" | sed -n 's/^pages: //p')"
  mac_pages="${mac_pages:--}"
  if [ -s "$mac_pdf" ]; then
    first_lines "$mac_pdf" > "$OUT_DIR/$name.mac.txt" || true
    rm -f "$mac_pdf"
  fi

  sheets_out="$(FMD_SHEETS_PAGES=1 "$DOTNET" exec "$HOST_DLL" --sheets "$doc" 2>/dev/null || true)"
  av_pages="$(printf '%s\n' "$sheets_out" | sed -n 's/^sheets: \([0-9]*\).*/\1/p')"
  av_pages="${av_pages:--}"
  printf '%s\n' "$sheets_out" | sed -n 's/^page \([0-9]*\)\tnode \(.*\)$/\1\t\2/p' > "$OUT_DIR/$name.avalonia.tsv"

  if [ "${FMD_PARITY_AVALONIA_PDF:-0}" = "1" ]; then
    av_pdf="$OUT_DIR/$name.avalonia.pdf"
    "$DOTNET" exec "$HOST_DLL" --pdf "$doc" "$av_pdf" >/dev/null 2>&1 || true
    if [ -s "$av_pdf" ]; then
      first_lines "$av_pdf" > "$OUT_DIR/$name.avalonia.txt" || true
      rm -f "$av_pdf"
    fi
  fi
  printf '%s\t%s\t%s\n' "$name" "$mac_pages" "$av_pages" >> "$SUMMARY"
done

printf '%-60s %8s %9s\n' document macOS Avalonia
while IFS=$'\t' read -r name mac av; do
  printf '%-60s %8s %9s\n' "$name" "$mac" "$av"
done < "$SUMMARY"
