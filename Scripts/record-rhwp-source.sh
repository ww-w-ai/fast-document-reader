#!/bin/bash
# Records WHICH rhwp commit the vendored parser binary was built from.
#
# `Vendor/RhwpNative.xcframework` is a prebuilt static library committed to THIS repo, while its Rust
# source lives in a separate checkout with no git relationship to this one (no submodule, no shared
# history — see docs/BUILD-RHWP.md). So nothing in git ties the shipped parser to the source that
# produced it, and a stale or mystery binary is invisible: `swift build` links whatever bytes are there
# (invariant 45). This writes that link down.
#
# Run it as the LAST step of every rhwp rebuild, from this repo:
#     ./Scripts/record-rhwp-source.sh [path-to-rhwp-checkout]
set -euo pipefail

# Default to the SUBMODULE, which is the pinned source this repo actually records (BUILD-RHWP.md).
# The other working checkout (~/Documents/DEV/refs/rhwp) is the same repository and may be at a
# different commit — defaulting to it is how a build from the submodule got attributed to the wrong
# one, silently, because the guard below rejected the submodule and the default took over.
RHWP="${1:-Vendor/rhwp-src}"
LIB="Vendor/RhwpNative.xcframework/macos-arm64/librhwp_native_ffi.a"
OUT="Vendor/RHWP-SOURCE.txt"

# `.git` is a DIRECTORY in a plain clone and a FILE in a submodule — test for either, or the
# submodule (this repo's own pinned source) is rejected as "not an rhwp checkout".
[ -e "$RHWP/.git" ] || { echo "not an rhwp checkout: $RHWP" >&2; exit 1; }
[ -f "$LIB" ]       || { echo "no vendored library at $LIB" >&2; exit 1; }

commit=$(git -C "$RHWP" rev-parse HEAD)
branch=$(git -C "$RHWP" rev-parse --abbrev-ref HEAD)
subject=$(git -C "$RHWP" log -1 --format=%s)
upstream=$(git -C "$RHWP" remote get-url origin 2>/dev/null || echo "(no origin)")
dirty=$(git -C "$RHWP" status --porcelain | wc -l | tr -d ' ')

cat > "$OUT" <<TXT
# Provenance of Vendor/RhwpNative.xcframework — written by Scripts/record-rhwp-source.sh
#
# The .a in this repo is a BUILD PRODUCT of the rhwp checkout below. Git knows nothing about that
# relationship, so this file is the only record of it. Regenerate on every rebuild.

rhwp commit   : $commit
rhwp branch   : $branch
rhwp subject  : $subject
rhwp origin   : $upstream
uncommitted   : $dirty file(s) in the rhwp checkout at build time
library bytes : $(stat -f%z "$LIB")
library sha256: $(shasum -a 256 "$LIB" | awk '{print $1}')
TXT

echo "wrote $OUT (rhwp $commit${dirty:+, $dirty uncommitted})"
[ "$dirty" = "0" ] || echo "WARNING: the rhwp checkout had uncommitted changes — this binary is not reproducible from a commit" >&2
