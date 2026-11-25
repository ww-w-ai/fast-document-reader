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
    typealias ObservedBlock = PlanInputBuilder.ObservedBlock
    private typealias Fragment = PlanInputBuilder.Fragment
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
        /// Which blocks hold the differing cell lines, and how many each.
        var cellLinesDifferingByBlock: [Int: Int] = [:]
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
        /// S6b2-0b (natural observation): the plan's `targets` against where TextKit put each line.
        var targets = 0
        var targetsDifferent = 0
        /// A target the reader has no line to compare with (a location the reader's layout lacks).
        var targetsUnmatched = 0
        var targetsMaxDelta = 0.0
        var targetsFirstDifference: String?
        var targetKinds: [String: Int] = [:]
        var flowedTablesPlan = 0
        var flowedTablesPlanOnly = 0
        var pitchMatches = true
        /// Prefix plans (`truncated`): one per cut, each compared with the full plan on its final pages.
        var prefixPlans = 0
        var prefixDifferent = 0
        var prefixFirstDifference: String?
        var prefixFinal: [String] = []
        /// S6b2-0c: what the apply probe needs from the plan call: the answer itself, the print grid
        /// it is on, and how far each table line in a columned run stands from the run's own left
        /// edge in the natural layout (a cell keeps that distance inside its column).
        var planAnswer: [String: Any]?
        var gridLeading: CGFloat = 0
        var gridPageContentHeight: CGFloat = 0
        var gridBand: CGFloat = 0
        var gridBodyWidth: CGFloat = 0
        var columnLineInset: [Int: CGFloat] = [:]
        /// S6b2-0e: the plan's painter state against the reader delegate's, per kind (how many
        /// entries differ), and how many entries were compared in all.
        var painterCompared = 0
        var painterDifferent: [String: Int] = [:]
        var painterFirstDifference: String?
        /// Reader-side artefacts the plan is deliberately not held to: a band the reader recorded
        /// with no height (its page rule re-met a line already at a page top, a hair under it), and a
        /// straddle record its last settle took from an earlier layout than the finished one.
        var painterReaderNotes: [String: Int] = [:]

        var text: String { summary.joined(separator: "\n") }
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
        /// What the painters read from the reader's delegate (S6b2-0e): the boundaries its page rule
        /// opened and where the gaps are, the boundaries a table is drawn across, and the ones a
        /// columned run crosses. `nil` straddle = nobody measured, read as none.
        var openedBoundaries: Set<Int> = []
        var openedBands: [Int: (top: CGFloat, height: CGFloat)] = [:]
        var tableStraddledBoundaries: Set<Int> = []
        /// The straddles measured from the finished layout as it stands (what a fresh settle records).
        var liveTableStraddles: Set<Int> = []
        var liveTableExtents: [(firstChar: Int, top: CGFloat, bottom: CGFloat)] = []
        var columnOpenedBoundaries: Set<Int> = []
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
        facts.openedBoundaries = wc.pageBandDelegate.openedBoundaries
        facts.openedBands = wc.pageBandDelegate.openedBands
        facts.tableStraddledBoundaries = wc.pageBandDelegate.tableStraddledBoundaries ?? []
        facts.columnOpenedBoundaries = wc.pageBandDelegate.columnOpenedBoundaries
        facts.liveTableStraddles = wc.currentTableStraddles()
        facts.liveTableExtents = wc.currentTableExtents()
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

    /// `FMD_PLAN_SHADOW_ROWS` and `FMD_PLAN_SHADOW_CELLBOX`: a table as the builder reads it, from the
    /// layout manager that laid it out.
    private static func inspect(_ t: PlanInputBuilder.TableSnapshot, lm: NSLayoutManager, into dump: inout [String]) {
        if !t.natural, (ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_ROWS"] ?? "").split(separator: ",").compactMap({ Int($0) }).contains(t.blockIndex) {
            for r in t.ordered {
                dump.append("SHADOW   row [\(t.blockIndex)] \(r): top \(String(format: "%.1f", Double(t.rows[r]!.top))) bottom \(String(format: "%.1f", Double(t.rows[r]!.bottom))) spans \(t.spans.filter { $0.start == r }.map { $0.end - $0.start })")
            }
        }
        if (ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_CELLBOX"] ?? "").split(separator: ",").compactMap({ Int($0) }).contains(t.blockIndex)
            || ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_CELLBOX_LOC"].flatMap({ Int($0) }).map({ loc in t.frags.contains { $0.location == loc } }) == true {
            var seen: [ObjectIdentifier] = []
            var by: [ObjectIdentifier: [PlanInputBuilder.Fragment]] = [:]
            for f in t.frags where f.table == t.first.table && !f.chain.isEmpty {
                let id = ObjectIdentifier(f.chain[0])
                if by[id] == nil { seen.append(id) }
                by[id, default: []].append(f)
            }
            // The cells of a table nested one level down.
            var nestedSeen: [ObjectIdentifier] = []
            var nestedBy: [ObjectIdentifier: [PlanInputBuilder.Fragment]] = [:]
            for f in t.frags where f.table == t.first.table && f.chain.count > 1 {
                let id = ObjectIdentifier(f.chain[1])
                if nestedBy[id] == nil { nestedSeen.append(id) }
                nestedBy[id, default: []].append(f)
            }
            for id in nestedSeen {
                let fs = nestedBy[id]!, cell = fs[0].chain[1]
                let box = lm.boundsRect(for: cell, at: lm.glyphIndexForCharacter(at: fs[0].location), effectiveRange: nil)
                dump.append("SHADOW   nestedbox [\(t.blockIndex)] r\(cell.startingRow)+\(cell.rowSpan) c\(cell.startingColumn)+\(cell.columnSpan) va\(cell.verticalAlignment.rawValue)/\(cell.authoredVerticalAlignment.rawValue) box \(String(format: "%.2f", Double(box.minY)))..\(String(format: "%.2f", Double(box.maxY))) lines \(String(format: "%.2f", Double(fs.map { $0.rect.minY }.min()!)))..\(String(format: "%.2f", Double(fs.map { $0.rect.maxY }.max()!))) n\(fs.count) pad \(String(format: "%.2f", Double(PlanInputBuilder.inset(cell, .minY))))/\(String(format: "%.2f", Double(PlanInputBuilder.inset(cell, .maxY))))")
            }
            for id in seen {
                let fs = by[id]!, cell = fs[0].chain[0]
                let box = lm.boundsRect(for: cell, at: lm.glyphIndexForCharacter(at: fs[0].location), effectiveRange: nil)
                dump.append("SHADOW   cellbox [\(t.blockIndex)] r\(cell.startingRow)+\(cell.rowSpan) c\(cell.startingColumn)+\(cell.columnSpan) va\(cell.verticalAlignment.rawValue)/\(cell.authoredVerticalAlignment.rawValue) box \(String(format: "%.2f", Double(box.minY)))..\(String(format: "%.2f", Double(box.maxY))) lines \(String(format: "%.2f", Double(fs.map { $0.rect.minY }.min()!)))..\(String(format: "%.2f", Double(fs.map { $0.rect.maxY }.max()!))) n\(fs.count) pad \(String(format: "%.2f", Double(PlanInputBuilder.inset(cell, .minY))))/\(String(format: "%.2f", Double(PlanInputBuilder.inset(cell, .maxY)))) nested \(fs.contains { $0.chain.count > 1 }) lastLS \(String(format: "%.2f", Double(fs.last!.lineSpacing))) lastH \(String(format: "%.2f", Double(fs.last!.rect.height))) boxH \(String(format: "%.2f", Double(fs.last!.box.height))) used \(String(format: "%.2f", Double(lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: fs.last!.location), effectiveRange: nil).height))) spaceAfter \(String(format: "%.2f", Double(fs.last!.spaceAfter))) spaceBefore \(String(format: "%.2f", Double(fs.first!.spaceBefore)))")
            }
        }
    }

    /// Runs the plan over `wc`'s finished layout. `nil` when the document is not paged or the engine
    /// answered no plan; the reason is in `Report.skippedReason`.
    static func run(controller wc: DocumentWindowController, natural: Bool = false, drawn: [Int: CGFloat] = [:]) -> Report {
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
        let fragments = PlanInputBuilder.collect(lm, tc, storage: storage)
        guard !fragments.isEmpty else { report.skippedReason = "no line fragments"; return report }

        // ---- 2. group into blocks, in document order ----
        let groups = PlanInputBuilder.group(fragments)

        // The reader's own layout, read through the builder with the reader's record beside it.
        var inspected: [String] = []
        let readerSource = PlanInputBuilder.Source(
            storage: storage, columnRuns: columnRuns, leading: leading, pitch: pitch,
            reader: PlanInputBuilder.ReaderRecord(page: page, openedBands: Array(delegate.openedBands.values),
                                                  oversizedPieces: delegate.oversizedPieces),
            inspectTable: { inspect($0, lm: lm, into: &inspected) })
        let reader = PlanInputBuilder.build(fragments, groups, source: readerSource)
        report.cellDump.append(contentsOf: inspected)
        report.tableHeightTotal = reader.tableHeightTotal
        report.tableHeights = reader.tableHeights
        let planBlocks = reader.planBlocks
        let cellLineRefs = reader.cellLineRefs
        let columnCellRefs = reader.columnCellRefs
        let observed = reader.observed
        let lineMacPages = reader.lineMacPages
        // What the engine is asked: the reader's own observation, or a layout nobody paginated.
        var askedBlocks = planBlocks
        /// Prefix plans: how many blocks one viewport, then 1, 2, 3 and 5 pages of the NATURAL layout hold.
        var prefixCuts: [(pages: Int, blocks: Int)] = []
        var naturalInput: [String: Any]?
        if natural {
            // The production path: the observer walk, the blocks and the input, in one call.
            guard let built = PlanInputBuilder.naturalInput(controller: wc) else {
                report.skippedReason = "no natural observation"
                return report
            }
            naturalInput = built.input
            let nat = built.observation.fragments
            let naturalGroups = built.observation.groups
            // Where a columned run's own left edge is in this layout: a table cell keeps its distance from it.
            for declared in columnRuns {
                let inRun = nat.filter { NSLocationInRange($0.location, declared.range) }
                guard let left = inRun.map({ $0.rect.minX }).min() else { continue }
                for f in inRun {
                    if !f.chain.isEmpty { report.columnLineInset[f.location] = max(0, f.rect.minX - left) }
                }
            }
            for pages in [1, 2, 3, 5] {
                let reach = leading + CGFloat(pages) * pitch
                let blocks = naturalGroups.filter { nat[$0.range.lowerBound].rect.minY < reach }.count
                if blocks > 0, blocks < naturalGroups.count, !prefixCuts.contains(where: { $0.blocks == blocks }) { prefixCuts.append((pages, blocks)) }
            }
            guard naturalGroups.map(\.id) == groups.map(\.id) else {
                report.skippedReason = "the observer's layout holds other blocks (\(naturalGroups.count) against \(groups.count))"
                return report
            }
            askedBlocks = built.blocks
        }

        // ---- 3. ask the engine ----
        // With notes the plan runs the band fixpoint itself, so the reader's bands are NOT handed in:
        // they are what the plan's own answer is compared with.
        let input = naturalInput ?? PlanInputBuilder.planInput(controller: wc, blocks: askedBlocks, columnRuns: columnRuns,
                                                               natural: false, readerNoteBands: facts.noteBands)
        guard let json = try? JSONSerialization.data(withJSONObject: input),
              let reply = plan(json: json),
              let envelope = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let plan = envelope["ok"] as? [String: Any] else {
            report.skippedReason = "the engine returned no plan"
            return report
        }
        report.planAnswer = plan
        report.gridLeading = leading
        report.gridPageContentHeight = delegate.pageContentHeight
        report.gridBand = delegate.band
        report.gridBodyWidth = delegate.columnBodyWidth

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
                    report.cellLinesDifferingByBlock[ref.block, default: 0] += 1
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
                report.cellLinesDifferingByBlock[ref.block, default: 0] += 1
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
        checkPainterState(&report, plan: plan, facts: facts, leading: leading, pitch: pitch)
        if ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_PAINTER"] != nil, report.painterDifferent["tableStraddledBoundaries"] != nil {
            let planned = Set(((plan["straddledBoundaries"] as? [NSNumber]) ?? []).map(\.intValue))
            let wrong = facts.liveTableStraddles.symmetricDifference(planned)
            let blockOfLocation = Dictionary(groups.enumerated().map { (fragments[$1.range.lowerBound].location, $0) }, uniquingKeysWith: { a, _ in a })
            for table in facts.liveTableExtents {
                let top = table.top, bottom = table.bottom
                let a = Int(((top - leading) / pitch).rounded(.down)), b = Int(((bottom - leading) / pitch).rounded(.down))
                guard wrong.contains(where: { $0 >= a && $0 < b }) || (wrong.contains { $0 >= a - 1 && $0 <= b + 1 } && b == a) else { continue }
                let bi = blockOfLocation[table.firstChar] ?? -1
                let mine = ((plan["placements"] as? [[String: Any]]) ?? []).filter { ($0["block"] as? Int) == bi }
                    .map { "p\(($0["page"] as? Int ?? -2) + 1) top \($0["top"] ?? "-") h \($0["height"] ?? "-") col \($0["column"] ?? "-")" }
                let segs = ((plan["columnRowSegments"] as? [[Any]]) ?? []).filter { ($0.first as? NSNumber)?.intValue == bi }
                let segPages = segs.compactMap { ($0[2] as? NSNumber)?.intValue }
                let nestedCount = ((plan["nestedLines"] as? [[String: Any]]) ?? []).filter { ($0["block"] as? Int) == bi }.count
                report.context.append("SHADOW   painter table [\(bi)] (nested lines \(nestedCount)) LIVE reader p\(a + 1)..p\(b + 1) top \(String(format: "%.2f", Double(top - leading - CGFloat(a) * pitch))) bottom \(String(format: "%.2f", Double(bottom - leading - CGFloat(b) * pitch))); plan placements \(mine.prefix(6).joined(separator: "; ")); column segments \(segs.count) pages \(segPages.min().map { $0 + 1 } ?? 0)..\(segPages.max().map { $0 + 1 } ?? 0)")
            }
        }
        if natural {
            checkTargets(&report, plan: plan, askedBlocks: askedBlocks, groups: groups.map { ($0.id, $0.range) }, fragments: fragments,
                         facts: facts, columnRuns: columnRuns, delegate: delegate, page: page, leading: leading, pitch: pitch,
                         readerOversized: reader.oversizedKeys, drawn: drawn)
            checkPrefixes(&report, full: plan, input: input, askedBlocks: askedBlocks, cuts: prefixCuts)
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
            "SHADOW cell lines differing by block: \(report.cellLinesDifferingByBlock.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ").nonEmpty ?? "none")",
            String(format: "SHADOW table height total: %.1f", Double(report.tableHeightTotal)),
            "SHADOW pages whose first block differs: \(report.pagesWithADifferentFirstBlock)",
            "SHADOW hard breaks dropped by 147: plan \(report.droppedByPlan), TextKit \(report.droppedByTextKit)",
            "SHADOW first difference: \(report.firstDifference ?? "none")",
            "SHADOW sheets: \(report.furniturePages) pages compared; differences \(report.furnitureDifferences.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ").nonEmpty ?? "none"); first: \(report.furnitureFirstDifference ?? "none")",
            "SHADOW reader's own number vetoes differ from the document's on pages: \(facts.hiddenByReader.symmetricDifference(facts.hidden).sorted().map { String($0 + 1) }.joined(separator: " ").nonEmpty ?? "none")",
            "SHADOW footnotes: TextKit bands \(report.noteBandsTextKit.sorted { $0.key < $1.key }.map { "\($0.key + 1):\(String(format: "%.1f", Double($0.value)))" }.joined(separator: " ")); plan bands \(report.noteBandsPlan.sorted { $0.key < $1.key }.map { "\($0.key + 1):\(String(format: "%.1f", $0.value))" }.joined(separator: " ")); pages whose cited notes differ: \(report.noteAssignmentDifferences)",
            "SHADOW columns: \(report.columnLines) lines in columned runs, different: \(report.columnLinesDifferent); first: \(report.columnFirstDifference ?? "none")",
            "SHADOW painter: \(report.painterCompared) entries compared (opened boundaries, bands, straddled, column crossed, note bands), different \(report.painterDifferent.values.reduce(0, +)) (\(report.painterDifferent.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ").nonEmpty ?? "none")); first: \(report.painterFirstDifference ?? "none"); reader artefacts not held against the plan: \(report.painterReaderNotes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ").nonEmpty ?? "none")",
        ] + (natural ? [
            "SHADOW targets: \(report.targets) (\(report.targetKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))), different: \(report.targetsDifferent), unmatched: \(report.targetsUnmatched), max delta \(String(format: "%.3f", report.targetsMaxDelta)); first: \(report.targetsFirstDifference ?? "none")",
            "SHADOW flowedTables: plan \(report.flowedTablesPlan), not in the reader's oversized record: \(report.flowedTablesPlanOnly); pitchUsed matches the grid: \(report.pitchMatches)",
            "SHADOW prefix: \(report.prefixPlans) plans, different: \(report.prefixDifferent); final pages \(report.prefixFinal.joined(separator: " ")); first: \(report.prefixFirstDifference ?? "none")",
        ] : []) + report.context + report.cellDump
        return report
    }

    // MARK: - S6b2-0e: the painters' state

    /// The state the painters read from `PageBandLayoutDelegate` — opened boundaries and bands, the
    /// boundaries a table straddles, the ones a columned run crosses, the footnote bands — against
    /// what the plan answers. Bands are compared page-locally (the plan's own grid).
    private static func checkPainterState(_ report: inout Report, plan: [String: Any], facts: MacFacts,
                                          leading: CGFloat, pitch: CGFloat) {
        func ints(_ key: String) -> Set<Int> { Set(((plan[key] as? [NSNumber]) ?? []).map(\.intValue)) }
        func differ(_ kind: String, _ detail: @autoclosure () -> String) {
            report.painterDifferent[kind, default: 0] += 1
            if report.painterFirstDifference == nil { report.painterFirstDifference = "\(kind): \(detail())" }
            if ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_PAINTER"] != nil {
                report.context.append("SHADOW   painter \(kind): \(detail())")
            }
        }
        func compareSets(_ kind: String, reader: Set<Int>, planned: Set<Int>) {
            report.painterCompared += reader.union(planned).count
            for page in reader.symmetricDifference(planned).sorted() {
                differ(kind, "boundary after page \(page + 1): reader \(reader.contains(page)), plan \(planned.contains(page))")
            }
        }
        compareSets("openedBoundaries", reader: facts.openedBoundaries, planned: ints("openedBoundaries"))
        // Against the layout as it stands: the delegate's own record is whatever its last settle saw,
        // which a columned document's later column pass can leave behind.
        // A table edge that lands ON a page edge reads as either side of it by float noise alone
        // (the reader floors `(y - leading) / pitch`); the plan reads it as the page it starts on.
        var readerStraddles = facts.liveTableStraddles
        let plannedStraddles = ints("straddledBoundaries")
        for boundary in readerStraddles.symmetricDifference(plannedStraddles) {
            let edge = leading + CGFloat(boundary + 1) * pitch
            if facts.liveTableExtents.contains(where: { abs($0.top - edge) < 0.01 || abs($0.bottom - edge) < 0.01 }) {
                if readerStraddles.contains(boundary) { readerStraddles.remove(boundary) } else { readerStraddles.insert(boundary) }
                report.painterReaderNotes["tableEdgeOnPageEdge", default: 0] += 1
            }
        }
        compareSets("tableStraddledBoundaries", reader: readerStraddles, planned: plannedStraddles)
        if facts.tableStraddledBoundaries != facts.liveTableStraddles {
            report.painterReaderNotes["straddleRecordStale", default: 0] += 1
        }
        compareSets("columnOpenedBoundaries", reader: facts.columnOpenedBoundaries, planned: ints("columnOpenedBoundaries"))
        var planned: [Int: (top: Double, height: Double)] = [:]
        for band in (plan["openedBands"] as? [[String: Any]]) ?? [] {
            if let page = (band["page"] as? NSNumber)?.intValue, let top = (band["top"] as? NSNumber)?.doubleValue,
               let height = (band["height"] as? NSNumber)?.doubleValue { planned[page] = (top, height) }
        }
        for page in Set(planned.keys).union(facts.openedBands.keys).sorted() {
            report.painterCompared += 1
            guard let kit = facts.openedBands[page], let mine = planned[page] else {
                differ("openedBands", "page \(page + 1): reader \(facts.openedBands[page] != nil), plan \(planned[page] != nil)")
                continue
            }
            let kitTop = Double(kit.top - leading - CGFloat(page) * pitch)
            // A line already at the next page's top, a hair under it, meets the page rule again and
            // is "moved" by nothing: the reader's record is then a gap of no height at the page end,
            // over the real one the plan reports (which ends at the page end).
            if kit.height < 0.5, kitTop >= Double(pitch) - 0.5, abs(mine.top + mine.height - Double(pitch)) < 0.6 {
                report.painterReaderNotes["zeroHeightBand", default: 0] += 1
                continue
            }
            if abs(kitTop - mine.top) > 0.6 || abs(Double(kit.height) - mine.height) > 0.6 {
                differ("openedBands", String(format: "after page %d: reader top %.2f height %.2f, plan top %.2f height %.2f", page + 1, kitTop, Double(kit.height), mine.top, mine.height))
            }
        }
        var planNotes: [Int: Double] = [:]
        for pair in (plan["noteBands"] as? [[Any]]) ?? [] where pair.count == 2 {
            if let page = (pair[0] as? NSNumber)?.intValue, let height = (pair[1] as? NSNumber)?.doubleValue { planNotes[page] = height }
        }
        let kitNotes = facts.noteBands.filter { $0.value > 0 }
        for page in Set(planNotes.keys).union(kitNotes.keys).sorted() {
            report.painterCompared += 1
            if abs((planNotes[page] ?? -1) - Double(kitNotes[page] ?? -1)) > 0.6 {
                differ("noteBands", "page \(page + 1): reader \(kitNotes[page].map { String(format: "%.2f", Double($0)) } ?? "none"), plan \(planNotes[page].map { String(format: "%.2f", $0) } ?? "none")")
            }
        }
    }

    // MARK: - S6b2-0b: targets and prefix plans

    /// The plan's `targets` against the layout the reader printed: every target is a line (or a table
    /// piece's first line) the engine placed by character location, so the page and top it names must
    /// be where TextKit put that line.
    private static func checkTargets(_ report: inout Report, plan: [String: Any], askedBlocks: [[String: Any]],
                                     groups: [(id: Int, range: Range<Int>)], fragments: [Fragment], facts: MacFacts,
                                     columnRuns: [(range: NSRange, layout: OfficeColumnLayout)], delegate: PageBandLayoutDelegate,
                                     page: (CGFloat) -> Int, leading: CGFloat, pitch: CGFloat, readerOversized: Set<Int>, drawn: [Int: CGFloat]) {
        func local(_ y: CGFloat) -> (page: Int, top: Double) {
            let p = page(y)
            return (p, Double(y - leading - CGFloat(p) * pitch))
        }
        let pitchUsed = (plan["pitchUsed"] as? NSNumber)?.doubleValue ?? 0
        report.pitchMatches = abs(pitchUsed - Double(pitch)) < 1e-6
        let flowedKeys = Set(((plan["flowedTables"] as? [NSNumber]) ?? []).map(\.intValue))
        report.flowedTablesPlan = flowedKeys.count
        report.flowedTablesPlanOnly = flowedKeys.subtracting(readerOversized).count
        var reader: [Int: (page: Int, top: Double)] = [:]
        var inTable: Set<Int> = []
        var byLocation: [Int: Fragment] = [:]
        var runLefts: [Int: CGFloat] = [:]
        for f in fragments {
            byLocation[f.location] = f
            if let run = columnRuns.firstIndex(where: { NSLocationInRange(f.location, $0.range) }) {
                runLefts[run] = min(runLefts[run] ?? f.rect.minX, f.rect.minX)
            }
        }
        for f in fragments {
            reader[f.location] = local(f.rect.minY)
            if f.table != nil { inTable.insert(f.location) }
        }
        // A table piece's first line: the reader's row top, with the inset the host sent for that line.
        var piece: [Int: (page: Int, top: Double, inset: Double, key: Int, columnRun: Bool)] = [:]
        for (index, group) in groups.enumerated() where (askedBlocks[index]["kind"] as? String) == "table" {
            let block = askedBlocks[index]
            let frags = Array(fragments[group.range])
            guard let outer = frags.first?.table else { continue }
            for (r, row) in ((block["rows"] as? [[String: Any]]) ?? []).enumerated() {
                let rowTops = frags.filter { $0.table == outer && $0.chain.first?.startingRow == r }.map(\.top)
                guard let top = rowTops.min() else { continue }
                var found: (loc: Int, inset: Double)?
                for cell in (row["cells"] as? [[String: Any]]) ?? [] where found == nil {
                    for line in (cell["lines"] as? [[String: Any]]) ?? [] {
                        if let loc = (line["loc"] as? NSNumber)?.intValue {
                            let own = (cell["padTop"] as? Double ?? 0) + (line["top"] as? Double ?? 0)
                            found = (loc, own)
                            break
                        }
                    }
                }
                guard var (loc, inset) = found.map({ ($0.loc, $0.inset) }) else { continue }
                if r == 0, let firstLoc = block["firstLoc"] as? Int { loc = firstLoc; inset = block["firstLineInset"] as? Double ?? 0 }
                let at = local(top)
                piece[loc] = (at.page, at.top, inset, group.id, block["columnRun"] != nil)
            }
        }
        for target in (plan["targets"] as? [[String: Any]]) ?? [] {
            guard let loc = (target["loc"] as? NSNumber)?.intValue, let tPage = (target["page"] as? NSNumber)?.intValue,
                  let tTop = (target["top"] as? NSNumber)?.doubleValue else { continue }
            let tColumn = (target["column"] as? NSNumber)?.intValue
            var expected: (page: Int, top: Double)?
            var kind = "line"
            var expectedColumn: Int?
            if let placed = facts.columnPlacements[loc] {
                // A line in a columned run: the reader's column map is where it stands.
                // A pushed piece's first line the column rule leaves where the typesetter proposed it meets the page
                // rule as well (`pushWholeTable`): the reader's drawn position, when the host has it, is its answer.
                var at = local(placed.y)
                if delegate.pushedTables[loc] != nil, let y = drawn[loc] { at = local(y) }
                expected = at
                kind = "column line"
                if let run = columnRuns.firstIndex(where: { NSLocationInRange(loc, $0.range) }) {
                    let columns = ColumnGeometry.columns(inWidth: delegate.columnBodyWidth, layout: columnRuns[run].layout)
                    // The reader's x is the column's edge plus how far a table cell stood from the run's
                    // own left edge (`settleColumnPlacements`); take that distance back out before asking
                    // which column the edge is.
                    let runLeft = runLefts[run] ?? 0
                    let inset: CGFloat = byLocation[loc].map { $0.chain.isEmpty ? 0 : max(0, $0.rect.minX - runLeft) } ?? 0
                    expectedColumn = columns.indices.min { abs(columns[$0].x + inset - placed.x) < abs(columns[$1].x + inset - placed.x) }
                }
            } else if let p = piece[loc], !flowedKeys.contains(p.key), !p.columnRun {
                expected = (p.page, p.top + p.inset)
                kind = "piece"
            } else if let at = reader[loc] {
                expected = at
                if inTable.contains(loc) { kind = "cell line" }
            }
            report.targets += 1
            report.targetKinds[kind, default: 0] += 1
            guard let expected else { report.targetsUnmatched += 1; continue }
            let delta = abs(expected.top - tTop)
            report.targetsMaxDelta = max(report.targetsMaxDelta, expected.page == tPage ? delta : 0)
            if expected.page != tPage || delta > 0.6 || (expectedColumn != nil && expectedColumn != tColumn) {
                report.targetsDifferent += 1
                // FMD_PLAN_SHADOW_TARGETS=1 lists every differing target.
                if ProcessInfo.processInfo.environment["FMD_PLAN_SHADOW_TARGETS"] == "1" {
                    let cellInfo = byLocation[loc].map { f in
                        "stack y \(String(format: "%.2f", Double(f.rect.minY))) h \(String(format: "%.2f", Double(f.rect.height))) chain " + f.chain.map { "r\($0.startingRow)+\($0.rowSpan) c\($0.startingColumn)+\($0.columnSpan) va\($0.verticalAlignment.rawValue)/\($0.authoredVerticalAlignment.rawValue)" }.joined(separator: " > ")
                    } ?? "-"
                    report.cellDump.append("SHADOW   target \(kind) at \(loc): TextKit p\(expected.page + 1) top \(String(format: "%.2f", expected.top)); plan p\(tPage + 1) top \(String(format: "%.2f", tTop)); \(cellInfo)")
                }
                if report.targetsFirstDifference == nil {
                    report.targetsFirstDifference = "\(kind) at \(loc): TextKit p\(expected.page + 1) top \(String(format: "%.2f", expected.top)) column \(expectedColumn.map(String.init) ?? "-"); plan p\(tPage + 1) top \(String(format: "%.2f", tTop)) column \(tColumn.map(String.init) ?? "-")"
                }
            }
        }
    }

    /// A plan over a prefix of the blocks (`truncated`), on the pages it calls final, against the full
    /// plan: the same targets, and nothing else standing on those pages.
    private static func checkPrefixes(_ report: inout Report, full: [String: Any], input: [String: Any],
                                      askedBlocks: [[String: Any]], cuts: [(pages: Int, blocks: Int)]) {
        func table(_ p: [String: Any]) -> [Int: String] {
            var out: [Int: String] = [:]
            for t in (p["targets"] as? [[String: Any]]) ?? [] {
                guard let loc = (t["loc"] as? NSNumber)?.intValue, let page = (t["page"] as? NSNumber)?.intValue else { continue }
                let top = (t["top"] as? NSNumber)?.doubleValue ?? 0
                out[loc] = "\(page) \(String(format: "%.3f", top)) \((t["column"] as? NSNumber)?.intValue ?? -1)"
            }
            return out
        }
        let fullTargets = table(full)
        let fullPages = (full["pageCount"] as? NSNumber)?.intValue ?? 0
        for cut in cuts {
            var asked = input
            asked["blocks"] = Array(askedBlocks.prefix(cut.blocks))
            asked["truncated"] = true
            guard let json = try? JSONSerialization.data(withJSONObject: asked), let reply = plan(json: json),
                  let envelope = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                  let part = envelope["ok"] as? [String: Any] else {
                report.prefixDifferent += 1
                report.prefixFirstDifference = report.prefixFirstDifference ?? "no plan for a prefix of \(cut.blocks) blocks"
                continue
            }
            report.prefixPlans += 1
            let final = (part["finalPages"] as? NSNumber)?.intValue ?? 0
            let partPages = (part["pageCount"] as? NSNumber)?.intValue ?? 0
            report.prefixFinal.append("\(cut.pages)p:\(final)/\(partPages)")
            func settled(_ table: [Int: String]) -> [Int: String] { table.filter { (Int($0.value.split(separator: " ")[0]) ?? 0) < final } }
            let a = settled(table(part)), b = settled(fullTargets)
            let differing = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
            if final > partPages || final > fullPages || !differing.isEmpty {
                report.prefixDifferent += 1
                if report.prefixFirstDifference == nil {
                    let loc = differing.min()
                    report.prefixFirstDifference = "prefix of \(cut.blocks) blocks (\(cut.pages) pages), final \(final) of \(partPages): \(differing.count) targets differ" + (loc.map { ", first at \($0): prefix \(a[$0] ?? "-") full \(b[$0] ?? "-")" } ?? "")
                }
            }
        }
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
