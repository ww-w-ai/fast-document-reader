#!/usr/bin/env bash
set -euo pipefail

# `--pdf` against a SANDBOXED build — the one shape `swift test` cannot see.
#
# The suite runs unsandboxed, so `FolderAccess.isNeeded` is false there and every destination is
# writable; the defect this guards shipped in 1.2 and appeared ONLY in the App Store build:
# `jobSavingURL` is honoured by the print subsystem rather than by this app, so the app's
# security-scoped grant never reached it and every destination outside the container failed with
# `PMSessionBeginCGDocumentNoDialog() returned -61` — then raised a modal alert that a headless
# process never dismisses, so it hung until it was killed.
#
# Build the shape first, then run this:
#   SANDBOX=1 ./Scripts/make-app.sh release
#   ./Scripts/smoke-headless-pdf.sh [path/to/FastDocReader.app]
#
# Two checks, and the second one needs no setup:
#   1. a GRANTED folder outside the container  -> exit 0, a real PDF appears there
#      (skipped, loudly, when this build has no grant yet — grant one from the app's File menu)
#   2. an UNGRANTED folder outside the container -> exits NON-ZERO promptly with the grant hint
#      (never hangs: a hang here is the alert coming back)

APP="${1:-./FastDocReader.app}"
BIN="$APP/Contents/MacOS/FastDocReader"
TIMEOUT="${SMOKE_TIMEOUT:-90}"

[ -x "$BIN" ] || { echo "no executable at $BIN — build one first" >&2; exit 1; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID"
PREFS="$CONTAINER/Data/Library/Preferences/$BUNDLE_ID.plist"

if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
        /dev/stdin <<<"$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - -)" \
        2>/dev/null | grep -q true; then
    echo "!! $APP is NOT sandboxed — this smoke would pass for the wrong reason." >&2
    echo "   Build it with: SANDBOX=1 ./Scripts/make-app.sh release" >&2
    exit 1
fi

SOURCE="$(cd "$(dirname "$0")/.." && pwd)/demo/moby-dick.md"
[ -f "$SOURCE" ] || { echo "missing demo input $SOURCE" >&2; exit 1; }

# The INPUT is copied inside the container, so reading it never needs a grant — otherwise the repo's
# own folder would have to be granted first and the checks below would fail at the READ step, which
# is not what they are about. This isolates the WRITE path, which is the whole subject here.
mkdir -p "$CONTAINER/Data/tmp"
INPUT="$CONTAINER/Data/tmp/smoke-input.md"
cp "$SOURCE" "$INPUT"
trap 'rm -f "$INPUT"' EXIT

# Run headless with a hard wall clock: the failure mode being guarded against is a process that
# never returns, and macOS has no `timeout(1)`.
run_with_timeout() {   # -> sets RC and OUT; RC=124 on timeout
    local out; out="$(mktemp)"
    "$BIN" --pdf "$@" >"$out" 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$TIMEOUT" ]; then
            kill -9 "$pid" 2>/dev/null || true
            RC=124; OUT="$(cat "$out")"; rm -f "$out"; return
        fi
        sleep 1; waited=$((waited + 1))
    done
    # Suspending `set -e` matters: a NON-ZERO exit is the EXPECTED result of half these checks, and
    # a bare `wait` on one would kill this script before it could judge it.
    set +e; wait "$pid"; RC=$?; set -e
    OUT="$(cat "$out")"; rm -f "$out"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- 1. a granted folder -------------------------------------------------------------------
# The values are bookmark BLOBS. A text dump of this dictionary is not valid UTF-8 (`sed` refuses
# it) and JSON has no way to hold `Data` at all (`plutil` answers "Invalid object in plist for JSON
# format" and reports NO grants, which reads exactly like a build that has none) — XML holds both,
# and the keys are the granted paths.
GRANTS="$(plutil -extract grantedFolderBookmarks xml1 -o - "$PREFS" 2>/dev/null \
          | sed -n 's/.*<key>\(.*\)<\/key>.*/\1/p' | head -1 || true)"
if [ -z "$GRANTS" ]; then
    echo "-- SKIPPED (granted folder): $BUNDLE_ID has no folder grant yet."
    echo "   Open a document in this build and choose File > \"Allow Access to This Folder…\", then re-run."
else
    DEST="$GRANTS/.fastdoc-smoke-$$.pdf"
    run_with_timeout "$INPUT" -o "$DEST" -f
    [ "$RC" -ne 124 ] || fail "timed out after ${TIMEOUT}s writing into the GRANTED folder $GRANTS (the modal alert is back)"
    [ "$RC" -eq 0 ] || fail "exit $RC writing into the GRANTED folder $GRANTS:\n$OUT"
    head -c 4 "$DEST" | grep -q '%PDF' || fail "no PDF at $DEST"
    echo "-- OK (granted folder $GRANTS): $(echo "$OUT" | sed -n '2p')"
    rm -f "$DEST"
fi

# ---- 2. an ungranted folder ----------------------------------------------------------------
UNGRANTED="$(mktemp -d "/private/tmp/fastdoc-smoke-XXXXXX")"
trap 'rm -f "$INPUT"; rm -rf "$UNGRANTED"' EXIT
run_with_timeout "$INPUT" -o "$UNGRANTED/out.pdf" -f
[ "$RC" -ne 124 ] || fail "timed out after ${TIMEOUT}s on an UNGRANTED destination — a refusal must exit, not hang"
[ "$RC" -ne 0 ] || fail "an ungranted destination unexpectedly succeeded; this smoke proves nothing on this machine"
echo "$OUT" | grep -q "Allow Access to This Folder" \
    || fail "the refusal must say how to fix it, got:\n$OUT"
echo "$OUT" | grep -qi "could not write" \
    || fail "an ungranted destination must be reported as a WRITE refusal, not a print failure:\n$OUT"
echo "-- OK (ungranted folder): refused in time, with the grant hint"

echo "smoke passed"
