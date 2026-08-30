//! swift: Render/Office/PageBandGeometry.swift
//! swift-range: 1-2

use std::collections::HashMap;
use swiftshim::{CGFloat, NSAttributedString};
use swiftshim::text_measure::{ResolveError, ResolvedText, TextMeasurerMissing};
use crate::render::office::office_block::OfficeBlock;
use crate::render::office::office_text_builder::OfficeTextBuilder;
use crate::render::render_theme::RenderTheme;

/// The document's own running header/footer for one section, as declared. Referenced here from
/// `office_block` (S3's vocabulary type); not redefined.
// swift: Render/Office/PageBandGeometry.swift — OfficeHeaderFooter is declared in OfficeBlock.swift, not here.
pub use crate::render::office::office_block::OfficeHeaderFooter;

/// Why a band-height decision could not answer, S5-03's typed absence. Two distinct causes fold
/// into one refusal for the caller: nothing is installed to measure with at all
/// (`TextMeasurerMissing`), or `OfficeTextBuilder`'s own output could not be resolved into the
/// port's payload — today that is only an attachment run whose reserved size the builder never
/// set (`ResolveError::UnresolvedAttachmentSize`). Both are refusals rather than a guessed
/// height: this module's header names that as the failure this repository has now shipped three
/// times, and a stand-in number here would be a fourth.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeasureError {
    NoMeasurer,
    UnresolvedPayload(ResolveError),
}

impl std::fmt::Display for MeasureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoMeasurer => f.write_str("no TextMeasurer installed — the band height cannot be decided"),
            Self::UnresolvedPayload(inner) => write!(f, "the band's own text could not be resolved: {inner}"),
        }
    }
}

impl std::error::Error for MeasureError {}

impl From<TextMeasurerMissing> for MeasureError {
    fn from(_: TextMeasurerMissing) -> Self {
        Self::NoMeasurer
    }
}

impl From<ResolveError> for MeasureError {
    fn from(error: ResolveError) -> Self {
        Self::UnresolvedPayload(error)
    }
}

/// Measures the vertical space a document's running header + footer actually occupy when built by
/// THIS reader's own `OfficeTextBuilder` — never the document's declared header/footer OFFSET.
/// header-footer-design.md §4 is explicit about why: "the space has to fit the header as this
/// reader renders it, and if our rendering is taller the header lands on top of the body text." So
/// the band is measured, not read from the file, and it needs no new parsing.
///
/// Consumed by `PageBandLayoutDelegate`, which reserves this much space between one page's text and
/// the next's (header-footer-design.md build step 4 — geometry only; painting the header/footer
/// into the space this reserves is step 5, not yet built).
// swift: Render/Office/PageBandGeometry.swift:3-232
pub struct PageBandGeometry;

/// The header height, the footer height, AND the combined band — measured together so a caller
/// building the PAINTING context (`PageBandPainter`, build step 5) doesn't measure header+footer
/// twice: once for `bandHeight` (how much space to RESERVE) and again for how tall each side is
/// (where to PAINT it). `band` here is the same number `bandHeight(...)` returns for identical
/// inputs — `PageBandReservationTests` proves that identity — but this is an ADDITIVE surface:
/// `bandHeight` itself is untouched (same private `measuredHeight` calls, same tests judge it
/// directly), so nothing already shipped is at risk of a change here.
// swift: Render/Office/PageBandGeometry.swift:56-68
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sides {
    pub header: CGFloat,
    pub footer: CGFloat,
    pub band: CGFloat,
}

/// The document's own declared rule above its footnotes, as much of `OfficeFootnoteSeparator` as
/// `separator_allowance` needs — mirrors `FootnotePainter.separatorAllowance`'s own four fields.
/// A page whose section resolved to no separator at all crosses as `None`, kept distinct from
/// `Some` with `is_declared == false` (a separator struct the document never populated) even
/// though both answer the reader's own default — the two are different FACTS on the host side
/// (`footnoteSeparator(forPage:)`'s own `nil` vs. `OfficeFootnoteSeparator.isDeclared`) and this
/// keeps them distinct at the boundary too, matching S5C-3's own "nothing invented" rule.
// swift: Render/Office/OfficeBlock.swift:1148-1170
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FootnoteSeparatorDesc {
    pub is_declared: bool,
    pub line_type: i64,
    pub line_width_pt: CGFloat,
    pub margin_top_pt: CGFloat,
    pub margin_bottom_pt: CGFloat,
}

impl PageBandGeometry {
    /// The space a document itself puts between one page's last body line and the next page's
    /// first: its bottom margin plus the next page's top margin. Both are the PAPER margins — a
    /// running header lives inside the top one and a footer inside the bottom one, in all three
    /// formats — so this single number is exactly the band, already carrying the header and footer
    /// areas the document allowed for.
    ///
    /// This replaced a fixed 12pt "gap between pages" the reader invented, which is the mistake
    /// invariant 57 is about: the document had stated the answer and the app was filling in its own.
    /// On a real .odt the two agree to within a point (declared 85.10pt against the old measured
    /// 84.15pt), which is why the invented value looked plausible for as long as it did.
    ///
    /// Nil margins mean the document never said, and the band falls back to what this reader must
    /// draw — see `bandHeight`.
    pub fn declared_band(margin_top: Option<CGFloat>, margin_bottom: Option<CGFloat>) -> CGFloat {
        margin_top.unwrap_or(0.0).max(0.0) + margin_bottom.unwrap_or(0.0).max(0.0)
    }

    /// The document's own inter-page space (`declaredBand`) — but never less than the header and
    /// footer this reader actually draws, or they would land on top of the body text. Exactly `0`
    /// when both measure empty — a document
    /// with no running header or footer must reserve nothing at all (see
    /// `PageBandLayoutDelegate.isActive`, which gates on this being `> 0`, and header-footer-
    /// design.md's own "a document with no header and no footer has band 0 and MUST behave exactly
    /// as it does today").
    ///
    /// Only the entry that applies to every ordinary page (`.defaultPages`) is measured;
    /// `.firstPage`/`.evenPages` are deferred past v1 (header-footer-design.md §7 — even/odd
    /// headers and a first-page cover are both "after v1"), so measuring the one that actually
    /// repeats on most pages is the honest number for now, not an oversight.
    ///
    /// Builds through the SAME `OfficeTextBuilder` the document's own body uses — never a second,
    /// divergent rendering path (invariant 29's discipline) — laid out once in an ISOLATED stack
    /// (its own storage/layout manager/container), so measuring never touches or invalidates the
    /// real text view.
    // swift: Render/Office/PageBandGeometry.swift:30-55
    #[allow(clippy::too_many_arguments)]
    pub fn band_height(
        headers: &[OfficeHeaderFooter],
        footers: &[OfficeHeaderFooter],
        theme: &RenderTheme,
        column_width: CGFloat,
        document_default_font_size: CGFloat,
        page_content_width: Option<CGFloat>,
        page_margin_top: Option<CGFloat>,
        page_margin_bottom: Option<CGFloat>,
    ) -> Result<CGFloat, MeasureError> {
        Ok(Self::measure(
            headers,
            footers,
            theme,
            column_width,
            document_default_font_size,
            page_content_width,
            page_margin_top,
            page_margin_bottom,
            false,
            None,
        )?
        .band)
    }

    /// `separatesPages` — the reader is drawing each sheet as its own page
    /// (`PageViewOptions.outline`), so the space BETWEEN two sheets has to exist even when there is
    /// no header or footer to put in it. Without this a document with page furniture switched off but
    /// the outline on would draw its sheets edge to edge with no desk between them, which is not a
    /// stack of pages. Defaults to `false`, which is exactly the rule this function had before the
    /// toggles existed: no header and no footer means no band at all.
    // swift: Render/Office/PageBandGeometry.swift:69-100
    #[allow(clippy::too_many_arguments)]
    pub fn measure(
        headers: &[OfficeHeaderFooter],
        footers: &[OfficeHeaderFooter],
        theme: &RenderTheme,
        column_width: CGFloat,
        document_default_font_size: CGFloat,
        page_content_width: Option<CGFloat>,
        page_margin_top: Option<CGFloat>,
        page_margin_bottom: Option<CGFloat>,
        separates_pages: bool,
        desk_gap: Option<CGFloat>,
    ) -> Result<Sides, MeasureError> {
        let h = Self::measured_height(headers, theme, column_width, document_default_font_size, page_content_width)?;
        let f = Self::measured_height(footers, theme, column_width, document_default_font_size, page_content_width)?;
        if !(h > 0.0 || f > 0.0 || separates_pages) {
            return Ok(Sides { header: h, footer: f, band: 0.0 });
        }
        // The document's own two margins when it stated them, and what this reader must draw when
        // that is taller — the max, not a sum, because the header and footer are drawn INSIDE those
        // margins rather than added to them. A document that never stated a margin falls back to the
        // drawn height alone, which is the honest minimum and what the two sides need.
        // …plus, when the reader is drawing SHEETS, the desk you can see between two of them. Two
        // stacked pieces of paper touch, so this is the one number in the band no document declares
        // and the reader has to (see `RenderTheme.pageDeskGap`, which explains why that is not
        // invariant 57(e)'s invented constant returning). It is NOT printed: `PagePagination` takes
        // it back off, so the paper is exactly the document's own sheet.
        let band = Self::declared_band(page_margin_top, page_margin_bottom).max(h + f)
            + desk_gap.unwrap_or(if separates_pages { RenderTheme::PAGE_DESK_GAP } else { 0.0 });
        Ok(Sides { header: h, footer: f, band })
    }

    /// One side (headers OR footers) of `bandHeight`, isolated so the additive structure
    /// (`headerOnly + footerOnly - gap == both`) is independently testable without re-deriving font
    /// metrics in the test itself.
    // swift: Render/Office/PageBandGeometry.swift:101-121
    fn measured_height(
        entries: &[OfficeHeaderFooter],
        theme: &RenderTheme,
        column_width: CGFloat,
        document_default_font_size: CGFloat,
        page_content_width: Option<CGFloat>,
    ) -> Result<CGFloat, MeasureError> {
        if !(column_width.is_finite() && column_width > 0.0) {
            return Ok(0.0);
        }
        // The TALLEST of them, not the first. Once a document's entries come from several sections
        // (a page takes its own section's — invariant 78), any of them can be the one painted on a
        // given page, and a band measured against a shorter one would let a taller one overlap the
        // body text. Reduces to exactly the old number for the overwhelmingly common document whose
        // entries are one section's.
        let mut tallest: CGFloat = 0.0;
        for entry in entries {
            if entry.blocks.is_empty() {
                continue;
            }
            tallest = tallest.max(Self::built_height(&entry.blocks, theme, column_width, document_default_font_size, page_content_width)?);
        }
        Ok(tallest)
    }

    /// How much a page must keep clear at its foot for the notes cited on it: the separator's own
    /// allowance, the notes themselves, and the document's spacing BETWEEN them.
    ///
    /// Pure arithmetic over already-measured heights, so the fixpoint (invariant 98) can be driven
    /// and tested without laying anything out. A page citing no note reserves nothing — not a
    /// minimum, not a separator: the rule must reduce to today's layout for the 615 of 637 corpus
    /// documents that never cite a footnote at all.
    // swift: Render/Office/PageBandGeometry.swift:122-136
    pub fn footnote_band_height(note_heights: &[CGFloat], separator_allowance: CGFloat, note_spacing: CGFloat) -> CGFloat {
        let drawn: Vec<CGFloat> = note_heights.iter().copied().filter(|h| *h > 0.0).collect();
        if drawn.is_empty() {
            return 0.0;
        }
        let between = note_spacing * ((drawn.len() as CGFloat) - 1.0);
        separator_allowance.max(0.0) + drawn.iter().sum::<CGFloat>() + between.max(0.0)
    }

    /// How much room a page's footnote separator claims above the notes themselves: the rule
    /// line's own width (or nothing, for a document that declared a line TYPE of "none") plus its
    /// top and bottom margins — or the reader's own minimum, `None`/undeclared, exactly matching
    /// `FootnotePainter.separatorAllowance`'s `guard let separator, separator.isDeclared else {
    /// return defaultSeparatorAllowance }`.
    ///
    /// Pure arithmetic ported unchanged so the reservation (`footnote_band_height`, above) and the
    /// separator `FootnotePainter.draw` actually paints agree to the point — a difference here puts
    /// a note over the last line of body text, the same failure that function's own comment names.
    // swift: Render/Office/FootnotePainter.swift:24-34
    pub fn separator_allowance(separator: Option<&FootnoteSeparatorDesc>) -> CGFloat {
        // swift: Render/Office/FootnotePainter.swift:17-34
        const DEFAULT_SEPARATOR_ALLOWANCE: CGFloat = 8.0;
        let Some(separator) = separator else { return DEFAULT_SEPARATOR_ALLOWANCE };
        if !separator.is_declared {
            return DEFAULT_SEPARATOR_ALLOWANCE;
        }
        let rule = if separator.line_type == 0 { 0.0 } else { separator.line_width_pt.max(0.5) };
        separator.margin_top_pt + rule + separator.margin_bottom_pt
    }

    /// How tall this run of blocks is once BUILT and laid out at `columnWidth` — the one place that
    /// answers it, for a running head and for a footnote alike.
    ///
    /// Built through `OfficeTextBuilder` exactly as before — paragraph style, tab stops, hanging
    /// indents, line height and list numbering are all INTERPRETED there, which is the decision
    /// this sprint keeps in Rust — and then measured through the port (S5-01/S5-03) rather than a
    /// TextKit stack this crate assembles itself: `swiftshim::text_measure` carries that resolved
    /// output across and asks whichever live text stack the host installed for the used height,
    /// because no arithmetic over the spans can tell a two-line header from one that WRAPS to two
    /// lines — only laying it out can. Blocks that build to nothing still measure `0`
    /// (`drawsSomething`) without asking the port at all — 28% of the real documents that declare a
    /// header declare an EMPTY one, and reserving space for those would put a gap on every page of
    /// a quarter of the corpus. With no measurer installed, or a run this module cannot resolve
    /// into the port's payload (an attachment whose reserved size the builder never set), this
    /// refuses rather than returning a plausible number — `MeasureError`, not a stand-in height.
    // swift: Render/Office/PageBandGeometry.swift:137-165
    pub fn built_height(
        blocks: &[OfficeBlock],
        theme: &RenderTheme,
        column_width: CGFloat,
        document_default_font_size: CGFloat,
        page_content_width: Option<CGFloat>,
    ) -> Result<CGFloat, MeasureError> {
        if blocks.is_empty() || !(column_width.is_finite() && column_width > 0.0) {
            return Ok(0.0);
        }
        let attr = OfficeTextBuilder::build(
            blocks,
            theme,
            column_width,
            document_default_font_size,
            page_content_width,
            None,
            None,
            None,
            &[],
            &std::collections::HashSet::new(),
            &[],
            &[],
            &[],
            &[],
            &[],
            &HashMap::new(),
        );
        if !(attr.length() > 0) || !Self::draws_something(blocks, &attr) {
            return Ok(0.0);
        }
        let resolved = ResolvedText::from_attributed_string(&attr)?;
        let measurer = swiftshim::text_measure::try_measurer()?;
        Ok(measurer.measure(&resolved, column_width))
    }

    /// EVERY footnote's own height, `(number, built_height)` per entry — S5D-2: the input the
    /// settle's own band arithmetic adds up (`footnote_band_height`, above), now measured here
    /// instead of once per render on the host side. Calls `built_height` UNCHANGED, one note at a
    /// time; no new arithmetic. Keyed by the document's own number (`OfficeFootnote.number`), never
    /// position — the host reads this back by number too (`s5d2.md`'s own reason: two independent
    /// parses of the same bytes must never be assumed to agree on ORDER, only on the numbers a
    /// document actually declared).
    ///
    /// `Err` on the FIRST note that cannot be measured — never a map missing just that one entry. A
    /// map short one footnote reserves that page's band short by exactly its height, which is
    /// invariant 98's corrupt half (a note drawn over the body); the caller must have every height
    /// or none.
    // swift: Render/Office/PageBandGeometry.swift — resolveNoteHeights consumes this answer, not a
    // Swift-side twin of this loop.
    pub fn footnote_heights(
        footnotes: &[crate::render::office::office_block::OfficeFootnote],
        theme: &RenderTheme,
        column_width: CGFloat,
        document_default_font_size: CGFloat,
        page_content_width: Option<CGFloat>,
    ) -> Result<Vec<(i64, CGFloat)>, MeasureError> {
        footnotes
            .iter()
            .map(|note| {
                Self::built_height(&note.blocks, theme, column_width, document_default_font_size, page_content_width)
                    .map(|height| (note.number, height))
            })
            .collect()
    }

    /// Does this ONE entry have anything for the reader to put in a band — the question every gate
    /// that used to ask `blocks.isEmpty` should be asking instead. Built through the same
    /// `OfficeTextBuilder` as everything else, so a format whose header parses into blocks that build
    /// to nothing is judged on what it BUILDS rather than on what it parsed.
    // swift: Render/Office/PageBandGeometry.swift:195-206
    pub fn entry_draws(
        entry: Option<&OfficeHeaderFooter>,
        theme: &RenderTheme,
        column_width: CGFloat,
        document_default_font_size: CGFloat,
        page_content_width: Option<CGFloat>,
    ) -> bool {
        let Some(entry) = entry else { return false };
        if entry.blocks.is_empty() || !(column_width.is_finite() && column_width > 0.0) {
            return false;
        }
        let built = OfficeTextBuilder::build(
            &entry.blocks,
            theme,
            column_width,
            document_default_font_size,
            page_content_width,
            None,
            None,
            None,
            &[],
            &std::collections::HashSet::new(),
            &[],
            &[],
            &[],
            &[],
            &[],
            &HashMap::new(),
        );
        Self::draws_something(&entry.blocks, &built)
    }

    /// Is there anything in this entry for the reader to PUT in the band it is about to reserve?
    ///
    /// "The entry has blocks" is not that question, and the difference is common rather than exotic:
    /// **26 of the 94 real HWP/HWPX documents that declare a header or footer at all — 28% — declare
    /// one made of nothing but empty paragraphs.** Such an entry measured a full line height, so the
    /// reader opened a band on every page and drew nothing in it. That is invariant 47's three-state
    /// lesson one level deeper than `w:titlePg`'s blank entry (which arrives with NO blocks and was
    /// already handled): present, present-but-empty, and absent are three different answers.
    ///
    /// A picture-only header must still reserve, so the text test is for any NON-WHITESPACE character
    /// — an attachment is `U+FFFC`, which is not whitespace — and a paragraph that draws only a RULE
    /// or a shaded band carries no glyph at all, so the blocks are asked directly for those. Anything
    /// that is not a paragraph (a table, an image, a formula) is content by construction.
    // swift: Render/Office/PageBandGeometry.swift:208-231
    pub fn draws_something(blocks: &[OfficeBlock], built: &NSAttributedString) -> bool {
        if built.string().chars().any(|c| !c.is_whitespace()) {
            return true;
        }
        blocks.iter().any(|block| match block {
            OfficeBlock::Paragraph { format, .. } | OfficeBlock::Heading { format, .. } => {
                format.shading.is_some() || format.border_edges.raw_value != 0
            }
            _ => true,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn declared(line_type: i64, line_width_pt: CGFloat, margin_top_pt: CGFloat,
                margin_bottom_pt: CGFloat) -> FootnoteSeparatorDesc {
        FootnoteSeparatorDesc { is_declared: true, line_type, line_width_pt, margin_top_pt, margin_bottom_pt }
    }

    use crate::render::office::office_block::OfficeFootnote;

    fn empty_note(number: i64) -> OfficeFootnote {
        OfficeFootnote { number, blocks: vec![], section: None }
    }

    /// No footnotes at all — the empty answer, no measurer needed.
    #[test]
    fn no_footnotes_answers_no_entries() {
        let theme = RenderTheme::current(11.0);
        let out = PageBandGeometry::footnote_heights(&[], &theme, 300.0, 11.0, None);
        assert_eq!(out, Ok(vec![]));
    }

    /// A footnote whose blocks are empty builds to nothing and measures `0` WITHOUT a measurer —
    /// `built_height`'s own short-circuit, called unchanged.
    #[test]
    fn a_footnote_with_no_blocks_measures_zero_without_a_measurer() {
        let theme = RenderTheme::current(11.0);
        let out = PageBandGeometry::footnote_heights(&[empty_note(3)], &theme, 300.0, 11.0, None);
        assert_eq!(out, Ok(vec![(3, 0.0)]));
    }


    /// No resolved separator at all — the host's `footnoteSeparator(forPage:)` returned `nil` —
    /// falls back to the reader's own minimum, matching `FootnotePainter.separatorAllowance`'s
    /// `defaultSeparatorAllowance`.
    #[test]
    fn no_separator_falls_back_to_the_default() {
        assert_eq!(PageBandGeometry::separator_allowance(None), 8.0);
    }

    /// A separator struct that carries no declaration (`is_declared == false`) answers the same
    /// default as `None` — the two are different FACTS at the boundary but the same ANSWER.
    #[test]
    fn undeclared_separator_falls_back_to_the_default() {
        let sep = FootnoteSeparatorDesc {
            is_declared: false, line_type: 1, line_width_pt: 2.0, margin_top_pt: 3.0, margin_bottom_pt: 4.0,
        };
        assert_eq!(PageBandGeometry::separator_allowance(Some(&sep)), 8.0);
    }

    /// `lineType == 0` ("no rule") drops the line width entirely — only the margins remain.
    #[test]
    fn line_type_zero_reserves_no_rule_width() {
        let sep = declared(0, 5.0, 1.0, 2.0);
        assert_eq!(PageBandGeometry::separator_allowance(Some(&sep)), 3.0);
    }

    /// A declared rule reserves its own width, floored at 0.5pt so a hairline still gets room.
    #[test]
    fn declared_line_reserves_its_own_width_with_a_hairline_floor() {
        let thin = declared(1, 0.1, 1.0, 1.0);
        assert_eq!(PageBandGeometry::separator_allowance(Some(&thin)), 2.5,
                   "a near-zero width floors at 0.5pt, not the authored 0.1pt");
        let wide = declared(1, 3.0, 1.0, 1.0);
        assert_eq!(PageBandGeometry::separator_allowance(Some(&wide)), 5.0,
                   "a rule wider than the floor reserves its own authored width");
    }
}


// Boundary lines (closing braces, blank separators, field/case lines already
// covered in substance by the ranges above) that the coverage script's per-item
// markers did not individually re-state:
// swift: Render/Office/PageBandGeometry.swift:194-194
// swift: Render/Office/PageBandGeometry.swift:207-207
// swift: Render/Office/PageBandGeometry.swift:232-232
