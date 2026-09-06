#!/usr/bin/env bash
# package-host.sh — turn Scripts/publish-host.sh's self-contained outputs
# (hosts/avalonia/publish/<rid>/) into distributable archives:
#   hosts/avalonia/dist/FastDoc-<ver>-win-x64.zip
#   hosts/avalonia/dist/FastDoc-<ver>-win-arm64.zip
#   hosts/avalonia/dist/FastDoc-<ver>-linux-x64.tar.gz
#   hosts/avalonia/dist/FastDoc-<ver>-linux-arm64.tar.gz
# plus hosts/avalonia/dist/SHA256SUMS covering all four. The macOS zip comes from
# Scripts/notarize.sh; drop it into dist/ afterwards and extend SHA256SUMS by hand.
#
# Each archive extracts to a single top-level folder (FastDoc-<ver>-<rid>/) containing:
#   - the published app (FastDoc.Avalonia[.exe] + runtimes/<rid>/native/<engine lib> + deps)
#   - the matching installers/<platform>/* scripts
#   - THIRD-PARTY-NOTICES.md and RELEASE-NOTES.md
#
# Requires hosts/avalonia/publish/<rid>/ to already exist — build it first with
# Scripts/publish-host.sh.
#
#   ./Scripts/package-host.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AVALONIA_DIR="$REPO_ROOT/hosts/avalonia"
CSPROJ="$AVALONIA_DIR/FastDoc.Avalonia/FastDoc.Avalonia.csproj"
PUBLISH_ROOT="$AVALONIA_DIR/publish"
DIST_ROOT="$AVALONIA_DIR/dist"
INSTALLERS_DIR="$AVALONIA_DIR/installers"
NOTICES="$AVALONIA_DIR/THIRD-PARTY-NOTICES.md"
RELEASE_NOTES="$AVALONIA_DIR/RELEASE-NOTES.md"

RIDS=(win-x64 win-arm64 linux-x64 linux-arm64)

VERSION="$(grep -oE '<Version>[^<]+</Version>' "$CSPROJ" | head -1 | sed -E 's|</?Version>||g')"
if [ -z "$VERSION" ]; then
  echo "FAIL: could not read <Version> from $CSPROJ" >&2
  exit 1
fi

for rid in "${RIDS[@]}"; do
  if [ ! -d "$PUBLISH_ROOT/$rid" ]; then
    echo "FAIL: $PUBLISH_ROOT/$rid missing — run Scripts/publish-host.sh first" >&2
    exit 1
  fi
done

rm -rf "$DIST_ROOT"
mkdir -p "$DIST_ROOT"

stage_common() {
  local stage_dir="$1"
  cp "$NOTICES" "$stage_dir/THIRD-PARTY-NOTICES.md"
  if [ -f "$RELEASE_NOTES" ]; then
    cp "$RELEASE_NOTES" "$stage_dir/RELEASE-NOTES.md"
  fi
}

# --- win-x64 / win-arm64: zip ---
for rid in win-x64 win-arm64; do
  folder_name="FastDoc-$VERSION-$rid"
  stage="$DIST_ROOT/_stage-$rid"
  rm -rf "$stage"
  mkdir -p "$stage/$folder_name"
  cp -r "$PUBLISH_ROOT/$rid"/. "$stage/$folder_name/"
  mkdir -p "$stage/$folder_name/installers/windows"
  cp "$INSTALLERS_DIR/windows/register.ps1" "$INSTALLERS_DIR/windows/unregister.ps1" "$stage/$folder_name/installers/windows/"
  stage_common "$stage/$folder_name"
  ( cd "$stage" && zip -r -q -X "$DIST_ROOT/$folder_name.zip" "$folder_name" )
  rm -rf "$stage"
  echo "==> built $DIST_ROOT/$folder_name.zip"
done

# --- linux-x64 / linux-arm64: tar.gz, executable bits preserved ---
for rid in linux-x64 linux-arm64; do
  folder_name="FastDoc-$VERSION-$rid"
  stage="$DIST_ROOT/_stage-$rid"
  rm -rf "$stage"
  mkdir -p "$stage/$folder_name"
  cp -r "$PUBLISH_ROOT/$rid"/. "$stage/$folder_name/"
  chmod +x "$stage/$folder_name/FastDoc.Avalonia"
  mkdir -p "$stage/$folder_name/installers/linux"
  cp "$INSTALLERS_DIR/linux/install.sh" "$INSTALLERS_DIR/linux/uninstall.sh" \
     "$INSTALLERS_DIR/linux/fastdoc.desktop" "$INSTALLERS_DIR/linux/ai.ww-w.fastdoc.xml" \
     "$INSTALLERS_DIR/linux/ai.ww-w.fastdoc.png" \
     "$stage/$folder_name/installers/linux/"
  chmod +x "$stage/$folder_name/installers/linux/install.sh" "$stage/$folder_name/installers/linux/uninstall.sh"
  stage_common "$stage/$folder_name"
  # macOS bsdtar records every file's extended attributes (com.apple.provenance on each file a
  # download or build touched) as LIBARCHIVE.xattr.* pax headers; GNU tar on the target prints
  # "Ignoring unknown extended header keyword" once PER FILE on extraction — ~200 lines of noise
  # before the user sees anything. Measured on Ubuntu 24.04 (S7-H). Strip them at packaging time.
  ( cd "$stage" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$DIST_ROOT/$folder_name.tar.gz" "$folder_name" )
  rm -rf "$stage"
  echo "==> built $DIST_ROOT/$folder_name.tar.gz"
done

# --- SHA256SUMS ---
( cd "$DIST_ROOT" && shasum -a 256 FastDoc-"$VERSION"-*.zip FastDoc-"$VERSION"-*.tar.gz > SHA256SUMS )
echo "==> wrote $DIST_ROOT/SHA256SUMS"
cat "$DIST_ROOT/SHA256SUMS"

echo "==> done: $DIST_ROOT"
