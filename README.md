# FastDoc

> **.md .docx .hwp .odt reader, built for the AI era**

[**Free on the Mac App Store**](https://apps.apple.com/app/id6791603562) · Apple silicon · macOS 13+

**AI writes it. You read it — and so does your AI.** That splits the work in two, and this app is
built for both halves.

**For you — reading, not writing.** Plans, specs, summaries, transcripts, the `.docx` a collaborator
sends: it arrives faster than anyone can read it, and your reader shouldn't be the slow part. Most
Markdown apps are a web browser wearing a costume, which is why they take a beat to open and why
memory climbs the longer you leave them running. This one is pure Swift/AppKit/TextKit: it launches
at **15 MB**, a 20 MB document brings it to about **161 MB**, and closing hands back **34–97 MB**
rather than holding the peak forever. Left running for **44 hours**, it used **2 minutes 41 seconds
of CPU** in total. No timers, no polling, no background web process.

**For your AI — fewer tokens.** Two headless commands, no window, no GUI at all:

- **`--extract`** hands any Word/ODT/HWP file over as clean Markdown on stdout. A 14 MB Word report
  is **3.2 MB of XML** if the model parses the file itself; through here it is **94 KB** — **34×
  less to read**, already resolved into headings, tables and text. A `.hwp` isn't even a zip, so
  without this there is nothing for a model to parse at all.
- **`--pdf`** goes the other way: any document to a page-faithful PDF, using the same pages the
  reader shows and ⌘P prints — so a script produces the file instead of asking a person to press ⌘P.

It is the only native Mac Markdown viewer that renders **mermaid diagrams and TeX formulas with both
engines bundled in the app** — offline, each one cached once as a vector PDF and never re-rendered
([`MermaidCache.swift`](Sources/FastDocReader/Cache/MermaidCache.swift)). Images and diagrams
outside the viewport **release their pixels but keep their exact height**, so memory stays flat and
the scrollbar never jumps
([`SizedAttachmentCell.swift`](Sources/FastDocReader/Render/SizedAttachmentCell.swift)).

A reader, on purpose — it opens, renders, and gets out of the way. There is no cursor blinking at
you and no mode to leave. But it is no longer only a viewer: when something in the text is wrong,
right-click that block (or press a key): **Edit** rewrites just its Markdown source, and **Add Below**,
**Move** and **Delete** restructure the document a block at a time. Changes are yours until you
press ⌘S, and only the block you touched is redrawn — **9 ms on a 64,000-character file, 29 ms on
1.2 MB**, so undo stays instant in documents where other apps stall.

**T** brings up a sidebar of every heading, and clicking one moves the reading cursor there — so the
next keystroke acts on that section. Press **⌘N** for a new file: Markdown starts with a small
outline you can immediately edit, plain text starts empty.

**The Finder previews with this engine too.** Press space on a `.md` or a `.hwp` and the preview is
drawn by the reader itself, not by a second, simpler renderer — so what you glance at is what you
open. On a Mac without Hangul installed a `.hwp` has **no preview at all** otherwise.

It opens **plain text too** — `.txt`, `.csv`, `.log`, and the config files a developer opens all day
(`.conf`, `.cfg`, `.ini`, `.env`, `.vars`) — shown verbatim in a fixed-width font, one
block per line, with `#` and `*` left as the characters they are. Files written on Windows or Linux
arrive intact: CP949, UTF-16, Latin-1 and friends are detected rather than assumed, and a file is
**saved back in the encoding it came in**, CRLF and all.

It also opens **Word (`.docx`, `.docm`, `.dotx`, `.dotm`) and OpenDocument (`.odt`) files** — read-only,
so nothing you didn't type can change, but shown as the author formatted it: headings, tables with
merged cells, cell-level images and lists, footnotes, tracked changes, internal links and bookmarks,
equations (drawn through the same bundled formula engine as Markdown math), charts and diagrams, and
right-to-left text. Colour, font and size follow the document — your reading-size preference
multiplies on top of what the author set, the same way Word's own zoom does. The titlebar says
plainly that these formats are read-only, with a one-click hand-off to whatever app you'd rather edit
them in.

A picture is sized against the **document's own page width**, not against your reading font — so ⌘+
and ⌘− change the text alone, and a figure keeps its share of the column as you resize the window,
the same treatment tables already had. A picture inside a table is measured against **that table's**
width instead and stays in its cell. Figures sit left, centred or right where the document says so
(`w:jc`, ODT's `fo:text-align`, HWP's own object alignment) — before this they all rendered left.
Table borders are read **edge by edge, in three states**: drawn, explicitly turned off, or never
mentioned at all. A table that described its own grid and left an edge out draws nothing there — it
already said what it wanted; an edge the author switched off draws nothing; and a table that declared
nothing at all keeps the reader's own default rule, which is every Markdown, HWP and ODT table.

It reads **Korea's HWP (`.hwp`, `.hwpx`) files** the same way — read-only and native, given the same
first-class treatment as Word and ODT. HWP is the dominant document format in Korean offices, schools
and government, and almost nothing on the Mac opens it without Hancom's own suite. Parsing runs
through **rhwp**, a Rust HWP engine compiled straight into the app, and its output flows into the very
same rendering path as Word — so tables, images, styles, links, footnotes and equations arrive as the
author set them, and `--extract` turns a `.hwp` into clean Markdown for an AI exactly like a `.docx`.

Korean documents also get a **table of contents**. HWP's outline flag only marks paragraphs that use
its outline *numbering*, and of 14 real files measured here, 13 produced no headings at all that way
— Korean authors name their styles (제목, 개요) instead. Headings are now read from the paragraph's
style name as well, which took that corpus from 1 file with an outline to 5, so **T** works on a
Korean report the way it already did on Markdown. Line spacing an author set as a percentage is
honoured too (160% reads as neutral, anything else is applied — one measured file had 772 paragraphs
whose spacing was being thrown away). Table cell margins are read from the document instead of a
guessed default, so a real 행정업무운영편람 paginates at **455 pages** here against Hancom's own
viewer at **429** — close, and honestly not identical.

| | FastDoc |
|---|---|
| Engine | 100% native AppKit + TextKit — **no web runtime for text** |
| Idle CPU | **0%** — 44 hours running used **2 min 41 s of CPU** in total; no timers, no polling, no background web process |
| Memory | **15 MB at launch**, ~161 MB with a 20 MB document open, **34–97 MB reclaimed** on close |
| Long docs | The whole document is laid out up front, so the **scrollbar is honest from the first frame** — a 4,000-paragraph file opens instantly and never resizes under you |
| Editing long docs | Only the edited block is re-rendered — **9 ms on 64k characters, 29 ms on 1.2 MB** |
| Plain text | `.txt` · `.csv` · `.log` · `.conf` · `.cfg` · `.ini` · `.env` · `.vars` shown **verbatim**, one block per line — nothing reinterpreted as Markdown |
| Finder preview | Space-bar Quick Look for `.md` and `.hwp` drawn by **this reader's own engine** — the preview and the opened document are the same thing |
| Word / OpenDocument | `.docx`/`.docm`/`.dotx`/`.dotm`/`.odt` — **read-only**, formatting, tables, equations, charts and RTL text shown as authored |
| HWP (Korean) | `.hwp`/`.hwpx` — **read-only**, Korea's dominant document format, rendered natively through the same office engine as Word/ODT, headings and all |
| Extract for an AI | `--extract` turns a `.docx`/`.odt`/`.hwp` into **clean Markdown on stdout** — headless, so an AI reads it without spending tokens parsing the file |
| Print to PDF | `--pdf` renders any document to a **PDF file with no window** — the same pages the reader shows and ⌘P prints |
| Encodings | CP949 · UTF-16 · Latin-1 detected, not assumed — **saved back in the same encoding**, CRLF kept |
| Diagrams | **mermaid bundled** — renders offline, cached as vector PDF, never re-rendered |
| Math | **KaTeX bundled** — `$$…$$` and ```` ```math ```` render offline, vector, cached the same way |
| Images | Off-screen pixels freed, exact height kept — **no reflow, no scrollbar jitter** |
| Office graphics | Sized by the **document's own page width**, not your font size — ⌘+/⌘− move text alone, and a figure tracks the window. Left/centre/right honoured as authored |
| Table borders | Read **per edge, three-state** — drawn, switched off, or never mentioned. A table that described its own grid is taken at its word; one that declared nothing is unchanged |
| Pages | Word/ODT/HWP shown as **real sheets** at the paper's own size, with the running header and footer in the page's own margins. **⌥⌘P** is the one switch — off collapses everything into continuous flow with no page edges, header, footer or break rule |
| Margin numbers | View ▸ Line Numbers — retitled **Page Numbers** for a paged document with the page outline on. Numbers the document's own line or page, painted beside the text, never moving it |
| Printing | **⌘P** prints the same pages you are reading, on the document's own paper — and the print dialog's "Save as PDF" is therefore the PDF export |
| Navigation | **T** opens a table of contents built from the document's own headings — click to jump. **⌘1…⌘9** and **⌥⌘←/→** move between tabs. Hidden outright when a document has none |
| Code | **34 languages** highlighted natively — one-pass scanner, no JS, per-block **Copy** and **Wrap** |
| Editing | Reader first — **E** edit · **I** add below · **U/J** move · **D** delete, held in memory until ⌘S |

## Hand a Word file to an AI, as clean Markdown

Point an AI at a `.docx` or `.odt` and it burns tokens unzipping and parsing the XML itself. Run the
same engine headless instead — no window, no Dock icon — and it prints clean Markdown to stdout:

```sh
FastDocReader.app/Contents/MacOS/FastDocReader --extract report.docx
```

Because it reuses the reader's **own** office parser, the Markdown mirrors what you'd see on screen:
headings, lists with the document's real numbering, bold/italic/strikethrough/links, simple tables as
pipe tables, standalone formulas as `$$…$$`, images and charts as honest placeholders. Mapping stays
conservative on purpose — anything a Markdown table can't hold safely (merged cells, block content in
a cell) is dumped as literal text inside a `<raw>…</raw>` marker rather than a fabricated grid that
would read as correct, and a one-line note at the top explains the marker. It reads the Word family
(`.docx` `.docm` `.dotx` `.dotm`), `.odt` and Korean HWP (`.hwp`/`.hwpx`), plus `.md`/`.txt`
verbatim, and exits non-zero on anything it can't read so a script can trust the output.

## A PDF, from the command line, no window

`⌘P` already prints exactly what you're reading — real pages, on the document's own paper, running
header and footer included. The same path runs headless, so a script can get that PDF without ever
opening a window:

```sh
FastDocReader.app/Contents/MacOS/FastDocReader --pdf report.docx
```

That writes `report.pdf` next to the input; `-o out.pdf` picks the path, and `-f` overwrites one
that's already there. It reads the same formats `--extract` does — the Word family, `.odt`, Korean
HWP (`.hwp`/`.hwpx`) and plain text/Markdown — one document per run. Tested against a 490-page HWP,
an 11-page `.docx`, a 9-page `.odt` and a 423-page Markdown file.

## Diagrams render offline, once

The mermaid engine ships inside the app — no CDN, no network, nothing to load. A diagram is
rendered a single time to a **vector PDF**, cached by content hash, and reused forever. Open the
same document again and diagrams appear instantly with zero web or JS cost. A document with no
diagrams never creates a web view at all.

![mermaid diagrams rendered natively](assets/screenshots/mermaid.png)

## Images stay sharp without staying in memory

Every image and diagram **owns its layout size independently of its pixels**. Scroll away and the
pixels are released; scroll back and they return — but the reserved height never changes, so the
document length is stable and the scrollbar never swings. Sizes are measured up front (image
headers, cached PDFs, and remote images via a range request), so the page is laid out **once**.

![images and rich Markdown](assets/screenshots/images.png)

## Formulas, drawn once and cached forever

Math ships the same way diagrams do: KaTeX is **inside the app**, fonts and all, so `$$…$$` (and
GitHub's ```` ```math ```` fence) render with no internet. Each formula is drawn a single time to a
vector PDF and reused forever — zoom as far as you like, it stays sharp.

Reading the TeX from the source, not the parsed text, is what makes it correct: Markdown claims `_`
and `^` as emphasis, so `$$a_1^2$$` would otherwise come back as *a12* — wrong maths, which is worse
than none ([`MarkdownRenderer.swift`](Sources/FastDocReader/Render/MarkdownRenderer.swift)).

## Code blocks are real cards

![code cards and tables](assets/screenshots/code.png)

Fenced blocks render as rounded cards with a language label, a **Copy** button and a **Wrap** toggle
— no JavaScript involved. **34 languages** are highlighted natively, under the names people actually
type (`yml`, `golang`, `c++`, `c#`, `sh`, `postgres`, `tsx`, `patch`…):

> swift · js · ts · go · rust · java · kotlin · c · c++ · c# · scala · dart · php · objc · python ·
> ruby · perl · lua · r · elixir · haskell · bash · powershell · dockerfile · makefile · json · yaml ·
> toml · ini · sql · html · xml · css · diff

The highlighter is a single left-to-right scanner, not a stack of regexes painting over each other
([`CodeHighlighter.swift`](Sources/FastDocReader/Render/CodeHighlighter.swift)). That's what keeps a
URL's `//` inside a string from turning the rest of the line into a comment — the bug you've seen in
every editor that gets it wrong. Tables, task lists and strikethrough come from CommonMark + GFM.

## Speed, and one optimisation that didn't work

Rendering used to walk the whole text storage three times; it walks it once. The table-column pass
used to invalidate layout per cell and now does a single union, which took a 62-table HWP file from
**72.8 ms to 1.1 ms** and a docx from **5.0 ms to 0.7 ms** — and tables are now built at the real
reading width instead of being drawn at a placeholder width and immediately re-solved. Zooming a
heavy HWP document went from **769 ms to about 300 ms**.

The one that failed is worth stating too, because it sounds obviously right: laying out only the
visible page first and deferring the rest. Measured on a 38-table docx, three runs per variant,
baseline settled at **105–121 ms**; viewport-first was **121–148 ms**; a 256-unit structural cap
**155–170 ms**; a 64-unit cap **186–192 ms**. Every variant was slower to a fully laid-out document
and none of them moved the worst freeze, because the visible page is already interactive before that
pass runs — there was nothing left to defer. It was reverted, and the numbers live in the code
comment and two tests so nobody has to re-derive them.

## Try it on real documents

The [`demo/`](demo/) folder has four documents, each one a case that makes readers stumble:
[34 languages in code blocks](demo/code-blocks.md), [formulas](demo/math.md), [twelve
photographs of differing heights](demo/images.md), and [the whole of *Moby-Dick*](demo/moby-dick.md) — 213,000 words in one
file, which should open the instant you double-click it.

## Install

**Apple Silicon (arm64) only.** Requires macOS 13+.

**[Mac App Store](https://apps.apple.com/app/id6791603562)** — free, one click, updates itself. That
build is sandboxed, which is the store's price: it can read the file you opened but not the images
sitting beside it until you grant that folder once (see [Two builds, one
difference](#two-builds-one-difference)). The same grant is what the two headless commands need
there — a path handed in on the command line carries no permission of its own, so `--extract` and
`--pdf` work on **folders you have granted** and say so plainly when they meet one you haven't.

Or download the notarized zip, unzip it, drag `FastDocReader.app` to `/Applications`, double-click.
No Gatekeeper prompt and no `xattr` step — the app is signed with a Developer ID and stapled, and it
is **not** sandboxed, so sibling images just load.

To open files here by default: **FastDoc → Set as Default App…**, which lists the kinds it
can claim with a checkbox each — Markdown ticked, text formats yours to choose. Per file, the Finder
route still works: right-click → **Get Info** → **Open with** → **Change All…**.

## Build from source

```bash
./Scripts/make-app.sh        # builds FastDocReader.app (ad-hoc signed, unsandboxed)
open FastDocReader.app
```

Tests: `swift test`.

> **Toolchain note:** a standalone Command Line Tools install can ship a mismatched SwiftPM
> ManifestAPI that breaks `swift build`. `make-app.sh` prefers Xcode's toolchain automatically via
> `DEVELOPER_DIR`; make it permanent with `sudo xcode-select -s /Applications/Xcode.app`.

Signing identity and App Store Connect key ids are **not** in this repo — the release scripts read
them from `$KEYCHAIN_DIR/signing.env` (default `~/Documents/DEV/ww-w-ai/.keychains/`) and name the
missing variable if it isn't there. To sign as yourself, export your own; no code changes:

```bash
export IDENTITY="Developer ID Application: <You> (<TEAMID>)"
export NOTARY_PROFILE="<your notarytool keychain profile>"
./Scripts/notarize.sh        # signed + notarized + stapled zip
```

### Two builds, one difference

The direct download is **not sandboxed**; the Mac App Store build is (the store requires it).
Sandboxed, macOS grants an app only the file you opened — a document's own `![](diagram.png)`
sibling is a different file and is denied, with no prompt, because the sandbox refuses before macOS
asks and no "Documents folder" entitlement exists. So the store build asks once, per folder, and
remembers it; the direct build simply reads them. `SANDBOX=1 ./Scripts/make-app.sh` builds the
sandboxed shape locally.

## Keyboard and mouse

The reading cursor moves in whole units — line, sentence, paragraph and heading. Down the page
**fn** steps the coarse `#` outline (top-level headings only) and **⌘** steps every heading, **⌥**
pages, and **fn⌘** jumps to the very top or bottom; across a line **⌘** is the whole line, **⌥** a
sentence, **fn** a paragraph. Hold **⇧** and the same move becomes a selection, so ⌘C grabs exactly
what you just crossed.

| Key | Moves the cursor to… |
|---|---|
| **⌘← / ⌘→** | Start / end of the line |
| **⌥← / ⌥→** | Previous / next sentence |
| **fn← / fn→** | Previous / next paragraph (a heading, list, code block or table is one stop) |
| **fn↑ / fn↓** | Previous / next top-level `#` heading (the document's coarse outline) |
| **⌘↑ / ⌘↓** | Previous / next heading (any level) |
| **⌥↑ / ⌥↓** | Page up / down (a few lines overlap so you keep your place) |
| **fn⌘↑ / fn⌘↓** | Start / end of the document |
| **⇧ + any of the above** | The same move, selecting everything it crosses |
| **Space / ⇧Space** | Page down / up |
| **⌘F** | Find in document |
| **⌘+ / ⌘− / ⌘0** | Font size (persists to the next launch) / actual size |
| **Type a number, then Return** | Jumps to that line — or that page, once the page outline is on. Esc, backspacing past the first digit, or ~2 seconds of silence forgets it |
| **⌘L** | Same jump, asked for in a dialog ("Go to Line…" / "Go to Page…") |

Mouse:

| Action | What it does |
|---|---|
| **Click the left margin** beside a block | Selects that whole block and copies it — a heading takes its entire section, a code block its raw source |
| **Click a diagram, formula or image** | Opens it enlarged in a zoomable window (pinch or `⌘+`/`⌘−`, `⌘0` to fit, `esc` to close) |
| **Select text, then ⌘-click it** | Opens it — a file path, a URL, or a bare domain |
| **Drag** | Ordinary text selection, as anywhere on the Mac |
| **Pinch** | A paged document (Word/ODT/HWP) zooms like a real viewer. Markdown and plain text preview the pinch live and commit one re-layout at the size your fingers chose — the same font-size model ⌘+/⌘− use |

The page holds still and the cursor moves inside it — the view scrolls only when the cursor would
leave the screen, and then by the least it can.

**Fix a typo without leaving:** right-click a block → **Edit** (or press **E**) opens just that
block's Markdown source; select across several blocks first and they open **merged as one**. **⌘↵**
applies it to the open document, **esc** discards. Nothing reaches disk until you press **⌘S** — the
edit lives in the document until then, undoes cleanly, and ⌘R warns before discarding it.

## License

MIT — see [LICENSE](LICENSE). Third-party attributions: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Built by [DubDubDub Corp.](https://ww-w.ai)
