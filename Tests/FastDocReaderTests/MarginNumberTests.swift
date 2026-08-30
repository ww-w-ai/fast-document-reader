import XCTest
import AppKit
@testable import FastDocReader

/// Line/page numbers in the margin: which unit a document gets, and that turning them on moves no
/// glyph. What a test CANNOT see is the drawing itself — that is `drawBackground`, the same seam the
/// reading-line band and the comment badges sit in, and it is verified by looking.
@MainActor
final class MarginNumberTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MarginNumberStore.reset()
        PageViewOptionsStore.reset()
    }

    override func tearDown() {
        MarginNumberStore.reset()
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    func testOffByDefault() {
        XCTAssertFalse(MarginNumberStore.isOn, "furniture that was never there must not appear unasked")
        XCTAssertNil(MarginNumberStore.unit(paged: true, drawingPages: true))
        XCTAssertNil(MarginNumberStore.unit(paged: false, drawingPages: false))
    }

    /// The unit is the DOCUMENT's, not a second preference: a file with pages on screen is numbered
    /// by page, everything else by its own lines — including a paged document whose pages are hidden,
    /// which is the owner's "페이지로 나눠보기 옵션이 없을 때에는 라인 번호로 통일".
    func testTheUnitFollowsTheDocument() {
        XCTAssertEqual(MarginNumberStore.unit(isOn: true, paged: true, drawingPages: true), .pages)
        XCTAssertEqual(MarginNumberStore.unit(isOn: true, paged: true, drawingPages: false), .lines)
        XCTAssertEqual(MarginNumberStore.unit(isOn: true, paged: false, drawingPages: false), .lines)
        XCTAssertEqual(MarginNumberStore.unit(isOn: true, paged: false, drawingPages: true), .lines,
                       "a document with no pages cannot be numbered by page, whatever the page menu says")
    }

    /// THE RULE THIS FEATURE LIVES UNDER: numbers are information ABOUT the document, so they must
    /// not be able to change it. Not merely "they aren't in the text storage" — the way a decoration
    /// moves a document is by asking a question that MAKES layout, from inside a draw pass. Asserted
    /// where it can actually be seen: the laid-out height and every line's position are identical
    /// with the numbers on and off, and the painter never advances `firstUnlaidGlyphIndex`.
    func testNumbersChangeNothingAboutTheDocument() throws {
        let url = repoRoot().appendingPathComponent("demo/code-blocks.md")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        func measure(numbers: MarginNumberUnit?) throws -> (CGFloat, [CGFloat], Int) {
            let doc = MarkdownDocument()
            doc.fileURL = url
            try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
            wc.textView.marginNumbers = numbers
            let lm = try XCTUnwrap(wc.textView.layoutManager)
            let tc = try XCTUnwrap(wc.textView.textContainer)
            lm.ensureLayout(for: tc)
            // Draw for real — the painter only ever runs from a draw pass, so a test that skips
            // drawing cannot see what it does (mutation-checked: it passes with the painter removed).
            wc.textView.displayIfNeeded()
            wc.textView.drawBackground(in: wc.textView.bounds)
            var tops: [CGFloat] = []
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { r, _, _, _, _ in
                tops.append(r.minY)
            }
            let h = lm.usedRect(for: tc).height
            doc.close()
            return (h, tops, tops.count)
        }

        let off = try measure(numbers: nil)
        let on = try measure(numbers: .lines)
        XCTAssertEqual(on.0, off.0, accuracy: 0.001, "the document's height moved because of a decoration")
        XCTAssertEqual(on.2, off.2, "the line count changed")
        XCTAssertEqual(on.1, off.1, "a line moved")
    }

    // MARK: - Go to line / page

    /// A JUMP is asked in the document's own unit whether or not the numbers are switched on: hiding
    /// the furniture does not remove the pages a reader wants to reach.
    func testTheJumpUnitIgnoresTheToggle() {
        XCTAssertFalse(MarginNumberStore.isOn, "precondition: numbers are off")
        XCTAssertEqual(MarginNumberStore.jumpUnit(paged: true, drawingPages: true), .pages)
        XCTAssertEqual(MarginNumberStore.jumpUnit(paged: true, drawingPages: false), .lines)
        XCTAssertEqual(MarginNumberStore.jumpUnit(paged: false, drawingPages: true), .lines)
    }

    /// A storage shaped like the painter sees one: blocks 0…3, of which block 2 is a table cell and
    /// therefore carries NO number. Hand-built rather than parsed so the numbering is stated by the
    /// test rather than inherited from whatever a fixture happens to contain.
    private func numberedStorage() -> NSTextStorage {
        let storage = NSTextStorage()
        let table = NSTextTable()
        for id in 0..<4 {
            let style = NSMutableParagraphStyle()
            if id == 2 {
                style.textBlocks = [NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                                     startingColumn: 0, columnSpan: 1)]
            }
            storage.append(NSAttributedString(string: "block \(id)\n",
                                              attributes: [MDAttr.blockId: id, .paragraphStyle: style]))
        }
        return storage
    }

    func testALineNumberResolvesToTheBlockThatCarriesIt() throws {
        let storage = numberedStorage()
        let char = try XCTUnwrap(MarginNumberNavigator.characterIndex(forLine: 2, in: storage))
        XCTAssertEqual(storage.attribute(MDAttr.blockId, at: char, effectiveRange: nil) as? Int, 1,
                       "line N is block N-1, the same arithmetic the margin draws")
        XCTAssertEqual(char, storage.string.distance(from: storage.string.startIndex,
                                                     to: storage.string.range(of: "block 1")!.lowerBound),
                       "and it lands at that block's FIRST character")
    }

    /// The numbers a reader can see have GAPS — every table block is missing from the sequence — so a
    /// request that falls in one must still land somewhere real: the next number that IS drawn.
    func testALineNumberInsideATableGoesToTheNextNumberedLine() throws {
        let storage = numberedStorage()
        let char = try XCTUnwrap(MarginNumberNavigator.characterIndex(forLine: 3, in: storage))
        XCTAssertEqual(storage.attribute(MDAttr.blockId, at: char, effectiveRange: nil) as? Int, 3,
                       "block 2 is a table cell and carries no number, so line 3 resolves past it")
    }

    func testAnOutOfRangeLineClampsIntoTheDocument() throws {
        let storage = numberedStorage()
        let past = try XCTUnwrap(MarginNumberNavigator.characterIndex(forLine: 9_999, in: storage))
        XCTAssertEqual(storage.attribute(MDAttr.blockId, at: past, effectiveRange: nil) as? Int, 3,
                       "past the end goes to the last numbered line, never nowhere")
        let before = try XCTUnwrap(MarginNumberNavigator.characterIndex(forLine: 0, in: storage))
        XCTAssertEqual(before, 0)
        XCTAssertNil(MarginNumberNavigator.characterIndex(forLine: 1, in: NSTextStorage()),
                     "an empty document has no line to go to")
    }

    func testAPageNumberClampsIntoTheDocumentsOwnRange() {
        XCTAssertEqual(MarginNumberNavigator.sheetIndex(forPage: 3, sheetCount: 8), 2)
        XCTAssertEqual(MarginNumberNavigator.sheetIndex(forPage: 0, sheetCount: 8), 0)
        XCTAssertEqual(MarginNumberNavigator.sheetIndex(forPage: 99, sheetCount: 8), 7)
        XCTAssertNil(MarginNumberNavigator.sheetIndex(forPage: 1, sheetCount: 0))
    }

    /// End to end, through the reader itself: asking for a page puts THAT SHEET's top edge at the top
    /// of the viewport. Judged against `pageSheets` — the same rectangles the outline draws and the
    /// printer prints — rather than against a character, because a page boundary belongs to the grid.
    func testGoingToAPageScrollsToThatSheetsTop() throws {
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true, splitTables: false)
        let url = repoRoot().appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "docs/ is local-only in this checkout")
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
        // The sheet grid exists only once the document is laid out — and a page can still MOVE while
        // the tables settle (invariant 61), so a jump measured before that would be measured against
        // a grid the reader never sees.
        wc.settlePagedTablesFully()
        defer { doc.close() }

        XCTAssertEqual(wc.jumpUnit, .pages, "a paged document drawing its pages is asked in pages")
        let sheets = wc.pageSheets
        try XCTSkipUnless(sheets.count >= 2, "needs a document of at least two sheets")
        wc.goTo(number: 2)
        XCTAssertEqual(wc.textView.visibleRect.minY, sheets[1].minY, accuracy: 0.5)
        // And page 1 goes to the very top rather than scrolling its own margin out of sight.
        wc.goTo(number: 1)
        XCTAssertEqual(wc.textView.visibleRect.minY, 0, accuracy: 0.5)
    }

    /// Typing the number is the whole command — no sheet, because a reader who can see "12" in the
    /// margin should not have to open a dialog to say 12. Driven through `keyDown`, which is the only
    /// place that can prove the digits are actually reaching the reader.
    func testTypingANumberAndPressingReturnJumps() throws {
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true, splitTables: false)
        let wc = try openPagedFixture()
        defer { wc.document.map { ($0 as? MarkdownDocument)?.close() } }
        let sheets = wc.pageSheets
        try XCTSkipUnless(sheets.count >= 3)

        wc.textView.keyDown(with: key("3"))
        XCTAssertEqual(wc.jumpBuffer, "3", "the digit must reach the reader, not be swallowed")
        wc.textView.keyDown(with: key("\r", code: 36))
        XCTAssertEqual(wc.jumpBuffer, "", "Return spends the number")
        XCTAssertEqual(wc.textView.visibleRect.minY, sheets[2].minY, accuracy: 0.5)
    }

    /// Escape forgets it, and — the load-bearing half — nothing a reader types can change the
    /// document. Typing is how a decoration would do the most damage, so the storage is asserted
    /// byte-for-byte around it.
    func testTypedDigitsNeverReachTheDocument() throws {
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true, splitTables: false)
        let wc = try openPagedFixture()
        defer { wc.document.map { ($0 as? MarkdownDocument)?.close() } }
        let before = wc.textView.textStorage?.string
        wc.textView.keyDown(with: key("1"))
        wc.textView.keyDown(with: key("2"))
        XCTAssertEqual(wc.jumpBuffer, "12")
        wc.textView.keyDown(with: key("\u{1b}", code: 53))
        XCTAssertEqual(wc.jumpBuffer, "", "Escape forgets the number")
        XCTAssertEqual(wc.textView.textStorage?.string, before, "typing changed the document")
    }

    /// The desk is what is left of the window after the paper, and at the reading zoom there is often
    /// none of it — so the number scales into whatever room there is and, failing that, moves just
    /// inside the paper's own left margin rather than silently not being drawn ("좌우 여백이 아주
    /// 크지 않으면 안 보임").
    func testTheDeskNumberFindsRoomOrMovesOntoThePaper() throws {
        let view = PageNumberDeskView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let wide = try XCTUnwrap(view.placement(number: 7, deskWidth: 300))
        XCTAssertLessThan(wide.x + wide.text.size().width, 300, "clear of the paper's edge")
        XCTAssertEqual((wide.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 44,
                       "44pt is the ceiling the owner set by looking at it")

        let tight = try XCTUnwrap(view.placement(number: 7, deskWidth: 40))
        XCTAssertLessThanOrEqual(tight.x + tight.text.size().width, 40, "must not spill onto the paper")
        let tightSize = try XCTUnwrap((tight.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize)
        XCTAssertLessThan(tightSize, 44, "stepped down to the room there is")

        let none = try XCTUnwrap(view.placement(number: 7, deskWidth: 0))
        XCTAssertGreaterThan(none.x, 0, "with no desk at all it goes inside the paper's margin")
    }

    private func key(_ chars: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func openPagedFixture() throws -> DocumentWindowController {
        let url = repoRoot().appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "docs/ is local-only in this checkout")
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
        wc.settlePagedTablesFully()
        return wc
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testThePreferenceSurvivesAndIsGlobal() {
        MarginNumberStore.isOn = true
        XCTAssertTrue(MarginNumberStore.isOn)
        MarginNumberStore.reset()
        XCTAssertFalse(MarginNumberStore.isOn, "reset must return the real default, not false-by-accident")
    }
}
