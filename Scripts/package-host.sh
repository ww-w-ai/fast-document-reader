#!/usr/bin/env bash
# package-host.sh — turn Scripts/publish-host.sh's self-contained outputs
# (hosts/avalonia/publish/<rid>/) into everything a Windows or Linux user downloads, in
# hosts/avalonia/dist/:
#
#   FastDoc-<ver>-win-x64-setup.exe     per-user setup (NSIS): no admin, Start menu, Open with,
#   FastDoc-<ver>-win-arm64-setup.exe   Installed apps entry with a real uninstaller
#   FastDoc-<ver>-win-x64.zip           portable: unzip and run FastDoc.exe; register.ps1 inside
#   FastDoc-<ver>-win-arm64.zip
#   fastdoc_<ver>_amd64.deb             Debian/Ubuntu: /opt/fastdoc, /usr/bin/fastdoc, launcher,
#   fastdoc_<ver>_arm64.deb             MIME types, icon
#   FastDoc-<ver>-linux-x64.tar.gz      other distributions: unpack and run fastdoc, or
#   FastDoc-<ver>-linux-arm64.tar.gz    installers/linux/install.sh for a user-local launcher
#   SHA256SUMS                          covers every file above
#
# The macOS zip comes from Scripts/notarize.sh; copy it into dist/ and re-run
#   (cd hosts/avalonia/dist && shasum -a 256 FastDoc-* fastdoc_* > SHA256SUMS)
# so SHA256SUMS covers it too.
#
# Requires: hosts/avalonia/publish/<rid>/ for all four RIDs (Scripts/publish-host.sh), makensis
# (`brew install makensis`), and a running Docker daemon (OrbStack: `orbctl start`) — dpkg-deb runs
# in a Debian container. A missing tool fails the run; nothing is skipped silently.
#
#   ./Scripts/package-host.sh
#
# DEB_MAINTAINER overrides the .deb Maintainer field (default below).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AVALONIA_DIR="$REPO_ROOT/hosts/avalonia"
CSPROJ="$AVALONIA_DIR/FastDoc.Avalonia/FastDoc.Avalonia.csproj"
REGISTRATION_CS="$AVALONIA_DIR/FastDoc.Avalonia/Open/DefaultAppRegistration.cs"
PUBLISH_ROOT="$AVALONIA_DIR/publish"
DIST_ROOT="$AVALONIA_DIR/dist"
INSTALLERS_DIR="$AVALONIA_DIR/installers"
NOTICES="$AVALONIA_DIR/THIRD-PARTY-NOTICES.md"
RELEASE_NOTES="$AVALONIA_DIR/RELEASE-NOTES.md"
NSIS_SCRIPT="$INSTALLERS_DIR/windows/fastdoc.nsi"
DEB_IMAGE="debian:bookworm-slim"
DEB_MAINTAINER="${DEB_MAINTAINER:-DubDubDub Corp. <https://github.com/ww-w-ai/fast-document-reader/issues>}"

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
for exe in "$PUBLISH_ROOT/win-x64/FastDoc.exe" "$PUBLISH_ROOT/win-arm64/FastDoc.exe" \
           "$PUBLISH_ROOT/linux-x64/fastdoc" "$PUBLISH_ROOT/linux-arm64/fastdoc"; do
  if [ ! -f "$exe" ]; then
    echo "FAIL: $exe missing — publish output predates the FastDoc.exe/fastdoc rename; re-run Scripts/publish-host.sh" >&2
    exit 1
  fi
done
if ! command -v makensis >/dev/null 2>&1; then
  echo "FAIL: makensis not found — brew install makensis" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "FAIL: Docker daemon not reachable — start OrbStack (orbctl start); the .deb is built in a container" >&2
  exit 1
fi

# --- the extension list: one source (DefaultAppFamilies.WindowsOpenWithExtensions), checked
# against the two PowerShell scripts that carry their own copy, so the setup, the portable
# scripts and the app's own File > Set as Default App never register different sets.
extensions_from() {
  # Prints the quoted words of the first list after the line matching $2, up to the closing line.
  awk -v start="$2" -v stop="$3" '
    index($0, start) { on = 1; next }
    on && index($0, stop) { exit }
    on { while (match($0, /"[A-Za-z0-9]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); $0 = substr($0, RSTART + RLENGTH) } }
  ' "$1"
}
EXTENSIONS="$(extensions_from "$REGISTRATION_CS" 'WindowsOpenWithExtensions = new[]' '};')"
for ps1 in register.ps1 unregister.ps1; do
  ps1_exts="$(extensions_from "$INSTALLERS_DIR/windows/$ps1" '$AllExtensions = @(' ')')"
  if [ "$ps1_exts" != "$EXTENSIONS" ]; then
    echo "FAIL: installers/windows/$ps1 \$AllExtensions differs from DefaultAppFamilies.WindowsOpenWithExtensions" >&2
    diff <(echo "$EXTENSIONS") <(echo "$ps1_exts") >&2 || true
    exit 1
  fi
done
EXT_COUNT="$(echo "$EXTENSIONS" | wc -l | tr -d ' ')"
echo "==> $EXT_COUNT extensions (DefaultAppFamilies.WindowsOpenWithExtensions = register.ps1 = unregister.ps1)"

rm -rf "$DIST_ROOT"
mkdir -p "$DIST_ROOT"

stage_common() {
  local stage_dir="$1"
  cp "$NOTICES" "$stage_dir/THIRD-PARTY-NOTICES.md"
  cp "$RELEASE_NOTES" "$stage_dir/RELEASE-NOTES.md"
}

# nsis_escape <text> — NSIS expands $; a literal one is $$.
nsis_escape() { printf '%s' "${1//\$/\$\$}"; }

# write_nsis_lists <app-dir> <out-dir> — install-files.nsh / uninstall-files.nsh / extensions.nsh.
# Files are listed one by one so the uninstaller deletes exactly what was installed and leaves
# anything else a user put in the folder.
write_nsis_lists() {
  local app_dir="$1" out_dir="$2"
  local install_nsh="$out_dir/install-files.nsh" uninstall_nsh="$out_dir/uninstall-files.nsh"
  : > "$install_nsh"
  : > "$uninstall_nsh"
  local current_dir="__none__" rel dir win_rel win_dir
  while IFS= read -r rel; do
    case "$rel" in *'"'*) echo "FAIL: file name with a double quote: $rel" >&2; exit 1 ;; esac
    dir="$(dirname "$rel")"
    if [ "$dir" != "$current_dir" ]; then
      current_dir="$dir"
      if [ "$dir" = "." ]; then win_dir=""; else win_dir="\\${dir//\//\\}"; fi
      printf '  SetOutPath "$INSTDIR%s"\n' "$(nsis_escape "$win_dir")" >> "$install_nsh"
    fi
    printf '  File "%s"\n' "$(nsis_escape "$app_dir/$rel")" >> "$install_nsh"
    win_rel="${rel//\//\\}"
    printf '  Delete "$INSTDIR\\%s"\n' "$(nsis_escape "$win_rel")" >> "$uninstall_nsh"
  done < <(cd "$app_dir" && find . -type f ! -path './installers/*' | sed 's|^\./||' | LC_ALL=C sort)
  while IFS= read -r dir; do
    printf '  RMDir "$INSTDIR\\%s"\n' "$(nsis_escape "${dir//\//\\}")" >> "$uninstall_nsh"
  done < <(cd "$app_dir" && find . -mindepth 1 -type d ! -path './installers' ! -path './installers/*' | sed 's|^\./||' \
             | awk -F/ '{ print NF "\t" $0 }' | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2r | cut -f2-)

  {
    echo '!macro FASTDOC_FOR_EACH_EXT MACRO'
    while IFS= read -r ext; do echo "  !insertmacro \${MACRO} \"$ext\""; done <<< "$EXTENSIONS"
    echo '!macroend'
  } > "$out_dir/extensions.nsh"
}

# --- Windows: portable zip + setup.exe from the same staged tree ---
for rid in win-x64 win-arm64; do
  arch="${rid#win-}"
  folder_name="FastDoc-$VERSION-$rid"
  stage="$DIST_ROOT/_stage-$rid"
  rm -rf "$stage"
  mkdir -p "$stage/$folder_name/installers/windows"
  cp -R "$PUBLISH_ROOT/$rid"/. "$stage/$folder_name/"
  cp "$INSTALLERS_DIR/windows/register.ps1" "$INSTALLERS_DIR/windows/unregister.ps1" "$stage/$folder_name/installers/windows/"
  stage_common "$stage/$folder_name"
  ( cd "$stage" && zip -r -q -X "$DIST_ROOT/$folder_name.zip" "$folder_name" )
  echo "==> built $DIST_ROOT/$folder_name.zip"

  nsh_dir="$stage/nsh"
  mkdir -p "$nsh_dir"
  write_nsis_lists "$stage/$folder_name" "$nsh_dir"
  setup="$DIST_ROOT/FastDoc-$VERSION-$rid-setup.exe"
  makensis -V2 -INPUTCHARSET UTF8 -DVERSION="$VERSION" -DARCH="$arch" -DSTAGE_NSH="$nsh_dir" \
    -DOUTFILE="$setup" "$NSIS_SCRIPT"
  rm -rf "$stage"
  echo "==> built $setup"
done

# --- Linux: tar.gz (any distribution) + .deb (Debian/Ubuntu) ---
deb_arch_for() {
  case "$1" in
    linux-x64)   echo "amd64" ;;
    linux-arm64) echo "arm64" ;;
  esac
}

for rid in linux-x64 linux-arm64; do
  folder_name="FastDoc-$VERSION-$rid"
  stage="$DIST_ROOT/_stage-$rid"
  rm -rf "$stage"
  mkdir -p "$stage/$folder_name/installers/linux"
  cp -R "$PUBLISH_ROOT/$rid"/. "$stage/$folder_name/"
  chmod +x "$stage/$folder_name/fastdoc"
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
  echo "==> built $DIST_ROOT/$folder_name.tar.gz"

  # .deb root: the app under /opt/fastdoc, the command on PATH, launcher + MIME + icon system-wide.
  deb_arch="$(deb_arch_for "$rid")"
  deb_name="fastdoc_${VERSION}_${deb_arch}"
  root="$stage/deb/$deb_name"
  mkdir -p "$root/opt/fastdoc" "$root/usr/bin" "$root/usr/share/applications" \
           "$root/usr/share/mime/packages" "$root/usr/share/icons/hicolor/512x512/apps" \
           "$root/usr/share/doc/fastdoc" "$root/DEBIAN"
  cp -R "$PUBLISH_ROOT/$rid"/. "$root/opt/fastdoc/"
  stage_common "$root/opt/fastdoc"
  ln -s ../../opt/fastdoc/fastdoc "$root/usr/bin/fastdoc"
  sed -e 's|^Exec=.*|Exec=fastdoc %f|' -e 's|^TryExec=.*|TryExec=fastdoc|' \
    "$INSTALLERS_DIR/linux/fastdoc.desktop" > "$root/usr/share/applications/ai.ww-w.fastdoc.desktop"
  cp "$INSTALLERS_DIR/linux/ai.ww-w.fastdoc.xml" "$root/usr/share/mime/packages/"
  cp "$INSTALLERS_DIR/linux/ai.ww-w.fastdoc.png" "$root/usr/share/icons/hicolor/512x512/apps/"
  {
    echo "FastDoc $VERSION — https://github.com/ww-w-ai/fast-document-reader"
    echo "Copyright DubDubDub Corp."
    echo
    echo "Third-party components and their licenses: /opt/fastdoc/THIRD-PARTY-NOTICES.md"
  } > "$root/usr/share/doc/fastdoc/copyright"
  installed_kb="$(du -sk "$root" | cut -f1)"
  sed -e "s|@VERSION@|$VERSION|" -e "s|@ARCH@|$deb_arch|" -e "s|@INSTALLED_SIZE@|$installed_kb|" \
      -e "s|@MAINTAINER@|$DEB_MAINTAINER|" \
    "$INSTALLERS_DIR/linux/deb/control.in" > "$root/DEBIAN/control"
  cp "$INSTALLERS_DIR/linux/deb/postinst" "$INSTALLERS_DIR/linux/deb/postrm" "$root/DEBIAN/"
  chmod -R u+rwX,go+rX,go-w "$root"
  chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm" "$root/opt/fastdoc/fastdoc"

  docker run --rm -v "$stage/deb:/build" -v "$DIST_ROOT:/out" "$DEB_IMAGE" \
    dpkg-deb --root-owner-group -Zxz --build "/build/$deb_name" "/out/$deb_name.deb"
  rm -rf "$stage"
  echo "==> built $DIST_ROOT/$deb_name.deb"
done

# --- SHA256SUMS ---
( cd "$DIST_ROOT" && shasum -a 256 FastDoc-"$VERSION"-* fastdoc_"$VERSION"_* > SHA256SUMS )
echo "==> wrote $DIST_ROOT/SHA256SUMS"
cat "$DIST_ROOT/SHA256SUMS"

echo "==> done: $DIST_ROOT"
