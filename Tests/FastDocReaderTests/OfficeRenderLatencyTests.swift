import XCTest
import AppKit
@testable import FastDocReader

/// What ONE ⌘+/⌘− press actually costs on a REAL office document, broken down by stage.
///
/// `reRenderPreservingCaret` re-runs the whole render (`OfficeTextBuilder.build` over every block)
/// and then re-lays the document out, so a heavy report — dozens of tables, hundreds of thousands of
/// characters — pays all of it per keypress. This probe exists so that cost is a measured number
/// rather than a guess, and so a future change that makes it worse is visible (the same reason
/// `FloatWrapExclusionSpikeTests` and `CorpusProbeTests` are kept).
///
/// Skips unless `FMD_OFFICE_LATENCY_FILE` points at a .docx/.odt/.hwp/.hwpx. Nothing from the
/// document's contents is printed — only sizes and timings.
///
/// What this probe has already established on a 62-table / 37-image HWP (~19k characters), so it
/// does not have to be re-derived:
///   • Before: 769 ms per press, 1706 ms for a 3-press burst (2.2× — three full rebuilds), and
///     `display(_:)` alone 138 ms because the full storage pass ran three times per render.
///   • After (`settleReadingColumn` + debounce): ~670 ms per press, ~660 ms for a 3-press burst
///     (1.0× — one rebuild), `display(_:)` ~50 ms.
///   • The residual ~216 ms main-thread freeze is the REBUILD itself (build ~100 ms + display
///     ~50 ms + the media/outline tail), not document layout. Time-slicing `precomputeLayout` was
///     tried against it and made things worse — see that function's comment.
///   • Machine noise is real: one run showed 2825 ms/2.1× that did not reproduce. Trust the
///     `rebuilds` count (deterministic) over the wall clock (not).
final class OfficeRenderLatencyTests: XCTestCase {
    /// What paragraph STYLES a real HWP actually uses, and how often — the input to
    /// `HwpReader.headingLevel`'s matching. Run before widening that matcher, so the rule follows the
    /// documents instead of a guess about them (the same "measure the corpus before believing it"
    /// discipline invariant 30 records). Skips unless `FMD_HWP_STYLE_PROBE` names an HWP/HWPX.
    func testHwpStyleNameFrequencies() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_STYLE_PROBE"] else {
            throw XCTSkip("set FMD_HWP_STYLE_PROBE to inspect a real HWP's paragraph styles")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = HwpReader.exportDocumentJSON(data),
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let blocks = root["blocks"] as? [[String: Any]] else {
            return XCTFail("could not export/parse that document")
        }
        var counts: [String: Int] = [:]
        var headingBlocks = 0
        func walk(_ blocks: [[String: Any]]) {
            for b in blocks {
                switch b["t"] as? String {
                case "para":
                    if b["heading"] != nil, !(b["heading"] is NSNull) { headingBlocks += 1 }
                    let en = (b["styleName"] as? String) ?? "-"
                    let ko = (b["styleLocalName"] as? String) ?? "-"
                    counts["\(en) / \(ko)", default: 0] += 1
                case "table":
                    if let rows = b["rows"] as? [[[String: Any]]] {
                        for row in rows { for cell in row { walk((cell["blocks"] as? [[String: Any]]) ?? []) } }
                    }
                default: break
                }
            }
        }
        walk(blocks)
        var lh: [String: Int] = [:]
        func walkLH(_ blocks: [[String: Any]]) {
            for b in blocks {
                if b["t"] as? String == "para", let h = b["lineHeight"] as? [String: Any] {
                    lh["\(h["type"] ?? "?")=\(h["value"] ?? "?")", default: 0] += 1
                }
                if let rows = b["rows"] as? [[[String: Any]]] {
                    for row in rows { for cell in row { walkLH((cell["blocks"] as? [[String: Any]]) ?? []) } }
                }
            }
        }
        walkLH(blocks)
        print("  line heights: " + lh.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: "  "))
        print("  paragraphs by style (english / korean), heading-flagged: \(headingBlocks)")
        for (name, n) in counts.sorted(by: { $0.value > $1.value }).prefix(12) {
            print(String(format: "   %5d  %@", n, name))
        }
    }

    private func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
    private func stamp(_ label: String, _ start: Date) {
        print(String(format: "  %-38@ %7.1f ms", label as NSString, ms(start)))
    }
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testFontSizeChangeCostOnARealOfficeDocument() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_OFFICE_LATENCY_FILE"] else {
            throw XCTSkip("set FMD_OFFICE_LATENCY_FILE to measure a real office document")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let uti: String = {
            switch ext {
            case "odt": return "org.oasis-open.opendocument.text"
            case "hwp", "hwpx": return "com.hancom.hwp"
            default: return "org.openxmlformats.wordprocessingml.document"
            }
        }()

        if let start = ProcessInfo.processInfo.environment["FMD_START_FONT"].flatMap(Double.init) {
            FontSizeStore.size = CGFloat(start)   // reproduce a reader who has already zoomed in
        }
        let doc = MarkdownDocument()
        doc.fileURL = url
        var t = Date()
        try doc.read(from: data, ofType: uti)
        stamp("read + parse", t)

        var tables = 0, images = 0
        func countBlocks(_ blocks: [OfficeBlock]) {
            for b in blocks {
                switch b {
                case let .table(rows, _, _, _):
                    tables += 1
                    for row in rows { for cell in row { countBlocks(cell.blocks) } }
                case .image: images += 1
                default: break
                }
            }
        }
        countBlocks(doc.officeBlocks)
        print("  blocks: \(doc.officeBlocks.count), tables: \(tables), images: \(images), "
              + "pageWidth: \(doc.officePageContentWidth.map { String(format: "%.1f", $0) } ?? "nil")")

        t = Date()
        doc.makeWindowControllers()
        stamp("first render (makeWindowControllers)", t)
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let probeW = Double(ProcessInfo.processInfo.environment["FMD_PROBE_WIDTH"] ?? "1200") ?? 1200
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: probeW, height: 900), display: false)
        spin(2)
        let storage = try XCTUnwrap(wc.textStorageRef)
        print("  characters rendered: \(storage.length)")

        // Stage 1 — the pure string rebuild (what changing the font size fundamentally requires).
        let colW = wc.textView.textContainer?.size.width ?? 800
        t = Date()
        let rebuilt = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: 20),
                                              columnWidth: colW,
                                              documentDefaultFontSize: doc.officeDefaultBodyFontSize,
                                              pageContentWidth: doc.officePageContentWidth,
                                              // Mirror `MarkdownDocument.render` exactly: tables are
                                              // built at the width they are displayed at.
                                              tableWidth: colW - 2 * (wc.textView.textContainer?.lineFragmentPadding ?? 5),
                                              comments: doc.officeComments)
        stamp("OfficeTextBuilder.build alone", t)
        XCTAssertGreaterThan(rebuilt.length, 0)

        // Stage 2 — `updateTextInset` with the document ALREADY rendered. `render(into:)` calls this
        // before every rebuild, and its two tail passes (tab reanchor + table column re-solve) walk
        // the FULL current storage — which the rebuild is about to throw away.
        t = Date()
        wc.updateTextInset()
        stamp("updateTextInset (full storage)", t)

        // Stage 2b — WHY that pass costs what it costs. It is two full-storage walks (fill-margin tab
        // re-anchor, table column re-solve) plus the graphic pass; a document can be cheap in
        // characters and ruinous in STRUCTURE, so count the structure rather than guess from length.
        var tableParagraphs = 0, fillMarginTabs = 0, graphics = 0, distinctTables = Set<ObjectIdentifier>()
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.paragraphStyle, in: all) { value, _, _ in
            guard let ps = value as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            tableParagraphs += 1
            distinctTables.insert(ObjectIdentifier(block.table))
        }
        storage.enumerateAttribute(MDAttr.fillMarginTab, in: all) { v, _, _ in if v != nil { fillMarginTabs += 1 } }
        storage.enumerateAttribute(MDAttr.officeGraphic, in: all) { v, _, _ in if v != nil { graphics += 1 } }
        print("  structure: \(distinctTables.count) NSTextTables, \(tableParagraphs) cell paragraphs, "
              + "\(fillMarginTabs) fill-margin tabs, \(graphics) graphics")
        // Both paths matter and they are very different: the SAME width (what `display(_:)`'s tail and
        // a repeated pass hit) must cost nothing, and a genuinely CHANGED width (a real resize) pays
        // the one invalidation. Measuring only the first would flatter the change.
        t = Date()
        TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 10)
        stamp("  ↳ resizeTables, width unchanged", t)
        t = Date()
        TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 210)
        stamp("  ↳ resizeTables, width CHANGED", t)
        TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 10)   // put it back

        // Stage 3 — installing the rebuilt string (this is what actually blocks the main thread).
        t = Date()
        wc.display(rebuilt)
        stamp("display(attributed)", t)

        // Stage 3a — the flicker check: after a render, does the resize pass still MOVE anything?
        // Any cell it changes is a cell the reader saw at the wrong width first (table shrinks, then
        // snaps wider). Zero changed = the first paint is the final one.
        do {
            func widths() -> [CGFloat] {
                var out: [CGFloat] = []
                storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                    if let ps = v as? NSParagraphStyle, let b = ps.textBlocks.first as? NSTextTableBlock {
                        out.append(b.contentWidth)
                    }
                }
                return out
            }
            let before = widths()
            let pad = wc.textView.textContainer?.lineFragmentPadding ?? 5
            TableBlockBuilder.resizeTables(in: storage, toWidth: colW - 2 * pad)
            let after = widths()
            let moved = zip(before, after).filter { abs($0 - $1) > 0.5 }.count
            print("  cells the resize pass still moves after a render: \(moved) of \(before.count)")
        }

        // Stage 3b — the TAIL after the string is installed: laying the whole document out is the
        // one that scales with table count, and it is worth knowing separately from the rebuild.
        //
        // Stage 3c is folded in here because it has to be read at the same instant: how much of the
        // document is laid out the moment `precomputeLayout` RETURNS. That is time-to-interactive —
        // the reader can see and select the part that is laid out — and unlike the settle time it is
        // a deterministic count, not a wall clock. `layoutStepCount` (how many run-loop turns the
        // walk took) is the other deterministic half: it says how finely the rest was sliced.
        do {
            let lm0 = wc.textView.layoutManager
            // Nothing may ASK for a glyph before the measurement: under contiguous layout every
            // glyph query lays the document out up to that glyph, so probing "what does the viewport
            // need" first would lay the viewport out and then report that laying it out was free.
            let t0 = Date()
            wc.precomputeLayout()
            let laidOnReturn = lm0?.firstUnlaidCharacterIndex() ?? 0
            var laid = 0.0
            for _ in 0..<1500 {
                spin(0.005)
                let total = wc.textView.textStorage?.length ?? 0
                if total > 0, (lm0?.firstUnlaidCharacterIndex() ?? 0) >= total { laid = ms(t0); break }
            }
            print(String(format: "  full-document layout alone           %7.1f ms", laid))
            // Now that everything is laid out, asking what the viewport spans costs nothing.
            let visible = wc.visibleCharRange(margin: 0)
            print("  laid out WHEN precomputeLayout returned: \(laidOnReturn) of \(storage.length) chars"
                  + "  (viewport needs \(NSMaxRange(visible)))"
                  + "  · layout run-loop turns: \(wc.layoutStepCount)")
        }

        // Stage 4+ — a press measured to the point the document is FULLY laid out again, which is
        // when it stops feeling busy. Two things make a naive timer lie here: `runBusy` defers the
        // work a run-loop turn, and the rebuild is DEBOUNCED — so "layout is complete" is true the
        // instant after the press, before anything has started. Waiting for `renderGeneration` to
        // advance first is what makes this measure the work rather than the wait.
        let lm = try XCTUnwrap(wc.textView.layoutManager)
        /// Returns (settle, worstHitch). `worstHitch` is what "slow" actually feels like: a 10 ms
        /// run-loop slice that takes 500 ms to come back means the main thread was blocked that whole
        /// time and the window was frozen. Total settle time can stay the same while the hitch drops,
        /// and the app still feels far better — so both are reported.
        func timePresses(_ n: Int, _ label: String) -> (Double, Double) {
            let gen = doc.renderGeneration
            let start = Date()
            for _ in 0..<n { doc.increaseReaderFontSize(nil) }
            var elapsed = 0.0, worst = 0.0
            for _ in 0..<1500 {
                let sliceStart = Date()
                spin(0.01)
                worst = max(worst, ms(sliceStart))
                let total = wc.textView.textStorage?.length ?? 0
                if doc.renderGeneration > gen, total > 0, lm.firstUnlaidCharacterIndex() >= total {
                    elapsed = ms(start); break
                }
            }
            // Decisive check for coalescing: how many REBUILDS did this gesture actually cause?
            // Three presses that produce three renders means the debounce is not collapsing them,
            // whatever the wall clock says.
            spin(0.5)
            print(String(format: "  %-30@ %7.1f ms   worst freeze %6.1f ms   rebuilds %d",
                         label as NSString, elapsed, worst, doc.renderGeneration - gen))
            return (elapsed, worst)
        }
        _ = timePresses(1, "first ⌘+ (cold)")
        let warm = timePresses(1, "warm ⌘+ press")
        // The real gesture: three presses as fast as the key repeats. Uncoalesced this is three full
        // rebuilds back to back, and the reader waits through all three to see only the last size.
        let burst = timePresses(3, "3-press burst")
        print(String(format: "  VERDICT: 1 press %.0f ms (worst freeze %.0f ms) · 3-press burst %.0f ms (%.1f× one press)",
                     warm.0, warm.1, burst.0, warm.0 > 0 ? burst.0 / warm.0 : 0))
    }
}

/// `precomputeLayout`'s two load-bearing properties, pinned so neither can be lost silently.
///
/// These do NOT need a real document: they need a document whose STRUCTURE is expensive while its
/// length is not, which is the whole shape of the problem — an office report is a few tens of
/// thousands of characters and hundreds of table cells. GFM tables go through the same
/// `TableBlockBuilder` as office tables (invariant 39), so a markdown file of small tables produces
/// the same `NSTextTableBlock`s at a fraction of the setup.
final class PrecomputeLayoutTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// `tables` small GFM tables, deliberately short: heavy in cells, light in characters.
    private func tableDenseMarkdown(tables: Int) -> String {
        (0..<tables).map { i in
            """
            ## Section \(i)

            | A | B | C |
            | - | - | - |
            | 1 | 2 | 3 |
            | 4 | 5 | 6 |
            | 7 | 8 | 9 |
            """
        }.joined(separator: "\n\n")
    }

    private func open(_ markdown: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-precompute-\(UUID().uuidString).md")
        try doc.read(from: Data(markdown.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        spin(0.5)
        return (doc, wc)
    }

    /// Waits until the document is laid out, bounded so a walk that never terminates fails the test
    /// instead of hanging the suite. Deliberately only a WAIT, not evidence: see the note below on
    /// why "is it laid out" says nothing about whether `precomputeLayout` is what laid it out.
    private func settle(_ wc: DocumentWindowController) -> Bool {
        guard let lm = wc.textView.layoutManager else { return false }
        for _ in 0..<400 {
            spin(0.005)
            let total = wc.textView.textStorage?.length ?? 0
            if total > 0, lm.firstUnlaidCharacterIndex() >= total { return true }
        }
        return false
    }

    // NOT TESTED HERE, and the reason is worth keeping: "after this settles the whole document is
    // laid out" (invariant 2's contract) cannot be asserted in this harness, because it is true
    // whether or not `precomputeLayout` does anything. Written and then withdrawn after the mutation
    // step — shortening every step by 100 characters left it passing, and so did deleting the call
    // entirely: with the window spinning the run loop, AppKit's own lazy layout finishes whatever
    // the walk left, and `firstUnlaidCharacterIndex` reports the same answer either way. A green
    // assertion whose subject is unreachable proves nothing (invariant 30), so it is gone rather
    // than kept as reassurance. What IS reachable is the walk's own step count, below.

    /// A step is bounded by CHARACTERS, and deliberately not also by structure. This document is
    /// exactly the case that makes that look wrong — hundreds of table cells inside a few thousand
    /// characters, so the entire thing is laid out in ONE run-loop turn — and the comment on
    /// `precomputeLayout` records the two measured attempts to fix it, both of which made a real
    /// 38-table docx worse (2 turns / 105–121 ms → 3 turns / 155–170 ms → 10 turns / 186–192 ms)
    /// while never shortening the worst freeze, because the freeze is the rebuild and not this pass.
    ///
    /// So this assertion is not a claim that one turn is ideal. It is a tripwire: a third attempt to
    /// slice by structure changes this count, and has to come with new measurements.
    func testAStepIsBoundedByCharactersNotByStructure() throws {
        // The document must outlive the controller: `NSWindowController.document` is an unowned
        // back-reference, so letting it go here would leave the controller pointing at freed memory.
        let (doc, wc) = try open(tableDenseMarkdown(tables: 60))
        defer { withExtendedLifetime(doc) {} }
        let storage = try XCTUnwrap(wc.textView.textStorage)
        // The premise: structurally heavy (one NSTextTable per section) and short (well under one
        // 20k chunk). If either stops being true the test is measuring something else.
        var cellParagraphs = 0
        var distinctTables = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let ps = v as? NSParagraphStyle, let b = ps.textBlocks.first as? NSTextTableBlock else { return }
            cellParagraphs += 1
            distinctTables.insert(ObjectIdentifier(b.table))
        }
        XCTAssertEqual(distinctTables.count, 60)
        XCTAssertGreaterThan(cellParagraphs, 500)
        XCTAssertLessThan(storage.length, 20_000)

        wc.precomputeLayout()
        XCTAssertTrue(settle(wc))
        let expected = max(1, Int(ceil(Double(storage.length) / 20_000.0)))
        XCTAssertEqual(wc.layoutStepCount, expected,
                       "\(cellParagraphs) cell paragraphs in \(storage.length) characters were laid out in "
                       + "\(wc.layoutStepCount) run-loop turns; the bound is characters, not structure")
    }

    /// A render that lands mid-walk must cancel it: `layoutToken` is what stops a stale walk from
    /// laying out ranges of a document that no longer exists. Two walks started back to back leave
    /// only the second one running, so the step count is the second walk's alone.
    func testANewWalkCancelsTheOneInFlight() throws {
        let (doc, wc) = try open(tableDenseMarkdown(tables: 60))
        defer { withExtendedLifetime(doc) {} }
        wc.precomputeLayout()
        wc.precomputeLayout()
        XCTAssertTrue(settle(wc))
        let storage = try XCTUnwrap(wc.textView.textStorage)
        let expected = max(1, Int(ceil(Double(storage.length) / 20_000.0)))
        XCTAssertEqual(wc.layoutStepCount, expected)
    }
}

extension OfficeRenderLatencyTests {
    /// Dumps one real table's resolved geometry — the parsed cell spans on one side, and the
    /// `NSTextTableBlock`s the reader actually laid out on the other. Column edges that disagree
    /// BETWEEN ROWS of the same table are invisible in a unit test and obvious here.
    /// `FMD_TABLE_PROBE=<file>` plus `FMD_TABLE_MATCH=<text in the table>`.
    func testDumpOneRealTableGeometry() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_TABLE_PROBE"] else {
            throw XCTSkip("set FMD_TABLE_PROBE to dump a real document's table geometry")
        }
        let needle = ProcessInfo.processInfo.environment["FMD_TABLE_MATCH"] ?? ""
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(contentsOf: url), ofType: "org.openxmlformats.wordprocessingml.document")

        func describe(_ blocks: [OfficeBlock], depth: Int = 0) {
            for b in blocks {
                guard case let .table(rows, _, widths, format) = b else { continue }
                let text = rows.flatMap { $0 }.flatMap { $0.blocks }.compactMap { blk -> String? in
                    if case let .paragraph(spans, _, _, _, _) = blk { return spans.map(\.text).joined() }
                    return nil
                }.joined()
                guard needle.isEmpty || text.contains(needle) else { continue }
                // One decimal, and the SUM alongside the source total. `Int()` truncates, and nine
                // truncated columns read as 4pt short of a grid that is exactly the page width —
                // which cost a real debugging session chasing a table-geometry bug that did not
                // exist. These are the SOURCE grid columns; the laid-out edges are cumulative and
                // rounded (`GridTextTable.edges(forWidth:)`), so they never drift.
                let sum = widths.reduce(0, +)
                let cols = widths.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                print(String(format: "  TABLE source grid=[%@] sum=%.1f sourceWidth=%.1f",
                             cols, sum, format.sourceWidth ?? -1))
                for (r, row) in rows.enumerated() {
                    let spec = row.map { "(c\($0.colSpan)r\($0.rowSpan)\($0.width.map { ",w\(Int($0))" } ?? ""))" }
                    print("    row\(r): \(row.count) cells \(spec.joined(separator: " "))")
                }
                return
            }
        }
        describe(doc.officeBlocks)

        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        wc.updateTextInset()
        let storage = try XCTUnwrap(wc.textStorageRef)
        // Dump the table that CONTAINS the needle, not merely the first one in the document.
        let ns = storage.string as NSString
        var target: ObjectIdentifier?
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            guard target == nil, let ps = v as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            if needle.isEmpty || ns.substring(with: r).contains(needle) {
                target = ObjectIdentifier(block.table); stop.pointee = true
            }
        }
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let ps = v as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock,
                  ObjectIdentifier(block.table) == target else { return }
            let cellText = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).prefix(9)
            print(String(format: "    r%d c%d span%d  content %7.2f  pad %4.1f/%4.1f  border %4.1f/%4.1f  %@",
                         block.startingRow, block.startingColumn, block.columnSpan, block.contentWidth,
                         block.width(for: .padding, edge: .minX), block.width(for: .padding, edge: .maxX),
                         block.width(for: .border, edge: .minX), block.width(for: .border, edge: .maxX),
                         String(cellText)))
        }
    }
}

/// A table must occupy the SAME width whatever its column count. It did not: cells subtracted their
/// full left and right border from their content while `collapsesBorders` makes AppKit charge a
/// shared interior border ONCE, so every extra column cost another border-width and a 9-column table
/// finished 8.5pt short of a 2-column one at the same reading width. Two tables in one report then
/// ended at visibly different x — the "tables look ragged" complaint, underneath the border colours.
/// Measured before the fix: 2 cols -1.5, 3 cols -2.5, 5 cols -4.5, 9 cols -8.5 against a 600pt target.
final class TableWidthIndependenceTests: XCTestCase {
    private func laidOutWidth(columns ncol: Int, target: CGFloat) -> CGFloat {
        let theme = RenderTheme.current(size: 16)
        let row = (0..<ncol).map { TableBlockBuilder.CellContent(content: NSAttributedString(string: "c\($0)")) }
        let attr = TableBlockBuilder.build(rows: [row, row], headerRows: 0, theme: theme,
                                           columnWidths: Array(repeating: target / CGFloat(ncol), count: ncol),
                                           width: target)
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: target, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).width
    }

    func testATableIsTheSameWidthWhateverItsColumnCount() {
        let target: CGFloat = 600
        let widths = [2, 3, 5, 9].map { laidOutWidth(columns: $0, target: target) }
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 0.01,
            "column count must not change the table's width — got \(widths)")
        for w in widths {
            XCTAssertEqual(w, target, accuracy: 1.0,
                "a table should fill its reading column, not fall short of it — got \(w)")
        }
    }
}
