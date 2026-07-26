import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import FastDocReader

/// S4: the wire-up from office bytes (`.docx`, `.odt`) to an open, read-only window.
/// `DocxReader`/`OdtReader`/`ZipArchive`/`OfficeTextBuilder` are already proven pure elsewhere
/// (`DocxReaderTests`, `OdtReaderTests`, `ZipArchiveTests`) — this file is about
/// `MarkdownDocument`/`DocumentTypes` routing them correctly and the edit surface staying shut,
/// the same shape `SpliceRenderTests` uses to drive a document directly. `DocumentTypes.readOffice`
/// is the seam this file exists to guard: `.odt` once shipped registered (reachable to the app,
/// `DocumentTypes.kind`/Info.plist both correct) but unreachable to its own parser, because every
/// call site still hard-coded `DocxReader.read` — a bug every `OdtReaderTests` case, which calls
/// `OdtReader.read` directly, was structurally unable to catch. These tests go through
/// `MarkdownDocument.read(from:ofType:)` itself for that reason.
final class OfficeDocumentTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory (same shape as
    // `DocxReaderTests`, duplicated here so this file stays a self-contained unit).

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
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

    private let headingStyles = """
    <?xml version="1.0" encoding="UTF-8"?><w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
    </w:styles>
    """

    /// One heading + one paragraph — enough to exercise the outline sidebar (`MDAttr.heading`) and
    /// the body text path in the same fixture.
    private func fixtureDocx() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>
          <w:p><w:r><w:t>Body text.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(headingStyles.utf8)),
        ])
    }

    /// A minimal real `.odt` body — a heading and a paragraph, enough to prove `OdtReader` (not
    /// `DocxReader`) parsed it: feeding this `content.xml` to `DocxReader` (which looks for
    /// `word/document.xml`'s `w:document`/`w:body`) finds nothing and throws, so a dispatch bug
    /// that routes `.odt` through `DocxReader` fails this fixture rather than silently mis-parsing it.
    private func fixtureOdt() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <text:h text:outline-level="1">ODT Title</text:h>
            <text:p>ODT body text.</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        return buildZip([("content.xml", Data(content.utf8))])
    }

    /// S7 invariant 29: a `Cell`-shape change (spans → blocks) must be proven through the same real
    /// dispatch table every other office capability is, not only through `DocxReaderTests`/
    /// `OfficeTextBuilderTests` calling their parser/builder directly — this is that seam for tables.
    private func fixtureDocxWithTable() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    /// S8 invariant 29: an image inside a table cell (gap-list row 6) must reach `doc.officeBlocks`
    /// through the SAME real dispatch table `fixtureDocxWithTable()` above already proves for plain
    /// cell text — not only through `DocxReaderTests`, which calls `DocxReader.read` directly.
    private func fixtureDocxWithTableImage() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:tbl><w:tr><w:tc><w:p><w:r>
            <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
              <a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId1"/></pic:blipFill></pic:pic></a:graphicData></a:graphic>
            </wp:inline></w:drawing>
          </w:r></w:p></w:tc></w:tr></w:tbl>
        </w:body></w:document>
        """
        let rels = "<Relationships xmlns=\"x\"><Relationship Id=\"rId1\" Type=\"x\" Target=\"media/image1.png\"/></Relationships>"
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data(rels.utf8)),
        ])
    }

    /// S10 invariant 29: a display equation (`m:oMathPara`) must reach `doc.officeBlocks` — AND the
    /// rendered text storage as a web block `MarkdownDocument`'s pre-render pass can find — through
    /// the real `MarkdownDocument.read` dispatch, not only through `DocxReaderTests`/
    /// `OfficeTextBuilderTests` calling the parser/builder directly.
    private func fixtureDocxWithFormula() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><m:oMathPara><m:oMath><m:r><m:t>x^2</m:t></m:r></m:oMath></m:oMathPara></w:p>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    /// S12 invariant 29: an RTL-marked paragraph must reach the RENDERED text storage's
    /// `NSParagraphStyle.baseWritingDirection` through the real `MarkdownDocument.read` dispatch —
    /// a parser-only test (`DocxReaderTests`) proves `OfficeBlock.paragraph`'s `rtl` field, not that
    /// it actually reaches `OfficeTextBuilder.build`'s output through this document's own pipeline.
    private func fixtureDocxWithBidiParagraph() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:bidi/></w:pPr><w:r><w:t>\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    private func fixtureOdtWithTableImage() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <table:table><table:table-row><table:table-cell>
              <text:p><draw:frame svg:width="72pt" svg:height="72pt">
              <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
            </table:table-cell></table:table-row></table:table>
          </office:text></office:body>
        </office:document-content>
        """
        return buildZip([("content.xml", Data(content.utf8)), ("Pictures/photo.png", Data([0x01]))])
    }

    /// Opens a fixture office document through the real document/window pipeline, mirroring how
    /// `SpliceRenderTests.open` drives markdown/plain-text. `ext`/`uti` select which office format
    /// the fixture pretends to be, exactly the two pieces of information `MarkdownDocument` itself
    /// has to work with (a file extension on disk, a UTI from the system) — using `docx` for both
    /// wherever the extension didn't matter for a given test would silently exercise only one path.
    private func openOffice(_ data: Data, ext: String = "docx", uti: String = "org.openxmlformats.wordprocessingml.document") throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-fixture-\(UUID().uuidString).\(ext)")
        try doc.read(from: data, ofType: uti)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    private func headingLevels(_ storage: NSTextStorage) -> [Int] {
        var levels: [Int] = []
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let level = v as? Int { levels.append(level) }
        }
        return levels
    }

    // MARK: Extension → kind

    func testExtensionResolvesToKind() {
        XCTAssertEqual(DocumentTypes.kind(forExtension: "docx"), .office)
        XCTAssertEqual(DocumentTypes.kind(forExtension: "DOCX"), .office)   // case-insensitive, like the others
        XCTAssertEqual(DocumentTypes.kind(forExtension: "txt"), .plainText)
        XCTAssertEqual(DocumentTypes.kind(forExtension: "md"), .markdown)
    }

    func testOpensInAppIncludesDocx() {
        XCTAssertTrue(DocumentTypes.opensInApp("docx"))
    }

    // MARK: Reading a fixture

    func testReadingFixtureProducesNonEmptyTextWithMatchingHeadingLevels() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertFalse(storage.string.isEmpty)
        XCTAssertTrue(storage.string.contains("Title"))
        XCTAssertTrue(storage.string.contains("Body text."))
        XCTAssertEqual(headingLevels(storage), [1])
        // `text` stays empty — an office document has no editable source (invariant checked by
        // `data(ofType:)` below); the rendered string comes from `officeBlocks` alone.
        XCTAssertEqual(doc.text, "")
        XCTAssertEqual(doc.officeBlocks.count, 2)
    }

    /// S7 invariant 29: `Cell` changing from `spans: [Span]` to `blocks: [OfficeBlock]` must still
    /// let a table cell's text reach the rendered document through `MarkdownDocument.read` +
    /// `render(into:)` — not just through `DocxReaderTests`/`OfficeTextBuilderTests`, which call the
    /// parser/builder directly and would not have caught a dispatch-level regression.
    func testTableCellTextReachesTheRenderedDocumentThroughTheFullReadPath() throws {
        let (_, wc) = try openOffice(fixtureDocxWithTable())
        let storage = try XCTUnwrap(wc.textStorageRef)
        // A table now renders as a REAL `NSTextTable`, so its cell text is ordinary — selectable,
        // copyable, searchable — text in the top-level storage string, not hidden inside a drawn
        // attachment. It reaches the rendered document simply by being in that string.
        XCTAssertTrue(storage.string.contains("Cell A"), "cell text must reach the rendered document")
        // And it really is inside an NSTextTable cell (a paragraph carrying an `NSTextTableBlock`),
        // not just loose text — proving the table structure survived the full read + render path.
        let ns = storage.string as NSString
        let cellLoc = ns.range(of: "Cell A").location
        let ps = storage.attribute(.paragraphStyle, at: cellLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(ps?.textBlocks.first is NSTextTableBlock, "the cell text sits in a real NSTextTable cell")
    }

    /// S8 invariant 29 (docx): an image inside a table cell must reach `doc.officeBlocks` through
    /// `MarkdownDocument.read` itself, not only `DocxReader.read` called directly.
    func testTableCellImageReachesOfficeBlocksThroughTheFullReadPathDocx() throws {
        let (doc, _) = try openOffice(fixtureDocxWithTableImage())
        guard case .table(let rows, _, _, _) = doc.officeBlocks.first else { return XCTFail("expected a table block") }
        let cellBlocks = rows.first?.first?.blocks ?? []
        XCTAssertTrue(cellBlocks.contains { if case .image = $0 { return true }; return false },
                      "the cell's image must survive the full read path, not just DocxReader.read directly")
    }

    /// S8 invariant 29 (odt): same guard, `OdtReader` side.
    func testTableCellImageReachesOfficeBlocksThroughTheFullReadPathOdt() throws {
        let (doc, _) = try openOffice(fixtureOdtWithTableImage(), ext: "odt", uti: "org.oasis-open.opendocument.text")
        guard case .table(let rows, _, _, _) = doc.officeBlocks.first else { return XCTFail("expected a table block") }
        let cellBlocks = rows.first?.first?.blocks ?? []
        XCTAssertTrue(cellBlocks.contains { if case .image = $0 { return true }; return false },
                      "the cell's image must survive the full read path, not just OdtReader.read directly")
    }

    /// S10 invariant 29: an office equation must reach both `doc.officeBlocks` (`.formula`) and the
    /// SAME `enumerateWebBlocks` seam `MarkdownDocument.prerenderAllDiagrams`/`presizeKnownMedia`
    /// use, through the real read path — a parser-only test (`DocxReaderTests`) cannot see whether
    /// the attribute actually reaches the text storage `OfficeTextBuilder.build` produces.
    func testFormulaReachesOfficeBlocksAndTheWebBlockSeamThroughTheFullReadPath() throws {
        let (doc, wc) = try openOffice(fixtureDocxWithFormula())
        XCTAssertTrue(doc.officeBlocks.contains { if case .formula = $0 { return true }; return false },
                      "the equation must survive the full read path, not just DocxReader.read directly")
        let storage = try XCTUnwrap(wc.textStorageRef)
        var found: [WebBlock] = []
        storage.enumerateWebBlocks { block, _ in found.append(block) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.engine, .math)
        XCTAssertEqual(found.first?.code, "x^2")
    }

    /// S12 invariant 29: the RTL-marked block reaches the rendered document's OWN paragraph style,
    /// not just `DocxReader`'s parsed output.
    func testRTLParagraphReachesRenderedDocumentThroughTheFullReadPath() throws {
        let (doc, wc) = try openOffice(fixtureDocxWithBidiParagraph())
        XCTAssertTrue(doc.officeBlocks.contains {
            if case .paragraph(_, let rtl, _, _, _) = $0 { return rtl }
            return false
        })
        let storage = try XCTUnwrap(wc.textStorageRef)
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft)
    }

    func testMalformedArchiveThrowsRatherThanProducingAnEmptyDocument() {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-garbage.docx")
        XCTAssertThrowsError(try doc.read(from: Data([0x00, 0x01, 0x02, 0x03]),
                                          ofType: "org.openxmlformats.wordprocessingml.document"))
    }

    // MARK: `.odt` reaches its OWN reader through the real document/window pipeline — the
    // regression this file exists for. Before this fix, `read(from:)` and `reloadDocument` both
    // hard-coded `DocxReader.read`, so `.odt` was registered (reachable to the app) but never
    // reachable to `OdtReader` — every `OdtReaderTests` case, calling `OdtReader.read` directly,
    // was green throughout and proved nothing about this seam.

    func testReadingOdtFixtureThroughMarkdownDocumentGoesThroughOdtReaderNotDocxReader() throws {
        let (doc, wc) = try openOffice(fixtureOdt(), ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("ODT Title"))
        XCTAssertTrue(storage.string.contains("ODT body text."))
        XCTAssertEqual(headingLevels(storage), [1])
    }

    func testMalformedOdtArchiveThrowsRatherThanFallingBackToDocxParsing() {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-garbage.odt")
        XCTAssertThrowsError(try doc.read(from: Data([0x00, 0x01, 0x02, 0x03]),
                                          ofType: "org.oasis-open.opendocument.text"))
    }

    /// The dispatch table itself, one level below the full document pipeline: each registered
    /// office extension must reach its OWN parser, and an extension with no registered parser must
    /// throw rather than silently falling through to `DocxReader` (the exact shape of bug this
    /// whole file guards against, isolated to the one function responsible for the routing).
    func testDocumentTypesReadOfficeRoutesEachExtensionToItsOwnReaderAndRejectsUnhandledOnes() throws {
        let docxBlocks = try DocumentTypes.readOffice(try ZipArchive(data: fixtureDocx()), extension: "docx").blocks
        XCTAssertFalse(docxBlocks.isEmpty)
        let odtBlocks = try DocumentTypes.readOffice(try ZipArchive(data: fixtureOdt()), extension: "odt").blocks
        XCTAssertFalse(odtBlocks.isEmpty)
        XCTAssertThrowsError(try DocumentTypes.readOffice(try ZipArchive(data: fixtureDocx()), extension: "rtf"))
    }

    /// The headless `--extract` seam end to end at the library level: bytes → the SAME dispatch the
    /// app uses (`DocumentTypes.readOffice`) → `OfficeMarkdownSerializer`. A pure serializer unit test
    /// (`OfficeMarkdownSerializerTests`) can't prove the reader actually FEEDS the serializer — this
    /// does, through the real dispatch, for both docx and odt (invariant 29's lesson).
    func testHeadlessExtractSerializesThroughTheRealOfficeDispatch() throws {
        let cases: [(data: Data, ext: String, heading: String, body: String)] = [
            (fixtureDocx(), "docx", "# Title", "Body text."),
            (fixtureOdt(), "odt", "# ODT Title", "ODT body text."),
        ]
        for c in cases {
            let blocks = try DocumentTypes.readOffice(try ZipArchive(data: c.data), extension: c.ext).blocks
            let markdown = OfficeMarkdownSerializer.serialize(blocks)
            XCTAssertTrue(markdown.contains(c.heading), "\(c.ext): heading must extract as `\(c.heading)` — got:\n\(markdown)")
            XCTAssertTrue(markdown.contains(c.body), "\(c.ext): body paragraph must survive")
        }
    }

    // MARK: Re-render, not a cached string

    func testRenderedResultChangesWithThemeFontSize() throws {
        let (doc, _) = try openOffice(fixtureDocx())
        // `render(into:)` calls `OfficeTextBuilder.build(officeBlocks, theme:)` fresh every time —
        // this is the storage the document keeps for that to be possible at all. Rebuilding it
        // directly at two theme sizes is the deterministic form of "a font-size change reflows the
        // document": if `officeBlocks` had been discarded in favor of a cached finished string,
        // there would be nothing here to rebuild from.
        let small = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: 14))
        let large = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: 28))
        let fontSmall = try XCTUnwrap(small.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let fontLarge = try XCTUnwrap(large.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(fontLarge.pointSize, fontSmall.pointSize,
                             "a font-size change must re-run OfficeTextBuilder.build, not redraw a cached string")
    }

    /// S13 invariant 29: `MarkdownDocument`'s own `render(into:)` is the ONE place that knows the
    /// document's `officeDefaultBodyFontSize` (set via `setOfficeContent`) and the user's
    /// `FontSizeStore` size both exist and must be combined — `OfficeTextBuilderTests` proves the
    /// SCALING MATH in isolation, but not that `MarkdownDocument` actually wires its own stored
    /// `documentDefaultFontSize` into that call, which is exactly the kind of seam a parser-only or
    /// builder-only test cannot see (no reader sets this field yet, so this drives the document
    /// directly via `setOfficeContent`, the same seam `OfficeImageLoadingTests` uses for images).
    func testDocumentDefaultBodyFontSizeReachesTheRenderedTextThroughMarkdownDocumentsOwnRenderPath() throws {
        var body = Span(text: "Body"); body.fontSize = 11
        let blocks: [OfficeBlock] = [.paragraph(spans: [body])]
        let archive = try ZipArchive(data: buildZip([("word/document.xml", Data())]))

        let userSize: CGFloat = 22 // FontSizeStore.size stand-in, applied via RenderTheme.current below
        let originalSize = FontSizeStore.size
        FontSizeStore.size = userSize
        defer { FontSizeStore.size = originalSize }

        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-fontsize-fixture-\(UUID().uuidString).docx")
        // documentDefaultFontSize: 11 → scale == userSize/11 == 2, so the 11pt authored run must
        // render at exactly 22pt — a value that could ONLY come from `render(into:)` actually
        // passing `officeDefaultBodyFontSize` through, not from `OfficeTextBuilder.build`'s own
        // 11pt fallback default (which would produce the SAME 22pt here by coincidence at this
        // particular size — so this also asserts against a DIFFERENT default, 8pt, below, where the
        // two would diverge if the real value weren't actually wired through).
        doc.setOfficeContent(blocks: blocks, archive: archive, defaultBodyFontSize: 8)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // scale = 22/8 = 2.75; 11 * 2.75 = 30.25 → rounds to 30.
        XCTAssertEqual(font.pointSize, 30,
                       "render(into:) must use the DOCUMENT's own default (8), not OfficeTextBuilder's 11pt fallback")
    }

    /// Invariant 29 applied to the GRAPHIC scale: `OfficeTextBuilderTests` proves the builder honours
    /// `graphicScale`, which says nothing about whether `render(into:)` computes it from the
    /// document's own `officePageContentWidth` and passes it — the exact seam where a working
    /// mechanism sits unreachable. Drives the REAL render path, and asserts the two scales stay
    /// SEPARATE: a 2.5× reading-size change must move the text and leave the picture untouched.
    ///
    /// The window frame is deliberately NOT changed after `makeWindowControllers()` — graphic sizes
    /// freeze at build time (invariant 1/11), so the column is read from the container that produced
    /// them rather than assumed, and the expectation is derived from that same column.
    func testRenderScalesOfficeGraphicsByPageWidthAndLeavesThemUntouchedByFontSize() throws {
        let declared = CGSize(width: 100, height: 50)
        let pageWidth: CGFloat = 400
        let original = FontSizeStore.size
        defer { FontSizeStore.size = original }

        func renderOnce(readingSize: CGFloat) throws -> (image: CGSize, column: CGFloat, font: CGFloat) {
            FontSizeStore.size = readingSize
            let doc = MarkdownDocument()
            doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-graphicscale-\(UUID().uuidString).docx")
            doc.setOfficeContent(blocks: [.paragraph(spans: [Span(text: "Body")]),
                                          .image(id: "pic", size: declared)],
                                 archive: nil, defaultBodyFontSize: 10, pageContentWidth: pageWidth)
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
            let storage = try XCTUnwrap(wc.textStorageRef)
            let column = try XCTUnwrap(wc.textView.textContainer?.size.width)
            var reserved: CGSize?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let cell = (value as? NSTextAttachment)?.attachmentCell as? SizedAttachmentCell {
                    reserved = cell.reservedSize
                }
            }
            let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            return (try XCTUnwrap(reserved), column, font.pointSize)
        }

        let small = try renderOnce(readingSize: 12)
        let large = try renderOnce(readingSize: 30)

        // The page-proportional size: the picture holds the share of the column it held of the page.
        XCTAssertGreaterThan(small.column, 1, "the reading column must be real before graphics freeze")
        XCTAssertEqual(small.image.width, declared.width * (small.column / pageWidth), accuracy: 0.5,
                       "render(into:) must divide the reading column by the document's OWN page width")
        XCTAssertEqual(small.image.height, declared.height * (small.column / pageWidth), accuracy: 0.5)
        XCTAssertNotEqual(small.image.width, declared.width, accuracy: 0.5,
                          "a graphicScale of 1 here would mean render never wired the page width through")

        // …and it is a TEXT setting that must not touch it.
        XCTAssertEqual(large.column, small.column, accuracy: 0.5, "same window ⇒ same column")
        XCTAssertEqual(large.image, small.image, "⌘+/⌘− must never resize a picture")
        XCTAssertGreaterThan(large.font, small.font,
                             "⌘+/⌘− must still resize office TEXT — fusing the two scales killed this")
    }

    /// Resizing the WINDOW must resize the pictures with it. A graphic holds the share of the reading
    /// column it held of the source page, so a wider column means a bigger picture — without this the
    /// text re-wrapped and the tables re-filled while the images stayed frozen at their build width.
    ///
    /// Also asserts the reflow result MATCHES what a rebuild at that width produces: two code paths
    /// computing a size independently is how a resized document drifts away from a reopened one.
    func testResizingTheWindowResizesOfficeGraphicsProportionally() throws {
        let declared = CGSize(width: 100, height: 50)
        let pageWidth: CGFloat = 400
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-resize-\(UUID().uuidString).docx")
        doc.setOfficeContent(blocks: [.paragraph(spans: [Span(text: "Body")]),
                                      .image(id: "pic", size: declared)],
                             archive: nil, defaultBodyFontSize: 10, pageContentWidth: pageWidth)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)

        func imageSize() throws -> CGSize {
            var found: CGSize?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                if let att = v as? NSTextAttachment { found = att.bounds.size }
            }
            return try XCTUnwrap(found)
        }
        func reservedSize() throws -> CGSize {
            var found: CGSize?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                if let cell = (v as? NSTextAttachment)?.attachmentCell as? SizedAttachmentCell { found = cell.reservedSize }
            }
            return try XCTUnwrap(found)
        }

        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 700, height: 600), display: false)
        wc.updateTextInset()
        let narrowColumn = try XCTUnwrap(wc.textView.textContainer?.size.width)
        let narrow = try imageSize()

        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1300, height: 600), display: false)
        wc.updateTextInset()
        let wideColumn = try XCTUnwrap(wc.textView.textContainer?.size.width)
        let wide = try imageSize()

        XCTAssertGreaterThan(wideColumn, narrowColumn, "the test must actually widen the reading column")
        XCTAssertEqual(wide.width / narrow.width, wideColumn / narrowColumn, accuracy: 0.02,
                       "a picture must grow in the same proportion as the column")
        XCTAssertEqual(wide.width, declared.width * (wideColumn / pageWidth), accuracy: 0.5)
        XCTAssertEqual(try reservedSize(), wide,
                       "the reserved layout size must move with the bounds, or the space and the picture disagree")

        // The reflow path and the build path must agree at the same width (invariant 42's lesson:
        // two implementations of one geometry is where drift comes from).
        let rebuilt = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: FontSizeStore.size),
                                              columnWidth: wideColumn, documentDefaultFontSize: 10,
                                              pageContentWidth: pageWidth)
        var rebuiltSize: CGSize?
        rebuilt.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rebuilt.length)) { v, _, _ in
            if let att = v as? NSTextAttachment { rebuiltSize = att.bounds.size }
        }
        XCTAssertEqual(try XCTUnwrap(rebuiltSize), wide,
                       "resizing must land on exactly what rebuilding at that width would produce")
    }

    /// A picture inside a TABLE CELL must stay inside its cell when the window is resized. The build
    /// clamps a cell graphic to the cell's content width, not to the reading column; a reflow pass
    /// that clamped everything to the ambient column instead would recompute a cell picture far
    /// larger than its cell and tear the table's fixed columns apart (invariant 39) — and because
    /// `display(_:)`'s tail also runs this pass, it would happen right after every render, not only
    /// on a live resize. Most images in real reports live in cells, so this is the common case, and
    /// it was invisible to a builder-only test.
    func testCellGraphicStaysInsideItsCellWhenTheWindowResizes() throws {
        // Authored wider than a third of the page: at any column this MUST be clamped by the cell,
        // never by the column, which is exactly the case the ambient-column bug got wrong.
        let cellImage = Cell(blocks: [.image(id: "in-cell", size: CGSize(width: 300, height: 150))])
        let filler = Cell(spans: [Span(text: "b")])
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-cellresize-\(UUID().uuidString).docx")
        doc.setOfficeContent(blocks: [.table(rows: [[cellImage, filler, filler]], headerRows: 0,
                                             columnWidths: [1, 1, 1], format: TableFormat())],
                             archive: nil, defaultBodyFontSize: 10, pageContentWidth: 400)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)

        for windowWidth in [700.0, 1300.0] {
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: windowWidth, height: 600), display: false)
            wc.updateTextInset()
            var imageWidth: CGFloat?, cellWidth: CGFloat?
            storage.enumerateAttribute(MDAttr.officeGraphic, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                guard v is OfficeGraphicInfo else { return }
                imageWidth = (storage.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment)?.bounds.width
                cellWidth = (storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)
                    .flatMap { $0.textBlocks.first as? NSTextTableBlock }?.contentWidth
            }
            let image = try XCTUnwrap(imageWidth), cell = try XCTUnwrap(cellWidth)
            let column = try XCTUnwrap(wc.textView.textContainer?.size.width)
            XCTAssertLessThanOrEqual(image, cell + 0.5,
                                     "a cell picture must never exceed its cell (window \(Int(windowWidth)))")
            XCTAssertLessThan(cell, column, "the fixture's cell must genuinely be narrower than the column")
        }
    }

    /// Alignment must survive the WHOLE path, not just the builder: reader → blocks → render →
    /// storage. `OfficeTextBuilderTests` proves the builder aligns an attachment and
    /// `DocxReaderTests`/`OdtReaderTests` prove each reader reports the alignment; neither says the
    /// document actually renders it (invariant 29's standing lesson in this codebase).
    func testCentredImageRendersCentredThroughTheDocumentsOwnRenderPath() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-align-\(UUID().uuidString).docx")
        doc.setOfficeContent(blocks: [.image(id: "pic", size: CGSize(width: 80, height: 40), alignment: .center)],
                             archive: nil, defaultBodyFontSize: 10, pageContentWidth: 400)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center, "a centred figure must render centred, not hard left")
    }

    /// A document that declares no page width must not be touched by the resize pass at all — its
    /// graphics keep their authored size at every window width (the pre-existing behaviour).
    func testResizingLeavesGraphicsAloneWhenTheDocumentDeclaresNoPageWidth() throws {
        let declared = CGSize(width: 120, height: 60)
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-resize-nopage-\(UUID().uuidString).docx")
        doc.setOfficeContent(blocks: [.image(id: "pic", size: declared)], archive: nil, defaultBodyFontSize: 10)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        for width in [700, 1300] {
            wc.window?.setFrame(NSRect(x: 0, y: 0, width: CGFloat(width), height: 600), display: false)
            wc.updateTextInset()
            var size: CGSize?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                if let att = v as? NSTextAttachment { size = att.bounds.size }
            }
            XCTAssertEqual(try XCTUnwrap(size), declared, "no page width ⇒ authored size, at any window width")
        }
    }

    // MARK: S16 — the document's OWN declared default body size, read through the real dispatch
    // (`DocumentTypes.officeDefaultBodyFontSize`), not injected via `setOfficeContent` directly.
    // `DocxReaderTests`/`OdtReaderTests` already prove each reader reports the right number in
    // isolation — that proves nothing about whether `MarkdownDocument.read(from:)` actually wires it
    // in, which is exactly the class of bug invariant 29 records (a reader that works but is never
    // reached).

    private func fixtureDocxWithDocDefaultsAndExplicitRun() -> Data {
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?><w:styles>
          <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="20"/></w:rPr></w:rPrDefault></w:docDefaults>
        </w:styles>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:r><w:rPr><w:sz w:val="22"/></w:rPr><w:t>Body</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
        ])
    }

    private func fixtureOdtWithDefaultStyleAndExplicitRun() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:automatic-styles>
            <style:style style:name="Styled" style:family="text">
              <style:text-properties fo:font-size="11pt"/>
            </style:style>
          </office:automatic-styles>
          <office:body><office:text>
            <text:p><text:span text:style-name="Styled">Body</text:span></text:p>
          </office:text></office:body>
        </office:document-content>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles>
          <office:styles>
            <style:default-style style:family="paragraph">
              <style:text-properties fo:font-size="13pt"/>
            </style:default-style>
          </office:styles>
        </office:document-styles>
        """
        return buildZip([
            ("content.xml", Data(content.utf8)),
            ("styles.xml", Data(styles.utf8)),
        ])
    }

    func testDocxDeclaringANonDefaultBodySizeRendersScaledThroughMarkdownDocumentsOwnReadPath() throws {
        let originalSize = FontSizeStore.size
        FontSizeStore.size = 20   // reading size == the document's own declared default (10pt) × 2
        defer { FontSizeStore.size = originalSize }

        let (doc, wc) = try openOffice(fixtureDocxWithDocDefaultsAndExplicitRun())
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 10,
                       "MarkdownDocument.read(from:) must call DocumentTypes.officeDefaultBodyFontSize, " +
                       "not leave the 11pt constant every call site used to hardcode")
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // scale = 20/10 = 2; the run's authored 11pt renders at 22pt.
        XCTAssertEqual(font.pointSize, 22)
    }

    func testOdtDeclaringANonDefaultBodySizeRendersScaledThroughMarkdownDocumentsOwnReadPath() throws {
        let originalSize = FontSizeStore.size
        FontSizeStore.size = 26   // reading size == the document's own declared default (13pt) × 2
        defer { FontSizeStore.size = originalSize }

        let (doc, wc) = try openOffice(fixtureOdtWithDefaultStyleAndExplicitRun(),
                                        ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 13,
                       "MarkdownDocument.read(from:) must call DocumentTypes.officeDefaultBodyFontSize " +
                       "for .odt too, through the SAME dispatch readOffice uses")
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // scale = 26/13 = 2; the run's authored 11pt renders at 22pt.
        XCTAssertEqual(font.pointSize, 22)
    }

    func testDocumentDeclaringNoDefaultStillUses11PointFallback() throws {
        let (doc, _) = try openOffice(fixtureDocx())
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 11)
    }

    /// An unstyled document (no `Span.fontSize` anywhere) must render exactly as it did before this
    /// wiring existed — `fontSizeScale` only multiplies a run that names an explicit size (see
    /// `OfficeTextBuilder.build`'s own doc), so a document with none must be untouched by whatever
    /// `officeDefaultBodyFontSize` resolves to.
    func testUnstyledDocumentIsUnaffectedByTheDefaultBodyFontSizeWiring() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 11)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let bodyRange = try XCTUnwrap(storage.string.range(of: "Body text."))
        let bodyIndex = storage.string.distance(from: storage.string.startIndex, to: bodyRange.lowerBound)
        let font = try XCTUnwrap(storage.attribute(.font, at: bodyIndex, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, FontSizeStore.size,
                       "an unsized run must render at the theme's own body size, unscaled")
    }

    /// Invariant 29's own lesson, applied to THIS wiring: a document must render identically on
    /// first open and after ⌘R. `ReloadOutcome.office` carries `defaultBodyFontSize` alongside
    /// `blocks`/`archive` for exactly this — assert the two paths agree rather than assume it.
    func testReloadProducesTheSameDefaultBodyFontSizeAsFirstOpen() throws {
        let data = fixtureDocxWithDocDefaultsAndExplicitRun()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmd-office-reload-fontsize-\(UUID().uuidString).docx")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "org.openxmlformats.wordprocessingml.document")
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 10)

        guard case .office(_, _, _, _, let reloadedDefault, _) =
            MarkdownDocument.reloadOutcome(url: url, kind: .office, extension: "docx")
        else { return XCTFail("expected a successful office reload") }
        XCTAssertEqual(reloadedDefault, doc.officeDefaultBodyFontSize,
                       "a reload must resolve the same default body size as the first open of the same file")
    }

    // MARK: Read-only enforcement

    func testDataOfTypeThrowsForOfficeDocument() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-save.docx")
        try doc.read(from: fixtureDocx(), ofType: "org.openxmlformats.wordprocessingml.document")
        XCTAssertThrowsError(try doc.data(ofType: "org.openxmlformats.wordprocessingml.document"))
    }

    /// The bug the S4 audit found: `addBlockBelow` used to treat "no `srcRange` at the anchor" —
    /// always true for an office document — as "the document is empty" and replaced the whole of
    /// `doc.text`, marking it dirty over content the reader never touched. This is the regression
    /// test for that fix, on the real object the bug lived in (`DocumentWindowController`), not a
    /// reimplementation of its logic.
    func testAddBlockBelowOnOfficeDocumentDoesNotTouchTextOrDirtyState() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        wc.addBlockBelow(atChar: 0)
        // The undo group closes on the NEXT run-loop turn (CLAUDE.md invariant 17) — but this path
        // must never even start an edit, so there is nothing to wait out; asserting immediately is
        // correct here, unlike a test that undoes an edit back to clean.
        XCTAssertEqual(doc.text, "")
        XCTAssertFalse(doc.isDocumentEdited)
    }

    // MARK: Regression — markdown and plain text unaffected

    func testMarkdownStillRendersThroughKind() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-md-\(UUID().uuidString).md")
        try doc.read(from: Data("# Hello\n\nWorld.\n".utf8), ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.kind, .markdown)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Hello"))
        XCTAssertEqual(headingLevels(storage), [1])
    }

    func testPlainTextStillRendersThroughKind() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-txt-\(UUID().uuidString).txt")
        try doc.read(from: Data("line one\nline two\n".utf8), ofType: "public.plain-text")
        XCTAssertEqual(doc.kind, .plainText)
        XCTAssertTrue(doc.isPlainText)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(storage.string, "line one\nline two\n")
    }

    // MARK: CLAUDE.md S2 item 1 — `.docm`/`.dotx`/`.dotm` open through the SAME real pipeline as
    // `.docx`, per invariant 29: a test that only proves `DocxReader` parses these bytes (it always
    // could — the XML shape is identical) says nothing about whether the app will let the file
    // through the door at all. `.odt` shipped registered-but-unreachable once already; these three
    // go through `MarkdownDocument.read(from:)` for exactly that reason.

    func testDocmOpensThroughMarkdownDocumentAndParsesLikeDocx() throws {
        let (doc, wc) = try openOffice(fixtureDocx(), ext: "docm",
                                       uti: "org.openxmlformats.wordprocessingml.document.macroenabled")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Title"))
        XCTAssertTrue(storage.string.contains("Body text."))
    }

    func testDotxOpensThroughMarkdownDocumentAndParsesLikeDocx() throws {
        let (doc, wc) = try openOffice(fixtureDocx(), ext: "dotx",
                                       uti: "org.openxmlformats.wordprocessingml.template")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Title"))
    }

    func testDotmOpensThroughMarkdownDocumentAndParsesLikeDocx() throws {
        let (doc, wc) = try openOffice(fixtureDocx(), ext: "dotm",
                                       uti: "org.openxmlformats.wordprocessingml.template.macroenabled")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Title"))
    }

    func testDocumentTypesOfficeExtensionsIncludesAllFourWordFormats() {
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("docx"))
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("docm"))
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("dotx"))
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("dotm"))
    }

    /// Mechanical, per CLAUDE.md's testing note: `DocumentTypes.officeExtensions` and
    /// `Resources/Info.plist`'s `CFBundleDocumentTypes` are two lists nothing keeps in sync but a
    /// human — read the plist straight out of the repo and assert every office extension this app
    /// claims to open (`DocumentTypes`) has a matching `LSItemContentTypes` entry the system can
    /// actually resolve back to that extension (`UTType(filenameExtension:)`), and vice versa.
    // MARK: S3 — heading recognition on the REAL corpus fixture, through MarkdownDocument itself
    //
    // INVARIANT 29: a parser test proves the parser, not that the app reaches it. `bus-headings.docx`
    // measured 0 headings before this sprint (every mechanism but the rarest was unread) and
    // `bus-headings.odt` measured 14 — this is the real regression guard: both formats of the SAME
    // document must produce the SAME heading count, read through `MarkdownDocument.read(from:)`,
    // not `DocxReader`/`OdtReader` directly.

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Counts `.heading` BLOCKS, not rendered attribute ranges — three of this fixture's fourteen
    /// headings have no text of their own (an author left the heading line blank), so their
    /// `MDAttr.heading` range collapses to zero length and never shows up in an attribute
    /// enumeration over the rendered storage. The block count is what the sprint brief measures
    /// (docx: 0 → 14) and what the outline sidebar is built from before empty ones are filtered for
    /// display — this is the level this regression guard belongs at.
    private func headingBlockCount(_ doc: MarkdownDocument) -> Int {
        doc.officeBlocks.filter { if case .heading = $0 { return true }; return false }.count
    }

    func testBusHeadingsDocxAndOdtAgreeOnFourteenHeadingsThroughMarkdownDocument() throws {
        let docxURL = repoRoot().appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        let odtURL = repoRoot().appendingPathComponent("docs/fixtures/office/bus-headings.odt")
        let (docxDoc, docxWc) = try openOffice(try Data(contentsOf: docxURL))
        let (odtDoc, odtWc) = try openOffice(
            try Data(contentsOf: odtURL), ext: "odt", uti: "org.oasis-open.opendocument.text")
        // Reached through `MarkdownDocument.read(from:)` itself (invariant 29) — not `DocxReader`/
        // `OdtReader` called directly, which would prove only the parser, not that the app gets there.
        XCTAssertEqual(headingBlockCount(docxDoc), 14, "docx must recognize all three heading mechanisms")
        XCTAssertEqual(headingBlockCount(odtDoc), 14)
        XCTAssertEqual(headingBlockCount(docxDoc), headingBlockCount(odtDoc),
                       "the same document must yield the same heading count in both formats")
        // The window controllers are exercised (not just discarded) so a render-time crash in either
        // format's heading path would still fail this test.
        _ = (try XCTUnwrap(docxWc.textStorageRef), try XCTUnwrap(odtWc.textStorageRef))
    }

    // MARK: S5 — clause numbering, INVARIANT 29 (through `MarkdownDocument`, not `DocxReader` directly)

    /// `w:lvlText="%1.%2"` with level 1 decimal / level 2 lowerLetter — the exact "1.a" shape a
    /// real multi-level clause list uses. Read through `MarkdownDocument.read(from:ofType:)`, the
    /// application's own path (INVARIANT 29: a unit test on `DocxReader` alone cannot prove this is
    /// REACHED by the app), and asserted on the rendered text a reader actually sees on screen.
    private let clauseNumbering = """
    <?xml version="1.0" encoding="UTF-8"?><w:numbering>
      <w:abstractNum w:abstractNumId="9">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="9"><w:abstractNumId w:val="9"/></w:num>
    </w:numbering>
    """

    func testClauseNumberingRendersThroughMarkdownDocument() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="9"/></w:numPr></w:pPr><w:r><w:t>First clause.</w:t></w:r></w:p>
          <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="9"/></w:numPr></w:pPr><w:r><w:t>Sub-clause.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let zip = buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/numbering.xml", Data(clauseNumbering.utf8)),
        ])
        let (_, wc) = try openOffice(zip)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("1.\tFirst clause."))
        XCTAssertTrue(storage.string.contains("1.a\tSub-clause."))
    }

    func testOfficeExtensionsAgreeWithInfoPlistDocumentTypes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent("Resources/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any])
        let docTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let plistContentTypes = Set(docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })

        // The bundle's OWN imported UTType declarations, as extension → identifier. HWP has no
        // universal system UTI (a `.hwp`'s resolved type depends on which Hancom software is installed
        // — see below), so the app DECLARES `com.hancom.hwp`/`.hwpx` here and lists them in
        // `LSItemContentTypes`. This map lets the check below verify coverage by extension even when
        // the system's resolved UTI isn't one the plist lists.
        let importedByExtension: [String: Set<String>] = {
            var out: [String: Set<String>] = [:]
            for decl in (plist["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [] {
                guard let id = decl["UTTypeIdentifier"] as? String,
                      let tags = decl["UTTypeTagSpecification"] as? [String: Any],
                      let exts = tags["public.filename-extension"] as? [String] else { continue }
                for e in exts { out[e.lowercased(), default: []].insert(id) }
            }
            return out
        }()

        for ext in DocumentTypes.officeExtensions {
            // Primary check: the extension's system-resolved UTI is declared in the plist. Stable for
            // docx/odt (org.openxmlformats.*/org.oasis-open.* exist on every Mac). HWP is machine-
            // dependent: with Hancom software the extension resolves to `com.haansoft.*`; on a clean
            // machine it resolves to a dynamic UTI. So HWP is ALSO accepted when covered by the
            // bundle's own imported declaration whose identifier is listed — proving the app claims the
            // extension either way (invariant 29: the plist mirrors the openable extension list).
            let systemUti = UTType(filenameExtension: ext)?.identifier
            let systemCovered = systemUti.map(plistContentTypes.contains) ?? false
            let importedCovered = (importedByExtension[ext.lowercased()] ?? []).contains(where: plistContentTypes.contains)
            XCTAssertTrue(systemCovered || importedCovered,
                          "Info.plist has no CFBundleDocumentTypes entry covering \".\(ext)\" " +
                          "(system UTI \(systemUti ?? "none"), imported \(importedByExtension[ext.lowercased()] ?? []))")
        }
    }

    // MARK: Internal (in-document) links (S11) — through the REAL read path (invariant 29): a
    // parser-only test (`DocxReaderTests`) can prove the span carries the right target, but not
    // that it reaches the text storage `DocumentWindowController` actually clicks on, and a
    // builder-only test (`OfficeTextBuilderTests`) can prove the attribute shape but not that the
    // real click handler resolves and navigates from it.

    /// A leading, deliberately unrelated paragraph is important, not decoration: it puts the link
    /// at a non-zero character position, so a mutant that resolved a dead anchor to "0" (document
    /// start) or otherwise guessed would be caught by `testInternalLinkToAMissingBookmarkDoesNothingRatherThanMisfiring`
    /// instead of coincidentally matching "stayed at the click position" — see invariant 30.
    private func fixtureDocxWithInternalLink(anchor: String, bookmarkName: String?) -> Data {
        let bookmarkPara = bookmarkName.map {
            "<w:bookmarkStart w:id=\"0\" w:name=\"\($0)\"/><w:r><w:t>Clause 7</w:t></w:r><w:bookmarkEnd w:id=\"0\"/>"
        } ?? "<w:r><w:t>Clause 7, no bookmark</w:t></w:r>"
        let body = """
        <w:p><w:r><w:t>Preamble text before the link.</w:t></w:r></w:p>
        <w:p><w:hyperlink w:anchor="\(anchor)"><w:r><w:t>See above</w:t></w:r></w:hyperlink></w:p>
        <w:p>\(bookmarkPara)</w:p>
        """
        return buildZip([("word/document.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>\(body)</w:body></w:document>
        """.utf8))])
    }

    /// The actual defect: clicking an internal link (`w:anchor`, no `r:id`) must resolve through
    /// `MDAttr.anchor`, never fall to the generic URL branch that would try to open a file named
    /// after the bookmark. Proven by resolving AND by the attribute shape at the click point.
    func testInternalLinkWithAResolvableBookmarkNavigatesToItsSpan() throws {
        let (_, wc) = try openOffice(fixtureDocxWithInternalLink(anchor: "_Toc1", bookmarkName: "_Toc1"))
        let storage = try XCTUnwrap(wc.textStorageRef)
        let linkLoc = (storage.string as NSString).range(of: "See above").location
        // Full-pipeline proof (invariant 29) that the anchor attribute — not a bare `#_Toc1` URL —
        // reached the real text storage `clickedOnLink` reads.
        XCTAssertEqual(storage.attribute(MDAttr.anchor, at: linkLoc, effectiveRange: nil) as? String, "_Toc1")
        XCTAssertNil(storage.attribute(MDAttr.filePath, at: linkLoc, effectiveRange: nil))
        let linkURL = storage.attribute(.link, at: linkLoc, effectiveRange: nil) as? URL
        XCTAssertEqual(linkURL, URL(string: "fmdanchor:jump"))

        let before = wc.textView.selectedRange()
        let handled = wc.textView(wc.textView, clickedOnLink: linkURL as Any, at: linkLoc)
        XCTAssertTrue(handled)
        let targetLoc = (storage.string as NSString).range(of: "Clause 7").location
        XCTAssertEqual(wc.textView.selectedRange(), NSRange(location: targetLoc, length: 0))
        XCTAssertNotEqual(wc.textView.selectedRange(), before)
    }

    /// A link to a bookmark that doesn't exist (deleted in a real document, common) — MUST NOT
    /// misfire as a file-open attempt, and must do NOTHING VISIBLE: the selection stays put.
    ///
    /// MUTATION CHECK: if `jumpToAnchor` guessed instead of returning early on a `nil` resolve (e.g.
    /// falling back to "jump to document start"), `selectedRange` would change and this would fail
    /// — proving this test is sensitive to the "do nothing" behaviour, not just "doesn't crash".
    func testInternalLinkToAMissingBookmarkDoesNothingRatherThanMisfiring() throws {
        let (_, wc) = try openOffice(fixtureDocxWithInternalLink(anchor: "_Deleted", bookmarkName: "_Toc1"))
        let storage = try XCTUnwrap(wc.textStorageRef)
        let linkLoc = (storage.string as NSString).range(of: "See above").location
        wc.textView.setSelectedRange(NSRange(location: linkLoc, length: 0))
        let linkURL = storage.attribute(.link, at: linkLoc, effectiveRange: nil) as? URL

        let handled = wc.textView(wc.textView, clickedOnLink: linkURL as Any, at: linkLoc)
        XCTAssertTrue(handled, "an anchor link is still HANDLED (never falls through to file-open) even when it doesn't resolve")
        XCTAssertEqual(wc.textView.selectedRange(), NSRange(location: linkLoc, length: 0),
                       "an unresolved anchor must not move the selection/scroll at all")
    }

    /// `AnchorResolver`'s pure decision, exercised against the REAL storage the full read path
    /// produces (not a synthetic dictionary) — the part of invariant 29 that doesn't need a window.
    func testAnchorResolverAgreesWithTheRealDocumentsStorage() throws {
        let (_, wc) = try openOffice(fixtureDocxWithInternalLink(anchor: "_Toc1", bookmarkName: "_Toc1"))
        let storage = try XCTUnwrap(wc.textStorageRef)
        var bookmarks: [String: Int] = [:]
        storage.enumerateAttribute(MDAttr.bookmarkTarget, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            (v as? [String])?.forEach { bookmarks[$0] = r.location }
        }
        let targetLoc = (storage.string as NSString).range(of: "Clause 7").location
        XCTAssertEqual(AnchorResolver.resolve(target: "_Toc1", bookmarks: bookmarks, headings: []), targetLoc)
        XCTAssertNil(AnchorResolver.resolve(target: "_Deleted", bookmarks: bookmarks, headings: []))
    }

    // MARK: P2 invariant 29 — the spacing/indent/line-height cascade, through MarkdownDocument itself

    /// A document declaring its own default body size (10pt) AND a paragraph's own `w:pPr/w:spacing`/
    /// `w:ind` — reached through `MarkdownDocument.read(from:)`, not `DocxReader.read` called
    /// directly, so this is invariant 29's own guard against the P2 wiring being reachable in the
    /// parser but never actually invoked by the real dispatch. The reading size is set to DOUBLE the
    /// document's own default, so a mutation that forgot to multiply P2's values by `fontSizeScale`
    /// (leaving them at their authored, unscaled points) is distinguishable from the correct,
    /// doubled result.
    private func fixtureDocxWithParagraphFormatting() -> Data {
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?><w:styles>
          <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="20"/></w:rPr></w:rPrDefault></w:docDefaults>
        </w:styles>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:spacing w:before="240" w:after="120" w:line="360" w:lineRule="auto"/>
            <w:ind w:start="720"/></w:pPr><w:r><w:t>Formatted</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
        ])
    }

    func testParagraphSpacingIndentAndLineHeightReachTheRenderedStorageThroughMarkdownDocument() throws {
        let originalSize = FontSizeStore.size
        FontSizeStore.size = 20   // reading size == the document's own declared default (10pt) × 2
        defer { FontSizeStore.size = originalSize }

        let (_, wc) = try openOffice(fixtureDocxWithParagraphFormatting())
        let storage = try XCTUnwrap(wc.textStorageRef)
        let loc = (storage.string as NSString).range(of: "Formatted").location
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle)
        // scale = 2: 240 twips (12pt) before → 24; 120 twips (6pt) after → 12; 720 twips (36pt)
        // indent → 72. `lineHeightMultiple` (360/240 = 1.5) is a unitless ratio, never scaled.
        XCTAssertEqual(style.paragraphSpacingBefore, 24)
        XCTAssertEqual(style.paragraphSpacing, 12)
        XCTAssertEqual(style.headIndent, 72)
        XCTAssertEqual(style.lineHeightMultiple, 1.5)
    }

    // MARK: Comments (P6a) — captured through the full read path (invariant 29), never through
    // `DocxReader.read`/`OdtReader.read` called directly, the same reasoning this whole file exists
    // for: a dispatch-level regression (comments wired for one format, not the other) would be
    // invisible to `DocxReaderTests`/`OdtReaderTests` calling their own parser directly.

    /// Two `word/comments.xml` entries, each with its own `w:commentRangeStart…w:commentRangeEnd`
    /// pair in the body: both must reach `doc.officeComments` (author/text/number) AND the spans
    /// INSIDE each range must carry that comment's id — text outside either range must carry none.
    func testDocxCommentsAndRangesAreCapturedThroughTheFullReadPath() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p>
            <w:r><w:t>Alpha </w:t></w:r>
            <w:commentRangeStart w:id="0"/>
            <w:r><w:t>bravo</w:t></w:r>
            <w:commentRangeEnd w:id="0"/>
            <w:r><w:commentReference w:id="0"/></w:r>
            <w:r><w:t> charlie </w:t></w:r>
            <w:commentRangeStart w:id="1"/>
            <w:r><w:t>delta</w:t></w:r>
            <w:commentRangeEnd w:id="1"/>
            <w:r><w:commentReference w:id="1"/></w:r>
          </w:p>
        </w:body></w:document>
        """
        let comments = """
        <?xml version="1.0" encoding="UTF-8"?><w:comments>
          <w:comment w:id="0" w:author="Alice" w:date="2024-01-01T00:00:00Z"><w:p><w:r><w:t>First comment</w:t></w:r></w:p></w:comment>
          <w:comment w:id="1" w:author="Bob" w:date="2024-01-02T00:00:00Z"><w:p><w:r><w:t>Second comment</w:t></w:r></w:p></w:comment>
        </w:comments>
        """
        let zip = buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/comments.xml", Data(comments.utf8)),
        ])
        let (doc, _) = try openOffice(zip)
        XCTAssertEqual(doc.officeComments.count, 2)
        XCTAssertEqual(doc.officeComments[0].author, "Alice")
        XCTAssertEqual(doc.officeComments[0].text, "First comment")
        XCTAssertEqual(doc.officeComments[0].dateISO, "2024-01-01T00:00:00Z")
        XCTAssertEqual(doc.officeComments[0].number, 1)
        XCTAssertEqual(doc.officeComments[1].author, "Bob")
        XCTAssertEqual(doc.officeComments[1].text, "Second comment")
        XCTAssertEqual(doc.officeComments[1].number, 2)

        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        let alpha = try XCTUnwrap(spans.first { $0.text == "Alpha " })
        XCTAssertTrue(alpha.commentIds.isEmpty)
        let bravo = try XCTUnwrap(spans.first { $0.text == "bravo" })
        XCTAssertEqual(bravo.commentIds, ["0"])
        let delta = try XCTUnwrap(spans.first { $0.text == "delta" })
        XCTAssertEqual(delta.commentIds, ["1"])
    }

    /// A comment in `word/comments.xml` with no matching `w:commentRangeStart`/`w:commentReference`
    /// anywhere in the body — still listed (with a display number), but no span anchors it.
    func testDocxCommentWithNoBodyRangeIsListedButAnchorsNothing() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:r><w:t>Plain text, no ranges at all.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let comments = """
        <?xml version="1.0" encoding="UTF-8"?><w:comments>
          <w:comment w:id="5" w:author="Carol"><w:p><w:r><w:t>Orphan comment</w:t></w:r></w:p></w:comment>
        </w:comments>
        """
        let zip = buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/comments.xml", Data(comments.utf8)),
        ])
        let (doc, _) = try openOffice(zip)
        XCTAssertEqual(doc.officeComments.count, 1)
        XCTAssertEqual(doc.officeComments[0].id, "5")
        XCTAssertEqual(doc.officeComments[0].author, "Carol")
        XCTAssertEqual(doc.officeComments[0].number, 1)
        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
    }

    /// A docx with no comments at all — `officeComments` is empty and no span carries an id. Every
    /// comment marker was already SKIPPED before P6a (invariant: this sprint only starts capturing
    /// them, never invents one), so this is the render-stays-byte-identical guarantee.
    func testDocxWithNoCommentsProducesEmptyOfficeCommentsAndNoSpanCarriesAnId() throws {
        let (doc, _) = try openOffice(fixtureDocx())
        XCTAssertTrue(doc.officeComments.isEmpty)
        for block in doc.officeBlocks {
            switch block {
            case .paragraph(let spans, _, _, _, _), .heading(_, let spans, _, _, _, _),
                 .listItem(_, _, let spans, _, _, _, _, _):
                XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
            case .table, .image, .unsupportedGraphic, .formula:
                continue
            }
        }
    }

    /// ODT's `office:annotation` is inline, RANGED by a shared `office:name` matched to a later
    /// `office:annotation-end` — the span(s) between the two carry the comment's id, text outside
    /// the range carries none.
    func testOdtAnnotationRangeIsCapturedThroughTheFullReadPath() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <text:p>Before <office:annotation office:name="c1"><dc:creator>Dana</dc:creator><dc:date>2024-02-02T00:00:00Z</dc:date><text:p>Odt comment text</text:p></office:annotation>commented<office:annotation-end office:name="c1"/> after</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        let zip = buildZip([("content.xml", Data(content.utf8))])
        let (doc, _) = try openOffice(zip, ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.officeComments.count, 1)
        XCTAssertEqual(doc.officeComments[0].id, "c1")
        XCTAssertEqual(doc.officeComments[0].author, "Dana")
        XCTAssertEqual(doc.officeComments[0].dateISO, "2024-02-02T00:00:00Z")
        XCTAssertEqual(doc.officeComments[0].text, "Odt comment text")
        XCTAssertEqual(doc.officeComments[0].number, 1)

        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        let before = try XCTUnwrap(spans.first { $0.text == "Before " })
        XCTAssertTrue(before.commentIds.isEmpty)
        let commented = try XCTUnwrap(spans.first { $0.text == "commented" })
        XCTAssertEqual(commented.commentIds, ["c1"])
        let after = try XCTUnwrap(spans.first { $0.text == " after" })
        XCTAssertTrue(after.commentIds.isEmpty)
    }

    /// A POINT `office:annotation` — no `office:name`, so no `office:annotation-end` can ever match
    /// it — is still captured and listed (with a display number), but deliberately anchors nothing
    /// (see the `office:annotation` case in `OdtReader.collectSpans`'s own doc for why).
    func testOdtPointAnnotationWithNoNameIsListedButAnchorsNothing() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <text:p>Point comment here<office:annotation><dc:creator>Eve</dc:creator><text:p>Point note</text:p></office:annotation> after</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        let zip = buildZip([("content.xml", Data(content.utf8))])
        let (doc, _) = try openOffice(zip, ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.officeComments.count, 1)
        XCTAssertEqual(doc.officeComments[0].author, "Eve")
        XCTAssertEqual(doc.officeComments[0].text, "Point note")
        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
    }

    /// An `.odt` with no comments at all — `officeComments` is empty and no span carries an id,
    /// mirroring the docx no-comments guarantee above.
    func testOdtWithNoCommentsProducesEmptyOfficeCommentsAndNoSpanCarriesAnId() throws {
        let (doc, _) = try openOffice(fixtureOdt(), ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertTrue(doc.officeComments.isEmpty)
        for block in doc.officeBlocks {
            switch block {
            case .paragraph(let spans, _, _, _, _), .heading(_, let spans, _, _, _, _),
                 .listItem(_, _, let spans, _, _, _, _, _):
                XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
            case .table, .image, .unsupportedGraphic, .formula:
                continue
            }
        }
    }

    // MARK: - HWP/HWPX wire-up (S5)
    //
    // These go through `MarkdownDocument.read(from:)` and the `--extract` dispatch — NOT `HwpReader`
    // in isolation (`HwpReaderTests`/`HwpMappingTests` do that). Invariant 29's lesson: `.odt` once
    // shipped parsed-and-tested yet unreachable because the app never routed bytes to it. HWP is the
    // riskier case still — it must branch BEFORE `ZipArchive(data:)` (a `.hwp` is CFB binary, not a
    // zip), so a test that only exercises the parser cannot prove the branch is taken. A repo has no
    // HWP fixture (no in-memory builder like `buildZip` — the format is CFB/rhwp's own), so these are
    // gated on real sample files: `FMD_HWP_SAMPLE`/`FMD_HWPX_SAMPLE`, defaulting to the rhwp fork's
    // sample corpus. They SKIP (not fail) when neither is present, so CI without the corpus stays
    // green while a local run with it proves the dispatch end to end.

    private static let rhwpSamples =
        NSString(string: "~/Documents/DEV/refs/rhwp/samples").expandingTildeInPath

    private func hwpSamplePath(env: String, fallback: String) throws -> String {
        if let p = ProcessInfo.processInfo.environment[env], FileManager.default.fileExists(atPath: p) { return p }
        let fb = (Self.rhwpSamples as NSString).appendingPathComponent(fallback)
        guard FileManager.default.fileExists(atPath: fb) else {
            throw XCTSkip("Set \(env) to a \(fallback.hasSuffix("x") ? ".hwpx" : ".hwp") path (or place the rhwp sample corpus at \(Self.rhwpSamples))")
        }
        return fb
    }

    /// `.hwp` (CFB binary) opened through `MarkdownDocument.read(from:)`: proves the read path branches
    /// to `HwpReader.read` BEFORE `ZipArchive(data:)` (which would throw on non-zip bytes) and that the
    /// document ends up `.office` kind with real `officeBlocks`, not a raw-text fallback. `officeArchive`
    /// must be nil (HWP has no archive) — the exact seam S4's reconcile map-first branch depends on.
    func testHwpBinaryOpensThroughMarkdownDocumentReadPath() throws {
        let path = try hwpSamplePath(env: "FMD_HWP_SAMPLE", fallback: "para-001.hwp")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: path)
        try doc.read(from: data, ofType: "com.hancom.hwp")
        XCTAssertEqual(doc.kind, .office, "a .hwp must resolve to the office kind")
        XCTAssertFalse(doc.officeBlocks.isEmpty,
                       "read(from:) must populate officeBlocks via HwpReader — an empty result means the branch fell through")
        XCTAssertNil(doc.officeArchive, "HWP has no ZipArchive; officeArchive must stay nil (reconcile relies on this)")
    }

    /// `.hwpx` (a zip, but rhwp still reads it from raw `Data`) through the same read path — HWP does
    /// NOT go through `ZipArchive`/`DocumentTypes.readOffice` even for the zip-shaped variant.
    func testHwpxOpensThroughMarkdownDocumentReadPath() throws {
        let path = try hwpSamplePath(env: "FMD_HWPX_SAMPLE", fallback: "hwpx_sample2.hwpx")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: path)
        try doc.read(from: data, ofType: "com.hancom.hwpx")
        XCTAssertEqual(doc.kind, .office)
        XCTAssertFalse(doc.officeBlocks.isEmpty,
                       "read(from:) must populate officeBlocks for .hwpx via HwpReader")
        XCTAssertNil(doc.officeArchive)
    }

    /// `--extract` for HWP: the headless serializer path (`HeadlessExtract.run` → the office `.office`
    /// branch → `HwpReader.read` → `OfficeMarkdownSerializer`) emits non-empty Markdown to stdout,
    /// mirroring `testHeadlessExtractSerializesThroughTheRealOfficeDispatch` for the zip readers. Runs
    /// the SAME library dispatch `HeadlessExtract` calls, so it proves the `--extract` HWP branch is
    /// wired (invariant 40 — one serializer for every office block vocabulary).
    func testHeadlessExtractSerializesHwpThroughTheRealDispatch() throws {
        let cases: [(env: String, fallback: String)] = [
            ("FMD_HWP_SAMPLE", "para-001.hwp"),
            ("FMD_HWPX_SAMPLE", "hwpx_sample2.hwpx"),
        ]
        for c in cases {
            let path = try hwpSamplePath(env: c.env, fallback: c.fallback)
            let ext = (path as NSString).pathExtension.lowercased()
            XCTAssertTrue(DocumentTypes.isHwp(ext), "\(c.fallback): must be recognized as an HWP extension")
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let result = try HwpReader.read(data)
            let markdown = OfficeMarkdownSerializer.serialize(result.blocks)
            XCTAssertFalse(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(c.fallback): --extract must emit non-empty Markdown")
        }
    }

    /// The extension list is the OTHER half of the single HWP dispatch (invariant 29): `hwp`/`hwpx`
    /// must resolve to `.office` and be recognized by `isHwp`, and Info.plist's `CFBundleDocumentTypes`
    /// must mirror this list by hand (the seam no compiler checks).
    func testHwpExtensionsResolveToOfficeKindAndAreRecognizedAsHwp() {
        for ext in ["hwp", "hwpx", "HWP", "Hwpx"] {
            XCTAssertEqual(DocumentTypes.kind(forExtension: ext), .office, "\(ext) must be office kind")
            XCTAssertTrue(DocumentTypes.isHwp(ext), "\(ext) must be recognized as HWP")
            XCTAssertTrue(DocumentTypes.opensInApp(ext), "\(ext) must be openable")
        }
    }
}
