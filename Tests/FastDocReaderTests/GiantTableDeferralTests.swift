import XCTest
import AppKit
@testable import FastDocReader

/// A table so large that BUILDING its grid is the whole opening freeze is left out of the first
/// paint and spliced in afterwards (`docs/giant-table-deferral-design.md`). Two things have to hold
/// or this is a regression rather than a speed-up: a document below the line must be untouched BYTE
/// FOR BYTE (invariant 37), and a document above it must end up with exactly the string it would
/// have had anyway — the deferral is a schedule, not a different document.
final class GiantTableDeferralTests: XCTestCase {
    /// The reading size is SEEDED from a persisted value, so a test that zooms leaks into every
    /// later test's freshly opened document — `OfficeRenderLatencyTests` carries the same guard for
    /// the same reason. Without it `testZoomingDeepInsideAGiantTableKeepsTheReadersPlace` passes
    /// alone and fails inside the class, which reads exactly like a product bug and is not one.
    override func setUp() { super.setUp(); FontSizeStore.startingSize = FontSizeStore.defaultSize }
    override func tearDown() { FontSizeStore.startingSize = FontSizeStore.defaultSize; super.tearDown() }

    private let theme = RenderTheme.current(size: 16)

    // MARK: Structural comparison
    //
    // `NSAttributedString.isEqual` is the WRONG instrument for anything holding a table, and finding
    // that out cost the prototype a wrong conclusion: `NSTextTable`/`NSTextTableBlock` are reference
    // types, and `NSParagraphStyle`'s equality compares its `textBlocks` by OBJECT IDENTITY. Two
    // builds of the same table therefore never compare equal, no matter how identical their geometry
    // is. So each run is reduced to a VALUE fingerprint — every attribute that reaches the screen,
    // with the table blocks described by their geometry rather than their address.

    private func describe(_ block: NSTextTableBlock) -> String {
        let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]
        let widths = edges.map { String(format: "%.2f", block.width(for: .border, edge: $0)) }.joined(separator: "/")
        let pads = edges.map { String(format: "%.2f", block.width(for: .padding, edge: $0)) }.joined(separator: "/")
        let colours = edges.map { block.borderColor(for: $0)?.description ?? "-" }.joined(separator: "/")
        return "cell(r\(block.startingRow)+\(block.rowSpan),c\(block.startingColumn)+\(block.columnSpan)"
            + " w=\(String(format: "%.2f", block.contentWidth)):\(block.contentWidthValueType.rawValue)"
            + " border=\(widths) pad=\(pads) colour=\(colours)"
            + " bg=\(block.backgroundColor?.description ?? "-") valign=\(block.verticalAlignment.rawValue)"
            + " table(cols=\(block.table.numberOfColumns) collapse=\(block.table.collapsesBorders))"
    }

    private func describe(_ style: NSParagraphStyle) -> String {
        let blocks = style.textBlocks.map { ($0 as? NSTextTableBlock).map(describe) ?? "block" }
        return "align=\(style.alignment.rawValue) head=\(style.headIndent) first=\(style.firstLineHeadIndent)"
            + " tail=\(style.tailIndent) before=\(style.paragraphSpacingBefore) after=\(style.paragraphSpacing)"
            + " lh=\(style.minimumLineHeight)/\(style.maximumLineHeight)/\(style.lineHeightMultiple)"
            + " base=\(style.baseWritingDirection.rawValue)"
            + " tabs=[\(style.tabStops.map { "\($0.alignment.rawValue)@\($0.location)" }.joined(separator: ","))]"
            + " blocks=[\(blocks.joined(separator: " | "))]"
    }

    private func fingerprint(_ s: NSAttributedString) -> String {
        var out: [String] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            let described = attrs.map { key, value -> String in
                if let style = value as? NSParagraphStyle { return "\(key.rawValue)={\(describe(style))}" }
                if let font = value as? NSFont {
                    return "\(key.rawValue)=\(font.fontName)@\(font.pointSize)"
                        + "/\(font.fontDescriptor.symbolicTraits.rawValue)"
                }
                if let att = value as? NSTextAttachment {
                    return "\(key.rawValue)=attachment\(NSStringFromRect(att.bounds))"
                        + "\(att.image == nil ? "-empty" : "-image")"
                }
                return "\(key.rawValue)=\(value)"
            }.sorted().joined(separator: " ")
            out.append("[\(range.location),\(range.length)] "
                       + "\(s.attributedSubstring(from: range).string.debugDescription) \(described)")
        }
        return out.joined(separator: "\n")
    }

    /// Compares two builds the way a reader would experience them — same text, same attribute runs,
    /// same table geometry — reporting the FIRST line that differs rather than a bare false.
    private func assertStructurallyIdentical(_ a: NSAttributedString, _ b: NSAttributedString,
                                             _ message: String,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.string, b.string, "\(message) — text differs", file: file, line: line)
        assertFingerprintsMatch(fingerprint(a), fingerprint(b), message, file: file, line: line)
    }

    /// The comparison for two strings that have BOTH been installed in a text view. Installing is not
    /// neutral — AppKit's own `fixAttributes` puts `Helvetica 12` on any character left without a
    /// font, which a paragraph's bare terminator legitimately is — so a live storage never matches a
    /// string straight out of the builder, on this branch or any other. Comparing storage to storage
    /// keeps the assertion about THIS change instead of about AppKit's fixups.
    private func assertFingerprintsMatch(_ a: String, _ b: String, _ message: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let (fa, fb) = (a.split(separator: "\n"), b.split(separator: "\n"))
        XCTAssertEqual(fa.count, fb.count, "\(message) — different number of attribute runs",
                       file: file, line: line)
        for (i, (x, y)) in zip(fa, fb).enumerated() where x != y {
            XCTFail("\(message) — run \(i) differs:\n  expected \(y)\n  got      \(x)", file: file, line: line)
            return
        }
    }

    private func table(rows: Int, cols: Int) -> OfficeBlock {
        let grid = (0..<rows).map { r in
            (0..<cols).map { c in Cell(blocks: [.paragraph(spans: [Span(text: "r\(r)c\(c)")])]) }
        }
        return .table(rows: grid, headerRows: 1)
    }

    // MARK: - The line

    /// Both halves of `rows >= 50 AND rows × cols >= 500` are load-bearing. The row half alone would
    /// catch a tall narrow prose table that costs nothing (the reference manual's 103×2 is the real
    /// case that forced the cell half); the cell half alone would catch a wide short one whose grid
    /// is cheap.
    func testTheLineNeedsBOTHRowsAndCells() {
        // 50 rows × 10 cols = 500 cells — exactly on the line, both ways.
        XCTAssertEqual(OfficeTextBuilder.giantTableIndices([table(rows: 50, cols: 10)]), [0])
        // Tall but narrow: 103×2 = 206 cells. This is the reference manual's shape and must NOT fire.
        XCTAssertTrue(OfficeTextBuilder.giantTableIndices([table(rows: 103, cols: 2)]).isEmpty)
        // Wide but short: 10×60 = 600 cells, under 50 rows.
        XCTAssertTrue(OfficeTextBuilder.giantTableIndices([table(rows: 10, cols: 60)]).isEmpty)
        // One under on each axis.
        XCTAssertTrue(OfficeTextBuilder.giantTableIndices([table(rows: 49, cols: 10)]).isEmpty)
        XCTAssertTrue(OfficeTextBuilder.giantTableIndices([table(rows: 50, cols: 9)]).isEmpty)
    }

    func testTheLineReportsEveryQualifyingTablesOwnIndex() {
        let blocks: [OfficeBlock] = [
            .paragraph(spans: [Span(text: "intro")]),
            table(rows: 60, cols: 10),          // 1 — qualifies
            .paragraph(spans: [Span(text: "between")]),
            table(rows: 3, cols: 3),            // 3 — does not
            table(rows: 200, cols: 8),          // 4 — qualifies
        ]
        XCTAssertEqual(OfficeTextBuilder.giantTableIndices(blocks), [1, 4])
    }

    /// A colSpan makes a row WIDER than its cell count, and the cost follows the grid, not the
    /// number of `Cell` values — 50 rows of 5 cells each spanning 2 columns is a 50×10 grid.
    func testColumnCountFollowsTheGridNotTheCellCount() {
        let grid = (0..<50).map { _ in
            (0..<5).map { _ in Cell(blocks: [.paragraph(spans: [Span(text: "x")])], colSpan: 2) }
        }
        XCTAssertEqual(OfficeTextBuilder.giantTableIndices([.table(rows: grid, headerRows: 0)]), [0])
    }

    // MARK: - Invariant 37: everything below the line is byte-identical

    func testAnEmptyDeferralSetBuildsTheIdenticalString() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [Span(text: "Report")]),
            table(rows: 6, cols: 4),
            .paragraph(spans: [Span(text: "after")]),
        ]
        let before = OfficeTextBuilder.build(blocks, theme: theme, columnWidth: 700, tableWidth: 690)
        let after = OfficeTextBuilder.build(blocks, theme: theme, columnWidth: 700, tableWidth: 690,
                                            deferringTables: [])
        assertStructurallyIdentical(after, before,
                                    "a document that defers nothing must be identical")
    }

    // MARK: - The stand-in

    func testAStandInHoldsThePlaceAndTheBlockIdOfTheTableItReplaces() {
        let blocks: [OfficeBlock] = [
            .paragraph(spans: [Span(text: "before")]),
            table(rows: 60, cols: 10),
            .paragraph(spans: [Span(text: "after")]),
        ]
        let full = OfficeTextBuilder.build(blocks, theme: theme, columnWidth: 700, tableWidth: 690)
        let deferred = OfficeTextBuilder.build(blocks, theme: theme, columnWidth: 700, tableWidth: 690,
                                               deferringTables: [1])

        XCTAssertLessThan(deferred.length, full.length / 10,
                          "the point is that the deferred document is SHORT — the grid is what costs")
        // The stand-in is found by attribute, never by text: that is the contract the splice uses.
        var standIn: (NSRange, Int)?
        deferred.enumerateAttribute(MDAttr.deferredTable,
                                    in: NSRange(location: 0, length: deferred.length)) { v, r, stop in
            if let i = v as? Int { standIn = (r, i); stop.pointee = true }
        }
        let (range, index) = try! XCTUnwrap(standIn)
        XCTAssertEqual(index, 1, "the attribute carries the BLOCK index, which is what rebuilds it")

        // Its block id is the one the table itself holds in the full document, so the reading cursor
        // sees the same number of stops before and after the splice.
        let fullTableId = full.attribute(MDAttr.blockId,
                                         at: (full.string as NSString).range(of: "r0c0").location,
                                         effectiveRange: nil) as? Int
        let standInId = deferred.attribute(MDAttr.blockId, at: range.location, effectiveRange: nil) as? Int
        XCTAssertEqual(standInId, fullTableId)

        // And the blocks AROUND it keep their own ids — a stand-in must not renumber the document.
        let ns = deferred.string as NSString
        XCTAssertEqual(deferred.attribute(MDAttr.blockId, at: ns.range(of: "before").location,
                                          effectiveRange: nil) as? Int,
                       full.attribute(MDAttr.blockId, at: (full.string as NSString).range(of: "before").location,
                                      effectiveRange: nil) as? Int)
    }

    func testTheStandInCarriesNoGridAtAll() {
        let deferred = OfficeTextBuilder.build([table(rows: 60, cols: 10)], theme: theme,
                                               columnWidth: 700, tableWidth: 690, deferringTables: [0])
        var sawTable = false
        deferred.enumerateAttribute(.paragraphStyle,
                                    in: NSRange(location: 0, length: deferred.length)) { v, _, _ in
            if let p = v as? NSParagraphStyle, !p.textBlocks.isEmpty { sawTable = true }
        }
        XCTAssertFalse(sawTable, "a deferred table must cost NO NSTextTableBlock — that is the freeze")
        XCTAssertFalse(deferred.string.contains("r0c0"), "and none of its text is laid out yet")
    }

    // MARK: - The splice puts back exactly what was left out

    /// The whole contract in one assertion: build the document deferred, replace each stand-in with
    /// a one-block build of the table it stood for, and the result must equal the document that was
    /// never deferred at all — same text, same attributes, same block ids.
    func testSplicingBackYieldsTheIdenticalDocument() throws {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [Span(text: "Annex")]),
            .paragraph(spans: [Span(text: "before")]),
            table(rows: 55, cols: 10),
            .paragraph(spans: [Span(text: "between")]),
            table(rows: 70, cols: 8),
            .paragraph(spans: [Span(text: "after")]),
        ]
        let colW: CGFloat = 700, tableW: CGFloat = 690
        let giants = OfficeTextBuilder.giantTableIndices(blocks)
        XCTAssertEqual(giants, [2, 4])

        let full = OfficeTextBuilder.build(blocks, theme: theme, columnWidth: colW, tableWidth: tableW)
        let spliced = NSMutableAttributedString(attributedString:
            OfficeTextBuilder.build(blocks, theme: theme, columnWidth: colW, tableWidth: tableW,
                                    deferringTables: giants))

        // Exactly what `MarkdownDocument.spliceDeferredTables` does, one stand-in at a time.
        while true {
            var found: (NSRange, Int)?
            spliced.enumerateAttribute(MDAttr.deferredTable,
                                       in: NSRange(location: 0, length: spliced.length)) { v, r, stop in
                if let i = v as? Int { found = (r, i); stop.pointee = true }
            }
            guard let (range, index) = found else { break }
            // Same bounds check the real pass makes. Without it a broken index takes the whole
            // process down with `Index out of range`, and a crash hides every other result in the
            // run — which is how a mutation check stops being able to tell you anything.
            guard index < blocks.count else { return XCTFail("stand-in named block \(index)") }
            let piece = NSMutableAttributedString(attributedString:
                OfficeTextBuilder.build([blocks[index]], theme: theme, columnWidth: colW, tableWidth: tableW))
            if let id = spliced.attribute(MDAttr.blockId, at: range.location, effectiveRange: nil) {
                piece.addAttribute(MDAttr.blockId, value: id, range: NSRange(location: 0, length: piece.length))
            }
            spliced.replaceCharacters(in: range, with: piece)
        }

        assertStructurallyIdentical(spliced, full,
                                    "a deferral is a schedule, not a different document")
    }

    /// A one-block build numbers its block from zero, so without the id rebase two neighbours would
    /// share id 0 and merge into ONE stop for the reading cursor (invariant 19's lesson). This test
    /// pins the rebase by showing the raw piece really does start at zero.
    func testAOneBlockBuildNumbersFromZeroWhichIsWhyTheIdIsRebased() {
        let piece = OfficeTextBuilder.build([table(rows: 55, cols: 10)], theme: theme,
                                            columnWidth: 700, tableWidth: 690)
        let firstId = piece.attribute(MDAttr.blockId,
                                      at: (piece.string as NSString).range(of: "r0c0").location,
                                      effectiveRange: nil) as? Int
        XCTAssertEqual(firstId, 0)
    }

    // MARK: - Invariant 29: the builder being right does not mean the app REACHES it

    private static func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("docs/fixtures/office is gitignored; regenerate with "
                          + "Scripts/make-giant-table-fixture.py")
        }
        return url
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func standInCount(_ s: NSAttributedString) -> Int {
        var n = 0
        s.enumerateAttribute(MDAttr.deferredTable, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if v is Int { n += 1 }
        }
        return n
    }

    /// The whole feature, through `MarkdownDocument`'s own read → render → window pipeline — the path
    /// a double-click takes — rather than through a string this test built for itself. A unit test on
    /// the builder cannot tell you the builder is reached: `.odt` once shipped registered, parsed and
    /// covered by 24 passing tests while being impossible to open at all (invariant 29).
    ///
    /// Three claims in order: the document really does paint WITHOUT the grid, the splice really does
    /// put it back on its own with nobody driving it, and what it puts back is exactly the document
    /// that was never deferred.
    func testTheRealRenderPathDefersTheGridAndThenSplicesItBack() throws {
        let url = try Self.fixture("giant-table.odt")
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "org.oasis-open.opendocument.text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        let storage = try XCTUnwrap(wc.textStorageRef)

        // 1. It painted, and the grid is NOT in what it painted.
        XCTAssertEqual(doc.deferredTables, [2], "the real path must decide to defer this table")
        XCTAssertEqual(standInCount(storage), 1)
        XCTAssertFalse(storage.string.contains("r999c7"),
                       "the first paint must not contain the grid — building it is the freeze")
        XCTAssertTrue(storage.string.contains("before the giant"),
                      "…while everything around it is there from the start")
        let deferredLength = storage.length

        // 2. Nothing here drives it: the pass runs itself off the render's own completion.
        for _ in 0..<200 where !doc.deferredTables.isEmpty { spin(0.02) }
        XCTAssertTrue(doc.deferredTables.isEmpty, "the splice pass must complete on its own")
        XCTAssertEqual(standInCount(storage), 0, "and leave no stand-in behind")
        XCTAssertGreaterThan(storage.length, deferredLength * 5,
                             "the grid really did arrive — this document is mostly table")

        // 3. What arrived is the document that was never deferred, cell for cell and attribute for
        //    attribute, at the same column the render solved at. Both sides are compared as INSTALLED
        //    storages (see `assertFingerprintsMatch`) so AppKit's own fixups cancel out.
        let splicedText = storage.string
        let splicedPrint = fingerprint(storage)
        // And the block ids stay unique per block — two neighbours sharing one would merge into a
        // single stop for the reading cursor (invariant 19).
        var ids: [Int] = []
        storage.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let i = v as? Int, ids.last != i { ids.append(i) }
        }
        XCTAssertEqual(ids, Array(Set(ids)).sorted(), "block ids must stay unique and in order")

        let colW = wc.textView.textContainer?.size.width ?? 800
        let pad = wc.textView.textContainer?.lineFragmentPadding ?? 5
        let undeferred = OfficeTextBuilder.build(doc.officeBlocks,
                                                 theme: RenderTheme.current(size: doc.readingSize),
                                                 columnWidth: colW,
                                                 documentDefaultFontSize: doc.officeDefaultBodyFontSize,
                                                 pageContentWidth: doc.officePageContentWidth,
                                                 tableWidth: max(1, colW - 2 * pad),
                                                 comments: doc.officeComments)
        wc.display(undeferred)
        let reference = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(splicedText, reference.string, "the spliced document must be the same TEXT")
        assertFingerprintsMatch(splicedPrint, fingerprint(reference),
                                "the spliced document must equal the one that never deferred")
    }

    /// THE TEST THAT WAS MISSING, and whose absence shipped a hang. The deferral originally left
    /// the giant tables unlaid on purpose, having measured that TextKit settles them in the
    /// background without a visible slice — true, and irrelevant the moment the reader SCROLLS.
    /// Arrival forces every unlaid character in between at once: 69,460 and 80,008 ms on the real
    /// report, measured twice. Walking the document after the splice makes the same scroll 3.2 ms.
    ///
    /// JUDGED BY `layoutStepCount`, NOT BY THE STOPWATCH — invariant 49's rule, and the reason this
    /// version is trustworthy where the first was not. That one asserted "ends up laid out" and
    /// "scrolling is quick" after spinning the run loop for eight seconds, and PASSED WITH THE FIX
    /// REMOVED: given that much idle time TextKit finishes a small document by itself. A real reader
    /// gets no such grace. `precomputeLayout` resets this counter and bumps it once per
    /// 20,000-character chunk, so it records WHICH document was last walked — the full one, or only
    /// the deferred string that is a fraction of its length.
    func testScrollingToTheSplicedTableIsNotAStall() throws {
        let url = try Self.fixture("giant-table.odt")
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "org.oasis-open.opendocument.text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 800), display: false)
        for _ in 0..<300 where !doc.deferredTables.isEmpty { spin(0.02) }
        XCTAssertTrue(doc.deferredTables.isEmpty, "precondition: the grid is back")
        let storage = try XCTUnwrap(wc.textStorageRef)
        let lm = try XCTUnwrap(wc.textView.layoutManager)

        var lastSteps = -1, stable = 0
        for _ in 0..<400 {
            spin(0.02)
            if wc.layoutStepCount == lastSteps { stable += 1 } else { stable = 0; lastSteps = wc.layoutStepCount }
            if stable > 15 && lm.firstUnlaidCharacterIndex() >= storage.length { break }
        }
        let chunk = 20_000
        let neededSteps = (storage.length + chunk - 1) / chunk
        XCTAssertGreaterThanOrEqual(wc.layoutStepCount, neededSteps,
                                    "the walk after the splice covered \(wc.layoutStepCount) chunks, "
                                    + "but the full \(storage.length)-character document needs "
                                    + "\(neededSteps) — the last walk was over the DEFERRED string, "
                                    + "which is the shipped bug")
        XCTAssertGreaterThanOrEqual(lm.firstUnlaidCharacterIndex(), storage.length,
                                    "and the document really is laid out end to end")

        for fraction in [0.95, 0.5, 0.2] {
            let target = min(storage.length - 1, Int(Double(storage.length) * fraction))
            let t = Date()
            wc.textView.scrollRangeToVisible(NSRange(location: target, length: 1))
            let elapsed = Date().timeIntervalSince(t) * 1000
            XCTAssertLessThan(elapsed, 250,
                              "scrolling to \(Int(fraction * 100))% took \(Int(elapsed)) ms")
        }
    }

    // NOT TESTED HERE, DELIBERATELY — two properties this unit depends on have no honest test in
    // this harness, and three attempts at each produced tests that passed with the fix REMOVED:
    //
    //   • "a RE-render never defers" (`hasPaintedOnce`). Its signature is the storage briefly
    //     shrinking, and on any fixture small enough to ship that window is under one run-loop turn,
    //     so sampling cannot see it. It is observable only on a document of the size the repo cannot
    //     ship (401,765 characters), where the splice takes ~2 s.
    //   • "restore works before anything is laid out" (the glyph-first fix in
    //     `DocumentWindowController.restore`). Reproducing the not-yet-laid-out state is what fails:
    //     `display` itself lays enough out that the old pre-guard passes anyway.
    //
    // Both were verified by MEASUREMENT instead — see invariant 56 — and both regress loudly on the
    // real document. Do not add a test here that merely goes green; check it against a mutation
    // first (invariant 30), and if it cannot fail, leave this comment rather than the test.

    /// The seam the splice hangs off: the completion fires when the walk finishes, and NOT when a
    /// later render supersedes it — otherwise a superseded pass would splice into a document that no
    /// longer exists.
    func testPrecomputeLayoutCompletionFiresOnceAndNotWhenSuperseded() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/does-not-matter.md")
        try doc.read(from: Data("# Title\n\nbody\n".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)

        // Let the OPEN's own render settle first. Its async tail runs `precomputeLayout` too, and a
        // walk started before that lands would lose the token to it and never report — the race is
        // real, and this test found it by failing.
        for _ in 0..<20 { spin(0.02) }

        var finished = 0
        wc.precomputeLayout { finished += 1 }
        for _ in 0..<100 where finished == 0 { spin(0.02) }
        XCTAssertEqual(finished, 1, "a walk that reaches the end reports it, exactly once")

        var superseded = 0
        wc.precomputeLayout { superseded += 1 }
        wc.precomputeLayout { }              // a second render's walk takes the token
        for _ in 0..<20 { spin(0.02) }
        XCTAssertEqual(superseded, 0, "the walk that lost its token must not report a finish")
    }

    // MARK: - `--extract` cannot see this (invariant 40)

    /// The serializer walks `[OfficeBlock]`, never the rendered string, so deferral is structurally
    /// invisible to it. Asserted rather than assumed, because "structurally impossible" is exactly
    /// the kind of claim invariant 29 was earned by getting wrong.
    func testHeadlessExtractIsUnaffectedByTheDeferralLine() {
        let blocks: [OfficeBlock] = [
            .paragraph(spans: [Span(text: "before")]),
            table(rows: 60, cols: 10),
        ]
        XCTAssertEqual(OfficeTextBuilder.giantTableIndices(blocks), [1], "precondition: this defers")
        let md = OfficeMarkdownSerializer.serialize(blocks)
        XCTAssertTrue(md.contains("r0c0"), "--extract must still hold every cell")
        XCTAssertTrue(md.contains("r59c9"))
        XCTAssertFalse(md.contains(OfficeTextBuilder.deferredTableStandIn),
                       "and must never carry the stand-in")
    }
}

/// What deferring the giant grids is WORTH, on a real document, measured rather than argued.
///
/// Kept as a permanently-skipped probe (the convention every other instrument here follows) so the
/// finding never has to be re-derived and a future change that erodes it is visible. Both arms are
/// built and displayed BACK TO BACK IN ONE PROCESS and interleaved across repeats: wall clock on
/// this machine swings up to 11x with load, so only the RATIO between arms survives, and the load
/// average is printed with every run so a number can be read in context.
///
/// Established on `…시장구조조사.hwp` (401,765 rendered characters, 129 tables, 51,816 cells,
/// five qualifying tables at 85x8, 481x8, 481x8, 2195x8, 2196x8) — see
/// `docs/giant-table-deferral-design.md`:
///   • first paint (build + display, ONE uninterruptible turn) 3,329 ms → 664 ms, 5x
///   • the work is MOVED, not saved: 418 + 1,912 ms of payback ≈ one full build, within 1%
///   • the payback must NOT force layout — forcing it costs a 211 ms freeze with two slices over
///     200 ms, while leaving it to TextKit settles in ~7.5 s with a worst slice of 45 ms
final class GiantTableDeferralLatencyProbe: XCTestCase {
    private func ms(_ s: Date) -> Double { Date().timeIntervalSince(s) * 1000 }
    private func loadAvg() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }

    func testFirstPaintCostWithAndWithoutTheGiantGrids() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_GIANT_TABLE_LATENCY"] else {
            throw XCTSkip("set FMD_GIANT_TABLE_LATENCY to a real office document to measure this")
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let uti = (ext == "odt") ? "org.oasis-open.opendocument.text"
            : (ext == "hwp" || ext == "hwpx") ? "com.hancom.hwp"
            : "org.openxmlformats.wordprocessingml.document"
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(contentsOf: url), ofType: uti)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 900), display: false)
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let giants = OfficeTextBuilder.giantTableIndices(doc.officeBlocks)
        let theme = RenderTheme.current(size: doc.readingSize)
        let colW = wc.textView.textContainer?.size.width ?? 800
        let pad = wc.textView.textContainer?.lineFragmentPadding ?? 5
        print("  document: \(doc.officeBlocks.count) blocks · qualifying tables \(giants.count) "
              + "\(giants.sorted()) · load \(String(format: "%.1f", loadAvg()))")

        func arm(_ label: String, _ deferring: Set<Int>) {
            let t = Date()
            let s = OfficeTextBuilder.build(doc.officeBlocks, theme: theme, columnWidth: colW,
                                            documentDefaultFontSize: doc.officeDefaultBodyFontSize,
                                            pageContentWidth: doc.officePageContentWidth,
                                            tableWidth: max(1, colW - 2 * pad),
                                            comments: doc.officeComments,
                                            deferringTables: deferring)
            let build = ms(t)
            let t2 = Date()
            wc.display(s)
            let display = ms(t2)
            print(String(format: "  [%-8s] build %8.1f + display %8.1f = FIRST PAINT %8.1f ms · chars %d",
                         (label as NSString).utf8String!, build, display, build + display, s.length))
        }

        for rep in 0..<3 {
            print("  --- repeat \(rep) · load \(String(format: "%.1f", loadAvg())) ---")
            arm("full", [])           // what ships without this feature
            arm("deferred", giants)   // what ships with it
        }

        // And what the payback costs, built one table at a time exactly as the splice pass does.
        var payback = 0.0
        for i in giants.sorted() {
            let t = Date()
            _ = OfficeTextBuilder.build([doc.officeBlocks[i]], theme: theme, columnWidth: colW,
                                        documentDefaultFontSize: doc.officeDefaultBodyFontSize,
                                        pageContentWidth: doc.officePageContentWidth,
                                        tableWidth: max(1, colW - 2 * pad),
                                        comments: doc.officeComments)
            let d = ms(t)
            payback += d
            print(String(format: "  payback build for block %d: %8.1f ms", i, d))
        }
        print(String(format: "  payback total %8.1f ms — spread one per run-loop turn, never in one turn",
                     payback))
    }
}
