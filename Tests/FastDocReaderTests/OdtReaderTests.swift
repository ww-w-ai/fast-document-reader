import XCTest
@testable import FastDocReader

/// `OdtReader` is pure: build an `.odt`-shaped ZIP by hand (stored entries only), hand it to
/// `ZipArchive`, then `OdtReader.read`, and assert on the `[OfficeBlock]` that comes back. Same
/// shape as `DocxReaderTests` — no fixture files on disk, no view, no document.
final class OdtReaderTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func buildOdt(content: String, styles: String? = nil) -> Data {
        var entries: [(String, Data)] = [("content.xml", Data(content.utf8))]
        if let styles { entries.append(("styles.xml", Data(styles.utf8))) }
        return buildZip(entries)
    }

    private func buildZip(_ entries: [(name: String, content: Data)]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50)
            body += le16(20)
            body += le16(0)
            body += le16(0)
            body += le16(0) + le16(0)
            body += le32(0)
            body += le32(UInt32(content.count))
            body += le32(UInt32(content.count))
            body += le16(UInt16(nameBytes.count))
            body += le16(0)
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var centralDirectory = [UInt8]()
        for p in prepared {
            centralDirectory += le32(0x0201_4b50)
            centralDirectory += le16(20) + le16(20)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0) + le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
        }
        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)
        archive += le16(0) + le16(0)
        archive += le16(UInt16(entries.count))
        archive += le16(UInt16(entries.count))
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)
        return Data(archive)
    }

    /// Wraps a body fragment in the minimal `office:document-content` shell every real ODT carries,
    /// with automatic-styles injected so tests can declare list/text styles inline.
    private func doc(body: String, automaticStyles: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:automatic-styles>\(automaticStyles)</office:automatic-styles>
          <office:body><office:text>\(body)</office:text></office:body>
        </office:document-content>
        """
    }

    private func read(body: String, automaticStyles: String = "", styles: String? = nil) throws -> [OfficeBlock] {
        let zip = buildOdt(content: doc(body: body, automaticStyles: automaticStyles), styles: styles)
        let archive = try ZipArchive(data: zip)
        return try OdtReader.read(archive).blocks
    }

    /// Full result (not just blocks) so page-width parsing off `style:page-layout-properties` is assertable.
    private func readResult(body: String, automaticStyles: String = "", styles: String? = nil) throws -> OfficeReadResult {
        try OdtReader.read(try ZipArchive(data: buildOdt(content: doc(body: body, automaticStyles: automaticStyles), styles: styles)))
    }

    // MARK: page content width (style:page-layout-properties → fo:page-width − fo:margin-*, →pt)

    func testPageContentWidthFromContentPageLayout() throws {
        // 21cm page − 2cm each margin = 17cm body = 17·72/2.54 ≈ 481.9pt.
        let r = try readResult(body: "<text:p>x</text:p>", automaticStyles:
            "<style:page-layout style:name=\"pm1\"><style:page-layout-properties fo:page-width=\"21cm\" fo:margin-left=\"2cm\" fo:margin-right=\"2cm\"/></style:page-layout>")
        XCTAssertEqual(r.pageContentWidth ?? -1, 17.0 * 72 / 2.54, accuracy: 0.01)
    }

    func testPageContentWidthNilWhenNoPageLayout() throws {
        XCTAssertNil(try readResult(body: "<text:p>x</text:p>").pageContentWidth)
    }

    func testPageContentWidthFromStylesXmlPageLayout() throws {
        // ODF overwhelmingly keeps the page layout in styles.xml — the reader searches both styleRoots.
        let styles = "<office:document-styles><office:automatic-styles>"
            + "<style:page-layout style:name=\"pm1\"><style:page-layout-properties fo:page-width=\"20cm\" fo:margin-left=\"1cm\" fo:margin-right=\"1cm\"/></style:page-layout>"
            + "</office:automatic-styles></office:document-styles>"
        let r = try readResult(body: "<text:p>x</text:p>", styles: styles)
        XCTAssertEqual(r.pageContentWidth ?? -1, 18.0 * 72 / 2.54, accuracy: 0.01)
    }

    /// Matches `OdtReader.parseODFColor`'s own construction (`deviceRed:`, not `srgbRed:`) so a
    /// comparison against a reader-resolved colour isn't tripped up by a colour-space mismatch that
    /// has nothing to do with whether the RGB VALUES themselves are right.
    private func odfColor(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16)!
        return NSColor(deviceRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// A picture inherits the alignment of the paragraph it sits in (`fo:text-align`), resolved
    /// through the same style lookup the paragraph's own text uses — an image-only paragraph in
    /// LibreOffice is how a centred figure is written, and the frame itself says nothing about it.
    func testImageInheritsItsParagraphsAlignment() throws {
        let blocks = try read(
            body: """
            <text:p text:style-name="Centred"><draw:frame svg:width="1in" svg:height="1in">
            <draw:image xlink:href="Pictures/p.png"/></draw:frame></text:p>
            """,
            automaticStyles: """
            <style:style style:name="Centred" style:family="paragraph">
              <style:paragraph-properties fo:text-align="center"/>
            </style:style>
            """)
        guard case let .image(_, _, alignment) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected an image block, got \(blocks)")
        }
        XCTAssertEqual(alignment, .center)
    }

    /// A paragraph that states nothing leaves the picture unaligned — byte-identical to before.
    func testImageInAnUnalignedParagraphCarriesNoAlignment() throws {
        let blocks = try read(body: """
        <text:p><draw:frame svg:width="1in" svg:height="1in">
        <draw:image xlink:href="Pictures/p.png"/></draw:frame></text:p>
        """)
        guard case let .image(_, _, alignment) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected an image block, got \(blocks)")
        }
        XCTAssertNil(alignment)
    }

    private func readWithMedia(body: String, media: [(name: String, bytes: [UInt8])]) throws -> [OfficeBlock] {
        var entries: [(String, Data)] = [("content.xml", Data(doc(body: body).utf8))]
        for (name, bytes) in media { entries.append((name, Data(bytes))) }
        let archive = try ZipArchive(data: buildZip(entries))
        return try OdtReader.read(archive).blocks
    }

    // MARK: Headings

    func testOutlineLevelsOneThroughSixMapDirectlyToHeadingLevels() throws {
        let paragraphs = (1...6).map { "<text:h text:outline-level=\"\($0)\">H\($0)</text:h>" }
        let blocks = try read(body: paragraphs.joined())
        XCTAssertEqual(blocks, (1...6).map { .heading(level: $0, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelSevenAndAboveClampsToHeadingLevelSix() throws {
        let blocks = try read(body: "<text:h text:outline-level=\"9\">Deep</text:h>")
        XCTAssertEqual(blocks, [.heading(level: 6, spans: [Span(text: "Deep")])])
    }

    /// S3: a `text:p` whose OWN paragraph style declares `style:default-outline-level` is a heading
    /// too, even though it's a plain `text:p` element (Writer produces this shape). This is the ODT
    /// counterpart of docx's style-based mechanisms — needed so both formats agree on the same
    /// document (the sprint's cross-format-equality guard).
    func testParagraphStyleWithDefaultOutlineLevelIsAHeadingEvenThoughItsElementIsTextP() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"H2Style\">Styled Heading</text:p>",
            automaticStyles: """
            <style:style style:name="H2Style" style:family="paragraph" style:default-outline-level="2"/>
            """)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Styled Heading")])])
    }

    func testParagraphStyleWithNoDefaultOutlineLevelIsAnOrdinaryParagraph() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Body\">Plain</text:p>",
            automaticStyles: """
            <style:style style:name="Body" style:family="paragraph"/>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")])])
    }

    // MARK: Writing direction (RTL) — S12

    /// `style:writing-mode="rl-tb"` lives on the PARAGRAPH STYLE, not on `text:p` itself — this
    /// reader resolves it through the same `text:style-name` lookup `parseParagraphOutlineLevels`
    /// already uses for headings, in a parallel table (`parseParagraphWritingModes`).
    func testRTLParagraphStyleGetsRightToLeftBaseWritingDirection() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Arabic\">\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}</text:p>",
            automaticStyles: """
            <style:style style:name="Arabic" style:family="paragraph">
              <style:paragraph-properties style:writing-mode="rl-tb"/>
            </style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")], rtl: true)])
    }

    /// Every OTHER `style:writing-mode` value (never just "not rl-tb") reads as NOT right-to-left
    /// — `lr-tb` is Writer's own default value when the toggle is off, exercised explicitly rather
    /// than only via absence.
    func testLRTBWritingModeIsNotRTL() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Ltr\">Plain</text:p>",
            automaticStyles: """
            <style:style style:name="Ltr" style:family="paragraph">
              <style:paragraph-properties style:writing-mode="lr-tb"/>
            </style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")], rtl: false)])
    }

    /// ODF's docx-equivalent trap: `styles.xml` can declare the SAME style-family name a different,
    /// unrelated way — only a `style:family="paragraph"` style may ever answer this lookup (mirrors
    /// `parseTextStyles`'s own family filter).
    func testWritingModeOnANonParagraphFamilyStyleIsIgnored() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Arabic\">Plain</text:p>",
            automaticStyles: """
            <style:style style:name="Arabic" style:family="text">
              <style:paragraph-properties style:writing-mode="rl-tb"/>
            </style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")], rtl: false)])
    }

    /// `rl-tb` in `styles.xml` (the document-level styles part) must be found exactly like one in
    /// `content.xml`'s own `office:automatic-styles` — `parseParagraphWritingModes` is merged from
    /// BOTH parts, the same way `parseParagraphOutlineLevels`/`parseTextStyles` already are.
    func testRTLParagraphStyleDeclaredInStylesXMLIsAlsoHonoured() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Arabic\">\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}</text:p>",
            styles: """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-styles>
              <office:styles>
                <style:style style:name="Arabic" style:family="paragraph">
                  <style:paragraph-properties style:writing-mode="rl-tb"/>
                </style:style>
              </office:styles>
            </office:document-styles>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")], rtl: true)])
    }

    /// A heading (via `text:h`) and a list item (`text:list` > `text:list-item` > `text:p`) both
    /// resolve `style:writing-mode` through their OWN `text:style-name`, exactly like an ordinary
    /// paragraph — the same field, not re-derived per case (mirrors `DocxReader`'s equivalent test).
    func testRTLHeadingAndListItemAlsoGetRightToLeftBaseWritingDirection() throws {
        let headingBlocks = try read(
            body: "<text:h text:outline-level=\"1\" text:style-name=\"Arabic\">Title</text:h>",
            automaticStyles: """
            <style:style style:name="Arabic" style:family="paragraph">
              <style:paragraph-properties style:writing-mode="rl-tb"/>
            </style:style>
            """)
        XCTAssertEqual(headingBlocks, [.heading(level: 1, spans: [Span(text: "Title")], rtl: true)])

        let listBlocks = try read(
            body: """
            <text:list>
              <text:list-item><text:p text:style-name="Arabic">Item</text:p></text:list-item>
            </text:list>
            """,
            automaticStyles: """
            <style:style style:name="Arabic" style:family="paragraph">
              <style:paragraph-properties style:writing-mode="rl-tb"/>
            </style:style>
            """)
        XCTAssertEqual(listBlocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")], rtl: true)])
    }

    /// ODT's run-level markup (`text:span`) carries no writing-direction signal of its own — unlike
    /// docx's `w:rPr/w:rtl` — so `Span.rtl` must stay `false` even when the enclosing paragraph is
    /// explicitly RTL. Documents the format asymmetry `OfficeBlock.swift`'s `Span.rtl` doc comment
    /// states, rather than leaving it merely implied.
    func testOdtRunsNeverCarryRunLevelRTLEvenInsideAnRTLParagraph() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Arabic\"><text:span text:style-name=\"B\">bold</text:span> plain</text:p>",
            automaticStyles: """
            <style:style style:name="Arabic" style:family="paragraph">
              <style:paragraph-properties style:writing-mode="rl-tb"/>
            </style:style>
            <style:style style:name="B" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
            """)
        guard case .paragraph(let spans, let rtl, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertTrue(rtl)
        XCTAssertTrue(spans.allSatisfy { !$0.rtl })
    }

    /// The regression guard: a document with no `style:writing-mode` anywhere parses with `rtl`
    /// `false` on every block, exactly as before this sprint.
    func testDocumentWithNoWritingModeMarkupProducesRtlFalseEverywhere() throws {
        let blocks = try read(body: "<text:p>Ordinary</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Ordinary")])])
        guard case .paragraph(_, let rtl, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertFalse(rtl)
    }

    // MARK: Paragraphs + span reassembly with mixed content ordering

    func testPlainParagraphIsText() throws {
        let blocks = try read(body: "<text:p>Hello, world.</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Hello, world.")])])
    }

    func testConsecutiveSpansWithIdenticalStylingReassembleAcrossBareTextInterleaving() throws {
        let blocks = try read(
            body: """
            <text:p>before <text:span text:style-name="B">bold </text:span><text:span text:style-name="B">still bold</text:span> after</text:p>
            """,
            automaticStyles: """
            <style:style style:name="B" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "before "),
            Span(text: "bold still bold", bold: true),
            Span(text: " after"),
        ])])
    }

    // MARK: Unit conversion

    func testUnitConversionsMatchMeasuredRealFileValues() throws {
        let cases: [(width: String, expectedPt: CGFloat)] = [
            ("7.938cm", 225.0), ("5.292cm", 150.0), ("1in", 72), ("72pt", 72), ("100", 100),
        ]
        for (index, testCase) in cases.enumerated() {
            let blocks = try readWithMedia(
                body: """
                <text:p><draw:frame svg:width="\(testCase.width)" svg:height="\(testCase.width)">
                <draw:image xlink:href="Pictures/img\(index).png"/></draw:frame></text:p>
                """,
                media: [(name: "Pictures/img\(index).png", bytes: [0x01])])
            guard case .image(_, let size, _) = blocks.first else { return XCTFail("expected an image block") }
            XCTAssertEqual(size.width, testCase.expectedPt, accuracy: 0.02, "width '\(testCase.width)'")
        }
    }

    // MARK: Images

    func testEmbeddedImageResolvesToArchiveEntryNameAndDeclaredSize() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p><draw:frame svg:width="225pt" svg:height="168.75pt">
            <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
            """,
            media: [(name: "Pictures/photo.png", bytes: [0x01, 0x02])])
        XCTAssertEqual(blocks, [.image(id: "Pictures/photo.png", size: CGSize(width: 225, height: 168.75))])
    }

    func testHrefNotPresentInArchiveEmitsUnresolvableSizedImageNeverZeroOrDropped() throws {
        let blocks = try read(body: """
        <text:p><draw:frame svg:width="100pt" svg:height="50pt">
        <draw:image xlink:href="Pictures/missing.png"/></draw:frame></text:p>
        """)
        XCTAssertEqual(blocks, [.image(id: "odt-unresolvable:Pictures/missing.png", size: CGSize(width: 100, height: 50))])
    }

    func testFrameWithNoDeclaredSizeFallsBackToNonZeroPlaceholder() throws {
        let blocks = try read(body: """
        <text:p><draw:frame><draw:image xlink:href="Pictures/missing.png"/></draw:frame></text:p>
        """)
        guard case .image(_, let size, _) = blocks.first else { return XCTFail("expected an image block") }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testImageOnlyParagraphEmitsNoPhantomEmptyTextBlock() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p><draw:frame svg:width="72pt" svg:height="72pt">
            <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
            """,
            media: [(name: "Pictures/photo.png", bytes: [0x01])])
        XCTAssertEqual(blocks, [.image(id: "Pictures/photo.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: Tables

    func testTwoByTwoTableWithAnEmptyCellKeepsShape() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell><text:p>H1</text:p></table:table-cell>
            <table:table-cell><text:p>H2</text:p></table:table-cell>
          </table:table-row>
          <table:table-row>
            <table:table-cell><text:p>A1</text:p></table:table-cell>
            <table:table-cell><text:p/></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "H1")]), Cell(spans: [Span(text: "H2")])],
            // A cell whose only content is an empty `<text:p/>` is truly empty —
            // `Cell(blocks: [])`, no phantom `.paragraph(spans: [])` (see `collectCellBlocks`).
            [Cell(spans: [Span(text: "A1")]), Cell(blocks: [])],
        ], headerRows: 0)])
    }

    func testNoTableHeaderRowsWrapperReportsZeroHeaderRows() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row><table:table-cell><text:p>A</text:p></table:table-cell></table:table-row>
        </table:table>
        """)
        guard case .table(_, let headerRows, _, _) = blocks.first else { return XCTFail("expected a table block") }
        XCTAssertEqual(headerRows, 0)
    }

    func testTableHeaderRowsWrapperReportsItsRowCount() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-header-rows>
            <table:table-row><table:table-cell><text:p>H1</text:p></table:table-cell></table:table-row>
          </table:table-header-rows>
          <table:table-row><table:table-cell><text:p>A1</text:p></table:table-cell></table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "H1")])],
            [Cell(spans: [Span(text: "A1")])],
        ], headerRows: 1)])
    }

    func testNumberColumnsRepeatedExpandsToThatManyColumns() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-columns-repeated="3"><text:p>X</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "X")]), Cell(spans: [Span(text: "X")]), Cell(spans: [Span(text: "X")])],
        ], headerRows: 0)])
    }

    // MARK: Merged cells — ODF's covered-table-cell convention (the opposite of docx's vMerge)

    func testHorizontalMergeCollapsesCoveredCellAndCarriesColSpan() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-columns-spanned="2"><text:p>Wide</text:p></table:table-cell>
            <table:covered-table-cell/>
            <table:table-cell><text:p>C3</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Wide")], rowSpan: 1, colSpan: 2), Cell(spans: [Span(text: "C3")])],
        ], headerRows: 0)])
    }

    func testVerticalMergeCollapsesCoveredCellInSubsequentRowAndCarriesRowSpan() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-rows-spanned="2"><text:p>Tall</text:p></table:table-cell>
            <table:table-cell><text:p>B1</text:p></table:table-cell>
          </table:table-row>
          <table:table-row>
            <table:covered-table-cell/>
            <table:table-cell><text:p>B2</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Tall")], rowSpan: 2, colSpan: 1), Cell(spans: [Span(text: "B1")])],
            [Cell(spans: [Span(text: "B2")])],
        ], headerRows: 0)])
    }

    /// A rowSpan that claims MORE rows than the table's SOURCE actually has must not crash
    /// `OfficeTextBuilder.build` downstream. `OdtReader` reads `table:number-rows-spanned` VERBATIM
    /// (unlike `DocxReader`, which clamps `rowSpan` at its own source) — a malformed/hand-edited
    /// document (or an exporter quirk) whose declared span outruns the table's actual rows reaches
    /// the shared table geometry solver completely untouched. Proven through the REAL path this bug
    /// crashed on — `ZipArchive -> OdtReader.read -> OfficeTextBuilder.build` — not just a reader-
    /// level assertion on `[OfficeBlock]` (invariant 29: a parser test alone can't show the BUILDER
    /// survives what the parser hands it).
    func testRowSpanClaimingMoreRowsThanTheTableHasDoesNotCrashTheBuilder() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-rows-spanned="3"><text:p>Tall</text:p></table:table-cell>
            <table:table-cell><text:p>B</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        guard case let .table(rows, _, _, _) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a table block, got \(blocks)")
        }
        XCTAssertEqual(rows.first?.first?.rowSpan, 3,
                       "the span must reach the reader UNCLAMPED, or this test proves nothing about the builder's own defence")
        let out = OfficeTextBuilder.build(blocks, theme: RenderTheme.current(size: 16))
        XCTAssertGreaterThan(out.length, 0, "a rowSpan claiming more rows than the table has must not crash")
    }

    /// `table:number-columns-repeated` can appear on `table:covered-table-cell` too (a wide merge's
    /// covered run compressed the same way an empty run would be) — it must not throw off the anchor
    /// that follows it, regardless of the repeat count.
    func testRepeatedCoveredCellsDoNotShiftTheAnchorThatFollows() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-columns-spanned="3"><text:p>Wide</text:p></table:table-cell>
            <table:covered-table-cell table:number-columns-repeated="2"/>
            <table:table-cell><text:p>Next</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Wide")], rowSpan: 1, colSpan: 3), Cell(spans: [Span(text: "Next")])],
        ], headerRows: 0)])
    }

    // MARK: S8 — images, lists (and their combination) inside table cells (gap-list rows 6/7)

    func testImageInsideTableCellProducesAnImageBlockWithReservedSize() throws {
        let zip = buildZip([
            ("content.xml", Data(doc(body: """
            <table:table><table:table-row><table:table-cell>
              <text:p><draw:frame svg:width="72pt" svg:height="36pt">
              <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
            </table:table-cell></table:table-row></table:table>
            """).utf8)),
            ("Pictures/photo.png", Data([0x01])),
        ])
        let blocks = try OdtReader.read(try ZipArchive(data: zip)).blocks
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(blocks: [.image(id: "Pictures/photo.png", size: CGSize(width: 72, height: 36))])],
        ], headerRows: 0)])
    }

    func testNumberedListInsideTableCellKeepsItsNumbering() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row><table:table-cell>
              <text:list text:style-name="L1"><text:list-item><text:p>In cell</text:p></text:list-item></text:list>
            </table:table-cell></table:table-row></table:table>
            """,
            automaticStyles: numberThenBulletListStyle)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(blocks: [.listItem(level: 0, ordered: true, spans: [Span(text: "In cell")])])],
        ], headerRows: 0)])
    }

    func testBulletedListInsideTableCellKeepsBullets() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row><table:table-cell>
              <text:list><text:list-item><text:p>Bullet item</text:p></text:list-item></text:list>
            </table:table-cell></table:table-row></table:table>
            """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(blocks: [.listItem(level: 0, ordered: false, spans: [Span(text: "Bullet item")])])],
        ], headerRows: 0)])
    }

    /// Text, then a numbered list item, then an image, all inside ONE cell — must keep all three, in
    /// the order the source wrote them, mirroring `DocxReaderTests`' equivalent.
    func testMixedContentInTableCellKeepsTextListAndImageInSourceOrder() throws {
        let zip = buildZip([
            ("content.xml", Data(doc(
                body: """
                <table:table><table:table-row><table:table-cell>
                  <text:p>Intro</text:p>
                  <text:list text:style-name="L1"><text:list-item><text:p>Listed</text:p></text:list-item></text:list>
                  <text:p><draw:frame svg:width="72pt" svg:height="72pt">
                  <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
                </table:table-cell></table:table-row></table:table>
                """,
                automaticStyles: numberThenBulletListStyle
            ).utf8)),
            ("Pictures/photo.png", Data([0x01])),
        ])
        let blocks = try OdtReader.read(try ZipArchive(data: zip)).blocks
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(blocks: [
                .paragraph(spans: [Span(text: "Intro")]),
                .listItem(level: 0, ordered: true, spans: [Span(text: "Listed")]),
                .image(id: "Pictures/photo.png", size: CGSize(width: 72, height: 72)),
            ])],
        ], headerRows: 0)])
    }

    /// A cell whose only content is an empty `<text:p/>` must produce no block at all —
    /// `Cell(blocks: [])`, never a phantom `.paragraph(spans: [])`.
    func testEmptyCellProducesNoPhantomBlock() throws {
        let blocks = try read(body: """
        <table:table><table:table-row><table:table-cell><text:p/></table:table-cell></table:table-row></table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [[Cell(blocks: [])]], headerRows: 0)])
    }

    // MARK: Nested tables — flattened to text (Cell has no room for a nested block)

    func testNestedTableInsideACellFlattensToTextRatherThanDisappearing() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell>
              <text:p>Outer</text:p>
              <table:table>
                <table:table-row>
                  <table:table-cell><text:p>Nested</text:p></table:table-cell>
                </table:table-row>
              </table:table>
            </table:table-cell>
          </table:table-row>
        </table:table>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table block") }
        // `Cell` holds `blocks`, not `spans`, since S7 — the reader still flattens a nested table
        // into a single `.paragraph` at parse time, so pull its spans back out for this assertion.
        let allText = rows.flatMap { $0 }.flatMap { $0.blocks }.flatMap { block -> [Span] in
            if case .paragraph(let spans, _, _, _, _) = block { return spans }
            return []
        }.map(\.text).joined()
        XCTAssertTrue(allText.contains("Outer"), "outer paragraph text must survive")
        XCTAssertTrue(allText.contains("Nested"), "nested table's text must survive, not disappear")
    }

    // MARK: Lists

    private let numberThenBulletListStyle = """
    <text:list-style style:name="L1">
      <text:list-level-style-number text:level="1"/>
      <text:list-level-style-bullet text:level="2"/>
    </text:list-style>
    """

    func testNestedListLevelsAndOrderedVsBulletResolveViaListStyle() throws {
        let blocks = try read(
            body: """
            <text:list text:style-name="L1">
              <text:list-item><text:p>One</text:p>
                <text:list><text:list-item><text:p>Nested</text:p></text:list-item></text:list>
              </text:list-item>
            </text:list>
            """,
            automaticStyles: numberThenBulletListStyle)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")]),
            .listItem(level: 1, ordered: false, spans: [Span(text: "Nested")]),
        ])
    }

    func testUnresolvableListStyleDefaultsToUnordered() throws {
        let blocks = try read(body: """
        <text:list text:style-name="Missing"><text:list-item><text:p>Item</text:p></text:list-item></text:list>
        """)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    func testListWithNoStyleNameAtAllDefaultsToUnordered() throws {
        let blocks = try read(body: """
        <text:list><text:list-item><text:p>Item</text:p></text:list-item></text:list>
        """)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    // MARK: Whitespace elements

    func testTextSWithCountProducesThatManySpaces() throws {
        let blocks = try read(body: "<text:p>a<text:s text:c=\"3\"/>b</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "a   b")])])
    }

    func testBareTextSDefaultsToOneSpace() throws {
        let blocks = try read(body: "<text:p>a<text:s/>b</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "a b")])])
    }

    func testTabAndLineBreakSurviveIntoText() throws {
        let blocks = try read(body: "<text:p>Col1<text:tab/>Col2<text:line-break/>Line2</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Col1\tCol2\nLine2")])])
    }

    // MARK: Emphasis

    func testBoldItalicUnderlineLandOnTheRightRanges() throws {
        let blocks = try read(
            body: """
            <text:p><text:span text:style-name="Bold">B</text:span><text:span text:style-name="Italic">I</text:span><text:span text:style-name="Under">U</text:span></text:p>
            """,
            automaticStyles: """
            <style:style style:name="Bold" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
            <style:style style:name="Italic" style:family="text"><style:text-properties fo:font-style="italic"/></style:style>
            <style:style style:name="Under" style:family="text"><style:text-properties style:text-underline-style="solid"/></style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "B", bold: true),
            Span(text: "I", italic: true),
            Span(text: "U", underline: true),
        ])])
    }

    func testUnresolvableSpanStyleEmitsTextUnstyledRatherThanDropped() throws {
        let blocks = try read(body: "<text:p><text:span text:style-name=\"Missing\">Text</text:span></text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")])])
    }

    func testStrikethroughSuperscriptAndSubscriptStylesMapToSpanFlags() throws {
        let blocks = try read(
            body: """
            <text:p><text:span text:style-name="Strike">S</text:span><text:span text:style-name="Sup">P</text:span><text:span text:style-name="Sub">B</text:span></text:p>
            """,
            automaticStyles: """
            <style:style style:name="Strike" style:family="text"><style:text-properties style:text-line-through-style="solid"/></style:style>
            <style:style style:name="Sup" style:family="text"><style:text-properties style:text-position="super 58%"/></style:style>
            <style:style style:name="Sub" style:family="text"><style:text-properties style:text-position="sub 58%"/></style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "S", strikethrough: true),
            Span(text: "P", superscript: true),
            Span(text: "B", subscripted: true),
        ])])
    }

    // MARK: Hyperlinks

    func testHyperlinkTextAProducesLinkSpan() throws {
        let blocks = try read(body: """
        <text:p>before <text:a xlink:href="https://example.com">link text</text:a> after</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "before "),
            Span(text: "link text", link: "https://example.com"),
            Span(text: " after"),
        ])])
    }

    func testHyperlinkWithNoHrefIsPlainTextNotACrash() throws {
        let blocks = try read(body: "<text:p><text:a>no href</text:a></text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "no href")])])
    }

    /// ODF's same-document convention: `xlink:href` beginning with `#` — must survive verbatim
    /// (`OfficeTextBuilder` is what turns this into a non-file-opening jump, not this reader).
    func testInternalHrefProducesAFragmentLinkVerbatim() throws {
        let blocks = try read(body: """
        <text:p><text:a xlink:href="#BookmarkName">see above</text:a></text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "see above", link: "#BookmarkName")])])
    }

    // MARK: Bookmarks (in-document link TARGETS, not the links themselves)

    /// `text:bookmark` — the zero-length, point form used for most cross-reference targets.
    func testPointBookmarkAttachesItsNameToTheFollowingSpan() throws {
        let blocks = try read(body: """
        <text:p><text:bookmark text:name="Target1"/>Clause 7</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Clause 7", bookmarks: ["Target1"])])])
    }

    /// `text:bookmark-start`/`text:bookmark-end` — the ranged form, mirroring docx's
    /// `w:bookmarkStart`/`w:bookmarkEnd`.
    func testRangedBookmarkAttachesItsNameToTheWrappedSpanOnly() throws {
        let blocks = try read(body: """
        <text:p>See <text:bookmark-start text:name="Ref9"/>clause 7<text:bookmark-end text:name="Ref9"/> above</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "See "),
            Span(text: "clause 7", bookmarks: ["Ref9"]),
            Span(text: " above"),
        ])])
    }

    // MARK: Footnotes / endnotes
    //
    // NOTE ON EVIDENCE: like `DocxReaderTests`' footnote section, this is entirely synthetic — no
    // fixture `.odt` in this project's corpus carries a real `text:note`. Built from the ODF spec
    // shape (`text:note` containing `text:note-citation` + `text:note-body`), not measured.

    func testFootnoteProducesSuperscriptMarkerAtCitationAndAppendsBodyAtDocumentEnd() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>Note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")]),
            // The tab between marker and text is SYNTHETIC (`OdtReader.noteMarkerSeparator`) — ODF
            // has nothing corresponding to docx's literal `w:tab` inside the note body, but the
            // marker here is our own construct, so we own the separator and match what docx already
            // shows for the same document (see the sprint's cross-format-divergence fix).
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: "\t"), Span(text: "Note body text.")]),
        ])
    }

    /// ODF tells footnotes and endnotes apart only by `text:note-class` — both are the SAME element
    /// otherwise, and this reader renders them identically (the marker is the file's own
    /// `text:note-citation` text either way, never recomputed), so an endnote needs no separate case.
    func testEndnoteIsRenderedTheSameWayAsAFootnote() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="edn1" text:note-class="endnote">
          <text:note-citation>i</text:note-citation>
          <text:note-body><text:p>Endnote body.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "i", superscript: true), Span(text: " note.")]),
            .paragraph(spans: [Span(text: "i", superscript: true), Span(text: "\t"), Span(text: "Endnote body.")]),
        ])
    }

    /// The corruption this sprint exists to avoid: a naive reader that walks `text:note` like any
    /// other wrapper would splice "Note body text." into the middle of "See  note.", reading as one
    /// garbled sentence. The citation and the body must stay visually separated.
    func testFootnoteBodyIsNeverSplicedIntoTheCitingParagraphsOwnSpans() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>Note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        guard case .paragraph(let citingSpans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertFalse(citingSpans.contains { $0.text.contains("Note body text.") })
    }

    /// Pins the exact separator between marker and body text against DRIFT: docx's note body reads
    /// as `"1\tThe first note body text."` (a real `w:tab` FROM THE FILE, in Word's own footnote
    /// template — see `DocxReaderTests`), and this reader must match that shape even though ODF has
    /// no equivalent element to read it from. Reading `docs/fixtures/office/notes.docx` and
    /// `docs/fixtures/office/notes.odt` (the real, LibreOffice-produced pair) must therefore produce
    /// identical block text end to end — this test pins the mechanism that makes that hold, in a
    /// fixture nobody has to keep around on disk to prove it.
    func testMarkerAndBodyAreSeparatedByATabMatchingDocxsOwnFootnoteConvention() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>The first note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        guard case .paragraph(let noteSpans, _, _, _, _) = blocks[1] else { return XCTFail("expected the appended note paragraph") }
        XCTAssertEqual(noteSpans.map(\.text).joined(), "1\tThe first note body text.")
    }

    /// A note missing `text:note-citation` entirely (malformed — ODF requires one) falls back to a
    /// plain sequential counter in citation order, rather than a blank marker — mirroring what
    /// `DocxReader` does for EVERY docx note (which never carries a citation number of its own at
    /// all, see the correction in the sprint brief).
    func testNoteWithNoCitationElementFallsBackToASequentialCounter() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-body><text:p>Note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: "\t"), Span(text: "Note body text.")]),
        ])
    }

    /// A note missing `text:note-body` entirely (malformed) still shows its citation marker inline —
    /// honest, since something WAS cited — but fabricates no body text, since there is none.
    func testNoteWithNoBodyElementStillShowsMarkerButAppendsNothing() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")])])
    }

    /// Two footnotes cited in the same paragraph both get their own marker AND their own appended
    /// body, in citation order — `text:note-citation`'s own text is trusted directly (never
    /// recomputed), so this is really just proving two notes don't collide or reorder.
    func testTwoFootnotesInOneParagraphEachGetTheirOwnMarkerAndBody() throws {
        let blocks = try read(body: """
        <text:p>One<text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>First note.</text:p></text:note-body>
        </text:note> two<text:note text:id="ftn2" text:note-class="footnote">
          <text:note-citation>2</text:note-citation>
          <text:note-body><text:p>Second note.</text:p></text:note-body>
        </text:note></text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [
                Span(text: "One"), Span(text: "1", superscript: true), Span(text: " two"), Span(text: "2", superscript: true),
            ]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: "\t"), Span(text: "First note.")]),
            .paragraph(spans: [Span(text: "2", superscript: true), Span(text: "\t"), Span(text: "Second note.")]),
        ])
    }

    /// An image inside a footnote's body belongs to the FOOTNOTE, not to the paragraph that cites
    /// it — `collectImages`' blind `allDescendants` walk over the citing paragraph would otherwise
    /// find it too and duplicate it at the wrong place (see `OdtReader.collectImages`).
    func testImageInsideAFootnoteBodyDoesNotLeakIntoTheCitingParagraphsOwnImages() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
              <text:note-citation>1</text:note-citation>
              <text:note-body>
                <text:p><draw:frame svg:width="1in" svg:height="1in"><draw:image xlink:href="Pictures/note.png"/></draw:frame></text:p>
              </text:note-body>
            </text:note> note.</text:p>
            """,
            media: [("Pictures/note.png", [0x00])])
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")]),
            // The note body opens with an image, not text — nowhere to splice the marker span into
            // (`OdtReader.prependingMarker` returns `nil` for `.image`), so it becomes its own small
            // leading paragraph rather than being silently dropped.
            .paragraph(spans: [Span(text: "1", superscript: true)]),
            .image(id: "Pictures/note.png", size: CGSize(width: 72, height: 72)),
        ])
    }

    // MARK: Archive-level failure and absent optional parts

    func testArchiveWithNoContentXMLThrows() throws {
        let archive = try ZipArchive(data: buildZip([("styles.xml", Data("<x/>".utf8))]))
        XCTAssertThrowsError(try OdtReader.read(archive)) { error in
            XCTAssertEqual(error as? OdtReader.ReadError, .missingContentXML)
        }
    }

    func testMissingStylesXMLStillParsesWithNoCrash() throws {
        let blocks = try read(body: "<text:p>Plain</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")])])
    }

    // MARK: S4 item 1 — unknown body wrappers RECURSE instead of dropping their contents whole

    func testTextSectionContentSurvivesViaRecursionNotJustCoincidentalReachability() throws {
        let blocks = try read(body: """
        <text:section text:name="Sec1"><text:p>Inside a section.</text:p></text:section>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Inside a section.")])])
    }

    func testTableOfContentIndexBodyParagraphsSurvive() throws {
        let blocks = try read(body: """
        <text:table-of-content text:name="TOC">
          <text:table-of-content-source/>
          <text:index-body>
            <text:index-title><text:p>Table of Contents</text:p></text:index-title>
            <text:p>Chapter 1 ... 1</text:p>
          </text:index-body>
        </text:table-of-content>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Table of Contents")]),
            .paragraph(spans: [Span(text: "Chapter 1 ... 1")]),
        ])
    }

    /// Two of the other six index-family wrappers, confirming the fix is generic rather than
    /// scoped to the two names gap-list.md happened to mention by example.
    func testIllustrationAndBibliographyIndexBodiesSurvive() throws {
        let illustrations = try read(body: """
        <text:illustration-index text:name="LOI">
          <text:index-body><text:p>Figure 1: A diagram</text:p></text:index-body>
        </text:illustration-index>
        """)
        XCTAssertEqual(illustrations, [.paragraph(spans: [Span(text: "Figure 1: A diagram")])])

        let bibliography = try read(body: """
        <text:bibliography text:name="Bib">
          <text:index-body><text:p>Smith, J. (2020). A Book.</text:p></text:index-body>
        </text:bibliography>
        """)
        XCTAssertEqual(bibliography, [.paragraph(spans: [Span(text: "Smith, J. (2020). A Book.")])])
    }

    func testPageSequenceContentSurvives() throws {
        let blocks = try read(body: """
        <text:page-sequence><text:page><text:p>Page content.</text:p></text:page></text:page-sequence>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Page content.")])])
    }

    func testAnnotationTrackedChangesAndDeclarationBlocksStayExcludedEvenThoughRecursionIsNowPermissive() throws {
        let blocks = try read(body: """
        <office:annotation><text:p>A reviewer comment.</text:p></office:annotation>
        <text:tracked-changes>
          <text:changed-region text:id="ct1"><text:deletion><text:p>Deleted text.</text:p></text:deletion></text:changed-region>
        </text:tracked-changes>
        <text:sequence-decls><text:sequence-decl text:display-outline-level="0" text:name="Figure"/></text:sequence-decls>
        <office:forms><form:form><text:p>Not document prose.</text:p></form:form></office:forms>
        <text:p>Real content.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Real content.")])])
    }

    /// Mutation check (invariant 30): confirm the recursion is what's carrying the content, not
    /// some OTHER reachable path — remove the recursion (simulate by asserting the wrapper name
    /// itself never reaches a matched case) by checking a NESTED wrapper (section inside a TOC
    /// index-body) still survives, which only recursion-at-every-level, not a single special case,
    /// can produce.
    func testNestedUnknownWrappersRecurseAtEveryLevelNotJustOnce() throws {
        let blocks = try read(body: """
        <text:table-of-content text:name="TOC">
          <text:index-body><text:section text:name="Inner"><text:p>Deeply nested.</text:p></text:section></text:index-body>
        </text:table-of-content>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Deeply nested.")])])
    }

    // MARK: S4 item 2 — text:numbered-paragraph (a list item with no enclosing text:list)

    func testNumberedParagraphAtLevelOneProducesAnOrderedListItem() throws {
        let blocks = try read(
            body: """
            <text:numbered-paragraph text:style-name="L1" text:list-level="1">
              <text:p>Clause one.</text:p>
            </text:numbered-paragraph>
            """,
            automaticStyles: numberThenBulletListStyle)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Clause one.")])])
    }

    func testNumberedParagraphAtDeeperLevelConvertsOneBasedToZeroBasedLevel() throws {
        let blocks = try read(
            body: """
            <text:numbered-paragraph text:style-name="L1" text:list-level="3">
              <text:p>Sub-clause.</text:p>
            </text:numbered-paragraph>
            """,
            automaticStyles: numberThenBulletListStyle)
        // Level 3 (1-based) → 2 (0-based); the fixture's list style only declares levels 0/1, so an
        // undeclared level 2 correctly resolves to unordered (`isOrdered`'s own unresolvable-input
        // contract), proving the level really did convert rather than clamp to a declared one.
        XCTAssertEqual(blocks, [.listItem(level: 2, ordered: false, spans: [Span(text: "Sub-clause.")])])
    }

    func testNumberedParagraphWithNoListLevelAttributeDefaultsToLevelZero() throws {
        let blocks = try read(
            body: """
            <text:numbered-paragraph text:style-name="L1">
              <text:p>Default level.</text:p>
            </text:numbered-paragraph>
            """,
            automaticStyles: numberThenBulletListStyle)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Default level.")])])
    }

    // MARK: S4 item 3 — hidden/conditional content shows unless the file explicitly says hidden

    /// `text:hidden-paragraph`'s content model is the SAME as `text:p`'s (spans directly, per ODF
    /// 1.3) — not a wrapper holding a nested `text:p`.
    func testHiddenParagraphMarkedHiddenIsSuppressed() throws {
        let blocks = try read(body: """
        <text:hidden-paragraph text:condition="false" text:is-hidden="true">Should not appear.</text:hidden-paragraph><text:p>Visible.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Visible.")])])
    }

    func testHiddenParagraphMarkedVisibleShows() throws {
        let blocks = try read(body: """
        <text:hidden-paragraph text:condition="true" text:is-hidden="false">Shown text.</text:hidden-paragraph>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Shown text.")])])
    }

    /// The project's governing rule: an unknown/absent display state must fall to SHOWING.
    func testHiddenParagraphWithNoIsHiddenAttributeShowsByDefault() throws {
        let blocks = try read(body: """
        <text:hidden-paragraph text:condition="SomeVar==1">No recorded state.</text:hidden-paragraph>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "No recorded state.")])])
    }

    func testHiddenTextRunHiddenIsSuppressed() throws {
        let blocks = try read(body: """
        <text:p>Before <text:hidden-text text:condition="false" text:is-hidden="true" text:string-value="secret"/> after.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Before  after.")])])
    }

    func testHiddenTextRunVisibleShowsCachedStringValue() throws {
        let blocks = try read(body: """
        <text:p>Before <text:hidden-text text:condition="true" text:is-hidden="false" text:string-value="shown"/> after.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Before shown after.")])])
    }

    func testConditionalTextShowsTrueBranchWhenCurrentValueIsTrue() throws {
        let blocks = try read(body: """
        <text:p><text:conditional-text text:condition="X" text:string-value-if-true="YES" text:string-value-if-false="NO" text:current-value="true"/></text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "YES")])])
    }

    func testConditionalTextShowsFalseBranchWhenCurrentValueIsFalseOrAbsent() throws {
        let blocksFalse = try read(body: """
        <text:p><text:conditional-text text:condition="X" text:string-value-if-true="YES" text:string-value-if-false="NO" text:current-value="false"/></text:p>
        """)
        XCTAssertEqual(blocksFalse, [.paragraph(spans: [Span(text: "NO")])])

        let blocksAbsent = try read(body: """
        <text:p><text:conditional-text text:condition="X" text:string-value-if-true="YES" text:string-value-if-false="NO"/></text:p>
        """)
        XCTAssertEqual(blocksAbsent, [.paragraph(spans: [Span(text: "NO")])])
    }

    // MARK: S4 item 4 — draw:frame > draw:text-box contributes its text content

    func testTextBoxContentsSurviveInsteadOfDisappearing() throws {
        let blocks = try read(body: """
        <text:p><draw:frame svg:width="72pt" svg:height="72pt">
          <draw:text-box><text:p>Callout text.</text:p></draw:text-box>
        </draw:frame></text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Callout text.")])])
    }

    func testTextBoxWithHeadingAndEmptyPlaceholderParagraphFiltersTheEmptyOne() throws {
        let blocks = try read(body: """
        <text:p><draw:frame svg:width="72pt" svg:height="72pt">
          <draw:text-box>
            <text:h text:outline-level="2">Box Title</text:h>
            <text:p/>
          </draw:text-box>
        </draw:frame></text:p>
        """)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Box Title")])])
    }

    func testFrameWithBothImageAndTextBoxIsTreatedAsAnImageNotDoubleCounted() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p><draw:frame svg:width="72pt" svg:height="72pt">
              <draw:image xlink:href="Pictures/photo.png"/>
            </draw:frame></text:p>
            """,
            media: [("Pictures/photo.png", [0x01])])
        XCTAssertEqual(blocks, [.image(id: "Pictures/photo.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: S4 — a real read path, not just the parser (invariant 29)

    func testAllFourItemsSurviveThroughDocumentTypesReadOfficeNotJustOdtReaderDirectly() throws {
        let zip = buildOdt(content: doc(
            body: """
            <text:section text:name="Sec1"><text:p>Section text.</text:p></text:section>
            <text:numbered-paragraph text:style-name="L1" text:list-level="1"><text:p>Clause.</text:p></text:numbered-paragraph>
            <text:hidden-paragraph text:is-hidden="true">Hidden.</text:hidden-paragraph>
            <text:p><draw:frame svg:width="72pt" svg:height="72pt"><draw:text-box><text:p>Box text.</text:p></draw:text-box></draw:frame></text:p>
            """,
            automaticStyles: numberThenBulletListStyle))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocumentTypes.readOffice(archive, extension: "odt").blocks
        let allText = blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let spans, _, _, _, _), .heading(_, let spans, _, _, _, _), .listItem(_, _, let spans, _, _, _, _, _): return spans.map(\.text)
            case .table, .image, .unsupportedGraphic, .formula: return []
            }
        }.joined()
        XCTAssertTrue(allText.contains("Section text."))
        XCTAssertTrue(allText.contains("Clause."))
        XCTAssertFalse(allText.contains("Hidden."))
        XCTAssertTrue(allText.contains("Box text."))
    }

    // MARK: S15 — paragraph-family styles: alignment, tab stops, inheritance

    func testExplicitTextAlignOnParagraphStyleSetsAlignment() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Centered\">Text</text:p>",
            automaticStyles: """
            <style:style style:name="Centered" style:family="paragraph">
              <style:paragraph-properties fo:text-align="center"/>
            </style:style>
            """)
        guard case .paragraph(_, _, let alignment, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(alignment, .center)
    }

    /// `"start"`/`"end"` are writing-direction-relative (ODF 1.3 §20.339) — must resolve against the
    /// SAME `style:writing-mode` this style declares, not a hardcoded LTR assumption.
    func testTextAlignStartAndEndResolveAgainstWritingDirection() throws {
        let ltr = try read(
            body: "<text:p text:style-name=\"S\">A</text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="paragraph">
              <style:paragraph-properties fo:text-align="start" style:writing-mode="lr-tb"/>
            </style:style>
            """)
        guard case .paragraph(_, _, let a1, _, _) = ltr[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(a1, .left)

        let rtl = try read(
            body: "<text:p text:style-name=\"S2\">A</text:p>",
            automaticStyles: """
            <style:style style:name="S2" style:family="paragraph">
              <style:paragraph-properties fo:text-align="start" style:writing-mode="rl-tb"/>
            </style:style>
            """)
        guard case .paragraph(_, let rtl2, let a2, _, _) = rtl[0] else { return XCTFail("expected a paragraph") }
        XCTAssertTrue(rtl2)
        XCTAssertEqual(a2, .right)
    }

    /// S12 left `alignment` `nil` for an RTL paragraph with no explicit `fo:text-align`, relying on
    /// `.natural` + `baseWritingDirection` to resolve the edge — a paragraph style that DOES declare
    /// one must override that default rather than being ignored in its favour.
    func testExplicitAlignmentWinsOverRTLDefault() throws {
        let noAlignment = try read(
            body: "<text:p text:style-name=\"Arabic\">Plain</text:p>",
            automaticStyles: """
            <style:style style:name="Arabic" style:family="paragraph">
              <style:paragraph-properties style:writing-mode="rl-tb"/>
            </style:style>
            """)
        guard case .paragraph(_, let rtl1, let a1, _, _) = noAlignment[0] else { return XCTFail("expected a paragraph") }
        XCTAssertTrue(rtl1)
        XCTAssertNil(a1)

        let explicitLeft = try read(
            body: "<text:p text:style-name=\"ArabicLeft\">Plain</text:p>",
            automaticStyles: """
            <style:style style:name="ArabicLeft" style:family="paragraph">
              <style:paragraph-properties style:writing-mode="rl-tb" fo:text-align="left"/>
            </style:style>
            """)
        guard case .paragraph(_, let rtl2, let a2, _, _) = explicitLeft[0] else { return XCTFail("expected a paragraph") }
        XCTAssertTrue(rtl2)
        XCTAssertEqual(a2, .left)
    }

    func testParagraphStyleTabStopsResolveToPoints() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Tabbed\">A\tB</text:p>",
            automaticStyles: """
            <style:style style:name="Tabbed" style:family="paragraph">
              <style:paragraph-properties>
                <style:tab-stops>
                  <style:tab-stop style:position="36pt"/>
                  <style:tab-stop style:position="1in"/>
                </style:tab-stops>
              </style:paragraph-properties>
            </style:style>
            """)
        guard case .paragraph(_, _, _, let tabStops, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(tabStops, [TabStop(position: 36), TabStop(position: 72)])
    }

    func testParagraphStyleInheritsOutlineLevelFromParentStyleName() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Child\">Heading via inheritance</text:p>",
            automaticStyles: """
            <style:style style:name="Parent" style:family="paragraph" style:default-outline-level="2"/>
            <style:style style:name="Child" style:family="paragraph" style:parent-style-name="Parent"/>
            """)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Heading via inheritance")])])
    }

    func testChildsOwnOutlineLevelWinsOverParents() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Child\">X</text:p>",
            automaticStyles: """
            <style:style style:name="Parent" style:family="paragraph" style:default-outline-level="2"/>
            <style:style style:name="Child" style:family="paragraph" style:parent-style-name="Parent" style:default-outline-level="4"/>
            """)
        XCTAssertEqual(blocks, [.heading(level: 4, spans: [Span(text: "X")])])
    }

    /// Invariant 30's own required case: a malformed document where two paragraph styles name each
    /// other as parent must NOT hang the resolver — the walk's `visited` set must break the cycle.
    func testParagraphStyleParentCycleDoesNotHangAndResolvesToUnstyled() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"A\">Cyclic</text:p>",
            automaticStyles: """
            <style:style style:name="A" style:family="paragraph" style:parent-style-name="B"/>
            <style:style style:name="B" style:family="paragraph" style:parent-style-name="A"/>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Cyclic")])])
    }

    // MARK: S15 — text-family styles: color, highlight, size, font family, inheritance

    func testTextRunColorBackgroundSizeAndFontFamilyAreRead() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"Styled\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="Styled" style:family="text">
              <style:text-properties fo:color="#FF0000" fo:background-color="#FFFF00" fo:font-size="14pt" fo:font-family="Georgia"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontSize, 14)
        XCTAssertEqual(spans[0].fontName, "Georgia")
        XCTAssertNotNil(spans[0].textColor)
        XCTAssertNotNil(spans[0].highlightColor)
    }

    /// `style:font-name` is a REFERENCE into `office:font-face-decls`, not a literal family name —
    /// `"Arial1"` here must resolve to the declared `svg:font-family`, `"Arial"`.
    func testFontNameResolvesThroughFontFaceDeclarations() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"Styled\">Text</text:span></text:p>",
            automaticStyles: """
            <office:font-face-decls>
              <style:font-face style:name="Arial1" svg:font-family="Arial"/>
            </office:font-face-decls>
            <style:style style:name="Styled" style:family="text">
              <style:text-properties style:font-name="Arial1"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Arial")
    }

    // MARK: Font family NAMES — an XSL font-family list, CSS-quoted

    /// `svg:font-family` and `fo:font-family` hold an XSL `font-family` LIST, whose members are
    /// CSS-quoted whenever the name is not a bare identifier — LibreOffice writes
    /// `svg:font-family="&apos;Noto Sans CJK KR&apos;"`, which unescapes to a value WITH literal
    /// apostrophes. `NSFont(name:)` takes a family name, not a CSS token: measured on this machine,
    /// `NSFont(name: "'Noto Sans CJK KR'", size: 12)` is `nil` while `NSFont(name: "Noto Sans CJK
    /// KR", size: 12)` resolves. So every quoted family in every ODT resolved to a font that could
    /// not be constructed and silently fell back to the theme's own face — the document's declared
    /// typeface was dead, not wrong. Asserted through the reader on the exact byte sequence a real
    /// LibreOffice file carries (all four `.odt` fixtures in `docs/fixtures/office` quote this way).
    func testQuotedFontFamilyIsUnquotedSoItCanActuallyBeConstructed() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"Styled\">Text</text:span></text:p>",
            automaticStyles: """
            <office:font-face-decls>
              <style:font-face style:name="F1" svg:font-family="&apos;Noto Sans CJK KR&apos;"/>
            </office:font-face-decls>
            <style:style style:name="Styled" style:family="text">
              <style:text-properties style:font-name="F1"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Noto Sans CJK KR")
    }

    /// The double-quoted form is equally legal CSS and appears in files from other producers.
    func testDoubleQuotedFontFamilyIsUnquotedToo() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="&quot;Liberation Serif&quot;"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Liberation Serif")
    }

    /// A LIST, not a single name — the first member is the author's first choice, and the rest are
    /// the fallbacks a CSS engine would walk. This reader records one family per span, so it takes
    /// the first and leaves the rest to `FontSubstitutionResolver`, which resolves coverage against
    /// what is actually installed. Handing the WHOLE list to `NSFont(name:)` yields `nil` just as a
    /// quoted single name did.
    func testFontFamilyListTakesTheFirstFamilyNotTheWholeList() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="&apos;맑은 고딕&apos;, Arial, sans-serif"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "맑은 고딕")
    }

    /// "First family" means the first that NAMES something: a list whose leading member is empty
    /// still plainly asks for the family after it, and reading that as "no family" would throw away
    /// a real declaration over a stray comma.
    func testFontFamilyListSkipsALeadingMemberThatNamesNothing() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family=", Arial"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Arial")
    }

    /// An unquoted bare identifier is already a family name and must come through byte-identical —
    /// this is the invariant-37 half of the de-quoting change. `굴림체`, `Wingdings` and `OpenSymbol`
    /// all appear unquoted in the real fixtures beside quoted names in the same file.
    func testUnquotedFontFamilyIsUnchanged() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="굴림체"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "굴림체")
    }

    /// An EMPTY family must behave exactly as an ABSENT one. `<style:font-face style:name="F"
    /// svg:font-family=""/>` is written by LibreOffice and appears in two of this repo's own
    /// fixtures (`bus-headings.odt`, `tago-tables.odt`). Resolved as a family it produced `""` —
    /// non-`nil`, so the `??` fallback never fired and the cascade recorded "this style states a
    /// family", which BLOCKS the parent's real family from being inherited. The span then asked for
    /// a font named `""` and got nothing, so an inherited typeface was lost to a declaration that
    /// names no typeface at all.
    func testEmptyFontFamilyIsTreatedAsAbsentSoTheParentFamilyStillInherits() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"Child\">Text</text:span></text:p>",
            automaticStyles: """
            <office:font-face-decls>
              <style:font-face style:name="Empty" svg:font-family=""/>
            </office:font-face-decls>
            <style:style style:name="Parent" style:family="text">
              <style:text-properties fo:font-family="Georgia"/>
            </style:style>
            <style:style style:name="Child" style:family="text" style:parent-style-name="Parent">
              <style:text-properties style:font-name="Empty"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Georgia")
    }

    /// The same rule stated directly rather than through the font-face indirection, and with
    /// nothing to inherit: an empty family is `nil` (the theme's own body font), never `""`, which
    /// no font is named.
    func testEmptyDirectFontFamilyResolvesToNoFamilyAtAll() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="" fo:font-size="14pt"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertNil(spans[0].fontName)
        XCTAssertEqual(spans[0].fontSize, 14, "the rest of the style must still be read")
    }

    /// A family of nothing but quotes, or nothing but spaces, is the same "names no typeface" case —
    /// unquoting must not turn `"''"` into `""` and then hand that on as a real family.
    func testFamilyThatIsOnlyQuotesOrWhitespaceIsAlsoTreatedAsAbsent() throws {
        for family in ["&apos;&apos;", " ", "&apos; &apos;", ","] {
            let blocks = try read(
                body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
                automaticStyles: """
                <style:style style:name="S" style:family="text">
                  <style:text-properties fo:font-family="\(family)"/>
                </style:style>
                """)
            guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
            XCTAssertNil(spans[0].fontName, "family \(family) should name no typeface")
        }
    }

    /// A font-face declaration whose `style:name` is referenced but which declares NO
    /// `svg:font-family` at all is a different case from an empty one, and must keep its existing
    /// behaviour: the reference falls through to the REFERENCE NAME itself (`fontFaces[n] ?? n`),
    /// which for these files is usually a real family name too. Pinned so the empty-family fix
    /// cannot quietly swallow this path as well.
    func testFontNameWithNoMatchingFontFaceStillFallsBackToTheReferenceName() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties style:font-name="Georgia"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Georgia")
    }

    /// The completeness guard `OdtReader.appendMerging`'s own comment points at — the twin of
    /// `DocxReaderTests.testEveryRunPropertyADocxCanCarryKeepsAdjacentRunsApart`. A merge keeps the
    /// FIRST span's attributes, so every property an ODT text style can express must keep adjacent
    /// runs apart or the second run's value is silently lost. `code`/`rtl` are absent by
    /// construction (no ODF markup sets either on a `text:span` — see `appendMerging`'s comment);
    /// `bookmarks`/`commentIds` are never merged at all and have their own tests.
    func testEveryTextPropertyAnOdtCanCarryKeepsAdjacentRunsApart() throws {
        let cases: [(field: String, a: String, b: String)] = [
            ("bold", "fo:font-weight=\"bold\"", "fo:font-weight=\"normal\""),
            ("italic", "fo:font-style=\"italic\"", "fo:font-style=\"normal\""),
            ("underline", "style:text-underline-style=\"solid\"", "style:text-underline-style=\"none\""),
            ("underlineStyle", "style:text-underline-style=\"solid\"", "style:text-underline-style=\"dotted\""),
            ("strikethrough", "style:text-line-through-style=\"solid\"", "style:text-line-through-style=\"none\""),
            ("superscript", "style:text-position=\"super 58%\"", "style:text-position=\"0% 100%\""),
            ("subscripted", "style:text-position=\"sub 58%\"", "style:text-position=\"0% 100%\""),
            ("caps", "fo:text-transform=\"uppercase\"", "fo:text-transform=\"none\""),
            ("smallCaps", "fo:font-variant=\"small-caps\"", "fo:font-variant=\"normal\""),
            ("textColor", "fo:color=\"#FF0000\"", "fo:color=\"#00FF00\""),
            ("highlightColor", "fo:background-color=\"#FFFF00\"", "fo:background-color=\"#00FFFF\""),
            ("fontSize", "fo:font-size=\"12pt\"", "fo:font-size=\"20pt\""),
            ("fontName", "fo:font-family=\"Georgia\"", "fo:font-family=\"Verdana\""),
        ]
        for (field, a, b) in cases {
            let blocks = try read(
                body: "<text:p><text:span text:style-name=\"A\">A</text:span><text:span text:style-name=\"B\">B</text:span></text:p>",
                automaticStyles: """
                <style:style style:name="A" style:family="text"><style:text-properties \(a)/></style:style>
                <style:style style:name="B" style:family="text"><style:text-properties \(b)/></style:style>
                """)
            guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
            XCTAssertEqual(spans.map(\.text), ["A", "B"],
                           "two runs differing only in \(field) were merged — the second run's \(field) is lost")
        }
    }

    /// `fo:background-color="transparent"` means "no highlight", not black — must resolve to `nil`,
    /// same as the attribute being absent entirely.
    func testTransparentBackgroundColorMeansNoHighlight() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:background-color="transparent"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertNil(spans[0].highlightColor)
    }

    /// `fo:font-size="150%"` is a legal ODF value this reader does NOT resolve (see
    /// `parseTextStyleDecls`'s own doc comment) — must read as unspecified, not as a wrong literal
    /// number.
    func testPercentageFontSizeIsSkippedRatherThanMisread() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Text</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-size="150%"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertNil(spans[0].fontSize)
    }

    func testTextStyleInheritsBoldFromParentAndOverridesItalic() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"Child\">X</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="Parent" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
            <style:style style:name="Child" style:family="text" style:parent-style-name="Parent"><style:text-properties fo:font-style="italic"/></style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "X", bold: true, italic: true)])])
    }

    /// Invariant 30's own required case for the TEXT-family walk: a cycle must not hang, and the
    /// non-cyclic field a style DOES declare (`A`'s own bold) must still survive the aborted walk.
    func testTextStyleParentCycleDoesNotHang() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"A\">X</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="A" style:family="text" style:parent-style-name="B"><style:text-properties fo:font-weight="bold"/></style:style>
            <style:style style:name="B" style:family="text" style:parent-style-name="A"/>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "X", bold: true)])])
    }

    // MARK: Font family SLOTS — ODF's three script types (§20.277-§20.279, table 22)
    //
    // The mapping from a character to one of the three slots lives in `OdfScriptTable` and is tested
    // as a pure function in `OdtFontSlotTests`; what these cases prove is the READER — that the six
    // attributes are read, that each slot inherits on its own, and that a run really is cut where the
    // family it resolves to changes. The fixture-level before/after measurement is over there too.

    /// The feature itself. One style names three different families through the indirect form, and a
    /// run mixing all three writing systems comes back as three spans, each in the family ODF's own
    /// table 22 assigns its characters — Latin letters to `style:font-name`, Hangul to
    /// `style:font-name-asian`, Arabic to `style:font-name-complex`. Before this, all three were
    /// drawn in the LATIN family, which is the defect: the document's Korean face was declared and
    /// never used.
    func testEachScriptTypeIsDrawnInTheFamilyItsOwnSlotDeclares() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Ab가나\u{0627}\u{0628}</text:span></text:p>",
            automaticStyles: """
            <office:font-face-decls>
              <style:font-face style:name="W" svg:font-family="&apos;Latin Face&apos;"/>
              <style:font-face style:name="A" svg:font-family="&apos;Asian Face&apos;"/>
              <style:font-face style:name="C" svg:font-family="&apos;Complex Face&apos;"/>
            </office:font-face-decls>
            <style:style style:name="S" style:family="text">
              <style:text-properties style:font-name="W" style:font-name-asian="A" style:font-name-complex="C"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.text), ["Ab", "가나", "\u{0627}\u{0628}"])
        XCTAssertEqual(spans.map(\.fontName), ["Latin Face", "Asian Face", "Complex Face"])
    }

    /// The same three slots stated in their DIRECT form. Both spellings appear together on one
    /// element in every LibreOffice file, and the western member is `fo:`-prefixed while its two
    /// twins are `style:`-prefixed — a naming asymmetry that defeats any `name + "-asian"` string
    /// building, which is why the reader carries a literal table of pairs.
    func testTheDirectFamilyAttributesFeedTheSameThreeSlots() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">Ab가나\u{0627}</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="Latin Face"
                                     style:font-family-asian="Asian Face"
                                     style:font-family-complex="Complex Face"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.fontName), ["Latin Face", "Asian Face", "Complex Face"])
    }

    /// §20.189, per slot: "Instead of this attribute, the `style:font-name` attribute should be
    /// used" — so where a style writes both spellings of one slot, the indirect one wins. Asserted
    /// on the asian slot specifically, because the latin slot's precedence predates this work and a
    /// test that only covered it would prove nothing about the two new ones.
    func testIndirectFontNameBeatsItsDirectTwinInEverySlot() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">가</text:span></text:p>",
            automaticStyles: """
            <office:font-face-decls>
              <style:font-face style:name="A" svg:font-family="Indirect Asian"/>
            </office:font-face-decls>
            <style:style style:name="S" style:family="text">
              <style:text-properties style:font-name-asian="A" style:font-family-asian="Direct Asian"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Indirect Asian")
    }

    /// Per-slot inheritance, which is the reason the cascade carries three "was it declared" flags
    /// rather than one. A child declaring ONLY the complex family must still inherit its parent's
    /// latin and asian ones — the exact shape two paragraph styles in this repo's own fixtures use
    /// (`List` and `Index` declare complex and nothing else). With a single flag the child's complex
    /// declaration would close the walk and the parent's other two families would vanish.
    func testAStyleDeclaringOnlyTheComplexSlotStillInheritsTheOtherTwo() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"Child\">A가\u{0627}</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="Parent" style:family="text">
              <style:text-properties fo:font-family="Parent Latin" style:font-family-asian="Parent Asian"/>
            </style:style>
            <style:style style:name="Child" style:family="text" style:parent-style-name="Parent">
              <style:text-properties style:font-family-complex="Child Complex"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.fontName), ["Parent Latin", "Parent Asian", "Child Complex"])
    }

    /// The empty-face case, now that there are three slots for it to reach. `<style:font-face
    /// style:name="F" svg:font-family=""/>` used as `style:font-name-complex` is exactly what
    /// `bus-headings.odt` and `tago-tables.odt` write, four times each. It states no typeface, so the
    /// parent's complex family must still inherit through it.
    func testAnEmptyFontFaceInTheComplexSlotDoesNotBlockInheritance() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"Child\">\u{0627}</text:span></text:p>",
            automaticStyles: """
            <office:font-face-decls>
              <style:font-face style:name="F" svg:font-family=""/>
            </office:font-face-decls>
            <style:style style:name="Parent" style:family="text">
              <style:text-properties style:font-family-complex="Parent Complex"/>
            </style:style>
            <style:style style:name="Child" style:family="text" style:parent-style-name="Parent">
              <style:text-properties style:font-name-complex="F"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].fontName, "Parent Complex")
    }

    /// A slot the document never declared states NO OPINION, so it neither starts a piece nor breaks
    /// one: the text rides along in whatever family its neighbours established.
    ///
    /// **This reverses what this test asserted when the slot work first landed, and the reversal was
    /// forced by measurement, so the argument it replaces is recorded here rather than deleted.** The
    /// original position was that an undeclared slot must resolve to the theme's own body font and
    /// never borrow, because borrowing is how Hangul ends up drawn in the face chosen for English
    /// words, and because ODF states the three properties independently with no precedence between
    /// them. Both halves of that are true. What made it untenable is what it costs: `nil` then
    /// compares as a family in its own right, so an undeclared slot "disagrees" with a declared one
    /// at every alternation, and a real 167-character Korean paragraph under a western-only style
    /// went from 2 spans to 50 — `제1항` rendered as 제 / 1 / 항 — which is verbatim the
    /// per-character fragmentation `docs/per-script-font-design.md` §1 exists to prevent, measured on
    /// this codebase at build 625 ms to 5.8 s and display 1.5 s to 34 s.
    ///
    /// What the reversal gives up is narrower than it first appears. Before per-slot fonts existed,
    /// a style declaring only the western family applied it to the WHOLE run, Hangul included — so
    /// riding along is not a new borrowing, it is the behaviour this document already had, and the
    /// invariant-37 answer. And where the borrowed family has no glyphs for the script (the ordinary
    /// case: a Latin face and Korean text), `FontSubstitutionResolver` substitutes a covering face
    /// either way, so what a reader actually sees is nearly unchanged while the span count is not.
    /// The case genuinely given up is a family that COVERS the script but was chosen for a different
    /// one; that is rarer than the paragraph above, and quieter than fragmenting it.
    func testAnUndeclaredSlotRidesAlongWithItsNeighbourRatherThanBreakingTheRun() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">A가</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="Only Latin"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.text), ["A가"])
        XCTAssertEqual(spans[0].fontName, "Only Latin")
    }

    /// The other half of the same rule, and the half that keeps it from being "the western slot
    /// always wins": once the document DOES declare the East Asian slot, the two families disagree
    /// for real and the run breaks exactly where they part. Without this, the fix above would read
    /// as a licence to ignore the asian slot entirely.
    func testTwoDeclaredSlotsNamingDifferentFamiliesStillBreakTheRun() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">A가</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="Only Latin" style:font-family-asian="Some Hangul"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.text), ["A", "가"])
        XCTAssertEqual(spans.map(\.fontName), ["Only Latin", "Some Hangul"])
    }

    /// Invariant 37, asserted rather than argued, and the reason a run breaks on the resolved FAMILY
    /// and not on the slot index: a style that points all three slots at one face cannot produce a
    /// boundary, so a run mixing Latin, Hangul, digits and punctuation stays ONE span — which is what
    /// keeps `제1항` and `2026년` from fragmenting at every alternation in the overwhelmingly common
    /// document that means one typeface.
    func testAStyleNamingOneFamilyForAllThreeSlotsStillProducesOneSpan() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">제1항 2026년 (3) ABC</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="One Face"
                                     style:font-family-asian="One Face"
                                     style:font-family-complex="One Face"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "제1항 2026년 (3) ABC")
        XCTAssertEqual(spans[0].fontName, "One Face")
    }

    /// A table 22 gap — the space at `U+0020` is one, and so is every character in General
    /// Punctuation — never STARTS a piece: it joins the run in progress. Without that a single space
    /// between two Korean words would end one span and begin another, and fragmentation would arrive
    /// through the most common character in the document.
    func testAGapCharacterJoinsTheRunInProgressRatherThanStartingOne() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">가 나 Ab</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="Latin Face" style:font-family-asian="Asian Face"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.text), ["가 나 ", "Ab"])
        XCTAssertEqual(spans.map(\.fontName), ["Asian Face", "Latin Face"])
    }

    /// The same rule ACROSS calls. `text:tab` arrives as its own stretch of text, and every scalar in
    /// it is a gap, so it states no script type at all — emitted verbatim it would strand a lone
    /// theme-font span between two runs of one real family. It takes the neighbour's family instead
    /// and merges away, so the tab between two Korean words is measured in the Korean face.
    func testATabBetweenTwoRunsTakesTheNeighboursFamilyInsteadOfNone() throws {
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">가<text:tab/>나</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="Latin Face" style:font-family-asian="Asian Face"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.text), ["가\t나"])
        XCTAssertEqual(spans[0].fontName, "Asian Face")
    }

    /// Nothing is dropped and nothing is reordered, whatever the split does: concatenating every span
    /// of a run reproduces the run's own text exactly. Exercised on the shapes a naive UTF-16 walk
    /// breaks — an astral pair, a variation-selector emoji, a regional-indicator pair and a ZWJ
    /// sequence — all of which must also stay whole, since a boundary inside one of them would cut a
    /// grapheme cluster in half.
    ///
    /// The combining acute is deliberately on a HANGUL base rather than a Latin one. Table 22 maps
    /// `U+0301` into its latin range, so `A\u{0301}` would hold together even with no cluster floor at
    /// all and would prove nothing; `가\u{0301}` splits the moment the floor is gone, because the base
    /// and its own mark then select two different slots.
    func testEverySpanConcatenatedReproducesTheRunExactly() throws {
        let source = "Ab가\u{0301}\u{20B9F}\u{0627}\u{FE0F}\u{1F1F0}\u{1F1F7}\u{1F468}\u{200D}\u{1F469}!"
        let blocks = try read(
            body: "<text:p><text:span text:style-name=\"S\">\(source)</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="Latin Face"
                                     style:font-family-asian="Asian Face"
                                     style:font-family-complex="Complex Face"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.text).joined(), source)
        XCTAssertFalse(spans.contains { $0.text.isEmpty }, "no piece may be empty")
        XCTAssertTrue(spans.contains { $0.text.contains("가\u{0301}") },
                      "the combining acute belongs to the base it sits on, not to a piece of its own")
    }

    /// Invariant 29: every case above calls `OdtReader.read` itself, which proves the parser and says
    /// nothing about the application reaching it. This one goes through `DocumentTypes.readOffice`,
    /// the single dispatch the app and `--extract` both use, on a document declaring all three slots
    /// and text exercising all three — so a three-slot resolution that worked only when called
    /// directly would fail here.
    func testThreeSlotResolutionSurvivesThroughDocumentTypesReadOffice() throws {
        let zip = buildOdt(content: doc(
            body: "<text:p><text:span text:style-name=\"S\">Ab가나\u{0627}\u{0628}</text:span></text:p>",
            automaticStyles: """
            <style:style style:name="S" style:family="text">
              <style:text-properties fo:font-family="Latin Face"
                                     style:font-family-asian="Asian Face"
                                     style:font-family-complex="Complex Face"/>
            </style:style>
            """))
        let blocks = try DocumentTypes.readOffice(try ZipArchive(data: zip), extension: "odt").blocks
        guard case .paragraph(let spans, _, _, _, _) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans.map(\.fontName), ["Latin Face", "Asian Face", "Complex Face"])
    }

    // MARK: S15 — table-cell styles: background, border

    func testTableCellBackgroundAndBorderApplyFromCellStyle() throws {
        let blocks = try read(
            body: """
            <table:table>
              <table:table-row>
                <table:table-cell table:style-name="Shaded"><text:p>A1</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            """,
            automaticStyles: """
            <style:style style:name="Shaded" style:family="table-cell">
              <style:table-cell-properties fo:background-color="#EEEEEE" fo:border="1pt solid #000000"/>
            </style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        XCTAssertNotNil(cell.backgroundColor)
        XCTAssertEqual(cell.borderWidth, 1)
        XCTAssertNotNil(cell.borderColor)
    }

    /// Only the FIRST side found wins (`Cell`'s own one-uniform-border scope) — `fo:border-top` alone,
    /// with no `fo:border` shorthand, must still contribute something rather than nothing.
    func testAsymmetricBorderTopAloneStillContributesAWidthAndColor() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell table:style-name="TopOnly"><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: """
            <style:style style:name="TopOnly" style:family="table-cell">
              <style:table-cell-properties fo:border-top="2pt solid #123456"/>
            </style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        XCTAssertEqual(cell.borderWidth, 2)
        XCTAssertNotNil(cell.borderColor)
    }

    /// ODF `style:vertical-align` (`middle` → `.center`) and `fo:padding` reach `Cell` — docx parity.
    /// Before this, an odt cell rendered top-aligned with the default 7pt inset no matter what its
    /// style declared, while the docx twin honoured both.
    func testTableCellVerticalAlignAndPaddingApplyFromCellStyle() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell table:style-name="Mid"><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: """
            <style:style style:name="Mid" style:family="table-cell">
              <style:table-cell-properties style:vertical-align="middle" fo:padding="3pt"/>
            </style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        XCTAssertEqual(cell.verticalAlignment, .center)
        XCTAssertEqual(cell.padding, 3)
    }

    /// PAGED per-edge padding (`Cell.edgePadding`): the uniform `fo:padding` shorthand applies to
    /// all four edges when no per-side override is present — ODF's own shorthand-then-override rule.
    func testTableCellEdgePaddingFallsBackToTheUniformShorthandOnEveryEdge() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell table:style-name="Mid"><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: """
            <style:style style:name="Mid" style:family="table-cell">
              <style:table-cell-properties style:vertical-align="middle" fo:padding="3pt"/>
            </style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        let edges = try XCTUnwrap(cell.edgePadding)
        XCTAssertEqual(edges.top, 3); XCTAssertEqual(edges.left, 3)
        XCTAssertEqual(edges.bottom, 3); XCTAssertEqual(edges.right, 3)
    }

    /// A per-side override (`fo:padding-top`) wins over the uniform shorthand for THAT edge only —
    /// the other three still fall back to it.
    func testTableCellEdgePaddingPerSideOverrideWinsForThatEdgeOnly() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell table:style-name="Asym"><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: """
            <style:style style:name="Asym" style:family="table-cell">
              <style:table-cell-properties fo:padding="3pt" fo:padding-top="0pt"/>
            </style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        let edges = try XCTUnwrap(cell.edgePadding)
        XCTAssertEqual(edges.top, 0, "the per-side override must win, and a declared ZERO must survive")
        XCTAssertEqual(edges.left, 3, "every other edge still falls back to the uniform shorthand")
        XCTAssertEqual(edges.bottom, 3)
        XCTAssertEqual(edges.right, 3)
    }

    /// No cell style at all — `edgePadding` stays `nil`, exactly like `padding` above.
    func testTableCellWithNoStyleHasNilEdgePadding() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: "")
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        XCTAssertNil(cell.edgePadding)
    }

    /// ODF `TableFormat.defaultPadding` is table-wide (docx `w:tblCellMar`'s counterpart) and ODF has
    /// no such construct — must stay `nil` even when the cell itself declares padding.
    func testOdtTableFormatNeverPopulatesDefaultPadding() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell table:style-name="Mid"><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: """
            <style:style style:name="Mid" style:family="table-cell">
              <style:table-cell-properties fo:padding="3pt"/>
            </style:style>
            """)
        guard case .table(_, _, _, let format) = blocks[0] else { return XCTFail("expected a table") }
        XCTAssertNil(format.defaultPadding, "ODF has no table-wide cell-margin equivalent to w:tblCellMar")
    }

    /// ODF `style:contextual-spacing` (docx's `w:contextualSpacing`) reaches the paragraph's format,
    /// so the builder can drop the space between adjacent same-style paragraphs. Absent → false.
    func testParagraphContextualSpacingReadsFromStyle() throws {
        let on = try read(
            body: "<text:p text:style-name=\"CS\">A</text:p>",
            automaticStyles: """
            <style:style style:name="CS" style:family="paragraph">
              <style:paragraph-properties style:contextual-spacing="true"/>
            </style:style>
            """)
        guard case .paragraph(_, _, _, _, let f) = on[0] else { return XCTFail("expected a paragraph") }
        XCTAssertTrue(f.contextualSpacing)

        let off = try read(body: "<text:p>A</text:p>")
        guard case .paragraph(_, _, _, _, let f2) = off[0] else { return XCTFail("expected a paragraph") }
        XCTAssertFalse(f2.contextualSpacing)
    }

    /// A cell with no `table:style-name` inherits its column's `table:default-cell-style-name` —
    /// ODF's own spelling of a table-wide default cell look. Before this, such a cell fell straight
    /// to the theme default and ignored the column default the document declared.
    func testTableCellInheritsColumnDefaultCellStyle() throws {
        let blocks = try read(
            body: """
            <table:table>
              <table:table-column table:default-cell-style-name="Bord"/>
              <table:table-row>
                <table:table-cell><text:p>A</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            """,
            automaticStyles: """
            <style:style style:name="Bord" style:family="table-cell">
              <style:table-cell-properties fo:border="2pt solid #ff0000"/>
            </style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        XCTAssertEqual(cell.borderWidth, 2)
        XCTAssertNotNil(cell.borderColor)
    }

    /// ODF `style:tab-stop`'s `style:type` (`right`) and leader (`style:leader-text="."`) reach
    /// `TabStop` — docx parity, so a TOC entry's right-aligned page number and dotted leader are no
    /// longer flattened to a plain left tab with no fill.
    func testTabStopAlignmentAndLeaderApplyFromParagraphStyle() throws {
        let blocks = try read(
            body: """
            <text:p text:style-name="TocEntry">Title\t3</text:p>
            """,
            automaticStyles: """
            <style:style style:name="TocEntry" style:family="paragraph">
              <style:paragraph-properties>
                <style:tab-stops>
                  <style:tab-stop style:position="288pt" style:type="right" style:leader-text="."/>
                </style:tab-stops>
              </style:paragraph-properties>
            </style:style>
            """)
        guard case .paragraph(_, _, _, let tabs, _) = blocks[0], let tab = tabs.first else {
            return XCTFail("expected a paragraph carrying a tab stop")
        }
        XCTAssertEqual(tab.alignment, .right)
        XCTAssertEqual(tab.leader, .dot)
        XCTAssertEqual(tab.position, 288)
    }

    func testTableCellStyleInheritsBackgroundFromParent() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell table:style-name="Child"><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: """
            <style:style style:name="Parent" style:family="table-cell"><style:table-cell-properties fo:background-color="#00FF00"/></style:style>
            <style:style style:name="Child" style:family="table-cell" style:parent-style-name="Parent"/>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        XCTAssertNotNil(cell.backgroundColor)
    }

    /// Invariant 30's own required case for the TABLE-CELL-family walk.
    func testTableCellStyleParentCycleDoesNotHang() throws {
        let blocks = try read(
            body: """
            <table:table><table:table-row>
              <table:table-cell table:style-name="A"><text:p>A</text:p></table:table-cell>
            </table:table-row></table:table>
            """,
            automaticStyles: """
            <style:style style:name="A" style:family="table-cell" style:parent-style-name="B"><style:table-cell-properties fo:background-color="#00FF00"/></style:style>
            <style:style style:name="B" style:family="table-cell" style:parent-style-name="A"/>
            """)
        guard case .table(let rows, _, _, _) = blocks[0], let cell = rows.first?.first else { return XCTFail("expected a table cell") }
        XCTAssertNotNil(cell.backgroundColor)
    }

    // MARK: S15 — table-column widths (table:table-column, previously referenced nowhere)

    func testColumnWidthAppliesFromTableColumnElement() throws {
        let blocks = try read(
            body: """
            <table:table>
              <table:table-column table:style-name="Col1"/>
              <table:table-column table:style-name="Col2"/>
              <table:table-row>
                <table:table-cell><text:p>A</text:p></table:table-cell>
                <table:table-cell><text:p>B</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            """,
            automaticStyles: """
            <style:style style:name="Col1" style:family="table-column"><style:table-column-properties style:column-width="1in"/></style:style>
            <style:style style:name="Col2" style:family="table-column"><style:table-column-properties style:column-width="2in"/></style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0] else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].width, 72)
        XCTAssertEqual(rows[0][1].width, 144)
    }

    /// The running column-position counter must advance past a COLUMN SPAN (not just one column per
    /// cell element), or every width after a merge would land on the wrong column.
    func testColumnWidthAlignsCorrectlyAcrossAColumnSpan() throws {
        let blocks = try read(
            body: """
            <table:table>
              <table:table-column table:style-name="Col1"/>
              <table:table-column table:style-name="Col2"/>
              <table:table-column table:style-name="Col3"/>
              <table:table-row>
                <table:table-cell table:number-columns-spanned="2"><text:p>Wide</text:p></table:table-cell>
                <table:covered-table-cell/>
                <table:table-cell><text:p>Next</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            """,
            automaticStyles: """
            <style:style style:name="Col1" style:family="table-column"><style:table-column-properties style:column-width="1in"/></style:style>
            <style:style style:name="Col2" style:family="table-column"><style:table-column-properties style:column-width="1in"/></style:style>
            <style:style style:name="Col3" style:family="table-column"><style:table-column-properties style:column-width="3in"/></style:style>
            """)
        guard case .table(let rows, _, _, _) = blocks[0] else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].width, 72)
        XCTAssertEqual(rows[0][1].width, 216)
    }

    func testUnstyledTableColumnLeavesWidthNilForAutoLayout() throws {
        let blocks = try read(body: """
        <table:table><table:table-row><table:table-cell><text:p>A</text:p></table:table-cell></table:table-row></table:table>
        """)
        guard case .table(let rows, _, _, _) = blocks[0] else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].width)
    }

    // MARK: S15 — document default body font size (style:default-style, family paragraph)

    func testDocumentDefaultBodyFontSizeReadsFromDefaultStyle() throws {
        let zip = buildOdt(content: doc(body: "<text:p>X</text:p>"), styles: """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles>
          <office:styles>
            <style:default-style style:family="paragraph">
              <style:text-properties fo:font-size="13pt"/>
            </style:default-style>
          </office:styles>
        </office:document-styles>
        """)
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(OdtReader.documentDefaultBodyFontSize(archive), 13)
    }

    func testDocumentDefaultBodyFontSizeFallsBackTo11WhenAbsent() throws {
        let zip = buildOdt(content: doc(body: "<text:p>X</text:p>"))
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(OdtReader.documentDefaultBodyFontSize(archive), 11)
    }

    func testDocumentDefaultBodyFontSizeReturns11ForAnArchiveWithNoContentXML() throws {
        let archive = try ZipArchive(data: buildZip([("styles.xml", Data("<x/>".utf8))]))
        XCTAssertEqual(OdtReader.documentDefaultBodyFontSize(archive), 11)
    }

    // MARK: S15 — a real read path exercising this sprint's own features (invariant 29)

    func testS15FeaturesSurviveThroughDocumentTypesReadOfficeNotJustOdtReaderDirectly() throws {
        let zip = buildOdt(content: doc(
            body: """
            <table:table>
              <table:table-column table:style-name="Col1"/>
              <table:table-row>
                <table:table-cell table:style-name="Shaded"><text:p text:style-name="Centered">Cell text</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            """,
            automaticStyles: """
            <style:style style:name="Col1" style:family="table-column"><style:table-column-properties style:column-width="1in"/></style:style>
            <style:style style:name="Shaded" style:family="table-cell"><style:table-cell-properties fo:background-color="#EEEEEE"/></style:style>
            <style:style style:name="Centered" style:family="paragraph"><style:paragraph-properties fo:text-align="center"/></style:style>
            """))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocumentTypes.readOffice(archive, extension: "odt").blocks
        guard case .table(let rows, _, _, _) = blocks.first, let cell = rows.first?.first else {
            return XCTFail("expected a table with a cell")
        }
        XCTAssertEqual(cell.width, 72)
        XCTAssertNotNil(cell.backgroundColor)
        guard case .paragraph(_, _, let alignment, _, _) = cell.blocks.first else {
            return XCTFail("expected a paragraph in the cell")
        }
        XCTAssertEqual(alignment, .center)
    }

    // MARK: P4 — paragraph cascade (spacing/indent/line-height), run props, table grid ratios

    /// The cm→pt/in→pt/pt→pt length helper (already shared with every other ODF length in this
    /// reader) AND the nearest-declaration-wins parent-style-name cascade, exercised together: `Base`
    /// declares the box-model properties, `Child` (based on `Base`) only adds line-height — the
    /// spacing/indent must still resolve from the PARENT, not go missing just because the paragraph's
    /// own style is `Child`.
    func testParagraphSpacingIndentAndLineHeightCascadeThroughParentStyle() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Child\">Text</text:p>",
            automaticStyles: """
            <style:style style:name="Base" style:family="paragraph">
              <style:paragraph-properties fo:margin-top="0.2cm" fo:margin-bottom="6pt" fo:text-indent="0.18in"/>
            </style:style>
            <style:style style:name="Child" style:family="paragraph" style:parent-style-name="Base">
              <style:paragraph-properties fo:line-height="150%"/>
            </style:style>
            """)
        guard case .paragraph(_, _, _, _, let format) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.spacingBefore ?? -1, 0.2 * 72 / 2.54, accuracy: 0.001) // 0.2cm
        XCTAssertEqual(format.spacingAfter, 6) // 6pt, already points
        XCTAssertEqual(format.firstLineIndent ?? -1, 0.18 * 72, accuracy: 0.001) // 0.18in, positive → first-line
        XCTAssertNil(format.hangingIndent)
        XCTAssertEqual(format.lineHeight, .multiple(1.5))
    }

    /// ODF's own hanging-indent spelling: a NEGATIVE `fo:text-indent` becomes `hangingIndent`
    /// (positive magnitude), never `firstLineIndent`, and the two stay mutually exclusive.
    func testNegativeTextIndentBecomesHangingIndentNotFirstLineIndent() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Hang\">Text</text:p>",
            automaticStyles: """
            <style:style style:name="Hang" style:family="paragraph">
              <style:paragraph-properties fo:text-indent="-0.25in"/>
            </style:style>
            """)
        guard case .paragraph(_, _, _, _, let format) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertNil(format.firstLineIndent)
        XCTAssertEqual(format.hangingIndent ?? -1, 0.25 * 72, accuracy: 0.001)
    }

    /// An absolute `fo:line-height` (a LENGTH, not a percentage) resolves to `.exact`, and
    /// `style:line-height-at-least` (only consulted when `fo:line-height` itself is absent) to
    /// `.atLeast` — the third `LineHeight` case this sprint's brief calls out.
    func testAbsoluteLineHeightAndLineHeightAtLeast() throws {
        let exact = try read(
            body: "<text:p text:style-name=\"Exact\">Text</text:p>",
            automaticStyles: """
            <style:style style:name="Exact" style:family="paragraph">
              <style:paragraph-properties fo:line-height="18pt"/>
            </style:style>
            """)
        guard case .paragraph(_, _, _, _, let exactFormat) = exact[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(exactFormat.lineHeight, .exact(18))

        let atLeast = try read(
            body: "<text:p text:style-name=\"AtLeast\">Text</text:p>",
            automaticStyles: """
            <style:style style:name="AtLeast" style:family="paragraph">
              <style:paragraph-properties style:line-height-at-least="20pt"/>
            </style:style>
            """)
        guard case .paragraph(_, _, _, _, let atLeastFormat) = atLeast[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(atLeastFormat.lineHeight, .atLeast(20))
    }

    /// `style:paragraph-properties/@fo:background-color` (paragraph SHADING) must land on
    /// `ParagraphFormat.shading`, and must NOT be conflated with a `text:span`'s OWN
    /// `style:text-properties/@fo:background-color` (RUN highlight, `Span.highlightColor`) even
    /// though the two share the exact same attribute name — this is the distinction the sprint brief
    /// calls out by name. `fo:border`'s width/colour land on `ParagraphFormat.borderColor`/
    /// `borderWidth`.
    func testParagraphShadingAndBorderAreDistinctFromRunHighlight() throws {
        let blocks = try read(
            body: """
            <text:p text:style-name="Shaded"><text:span text:style-name="Marked">hi</text:span></text:p>
            """,
            automaticStyles: """
            <style:style style:name="Shaded" style:family="paragraph">
              <style:paragraph-properties fo:background-color="#FFCC00" fo:border="0.5pt solid #000000"/>
            </style:style>
            <style:style style:name="Marked" style:family="text">
              <style:text-properties fo:background-color="#00FF00"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, let format) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.shading, odfColor("FFCC00"))
        XCTAssertEqual(format.borderColor, odfColor("000000"))
        XCTAssertEqual(format.borderWidth, 0.5)
        XCTAssertEqual(spans[0].highlightColor, odfColor("00FF00"))
        XCTAssertNotEqual(format.shading, spans[0].highlightColor)
    }

    /// `style:text-underline-type="double"` wins over the dotted/dashed/wavy `style:text-underline-
    /// style` reading; `fo:text-transform="uppercase"` → `Span.caps`; `fo:font-variant="small-caps"`
    /// → `Span.smallCaps`.
    func testRunUnderlineTypeDoubleCapsAndSmallCaps() throws {
        let blocks = try read(
            body: """
            <text:p><text:span text:style-name="Fancy">shout</text:span></text:p>
            """,
            automaticStyles: """
            <style:style style:name="Fancy" style:family="text">
              <style:text-properties style:text-underline-style="solid" style:text-underline-type="double"
                fo:text-transform="uppercase" fo:font-variant="small-caps"/>
            </style:style>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(spans[0].underlineStyle, .double)
        XCTAssertTrue(spans[0].caps)
        XCTAssertTrue(spans[0].smallCaps)
    }

    /// `style:rel-column-width` ("N*") is ODF's own proportion-native column width — fed into
    /// `OfficeBlock.table.columnWidths` so `TableBlockBuilder` fills the table proportionally
    /// (1:3 → 25%/75%) instead of falling back to its equal-ish auto layout.
    func testRelativeColumnWidthsFeedTableGridColumnWidthsAsAProportion() throws {
        let blocks = try read(
            body: """
            <table:table>
              <table:table-column table:style-name="Narrow"/>
              <table:table-column table:style-name="Wide"/>
              <table:table-row>
                <table:table-cell><text:p>A</text:p></table:table-cell>
                <table:table-cell><text:p>B</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            """,
            automaticStyles: """
            <style:style style:name="Narrow" style:family="table-column"><style:table-column-properties style:rel-column-width="1*"/></style:style>
            <style:style style:name="Wide" style:family="table-column"><style:table-column-properties style:rel-column-width="3*"/></style:style>
            """)
        guard case .table(_, _, let columnWidths, _) = blocks[0] else { return XCTFail("expected a table") }
        XCTAssertEqual(columnWidths, [1, 3])
    }

    /// A grid where only SOME columns resolve a width must not partially apply — `[]` (auto layout),
    /// mirroring `DocxReader.tableGridColumnWidths`'s own "never partially apply an untrustworthy
    /// grid" posture.
    func testPartiallyUnstyledColumnGridFallsBackToEmptyColumnWidths() throws {
        let blocks = try read(
            body: """
            <table:table>
              <table:table-column table:style-name="Styled"/>
              <table:table-column/>
              <table:table-row>
                <table:table-cell><text:p>A</text:p></table:table-cell>
                <table:table-cell><text:p>B</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            """,
            automaticStyles: """
            <style:style style:name="Styled" style:family="table-column"><style:table-column-properties style:rel-column-width="1*"/></style:style>
            """)
        guard case .table(_, _, let columnWidths, _) = blocks[0] else { return XCTFail("expected a table") }
        XCTAssertEqual(columnWidths, [])
    }

    /// A document that declares NONE of P4's new attributes renders byte-identical to before this
    /// sprint — `ParagraphFormat()`'s all-`nil` default, `Span`'s default `.single`/`false`/`false`,
    /// and `columnWidths: []` (the pre-P4 return value in every case that isn't this sprint's own new
    /// tests) are exactly what an untouched document already produced.
    func testUndeclaredP4AttributesLeaveEveryFieldAtItsPreP4Default() throws {
        let blocks = try read(body: "<text:p>Plain text</text:p>")
        guard case .paragraph(let spans, _, _, _, let format) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format, ParagraphFormat())
        XCTAssertEqual(spans[0].underlineStyle, .single)
        XCTAssertFalse(spans[0].caps)
        XCTAssertFalse(spans[0].smallCaps)
    }
    // MARK: Bold/italic declared by the PARAGRAPH style (a heading's weight lives there)

    /// ODF puts a heading's weight on its `style:family="paragraph"` style's own
    /// `style:text-properties` — `Heading_20_1` carries `fo:font-weight="bold"` and no text-family
    /// style is involved. Reading only the text family reported every such heading as not bold;
    /// measured on this repo's own fixtures, 32 heading characters across `notes.odt`, `embed.odt`
    /// and `giant-table.odt` rendered a weight lighter than LibreOffice draws them. The docx twin of
    /// this gap is `DocxReader.resolvedBold`.
    func testBoldDeclaredByTheParagraphStyleReachesTheRun() throws {
        let styles = """
        <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0">
          <office:styles>
            <style:style style:name="Heading_20_1" style:family="paragraph" style:default-outline-level="1">
              <style:text-properties fo:font-weight="bold"/>
            </style:style>
          </office:styles>
        </office:document-styles>
        """
        let content = """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text>
            <text:h text:style-name="Heading_20_1" text:outline-level="1">제목</text:h>
          </office:text></office:body>
        </office:document-content>
        """
        let archive = try ZipArchive(data: buildOdt(content: content, styles: styles))
        let blocks = try OdtReader.read(archive).blocks
        guard case let .heading(_, spans, _, _, _, _) = blocks.first else {
            return XCTFail("expected a heading, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(spans.first?.bold, true,
                       "the run declares no style of its own — its bold must come from Heading_20_1")
    }

}
