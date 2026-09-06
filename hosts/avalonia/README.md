# FastDoc.Avalonia — the Windows / Linux host

## What it is

A .NET 9 + Avalonia reader that links the SAME Rust engine the macOS app links
(`libfastdoc_engine_ffi.{dylib,so,dll}`) through P/Invoke, receives the engine's `RenderTree`
(`EnvelopeV1`, `schema_version` 1 — the one office contract, INVARIANTS.md 172), and lays it out
and paints it itself with Avalonia `TextLayout`. The tree carries document structure and no
bounding boxes, so layout is the host's job on this platform the way it is TextKit's on macOS —
ADR 0002, a transitional split that ends when the
engine emits boxes. The engine owns parsing, normalisation, band sides, sheet geometry and table
placement; this host owns windows, input, fonts, the pixel-level layout and drawing.

Reads everything the macOS app reads: Markdown and plain text (`fastdoc_read_text_tree`), and
docx/docm/dotx/dotm/odt/hwp/hwpx (`fastdoc_office_open` → `fastdoc_office_tree_json` →
`fastdoc_office_close`). Read-only; no editing.

## Build and run

```bash
export FASTDOC_ENGINE_LIB=/absolute/path/to/libfastdoc_engine_ffi.dylib   # or .so / .dll
dotnet build hosts/avalonia/FastDoc.Avalonia/FastDoc.Avalonia.csproj -c Release
dotnet hosts/avalonia/FastDoc.Avalonia/bin/Release/net9.0/FastDoc.Avalonia.dll            # GUI, empty window
dotnet hosts/avalonia/FastDoc.Avalonia/bin/Release/net9.0/FastDoc.Avalonia.dll <document>  # GUI, document opened
```

Build the engine library first: `Scripts/build-engine.sh` for macOS, `Scripts/build-engine-xplat.sh`
for win-x64 / win-arm64 / linux-x64 / linux-arm64 (stripped `--strip-all`, into `rust/dist/xplat/`).
The win-arm64 target (`aarch64-pc-windows-gnullvm`) needs llvm-mingw at `$LLVM_MINGW_DIR` (default
`~/.local/opt/llvm-mingw`) — the GNU mingw-w64 toolchain has no aarch64 port — and the script skips
that target with a message when the toolchain is absent. Its clang is handed to cargo as linker, `CC`
and `AR` (blake3 compiles C through the `cc` crate), and the unwinder is linked statically from a
search directory holding only `libunwind.a`; the script fails the build if the finished DLL still
imports `libunwind.dll` (INVARIANTS.md 206). Stripped engine DLLs: x64 30.4 MB, ARM64 10.1 MB.

**Engine library lookup** (`Native/FastdocEngine.cs`): `FASTDOC_ENGINE_LIB` if set; otherwise
`runtimes/<rid>/native/<libname>` next to the managed assembly (`AppContext.BaseDirectory`), which
is where `dotnet publish` and `Scripts/publish-host.sh` put it; otherwise a loud failure naming
every path tried. The fallback is proven: a self-contained linux-x64 publish opened a document in a
container with the variable unset (893 ms, `moby-dick.md`).

### Entry convention

No arguments, or a single bare document path, is the GUI — the bare path is the file-association /
double-click case and is opened in the main window. Headless is only ever an explicit flag. Every
branch prints one `mode:` line to stderr before it does anything, so a gate can tell which door was
taken without a display.

| Invocation | stderr | stdout |
|---|---|---|
| `--noop` | `mode: headless --noop` | — (boots the runtime and exits; the timing baseline) |
| `--extract <doc>` | `mode: headless --extract`, `opened: N nodes, M ms` | the document as Markdown (office docs go through `MarkdownSerializer`; markdown/plain text is printed verbatim) |
| `--sheets <doc>` | `mode: headless --sheets` | `sheets: N` + one line of page geometry |
| `--paint-probe <doc>` | `mode: headless --paint-probe` | first-frame paint and five scroll stops (0/25/50/75/100%), ms |
| `--pdf <in> <out>` | `mode: headless --pdf` | `pages: N` |
| (none / `<doc>`) | `mode: gui` | — |

**Exit codes** (every door above, plus the GUI entry):

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | document error (unreadable, corrupt, unsupported extension, missing file, no permission) or usage error (an unrecognized `--flag`) |
| `2` | environment error — the engine library could not be found. The GUI entry shows a small window naming the paths it tried; a headless door prints one `engine library not found: ...` line to stderr and exits with no window and no stack trace |

A headless door's own exception (a bad path, a directory instead of a file, no read permission)
prints ONE line naming the case in plain words — never a raw .NET exception with this machine's
absolute paths and internal call chain. Set `FMD_AVALONIA_DEBUG=1` to get the full exception
(`ex.ToString()`, stack trace included) appended after that line, for a developer who asked for it.

- `FMD_AVALONIA_REPEAT=N` — `--extract` and `--paint-probe` reopen the same document N times in
  one process and report each; use the median of repetitions two onward (the first pays the dylib
  load and JIT warm-up, INVARIANTS.md 173).
- `FMD_AVALONIA_GUI_EXIT_IMMEDIATELY=1` — the GUI shuts itself down about 500 ms after start, so
  the no-args path can be asserted by a gate instead of hung on.
- `FMD_AVALONIA_PDF_TRACE=1` — `--pdf` prints one line per downsampled picture to stderr
  (`pdftrace: page=N downsample WxH -> W'xH'`), N being the 1-based page `RenderCore` was drawing at
  that moment, and matches the PDF page the resulting image XObject actually lands on (verified
  with `pdfimages -list` against a 186-page hwpx export).
- `FASTDOC_DRAW_LOG=<path>` — flow-mode `FlowDocumentView.RenderCore` appends one diagnostic frame
  per real paint to this file: a header line (frame number, scroll offset, viewport cull bounds,
  viewport height, document total height) plus one `BLOCK` line per top-level block (index, node
  id, kind, y, height, and `verdict=drawn|culled-above|culled-below`), and for a drawn table block,
  one indented line per cell it actually built content for (row/column, whether it has a
  `TextLayout`, its height) — written for a bug this repo's own headless replay could not
  reproduce (S9-C/S9-V), so a real machine can record
  its own scroll/cull decisions instead. Unset (the default): a single field read per frame, no
  file, no lock. Set: appends, thread-safe.

**Single instance** (GUI entry only — the headless flags above never touch this): a named `Mutex`
decides which process is primary. Its name carries the `Global\` prefix plus the user name: without
the prefix .NET scopes the name to the launching process's session on Linux, and every desktop
launch is its own session, so two double-clicks made two windows (INVARIANTS 186). A losing launch forwards its document path over a named pipe to
the primary and exits with no window of its own; the primary's pipe server marshals that path onto
the UI thread and calls the SAME `MainWindow.LoadPath` a normal open uses, then brings the window
forward (restoring it first if minimized). No path (a bare second launch) just activates the
window. A losing launch that cannot reach a primary within 2s (e.g. it is mid-shutdown) falls
through and opens its own window rather than exiting with nothing visible.

`FMD_AVALONIA_PIPE_PROBE` proves the pipe transport headlessly, with no GUI on either side —
useful because an automation session cannot open a real window at all (see the gate step 4 note
below). `=1` is the server role (listens for one message, prints `received-path: <path>` to
stderr, exits); `=client` plus a path argument is the client role (sends that path, prints
`sent-path: <path>` to stdout, exits). Both share the exact
`NamedPipeServerStream`/`NamedPipeClientStream` code the real forwarding path uses.

## Gate

`Scripts/host-gate.sh` — absolute paths, runs from any directory, prints `HOST GATE: PASS` or fails
loudly. Six steps in order:

1. Managed build (Release).
2. Managed unit tests (Release) — `FastDoc.Avalonia.Tests`, xunit, 34 tests.
3. Headless `--extract` smoke against the real engine library, one document per family
   (markdown, docx, hwpx); requires non-empty Markdown on stdout and `opened: N nodes` plus the
   `mode:` line on stderr.
4. No-args GUI-entry smoke (`FMD_AVALONIA_GUI_EXIT_IMMEDIATELY=1`); requires `mode: gui`. An
   abnormal exit AFTER that line is a WARN, not a FAIL, because an automation session on macOS
   cannot connect to WindowServer (exit 134). It becomes a hard FAIL once a run from a logged-in
   terminal has exited 0 (INVARIANTS.md 178).
5. Linux Docker smoke — the self-contained linux-x64 publish, mounted read-only into
   `mcr.microsoft.com/dotnet/runtime-deps:9.0` (no X11, no fontconfig), runs `--extract` on a real
   document. Skipped with a WARN only when Docker itself is unavailable (INVARIANTS.md 175).
6. Headless `--pdf` smoke on the same three documents; the reported `pages: N` must equal the
   number of `/Type /Page` objects in the file.

`Scripts/publish-host.sh` — `dotnet publish --self-contained` for win-x64, win-arm64, linux-x64 and
linux-arm64 into `hosts/avalonia/publish/<rid>/`, copying the matching engine library into
`runtimes/<rid>/native/`. After each RID it runs a verification gate — engine library present and
>= 1 MB, bundled font resource embedded in the main assembly — and exits 1 loudly (never a silent
pass) if either check fails; `--verify-only <rid>` re-runs just that gate against an existing
publish output. Sizes: win-x64 239.4 MB (engine 30.4 MB), win-arm64 228.0 MB (engine 10.1 MB),
linux-x64 118.9 MB (engine 13.2 MB), linux-arm64 122.4 MB (engine 11.3 MB).

`Scripts/package-host.sh` — packages each `publish-host.sh` output plus its installer scripts,
`THIRD-PARTY-NOTICES.md` and `RELEASE-NOTES.md` into a distributable archive (`.zip` for the two
Windows RIDs, `.tar.gz` for the two Linux RIDs) under `hosts/avalonia/dist/`, with a `SHA256SUMS`
file covering all four; the macOS zip from `Scripts/notarize.sh` is dropped in afterwards and the
checksum file extended by hand. Archive sizes: win-x64 89.7 MB, win-arm64 79.2 MB, linux-x64
53.1 MB, linux-arm64 50.6 MB.

## What works

- **Flow mode** (default for every format): virtualised layout — paragraph heights are estimated,
  then corrected as blocks reach the screen. First frame 8 ms median on a 19 MB HWPX, 2–8 ms on a
  27-table docx; tables draw as real cell grids (merged cells, per-edge borders, shading, column
  widths from the document's own grid) with a row-height cache so a document that is one table
  scrolls at 10–114 ms per stop instead of 250–450 (INVARIANTS.md 174). A cell's own image or
  nested table is now measured and painted as part of the cell, not silently dropped (S9-C,
  INVARIANTS.md 196), and a scrolled viewport no longer culls every row of a table that is
  actually on screen (S9-C, INVARIANTS.md 197).
- **Images**: hwp/hwpx bytes fetched on demand through `fastdoc_office_image_base64`; docx/odt
  bytes read from the source archive by `sourceKey`. Scaled by the reading column over the
  document's declared width, the macOS rule (INVARIANTS.md 46).
- **Zoom** Ctrl/Cmd `+` `−` `0` (0.5–3.0, 10% steps; text only, the reading position is kept).
- **Find** Ctrl/Cmd F: case-insensitive, all matches, Enter / Shift+Enter cycle, Esc closes;
  highlights come from the same `TextLayout` that draws the text, so they cannot drift.
- **Open**: file dialog (Ctrl/Cmd O), drag-and-drop onto the window, ten recent files.
- **Reading position** restored per document (block index + fraction + zoom, keyed by
  path|size|mtime; 100 entries in `positions.json` beside the recent-files store).
- **Page mode** (View ▸ Page Mode, Ctrl/Cmd+Shift+P; office documents only): the engine's band
  sides, sheets and table placement, line-by-line placement that never splits a line, up to eight
  table-settle rounds, multi-page tables with repeated header rows. Now measures and draws a
  table cell's own image and nested table too (S10-A, INVARIANTS.md 203), and pushes a block
  taller than one page's content height to a fresh page instead of clipping it mid-page (S10-A,
  INVARIANTS.md 204). Toggling into or out of page mode (Ctrl/Cmd+Shift+P) keeps the reading
  position by block rather than resetting to the top (S10-B, INVARIANTS.md 205). Structurally
  complete; see below for accuracy.
- **PDF export**: File ▸ Export PDF… / Ctrl+P and headless `--pdf` call the same
  `Printing/PdfExporter.ExportPdf`. Office documents paginate through page mode; markdown/text is
  cut into A4 (595×842 pt) pages. **Vector, not raster** (S5-C): every renderer
  (`FlowDocumentView`/`TableGridRenderer`/`ImageBlockRenderer`/`PageModePainter`) paints through
  `Printing/IPageCanvas` instead of a raw `DrawingContext` — the screen uses `AvaloniaPageCanvas`
  (a thin pass-through, unchanged pixels), and PDF export uses `SkiaPageCanvas`, drawing straight
  onto an `SKDocument` page's `SKCanvas` with no offscreen `Window` and no captured frame. Text is
  real glyph draws (`SKCanvas.DrawText` against the bundled Noto Sans KR TTF, loaded once as an
  owned `SKData` copy — not a live stream, which silently produced ZERO text on Linux/FreeType
  before this was fixed) sharing the
  SAME `TextLine` the screen already built, so page counts are identical to the old raster path.
  The bundled font is TTF, not the OTF S5-C shipped (S5-C2): SkiaSharp's PDF backend embeds a
  non-system CFF/OTTO-outline font as `/Type3` (per-glyph vector paths) regardless of platform —
  confirmed identically on macOS and Linux — but a `glyf`-outline TTF embeds as a real
  `/CIDFontType2`+`/FontFile2`, so the bundled OTF was converted with fontTools' `cu2qu` pen
  (glyph counts unchanged: 11,172 Hangul + 8,138 Hanja). Pictures (S5-C3): `IPageCanvas.DrawImage`
  carries the document's OWN encoded bytes and MIME type (not just the decoded `Bitmap`), so a
  JPEG source embeds AS-IS (`/DCTDecode`, no re-encode) unless it is grossly oversized for how it
  is drawn (a 4961×7015px scan printed at signature-stamp size, measured in the HWPX sample, still
  gets downsampled first); anything else is decoded, downsampled to at most 2x its drawn pixel
  size, then encoded as whichever of JPEG(85)/PNG comes out smaller (PNG usually wins for a
  screenshot's sharp edges; JPEG usually wins for a photo). One `SkiaPageCanvas` per EXPORT (not
  per page) caches the result by a hash of the source bytes, so a picture repeated across many
  pages (a background, a letterhead) is encoded once and dedups to a single PDF object. Net result
  on the HWPX sample: 16.9MB raster → 10.7MB vector (down from an intermediate 42.3MB before the
  image fix). Behind those numbers are two regressions caught along the way (a lazily-read font stream that
  silently dropped ALL text on Linux; a blanket "opaque means JPEG" rule that made PNG-sourced
  screenshots bigger, not smaller).
- **Korean text** without a system font: Noto Sans KR (SIL OFL 1.1, `Assets/Fonts/`) is bundled and
  registered as a fallback for Hangul syllables, compatibility jamo and box-drawing characters on
  every `AppBuilder` the process constructs.
- **Runs on Linux with no display and no fontconfig** — that is what gate step 5 executes.
- **Single instance**: a second launch forwards its document path to the running window and exits
  instead of opening a second one — see the Entry convention section's "Single instance" note.
- **Text selection and copy, flow mode only**: drag, double-click (word), triple-click (block),
  Ctrl/Cmd+A, Ctrl/Cmd+C, Escape. Hit-testing reuses the exact cached `TextLayout` the view already
  paints with, so selection can never disagree with what is on screen (INVARIANTS.md 191). A table
  falls inside a range selection (`SelectedText` serializes its cells tab-separated, row by row,
  recursing into a nested grid) but a drag cannot start or end INSIDE a table cell — the cell has
  its own separate layout the selection model does not see. Page mode does not support selection at
  all (INVARIANTS.md 191).
- **Find highlighting is theme-resolved**: all matches and the current match use distinct
  light/dark colors from `App.axaml` rather than a fixed color, matching the rest of the reading
  surface's light/dark handling.
- **Table of contents and comment panel entries scroll to their exact source node**, addressed by
  the RenderTree's own node id rather than a recomputed block index — including a heading that
  lives inside a one-cell table (S9-A, a common Korean report chapter-title box), which now
  scrolls to the table that contains it (INVARIANTS.md 195). Flow mode only; a page-mode document
  does not scroll from these panels.
- **Links**: an internal link resolves against document bookmarks first, then (for Markdown, which
  carries no bookmarks) against a GitHub-flavored heading slug — the first heading with a matching
  slug wins, with no de-duplication suffix. An external link opens through the OS default handler.
  A link a click cannot resolve does nothing rather than being handed to the OS as a bare
  `#fragment`. Hovering a link shows a hand cursor; a left-button drag starting on a link selects
  text instead of navigating. A right-click offers Copy (when text is selected) and Copy Link
  (when the click landed on a link). Flow mode only.
- **Code block syntax highlighting**: token colors (keyword / type / string / number / comment /
  added / removed) come from the engine's own tokenizer and are drawn using theme-resolved colors,
  matching in light and dark.
- **Markdown images**: a relative or `file:` image path resolves against the document's own
  directory and renders at its actual decoded size; a remote (`http`/`https`) image is never
  fetched and shows a placeholder instead.
- **PDF export renders tofu-free glyphs** for the control and separator characters `--pdf` used to
  print as `.notdef` boxes (INVARIANTS.md 188) — a docx's embedded XML example and the HWP manual's
  table-of-contents leader column both export clean.
- **Keyboard Shortcuts window** (S9-B2): "?" or F1, and Help ▸ Keyboard Shortcuts…, open a
  non-modal guide listing every shortcut this host actually implements, grouped File/Edit/View/
  Navigate/Find/Help; Help ▸ Welcome to FastDoc re-opens the first-run notice. Opening the guide
  twice focuses the existing window rather than duplicating it; Esc closes it.
- **Page furniture toggles** (S9-B3, View ▸ Master Page Furniture / Split Tables Across Pages,
  Ctrl+Shift+M / Ctrl+Shift+B, page mode only): turns the running header/footer band on and off,
  and chooses whether a table that would not finish on its page is broken at a row boundary or
  carried whole to the next page — both already fed to `PageLayout.BuildWithTableSettle`, now from
  live menu state instead of a hardcoded `true`.
- **Line Numbers + Go to Line…** (S9-B3, View ▸ Line Numbers Ctrl+Shift+L, View ▸ Go to Line… Ctrl+L,
  flow mode only): numbers every top-level block (paragraph/table/image/rule) in the left margin —
  NOT every wrapped visual line the way macOS's MarginNumbers does, a disclosed scope narrowing (see
  `Rendering/LineNumberModel.cs`'s own doc) since numbering each wrapped line safely would mean
  editing the shared per-line text-drawing loop this sprint's dispatch kept out of scope. Page mode
  is not covered at all.
- **Reload** (S9-B3, File ▸ Reload, Ctrl+R): re-reads the current path from disk through the same
  `LoadPath` door Open… and a recent-file click use.
- **About FastDoc** (S9-B3, Help ▸ About FastDoc): app name, the built assembly's own version
  (`AssemblyInformationalVersion`, `1.4.2+<git sha>` — the same version number as the macOS app, pinned by `VersionFieldsTests`), and the MIT licence line. Engine version is
  deliberately blank — `Native/FastdocEngine.cs` exposes no version export today.
- **Right-click Open / Select All / Copy Code** (S9-B3): the context menu gained "Open" (navigates
  the same link "Copy Link" already resolves), an always-present "Select All", and "Copy Code" when
  the click landed on a code block (copies the WHOLE block, not just the selection). Code blocks'
  other macOS chip — "Wrap" — is NOT implemented; it would mean editing `FlowDocumentView`'s shared
  `TextWrapping` construction, out of scope for the same reason as per-line numbering above.
- **Ctrl/Cmd-click on a selection opens it as a link/path** (S9-B3, `Rendering/SelectionOpenTarget.cs`):
  an absolute `http(s)`/`mailto` URI, or a path that exists on disk, opens through the OS default
  handler; the selection itself is left untouched. Ordinary prose is a no-op.
- **Left-margin gutter click copies the whole line** (S9-B3): a click landing left of the text
  column (the same band the line-number gutter draws into, whether or not Line Numbers is on)
  copies that block's plain text to the clipboard instead of starting a selection.
- **Click an image/diagram to enlarge it** (S9-B3, `Panels/ImageZoomWindow.axaml`): opens a
  non-modal window with the SAME decoded bitmap, Ctrl/Cmd `+`/`−`/`0` zoom and Esc to close.
  Drag-to-pan and a trackpad pinch gesture are NOT implemented — a `ScrollViewer` substitutes for
  pan; pinch was already out of scope for this host (see "What does not work yet" below).
- **Edit in &lt;App&gt;…** (S9-B3, File ▸ Edit in Default App…, read-only office documents only —
  docx/docm/dotx/dotm/odt/hwp/hwpx): opens the file through the OS's own default handler for that
  extension (the same `UseShellExecute` mechanism a link click already uses). The menu label names
  that app when it can be determined — Windows via the registry's ProgId → `shell\open\command`,
  Linux via `xdg-mime query default` and the resolved `.desktop` file's `Name=` line — and falls
  back to "Edit in Default App…" otherwise. Narrower than macOS's `ExternalEditor.swift`, which
  lists every candidate app; neither OS's default-handler query gives a ranked candidate list to
  show (`Open/ExternalEditorResolver.cs`'s own doc).

## What does not work yet

- **Page mode sheet counts differ from Word and from the macOS app.** Cell images and nested
  tables are measured and drawn (INVARIANTS.md 203), a block taller than a page moves to a fresh
  page (204) and the flow/page toggle keeps the reading position (205), but the count itself is
  not Word's. The remaining cause on record is the HWP line model (INVARIANTS.md 161 b/e), absent
  from `TableGridRenderer.BuildCellLayout`; a vertical-axis oracle has to exist before the next
  attempt (INVARIANTS.md 176). Flow mode stays the default until this is closed.
- **The GUI PDF export path is unverified on a real window.** File ▸ Export PDF… shares the same
  `RenderCore`/`SkiaPageCanvas` code the headless `--pdf` path (font, image encoding) was measured
  through, but has still
  not itself been exercised on a real display (no window server in the sandbox that built either
  unit).
- **Hanja coverage is the bundled font's, not the engine's.** The bundled Noto Sans KR carries
  8,138 CJK Unified ideographs plus Extension A and compatibility ideographs, so a font-less Linux
  container renders mixed Korean text; the engine's metric table still measures Hanja by the host
  font, and ideographs outside that set fall to the OS font stack.
- **Verified in virtual machines, not on bare metal.** Windows: both builds ran on Windows 11 Pro
  ARM64 (build 26200) in a VM. The x64 build under Windows' x64 emulation: `--pdf` on a 20 MB HWPX
  report 197 s, a 10 MB DOCX 24 s, a 160 KB HWP 12 s; the GUI opened the DOCX in 7.3 s (2,705
  nodes) with the welcome dialog, tables and Korean text rendered. The native ARM64 build on the
  same VM: `--pdf` HWPX 31.2 s (195 pages), DOCX 6.1 s (35), HWP 3.0 s (45) — the same page counts
  as the x64 build, 4–6× faster — and the GUI opened the HWPX report in 884 ms (12,820 nodes).
  Those counts are one page off the Linux build's on two of the three (196/35/46, same bundled
  font); word counts show no content loss and the difference is unexplained. Linux: Ubuntu 24.04
  (GNOME on Xorg and XWayland) in a VM on Apple Silicon. `installers\windows\register.ps1` has
  still not been executed on Windows. Android has not been started.
- **Header/footer text is drawn unstyled**; per-section and first-page scoping is now honored
  (INVARIANTS.md 189) but there is still no footnote band, no master page (바탕쪽) or pinned page
  number.
- **Text selection inside a table cell is not supported** — a drag that starts or ends inside a
  cell clamps to the nearest text block instead; only a range that passes over the whole table
  (e.g. Ctrl/Cmd+A) includes its text. Page mode does not support selection, links or click-to-scroll
  at all — it uses a separate page-by-page text layout the flow-mode selection/hit-test/scroll
  contract does not reach (INVARIANTS.md 191).
- **Pure prose scrolls at 65–74 ms per stop** (`moby-dick.md`) — long paragraphs are laid out the
  first time they are revealed; not yet 16 ms.

## Install

`hosts/avalonia/installers/`, applied to a published output:

- Linux — `linux/install.sh <published-dir>` / `linux/uninstall.sh`: user-local (no sudo) `.desktop`
  entry plus `ai.ww-w.fastdoc.xml` MIME types for hwp/hwpx. Install prints the `xdg-mime default`
  line; does not run it. Uninstall removes exactly what install added (app copy, `.desktop` entry,
  MIME definition) and refreshes both caches; it never touches an `xdg-mime default` a user set.
  Fresh-machine round-trip verified in a `debian:bookworm-slim` container (no desktop session).
- Windows — `windows/register.ps1 -InstallDir <published-dir>` / `unregister.ps1`: writes
  `HKCU\Software\Classes` only. Not yet executed on Windows — reviewed statically only.

Neither script makes FastDoc the default application. On Windows `UserChoice` is hash-protected
and cannot be set by an application; on Linux it is left to the user. Both scripts were written on
macOS; the Linux pair has been run on Ubuntu 24.04 in a VM, the Windows pair has not been run.

## Layout

| Directory | Owns |
|---|---|
| `Native/` | `FastdocEngine.cs` — P/Invoke bindings, byte-matched structs, engine library lookup |
| `Model/` | `RenderTreeEnvelope.cs` — the C# mirror of `EnvelopeV1` |
| `Rendering/` | flow mode: `FlowDocumentBuilder` / `FlowBlock` / `FlowDocumentView` (virtualisation, zoom, find, scroll), `TableGridRenderer` (the one row measurement), `ImageBlockRenderer`, `RenderTreeLoader` (handle lifetime) |
| `Paging/` | page mode: `TextMeasurerPort`, `PageGeometry`, `PageLayout`, `TableSettle`, `PageModePainter` |
| `Printing/` | `PdfExporter` |
| `Open/` | `OpenService`, `RecentFiles` |
| `Reading/` | `ReadingPosition` |
| `Fonts/` | `FontSetup` + `Assets/Fonts/NotoSansKR-Regular.ttf` (full KR-region subset, converted from OTF to TrueType outlines for PDF export — S5-C2 — OFL text beside it) |

`ARCHITECTURE.md` (repo root) has the per-directory decisions and the invariants they answer to.
