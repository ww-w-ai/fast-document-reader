#!/usr/bin/env bash
# install.sh — user-local (no sudo) file-association install for the Linux build, following
# docs/studio/sprints/S3/d5-file-assoc-print-dnd.md §3's procedure exactly: copy the .desktop +
# MIME definition, refresh the two caches, and set the default app ONLY on explicit confirmation
# (setting text/plain as default would hijack every plain-text file on the distro — see that
# doc's own warning).
#
# Usage:
#   ./install.sh <published-app-dir>
#
# <published-app-dir> is a self-contained publish output, e.g. hosts/avalonia/publish/linux-x64
# (built by Scripts/publish-host.sh). The binary and its runtimes/ are copied to
# ~/.local/share/fastdoc/ so this needs no root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC_DIR="${1:-}"

if [ -z "$APP_SRC_DIR" ] || [ ! -d "$APP_SRC_DIR" ]; then
  echo "Usage: $0 <published-app-dir>" >&2
  echo "  e.g. $0 hosts/avalonia/publish/linux-x64" >&2
  exit 1
fi
APP_SRC_DIR="$(cd "$APP_SRC_DIR" && pwd)"
if [ ! -f "$APP_SRC_DIR/FastDoc.Avalonia" ]; then
  echo "FAIL: $APP_SRC_DIR/FastDoc.Avalonia not found — is this a published self-contained output?" >&2
  exit 1
fi

INSTALL_DIR="$HOME/.local/share/fastdoc"
APPS_DIR="$HOME/.local/share/applications"
MIME_DIR="$HOME/.local/share/mime/packages"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
DESKTOP_FILE="ai.ww-w.fastdoc.desktop"

echo "==> 1/5: copying app to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$APP_SRC_DIR"/. "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/FastDoc.Avalonia"

echo "==> 2/5: installing .desktop entry (all 70 extensions this app opens become 'open with' candidates)"
mkdir -p "$APPS_DIR"
sed "s|^Exec=.*|Exec=$INSTALL_DIR/FastDoc.Avalonia %f|" \
  "$SCRIPT_DIR/fastdoc.desktop" > "$APPS_DIR/$DESKTOP_FILE"
# The .desktop names its icon by theme id (Icon=ai.ww-w.fastdoc); the launcher shows a generic
# icon unless a file by that name exists in the hicolor theme.
mkdir -p "$ICON_DIR"
cp "$SCRIPT_DIR/ai.ww-w.fastdoc.png" "$ICON_DIR/ai.ww-w.fastdoc.png"
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi

echo "==> 3/5: installing MIME definition for .hwp/.hwpx (only needed if the distro's shared-mime-info lacks them)"
mkdir -p "$MIME_DIR"
cp "$SCRIPT_DIR/ai.ww-w.fastdoc.xml" "$MIME_DIR/"

echo "==> 4/5: refreshing MIME + desktop caches"
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$HOME/.local/share/mime"
else
  echo "    WARN: update-mime-database not found — .hwp/.hwpx custom MIME type may not take effect"
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR"
else
  echo "    WARN: update-desktop-database not found — 'open with' list may not refresh"
fi

echo "==> 5/5: default app — NOT set automatically"
echo "    FastDoc is now an 'open with' candidate for all supported types."
echo "    Per D5, only Markdown/Word-ODT/HWP/plain-text are candidates for DEFAULT, and only on your say-so."
echo "    To make FastDoc the default for a type, run e.g.:"
echo "      xdg-mime default $DESKTOP_FILE text/markdown"
echo "    Do NOT set text/plain as default unless you mean it — it claims every plain-text file on this system."
