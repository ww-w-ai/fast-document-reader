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
        var heightMac: CGFloat = 0   // the block's height in TextKit
    }

    struct Report {
        var summary: [String] = []
        var planPages = 0
        /// The pages the reader prints. A columned document is then laid out again as the stack the
        /// plan models; `stackPages` is that stack's own page count.
        var macPages = 0
        var stackPages = 0
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
        /// One tab-separated row per block (`FMD_PLAN_SHADOW_BLOCKS`): index, kind, TextKit page,
        /// TextKit page-local top, height, plan page, plan top, spacing before, lines or rows, flags, text.
        var blockRows: [String] = []
        var cellDump: [String] = []
        var pagesWithADifferentFirstBlock = 0
        var droppedByPlan = 0
        var droppedByTextKit = 0
        var skippedReason: String?
        /// What the plan decided about the sheet itself, against what the reader settled on: pages
        /// compared, and how many differ in their section, running head, foot, master page, printed
        /// number or number veto.
        var furniturePages = 0
        var furnitureDifferences: [String: Int] = [:]
        var furnitureFirstDifference: String?
        /// Footnotes: the plan's bands against the reader's, and the pages that cite notes.
        var noteBandsTextKit: [Int: CGFloat] = [:]
        var noteBandsPlan: [Int: Double] = [:]
        var noteAssignmentDifferences = 0
        /// Lines inside columned runs, and how many the plan dealt to another page, top or column.
        var columnLines = 0
        var columnLinesDifferent = 0
        var columnFirstDifference: String?
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
        /// The height of the glyphs the line holds (`usedRect`): the fragment adds the paragraph's
        /// spacing after when this is the paragraph's last line.
        var usedHeight: CGFloat = 0
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
            // The cell's box encloses what its last line USES; the paragraph spacing after that line
            // adds to the fragment, not to the box.
            if depth == 0, let tail = fs.last, tail.chain.count <= depth + 1, tail.rect.height - tail.usedHeight > 0.01 {
                cell["boxContent"] = Double(natural - (tail.rect.height - tail.usedHeight))
            }
            // Where the document puts the content in the cell's box is the plan's to apply.
            switch block.verticalAlignment {
            case .middleAlignment: cell["verticalAlign"] = "middle"
            case .bottomAlignment: cell["verticalAlign"] = "bottom"
            default: break
            }
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

    // MARK: - What the reader decided, read before the probe touches the layout

    /// Everything TextKit's reader settled on for each page — the section, the head, foot and master
    /// page that apply, the printed number, the footnote bands and the column map — taken from the
    /// FINISHED layout. A column document is then laid out again as the stack the plan models, so
    /// these are read first.
    struct MacFacts {
        var pageCount = 0
        var sections: [Int?] = []
        var headers: [Int?] = []
        var footers: [Int?] = []
        var masters: [Int?] = []
        var numbers: [Int] = []
        var hidden: Set<Int> = []
        /// What the reader itself prints (`hiddenPageNumberPages`), which differs from `hidden` where
        /// two vetoing paragraphs are adjacent.
        var hiddenByReader: Set<Int> = []
        var footnotePages: [Int: [Int]] = [:]
        var noteBands: [Int: CGFloat] = [:]
        var columnPlacements: [Int: (x: CGFloat, y: CGFloat)] = [:]
    }

    /// The pages a document's own vetoes land on, read paragraph by paragraph. The reader's
    /// `hiddenPageNumberPages` asks where each attribute RUN begins, and two consecutive vetoing
    /// paragraphs are one run (equal values merge): the second one's page is never asked about.
    /// 1790387's contents page is one such second paragraph — the document hides its number, the
    /// reader prints it. The plan answers per block, as the document declared.
    private static func hiddenPages(_ wc: DocumentWindowController) -> Set<Int> {
        guard let storage = wc.textView.textStorage, storage.length > 0, let lm = wc.textView.layoutManager,
              wc.pageBandDelegate.isActive else { return [] }
        let pitch = PagePagination.pitch(pageContentHeight: wc.pageBandDelegate.pageContentHeight, band: wc.pageBandDelegate.band)
        guard pitch > 0 else { return [] }
        let text = storage.string as NSString
        var out: Set<Int> = []
        storage.enumerateAttribute(MDAttr.hidesPageNumber, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value as? Bool == true else { return }
            var at = range.location
            while at < NSMaxRange(range) {
                let glyph = lm.glyphIndexForCharacter(at: at)
                let frame = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let page = PageBandLayoutDelegate.page(of: frame.minY, leadingBand: wc.pageBandDelegate.leadingBand, pitch: pitch)
                if page >= 0 { out.insert(Int(page)) }
                at = max(at + 1, NSMaxRange(text.paragraphRange(for: NSRange(location: at, length: 0))))
            }
        }
        return out
    }

    static func macFacts(_ wc: DocumentWindowController) -> MacFacts {
        var facts = MacFacts()
        facts.pageCount = wc.printPageCount
        facts.columnPlacements = wc.pageBandDelegate.columnPlacements
        facts.noteBands = wc.pageBandDelegate.noteBands
        facts.footnotePages = wc.footnotePages
        facts.hiddenByReader = wc.hiddenPageNumberPages
        facts.hidden = hiddenPages(wc)
        let content = wc.pageBandContent
        let master = wc.masterPageContent
        for page in 0..<facts.pageCount {
            let section = wc.sectionOfPage(page)
            facts.sections.append(section)
            facts.numbers.append(wc.displayedPageNumber(page))
            func pick(_ entries: [OfficeHeaderFooter], _ hiding: Set<Int>) -> Int? {
                PageBandPainter.applicableEntry(entries, pageIndex: page, section: section, hiddenSections: hiding)
                    .flatMap { entry in entries.firstIndex(of: entry) }
            }
            facts.headers.append(content.flatMap { pick($0.headers, $0.sectionsHidingHeader) })
            facts.footers.append(content.flatMap { pick($0.footers, $0.sectionsHidingFooter) })
            var chosen: Int?
            if let master, !(section.map { master.sectionsHidingMasterPage.contains($0) } ?? false),
               let found = MasterPagePainter.applicablePage(master.pages, pageIndex: page, section: section) {
                chosen = master.pages.firstIndex(of: found)
            }
            facts.masters.append(chosen)
        }
        return facts
    }

    private static func appliesName(_ a: HeaderFooterApplicability) -> String {
        switch a {
        case .defaultPages: return "defaultPages"
        case .firstPage: return "firstPage"
        case .evenPages: return "evenPages"
        case .oddPages: return "oddPages"
        }
    }

    private static func entries(_ list: [OfficeHeaderFooter]) -> [[String: Any]] {
        list.map { var e: [String: Any] = ["appliesTo": appliesName($0.appliesTo)]; if let s = $0.section { e["section"] = s }; return e }
    }

    /// The part of the plan input that is about the sheet rather than the flow.
    private static func furnitureInput(_ wc: DocumentWindowController) -> [String: Any] {
        guard let doc = wc.mdDocument else { return [:] }
        var out: [String: Any] = [:]
        if let content = wc.pageBandContent {
            out["headers"] = entries(content.headers)
            out["footers"] = entries(content.footers)
            out["sectionsHidingHeader"] = content.sectionsHidingHeader.sorted()
            out["sectionsHidingFooter"] = content.sectionsHidingFooter.sorted()
        }
        if let master = wc.masterPageContent {
            out["masters"] = master.pages.map { ["appliesTo": appliesName($0.appliesTo), "section": $0.section] as [String: Any] }
            out["sectionsHidingMaster"] = master.sectionsHidingMasterPage.sorted()
        }
        if !wc.footnotes.isEmpty {
            out["notes"] = wc.footnotes.map { ["number": $0.number, "height": Double(wc.footnoteHeights[$0.number] ?? 0)] as [String: Any] }
            out["separators"] = doc.officeSections.enumerated().compactMap { index, section -> [String: Any]? in
                guard let s = section.footnoteSeparator, s.isDeclared else { return nil }
                return ["section": index, "lineType": s.lineType, "lineWidth": Double(s.lineWidthPt),
                        "marginTop": Double(s.marginTopPt), "marginBottom": Double(s.marginBottomPt),
                        "noteSpacing": Double(s.noteSpacingPt)]
            }
        }
        return out
    }

    private static func columnRunsInput(_ runs: [(range: NSRange, layout: OfficeColumnLayout)]) -> [[String: Any]] {
        runs.map { run in
            let l = run.layout
            return ["count": l.count, "spacing": Double(l.spacing), "widths": l.widths.map(Double.init),
                    "gaps": l.gaps.map(Double.init), "proportional": l.proportional]
        }
    }

    /// Puts `wc` in the state `--pdf` and ⌘P print from: the print grid (band without the desk gap,
    /// invariant 161c), tables settled for paper, and the trailing footer reserved — the same three
    /// calls `makePrintOperation` makes before it builds the operation. A shadow taken on the SCREEN
    /// grid lays the 편람 out at 403 pages where `--pdf` gives 391, so the probe measures this layout.
    static func layOutForPrint(_ wc: DocumentWindowController) {
        if let tc = wc.textView.textContainer { wc.textView.layoutManager?.ensureLayout(for: tc) }
        wc.applyTrailingFooterBand()
        // `HeadlessPDF.run` stops here and runs the operation; building it is what lays the document
        // out for paper (print layout, tables settled, every picture loaded), so the probe builds
        // it too and measures the layout `--pdf` prints.
        _ = wc.makePrintOperation()
        if let tc = wc.textView.textContainer { wc.textView.layoutManager?.ensureLayout(for: tc) }
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
        report.macPages = wc.printPageCount
        let pitch = delegate.pageContentHeight + delegate.band
        guard pitch > 0 else { report.skippedReason = "no page pitch"; return report }
        let leading = delegate.leadingBand
        // What the reader settled on, read before the layout is touched. A columned document is then
        // laid out again WITHOUT its column map: the plan models the run as one stack dealt into
        // columns afterwards, so the stack is what the host observes (invariant 100).
        let facts = macFacts(wc)
        let columnRuns = wc.columnRunRanges()
        if !delegate.columnPlacements.isEmpty {
            delegate.columnPlacements = [:]
            delegate.columnOpenedBoundaries = []
            lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            lm.ensureLayout(for: tc)
        }
        func page(of y: CGFloat) -> Int {
            Int(PageBandLayoutDelegate.page(of: y, leadingBand: leading, pitch: pitch))
        }

        // ---- 1. one pass over the finished layout ----
        var fragments: [Fragment] = []
        let storageText = storage.string as NSString
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, usedRect, _, glyphRange, _ in
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
                // The cell's own box as the layout stored it: a row is as tall as its cells' boxes,
                // wherever a vertically centred or bottom-aligned cell put its lines inside one.
                let box = lm.boundsRect(for: cell, at: glyphRange.location, effectiveRange: nil)
                if box.height > 0, box.minY <= rect.minY + 0.01, box.maxY >= rect.maxY - 0.01 { top = box.minY; bottom = box.maxY }
            }
            fragments.append(Fragment(location: chars.location, rect: rect, blockId: id, table: table,
                                      startingRow: startingRow, rowSpan: rowSpan, top: top, bottom: bottom,
                                      lineSpacing: max(0, style?.lineSpacing ?? 0), box: box,
                                      usedHeight: usedRect.height,
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
        var columnCellRefs: [(block: Int, row: Int, cell: Int, line: Int, page: Int, top: CGFloat, loc: Int)] = []
        var observed: [ObservedBlock] = []
        var lineMacPages: [[Int]] = []          // per block, the page TextKit put each line on
        var previousBottom: CGFloat?
        var previousPage = -1
        for (groupIndex, group) in groups.enumerated() {
            let frags = Array(fragments[group.range])
            let first = frags[0]
            let isTable = first.table != nil
            let location = first.location
            var block: [String: Any] = ["key": group.id]
            // Where the block ends in the text, for the markers it carries.
            let endLocation = groupIndex + 1 < groups.count ? fragments[groups[groupIndex + 1].range.lowerBound].location : storage.length
            let extentRange = NSRange(location: location, length: max(0, endLocation - location))
            if let run = columnRuns.firstIndex(where: { NSLocationInRange(location, $0.range) }) { block["columnRun"] = run }
            var restart: Int?
            var hides = false
            storage.enumerateAttribute(MDAttr.pageNumberRestart, in: extentRange) { value, _, stop in
                if let n = (value as? NSNumber)?.intValue { restart = n; stop.pointee = true }
            }
            storage.enumerateAttribute(MDAttr.hidesPageNumber, in: extentRange) { value, _, stop in
                if value as? Bool == true { hides = true; stop.pointee = true }
            }
            if let restart { block["pageNumberRestart"] = restart }
            if hides { block["hidesPageNumber"] = true }
            var cites: [[String: Any]] = []
            storage.enumerateAttribute(MDAttr.footnoteRef, in: extentRange) { value, range, _ in
                guard let number = (value as? NSNumber)?.intValue else { return }
                var cite: [String: Any] = ["note": number]
                if !isTable, let line = frags.lastIndex(where: { $0.location <= range.location }) { cite["line"] = line }
                cites.append(cite)
            }
            if !cites.isEmpty { block["cites"] = cites }
            if storage.attribute(MDAttr.startsPage, at: location, effectiveRange: nil) != nil {
                block["pageBreakBefore"] = true
            }
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
            // A section that really opened its own sheet in the reader's layout names its section to
            // the plan. One whose break the reader dropped (invariant 147) or that continued on the
            // page it began on opened nothing, and the plan is not told it did.
            if storage.attribute(MDAttr.sectionIndex, at: location, effectiveRange: nil) != nil {
                block[block["pageBreakBefore"] != nil && topPage > previousPage ? "sectionStart" : "sectionMarker"] = true
            }

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
                if (ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_ROWS"] ?? "").split(separator: ",").compactMap({ Int($0) }).contains(planBlocks.count) {
                    for r in ordered {
                        report.cellDump.append("SHADOW   row [\(planBlocks.count)] \(r): top \(String(format: "%.1f", Double(rows[r]!.top))) bottom \(String(format: "%.1f", Double(rows[r]!.bottom))) spans \(spans.filter { $0.start == r }.map { $0.end - $0.start })")
                    }
                }
                if (ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_CELLBOX"] ?? "").split(separator: ",").compactMap({ Int($0) }).contains(planBlocks.count) {
                    var seen: [ObjectIdentifier] = []
                    var by: [ObjectIdentifier: [Fragment]] = [:]
                    for f in frags where f.table == first.table && !f.chain.isEmpty {
                        let id = ObjectIdentifier(f.chain[0])
                        if by[id] == nil { seen.append(id) }
                        by[id, default: []].append(f)
                    }
                    // The cells of a table nested one level down.
                    var nestedSeen: [ObjectIdentifier] = []
                    var nestedBy: [ObjectIdentifier: [Fragment]] = [:]
                    for f in frags where f.table == first.table && f.chain.count > 1 {
                        let id = ObjectIdentifier(f.chain[1])
                        if nestedBy[id] == nil { nestedSeen.append(id) }
                        nestedBy[id, default: []].append(f)
                    }
                    for id in nestedSeen {
                        let fs = nestedBy[id]!, cell = fs[0].chain[1]
                        let box = lm.boundsRect(for: cell, at: lm.glyphIndexForCharacter(at: fs[0].location), effectiveRange: nil)
                        report.cellDump.append("SHADOW   nestedbox [\(planBlocks.count)] r\(cell.startingRow)+\(cell.rowSpan) c\(cell.startingColumn)+\(cell.columnSpan) va\(cell.verticalAlignment.rawValue) box \(String(format: "%.2f", Double(box.minY)))..\(String(format: "%.2f", Double(box.maxY))) lines \(String(format: "%.2f", Double(fs.map { $0.rect.minY }.min()!)))..\(String(format: "%.2f", Double(fs.map { $0.rect.maxY }.max()!))) n\(fs.count) pad \(String(format: "%.2f", Double(inset(cell, .minY))))/\(String(format: "%.2f", Double(inset(cell, .maxY))))")
                    }
                    for id in seen {
                        let fs = by[id]!, cell = fs[0].chain[0]
                        let box = lm.boundsRect(for: cell, at: lm.glyphIndexForCharacter(at: fs[0].location), effectiveRange: nil)
                        report.cellDump.append("SHADOW   cellbox [\(planBlocks.count)] r\(cell.startingRow)+\(cell.rowSpan) c\(cell.startingColumn)+\(cell.columnSpan) va\(cell.verticalAlignment.rawValue) box \(String(format: "%.2f", Double(box.minY)))..\(String(format: "%.2f", Double(box.maxY))) lines \(String(format: "%.2f", Double(fs.map { $0.rect.minY }.min()!)))..\(String(format: "%.2f", Double(fs.map { $0.rect.maxY }.max()!))) n\(fs.count) pad \(String(format: "%.2f", Double(inset(cell, .minY))))/\(String(format: "%.2f", Double(inset(cell, .maxY)))) nested \(fs.contains { $0.chain.count > 1 }) lastLS \(String(format: "%.2f", Double(fs.last!.lineSpacing))) lastH \(String(format: "%.2f", Double(fs.last!.rect.height))) boxH \(String(format: "%.2f", Double(fs.last!.box.height))) used \(String(format: "%.2f", Double(lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: fs.last!.location), effectiveRange: nil).height))) spaceAfter \(String(format: "%.2f", Double(fs.last!.spaceAfter))) spaceBefore \(String(format: "%.2f", Double(fs.first!.spaceBefore)))")
                    }
                }
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
                // A row's top is the least of its own cells' tops and every later row's: rows never run
                // upward, and a cell that is vertically centred (or sits in a merge) has its lines — and
                // so its measured top — below the row it starts in.
                var rowTop: [Int: CGFloat] = [:]
                var lowest = CGFloat.greatestFiniteMagnitude
                for r in ordered.reversed() { lowest = min(lowest, rows[r]!.top); rowTop[r] = lowest }
                var rowEntries = ordered.enumerated().map { position, r -> [String: Any] in
                    let crossed = spans.contains { $0.start < r && $0.end > r }
                    // A row runs from its own top to the next row's top. Its cells' bottoms cannot say:
                    // a cell merged down several rows ends far below the row it starts in.
                    let end = position + 1 < ordered.count ? rowTop[ordered[position + 1]]! : tableBottom
                    var entry: [String: Any] = ["height": max(0, natural(end) - natural(rowTop[r]!))]
                    if r != ordered.first && !crossed { entry["canBreakAbove"] = true }
                    return entry
                }
                // A table the reader breaks where it stands (invariant 64's over-tall pieces) flows line
                // by line, so the host reports what the flow needs: each cell's lines at their NATURAL
                // offsets (the gap a page break opened between two of them is taken back out) and the
                // cell's padding.
                let firstLocation = first.location, lastLocation = frags.last!.location
                let breaksWhereItStands = delegate.oversizedPieces.keys.contains { $0 >= firstLocation && $0 <= lastLocation }
                // A table in a columned run is dealt line by line too, from where its lines fall.
                let inColumnRun = block["columnRun"] != nil
                if breaksWhereItStands || inColumnRun {
                    var measured: [(block: Int, row: Int, cell: Int, line: Int, page: Int, top: CGFloat, loc: Int)] = []
                    let built = flowRows(frags.filter { $0.table == first.table }, depth: 0, blockIndex: planBlocks.count,
                                         page: page, leading: leading, pitch: pitch, refs: &measured)
                    // Positions in the stack of a columned run are not the plan's final ones.
                    if inColumnRun { columnCellRefs.append(contentsOf: measured) } else { cellLineRefs.append(contentsOf: measured) }
                    if built.rows.count == rowEntries.count {
                        for position in rowEntries.indices {
                            rowEntries[position]["observedHeight"] = rowEntries[position]["height"]
                            rowEntries[position]["cells"] = built.rows[position]["cells"]
                            // A table in a columned run is sized by the engine from its cells (the rule
                            // of `table_rows.rs`); the other tables the flow breaks take the heights the
                            // cells add up to.
                            if !inColumnRun { rowEntries[position]["height"] = built.rows[position]["height"] }
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
                macLocalTop: top - leading - CGFloat(macPages[0]) * pitch,
                heightMac: (isTable ? frags.map(\.bottom).max()! : frags.last!.rect.maxY) - top))
        }

        // ---- 3. ask the engine ----
        // With notes the plan runs the band fixpoint itself, so the reader's bands are NOT handed in:
        // they are what the plan's own answer is compared with.
        var input: [String: Any] = [
            "planVersion": 1,
            "contentHeight": Double(delegate.pageContentHeight),
            "splitTables": wc.mdDocument?.pageOptions.splitTables ?? false,
            "band": Double(delegate.band),
            "leadingBand": Double(leading),
            "bodyWidth": Double(delegate.columnBodyWidth),
            "columnRuns": columnRunsInput(columnRuns),
            "noteBands": wc.footnotes.isEmpty
                ? facts.noteBands.sorted { $0.key < $1.key }.map { ["page": $0.key, "height": Double($0.value)] }
                : [],
            "blocks": planBlocks,
        ]
        input.merge(furnitureInput(wc)) { a, _ in a }
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
        // FMD_PLAN_SHADOW_CELLS=<block>[,<block>...]: every flowed cell line of those blocks against the
        // plan, with the reader's own pulls (`pullToNextPage`) and the plan's marked.
        let dumpedBlocks = Set((ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_CELLS"] ?? "").split(separator: ",").compactMap { Int($0) })
        let planPulls = Set(((plan["pulledLines"] as? [[Any]]) ?? []).map { $0.map { "\(($0 as? NSNumber)?.intValue ?? -1)" }.joined(separator: ",") })
        // A table the reader's record calls oversized can be one the plan does not flow: the record only
        // grows (`oversizedPieces`), so a piece measured tall in an early round stays "broken where it
        // stands" after the final layout holds it whole. The plan then places it by row pieces and has
        // no cell lines to compare. Each such line is checked against the piece the plan put its row
        // in: same page, and its top inside that piece.
        var pieces: [Int: [(page: Int, top: Double, bottom: Double, rows: Range<Int>)]] = [:]
        for placement in (plan["placements"] as? [[String: Any]]) ?? [] {
            guard let b = placement["block"] as? Int, let p = placement["page"] as? Int,
                  let start = placement["rowStart"] as? Int, let count = placement["rowCount"] as? Int,
                  let top = (placement["top"] as? NSNumber)?.doubleValue,
                  let height = (placement["height"] as? NSNumber)?.doubleValue else { continue }
            pieces[b, default: []].append((p, top, top + height, start..<(start + count)))
        }
        let flowedBlocks = Set(plannedCellLines.keys.compactMap { $0.split(separator: ",").first.flatMap { Int($0) } })
        for ref in cellLineRefs {
            report.cellLines += 1
            if !flowedBlocks.contains(ref.block) {
                let inPiece = (pieces[ref.block] ?? []).contains {
                    $0.rows.contains(ref.row) && $0.page == ref.page && Double(ref.top) > $0.top - 0.6 && Double(ref.top) < $0.bottom + 0.6
                }
                if !inPiece {
                    report.cellLinesOnADifferentPage += 1
                    if dumpedBlocks.contains(ref.block) {
                        report.cellDump.append("SHADOW   cell [\(ref.block)] r\(ref.row) c\(ref.cell) l\(ref.line): TextKit p\(ref.page + 1) top \(String(format: "%.1f", Double(ref.top))); plan pieces \((pieces[ref.block] ?? []).map { "p\($0.page + 1) \(String(format: "%.1f", $0.top))..\(String(format: "%.1f", $0.bottom)) rows \($0.rows)" }) DIFF")
                    }
                }
                continue
            }
            let planned = plannedCellLines["\(ref.block),\(ref.row),\(ref.cell),\(ref.line)"]
            if dumpedBlocks.contains(ref.block) {
                let ok = planned.map { $0.page == ref.page && abs($0.top - Double(ref.top)) < 0.6 } ?? false
                let pulled = delegate.pullToNextPage.contains(ref.loc) ? " PULLED(TextKit)" : ""
                let planPulled = planPulls.contains("\(ref.block),\(ref.row),\(ref.cell),\(ref.line)") ? " PULLED(plan)" : ""
                report.cellDump.append("SHADOW   cell [\(ref.block)] r\(ref.row) c\(ref.cell) l\(ref.line): TextKit p\(ref.page + 1) top \(String(format: "%.3f", Double(ref.top))); plan p\(planned.map { String($0.page + 1) } ?? "-") top \(planned.map { String(format: "%.3f", $0.top) } ?? "-")\(ok ? "" : " DIFF")\(pulled)\(planPulled)")
            }
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
        // FMD_PLAN_SHADOW_PLACEMENTS=<block>[,<block>...]: every piece the plan placed for those blocks.
        let placedBlocks = Set((ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_PLACEMENTS"] ?? "").split(separator: ",").compactMap { Int($0) })
        for placement in placements {
            if let b = placement["block"] as? Int, placedBlocks.contains(b) {
                report.cellDump.append("SHADOW   placed [\(b)] page \(placement["page"] ?? "-") top \(placement["top"] ?? "-") height \(placement["height"] ?? "-") rows \(placement["rowStart"] ?? "-")+\(placement["rowCount"] ?? "-") flowed \(placement["flowed"] ?? "-")")
            }
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
            // A block under a column run is dealt into columns by the plan; it is compared against
            // the reader's column map below, not against the stack it was measured in.
            let inRun = planBlocks[index]["columnRun"] != nil
            if !inRun, planPage != block.macPage {
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
            if !block.isTable, !inRun {
                for (l, macPage) in lineMacPages[index].enumerated() where planLinePage[index]?[l] != macPage {
                    report.linesOnADifferentPage += 1
                }
            }
            if block.isTable { report.tables += 1 }
            // One row per block for `FMD_PLAN_SHADOW_BLOCKS`: what TextKit did and what the plan did.
            let pb = planBlocks[index]
            let flags = ["pageBreakBefore", "keepWithNext", "sectionStart", "sectionMarker", "empty", "keepsWhole", "columnRun", "hidesPageNumber", "pageNumberRestart"]
                .filter { pb[$0] != nil }.joined(separator: ",")
            let heights = ((pb["lines"] as? [Double]) ?? ((pb["rows"] as? [[String: Any]]) ?? []).compactMap { row -> Double? in
                (row["height"] as? Double) ?? (row["height"] as? CGFloat).map(Double.init) })
                .map { String(format: "%.1f", $0) }.joined(separator: ",")
            // For a table the reader breaks line by line: each row's observed height beside the one the
            // plan was given (they differ where a spanning or centred cell decides the row).
            let observedHeights = ((pb["rows"] as? [[String: Any]]) ?? []).compactMap { row -> String? in
                (row["observedHeight"] as? Double).map { String(format: "%.1f", $0) } }.joined(separator: ",")
            let planTopText = planTops[index].map { String(format: "%.1f", $0) } ?? "-"
            let planPageText = planPage.map { String($0 + 1) } ?? "-"
            let spacing = String(format: "%.1f", (pb["spacingBefore"] as? Double) ?? 0)
            let macTop = String(format: "%.1f", Double(block.macLocalTop)), macHeight = String(format: "%.1f", Double(block.heightMac))
            report.blockRows.append([String(index), block.isTable ? "table" : "text", String(block.macPage + 1), macTop, macHeight,
                                     planPageText, planTopText, spacing, heights, flags, block.preview, observedHeights,
                                     String(format: "%.2f", (pb["trailing"] as? Double) ?? 0)].joined(separator: "\t"))
        }
        report.pagesWithADifferentFirstBlock = Set(planFirstOnPage.keys).union(macFirstOnPage.keys)
            .filter { planFirstOnPage[$0] != macFirstOnPage[$0] }.count
        // ---- 5. the sheet itself: section, head, foot, master, number, notes, columns ----
        let planSheets = (plan["pages"] as? [[String: Any]]) ?? []
        report.furniturePages = min(planSheets.count, facts.pageCount)
        func note(_ kind: String, page: Int, _ mac: Any?, _ planned: Any?) {
            report.furnitureDifferences[kind, default: 0] += 1
            if report.furnitureFirstDifference == nil {
                report.furnitureFirstDifference = "\(kind) on page \(page + 1): TextKit \(mac.map { "\($0)" } ?? "none"), plan \(planned.map { "\($0)" } ?? "none")"
            }
        }
        for page in 0..<report.furniturePages {
            let sheet = planSheets[page]
            let planSection = (sheet["section"] as? Int)
            if let macSection = facts.sections[page], macSection != planSection { note("section", page: page, macSection, planSection) }
            if facts.headers[page] != (sheet["header"] as? Int) { note("header", page: page, facts.headers[page], sheet["header"]) }
            if facts.footers[page] != (sheet["footer"] as? Int) { note("footer", page: page, facts.footers[page], sheet["footer"]) }
            if facts.masters[page] != (sheet["master"] as? Int) { note("master", page: page, facts.masters[page], sheet["master"]) }
            if facts.numbers[page] != (sheet["number"] as? Int) { note("number", page: page, facts.numbers[page], sheet["number"]) }
            if facts.hidden.contains(page) != ((sheet["numberHidden"] as? Bool) ?? false) {
                note("numberHidden", page: page, facts.hidden.contains(page), sheet["numberHidden"])
            }
        }
        if !wc.footnotes.isEmpty {
            report.noteBandsTextKit = facts.noteBands
            for pair in (plan["noteBands"] as? [[Any]]) ?? [] where pair.count == 2 {
                if let page = (pair[0] as? NSNumber)?.intValue, let height = (pair[1] as? NSNumber)?.doubleValue { report.noteBandsPlan[page] = height }
            }
            var planned: [Int: [Int]] = [:]
            for pair in (plan["notesByPage"] as? [[Any]]) ?? [] where pair.count == 2 {
                if let page = (pair[0] as? NSNumber)?.intValue, let list = pair[1] as? [NSNumber] { planned[page] = list.map(\.intValue) }
            }
            let pagesNamed = Set(planned.keys).union(facts.footnotePages.keys)
            report.noteAssignmentDifferences = pagesNamed.filter { planned[$0] != facts.footnotePages[$0] }.count
        }
        if !facts.columnPlacements.isEmpty {
            // The stack itself — the same blocks planned with the column runs left out — against the
            // stack TextKit measured, line by line: a difference here is the stack's, not the deal's.
            if ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_COLUMNS"] != nil {
                var flat = input
                flat["blocks"] = planBlocks.map { var b = $0; b.removeValue(forKey: "columnRun"); return b }
                if let data = try? JSONSerialization.data(withJSONObject: flat), let reply = Self.plan(json: data),
                   let envelope = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                   let flatPlan = envelope["ok"] as? [String: Any] {
                    var stackTop: [String: (Int, Double)] = [:]
                    for line in (flatPlan["lines"] as? [[Any]]) ?? [] where line.count == 4 {
                        if let b = (line[0] as? NSNumber)?.intValue, let l = (line[1] as? NSNumber)?.intValue,
                           let p = (line[2] as? NSNumber)?.intValue, let t = (line[3] as? NSNumber)?.doubleValue { stackTop["\(b),\(l)"] = (p, t) }
                    }
                    // The cell lines of the stack: the plan's flat answer against the observed stack.
                    var flatCells: [String: (Int, Double)] = [:]
                    for l in (flatPlan["cellLines"] as? [[Any]]) ?? [] where l.count == 6 {
                        let n = l.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                        flatCells["\(Int(n[0])),\(Int(n[1])),\(Int(n[2])),\(Int(n[3]))"] = (Int(n[4]), n[5])
                    }
                    var stackCellsDifferent = 0, stackCellsShown = 0
                    for ref in columnCellRefs {
                        let planned = flatCells["\(ref.block),\(ref.row),\(ref.cell),\(ref.line)"]
                        if planned?.0 != ref.page || abs((planned?.1 ?? .infinity) - Double(ref.top)) > 0.6 {
                            stackCellsDifferent += 1
                            if stackCellsShown < 6 {
                                stackCellsShown += 1
                                report.context.append("SHADOW   stackcell [\(ref.block)] r\(ref.row) c\(ref.cell) l\(ref.line): TextKit p\(ref.page + 1) top \(String(format: "%.1f", Double(ref.top))); plan p\(planned.map { String($0.0 + 1) } ?? "-") top \(planned.map { String(format: "%.1f", $0.1) } ?? "-")")
                            }
                        }
                    }
                    report.context.append("SHADOW   stack cell lines: \(columnCellRefs.count), different \(stackCellsDifferent)")
                    var shown = 0
                    for (blockIndex, group) in groups.enumerated() where planBlocks[blockIndex]["columnRun"] != nil && !observed[blockIndex].isTable {
                        for (line, frag) in fragments[group.range].enumerated() {
                            let macPage = page(of: frag.rect.minY)
                            let macTop = Double(frag.rect.minY - leading - CGFloat(macPage) * pitch)
                            guard let planned = stackTop["\(blockIndex),\(line)"], planned.0 != macPage || abs(planned.1 - macTop) > 0.6, shown < 6 else { continue }
                            shown += 1
                            report.context.append("SHADOW   stack [\(blockIndex)] line \(line): TextKit p\(macPage + 1) top \(String(format: "%.1f", macTop)); plan p\(planned.0 + 1) top \(String(format: "%.1f", planned.1)); pitch \(pitch) content \(delegate.pageContentHeight) band \(delegate.band) leading \(leading)")
                        }
                    }
                }
            }
            var columnOf: [String: Int] = [:]
            for entry in (plan["columnLines"] as? [[Any]]) ?? [] where entry.count == 3 {
                let n = entry.compactMap { ($0 as? NSNumber)?.intValue }
                if n.count == 3 { columnOf["\(n[0]),\(n[1])"] = n[2] }
            }
            // Cell lines of the tables in the runs: each against where the reader's column map put it.
            var planCellColumn: [String: Int] = [:]
            for entry in (plan["columnCellLines"] as? [[Any]]) ?? [] where entry.count == 5 {
                let n = entry.compactMap { ($0 as? NSNumber)?.intValue }
                if n.count == 5 { planCellColumn["\(n[0]),\(n[1]),\(n[2]),\(n[3])"] = n[4] }
            }
            var cellsShown = 0
            if ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_PULLS"] != nil {
                var kitOnly: [String] = [], planOnly: [String] = [], both = 0
                for ref in columnCellRefs {
                    let key = "\(ref.block),\(ref.row),\(ref.cell),\(ref.line)"
                    let kit = delegate.pullToNextPage.contains(ref.loc), planned = planPulls.contains(key)
                    if kit && planned { both += 1 } else if kit { kitOnly.append(key) } else if planned { planOnly.append(key) }
                }
                report.context.append("SHADOW   column-table pulls: both \(both), TextKit only \(kitOnly.count) \(kitOnly.prefix(12)), plan only \(planOnly.count) \(planOnly.prefix(12))")
            }
            let stackDumped = Set((ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_STACKCELLS"] ?? "").split(separator: ",").compactMap { Int($0) })
            for ref in columnCellRefs {
                if stackDumped.contains(ref.block) {
                    report.cellDump.append("SHADOW   stackref [\(ref.block)] r\(ref.row) c\(ref.cell) l\(ref.line): stack p\(ref.page + 1) top \(String(format: "%.2f", Double(ref.top)))\(delegate.pullToNextPage.contains(ref.loc) ? " PULLED(TextKit)" : "")")
                }
                guard let target = facts.columnPlacements[ref.loc] else { continue }
                report.columnLines += 1
                let macPage = page(of: target.y)
                let macTop = Double(target.y - leading - CGFloat(macPage) * pitch)
                let key = "\(ref.block),\(ref.row),\(ref.cell),\(ref.line)"
                let planned = plannedCellLines[key]
                if planned?.page != macPage || abs((planned?.top ?? .infinity) - macTop) > 0.6 {
                    report.columnLinesDifferent += 1
                    if cellsShown < 4 {
                        cellsShown += 1
                        report.context.append("SHADOW   cell [\(ref.block)] row \(ref.row) cell \(ref.cell) line \(ref.line): TextKit p\(macPage + 1) top \(String(format: "%.1f", macTop)) (stack p\(ref.page + 1) top \(String(format: "%.1f", Double(ref.top)))); plan p\(planned.map { String($0.page + 1) } ?? "-") top \(planned.map { String(format: "%.1f", $0.top) } ?? "-")")
                    }
                }
            }
            var planLineTop: [String: Double] = [:]
            for line in planLines where line.count == 4 {
                if let b = (line[0] as? NSNumber)?.intValue, let l = (line[1] as? NSNumber)?.intValue, let t = (line[3] as? NSNumber)?.doubleValue {
                    planLineTop["\(b),\(l)"] = t
                }
            }
            for (blockIndex, group) in groups.enumerated() where planBlocks[blockIndex]["columnRun"] != nil && !observed[blockIndex].isTable {
                let frags = Array(fragments[group.range])
                guard let run = columnRuns.firstIndex(where: { NSLocationInRange(frags[0].location, $0.range) }) else { continue }
                let columns = ColumnGeometry.columns(inWidth: delegate.columnBodyWidth, layout: columnRuns[run].layout)
                for (line, frag) in frags.enumerated() {
                    guard let target = facts.columnPlacements[frag.location] else { continue }
                    report.columnLines += 1
                    let macPage = page(of: target.y)
                    let macTop = Double(target.y - leading - CGFloat(macPage) * pitch)
                    let macColumn = columns.firstIndex { abs($0.x - target.x) < 0.5 } ?? 0
                    let planPage = planLinePage[blockIndex]?[line]
                    let planTop = planLineTop["\(blockIndex),\(line)"]
                    if ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_COLUMNS"] != nil {
                        report.context.append("SHADOW   col [\(blockIndex)] line \(line) \(observed[blockIndex].preview.prefix(10)): TextKit p\(macPage + 1) top \(String(format: "%.1f", macTop)) col \(macColumn) (stack top \(String(format: "%.1f", frag.rect.minY - leading)) h \(String(format: "%.1f", frag.rect.height))); plan p\(planPage.map { String($0 + 1) } ?? "-") top \(planTop.map { String(format: "%.1f", $0) } ?? "-") col \(columnOf["\(blockIndex),\(line)"].map(String.init) ?? "-")")
                    }
                    if planPage != macPage || abs((planTop ?? .infinity) - macTop) > 0.6 || columnOf["\(blockIndex),\(line)"] != macColumn {
                        report.columnLinesDifferent += 1
                        if report.columnFirstDifference == nil {
                            report.columnFirstDifference = "block \(group.id) line \(line): TextKit page \(macPage + 1) top \(String(format: "%.1f", macTop)) column \(macColumn), plan page \(planPage.map { String($0 + 1) } ?? "none") top \(planTop.map { String(format: "%.1f", $0) } ?? "none") column \(columnOf["\(blockIndex),\(line)"].map(String.init) ?? "none")"
                        }
                    }
                }
            }
        }
        let lastMacPage = (observed.map { $0.macPage }.max() ?? 0)
        report.stackPages = lastMacPage + 1
        report.planPages = planPages
        report.blocks = observed.count
        let rawBreaks = PageBandLayoutDelegate.markedParagraphs(MDAttr.startsPage, in: storage).count
        report.droppedByPlan = plan["droppedBreakCount"] as? Int ?? 0
        report.droppedByTextKit = max(0, rawBreaks - delegate.documentPageBreaks.count)
        report.summary = [
            "SHADOW pages: TextKit \(report.macPages), plan \(report.planPages) (reader reports \(facts.pageCount); observed stack \(report.stackPages))",
            "SHADOW grid: content \(delegate.pageContentHeight) band \(delegate.band) leading \(leading) pitch \(pitch)",
            "SHADOW settle records: pushed \(delegate.pushedTables.count), oversized \(delegate.oversizedPieces.count), pulled \(delegate.pullToNextPage.count), opened bands \(delegate.openedBands.count), keepWithNext \(delegate.keepWithNextRanges.count), page breaks \(delegate.documentPageBreaks.count)",
            "SHADOW blocks: \(report.blocks) (\(report.tables) tables); on a different page: \(report.blocksOnADifferentPage); lines on a different page: \(report.linesOnADifferentPage); flowed cell lines: \(report.cellLines), differing: \(report.cellLinesOnADifferentPage)",
            String(format: "SHADOW table height total: %.1f", Double(report.tableHeightTotal)),
            "SHADOW pages whose first block differs: \(report.pagesWithADifferentFirstBlock)",
            "SHADOW hard breaks dropped by 147: plan \(report.droppedByPlan), TextKit \(report.droppedByTextKit)",
            "SHADOW first difference: \(report.firstDifference ?? "none")",
            "SHADOW sheets: \(report.furniturePages) pages compared; differences \(report.furnitureDifferences.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ").nonEmpty ?? "none"); first: \(report.furnitureFirstDifference ?? "none")",
            "SHADOW reader's own number vetoes differ from the document's on pages: \(facts.hiddenByReader.symmetricDifference(facts.hidden).sorted().map { String($0 + 1) }.joined(separator: " ").nonEmpty ?? "none")",
            "SHADOW footnotes: TextKit bands \(report.noteBandsTextKit.sorted { $0.key < $1.key }.map { "\($0.key + 1):\(String(format: "%.1f", Double($0.value)))" }.joined(separator: " ")); plan bands \(report.noteBandsPlan.sorted { $0.key < $1.key }.map { "\($0.key + 1):\(String(format: "%.1f", $0.value))" }.joined(separator: " ")); pages whose cited notes differ: \(report.noteAssignmentDifferences)",
            "SHADOW columns: \(report.columnLines) lines in columned runs, different: \(report.columnLinesDifferent); first: \(report.columnFirstDifference ?? "none")",
        ] + report.context + report.cellDump
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
