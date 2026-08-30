#!/bin/bash
# Builds the ported Rust engine and packages it the way this repo already packages rhwp: a
# static-library xcframework under Vendor/, absorbed into the executable at link time.
#
# Run by make-app.sh when the packaged library is missing or older than the Rust source. The rhwp
# binary is committed because its source lives outside this repo; this engine's source is right
# here, so committing a build product of it would be a second copy that can disagree with the code
# beside it. Nothing else notices that disagreement — `swift build` rebuilds only the Swift half —
# so the check that keeps the two in step lives in make-app.sh and must stay there.
#
#   ./Scripts/build-engine.sh                 # build + package
#   FMD_RUST_ENGINE=1 ./Scripts/make-app.sh   # build an app that links and uses it
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TARGET=aarch64-apple-darwin
OUT=Vendor/FastdocEngine.xcframework

echo "==> cargo build --release ($TARGET)"
cargo build --release --manifest-path rust/Cargo.toml -p fastdoc-ffi --target "$TARGET"

echo "==> packaging $OUT"
rm -rf "$OUT" rust/dist/swift
mkdir -p rust/dist/swift/Headers
cp rust/crates/fastdoc-ffi/include/fastdoc_engine_ffi.h rust/dist/swift/Headers/
cp rust/crates/fastdoc-ffi/include/module.modulemap     rust/dist/swift/Headers/
xcodebuild -create-xcframework \
  -library "rust/target/$TARGET/release/libfastdoc_engine_ffi.a" \
  -headers rust/dist/swift/Headers \
  -output "$OUT" >/dev/null

echo "==> done: $OUT"
