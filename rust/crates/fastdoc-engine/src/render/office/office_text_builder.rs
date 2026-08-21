//! swift: Render/Office/OfficeTextBuilder.swift
//! swift-range: 1-46

// swift: Render/Office/OfficeTextBuilder.swift:1
// (Swift `import AppKit` — every AppKit symbol below is a swiftshim stand-in per
// docs/plans/rust-port-convention.md §4's symbol-surface table.)

use std::collections::HashMap;

use swiftshim::{
    CGFloat, CGSize, NSAttributedString, NSAttributedStringKey, NSFont, NSFontDescriptor, NSImage,
    NSMutableAttributedString, NSMutableParagraphStyle, NSNumber, NSParagraphStyle, NSPoint,
    NSRange, NSRect, NSTextAlignment, NSTextAttachment, NSTextTab, NSUnderlineStyle,
    NSWritingDirection, SizedAttachmentCell, NS_NOT_FOUND, URL,
};

use crate::render::md_attr::MDAttr;
use crate::render::office::column_geometry::{ColumnGeometry, OfficeColumnLayout};
use crate::render::office::office_block::{
    Cell, LineBreakGranularity, LineHeight, ListNumbering, OfficeBlock, OfficeComment,
    OfficePageNumberRestart, ParagraphFormat, RectEdge, Span, TabAlignment, TabLeader, TabStop,
    TableFormat, UnderlineStyle,
};
use crate::render::render_theme::{OfficeStyle, Palette, RenderTheme};
use crate::render::table_block_builder::{AnchorSpan, CellContent, GridTextTable, TableBlockBuilder};

// swift: Render/Office/OfficeTextBuilder.swift:3-9
/// What a "fill to margin" paragraph (see `OfficeTextBuilder.fillMarginTabInfo`) needs to rebuild
/// its trailing tab at any width: the OTHER (non-margin) tab stops, preserved verbatim in their
/// own authored positions, plus the margin tab's own alignment/leader — never its `position`,
/// which is supplied fresh every time by `OfficeTextBuilder.fillMarginTabStops` (that's the whole
/// point of carrying this instead of just keeping the original `TabStop`). Carried as
/// `MDAttr.fillMarginTab`'s attribute value, so it rides along in the text storage from build
/// time through every later reflow.
#[derive(Debug, Clone, PartialEq)]
pub struct FillMarginTabInfo {
    pub margin_alignment: TabAlignment,
    pub margin_leader: TabLeader,
    pub other_tabs: Vec<TabStop>,
}

// swift: Render/Office/OfficeTextBuilder.swift:15-31
/// What an office graphic was AUTHORED as, carried as `MDAttr.officeGraphic`'s value so it rides in
/// the text storage from build time through every later reflow — the same trick `FillMarginTabInfo`
/// uses for a fill-to-margin tab, and for the same reason: the size a graphic should occupy is a
/// FUNCTION of the current reading column (`OfficeTextBuilder.graphicSize`), not a number to freeze
/// at whatever width the window happened to have when the document was built.
///
/// Without this, widening the window re-wrapped the text and re-solved every table to the new width
/// while the pictures stayed exactly as large as they were built — the document visibly came apart.
/// `placeholderLabel` is non-nil only for the chart/SmartArt frame, whose pixels are DRAWN at a
/// size (invariant 31) and so must be redrawn rather than merely re-bounded.
#[derive(Debug, Clone, PartialEq)]
pub struct OfficeGraphicInfo {
    pub authored: CGSize,
    pub placeholder_label: Option<String>,
    /// The DENOMINATOR this graphic's scale is measured against, in points: the source page's body
    /// width for a graphic in the text flow, or the source TABLE's own width for one inside a cell
    /// (see `TableFormat.sourceWidth` for why those differ). `nil` = unknown → no scaling, the
    /// authored size verbatim. Carried per graphic rather than looked up at reflow time so the
    /// reflow cannot pick a different basis than the build did.
    pub basis_width: Option<CGFloat>,
    /// The width this graphic is clamped to when it would otherwise overflow — its cell's content
    /// width inside a table, the reading column outside one. Recomputed at reflow (a cell's width
    /// changes with the window), so only the KIND of clamp is implied here, not a frozen number.
    pub is_inside_cell: bool,
}

impl Default for OfficeGraphicInfo {
    fn default() -> Self {
        Self {
            authored: CGSize::zero(),
            placeholder_label: None,
            basis_width: None,
            is_inside_cell: false,
        }
    }
}

// swift: Render/Office/OfficeTextBuilder.swift:33-47
/// Turns a format-neutral `[OfficeBlock]` into styled `NSAttributedString`, the same way
/// `MarkdownRenderer` turns a parsed markdown tree into one and `PlainTextRenderer` turns raw text
/// into one. Every TOP-LEVEL block is exactly one navigation stop: it gets its own `MDAttr.blockId`
/// over its full rendered range (content + its one trailing separator), so gutter click / block
/// edit work here for free once a later sprint wires this into the document — see invariant 1's
/// sibling rule for images: a reserved layout size must never depend on whether pixels are loaded.
///
/// swift: `enum OfficeTextBuilder` — a namespace of static functions, no instance. Mirrored here
/// as a zero-sized struct whose `impl` block carries every associated function 1:1.
pub struct OfficeTextBuilder;

impl OfficeTextBuilder {
    // Local convenience wrappers built on top of the shim's existing primitives — not new
    // shim surface (nothing here reaches past what `swiftshim` already exposes), just the
    // small pieces of NSString/NSAttributedString glue the Swift original leans on inline.

    /// swift: `result.string as NSString` — the text content as a UTF-16-indexed string, for the
    /// paragraph-boundary scans below.
    fn as_ns_string(result: &NSMutableAttributedString) -> swiftshim::SwiftString {
        swiftshim::SwiftString::new(result.string())
    }

    /// swift: `ns.enumerateSubstrings(in:options: .byParagraphs) { _, _, enclosing, _ in ... }` —
    /// walks `range` one paragraph (line, LF-terminated) at a time, handing the body the
    /// ENCLOSING range (content + its own terminator), exactly what `.byParagraphs` hands Swift's
    /// closure. Built on `SwiftString.getLineStart`, the shim's own line-boundary primitive.
    fn enumerate_paragraphs(ns: &swiftshim::SwiftString, range: NSRange, mut body: impl FnMut(NSRange)) {
        let mut loc = range.location;
        let limit = range.maxRange();
        while loc < limit {
            let mut line_end = 0usize;
            let mut contents_end = 0usize;
            ns.getLineStart(None, &mut line_end, &mut contents_end, NSRange::new(loc, 0));
            let enclosing_end = line_end.min(limit);
            if enclosing_end <= loc {
                break;
            }
            body(NSRange::new(loc, enclosing_end - loc));
            loc = enclosing_end;
        }
    }

    /// swift: `result.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle`
    fn paragraph_style_at(result: &NSMutableAttributedString, at: usize) -> Option<NSParagraphStyle> {
        match result.attribute(&NSAttributedStringKey::ParagraphStyle, at) {
            Some((swiftshim::AttrValue::ParagraphStyle(p), _)) => Some(p.clone()),
            _ => None,
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:48-118
    /// `columnWidth` is the text column's width in points at build time (what `presizeKnownMedia`
    /// calls `maxWidth` for markdown) — defaulted huge so callers that don't care about wrapping
    /// (every test but the scaling one) get the declared size back untouched. A real caller
    /// (`MarkdownDocument.render(into:)`) always passes the reader's actual column width: office
    /// image sizing is decided HERE, once, at build time — never at load time (see `appendImage`).
    ///
    /// `documentDefaultFontSize` is the SOURCE document's own default body run size, in points
    /// (docx `w:docDefaults/w:rPrDefault/w:rPr/w:sz`, HALF-points, converted by the reader; the
    /// OOXML default when a document states none at all is 11pt — the same default this parameter
    /// itself defaults to, so a caller that hasn't wired a reader-supplied value through yet still
    /// gets the standard behaviour). This is the OTHER half of the font-size model, alongside
    /// `Span.fontSize`: the document, as authored, is 100% — `theme.baseFontSize` (the reading
    /// document's own `readingSize`) is multiplied on top of it, as the RATIO
    /// `theme.baseFontSize / documentDefaultFontSize`. A run that names an explicit size (a 22
    /// half-point body run, a 32 half-point heading — `Span.fontSize` 11pt/16pt) is scaled by that
    /// ratio; a run that names none keeps whatever the surrounding block's OWN base font already is
    /// (`theme.headingFont(level:)`/`theme.bodyFont`), which is already sized off `theme.baseFontSize`
    /// with no further scaling. Two things this preserves, deliberately, the way Word itself does:
    /// a document's own internal relationships survive the user's reading-size setting (a heading
    /// stays proportionally larger than body text, an emphasised 14pt line stays larger than an
    /// 11pt paragraph, AT ANY reading size) — and the reading-size setting still governs how big
    /// the document looks overall, which is the entire point of that setting and must never be
    /// silently overridden by what the document happened to be authored at.
    /// `pageContentWidth` is the SOURCE document's own page body width in points, and it drives the
    /// SEPARATE scale for absolute-extent GRAPHICS — images and the chart/SmartArt placeholder —
    /// which is deliberately NOT `fontSizeScale`. A picture's authored size is a fraction of the PAGE
    /// it was drawn on, so the reader reproduces that fraction: the graphic scale is
    /// `readingColumn ÷ pageContentWidth`, which makes a graphic occupy the same share of the reading
    /// column that it occupied of the source page. A picture INSIDE A TABLE CELL divides by the
    /// table's own `TableFormat.sourceWidth` instead, because tables are stretched to fill the column
    /// (invariant 39) and a page-scaled picture would sit small inside a cell that grew around it.
    /// `nil` = the reader could not determine a page width → scale 1, authored sizes verbatim. Two
    /// consequences, both deliberate: a graphic grows and shrinks with the WINDOW at the document's
    /// own proportion, and it is UNTOUCHED by the reading-size setting — ⌘+/⌘− resizes text, never the
    /// pictures. Scaling graphics by `fontSizeScale` instead was tried and rejected twice: at 1.0 it
    /// left photographs tiny beside 1.6×-enlarged text (the document's own font↔image proportion
    /// broken), and riding the font scale made ⌘+ inflate photographs. Column-fitting still applies
    /// on top (`fittedOfficeSize`), so a scaled graphic can never overflow its column — or its cell —
    /// and because a page-proportional scale maps the page onto the column, a full-page-width image
    /// lands just inside it rather than being clamped.
    /// `comments` (P6b) is `officeComments` from `MarkdownDocument` — used ONLY to resolve each
    /// `Span.commentIds` entry to that comment's DISPLAY number (`OfficeComment.number`), via
    /// `commentNumbers` below, so `MDAttr.commentMark` carries the number a reader recognizes
    /// ("Comment 3") rather than the source's opaque id string. Threaded into headings/paragraphs/
    /// list items (where a comment's anchor overwhelmingly lands); table-cell content does not
    /// receive it — cells build through a separate, already-deep call chain
    /// (`appendTable`→`cellContent`) and a comment anchored inside a table cell is rare enough that
    /// widening that chain wasn't worth the added surface for this sprint.
    /// Indices (into `blocks`) of the tables big enough that building their grid is what makes a
    /// document freeze on open — the ONE place this line is drawn, so the render path and every test
    /// judge the same tables. `rows >= 50 AND rows × maxColumns >= 500`, measured over 1,280
    /// documents / 11,207 tables: it fires on 0.68% of tables and 1.4% of documents while removing
    /// 30.9% of all grid cells, and on ZERO of the reference manual's 388 tables. Both halves are
    /// load-bearing — row count alone catches a 103×2 prose table that costs nothing.
    /// See `docs/giant-table-deferral-design.md`.
    pub fn giant_table_indices(blocks: &[OfficeBlock]) -> std::collections::HashSet<usize> {
        let mut out = std::collections::HashSet::new();
        for (i, b) in blocks.iter().enumerate() {
            let OfficeBlock::Table { rows, .. } = b else { continue };
            let r = rows.len();
            if r < 50 {
                continue;
            }
            let cols = rows
                .iter()
                .map(|row| row.iter().map(|c| c.col_span as usize).sum::<usize>())
                .max()
                .unwrap_or(0);
            if r * cols >= 500 {
                out.insert(i);
            }
        }
        out
    }

    // swift: Render/Office/OfficeTextBuilder.swift:110-113
    /// The stand-in a deferred table leaves behind. Deliberately language-neutral — this app has no
    /// localisation table, and a word here would ship one language to all 23 stores. It is on screen
    /// for about a second, and only for a reader who scrolled ~121 screens down within that second.
    pub const DEFERRED_TABLE_STAND_IN: &'static str = "⋯";

    // swift: Render/Office/OfficeTextBuilder.swift:114-374
    /// `deferringTables` — indices whose `.table` is replaced by a one-paragraph stand-in carrying
    /// `MDAttr.deferredTable`, so `MarkdownDocument` can paint now and splice the grid in after
    /// (invariant 49's freeze, see `docs/giant-table-deferral-design.md`). EMPTY is the default and
    /// the identity: nothing about any other document changes, byte for byte (invariant 37).
    #[allow(clippy::too_many_arguments)]
    pub fn build(
        blocks: &[OfficeBlock],
        theme: &RenderTheme,
        column_width: CGFloat,
        document_default_font_size: CGFloat,
        page_content_width: Option<CGFloat>,
        page_margin_right: Option<CGFloat>,
        table_width: Option<CGFloat>,
        line_grid_pitch: Option<CGFloat>,
        comments: &[OfficeComment],
        deferring_tables: &std::collections::HashSet<usize>,
        section_start_blocks: &[usize],
        page_break_blocks: &[usize],
        keep_with_next_blocks: &[usize],
        hide_page_number_blocks: &[usize],
        page_number_restart_blocks: &[OfficePageNumberRestart],
        anchored_objects: &HashMap<usize, Vec<i64>>,
    ) -> NSAttributedString {
        let mut result = NSMutableAttributedString::new();
        let mut block_seq: i64 = 0;
        // Ordered-list numbering state, keyed by nesting level. Lives for the whole build() call
        // (not per-block) because the restart rule below needs to see across blocks.
        let mut ordered_counters: HashMap<i64, i64> = HashMap::new();
        let font_size_scale = if document_default_font_size > 0.0 {
            theme.base_font_size / document_default_font_size
        } else {
            1.0
        };
        // A graphic in the text flow is measured against the source PAGE; one inside a table is
        // measured against that TABLE (see `pageContentWidth`'s doc above and `appendTable`).
        let page_basis: Option<CGFloat> = page_content_width.filter(|w| *w > 0.0);
        // THE paged predicate, in one place, exactly as `DocumentWindowController.pagedWidth` states
        // it: a declared page body width is what makes a document paged, and every rule below that
        // says "the document wins" is gated on this and nothing else.
        let paged = page_basis.is_some();
        // How far a picture may run past the body before it is shrunk after all (`bleedAllowance`).
        let bleed = Self::bleed_allowance(paged, page_margin_right);
        let scale = |basis: Option<CGFloat>| -> CGFloat {
            match basis {
                Some(b) if b > 0.0 && column_width.is_finite() && column_width > 0.0 => {
                    column_width / b
                }
                _ => 1.0,
            }
        };
        // id → display number, built once per build() call (comments list is small; a dictionary
        // avoids an O(n) scan per span).
        let mut comment_numbers: HashMap<String, i64> = HashMap::new();
        for c in comments {
            comment_numbers.insert(c.id.to_string(), c.number);
        }

        // Block index → the section that starts there, so the marker is one dictionary lookup per
        // block rather than a search per section.
        let mut section_of_block: HashMap<usize, usize> = HashMap::new();
        for (section, first) in section_start_blocks.iter().enumerate() {
            section_of_block.insert(*first, section);
        }
        let breaks_page: std::collections::HashSet<usize> =
            page_break_blocks.iter().copied().collect();
        let keeps_with_next: std::collections::HashSet<usize> =
            keep_with_next_blocks.iter().copied().collect();
        let hides_page_number: std::collections::HashSet<usize> =
            hide_page_number_blocks.iter().copied().collect();
        let mut restarts_numbering: HashMap<usize, i64> = HashMap::new();
        for r in page_number_restart_blocks {
            // uniquingKeysWith: { first, _ in first } — the FIRST declaration for a block wins.
            restarts_numbering.entry(r.block as usize).or_insert(r.number);
        }

        // swift: Render/Office/OfficeTextBuilder.swift:174-215
        // `block_seq` is captured by mutable reference (not passed by value) — the Swift nested
        // function mutates the OUTER `blockSeq` directly, and the guard above the increment is the
        // whole point: a block whose range is empty returns before `blockSeq += 1` runs, so it never
        // consumes a sequence number. Passing `block_seq` by value here (as an earlier version of
        // this port did) cannot express that — the caller ends up incrementing unconditionally on
        // every iteration, including ones where this closure bailed out on the empty-range guard,
        // which drifts `MDAttr.blockId` away from the Swift assignment for every block after the
        // first one that builds to nothing.
        let mut tag_block = |result: &mut NSMutableAttributedString, start: usize, index: usize, block_seq: &mut i64| {
            let r = NSRange::new(start, result.length() - start);
            if r.length == 0 {
                return;
            }
            result.addAttribute(MDAttr::block_id(), swiftshim::AttrValue::Int(*block_seq), r);
            *block_seq += 1;
            // The section marker goes on the block that STARTS a section, over its whole range —
            // one attribute run per section, which is what a page lookup binary-searches. A section
            // whose first block builds to nothing carries no marker, exactly like `blockId`: an
            // empty run cannot be found by a character, so claiming one would be a lie about where
            // the section begins.
            if let Some(section) = section_of_block.get(&index) {
                result.addAttribute(MDAttr::section_index(), swiftshim::AttrValue::Int(*section as i64), r);
            }
            // The objects the document pinned to the paper AT this block. The block itself renders
            // as an empty paragraph (the reader took the object out of the flow), and that empty
            // paragraph's own newline is what carries the marker — an object with no range could
            // never be found by a page.
            if let Some(ids) = anchored_objects.get(&index) {
                result.addAttribute(MDAttr::anchored_objects(), swiftshim::AttrValue::Any(std::sync::Arc::new(ids.clone())), r);
            }
            // The document's own page break, marked on the block that starts the new page. A block
            // that builds to nothing carries no marker for the same reason the section one does not:
            // an empty run cannot be found by a line, so claiming one would put the break somewhere
            // layout can never see it.
            if breaks_page.contains(&index) {
                result.addAttribute(MDAttr::starts_page(), swiftshim::AttrValue::Bool(true), r);
            }
            if keeps_with_next.contains(&index) {
                result.addAttribute(MDAttr::keep_with_next(), swiftshim::AttrValue::Bool(true), r);
            }
            // The document's own veto against printing a page number on the page this block lands
            // on (HWP's PageHide). Marked the same way `startsPage` is — on the block's own range,
            // absent when it builds to nothing — because a page is resolved from where a marker
            // sits in the laid-out text, exactly as `sectionIndex` is.
            if hides_page_number.contains(&index) {
                result.addAttribute(MDAttr::hides_page_number(), swiftshim::AttrValue::Bool(true), r);
            }
            // Where the document restarts its page counter. Marked on the block's own range for the
            // same reason the veto above is: which PAGE it lands on is a layout answer, resolved
            // later from where the marked character actually sits.
            if let Some(first) = restarts_numbering.get(&index) {
                result.addAttribute(MDAttr::page_number_restart(), swiftshim::AttrValue::Int(*first), r);
            }
        };

        // A multi-column run is typeset at the COLUMN's width, not the page's — the line has to
        // break at the column edge before anything can move it there, and a table or an image
        // carries its own width and would otherwise stay page-wide inside a narrow column (244 of
        // the corpus's tables sit under a column declaration). Resolved for every block up front
        // because the declaration is a POSITION: what a block is typeset at depends on which
        // declaration is still in force above it.
        let block_column_widths = Self::column_width_per_block(blocks, column_width);
        let block_column_layouts = Self::column_layout_per_block(blocks);
        for (index, block) in blocks.iter().enumerate() {
            let start = result.length();
            let col_w = block_column_widths[index];
            // P2's `w:contextualSpacing` adjacency rule (spec area 5): suppress THIS paragraph's
            // spacing-before when the PREVIOUS block is the same style (its `ParagraphFormat` is
            // EQUAL — the vocabulary carries no style id, so equal resolved format is the proxy),
            // and symmetric for spacing-after against the NEXT block. Only ever narrows a format
            // (zeroes spacing that was otherwise set) — a block with no format at all (`nil`, every
            // non-paragraph-shaped case) is untouched, and a paragraph whose OWN contextualSpacing
            // is `false`/unset never has this rule applied regardless of its neighbours.
            let format = Self::contextual_spacing_adjusted_format(block, index, blocks);
            match block {
                OfficeBlock::Heading { level, spans, rtl, alignment, tab_stops, .. } => {
                    let heading_base = Self::heading_base_font(*level, theme, paged);
                    result.append(&Self::spans_attributed_string(
                        spans, &heading_base, &theme.text_color(), theme, font_size_scale, paged,
                        &comment_numbers,
                    ));
                    // Tagged BEFORE the trailing newline is appended, so a substring of this range is
                    // exactly the heading's text — precisely what the outline sidebar reads
                    // (`OutlinePanel.reload` trims and shows it verbatim).
                    result.addAttribute(
                        MDAttr::heading(),
                        swiftshim::AttrValue::Int(*level),
                        NSRange::new(start, result.length() - start),
                    );
                    result.append(&NSAttributedString::new("\n"));
                    let heading_range = NSRange::new(start, result.length() - start);
                    result.addAttribute(
                        NSAttributedStringKey::ParagraphStyle,
                        swiftshim::AttrValue::ParagraphStyle(Self::heading_paragraph_style(
                            *level, spans, theme, *rtl, alignment.clone(), tab_stops, format.clone(),
                            font_size_scale, paged, line_grid_pitch, col_w,
                        )),
                        heading_range,
                    );
                    if let Some(info) = Self::fill_margin_tab_info(tab_stops) {
                        result.addAttribute(MDAttr::fill_margin_tab(), swiftshim::AttrValue::Any(std::sync::Arc::new(info)), heading_range);
                    }
                }
                OfficeBlock::Paragraph { spans, rtl, alignment, tab_stops, .. } => {
                    result.append(&Self::spans_attributed_string(
                        spans, &theme.body_font(), &theme.text_color(), theme, font_size_scale, paged,
                        &comment_numbers,
                    ));
                    result.append(&NSAttributedString::new("\n"));
                    let paragraph_range = NSRange::new(start, result.length() - start);
                    result.addAttribute(
                        NSAttributedStringKey::ParagraphStyle,
                        swiftshim::AttrValue::ParagraphStyle(Self::body_paragraph_style(
                            theme, *rtl, alignment.clone(), tab_stops, format.clone(), font_size_scale,
                            paged, line_grid_pitch, col_w,
                        )),
                        paragraph_range,
                    );
                    if let Some(info) = Self::fill_margin_tab_info(tab_stops) {
                        result.addAttribute(MDAttr::fill_margin_tab(), swiftshim::AttrValue::Any(std::sync::Arc::new(info)), paragraph_range);
                    }
                    Self::mark_tab_leaders(tab_stops, paragraph_range, &mut result);
                }
                OfficeBlock::ListItem {
                    level, ordered, spans, marker, rtl, alignment, tab_stops, numbering, ..
                } => {
                    Self::append_list_item(
                        *level, *ordered, spans, marker.as_ref().map(|m| m.to_string()), *rtl, alignment.clone(), tab_stops,
                        &mut result, theme, &mut ordered_counters, font_size_scale, paged,
                        line_grid_pitch, format.clone(), &comment_numbers, numbering.clone(),
                    );
                }
                OfficeBlock::Table { .. } if deferring_tables.contains(&index) => {
                    // Holds this table's PLACE (and, via `tagBlock` below, its block id) so the splice
                    // that follows is a local replacement rather than a re-render. Styled as an ordinary
                    // body paragraph: it must not reserve the grid's eventual height, because the whole
                    // point is that this document is short until the grid arrives.
                    let mut stand_in = NSMutableAttributedString::fromString(
                        Self::DEFERRED_TABLE_STAND_IN.to_string() + "\n",
                    );
                    let whole = NSRange::new(0, stand_in.length());
                    stand_in.addAttribute(NSAttributedStringKey::Font, swiftshim::AttrValue::Font(theme.body_font()), whole);
                    stand_in.addAttribute(NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(theme.secondary_color()), whole);
                    stand_in.addAttribute(
                        NSAttributedStringKey::ParagraphStyle,
                        swiftshim::AttrValue::ParagraphStyle(Self::body_paragraph_style(
                            theme, false, None, &[], format.clone(), font_size_scale, paged,
                            line_grid_pitch, col_w,
                        )),
                        whole,
                    );
                    stand_in.addAttribute(MDAttr::deferred_table(), swiftshim::AttrValue::Int(index as i64), whole);
                    result.append(stand_in.asAttributedString());
                }
                OfficeBlock::Table { rows, header_rows, column_widths, format: table_format } => {
                    Self::append_table(
                        rows, *header_rows as usize, column_widths, table_format, &mut result, theme,
                        font_size_scale, col_w,
                        // A cell picture is measured against the table's own source width when the
                        // format stated one, else it falls back to the page — never left unscaled.
                        table_format.source_width.or(page_basis),
                        paged, line_grid_pitch, table_width,
                    );
                }
                OfficeBlock::Image { id, size, alignment } => {
                    Self::append_image(
                        id.to_string(), *size, col_w, page_basis, scale(page_basis), alignment.clone(),
                        false, bleed, &mut result,
                    );
                }
                OfficeBlock::UnsupportedGraphic { label, size, alignment } => {
                    Self::append_unsupported_graphic(
                        label.to_string(), *size, col_w, page_basis, scale(page_basis), alignment.clone(),
                        false, bleed, &mut result,
                    );
                }
                OfficeBlock::Formula { latex } => {
                    Self::append_formula(latex.to_string(), &mut result);
                }
            }
            // P2b — a heading/paragraph/list-item's own resolved shading/border (`format` is `nil`
            // for every other case, so this is a no-op there): tagged over the block's FULL rendered
            // range (content + its one trailing separator, same range `tagBlock` below tags), read
            // by `drawMDDecorations` at draw time — see `MDAttr.paraShading`'s own doc for why this
            // is build-time-only (nothing here recomputes geometry; the layout manager just paints a
            // rect over glyphs already laid out).
            if let Some(format) = &format {
                let range = NSRange::new(start, result.length() - start);
                if let Some(shading) = &format.shading {
                    result.addAttribute(MDAttr::para_shading(), swiftshim::AttrValue::Color(*shading), range);
                }
                // Presence is "either field resolved" — a source can legally set only `w:pBdr`'s
                // `@w:sz` (width) with `@w:color="auto"` (theme decides), or vice versa; the SAME
                // per-field fallback `TableBlockBuilder` already applies to `Cell.borderColor`/
                // `.borderWidth` (`Palette.tableBorder` / `1`pt) is mirrored here so a partially
                // resolved border still draws something rather than silently vanishing.
                if format.border_color.is_some() || format.border_width.is_some() {
                    let color = format.border_color.unwrap_or_else(Palette::table_border);
                    let width = format.border_width.unwrap_or(1.0);
                    result.addAttribute(MDAttr::para_border_color(), swiftshim::AttrValue::Color(color), range);
                    result.addAttribute(MDAttr::para_border_width(), swiftshim::AttrValue::Double(width), range);
                    // WHICH edges — empty means the reader said nothing per-edge, which is the
                    // whole box this drew before the set existed (every ODT paragraph, invariant 37).
                    let edges = if format.border_edges.raw_value == 0 { RectEdge::ALL } else { format.border_edges };
                    result.addAttribute(MDAttr::para_border_edges(), swiftshim::AttrValue::Double(edges.raw_value as f64), range);
                }
            }
            tag_block(&mut result, start, index, &mut block_seq);
        }
        Self::unify_paragraph_terminators(&mut result);
        result.into()
    }

    // swift: Render/Office/OfficeTextBuilder.swift:374-392
    /// Give every paragraph's terminating `"\n"` the attributes of the paragraph it ENDS.
    ///
    /// **A separator with no font is not a neutral character — AppKit gives it Helvetica 12pt**, the
    /// app's own default, so a font the document never mentions sits inside the document. Measured on
    /// a real 9pt Korean report: each of the bare `NSAttributedString(string: "\n")` appends above
    /// produced a `Helvetica@12` run. Laid-out height and page count are IDENTICAL either way
    /// (verified against a `--pdf` render before and after, and by measuring the document's used
    /// height with this pass removed) — this is hygiene and one fewer attribute run per paragraph,
    /// not a spacing change.
    ///
    /// This is invariant 51 at the TOP level. `TableBlockBuilder` unified the newline that ends a
    /// cell and `cellContent` the ones between a cell's own paragraphs; the document's own paragraph
    /// separators were the third case and were never covered. Same function, same ALLOW-list, so a
    /// separator next to an attachment/link/underline still falls back to exactly what it had.
    fn unify_paragraph_terminators(result: &mut NSMutableAttributedString) {
        if result.length() == 0 {
            return;
        }
        let ns = Self::as_ns_string(result);
        let mut paragraphs: Vec<NSRange> = Vec::new();
        Self::enumerate_paragraphs(&ns, NSRange::new(0, result.length()), |enclosing| {
            if enclosing.length > 0 {
                paragraphs.push(enclosing);
            }
        });
        for range in paragraphs {
            Self::unify_terminator(range, result, &ns);
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:392-401
    /// The `format` carried by a heading/paragraph/list-item block — `nil` for every other case
    /// (table/image/unsupportedGraphic/formula), which carries no `ParagraphFormat` at all.
    /// The width each block is typeset at, once the column declarations above it are taken into
    /// account.
    ///
    /// A declaration is carried on a RUN inside a paragraph (`Span.columnLayout`), so the state has
    /// to be rolled forward from the start of the document: a block is in whatever column layout the
    /// nearest declaration above it asked for, and a declaration of ONE column ends the run. The
    /// width returned is the first column's — every column of a run this reader lays out is typeset
    /// at the same width, and an unequal declaration's own widths are honoured when the columns are
    /// PLACED (`ColumnGeometry`), which is where the difference between them can actually be seen.
    // swift: Render/Office/OfficeTextBuilder.swift:402-416
    pub fn column_layout_per_block(blocks: &[OfficeBlock]) -> Vec<Option<OfficeColumnLayout>> {
        let mut out: Vec<Option<OfficeColumnLayout>> = vec![None; blocks.len()];
        let mut active: Option<OfficeColumnLayout> = None;
        for (i, block) in blocks.iter().enumerate() {
            // The declaration takes effect from the block it sits in, which is how a document that
            // opens in two columns gets two columns on its first paragraph rather than its second.
            if let Some(declared) = Self::declared_column_layout(block) {
                active = if declared.splits_text() { Some(declared) } else { None };
            }
            out[i] = active.clone();
        }
        out
    }

    // swift: Render/Office/OfficeTextBuilder.swift:417-427
    /// The width each block is typeset at, given the layout in force above it.
    pub fn column_width_per_block(blocks: &[OfficeBlock], body_width: CGFloat) -> Vec<CGFloat> {
        let layouts = Self::column_layout_per_block(blocks);
        layouts
            .into_iter()
            .map(|layout| {
                let Some(layout) = layout else { return body_width };
                if body_width >= CGFloat::MAX {
                    return body_width;
                }
                match ColumnGeometry::columns(body_width, &layout).first() {
                    Some(first) => first.width,
                    None => body_width,
                }
            })
            .collect()
    }

    // swift: Render/Office/OfficeTextBuilder.swift:428-438
    /// The column declaration this block carries, if any.
    fn declared_column_layout(block: &OfficeBlock) -> Option<OfficeColumnLayout> {
        match block {
            OfficeBlock::Paragraph { spans, .. } | OfficeBlock::Heading { spans, .. } => {
                spans.iter().find_map(|s| s.column_layout.clone())
            }
            OfficeBlock::ListItem { spans, .. } => spans.iter().find_map(|s| s.column_layout.clone()),
            _ => None,
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:439-450
    fn paragraph_format(block: &OfficeBlock) -> Option<ParagraphFormat> {
        match block {
            OfficeBlock::Heading { format, .. } => Some(format.clone()),
            OfficeBlock::Paragraph { format, .. } => Some(format.clone()),
            OfficeBlock::ListItem { format, .. } => Some(format.clone()),
            OfficeBlock::Table { .. }
            | OfficeBlock::Image { .. }
            | OfficeBlock::UnsupportedGraphic { .. }
            | OfficeBlock::Formula { .. } => None,
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:451-470
    /// `block`'s own resolved `ParagraphFormat`, with `spacingBefore`/`spacingAfter` zeroed when
    /// P2's `w:contextualSpacing` adjacency rule applies — see `build`'s call site doc. `nil` in,
    /// `nil` out (a block with no `ParagraphFormat` never gets one invented).
    fn contextual_spacing_adjusted_format(
        block: &OfficeBlock,
        index: usize,
        blocks: &[OfficeBlock],
    ) -> Option<ParagraphFormat> {
        let Some(resolved) = Self::paragraph_format(block) else { return None };
        if !resolved.contextual_spacing {
            return Some(resolved);
        }
        // Both neighbour comparisons are against `resolved` — the UNMUTATED format — so zeroing
        // `spacingBefore` for the "previous block matches" check can never change what the
        // "next block matches" check compares against (and vice versa).
        let mut adjusted = resolved.clone();
        if index > 0 && Self::paragraph_format(&blocks[index - 1]) == Some(resolved.clone()) {
            adjusted.spacing_before = Some(0.0);
        }
        if index + 1 < blocks.len() && Self::paragraph_format(&blocks[index + 1]) == Some(resolved.clone()) {
            adjusted.spacing_after = Some(0.0);
        }
        Some(adjusted)
    }

    // MARK: Spans → attributed runs

    // swift: Render/Office/OfficeTextBuilder.swift:471-489
    /// Renders one block's spans against that block's base font/color. A `code` span overrides
    /// BOTH with the theme's inline-code styling and tags `MDAttr.inlineCode` — bold/italic/
    /// underline still layer on top of it (an office run can be monospaced AND bold at once,
    /// unlike a markdown code span, which never carries emphasis).
    ///
    /// NOT private: a later sprint's RTF reader re-themes spans it parsed itself rather than
    /// receiving as `OfficeBlock`, and needs this exact styling logic rather than a duplicate.
    ///
    /// `fontSizeScale` is `theme.baseFontSize / documentDefaultFontSize` (see `build`'s doc comment
    /// for the model) — defaulted to `1` so every pre-sprint call site (this file's own cell/list
    /// helpers used to, and `OfficeTextBuilderTests`' direct calls still do, pass none) keeps
    /// meaning "don't rescale", i.e. `Span.fontSize` is already in the units the caller wants.
    /// `commentNumbers` (P6b) maps a comment's source id (`Span.commentIds` entries) to its DISPLAY
    /// number — see `build`'s doc. Defaults to empty so every pre-P6b call site (every test, and
    /// the table-cell chain — see `build`'s doc for why cells don't thread this) keeps compiling
    /// and behaving exactly as before: a span with no matching number gets no `MDAttr.commentMark`.
    /// `paged` (see `build`'s own `pageContentWidth`) governs ONE thing here: whether an authored
    /// point size is rounded to a whole point — see the `span.fontSize` branch below.
    // swift: Render/Office/OfficeTextBuilder.swift:468-709
    pub fn spans_attributed_string(
        spans: &[Span],
        base_font: &NSFont,
        base_color: &swiftshim::NSColor,
        theme: &RenderTheme,
        font_size_scale: CGFloat,
        paged: bool,
        comment_numbers: &HashMap<String, i64>,
    ) -> NSAttributedString {
        let mut out = NSMutableAttributedString::new();
        for span in spans {
            let mut font = base_font.clone();
            let mut color = base_color.clone();
            let mut attrs: HashMap<NSAttributedStringKey, swiftshim::AttrValue> = HashMap::new();
            // `caps` is a DISPLAY-only transform (see `Span.caps`'s doc) — computed on a local copy
            // of the run's text, never on `span` itself, so nothing downstream (undo, re-render,
            // the source model) ever sees an uppercased string that wasn't authored.
            let display_text = if span.caps { span.text.to_string().to_uppercase() } else { span.text.to_string() };
            if span.code {
                font = theme.code_font().clone();
                color = theme.inline_code_color().clone();
                attrs.insert(MDAttr::inline_code(), swiftshim::AttrValue::Bool(true));
            } else if let Some(name) = &span.font_name {
                // Family override — never applied to a `code` span (see `Span.fontName`'s doc).
                if let Some(named) = NSFont::named(&name.to_string(), font.pointSize()) {
                    font = named;
                }
            }
            // `resolvedFontDescriptor` (see its own doc) is `nil` for the overwhelming majority of
            // spans — the font just assigned above already covers every character, so this is a
            // no-op and the span renders byte-identically to before this field existed (invariant
            // 37). Where it is set, `NSFont(descriptor:size:)` — the SAME reconstruction idiom the
            // authored-size step just below and `fontAdding` already use for the theme's own private
            // system-UI faces — rebuilds the EXACT font `FontSubstitutionResolver` found at READ
            // time, so this performs ZERO coverage tests and ZERO CoreText calls on every ⌘+ press:
            // the decision was already made once, when the document was opened, and it cannot go
            // stale because its inputs (this document's own text and fonts) cannot change.
            //
            // `FontSubstitutionResolver.declaredFont` already unions the span's OWN bold/italic (and
            // the block's base weight — semibold for a heading) into the probe it hands CoreText, so
            // a resolved descriptor already IS the correctly-weighted/traited substitute — it must
            // not be re-traited here. Re-adding traits via `withSymbolicTraits` onto an already-
            // resolved PRIVATE system-UI substitute descriptor is not reliable: measured, re-adding
            // `.bold` on an already-`-SemiBold` Korean substitute produced a DIFFERENT face
            // (`.AppleKoreanFont-Bold`, not `-SemiBold`), and re-adding `[.bold, .italic]` on a
            // `-Regular` one silently no-opped. `hasResolvedSubstitute` gates the trait step below so
            // the untouched (`resolvedFontDescriptor == nil`) path — still the overwhelming majority
            // of spans — keeps applying bold/italic exactly as it always has.
            let has_resolved_substitute = span.resolved_font_descriptor.is_some();
            if let Some(resolved_descriptor) = &span.resolved_font_descriptor {
                if let Some(substituted) = NSFont::with_descriptor(resolved_descriptor, font.pointSize()) {
                    font = substituted;
                }
            }
            // An authored size REPLACES the block's base size before bold/italic/super-sub touch
            // it, so those still layer on top of the right starting point (traits preserve family,
            // not size; scaling preserves family, not traits — order doesn't matter between the
            // two, but both must happen before either reads `font.pointSize()` for anything else).
            //
            // The `.rounded()` is the NON-paged half of the model and belongs there: a run's size
            // has been multiplied by `fontSizeScale` (reading size ÷ the document's own default),
            // which turns the document's own tidy numbers into arbitrary fractions, and rounding
            // those back to whole points is what keeps a re-typeset document's sizes coalescing into
            // a small set of attribute runs. PAGED has neither the cause nor the licence: the scale
            // is exactly 1 there (`MarkdownDocument.render` builds the theme at the document's own
            // default body size), so the only thing rounding can do is DESTROY a size the author
            // stated. Word's `w:sz` is in HALF-points, so 10.5pt is an ordinary authored size, not an
            // exotic one — measured on one real report, 106 of its 617 runs declare a fractional
            // size, and every one of them was being drawn a half point too large or too small.
            if let Some(authored_size) = span.font_size {
                let scaled = authored_size * font_size_scale;
                let target = if paged { scaled } else { scaled.round() };
                if let Some(resized) = NSFont::with_descriptor(&font.fontDescriptor(), target.max(1.0)) {
                    font = resized;
                }
            }
            if !has_resolved_substitute {
                let mut traits = swiftshim::NSFontDescriptorSymbolicTraits::empty();
                if span.bold { traits.insert(swiftshim::NSFontDescriptorSymbolicTraits::bold); }
                if span.italic { traits.insert(swiftshim::NSFontDescriptorSymbolicTraits::italic); }
                if !traits.isEmpty() {
                    font = Self::font_adding(traits, &font);
                }
            }
            // Super/subscript shrink the font AND shift the baseline — `.superscript` alone isn't
            // interpreted by TextKit's own drawing, so it wouldn't actually render raised/lowered
            // here; a smaller font at an offset baseline is what makes it look right on screen.
            // `superscript`/`subscripted` are mutually exclusive in every real document, but if a
            // parser ever set both, superscript wins (checked first) rather than the two offsets
            // cancelling into something illegible.
            // The marker that cites a footnote is tagged where it is BUILT, because that is the only
            // moment the span model and the laid-out text are the same thing. Everything downstream
            // — which page the note lands on, how tall that page's band is — is found from where
            // this attribute ends up after layout (invariant 98).
            if let Some(reference) = &span.footnote_ref {
                attrs.insert(MDAttr::footnote_ref(), swiftshim::AttrValue::Int(*reference));
            }
            if let Some(cols) = &span.column_layout {
                attrs.insert(MDAttr::column_layout(), swiftshim::AttrValue::Any(std::sync::Arc::new(cols.clone())));
            }
            if span.superscript {
                let raised = font.pointSize() * 0.35;
                font = Self::font_scaled(&font, 0.7);
                attrs.insert(swiftshim::NSAttributedStringKey::Custom("baselineOffset".to_string()), swiftshim::AttrValue::Double(raised));
            } else if span.subscripted {
                let lowered = -font.pointSize() * 0.15;
                font = Self::font_scaled(&font, 0.7);
                attrs.insert(swiftshim::NSAttributedStringKey::Custom("baselineOffset".to_string()), swiftshim::AttrValue::Double(lowered));
            }
            // Authored colour is resolved against the theme, never applied raw — see
            // `resolvedTextColor`'s doc for the ordinary-ink-vs-marked-colour decision. Skipped for
            // a `code` span for the same reason `fontName` is: the inline-code look is one
            // consistent accent across the whole app, not something an individual run overrides.
            if let (Some(authored_color), false) = (&span.text_color, span.code) {
                color = Self::resolved_text_color(authored_color, theme);
            }
            // `smallCaps` (unlike `caps`) never touches `displayText` — it asks the FONT itself to
            // draw lowercase letters as small capitals, via the classic Apple `kLowerCaseType`/
            // `kLowerCaseSmallCapsSelector` font feature (present on macOS system fonts; a font
            // lacking the feature silently renders its ordinary lowercase glyphs instead — no
            // crash, just no small-caps look, the same graceful-degradation posture `fontName`'s
            // missing-family fallback already takes). Applied LAST, after every other font
            // transform above (code/family/size/bold-italic/super-sub), so the feature rides
            // whatever font those already produced rather than being clobbered by one of them.
            // Word's own precedence has `caps` win when both are set — `caps` already uppercased
            // `displayText` above, so this only visibly matters when `smallCaps` is set alone, but
            // it is harmless to also request the feature on an already-uppercased run (small-caps
            // has no effect on characters that are already capital).
            if span.small_caps {
                font = todo!("swift:602-607 kLowerCaseType/kLowerCaseSmallCapsSelector font-feature descriptor — needs NSFontDescriptor.FeatureKey shim");
            }
            attrs.insert(swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(font.clone()));
            attrs.insert(swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(color.clone()));
            // Always drawn exactly as authored — see `Span.highlightColor`'s doc for why a
            // highlight, unlike text colour, is never reinterpreted against the theme.
            if let Some(highlight) = &span.highlight_color {
                attrs.insert(swiftshim::NSAttributedStringKey::Custom("backgroundColor".to_string()), swiftshim::AttrValue::Color(highlight.clone()));
            }
            if span.underline {
                attrs.insert(
                    swiftshim::NSAttributedStringKey::UnderlineStyle,
                    swiftshim::AttrValue::Double(Self::ns_underline_style(span.underline_style).0 as f64),
                );
            }
            if span.strikethrough {
                attrs.insert(
                    swiftshim::NSAttributedStringKey::StrikethroughStyle,
                    swiftshim::AttrValue::Double(NSUnderlineStyle::single.0 as f64),
                );
            }
            // A decoration's OWN colour, when the document gave it one distinct from the text.
            // Set only alongside the decoration itself: AppKit draws neither from a colour alone,
            // and an underline colour on a run with no underline is a fact about nothing.
            if span.underline {
                if let Some(c) = &span.underline_color {
                    attrs.insert(swiftshim::NSAttributedStringKey::Custom("underlineColor".to_string()), swiftshim::AttrValue::Color(c.clone()));
                }
            }
            if span.strikethrough {
                if let Some(c) = &span.strikethrough_color {
                    attrs.insert(swiftshim::NSAttributedStringKey::Custom("strikethroughColor".to_string()), swiftshim::AttrValue::Color(c.clone()));
                }
            }
            // Letter spacing and baseline shift are stated as a share of the run's own em, so they
            // become points against the font this build actually resolved — which is what keeps
            // them proportional at every reading size, exactly like every other authored length.
            if let Some(pct) = span.letter_spacing_percent {
                if pct != 0.0 {
                    attrs.insert(swiftshim::NSAttributedStringKey::Custom("kern".to_string()), swiftshim::AttrValue::Double(font.pointSize() * pct / 100.0));
                }
            }
            if let Some(pct) = span.baseline_offset_percent {
                if pct != 0.0 {
                    attrs.insert(swiftshim::NSAttributedStringKey::Custom("baselineOffset".to_string()), swiftshim::AttrValue::Double(font.pointSize() * pct / 100.0));
                }
            }
            // Same colour/underline treatment `MarkdownRenderer.inlineFragment`'s `Markdown.Link`
            // case uses — a link must look and behave identically whether it arrived via markdown
            // or an office hyperlink, not grow a second visual style.
            // A PAGED document that stated a colour on the link keeps it — invariant 57, applied to
            // the one attribute the link branch below always overwrote. A printed manual that sets
            // its cross-references in black is not asking for the reader's blue.
            //
            // Only when the document SAID something, and this is the whole reason the rule is not
            // simply "the document always wins": Word's own blue-and-underlined hyperlink comes from
            // the `Hyperlink` CHARACTER style (`w:rPr/w:rStyle`), which this reader does not resolve
            // (see `DocxReader.resolvedRFonts`' note — measured at 0.23% of runs, deferred because it
            // moves size and font as well as colour). So an ordinary Word hyperlink arrives here with
            // NO authored colour at all, and handing it the body colour would make every link in
            // every document indistinguishable from the text around it — further from Word, not
            // closer. The theme's link colour stands in for the style we cannot yet read.
            //
            // The UNDERLINE is left forced for a different reason: `Span.underline` is a Bool with no
            // "unstated" value, so "the document turned underline off" and "the document said
            // nothing" arrive identically, and the three-state distinction invariant 47 needed for
            // borders does not exist here. Guessing wrong would silently drop the click affordance.
            let link_keeps_authored_colour = paged && span.text_color.is_some() && !span.code;
            if let Some(link) = span.link.as_ref().map(|l| l.to_string()) {
                if let Some(rest) = link.strip_prefix('#') {
                    // An in-document anchor (docx `w:anchor`, odt same-document `xlink:href`) —
                    // NEVER a `.link` URL built from the raw fragment. `MarkdownRenderer`'s own TOC
                    // links use the identical placeholder-URL-plus-`MDAttr.anchor` pair (see its
                    // `Markdown.Link` case) precisely so the click handler's `MDAttr.anchor` check
                    // catches this BEFORE it can ever reach the generic URL branch that treats a
                    // bare `#fragment` as a relative file path — that misread (clicking a
                    // cross-reference tries to open a file named after the bookmark) is the defect
                    // this exists to prevent, not a style nicety.
                    if !link_keeps_authored_colour {
                        attrs.insert(swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(theme.link_color().clone()));
                    }
                    attrs.insert(swiftshim::NSAttributedStringKey::UnderlineStyle, swiftshim::AttrValue::Double(NSUnderlineStyle::single.0 as f64));
                    attrs.insert(MDAttr::anchor(), swiftshim::AttrValue::Text(rest.to_string()));
                    // AttrValue has no Url variant (missing shim member); carried as Text(url.string) instead.
                    attrs.insert(swiftshim::NSAttributedStringKey::Link, swiftshim::AttrValue::Text(URL::fromString("fmdanchor:jump").unwrap().string));
                } else if let Some(url) = URL::fromString(&link) {
                    if !link_keeps_authored_colour {
                        attrs.insert(swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(theme.link_color().clone()));
                    }
                    attrs.insert(swiftshim::NSAttributedStringKey::UnderlineStyle, swiftshim::AttrValue::Double(NSUnderlineStyle::single.0 as f64));
                    // AttrValue has no Url variant (missing shim member); carried as Text(url.string) instead.
                    attrs.insert(swiftshim::NSAttributedStringKey::Link, swiftshim::AttrValue::Text(url.string));
                }
            }
            if !span.bookmarks.is_empty() {
                let names: Vec<String> = span.bookmarks.iter().map(|b| b.to_string()).collect();
                attrs.insert(MDAttr::bookmark_target(), swiftshim::AttrValue::Any(std::sync::Arc::new(names)));
            }
            // P6b: a span whose ids resolve to a known comment gets the DISPLAY number(s) tagged —
            // an id with no match (comments capture failed to find it, or a stale/dangling id) is
            // silently skipped rather than surfacing a "Comment ?" the reader can't act on.
            if !span.comment_ids.is_empty() {
                let numbers: Vec<i64> = span.comment_ids.iter().filter_map(|id| comment_numbers.get(&id.to_string()).copied()).collect();
                if !numbers.is_empty() {
                    attrs.insert(MDAttr::comment_mark(), swiftshim::AttrValue::Any(std::sync::Arc::new(numbers)));
                }
            }
            // header-footer-design.md §5 (build step 5): mark a PAGE/NUMPAGES run so a header/footer
            // draw pass can substitute the live value — see `MDAttr.pageNumberField`'s own doc for
            // why this never touches `displayText`/the span model itself (the cached text still
            // renders verbatim everywhere else, including `--extract`, which never reaches this
            // function at all — invariant 40's blocks→serializer path is entirely separate).
            if let Some(field) = &span.page_number_field {
                attrs.insert(MDAttr::page_number_field(), swiftshim::AttrValue::Any(std::sync::Arc::new(field.clone())));
            }
            // An explicitly-marked run (docx `w:rPr/w:rtl`) gets TextKit's own run-level embedding
            // override — the same mechanism a Unicode RLE/PDF control character would produce, just
            // stated declaratively instead of via invisible characters in the string. This is
            // independent of the paragraph's base direction (`OfficeBlock`'s `rtl`): a Latin phrase
            // embedded in an RTL paragraph never sets this, and a Hebrew phrase embedded in an LTR
            // one does — TextKit's bidi algorithm already reorders the two correctly around each
            // other once told which is which.
            // No dedicated `NSAttributedStringKey::WritingDirection` case (the shim only names the
            // stock keys `spansAttributedString`'s siblings already used, plus `Custom`) — carried
            // under a Custom key, same as AppKit's own real key is a string underneath. The AppKit
            // value is `[NSWritingDirection.rightToLeft.rawValue | NSWritingDirectionFormatType
            // .embedding.rawValue]`, an OptionSet-flavoured raw-value array this shim's plain
            // `NSWritingDirection`/`NSWritingDirectionFormatType` enums have no bits for — so the
            // pair of enum values rides through `Any` instead of a re-derived integer.
            if span.rtl {
                attrs.insert(
                    swiftshim::NSAttributedStringKey::Custom("writingDirection".to_string()),
                    swiftshim::AttrValue::Any(std::sync::Arc::new((
                        NSWritingDirection::RightToLeft,
                        swiftshim::NSWritingDirectionFormatType::Embedding,
                    ))),
                );
            }
            out.append(&NSAttributedString::with_attributes(display_text, attrs));
        }
        out.into()
    }

    // swift: Render/Office/OfficeTextBuilder.swift:710-734
    /// Maps `UnderlineStyle` (already-collapsed from docx `w:u/@w:val` — see that enum's doc) to
    /// the nearest `NSUnderlineStyle` AppKit actually draws. `.dashed`/`.dotted` have exact pattern
    /// equivalents; `.wavy` does not — `NSUnderlineStyle` has no wave pattern at all, so `.thick` is
    /// used as the nearest "this is not an ordinary underline" visual distinction AppKit offers
    /// (a plain `.single` would silently lose the fact the source asked for something unusual).
    fn ns_underline_style(style: UnderlineStyle) -> NSUnderlineStyle {
        match style {
            UnderlineStyle::Single => NSUnderlineStyle::single,
            UnderlineStyle::Double => NSUnderlineStyle::double,
            UnderlineStyle::Dotted => NSUnderlineStyle::patternDot,
            UnderlineStyle::Dashed => NSUnderlineStyle::patternDash,
            UnderlineStyle::Wavy => NSUnderlineStyle::thick,
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:735-745
    /// Decides whether an authored run colour survives into the current reading theme, or steps
    /// aside for the theme's own text colour. The judgement call the app makes: a NEAR-NEUTRAL
    /// authored colour (low saturation — almost always literal black, occasionally literal white)
    /// reads as "ORDINARY" — the author never meant to mark this text, they typed body copy under
    /// whatever their template's default run colour happened to be. Honouring that literally under
    /// the dark theme is exactly how ordinary text goes invisible (black-on-near-black); stepping
    /// aside for `theme.textColor` makes an authored-black run behave IDENTICALLY to a run that
    /// authored no colour at all, which is the only self-consistent reading of "ordinary" text.
    /// A genuinely COLOURFUL authored run (a red warning, a brand blue) has enough saturation to
    /// read as a DELIBERATE mark, and is drawn exactly as authored in both themes — losing that
    /// distinction would lose the meaning the colour exists to carry (a warning that silently
    /// becomes normal-coloured text is a warning nobody can see).
    ///
    /// `0.12` is a low bar deliberately: it only has to separate "grey/black/white" from "has a
    /// hue at all", not fine-tune how vivid a colour must be to count as a mark.
    pub fn resolved_text_color(authored: &swiftshim::NSColor, theme: &RenderTheme) -> swiftshim::NSColor {
        let Some(rgb) = authored.usingColorSpaceDeviceRGB() else { return theme.text_color().clone() };
        // swift: `rgb.getHue(_:saturation: &saturation, brightness: _, alpha: _)` — the shim has no
        // HSB conversion (`NSColor::get_hsba` is a missing member, reported to b-shim), so this
        // computes the same standard RGB→HSB saturation directly from the public RGB components.
        let (r, g, b) = (rgb.redComponent(), rgb.greenComponent(), rgb.blueComponent());
        let max = r.max(g).max(b);
        let min = r.min(g).min(b);
        let saturation = if max > 0.0 { (max - min) / max } else { 0.0 };
        if saturation < 0.12 { theme.text_color().clone() } else { authored.clone() }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:746-758
    /// Adds symbolic traits while keeping the SAME family, so vertical metrics (ascent/descent)
    /// don't shift — an unrelated bold face would jitter the baseline under a fixed line height
    /// (same reasoning as `MarkdownRenderer.fontAdding`, duplicated here: that one is private to
    /// its file).
    fn font_adding(traits: swiftshim::NSFontDescriptorSymbolicTraits, font: &NSFont) -> NSFont {
        let d = font.fontDescriptor().withSymbolicTraits(font.fontDescriptor().symbolicTraits().union(traits));
        NSFont::with_descriptor(&d, font.pointSize()).unwrap_or_else(|| font.clone())
    }

    // swift: Render/Office/OfficeTextBuilder.swift:753-756
    /// Same family, scaled point size — used for super/subscript, which shrink the glyph as well
    /// as shifting its baseline.
    fn font_scaled(font: &NSFont, factor: CGFloat) -> NSFont {
        NSFont::with_descriptor(&font.fontDescriptor(), (font.pointSize() * factor).round())
            .unwrap_or_else(|| font.clone())
    }

    // MARK: Paragraph styles

    // swift: Render/Office/OfficeTextBuilder.swift:759-770
    /// `rtl` sets `baseWritingDirection` ONLY when true — an LTR block (`rtl == false`, every
    /// existing call site before this sprint) leaves it at `NSMutableParagraphStyle()`'s own default
    /// (`.natural`), so a pre-sprint document's paragraph style is byte-identical to before.
    /// `alignment`, when supplied, ALWAYS wins over `rtl`'s implicit edge (see `OfficeBlock`'s doc
    /// on the two) — `nil` (every pre-sprint call site) leaves `.natural` exactly as `rtl` alone
    /// left it before this parameter existed. `tabStops` (points) are appended to whatever default
    /// tab stops `NSMutableParagraphStyle()` already carries; empty (every pre-sprint call site)
    /// changes nothing. Each authored stop's OWN alignment (P2b) is carried into the built
    /// `NSTextTab` — see `officeTextTab`'s doc for exactly how.
    /// `columnWidth` (same meaning as `build`'s own parameter) supplies the placeholder width for
    /// a fill-margin tab (see `fillMarginTabInfo`/`fillMarginTabStops`) — it is otherwise unused
    /// here, since every other tab stop renders exactly as it always has.
    // swift: Render/Office/OfficeTextBuilder.swift:771-849
    #[allow(clippy::too_many_arguments)]
    fn body_paragraph_style(
        theme: &RenderTheme,
        rtl: bool,
        alignment: Option<NSTextAlignment>,
        tab_stops: &[TabStop],
        format: Option<ParagraphFormat>,
        font_size_scale: CGFloat,
        paged: bool,
        line_grid_pitch: Option<CGFloat>,
        column_width: CGFloat,
    ) -> NSParagraphStyle {
        let mut p = NSMutableParagraphStyle::default();
        let lh = (theme.base_font_size * theme.line_height_ratio()).round();
        // The `base × lineHeightRatio` line height is a comfortable FLOOR, not a fixed cap. Pinning
        // `maximumLineHeight` to it clips any paragraph whose own font is TALLER than the floor —
        // and a large BODY paragraph is exactly that (an HWP title is a 32pt body paragraph, not a
        // `.heading`, so it hits this style and its glyphs overlapped at ~23pt). Cleared to 0 (no
        // cap), TextKit uses the natural line height once it EXCEEDS the floor, so a tall line grows.
        // Normal body (font ≤ base) is byte-identical: 16pt text's natural height is below the floor,
        // so the `minimumLineHeight` floor still governs. Explicit `.multiple`/`.exact`/`.atLeast`
        // line rules from the document (applyParagraphFormat, below) override this per their own contract.
        // PAGED: the app supplies NO rhythm of its own. A paragraph the document said nothing about
        // gets the font's natural line height and no trailing gap — which is what Word draws for the
        // same paragraph — instead of the reader's 1.45x line and 0.9x gap. Those two ratios are the
        // editorial rhythm this app applies to its OWN markdown, and carrying them onto a page we are
        // reproducing is exactly the "우리 자체 판단" the owner asked to be removed: "예전에는 자체
        // 비율로 보여지는거라 우리가 맘대로 줄간격 등을 조정했지만 이제는 아니야".
        // `applyParagraphFormat` below still applies every line rule and gap the document DID state.
        // PAGED + the section declares a LINE GRID: that pitch is the floor instead of "natural".
        // Word snaps a paragraph that states no spacing of its own onto the grid, and skipping it is
        // why a row Word draws at 18.48pt came out at 13.33pt here — the font's natural height, five
        // points short. `applyParagraphFormat` still overrides this for any paragraph that DID state
        // a rule, so the grid is a floor and never a cap. No grid → 0, i.e. exactly today.
        p.minimumLineHeight = if paged { line_grid_pitch.unwrap_or(0.0) } else { lh };
        p.maximumLineHeight = 0.0;
        p.paragraphSpacing = if paged { 0.0 } else { theme.base_font_size * theme.paragraph_spacing_ratio() };
        if rtl {
            p.baseWritingDirection = NSWritingDirection::RightToLeft;
        }
        if let Some(alignment) = alignment {
            p.alignment = alignment;
        }
        if !tab_stops.is_empty() {
            p.tabStops = Self::resolved_tab_stops(&tab_stops, column_width, paged);
        }
        // Body only: a `.multiple` line rule never renders below the readability floor (see
        // `OfficeStyle.bodyMinLineHeightRatio`). Headings pass none — they are effectively single-line
        // and carry their own comfortable `headingLineHeightRatio`.
        //
        // PAGED: both floors are switched OFF. Their entire justification (RenderTheme.swift:138-156)
        // is that a dense document rendering tighter than this reader's OWN markdown body "reads as a
        // defect" — a reader-first judgement that holds while office text is being re-typeset at the
        // READER's 16pt size, and stops holding the moment the reader is deliberately reproducing the
        // author's page. Measured on a typical Korean report at a 10pt document default they cost
        // +1pt on every line and +2pt on every paragraph gap, and because `cellContent` routes every
        // table cell through this same style they are paid again on every row of every table — half
        // of the "표가 너무 큼" the owner reported. The no-page-width fallback keeps them, because
        // there the old window-filling model (and its justification) is still what is running.
        let office_style = OfficeStyle { theme: *theme };
        Self::apply_paragraph_format(
            format.as_ref(),
            font_size_scale,
            if paged { 0.0 } else { theme.base_font_size * office_style.body_min_line_height_ratio() },
            if paged { 0.0 } else { theme.base_font_size * office_style.body_min_paragraph_spacing_ratio() },
            &mut p,
        );
        p
    }

    // swift: Render/Office/OfficeTextBuilder.swift:850-870
    /// The font a heading's spans START from. `RenderTheme.headingFont(level:)` is
    /// `.systemFont(weight: .semibold)`, so every office heading used to be drawn SEMIBOLD whatever
    /// its runs said — a weight the document never asked for, and one that on a Korean face is also
    /// WIDER, so a heading wrapped where the document's own weight would not have.
    ///
    /// PAGED drops the weight and keeps the size, letting `Span.bold` decide — which is only safe
    /// because `DocxReader` now resolves bold through the `w:basedOn` style chain
    /// (`resolvedBold`/`toggleState`). Before that it read only the run's DIRECT `w:rPr`, and a Word
    /// heading takes its bold from its STYLE: measured on two real reports, 39 of 39 and 38 of 38
    /// headings carried no run-bold at all while their `heading 1/2/3` styles declared `<w:b/>`, so
    /// this same change would have un-bolded every one of them. ODT and HWP already carried a
    /// resolved weight.
    ///
    /// The size is taken from the theme's own heading font rather than recomputed, so this stays
    /// correct if the app's heading ladder changes or is removed — it only ever REMOVES the weight.
    ///
    /// One honest limit: a span that needed font SUBSTITUTION carries a descriptor
    /// `FontSubstitutionResolver` resolved at READ time against `blockWeight: .semibold`, and
    /// `spansAttributedString` uses such a descriptor verbatim (re-traiting a resolved private
    /// system-UI descriptor is measured-unreliable — see its own comment). So a substituted heading
    /// run still draws semibold. That is the majority-inert case, not the common one: a
    /// `resolvedFontDescriptor` is nil for the overwhelming majority of spans.
    fn heading_base_font(level: i64, theme: &RenderTheme, paged: bool) -> NSFont {
        let themed = theme.heading_font(level as i32);
        if !paged {
            return themed;
        }
        // PAGED: no ladder and no weight of our own. The owner's rule, verbatim — "그냥 우리 자체
        // 판단을 버리고, 파싱하는 정보 그대로 다 보여지게 하자 (정의되지 않은 값들만 디폴트를 뭘로
        // 지정할지만 옵션)" — leaves exactly one decision here, WHICH default an unstated heading
        // size takes, and the honest answer is the document's own default body size. That is also
        // what Word draws: measured on the file this came from, its `heading 1` style declares 12pt
        // while `heading 3/4/5` declare no size at all, so Word renders those at the document
        // default — where the ladder drew them at 12 x 1.875 = 22.5 and 12 x 1.25 = 15. That gap is
        // the "폰트가 과도하게 큼" reported after comparing us against Word and Pages.
        //
        // A heading whose runs DO state a size is unaffected: `spansAttributedString` replaces this
        // base with the authored size either way.
        NSFont::systemFont(theme.base_font_size)
    }

    // swift: Render/Office/OfficeTextBuilder.swift:871-881
    /// The size a heading's own RUNS state, in points, already through `fontSizeScale` — `nil` when
    /// none of them state one, which is the case `RenderTheme.headingSize(level:)` exists for. The
    /// LARGEST is taken: this feeds a line-height FLOOR, and a floor derived from the smallest run
    /// of a mixed-size heading would sit under its tallest glyphs.
    fn heading_own_size(spans: &[Span], font_size_scale: CGFloat) -> Option<CGFloat> {
        let largest = spans.iter().filter_map(|s| s.font_size).fold(None, |acc: Option<CGFloat>, v| {
            Some(acc.map_or(v, |a| a.max(v)))
        })?;
        Some(largest * font_size_scale)
    }

    // swift: Render/Office/OfficeTextBuilder.swift:882-939
    /// The line-height FLOOR is derived from the heading's OWN spans, and this function takes them
    /// rather than a precomputed basis ON PURPOSE. It was a `lineHeightBasis: CGFloat?` parameter
    /// first, and that shape lost the rule twice in one afternoon: a caller that reshapes this call
    /// (and both callers were reshaped) writes `nil` for it without anything failing to compile, and
    /// the floor silently falls back to the ladder. Passing the spans makes the rule impossible to
    /// drop by editing a call site — the decision lives here, with the arithmetic it feeds.
    #[allow(clippy::too_many_arguments)]
    fn heading_paragraph_style(
        level: i64,
        spans: &[Span],
        theme: &RenderTheme,
        rtl: bool,
        alignment: Option<NSTextAlignment>,
        tab_stops: &[TabStop],
        format: Option<ParagraphFormat>,
        font_size_scale: CGFloat,
        paged: bool,
        line_grid_pitch: Option<CGFloat>,
        column_width: CGFloat,
    ) -> NSParagraphStyle {
        let b = theme.base_font_size;
        let style = OfficeStyle { theme: *theme };
        let mut p = NSMutableParagraphStyle::default();
        // The floor is a ratio of the heading's OWN size wherever the document stated one (paged) —
        // not of `theme.headingSize(level:)`, which is the app's ladder over the document's default
        // body size and has nothing to do with what this heading was authored at. Concretely, an
        // 11pt-default report whose H1 runs declare 19pt got a floor of 11 × 1.875 × 1.25 = 26pt
        // under a 19pt line: a heading held apart from its own text by 7pt of invented leading.
        // Where the runs state NOTHING the ladder is still the only size there is, so the basis
        // falls back to it — and so does every NON-paged call, byte-identically to before this.
        // Paged: the floor follows the heading's own stated size, and where it states none it follows
        // the size the heading is ACTUALLY drawn at — the document's default body size, since the
        // ladder is gone (see `headingBaseFont`). Unpaged keeps the ladder, unchanged.
        let basis = if paged {
            Self::heading_own_size(spans, font_size_scale).unwrap_or(theme.base_font_size)
        } else {
            theme.heading_size(level as i32)
        };
        let lh = (basis * theme.heading_line_height_ratio()).round();
        p.minimumLineHeight = lh;
        // Cleared for the SAME reason the body path was (see `bodyParagraphStyle`, and the comment
        // there naming a 32pt HWP title whose glyphs overlapped at ~23pt): a cap derived from the
        // app's own heading scale CLIPS a heading the document made larger than that scale. The
        // heading path was missed when body was fixed, and the paged model made it bite: the cap now
        // shrinks with the document's own base (11pt → H1 cap 26) while the run's size is taken
        // verbatim, so an ordinary 22–28pt Word/HWP title is cut. A floor still governs anything
        // shorter, and an explicit line rule from the document still overrides both.
        p.maximumLineHeight = 0.0;
        // Paged: no invented space around a heading either. `applyParagraphFormat` below still
        // applies whatever the document's own `spacingBefore`/`spacingAfter` resolved to, so a
        // document that asked for room gets exactly the room it asked for — and one that asked for
        // none gets none, instead of the app's 1.9x/0.4x editorial rhythm on top.
        p.paragraphSpacing = if paged { 0.0 } else { b * theme.heading_spacing_after_ratio() };
        p.paragraphSpacingBefore = if paged { 0.0 } else { style.heading_spacing_before(level as i32) };
        if rtl {
            p.baseWritingDirection = NSWritingDirection::RightToLeft;
        }
        if let Some(alignment) = alignment {
            p.alignment = alignment;
        }
        if !tab_stops.is_empty() {
            p.tabStops = Self::resolved_tab_stops(&tab_stops, column_width, paged);
        }
        Self::apply_paragraph_format(format.as_ref(), font_size_scale, 0.0, 0.0, &mut p);
        p
    }

    // swift: Render/Office/OfficeTextBuilder.swift:940-973
    /// Turns a paragraph's authored `tabStops` into `NSTextTab`s for build time ONLY — an ordinary
    /// paragraph (no fill-margin tab, `fillMarginTabInfo` returns nil) maps every stop straight
    /// through via `officeTextTab`, byte-identical to before this attribute existed. A fill-margin
    /// paragraph instead gets `fillMarginTabStops` at a PLACEHOLDER width: the real `columnWidth`
    /// minus `fillMarginTrailingInset` when the caller supplied one (every real render call —
    /// `MarkdownDocument.render(into:)` always does), or the tab's own authored `position`
    /// otherwise (every test/cell-content call site that builds with the default sentinel column,
    /// where "no reflow will ever correct this" makes the original position the honest answer).
    /// Either way this is only ever a STARTING point — `DocumentWindowController.updateTextInset`
    /// re-anchors it to the actual reading column on first layout and every reflow after.
    fn resolved_tab_stops(tab_stops: &[TabStop], column_width: CGFloat, paged: bool) -> Vec<NSTextTab> {
        // PAGED: the authored position is kept, full stop. This whole mechanism exists to correct a
        // MISMATCH between the source page's width and this reader's window-sized column (see
        // `MDAttr.fillMarginTab`), and a paged document has no mismatch — the column IS the page
        // body, so the position the author wrote is already the position it should be drawn at.
        // Rebuilding it anyway does pure damage twice over: a TOC page number lands
        // `fillMarginTrailingInset` (12pt) left of where the author put it and stays there for good
        // (`DocumentWindowController.updateTextInset` skips `reanchorFillMarginTabs` when paged), and
        // a right tab the author placed MID-column — at 200pt in a 451pt page, an ordinary two-column
        // header — is yanked out to 439pt, because `fillMarginTabInfo` picks the RIGHTMOST right tab
        // with no proximity test at all and this branch then discards its position outright.
        if paged {
            return tab_stops.iter().map(Self::office_text_tab).collect();
        }
        let Some(info) = Self::fill_margin_tab_info(tab_stops) else {
            return tab_stops.iter().map(Self::office_text_tab).collect();
        };
        let has_real_column = column_width < CGFloat::MAX;
        let width = if has_real_column {
            (column_width - Self::FILL_MARGIN_TRAILING_INSET).max(0.0)
        } else {
            tab_stops.iter().map(|t| t.position).fold(None, |acc: Option<CGFloat>, v| {
                Some(acc.map_or(v, |a| a.max(v)))
            }).unwrap_or(0.0)
        };
        Self::fill_margin_tab_stops(&info, width)
    }

    // swift: Render/Office/OfficeTextBuilder.swift:961-973
    /// Trailing gap (points) between a fill-margin tab (a TOC page number, say) and the reading
    /// column's own right edge — small enough the number still reads flush-right, not crowded
    /// against the very edge. Shared with `DocumentWindowController.updateTextInset`, which
    /// re-anchors this tab to the CURRENT column on every reflow (see `MDAttr.fillMarginTab`).
    /// Must clear the text container's default lineFragmentPadding (5pt) plus the right-tab rounding
    /// slack, or a right-aligned tab placed a hair OUTSIDE the wrap boundary pushes its number onto a
    /// second line — the "number on an extra line" regression. The wrap threshold was MEASURED at ~9pt
    /// (8pt wraps, 10pt holds, `lineFragmentPadding` 5); 12pt sits comfortably above it while reading
    /// flush-right — the page number lands ~16pt in from the edge, not the 28pt a larger safety margin
    /// once cost. Larger is safe but visibly not flush; smaller risks the wrap.
    pub const FILL_MARGIN_TRAILING_INSET: CGFloat = 12.0;

    // swift: Render/Office/OfficeTextBuilder.swift:974-984
    /// The rightmost tab in `tabStops`, when it is right- or decimal-aligned, marks the paragraph
    /// as "fill to margin": a right tab exists to push text — a TOC page number, a right-aligned
    /// header — out to the paragraph's own trailing edge, and that edge was authored against the
    /// SOURCE document's page margin, not this reader's window-width reading column (see
    /// `MDAttr.fillMarginTab`'s doc for the width mismatch this exists to correct). A LEFT- or
    /// CENTER-aligned rightmost tab is an ordinary tab stop and is left alone (returns `nil`) —
    /// this only ever narrows behaviour onto paragraphs that authored a real trailing right/
    /// decimal tab; every other paragraph (the overwhelming common case, and every markdown/
    /// plain-text block, which carries no tab-stop vocabulary at all) is unaffected.
    // swift: Render/Office/OfficeTextBuilder.swift:985-1001
    pub fn fill_margin_tab_info(tab_stops: &[TabStop]) -> Option<FillMarginTabInfo> {
        let (i, rightmost) = tab_stops
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.position.partial_cmp(&b.1.position).unwrap())?;
        if !(rightmost.alignment == TabAlignment::Right || rightmost.alignment == TabAlignment::Decimal) {
            return None;
        }
        let mut others = tab_stops.to_vec();
        others.remove(i);
        Some(FillMarginTabInfo {
            margin_alignment: rightmost.alignment,
            margin_leader: rightmost.leader,
            other_tabs: others,
        })
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1002-1009
    /// Rebuilds tab stops so the fill-margin tab sits at `width` — an absolute point, already the
    /// caller's chosen right edge (minus whatever inset it wants) — while every OTHER authored tab
    /// stop keeps its own original position. This is the ONE place that turns `FillMarginTabInfo`
    /// back into real `NSTextTab`s, called both at build time (`resolvedTabStops`, a placeholder
    /// width) and on every later reflow (`DocumentWindowController.reanchorFillMarginTabs`, the
    /// reading column's CURRENT width) — so a TOC's page numbers track the window instead of
    /// staying pinned to the document's own page margin.
    pub fn fill_margin_tab_stops(info: &FillMarginTabInfo, width: CGFloat) -> Vec<NSTextTab> {
        let margin = TabStop { position: width, alignment: info.margin_alignment, leader: info.margin_leader };
        let mut all: Vec<TabStop> = info.other_tabs.clone();
        all.push(margin);
        all.iter().map(Self::office_text_tab).collect()
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1010-1028
    /// Builds ONE `NSTextTab` from an authored `TabStop` — `.left`/`.center`/`.right` map straight
    /// onto `NSTextAlignment`'s own cases (Apple's modern, non-deprecated `NSTextTab` initializer
    /// is ALREADY alignment-based, so this is a direct translation, not an emulation). `.decimal`
    /// has no `NSTextAlignment` case at all (the deprecated `NSTextTab(type:location:)`/
    /// `.decimalTabStopType` initializer is the only API that names one, and this codebase avoids
    /// deprecated AppKit surface) — the documented, still-current replacement (the header comment
    /// on `NSTextTab`'s alignment initializer) is `.right` alignment plus a column terminator
    /// character set: text runs up TO the tab stop right-aligned, then a further terminator
    /// (the decimal point) ends that column, which is what actually makes a `12.5` and a `100.25`
    /// line their decimal points up under this stop — the same visible effect `.decimal` names.
    /// `leader` is READ but never turned into a drawing instruction here — see `TabLeader`'s own
    /// doc for why (no native AppKit primitive, and a faithful fill is a deferred rendering cost).
    /// Marks every TAB character in `range` with the leader the document asked a tab to fill with —
    /// the `······` between a contents entry and its page number. Drawn by `drawMDDecorations`;
    /// `NSTextTab` carries no leader of its own, so this attribute is the only way the information
    /// survives to draw time.
    ///
    /// ONE leader per paragraph, taken from the LAST stop that declares one: which stop a given tab
    /// actually lands on is a layout answer, not a build-time one, and a contents line has exactly
    /// one leader tab — the trailing right-aligned stop that carries the page number. A paragraph
    /// whose stops declare no leader is untouched, which is every markdown, plain-text and ODT
    /// paragraph and most docx ones (invariant 37).
    // swift: Render/Office/OfficeTextBuilder.swift:1029-1043
    fn mark_tab_leaders(tab_stops: &[TabStop], range: NSRange, result: &mut NSMutableAttributedString) {
        let Some(leader) = tab_stops.iter().rev().find(|t| t.leader != TabLeader::None).map(|t| t.leader) else {
            return;
        };
        let Some(character) = Self::leader_character(leader) else { return };
        let text = Self::as_ns_string(result);
        let mut index = range.location;
        while index < range.maxRange() {
            let found = text.range_of("\t", NSRange::new(index, range.maxRange() - index));
            if found.location == NS_NOT_FOUND {
                break;
            }
            result.addAttribute(MDAttr::tab_leader(), swiftshim::AttrValue::Text(character.to_string()), found);
            index = found.maxRange();
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1044-1052
    /// The character a `TabLeader` fills with. `.none` has none, which is why this is optional.
    pub fn leader_character(leader: TabLeader) -> Option<&'static str> {
        match leader {
            TabLeader::None => None,
            TabLeader::Dot => Some("."),
            TabLeader::Hyphen => Some("-"),
            TabLeader::Underscore => Some("_"),
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1053-1063
    fn office_text_tab(stop: &TabStop) -> NSTextTab {
        match stop.alignment {
            TabAlignment::Left => NSTextTab::new(NSTextAlignment::Left, stop.position, HashMap::new()),
            TabAlignment::Center => NSTextTab::new(NSTextAlignment::Center, stop.position, HashMap::new()),
            TabAlignment::Right => NSTextTab::new(NSTextAlignment::Right, stop.position, HashMap::new()),
            // BLOCKED on missing shim capability: real AppKit sets `.tabColumnTerminators` to a
            // `CharacterSet(charactersIn: ".")` here, but `NSTextTabOptions` (this shim's stand-in
            // for `NSTextTab.OptionKey`) is a `HashMap<String, f64>` — there is no way to carry a
            // character set through it. Falls back to a plain right-aligned tab (no decimal
            // terminator) until the shim grows a real options type. Reported to b-shim.
            TabAlignment::Decimal => NSTextTab::new(NSTextAlignment::Right, stop.position, HashMap::new()),
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1064-1076
    /// Applies the P2 cascade's resolved `ParagraphFormat` on top of whatever theme-token defaults
    /// the caller already set on `p` — per-field, only when the source specified that field (`nil`
    /// leaves the token value exactly as it was, which is what makes a paragraph with an entirely
    /// unspecified cascade render byte-identical to the pre-P2 token path). Order matters: this
    /// runs AFTER the caller's own token defaults, since `lineRule="atLeast"` must explicitly clear
    /// the `maximumLineHeight` cap those defaults set (a plain unset would leave the old cap active,
    /// silently reintroducing the very clipping `atLeast` exists to prevent).
    ///
    /// `fontSizeScale` is `theme.baseFontSize / documentDefaultFontSize` (see `build`'s doc) — every
    /// POINT value the source declared is scaled by it, exactly like `Span.fontSize`, so a
    /// document's own spacing/indent stays proportional at any reading-size setting.
    /// `lineHeightMultiple` is NOT scaled — `LineHeight.multiple` is already a unitless ratio
    /// (`w:lineRule="auto"`'s `line/240`), not a point value.
    // swift: Render/Office/OfficeTextBuilder.swift:1077-1114
    fn apply_paragraph_format(
        format: Option<&ParagraphFormat>,
        font_size_scale: CGFloat,
        min_line_height: CGFloat,
        min_paragraph_spacing: CGFloat,
        p: &mut NSMutableParagraphStyle,
    ) {
        let Some(format) = format else { return };
        if let Some(before) = format.spacing_before {
            p.paragraphSpacingBefore = before * font_size_scale;
        }
        if let Some(after) = format.spacing_after {
            // A POSITIVE author gap never drops below the readability floor (see
            // `OfficeStyle.bodyMinParagraphSpacingRatio`); an EXACTLY-zero gap (a deliberate
            // "no space", incl. `contextualSpacing`'s zeroing) stays zero, the floor not applied.
            let scaled = after * font_size_scale;
            p.paragraphSpacing = if scaled > 0.0 { scaled.max(min_paragraph_spacing) } else { scaled };
        }
        if let Some(line_height) = &format.line_height {
            match line_height {
                LineHeight::Multiple(ratio) => {
                    p.lineHeightMultiple = *ratio;
                    // Clear the caller's token min/max the SAME way `.atLeast` does below: the token
                    // default set `minimumLineHeight == maximumLineHeight == lh` (a FIXED line height),
                    // and a live `maximumLineHeight` cap clamps `naturalHeight * ratio` back down to
                    // `lh` — silently squeezing a document that asked for e.g. `w:line="260"` (1.083×)
                    // into the app's own tighter fixed rhythm. That was the "줄간격이 너무 타이트" bug:
                    // the multiple was set but never allowed to take effect. A multiple is a ratio of the
                    // line's own natural height, so it governs upward freely — the maximum is cleared so
                    // a document that asks for MORE than the floor gets exactly that. The minimum is the
                    // readability FLOOR (`OfficeStyle.bodyMinLineHeightRatio`, 0 for callers that pass
                    // none): a near-single rule measured against the substituted body font renders far
                    // tighter than the same reader's markdown body, so office body never drops below it.
                    p.minimumLineHeight = min_line_height;
                    p.maximumLineHeight = 0.0;
                }
                LineHeight::Exact(pt) => {
                    let v = pt * font_size_scale;
                    p.minimumLineHeight = v;
                    p.maximumLineHeight = v;
                }
                LineHeight::AtLeast(pt) => {
                    p.minimumLineHeight = pt * font_size_scale;
                    p.maximumLineHeight = 0.0; // a floor, not a cap — clears the token's own maximum.
                }
            }
        }
        if format.indent_start.is_some() || format.indent_end.is_some() || format.first_line_indent.is_some()
            || format.hanging_indent.is_some()
        {
            // `NSParagraphStyle.headIndent`/`firstLineHeadIndent` per the spec's own mapping (area
            // 5): unspecified components read as 0, so a level that sets ONLY `spacingBefore`
            // (say) never reaches this block at all, and a level that sets exactly one indent
            // component still combines correctly with the other three at their neutral value.
            let start = format.indent_start.unwrap_or(0.0) * font_size_scale;
            let first_line = format.first_line_indent.unwrap_or(0.0) * font_size_scale;
            let hanging = format.hanging_indent.unwrap_or(0.0) * font_size_scale;
            p.headIndent = start;
            p.firstLineHeadIndent = start + first_line - hanging;
            if let Some(end) = format.indent_end {
                // AppKit's own convention (already used by the markdown code-card header/footer,
                // `MarkdownRenderer.swift`'s `tailIndent = -CodeCardMetrics.textInset`): a positive
                // `tailIndent` measures from the LEFT margin, so the OOXML "distance from the right
                // edge" must be negated to land in the same place.
                p.tailIndent = -(end * font_size_scale);
            }
        }
        Self::apply_line_breaking(format, p);
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1115-1146
    /// Where the document says a line may be broken — the one half of HWP's five line-fitting bits
    /// that real documents actually use, and the only one this builder honours.
    ///
    /// Measured over 1,589 real HWP/HWPX files (454,134 paragraphs, `HwpLineBreakProbeTests`):
    ///
    /// | declaration | paragraphs | documents |
    /// |---|---|---|
    /// | Hangul broken between CHARACTERS | 287,367 (63%) | 1,489 of 1,589 |
    /// | Hangul broken between WORDS | 164,928 (36%) | — |
    /// | Latin broken other than between words | 394 (0.09%) | 49 |
    /// | auto-space at a Hangul/Latin or Hangul/digit seam | 3,366 (0.7%) | 82 |
    /// | line height taken from the font's metrics | 59 (0.013%) | 9 |
    ///
    /// So the Hangul bit is not a curiosity — two thirds of every Korean paragraph on this machine
    /// sets it, and getting it wrong changes how many characters fit on a line, which is a page
    /// count. The bottom two rows are why the other three fields are decoded and NOT honoured: both
    /// would cost every paragraph of every document something (an attribute run at every script
    /// seam, a second line-height basis) to serve well under one paragraph in a hundred. They are
    /// carried in `ParagraphFormat` so the next reader of this code can see they were measured
    /// rather than missed.
    ///
    /// `.hyphen` deliberately behaves as `.word`: a hyphen already IS a break opportunity in
    /// standard line breaking, so TextKit gives HWP's middle setting without being asked.
    // swift: Render/Office/OfficeTextBuilder.swift:1147-1166
    fn apply_line_breaking(format: &ParagraphFormat, p: &mut NSMutableParagraphStyle) {
        match format.east_asian_line_break {
            Some(LineBreakGranularity::Word) => {
                // The Korean-aware strategy: prefer a word boundary, and only fall inside a word when
                // nothing else fits. This is what a document means by 어절 단위.
                p.lineBreakStrategy.insert(swiftshim::NSLineBreakStrategy::hangulWordPriority);
            }
            Some(LineBreakGranularity::Character) => {
                // 글자 단위 — fill the line and break wherever it runs out, which is what AppKit does
                // for CJK with no strategy set. Removing the flag rather than clearing the whole set
                // leaves any other strategy (`.pushOut`) the caller chose alone.
                p.lineBreakStrategy.remove(swiftshim::NSLineBreakStrategy::hangulWordPriority);
            }
            Some(LineBreakGranularity::Hyphen) | None => {}
        }
        if format.latin_line_break == Some(LineBreakGranularity::Character) {
            p.lineBreakMode = swiftshim::NSLineBreakMode::ByCharWrapping;
        }
    }

    // MARK: Lists

    // swift: Render/Office/OfficeTextBuilder.swift:1167-1181
    /// Bullet glyph per depth so nested levels read distinctly: • → ◦ → ▪ (then repeat) — same
    /// progression `MarkdownRenderer.bullet(_:)` uses.
    fn bullet_glyph(level: i64) -> &'static str {
        match level.rem_euclid(3) {
            0 => "•",
            1 => "◦",
            _ => "▪",
        }
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1182-1194
    /// The document's own number format with its `^N` placeholders filled in.
    ///
    /// `^1`…`^7` are HWP's level counters — a level-3 item under format `^1.^2.^3` reads `2.4.1`, so
    /// an OUTER level's placeholder is answered from the counter that level is currently on rather
    /// than from this item's own number. A level with no counter yet reads as 1, which is what it
    /// would have been had the document numbered it.
    // swift: Render/Office/OfficeTextBuilder.swift:1195-1221
    pub fn fill_list_format(
        format: &str,
        level: i64,
        number: i64,
        counters: &HashMap<i64, i64>,
        numbering: Option<&ListNumbering>,
    ) -> String {
        let mut out = String::new();
        let chars: Vec<char> = format.chars().collect();
        let mut i = 0;
        while i < chars.len() {
            if chars[i] == '^' {
                if i + 1 < chars.len() {
                    if let Some(digit) = chars[i + 1].to_digit(10) {
                        if (1..=7).contains(&digit) {
                            let placeholder_level = digit as i64 - 1;
                            let value = if placeholder_level == level { number } else { *counters.get(&placeholder_level).unwrap_or(&1) };
                            let owned = numbering.cloned().unwrap_or_default();
                            out.push_str(&owned.text(value));
                            i += 2;
                            continue;
                        }
                    }
                }
                out.push('^');
                i += 1;
                continue;
            }
            out.push(chars[i]);
            i += 1;
        }
        out
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1216-1221
    /// Hanging-indent paragraph style: marker at `markerX`, a tab pushes text to `textX`, and
    /// wrapped lines align at `textX` — so the item's first line and every wrap share one edge.
    /// `extraTabStops` (points, from `OfficeBlock.listItem.tabStops`) are AUTHORED stops beyond the
    /// marker's own — appended after the marker tab, never in place of it, so `1.\t<text>` still
    /// reaches the item's hanging indent first (this is the sprint brief's own required case: a
    /// custom tab stop must coexist with, not break, list indentation).
    // swift: Render/Office/OfficeTextBuilder.swift:1222-1279
    #[allow(clippy::too_many_arguments)]
    fn list_paragraph_style(
        marker_x: CGFloat,
        text_x: CGFloat,
        theme: &RenderTheme,
        rtl: bool,
        alignment: Option<NSTextAlignment>,
        extra_tab_stops: &[TabStop],
        format: Option<ParagraphFormat>,
        paged: bool,
        line_grid_pitch: Option<CGFloat>,
        font_size_scale: CGFloat,
    ) -> NSParagraphStyle {
        let mut p = NSMutableParagraphStyle::default();
        let lh = (theme.base_font_size * theme.line_height_ratio()).round();
        // Paged: the app's line rhythm and inter-item gap are BOTH withheld, exactly as in
        // `bodyParagraphStyle` — a list item is a paragraph and gets the same treatment. What the
        // document itself states still arrives through `applyParagraphFormat` below.
        p.minimumLineHeight = if paged { line_grid_pitch.unwrap_or(0.0) } else { lh };
        // Cleared for the same reason as body and heading: pinning the maximum to the app's own
        // rhythm clips a list item whose run the document made larger than the document default
        // (a 14pt callout in an 11pt document is capped at 16 against a ~17pt natural line). A
        // floor, not a cap.
        p.maximumLineHeight = 0.0;
        p.paragraphSpacing = if paged { 0.0 } else { theme.base_font_size * theme.tight_spacing_ratio() };
        p.firstLineHeadIndent = marker_x;
        p.headIndent = text_x;
        // NOT routed through `resolvedTabStops`: a list item's authored stops have ALWAYS been mapped
        // straight through here, never re-anchored to the column, so there is no fill-margin
        // correction to switch off for paged (item 7 is a body/heading question only). Sending them
        // through it "for symmetry" would newly apply that correction to every NON-paged list item,
        // which is a change to the model that must stay byte-identical.
        p.tabStops = std::iter::once(NSTextTab::new(NSTextAlignment::Left, text_x, HashMap::new()))
            .chain(extra_tab_stops.iter().map(Self::office_text_tab))
            .collect();
        p.defaultTabInterval = text_x;
        // The marker/hang-indent geometry (`markerX`/`textX`) is left exactly as it is for an LTR
        // item — mirroring it for RTL (marker on the right, indent growing leftward) is real work
        // this sprint's brief scoped out (base direction only); `baseWritingDirection` alone is
        // enough for TextKit to draw the text right-to-left, just still left-indented.
        if rtl {
            p.baseWritingDirection = NSWritingDirection::RightToLeft;
        }
        if let Some(alignment) = alignment {
            p.alignment = alignment;
        }
        // Applied LAST, same as the body/heading paths — a list item's own direct `w:pPr` spacing/
        // line-height/indent (P2's cascade) wins over the marker/hang-indent geometry above when
        // the source specified it; an unspecified cascade (the overwhelming common case — Word's
        // numbering, not a paragraph's own `w:ind`, usually carries a list's indentation) leaves
        // `markerX`/`textX` exactly as before this sprint.
        Self::apply_paragraph_format(format.as_ref(), font_size_scale, 0.0, 0.0, &mut p);
        p
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1224-1265
    /// Renders one list item and updates the per-level numbering state.
    ///
    /// Restart rule (the only stateful part of this file, and only when `marker` is `nil` — see
    /// below): any item at `level` clears the counters of every level DEEPER than it —
    /// a shallower-or-equal item breaks a deeper level's run, so that level restarts at 1 the next
    /// time it appears. A deeper level intervening does NOT clear a shallower level's own counter,
    /// so `1. / a. / b. / 2.` keeps counting `1, 2` at the outer level across the nested run. An
    /// UNORDERED item also clears its OWN level's counter, so a bullet breaks an ordered run at
    /// that same level too.
    ///
    /// `marker`, when supplied, is rendered VERBATIM and `orderedCounters` is left untouched —
    /// see `OfficeBlock.listItem`'s doc comment for why only the reader can compute real numbering
    /// text (continuation across paragraphs, `w:startOverride`, multi-level `%1.%2` formats). This
    /// builder's own counters are a fallback for when the source couldn't supply that text, not a
    /// second, competing numbering scheme — the two never mix for a single item.
    // swift: Render/Office/OfficeTextBuilder.swift:1280-1373
    #[allow(clippy::too_many_arguments)]
    fn append_list_item(
        level: i64,
        ordered: bool,
        spans: &[Span],
        supplied_marker: Option<String>,
        rtl: bool,
        alignment: Option<NSTextAlignment>,
        tab_stops: &[TabStop],
        result: &mut NSMutableAttributedString,
        theme: &RenderTheme,
        ordered_counters: &mut HashMap<i64, i64>,
        font_size_scale: CGFloat,
        paged: bool,
        line_grid_pitch: Option<CGFloat>,
        format: Option<ParagraphFormat>,
        comment_numbers: &HashMap<String, i64>,
        numbering: Option<ListNumbering>,
    ) {
        let marker: String;
        if let Some(supplied_marker) = supplied_marker {
            // A supplied marker is the DOCUMENT's, and for a numbered list it is a FORMAT — HWP
            // writes `^1.`, `제^1장`, where `^N` stands for level N's counter. Emitting it verbatim
            // printed a literal caret on screen; the number is the reader's to compute because only
            // the reader knows how many items its own layout has passed. A bullet's marker carries
            // no placeholder and so survives this untouched.
            if ordered && supplied_marker.contains('^') {
                let deeper: Vec<i64> = ordered_counters.keys().filter(|&&k| k > level).copied().collect();
                for d in deeper {
                    ordered_counters.remove(&d);
                }
                let start = numbering.as_ref().and_then(|n| n.start_number).unwrap_or(1);
                let n = ordered_counters.get(&level).map(|v| v + 1).unwrap_or(start);
                ordered_counters.insert(level, n);
                marker = Self::fill_list_format(&supplied_marker, level, n, ordered_counters, numbering.as_ref()) + "\t";
            } else {
                marker = supplied_marker + "\t";
            }
        } else {
            // Snapshot the keys first — removing while iterating `.keys` directly mutates the same
            // storage the view is walking.
            let deeper: Vec<i64> = ordered_counters.keys().filter(|&&k| k > level).copied().collect();
            for d in deeper {
                ordered_counters.remove(&d);
            }
            if ordered {
                let n = ordered_counters.get(&level).unwrap_or(&0) + 1;
                ordered_counters.insert(level, n);
                marker = format!("{n}.\t");
            } else {
                ordered_counters.remove(&level);
                marker = Self::bullet_glyph(level).to_string() + "\t";
            }
        }

        let hang = theme.base_font_size * theme.list_hang_ratio();
        let marker_x = level as CGFloat * hang;
        // The document's own marker-to-text gap when it declared one, else the reader's own hanging
        // indent. Measured before it was built: 6,508 declarations across 39 of 637 documents, every
        // one of which was being drawn at this reader's rhythm instead of the author's.
        let text_x = format.as_ref().and_then(|f| f.list_text_distance).map(|d| marker_x + d)
            .unwrap_or((level + 1) as CGFloat * hang);
        let start = result.length();
        // The item's text is rendered FIRST (into a local — the appended order is unchanged) so the
        // marker can be drawn to match it. PAGED takes the marker's SIZE and COLOUR from the item's
        // own first resolved span: a bullet beside a 14pt item was drawn at the document's default
        // 11pt, and a marker beside coloured text stayed the theme's ink. Deliberately size+colour
        // only — the FAMILY stays `theme.bodyFont`'s, so an item that opens with a monospaced `code`
        // run does not get a monospaced bullet, and a marker never inherits bold/italic/underline
        // from the word that happens to follow it. Read off the RENDERED run rather than off
        // `Span.fontSize` so it is the one cascade in `spansAttributedString` deciding this, not a
        // second copy of it here. Non-paged is unchanged: theme body font, theme ink.
        let body = Self::spans_attributed_string(
            spans, &theme.body_font(), &theme.text_color(), theme, font_size_scale, paged, comment_numbers,
        );
        let mut marker_font = theme.body_font().clone();
        let mut marker_color = theme.text_color().clone();
        if paged && body.length() > 0 {
            let first = body.attributesAt(0);
            let font_attr = first.and_then(|m| m.get(&NSAttributedStringKey::Font));
            if let Some(swiftshim::AttrValue::Font(f)) = font_attr {
                if let Some(sized) = NSFont::with_descriptor(&theme.body_font().fontDescriptor(), f.pointSize()) {
                    marker_font = sized;
                }
            }
            let color_attr = first.and_then(|m| m.get(&NSAttributedStringKey::ForegroundColor));
            if let Some(swiftshim::AttrValue::Color(c)) = color_attr {
                marker_color = *c;
            }
        }
        let mut marker_attrs: HashMap<NSAttributedStringKey, swiftshim::AttrValue> = HashMap::new();
        marker_attrs.insert(swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(marker_font));
        marker_attrs.insert(swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(marker_color));
        result.append(&NSAttributedString::with_attributes(&marker, marker_attrs));
        result.append(&body);
        result.append(&NSAttributedString::new("\n"));
        result.addAttribute(
            NSAttributedStringKey::ParagraphStyle,
            swiftshim::AttrValue::ParagraphStyle(Self::list_paragraph_style(
                marker_x, text_x, theme, rtl, alignment, tab_stops, format, paged, line_grid_pitch,
                font_size_scale,
            )),
            NSRange::new(start, result.length() - start),
        );
    }

    // MARK: Tables

    // swift: Render/Office/OfficeTextBuilder.swift:1368-1373
    /// Real bordered grid via the shared `TableBlockBuilder` (also used by `MarkdownRenderer`'s
    /// GFM tables) — an office table now looks and behaves exactly like a markdown one, not a
    /// tab-stop approximation. `headerRows: 0` shades no row, because the source didn't say any
    /// row was a header (see `OfficeBlock.table`; guessing "row one" would misrepresent a
    /// headerless table). A cell shorter than the widest row leaves its trailing columns empty
    /// rather than collapsing the row.
    // swift: Render/Office/OfficeTextBuilder.swift:1374-1491
    #[allow(clippy::too_many_arguments)]
    fn append_table(
        rows: &[Vec<Cell>],
        header_rows: usize,
        column_widths: &[CGFloat],
        table_format: &TableFormat,
        result: &mut NSMutableAttributedString,
        theme: &RenderTheme,
        font_size_scale: CGFloat,
        column_width: CGFloat,
        graphic_basis: Option<CGFloat>,
        paged: bool,
        line_grid_pitch: Option<CGFloat>,
        table_width: Option<CGFloat>,
    ) {
        if !rows.iter().any(|r| !r.is_empty()) {
            result.append(&NSAttributedString::new("\n"));
            return;
        }
        // PAGED: a header row's runs decide their own weight. `headerRows` comes from docx
        // `w:tblHeader` (`DocxReader` reads it as `headerRows`), and ECMA-376 §17.4.49 defines that
        // as "repeat this row at the top of each page" — a PAGINATION instruction, not emphasis.
        // Bolding on it states something the document did not, and on a Korean face the bold form is
        // also WIDER, so the header row's cells wrap at different points than the body rows under
        // them — the column reads as misaligned for a reason nothing in the document explains. Where
        // a header really is emphasised the runs say so (`Span.bold`) and it stays bold either way.
        // Non-paged keeps the app's own convention, which is the model that branch is still running.
        //
        // This changes the WEIGHT only. The header row's SHADING is a different decision made in a
        // different place — `TableBlockBuilder` gives a header cell `Palette.tableHeaderBg`, and only
        // as a last resort, after the cell's own, the table's, and the table style's shading — and it
        // is deliberately left exactly as it is here.
        let header_font = if paged { theme.body_font().clone() } else { Self::font_adding(swiftshim::NSFontDescriptorSymbolicTraits::bold, &theme.body_font()) };
        // Each cell's absolute content width at the reading column, resolved by `TableBlockBuilder`'s
        // own placement + edge geometry (single source of truth for column math) so a cell IMAGE can
        // be clamped to its column at BUILD time — mirroring the top-level `.image` path, which
        // already clamps to `columnWidth`. Padding/border are resolved here EXACTLY as
        // `TableBlockBuilder.build`'s per-placement loop does (cell-direct > table-default >
        // style > floor/1 for non-paged; cell-edge > table-edge > `defaultCellPadding` fallback for
        // paged, via the SAME `TableBlockBuilder.resolvedPagedPadding` `build` itself calls — two
        // independent copies of this cascade is exactly the drift invariant 47 warns about), then
        // handed to the helper so the width math stays in one place. `AnchorSpan.padding` only ever
        // needs an APPROXIMATE horizontal figure (this feeds a build-time image clamp, not the real
        // grid — see its own doc: "a slightly generous estimate is harmless"), so a paged cell's
        // asymmetric left/right edges are averaged into the one number that shape wants.
        let span_grid: Vec<Vec<AnchorSpan>> = rows
            .iter()
            .map(|anchors| {
                anchors
                    .iter()
                    .map(|cell| {
                        let padding = if paged {
                            let (_top, left, _bottom, right) = TableBlockBuilder::resolved_paged_padding(cell.edge_padding.as_ref(), table_format.default_padding.as_ref());
                            (left + right) / 2.0
                        } else {
                            cell.padding.unwrap_or(TableBlockBuilder::DEFAULT_CELL_PADDING).max(TableBlockBuilder::DEFAULT_CELL_PADDING)
                        };
                        let border_width = cell.border_width.or(table_format.default_border_width).or(cell.style_border_width).unwrap_or(1.0);
                        AnchorSpan { row_span: cell.row_span as usize, col_span: cell.col_span as usize, padding, border_width }
                    })
                    .collect()
            })
            .collect();
        // The width the table is really laid out at (the reading column minus the text container's
        // own padding), so cell content widths and the built grid agree with the final layout from
        // the FIRST paint — see `TableBlockBuilder.build`'s `width`. For a PAGED document, clamped
        // DOWN to the table's own authored width (`TableFormat.sourceWidth`) when it declared one
        // narrower than the column — Job 2: a table drawn at 68% of the page body must not become
        // 100% of it just because the reader fills the column. Never clamped UP: a table wider than
        // the column, or a non-paged one, still fills it exactly as before this existed. `maxWidth`
        // is ALSO handed to `TableBlockBuilder.build` below so a LATER reflow re-derives the same
        // clamp against the full column rather than re-stretching the table back out to it.
        let requested_width = table_width.unwrap_or(column_width);
        let max_width: Option<CGFloat> = if paged { table_format.source_width } else { None };
        let solved_width = GridTextTable::clamped_width(requested_width, max_width);
        // The GRID this table's columns actually solve across — `solvedWidth` narrowed by the
        // table's own outer margin, mirroring `GridTextTable.edges(forWidth:)`'s own subtraction
        // (`TableBlockBuilder.build`, called below, applies the identical shrink internally via
        // `table.outerMarginLeft`/`Right`). `anchorContentWidths` only feeds a build-time cell-IMAGE
        // clamp, not the real grid — an estimate on the wider, unmargined width would clamp a
        // picture generously wide for a table with declared margins, so this keeps the two in step.
        let margined_width = solved_width
            - table_format.outer_margin.as_ref().and_then(|m| m.left).unwrap_or(0.0)
            - table_format.outer_margin.as_ref().and_then(|m| m.right).unwrap_or(0.0);
        let cell_content_widths = TableBlockBuilder::anchor_content_widths(&span_grid, column_widths, margined_width);
        let cell_rows: Vec<Vec<CellContent>> = rows
            .iter()
            .enumerate()
            .map(|(r, anchors)| {
                let is_header = r < header_rows;
                anchors
                    .iter()
                    .enumerate()
                    .map(|(i, cell)| {
                        let body_font = theme.body_font();
                        let cell_base_font = if is_header { &header_font } else { &body_font };
                        let content = Self::cell_content(
                            &cell.blocks, cell_base_font, theme,
                            font_size_scale, cell_content_widths[r][i], graphic_basis, paged, line_grid_pitch,
                            solved_width,
                        );
                        CellContent {
                            content,
                            row_span: cell.row_span as usize,
                            column_span: cell.col_span as usize,
                            background_color: cell.background_color.clone(),
                            background_image: cell.background_image.clone(),
                            border_color: cell.border_color.clone(),
                            border_width: cell.border_width,
                            width: cell.width,
                            vertical_alignment: cell.vertical_alignment,
                            padding: cell.padding,
                            style_shading: cell.style_shading.clone(),
                            style_border_color: cell.style_border_color.clone(),
                            style_border_width: cell.style_border_width,
                            edge_borders: cell.edge_borders.clone(),
                            edge_padding: cell.edge_padding.clone(),
                            diagonal: cell.diagonal.clone(),
                        }
                    })
                    .collect()
            })
            .collect();
        let table_start = result.length();
        result.append(&TableBlockBuilder::build(
            &cell_rows, header_rows, theme, column_widths,
            table_format.default_border_color, table_format.default_border_width,
            table_format.default_shading, table_format.edge_borders.as_ref(),
            table_format.default_padding.as_ref(), table_format.background_image.clone(),
            table_format.outer_margin.as_ref(), paged, max_width, solved_width,
        ));
        // The document's own answer to "may this be cut at the foot of a page". Stamped only when
        // it says NO: an absent attribute is every table that said nothing, and those keep behaving
        // exactly as they did before this existed (invariant 92's default).
        if table_format.page_break_policy == Some(crate::render::office::office_block::TablePageBreakPolicy::Never)
            && result.length() > table_start
        {
            result.addAttribute(MDAttr::table_keeps_whole(), swiftshim::AttrValue::Bool(true), NSRange::new(table_start, result.length() - table_start));
        }
        result.append(&NSAttributedString::new("\n"));
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1492-1524
    /// Renders one cell's blocks. Deliberately NOT `build(_:theme:columnWidth:)` reused wholesale:
    /// that function ends every block with its own trailing `"\n"` PLUS a block-level paragraph
    /// style (heading/body line-height, paragraph spacing) sized for the full text column — inside
    /// a cell that fights `TableBlockBuilder`'s own paragraph style (`cellLH`, applied to the whole
    /// cell content afterwards) and would draw a spurious blank line under a single-paragraph cell.
    /// So the SEPARATOR is minimal here (a plain `"\n"` between blocks, none after the last) and no
    /// block gets its own `.paragraphStyle` — everything folds into the outer cell paragraph style.
    /// The single-block, single-paragraph case (the compatibility initialiser's shape) therefore
    /// renders BYTE-IDENTICAL to the pre-sprint `spansAttributedString(cell.spans, …)` call this
    /// replaces: no separator is ever emitted around a lone block.
    ///
    /// `.table` is handled by flattening rather than recursing into `appendTable`/
    /// `TableBlockBuilder` — a cell must never contain a REAL nested `NSTextTable` grid (the
    /// project's standing "nested tables flatten to text" decision, applied identically by both
    /// readers at parse time; this is the renderer's own backstop in case a `.table` block ever
    /// reaches a cell some other way).
    /// `imageColumnWidth` is the cell's resolved content width (from `appendTable`'s
    /// `TableBlockBuilder.anchorContentWidths`); a cell `.image`/`.unsupportedGraphic` wider than it
    /// is shrunk aspect-preserving via `fittedOfficeSize`, exactly as a top-level image clamps to the
    /// reading column. `.greatestFiniteMagnitude` (the default) = "no column known" = no clamp, so
    /// callers/tests that never pass it behave as before. Clamped at BUILD time only (invariant 1).
    /// Does this end in a newline? Asked by LOOKING AT THE LAST UNIT, not by bridging the text.
    ///
    /// `result.string.hasSuffix("\n")` reads as the same question and is not the same work: it
    /// bridges the whole accumulated store out to a Swift string (UTF-16 → UTF-8) to look at one
    /// character, inside a loop over a cell's blocks. `mutableString` IS the store, so this is one
    /// indexed read and no conversion at all. Same reason as `MarkdownRenderer.autolink`: once text
    /// is in an attributed string it is UTF-16, and leaving that representation to ask it a question
    /// is the cost.
    ///
    /// MEASURED, and it is NOT a hot spot — first paint on the 542-page 편람 is 973–997 ms with this
    /// and 984–1002 ms with the bridge, i.e. the same. A cell's accumulated text is short at the
    /// moment the question is asked, so the O(n) it removes is an n of a few characters. Recorded so
    /// nobody spends the afternoon that found `MarkdownRenderer.autolink` looking for a twin here.
    // swift: Render/Office/OfficeTextBuilder.swift:1529-1532
    fn ends_in_newline(s: &NSMutableAttributedString) -> bool {
        s.length() > 0 && s.string().ends_with('\n')
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1525-1689
    #[allow(clippy::too_many_arguments)]
    fn cell_content(
        blocks: &[OfficeBlock],
        base_font: &NSFont,
        theme: &RenderTheme,
        font_size_scale: CGFloat,
        image_column_width: CGFloat,
        graphic_basis: Option<CGFloat>,
        paged: bool,
        line_grid_pitch: Option<CGFloat>,
        table_width: CGFloat,
    ) -> NSAttributedString {
        // A cell picture's scale is the TABLE's on-screen width over the table's source width — not
        // the cell's over the cell's. They are the same ratio (every column keeps its proportion when
        // the table is stretched), and using the table's avoids needing each cell's source width.
        let cell_graphic_scale: CGFloat = match graphic_basis {
            Some(b) if b > 0.0 && table_width.is_finite() && table_width > 0.0 => table_width / b,
            _ => 1.0,
        };
        let mut result = NSMutableAttributedString::new();
        for (index, block) in blocks.iter().enumerate() {
            match block {
                // `rtl`/`alignment`/`tabStops` are dropped here (`_`), not lost: a cell's own paragraph
                // style comes from `TableBlockBuilder`'s shared `cellLH` treatment, not from
                // `bodyParagraphStyle`/`headingParagraphStyle`/`listParagraphStyle` above, so there is
                // nowhere in a cell to apply a per-block paragraph override without reaching into that
                // shared builder (out of this sprint's file scope). A cell's RUN-level styling
                // (`Span.rtl`, `Span.textColor`, …) still applies, unaffected — it's carried entirely
                // inside `spansAttributedString`.
                OfficeBlock::Heading { level, spans, rtl, alignment, tab_stops, format } => {
                    let heading_base = Self::heading_base_font(*level, theme, paged);
                    let mut str = NSMutableAttributedString::from_attributed_string(&Self::spans_attributed_string(
                        spans, &heading_base, &theme.text_color(), theme, font_size_scale, paged, &HashMap::new(),
                    ));
                    let whole = NSRange::new(0, str.length());
                    str.addAttribute(
                        NSAttributedStringKey::ParagraphStyle,
                        swiftshim::AttrValue::ParagraphStyle(Self::heading_paragraph_style(
                            *level, spans, theme, *rtl, alignment.clone(), tab_stops, Some(format.clone()),
                            font_size_scale, paged, line_grid_pitch, CGFloat::MAX,
                        )),
                        whole,
                    );
                    result.append(&str);
                }
                OfficeBlock::Paragraph { spans, rtl, alignment, tab_stops, format } => {
                    let mut str = NSMutableAttributedString::from_attributed_string(&Self::spans_attributed_string(
                        spans, base_font, &theme.text_color(), theme, font_size_scale, paged, &HashMap::new(),
                    ));
                    let whole = NSRange::new(0, str.length());
                    str.addAttribute(
                        NSAttributedStringKey::ParagraphStyle,
                        swiftshim::AttrValue::ParagraphStyle(Self::body_paragraph_style(
                            theme, *rtl, alignment.clone(), tab_stops, Some(format.clone()), font_size_scale,
                            paged, line_grid_pitch, CGFloat::MAX,
                        )),
                        whole,
                    );
                    result.append(&str);
                }
                OfficeBlock::ListItem { level, ordered, spans, marker, .. } => {
                    // Cell-local numbering state — a list embedded in one cell doesn't continue a
                    // count begun in a sibling cell or at top level.
                    let mut counters: HashMap<i64, i64> = HashMap::new();
                    Self::append_list_item(
                        *level, *ordered, spans, marker.as_ref().map(|m| m.to_string()), false, None, &[], &mut result, theme,
                        &mut counters, font_size_scale, paged, line_grid_pitch, None, &HashMap::new(), None,
                    );
                    if result.length() > 0 && Self::ends_in_newline(&result) {
                        result.replaceCharacters(NSRange::new(result.length() - 1, 1), "");
                    }
                }
                OfficeBlock::Table { rows: nested_rows, .. } => {
                    result.append(&Self::flatten_table_to_text(nested_rows, base_font, theme));
                }
                OfficeBlock::Image { id, size, alignment } => {
                    // A CELL picture is clamped whether paged or not — see `fittedOfficeSize`'s doc for
                    // why the bleed decision stops at the cell edge (invariant 39's fixed grid).
                    Self::append_image(
                        id.to_string(), *size, image_column_width, graphic_basis, cell_graphic_scale,
                        alignment.clone(), true, 0.0, &mut result,
                    );
                    if result.length() > 0 && Self::ends_in_newline(&result) {
                        result.replaceCharacters(NSRange::new(result.length() - 1, 1), "");
                    }
                }
                OfficeBlock::UnsupportedGraphic { label, size, alignment } => {
                    Self::append_unsupported_graphic(
                        label.to_string(), *size, image_column_width, graphic_basis, cell_graphic_scale,
                        alignment.clone(), true, 0.0, &mut result,
                    );
                    if result.length() > 0 && Self::ends_in_newline(&result) {
                        result.replaceCharacters(NSRange::new(result.length() - 1, 1), "");
                    }
                }
                OfficeBlock::Formula { latex } => {
                    Self::append_formula(latex.to_string(), &mut result);
                    if result.length() > 0 && Self::ends_in_newline(&result) {
                        result.replaceCharacters(NSRange::new(result.length() - 1, 1), "");
                    }
                }
            }
            if index < blocks.len() - 1 {
                let sep_range = {
                    let before = result.length();
                    result.append(&NSAttributedString::new("\n"));
                    NSRange::new(before, result.length() - before)
                };
                result.addAttribute(NSAttributedStringKey::Font, swiftshim::AttrValue::Font(base_font.clone()), sep_range);
            }
        }
        // A block's paragraph style was applied to its spans but NOT to the "\n" separators appended
        // between blocks — and TextKit reads a paragraph's spacing/line-height from its TERMINATOR.
        // Unify each paragraph's style across its terminating newline (using the style at its start),
        // then TRIM the cell's own edges: the first paragraph's leading gap and the last paragraph's
        // trailing gap would pad the cell's inner top/bottom (a single-paragraph data cell would grow
        // by a whole paragraph gap) — that breathing is the cell's own vertical padding's job.
        //
        // The SECOND half of that same unification is `unifyTerminator` below: paragraph style alone
        // left the separator carrying the cell's base font and no colour while the text either side
        // carried its own resolved font and an `NSColor`, so it stayed a run of its own. Same pass,
        // same "attributes of the paragraph's own start" rule, one more step — see `unifyTerminator`.
        let ns = Self::as_ns_string(&result);
        let mut paragraphs: Vec<NSRange> = Vec::new();
        Self::enumerate_paragraphs(&ns, NSRange::new(0, result.length()), |enclosing| {
            if enclosing.length > 0 {
                paragraphs.push(enclosing);
            }
        });
        let last = paragraphs.len().saturating_sub(1);
        for (i, range) in paragraphs.iter().enumerate() {
            let Some(base) = Self::paragraph_style_at(&result, range.location) else { continue };
            let mut m = base;
            if i == 0 {
                m.paragraphSpacingBefore = 0.0;
            }
            if i == last {
                m.paragraphSpacing = 0.0;
            }
            result.addAttribute(NSAttributedStringKey::ParagraphStyle, swiftshim::AttrValue::ParagraphStyle(m), *range);
            Self::unify_terminator(*range, &mut result, &ns);
        }
        result.into()
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1656-1689
    /// Finishes the paragraph pass above: gives a paragraph's terminating `"\n"` the rest of the
    /// attributes its OWN first character carries, so the two collapse into ONE attribute run.
    ///
    /// This is invariant 51 one layer up. `TableBlockBuilder` merged the newline that ends a whole
    /// CELL; what it explicitly left behind — and named — is the separator `cellContent` joins
    /// between two blocks of a MULTI-PARAGRAPH cell. That separator was appended carrying the cell's
    /// base font and nothing else, while the text either side of it carries its own resolved font
    /// (a declared family, a substitute) and an `NSColor`, so every interior separator cost a second
    /// run. Measured through `OfficeTextBuilder.build` at a 700pt column: 2,176 of them on the
    /// 600-page reference manual and 271 on the report — and an attribute run is what installing a
    /// string into a live text view is priced by (~50 µs each, invariant 51).
    ///
    /// Three rules, each carried over from invariant 51 because each was earned there:
    ///
    /// **The separator belongs to the paragraph it TERMINATES, not to the one that follows.** It
    /// cannot merge with both when the two blocks are genuinely differently styled, and this side is
    /// forced rather than chosen: the loop above already stamps the PRECEDING paragraph's style on
    /// this character, so taking the following block's font would leave the separator matching
    /// NEITHER neighbour — one run saved becomes one run kept, and it would describe a paragraph that
    /// does not exist. Measured by mutation: reading the following paragraph instead prints
    /// `"\n둘째 문단"` as a run, a separator visibly attached to the wrong side. What that mutation
    /// does NOT do is move the laid-out geometry, and neither does anything else put here — for
    /// invariant 51's three reasons, unchanged: TextKit resolves a paragraph's metrics at its START,
    /// a trailing newline contributes no glyph of its own, and AppKit builds an attachment glyph only
    /// for U+FFFC. So the side is chosen for the RUN COUNT and for describing the document honestly,
    /// not to protect a pixel.
    ///
    /// **The attributes come from the paragraph's OWN START, never from the character before it.**
    /// That character belongs to the PREVIOUS block, and in invariant 51's case to the previous
    /// CELL, where copying it took the neighbour's `NSTextTableBlock` with it. The risk is milder
    /// inside one cell — the same cell, the same table block — but the discipline is what keeps this
    /// pass local to one paragraph. The consequence is honest and measured: a paragraph whose start
    /// and end differ (`**bold** then plain`) merges with neither and stays exactly as many runs as
    /// it was, no better and no worse.
    ///
    /// **Inheritance is an ALLOW-list** — `TableBlockBuilder.inheritableTerminatorAttributes`, the
    /// same one and deliberately not a second copy: it is the same question about the same character
    /// (invariant 36's one-place rule), and a divergent second list is how the two halves of this
    /// would drift apart. Everything that DRAWS or is CLICKED (`.attachment`, `.backgroundColor`,
    /// `.underlineStyle`/`.strikethroughStyle`, `.link`) is absent, so a paragraph ending in a
    /// picture, a highlight or a hyperlink falls back to exactly the separator it always had. A
    /// paragraph with no content of its own (an empty block between two others) has no attributes to
    /// inherit and keeps the bare separator, for invariant 51's empty-cell reason.
    // swift: Render/Office/OfficeTextBuilder.swift:1690-1708
    fn unify_terminator(paragraph: NSRange, result: &mut NSMutableAttributedString, ns: &swiftshim::NSString) {
        // A terminator only exists where the paragraph's enclosing range ends in one; the LAST block
        // of a cell has none (`cellContent` never appends a trailing separator), and a paragraph that
        // is nothing BUT its terminator has no content of its own to inherit from.
        if paragraph.length <= 1 {
            return;
        }
        let terminator = NSRange::new(paragraph.location + paragraph.length - 1, 1);
        if ns.characterAt(terminator.location) != 10 {
            return;
        }
        let Some(start) = result.asAttributedString().attributesAt(paragraph.location) else { return };
        let allow = TableBlockBuilder::inheritable_terminator_attributes();
        if !start.keys().all(|k| allow.contains(k)) {
            return;
        }
        result.setAttributes(start.clone(), terminator);
    }

    /// Flattens a nested table's cells into one run of text — a tab between cells, a newline after
    /// each non-empty row — so a reader glancing at the flattened text can still tell where one
    /// cell ended and the next began, even though the grid itself is gone. Mirrors the readers' own
    /// `flattenNestedTable` (applied when a `<w:tbl>`/`<table:table>` is found while COLLECTING a
    /// cell's spans, before a `Cell` even exists); this is the renderer-side twin for the case
    /// where a `.table` block reaches `cellContent` directly instead.
    // swift: Render/Office/OfficeTextBuilder.swift:1709-1734
    fn flatten_table_to_text(rows: &[Vec<Cell>], base_font: &NSFont, theme: &RenderTheme) -> NSAttributedString {
        let mut result = NSMutableAttributedString::new();
        for row in rows {
            let mut row_has_content = false;
            for cell in row {
                let text = Self::cell_content(&cell.blocks, base_font, theme, 1.0, CGFloat::MAX, None, false, None, CGFloat::MAX);
                if text.length() == 0 {
                    continue;
                }
                if row_has_content {
                    let r = {
                        let before = result.length();
                        result.append(&NSAttributedString::new("\t"));
                        NSRange::new(before, result.length() - before)
                    };
                    result.addAttribute(NSAttributedStringKey::Font, swiftshim::AttrValue::Font(base_font.clone()), r);
                }
                result.append(&text);
                row_has_content = true;
            }
            if row_has_content {
                let r = {
                    let before = result.length();
                    result.append(&NSAttributedString::new("\n"));
                    NSRange::new(before, result.length() - before)
                };
                result.addAttribute(NSAttributedStringKey::Font, swiftshim::AttrValue::Font(base_font.clone()), r);
            }
        }
        result.into()
    }

    // MARK: Images

    // swift: Render/Office/OfficeTextBuilder.swift:1737-1744
    /// Word DRAWS an image at its declared size regardless of the asset's own pixel dimensions (a
    /// 300px PNG placed at 225pt is ordinary), so — unlike a markdown image, whose true size is
    /// unknown until the bytes arrive — the declared size here is already authoritative. The only
    /// adjustment left is column-fitting: shrink proportionally if it's wider than the page. Doing
    /// that HERE, from the declared size alone, means `MarkdownDocument.reconcileMedia` never has
    /// to recompute a fit from real pixels for an office image — which matters, because
    /// recomputing on load is exactly the scroll-bar-jitter invariant 1 exists to prevent (an
    /// office image's pixel dimensions can legitimately disagree with its declared size).
    // swift: Render/Office/OfficeTextBuilder.swift:1735-1745
    fn fitted_office_size(declared: CGSize, column_width: CGFloat) -> CGSize {
        if !(declared.width > column_width) || !(declared.width > 0.0) {
            return declared;
        }
        let scale = column_width / declared.width;
        CGSize::new(column_width.round(), (declared.height * scale).round())
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1746-1795
    /// How far past the reading column a PAGED document's picture may run before it is shrunk after
    /// all — the owner's "이 앱은 뷰어니 보이게 하는 게 더 중요하다" decision, bounded by what is
    /// actually DRAWABLE rather than by what would be nice.
    ///
    /// Word and HWP let a figure bleed off the body into the page MARGINS, and the geometry to do
    /// that now exists: `DocumentWindowController.settleReadingColumn`'s paged branch sets the text
    /// container to the BODY width, the container's left inset to the document's own LEFT margin, and
    /// the text view's FRAME to `left + body + right` — the author's whole sheet. A line fragment
    /// starts at the container's left edge, so an oversize attachment overruns to the RIGHT only, and
    /// the space it has to overrun into is exactly one number: the document's own RIGHT margin. Past
    /// that it is off the sheet and off the view's bounds, and a view clips its own drawing to its
    /// bounds — so it would be CUT, not bled. A clipped picture is strictly worse than a shrunk one
    /// (the reader loses the right of the figure and nothing on screen says why), which is why the
    /// allowance is the real margin and never a guess at it.
    ///
    /// `nil` — no margin supplied — means NO bleed, i.e. exactly the clamp-to-column behaviour that
    /// preceded this. That is the honest default: without the margin there is no width this can be
    /// proven safe at, and inventing one trades a shrunk picture for a possibly-clipped one.
    ///
    /// **RETURNS 0 TODAY, DELIBERATELY — the premise above is FALSE and was measured to be.** The
    /// paragraph above assumes an attachment wider than the text container paints on into the
    /// frame's spare width and is stopped only by the view's bounds. It is not: **AppKit clips an
    /// attachment to the TEXT CONTAINER**, and the frame is never the limit. Measured by drawing a
    /// real `NSTextView` in exactly `settleReadingColumn`'s paged geometry (inset = left margin,
    /// `containerSize` = body, frame = `left + body + right`), painting a solid attachment through
    /// `cacheDisplay`, and scanning the bitmap for the rightmost painted pixel — container 451.3,
    /// inset 32, frame 515.3:
    ///
    /// ```text
    ///     authored  container   rightmost painted   unclipped would be
    ///      411.3      451.3          447.3               448.3    ← fits, whole
    ///      451.3      451.3          482.3               488.3
    ///      481.3      451.3          482.3               518.3
    ///      551.3      451.3          482.3               588.3
    ///      651.3      451.3          482.3               688.3
    ///      551.3      551.3          582.3               588.3    ← CONTROL, whole
    ///      651.3      651.3          682.3               688.3    ← CONTROL, whole
    /// ```
    ///
    /// The painted extent tracks the CONTAINER and nothing else: pinned at 482.3 for every oversize
    /// width, while the two controls — same pictures, container widened to match — paint whole. So
    /// letting the authored width exceed the column does not bleed the picture, it CROPS it: the
    /// reader loses the right of the figure with nothing on screen to explain it, which is strictly
    /// worse than the shrink it would replace. The gate is here, and not a revert, because the
    /// mechanism and the `pageMarginRight` thread are both correct and the finding must not have to
    /// be re-derived.
    ///
    /// What actually unlocks it: `DocumentWindowController.settleReadingColumn`'s paged branch has to
    /// give the container the whole SHEET (`left + body + right`, `textContainerInset.width` 0) and
    /// pull body text back to the body column with paragraph indents instead of with the container.
    /// Then this returns `right` and the numbers above say it will be drawn. That composes with every
    /// indent `applyParagraphFormat` already sets and with `TableBlockBuilder`'s column solve, so it
    /// wants measuring rather than assuming.
    ///
    /// Measured before any of it, on 41 real documents (4 docx + 37 HWP): not ONE picture is authored
    /// wider than its own page body — the widest observed is exactly the body width. The feature has
    /// no subject in this corpus, which is also why gating it costs nothing today.
    // swift: Render/Office/OfficeTextBuilder.swift:1796-1810
    fn bleed_allowance(paged: bool, page_margin_right: Option<CGFloat>) -> CGFloat {
        let Some(right) = page_margin_right.filter(|_| paged) else { return 0.0 };
        if right <= 0.0 {
            return 0.0;
        }
        let _ = right; // see above: re-enable by returning `right` once the container is the sheet
        0.0
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1812-1820
    /// THE size an office graphic occupies, in one place: authored size × page-proportional scale,
    /// then column-fitted. Called at build time here, and again by
    /// `DocumentWindowController.resizeOfficeGraphics` on every reflow — one function so a picture
    /// cannot drift from what a rebuild at the same width would have produced. (Two copies of this
    /// arithmetic is precisely how a resized document ends up disagreeing with a reopened one.)
    /// `bleed` widens the clamp by that many points — see `bleedAllowance`. `0`, the default, is every
    /// non-paged build, every cell picture, every paged document whose reader found no right margin,
    /// and `DocumentWindowController.resizeOfficeGraphics`, which is skipped outright for a paged
    /// document and so can never reach the widened arm.
    // swift: Render/Office/OfficeTextBuilder.swift:1811-1822
    pub fn graphic_size(authored: CGSize, graphic_scale: CGFloat, column_width: CGFloat, bleed: CGFloat) -> CGSize {
        let scaled = CGSize::new(authored.width * graphic_scale, authored.height * graphic_scale);
        let limit = if bleed > 0.0 && column_width.is_finite() { column_width + bleed } else { column_width };
        // Clamped to `limit`, but never SCALED UP to it: `fittedOfficeSize` only ever shrinks, so a
        // picture narrower than the column keeps its authored width exactly as before.
        Self::fitted_office_size(scaled, limit)
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1823-1840
    /// The chart/SmartArt frame's pixels. Extracted so a reflow can REDRAW it at the new size —
    /// invariant 31 means this case is sized by `.bounds` with an image that is never nil, so
    /// stretching the old bitmap would blur its label instead of re-laying it out.
    pub fn placeholder_image(label: &str, size: CGSize) -> NSImage {
        // `with_drawing` is a real shim constructor now, but its drawing handler is `todo!()`
        // (needs a live graphics context, same as `draw_placeholder_card` below) — this still
        // cannot draw a bitmap, but it no longer silently drops `label` behind a size-only stub;
        // it fails loudly the moment something actually tries to rasterize the placeholder,
        // which is the honest state of a phase-A port rather than a quiet data loss.
        let label = label.to_string();
        NSImage::with_drawing(size, false, move |rect| {
            Self::draw_placeholder_card(&label, rect);
            true
        })
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1842-1866
    /// The card's actual pixels, drawn into whatever rect it is given. Split out of
    /// `placeholderImage` so the OTHER discovery of "this reader cannot draw this graphic" —
    /// `SizedAttachmentCell.undrawableLabel`, where the bytes turned out to be a format no
    /// installed decoder reads — draws the identical card LIVE at its current cell frame instead
    /// of baking a bitmap that a later resize would scale. One routine, so the two cannot drift.
    ///
    /// The label is fitted rather than allowed to run off the card: the font shrinks toward the
    /// card's width and, if even the floor size cannot hold the sentence, only the label's FIRST
    /// WORD is drawn — which is the format's name ("WMF"), the part worth keeping in a frame too
    /// small for a sentence. A one-word label (`[Chart]`, every caller before this) is measured,
    /// found to fit, and drawn exactly where it always was.
    // swift: Render/Office/OfficeTextBuilder.swift:1841-1869
    pub fn draw_placeholder_card(label: &str, rect: NSRect) {
        Palette::code_card_bg().setFill();
        rect.fill();
        Palette::code_card_border().setStroke();
        // BLOCKED on missing shim member: CGRect has no `insetBy`/`inset_by`. Reported to b-shim.
        swiftshim::NSBezierPath::fromRect(rect).stroke();
        let available = rect.size.width - Self::PLACEHOLDER_CARD_TEXT_INSET;
        if available <= 0.0 {
            return;
        }
        let mut font_size = (rect.size.height * 0.18).clamp(9.0, 14.0);
        let mut text = format!("[{label}]");
        let attributes = |size: CGFloat| -> HashMap<NSAttributedStringKey, swiftshim::AttrValue> {
            let mut m = HashMap::new();
            m.insert(swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(NSFont::systemFont(size)));
            m.insert(swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(Palette::secondary()));
            m
        };
        let mut width = swiftshim::size_with_attributes(&text, &attributes(font_size)).width;
        if width > available {
            // Scale the size by exactly the overshoot (text width is very nearly linear in point
            // size), floored so it never becomes unreadable — one step, no search loop.
            font_size = (font_size * available / width).max(Self::PLACEHOLDER_CARD_MIN_FONT_SIZE);
            width = swiftshim::size_with_attributes(&text, &attributes(font_size)).width;
        }
        if width > available {
            if let Some(first_word) = label.split(' ').next() {
                if first_word.len() < label.len() {
                    text = format!("[{first_word}]");
                    width = swiftshim::size_with_attributes(&text, &attributes(font_size)).width;
                }
            }
        }
        let attrs = attributes(font_size);
        let text_size = swiftshim::size_with_attributes(&text, &attrs);
        swiftshim::draw_string_at(
            &text,
            NSPoint::new((rect.size.width - text_size.width) / 2.0, (rect.size.height - text_size.height) / 2.0),
            &attrs,
        );
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1870-1872
    /// Breathing room kept clear either side of a placeholder card's label.
    pub const PLACEHOLDER_CARD_TEXT_INSET: CGFloat = 8.0;
    // swift: Render/Office/OfficeTextBuilder.swift:1873-1874
    /// Below this the label stops being readable, so a narrower card loses words instead of size.
    pub const PLACEHOLDER_CARD_MIN_FONT_SIZE: CGFloat = 7.0;

    // swift: Render/Office/OfficeTextBuilder.swift:1875-1878
    /// Reserves the (column-fitted) declared size via `SizedAttachmentCell`, image left `nil` —
    /// pixels arrive lazily via `MarkdownDocument.reconcileMedia`. This is invariant 1 of this
    /// codebase: the reserved layout size must NEVER depend on whether an image is loaded, or the
    /// scroll bar swings when it loads/purges.
    // swift: Render/Office/OfficeTextBuilder.swift:1879-1910
    #[allow(clippy::too_many_arguments)]
    fn append_image(
        id: String,
        size: CGSize,
        column_width: CGFloat,
        basis: Option<CGFloat>,
        scale: CGFloat,
        alignment: Option<NSTextAlignment>,
        inside_cell: bool,
        bleed: CGFloat,
        result: &mut NSMutableAttributedString,
    ) {
        // `scale` (= the on-screen width of what this picture was measured against ÷ that thing's
        // SOURCE width — page for a picture in the flow, table for one in a cell), NOT `fontSizeScale`:
        // the authored size is a fraction of that container, and reproducing the fraction is what keeps
        // the document's own font↔image proportion at any window size — while leaving ⌘+/⌘− (a TEXT
        // setting) unable to inflate a photograph. Scale first, THEN fit, so a scaled image still never
        // exceeds its column or its cell.
        let fitted = Self::graphic_size(size, scale, column_width, bleed);
        let mut att = NSTextAttachment::new();
        att.bounds = NSRect::fromOriginSize(NSPoint::zero(), fitted);
        att.attachmentCell = Some(SizedAttachmentCell::new(fitted));
        // BLOCKED on missing shim member: no constructor builds an NSAttributedString
        // containing an attachment character + `.attachment` key (AttrValue has no NSTextAttachment
        // variant either). Reported to b-shim.
        let mut ph = NSMutableAttributedString::from_attachment(&att);
        let whole = NSRange::new(0, ph.length());
        ph.addAttribute(MDAttr::image(), swiftshim::AttrValue::Text(id), whole);
        // The AUTHORED size and its basis ride along so a reflow can re-derive this picture's size at
        // the new width (see `MDAttr.officeGraphic`) — a rebuild is not required to resize a window.
        ph.addAttribute(
            MDAttr::office_graphic(),
            swiftshim::AttrValue::Any(std::sync::Arc::new(OfficeGraphicInfo {
                authored: size,
                placeholder_label: None,
                basis_width: basis,
                is_inside_cell: inside_cell,
            })),
            whole,
        );
        Self::apply_graphic_alignment(alignment, &mut ph);
        result.append(&ph);
        result.append(&NSAttributedString::new("\n"));
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1912-1917
    /// The containing paragraph's alignment, applied to the one-character attachment paragraph. A
    /// centred picture is the norm in a report and used to render hard left, because this case
    /// carried no paragraph style at all. `nil` (the document said nothing) adds NO paragraph style,
    /// so a document that never aligns anything is byte-identical to before this existed.
    // swift: Render/Office/OfficeTextBuilder.swift:1911-1919
    fn apply_graphic_alignment(alignment: Option<NSTextAlignment>, ph: &mut NSMutableAttributedString) {
        let Some(alignment) = alignment else { return };
        let mut p = NSMutableParagraphStyle::default();
        p.alignment = alignment;
        ph.addAttribute(NSAttributedStringKey::ParagraphStyle, swiftshim::AttrValue::ParagraphStyle(p), NSRange::new(0, ph.length()));
    }

    // swift: Render/Office/OfficeTextBuilder.swift:1920-1931
    /// A chart/SmartArt this reader could not resolve to any picture at all — reserves the SAME
    /// declared+column-fitted area `appendImage` would, drawn as a bordered, labelled frame
    /// SYNTHESIZED RIGHT HERE rather than left for `MarkdownDocument.reconcileMedia` to fill in
    /// later. Deliberately NOT built through `SizedAttachmentCell` the way `appendImage`'s
    /// reserved-but-unloaded state is (measured: `NSTextAttachment` drops a custom
    /// `attachmentCell` the moment `.image` is set — AppKit switches to its own bounds-based
    /// image layout at that point, the SAME mechanism `reconcileMedia`'s "pixels already loaded,
    /// just repaint" branch relies on) — so sizing here comes from `.bounds` alone, set once,
    /// alongside an `.image` that is never nil to begin with. Invariant 1 (reserved size must
    /// never depend on whether pixels are loaded) holds trivially: there is no "not yet loaded"
    /// state for this case at all, so nothing here can ever revise `.bounds` after the fact.
    /// `label` renders verbatim — the caller (`DocxReader`) already turned it into a word a reader
    /// understands ("Chart", "Diagram"), never an XML element name.
    // swift: Render/Office/OfficeTextBuilder.swift:1932-1963
    #[allow(clippy::too_many_arguments)]
    fn append_unsupported_graphic(
        label: String,
        size: CGSize,
        column_width: CGFloat,
        basis: Option<CGFloat>,
        scale: CGFloat,
        alignment: Option<NSTextAlignment>,
        inside_cell: bool,
        bleed: CGFloat,
        result: &mut NSMutableAttributedString,
    ) {
        // Same proportional scaling as `appendImage` — a chart/SmartArt placeholder stands in for the
        // space the real graphic would occupy, so it must hold that same share of its container.
        let fitted = Self::graphic_size(size, scale, column_width, bleed);
        let mut att = NSTextAttachment::new();
        att.bounds = NSRect::fromOriginSize(NSPoint::zero(), fitted);
        att.image = Some(Self::placeholder_image(&label, fitted));
        // BLOCKED on missing shim member: no constructor builds an NSAttributedString
        // containing an attachment character + `.attachment` key (AttrValue has no NSTextAttachment
        // variant either). Reported to b-shim.
        let mut ph = NSMutableAttributedString::from_attachment(&att);
        // The authored size + label ride along so a reflow can re-derive this frame at the new
        // width (see `MDAttr.officeGraphic`) instead of leaving it frozen at the build width.
        ph.addAttribute(
            MDAttr::office_graphic(),
            swiftshim::AttrValue::Any(std::sync::Arc::new(OfficeGraphicInfo {
                authored: size,
                placeholder_label: Some(label),
                basis_width: basis,
                is_inside_cell: inside_cell,
            })),
            NSRange::new(0, ph.length()),
        );
        Self::apply_graphic_alignment(alignment, &mut ph);
        result.append(&ph);
        result.append(&NSAttributedString::new("\n"));
    }

    // MARK: Formulas

    // swift: Render/Office/OfficeTextBuilder.swift:1958-1963
    /// Reserves a placeholder exactly the way `MarkdownRenderer.appendWebBlock` does for a markdown
    /// `$$…$$` — same `MDAttr.math` attribute, same `SizedAttachmentCell`-owned guessed size (260×60).
    /// `MarkdownDocument`'s pre-render/pre-size passes key off `enumerateWebBlocks`
    /// (`storage.enumerateAttribute(MDAttr.math, …)`), not this document's `kind`, so an office
    /// formula is picked up by the SAME up-front measure pass a markdown one is — nothing here (or
    /// in `MarkdownDocument`) had to be taught that office documents exist. The guessed size is only
    /// a placeholder; the up-front pass replaces it with the exact cached-PDF size before layout
    /// (invariant 1: reserved size must never depend on whether pixels are loaded).
    // swift: Render/Office/OfficeTextBuilder.swift:1964-1973
    fn append_formula(latex: String, result: &mut NSMutableAttributedString) {
        let size = CGSize::new(260.0, 60.0);
        let mut att = NSTextAttachment::new();
        att.bounds = NSRect::fromOriginSize(NSPoint::zero(), size);
        att.attachmentCell = Some(SizedAttachmentCell::new(size));
        // BLOCKED on missing shim member: no constructor builds an NSAttributedString
        // containing an attachment character + `.attachment` key (AttrValue has no NSTextAttachment
        // variant either). Reported to b-shim.
        let mut ph = NSMutableAttributedString::from_attachment(&att);
        ph.addAttribute(MDAttr::math(), swiftshim::AttrValue::Text(latex), NSRange::new(0, ph.length()));
        result.append(&ph);
        result.append(&NSAttributedString::new("\n"));
    }
}
// swift: Render/Office/OfficeTextBuilder.swift:1973-1974
