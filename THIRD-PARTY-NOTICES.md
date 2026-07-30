# Third-Party Notices

This product includes software developed by third parties. All components below are under
permissive licenses (MIT, BSD-2-Clause, Apache-2.0, MPL-2.0, OFL-1.1, Unicode-3.0); none is copyleft.

Standard license texts: [MIT](https://opensource.org/license/mit),
[BSD-2-Clause](https://opensource.org/license/bsd-2-clause),
[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0),
[MPL-2.0](https://www.mozilla.org/en-US/MPL/2.0/).
Two licences require their notice to travel with the thing they cover, so both are included in full:
[`licenses/KaTeX-fonts-OFL-1.1.txt`](licenses/KaTeX-fonts-OFL-1.1.txt) and
[`licenses/UNICODE-LICENSE-V3.txt`](licenses/UNICODE-LICENSE-V3.txt).

## Swift dependencies (fetched at build time)

### swift-markdown — Apache-2.0
- Copyright: The Swift Project Authors
- https://github.com/swiftlang/swift-markdown

### swift-cmark (`gfm` branch) — BSD-2-Clause and MIT
Pulled in transitively by swift-markdown. Multi-licensed, with several named holders:
- BSD-2-Clause: Copyright (c) 2014, John MacFarlane (cmark core)
- MIT: Copyright (c) 2012, Github, Inc. (buffer); Copyright (c) 2012, Vicent Marti (houdini);
  Copyright (c) 2008-2009, Björn Höhrmann and Public Software Group (utf8 decoder);
  Copyright (c) 2015, Karl Dubost (normalization)
- https://github.com/swiftlang/swift-cmark

## Generated from third-party data

### Unicode Character Database 17.0.0 — UNICODE LICENSE V3
- Copyright (c) 1991-2026 Unicode, Inc. Unicode and the Unicode Logo are registered trademarks of
  Unicode, Inc. in the U.S. and other countries.
- https://www.unicode.org/Public/17.0.0/ucd/ — licence at https://www.unicode.org/license.txt,
  which the data files' own headers point at via https://www.unicode.org/copyright.html.
- `Sources/FastDocReader/Render/Office/Script/ScriptRanges.swift` is GENERATED from two UCD files —
  `Scripts.txt` (the Unicode Script property) and `DerivedCoreProperties.txt` (`Grapheme_Extend`) —
  by `Scripts/gen-script-ranges.py`, which is committed alongside it. No UCD file is redistributed;
  what ships is a derived range table the reader uses to draw each character in the typeface its own
  document assigned to that writing system. The generator re-fetches its input on demand and the UCD
  release is stamped into the generated file's header.
- The licence is permissive and requires only that the copyright and permission notice accompany the
  data or its documentation. It does so in three places: the generated file's own header, this entry,
  and the full text at [`licenses/UNICODE-LICENSE-V3.txt`](licenses/UNICODE-LICENSE-V3.txt).

## Vendored files (copied into this repository)

### rhwp — MIT (the HWP/HWPX parser)
- Copyright (c) 2025-2026 Edward Kim
- https://github.com/edwardkim/rhwp
- rhwp (Rust) parses `.hwp`/`.hwpx`. We ship a FORK of it — our changes: an FFI drift fix, an added
  structured-export FFI (`document_json`), and a handle-based C ABI (`rhwp_open`/`rhwp_document_json`/
  `rhwp_image_base64`/`rhwp_close`); see `docs/BUILD-RHWP.md`. It is compiled to a static-library
  xcframework and vendored as `Vendor/RhwpNative.xcframework` (arm64), statically linked into the app;
  `Sources/FastDocReader/Render/Office/HwpReader.swift` calls it (a bridge, not ported code).
- Full MIT text: [`licenses/rhwp-MIT-LICENSE.txt`](licenses/rhwp-MIT-LICENSE.txt).
- **Transitive Rust crates**: the compiled staticlib links ~131 transitive crates, **all under
  permissive licenses (MIT / Apache-2.0 / BSD-2 / BSD-3 / Zlib / Unicode-3.0 / BSL-1.0 / CC0) — zero
  copyleft** (audited against the `aarch64-apple-darwin` default-feature closure; `native-skia` is
  off). rhwp's own crate notices ship alongside at
  [`licenses/rhwp-THIRD_PARTY_LICENSES.md`](licenses/rhwp-THIRD_PARTY_LICENSES.md). Because the app
  statically links and DEAD-STRIPS the library, most of those crates — including the
  svg2pdf/resvg/tiny-skia PDF path — are stripped as uncalled and never ship at all. A precise
  per-crate notice for exactly the surviving symbols is generated with `cargo-about` before store
  submission (tracked in the sprint's deferred decisions). BSD/Zlib crates that do survive require their copyright lines
  preserved — that is what the generated notice will carry.

### mermaid v10.9.6 — MIT
- Copyright: Knut Sveidqvist and mermaid contributors
- https://github.com/mermaid-js/mermaid
- Bundled verbatim as `Resources/mermaid.min.js` (sha256
  `eda3a0ad572bbe69a318c1be0163e8233dd824f3f12939e5168feba207767151`, byte-identical to the
  official `mermaid@10.9.6/dist/mermaid.min.js`). Used transiently in an offscreen WebKit view,
  only on a diagram cache miss.

### KaTeX v0.17.0 — MIT (JavaScript)
- Copyright (c) 2013-2020 Khan Academy and other contributors
- https://github.com/KaTeX/KaTeX
- Bundled verbatim as `Resources/katex.min.js` (from `katex@0.17.0/dist/katex.min.js`). Used
  transiently in an offscreen WebKit view, only on a formula cache miss.

### KaTeX fonts — SIL Open Font License 1.1
**Not** covered by KaTeX's MIT licence, which is for its code only. Verified by reading the licence
field (name ID 13) out of the shipped font binaries; all 20 carry the same notice.
- Copyright (c) 2009-2010, Design Science, Inc. (`www.mathjax.org`)
- Copyright (c) 2014-2018 Khan Academy (`www.khanacademy.org`), with Reserved Font Name `KaTeX_*`
- Derived from MathJax's TeX fonts.
- The 20 `KaTeX_*.woff2` files are embedded as data: URIs inside `Resources/katex-inlined.min.css`
  (generated by `Scripts/build-katex-css.sh`) — embedding them is still redistribution, so the full
  licence ships alongside: [`licenses/KaTeX-fonts-OFL-1.1.txt`](licenses/KaTeX-fonts-OFL-1.1.txt),
  copied into the app bundle too.

### Libraries embedded inside `Resources/mermaid.min.js`

That file is mermaid's pre-bundled distribution, so it also contains these projects verbatim.
They are listed here because copying the bundle copies them too.

| Library | License | Copyright |
|---|---|---|
| [js-yaml](https://github.com/nodeca/js-yaml) | MIT | Vitaly Puzrin and contributors |
| [DOMPurify](https://github.com/cure53/DOMPurify) | Apache-2.0 **or** MPL-2.0 (dual — either may be chosen) | Dr.-Ing. Mario Heiderich, Cure53 |
| [KaTeX](https://github.com/KaTeX/KaTeX) | MIT | Khan Academy and contributors (code only — mermaid bundles no fonts; ours are listed above) |
| [cytoscape.js](https://github.com/cytoscape/cytoscape.js) | MIT | The Cytoscape Consortium |
| [dagre / dagre-d3](https://github.com/dagrejs/dagre) | MIT | Chris Pettitt and contributors |
| [D3](https://github.com/d3/d3) | ISC | Mike Bostock |

Smaller snippets carrying their own notices inside the same bundle:

- **Thenable** (Promises/A+ shim) — MIT, Copyright (c) 2013-2014 Ralf S. Engelschall
- **bezier-easing** — MIT, Copyright Gaetan Renaudeau
- **Spring physics adapted from Framer.js** — MIT, Copyright Koen Bok

## Notes on scope

- `Sources/` and `Scripts/` contain no copied or ported third-party SOURCE. The one file in `Sources/`
  carrying a third-party copyright is `Render/Office/Script/ScriptRanges.swift`, which is not copied
  code but a table GENERATED from Unicode's data by a script in this repo (noted above); its header
  carries the notice that licence requires. The one third-party binary is rhwp's parser, vendored as
  `Vendor/RhwpNative.xcframework` and noted above; `HwpReader.swift` only CALLS its C ABI.
- `licenses/` is copied wholesale into the app bundle by `Scripts/make-app.sh`, so every licence text
  added there travels with a shipped build without anyone having to remember it.
- The app icon (`Resources/AppIcon.icns`, `Resources/AppIcon-1024.png`) is original work.
- The only third-party fonts bundled are KaTeX's, above (OFL-1.1). Everything else the reader draws
  uses the fonts already on the Mac.
