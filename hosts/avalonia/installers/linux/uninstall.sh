#!/usr/bin/env bash
# uninstall.sh — reverses install.sh exactly: removes the copied app directory, the .desktop
# entry, and the custom MIME definition, then refreshes the two caches. Never touches an
# `xdg-mime default` association a user may have set — that association points at a ProgId/
# desktop file this script deletes, so the OS falls back to its previous default on its own
# (same reasoning as installers/windows/unregister.ps1 leaving UserChoice untouched).
#
# Usage:
#   ./uninstall.sh
#
# No arguments — it undoes exactly what install.sh did, at the fixed locations install.sh used.
set -euo pipefail

INSTALL_DIR="$HOME/.local/share/fastdoc"
APPS_DIR="$HOME/.local/share/applications"
MIME_DIR="$HOME/.local/share/mime/packages"
DESKTOP_FILE="ai.ww-w.fastdoc.desktop"
MIME_FILE="ai.ww-w.fastdoc.xml"

echo "==> 1/4: removing app directory $INSTALL_DIR"
rm -rf "$INSTALL_DIR"

echo "==> 2/4: removing .desktop entry and icon"
rm -f "$APPS_DIR/$DESKTOP_FILE"
rm -f "$HOME/.local/share/icons/hicolor/512x512/apps/ai.ww-w.fastdoc.png"

echo "==> 3/4: removing MIME definition"
rm -f "$MIME_DIR/$MIME_FILE"

echo "==> 4/4: refreshing MIME + desktop caches"
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$HOME/.local/share/mime"
else
  echo "    WARN: update-mime-database not found — stale .hwp/.hwpx MIME entry may linger in the cache"
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR"
else
  echo "    WARN: update-desktop-database not found — stale 'open with' entry may linger in the cache"
fi

echo "Done. FastDoc removed. If it was ever set as default for a type, the OS falls back to its previous default."
