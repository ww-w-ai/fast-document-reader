#!/usr/bin/env bash
# publish-host.sh — self-contained `dotnet publish` of the Avalonia host for every RID it ships
# on besides macOS (win-x64, win-arm64, linux-x64, linux-arm64), with the matching Rust engine library
# copied into runtimes/<rid>/native/ so FastdocEngine.cs's own bundled-library fallback
# (Native/FastdocEngine.cs CandidatePaths/CurrentRid/PlatformLibraryFileName) finds it with
# FASTDOC_ENGINE_LIB unset — this is the packaged-build shape that resolver is written for.
#
# Requires rust/dist/xplat/<platform>/<lib> to already exist — build it first with
# Scripts/build-engine-xplat.sh.
#
#   ./Scripts/publish-host.sh
#
# Output layout (per RID):
#   hosts/avalonia/publish/<rid>/FastDoc.Avalonia(.exe)
#   hosts/avalonia/publish/<rid>/runtimes/<rid>/native/<engine lib>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTNET="/Users/taehyoungkim/.dotnet/dotnet"

CSPROJ="$REPO_ROOT/hosts/avalonia/FastDoc.Avalonia/FastDoc.Avalonia.csproj"
XPLAT_DIR="$REPO_ROOT/rust/dist/xplat"
PUBLISH_ROOT="$REPO_ROOT/hosts/avalonia/publish"

# rid -> "xplat subdir:engine filename" — the exact rid/filename pairs
# Native/FastdocEngine.cs's CurrentRid()/PlatformLibraryFileName() expect to find under
# runtimes/<rid>/native/ inside a published output.
RIDS=(win-x64 win-arm64 linux-x64 linux-arm64)

engine_source_for() {
  case "$1" in
    win-x64)      echo "$XPLAT_DIR/windows-x64/fastdoc_engine_ffi.dll" ;;
    win-arm64)    echo "$XPLAT_DIR/windows-arm64/fastdoc_engine_ffi.dll" ;;
    linux-x64)    echo "$XPLAT_DIR/linux-x64/libfastdoc_engine_ffi.so" ;;
    linux-arm64)  echo "$XPLAT_DIR/linux-arm64/libfastdoc_engine_ffi.so" ;;
    *) echo ""; return 1 ;;
  esac
}

engine_filename_for() {
  case "$1" in
    win-*) echo "fastdoc_engine_ffi.dll" ;;
    *)     echo "libfastdoc_engine_ffi.so" ;;
  esac
}

# Minimum plausible size for the engine cdylib/dll — a stub or truncated copy is far smaller than
# any real build (measured builds run 12-32 MB). Below this, treat it as missing.
MIN_ENGINE_BYTES=$((1 * 1024 * 1024))

# verify_rid <rid> — fails loudly (exit 1) instead of a silent pass when either check fails:
#   1. runtimes/<rid>/native/<engine lib> exists and is >= MIN_ENGINE_BYTES.
#   2. the bundled font (Assets/Fonts/NotoSansKR-Regular.ttf, declared as <AvaloniaResource> in the
#      csproj) is embedded in the main assembly's manifest resources. Avalonia resources are NOT
#      separate files in the publish output — they are compiled into FastDoc.Avalonia.dll's resource
#      blob, so the only way to confirm the font shipped is to look for its resource path STRING
#      inside that dll: `strings FastDoc.Avalonia.dll | grep 'Assets/Fonts/NotoSansKR-Regular.ttf'`.
#      A dll with the font correctly excluded, or a build that dropped the AvaloniaResource include,
#      has no such string; the font's own bytes (an OpenType/TrueType binary) are not searched for
#      the same reason a search for the engine library's own bytes would not work — only the
#      resource-name string is guaranteed to survive intact.
verify_rid() {
  local rid="$1"
  local out_dir="$PUBLISH_ROOT/$rid"
  local native_dir="$out_dir/runtimes/$rid/native"
  local filename
  filename="$(engine_filename_for "$rid")"
  local engine_path="$native_dir/$filename"
  local main_dll="$out_dir/FastDoc.Avalonia.dll"
  local ok=1

  if [ ! -f "$engine_path" ]; then
    echo "FAIL: engine library missing in $engine_path" >&2
    ok=0
  else
    local size_bytes
    size_bytes=$(stat -f%z "$engine_path")
    if [ "$size_bytes" -lt "$MIN_ENGINE_BYTES" ]; then
      echo "FAIL: engine library missing in $engine_path (found but only $size_bytes bytes, expected >= $MIN_ENGINE_BYTES)" >&2
      ok=0
    fi
  fi

  if [ ! -f "$main_dll" ]; then
    echo "FAIL: main assembly missing at $main_dll — cannot verify bundled font" >&2
    ok=0
  else
    # Captured to a variable rather than piped straight into grep -q: under `set -o pipefail`,
    # grep -q closing its stdin early on a match sends `strings` a SIGPIPE, and pipefail then
    # reports the PIPELINE as failed even though grep found the string — a false FAIL.
    local dll_strings
    dll_strings="$(strings -a "$main_dll")"
    if ! grep -q 'Assets/Fonts/NotoSansKR-Regular.ttf' <<<"$dll_strings"; then
      echo "FAIL: bundled font resource (Assets/Fonts/NotoSansKR-Regular.ttf) not found embedded in $main_dll" >&2
      ok=0
    fi
  fi

  if [ "$ok" -ne 1 ]; then
    return 1
  fi
  echo "==> [$rid] verify OK: engine lib $engine_path ($(stat -f%z "$engine_path") bytes), font resource embedded in $main_dll"
  return 0
}

# --verify-only <rid> — run just the verification gate against an already-published output, for
# confirming the gate actually catches a missing engine library (rather than re-publishing).
if [ "${1:-}" = "--verify-only" ]; then
  rid="${2:-}"
  if [ -z "$rid" ]; then
    echo "usage: $0 --verify-only <rid>" >&2
    exit 1
  fi
  verify_rid "$rid"
  exit $?
fi

for rid in "${RIDS[@]}"; do
  src="$(engine_source_for "$rid")"
  if [ ! -f "$src" ]; then
    echo "FAIL: engine library for $rid not found at $src" >&2
    echo "      Build it first: ./Scripts/build-engine-xplat.sh" >&2
    exit 1
  fi
done

for rid in "${RIDS[@]}"; do
  out_dir="$PUBLISH_ROOT/$rid"
  echo "==> [$rid] dotnet publish -r $rid --self-contained"
  rm -rf "$out_dir"
  "$DOTNET" publish "$CSPROJ" -c Release -r "$rid" --self-contained -o "$out_dir"

  native_dir="$out_dir/runtimes/$rid/native"
  mkdir -p "$native_dir"
  src="$(engine_source_for "$rid")"
  filename="$(engine_filename_for "$rid")"
  cp "$src" "$native_dir/$filename"

  if ! verify_rid "$rid"; then
    echo "FAIL: [$rid] publish verification gate failed — see errors above" >&2
    exit 1
  fi

  size_bytes=$(find "$out_dir" -type f -exec stat -f%z {} \; | awk '{s+=$1} END {print s}')
  size_mb=$(echo "scale=1; $size_bytes / 1048576" | bc)
  engine_size_bytes=$(stat -f%z "$native_dir/$filename")
  engine_size_mb=$(echo "scale=1; $engine_size_bytes / 1048576" | bc)
  echo "==> [$rid] published: $out_dir ($size_mb MB total, engine lib: $native_dir/$filename, $engine_size_mb MB)"
done

echo "==> done: $PUBLISH_ROOT"
