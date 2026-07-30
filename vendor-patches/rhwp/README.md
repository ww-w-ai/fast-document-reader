# Our patches to rhwp — the HWP parser vendored into this app

`Vendor/RhwpNative.xcframework` is a prebuilt static library. Its Rust source is a **fork of
[edwardkim/rhwp](https://github.com/edwardkim/rhwp) (MIT)** that lives in a separate checkout with no
git relationship to this repo — no submodule, no shared history. So the four commits below, which are
the only part of that parser we wrote, existed **on one laptop** while the binary they produce is
published here permanently. These patches are that gap closed: 86 KB, in the repo that already ships
the binary.

`Vendor/RHWP-SOURCE.txt` names the exact commit the CURRENT binary was built from.

## What they are

Applied on top of upstream **`8d3bfa4b92174b16bac587fe1409975cf34ba566`** (just after `v0.7.19`,
2026-07-17):

| Patch | What it adds to rhwp |
|---|---|
| 0001 | The structured-export FFI itself (`document_json.rs`) + an equation→LaTeX emitter |
| 0002 | `csId` per span and a per-char-shape table of all seven font slots (per-script fonts) |
| 0003 | Full page geometry — paper height and all four margins, not just the body width |
| 0004 | HWP's page-number control (`AutoNumber(Page)`), so a running header can show its page |

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
