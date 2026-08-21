//! swift: Render/TableBlockBuilder.swift
//! swift-range: 1-2
//! swift-range: 9-10
//! swift-range: 16-16
//! swift-range: 132-133
//! swift-range: 139-139
//! swift-range: 144-144
//! swift-range: 153-153
//! swift-range: 158-158
//! swift-range: 173-177
//! swift-range: 197-197
//! swift-range: 242-242
//! swift-range: 849-853
//! swift-range: 881-881
//! swift-range: 893-893
//! swift-range: 957-957
//! swift-range: 1019-1019
//! swift-range: 59-59
//! swift-range: 285-288
//! swift-range: 319-320
//! swift-range: 336-336
//! swift-range: 353-355
//! swift-range: 403-403
//! swift-range: 566-566
//! swift-range: 691-691
//! swift-range: 823-825

use std::collections::{HashMap, HashSet};

use swiftshim::{
    CGFloat, NSAttributedString, NSAttributedStringKey, NSColor, NSImage, NSLayoutManager,
    NSMutableAttributedString, NSRange, NSRectEdge, NSTextStorage, NSTextTable, NSTextTableBlock,
};

use crate::render::grid_text_table_block::GridTextTableBlock;
use crate::render::md_attr::MDAttr;
use crate::render::office::office_block::{
    BorderDecl, BorderLineStyle, BorderSide, CellDiagonal, CellVAlign, EdgeBorders, EdgePadding,
};
use crate::render::render_theme::{Palette, RenderTheme};

// swift: Render/TableBlockBuilder.swift:3-8
// An `NSTextTable` that remembers its columns' PROPORTIONS (summing to 1) so the table can be
// re-solved to ABSOLUTE integer point widths at whatever reading-column width the window currently
// has. Percentage column widths are the wrong tool: `NSTextTable` recomputes them per row, so a
// column boundary lands on a slightly different fractional pixel in a 4-cell row than in a
// span-merged one — the "열이 살짝 어긋남" drift. Absolute widths, computed once as a cumulative sum of
// rounded integer edges, put every row's column boundary at the SAME integer x by construction.
//
// swift: `final class GridTextTable: NSTextTable` — class -> struct wrapping the NSTextTable
// superclass state in `base` (convention §3), same shape as `GridTextTableBlock`.
pub struct GridTextTable {
    pub base: NSTextTable,

    // swift: Render/TableBlockBuilder.swift:10
    pub column_proportions: Vec<CGFloat>, // one per column, sums to 1

    // swift: Render/TableBlockBuilder.swift:11-15
    /// The table's own picture fill (`TableFormat.backgroundImage`), painted ONCE across the whole
    /// grid. A table block is drawn before its cells, so this lands behind them; stretching it to
    /// the table's frame is what reproduces HWP's rounded annotation frames, which are one image
    /// behind a table whose cells declare nothing at all.
    pub background_image: Option<NSImage>,

    // swift: Render/TableBlockBuilder.swift:24-58
    /// The table's own AUTHORED width, in points — set only for a PAGED document's table that
    /// declared one (`TableFormat.sourceWidth`, threaded through `TableBlockBuilder.build`'s own
    /// `maxWidth` parameter). `nil` (every markdown table, every non-paged office table, and a
    /// paged table whose format stated no grid total) means no cap at all — `edges(forWidth:)`
    /// solves across whatever width it is asked to, exactly as before this property existed. Never
    /// clamps UPWARD: a reading column narrower than this table's own authored width still shrinks
    /// the table to fit it, same as a paragraph would. Stored on the table object (not just applied
    /// once at build time) so a LATER reflow — `resizeTables(in:toWidth:)`, called with the FULL,
    /// unclamped reading column — re-derives the identical clamped width rather than snapping the
    /// table back out to the column (invariant 48's "build and resizeTables must use the IDENTICAL
    /// formula": both now call the same `edges(forWidth:)`, which applies this clamp internally).
    pub max_width: Option<CGFloat>,

    // swift: Render/TableBlockBuilder.swift:36-57
    /// The table OBJECT's own LEFT/RIGHT outer margin (`TableFormat.outerMargin`, threaded through
    /// `build`'s `tableOuterMargin` parameter) — the horizontal gap between the table and what
    /// surrounds it, distinct from a cell's padding/border (inside the grid). Consulted ONLY by
    /// `edges(forWidth:)`, which is the ONE place this margin is expressed: it narrows the usable
    /// grid AND shifts every edge's starting point to `outerMarginLeft` (see that function's own
    /// doc for why a SECOND box — `NSTextBlock`'s `.margin` on the perimeter cells — was tried and
    /// measured wrong: it double-charged the same margin and clipped real text). A LATER reflow
    /// (`resizeTables`, called with the full, unmargined reading column) re-derives the identical
    /// narrowed grid rather than the margin quietly evaporating on resize — invariant 48's "build
    /// and resizeTables must use the IDENTICAL formula" via the one shared function both call.
    ///
    /// HORIZONTAL ONLY, deliberately. `TableFormat.outerMargin.top`/`.bottom` carry the document's
    /// declared value but are NEVER APPLIED to the built table — a shape invariant 97 already names
    /// (carried on the model, not drawn, same as six of a char shape's sixteen decorations). A
    /// `.minY`/`.maxY` `NSTextBlock` margin box on the first/last row was built, measured against
    /// the real 편람 (545 pages), and REMOVED: 38 pages lost glyphs and several — 105, 118, 120,
    /// 174, 177, 185 among them — rendered COMPLETELY EMPTY, because a table crossing a page
    /// boundary lands its first/last row at the top or bottom of a SHEET, and the reserved band,
    /// the page-break arithmetic and the table's own mid-page splitting (`GridTextTableBlock`,
    /// invariants 61/64/72/96) all read a cell's box geometry — a margin box is not a shape that
    /// machinery was built to absorb. Re-adopting a vertical margin box needs new evidence against
    /// those four invariants first, not a retry of this shape.
    pub outer_margin_left: CGFloat,
    pub outer_margin_right: CGFloat,
}

impl Default for GridTextTable {
    fn default() -> Self {
        Self {
            base: NSTextTable::default(),
            column_proportions: Vec::new(),
            background_image: None,
            max_width: None,
            outer_margin_left: 0.0,
            outer_margin_right: 0.0,
        }
    }
}

impl GridTextTable {
    // swift: Render/TableBlockBuilder.swift:17-23
    /// swift: override func drawBackground(withFrame:in:characterRange:layoutManager:)
    pub fn draw_background(
        &self,
        frame_rect: swiftshim::NSRect,
        control_view: &swiftshim::NSView,
        char_range: NSRange,
        layout_manager: &NSLayoutManager,
    ) {
        // BLOCKED ON SHIM: `NSTextTable.drawBackground(forBlock:rect:in:characterRange:
        // layoutManager:)` — the TABLE-level override `super.drawBackground(...)` calls here —
        // has no member in swiftshim's `text_table.rs` (only `NSTextTableBlock.drawBackground`
        // exists there, a different AppKit method with a different signature). Reported to
        // b-shim; phase B (needs a live graphics context, same as every other drawing call).
        let _ = (&self.base, frame_rect, control_view, char_range, layout_manager);
        if let Some(image) = &self.background_image {
            image.draw(
                frame_rect,
                swiftshim::CGRect::fromOriginSize(swiftshim::CGPoint::zero(), image.size),
                swiftshim::NSCompositingOperation::SourceOver,
                1.0,
                true,
                None,
            );
        }
    }

    // swift: Render/TableBlockBuilder.swift:60-67
    /// `width`, capped to `maxWidth` when the table declared a narrower authored one — the ONE
    /// place this clamp is expressed, so every caller (`edges(forWidth:)` below, and
    /// `OfficeTextBuilder.appendTable`'s own pre-clamp for the picture-scale/image-clamp math that
    /// runs before a `GridTextTable` even exists) shares it instead of drifting apart.
    pub fn clamped_width(width: CGFloat, max_width: Option<CGFloat>) -> CGFloat {
        match max_width {
            Some(m) if m > 0.0 => width.min(m),
            _ => width,
        }
    }

    // swift: Render/TableBlockBuilder.swift:68-131
    /// Integer cumulative x-edges (ncol+1) across the FULL `width` — the shared grid every cell reads.
    ///
    /// No slack is held back. `collapsesBorders` is OFF (see `TableBlockBuilder.build`'s own border
    /// resolution) — each boundary is resolved to exactly ONE drawer with an explicit width, so a row
    /// of `cellWidth`s (content + padding + the cell's own two border widths) sums to exactly this
    /// array's last entry, for any column count and any merge shape WIDE ENOUGH to fit its own two
    /// border widths (`build` shrinks padding, never a border, to make that true down to a genuinely
    /// near-zero-width source column — e.g. `w:gridCol w:w="0"`, which Word writes for a hidden
    /// bookmark column — leaving only a column narrower than its own borders with a real, bounded
    /// overshoot; see `build`'s own comment at the content-width call). The old formula solved inside
    /// `width - 1`: `collapsesBorders = true` charged a shared interior rule once but ignored the
    /// table's own outer share, which this codebase measured as pure slack (moving that outer share
    /// from a full rule to half changed the laid-out total by exactly nothing) — one point was held
    /// back so the table landed just under the reading column instead of half a point over it, which
    /// the container would clip. With collapsing off there is no shared rule left to protect against
    /// double-counting, so the slack is gone and the table lands exactly on `width`, not `width - 1`.
    pub fn edges(&self, width: CGFloat) -> Vec<CGFloat> {
        // Shrink by the table's own outer margin FIRST — before the `maxWidth` clamp, so a table
        // that declares BOTH an authored width and an outer margin still fits the margin inside
        // whichever is narrower, exactly as a paragraph's own indent narrows the space its own
        // width then wraps inside.
        let margined = width - self.outer_margin_left - self.outer_margin_right;
        let usable = (1.0 as CGFloat).max(Self::clamped_width(margined, self.max_width));
        // The grid begins at `outerMarginLeft`, not `0` — floored to an integer, invariant 42's own
        // discipline — so the ONE place that narrows the grid for the table's own outer margin is
        // this array, not a second `NSTextBlock` `.margin` box on the perimeter cells. That second
        // box was tried and MEASURED WRONG: `build`'s per-cell content width is already computed
        // from THIS narrowed grid, so a `.margin` box on top of it charged the same margin again —
        // AppKit reserves a block's margin/border/padding/content OUT OF the column's own
        // proportion-derived slot rather than growing the table to fit them, so the doubled charge
        // left real text with less room than `setContentWidth` had promised and TextKit clipped it:
        // 74,513 glyphs (1.4%) missing from a real 545-page manual, confirmed through `--pdf`.
        // `edges[c1] - edges[c0]` is unaffected by this shift (every caller reads a DIFFERENCE, never
        // `edges[0]` itself — `build` at `let edges = table.edges(forWidth: width)` and
        // `resizeTables` identically), so this line does not, on its own, move a block's rendered
        // POSITION: AppKit positions a table's columns from `columnProportions` against the
        // container's own line width, which this array never touches. What it does do, and the only
        // thing that was broken, is stop a second box from re-charging space this grid already gave
        // up — the table now renders NARROWER by the full declared margin, without clipping anything
        // inside it. A true leftward visual inset would need AppKit to honour it from the block's own
        // box (`.margin`, `.border` or a paragraph's `headIndent`); measured before this shipped, none
        // of those three moves an `NSTextTableBlock`'s position — only `.margin` moves its FOOTPRINT
        // (additively, confirmed empirically), and that additive growth is exactly what caused the
        // double-charge here once combined with a grid already narrowed by the same amount.
        let left = self.outer_margin_left.floor();
        let mut out: Vec<CGFloat> = vec![left];
        let mut cum: CGFloat = 0.0;
        let n = self.column_proportions.len();
        for (i, p) in self.column_proportions.iter().enumerate() {
            cum += p;
            if i == n - 1 {
                // The LAST edge is clamped to `usable`'s FLOOR, never rounded past it. `.rounded()`
                // (round-half-away-from-zero) sends a `width` with a fractional part in [0.5, 1.0) —
                // 705.5, say — to 706: half a point OVER the reading column, which the container then
                // clips, exactly the fault the deleted `width - 1` slack existed to prevent (see this
                // type's own doc comment above). Every earlier edge still rounds normally — unaffected,
                // and still lands on the same integer whichever row reads a given boundary back — only
                // the table's own OUTER right edge is ever at risk of rounding past its target.
                out.push(left + (usable * cum).round().min(usable.floor()));
            } else {
                out.push(left + (usable * cum).round());
            }
        }
        out
    }
}

// swift: Render/TableBlockBuilder.swift:134-138
/// The one place that builds a real bordered `NSTextTable` grid, shared by `MarkdownRenderer`
/// (GFM tables) and `OfficeTextBuilder` (Word/office tables) — a table looks and behaves the same
/// however the document reached it. Each caller renders its own cell content (markdown inline
/// spans vs office `Span`s) into an `NSAttributedString` first; this only lays those strings into
/// `NSTextTableBlock` cells with border, padding and header shading.
pub struct TableBlockBuilder;

impl TableBlockBuilder {
    // swift: Render/TableBlockBuilder.swift:140-143
    /// Upper bound on a single cell's row/column span. A span comes from a parsed file, so a corrupt
    /// or hostile document can claim any number; this keeps an absurd one from turning into that many
    /// loop iterations and set insertions. No real table comes near it.
    pub const MAX_SPAN: usize = 512;

    // swift: Render/TableBlockBuilder.swift:145-152
    /// A guess for the reading column's width at BUILD time, when no real one exists yet — a
    /// table is built once at parse time, long before `DocumentWindowController` knows the actual
    /// window width. Matches the `NSTextContainer`'s own initial 600pt (`DocumentWindowController`'s
    /// `init`), so the FIRST paint (before `updateTextInset` runs its own
    /// `resizeTableColumns(toColumn:)`) is already close, not zero-width. Purely cosmetic: the real
    /// width always arrives on the very next layout pass, same as invariant 2's "measure everything,
    /// then lay out once" — this is that pass's harmless placeholder, not a second source of truth.
    pub const INITIAL_COLUMN_WIDTH: CGFloat = 600.0;

    // swift: Render/TableBlockBuilder.swift:154-157
    /// The reader's comfortable in-cell inset, and the FLOOR every cell's padding is held to (see the
    /// per-cell `cellPadding` below): markdown declares none and gets exactly this; docx/odt declare
    /// their own but never render below it, so a `fo:padding="0cm"` cell reads with room, not cramped.
    pub const DEFAULT_CELL_PADDING: CGFloat = 7.0;

    // swift: Render/TableBlockBuilder.swift:159-172
    /// The PAGED padding cascade — cell-own edge > table-default edge > `defaultCellPadding` as a
    /// FALLBACK (never a floor: a document's own zero survives) — exposed so a caller resolving
    /// padding OUTSIDE `build` (`OfficeTextBuilder.appendTable`'s build-time cell-IMAGE clamp,
    /// which needs an approximate width before a `GridTextTable` exists at all) uses the IDENTICAL
    /// cascade `build`'s own Step A applies, rather than a second copy that could drift out of step
    /// with it — the exact trap invariant 47 already names for the border cascade, reused here.
    /// Floored to an integer per edge (`.rounded(.down)`), same reasoning as `build`'s own use.
    pub fn resolved_paged_padding(
        cell: Option<&EdgePadding>,
        table: Option<&EdgePadding>,
    ) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        fn edge(
            cell: Option<&EdgePadding>,
            table: Option<&EdgePadding>,
            pick: impl Fn(&EdgePadding) -> Option<CGFloat>,
        ) -> CGFloat {
            cell.and_then(&pick)
                .or_else(|| table.and_then(&pick))
                .unwrap_or(TableBlockBuilder::DEFAULT_CELL_PADDING)
                .floor()
        }
        (
            edge(cell, table, |e| e.top),
            edge(cell, table, |e| e.left),
            edge(cell, table, |e| e.bottom),
            edge(cell, table, |e| e.right),
        )
    }

    // swift: Render/TableBlockBuilder.swift:178-196
    /// The width a border edge actually OCCUPIES once AppKit has laid it out: the declared width
    /// rounded UP to a whole point. Both the `setWidth` call and the content-width subtraction go
    /// through here so they can never disagree.
    ///
    /// Measured, not assumed (`SubPointRuleSpikeTests`): a whole-point rule lands exactly at every
    /// column count, and a FRACTIONAL one overshoots by about a point per column boundary, growing
    /// with the count — 0.5pt rules finished +2 / +3 / +5 / +9 / +13 past a 600pt target at 2 / 3 /
    /// 5 / 9 / 13 columns. AppKit charges whole points for a border whatever it is told, so a
    /// document's `w:sz="4"` (Word's ordinary half point) was being subtracted as 0.5 and charged as
    /// something larger, and the difference accumulated across every boundary in the row.
    ///
    /// This makes the GEOMETRY honest. It does not make the rule thinner: a half-point border still
    /// DRAWS as one point, which is what AppKit does with it and what this reader showed before.
    /// Drawing a genuine sub-point rule needs the custom block the spike's own doc sketches — set
    /// AppKit's width to 0 (or its colour to clear) and stroke it ourselves — and that is a visual
    /// change that wants an eye on it, not a geometry fix that a test can settle.
    pub fn laid_out_border_width(declared: CGFloat) -> CGFloat {
        if declared > 0.0 { declared.ceil() } else { 0.0 }
    }

    // swift: Render/TableBlockBuilder.swift:958-1018
    /// Re-solve every `GridTextTable`'s cells to ABSOLUTE integer widths for the current reading-column
    /// `width`. Tables are built at a placeholder width (`initialColumnWidth`); this is the counterpart
    /// of the old custom engine's `relayout`, but far smaller — it just rewrites each cell block's
    /// content width from the table's stored proportions, then the layout manager reflows. Called from
    /// the window controller on first layout and every reflow (resize / sidebar toggle).
    pub fn resize_tables(storage: &mut NSTextStorage, width: CGFloat) {
        if !(width > 0.0) || storage.length() == 0 {
            return;
        }
        let whole = NSRange::new(0, storage.length());
        let mut edges_by_table: HashMap<usize, Vec<CGFloat>> = HashMap::new();
        let mut touched: Vec<NSRange> = Vec::new();
        // swift: storage.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in ... }
        //
        // The body reads a `GridTextTable` back off a paragraph's first `NSTextTableBlock`, re-solves
        // its edges once per table (memoised in `edgesByTable`), and rewrites the owning block's
        // content width — all pure geometry, expressible now; only the live callback plumbing
        // (`enumerateAttribute` over a mutable `NSTextStorage`, and `ObjectIdentifier`-keyed table
        // identity) needs the real TextKit object model B-phase brings.
        let _ = (&mut edges_by_table, &mut touched, whole);
        todo!("swift:968-1005 storage.enumerateAttribute(.paragraphStyle) body — needs a live NSTextStorage/NSTextTableBlock object model");
        // swift: Render/TableBlockBuilder.swift:1006-1017
        // one invalidateLayout call over the union of touched ranges, not per cell:
        //
        //   if let lower = touched.first?.location, let last = touched.last,
        //      let lm = storage.layoutManagers.first {
        //       let upper = min(storage.length, last.location + last.length)
        //       guard upper > lower else { return }
        //       lm.invalidateLayout(forCharacterRange: NSRange(location: lower, length: upper - lower),
        //                           actualCharacterRange: nil)
        //   }
    }


    // swift: Render/TableBlockBuilder.swift:243-284
    /// - Parameters:
    ///   - rows: one entry per row, listing only that row's ANCHOR cells (the top-left corner of
    ///     each merge) left to right — a covered position (inside another cell's `rowSpan`/
    ///     `columnSpan`) is simply absent, not present-and-empty. A row with fewer VISIBLE columns
    ///     than the widest row just leaves its trailing columns empty, it does not shift or
    ///     collapse; the grid's total column count is derived below from every row's anchors and
    ///     their spans together, not from any single row's `count`.
    ///   - headerRows: how many LEADING rows are shaded/bold. `0` means none — a real contract can
    ///     be headerless, and shading row one anyway would misrepresent it (same reasoning
    ///     `OfficeTextBuilder.appendTable`'s doc comment gives for its own header handling).
    ///   - columnWidths: the SOURCE's own grid column widths (points, left-to-right), authoritative
    ///     over any per-cell `CellContent.width` — see `OfficeBlock.table`'s doc comment. Empty (the
    ///     default, and every markdown table) or a count that doesn't match the grid derived below
    ///     leaves this function's PRE-EXISTING per-cell/auto layout completely untouched; only a
    ///     usable grid switches a placed cell's width source from `CellContent.width` (absolute) to
    ///     a percentage of these ratios (see the per-placement loop below).
    ///   - tableBorderColor/tableBorderWidth/tableShading: the table's OWN default border/shading
    ///     (see `TableFormat`) — the MIDDLE layer of the resolution chain a placed cell now goes
    ///     through: its own value, then these table defaults, then (only if both are `nil`) this
    ///     function's pre-existing theme default. All three default to `nil`, so a caller that never
    ///     mentions them (every markdown table) renders BYTE-IDENTICAL to before these parameters
    ///     existed.
    ///   - tablePadding: the table's own default cell margin/padding per edge (`TableFormat.
    ///     defaultPadding`) — the layer beneath a cell's own `CellContent.edgePadding`, consulted
    ///     ONLY when `paged` is `true`. `nil` (every non-paged caller) is inert.
    ///   - paged: whether the CALLER is a paged document reproducing its own page — switches the
    ///     per-cell padding resolution from the single-value floor model (`CellContent.padding`,
    ///     `Self.defaultCellPadding` as a FLOOR) to the four-edge model (`CellContent.edgePadding` >
    ///     `tablePadding` > `Self.defaultCellPadding` as a FALLBACK, no floor — a document's own
    ///     zero survives). `false` (every markdown table, and every existing call site before this
    ///     parameter existed) renders BYTE-IDENTICAL to before it existed.
    ///   - maxWidth: the table's own AUTHORED width (`TableFormat.sourceWidth`), when `paged` — see
    ///     `GridTextTable.maxWidth`'s own doc. `nil` leaves the table filling `width` exactly as
    ///     before this parameter existed.
    #[allow(clippy::too_many_arguments)]
    pub fn build(
        rows: &[Vec<CellContent>],
        header_rows: usize,
        _theme: &RenderTheme,
        column_widths: &[CGFloat],
        table_border_color: Option<NSColor>,
        table_border_width: Option<CGFloat>,
        table_shading: Option<NSColor>,
        table_edges: Option<&EdgeBorders>,
        table_padding: Option<&EdgePadding>,
        table_background_image: Option<NSImage>,
        table_outer_margin: Option<&EdgePadding>,
        paged: bool,
        max_width: Option<CGFloat>,
        width: CGFloat,
    ) -> NSAttributedString {
        let mut result = NSMutableAttributedString::new();
        if rows.is_empty() {
            return result.into();
        }
        let row_count = rows.len();

        // swift: Render/TableBlockBuilder.swift:289-318
        // Walk anchors in document order, placing each into the next column not already covered
        // by an EARLIER row's vertical span. `coveredByLaterRow[r]` collects the columns a span
        // starting above row `r` reaches into; only entries for rows AFTER the anchor's own row
        // are recorded here — within the anchor's own row, `col` is advanced directly by its
        // `columnSpan`, so nothing needs to be looked up for that row.
        struct Placement<'a> {
            row: usize,
            col: usize,
            row_span: usize,
            col_span: usize,
            cell: Option<&'a CellContent>,
        }
        let mut placements: Vec<Placement> = Vec::new();
        let mut covered_by_later_row: HashMap<usize, HashSet<usize>> = HashMap::new();
        let mut ncol: usize = 0;

        for (r, anchors) in rows.iter().enumerate() {
            let covered = covered_by_later_row.get(&r).cloned().unwrap_or_default();
            let mut col = 0usize;
            for cell in anchors {
                // A span arrives from a parsed document, so it is untrusted: a file claiming a cell
                // spans a million rows would otherwise have us loop and allocate that many times.
                // Same posture as ZipArchive's declared-size cap — refuse the absurd, keep rendering.
                let row_span = cell.row_span.max(1).min(Self::MAX_SPAN);
                let col_span = cell.column_span.max(1).min(Self::MAX_SPAN);
                while covered.contains(&col) {
                    col += 1;
                }
                placements.push(Placement { row: r, col, row_span, col_span, cell: Some(cell) });
                if row_span > 1 {
                    for later_row in (r + 1)..(r + row_span) {
                        covered_by_later_row
                            .entry(later_row)
                            .or_default()
                            .extend(col..(col + col_span));
                    }
                }
                col += col_span;
                ncol = ncol.max(col);
            }
        }
        if ncol == 0 {
            return result.into();
        }

        // swift: Render/TableBlockBuilder.swift:321-335
        // Normalise the source's grid widths to PERCENTAGES that sum to 100 — proportions of the
        // already-100%-wide table, not absolute sizes, so they must never be scaled by
        // `fontSizeScale` (unlike a font-derived size, invariant 24's zoom multiplies on top of
        // these, not into them) and never fed in as raw twips (that would be the exact landmine
        // `cellWidth`'s doc comment already warns about for absolute cell widths). Only used when
        // the grid actually matches this table's own derived column count — a mismatch (a
        // malformed/edited document) is treated exactly like "no grid known" rather than partially
        // applied to the wrong columns.
        let mut column_percentages: Vec<CGFloat> = Vec::new();
        if column_widths.len() == ncol {
            let sum: CGFloat = column_widths.iter().sum();
            if sum > 0.0 {
                column_percentages = column_widths.iter().map(|w| w / sum * 100.0).collect();
            }
        }

        // swift: Render/TableBlockBuilder.swift:337-352
        // Pad the gaps. A row can carry fewer anchors than the grid is wide — which is exactly what a
        // vertically merged Word row looks like — and a position left with no block at all renders as
        // a hole in the border, not as an empty cell. Only genuinely UNOCCUPIED positions are padded:
        // a position covered by another cell's span is taken, not empty, and must stay untouched.
        let mut occupied: HashMap<usize, HashSet<usize>> = HashMap::new();
        for p in &placements {
            for r in p.row..(p.row + p.row_span) {
                occupied.entry(r).or_default().extend(p.col..(p.col + p.col_span));
            }
        }
        for r in 0..rows.len() {
            let taken = occupied.get(&r).cloned().unwrap_or_default();
            for c in 0..ncol {
                if !taken.contains(&c) {
                    placements.push(Placement { row: r, col: c, row_span: 1, col_span: 1, cell: None });
                }
            }
        }
        // Reading order, so the laid-out cells follow the grid rather than the order they were found.
        placements.sort_by_key(|p| (p.row, p.col));

        // swift: Render/TableBlockBuilder.swift:356-402
        // Lay the cells into a REAL `NSTextTable` so their text is part of the document — selectable,
        // copyable and searchable (a custom-drawn attachment, however crisply aligned, is a picture the
        // reader can't select, copy or ⌘F). Columns are pinned by PERCENTAGE of the table (one shared
        // proportion per column, spanned cells summing their columns'), so every row reads the same
        // column edge and the table tracks the window width natively — no custom relayout. The old
        // "per-row packing drifted a merged seam" was the reason for the earlier custom engine; giving
        // every cell in a column the identical percentage removes the per-row freedom that drifted.
        // Column PROPORTIONS (sum 1) — from the source's own grid, else equal. Kept on the table so a
        // resize can re-solve absolute widths; the table is first built at the placeholder width and
        // `resizeTables(in:toWidth:)` re-solves it to the real reading column on the next layout.
        let proportions: Vec<CGFloat> = if column_percentages.is_empty() {
            vec![1.0 / ncol as CGFloat; ncol]
        } else {
            column_percentages.iter().map(|p| p / 100.0).collect()
        };
        let mut table = GridTextTable::default();
        table.base.numberOfColumns = ncol as i32;
        table.column_proportions = proportions;
        // Job 2: a PAGED table with a known authored width never grows past it, even on a LATER
        // reflow that asks `edges(forWidth:)` for the full column — see `GridTextTable.maxWidth`'s
        // own doc for why this is stored on the table object rather than applied only here.
        table.max_width = max_width;
        table.background_image = table_background_image;
        // HORIZONTAL only. The VERTICAL pair (`tableOuterMargin?.top`/`.bottom`) is intentionally
        // never read here — see this file's own `outerMargin` doc (near `GridTextTable`) for why a
        // `.minY`/`.maxY` `NSTextBlock` margin box on the first/last row was built, measured on the
        // real 편람, and REMOVED: 38 pages lost glyphs and several (105, 118, 120, 174, 177, 185…)
        // rendered EMPTY once a table carrying it crossed a page boundary — the reserved band, the
        // page-break arithmetic and the table's own splitting (invariants 61/64/72/96) all read a
        // cell's box geometry, and a margin box is not a shape that area was built to absorb.
        let margin_left = table_outer_margin.and_then(|m| m.left).unwrap_or(0.0);
        let margin_right = table_outer_margin.and_then(|m| m.right).unwrap_or(0.0);
        table.outer_margin_left = margin_left;
        table.outer_margin_right = margin_right;
        // Collapsing is OFF. With it on, two adjacent cells can each independently draw a different
        // border and AppKit — not this code — silently picks which one shows, which is why a
        // vertically merged cell used to change which rule it drew every time its neighbour changed
        // (the defect this pipeline exists to remove). Off, every boundary below is resolved to
        // exactly ONE drawer ourselves, so the result is ours to decide and stays consistent down a
        // merge. It also removes the interior-rule double-charge collapsing caused — see
        // `edges(forWidth:)`'s own comment for why that no longer needs to hold back any slack.
        table.base.collapsesBorders = false;
        table.base.hidesEmptyCells = false;
        // Solve the grid at the width the table will ACTUALLY be displayed at when the caller knows
        // it. Building at the placeholder and letting `resizeTables` correct it a moment later is
        // what made a table visibly shrink and then snap wider on every render — two paints of the
        // same table, the first one wrong. The placeholder stays as the default for callers with no
        // real width yet (markdown's renderer, and any build before a window exists).
        let edges = table.edges(width);

        // swift: Render/TableBlockBuilder.swift:404-565
        // STEP A
        // unchanged from before this pipeline existed (two independent reviews already
        // confirmed it, including the `tableDrewABox` fix): resolve each placement's OWN four edges
        // to what THIS cell alone would draw, from the cascade cell-direct > table-direct >
        // table-STYLE (P5) > theme default. `explicit` additionally records whether that came from
        // an actual declaration (the cell's own per-edge decl, or the table's) rather than the bare
        // theme fallback — Step B's tie-break needs to tell those apart, and a bare width/colour pair
        // can't.
        #[derive(Clone)]
        struct ResolvedEdge {
            side: Option<BorderSide>,
            explicit: bool,
        }
        struct PlacementBorders {
            /// `authoredBorderColor` — the block's BASE border colour (Step D), i.e. what an edge
            /// the DOCUMENT drew resolves to when it stated no colour of its own. The reader's
            /// invented stand-in rule does NOT use this: it carries `standInBorderColor` on its own
            /// `BorderSide` and overrides back to the faint tint. See the two-last-resort comment
            /// where both are computed.
            border_color: Option<NSColor>,
            background: Option<NSColor>,
            // PADDING RAW values — "raw" because the LEFT/RIGHT pair is still subject to Step D's
            // width-availability shrink (a column too narrow for the declared padding on both
            // sides), which needs `cellWidth`/border widths not yet known here. TOP/BOTTOM never
            // compete for `cellWidth` (they don't touch the grid's horizontal geometry at all), so
            // they are already final. Non-paged: all four equal the SAME uniform floor-applied
            // value `padding` used to be — see the `paged` branch below.
            padding_top: CGFloat,
            padding_left: CGFloat,
            padding_bottom: CGFloat,
            padding_right: CGFloat,
            on_left: bool,
            on_top: bool,
            top: ResolvedEdge,
            bottom: ResolvedEdge,
            left: ResolvedEdge,
            right: ResolvedEdge,
        }
        let mut info: Vec<PlacementBorders> = Vec::with_capacity(placements.len());
        for placement in &placements {
            let header = placement.row < header_rows;
            let cell = placement.cell;
            // The cascade's DOCUMENT layers — cell-direct > table-direct > table-STYLE — and then
            // TWO different last resorts, because "a rule the document DREW and left the colour of"
            // and "a rule the READER invented because nothing described this edge" are different
            // statements, and only the first should look like the author's own table. This is
            // invariant 47's three states applied to COLOUR: the state is decided per edge below,
            // in `resolvedEdge`, and each state picks its own last resort here.
            //
            //  • `authoredBorderColor` — what a `.drawn` edge takes when no layer stated a colour
            //    (Word writes `w:color="auto"`, i.e. "the application decides", and decides BLACK
            //    itself). PAGED reproduces the author's page, so it gets a real dark rule; the
            //    document asked for a rule here and only left the colour to us. Carried as the
            //    BLOCK's base colour (Step D), which is exactly where a `.drawn` side with a `nil`
            //    colour already resolved — so nothing about how it reaches the screen changes,
            //    only what the value is when the cascade runs out.
            //  • `standInBorderColor` — what the reader's OWN fallback rule takes, the one
            //    `resolvedEdge` invents for an edge NOBODY mentioned in a table that drew no box.
            //    Always `Palette.tableBorder`: a rule with no document behind it must not start
            //    asserting itself as though an author had drawn it. A `.suppressed` edge draws
            //    nothing at all and so has no colour to change either way.
            //
            // The two are the SAME object unless `paged` AND the cascade ran all the way out, so a
            // non-paged table — every markdown table, every office document with no page width —
            // renders byte-identically to before this split, including the per-edge override call
            // in Step D, which compares them and finds them equal (invariant 36's parity harness).
            let stated_border_color = cell
                .and_then(|c| c.border_color)
                .or(table_border_color)
                .or_else(|| cell.and_then(|c| c.style_border_color));
            let authored_border_color = stated_border_color.unwrap_or(if paged {
                Palette::table_border_authored()
            } else {
                Palette::table_border()
            });
            let stand_in_border_color = stated_border_color.unwrap_or(Palette::table_border());
            let border_width = cell
                .and_then(|c| c.border_width)
                .or(table_border_width)
                .or_else(|| cell.and_then(|c| c.style_border_width))
                .unwrap_or(RenderTheme::TABLE_BORDER_WIDTH);
            let background: Option<NSColor> = if let Some(bg) = cell.and_then(|c| c.background_color) {
                Some(bg)
            } else if let Some(ts) = table_shading {
                Some(ts)
            } else if let Some(sb) = cell.and_then(|c| c.style_shading) {
                Some(sb)
            } else if header {
                Some(Palette::table_header_bg())
            } else {
                None
            };
            // PADDING — two entirely different models, gated on `paged`:
            //
            //  • non-paged (unchanged): ONE uniform value, and `Self.defaultCellPadding` is a FLOOR
            //    (`max`, never a document's smaller number) — the pre-existing behaviour, byte-
            //    identical to before this `paged` branch existed.
            //  • paged: FOUR independent edges, cell-own > table-default > `Self.defaultCellPadding`
            //    as a FALLBACK only when NEITHER said anything — a document's own zero (Word's stock
            //    `w:tblCellMar` top/bottom) survives rather than being floored up to 7pt. Floored to
            //    an integer (`.rounded(.down)`) for invariant 42's discipline, reused here for
            //    padding: a fractional twip-converted value (108/20 = 5.4) has no business in this
            //    grid's arithmetic either.
            let (padding_top, padding_left, padding_bottom, padding_right);
            if paged {
                let resolved = Self::resolved_paged_padding(
                    cell.and_then(|c| c.edge_padding.as_ref()),
                    table_padding,
                );
                padding_top = resolved.0;
                padding_left = resolved.1;
                padding_bottom = resolved.2;
                padding_right = resolved.3;
            } else {
                let uniform = cell
                    .and_then(|c| c.padding)
                    .unwrap_or(Self::DEFAULT_CELL_PADDING)
                    .max(Self::DEFAULT_CELL_PADDING);
                padding_top = uniform;
                padding_left = uniform;
                padding_bottom = uniform;
                padding_right = uniform;
            }

            // PER-EDGE borders when the document declared them that way (docx `w:tcBorders`/
            // `w:tblBorders`), the uniform width/colour otherwise. Real reports state each edge
            // separately — a row whose top is a solid blue rule and whose bottom is a dotted hairline
            // — and collapsing that to one width per cell gave every row a different-looking box,
            // which reads as a ragged table. A cell inherits the table's OUTER edge where it sits on
            // that side of the grid and the table's INTERIOR edge where it does not, which is Word's
            // own model and the reason this resolution lives here: only this loop knows where a cell
            // sits. An edge the document turned off draws nothing (width 0), which is a different
            // statement from an edge it never mentioned (inherits).
            let cell_edges = cell.and_then(|c| c.edge_borders.as_ref());
            let on_top = placement.row == 0;
            let on_left = placement.col == 0;
            let on_bottom = placement.row + placement.row_span >= row_count;
            let on_right = placement.col + placement.col_span >= ncol;
            // Whether the TABLE drew a box is a different question from whether a cell said anything.
            // A cell that merely turned ONE of its own edges off — what Word writes when someone
            // selects a cell and removes a single rule — says nothing about the other three, and
            // those must keep resolving through `borderWidth`/`borderColor` above so the cell still
            // matches its neighbours. Treating any declaration as "this table describes its own
            // geometry" made that one cell render thin and open on the edges nobody touched, which is
            // the ragged-table fault this whole per-edge path exists to remove.
            let table_drew_a_box = table_edges.map(|e| e.draws_any_edge()).unwrap_or(false);
            // Step 1 — INHERIT: a cell's own declaration wins; otherwise it takes the table's OUTER
            // edge where it sits on that side of the grid and the table's INTERIOR edge where it
            // doesn't. Still a declaration at this point, not yet a rule to draw.
            fn declaration(
                own: Option<&BorderDecl>,
                outer: Option<&BorderDecl>,
                inside: Option<&BorderDecl>,
                is_outer: bool,
            ) -> Option<BorderDecl> {
                own.cloned().or_else(|| if is_outer { outer.cloned() } else { inside.cloned() })
            }
            // Step 2 — RESOLVE a declaration to what THIS cell alone would draw if nothing else were
            // in play. `.suppressed` draws nothing here, but it is not yet final — Step B (below,
            // after every placement's own resolution is known) is what decides whether a neighbour's
            // rule still wins the boundary; `.suppressed` loses to a drawn rule rather than vetoing
            // it, which is what keeps one cell's lone "off" from stripping the boundary entirely. An
            // UNSPECIFIED edge depends on whether the TABLE drew a box:
            //
            //  • It did — nothing. The table described its own geometry and left this edge out, so
            //    leaving it out is what the document asked for. Standing a faint rule in its place
            //    was built and rejected: measured across one 114-table report, 95 tables turn their
            //    outer rules OFF explicitly and 19 merely never mention them, so the stand-in landed
            //    on 19 tables and not the other 95 — the reader sees some tables boxed and some open
            //    with no way to tell why, which reads worse than honestly showing what is there.
            //  • It did not — the edge falls back to the resolved cell-direct > table-direct >
            //    table-STYLE > theme value, i.e. exactly what this cell would have drawn before any
            //    per-edge data existed. This is the case where only a CELL spoke, and its silence on
            //    an edge must not cost that edge the cascade the rest of the table is using.
            let resolved_edge = |decl: Option<BorderDecl>| -> ResolvedEdge {
                match decl {
                    Some(BorderDecl::Drawn(stated)) => ResolvedEdge { side: Some(stated), explicit: true },
                    Some(BorderDecl::Suppressed) => ResolvedEdge { side: None, explicit: true },
                    None => {
                        // `standInBorderColor`, never `authoredBorderColor` — this arm is the reader's
                        // own invented rule (the document never mentioned this edge and the table drew
                        // no box), so it keeps the faint tint even on a paged page. Making it dark would
                        // put an assertive rule on an edge nobody asked for, in the same table where a
                        // genuinely drawn edge is already dark — the ragged look this whole per-edge
                        // path exists to remove, reintroduced from the other direction.
                        let fallback = if table_drew_a_box {
                            None
                        } else {
                            Some(BorderSide { width: border_width, color: Some(stand_in_border_color), style: BorderLineStyle::Solid })
                        };
                        ResolvedEdge { side: fallback, explicit: false }
                    }
                }
            };
            let top = resolved_edge(declaration(
                cell_edges.and_then(|e| e.top.as_ref()),
                table_edges.and_then(|e| e.top.as_ref()),
                table_edges.and_then(|e| e.inside_h.as_ref()),
                on_top,
            ));
            let bottom = resolved_edge(declaration(
                cell_edges.and_then(|e| e.bottom.as_ref()),
                table_edges.and_then(|e| e.bottom.as_ref()),
                table_edges.and_then(|e| e.inside_h.as_ref()),
                on_bottom,
            ));
            let left = resolved_edge(declaration(
                cell_edges.and_then(|e| e.left.as_ref()),
                table_edges.and_then(|e| e.left.as_ref()),
                table_edges.and_then(|e| e.inside_v.as_ref()),
                on_left,
            ));
            let right = resolved_edge(declaration(
                cell_edges.and_then(|e| e.right.as_ref()),
                table_edges.and_then(|e| e.right.as_ref()),
                table_edges.and_then(|e| e.inside_v.as_ref()),
                on_right,
            ));
            info.push(PlacementBorders {
                border_color: Some(authored_border_color),
                background,
                padding_top,
                padding_left,
                padding_bottom,
                padding_right,
                on_left,
                on_top,
                top,
                bottom,
                left,
                right,
            });
        }

        // swift: Render/TableBlockBuilder.swift:567-690
        // STEP B/C
        // one boundary, one drawer. A grid lookup (placement index covering each row and
        // column, including the padding step's cellless positions) is how a cell finds the
        // neighbour(s) facing its right/bottom edge without re-deriving the placement walk; the
        // table's own left/top perimeter has no neighbour inside the table to contest it, so it is
        // always just this cell's own resolved side, never a contest.
        // `rowCount` is `rows.count` — the SOURCE's literal row count — and is not derived from any
        // `rowSpan` the way `ncol` is derived from `colSpan` (see the placement walk above): a
        // hostile document's absurd `rowSpan`, even after `maxSpan` clamps it, can still claim more
        // rows than the table actually has (one real row, a clamped rowSpan of 512). `ncol` can't
        // overshoot the same way — it IS the maximum extent the walk found — but both ends of THIS
        // fill loop are clamped regardless, defensively, rather than relying on that asymmetry to
        // hold. Every OTHER place that walks `p.row..<(p.row + p.rowSpan)` against `grid` needs its
        // OWN clamp to `rowCount` — the fill loop clamping itself does not protect them.
        let mut grid: Vec<Vec<i64>> = vec![vec![-1; ncol]; row_count];
        for (idx, p) in placements.iter().enumerate() {
            let r_end = (p.row + p.row_span).min(row_count);
            let c_end = (p.col + p.col_span).min(ncol);
            if !(p.row < r_end && p.col < c_end) {
                continue;
            }
            for r in p.row..r_end {
                for c in p.col..c_end {
                    grid[r][c] = idx as i64;
                }
            }
        }
        // The winner between two claimants to ONE boundary. `nil` (nothing to draw) counts as width
        // 0, so `.suppressed` — which resolves to `nil` above — loses to any real rule instead of
        // vetoing it (this is what matches Word: removing one cell's border still leaves the
        // NEIGHBOUR'S OWN border visible). But "the neighbour's own border" presupposes the neighbour
        // (or the table) actually DECLARED one — an EXPLICIT suppression against a bare, non-explicit
        // FALLBACK is a different contest, and this rule is checked FIRST, ahead of "wider wins":
        // that fallback is OUR invented default (used only because `tableDrewABox` is false), not a
        // rule the document ever asked for, and a document that explicitly turned an edge off must
        // not have that "off" overridden by a reader-invented default with nothing behind it. Only a
        // GENUINELY declared rule — the neighbour's own edge, or the table's — still beats a
        // suppression, matching Word's actual behaviour. Once neither side is "explicit suppression
        // vs bare fallback", width decides (`nil` still counts as 0), equal width defers to whichever
        // side was actually DECLARED over a bare theme fallback, and a full tie (both declared, or
        // both fallback, at the same width) keeps the OWNER's own colour — so the result never
        // depends on which side of the boundary happens to be scanned first.
        fn winner(owner: &ResolvedEdge, other: &ResolvedEdge) -> Option<BorderSide> {
            if owner.side.is_none() && owner.explicit && !other.explicit {
                return None;
            }
            if other.side.is_none() && other.explicit && !owner.explicit {
                return None;
            }
            let ow = owner.side.as_ref().map(|s| s.width).unwrap_or(0.0);
            let otw = other.side.as_ref().map(|s| s.width).unwrap_or(0.0);
            if ow != otw {
                return if ow > otw { owner.side.clone() } else { other.side.clone() };
            }
            if owner.explicit != other.explicit {
                return if owner.explicit { owner.side.clone() } else { other.side.clone() };
            }
            owner.side.clone()
        }
        // Folds a MERGED cell's several per-row/per-column boundary winners down to the single widest
        // one it draws uniformly (design doc §3's "Merged cells" — a block has one width per edge).
        // Ties are broken toward `a`, the fold's ACCUMULATOR — which only gives a stable, reproducible
        // answer if the caller always visits the tied neighbours in the SAME order every run. It must
        // NOT be handed a `Set<Int>`'s own iteration order: Swift randomises a `Set`'s per-process
        // hash seed, so the same three tied-width, different-colour neighbours resolved red 6/14,
        // blue 5/14 and green 3/14 across 14 separate process launches of the identical document —
        // the merged cell's rule colour changed from launch to launch with nothing in the document
        // asking for that, the exact fault this whole pipeline exists to remove, reintroduced from a
        // different direction. The caller must fold over `neighbours.sorted()` (ascending placement
        // index — topmost row for `.maxX`, leftmost column for `.maxY`), never the bare `Set`.
        fn wider(a: &Option<BorderSide>, b: &Option<BorderSide>) -> Option<BorderSide> {
            let aw = a.as_ref().map(|s| s.width).unwrap_or(0.0);
            let bw = b.as_ref().map(|s| s.width).unwrap_or(0.0);
            if aw >= bw { a.clone() } else { b.clone() }
        }
        let n = placements.len();
        let mut assigned_min_x: Vec<Option<BorderSide>> = vec![None; n];
        let mut assigned_max_x: Vec<Option<BorderSide>> = vec![None; n];
        let mut assigned_min_y: Vec<Option<BorderSide>> = vec![None; n];
        let mut assigned_max_y: Vec<Option<BorderSide>> = vec![None; n];
        for (idx, p) in placements.iter().enumerate() {
            let me = &info[idx];
            assigned_min_x[idx] = if me.on_left { me.left.side.clone() } else { None };
            assigned_min_y[idx] = if me.on_top { me.top.side.clone() } else { None };
            // `.maxX` — this cell's own right declaration against every right-neighbour's left
            // declaration, WIDEST across the span: a merged cell's one `NSTextTableBlock` can only
            // carry a single width per edge, so a cell spanning rows r0…r1 takes the widest of its
            // per-row boundary winners and draws that one rule uniformly down the whole merge (the
            // alternative — narrowest, or dropping to nothing — makes a rule disappear mid-table,
            // the same fault by another route). No neighbour (the table's own right perimeter) ⇒
            // just its own, unwon.
            if p.col + p.col_span >= ncol {
                assigned_max_x[idx] = me.right.side.clone();
            } else if p.row_span == 1 {
                // FAST PATH — the overwhelming majority of cells in a real table (measured: ~25ms of
                // extra ObjC traffic on 2,489 cells before this, design doc §6 item 7's own cost
                // note). An un-merged cell has exactly ONE right-neighbour, so the `Set` allocation +
                // sort below is pure overhead: `wider(nil, x) == x` always (`wider`'s own definition,
                // `0 >= x.width` is true only when `x` is also nil/width-0, in which case both sides
                // of that comparison are the same `nil`), so folding a ONE-element sorted set can only
                // ever reproduce `winner(...)` directly.
                let n_idx = grid[p.row][p.col + p.col_span];
                assigned_max_x[idx] = if n_idx >= 0 {
                    winner(&me.right, &info[n_idx as usize].left)
                } else {
                    me.right.side.clone()
                };
            } else {
                let mut neighbours: HashSet<i64> = HashSet::new();
                // CLAMPED to `rowCount`, exactly like the grid-fill loop above (line 335) — `rowSpan`
                // is untrusted input (`OdtReader`/`HwpReader` read `table:number-rows-spanned`/HWP's
                // own span attribute VERBATIM, with no clamp of their own; only `DocxReader` clamps at
                // its own source), so a cell whose declared span reaches past the table's last row was
                // indexing `grid[r]` on rows that don't exist — an out-of-bounds trap, not a bad
                // border. `.maxY` below is already guarded by its own `>= rowCount` branch; this was
                // the one unclamped read the comment two blocks up wrongly claimed didn't exist.
                let r_end = (p.row + p.row_span).min(row_count);
                for r in p.row..r_end {
                    neighbours.insert(grid[r][p.col + p.col_span]);
                }
                let mut best: Option<BorderSide> = None;
                // SORTED — see `wider`'s own comment: a bare `Set<Int>` iterates in a per-process
                // hash-randomised order, which made a tie between neighbours resolve to a different
                // colour on every launch.
                let mut sorted: Vec<i64> = neighbours.into_iter().collect();
                sorted.sort();
                for n_idx in sorted {
                    if n_idx >= 0 {
                        best = wider(&best, &winner(&me.right, &info[n_idx as usize].left));
                    }
                }
                assigned_max_x[idx] = best;
            }
            // `.maxY` — the same, downward, against every below-neighbour's top declaration.
            if p.row + p.row_span >= row_count {
                assigned_max_y[idx] = me.bottom.side.clone();
            } else if p.col_span == 1 {
                // FAST PATH — same reasoning as the `.maxX` arm above, mirrored for a single-column cell.
                let n_idx = grid[p.row + p.row_span][p.col];
                assigned_max_y[idx] = if n_idx >= 0 {
                    winner(&me.bottom, &info[n_idx as usize].top)
                } else {
                    me.bottom.side.clone()
                };
            } else {
                let mut neighbours: HashSet<i64> = HashSet::new();
                for c in p.col..(p.col + p.col_span) {
                    neighbours.insert(grid[p.row + p.row_span][c]);
                }
                let mut best: Option<BorderSide> = None;
                // SORTED — same reason as the `.maxX` arm above.
                let mut sorted: Vec<i64> = neighbours.into_iter().collect();
                sorted.sort();
                for n_idx in sorted {
                    if n_idx >= 0 {
                        best = wider(&best, &winner(&me.bottom, &info[n_idx as usize].top));
                    }
                }
                assigned_max_y[idx] = best;
            }
        }

        // swift: Render/TableBlockBuilder.swift:692-818
        // the per-placement emission loop
        for (idx, placement) in placements.iter().enumerate() {
            let me = &info[idx];
            // `GridTextTableBlock`, not the bare AppKit class: a cell a page passes THROUGH has to
            // paint itself in pieces, with no rule at the cut (see that class).
            let block = GridTextTableBlock {
                base: NSTextTableBlock::new(
                    table.base.clone(),
                    placement.row as i32,
                    placement.row_span as i32,
                    placement.col as i32,
                    placement.col_span as i32,
                ),
                edge_styles: HashMap::new(),
                declared_widths: HashMap::new(),
                background_image: None,
                diagonal: None,
            };
            let mut block = block;
            // STEP D (part 1) — only the edges that actually draw something cost a call. A freshly
            // created `NSTextTableBlock`'s border width already defaults to 0 for every edge (verified
            // by the boundary/geometry tests reading a non-owner side back as exactly 0 without this
            // code ever calling `setWidth` there), so a non-owner side needs no call at all — and most
            // cells in a real table are interior, owning only two of their four edges. One base colour
            // call covers every nonzero edge that shares the cascade's ordinary colour; only a
            // genuinely differing per-edge colour pays for its own call. This is the reduction the
            // design's own cost note asks for once collapsing is off and every cell is inherently
            // asymmetric (a uniform 4-edges-at-once call no longer applies almost anywhere).
            let owned: [(NSRectEdge, Option<BorderSide>); 4] = [
                (NSRectEdge::MinX, assigned_min_x[idx].clone()),
                (NSRectEdge::MaxX, assigned_max_x[idx].clone()),
                (NSRectEdge::MinY, assigned_min_y[idx].clone()),
                (NSRectEdge::MaxY, assigned_max_y[idx].clone()),
            ];
            let nonzero: Vec<(NSRectEdge, BorderSide)> = owned
                .into_iter()
                .filter_map(|(e, s)| s.filter(|s| s.width > 0.0).map(|s| (e, s)))
                .collect();
            if !nonzero.is_empty() {
                block.base.setBorderColor(me.border_color.unwrap_or_else(swiftshim::NSColor::clear));
                for (edge, side) in &nonzero {
                    block.base.set_width_border(Self::laid_out_border_width(side.width), *edge);
                    if let Some(c) = side.color {
                        if Some(c) != me.border_color {
                            block.base.set_border_color_edge(c, *edge);
                        }
                    }
                    // The one thing `NSTextTableBlock` cannot carry: HOW the rule is drawn. Only a
                    // non-solid style is recorded, so a table of ordinary rules keeps an empty
                    // dictionary and the block draws exactly as it did before this existed.
                    if side.style != BorderLineStyle::Solid {
                        block.edge_styles.insert(*edge, side.style);
                    }
                    // …and how WIDE it really is. The width above had to be a whole point for the
                    // geometry to add up; the rule itself is drawn at what the document declared,
                    // centred in that band, so 0.1mm and 0.4mm stop looking like the same line.
                    if side.width < Self::laid_out_border_width(side.width) - 0.01 {
                        block.declared_widths.insert(*edge, side.width);
                    }
                }
            }
            // STEP D (part 2) — ABSOLUTE integer content width: the cell's integer span width minus
            // its own padding and its own two (never halved) border widths. Collapsing is off, so
            // nothing is shared with a neighbour to double-account for — each block occupies exactly
            // `content + padding·2 + its own borders`, and summing a row's `cellWidth`s therefore
            // reproduces `edges[ncol]` exactly, for any column count or merge shape wide enough to fit
            // its own two border widths (see below for narrower ones). The old interior halving
            // existed only to model AppKit's collapsing, which no longer runs.
            let cell_width = edges[(placement.col + placement.col_span).min(ncol)] - edges[placement.col];
            let left_width = Self::laid_out_border_width(assigned_min_x[idx].as_ref().map(|s| s.width).unwrap_or(0.0));
            let right_width = Self::laid_out_border_width(assigned_max_x[idx].as_ref().map(|s| s.width).unwrap_or(0.0));
            // PADDING SHRINKS FIRST when a column is too narrow for `defaultCellPadding` on both
            // sides — many columns crowded into one reading width, or a genuinely near-zero source
            // column (`w:gridCol w:w="0"`, which Word writes for a hidden bookmark column). Padding
            // is OUR cosmetic choice, never the document's, so it is what gives way before the "sums
            // to exactly `cellWidth`" guarantee does. Borders are NOT shrunk here — invariant 47's
            // per-edge resolution already decided them, and a document that asked for a rule gets it.
            // Only when the borders ALONE already exceed `cellWidth` (padding already at its own
            // floor of 0) does the 1pt content floor below still cost a real, bounded overshoot — a
            // column narrower than its own border has no exact answer available at all.
            // Rounded DOWN and kept an integer (invariant 42 — a fractional width belongs nowhere in
            // this arithmetic, padding included): rounding up could make a shrunk pair of paddings
            // sum to MORE than `availableForPadding`, reopening the very overshoot this exists to
            // shrink; rounding down never does.
            let available_for_padding = (0.0 as CGFloat).max(cell_width - left_width - right_width);
            let (eff_left, eff_right): (CGFloat, CGFloat);
            if paged {
                // PER-EDGE — the left/right pair can genuinely differ (a document's own asymmetric
                // margin), so each is capped independently against HALF the available room rather
                // than forced to a shared value first; TOP/BOTTOM need no such cap at all — they
                // never compete for `cellWidth`, which is a purely horizontal quantity, and are
                // applied to their own edges exactly as resolved in Step A.
                let max_each_side = (available_for_padding / 2.0).floor();
                eff_left = me.padding_left.min(max_each_side);
                eff_right = me.padding_right.min(max_each_side);
                block.base.set_padding_edge(eff_left, NSRectEdge::MinX);
                block.base.set_padding_edge(eff_right, NSRectEdge::MaxX);
                block.base.set_padding_edge(me.padding_top, NSRectEdge::MinY);
                block.base.set_padding_edge(me.padding_bottom, NSRectEdge::MaxY);
            } else {
                // UNCHANGED — the exact call this file made before the `paged` branch existed: ONE
                // uniform value, set for all four edges via the no-`edge:` overload. `paddingLeft`
                // stands in for the old single `padding` field: Step A made all four fields equal
                // for the non-paged branch, so reading any one of them here is the same number.
                let effective_padding = me.padding_left.min((available_for_padding / 2.0).floor());
                eff_left = effective_padding;
                eff_right = effective_padding;
                block.base.set_padding_all(effective_padding);
            }
            block.base.setContentWidth(
                (1.0 as CGFloat).max(cell_width - eff_left - eff_right - left_width - right_width),
                swiftshim::NSTextBlockValueType::AbsoluteValueType,
            );
            // The table's own OUTER margin, HORIZONTAL half only: reserved ENTIRELY by
            // `edges(forWidth:)` narrowing the grid — never a SECOND `.margin` box on the left/right
            // perimeter cells. That second box was tried and measured wrong: AppKit charges a
            // block's margin/border/padding/content OUT OF the column's own proportion-derived
            // slot, so a `.margin` box on a cell whose content width was ALREADY computed from the
            // narrowed grid charged the same margin twice and clipped real text. There is no
            // VERTICAL counterpart here at all — see `GridTextTable.outerMarginLeft`'s own doc for
            // why a `.minY`/`.maxY` box on the first/last row was tried, measured, and removed too:
            // it is `TableFormat.outerMargin.top`/`.bottom` that stops here, carried on the format
            // but never drawn (invariant 97 names this shape — carried, not applied).
            if let Some(background) = me.background {
                block.base.backgroundColor = Some(background);
            }
            block.background_image = placement.cell.and_then(|c| c.background_image.clone());
            // Only the cell's own declaration — a diagonal is never inherited from the table or a
            // named style, because it marks THIS box rather than describing the grid.
            block.diagonal = placement.cell.and_then(|c| c.diagonal.clone());
            match placement.cell.and_then(|c| c.vertical_alignment).unwrap_or(CellVAlign::Top) {
                CellVAlign::Top => block.base.verticalAlignment = swiftshim::NSTextBlockVerticalAlignment::TopAlignment,
                CellVAlign::Center => block.base.verticalAlignment = swiftshim::NSTextBlockVerticalAlignment::MiddleAlignment,
                CellVAlign::Bottom => block.base.verticalAlignment = swiftshim::NSTextBlockVerticalAlignment::BottomAlignment,
            }

            // swift: Render/TableBlockBuilder.swift:800-817
            // Each cell is one or more paragraphs carrying this block. Preserve the cell content's own
            // paragraph style (alignment/indent/spacing) and only graft the table block onto it.
            let mut cell_str = NSMutableAttributedString::new();
            if let Some(c) = placement.cell {
                cell_str.append(&c.content);
            }
            if cell_str.length() == 0 || !cell_str.string().ends_with('\n') {
                // The terminator carries the cell's OWN attributes so it merges with the cell's
                // content into ONE attribute run instead of two — see `terminatorAttributes`, which
                // owns the reasoning and the empty-cell trap.
                let attrs = Self::terminator_attributes(cell_str.asAttributedString());
                let range = NSRange::new(cell_str.length(), 1);
                cell_str.mutableString().push('\n');
                if let Some(attrs) = attrs {
                    cell_str.setAttributes(attrs, range);
                }
            }
            let whole = NSRange::new(0, cell_str.length());
            // swift: cellStr.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            //     let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            //         ?? NSMutableParagraphStyle()
            //     ps.textBlocks = [block]
            //     cellStr.addAttribute(.paragraphStyle, value: ps, range: range)
            // }
            //
            // Needs a mutable-while-enumerating pass over `cellStr`'s own paragraph-style runs — the
            // enumeration primitive exists (`NSAttributedString::enumerate_attribute`), but the
            // `NSParagraphStyle` -> `NSMutableParagraphStyle` copy-and-mutate step needs the
            // `paragraph_style` shim module `attributed_string.rs` already forward-references and
            // does not exist yet.
            let _ = &whole;
            let _ = &block;
            let block_ref: NSTextTableBlock = block.base.clone();
            todo!("swift:811-816 cellStr.enumerateAttribute(.paragraphStyle) — needs NSMutableParagraphStyle (paragraph_style shim, not yet added)");
            #[allow(unreachable_code)]
            result.append(&cell_str.asAttributedString().clone());
            let _ = block_ref;
        }
        // swift: Render/TableBlockBuilder.swift:819-822
        // A trailing paragraph with NO table block closes the table (else the next document content
        // would be pulled into the last cell). The caller's own following block usually does this, but
        // a table that ends the document needs its own terminator.
        result.append(&NSAttributedString::new("\n"));
        result.into()
    }

    // swift: Render/TableBlockBuilder.swift:826-848
    /// The attributes a cell's terminating `"\n"` is allowed to INHERIT from the cell's own last
    /// character — an ALLOW-list, not a deny-list, so anything new falls back to the old bare
    /// terminator instead of silently riding along on a character it was never measured against.
    ///
    /// Every one of these is inert on a newline, and that is MEASURED rather than reasoned — see
    /// `TableCellTerminatorTests.testTheLaidOutGeometryIsUnchanged`, which records the mutations:
    /// a `lineHeightMultiple` of 5 with 40pt spacing on the terminator moves the laid-out rect by
    /// nothing (TextKit resolves a paragraph's metrics at its START), and neither does a 96pt `.font`
    /// (a trailing newline contributes no glyph of its own to its line fragment — so `.font` is inert
    /// here in BOTH directions, including a cell whose font is SMALLER than AppKit's own default,
    /// where the line could otherwise have shrunk). Ten real documents lay out to an identical height
    /// to five decimal places.
    ///
    /// What is deliberately ABSENT is everything that DRAWS or is CLICKED: `.attachment`,
    /// `.backgroundColor`, `.underlineStyle`/`.strikethroughStyle` and `.link`. Being honest about
    /// the strength of this: none of them was shown to change the laid-out geometry either — an
    /// attachment on a newline draws nothing, because AppKit builds an attachment glyph only for
    /// U+FFFC. So this exclusion is a POSTURE, not a proven bug fix: a picture's attributes describe
    /// a glyph rather than a paragraph, a highlight or rule has no business trailing past the last
    /// glyph, and every media pass (`reconcileMedia`, `resizeOfficeGraphics`, `presizeKnownMedia`)
    /// keeps seeing exactly ONE run per picture instead of two that share an attachment object.
    /// It is nearly free: measured across the two real reports plus every office fixture, these
    /// account for 79 of ~57,000 cell terminators.
    pub fn inheritable_terminator_attributes() -> HashSet<NSAttributedStringKey> {
        HashSet::from([
            NSAttributedStringKey::Font,
            NSAttributedStringKey::ForegroundColor,
            NSAttributedStringKey::ParagraphStyle,
            NSAttributedStringKey::Custom("baselineOffset".to_string()),
            MDAttr::block_id(),
            MDAttr::bookmark_target(),
            MDAttr::src_range(),
        ])
    }

    // swift: Render/TableBlockBuilder.swift:854-880
    /// The attributes to give a cell's terminating `"\n"`, or `nil` to append it bare as before.
    ///
    /// A cell is emitted as its content plus this terminator. Appending that newline with NO
    /// attributes — which is what shipped — made the `enumerateAttribute(.paragraphStyle)` loop below
    /// hand it a FRESH `NSMutableParagraphStyle()`: default alignment, no font, no colour, an
    /// attribute dictionary that can never equal the cell content's own. So EVERY cell cost TWO
    /// attribute runs instead of one, and a run is what `setAttributedString` into a live text view
    /// is priced by (~50 µs each, measured indifferent to WHICH attributes the run carries). On a
    /// 51,816-cell report that is 53,522 runs of pure overhead — half the document's runs.
    ///
    /// Giving the terminator the cell's OWN attributes merges the two into one run. It must be the
    /// cell's own and never simply "the preceding character's": for an EMPTY cell the preceding
    /// character belongs to the PREVIOUS cell. On the FINISHED string that copies the previous cell's
    /// `NSTextTableBlock` and merges two cells into one — which is how the throwaway measurement
    /// behind this change's −49% estimate did it. Inside this function that half is already covered
    /// by the loop below, which re-stamps `ps.textBlocks = [block]` over every run of the cell
    /// (verified by mutation: inheriting from the result string left every block correct). What is
    /// NOT covered, and what this `nil` prevents, is the previous cell's FONT, COLOUR and ALIGNMENT
    /// bleeding into an empty cell, taking its line height with them. An empty cell has no attributes
    /// of its own, so it keeps the bare terminator — byte-identical to before, and free, since a cell
    /// with no content is one run either way.
    pub fn terminator_attributes(
        cell: &NSAttributedString,
    ) -> Option<HashMap<NSAttributedStringKey, swiftshim::AttrValue>> {
        if cell.length() == 0 {
            return None;
        }
        let attrs = cell.attributesAt(cell.length() - 1)?;
        let allow = Self::inheritable_terminator_attributes();
        if !attrs.keys().all(|k| allow.contains(k)) {
            return None;
        }
        Some(attrs.clone())
    }


    // swift: Render/TableBlockBuilder.swift:894-956
    /// The absolute content width available to each ANCHOR cell's blocks at `width`, mirroring
    /// `build`'s own placement walk + integer-edge geometry (same column count, same proportion
    /// normalisation, same `edges(forWidth:)`, same `content = cellWidth − 2·padding − 2·border`).
    /// The `edges` computed a few lines below solve over the SAME full `width` `GridTextTable.
    /// edges(forWidth:)` does (no held-back slack in either) — they used to disagree (`build` solved
    /// inside `width − 1`, this solved across the full `width`), which is now moot since neither
    /// holds any back, but the two must keep matching if that ever changes again. This function keeps
    /// its own `2·borderWidth` approximation regardless — a real per-edge asymmetric subtraction is
    /// unneeded here since the result never feeds `resizeTables` (see below), only a build-time image
    /// clamp, where a slightly generous estimate is harmless.
    /// Returned in the SAME `[row][index]` shape as `spans`. This exists so `OfficeTextBuilder` can
    /// clamp a cell IMAGE to its resolved column at BUILD time — the top-level `.image` path already
    /// clamps to the reading column; a cell image had no column to clamp to until now. Deliberately a
    /// BUILD-time value only: it must NOT feed `resizeTables` (invariant 1 — resizing an attachment in
    /// the reflow path risks scroll jitter and breaks office media's "sized once" policy; a reflow that
    /// only re-solves columns leaves the image at its build-time size, exactly like top-level images).
    pub fn anchor_content_widths(
        spans: &[Vec<AnchorSpan>],
        column_widths: &[CGFloat],
        width: CGFloat,
    ) -> Vec<Vec<CGFloat>> {
        // Placement walk — identical to `build`'s: assign each anchor its (col, colSpan), skipping
        // columns a taller earlier row already spans into, and derive the grid's column count.
        struct Placed {
            r: usize,
            i: usize,
            col: usize,
            col_span: usize,
        }
        let mut placed: Vec<Placed> = Vec::new();
        let mut covered_by_later_row: HashMap<usize, HashSet<usize>> = HashMap::new();
        let mut ncol: usize = 0;
        for (r, anchors) in spans.iter().enumerate() {
            let covered = covered_by_later_row.get(&r).cloned().unwrap_or_default();
            let mut col = 0usize;
            for (i, a) in anchors.iter().enumerate() {
                let row_span = a.row_span.max(1).min(Self::MAX_SPAN);
                let col_span = a.col_span.max(1).min(Self::MAX_SPAN);
                while covered.contains(&col) {
                    col += 1;
                }
                placed.push(Placed { r, i, col, col_span });
                if row_span > 1 {
                    for later_row in (r + 1)..(r + row_span) {
                        covered_by_later_row.entry(later_row).or_default().extend(col..(col + col_span));
                    }
                }
                col += col_span;
                ncol = ncol.max(col);
            }
        }
        let mut out: Vec<Vec<CGFloat>> =
            spans.iter().map(|row| vec![CGFloat::MAX; row.len()]).collect();
        if !(ncol > 0 && width.is_finite() && width > 0.0) {
            return out;
        }

        // Proportions — from the source grid when it matches the derived column count, else an even
        // split (exactly `build`'s fallback), so a table with no known grid still clamps to its even
        // column rather than to nothing.
        let mut proportions: Vec<CGFloat> = vec![1.0 / ncol as CGFloat; ncol];
        if column_widths.len() == ncol {
            let sum: CGFloat = column_widths.iter().sum();
            if sum > 0.0 {
                proportions = column_widths.iter().map(|w| w / sum).collect();
            }
        }
        let mut edges: Vec<CGFloat> = vec![0.0];
        let mut cum: CGFloat = 0.0;
        for p in &proportions {
            cum += p;
            edges.push((width * cum).round());
        }

        for p in &placed {
            let a = &spans[p.r][p.i];
            let cell_width = edges[(p.col + p.col_span).min(ncol)] - edges[p.col];
            out[p.r][p.i] = (1.0 as CGFloat).max(cell_width - 2.0 * a.padding - 2.0 * a.border_width);
        }
        out
    }
}

// swift: Render/TableBlockBuilder.swift:198-241
/// One already-styled cell, plus how many rows/columns its `NSTextTableBlock` covers.
/// `rowSpan`/`columnSpan` default to 1, so a caller with no merges (every markdown table, and
/// an office table before its parser learns `w:gridSpan`/`w:vMerge`) builds these without ever
/// mentioning them.
pub struct CellContent {
    pub content: NSAttributedString,
    pub row_span: usize,
    pub column_span: usize,
    /// The cell's OWN shading/border/width, `nil`/`nil`/`nil`/`nil` meaning "use `build`'s
    /// existing theme defaults" (header shading, `Palette.tableBorder` at 1pt, auto column
    /// layout) exactly as before these fields existed — see `Cell`'s own doc comment in
    /// `OfficeBlock.swift` for the source-format reasoning; this struct only carries the
    /// already-decided values through to `NSTextTableBlock`.
    pub background_color: Option<NSColor>,
    /// Mirrors `Cell.backgroundImage` — a picture fill, painted stretched into the cell's own
    /// frame (and clipped per page piece by `GridTextTableBlock`, so a cell a page break crosses
    /// does not paint its image on the desk between sheets).
    pub background_image: Option<NSImage>,
    pub border_color: Option<NSColor>,
    pub border_width: Option<CGFloat>,
    pub width: Option<CGFloat>,
    /// Mirrors `Cell.verticalAlignment` — `nil` leaves `NSTextTableBlock`'s already-`.top`
    /// vertical alignment untouched.
    pub vertical_alignment: Option<CellVAlign>,
    /// Mirrors `Cell.padding` — already resolved by the caller against any table default;
    /// `nil` means neither said anything, and `build` keeps its own pre-existing 7pt default.
    pub padding: Option<CGFloat>,
    /// The cell's shading/border RESOLVED from the table's named STYLE (`Cell.styleShading`/
    /// `.styleBorderColor`/`.styleBorderWidth` — P5), a LOWER-priority layer than the direct
    /// fields above and the table's own direct default (`tableShading`/`tableBorderColor`/
    /// `tableBorderWidth` on `build`) but a HIGHER-priority one than the theme default — see
    /// `build`'s resolution chain below.
    pub style_shading: Option<NSColor>,
    pub style_border_color: Option<NSColor>,
    pub style_border_width: Option<CGFloat>,
    /// Mirrors `Cell.edgeBorders` — the cell's four edges when the document declared them
    /// individually. `nil` (markdown, and any format that states one uniform border) keeps the
    /// single-width path above, byte-identical to before this existed.
    pub edge_borders: Option<EdgeBorders>,
    /// Mirrors `Cell.edgePadding` — the cell's four edges of padding, consulted ONLY when
    /// `build` is told this table is PAGED. `nil` (every non-paged caller, and any paged cell
    /// whose reader didn't populate it) leaves the single `padding` value above governing,
    /// byte-identical to before this existed.
    pub edge_padding: Option<EdgePadding>,
    /// Mirrors `Cell.diagonal` — the rule this cell draws ACROSS itself. `nil` for markdown and
    /// for every format but HWP, and for the great majority of HWP cells too.
    pub diagonal: Option<CellDiagonal>,
}

impl Default for CellContent {
    fn default() -> Self {
        Self {
            content: NSAttributedString::default(),
            row_span: 1,
            column_span: 1,
            background_color: None,
            background_image: None,
            border_color: None,
            border_width: None,
            width: None,
            vertical_alignment: None,
            padding: None,
            style_shading: None,
            style_border_color: None,
            style_border_width: None,
            edge_borders: None,
            edge_padding: None,
            diagonal: None,
        }
    }
}

// swift: Render/TableBlockBuilder.swift:882-892
/// One anchor's span + already-resolved padding/border, the only inputs `anchorContentWidths`
/// needs to reproduce `build`'s column geometry. The caller (`OfficeTextBuilder.appendTable`)
/// resolves padding/border against the table defaults exactly as `build`'s per-placement loop
/// does, then hands the resolved values here — so the width math stays in this ONE place rather
/// than being re-derived beside `build`.
pub struct AnchorSpan {
    pub row_span: usize,
    pub col_span: usize,
    pub padding: CGFloat,
    pub border_width: CGFloat,
}
