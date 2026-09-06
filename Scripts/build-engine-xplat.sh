#!/bin/bash
# Builds the fastdoc-ffi cdylib for every platform an Avalonia P/Invoke host needs to load it on:
# macOS (arm64), Windows (x64, arm64) and Linux (x64, arm64 best-effort).
#
# This is separate from Scripts/build-engine.sh on purpose: that script packages the STATICLIB into
# Vendor/FastdocEngine.xcframework for the macOS app's own build, using rust/target/ as its build
# directory. This script builds the CDYLIB for a different consumer (a .NET host, not Xcode) into its
# own rust/target-xplat/<triple> directories, so a run of this script can never leave rust/target/
# older or newer than what the macOS engine gate expects.
#
#   ./Scripts/build-engine-xplat.sh
#
# Output layout:
#   rust/dist/xplat/macos-arm64/libfastdoc_engine_ffi.dylib
#   rust/dist/xplat/windows-x64/fastdoc_engine_ffi.dll
#   rust/dist/xplat/windows-arm64/fastdoc_engine_ffi.dll   (only if llvm-mingw is installed)
#   rust/dist/xplat/linux-x64/libfastdoc_engine_ffi.so
#   rust/dist/xplat/linux-arm64/libfastdoc_engine_ffi.so   (only if the Docker platform build succeeds)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

MANIFEST="$REPO/rust/Cargo.toml"
OUT_ROOT="$REPO/rust/dist/xplat"
mkdir -p "$OUT_ROOT"

# ---------------------------------------------------------------------------
# macOS (arm64) — built directly on this machine.
# ---------------------------------------------------------------------------
build_macos() {
  local triple=aarch64-apple-darwin
  local out_dir="$OUT_ROOT/macos-arm64"
  echo "==> [macos-arm64] cargo build --release ($triple)"
  cargo build --release \
    --manifest-path "$MANIFEST" \
    -p fastdoc-ffi \
    --target "$triple" \
    --target-dir "$REPO/rust/target-xplat/$triple"
  mkdir -p "$out_dir"
  cp "$REPO/rust/target-xplat/$triple/$triple/release/libfastdoc_engine_ffi.dylib" "$out_dir/"
  echo "==> [macos-arm64] $(file "$out_dir/libfastdoc_engine_ffi.dylib")"
}

# ---------------------------------------------------------------------------
# Windows (x64) — cross-compiled with the mingw-w64 linker.
# ---------------------------------------------------------------------------
build_windows() {
  local triple=x86_64-pc-windows-gnu
  local out_dir="$OUT_ROOT/windows-x64"
  local linker="/opt/homebrew/bin/x86_64-w64-mingw32-gcc"

  if [ ! -x "$linker" ]; then
    echo "==> [windows-x64] SKIPPED: mingw-w64 linker not found at $linker"
    return 0
  fi

  echo "==> [windows-x64] cargo build --release ($triple)"
  CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$linker" \
    cargo build --release \
    --manifest-path "$MANIFEST" \
    -p fastdoc-ffi \
    --target "$triple" \
    --target-dir "$REPO/rust/target-xplat/$triple"
  mkdir -p "$out_dir"
  cp "$REPO/rust/target-xplat/$triple/$triple/release/fastdoc_engine_ffi.dll" "$out_dir/"
  echo "==> [windows-x64] $(file "$out_dir/fastdoc_engine_ffi.dll")"

  strip_windows_dll "$out_dir/fastdoc_engine_ffi.dll"
}

# ---------------------------------------------------------------------------
# Windows (arm64) — cross-compiled with llvm-mingw (the GNU mingw-w64 toolchain has no aarch64
# port; Rust's aarch64-pc-windows-gnullvm target exists for exactly this toolchain). blake3 builds
# C/asm through the cc crate, so the toolchain's clang is handed over as CC/AR as well as the linker.
# Windows 11 on ARM runs the x64 build through emulation, so this is what an ARM laptop should get.
# ---------------------------------------------------------------------------
build_windows_arm64() {
  local triple=aarch64-pc-windows-gnullvm
  local out_dir="$OUT_ROOT/windows-arm64"
  local tc="${LLVM_MINGW_DIR:-$HOME/.local/opt/llvm-mingw}/bin"
  local linker="$tc/aarch64-w64-mingw32-clang"

  if [ ! -x "$linker" ]; then
    echo "==> [windows-arm64] SKIPPED: llvm-mingw not found at $tc (set LLVM_MINGW_DIR)"
    return 0
  fi

  # rustc's target spec links the unwinder with a plain `-lunwind` under `-Bdynamic`, so in the
  # toolchain's lib dir (which holds both libunwind.a and libunwind.dll.a) the linker picks the
  # import library and the DLL then imports libunwind.dll — a runtime file no Windows machine has;
  # LoadLibrary fails with 0x8007007E (measured on Windows 11 ARM64). `-static` and
  # `-static-libgcc` do not change that (both measured). A search directory that holds ONLY
  # libunwind.a, placed ahead of the toolchain's, does. Check after every toolchain bump:
  #   llvm-objdump -p <dll> | grep "DLL Name"   must not list libunwind.dll
  local static_unwind="$REPO/rust/target-xplat/$triple/static-unwind"
  mkdir -p "$static_unwind"
  cp "$tc/../aarch64-w64-mingw32/lib/libunwind.a" "$static_unwind/"

  echo "==> [windows-arm64] cargo build --release ($triple)"
  CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_RUSTFLAGS="-L native=$static_unwind" \
  CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_LINKER="$linker" \
  CC_aarch64_pc_windows_gnullvm="$linker" \
  AR_aarch64_pc_windows_gnullvm="$tc/aarch64-w64-mingw32-ar" \
    cargo build --release \
    --manifest-path "$MANIFEST" \
    -p fastdoc-ffi \
    --target "$triple" \
    --target-dir "$REPO/rust/target-xplat/$triple"
  mkdir -p "$out_dir"
  cp "$REPO/rust/target-xplat/$triple/$triple/release/fastdoc_engine_ffi.dll" "$out_dir/"
  echo "==> [windows-arm64] $(file "$out_dir/fastdoc_engine_ffi.dll")"

  if "$tc/llvm-objdump" -p "$out_dir/fastdoc_engine_ffi.dll" | grep -q "DLL Name: libunwind.dll"; then
    echo "FAIL: [windows-arm64] fastdoc_engine_ffi.dll imports libunwind.dll — it would not load on Windows" >&2
    exit 1
  fi

  local before_bytes after_bytes
  before_bytes=$(stat -f%z "$out_dir/fastdoc_engine_ffi.dll")
  "$tc/aarch64-w64-mingw32-strip" --strip-all "$out_dir/fastdoc_engine_ffi.dll"
  after_bytes=$(stat -f%z "$out_dir/fastdoc_engine_ffi.dll")
  echo "==> [windows-arm64] stripped: $before_bytes -> $after_bytes bytes"
}

# ---------------------------------------------------------------------------
# Strip debug symbols from the cross-compiled Windows DLL with the mingw-w64 toolchain's own
# strip binary — not a native macOS tool, since the object format differs (PE vs Mach-O).
# ---------------------------------------------------------------------------
strip_windows_dll() {
  local dll="$1"
  local stripper="/opt/homebrew/bin/x86_64-w64-mingw32-strip"

  if [ ! -x "$stripper" ]; then
    echo "==> [windows-x64] strip SKIPPED: $stripper not found"
    return 0
  fi

  local before_bytes
  before_bytes=$(stat -f%z "$dll")
  "$stripper" --strip-all "$dll"
  local after_bytes
  after_bytes=$(stat -f%z "$dll")
  echo "==> [windows-x64] stripped: $before_bytes -> $after_bytes bytes ($(echo "scale=1; $before_bytes/1048576" | bc)MB -> $(echo "scale=1; $after_bytes/1048576" | bc)MB)"
}

# ---------------------------------------------------------------------------
# Linux — built inside Docker so the host never needs a Linux cross-toolchain.
#
# rhwp is a git dependency (github.com/ww-w-ai/rhwp, pinned rev). A slim container has no network
# credentials to fetch it, so this mounts the HOST's cargo registry/git caches read-write and builds
# --offline: the crate is already resolved on this machine (it's a dependency of the very fastdoc-ffi
# crate this script builds), so no network fetch is needed once the cache is visible inside.
# ---------------------------------------------------------------------------
build_linux() {
  local triple="$1"          # e.g. x86_64-unknown-linux-gnu
  local platform="$2"        # e.g. linux/amd64
  local out_name="$3"        # e.g. linux-x64
  local out_dir="$OUT_ROOT/$out_name"

  echo "==> [$out_name] docker build ($triple via $platform)"
  # Strip runs INSIDE the same container, right after the build: the container's own `strip` is
  # native to $platform (via qemu emulation, matching the .so's actual object format), whereas the
  # host's mingw-w64 strip only understands PE, not ELF — there is no macOS cross-strip for Linux.
  if ! docker run --rm \
    --platform "$platform" \
    -v "$REPO:/work" \
    -v "$HOME/.cargo/registry:/usr/local/cargo/registry" \
    -v "$HOME/.cargo/git:/usr/local/cargo/git" \
    -w /work \
    rust:1.93-slim \
    bash -c "cargo build --release --offline --manifest-path rust/Cargo.toml -p fastdoc-ffi --target-dir rust/target-xplat/docker-$out_name && \
      before=\$(stat -c%s rust/target-xplat/docker-$out_name/release/libfastdoc_engine_ffi.so) && \
      if command -v strip >/dev/null 2>&1; then strip --strip-all rust/target-xplat/docker-$out_name/release/libfastdoc_engine_ffi.so; else echo 'strip not found in container, skipping'; fi && \
      after=\$(stat -c%s rust/target-xplat/docker-$out_name/release/libfastdoc_engine_ffi.so) && \
      echo \"==> [$out_name] stripped (in-container): \$before -> \$after bytes\""
  then
    echo "==> [$out_name] SKIPPED: docker build failed (see log above) — not treated as a hard failure"
    return 0
  fi

  local produced="$REPO/rust/target-xplat/docker-$out_name/release/libfastdoc_engine_ffi.so"
  if [ ! -f "$produced" ]; then
    echo "==> [$out_name] SKIPPED: build reported success but $produced is missing"
    return 0
  fi
  mkdir -p "$out_dir"
  cp "$produced" "$out_dir/"
  echo "==> [$out_name] $(file "$out_dir/libfastdoc_engine_ffi.so")"
}

build_macos
build_windows
build_windows_arm64
build_linux x86_64-unknown-linux-gnu   linux/amd64 linux-x64
build_linux aarch64-unknown-linux-gnu  linux/arm64 linux-arm64

echo "==> done: $OUT_ROOT"
