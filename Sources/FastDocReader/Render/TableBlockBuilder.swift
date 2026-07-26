import AppKit

/// An `NSTextTable` that remembers its columns' PROPORTIONS (summing to 1) so the table can be
/// re-solved to ABSOLUTE integer point widths at whatever reading-column width the window currently
/// has. Percentage column widths are the wrong tool: `NSTextTable` recomputes them per row, so a
/// column boundary lands on a slightly different fractional pixel in a 4-cell row than in a
/// span-merged one — the "열이 살짝 어긋남" drift. Absolute widths, computed once as a cumulative sum of
/// rounded integer edges, put every row's column boundary at the SAME integer x by construction.
final class GridTextTable: NSTextTable {
    var columnProportions: [CGFloat] = []   // one per column, sums to 1
    /// Integer cumulative x-edges (ncol+1) inside `width` — the shared grid every cell reads.
    ///
    /// One point of `width` is held back. With `collapsesBorders` on, AppKit charges roughly half a
    /// rule at the table's own outer edges that a cell cannot account for through its content width
    /// (proved by measurement: changing the outer share from a full rule to half moved the laid-out
    /// total by exactly nothing, while the interior share moved it point for point). Solving the grid
    /// inside `width` rather than across it leaves that slack unclaimed, so the table lands just
    /// UNDER the reading column instead of half a point over it — and half a point over is not
    /// harmless: the container clips it, and the right-hand rule of the last column disappears.
    func edges(forWidth width: CGFloat) -> [CGFloat] {
        let usable = max(1, width - 1)
        var out: [CGFloat] = [0]
        var cum: CGFloat = 0
        for p in columnProportions { cum += p; out.append((usable * cum).rounded()) }
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
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        // Solve the grid at the width the table will ACTUALLY be displayed at when the caller knows
        // it. Building at the placeholder and letting `resizeTables` correct it a moment later is
        // what made a table visibly shrink and then snap wider on every render — two paints of the
        // same table, the first one wrong. The placeholder stays as the default for callers with no
        // real width yet (markdown's renderer, and any build before a window exists).
        let edges = table.edges(forWidth: width)

        for placement in placements {
            let header = placement.row < headerRows
            // cell-direct > table-direct > table-STYLE (P5) > theme default — unchanged resolution.
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

            let block = NSTextTableBlock(table: table,
                                         startingRow: placement.row, rowSpan: placement.rowSpan,
                                         startingColumn: placement.col, columnSpan: placement.colSpan)
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
            // Did this table say ANYTHING about borders (a cell's own edges, or the table's)? That
            // one question separates the two silences: an edge nobody mentioned inside an otherwise
            // bordered table, from a table that declared nothing at all — every markdown/HWP/ODT
            // table and any docx without `w:tblBorders`/`w:tcBorders` — which must reach the theme
            // default in the final arm, byte-identical to before any of this existed (invariant 37).
            let declared = (cellEdges.map { !$0.isEmpty } ?? false) || (tableEdges.map { !$0.isEmpty } ?? false)
            // Whether the TABLE drew a box is a different question. A cell that merely turned ONE of
            // its own edges off — what Word writes when someone selects a cell and removes a single
            // rule — says nothing about the other three, and those must keep resolving through
            // `borderWidth`/`borderColor` above so the cell still matches its neighbours. Treating
            // any declaration as "this table describes its own geometry" made that one cell render
            // thin and open on the edges nobody touched, which is the ragged-table fault this whole
            // per-edge path exists to remove.
            let tableDrewABox = tableEdges?.drawsAnyEdge ?? false
            // Step 1 — INHERIT: a cell's own declaration wins; otherwise it takes the table's OUTER
            // edge where it sits on that side of the grid and the table's INTERIOR edge where it
            // doesn't. Still a declaration at this point, not yet a rule to draw.
            func declaration(_ own: BorderDecl?, outer: BorderDecl?, inside: BorderDecl?,
                             isOuter: Bool) -> BorderDecl? {
                own ?? (isOuter ? outer : inside)
            }
            // Step 2 — RESOLVE a declaration to what is actually drawn. `.suppressed` draws nothing,
            // deliberately and finally. An UNSPECIFIED edge depends on whether the TABLE drew a box:
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
            func side(_ decl: BorderDecl?) -> BorderSide? {
                switch decl {
                case .drawn(let stated): return stated
                case .suppressed: return nil
                case nil:
                    return tableDrewABox ? nil : BorderSide(width: borderWidth, color: borderColor)
                }
            }
            let t = side(declaration(cellEdges?.top, outer: tableEdges?.top,
                                     inside: tableEdges?.insideH, isOuter: onTop))
            let b = side(declaration(cellEdges?.bottom, outer: tableEdges?.bottom,
                                     inside: tableEdges?.insideH, isOuter: onBottom))
            let l = side(declaration(cellEdges?.left, outer: tableEdges?.left,
                                     inside: tableEdges?.insideV, isOuter: onLeft))
            let r = side(declaration(cellEdges?.right, outer: tableEdges?.right,
                                     inside: tableEdges?.insideV, isOuter: onRight))
            // Four edges that agree need only the UNIFORM setters — two calls instead of twelve. Most
            // cells in most documents are uniform, and a table-heavy report has thousands of them: the
            // per-edge path measured ~25 ms of extra ObjC traffic on a 2,489-cell document, paid on
            // every font change. Only a cell whose edges genuinely differ pays for the difference.
            let uniform = t == b && b == l && l == r
            let perEdge = !uniform && declared
            var leftWidth = borderWidth, rightWidth = borderWidth
            if uniform, declared {
                // Every edge the same AND declared — honour it uniformly. `t == nil` here is not
                // "nothing was said", it is every edge resolving to nothing to draw (a table that
                // turned all of them off), so it sets width 0 rather than falling through to the
                // theme default the document just removed. `declared` is the whole guard: a table
                // that said nothing never enters this arm.
                block.setBorderColor(t?.color ?? borderColor)
                block.setWidth(t?.width ?? 0, type: .absoluteValueType, for: .border)
                leftWidth = t?.width ?? 0
                rightWidth = t?.width ?? 0
            } else if perEdge {
                // One colour call for the common case, then only the edges that actually differ —
                // a table-heavy report runs this thousands of times per font change, and most edges
                // either state no colour (auto) or the same one.
                block.setBorderColor(borderColor)
                for (edge, spec) in [(NSRectEdge.minY, t), (.maxY, b), (.minX, l), (.maxX, r)] {
                    block.setWidth(spec?.width ?? 0, type: .absoluteValueType, for: .border, edge: edge)
                    if let c = spec?.color, c != borderColor { block.setBorderColor(c, for: edge) }
                }
                leftWidth = l?.width ?? 0
                rightWidth = r?.width ?? 0
            } else {
                block.setBorderColor(borderColor)
                block.setWidth(borderWidth, type: .absoluteValueType, for: .border)
            }
            block.setWidth(padding, type: .absoluteValueType, for: .padding)
            // ABSOLUTE integer content width: the cell's integer span width minus its own padding and
            // borders, so every row's column boundary lands on the same integer x (no percentage
            // drift). The LEFT and RIGHT edges are subtracted individually — with per-edge borders
            // they legitimately differ, and subtracting one of them twice moves the column boundary.
            let cellWidth = edges[min(placement.col + placement.colSpan, ncol)] - edges[placement.col]
            // Interior borders are SHARED — `collapsesBorders` is on, so AppKit charges the rule
            // between two cells ONCE. Subtracting the full width from BOTH neighbours spent it twice,
            // and every extra column cost another border: measured against a 600pt reading column, a
            // 2-column table finished 1.5pt short and a 9-column one 8.5pt. Two tables of different
            // shapes in one report therefore ended at visibly different x, which reads as a ragged
            // document. An OUTER edge belongs to its cell alone and is still subtracted in full.
            let lShare = onLeft ? leftWidth : leftWidth / 2
            let rShare = onRight ? rightWidth : rightWidth / 2
            block.setContentWidth(max(1, cellWidth - 2 * padding - lShare - rShare),
                                  type: .absoluteValueType)
            if let background { block.backgroundColor = background }
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
            // HALVE an INTERIOR border, exactly as `build` does — `collapsesBorders` charges a shared
            // rule once, and this formula must stay identical to the one in `build` or every cell
            // reads as "changed" on every reflow (see the note above: real work plus a visible
            // re-snap). An edge on the table's perimeter is that cell's alone and counts in full.
            let lShare = c0 == 0 ? borderL : borderL / 2
            let rShare = c1 >= ncol ? borderR : borderR / 2
            let target = max(1, edges[c1] - edges[c0] - padL - padR - lShare - rShare)
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
