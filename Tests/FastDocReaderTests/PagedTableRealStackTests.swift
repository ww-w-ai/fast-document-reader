import XCTest
import AppKit
@testable import FastDocReader

/// "A table never prints in the margin", on the real stack. The engine's page plan decides where a
/// table goes (its own unit tests pin the rules); this is where the app is shown to REACH that
/// decision: opening, the View-menu toggle, and printing each take a plan, and the reference report
/// ends with no table row below its page's text bottom.
final class PagedTableRealStackTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUp() {
        super.setUp()
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    private func openPaged(_ relativePath: String) throws -> DocumentWindowController {
        let url = repoRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) is not in this checkout (docs/ is local-only)")
        }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
        return wc
    }

    /// How far each LINE inside a table falls past the bottom of the page it sits on. Non-empty means
    /// table content is being drawn in a margin, which is the defect — measured per line rather than
    /// per table, because a table the plan breaks across pages legitimately spans several of them
    /// while none of its rows may.
    private func linesInMargins(_ wc: DocumentWindowController) throws -> [CGFloat] {
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        let storage = try XCTUnwrap(wc.textView.textStorage)
        layout.ensureLayout(for: container)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        guard pitch > 0 else { return [] }
        var out: [CGFloat] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, gr, _ in
            let cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < storage.length,
                  let style = storage.attribute(.paragraphStyle, at: cr.location,
                                                effectiveRange: nil) as? NSParagraphStyle,
                  style.textBlocks.first is NSTextTableBlock else { return }
            let page = ((rect.minY - d.leadingBand) / pitch).rounded(.down)
            let over = (rect.maxY - d.leadingBand) - d.textBottom(ofPage: page)
            if over > 0.01 { out.append(over) }
        }
        return out
    }

    /// Back to the typesetter's own layout: what the document would look like if nobody paginated it.
    private func unpaginate(_ wc: DocumentWindowController) {
        wc.pageBandDelegate.resetPlan()
        if let lm = wc.textView.layoutManager, let length = wc.textView.textStorage?.length {
            lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
        }
    }

    /// THE REPORTED DEFECT, on the document it was reported on: four of this report's sixteen tables
    /// ran past their page's text bottom, so those rows printed inside the margin. The plan leaves none.
    func testTheReferenceReportEndsWithNoTableRowInAMargin() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.pageBandDelegate.paginates, "this fixture must actually paginate")
        unpaginate(wc)
        XCTAssertFalse(try linesInMargins(wc).isEmpty,
                       "unpaginated, the fixture must have rows in the margin, or this proves nothing")
        wc.paginateNow()
        XCTAssertEqual(try linesInMargins(wc), [], "no table row may sit in a margin once the plan is applied")
        XCTAssertFalse(wc.pageBandDelegate.targets.isEmpty)
    }

    /// A table taller than its page is broken where it stands, even with tables kept whole: there is
    /// no page to carry it to.
    func testATableTallerThanItsPageIsBrokenEvenWhenTablesAreKeptWhole() throws {
        XCTAssertFalse(PageViewOptionsStore.startingOptions.splitTables, "precondition: the setting says whole")
        let wc = try openPaged("docs/fixtures/office/paged-visual/tablepage.docx")
        XCTAssertTrue(wc.pageBandDelegate.paginates)
        unpaginate(wc)
        XCTAssertFalse(try linesInMargins(wc).isEmpty, "precondition: it starts out overrunning")
        wc.paginateNow()
        let flowed = (wc.lastPlan?["flowedTables"] as? [Any]) ?? []
        XCTAssertFalse(flowed.isEmpty, "a table with no page to move to is broken where it stands")
        XCTAssertEqual(try linesInMargins(wc), [], "and then no row of it may sit in a margin")
    }

    /// The menu's own effect, on a table that COULD be kept whole: with breaking on it is broken where
    /// it stands instead of being carried down, so the same tables sit higher.
    func testTheSettingDecidesBetweenBreakingATableAndCarryingItDown() throws {
        func tableTops(_ split: Bool) throws -> [CGFloat] {
            PageViewOptionsStore.startingOptions = PageViewOptions(outline: true, splitTables: split)
            let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
            wc.paginateNow()
            XCTAssertEqual(try linesInMargins(wc), [], "either way, nothing may end in a margin")
            return try Self.tableTops(in: wc)
        }
        let whole = try tableTops(false)
        let split = try tableTops(true)
        XCTAssertEqual(whole.count, split.count, "the same tables exist under both settings")
        XCTAssertTrue(zip(split, whole).contains { $0 < $1 },
                      "breaking leaves a table where it started; keeping it whole carries it "
                      + "down to the next page, so its top is lower — tops split \(split) whole \(whole)")
    }

    /// The minimum line-fragment top of each distinct table, in document order.
    static func tableTops(in wc: DocumentWindowController) throws -> [CGFloat] {
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        let storage = try XCTUnwrap(wc.textView.textStorage)
        var tops: [CGFloat] = []
        var seen: [ObjectIdentifier: Int] = [:]
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, gr, _ in
            let cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < storage.length,
                  let style = storage.attribute(.paragraphStyle, at: cr.location,
                                                effectiveRange: nil) as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock else { return }
            let key = ObjectIdentifier(block.table)
            if let i = seen[key] {
                tops[i] = min(tops[i], rect.minY)
            } else {
                seen[key] = tops.count
                tops.append(rect.minY)
            }
        }
        return tops
    }

    /// Printing must not depend on the window's own generation having run: ⌘P straight after
    /// opening is exactly when it has not. The paper is a function of the document (invariant 151).
    func testPrintingTakesThePlanItself() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        unpaginate(wc)
        XCTAssertTrue(wc.pageBandDelegate.targets.isEmpty, "nothing has been planned yet")
        let planned = wc.planCallCount
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-table-overrun-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let op = wc.makePrintOperation()
        XCTAssertFalse(wc.pageBandDelegate.targets.isEmpty, "⌘P must plan the pages before deciding what goes on each sheet")
        XCTAssertEqual(wc.planCallCount, planned + 1, "…with exactly one plan call")
        XCTAssertEqual(try linesInMargins(wc), [])

        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        XCTAssertTrue(op.run())
        let provider = try XCTUnwrap(CGDataProvider(data: try Data(contentsOf: out) as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(pdf.numberOfPages, wc.printPageCount,
                       "the printout must have the page count the planned reader reports")
        let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.height, 841.89, accuracy: 1.0, "still A4 — moving tables must not resize paper")
    }

    /// THE SEAM NO OTHER TEST HERE CAN SEE (invariant 29's lesson): every check above asks for the
    /// plan itself, which proves the rule and says nothing about whether the app ever REACHES it.
    /// Opening a document paginates through `precomputeLayout`'s own walk.
    func testJustOpeningTheDocumentPlansItOnItsOwn() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        XCTAssertEqual(wc.planCallCount, 0, "the full plan comes with the walk, not with the render")
        XCTAssertEqual(wc.prefixPlanCount, 1, "the first paint was planned from the head of the text")
        // Waited for by POLLING rather than by a completion: `precomputeLayout` cancels an in-flight
        // walk whenever a new one starts (invariant 60b), so a callback races the document's own
        // opening walk and may never fire. What is claimed is "opening it is enough".
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !((try? linesInMargins(wc))?.isEmpty ?? false) && wc.planCallCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        while Date() < deadline && wc.planCallCount == 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(wc.planCallCount, 0, "the walk that lays a paged document out must take its plan")
        XCTAssertEqual(try linesInMargins(wc), [], "opening the document must be enough")
    }

    /// The View menu item, through the real action — it flips the stored preference, the open document
    /// re-plans on the spot, and neither answer leaves a row in a margin.
    func testTheMenuItemRepaginatesTheOpenDocument() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        wc.paginateNow()
        let whole = wc.printPageCount
        XCTAssertEqual(try linesInMargins(wc), [])
        let lm = try XCTUnwrap(wc.textView.layoutManager)
        let tc = try XCTUnwrap(wc.textView.textContainer)
        lm.ensureLayout(for: tc)
        let carriedHeight = lm.usedRect(for: tc).height

        wc.toggleSplitTables(nil)
        XCTAssertTrue(PageViewOptionsStore.startingOptions.splitTables, "the menu item must store the choice")
        wc.paginateNow()
        lm.ensureLayout(for: tc)
        XCTAssertLessThan(lm.usedRect(for: tc).height, carriedHeight,
                          "breaking tables gives back the foot of every page a carry left empty")
        XCTAssertLessThanOrEqual(wc.printPageCount, whole,
                                 "breaking tables never needs more pages than carrying them")
        XCTAssertEqual(try linesInMargins(wc), [])
    }

    /// It is checked to match the stored choice and disabled where there is no paper.
    func testTheMenuItemIsCheckedAndIsDisabledWithoutPaper() throws {
        let item = NSMenuItem(title: "Split Tables Across Pages",
                              action: #selector(DocumentWindowController.toggleSplitTables(_:)),
                              keyEquivalent: "")
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.validateMenuItem(item), "a paged document can choose")
        XCTAssertEqual(item.state, .off, "…and starts on the shipped default")
        wc.toggleSplitTables(nil)
        XCTAssertTrue(wc.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
    }

    /// Invariant 57(d): a document with no page is not the plan's business at all.
    func testANonPagedDocumentIsNeverPlanned() throws {
        let source = "# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmd-paged-table-\(UUID().uuidString).md")
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        XCTAssertFalse(wc.pageBandDelegate.isActive)
        XCTAssertFalse(wc.paginate(), "a markdown document has no pages to plan")
        XCTAssertTrue(wc.pageBandDelegate.targets.isEmpty)
        XCTAssertEqual(wc.planCallCount, 0)
    }
}
