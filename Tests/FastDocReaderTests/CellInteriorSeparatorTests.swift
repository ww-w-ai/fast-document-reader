import XCTest
import AppKit
@testable import FastDocReader

/// A multi-paragraph table cell must not pay a separate attribute run for each `"\n"` between its
/// blocks — invariant 51, one layer up.
///
/// `TableBlockBuilder` merged the newline that ends a whole CELL. What it explicitly left behind, and
/// named in its own closing sentence, is `OfficeTextBuilder.cellContent`'s INTERIOR separator: the
/// newline joined between two blocks of a multi-paragraph cell, appended carrying the CELL's base
/// font and no colour while the text either side carries its own resolved font and an `NSColor`. Two
/// runs where one would do, and an attribute run is what installing a string into a live text view is
/// priced by (~50 µs each, measured indifferent to what the run contains).
///
/// Measured through `OfficeTextBuilder.build` at a 700pt column, before → after, load 5–6:
///   • 2025 행정업무운영 편람.hwp   15,308 → 12,760 runs (−16.6%); interior separators 2,323 → 374
///   • 2017년기준 시장구조조사.hwp  56,560 → 56,245 runs (−0.6%);  interior separators   271 →   7
///   • bus-headings.docx 797 → 676 · bus-headings.odt 795 → 650 · tago-tables.odt 951 → 776
/// The reference gains and the report barely does — the REVERSE of invariant 51 — because the
/// reference is the document with multi-paragraph cells and the report's cells hold one paragraph
/// each. Laid-out height is IDENTICAL to five decimal places on both (428736.31199 pt and
/// 304483.36649 pt), which `testTheLaidOutGeometryIsUnchanged` pins as an assertion.
///
/// Both totals fall by MORE than the separators they remove (−2,548 against −1,999 on the reference),
/// and that surplus is the second-order win `testAUniformMultiParagraphCellCollapsesToOneRun`
/// records: once a separator carries its paragraph's own attributes, a cell whose paragraphs are
/// identically styled coalesces end to end into ONE run, because `NSParagraphStyle` compares by value.
///
/// What is left is measured rather than assumed: 374 interior separators survive on the reference, of
/// which 268 terminate an EMPTY paragraph and can never merge (nothing to merge with — invariant 51's
/// empty-cell rule), leaving 106 that decline because the paragraph's own start carries something the
/// allow-list refuses. `InteriorSeparatorProbeTests` is the instrument for all of those figures.
final class CellInteriorSeparatorTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    /// One office table, built through the real `OfficeTextBuilder` path.
    private func table(_ cells: [[Cell]], headerRows: Int = 0, width: CGFloat = 600) -> NSAttributedString {
        OfficeTextBuilder.build([.table(rows: cells, headerRows: headerRows)], theme: theme, tableWidth: width)
    }

    private func runs(in attr: NSAttributedString) -> [(text: String, attrs: [NSAttributedString.Key: Any])] {
        var out: [(String, [NSAttributedString.Key: Any])] = []
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { a, r, _ in
            out.append(((attr.string as NSString).substring(with: r), a))
        }
        return out
    }

    /// Every newline INSIDE a table cell that is NOT merged into a content run — the number this whole
    /// unit is about. Counted per CHARACTER so two coalesced separators cannot hide behind their own
    /// coalescing, and restricted to newlines carrying an `NSTextTableBlock`: a table is closed by two
    /// ordinary newlines of its own (`TableBlockBuilder`'s and `appendTable`'s), which belong to no
    /// cell and are not this unit's business — counting those was the first version of this helper and
    /// it reported 2 phantom failures against a correct build.
    private func unmergedNewlines(in attr: NSAttributedString) -> Int {
        let ns = attr.string as NSString
        var n = 0
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { a, r, _ in
            guard (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock else { return }
            var newlines = 0, content = 0
            for i in r.location..<(r.location + r.length) {
                if ns.character(at: i) == 10 { newlines += 1 } else { content += 1 }
            }
            if content == 0 { n += newlines }
        }
        return n
    }

    private func para(_ text: String, bold: Bool = false, size: CGFloat? = nil) -> OfficeBlock {
        .paragraph(spans: [Span(text: text, bold: bold, fontSize: size)])
    }

    // MARK: the unit

    /// A two-paragraph cell whose paragraphs are styled DIFFERENTLY: each separator must still fold
    /// into the paragraph it terminates, so the cell costs one run per paragraph and none per newline.
    func testAnInteriorSeparatorMergesIntoTheParagraphItTerminates() {
        let cell = Cell(blocks: [para("첫 문단"), para("둘째 문단", bold: true), para("셋째 문단", size: 24)])
        let out = table([[cell]])
        XCTAssertEqual(unmergedNewlines(in: out), 0,
                       "no newline inside this cell may still be a run of its own — runs were "
                       + "\(runs(in: out).map(\.text.debugDescription))")
        // …and each separator is INSIDE its own paragraph's run, not the next one's.
        let ns = out.string as NSString
        for marker in ["첫 문단", "둘째 문단"] {
            let run = runs(in: out).first { $0.text.hasPrefix(marker) }
            XCTAssertNotNil(run, "\(marker) must be a run")
            XCTAssertTrue(run?.text.hasSuffix("\n") == true,
                          "\(marker)'s separator must terminate ITS run — got \(run?.text.debugDescription ?? "nil")")
        }
        XCTAssertTrue(ns.contains("셋째 문단"))
    }

    /// The surplus the totals show: identically-styled paragraphs COALESCE ACROSS their separators
    /// once each separator carries its own paragraph's attributes, because `NSParagraphStyle` compares
    /// by VALUE and equal attribute dictionaries merge. That is why the reference lost 2,548 runs
    /// while removing only 1,999 separators — the surplus is whole cells collapsing.
    ///
    /// It is a collapse to TWO runs, not one, and the reason is the pre-existing trim this pass has
    /// always done: the LAST paragraph of a cell gets `paragraphSpacing = 0` so the cell does not grow
    /// by a trailing paragraph gap, which makes its style genuinely different from its siblings'. The
    /// first paragraph's `paragraphSpacingBefore = 0` trim is invisible here only because these blocks
    /// declare no spacing to begin with. Recording the real number rather than the tidy one: pinning
    /// this at 1 was the first version of this test and it was simply wrong about the code.
    func testAUniformMultiParagraphCellCoalescesAcrossItsSeparators() {
        let cell = Cell(blocks: [para("가"), para("나"), para("다"), para("라")])
        let out = table([[cell]])
        let cellRuns = runs(in: out).filter { $0.text.contains("가") || $0.text.contains("나")
            || $0.text.contains("다") || $0.text.contains("라") }
        XCTAssertEqual(cellRuns.map(\.text), ["가\n나\n다\n", "라\n"],
                       "the first three paragraphs must coalesce into ONE run and the last stay its own "
                       + "(its trailing spacing is trimmed) — got \(cellRuns.map(\.text.debugDescription))")
        XCTAssertEqual(unmergedNewlines(in: out), 0, "and no separator is left as a run of its own")
    }

    /// The allow-list, from the drawing side. A paragraph ending in a picture, a highlight, a
    /// hyperlink or an underline must leave its separator EXACTLY as it was — an attachment's or a
    /// rule's attributes describe a glyph, not a paragraph, and a separator carrying a link would be
    /// clickable past the last glyph. Same posture and the same single list invariant 51 established.
    func testASeparatorNeverInheritsAnythingThatDrawsOrIsClicked() {
        let cases: [(String, OfficeBlock)] = [
            ("highlight", .paragraph(spans: [Span(text: "형광", highlightColor: .systemYellow)])),
            ("underline", .paragraph(spans: [Span(text: "밑줄", underline: true)])),
            ("strikethrough", .paragraph(spans: [Span(text: "취소", strikethrough: true)])),
            ("link", .paragraph(spans: [Span(text: "링크", link: "https://example.com")])),
        ]
        for (name, first) in cases {
            let out = table([[Cell(blocks: [first, para("뒤 문단")])]])
            let ns = out.string as NSString
            let sep = ns.range(of: "\n").location
            XCTAssertNotEqual(sep, NSNotFound, "\(name): the cell must have a separator")
            let attrs = out.attributes(at: sep, effectiveRange: nil)
            XCTAssertNil(attrs[.backgroundColor], "\(name): a separator must not carry a highlight")
            XCTAssertNil(attrs[.underlineStyle], "\(name): nor a rule that trails past the last glyph")
            XCTAssertNil(attrs[.strikethroughStyle], "\(name): nor a strikethrough")
            XCTAssertNil(attrs[.link], "\(name): nor a link that would be clickable past the last glyph")
            XCTAssertNil(attrs[.attachment], "\(name): nor an attachment")
        }
    }

    /// A cell whose first block is a PICTURE: the separator after it must never carry the attachment,
    /// so every media pass (`reconcileMedia`, `resizeOfficeGraphics`, `presizeKnownMedia`) keeps
    /// seeing exactly ONE run per picture rather than two sharing an attachment object.
    ///
    /// BOTH alignments are here because mutation showed the first version of this test had an
    /// unreachable subject (invariant 30). An UNALIGNED picture carries no `.paragraphStyle` at all,
    /// so the paragraph loop's own `guard let base` skips it before the allow-list is ever consulted —
    /// deleting the allow-list entirely leaves that case passing. A CENTRED picture does carry one
    /// (`applyGraphicAlignment`), reaches the allow-list, and is refused there; that case is what
    /// actually fails when the allow-list is removed, and it is why this test is worth having.
    func testASeparatorAfterAPictureKeepsTheBareNewline() {
        for alignment in [nil, NSTextAlignment.center] as [NSTextAlignment?] {
            let cell = Cell(blocks: [.image(id: "img1", size: NSSize(width: 40, height: 40), alignment: alignment),
                                     para("캡션")])
            let out = table([[cell]])
            let ns = out.string as NSString
            let sep = ns.range(of: "\n").location
            XCTAssertNotEqual(sep, NSNotFound)
            let what = alignment == nil ? "unaligned" : "centred"
            XCTAssertNil(out.attribute(.attachment, at: sep, effectiveRange: nil),
                         "\(what): the picture's attachment must not ride along on the separator")
            XCTAssertNil(out.attribute(MDAttr.image, at: sep, effectiveRange: nil),
                         "\(what): …nor its image id, which every media pass walks")
            XCTAssertNil(out.attribute(MDAttr.officeGraphic, at: sep, effectiveRange: nil),
                         "\(what): …nor the authored size `resizeOfficeGraphics` re-solves from")
        }
    }

    /// An EMPTY block between two others has no attributes of its own, so its separator stays bare —
    /// invariant 51's empty-cell rule, one layer up. This is the irreducible residue: 268 of the 374
    /// interior separators still on the reference manual are exactly this.
    func testAnEmptyParagraphKeepsItsBareSeparator() {
        let cell = Cell(blocks: [para("위"), .paragraph(spans: []), para("아래")])
        let out = table([[cell]])
        XCTAssertTrue((out.string as NSString).contains("위\n\n아래"),
                      "the empty paragraph must still occupy its own line")
        XCTAssertGreaterThan(unmergedNewlines(in: out), 0,
                             "an empty paragraph's separator cannot merge — there is nothing to merge with")
    }

    // MARK: what must not move

    /// Invariant 37: this buys runs and moves NO geometry. Compared against the same string with every
    /// interior separator stripped back to what it carried before — laid out through a real
    /// `NSLayoutManager` in a container 200pt wider than the table, so an overshoot cannot be clipped
    /// into looking exact (invariant 50's trap).
    ///
    /// Swept across four font sizes × three line-height multiples with paragraph spacing on, because
    /// line height and paragraph spacing inside a multi-paragraph cell are the exact thing the
    /// paragraph-style half of this pass exists to protect — this change works next to that live wire.
    ///
    /// Being as honest about this harness as invariant 51 was about its own: it is a PAIRED
    /// comparison, so the only thing it can detect is a terminator ATTRIBUTE — and mutation says
    /// nothing put there moves it. Stamping the FOLLOWING paragraph's attributes instead of the
    /// paragraph's own leaves this test green (the merge tests are what kill that, printing
    /// `"\n둘째 문단"` — a separator visibly attached to the wrong side); so does deleting the
    /// trailing-spacing trim, because that moves BOTH arms equally. So this test cannot fail on a
    /// terminator attribute, and saying so is the point of it: the reason it is safe to inherit is
    /// invariant 51's three, unchanged here — TextKit resolves a paragraph's metrics at its START, a
    /// trailing newline contributes no glyph of its own, and AppKit builds an attachment glyph only
    /// for U+FFFC. What this test IS, is that claim written down as an executable assertion over a
    /// sweep, with the vacuity check below so it can never quietly compare a string with itself.
    ///
    /// The strong form of the same claim is the measurement, not this: both real HWPs lay out to the
    /// identical height before and after, from two separately built binaries — 428736.31199 pt on the
    /// report and 304483.36649 pt on the reference manual, five decimal places, unchanged.
    func testTheLaidOutGeometryIsUnchanged() {
        var strippedSomething = false
        for size in [8.0, 12.0, 16.0, 24.0] as [CGFloat] {
            for multiple in [1.0, 1.5, 2.5] as [CGFloat] {
                let format = ParagraphFormat(spacingBefore: 5, spacingAfter: 9,
                                             lineHeight: .multiple(multiple))
                func p(_ t: String) -> OfficeBlock {
                    .paragraph(spans: [Span(text: t, fontSize: size)], format: format)
                }
                let cells: [[Cell]] = [
                    [Cell(blocks: [p("셀 안의 첫 문단이 조금 길어서 줄바꿈이 일어난다"), p("둘째"), p("셋째 문단")]),
                     Cell(blocks: [p("옆 칸"), p("두 번째 줄")])],
                    [Cell(blocks: [p("아래")]), Cell(blocks: [])],
                ]
                let built = table(cells, headerRows: 1)
                let old = strippingInteriorSeparatorAttributes(built)
                if !old.isEqual(to: built) { strippedSomething = true }
                let new = laidOut(built), was = laidOut(old)
                XCTAssertEqual(new.height, was.height, accuracy: 0.00001,
                               "font \(size) × lineHeight \(multiple): a separator's attributes must not move the height")
                XCTAssertEqual(new.width, was.width, accuracy: 0.00001,
                               "font \(size) × lineHeight \(multiple): nor the width")
            }
        }
        XCTAssertTrue(strippedSomething,
                      "the comparison must have a subject — if stripping changed nothing this test was "
                      + "laying out the same string twice and proving nothing")
    }

    /// Invariant 48: re-solving the columns at the width the table was BUILT at must still move zero
    /// cells. A uniform multi-paragraph cell is now ONE paragraph-style run where it used to be five,
    /// and `resizeTables` walks `.paragraphStyle` runs — so the cell must still be found, and still
    /// not move.
    func testResizeTablesStillMovesNoCellAfterABuildAtTheSameWidth() {
        let cells: [[Cell]] = [
            [Cell(blocks: [para("가"), para("나"), para("다")]), Cell(blocks: [para("A"), para("B")])],
            [Cell(blocks: [para("긴 셀 내용이 들어간다")]), Cell(blocks: [])],
        ]
        let out = table(cells, headerRows: 1)
        let storage = NSTextStorage(attributedString: out)
        func widths() -> [CGFloat] {
            var out: [CGFloat] = []
            var seen = Set<ObjectIdentifier>()
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                guard let b = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                      seen.insert(ObjectIdentifier(b)).inserted else { return }
                out.append(b.contentWidth)
            }
            return out
        }
        let before = widths()
        XCTAssertEqual(before.count, 4, "four cells must still be visible to a paragraph-style walk")
        TableBlockBuilder.resizeTables(in: storage, toWidth: 600)
        XCTAssertEqual(widths(), before, "re-solving at the build width must move no cell")
    }

    /// Invariant 29, the strong form: a unit test on the builder cannot tell you the builder is
    /// REACHED. This drives a real office document through `MarkdownDocument`'s own read + render +
    /// window pipeline — the same path a double-click takes — and inspects the storage the text view
    /// is actually GIVEN, not a string this test built for itself. `tago-tables.odt` is the fixture
    /// because it is the one with multi-paragraph cells.
    ///
    /// Measured on that storage, before → after: 1,851 → 1,681 attribute runs (−9.2%), interior
    /// separators 91 → 0. The two categories this unit does NOT touch are unchanged, which is how the
    /// number is read as a gain rather than a reshuffle: 141 cell terminators and 3 empty-cell
    /// terminators both ways (invariant 51's territory — the render path's own reading size makes more
    /// cells decline its allow-list than a fixed-width build does, and that is true before this change
    /// as well). Reverting the source makes this assertion fail at 91, so its subject is live.
    func testTheRenderPathItselfProducesTheMergedSeparators() throws {
        let url = try Self.fixture("tago-tables.odt")
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "org.oasis-open.opendocument.text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertGreaterThan(storage.length, 0, "the document must actually have rendered")
        let d = InteriorSeparatorProbeTests.decompose(storage)
        XCTAssertEqual(d.interiorSeparators, 0,
                       "on the REAL render path, no separator inside a cell may be a run of its own")
        XCTAssertEqual(d.cellTerminators, 141,
                       "…and the categories this unit does not touch must not move either — a fall here "
                       + "would mean runs were reshuffled rather than removed")
        XCTAssertEqual(d.emptyCellTerminators, 3)
    }

    /// The same claim through the builder at a fixed width, where the count is comparable with the
    /// probe's own figures — the render path above solves at whatever column the window gives it.
    func testARealDocumentGoesThroughThisPathWithNoInteriorSeparatorLeft() throws {
        let attr = try InteriorSeparatorProbeTests.build(Self.fixture("tago-tables.odt"))
        let d = InteriorSeparatorProbeTests.decompose(attr)
        XCTAssertGreaterThan(d.totalRuns, 0)
        XCTAssertEqual(d.interiorSeparators, 0,
                       "this fixture's 91 interior separators must all have merged — got \(d.interiorSeparators)")
    }

    /// `docs/` is gitignored, so a fresh clone has no fixtures — skip rather than fail there.
    private static func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("docs/fixtures/office is gitignored and absent in this checkout")
        }
        return url
    }

    /// A MARKDOWN table goes through `TableBlockBuilder` rather than `cellContent`, so it must be
    /// UNCHANGED by this — checked rather than assumed, through the real `MarkdownRenderer.render`.
    func testAMarkdownTableIsUnaffected() {
        let md = """
        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let out = MarkdownRenderer.render(md, theme: theme)
        var cellRuns = 0
        let ns = out.string as NSString
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { a, r, _ in
            guard (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock else { return }
            if ns.substring(with: r).hasSuffix("\n") { cellRuns += 1 }
        }
        XCTAssertEqual(cellRuns, 4, "each markdown cell stays ONE run — invariant 51's gain, untouched here")
    }

    // MARK: helpers

    /// The OLD behaviour, reconstructed: every interior separator back to the cell base font plus the
    /// paragraph style it was already given. An interior separator is a newline INSIDE a table block
    /// with more of the same block following it.
    private func strippingInteriorSeparatorAttributes(_ attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        let ns = m.string as NSString
        func block(at i: Int) -> NSTextTableBlock? {
            guard i >= 0, i < m.length else { return nil }
            return (m.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.first as? NSTextTableBlock
        }
        for i in 0..<m.length where ns.character(at: i) == 10 {
            guard let mine = block(at: i), block(at: i - 1) === mine, block(at: i + 1) === mine,
                  let ps = m.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
            else { continue }
            m.setAttributes([.paragraphStyle: ps, .font: theme.bodyFont], range: NSRange(location: i, length: 1))
        }
        return m
    }

    private func laidOut(_ attr: NSAttributedString, width: CGFloat = 600) -> NSRect {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: width + 200, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc)
    }
}
