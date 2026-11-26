# FastDoc for Windows and Linux 1.4.6

## What's new in 1.4.6

- Real installers. On Windows, run `FastDoc-1.4.6-win-x64-setup.exe` (or `-win-arm64-setup.exe`):
  it installs for the current user without administrator rights, adds FastDoc to the Start menu
  and to **Open with** for every file type it reads, and removes itself cleanly from **Settings →
  Apps → Installed apps**. On Debian and Ubuntu, install `fastdoc_1.4.6_amd64.deb` (or `_arm64.deb`)
  with `apt`; it adds a `fastdoc` command, a launcher entry, the HWP and HWPX file types and an icon.
- The program is now called `FastDoc.exe` on Windows and `fastdoc` on Linux.
- A vertical scrollbar now sits beside the document and stays visible; drag it, click the track or use the arrows, and it follows wheel, keyboard, find, zoom and page-view changes. Earlier builds scrolled by wheel and keys only, with no scrollbar shown.

## What's new in 1.4.5

- Word, OpenDocument and Hangul documents are laid out into pages by the same engine as the macOS
  app, and most documents now have the same page count as on macOS.
- Korean text wraps at word boundaries, Hangul character width (장평) is applied per glyph, and
  table rows, cells, nested tables and list markers are measured the way macOS measures them.

## What's new in 1.4.4

- Markdown renders strikethrough, tables and code inside list items, Korean italics, footnotes,
  alert boxes, highlights, superscript, definition lists and inline HTML formatting.
- Office documents draw anchored objects, master pages, tab leaders, paragraph borders and shading,
  and footnotes at the foot of the page.

## What's new in 1.4.3

- Open plain-text files with custom extensions or no extension from the file picker, by dropping
  them onto the window, or through their file association.
- Markdown conversion preserves document headers, footers, anchored text and comments.
- Headless text extraction consistently decodes legacy CP949 and UTF-16 files.
- Files too large to open as plain text report an error without partial output.

## What it is

FastDoc for Windows and Linux is a read-only document viewer built on the same Rust engine as the
macOS app. It opens 9 file families: `.md`, `.txt` (and the plain-text family the macOS app
registers, 70 extensions in total), `.docx`, `.docm`, `.dotx`, `.dotm`, `.odt`, `.hwp` and `.hwpx`.
Korean text renders without any system font: a Noto Sans KR subset with 11,172 Hangul syllables and
8,138 Hanja glyphs is bundled. PDF export writes real glyphs (a `/CIDFontType2` font object), not a
bitmap of the page. One window per user: a second launch hands its document to the running window
and exits. The document scrolls from the keyboard (arrow keys, PageUp/PageDown, Space, Home, End).
The reading surface follows the OS light/dark theme.

## What's in this build

- **Fixed: a table could go completely blank once the page was scrolled**, in flow mode, even
  though the table's own content was intact — a coordinate mix-up mismatched the table's on-screen
  position against the visible area, so every one of its rows looked like it had scrolled off
  screen when it had not.
- **Fixed: a table cell's own picture or nested table could silently disappear**, in flow mode —
  the cell reserved no space for it and drew nothing, as if that part of the cell were empty.
- **Fixed: clicking a table-of-contents entry did nothing** when that heading was a report's
  chapter-title box sitting inside a one-cell table (a common layout in Korean documents) — it now
  scrolls to that table.
- **Fixed: page mode dropped a table cell's own picture or nested table**, drawing empty rows
  instead — page mode now reserves the same height for it and draws it, matching flow mode.
- **Fixed: a page-mode block taller than one page could lose most of its content** instead of
  moving to a fresh page — a survey table nested inside one cell was clipped down to about a sixth
  of itself. Such a block now always starts a fresh page.
- **Fixed: toggling page mode (Ctrl/Cmd+Shift+P) reset the reading position to page 1** in either
  direction — the toggle now keeps the block you were reading, matching the macOS app.
- This build's version number is now shared with the macOS app.
- **New: a native Windows ARM64 build** (`win-arm64`), cross-compiled with llvm-mingw. On the same
  Windows 11 ARM64 machine it exports the same page counts as the x64 build 4–6× faster (`--pdf` on
  a 20 MB HWPX report: 31.2 s against 197 s under x64 emulation) and opened that report in the GUI
  in 884 ms. Its engine library is 10.1 MB against the x64 build's 30.4 MB.
- Text selection and copy in flow mode: drag, double-click for a word, triple-click for a block,
  Ctrl/Cmd+A, Ctrl/Cmd+C, Escape. A table's cells copy tab-separated when the table falls inside a
  larger selection; dragging cannot start or stop inside a cell. Not available in page mode.
- Find highlighting now uses theme colors (a distinct color for the current match) instead of a
  fixed color, matching the reading surface's light/dark handling.
- Clicking a table-of-contents entry or a comment scrolls the flow-mode view to its exact source
  location, addressed by the document's own node id.
- Links: an internal link resolves against document bookmarks, or — for Markdown, which carries no
  bookmarks — against a heading's slug; a link a click cannot resolve does nothing rather than
  being handed to the OS. External links open through the OS default handler. A right-click offers
  Copy and, on a link, Copy Link.
- Code block syntax highlighting: keyword/type/string/number/comment/added/removed tokens are
  colored from the engine's own tokenizer, in theme-matched light/dark colors.
- Markdown images: a relative or `file:` path now renders (resolved against the document's own
  directory); a remote `http`/`https` image shows a placeholder rather than being fetched.
- Header and footer text now respects per-section and first-page scoping instead of concatenating
  every header/footer in the document onto every page.
- PDF export no longer prints `.notdef` tofu boxes for certain control and separator characters
  (a docx's embedded XML example, an HWP table of contents' leader column).
- Pictures now interpolate at high quality when scaled, on screen and in page mode.
- The single-instance fix (a losing launch forwards its path instead of opening a second window)
  is covered in `INVARIANTS.md` 186, not repeated here.
- New Help menu: "?" or F1 opens a Keyboard Shortcuts window listing every shortcut this build
  implements, grouped File/Edit/View/Navigate/Find/Help; Welcome to FastDoc re-opens the first-run
  notice; About FastDoc shows the app name, build version and licence.
- New View menu toggles: Master Page Furniture and Split Tables Across Pages (page mode), Line
  Numbers and Go to Line… (flow mode — numbers each top-level paragraph/table/image, not every
  wrapped line).
- File ▸ Reload re-reads the current document from disk.
- New right-click options: Open (a link under the cursor), Select All, and Copy Code (the whole
  code block, not just a selection).
- Ctrl/Cmd-click on a selected link or file path opens it through the OS; clicking left of the
  text column copies that line's plain text.
- Clicking an image or diagram opens it in an enlarged, zoomable window.
- File ▸ Edit in Default App… opens a read-only Office document (docx/docm/dotx/dotm/odt/hwp/hwpx)
  through the OS's own default handler for that file type.

## What works

- Flow mode (the default for every format): virtualised layout, first frame 8 ms median on a 19 MB
  HWPX and 2 to 8 ms on a 27-table docx. Tables draw as cell grids with merged cells, per-edge
  borders, shading and the document's own column widths.
- Images: hwp/hwpx bytes fetched on demand from the engine; docx/odt bytes read from the source
  archive. Sized by the reading column over the document's declared page width.
- Zoom: Ctrl `+` / `-` / `0`, 0.5x to 3.0x in 10% steps. Text only; the reading position is kept.
- Find: Ctrl+F, case-insensitive, all matches highlighted, Enter / Shift+Enter cycle, Esc closes.
- Open: file dialog (Ctrl+O), drag-and-drop onto the window, 10 recent files.
- Reading position restored per document (100 entries, keyed by path, size and mtime).
- Keyboard scrolling: Down / Up, PageDown / PageUp, Space / Shift+Space, Home / End.
- Light and dark theme: text and background colours re-resolve when the OS theme changes.
- Page mode (View > Page Mode, Ctrl+Shift+P; office documents only): sheets, band sides and table
  placement from the engine, lines never split across pages, header rows repeated on multi-page
  tables. Page counts differ from Word and the macOS app; see the limits below.
- PDF export (File > Export PDF, Ctrl+P, and headless `--pdf`): vector text and embedded pictures.
  A JPEG source is embedded as-is; other pictures are downsampled to at most 2x their drawn size and
  encoded as whichever of JPEG or PNG is smaller. A picture repeated on many pages is stored once.
- Korean text without a system font: Noto Sans KR (SIL OFL 1.1) bundled and registered as the
  fallback for Hangul syllables, compatibility jamo and box-drawing characters.
- Single instance: a second launch forwards its path over a named pipe to the running window, which
  opens it and comes to the front. If no running window answers within 2 s, the second launch opens
  its own window.
- Error messages are plain sentences. A damaged file, an unsupported extension, a missing file, a
  directory passed as a file, a permission error and a non-UTF-8 text file each print one line naming
  the case; no stack trace unless asked for (see Command line).
- Runs on Linux with no display and no fontconfig for the headless flags. This is what the gate's
  Docker step executes on every run.

## What does not work, or is not yet verified

- Page mode's page counts differ from Word and from the macOS app. Cell images and nested tables
  are measured and drawn, a table taller than a page moves to a fresh page, and the page/flow toggle
  keeps the reading position; the count itself is still not Word's. Flow mode stays the default
  until this is closed.
- Android is not included.
- Both Windows builds were run on Windows 11 Pro ARM64 in a virtual machine, not on bare-metal
  hardware. The x64 build ran under Windows' x64 emulation and opened a 10 MB DOCX in 7.3 s; the
  native ARM64 build opened a 20 MB HWPX report in 884 ms. Headless `--pdf` on that HWPX report,
  the DOCX and a 160 KB HWP: 197 s / 24 s / 12 s under emulation, 31.2 s / 6.1 s / 3.0 s native,
  with the same page counts (195 / 35 / 45) from both. The Linux build reports 196 / 35 / 46 for the
  same three files with the same bundled font; word counts show no content loss, and the one-page
  difference is unexplained. Both setups were installed, launched from the Start menu, used through
  **Open with**, upgraded in place and uninstalled on that virtual machine (the x64 setup under
  emulation). `register.ps1` and `unregister.ps1` for the portable zip were reviewed by reading
  them, not by executing them.
- The `.deb` packages were installed, run and removed on Ubuntu 24.04: `arm64` in a virtual
  machine with a desktop session, `amd64` in a container without one.
- The Linux GUI was run on Ubuntu 24.04 (GNOME on Xorg) inside a UTM virtual machine on Apple
  Silicon, not on bare-metal Linux hardware: opening Markdown, DOCX and HWPX by double-click, zoom,
  wheel scrolling, the Export PDF menu item, single instance, and the install/uninstall scripts were
  all exercised there, on both an Xorg and a Wayland (XWayland) GNOME session.
- A screen reader does not read the document body. The reading surface draws its own text and
  exposes no accessibility tree; menus and buttons are standard controls and are announced.
- CJK unified ideographs (U+4E00 to U+9FFF) are not in the bundled font. A document that uses them
  shows boxes unless the OS supplies a font.
- The Linux `.desktop` entry lists only the extensions that have a standard MIME type. Extensions
  without one (`.tf`, `.graphql`, `.proto`, `.hcl` and similar) do not appear in "Open With" on
  Linux. The Windows registration covers all 70.
- Header and footer text is drawn unstyled. No footnote band, no HWP master page (바탕쪽), no
  pinned page number.
- A picture-heavy 186-page HWPX report exports to a 10.7 MB PDF. Its 43 embedded pictures account
  for most of that.
- Long plain-prose documents scroll at 56 to 110 ms per stop (measured on `moby-dick.md`).

## System requirements

Linux (Debian/Ubuntu package names; use your distribution's equivalents):

| Package | Needed for |
|---|---|
| `libicu72` (or the distribution's ICU) | Startup. Without it .NET aborts with "Couldn't find a valid ICU package" |
| `libfontconfig1` and its chain (`libfreetype6`, `libexpat1`, `libpng16-16`, `libbrotli1`) | Loading `libSkiaSharp.so`; apt installs the chain automatically |
| `libx11-6`, `libx11-xcb1` | The GUI. The headless flags do not need them |
| `desktop-file-utils`, `shared-mime-info` | Refreshing the launcher and file-type caches. Without them FastDoc still runs |

The `.deb` package declares these, so `apt` installs them. Windows: none. Each build is
self-contained and includes its own .NET runtime.

Installed sizes, engine library included:

| Target | Size |
|---|---|
| win-x64 | 253.9 MB |
| win-arm64 | 242.4 MB |
| linux-x64 | 133.4 MB |
| linux-arm64 | 136.7 MB |

## Install and uninstall

Downloads are on the GitHub Releases page (https://github.com/ww-w-ai/fast-document-reader/releases),
with a `SHA256SUMS` file covering every file.

| Your computer | Download | Install | Uninstall |
|---|---|---|---|
| Windows, Intel or AMD | `FastDoc-1.4.6-win-x64-setup.exe` | Run it | Settings → Apps → Installed apps → FastDoc → Uninstall |
| Windows on ARM (Snapdragon and similar) | `FastDoc-1.4.6-win-arm64-setup.exe` | Run it | Same |
| Ubuntu or Debian, Intel or AMD | `fastdoc_1.4.6_amd64.deb` | `sudo apt install ./fastdoc_1.4.6_amd64.deb` | `sudo apt remove fastdoc` |
| Ubuntu or Debian, ARM (Raspberry Pi, Apple Silicon VMs) | `fastdoc_1.4.6_arm64.deb` | `sudo apt install ./fastdoc_1.4.6_arm64.deb` | `sudo apt remove fastdoc` |
| Other Linux | `FastDoc-1.4.6-linux-x64.tar.gz` or `-linux-arm64.tar.gz` | Unpack, run `installers/linux/install.sh` | `installers/linux/uninstall.sh` |

The Windows x64 setup also runs on Windows on ARM through Windows' x64 emulation, 4–6× slower; the
ARM64 setup refuses to run on an Intel or AMD PC.

**Windows setup.** No administrator rights: it installs to `%LOCALAPPDATA%\Programs\FastDoc` for the
current user, adds a Start-menu shortcut (a desktop shortcut is optional), and registers FastDoc as an
**Open with** choice for all 70 file extensions it reads. Running a newer setup upgrades in place;
close FastDoc first. Uninstalling removes the program, the shortcuts and every registry entry the
setup added; your recent files and settings stay.

**Debian/Ubuntu package.** Installs the program to `/opt/fastdoc`, the `fastdoc` command to
`/usr/bin`, a launcher entry, the MIME types for `.hwp` and `.hwpx`, and the icon, then refreshes the
desktop caches. `apt remove` takes all of it away again.

**Other Linux.** `installers/linux/install.sh` inside the unpacked archive installs for the current
user only (no `sudo`): it copies the program to `~/.local/share/fastdoc` and adds the launcher entry,
MIME types and icon. `installers/linux/uninstall.sh` removes exactly that.

**Portable Windows zip.** `FastDoc-1.4.6-win-x64.zip` and `-win-arm64.zip` run without installing:
unzip anywhere and start `FastDoc.exe`. `installers\windows\register.ps1 -InstallDir <folder>` adds the
same **Open with** entries the setup adds, and `unregister.ps1` removes them.

None of these makes FastDoc your default app. Windows does not let a program set its own defaults:
choose FastDoc in **Settings → Apps → Default apps** (the setup's last page has a button for it), or
use **File → Set as Default App…** in FastDoc. On Linux, that menu item runs `xdg-mime default` for
Markdown, Word/OpenDocument, HWP and plain text.

## Command line

No arguments, or one document path, opens the window. Headless work is always an explicit flag.
Every entry prints one `mode:` line to stderr first.

| Invocation | stdout |
|---|---|
| `fastdoc --extract <doc>` | the document as Markdown (an office document goes through the host's own `MarkdownSerializer`, ported from the macOS app's; markdown/plain text is printed verbatim) |
| `fastdoc --pdf <in> <out.pdf>` | `pages: N`; the PDF is written to `<out.pdf>` |
| `fastdoc --sheets <doc>` | `sheets: N` plus one line of page geometry |
| `fastdoc --noop` | `noop`; boots the runtime and exits, the timing baseline |

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Document error (unreadable, damaged, unsupported extension, missing file, no permission) or usage error (unknown flag) |
| `2` | Environment error: the engine library was not found. The GUI shows a small window listing the paths it tried; a headless flag prints one `engine library not found:` line |

`FMD_AVALONIA_DEBUG=1` appends the full .NET exception and stack trace after the one-line message.
Without it, only the one line is printed.

Note: `--extract` prints the document's node count and open timing on stderr (`opened: N nodes, M
ms`), alongside the `mode:` line, so a caller can trust stdout to be only the document.

## Third-party notices

`THIRD-PARTY-NOTICES.md` in this directory lists every component shipped: the Avalonia 12.1.2 and
SkiaSharp 3.119.4 packages (MIT), the Noto Sans KR font (SIL OFL 1.1, licence text bundled beside
the font), the rhwp HWP parser (MIT) and the 168 crates.io crates linked into the engine library.
