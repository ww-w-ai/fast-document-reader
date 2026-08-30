# fast-md-reader — dev notes (read before continuing)

Native macOS **document viewer** (reader-first), shipped as **FastDoc**. Markdown is where it
started; it also reads **Word `.docx`/`.docm`/`.dotx`/`.dotm`, OpenDocument `.odt`, and Korean HWP `.hwp`/`.hwpx`** (read-only) —
text, tables with merged cells and cell-level images/lists, images, links (including internal
bookmarks/cross-references), footnotes, headings resolved through all three ways Word and ODT can
declare one, clause/list numbering with overrides, equations rendered through the app's own formula
engine, charts and SmartArt diagrams (via Word's legacy-picture fallback, or an honest placeholder
when none exists), right-to-left text, review comments (shown in a right panel, hidden by default),
and presentation resolved from the document's OWN style cascade — paragraph spacing, indent,
line-height and alignment; run/theme colour, highlight, font, size, caps/small-caps and underline
style; tab stops and their alignment; paragraph shading and borders; table columns that fill the
width by the document's own grid proportions, plus cell shading, PER-EDGE borders (an edge the
document silenced is told apart from one it never mentioned, invariant 47), vertical alignment and
margins, and named table styles' banded rows and shaded headers — every absolute value sized to the
document's own default so the reader's zoom multiplies on top of it, not a hardcoded app rhythm.
Pictures are the deliberate exception: a graphic is scaled by the reading column over the DOCUMENT's
own page width and honours its paragraph's left/centre/right alignment, so ⌘+/⌘− resizes text alone
while a picture tracks the window (invariant 46). Floating/anchored image text-wrap was built,
measured, and deliberately not shipped (invariant 31). Plain text (.txt/.csv/.log…) opens verbatim.
`.rtf` was deliberately dropped (`35c9485`): AppKit's RTF reader loses tables, lists and embedded
images, so supporting it honestly meant writing a second parser the size of the Word one.
Korea's dominant **HWP** format (`.hwp` = HWP 5.x binary/OLE, `.hwpx` = OWPML XML) is parsed by
**rhwp** (Rust, MIT — github.com/edwardkim/rhwp, a fork we maintain adding a structured-export FFI
and an equation→LaTeX emitter), shipped as a prebuilt **static-library xcframework**
(`Vendor/RhwpNative.xcframework`, arm64) statically linked into the app; rhwp's JSON is mapped to the
SAME `OfficeBlock` vocabulary by `HwpReader.swift`, so the identical `OfficeTextBuilder` renders HWP —
tables, images, styles, hyperlinks, footnotes drawn at the foot of the page that CITES them (with the
document's own rule above them and the characters it prints around each marker), form controls
(checkbox, radio, button, combo, field) shown as read-only text so a form document is legible rather
than blank, equations, and headings taken from the paragraph's STYLE NAME, which is how a Korean file
declares one (invariant 33) — and `--extract` works for it too, marker placement included. Multi-column
sections FLOW: the text is built at the column's width so tables and images fit it, and each line is
placed from a character-keyed map because the typesetter throws away a moved line's `x` (invariant 100).
Writing is deliberate and narrow: right-click a block → Edit / Add Below / Move / Delete, held in
memory until ⌘S.
Two headless flags let a tool use the reader without a window: `--pdf` prints a document to a PDF file
through the SAME print path ⌘P uses (invariant 66), and `--extract` runs the SAME office reader without any
GUI and prints the document as Markdown to stdout — for feeding a `.docx`/`.odt` to an AI without it
spending tokens on the zip/XML (invariant 40).
The Finder's own space-bar preview is this engine too: `Contents/PlugIns/QuickLookPreview.appex`
carries a COPY of the app's executable and `main.swift` routes it to `NSExtensionMain`, so the
preview is the reader rather than a second, simpler rendering of the same file (invariant 68).
Native Swift/AppKit + TextKit host, SwiftPM executable. No web runtime for text. WebKit renders only two
things — mermaid diagrams and TeX/KaTeX formulas — and only on a cache miss; both cache to vector PDF.
Code highlighting is native (34 languages, single-pass scanner), no JS.

## Architecture authority — all-format Rust migration

This tracked authority supersedes earlier statements that macOS/Swift owns the document engine.

- **Rust owns document semantics for every supported type:** byte decoding, format parsing,
  normalization into the semantic `RenderTree`, and all platform-neutral measurement and layout.
- **Swift/AppKit/TextKit owns the host:** windows, input, accessibility, printing, Quick Look, OS font
  discovery/substitution, WebKit-backed Mermaid/KaTeX rasterization, and final AppKit painting. A host
  exception may supply platform facts or draw a Rust-decided box; it must not reinterpret document
  structure or make platform-neutral layout decisions.
- The current schema-v4 JSON/FFI path that decodes `OfficeReadResult` is a **transitional bridge**, not
  the target contract. The canonical engine/host boundary is `RenderTree`; compatibility work on the
  bridge must move toward that boundary rather than make `OfficeReadResult` permanent.
- Existing hard-won invariants remain binding during the transfer. Move an ownership slice only with
  parity tests and relevant corpus/performance evidence. Roll it back only for a recorded regression
  that fails that evidence gate; keep the rollback scoped and preserve the evidence needed to resume.

## Build / test / run

- **Build app**: `./Scripts/make-app.sh [debug|release]` → `FastDocReader.app` in repo root (ad-hoc signed).
- **Toolchain (MUST)**: standalone Command Line Tools has a mismatched SwiftPM ManifestAPI → `swift build` breaks. Always use Xcode's toolchain. `make-app.sh` auto-sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if unset.
- **Tests**: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (1803 tests, keep green; 65 skip by default). Every skip is a probe that needs a real document this repo does not ship, named by an environment variable: two markdown edit-latency measurements (`FMD_LATENCY_FILE`); the whole-reader cost probe (`FMD_PERF_FILE`, plus `FMD_PERF_WIDTH`/`FMD_PERF_HEIGHT`) which walks ONE real document through every stage a reader pays in order — parse, first paint, time-to-interactive, full layout, zoom, width change, jump to the end, read all the way down — and samples the process's own memory at four points, so a change that improves one stage while ruining another is visible in a single run (invariant 65's numbers came from it); office ones (`FMD_OFFICE_LATENCY_FILE` for the ⌘+ cost breakdown, `FMD_HWP_STYLE_PROBE` for a real HWP's paragraph-style frequencies, `FMD_TABLE_PROBE` for one table's geometry, `FMD_SPAN_PROBE` and `FMD_SUBST_PROBE` for the attribute-run counts invariants 51/52 are judged by, `FMD_DOCX_FONT_PROBE` for a docx's resolved-family histogram, `FMD_GIANT_TABLE_LATENCY` for the paired first-paint measurement invariant 55 is judged by); HWP real-sample checks (`FMD_HWP_SAMPLE` for parse/default body size/page width/equation, `FMD_HWP_IMAGE_SAMPLE` for pre-decoded images, `FMD_HWP_SPAN_DUMP`/`FMD_HWP_SPAN_DUMP_OUT` for the before/after dump that proved the rhwp rebuild changed nothing, `FMD_HWP_SLOT_SURVEY` for how often a corpus varies its seven font slots, and the four corpus probes that decided which HWP declarations are worth honouring — `FMD_HWP_BREAK_PROBE` for what documents say about line breaking, `FMD_HWP_FONT_AVAILABILITY` for whether their fonts exist on this machine, `FMD_HWP_TABLE_POLICY` for what a table permits at a page boundary, and `FMD_HWP_CHAR_DECOR` for which of a char shape's sixteen decorations anyone uses, invariants 94-97); the re-runnable corpus probes (`FMD_CORPUS_DIR`, and `FMD_RENDER_CORPUS=<colon-separated dirs>` which drives every real document under those directories through the real render path as a crash gate — **pass `FMD_RENDER_CORPUS_OUT=<path>` too**, because the verdict and the numbers travel different channels and a long run's summary is lost to stdout interleaving between xctest and the swift-testing runner, which reads exactly like a trap; current run 2,029 documents, 0 read failures, 18,776 tables, no crash, invariant 113); the paged-fidelity probes added while matching Word page by page (`FMD_PAGED_PROBE` for the row-pitch/line-box decomposition, `FMD_TABLE_MATCH` for a table's geometry against its source, `FMD_HWP_LINESPACING_SURVEY` for a corpus's line-spacing modes, `FMD_HWP_EXPECT_PT`/`FMD_HWP_EXPECT_WIDTH_PT` for a real HWP's declared page numbers, `FMD_HEADER_FOOTER_PROBE` for a real docx/odt/hwp's running header — the only check that a NON-docx header both reserves its band and builds to real glyphs, AND that ⌘P on that same file produces a PDF with the page count the reader reports, which no reader unit test can see, invariants 29/62); the probes that decided how far to take front-first first paint (`FMD_FIRSTPAINT_FILE` also drives `ProgressiveTurnProbeTests`, which reports the worst main-thread turn AFTER the window is up and the time to a fully laid-out document — the two numbers invariant 101's tail is judged by; `FMD_PROGRESSIVE_PRINT_FILE`, which prints ONE real markdown file three times and compares the second render against the third — see invariant 102 for why the ordinal matters; and `FMD_OFFICE_TEXT_SIZE_CORPUS`, the office text-size census that decided NOT to extend it to docx/hwp/odt — 15 of 2,812 documents reach the 300,000-character threshold, median 779); the artwork-blit decomposition (`FMD_ARTWORK_BLIT_PROBE`, which times the same 바탕쪽 picture through eight draw paths and is where invariant 121's table comes from); and the floating-image-wrap layout-cost spike (`FMD_FLOAT_PERF=1` — see invariant 31, that feature was measured and deliberately not shipped, and the spike stays as a test so the finding never has to be re-derived).
- **The engine gate (this branch only)**: the engine is what every build links (S9 — there is no flag and no second configuration), so its gate is the app's gate. `cd rust && cargo test`, then `./Scripts/build-engine.sh`, then `swift test` — all three green, **and neither run takes a narrowing flag**: no `--skip`, and no `-p <crate>`. A `-p fastdoc-engine` run is 278 tests against the workspace's 302, and the 24 it drops are `fastdoc-ffi`'s — the ones that drive the real exported symbols. One of them had been failing for five commits before anything ran it (invariant 111). `Vendor/FastdocEngine.xcframework` is NOT committed; `make-app.sh` builds it when absent, and `swift test` needs it to exist first. `OfficeDocumentTests` was excused from the engine run for several sprints as "a pre-existing crash, unrelated"; it was neither — it crashed only on the engine path, and it was hiding six engine defects a reader shows (dead internal links, dropped comments, body text at the wrong size). A class excused from the gate is a class nobody reads. The real-corpus census that judges how many documents the canonical tree accepts is `FMD_OFFICE_TREE_CENSUS=1 cargo test -p fastdoc-ffi --test office_corpus_census -- --nocapture`; measure through that FFI symbol, never through a direct `from_office` call with an empty resource map — the two are different measurements, not different sizes of one. **Every corpus census walks all 669 documents now, and a cap must be asked for** (`FMD_OFFICE_TREE_CENSUS_LIMIT`, `FMD_OFFICE_PROJECT_CENSUS_LIMIT`, `FMD_UNSUPPORTED_GRAPHIC_CENSUS_LIMIT`, `FMD_SECTION_FIELD_CENSUS_LIMIT`) and prints what it dropped: four of them silently stopped at 400, and `office_project_corpus_census` reported "fell back: 0" while every document that actually falls back sorted past the cut (invariant 111's family). How a document's exported bytes split between its pictures and the vocabulary describing them is `FMD_OFFICE_PAYLOAD_CENSUS=1 cargo test -p fastdoc-ffi --test office_payload_size_census -- --nocapture`; take the picture total from the TREE, never from schema-v4's `images` map, which a table's picture fill and a master page's artwork both bypass (invariant 112). See INVARIANTS.md 103-112.
- **The suite is FLAKY UNDER LOAD, and it is not your change.** Verified by running the same commit twice: at a green commit under load ~50 the suite reported 0, 1 and 3 failures on successive runs. The offenders are always wall-clock or async-timeout tests untouched by whatever you are doing — `SpliceRenderTests.testLongDocumentEditStaysFast` (a 250 ms budget), `OfficeImageLoadingTests` placeholder cases (a 2 s `XCTestExpectation`), `WindowResizeGateTests`, `LargeDocumentTests`, `PerDocumentFontSizeTests`, and `PageViewOptionsTests.testTheReadingPositionSurvivesAToggleFromDeepInTheDocument` (seen once at load 12→25 reporting the reader at character 0; passed on the next four full runs and in isolation — it waits on an asynchronous layout walk, so a machine that starves that walk reads as a lost reading position). A SECOND family joins them, found on 2026-08-29: the two cache-ceiling suites — `ImageCacheCeilingTests` and `MasterPageArtworkCacheTests` — assert that a picture just put into an `NSCache` is STILL IN IT, and `NSCache` evicts on memory pressure whenever it likes. Under load they reported 3 failures in a full run and were green in isolation, together, and in two further full runs at load ~3. Neither is a clock test, so `uptime` alone does not explain them; what they share is that a full run has already opened a thousand documents. Before believing a failure, check `uptime` and re-run the named test in isolation; a quiet machine finishes the suite in ~14 s and a busy one in 40–55 s.
- **Run a dev build from the REPO** — `open ./FastDocReader.app`, and to open a DOCUMENT in it, `open -a "$(pwd)/FastDocReader.app" <file>`. **The `-a` is not optional.** `open ./FastDocReader.app <file>` reads as two independent arguments: it launches the dev bundle AND hands the document to whatever app is REGISTERED for that type — which, on a machine that also has the shipped build installed, is `/Applications/FastDocReader.app`. Both processes then appear in `pgrep` a second apart, the document opens in the RELEASE, and a change you are trying to eyeball is simply not in the window you are looking at. Two identically-named apps make that invisible; check `ps -o command` for which bundle owns the window before trusting a visual verification. Do NOT copy the dev build to `/Applications`: that folder holds properly signed builds only (owner's rule). A dev build there is ad-hoc signed, and macOS ties per-app state to the signature, so every rebuild reads as a different app — which is exactly why Open Recent kept emptying (see invariant 21). `/Applications` gets a build from `notarize.sh` or the App Store, nothing else.
- **Quit cleanly, never `pkill`**: `osascript -e 'tell application "FastDocReader" to quit'`. Force-kill loses recent-docs persistence and can leave state inconsistent.
- **⌘R (Reload)** reloads the *document* content only — it does NOT pick up a new app build. A code change needs rebuild + relaunch.

## Layout / files

Short map only. **What each file DECIDES, and why, is `ARCHITECTURE.md`** — read a file's entry
there before changing its behaviour.

- `App/AppDelegate.swift` — menu bar, built in code (no MainMenu.nib). Any shortcut or menu item is added HERE.
- `App/MarkdownDocument.swift` — `NSDocument`: render pipeline, presize + prerender, lazy media reconcile, page band.
- `App/DocumentWindowController.swift` — text view, scroll, tabs, find, sidebar split, and EVERY reflow path.
- `App/ExternalEditor.swift` — "Edit in <App>" for read-only office documents (resolved by bundle id).
- `App/OutlinePanel.swift` / `App/CommentPanel.swift` — the left outline sidebar and the right comments inspector.
- `App/PageViewOptions.swift` — the View menu's page toggles + the global preference behind them.
- `App/MarginNumbers.swift` / `PageNumberDeskView.swift` / `JumpIndicatorView.swift` — line/page numbers and the jump overlay.
- `App/ReaderScrollView.swift` — the pinch gesture. `App/DocumentTypes.swift` — the single list of openable extensions.
- `App/DefaultAppClaim.swift` — becoming the Finder's handler: the four claimable FAMILIES, the read-back check, and the shared tick list. Opened ≠ claimed, deliberately (each claim costs a macOS confirmation dialog).
- `App/WelcomeWindow.swift` — the first-run guide, two steps in order (what it is → default app). The "don't show again" tick lives on step 2, so leaving at step 1 does not count as seen.
- `App/TextEncodingDetector.swift` — what a file's bytes actually are, and the bytes to write back.
- `App/HeadlessExtract.swift` / `App/HeadlessPDF.swift` / `App/main.swift` — the `--extract` and `--pdf` CLIs and their gating.
- `Navigation/` — `ReaderTextView` (key handling, gutter select, reading-line band), `TextNavigator` (pure boundary math), `AnchorResolver` (internal links).
- `Render/MarkdownRenderer.swift` · `PlainTextRenderer.swift` · `CodeHighlighter.swift` — the three text renderers.
- `Render/WebBlock.swift` / `WebBlockRenderer.swift` — the ONE place that knows there are two WebKit engines (mermaid, math).
- `Render/RenderTheme.swift` — the base design system; `MarkdownStyle`/`OfficeStyle`/`PlainTextStyle` are thin branches.
- `Render/TableBlockBuilder.swift` — row/cell vocabulary → a real `NSTextTable`, for BOTH renderers. `SizedAttachmentCell.swift` — the cell that owns its reserved size.
- `Render/Office/OfficeBlock.swift` — the format-neutral vocabulary all three office readers map into.
- `Render/Office/OfficeTextBuilder.swift` — the ONE builder turning that vocabulary into typography.
- `Render/Office/HwpReader.swift` + `Vendor/RhwpNative.xcframework` + `vendor-patches/rhwp/` — the HWP path. **Read `vendor-patches/rhwp/README` before touching the parser.**
- `Render/Office/OfficeMarkdownSerializer.swift` — the `--extract` serializer (pure, view-free).
- `Render/Office/PageBandGeometry.swift` / `PageBandLayoutDelegate.swift` / `PageBandPainter.swift` — the running header/footer in its three halves.
- `Render/Office/PagePagination.swift` — where each SHEET is: the same rectangles for screen and paper.
- `Render/Office/MasterPagePainter.swift` — the 바탕쪽: the title, tab, artwork and PAGE NUMBER a Korean document pins to the sheet itself (invariant 78).
- `QuickLook/QuickLookPreviewController.swift` — the Finder's space-bar preview, through the same door `--pdf` uses.
- `Cache/MermaidCache.swift` — content-addressed disk cache for both web engines.
- `Resources/` — `mermaid.min.js`, `katex.min.js`, `katex-inlined.min.css` (regenerate with `Scripts/build-katex-css.sh`), `Info.plist`. `Scripts/make-app.sh` — build + bundle + ad-hoc sign.

## Hard-won invariants — MUST Read before touching an area

`INVARIANTS.md` (repo root) is this app's manual: 132 numbered entries, each the measurements
behind one rule plus the designs that were built, measured and REJECTED. It is not background
reading — **find your area below and read those entries BEFORE you change anything there.**

The rule this table exists to enforce: **nothing here is re-derivable by reasoning.** Every entry
records something that was already tried. Changing one of these areas without reading its entries
means re-proposing a rejected design or re-earning a defect that already shipped.

| if you touch | read INVARIANTS.md |
|---|---|
| image / diagram / formula sizing, attachments, placeholders | 1, 2, 3, 10, 11, 31, 54, 75, 80, 115, 121 |
| the mermaid + KaTeX web-block cache | 4, 5, 13 |
| `Info.plist`, document types, default handler, sandbox, entitlements | 6, 8, 9, 22, 28, 43, 69, 70 |
| menus, Open Recent, titlebar accessory, sidebar, outline panel | 7, 21, 23, 26, 27 |
| markdown parsing or a new markdown feature | 12, 41, 101, 122, 123, 128, 130, 131 |
| keyboard navigation, reading cursor, margin numbers, jump | 14, 15, 71 |
| editing, save, text encoding, splice render | 16, 17, 18, 19, 20 |
| reflow, resize, `precomputeLayout`, first-paint cost | 24, 25, 32, 48, 49, 55, 56, 113, 117 |
| scroll cost, what a draw pass does per frame, page furniture | 113, 117, 118 |
| `PageViewOptions`, any UserDefaults-backed preference, from a test | 119, 125 |
| office readers (docx / odt / hwp), dispatch, rhwp, headings | 29, 33, 44, 45, 73, 75, 78, 79, 81, 94, 110, 112, 115 |
| tests, corpus probes, "is this check actually reached" | 5, 29, 30, 34, 35, 41, 103, 104, 106, 109, 110, 111, 112, 113, 114, 116, 119, 122, 124 |
| `RenderTheme` tokens, `OfficeTextBuilder`, style resolution | 36, 37, 97, 107 |
| tables — build, widths, borders, merges, attribute cost | 39, 42, 47, 50, 51, 72, 74, 76, 129 |
| fonts, per-script slots, substitution | 52, 53, 93, 95 |
| `swiftshim` strings, UTF-16 offsets, `SwiftString`, attributed-string length | 122, 123 |
| the engine's measurement port (`RustEngineMeasure`), terminator attributes | 51, 105 |
| the comments panel | 38 |
| paged documents — zoom, page band, header/footer, page outline | 46, 57, 58, 60, 62, 77, 78, 118, 121 |
| footnotes — the band fixpoint, where a note lands, the settle's round budget | 98, 99 |
| printing, `--pdf`, `--extract`, anything headless | 40, 59, 66, 70, 102, 116, 120, 125, 126, 127, 132 |
| a table that crosses a page boundary | 61, 64, 72, 96 |
| multi-column layout, `ColumnGeometry`, column flow | 100, 108 |
| memory, image caches, document lifetime, crashes | 63, 65 |
| the Quick Look preview extension | 68 |
| any Swift value carried as a text attribute | 67 |

## Debugging discipline (this app specifically)

- **Synthetic scroll is blocked by accessibility** — CGEvent scroll doesn't reach the window. You cannot drive scrolling programmatically; **the user reproduces, you read logs.** Log total height / frame height / scrollY per reconcile and read them.
- Temporary instrumentation goes to `/tmp/fmd-*.log`. **Remove all of it (delete `DebugLog.swift`, strip log calls) before committing** and clean `/tmp/fmd-*`.
- Verify visual/pixel behavior with a screenshot only when the judgment is truly visual; deterministic size assertions are proven by the logs/code, not screenshots.
- **Capture ONE window by its id, not the screen.** A full-screen `screencapture` races the terminal for focus and keeps returning a picture of the terminal — activating the app and sleeping first is unreliable, because whatever is producing output raises itself again. Ask Quartz for the window number and grab that window alone, which needs no focus at all and yields a tight, cheap image:
  `python3 -c "import Quartz; [print(w['kCGWindowNumber']) for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) if '<title>' in (w.get('kCGWindowName') or '')]"` then `screencapture -x -o -l <id> out.png`.
- **Driving the UI: `click button "X" of window 1` via System Events works; `keystroke` does not.** A synthesized keystroke goes to whatever is frontmost and was swallowed by the terminal every time, while an accessibility click reaches the named button whether or not the app has focus. (Scrolling is still not drivable at all — that is the CGEvent limit above.)

## Commit / distribution

- **Solo local app → commit directly to `main`** (established pattern: `a80271e`, `57b485b`, `bce0ead`). No dev branch. Stage by filename (exclude `.bkit/`).
- **`docs/` is gitignored — local only, NOT on GitHub** (this repo is public and the AI collaboration logs quote internal discussion verbatim; GitHub can't keep a folder private inside a public repo). The distribution playbooks (`docs/NOTARIZATION.md`, `docs/APP-STORE.md`, `docs/APP-STORE-METADATA.md`) live there too, so they exist on this machine only — **don't link to them from README** (public readers would hit a dead path), and don't assume a fresh clone has them. (The `.gitignore` line is now `docs/`, not just `docs/commit-log/` — for a while only commit-log was ignored and the rest was merely untracked, one `git add .` from being public.)
- **`demo/` and `licenses/` ARE public** (committed): `demo/` = the four sample docs shipped for users (code-blocks, math, images, moby-dick — Moby-Dick is public-domain, PG boilerplate stripped; demo photos are PD/CC0, credited in `demo/assets/CREDITS.md`). `licenses/` = the OFL text the fonts require.
- **Two distribution tracks, both arm64-only, both from this SwiftPM build — no Xcode project:**
  - **Direct (`./Scripts/notarize.sh`)** — Developer ID + hardened runtime + Apple notarization → stapled `FastDocReader.zip`. **Unsandboxed.** Recipients double-click; no quarantine step. Run it only when shipping a build to someone, not per build. → `docs/NOTARIZATION.md` (local)
  - **Mac App Store (`./Scripts/appstore.sh`)** — Apple Distribution + embedded profile → signed `.pkg` → `altool`. **Sandboxed** (the store's price). Defaults to validate-only; `--upload` submits. The store notarizes during review, so this track never calls notarytool. → `docs/APP-STORE.md` (local)
- **The bundle is no longer a single binary** — `Contents/PlugIns/QuickLookPreview.appex` is separate code with its own identity, so both distribution scripts sign **inside-out** (extension first, app second; `--deep` is deprecated for distribution). The store needs more than a signature: an extension is its own app for provisioning, so `ai.ww-w.fast-md-reader.quicklook` has its OWN App ID and Mac App Store profile (`Fast_Doc_Reader_QuickLook_MAS.provisionprofile`, named by `QUICKLOOK_PROVISION_PROFILE` in `signing.env`), embedded in the `.appex`. `appstore.sh` refuses to submit without it rather than being rejected at ingest hours later; `SKIP_QUICKLOOK=1` ships a build without the preview (and the store copy must then not claim it). **Two Info.plist keys are store-only** and pass Developer ID and notarization untouched: `CFBundleExecutable` must equal the bundle directory's name (90362) and an extension must carry `CFBundleDisplayName` (90360) — `docs/APP-STORE.md`.
- **The builds differ ONLY in the sandbox, deliberately** (invariant 9) — don't "unify" them.
- **Signing identity / key ids are NOT in the repo** — scripts source `$KEYCHAIN_DIR/signing.env` (default `~/Documents/DEV/ww-w-ai/.keychains/`, chmod 600) and fail loudly naming the missing variable. Never re-add them as script defaults.
- `make-app.sh` alone is ad-hoc signed — runs on the building machine only. Never ship that bundle. It matches the direct build (unsandboxed); `SANDBOX=1 ./Scripts/make-app.sh` builds the sandboxed shape to exercise the folder grant.
- **A build carrying the App Store entitlements won't launch locally** (RBS error 163, "Launchd job spawn failed") — those identifiers require store installation. Hence `Resources/FastDocReader.entitlements` = same sandbox, no store identifiers, local testing only.
- Intel support needs a universal build (`swift build --arch arm64 --arch x86_64`) before packaging.
