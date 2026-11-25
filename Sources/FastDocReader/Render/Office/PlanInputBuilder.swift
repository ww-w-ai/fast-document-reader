import AppKit

/// S6b2-0f: the page plan's input, built from an observed layout.
///
/// A host that lets the engine decide pagination observes its text once, in a layout nobody
/// paginated (`PlanObservation`), and hands the engine what it measured: every line's box, every
/// table's rows and cells, the document's page-bearing marks. This is that observation as a unit: the
/// observer walk, the fragments it yields, the blocks they group into, and the input the engine is
/// asked with (`naturalInput`). `PlanAppliedParity` checks the applied layout against the plan.
enum PlanInputBuilder {

    struct Fragment {
        var location: Int
        var rect: NSRect
        var blockId: Int
        var table: ObjectIdentifier?
        var startingRow: Int
        var rowSpan: Int
        var top: CGFloat       // for a table cell: the cell's own top edge (padding + border included)
        var bottom: CGFloat
        /// A table cell: where the cell's own box ends, which the spacing after its last line hangs
        /// below. Equal to `bottom` for anything else.
        var boxBottom: CGFloat = 0
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

    static func inset(_ block: NSTextTableBlock, _ edge: NSRectEdge) -> CGFloat {
        block.width(for: .padding, edge: edge) + block.width(for: .border, edge: edge)
    }

    /// Where one depth-0 cell line sits in the rows `flowRows` reports, by its text location.
    typealias CellRef = (row: Int, cell: Int, line: Int, loc: Int)

    /// The rows of the table at nesting `depth`, as the plan's flow wants them: every cell's items at
    /// their natural offsets, nested tables as items of their own, and a row's height the larger of
    /// its cells' extent and the observed distance to the next row.
    static func flowRows(_ frags: [Fragment], depth: Int, refs: inout [CellRef])
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
        var observedTop: [Int: CGFloat] = [:]
        for id in order {
            let fs = byCell[id]!
            let block = fs[0].chain[depth]
            guard let at = position[block.startingRow] else { continue }
            let padTop = inset(block, .minY), padBottom = inset(block, .maxY)
            let top = fs[0].rect.minY - padTop
            if observedTop[at] == nil || top < observedTop[at]! { observedTop[at] = top }
            var items: [[String: Any]] = []
            var natural: CGFloat = 0
            var previousBottom: CGFloat?
            let cellIndex = cellsOfRow[at, default: []].count
            var i = 0
            while i < fs.count {
                let f = fs[i]
                var item: [String: Any]
                var itemTop: CGFloat, itemBottom: CGFloat, itemHeight: CGFloat
                if f.chain.count > depth + 1 {
                    let nestedTable = ObjectIdentifier(f.chain[depth + 1].table)
                    var j = i
                    while j < fs.count, fs[j].chain.count > depth + 1,
                          ObjectIdentifier(fs[j].chain[depth + 1].table) == nestedTable { j += 1 }
                    let run = Array(fs[i..<j])
                    let sub = flowRows(run, depth: depth + 1, refs: &refs)
                    itemTop = run.map { $0.rect.minY - inset($0.chain[depth + 1], .minY) }.min()!
                    itemBottom = run.map { $0.rect.maxY + inset($0.chain[depth + 1], .maxY) }.max()!
                    itemHeight = sub.height
                    item = ["height": Double(itemHeight), "rows": sub.rows]
                    i = j
                } else {
                    itemTop = f.rect.minY
                    itemBottom = f.rect.maxY
                    itemHeight = f.rect.height
                    item = ["height": Double(itemHeight), "trailing": Double(f.lineSpacing), "loc": f.location]
                    if depth == 0 {
                        refs.append((row: at, cell: cellIndex, line: items.count, loc: f.location))
                    }
                    i += 1
                }
                if let previousBottom { natural += max(0, itemTop - previousBottom) }
                item["top"] = Double(natural)
                items.append(item)
                natural += itemHeight
                previousBottom = itemBottom
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
            var height = extentOfRow[r] ?? 0
            if r + 1 < rowKeys.count, let a = observedTop[r], let b = observedTop[r + 1] {
                height = max(height, b - a)
            }
            total += height
            rows.append(["height": Double(height), "cells": cellsOfRow[r] ?? []])
        }
        return (rows, total)
    }

    // MARK: - Fragments and blocks

    struct Group { var id: Int; var range: Range<Int> }

    /// The text and the column runs a build reads.
    struct Source {
        var storage: NSTextStorage
        var columnRuns: [(range: NSRange, layout: OfficeColumnLayout)]
    }

    /// Every line fragment of a layout, in order, as the plan's host reads it. The visible layout
    /// and the natural observer are read by this same function.
    static func collect(_ lm: NSLayoutManager, _ tc: NSTextContainer, storage: NSTextStorage,
                        glyphs: NSRange? = nil) -> [Fragment] {
        let storageText = storage.string as NSString
        var fragments: [Fragment] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs ?? lm.glyphRange(for: tc)) { rect, usedRect, _, glyphRange, _ in
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
            var boxBottom: CGFloat?
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
                if box.height > 0, box.minY <= rect.minY + 0.01 { boxBottom = box.maxY }
            }
            fragments.append(Fragment(location: chars.location, rect: rect, blockId: id, table: table,
                                      startingRow: startingRow, rowSpan: rowSpan, top: top, bottom: bottom,
                                      boxBottom: boxBottom ?? bottom,
                                      lineSpacing: max(0, style?.lineSpacing ?? 0), box: box,
                                      usedHeight: usedRect.height,
                                      column: column, paragraphStart: paragraphRange.location,
                                      spaceBefore: max(0, style?.paragraphSpacingBefore ?? 0),
                                      spaceAfter: max(0, style?.paragraphSpacing ?? 0),
                                      chain: (style?.textBlocks ?? []).compactMap { $0 as? NSTextTableBlock }))
        }
        return fragments
    }

    /// The fragments, in order, as consecutive runs of one block.
    static func group(_ fragments: [Fragment]) -> [Group] {
        var groups: [Group] = []
        for (i, f) in fragments.enumerated() {
            if let last = groups.last, last.id == f.blockId { groups[groups.count - 1].range = last.range.lowerBound..<(i + 1) }
            else { groups.append(Group(id: f.blockId, range: i..<(i + 1))) }
        }
        return groups
    }

    /// Turns a natural observation's fragments (`PlanObservation`, a layout nobody paginated) into the
    /// plan's blocks: every line's box, every table's rows and cells, the page-bearing marks as facts.
    /// Nothing here reads a page: whether a section opens a sheet, which table flows and where
    /// anything lands are the plan's to decide.
    static func build(_ fragments: [Fragment], _ groups: [Group], source: Source, proposedTops: [Int: CGFloat] = [:]) -> [[String: Any]] {
        let storage = source.storage, columnRuns = source.columnRuns
        let text = storage.string as NSString
        var planBlocks: [[String: Any]] = []
        var previousBottom: CGFloat?
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
            var citeLocations: [Int] = []
            storage.enumerateAttribute(MDAttr.footnoteRef, in: extentRange) { value, range, _ in
                guard let number = (value as? NSNumber)?.intValue else { return }
                citeLocations.append(range.location)
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

            // The gap TextKit left between this block and the one before it: the paragraph spacing
            // the plan adds itself.
            let top = isTable ? frags.map(\.top).min()! : first.rect.minY
            let gap = previousBottom.map { max(0, top - $0) } ?? 0
            if gap > 0.001 { block["spacingBefore"] = gap }
            // A fact only: whether the section opens a sheet is the plan's to say (invariant 147).
            if storage.attribute(MDAttr.sectionIndex, at: location, effectiveRange: nil) != nil { block["section"] = true }

            if isTable {
                var rows: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
                var spans: [(start: Int, end: Int)] = []
                for f in frags {
                    if f.rowSpan > 1 { spans.append((f.startingRow, f.startingRow + f.rowSpan)) }
                    if var row = rows[f.startingRow] {
                        row.top = min(row.top, f.top); row.bottom = max(row.bottom, f.bottom); rows[f.startingRow] = row
                    } else { rows[f.startingRow] = (f.top, f.bottom) }
                }
                let ordered = rows.keys.sorted()
                let tableBottom = frags.map(\.bottom).max()!
                let tableTop = frags.map(\.top).min() ?? tableBottom
                block["kind"] = "table"
                // A row's top is the least of its own cells' tops and every later row's: rows never run
                // upward, and a cell that is vertically centred (or sits in a merge) has its lines — and
                // so its measured top — below the row it starts in.
                var rowTop: [Int: CGFloat] = [:]
                var lowest = CGFloat.greatestFiniteMagnitude
                for r in ordered.reversed() { lowest = min(lowest, rows[r]!.top); rowTop[r] = lowest }
                // The block after a table starts at the lower of two things: the cells' boxes, and the
                // last line the typesetter placed (the last cell's, spacing after included). One answer
                // per table, not per row (it read every fragment once per row).
                let lastRow = ordered.last ?? 0
                let boxesEnd = frags.lazy
                    .filter { f in f.chain.first.map { $0.startingRow + $0.rowSpan > lastRow } ?? false }
                    .map(\.boxBottom).max()
                let lastLineEnd = frags.last { !$0.chain.isEmpty }?.rect.maxY
                let cellsEnd = boxesEnd.map { max($0, lastLineEnd ?? $0) }
                // Only a hang is taken back: a hair of border width between the two measures is not one.
                let lastEnd = cellsEnd.map { tableBottom - $0 > 0.5 ? $0 : tableBottom } ?? tableBottom
                var rowEntries = ordered.enumerated().map { position, r -> [String: Any] in
                    let crossed = spans.contains { $0.start < r && $0.end > r }
                    // A row runs from its own top to the next row's top. Its cells' bottoms cannot say:
                    // a cell merged down several rows ends far below the row it starts in.
                    let end = position + 1 < ordered.count ? rowTop[ordered[position + 1]]! : lastEnd
                    var entry: [String: Any] = ["height": max(0, end - rowTop[r]!)]
                    if r != ordered.first && !crossed { entry["canBreakAbove"] = true }
                    return entry
                }
                let boxHeights = rowEntries.map { ($0["height"] as? Double) ?? 0 }
                // A table in a columned run is sized by the engine from its cells (the rule of
                // `table_rows.rs`); every other table keeps the layout's own rows.
                let inColumnRun = block["columnRun"] != nil
                if !inColumnRun { block["rowsObserved"] = true }
                block["firstLoc"] = first.location
                // What the group holds outside its cells (the separators a table ends in): lines of
                // their own that the plan places, so the apply pass never has to guess where they go.
                let tail = frags.filter { $0.chain.isEmpty }
                if !tail.isEmpty { block["tail"] = tail.map { ["loc": $0.location, "height": Double($0.rect.height)] as [String: Any] } }
                if let proposed = proposedTops[first.location] { block["firstLineInset"] = Double(proposed - tableTop) }
                // Every table hands in its cells: which one flows line by line is the plan's call.
                var measured: [CellRef] = []
                let flowed = flowRows(frags.filter { $0.table == first.table }, depth: 0, refs: &measured)
                // A marker in a table the plan flows stands on the page of ITS line, not of the
                // table's start: name the cell line that holds it (a marker in a nested table
                // names none, and is cited from where the table starts).
                if !inColumnRun, !cites.isEmpty, cites.count == citeLocations.count {
                    for (n, marker) in citeLocations.enumerated() {
                        guard let holder = frags.last(where: { $0.location <= marker }),
                              holder.chain.count == 1,
                              let ref = measured.first(where: { $0.loc == holder.location }) else { continue }
                        cites[n]["cell"] = [ref.row, ref.cell, ref.line]
                    }
                    block["cites"] = cites
                }
                if flowed.rows.count == rowEntries.count {
                    for position in rowEntries.indices {
                        rowEntries[position]["observedHeight"] = rowEntries[position]["height"]
                        rowEntries[position]["cells"] = flowed.rows[position]["cells"]
                    }
                }
                block["rows"] = rowEntries
                // Where each row's lines end, spacing after the last one included: the rule that carries
                // a piece to the next page asks that, not where the row's box ends.
                var lineBottom: [Int: CGFloat] = [:]
                for f in frags {
                    guard let cell = f.chain.first else { continue }
                    let bottom = f.rect.maxY + cell.width(for: .padding, edge: .maxY) + cell.width(for: .border, edge: .maxY)
                    lineBottom[f.startingRow] = max(lineBottom[f.startingRow] ?? bottom, bottom)
                }
                let reach = ordered.map { r in max(0, (lineBottom[r] ?? rows[r]!.bottom) - rowTop[r]!) }
                if zip(reach, boxHeights).contains(where: { Double($0) > $1 + 0.01 }) {
                    block["rowReach"] = reach.map { Double($0) }
                }
                if (storage.attribute(MDAttr.tableKeepsWhole, at: location, effectiveRange: nil) as? Bool) == true {
                    block["keepsWhole"] = true
                }
                previousBottom = tableBottom
            } else {
                block["kind"] = "text"
                block["lines"] = frags.map { Double($0.box.height) }
                block["lineLocs"] = frags.map { $0.location }
                if first.lineSpacing > 0 { block["trailing"] = Double(first.lineSpacing) }
                previousBottom = frags.last!.rect.maxY
            }
            planBlocks.append(block)
        }
        return planBlocks
    }

    // MARK: - The natural observation

    /// A layout nobody paginated, read by `collect`: the fragments, their blocks, and where the
    /// typesetter proposed each table's first line (`PlanObservationDelegate`).
    struct Observation {
        var fragments: [Fragment]
        var groups: [Group]
        var proposedTableLineTops: [Int: CGFloat]
    }

    /// Lays `storage` out on a second layout manager sized like `container`, in the chunked walk the
    /// visible layout uses, reads it, and removes the observer again.
    static func observeNaturally(storage: NSTextStorage, like container: NSTextContainer) -> Observation {
        let observer = PlanObservation(storage: storage, like: container)
        observer.walk()
        let fragments = collect(observer.layout, observer.container, storage: storage)
        let proposed = observer.recorder.proposedTableLineTops
        observer.remove()
        return Observation(fragments: fragments, groups: group(fragments), proposedTableLineTops: proposed)
    }

    /// A natural observation of only the HEAD of the text: the lines whose natural top lies above
    /// `reach`. `complete` says the head was the whole document.
    static func observePrefix(storage: NSTextStorage, like container: NSTextContainer,
                              reach: CGFloat) -> (observation: Observation, complete: Bool) {
        let observer = PlanObservation(storage: storage, like: container)
        defer { observer.remove() }
        let area = NSRect(x: 0, y: 0, width: container.size.width, height: reach)
        observer.layout.ensureLayout(forBoundingRect: area, in: observer.container)
        let glyphs = observer.layout.glyphRange(forBoundingRect: area, in: observer.container)
        let fragments = collect(observer.layout, observer.container, storage: storage, glyphs: glyphs)
        let complete = observer.layout.firstUnlaidCharacterIndex() >= storage.length
        return (Observation(fragments: fragments, groups: group(fragments),
                            proposedTableLineTops: observer.recorder.proposedTableLineTops), complete)
    }

    /// The plan input for the first screen only (`truncated: true` unless the head is the whole
    /// document): the blocks the observation holds, less the last, which the walk may have cut in
    /// the middle. `nil` when the document is not paged or the head holds no complete block.
    static func naturalPrefixInput(controller wc: DocumentWindowController, reach: CGFloat) -> NaturalInput? {
        let delegate = wc.pageBandDelegate
        guard delegate.pageContentHeight > 0, let tc = wc.textView.textContainer,
              let storage = wc.textView.textStorage, storage.length > 0 else { return nil }
        let pitch = delegate.pageContentHeight + delegate.band - delegate.deskGap
        guard pitch > 0 else { return nil }
        let columnRuns = wc.columnRunRanges()
        let (observation, complete) = observePrefix(storage: storage, like: tc, reach: reach)
        guard !observation.fragments.isEmpty else { return nil }
        let source = Source(storage: storage, columnRuns: columnRuns)
        var blocks = build(observation.fragments, observation.groups, source: source, proposedTops: observation.proposedTableLineTops)
        if !complete { blocks.removeLast() }
        guard !blocks.isEmpty else { return nil }
        var input = planInput(controller: wc, blocks: blocks, columnRuns: columnRuns)
        if !complete { input["truncated"] = true }
        return NaturalInput(observation: observation, blocks: blocks, input: input,
                            columnLineInset: columnLineInset(observation.fragments, columnRuns: columnRuns), columnRuns: columnRuns)
    }

    /// Where a table cell in a columned run stood from the run's own left edge, by line location.
    static func columnLineInset(_ fragments: [Fragment], columnRuns: [(range: NSRange, layout: OfficeColumnLayout)]) -> [Int: CGFloat] {
        var inset: [Int: CGFloat] = [:]
        for declared in columnRuns {
            let inRun = fragments.filter { NSLocationInRange($0.location, declared.range) }
            guard let left = inRun.map({ $0.rect.minX }).min() else { continue }
            for f in inRun where !f.chain.isEmpty { inset[f.location] = max(0, f.rect.minX - left) }
        }
        return inset
    }

    /// The plan input of a natural observation of `controller`'s document, with the observation it
    /// came from. `nil` when the document is not paged or holds nothing to observe.
    struct NaturalInput {
        var observation: Observation
        var blocks: [[String: Any]]
        var input: [String: Any]
        /// Where a table cell in a columned run stood from the run's own left edge, by line location.
        var columnLineInset: [Int: CGFloat]
        var columnRuns: [(range: NSRange, layout: OfficeColumnLayout)]
    }

    static func naturalInput(controller wc: DocumentWindowController) -> NaturalInput? {
        let delegate = wc.pageBandDelegate
        guard delegate.pageContentHeight > 0, let tc = wc.textView.textContainer,
              let storage = wc.textView.textStorage, storage.length > 0 else { return nil }
        // The plan is on the PRINT grid: the desk between two drawn sheets is added back per page
        // when the targets are turned into container coordinates.
        let pitch = delegate.pageContentHeight + delegate.band - delegate.deskGap
        guard pitch > 0 else { return nil }
        let columnRuns = wc.columnRunRanges()
        let observation = observeNaturally(storage: storage, like: tc)
        guard !observation.fragments.isEmpty else { return nil }
        let source = Source(storage: storage, columnRuns: columnRuns)
        let blocks = build(observation.fragments, observation.groups, source: source, proposedTops: observation.proposedTableLineTops)
        let input = planInput(controller: wc, blocks: blocks, columnRuns: columnRuns)
        // A table cell keeps its distance from its columned run's left edge: the proposed rect cannot
        // say where a cell's line ends up, so the host reads it where the layout has it.
        return NaturalInput(observation: observation, blocks: blocks, input: input,
                            columnLineInset: columnLineInset(observation.fragments, columnRuns: columnRuns), columnRuns: columnRuns)
    }

    /// The input the engine is asked with. With notes the plan runs the band fixpoint itself, so no
    /// band is handed in.
    static func planInput(controller wc: DocumentWindowController, blocks: [[String: Any]],
                          columnRuns: [(range: NSRange, layout: OfficeColumnLayout)]) -> [String: Any] {
        let delegate = wc.pageBandDelegate
        var input: [String: Any] = [
            "planVersion": 1,
            "contentHeight": Double(delegate.pageContentHeight),
            "splitTables": wc.mdDocument?.pageOptions.splitTables ?? false,
            "band": Double(max(0, delegate.band - delegate.deskGap)),
            "leadingBand": Double(delegate.leadingBand),
            "bodyWidth": Double(delegate.columnBodyWidth),
            "columnRuns": columnRunsInput(columnRuns),
            "noteBands": [] as [Any],
            "blocks": blocks,
        ]
        input.merge(furnitureInput(wc)) { a, _ in a }
        return input
    }

    // MARK: - The part of the input about the sheet

    static func appliesName(_ a: HeaderFooterApplicability) -> String {
        switch a {
        case .defaultPages: return "defaultPages"
        case .firstPage: return "firstPage"
        case .evenPages: return "evenPages"
        case .oddPages: return "oddPages"
        }
    }

    static func entries(_ list: [OfficeHeaderFooter]) -> [[String: Any]] {
        list.map { var e: [String: Any] = ["appliesTo": appliesName($0.appliesTo)]; if let s = $0.section { e["section"] = s }; return e }
    }

    /// The part of the plan input that is about the sheet rather than the flow.
    static func furnitureInput(_ wc: DocumentWindowController) -> [String: Any] {
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

    static func columnRunsInput(_ runs: [(range: NSRange, layout: OfficeColumnLayout)]) -> [[String: Any]] {
        runs.map { run in
            let l = run.layout
            return ["count": l.count, "spacing": Double(l.spacing), "widths": l.widths.map(Double.init),
                    "gaps": l.gaps.map(Double.init), "proportional": l.proportional]
        }
    }
}
