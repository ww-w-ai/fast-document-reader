#!/usr/bin/env bash
# Every build product in this tree that is NOT rebuilt by `swift build`, checked against the source
# it was built from. Run unconditionally by make-app.sh, and standalone: ./Scripts/check-freshness.sh
#
# WHY THIS EXISTS. A build step everyone passes through has to be true every time, not usually. The
# engine's xcframework is built by a separate script and `swift build` never touches it, so editing
# Rust and rebuilding the app paired a NEW host with an OLD engine and said nothing. That pair is
# not a build of anything: it read one real document into 543 pages against the 400 the same commit
# produces when built properly, twenty consecutive pages drawing text over other text — a product
# defect that does not exist, chased for hours before anyone looked at a timestamp.
#
# HOW EACH ONE IS JUDGED, and why they differ. An artifact that is NOT committed carries its own
# build time, so mtime is the honest signal. A COMMITTED artifact does not: git records no mtime, so
# a fresh clone or worktree stamps the artifact and its sources with the same checkout time in
# arbitrary order, and comparing them reports whatever the filesystem happened to do. Those are
# judged by a recorded FINGERPRINT instead — which is the job `Vendor/RHWP-SOURCE.txt` was already
# doing, and this makes something read it.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
note() { echo "  $1"; }
bad()  { echo "STALE: $1"; fail=1; }

# 1. The Rust engine — NOT committed, so its mtime is a real build time.
ENGINE=Vendor/FastdocEngine.xcframework/macos-arm64/libfastdoc_engine_ffi.a
if [[ ! -f "$ENGINE" ]]; then
  note "engine: not built yet (make-app.sh builds it)"
else
  newer="$(find rust/crates rust/Cargo.toml rust/Cargo.lock -type f -newer "$ENGINE" -print -quit 2>/dev/null)"
  if [[ -n "$newer" ]]; then
    bad "the engine is older than the Rust source it was built from (e.g. $newer) — ./Scripts/build-engine.sh"
  else
    note "engine: current with rust/"
  fi
fi

# 2. rhwp — COMMITTED, so judged by the sha256 its own provenance file records.
RHWP=Vendor/RhwpNative.xcframework/macos-arm64/librhwp_native_ffi.a
REC=Vendor/RHWP-SOURCE.txt
if [[ -f "$RHWP" && -f "$REC" ]]; then
  want="$(awk -F': *' '/^library sha256/{print $2}' "$REC")"
  have="$(shasum -a 256 "$RHWP" | cut -d' ' -f1)"
  if [[ "$want" != "$have" ]]; then
    bad "the packaged rhwp library is not the one $REC describes (recorded ${want:0:12}…, found ${have:0:12}…) — ./Scripts/record-rhwp-source.sh after rebuilding it"
  else
    note "rhwp: matches the sha256 its provenance records"
  fi
  if [[ -d Vendor/rhwp-src/.git ]]; then
    wantc="$(awk -F': *' '/^rhwp commit/{print $2}' "$REC")"
    havec="$(git -C Vendor/rhwp-src rev-parse HEAD 2>/dev/null)"
    [[ -n "$havec" && "$wantc" != "$havec" ]] && \
      bad "the rhwp checkout is at ${havec:0:12}… but the library was built from ${wantc:0:12}…"
  fi
fi

# 3. KaTeX — two files from ONE npm package, so their stamped versions must agree.
CSS=Resources/katex-inlined.min.css
JS=Resources/katex.min.js
if [[ -f "$CSS" && -f "$JS" ]]; then
  vcss="$(head -3 "$CSS" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  vjs="$(grep -oE 'version"?[:=]"?[0-9]+\.[0-9]+\.[0-9]+' "$JS" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -n "$vcss" && -n "$vjs" && "$vcss" != "$vjs" ]]; then
    bad "the inlined KaTeX css is $vcss but katex.min.js is $vjs — ./Scripts/build-katex-css.sh against the SAME package"
  else
    note "katex: css and js both $vcss"
  fi
fi

if (( fail )); then
  echo "freshness check FAILED — a build product does not match its source" >&2
  exit 1
fi
echo "freshness: ok"
