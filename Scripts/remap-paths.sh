#!/usr/bin/env bash
# Sourced by every release build script. Defines the flags that keep the build machine's absolute
# paths (home directory, user name, cargo registry/git checkouts, this checkout) out of shipped
# binaries. Rust embeds them in panic `Location` strings and metadata; the linker records object and
# archive-member paths in the Mach-O debug map.
#
#   source "$(dirname "$0")/remap-paths.sh"
#   RUSTFLAGS="$FMD_RUSTFLAGS" cargo build --release ...
#
# Derived from the actual locations at build time — nothing here names a developer.
# `--remap-path-prefix` applies the LAST matching rule, so the broadest prefix comes first.
#
# Pass the flags with RUSTFLAGS on the cargo command. Do not export them: a target-specific
# CARGO_TARGET_<TRIPLE>_RUSTFLAGS is overridden by RUSTFLAGS, so a build that needs its own flags
# appends them to FMD_RUSTFLAGS instead.

FMD_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FMD_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
FMD_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"

FMD_RUSTFLAGS=""
[[ -n "${HOME:-}" ]] && FMD_RUSTFLAGS+=" --remap-path-prefix=$HOME=/home"
FMD_RUSTFLAGS+=" --remap-path-prefix=$FMD_RUSTUP_HOME=/rustup"
FMD_RUSTFLAGS+=" --remap-path-prefix=$FMD_CARGO_HOME=/cargo"
FMD_RUSTFLAGS+=" --remap-path-prefix=$FMD_REPO_ROOT=/src"
FMD_RUSTFLAGS="${FMD_RUSTFLAGS# }"

# C sources compiled through the `cc` crate (blake3 and friends) embed `__FILE__` the same way.
FMD_CFLAGS="-ffile-prefix-map=$FMD_REPO_ROOT=/src -ffile-prefix-map=$FMD_CARGO_HOME=/cargo"
[[ -n "${HOME:-}" ]] && FMD_CFLAGS="-ffile-prefix-map=$HOME=/home $FMD_CFLAGS"

# Swift: source paths from `#file`/`#filePath` and debug info.
FMD_SWIFT_PREFIX_FLAGS=(
  -Xswiftc -file-prefix-map -Xswiftc "$FMD_REPO_ROOT=/src"
  -Xswiftc -debug-prefix-map -Xswiftc "$FMD_REPO_ROOT=/src"
)
