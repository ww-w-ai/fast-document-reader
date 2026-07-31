#!/usr/bin/env bash
set -euo pipefail

# Build and upload the Mac App Store package: release build -> embed the provisioning profile ->
# sign with Apple Distribution -> wrap in a signed .pkg -> validate/upload to App Store Connect.
#
# This is the App Store track and is SEPARATE from Scripts/notarize.sh (the Developer ID track for
# handing a zip to someone directly). The store does its own notarization during review, so nothing
# here talks to notarytool.
#
# Usage:
#   ./Scripts/appstore.sh            # build + validate only (safe; does not submit)
#   ./Scripts/appstore.sh --upload   # build + validate + upload to App Store Connect
#
# Signing identity and App Store Connect identifiers are NOT in this repo — they live with the
# keys, in a config file outside it (default: $KEYCHAIN_DIR/signing.env, chmod 600). Set
# KEYCHAIN_DIR, or export the variables yourself, to sign as someone else. See docs/APP-STORE.md.

KEYCHAIN_DIR="${KEYCHAIN_DIR:-$HOME/Documents/DEV/ww-w-ai/.keychains}"
[[ -f "$KEYCHAIN_DIR/signing.env" ]] && source "$KEYCHAIN_DIR/signing.env"

: "${APP_IDENTITY:?set APP_IDENTITY (e.g. 'Apple Distribution: <Team> (<TEAMID>)') — see docs/APP-STORE.md}"
: "${PKG_IDENTITY:?set PKG_IDENTITY (e.g. '3rd Party Mac Developer Installer: <Team> (<TEAMID>)')}"
: "${API_KEY_ID:?set API_KEY_ID (App Store Connect API key id)}"
: "${API_ISSUER:?set API_ISSUER (App Store Connect issuer uuid)}"
: "${PROVISION_PROFILE:?set PROVISION_PROFILE (path to the Mac App Store .provisionprofile)}"

KEYCHAIN="${SIGNING_KEYCHAIN:-$KEYCHAIN_DIR/ww-w-signing.keychain-db}"
PROFILE="$PROVISION_PROFILE"
APP="FastDocReader.app"
PKG="FastDocReader.pkg"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

echo "==> Unlocking the signing keychain"
KC_PW="$(security find-generic-password -a ww-w-signing -s ww-w-signing-keychain -w)"
security unlock-keychain -p "$KC_PW" "$KEYCHAIN"

echo "==> Building release"
# DIST_IDENTITY keeps the real bundle identifier: a local build otherwise gets a .dev suffix so it
# cannot share per-app state (recent documents above all) with an installed release.
DIST_IDENTITY=1 ./Scripts/make-app.sh release

# Verify rather than trust the flag. Here a wrong identifier does not just break state — it will not
# match the provisioning profile, and the failure would surface late, during upload or review.
BUILT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$BUILT_ID" == *.dev ]]; then
  echo "REFUSING TO SUBMIT: bundle identifier is $BUILT_ID — DIST_IDENTITY did not take effect." >&2
  exit 1
fi
echo "    submitting identifier: $BUILT_ID"

echo "==> Embedding the provisioning profile"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# Strip extended attributes from the whole bundle before signing. The profile was downloaded in a
# browser, so macOS tagged it com.apple.quarantine — and that tag rides along into the .pkg, which
# App Store Connect rejects on ingest:
#   ITMS-91109: Invalid package contents — the package contains one or more files with the
#   com.apple.quarantine extended file attribute … isn't permitted on TestFlight or the App Store.
# It cost builds 1-3. Clearing the bundle (not just the profile) also covers any other file that
# picks up an attribute from a download or a copy.
xattr -cr "$APP"

echo "==> Signing with Apple Distribution (App Store entitlements)"
# Hardened runtime is not required for the store (the sandbox is), and --deep is deprecated. Nested
# code is signed INSIDE-OUT instead: the Quick Look extension first, the app after, so the app's
# signature seals an already-signed extension.
#
# The extension is its own app as far as provisioning is concerned — a separate App ID
# (`…fast-md-reader.quicklook`) and a separate Mac App Store profile, embedded in the .appex. Both
# have to exist in the developer portal before this can ship, so a missing profile stops the build
# HERE with the reason, rather than being rejected during ingest hours later.
QL_APPEX="$APP/Contents/PlugIns/QuickLookPreview.appex"
if [[ -d "$QL_APPEX" ]]; then
  if [[ -z "${QUICKLOOK_PROVISION_PROFILE:-}" ]]; then
    echo "REFUSING TO SUBMIT: the bundle carries QuickLookPreview.appex but" >&2
    echo "  QUICKLOOK_PROVISION_PROFILE is unset. Register the App ID" >&2
    echo "  ai.ww-w.fast-md-reader.quicklook in the developer portal, download its Mac App Store" >&2
    echo "  .provisionprofile, and set that path — or build with SKIP_QUICKLOOK=1 to ship this" >&2
    echo "  version without the Finder preview." >&2
    exit 1
  fi
  cp "$QUICKLOOK_PROVISION_PROFILE" "$QL_APPEX/Contents/embedded.provisionprofile"
  xattr -cr "$QL_APPEX"
  codesign --force --timestamp --keychain "$KEYCHAIN" \
    --entitlements Resources/QuickLookPreview-mas.entitlements \
    --sign "$APP_IDENTITY" "$QL_APPEX"
fi
codesign --force --timestamp --keychain "$KEYCHAIN" \
  --entitlements Resources/FastDocReader-mas.entitlements \
  --sign "$APP_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Building the signed installer package"
rm -f "$PKG"
productbuild --component "$APP" /Applications \
  --keychain "$KEYCHAIN" --sign "$PKG_IDENTITY" "$PKG"

ACTION="--validate-app"
[[ "${1:-}" == "--upload" ]] && ACTION="--upload-app"
echo "==> Running altool $ACTION (this is the step that proves an SPM-built, hand-signed"
echo "    package is acceptable to App Store Connect)"
xcrun altool "$ACTION" -f "$PKG" -t macos \
  --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER"

echo
if [[ "$ACTION" == "--validate-app" ]]; then
  echo "Validation passed. Re-run with --upload to submit: ./Scripts/appstore.sh --upload"
else
  echo "Uploaded. Check App Store Connect — the build takes a few minutes to finish processing."
fi
