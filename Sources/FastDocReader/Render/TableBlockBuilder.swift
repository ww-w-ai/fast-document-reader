import AppKit

/// An `NSTextTable` that remembers its columns' PROPORTIONS (summing to 1) so the table can be
/// re-solved to ABSOLUTE integer point widths at whatever reading-column width the window currently
/// has. Percentage column widths are the wrong tool: `NSTextTable` recomputes them per row, so a
/// column boundary lands on a slightly different fractional pixel in a 4-cell row than in a
/// span-merged one — the "열이 살짝 어긋남" drift. Absolute widths, computed once as a cumulative sum of
/// rounded integer edges, put every row's column boundary at the SAME integer x by construction.
final class GridTextTable: NSTextTable {
    var columnProportions: [CGFloat] = []   // one per column, sums to 1
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
    func edges(forWidth width: CGFloat) -> [CGFloat] {
        let usable = max(1, width)
        var out: [CGFloat] = [0]
        var cum: CGFloat = 0
        for (i, p) in columnProportions.enumerated() {
            cum += p
            if i == columnProportions.count - 1 {
                // The LAST edge is clamped to `usable`'s FLOOR, never rounded past it. `.rounded()`
                // (round-half-away-from-zero) sends a `width` with a fractional part in [0.5, 1.0) —
                // 705.5, say — to 706: half a point OVER the reading column, which the container then
                // clips, exactly the fault the deleted `width - 1` slack existed to prevent (see this
                // type's own doc comment above). Every earlier edge still rounds normally — unaffected,
                // and still lands on the same integer whichever row reads a given boundary back — only
                // the table's own OUTER right edge is ever at risk of rounding past its target.
                out.append(min((usable * cum).rounded(), usable.rounded(.down)))
            } else {
                out.append((usable * cum).rounded())
            }
        }
        return out
    }
}

/// The one place that builds a real bordered `NSTextTable` grid, shared by `MarkdownRenderer`
/// (GFM tables) and `OfficeTextBuilder` (Word/office tables) — a table looks and behaves the same
/// however the document reached it. Each caller renders its own cell content (markdown inline
/// spans vs office `Span`s) into an `NSAttributedString` first; this only lays those strings into
/// `NSTextTableBlock` cells with border, padding and header shading.
enum TableBlockBuilder {
    /// Upper bound on a single cell's row/column span. A span comes from a parsed file, so a corrupt
    /// or hostile document can claim any number; this keeps an absurd one from turning into that many
    /// loop iterations and set insertions. No real table comes near it.
    static let maxSpan = 512

    /// A guess for the reading column's width at BUILD time, when no real one exists yet — a
    /// table is built once at parse time, long before `DocumentWindowController` knows the actual
    /// window width. Matches the `NSTextContainer`'s own initial 600pt (`DocumentWindowController`'s
    /// `init`), so the FIRST paint (before `updateTextInset` runs its own
    /// `resizeTableColumns(toColumn:)`) is already close, not zero-width. Purely cosmetic: the real
    /// width always arrives on the very next layout pass, same as invariant 2's "measure everything,
    /// then lay out once" — this is that pass's harmless placeholder, not a second source of truth.
    static let initialColumnWidth: CGFloat = 600

    /// The reader's comfortable in-cell inset, and the FLOOR every cell's padding is held to (see the
    /// per-cell `cellPadding` below): markdown declares none and gets exactly this; docx/odt declare
    /// their own but never render below it, so a `fo:padding="0cm"` cell reads with room, not cramped.
    static let defaultCellPadding: CGFloat = 7

    /// One already-styled cell, plus how many rows/columns its `NSTextTableBlock` covers.
    /// `rowSpan`/`columnSpan` default to 1, so a caller with no merges (every markdown table, and
    /// an office table before its parser learns `w:gridSpan`/`w:vMerge`) builds these without ever
    /// mentioning them.
    struct CellContent {
        var content: NSAttributedString
        var rowSpan: Int = 1
        var columnSpan: Int = 1
        /// The cell's OWN shading/border/width, `nil`/`nil`/`nil`/`nil` meaning "use `build`'s
        /// existing theme defaults" (header shading, `Palette.tableBorder` at 1pt, auto column
        /// layout) exactly as before these fields existed — see `Cell`'s own doc comment in
        /// `OfficeBlock.swift` for the source-format reasoning; this struct only carries the
        /// already-decided values through to `NSTextTableBlock`.
        var backgroundColor: NSColor? = nil
        var borderColor: NSColor? = nil
        var borderWidth: CGFloat? = nil
        var width: CGFloat? = nil
        /// Mirrors `Cell.verticalAlignment` — `nil` leaves `NSTextTableBlock`'s already-`.top`
        /// vertical alignment untouched.
        var verticalAlignment: CellVAlign? = nil
        /// Mirrors `Cell.padding` — already resolved by the caller against any table default;
        /// `nil` means neither said anything, and `build` keeps its own pre-existing 7pt default.
        var padding: CGFloat? = nil
        /// The cell's shading/border RESOLVED from the table's named STYLE (`Cell.styleShading`/
        /// `.styleBorderColor`/`.styleBorderWidth` — P5), a LOWER-priority layer than the direct
        /// fields above and the table's own direct default (`tableShading`/`tableBorderColor`/
        /// `tableBorderWidth` on `build`) but a HIGHER-priority one than the theme default — see
        /// `build`'s resolution chain below.
        var styleShading: NSColor? = nil
        var styleBorderColor: NSColor? = nil
        var styleBorderWidth: CGFloat? = nil
        /// Mirrors `Cell.edgeBorders` — the cell's four edges when the document declared them
        /// individually. `nil` (markdown, and any format that states one uniform border) keeps the
        /// single-width path above, byte-identical to before this existed.
        var edgeBorders: EdgeBorders? = nil
    }

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
    static func build(rows: [[CellContent]], headerRows: Int, theme: RenderTheme,
                       columnWidths: [CGFloat] = [], tableBorderColor: NSColor? = nil,
                       tableBorderWidth: CGFloat? = nil, tableShading: NSColor? = nil,
                       tableEdges: EdgeBorders? = nil,
                       width: CGFloat = Self.initialColumnWidth) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !rows.isEmpty else { return result }
        let rowCount = rows.count

        // Walk anchors in document order, placing each into the next column not already covered
        // by an EARLIER row's vertical span. `coveredByLaterRow[r]` collects the columns a span
        // starting above row `r` reaches into; only entries for rows AFTER the anchor's own row
        // are recorded here — within the anchor's own row, `col` is advanced directly by its
        // `columnSpan`, so nothing needs to be looked up for that row.
        struct Placement { let row: Int; let col: Int; let rowSpan: Int; let colSpan: Int; let cell: CellContent? }
        var placements: [Placement] = []
        var coveredByLaterRow: [Int: Set<Int>] = [:]
        var ncol = 0

        for (r, anchors) in rows.enumerated() {
            let covered = coveredByLaterRow[r] ?? []
            var col = 0
            for cell in anchors {
                // A span arrives from a parsed document, so it is untrusted: a file claiming a cell
                // spans a million rows would otherwise have us loop and allocate that many times.
                // Same posture as ZipArchive's declared-size cap — refuse the absurd, keep rendering.
                let rowSpan = min(max(1, cell.rowSpan), Self.maxSpan)
                let colSpan = min(max(1, cell.columnSpan), Self.maxSpan)
                while covered.contains(col) { col += 1 }
                placements.append(Placement(row: r, col: col, rowSpan: rowSpan, colSpan: colSpan, cell: cell))
                if rowSpan > 1 {
                    for laterRow in (r + 1)..<(r + rowSpan) {
                        coveredByLaterRow[laterRow, default: []].formUnion(col..<(col + colSpan))
                    }
                }
                col += colSpan
                ncol = max(ncol, col)
            }
        }
        guard ncol > 0 else { return result }

        // Normalise the source's grid widths to PERCENTAGES that sum to 100 — proportions of the
        // already-100%-wide table, not absolute sizes, so they must never be scaled by
        // `fontSizeScale` (unlike a font-derived size, invariant 24's zoom multiplies on top of
        // these, not into them) and never fed in as raw twips (that would be the exact landmine
        // `cellWidth`'s doc comment already warns about for absolute cell widths). Only used when
        // the grid actually matches this table's own derived column count — a mismatch (a
        // malformed/edited document) is treated exactly like "no grid known" rather than partially
        // applied to the wrong columns.
        var columnPercentages: [CGFloat] = []
        if columnWidths.count == ncol {
            let sum = columnWidths.reduce(0, +)
            if sum > 0 {
                columnPercentages = columnWidths.map { $0 / sum * 100 }
            }
        }

        // Pad the gaps. A row can carry fewer anchors than the grid is wide — which is exactly what a
        // vertically merged Word row looks like — and a position left with no block at all renders as
        // a hole in the border, not as an empty cell. Only genuinely UNOCCUPIED positions are padded:
        // a position covered by another cell's span is taken, not empty, and must stay untouched.
        var occupied: [Int: Set<Int>] = [:]
        for p in placements {
            for r in p.row..<(p.row + p.rowSpan) {
                occupied[r, default: []].formUnion(p.col..<(p.col + p.colSpan))
            }
        }
        for r in rows.indices {
            let taken = occupied[r] ?? []
            for c in 0..<ncol where !taken.contains(c) {
                placements.append(Placement(row: r, col: c, rowSpan: 1, colSpan: 1, cell: nil))
            }
        }
        // Reading order, so the laid-out cells follow the grid rather than the order they were found.
        placements.sort { ($0.row, $0.col) < ($1.row, $1.col) }

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
        let proportions: [CGFloat] = columnPercentages.isEmpty
            ? Array(repeating: 1 / CGFloat(ncol), count: ncol)
            : columnPercentages.map { $0 / 100 }
        let table = GridTextTable()
        table.numberOfColumns = ncol
        table.columnProportions = proportions
        // Collapsing is OFF. With it on, two adjacent cells can each independently draw a different
        // border and AppKit — not this code — silently picks which one shows, which is why a
        // vertically merged cell used to change which rule it drew every time its neighbour changed
        // (the defect this pipeline exists to remove). Off, every boundary below is resolved to
        // exactly ONE drawer ourselves, so the result is ours to decide and stays consistent down a
        // merge. It also removes the interior-rule double-charge collapsing caused — see
        // `edges(forWidth:)`'s own comment for why that no longer needs to hold back any slack.
        table.collapsesBorders = false
        table.hidesEmptyCells = false
        // Solve the grid at the width the table will ACTUALLY be displayed at when the caller knows
        // it. Building at the placeholder and letting `resizeTables` correct it a moment later is
        // what made a table visibly shrink and then snap wider on every render — two paints of the
        // same table, the first one wrong. The placeholder stays as the default for callers with no
        // real width yet (markdown's renderer, and any build before a window exists).
        let edges = table.edges(forWidth: width)

        // STEP A — unchanged from before this pipeline existed (two independent reviews already
        // confirmed it, including the `tableDrewABox` fix): resolve each placement's OWN four edges
        // to what THIS cell alone would draw, from the cascade cell-direct > table-direct >
        // table-STYLE (P5) > theme default. `explicit` additionally records whether that came from
        // an actual declaration (the cell's own per-edge decl, or the table's) rather than the bare
        // theme fallback — Step B's tie-break needs to tell those apart, and a bare width/colour pair
        // can't.
        struct ResolvedEdge { var side: BorderSide?; var explicit: Bool }
        struct PlacementBorders {
            let borderColor: NSColor?
            let background: NSColor?
            let padding: CGFloat
            let onLeft: Bool, onTop: Bool
            let top: ResolvedEdge, bottom: ResolvedEdge, left: ResolvedEdge, right: ResolvedEdge
        }
        var info: [PlacementBorders] = []
        info.reserveCapacity(placements.count)
        for placement in placements {
            let header = placement.row < headerRows
            let borderColor = placement.cell?.borderColor ?? tableBorderColor
                ?? placement.cell?.styleBorderColor ?? Palette.tableBorder
            let borderWidth = placement.cell?.borderWidth ?? tableBorderWidth
                ?? placement.cell?.styleBorderWidth ?? RenderTheme.tableBorderWidth
            let background: NSColor?
            if let bg = placement.cell?.backgroundColor { background = bg }
            else if let tableShading { background = tableShading }
            else if let styleBg = placement.cell?.styleShading { background = styleBg }
            else if header { background = Palette.tableHeaderBg }
            else { background = nil }
            let padding = max(placement.cell?.padding ?? Self.defaultCellPadding, Self.defaultCellPadding)

            // PER-EDGE borders when the document declared them that way (docx `w:tcBorders`/
            // `w:tblBorders`), the uniform width/colour otherwise. Real reports state each edge
            // separately — a row whose top is a solid blue rule and whose bottom is a dotted hairline
            // — and collapsing that to one width per cell gave every row a different-looking box,
            // which reads as a ragged table. A cell inherits the table's OUTER edge where it sits on
            // that side of the grid and the table's INTERIOR edge where it does not, which is Word's
            // own model and the reason this resolution lives here: only this loop knows where a cell
            // sits. An edge the document turned off draws nothing (width 0), which is a different
            // statement from an edge it never mentioned (inherits).
            let cellEdges = placement.cell?.edgeBorders
            let onTop = placement.row == 0, onLeft = placement.col == 0
            let onBottom = placement.row + placement.rowSpan >= rowCount
            let onRight = placement.col + placement.colSpan >= ncol
            // Whether the TABLE drew a box is a different question from whether a cell said anything.
            // A cell that merely turned ONE of its own edges off — what Word writes when someone
            // selects a cell and removes a single rule — says nothing about the other three, and
            // those must keep resolving through `borderWidth`/`borderColor` above so the cell still
            // matches its neighbours. Treating any declaration as "this table describes its own
            // geometry" made that one cell render thin and open on the edges nobody touched, which is
            // the ragged-table fault this whole per-edge path exists to remove.
            let tableDrewABox = tableEdges?.drawsAnyEdge ?? false
            // Step 1 — INHERIT: a cell's own declaration wins; otherwise it takes the table's OUTER
            // edge where it sits on that side of the grid and the table's INTERIOR edge where it
            // doesn't. Still a declaration at this point, not yet a rule to draw.
            func declaration(_ own: BorderDecl?, outer: BorderDecl?, inside: BorderDecl?,
                             isOuter: Bool) -> BorderDecl? {
                own ?? (isOuter ? outer : inside)
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
            func resolvedEdge(_ decl: BorderDecl?) -> ResolvedEdge {
                switch decl {
                case .drawn(let stated): return ResolvedEdge(side: stated, explicit: true)
                case .suppressed: return ResolvedEdge(side: nil, explicit: true)
                case nil:
                    let fallback = tableDrewABox ? nil : BorderSide(width: borderWidth, color: borderColor)
                    return ResolvedEdge(side: fallback, explicit: false)
                }
            }
            let top = resolvedEdge(declaration(cellEdges?.top, outer: tableEdges?.top,
                                               inside: tableEdges?.insideH, isOuter: onTop))
            let bottom = resolvedEdge(declaration(cellEdges?.bottom, outer: tableEdges?.bottom,
                                                  inside: tableEdges?.insideH, isOuter: onBottom))
            let left = resolvedEdge(declaration(cellEdges?.left, outer: tableEdges?.left,
                                                inside: tableEdges?.insideV, isOuter: onLeft))
            let right = resolvedEdge(declaration(cellEdges?.right, outer: tableEdges?.right,
                                                 inside: tableEdges?.insideV, isOuter: onRight))
            info.append(PlacementBorders(borderColor: borderColor, background: background, padding: padding,
                                         onLeft: onLeft, onTop: onTop,
                                         top: top, bottom: bottom, left: left, right: right))
        }

        // STEP B/C — one boundary, one drawer. A grid lookup (placement index covering each row and
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
        var grid = Array(repeating: Array(repeating: -1, count: ncol), count: rowCount)
        for (idx, p) in placements.enumerated() {
            let rEnd = min(p.row + p.rowSpan, rowCount)
            let cEnd = min(p.col + p.colSpan, ncol)
            guard p.row < rEnd, p.col < cEnd else { continue }
            for r in p.row..<rEnd {
                for c in p.col..<cEnd { grid[r][c] = idx }
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
        func winner(owner: ResolvedEdge, other: ResolvedEdge) -> BorderSide? {
            if owner.side == nil, owner.explicit, !other.explicit { return nil }
            if other.side == nil, other.explicit, !owner.explicit { return nil }
            let ow = owner.side?.width ?? 0, otw = other.side?.width ?? 0
            if ow != otw { return ow > otw ? owner.side : other.side }
            if owner.explicit != other.explicit { return owner.explicit ? owner.side : other.side }
            return owner.side
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
        func wider(_ a: BorderSide?, _ b: BorderSide?) -> BorderSide? {
            (a?.width ?? 0) >= (b?.width ?? 0) ? a : b
        }
        var assignedMinX: [BorderSide?] = Array(repeating: nil, count: placements.count)
        var assignedMaxX: [BorderSide?] = Array(repeating: nil, count: placements.count)
        var assignedMinY: [BorderSide?] = Array(repeating: nil, count: placements.count)
        var assignedMaxY: [BorderSide?] = Array(repeating: nil, count: placements.count)
        for (idx, p) in placements.enumerated() {
            let me = info[idx]
            assignedMinX[idx] = me.onLeft ? me.left.side : nil
            assignedMinY[idx] = me.onTop ? me.top.side : nil
            // `.maxX` — this cell's own right declaration against every right-neighbour's left
            // declaration, WIDEST across the span: a merged cell's one `NSTextTableBlock` can only
            // carry a single width per edge, so a cell spanning rows r0…r1 takes the widest of its
            // per-row boundary winners and draws that one rule uniformly down the whole merge (the
            // alternative — narrowest, or dropping to nothing — makes a rule disappear mid-table,
            // the same fault by another route). No neighbour (the table's own right perimeter) ⇒
            // just its own, unwon.
            if p.col + p.colSpan >= ncol {
                assignedMaxX[idx] = me.right.side
            } else if p.rowSpan == 1 {
                // FAST PATH — the overwhelming majority of cells in a real table (measured: ~25ms of
                // extra ObjC traffic on 2,489 cells before this, design doc §6 item 7's own cost
                // note). An un-merged cell has exactly ONE right-neighbour, so the `Set` allocation +
                // sort below is pure overhead: `wider(nil, x) == x` always (`wider`'s own definition,
                // `0 >= x.width` is true only when `x` is also nil/width-0, in which case both sides
                // of that comparison are the same `nil`), so folding a ONE-element sorted set can only
                // ever reproduce `winner(...)` directly.
                let nIdx = grid[p.row][p.col + p.colSpan]
                assignedMaxX[idx] = nIdx >= 0 ? winner(owner: me.right, other: info[nIdx].left) : me.right.side
            } else {
                var neighbours = Set<Int>()
                // CLAMPED to `rowCount`, exactly like the grid-fill loop above (line 335) — `rowSpan`
                // is untrusted input (`OdtReader`/`HwpReader` read `table:number-rows-spanned`/HWP's
                // own span attribute VERBATIM, with no clamp of their own; only `DocxReader` clamps at
                // its own source), so a cell whose declared span reaches past the table's last row was
                // indexing `grid[r]` on rows that don't exist — an out-of-bounds trap, not a bad
                // border. `.maxY` below is already guarded by its own `>= rowCount` branch; this was
                // the one unclamped read the comment two blocks up wrongly claimed didn't exist.
                let rEnd = min(p.row + p.rowSpan, rowCount)
                for r in p.row..<rEnd { neighbours.insert(grid[r][p.col + p.colSpan]) }
                var best: BorderSide?
                // SORTED — see `wider`'s own comment: a bare `Set<Int>` iterates in a per-process
                // hash-randomised order, which made a tie between neighbours resolve to a different
                // colour on every launch.
                for nIdx in neighbours.sorted() where nIdx >= 0 {
                    best = wider(best, winner(owner: me.right, other: info[nIdx].left))
                }
                assignedMaxX[idx] = best
            }
            // `.maxY` — the same, downward, against every below-neighbour's top declaration.
            if p.row + p.rowSpan >= rowCount {
                assignedMaxY[idx] = me.bottom.side
            } else if p.colSpan == 1 {
                // FAST PATH — same reasoning as the `.maxX` arm above, mirrored for a single-column cell.
                let nIdx = grid[p.row + p.rowSpan][p.col]
                assignedMaxY[idx] = nIdx >= 0 ? winner(owner: me.bottom, other: info[nIdx].top) : me.bottom.side
            } else {
                var neighbours = Set<Int>()
                for c in p.col..<(p.col + p.colSpan) { neighbours.insert(grid[p.row + p.rowSpan][c]) }
                var best: BorderSide?
                // SORTED — same reason as the `.maxX` arm above.
                for nIdx in neighbours.sorted() where nIdx >= 0 {
                    best = wider(best, winner(owner: me.bottom, other: info[nIdx].top))
                }
                assignedMaxY[idx] = best
            }
        }

        for (idx, placement) in placements.enumerated() {
            let me = info[idx]
            let block = NSTextTableBlock(table: table,
                                         startingRow: placement.row, rowSpan: placement.rowSpan,
                                         startingColumn: placement.col, columnSpan: placement.colSpan)
            // STEP D (part 1) — only the edges that actually draw something cost a call. A freshly
            // created `NSTextTableBlock`'s border width already defaults to 0 for every edge (verified
            // by the boundary/geometry tests reading a non-owner side back as exactly 0 without this
            // code ever calling `setWidth` there), so a non-owner side needs no call at all — and most
            // cells in a real table are interior, owning only two of their four edges. One base colour
            // call covers every nonzero edge that shares the cascade's ordinary colour; only a
            // genuinely differing per-edge colour pays for its own call. This is the reduction the
            // design's own cost note asks for once collapsing is off and every cell is inherently
            // asymmetric (a uniform 4-edges-at-once call no longer applies almost anywhere).
            let owned: [(NSRectEdge, BorderSide?)] = [(.minX, assignedMinX[idx]), (.maxX, assignedMaxX[idx]),
                                                       (.minY, assignedMinY[idx]), (.maxY, assignedMaxY[idx])]
            let nonzero = owned.filter { ($0.1?.width ?? 0) > 0 }
            if !nonzero.isEmpty {
                block.setBorderColor(me.borderColor)
                for (edge, side) in nonzero {
                    block.setWidth(side!.width, type: .absoluteValueType, for: .border, edge: edge)
                    if let c = side!.color, c != me.borderColor { block.setBorderColor(c, for: edge) }
                }
            }
            // STEP D (part 2) — ABSOLUTE integer content width: the cell's integer span width minus
            // its own padding and its own two (never halved) border widths. Collapsing is off, so
            // nothing is shared with a neighbour to double-account for — each block occupies exactly
            // `content + padding·2 + its own borders`, and summing a row's `cellWidth`s therefore
            // reproduces `edges[ncol]` exactly, for any column count or merge shape wide enough to fit
            // its own two border widths (see below for narrower ones). The old interior halving
            // existed only to model AppKit's collapsing, which no longer runs.
            let cellWidth = edges[min(placement.col + placement.colSpan, ncol)] - edges[placement.col]
            let leftWidth = assignedMinX[idx]?.width ?? 0
            let rightWidth = assignedMaxX[idx]?.width ?? 0
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
            let availableForPadding = max(0, cellWidth - leftWidth - rightWidth)
            let effectivePadding = min(me.padding, (availableForPadding / 2).rounded(.down))
            block.setWidth(effectivePadding, type: .absoluteValueType, for: .padding)
            block.setContentWidth(max(1, cellWidth - 2 * effectivePadding - leftWidth - rightWidth),
                                  type: .absoluteValueType)
            if let background = me.background { block.backgroundColor = background }
            switch placement.cell?.verticalAlignment ?? .top {
            case .top: block.verticalAlignment = .topAlignment
            case .center: block.verticalAlignment = .middleAlignment
            case .bottom: block.verticalAlignment = .bottomAlignment
            }

            // Each cell is one or more paragraphs carrying this block. Preserve the cell content's own
            // paragraph style (alignment/indent/spacing) and only graft the table block onto it.
            let cellStr = NSMutableAttributedString(attributedString: placement.cell?.content ?? NSAttributedString())
            if cellStr.length == 0 || !cellStr.string.hasSuffix("\n") {
                cellStr.append(NSAttributedString(string: "\n"))
            }
            let whole = NSRange(location: 0, length: cellStr.length)
            cellStr.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
                let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                ps.textBlocks = [block]
                cellStr.addAttribute(.paragraphStyle, value: ps, range: range)
            }
            result.append(cellStr)
        }
        // A trailing paragraph with NO table block closes the table (else the next document content
        // would be pulled into the last cell). The caller's own following block usually does this, but
        // a table that ends the document needs its own terminator.
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    /// One anchor's span + already-resolved padding/border, the only inputs `anchorContentWidths`
    /// needs to reproduce `build`'s column geometry. The caller (`OfficeTextBuilder.appendTable`)
    /// resolves padding/border against the table defaults exactly as `build`'s per-placement loop
    /// does, then hands the resolved values here — so the width math stays in this ONE place rather
    /// than being re-derived beside `build`.
    struct AnchorSpan {
        var rowSpan: Int
        var colSpan: Int
        var padding: CGFloat
        var borderWidth: CGFloat
    }

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
    static func anchorContentWidths(spans: [[AnchorSpan]], columnWidths: [CGFloat],
                                    width: CGFloat) -> [[CGFloat]] {
        // Placement walk — identical to `build`'s: assign each anchor its (col, colSpan), skipping
        // columns a taller earlier row already spans into, and derive the grid's column count.
        struct Placed { let r: Int; let i: Int; let col: Int; let colSpan: Int }
        var placed: [Placed] = []
        var coveredByLaterRow: [Int: Set<Int>] = [:]
        var ncol = 0
        for (r, anchors) in spans.enumerated() {
            let covered = coveredByLaterRow[r] ?? []
            var col = 0
            for (i, a) in anchors.enumerated() {
                let rowSpan = min(max(1, a.rowSpan), Self.maxSpan)
                let colSpan = min(max(1, a.colSpan), Self.maxSpan)
                while covered.contains(col) { col += 1 }
                placed.append(Placed(r: r, i: i, col: col, colSpan: colSpan))
                if rowSpan > 1 {
                    for laterRow in (r + 1)..<(r + rowSpan) {
                        coveredByLaterRow[laterRow, default: []].formUnion(col..<(col + colSpan))
                    }
                }
                col += colSpan
                ncol = max(ncol, col)
            }
        }
        var out: [[CGFloat]] = spans.map { Array(repeating: .greatestFiniteMagnitude, count: $0.count) }
        guard ncol > 0, width.isFinite, width > 0 else { return out }

        // Proportions — from the source grid when it matches the derived column count, else an even
        // split (exactly `build`'s fallback), so a table with no known grid still clamps to its even
        // column rather than to nothing.
        var proportions = Array(repeating: 1 / CGFloat(ncol), count: ncol)
        if columnWidths.count == ncol {
            let sum = columnWidths.reduce(0, +)
            if sum > 0 { proportions = columnWidths.map { $0 / sum } }
        }
        var edges: [CGFloat] = [0]
        var cum: CGFloat = 0
        for p in proportions { cum += p; edges.append((width * cum).rounded()) }

        for p in placed {
            let a = spans[p.r][p.i]
            let cellWidth = edges[min(p.col + p.colSpan, ncol)] - edges[p.col]
            out[p.r][p.i] = max(1, cellWidth - 2 * a.padding - 2 * a.borderWidth)
        }
        return out
    }

    /// Re-solve every `GridTextTable`'s cells to ABSOLUTE integer widths for the current reading-column
    /// `width`. Tables are built at a placeholder width (`initialColumnWidth`); this is the counterpart
    /// of the old custom engine's `relayout`, but far smaller — it just rewrites each cell block's
    /// content width from the table's stored proportions, then the layout manager reflows. Called from
    /// the window controller on first layout and every reflow (resize / sidebar toggle).
    static func resizeTables(in storage: NSTextStorage, toWidth width: CGFloat) {
        guard width > 0, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var edgesByTable: [ObjectIdentifier: [CGFloat]] = [:]
        var touched: [NSRange] = []
        storage.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock,
                  let table = block.table as? GridTextTable, !table.columnProportions.isEmpty else { return }
            let key = ObjectIdentifier(table)
            let edges = edgesByTable[key] ?? {
                let e = table.edges(forWidth: width); edgesByTable[key] = e; return e
            }()
            let ncol = table.numberOfColumns
            let c0 = min(block.startingColumn, ncol)
            let c1 = min(block.startingColumn + block.columnSpan, ncol)
            guard c1 > c0, c1 < edges.count else { return }
            // Read BOTH horizontal edges back, never one of them twice. With per-edge borders the
            // left and right widths legitimately differ (a table with no outer rule but an inner one
            // has left 0 and right 1), and doubling the left produced a target that never matched
            // what `build` had already set — so every cell "changed" on every reflow: real work, and
            // a visible re-snap of the whole table right after it was drawn.
            let padL = block.width(for: .padding, edge: .minX)
            let padR = block.width(for: .padding, edge: .maxX)
            let borderL = block.width(for: .border, edge: .minX)
            let borderR = block.width(for: .border, edge: .maxX)
            // SUBTRACT BOTH IN FULL, exactly as `build` does — `collapsesBorders` is off, so nothing
            // is shared with a neighbour to double-account for, and `build` already left a non-owner
            // side at width 0 (see its Step B/C), so reading it back here and subtracting it in full
            // costs nothing extra. This formula must stay identical to the one in `build` or every
            // cell reads as "changed" on every reflow (see the note above: real work plus a visible
            // re-snap) — the old halving existed only to model AppKit's collapsing, which no longer
            // runs, and its perimeter-vs-interior distinction goes with it: every cell's own left/
            // right width, owner or not, is now exactly what it should be subtracted at, in full.
            let target = max(1, edges[c1] - edges[c0] - padL - padR - borderL - borderR)
            // Only cells whose width actually MOVES are touched. This pass runs on every reflow AND
            // in `display(_:)`'s tail, where the column usually hasn't changed at all — recording
            // every cell unconditionally meant invalidating the whole document to set widths to the
            // values they already had.
            guard abs(block.contentWidth - target) > 0.5 else { return }
            block.setContentWidth(target, type: .absoluteValueType)
            touched.append(range)
        }
        // Widths changed on the shared block objects; nudge layout to pick them up — ONCE, over the
        // span they cover, not once per cell. Measured on a 62-table Korean form (1,702 cell
        // paragraphs): per-cell invalidation cost 73 ms against 5 ms for a 610-cell Word report — a
        // 14× gap on 2.8× the cells, because each `invalidateLayout` call re-walks what follows it.
        // One call over the union is the same instruction to the layout manager, paid once.
        if let lower = touched.first?.location, let last = touched.last,
           let lm = storage.layoutManagers.first {
            let upper = min(storage.length, last.location + last.length)
            guard upper > lower else { return }
            lm.invalidateLayout(forCharacterRange: NSRange(location: lower, length: upper - lower),
                                actualCharacterRange: nil)
        }
    }
}
