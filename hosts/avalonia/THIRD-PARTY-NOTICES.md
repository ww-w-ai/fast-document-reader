# Third-Party Notices — FastDoc (Avalonia host)

## 1. NuGet packages shipped with the application

Source of each version: `hosts/avalonia/FastDoc.Avalonia/FastDoc.Avalonia.csproj`. Licenses read from the `<license>` element of each package's `.nuspec` in the local NuGet cache (`~/.nuget/packages/<id>/<version>/`). Transitive NuGet dependencies are not enumerated here.

| Component | Version | License | Source |
|---|---|---|---|
| Avalonia | 12.1.2 | MIT | `~/.nuget/packages/avalonia/12.1.2/avalonia.nuspec` — https://avaloniaui.net/ |
| Avalonia.Desktop | 12.1.2 | MIT | `~/.nuget/packages/avalonia.desktop/12.1.2/avalonia.desktop.nuspec` |
| Avalonia.Themes.Fluent | 12.1.2 | MIT | `~/.nuget/packages/avalonia.themes.fluent/12.1.2/avalonia.themes.fluent.nuspec` |
| Avalonia.Fonts.Inter | 12.1.2 | MIT (package); Inter typeface license: Unverified (see section 3) | `~/.nuget/packages/avalonia.fonts.inter/12.1.2/avalonia.fonts.inter.nuspec` |
| Avalonia.Headless | 12.1.2 | MIT | `~/.nuget/packages/avalonia.headless/12.1.2/avalonia.headless.nuspec` |
| SkiaSharp | 3.119.4 | MIT (Copyright 2015-2016 Xamarin, Inc.; 2017-2018 Microsoft Corporation) | `~/.nuget/packages/skiasharp/3.119.4/LICENSE.txt`, `skiasharp.nuspec` |
| AvaloniaUI.DiagnosticsSupport | 2.2.3 | Unverified — the `.nuspec` carries no `<license>` or `<licenseUrl>` element; copyright "2019-2026 AvaloniaUI OÜ". Not in the distributed build: the `PackageReference` sets `IncludeAssets=None` and `PrivateAssets=All` for every configuration other than Debug (`FastDoc.Avalonia.csproj` lines 20-23), so Release builds do not reference it. | `~/.nuget/packages/avaloniaui.diagnosticssupport/2.2.3/avaloniaui.diagnosticssupport.nuspec` — https://avaloniaui.net/ |

## 2. Test-only packages (not included in the distributed build)

Source: `hosts/avalonia/FastDoc.Avalonia.Tests/FastDoc.Avalonia.Tests.csproj` (`IsPackable=false`, referenced only by the test project).

| Component | Version | License | Source |
|---|---|---|---|
| coverlet.collector | 6.0.2 | MIT | `~/.nuget/packages/coverlet.collector/6.0.2/coverlet.collector.nuspec` — https://github.com/coverlet-coverage/coverlet |
| Microsoft.NET.Test.Sdk | 17.12.0 | MIT | `~/.nuget/packages/microsoft.net.test.sdk/17.12.0/microsoft.net.test.sdk.nuspec` — https://github.com/microsoft/vstest |
| xunit | 2.9.2 | Apache-2.0 | `~/.nuget/packages/xunit/2.9.2/xunit.nuspec` |
| xunit.runner.visualstudio | 2.8.2 | Apache-2.0 | `~/.nuget/packages/xunit.runner.visualstudio/2.8.2/xunit.runner.visualstudio.nuspec` |

## 3. Fonts

| Component | Version | License | Source |
|---|---|---|---|
| Noto Sans KR (`Assets/Fonts/NotoSansKR-Regular.ttf`, Noto Sans CJK KR region subset, converted to TrueType outlines with fontTools — S5-C2) | 2.004 (read from the `head.fontRevision` and `name` table version string of the shipped TTF via fontTools — S7-F) | SIL Open Font License 1.1 — full text bundled at `hosts/avalonia/FastDoc.Avalonia/Assets/Fonts/NotoSansKR-OFL.txt` (Copyright 2014-2021 Adobe, Reserved Font Name 'Source') | https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/KR/NotoSansKR-Regular.otf |
| Inter (embedded in `Avalonia.Fonts.Inter` 12.1.2) | Unverified — the NuGet package ships only `Avalonia.Fonts.Inter.dll`/`.xml` and no font file or license text, so no version string is readable from package contents (checked S7-F) | OFL 1.1 per upstream Inter project — not verified from package contents; the package's own license is MIT | `~/.nuget/packages/avalonia.fonts.inter/12.1.2/` — upstream: https://github.com/rsms/inter |

## 4. rhwp (HWP/HWPX parser, Rust)

| Component | Version | License | Source |
|---|---|---|---|
| rhwp (fork maintained by ww-w-ai; upstream edwardkim/rhwp, base commit `8d3bfa4b92174b16bac587fe1409975cf34ba566`) | 0.7.19, pinned commit `bcf7acf2fa05a2f00bbe9d4c97b78daa1d20ea00` | MIT (Copyright (c) 2025-2026 Edward Kim) | `Vendor/rhwp-src/LICENSE`; `Cargo.toml` `license = "MIT"` in the pinned checkout; pin recorded in `Vendor/RHWP-SOURCE.txt` and `rust/Cargo.lock`; patch record in `vendor-patches/rhwp/README.md` |

rhwp's own third-party notices (its Rust crates, npm packages, and bundled fonts) are in `Vendor/rhwp-src/THIRD_PARTY_LICENSES.md` (same file in the cargo checkout: `~/.cargo/git/checkouts/rhwp-*/bcf7acf/THIRD_PARTY_LICENSES.md`). The Rust crates rhwp pulls into this build are also resolved individually in section 5 below.

## 5. Rust engine crates (`fastdoc_engine_ffi`)

Package list: every `[[package]]` in `rust/Cargo.lock` (172 entries). Four are this repository's own or git-sourced: `fastdoc-engine`, `fastdoc-ffi`, `swiftshim` (workspace crates, `publish = false`, no `license` field — first party) and `rhwp` (section 4). The remaining 168 are crates.io crates; each license below is the `license` field of `~/.cargo/registry/src/*/<crate>-<version>/Cargo.toml`. The Shipped column was determined by `cargo tree -e normal --manifest-path rust/Cargo.toml -p fastdoc-ffi --prefix none --no-dedupe` (S7-F): a crate reachable through a normal (non-build, non-dev) dependency edge from `fastdoc-ffi` is `shipped`; the remaining 21 are build-time-only (proc-macro codegen helpers, `cc`/`find-msvc-tools` native-toolchain drivers, and wasm/js interop crates pulled in only by other crates' build scripts on this workspace) and never link into the distributed binary — marked `build-only`. 147 shipped + 21 build-only = 168.

| Crate | Version | Shipped | License | Source |
|---|---|---|---|---|
| adler2 | 2.0.1 | shipped | 0BSD OR MIT OR Apache-2.0 | https://github.com/oyvindln/adler2 |
| aho-corasick | 1.1.5 | shipped | Unlicense OR MIT | https://github.com/BurntSushi/aho-corasick |
| arrayref | 0.3.9 | shipped | BSD-2-Clause | https://github.com/droundy/arrayref |
| arrayvec | 0.7.8 | shipped | MIT OR Apache-2.0 | https://github.com/bluss/arrayvec |
| autocfg | 1.5.1 | build-only | Apache-2.0 OR MIT | https://github.com/cuviper/autocfg |
| base64 | 0.22.1 | shipped | MIT OR Apache-2.0 | https://github.com/marshallpierce/rust-base64 |
| bitflags | 1.3.2 | shipped | MIT/Apache-2.0 | https://github.com/bitflags/bitflags |
| bitflags | 2.13.1 | shipped | MIT OR Apache-2.0 | https://github.com/bitflags/bitflags |
| blake3 | 1.8.7 | shipped | CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception | https://github.com/BLAKE3-team/BLAKE3 |
| block-buffer | 0.10.4 | shipped | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| bumpalo | 3.20.3 | shipped | MIT OR Apache-2.0 | https://github.com/fitzgen/bumpalo |
| bytemuck | 1.25.2 | shipped | Zlib OR Apache-2.0 OR MIT | https://github.com/Lokathor/bytemuck |
| bytemuck_derive | 1.12.0 | shipped | Zlib OR Apache-2.0 OR MIT | https://github.com/Lokathor/bytemuck |
| byteorder | 1.5.0 | shipped | Unlicense OR MIT | https://github.com/BurntSushi/byteorder |
| byteorder-lite | 0.1.0 | shipped | Unlicense OR MIT | https://github.com/image-rs/byteorder-lite |
| caseless | 0.2.2 | shipped | MIT | https://github.com/unicode-rs/rust-caseless |
| cc | 1.4.3 | build-only | MIT OR Apache-2.0 | https://github.com/rust-lang/cc-rs |
| cfb | 0.14.0 | shipped | MIT | https://github.com/mdsteele/rust-cfb |
| cfg-if | 1.0.4 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/cfg-if |
| codepage | 0.1.2 | shipped | Apache-2.0 OR MIT | https://github.com/hsivonen/codepage |
| color_quant | 1.1.0 | shipped | MIT | https://github.com/image-rs/color_quant.git |
| comrak | 0.54.0 | shipped | BSD-2-Clause | https://github.com/kivikakk/comrak |
| constant_time_eq | 0.4.2 | shipped | CC0-1.0 OR MIT-0 OR Apache-2.0 | https://github.com/cesarb/constant_time_eq |
| core_maths | 0.1.1 | shipped | MIT | https://github.com/robertbastian/core_maths |
| cpufeatures | 0.2.17 | shipped | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| cpufeatures | 0.3.0 | build-only | MIT OR Apache-2.0 | https://github.com/RustCrypto/utils |
| crc32fast | 1.5.0 | shipped | MIT OR Apache-2.0 | https://github.com/srijs/rust-crc32fast |
| crunchy | 0.2.4 | build-only | MIT | https://github.com/eira-fransham/crunchy |
| crypto-common | 0.1.7 | shipped | MIT OR Apache-2.0 | https://github.com/RustCrypto/traits |
| data-url | 0.3.2 | shipped | MIT OR Apache-2.0 | https://github.com/servo/rust-url |
| digest | 0.10.7 | shipped | MIT OR Apache-2.0 | https://github.com/RustCrypto/traits |
| embedded-io | 0.7.1 | shipped | MIT OR Apache-2.0 | https://github.com/rust-embedded/embedded-hal |
| encoding_rs | 0.8.35 | shipped | (Apache-2.0 OR MIT) AND BSD-3-Clause | https://github.com/hsivonen/encoding_rs |
| entities | 1.0.1 | build-only | MIT | https://github.com/p-jackson/entities |
| equivalent | 1.0.2 | shipped | Apache-2.0 OR MIT | https://github.com/indexmap-rs/equivalent |
| euclid | 0.22.14 | build-only | MIT OR Apache-2.0 | https://github.com/servo/euclid |
| fastrand | 2.5.0 | build-only | Apache-2.0 OR MIT | https://github.com/smol-rs/fastrand |
| fax | 0.2.7 | shipped | MIT | https://github.com/pdf-rs/fax |
| fdeflate | 0.3.7 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/fdeflate |
| find-msvc-tools | 0.1.11 | build-only | MIT OR Apache-2.0 | https://github.com/rust-lang/cc-rs |
| finl_unicode | 1.4.0 | shipped | (MIT OR Apache-2.0) AND Unicode-DFS-2016 | https://github.com/dahosek/finl_unicode |
| flate2 | 1.1.9 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/flate2-rs |
| float-cmp | 0.9.0 | shipped | MIT | https://github.com/mikedilger/float-cmp |
| fnv | 1.0.7 | shipped | Apache-2.0 / MIT | https://github.com/servo/rust-fnv |
| font-types | 0.11.3 | shipped | MIT OR Apache-2.0 | https://github.com/googlefonts/fontations |
| fontconfig-parser | 0.5.8 | build-only | MIT | https://github.com/Riey/fontconfig-parser |
| fontdb | 0.23.0 | shipped | MIT | https://github.com/RazrFalcon/fontdb |
| futures-core | 0.3.34 | build-only | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-task | 0.3.34 | build-only | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| futures-util | 0.3.34 | build-only | MIT OR Apache-2.0 | https://github.com/rust-lang/futures-rs |
| generic-array | 0.14.7 | shipped | MIT | https://github.com/fizyk20/generic-array.git |
| gif | 0.13.3 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/image-gif |
| gif | 0.14.2 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/image-gif |
| half | 2.7.1 | shipped | MIT OR Apache-2.0 | https://github.com/VoidStarKat/half-rs |
| hashbrown | 0.17.1 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/hashbrown |
| heck | 0.5.0 | shipped | MIT OR Apache-2.0 | https://github.com/withoutboats/heck |
| image | 0.25.10 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/image |
| image-webp | 0.2.4 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/image-webp |
| imagesize | 0.13.0 | shipped | MIT | https://github.com/Roughsketch/imagesize |
| indexmap | 2.14.0 | shipped | Apache-2.0 OR MIT | https://github.com/indexmap-rs/indexmap |
| itoa | 1.0.18 | shipped | MIT OR Apache-2.0 | https://github.com/dtolnay/itoa |
| jetscii | 0.5.3 | shipped | MIT OR Apache-2.0 | https://github.com/shepmaster/jetscii |
| js-sys | 0.3.104 | build-only | MIT OR Apache-2.0 | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/js-sys |
| kurbo | 0.11.3 | shipped | Apache-2.0 OR MIT | https://github.com/linebender/kurbo |
| kurbo | 0.13.1 | shipped | Apache-2.0 OR MIT | https://github.com/linebender/kurbo |
| libc | 0.2.189 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/libc |
| libm | 0.2.16 | shipped | MIT | https://github.com/rust-lang/compiler-builtins |
| log | 0.4.33 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/log |
| memchr | 2.8.3 | shipped | Unlicense OR MIT | https://github.com/BurntSushi/memchr |
| memmap2 | 0.9.11 | shipped | MIT OR Apache-2.0 | https://github.com/RazrFalcon/memmap2-rs |
| miniz_oxide | 0.8.9 | shipped | MIT OR Zlib OR Apache-2.0 | https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide |
| moxcms | 0.8.1 | shipped | BSD-3-Clause OR Apache-2.0 | https://github.com/awxkee/moxcms.git |
| num-traits | 0.2.19 | shipped | MIT OR Apache-2.0 | https://github.com/rust-num/num-traits |
| once_cell | 1.21.4 | shipped | MIT OR Apache-2.0 | https://github.com/matklad/once_cell |
| paste | 1.0.15 | shipped | MIT OR Apache-2.0 | https://github.com/dtolnay/paste |
| pcx | 0.2.5 | shipped | MIT OR Apache-2.0 OR WTFPL | https://github.com/kryptan/pcx |
| pdf-writer | 0.12.1 | shipped | MIT OR Apache-2.0 | https://github.com/typst/pdf-writer |
| phf | 0.13.1 | shipped | MIT | https://github.com/rust-phf/rust-phf |
| phf_codegen | 0.13.1 | build-only | MIT | https://github.com/rust-phf/rust-phf |
| phf_generator | 0.13.1 | build-only | MIT | https://github.com/rust-phf/rust-phf |
| phf_shared | 0.13.1 | shipped | MIT | https://github.com/rust-phf/rust-phf |
| pico-args | 0.5.0 | shipped | MIT | https://github.com/RazrFalcon/pico-args |
| pin-project-lite | 0.2.17 | build-only | Apache-2.0 OR MIT | https://github.com/taiki-e/pin-project-lite |
| png | 0.17.16 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/image-png |
| png | 0.18.1 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/image-png |
| polycool | 0.4.0 | shipped | MIT OR Apache-2.0 | https://github.com/linebender/kurbo |
| proc-macro2 | 1.0.107 | shipped | MIT OR Apache-2.0 | https://github.com/dtolnay/proc-macro2 |
| pxfm | 0.1.30 | shipped | BSD-3-Clause OR Apache-2.0 | https://github.com/awxkee/pxfm |
| quick-error | 2.0.1 | shipped | MIT/Apache-2.0 | http://github.com/tailhook/quick-error |
| quick-xml | 0.37.5 | shipped | MIT | https://github.com/tafia/quick-xml |
| quick-xml | 0.41.0 | shipped | MIT | https://github.com/tafia/quick-xml |
| quote | 1.0.47 | shipped | MIT OR Apache-2.0 | https://github.com/dtolnay/quote |
| read-fonts | 0.39.2 | shipped | MIT OR Apache-2.0 | https://github.com/googlefonts/fontations |
| regex | 1.13.1 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/regex |
| regex-automata | 0.4.18 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/regex |
| regex-syntax | 0.8.11 | shipped | MIT OR Apache-2.0 | https://github.com/rust-lang/regex |
| resvg | 0.45.1 | shipped | Apache-2.0 OR MIT | https://github.com/linebender/resvg |
| rgb | 0.8.53 | shipped | MIT | https://github.com/kornelski/rust-rgb |
| roxmltree | 0.20.0 | shipped | MIT OR Apache-2.0 | https://github.com/RazrFalcon/roxmltree |
| rustc-hash | 2.1.3 | shipped | Apache-2.0 OR MIT | https://github.com/rust-lang/rustc-hash |
| rustversion | 1.0.23 | build-only | MIT OR Apache-2.0 | https://github.com/dtolnay/rustversion |
| rustybuzz | 0.20.1 | shipped | MIT | https://github.com/harfbuzz/rustybuzz |
| ryu | 1.0.23 | shipped | Apache-2.0 OR BSL-1.0 | https://github.com/dtolnay/ryu |
| serde | 1.0.229 | shipped | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_core | 1.0.229 | shipped | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_derive | 1.0.229 | shipped | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.151 | shipped | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| sha2 | 0.10.9 | shipped | MIT OR Apache-2.0 | https://github.com/RustCrypto/hashes |
| shlex | 2.0.1 | build-only | MIT OR Apache-2.0 | https://github.com/comex/rust-shlex |
| simd-adler32 | 0.3.10 | shipped | MIT | https://github.com/mcountryman/simd-adler32 |
| simplecss | 0.2.2 | shipped | Apache-2.0 OR MIT | https://github.com/linebender/simplecss |
| siphasher | 1.0.3 | shipped | MIT/Apache-2.0 | https://github.com/jedisct1/rust-siphash |
| skrifa | 0.42.1 | shipped | MIT OR Apache-2.0 | https://github.com/googlefonts/fontations |
| slab | 0.4.12 | build-only | MIT | https://github.com/tokio-rs/slab |
| slotmap | 1.1.1 | shipped | Zlib | https://github.com/orlp/slotmap |
| smallvec | 1.15.2 | shipped | MIT OR Apache-2.0 | https://github.com/servo/rust-smallvec |
| snafu | 0.9.2 | shipped | MIT OR Apache-2.0 | https://github.com/shepmaster/snafu |
| snafu-derive | 0.9.2 | shipped | MIT OR Apache-2.0 | https://github.com/shepmaster/snafu |
| strict-num | 0.1.1 | shipped | MIT | https://github.com/RazrFalcon/strict-num |
| strum | 0.28.0 | shipped | MIT | https://github.com/Peternator7/strum |
| strum_macros | 0.28.0 | shipped | MIT | https://github.com/Peternator7/strum |
| subsetter | 0.2.6 | shipped | MIT OR Apache-2.0 | https://github.com/typst/subsetter |
| svg2pdf | 0.13.0 | shipped | MIT OR Apache-2.0 | https://github.com/typst/svg2pdf |
| svgtypes | 0.15.3 | shipped | Apache-2.0 OR MIT | https://github.com/linebender/svgtypes |
| svgtypes | 0.16.1 | shipped | Apache-2.0 OR MIT | https://github.com/linebender/svgtypes |
| syn | 2.0.119 | shipped | MIT OR Apache-2.0 | https://github.com/dtolnay/syn |
| syn | 3.0.3 | shipped | MIT OR Apache-2.0 | https://github.com/dtolnay/syn |
| tiff | 0.11.3 | shipped | MIT | https://github.com/image-rs/image-tiff |
| tiny-skia | 0.11.4 | shipped | BSD-3-Clause | https://github.com/RazrFalcon/tiny-skia |
| tiny-skia-path | 0.11.4 | shipped | BSD-3-Clause | https://github.com/RazrFalcon/tiny-skia/tree/master/path |
| tinyvec | 1.12.0 | shipped | Zlib OR Apache-2.0 OR MIT | https://github.com/Lokathor/tinyvec |
| tinyvec_macros | 0.1.1 | shipped | MIT OR Apache-2.0 OR Zlib | https://github.com/Soveu/tinyvec_macros |
| ttf-parser | 0.25.1 | shipped | MIT OR Apache-2.0 | https://github.com/harfbuzz/ttf-parser |
| typed-arena | 2.0.2 | shipped | MIT | https://github.com/SimonSapin/rust-typed-arena |
| typed-path | 0.12.3 | shipped | MIT OR Apache-2.0 | https://github.com/chipsenkbeil/typed-path |
| typenum | 1.20.1 | shipped | MIT OR Apache-2.0 | https://github.com/paholg/typenum |
| unicode-bidi | 0.3.18 | shipped | MIT OR Apache-2.0 | https://github.com/servo/unicode-bidi |
| unicode-bidi-mirroring | 0.4.0 | shipped | MIT/Apache-2.0 | https://github.com/RazrFalcon/unicode-bidi-mirroring |
| unicode-ccc | 0.4.0 | shipped | MIT/Apache-2.0 | https://github.com/RazrFalcon/unicode-ccc |
| unicode-ident | 1.0.24 | shipped | (MIT OR Apache-2.0) AND Unicode-3.0 | https://github.com/dtolnay/unicode-ident |
| unicode-normalization | 0.1.25 | shipped | MIT OR Apache-2.0 | https://github.com/unicode-rs/unicode-normalization |
| unicode-properties | 0.1.4 | shipped | MIT/Apache-2.0 | https://github.com/unicode-rs/unicode-properties |
| unicode-script | 0.5.8 | shipped | MIT OR Apache-2.0 | https://github.com/unicode-rs/unicode-script |
| unicode-segmentation | 1.13.3 | shipped | MIT OR Apache-2.0 | https://github.com/unicode-rs/unicode-segmentation |
| unicode-vo | 0.1.0 | shipped | MIT/Apache-2.0 | https://github.com/RazrFalcon/unicode-vo |
| unicode-width | 0.2.2 | shipped | MIT OR Apache-2.0 | https://github.com/unicode-rs/unicode-width |
| usvg | 0.45.1 | shipped | Apache-2.0 OR MIT | https://github.com/linebender/resvg |
| uuid | 1.24.1 | shipped | Apache-2.0 OR MIT | https://github.com/uuid-rs/uuid |
| version_check | 0.9.5 | build-only | MIT/Apache-2.0 | https://github.com/SergioBenitez/version_check |
| wasm-bindgen | 0.2.127 | shipped | MIT OR Apache-2.0 | https://github.com/wasm-bindgen/wasm-bindgen |
| wasm-bindgen-macro | 0.2.127 | shipped | MIT OR Apache-2.0 | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/macro |
| wasm-bindgen-macro-support | 0.2.127 | shipped | MIT OR Apache-2.0 | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/macro-support |
| wasm-bindgen-shared | 0.2.127 | shipped | MIT OR Apache-2.0 | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/shared |
| web-sys | 0.3.104 | build-only | MIT OR Apache-2.0 | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/web-sys |
| web-time | 1.1.0 | shipped | MIT OR Apache-2.0 | https://github.com/daxpedda/web-time |
| weezl | 0.1.12 | shipped | MIT OR Apache-2.0 | https://github.com/image-rs/weezl |
| write-fonts | 0.48.1 | shipped | MIT OR Apache-2.0 | https://github.com/googlefonts/fontations |
| xmlwriter | 0.1.0 | shipped | MIT | https://github.com/RazrFalcon/xmlwriter |
| zerocopy | 0.8.56 | shipped | BSD-2-Clause OR Apache-2.0 OR MIT | https://github.com/google/zerocopy |
| zerocopy-derive | 0.8.56 | shipped | BSD-2-Clause OR Apache-2.0 OR MIT | https://github.com/google/zerocopy |
| zip | 8.6.0 | shipped | MIT | https://github.com/zip-rs/zip2 |
| zlib-rs | 0.6.7 | shipped | Zlib | https://github.com/trifectatechfoundation/zlib-rs |
| zmij | 1.0.23 | shipped | MIT | https://github.com/dtolnay/zmij |
| zopfli | 0.8.3 | shipped | Apache-2.0 | https://github.com/zopfli-rs/zopfli |
| zune-core | 0.4.12 | shipped | MIT OR Apache-2.0 OR Zlib | crates.io (no `repository` field in Cargo.toml) |
| zune-core | 0.5.3 | shipped | MIT OR Apache-2.0 OR Zlib | https://github.com/etemesi254/zune-image |
| zune-jpeg | 0.4.21 | shipped | MIT OR Apache-2.0 OR Zlib | https://github.com/etemesi254/zune-image/tree/dev/crates/zune-jpeg |
| zune-jpeg | 0.5.15 | shipped | MIT OR Apache-2.0 OR Zlib | https://github.com/etemesi254/zune-image/tree/dev/crates/zune-jpeg |

## 6. Runtime

| Component | Version | License | Source |
|---|---|---|---|
| .NET runtime (Microsoft) | net9.0 (`TargetFramework` in `FastDoc.Avalonia.csproj`) | MIT | https://github.com/dotnet/runtime |
