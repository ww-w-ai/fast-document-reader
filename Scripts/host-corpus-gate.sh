#!/usr/bin/env bash
# host-corpus-gate.sh — real-document crash gate for the Avalonia host (S6-B).
#
# Drives every document under the given directories through the host's headless doors
# (--extract and --paint-probe, falling back to --sheets if --paint-probe is absent) and
# records exit code, wall-clock ms, and the last stderr line per document. Never prints or
# stores document TEXT — only path, exit code, timing, and an exception type/first line.
#
# Usage:
#   Scripts/host-corpus-gate.sh <dir1[:dir2:...]> <output.tsv> [host-dll] [engine-lib]
#
# Defaults: host-dll = hosts/avalonia/FastDoc.Avalonia/bin/Release/net9.0/FastDoc.Avalonia.dll
#           engine-lib = rust/dist/xplat/macos-arm64/libfastdoc_engine_ffi.dylib
#
# Per-document timeout: 120s. macOS has no `timeout`/`gtimeout` by default, so this uses a
# perl `alarm()` wrapper (present on macOS by default) instead of a background+kill dance.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTNET="/Users/taehyoungkim/.dotnet/dotnet"

DIRS="${1:?usage: host-corpus-gate.sh <dir1[:dir2:...]> <output.tsv> [host-dll] [engine-lib]}"
OUT_TSV="${2:?usage: host-corpus-gate.sh <dir1[:dir2:...]> <output.tsv> [host-dll] [engine-lib]}"
HOST_DLL="${3:-$REPO_ROOT/hosts/avalonia/FastDoc.Avalonia/bin/Release/net9.0/FastDoc.Avalonia.dll}"
ENGINE_LIB="${4:-$REPO_ROOT/rust/dist/xplat/macos-arm64/libfastdoc_engine_ffi.dylib}"
TIMEOUT_SECS=120

if [ ! -f "$HOST_DLL" ]; then
  echo "FAIL: host DLL not found at $HOST_DLL (build it first: dotnet build hosts/avalonia/FastDoc.Avalonia/FastDoc.Avalonia.csproj -c Release)" >&2
  exit 1
fi
if [ ! -f "$ENGINE_LIB" ]; then
  echo "FAIL: engine library not found at $ENGINE_LIB (build with Scripts/build-engine-xplat.sh)" >&2
  exit 1
fi
export FASTDOC_ENGINE_LIB="$ENGINE_LIB"

# Probe flag: --paint-probe if this build's Program.cs source declares it (checked against the
# repo source, not the compiled DLL — .NET string literals are UTF-16LE and don't survive a
# plain `strings` scan), else --sheets.
PROBE_FLAG="--sheets"
if grep -qF -- '"--paint-probe"' "$REPO_ROOT/hosts/avalonia/FastDoc.Avalonia/Program.cs" 2>/dev/null; then
  PROBE_FLAG="--paint-probe"
fi

# Run one command with a wall-clock timeout via perl's alarm(), printing the elapsed ms,
# exit code, and a diagnostic last-line as three tab-separated fields. This host's headless
# doors (RunHeadless/RunPaintProbe et al, Program.cs) print ONLY a one-line "opened: N nodes,
# M ms" / "error: [...] ..." / "exception: ..." summary to stdout on failure or success --
# never document body text -- so capturing stdout's last line here is safe and is in fact
# where this host's error messages actually land (Console.WriteLine, not Console.Error).
run_with_timeout() {
  local timeout_secs="$1"; shift
  local start_ms end_ms
  local stdout_file stderr_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  start_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000')
  perl -e '
    my $timeout = shift @ARGV;
    alarm($timeout);
    $SIG{ALRM} = sub { print STDERR "TIMEOUT after ${timeout}s\n"; exit 124; };
    exec { $ARGV[0] } @ARGV or do { print STDERR "exec failed: $!\n"; exit 127; };
  ' "$timeout_secs" "$@" >"$stdout_file" 2>"$stderr_file"
  local rc=$?
  end_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000')
  local elapsed_ms=$((end_ms - start_ms))
  local last_line
  last_line="$(tail -n 1 "$stdout_file" 2>/dev/null | tr -d '\t\n' | cut -c1-200)"
  if [ -z "$last_line" ]; then
    last_line="$(tail -n 1 "$stderr_file" 2>/dev/null | tr -d '\t\n' | cut -c1-200)"
  fi
  rm -f "$stdout_file" "$stderr_file"
  echo -e "${rc}\t${elapsed_ms}\t${last_line}"
}

IFS=':' read -r -a DIR_LIST <<< "$DIRS"
FILES=()
for d in "${DIR_LIST[@]}"; do
  if [ ! -d "$d" ]; then
    echo "WARN: directory not found, skipping: $d" >&2
    continue
  fi
  while IFS= read -r -d '' f; do
    FILES+=("$f")
  done < <(find "$d" -type f \( \
      -iname '*.md' -o -iname '*.txt' -o \
      -iname '*.docx' -o -iname '*.docm' -o -iname '*.dotx' -o -iname '*.dotm' -o \
      -iname '*.odt' -o -iname '*.hwp' -o -iname '*.hwpx' \
    \) -print0 | sort -z)
done

TOTAL=${#FILES[@]}
echo "== host-corpus-gate: $TOTAL documents under: $DIRS (probe flag: $PROBE_FLAG) ==" >&2

{
  echo -e "path\text\text_ms\text_last_err\tprobe\tprobe_ms\tprobe_last_err\tstatus"
  n=0
  for f in "${FILES[@]}"; do
    n=$((n+1))
    echo "[$n/$TOTAL] $f" >&2

    IFS=$'\t' read -r ext_rc ext_ms ext_err <<< "$(run_with_timeout "$TIMEOUT_SECS" "$DOTNET" exec "$HOST_DLL" --extract "$f")"
    IFS=$'\t' read -r probe_rc probe_ms probe_err <<< "$(run_with_timeout "$TIMEOUT_SECS" "$DOTNET" exec "$HOST_DLL" "$PROBE_FLAG" "$f")"

    status="ok"
    if [ "$ext_rc" != "0" ] || [ "$probe_rc" != "0" ]; then
      status="fail"
    fi
    if [ "$ext_rc" = "124" ] || [ "$probe_rc" = "124" ]; then
      status="timeout"
    fi

    echo -e "${f}\t${ext_rc}\t${ext_ms}\t${ext_err}\t${PROBE_FLAG}\t${probe_ms}\t${probe_err}\t${status}"
  done
} > "$OUT_TSV"

TOTAL_ROWS=$(($(wc -l < "$OUT_TSV") - 1))
OK_ROWS=$(awk -F'\t' 'NR>1 && $8=="ok"' "$OUT_TSV" | wc -l | tr -d ' ')
FAIL_ROWS=$(awk -F'\t' 'NR>1 && $8=="fail"' "$OUT_TSV" | wc -l | tr -d ' ')
TIMEOUT_ROWS=$(awk -F'\t' 'NR>1 && $8=="timeout"' "$OUT_TSV" | wc -l | tr -d ' ')

echo "== summary ==" >&2
echo "total: $TOTAL_ROWS  ok: $OK_ROWS  fail: $FAIL_ROWS  timeout: $TIMEOUT_ROWS" >&2
echo "by extension:" >&2
awk -F'\t' 'NR>1 {n=split($1,a,"."); ext=a[n]; total[ext]++; if ($8!="ok") fail[ext]++} END {for (e in total) printf "  .%s: total=%d fail=%d\n", e, total[e], fail[e]+0}' "$OUT_TSV" >&2
echo "output: $OUT_TSV" >&2
