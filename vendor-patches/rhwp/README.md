# Our patches to rhwp — the HWP parser vendored into this app

**The source of truth is now the submodule `Vendor/rhwp-src` → `ww-w-ai/rhwp` (private), pinned to the
exact commit `Vendor/RHWP-SOURCE.txt` names.** Git records that pin, so "the shipped `.a` and its source
must be committed together" is a rule the tooling keeps rather than a rule a person has to remember.

These patches remain as the READABLE record of what we changed — 86 KB against upstream, which is far
easier to review than a diff of two 6,000-commit trees — and as a second recovery route if the fork
repository is ever lost. They are no longer the only copy of the source.

Restoring the parser source now:

```bash
git submodule update --init Vendor/rhwp-src     # our fork, at the pinned commit
```

The fork's remotes are already `origin` = `ww-w-ai/rhwp` (ours) and `upstream` = `edwardkim/rhwp`, so
following upstream is ordinary git: `git fetch upstream`, then cherry-pick or rebase.

## What they are

Applied on top of upstream **`8d3bfa4b92174b16bac587fe1409975cf34ba566`** (just after `v0.7.19`,
2026-07-17):

| Patch | What it adds to rhwp |
|---|---|
| 0001 | The structured-export FFI itself (`document_json.rs`) + an equation→LaTeX emitter |
| 0002 | `csId` per span and a per-char-shape table of all seven font slots (per-script fonts) |
| 0003 | Full page geometry — paper height and all four margins, not just the body width |
| 0004 | HWP's page-number control (`AutoNumber(Page)`), so a running header can show its page |
| 0005 | Each cell's resolved inner margin, so a host stops inventing one |
| 0006 | An unlocatable inline control placed at its gap rather than at the line's end |
| 0007 | A text run broken where a control sits, so an inline marker lands inside it |
| 0008 | The border-fill table (`borderFills`), and page geometry from the section holding the most paragraphs rather than the first |
| 0009 | Drawing objects as flattened PATHS (+ `asChar`), and picture/gradient fills on a border fill |
| 0010 | A drawing's own affine matrix applied to its points, pictures inside a shape kept, and no fill on an open path |
| 0011 | A picture's size taken from the shape that holds it when the picture states none |
| 0012 | `section` on every running head + `bodySection`, so a host can keep only the ones its page belongs to |
| 0013 | The 바탕쪽 (master page) templates as positioned objects at paper coordinates — where a Korean document's page number actually lives |
| 0014 | A shape's border taken from its LINE TYPE (0 = none) rather than from its width alone, plus the paper sort key (`plane`/`z`) on a master object |
| 0015 | `sectionStarts` — where each section begins in the flat block stream, so a host can tell which page belongs to which section |
| 0016 | A drawing's text boxes collected through GROUP nesting, and kept when the same object also carries a picture |
| 0017 | `vertAlign`/`horzAlign` on an anchored drawing, and the whole anchor (as-char, reference, aligns, offsets) on a picture |
| 0018 | `breakBefore` — the break that STARTS a paragraph (쪽/구역/단 나누기), without which a host loses every page break the author placed (invariant 82) |
| 0019 | The ten things the model knew and the export never said: keep-with-next / keep-lines / widow-orphan / style page-break-before, tab stops, a list's format + start number + glyph system + bullet char, a table's repeat-header rows, and each section's hidden furniture / page-number restart / grid / vertical flag (invariant 83) |
| 0020 | Where a drawing's TEXT BOX sits — the position + size fields themselves (`boxX`/`boxY`/`boxW`/`boxH`) |
| 0021 | …and the coordinates that actually fill them: a group CHILD's position is in its render matrix, which already composes every nested group's transform, so the outermost origin is added once and nesting never accumulates. Accumulating `common` offsets instead exported a 0×0 box, because a child's `common` is empty (invariant 85) |
| 0022 | The paper EACH SECTION declared, not just the busiest one. HWP defines a page per section; carrying one geometry for the document typeset the 편람's 413.9×612.3pt appendix on the body's 396.9×555.6pt sheet |
| 0023 | `wrapsText` — whether an object HOLDS SPACE in the flow (어울림/위아래) or is painted over and behind it (글 앞으로/글 뒤로). Floating both kinds deleted the space the wrapping ones held: 16 of 2,066 real documents lost pages (invariant 86) |
| 0024 | `pageBorder` — the 쪽 테두리/배경 a section rules around its whole page (fill id into the same `borderFills` table, four spacings, and whether they are measured from the sheet or the body area) |
| 0025 | `Placement` — an object's anchor read ONCE from the object the document placed, then handed to everything it emits at any depth. A group child's `CommonObjAttr` is defaults, so reading it drew the 편람's centred foreword frame at the paper's left edge (invariant 87) |

The set is regenerated wholesale — `git format-patch <base>..HEAD -o vendor-patches/rhwp/` from the
fork — so it never drifts behind the submodule again (it had: 0005–0007 existed only as commits).

## Restoring them

```bash
git clone https://github.com/edwardkim/rhwp.git       # full clone, NOT --depth
cd rhwp
git checkout -b fastdocreader/charshape-export 8d3bfa4b92174b16bac587fe1409975cf34ba566
git am /path/to/vendor-patches/rhwp/*.patch
# then docs/BUILD-RHWP.md's rebuild steps (cargo → xcframework → rm -rf .build)
```

Reapplying produces **new commit hashes**, so `Vendor/RHWP-SOURCE.txt`'s recorded commit will no longer
resolve. The base above plus these patches is what identifies the work; the hash is a convenience.

**Clone WITHOUT `--depth`.** The original checkout was shallow (5 commits) and that is why it could
never be pushed anywhere: a remote will not accept a branch whose ancestry is missing
(`remote: fatal: did not receive expected object …`). A shallow clone can fetch and rebase; it cannot
be backed up. That is the whole reason these patches exist instead of a mirror repository.

## Why we are PINNED to 0.7.19, deliberately

Measured 2026-07-30, from our base to upstream `main`:

| | |
|---|---|
| Time | 10 days (2026-07-17 → 07-27) |
| Version | 0.7.19 → 0.8.2 |
| Commits | **7,345** (2,119 of them merges) |
| Source changed | **189 files, +45,014 / −3,032 lines** under `src/` |
| Pull requests | #2335 → #3453 — about **1,118 PRs, ~110 a day** |
| `Co-Authored-By:` an AI | **2,420** commits |

Upstream is an AI-assisted project moving at a hundred merged PRs a day, and 0.8.0, 0.8.1 and 0.8.2
shipped within **two days** of each other (0.8.2 is a hotfix). Taking 45,000 lines of parser change is
not "updating a dependency" — this reader's entire HWP rendering stands on it, so it is a parser
replacement whose verification scope is all of HWP support, not a rebase check.

Being pinned is therefore a CHOICE, not neglect. Anyone finding this repo months behind upstream should
read the numbers above before assuming it drifted by accident.

### The default when we need an upstream fix: cherry-pick, not rebase

If a bug we are blocked on is already fixed upstream, take **that commit alone**, rebuild, and verify.
Known candidates as of this writing:

- `22459efd` `fix(renderer): 바탕쪽 Para/Column 기준 개체를 본문 여백 안에 배치` — relevant to the one
  open HWP defect: a page number inside a 바탕쪽 (master page) text box lands at the end of the header
  line instead of between its dashes.
- `2e0cd528` `fix(render): TAC 인라인 표 x-원점에 outMargin 좌/우 배선`
- `1dbf024f` `v0.8.1 릴리즈 — 렌더 정정`

A cherry-pick can fail if the fix depends on later refactors. That is cheap to find out and still far
cheaper than the alternative.

### Upstreaming our FFI (the exit from maintaining a fork at all) — BLOCKED ON THE REBASE

Upstream welcomes contributions and it is not a formality: `CONTRIBUTING.md` opens with *"모두의 한글은
이름 그대로 모두의 참여로 완성됩니다 … 어떤 형태든 환영합니다"*, there is a `CODE_OF_CONDUCT.md`, 651
forks, 74 open issues, and recently merged PRs come from outside the owner (postmelee ×3, planet6897 ×2,
kevin9327 ×2, lpaiu-cs ×1). What we added is not app-specific glue — a structured JSON export, a
per-char-shape font-slot table, full page geometry, the page-number control — so it is useful to any
consumer, which is why it is worth offering.

A second, easier PR to offer alongside it: rhwp declares `svg2pdf`, `usvg` and `pdf-writer` as
NON-optional dependencies (Cargo.toml 52–55, under a "PDF 내보내기" comment), while `resvg`/`skia-safe`
beside them are already optional behind `native-skia`. Every embedder that does not export PDF links a
PDF writer for nothing — we certainly do, since macOS's print dialog gives "Save as PDF" for free.

Verified that this is safe for us rather than assumed: `usvg` is used in only two files,
`src/renderer/pdf.rs` and `src/renderer/skia/image_conv.rs` (the latter via `resvg`, already gated by
`native-skia`), so with Skia off the PDF path is the only thing in our build touching it. We consume the
PARSE FFI alone and draw with AppKit — even equations arrive as LaTeX for the app's KaTeX engine, which
is what patch 0001's emitter exists for. A `pdf-export` feature mirroring `native-skia` is small,
self-contained, and a gentler first contribution than the FFI itself.

Two things block the FFI PR, and both are structural rather than a matter of willingness:

1. **A PR must come from a GitHub FORK of the target, and GitHub does not allow a private fork of a
   public repo.** `ww-w-ai/rhwp` is a plain private repository (`fork: false`), so it cannot open a PR.
   Sending one needs a second, PUBLIC fork — a decision for the owner, not a step to take quietly.
2. **Our four commits sit on 0.7.19 and would not apply to today's `main`** (45,014 changed source lines
   since). Any reviewer would ask for a rebase, and that rebase IS the work described below. So the PR
   comes AFTER it, not before.

### When to revisit the pin

The owner's own condition: **once 0.8 has settled, take it as a TEST and try applying it.** Concretely,
when the 0.8 line stops shipping hotfixes days apart — say 0.8.4+ with a week of quiet — spend a session
on: full clone → `git am` these patches onto the new tag → rebuild → verify with the instruments this
repo already has, which is the point of doing it as a test rather than a leap:

- `swift test` (1,258 tests; the HWP ones are real)
- `FMD_HWP_SAMPLE`, `FMD_HWP_IMAGE_SAMPLE`, `FMD_HWP_SLOT_SURVEY`, `FMD_HEADER_FOOTER_PROBE` — real-file
  probes that need documents this repo does not ship (see CLAUDE.md's skip list)
- `FMD_RENDER_CORPUS` — drives 1,279 real documents through the real render path as a crash gate
- `--extract` byte-comparison before and after, which is how a parser swap's effect on text is measured
  without judging it by eye
