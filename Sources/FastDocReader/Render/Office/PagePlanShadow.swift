import AppKit
import CFastdocEngine

/// S2 of `docs/plans/pagination-to-engine.md`: the engine's page plan run in SHADOW beside TextKit.
///
/// TextKit still decides where every line of a paged document lands (`PageBandLayoutDelegate`).
/// This takes the FINISHED layout, reports what it observed — each block's line boxes, each table
/// row's height, the flags the document declared — to `fastdoc_office_page_plan_json`, and diffs the
/// engine's answer against the page TextKit actually put each block and line on. Nothing here feeds
/// back into layout, and nothing calls it from the app: it is a probe (`PagePlanShadowProbeTests`),
/// so it costs a reader no first-paint time (invariants 55/65/101/113). Cutting macOS over to the
/// plan is S6, gated on this diff reaching zero.
///
/// The key the plan echoes is `MDAttr.blockId` — the OfficeBlock's position. The Avalonia host keys
/// by RenderTree node id; the engine treats both as an opaque number.
enum PagePlanShadow {
    /// One block as the observed layout shows it.
    struct ObservedBlock {
        var blockId: Int
        var isTable: Bool
        var firstLine: Int       // index into `lines`
        var lineCount: Int
        var macPage: Int         // the page of its first line (a table: of its top edge)
        var preview: String
        var detail: String       // TextKit local top, the block's height and the gap before it
        var macLocalTop: CGFloat
    }

    struct Report {
        var summary: [String] = []
        var planPages = 0
        var macPages = 0
        var blocks = 0
        var tables = 0
        var blocksOnADifferentPage = 0
        var linesOnADifferentPage = 0
        /// Lines inside tables the plan flowed line by line, and how many of them the plan placed on
        /// another page (or at another top) than TextKit did.
        var cellLines = 0
        var cellLinesOnADifferentPage = 0
        var firstDifference: String?
        var context: [String] = []
        var pagesWithADifferentFirstBlock = 0
        var droppedByPlan = 0
        var droppedByTextKit = 0
        var skippedReason: String?
        /// The sum of every table's laid-out height — what the engine's row model is compared with
        /// on a host that has no TextKit (S3: Avalonia's `--sheets` prints the same sum).
        var tableHeightTotal: CGFloat = 0
        /// Per top-level table in document order: its laid-out height and whether a page boundary
        /// fell inside it (TextKit shifts the lines below the boundary, so a crossed table's height
        /// carries the band and is not comparable).
        var tableHeights: [(height: CGFloat, crossed: Bool)] = []

        var text: String { summary.joined(separator: "\n") }
    }

    private struct Fragment {
        var location: Int
        var rect: NSRect
        var blockId: Int
        var table: ObjectIdentifier?
        var startingRow: Int
        var rowSpan: Int
        var top: CGFloat       // for a table cell: the cell's own top edge (padding + border included)
        var bottom: CGFloat
        var lineSpacing: CGFloat
        /// The line as the port's vocabulary has it, read from this same pass (no second layout).
        var box: RustEngineMeasure.LineBox
        var column: Int = 0
        var paragraphStart: Int = 0
        var spaceBefore: CGFloat = 0
        var spaceAfter: CGFloat = 0
        /// The cell blocks the line sits in, outermost first (a nested table adds one).
        var chain: [NSTextTableBlock] = []
    }

    private static func inset(_ block: NSTextTableBlock, _ edge: NSRectEdge) -> CGFloat {
        block.width(for: .padding, edge: edge) + block.width(for: .border, edge: edge)
    }

    /// The rows of the table at nesting `depth`, as the plan's flow wants them: every cell's items at
    /// their NATURAL offsets (a gap a page break opened between two of them is taken back out),
    /// nested tables as items of their own, and a row's height from its cells whenever a page
    /// boundary fell in or beside it (the observed distance to the next row then carries the gap).
    private static func flowRows(_ frags: [Fragment], depth: Int, blockIndex: Int, page: (CGFloat) -> Int,
                                 leading: CGFloat, pitch: CGFloat,
                                 refs: inout [(block: Int, row: Int, cell: Int, line: Int, page: Int, top: CGFloat, loc: Int)])
        -> (rows: [[String: Any]], height: CGFloat) {
        var order: [ObjectIdentifier] = []
        var byCell: [ObjectIdentifier: [Fragment]] = [:]
        for f in frags where f.chain.count > depth {
            let id = ObjectIdentifier(f.chain[depth])
            if byCell[id] == nil { order.append(id) }
            byCell[id, default: []].append(f)
        }
        let rowKeys = Set(order.map { byCell[$0]![0].chain[depth].startingRow }).sorted()
        let position = Dictionary(uniqueKeysWithValues: rowKeys.enumerated().map { ($1, $0) })
        var cellsOfRow: [Int: [[String: Any]]] = [:]
        var extentOfRow: [Int: CGFloat] = [:]
        var shiftedRows: Set<Int> = []
        var observedTop: [Int: CGFloat] = [:]
        var observedPage: [Int: Int] = [:]
        for id in order {
            let fs = byCell[id]!
            let block = fs[0].chain[depth]
            guard let at = position[block.startingRow] else { continue }
            let padTop = inset(block, .minY), padBottom = inset(block, .maxY)
            let top = fs[0].rect.minY - padTop
            if observedTop[at] == nil || top < observedTop[at]! { observedTop[at] = top; observedPage[at] = page(fs[0].rect.minY) }
            var items: [[String: Any]] = []
            var natural: CGFloat = 0
            var previous: (bottom: CGFloat, page: Int, spaceAfter: CGFloat, paragraph: Int)?
            let cellIndex = cellsOfRow[at, default: []].count
            var i = 0
            while i < fs.count {
                let f = fs[i]
                var item: [String: Any]
                var itemTop: CGFloat, itemBottom: CGFloat, itemHeight: CGFloat
                var last = f
                if f.chain.count > depth + 1 {
                    let nestedTable = ObjectIdentifier(f.chain[depth + 1].table)
                    var j = i
                    while j < fs.count, fs[j].chain.count > depth + 1,
                          ObjectIdentifier(fs[j].chain[depth + 1].table) == nestedTable { j += 1 }
                    let run = Array(fs[i..<j])
                    let sub = flowRows(run, depth: depth + 1, blockIndex: blockIndex, page: page, leading: leading,
                                       pitch: pitch, refs: &refs)
                    itemTop = run.map { $0.rect.minY - inset($0.chain[depth + 1], .minY) }.min()!
                    itemBottom = run.map { $0.rect.maxY + inset($0.chain[depth + 1], .maxY) }.max()!
                    itemHeight = sub.height
                    item = ["height": Double(itemHeight), "rows": sub.rows]
                    last = run.last!
                    i = j
                } else {
                    itemTop = f.rect.minY
                    itemBottom = f.rect.maxY
                    itemHeight = f.rect.height
                    item = ["height": Double(itemHeight), "trailing": Double(f.lineSpacing)]
                    if depth == 0 {
                        refs.append((block: blockIndex, row: at, cell: cellIndex, line: items.count,
                                     page: page(f.rect.minY), top: f.rect.minY - leading - CGFloat(page(f.rect.minY)) * pitch, loc: f.location))
                    }
                    i += 1
                }
                if let p = previous {
                    if p.page == page(f.rect.minY) {
                        natural += max(0, itemTop - p.bottom)
                    } else {
                        shiftedRows.insert(at)
                        natural += p.paragraph == f.paragraphStart ? 0 : p.spaceAfter + f.spaceBefore
                    }
                }
                item["top"] = Double(natural)
                items.append(item)
                natural += itemHeight
                previous = (itemBottom, page(last.rect.minY), last.spaceAfter, last.paragraphStart)
            }
            var cell: [String: Any] = ["padTop": Double(padTop), "padBottom": Double(padBottom),
                                       "contentHeight": Double(natural), "lines": items]
            if block.rowSpan > 1 { cell["rowSpan"] = block.rowSpan }
            cellsOfRow[at, default: []].append(cell)
            if block.rowSpan <= 1 { extentOfRow[at] = max(extentOfRow[at] ?? 0, padTop + natural + padBottom) }
        }
        var rows: [[String: Any]] = []
        var total: CGFloat = 0
        for r in rowKeys.indices {
            // The observed distance to the next row is the natural height only when nothing moved in
            // this row and the next row begins on the page this one did.
            var height = extentOfRow[r] ?? 0
            if !shiftedRows.contains(r), r + 1 < rowKeys.count, let a = observedTop[r], let b = observedTop[r + 1],
               observedPage[r] == observedPage[r + 1] {
                height = max(height, b - a)
            }
            total += height
            rows.append(["height": Double(height), "cells": cellsOfRow[r] ?? []])
        }
        return (rows, total)
    }

    /// Runs the plan over `wc`'s finished layout. `nil` when the document is not paged or the engine
    /// answered no plan; the reason is in `Report.skippedReason`.
    static func run(controller wc: DocumentWindowController) -> Report {
        var report = Report()
        let delegate = wc.pageBandDelegate
        guard delegate.pageContentHeight > 0, let lm = wc.textView.layoutManager,
              let tc = wc.textView.textContainer, let storage = wc.textView.textStorage,
              storage.length > 0 else {
            report.skippedReason = "not paged"
            return report
        }
        guard delegate.columnPlacements.isEmpty else {
            report.skippedReason = "multi-column runs (S5: columns are placed by character, not by the page rule)"
            return report
        }
        let pitch = delegate.pageContentHeight + delegate.band
        guard pitch > 0 else { report.skippedReason = "no page pitch"; return report }
        let leading = delegate.leadingBand
        func page(of y: CGFloat) -> Int {
            Int(PageBandLayoutDelegate.page(of: y, leadingBand: leading, pitch: pitch))
        }

        // ---- 1. one pass over the finished layout ----
        var fragments: [Fragment] = []
        let storageText = storage.string as NSString
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, glyphRange, _ in
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard chars.location >= 0, chars.location < storage.length,
                  let id = storage.attribute(MDAttr.blockId, at: chars.location, effectiveRange: nil) as? Int else { return }
            let paragraphRange = storageText.paragraphRange(for: NSRange(location: chars.location, length: 0))
            let terminated = paragraphRange.length > 0 && storageText.character(at: NSMaxRange(paragraphRange) - 1) == 10
            let box = RustEngineMeasure.observedLineBox(
                layout: lm, rect: rect, glyphRange: glyphRange, paragraph: 0,
                paragraphStart: paragraphRange.location, contentLength: paragraphRange.length - (terminated ? 1 : 0))
            let style = storage.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle
            var table: ObjectIdentifier?
            var startingRow = 0, rowSpan = 1, column = 0
            var top = rect.minY, bottom = rect.maxY
            if let cell = style?.textBlocks.first as? NSTextTableBlock {
                table = ObjectIdentifier(cell.table)
                startingRow = cell.startingRow
                column = cell.startingColumn
                rowSpan = cell.rowSpan
                top = rect.minY - cell.width(for: .padding, edge: .minY) - cell.width(for: .border, edge: .minY)
                bottom = rect.maxY + cell.width(for: .padding, edge: .maxY) + cell.width(for: .border, edge: .maxY)
            }
            fragments.append(Fragment(location: chars.location, rect: rect, blockId: id, table: table,
                                      startingRow: startingRow, rowSpan: rowSpan, top: top, bottom: bottom,
                                      lineSpacing: max(0, style?.lineSpacing ?? 0), box: box,
                                      column: column, paragraphStart: paragraphRange.location,
                                      spaceBefore: max(0, style?.paragraphSpacingBefore ?? 0),
                                      spaceAfter: max(0, style?.paragraphSpacing ?? 0),
                                      chain: (style?.textBlocks ?? []).compactMap { $0 as? NSTextTableBlock }))
        }
        guard !fragments.isEmpty else { report.skippedReason = "no line fragments"; return report }

        // ---- 2. group into blocks, in document order ----
        struct Group { var id: Int; var range: Range<Int> }
        var groups: [Group] = []
        for (i, f) in fragments.enumerated() {
            if let last = groups.last, last.id == f.blockId { groups[groups.count - 1].range = last.range.lowerBound..<(i + 1) }
            else { groups.append(Group(id: f.blockId, range: i..<(i + 1))) }
        }
        let text = storage.string as NSString

        var planBlocks: [[String: Any]] = []
        var cellLineRefs: [(block: Int, row: Int, cell: Int, line: Int, page: Int, top: CGFloat, loc: Int)] = []
        var observed: [ObservedBlock] = []
        var lineMacPages: [[Int]] = []          // per block, the page TextKit put each line on
        var previousBottom: CGFloat?
        var previousPage = -1
        for group in groups {
            let frags = Array(fragments[group.range])
            let first = frags[0]
            let isTable = first.table != nil
            let location = first.location
            var block: [String: Any] = ["key": group.id]
            if storage.attribute(MDAttr.startsPage, at: location, effectiveRange: nil) != nil { block["pageBreakBefore"] = true }
            if storage.attribute(MDAttr.keepWithNext, at: location, effectiveRange: nil) != nil { block["keepWithNext"] = true }
            let lastEnd = frags.map { $0.location }.max() ?? location
            let extent = NSRange(location: location, length: max(1, min(storage.length, lastEnd + 1) - location))
            let blockText = text.substring(with: extent)
            let blank = !isTable && blockText.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FFFC}"
            }
            if blank { block["empty"] = true }

            // The gap TextKit left between this block and the one before it, when neither was moved
            // across a page boundary: that is the paragraph spacing the plan adds itself.
            let top = isTable ? frags.map(\.top).min()! : first.rect.minY
            let topPage = page(of: top)
            var gap: CGFloat = 0
            if let previousBottom, previousPage == topPage { gap = max(0, top - previousBottom) }
            if gap > 0.001 { block["spacingBefore"] = gap }

            var macPages: [Int] = []
            if isTable {
                // Per row, as `DocumentWindowController.laidOutTables` reads it.
                var rows: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
                var spans: [(start: Int, end: Int)] = []
                for f in frags {
                    if f.rowSpan > 1 { spans.append((f.startingRow, f.startingRow + f.rowSpan)) }
                    if var row = rows[f.startingRow] {
                        row.top = min(row.top, f.top); row.bottom = max(row.bottom, f.bottom); rows[f.startingRow] = row
                    } else { rows[f.startingRow] = (f.top, f.bottom) }
                }
                let ordered = rows.keys.sorted()
                // The row heights the host reports are the layout's own BEFORE the page rule moved
                // anything: every band the rule opened inside this table is empty space the rows did
                // not have, so it is taken back out (the `proposedTableLineTops` idea of invariant 72,
                // applied to heights).
                let tableFirstTop = frags.map(\.top).min() ?? 0
                let bandsInside = delegate.openedBands.values.filter { $0.top > tableFirstTop + 0.5 }
                func natural(_ y: CGFloat) -> CGFloat {
                    y - bandsInside.filter { $0.top < y - 0.01 }.reduce(0) { $0 + $1.height }
                }
                let tableBottom = frags.map(\.bottom).max()!
                let tableTop = frags.map(\.top).min() ?? tableBottom
                report.tableHeightTotal += tableBottom - tableTop
                report.tableHeights.append((tableBottom - tableTop, page(of: tableTop) != page(of: frags.last!.rect.minY)))
                block["kind"] = "table"
                var rowEntries = ordered.enumerated().map { position, r -> [String: Any] in
                    let row = rows[r]!
                    let crossed = spans.contains { $0.start < r && $0.end > r }
                    // A row runs from its own top to the next row's top. Its cells' bottoms cannot say:
                    // a cell merged down several rows ends far below the row it starts in.
                    let end = position + 1 < ordered.count ? rows[ordered[position + 1]]!.top : tableBottom
                    var entry: [String: Any] = ["height": max(0, natural(end) - natural(row.top))]
                    if r != ordered.first && !crossed { entry["canBreakAbove"] = true }
                    return entry
                }
                // A table the reader breaks where it stands (invariant 64's over-tall pieces) flows line
                // by line, so the host reports what the flow needs: each cell's lines at their NATURAL
                // offsets (the gap a page break opened between two of them is taken back out) and the
                // cell's padding.
                let firstLocation = first.location, lastLocation = frags.last!.location
                let breaksWhereItStands = delegate.oversizedPieces.keys.contains { $0 >= firstLocation && $0 <= lastLocation }
                if breaksWhereItStands {
                    let built = flowRows(frags.filter { $0.table == first.table }, depth: 0, blockIndex: planBlocks.count,
                                         page: page, leading: leading, pitch: pitch, refs: &cellLineRefs)
                    if built.rows.count == rowEntries.count {
                        for position in rowEntries.indices {
                            rowEntries[position]["cells"] = built.rows[position]["cells"]
                            rowEntries[position]["height"] = built.rows[position]["height"]
                        }
                    }
                }
                block["rows"] = rowEntries
                if (storage.attribute(MDAttr.tableKeepsWhole, at: location, effectiveRange: nil) as? Bool) == true {
                    block["keepsWhole"] = true
                }
                macPages = [page(of: top)]
                previousBottom = frags.map(\.bottom).max()
                previousPage = page(of: frags.last!.rect.minY)
            } else {
                block["kind"] = "text"
                block["lines"] = frags.map { Double($0.box.height) }
                if first.lineSpacing > 0 { block["trailing"] = Double(first.lineSpacing) }
                macPages = frags.map { page(of: $0.rect.minY) }
                previousBottom = frags.last!.rect.maxY
                previousPage = page(of: frags.last!.rect.minY)
            }
            // A section start is deliberately NOT passed as one: TextKit opens a page only for
            // `startsPage`, so the per-page section answer is compared in S5, not here.
            planBlocks.append(block)
            lineMacPages.append(macPages)
            observed.append(ObservedBlock(
                blockId: group.id, isTable: isTable, firstLine: group.range.lowerBound,
                lineCount: frags.count, macPage: macPages[0],
                preview: String(blockText.prefix(24)).replacingOccurrences(of: "\n", with: " "),
                detail: String(format: "TextKit top %.1f, height %.1f, gap %.1f",
                               top - leading - CGFloat(macPages[0]) * pitch,
                               (isTable ? frags.map(\.bottom).max()! : frags.last!.rect.maxY) - top, gap),
                macLocalTop: top - leading - CGFloat(macPages[0]) * pitch))
        }

        // ---- 3. ask the engine ----
        let input: [String: Any] = [
            "planVersion": 1,
            "contentHeight": Double(delegate.pageContentHeight),
            "splitTables": wc.mdDocument?.pageOptions.splitTables ?? false,
            "band": Double(delegate.band),
            "noteBands": delegate.noteBands.sorted { $0.key < $1.key }.map { ["page": $0.key, "height": Double($0.value)] },
            "blocks": planBlocks,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: input),
              let reply = plan(json: json),
              let envelope = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let plan = envelope["ok"] as? [String: Any] else {
            report.skippedReason = "the engine returned no plan"
            return report
        }

        // ---- 4. diff ----
        // A flowed table's cell lines, each against the page and top TextKit gave it.
        var plannedCellLines: [String: (page: Int, top: Double)] = [:]
        for l in (plan["cellLines"] as? [[Any]]) ?? [] where l.count == 6 {
            let n = l.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            plannedCellLines["\(Int(n[0])),\(Int(n[1])),\(Int(n[2])),\(Int(n[3]))"] = (Int(n[4]), n[5])
        }
        for ref in cellLineRefs {
            report.cellLines += 1
            let planned = plannedCellLines["\(ref.block),\(ref.row),\(ref.cell),\(ref.line)"]
            guard let planned, planned.page == ref.page, abs(planned.top - Double(ref.top)) < 0.6 else {
                report.cellLinesOnADifferentPage += 1
                continue
            }
        }
        let planPages = plan["pageCount"] as? Int ?? 0
        let planLines = (plan["lines"] as? [[Any]]) ?? []
        let placements = (plan["placements"] as? [[String: Any]]) ?? []
        var planLinePage: [Int: [Int: Int]] = [:]       // block index -> line -> page
        for line in planLines {
            guard line.count == 4, let b = (line[0] as? NSNumber)?.intValue, let l = (line[1] as? NSNumber)?.intValue,
                  let p = (line[2] as? NSNumber)?.intValue else { continue }
            planLinePage[b, default: [:]][l] = p
        }
        var planBlockPage: [Int: Int] = [:]
        for placement in placements {
            if let b = placement["block"] as? Int, let p = placement["page"] as? Int, planBlockPage[b] == nil {
                planBlockPage[b] = p
            }
        }
        var planTops: [Int: Double] = [:]               // block index -> top of its first line / piece
        for line in planLines {
            if line.count == 4, let b = (line[0] as? NSNumber)?.intValue, let l = (line[1] as? NSNumber)?.intValue, l == 0,
               let t = (line[3] as? NSNumber)?.doubleValue { planTops[b] = t }
        }
        for placement in placements {
            if let b = placement["block"] as? Int, planTops[b] == nil, let t = placement["top"] as? Double { planTops[b] = t }
        }
        var planFirstOnPage: [Int: Int] = [:]
        var macFirstOnPage: [Int: Int] = [:]
        for (index, block) in observed.enumerated() {
            let planPage = block.isTable ? planBlockPage[index] : planLinePage[index]?[0]
            if let planPage, planFirstOnPage[planPage] == nil { planFirstOnPage[planPage] = block.blockId }
            if macFirstOnPage[block.macPage] == nil { macFirstOnPage[block.macPage] = block.blockId }
            if planPage != block.macPage {
                report.blocksOnADifferentPage += 1
                if report.firstDifference == nil {
                    report.firstDifference = "block \(block.blockId) \(block.isTable ? "table" : "text") \"\(block.preview)\": TextKit page \(block.macPage + 1), plan page \(planPage.map { String($0 + 1) } ?? "none")"
                    // The blocks just before it, each with TextKit's top and the plan's page and top.
                    var context: [String] = []
                    // Start at the earliest block of this TextKit page whose plan top has already drifted.
                    var from = index
                    while from > 0, observed[from - 1].macPage == block.macPage,
                          let t = planTops[from - 1], abs(Double(observed[from - 1].macLocalTop) - t) > 1 { from -= 1 }
                    for back in max(0, from - 2)...index {
                        let b = observed[back]
                        let planTop = planTops[back].map { String(format: "%.1f", $0) } ?? "-"
                        let planP = (b.isTable ? planBlockPage[back] : planLinePage[back]?[0]).map { String($0 + 1) } ?? "-"
                        context.append("SHADOW   [\(back)] \(b.isTable ? "table" : "text") \"\(b.preview)\" page \(b.macPage + 1)/plan \(planP): \(b.detail); plan top \(planTop)")
                    }
                    report.context = context
                }
            }
            if !block.isTable {
                for (l, macPage) in lineMacPages[index].enumerated() where planLinePage[index]?[l] != macPage {
                    report.linesOnADifferentPage += 1
                }
            }
            if block.isTable { report.tables += 1 }
        }
        report.pagesWithADifferentFirstBlock = Set(planFirstOnPage.keys).union(macFirstOnPage.keys)
            .filter { planFirstOnPage[$0] != macFirstOnPage[$0] }.count
        let lastMacPage = (observed.map { $0.macPage }.max() ?? 0)
        report.macPages = lastMacPage + 1
        report.planPages = planPages
        report.blocks = observed.count
        let rawBreaks = PageBandLayoutDelegate.markedParagraphs(MDAttr.startsPage, in: storage).count
        report.droppedByPlan = plan["droppedBreakCount"] as? Int ?? 0
        report.droppedByTextKit = max(0, rawBreaks - delegate.documentPageBreaks.count)
        report.summary = [
            "SHADOW pages: TextKit \(report.macPages), plan \(report.planPages) (reader reports \(wc.printPageCount))",
            "SHADOW blocks: \(report.blocks) (\(report.tables) tables); on a different page: \(report.blocksOnADifferentPage); lines on a different page: \(report.linesOnADifferentPage); flowed cell lines: \(report.cellLines), differing: \(report.cellLinesOnADifferentPage)",
            String(format: "SHADOW table height total: %.1f", Double(report.tableHeightTotal)),
            "SHADOW pages whose first block differs: \(report.pagesWithADifferentFirstBlock)",
            "SHADOW hard breaks dropped by 147: plan \(report.droppedByPlan), TextKit \(report.droppedByTextKit)",
            "SHADOW first difference: \(report.firstDifference ?? "none")",
        ] + report.context
        return report
    }

    static func plan(json: Data) -> Data? {
        var bytes = [UInt8](json)
        bytes.append(0)
        let out: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                fastdoc_office_page_plan_json(nil, $0)
            }
        }
        guard let out else { return nil }
        defer { fastdoc_string_free(out) }
        return String(cString: out).data(using: .utf8)
    }
}
