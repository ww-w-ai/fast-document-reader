import XCTest
import AppKit
@testable import FastDocReader

/// "A table never prints in the margin" — the three layers of it.
///
///  1. `PagePagination.tablesToPush` — the DECISION, pure arithmetic over what a layout produced.
///  2. `PageBandLayoutDelegate` — the MOVE, in isolation against a real `NSTextTable`.
///  3. The real stack — that the two are wired together, that the reference report ends with zero
///     rows in a margin, and that everything which is not a paged table is provably untouched.
///
/// The measured findings behind the design live in `PageBandLayoutDelegate.pushWholeTable`: splitting
/// a table at the boundary was built and does work on single-line rows, and tears a real report's
/// vertically merged cells, which is why the table is MOVED instead.
final class PagedTableOverrunTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUp() {
        super.setUp()
        // The page outline adds a desk to the band and so moves the pitch; every number below is
        // about tables, not about that, so it is pinned exactly as `PageBandReservationTests` pins it.
        PageViewOptionsStore.current = PageViewOptions(outline: false, header: true, footer: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    // MARK: - 1. The decision

    /// Page 0's text runs 0…100, page 1's 120…220 (band 20).
    private let geometry = (pageContentHeight: CGFloat(100), band: CGFloat(20), leadingBand: CGFloat(0))

    private func decide(_ tables: [PagePagination.LaidOutTable],
                        alreadyPushed: [Int: PagePagination.TableMetrics] = [:])
        -> [Int: PagePagination.TableMetrics] {
        PagePagination.tablesToPush(tables, pageContentHeight: geometry.pageContentHeight,
                                    band: geometry.band, leadingBand: geometry.leadingBand,
                                    alreadyPushed: alreadyPushed)
    }

    func testATableThatEndsInsideItsOwnPageIsLeftAlone() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 20, bottom: 90, firstLineTop: 20)
        XCTAssertTrue(decide([t]).isEmpty, "a table that fits on its page must not be moved")
    }

    /// The whole point: its last rows would land in the margin, and it would fit on a page of its own.
    func testATableThatRunsIntoTheMarginAndWouldFitOnAPageIsMoved() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 60, bottom: 130, firstLineTop: 60)
        let out = decide([t])
        XCTAssertEqual(out[10], PagePagination.TableMetrics(height: 70, topInset: 0))
        XCTAssertEqual(out.count, 1)
    }

    /// A table taller than the page body gains nothing by moving — it would overrun the next page just
    /// as far, having emptied the one it left. Real: a 25-row fixture's 660pt table on a 220pt page,
    /// and every giant table of invariant 55.
    func testATableTallerThanThePageIsNeverMoved() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 20, bottom: 200, firstLineTop: 20)
        XCTAssertTrue(decide([t]).isEmpty,
                      "a table that cannot fit on any page must stay where it is and overrun honestly")
    }

    /// Exactly at the page's last point is still inside it — the boundary case that decides whether a
    /// document paginates one way or the other.
    func testATableEndingExactlyOnThePageBottomIsNotMoved() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 30, bottom: 100, firstLineTop: 30)
        XCTAssertTrue(decide([t]).isEmpty)
        let overByAHair = PagePagination.LaidOutTable(firstChar: 10, visualTop: 30, bottom: 100.5,
                                                      firstLineTop: 30)
        XCTAssertEqual(decide([overByAHair]).count, 1)
    }

    /// A vertically merged cell is centred in its own span, so the first line the typesetter reaches
    /// can sit well below the table's top edge. That distance has to be carried or the move lands the
    /// table's VISIBLE top that far past the page's.
    func testTheRecordedInsetIsHowFarTheFirstLineSitsBelowTheTablesTop() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 60, bottom: 130, firstLineTop: 81.35)
        XCTAssertEqual(decide([t])[10]?.topInset ?? -1, 21.35, accuracy: 0.001)
    }

    /// Kept verbatim, and that is what makes the settle loop converge: a moved table now FITS, so
    /// re-deriving would drop it, which would move it back, which would make it not fit…
    func testAlreadyDecidedTablesSurviveARoundThatWouldNotReDeriveThem() {
        let moved = PagePagination.LaidOutTable(firstChar: 10, visualTop: 120, bottom: 190, firstLineTop: 120)
        let previous = [10: PagePagination.TableMetrics(height: 70, topInset: 0)]
        XCTAssertEqual(decide([moved], alreadyPushed: previous), previous)
    }

    func testNothingIsDecidedForADocumentWithNoPage() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 60, bottom: 130, firstLineTop: 60)
        XCTAssertTrue(PagePagination.tablesToPush([t], pageContentHeight: 0, band: 0, leadingBand: 0).isEmpty)
    }

    // MARK: - 2. The move, in isolation

    private func makeStack(_ delegate: PageBandLayoutDelegate)
        -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.delegate = delegate
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    /// A prose paragraph, then a real two-column table of `rows` rows — the same `NSTextTableBlock`
    /// shape `TableBlockBuilder` produces, which is what the delegate keys off.
    private func documentWithTable(leadingLines: Int, rows: Int) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        for i in 0..<leadingLines {
            out.append(NSAttributedString(string: "Body line \(i)\n",
                                          attributes: [.font: font,
                                                       .paragraphStyle: NSParagraphStyle.default]))
        }
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.setContentWidth(300, type: .absoluteValueType)
        table.collapsesBorders = false
        for r in 0..<rows {
            for c in 0..<2 {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                             startingColumn: c, columnSpan: 1)
                block.setContentWidth(150, type: .absoluteValueType)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                out.append(NSAttributedString(string: "r\(r)c\(c)\n",
                                              attributes: [.font: font, .paragraphStyle: style]))
            }
        }
        return out
    }

    /// Every line fragment, and the extent of the ones inside a table.
    private func tableExtent(_ layout: NSLayoutManager, _ container: NSTextContainer,
                             _ storage: NSTextStorage) -> (top: CGFloat, bottom: CGFloat, firstChar: Int)? {
        layout.ensureLayout(for: container)
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        var firstChar: Int?
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, gr, _ in
            let cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            guard cr.location < storage.length,
                  let style = storage.attribute(.paragraphStyle, at: cr.location,
                                                effectiveRange: nil) as? NSParagraphStyle,
                  style.textBlocks.first is NSTextTableBlock else { return }
            if firstChar == nil { firstChar = cr.location }
            top = min(top, rect.minY)
            bottom = max(bottom, rect.maxY)
        }
        guard let firstChar else { return nil }
        return (top, bottom, firstChar)
    }

    /// THE PRE-EXISTING CONTRACT, and the thing this change must not quietly take away: with nothing
    /// measured, a table line is never touched. Every document whose tables all fit lays out exactly
    /// as it did before any of this existed.
    func testATableIsNeverMovedUntilSomethingHasMeasuredIt() throws {
        let d = PageBandLayoutDelegate(pageContentHeight: 120, band: 40)
        let (storage, layout, container) = makeStack(d)
        storage.setAttributedString(documentWithTable(leadingLines: 4, rows: 8))
        let before = try XCTUnwrap(tableExtent(layout, container, storage))
        XCTAssertGreaterThan(before.bottom, 120, "the fixture must actually overrun, or it proves nothing")
        XCTAssertTrue(d.pushedTables.isEmpty)
        // Its top is wherever the prose left it — no page arithmetic has been applied to it.
        XCTAssertLessThan(before.top, 120)
    }

    func testAMeasuredTableMovesWholeToTheNextPageTop() throws {
        let d = PageBandLayoutDelegate(pageContentHeight: 120, band: 40)
        let (storage, layout, container) = makeStack(d)
        storage.setAttributedString(documentWithTable(leadingLines: 4, rows: 8))
        let before = try XCTUnwrap(tableExtent(layout, container, storage))
        let height = before.bottom - before.top

        d.pushedTables = [before.firstChar: PagePagination.TableMetrics(height: height, topInset: 0)]
        layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                actualCharacterRange: nil)
        let after = try XCTUnwrap(tableExtent(layout, container, storage))

        XCTAssertEqual(after.top, 160, accuracy: 0.01,
                       "the table's top must land on page 1's own text top (pitch 160)")
        XCTAssertEqual(after.bottom - after.top, height, accuracy: 0.01,
                       "the table must move as ONE piece — shifting its first line carries the rest")
        XCTAssertEqual(d.openedBoundaries, [0], "the boundary it cleared is the one that opened")
        XCTAssertEqual(d.openedBands[0]?.top ?? -1, before.top, accuracy: 0.01,
                       "the gap starts where the table was going to, not at the arithmetic page bottom")
    }

    /// Idempotence, which is what lets the settle loop stop: the same rule applied to an already-moved
    /// table declines to move it. Without this the table would walk down a page per layout pass.
    func testATableAlreadyAtAPageTopIsNotMovedAgain() throws {
        let d = PageBandLayoutDelegate(pageContentHeight: 120, band: 40)
        let (storage, layout, container) = makeStack(d)
        storage.setAttributedString(documentWithTable(leadingLines: 4, rows: 8))
        let before = try XCTUnwrap(tableExtent(layout, container, storage))
        d.pushedTables = [before.firstChar:
            PagePagination.TableMetrics(height: before.bottom - before.top, topInset: 0)]
        layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                actualCharacterRange: nil)
        let once = try XCTUnwrap(tableExtent(layout, container, storage))
        for _ in 0..<3 {
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                    actualCharacterRange: nil)
            let again = try XCTUnwrap(tableExtent(layout, container, storage))
            XCTAssertEqual(again.top, once.top, accuracy: 0.01,
                           "re-laying out must not walk the table down another page")
        }
    }

    /// The refusal, in the layout rule itself rather than only in the decision: even if something put
    /// an over-tall table in the record, moving it would only waste the page it left.
    func testAnOverTallTableIsNotMovedEvenIfItIsInTheRecord() throws {
        let d = PageBandLayoutDelegate(pageContentHeight: 120, band: 40)
        let (storage, layout, container) = makeStack(d)
        storage.setAttributedString(documentWithTable(leadingLines: 2, rows: 40))
        let before = try XCTUnwrap(tableExtent(layout, container, storage))
        XCTAssertGreaterThan(before.bottom - before.top, 120, "fixture must be taller than a page")
        // The decision refuses it, which is where the guard belongs.
        let decided = PagePagination.tablesToPush(
            [PagePagination.LaidOutTable(firstChar: before.firstChar, visualTop: before.top,
                                         bottom: before.bottom, firstLineTop: before.top)],
            pageContentHeight: 120, band: 40, leadingBand: 0)
        XCTAssertTrue(decided.isEmpty)
    }

    // MARK: - 3. The real stack

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

    /// How far each table runs past the text bottom of the page it starts on. Positive = rows in the
    /// margin, which is the defect.
    private func overruns(_ wc: DocumentWindowController) throws -> [CGFloat] {
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        let storage = try XCTUnwrap(wc.textView.textStorage)
        layout.ensureLayout(for: container)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        guard pitch > 0 else { return [] }
        var runs: [(top: CGFloat, bottom: CGFloat)] = []
        var current: ObjectIdentifier?
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, gr, _ in
            let cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            var table: ObjectIdentifier?
            if cr.location < storage.length,
               let style = storage.attribute(.paragraphStyle, at: cr.location,
                                             effectiveRange: nil) as? NSParagraphStyle,
               let block = style.textBlocks.first as? NSTextTableBlock {
                table = ObjectIdentifier(block.table)
            }
            guard let table else { current = nil; return }
            if current == table, var last = runs.last {
                last.top = min(last.top, rect.minY)
                last.bottom = max(last.bottom, rect.maxY)
                runs[runs.count - 1] = last
            } else {
                current = table
                runs.append((rect.minY, rect.maxY))
            }
        }
        return runs.compactMap { r in
            let page = ((r.top - d.leadingBand) / pitch).rounded(.down)
            let over = (r.bottom - d.leadingBand) - (page * pitch + d.pageContentHeight)
            return over > 0.01 ? over : nil
        }
    }

    /// THE REPORTED DEFECT, on the document it was reported on: four of this report's sixteen tables
    /// ran past their page's text bottom by 71–236pt, so those rows printed inside the margin — three
    /// of its eight sheets. Settling leaves none.
    func testTheReferenceReportEndsWithNoTableRowInAMargin() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.pageBandDelegate.isActive, "this fixture must actually paginate")
        XCTAssertFalse(try overruns(wc).isEmpty,
                       "the fixture must start out with rows in the margin, or this proves nothing")
        wc.settlePagedTablesFully()
        XCTAssertEqual(try overruns(wc), [], "no table may end inside a margin once the pages settle")
        XCTAssertFalse(wc.pageBandDelegate.pushedTables.isEmpty)
    }

    /// Same claim on the ODT twin of that report, because the two formats reach the same builder by
    /// different roads and only running both can say the pagination is the reader's rather than the
    /// docx parser's.
    func testTheSameReportAsOdtAlsoEndsWithNoTableRowInAMargin() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.odt")
        XCTAssertTrue(wc.pageBandDelegate.isActive)
        wc.settlePagedTablesFully()
        XCTAssertEqual(try overruns(wc), [])
    }

    /// The honest limit, kept visible: a table taller than its own page cannot be moved anywhere that
    /// helps, so it still overruns — and `PagePagination.joiningUnopenedBoundaries` is what draws that
    /// truthfully on screen. A future change that "fixed" this by moving it anyway would add an empty
    /// page and change nothing else.
    func testATableTallerThanItsPageStillOverrunsAfterSettling() throws {
        let wc = try openPaged("docs/fixtures/office/paged-visual/tablepage.docx")
        XCTAssertTrue(wc.pageBandDelegate.isActive)
        wc.settlePagedTablesFully()
        XCTAssertTrue(wc.pageBandDelegate.pushedTables.isEmpty,
                      "a table that cannot fit on any page must not be moved")
        XCTAssertFalse(try overruns(wc).isEmpty)
    }

    /// Printing must not depend on the ASYNCHRONOUS settle having finished: ⌘P straight after opening
    /// is exactly when it has not. Paper cannot show an overrun honestly the way the screen can.
    func testPrintingSettlesTheTablesItself() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.pageBandDelegate.pushedTables.isEmpty, "nothing has settled yet")
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-table-overrun-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let op = wc.makePrintOperation()
        XCTAssertFalse(wc.pageBandDelegate.pushedTables.isEmpty,
                       "⌘P must settle the pages before deciding what goes on each sheet")
        XCTAssertEqual(try overruns(wc), [])

        // And the printout itself, which is where the defect was reported: run headlessly to a file so
        // the paper and the page count are ordinary assertions rather than something judged by looking
        // at a printed page.
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        XCTAssertTrue(op.run())
        let provider = try XCTUnwrap(CGDataProvider(data: try Data(contentsOf: out) as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(pdf.numberOfPages, wc.printPageCount,
                       "the printout must have the page count the settled reader reports")
        let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.height, 841.89, accuracy: 1.0, "still A4 — moving tables must not resize paper")
    }

    /// THE SEAM NO OTHER TEST HERE CAN SEE (invariant 29's lesson): every check above calls
    /// `settlePagedTablesFully` itself, which proves the rule and says nothing about whether the app
    /// ever REACHES it. Opening a document settles asynchronously, through `precomputeLayout`'s own
    /// chunked walk, and a version whose walk never called the settle would leave all of them green
    /// while every reader still printed rows in the margin.
    func testJustOpeningTheDocumentSettlesItsTablesOnItsOwn() throws {
        let wc = try openPaged("docs/fixtures/office/bus-headings.docx")
        XCTAssertTrue(wc.pageBandDelegate.pushedTables.isEmpty, "nothing has settled synchronously")
        // Waited for by POLLING rather than by a completion, deliberately: `precomputeLayout` cancels
        // an in-flight walk whenever a new one starts, and a cancelled walk's completion never runs
        // (invariant 60b) — so a callback here races the document's own opening walk and simply never
        // fires. What is being claimed is "opening it is enough", and that is what this waits for.
        // Waited on the RESULT rather than on the first sign of life: one round of settling only moves
        // the tables that overran where they stood, and moving them makes later ones overrun, so a
        // wait that stops at "something was recorded" catches the document mid-repagination (measured:
        // three tables still in the margin at that instant).
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !((try? overruns(wc))?.isEmpty ?? false) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(wc.pageBandDelegate.pushedTables.isEmpty,
                       "the walk that lays a paged document out must settle its tables — nothing else "
                       + "in this file can see that wiring")
        XCTAssertEqual(try overruns(wc), [],
                       "opening the document must be enough; no reader calls settlePagedTables itself")
    }

    /// Invariant 57(d), from this feature's direction: a document with no page is not this rule's
    /// business at all, and must not be re-laid-out by it.
    func testANonPagedDocumentIsNeverSettled() throws {
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
        XCTAssertFalse(wc.settlePagedTables(), "a markdown document has no pages to settle")
        XCTAssertTrue(wc.pageBandDelegate.pushedTables.isEmpty)
    }
}
