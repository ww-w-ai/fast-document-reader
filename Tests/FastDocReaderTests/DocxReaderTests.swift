import XCTest
import AppKit
@testable import FastDocReader

/// `DocxReader` is pure: build a `.docx`-shaped ZIP by hand (stored entries only — no need to
/// deflate to exercise the reader), hand it to `ZipArchive`, then `DocxReader.read`, and assert
/// on the `[OfficeBlock]` that comes back. Same shape as `ZipArchiveTests` — no fixture files on
/// disk, no view, no document.
final class DocxReaderTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Builds a minimal `.docx`-shaped archive: `word/document.xml` always, `word/styles.xml`,
    /// `word/numbering.xml` and `word/_rels/document.xml.rels` only when provided (Word itself
    /// omits `numbering.xml` from documents with no lists, and a document with no relationships
    /// at all omits the `.rels` part too — several tests below exercise both).
    private func buildDocx(
        document: String, styles: String? = nil, numbering: String? = nil, rels: String? = nil,
        footnotes: String? = nil, endnotes: String? = nil, theme: String? = nil, comments: String? = nil,
        media: [(name: String, bytes: [UInt8])] = [],
        // Arbitrary extra parts (header-footer-design.md coverage) — path relative to the archive
        // root, e.g. `("word/header1.xml", "<w:hdr>…")` or `("word/_rels/header1.xml.rels", "…")`.
        // A generic escape hatch rather than a named parameter per part, since a header/footer test
        // needs a combination (a header part + ITS OWN rels + a footer part) no fixed set of named
        // parameters could anticipate.
        extraParts: [(path: String, xml: String)] = []
    ) -> Data {
        var entries: [(String, Data)] = [("word/document.xml", Data(document.utf8))]
        if let styles { entries.append(("word/styles.xml", Data(styles.utf8))) }
        if let numbering { entries.append(("word/numbering.xml", Data(numbering.utf8))) }
        if let rels { entries.append(("word/_rels/document.xml.rels", Data(rels.utf8))) }
        if let footnotes { entries.append(("word/footnotes.xml", Data(footnotes.utf8))) }
        if let endnotes { entries.append(("word/endnotes.xml", Data(endnotes.utf8))) }
        if let theme { entries.append(("word/theme/theme1.xml", Data(theme.utf8))) }
        if let comments { entries.append(("word/comments.xml", Data(comments.utf8))) }
        for (name, bytes) in media { entries.append(("word/media/" + name, Data(bytes))) }
        for (path, xml) in extraParts { entries.append((path, Data(xml.utf8))) }
        return buildZip(entries)
    }

    /// A minimal, real-shaped `a:clrScheme` — enough of `word/theme/theme1.xml` for
    /// `DocxReader`'s theme-colour resolution tests without a full Office-authored theme part.
    private let sampleTheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
      <a:themeElements>
        <a:clrScheme name="Office">
          <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
          <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
          <a:dk2><a:srgbClr val="1F497D"/></a:dk2>
          <a:lt2><a:srgbClr val="EEECE1"/></a:lt2>
          <a:accent1><a:srgbClr val="4F81BD"/></a:accent1>
          <a:accent2><a:srgbClr val="C0504D"/></a:accent2>
          <a:accent3><a:srgbClr val="9BBB59"/></a:accent3>
          <a:accent4><a:srgbClr val="8064A2"/></a:accent4>
          <a:accent5><a:srgbClr val="4BACC6"/></a:accent5>
          <a:accent6><a:srgbClr val="F79646"/></a:accent6>
          <a:hlink><a:srgbClr val="0000FF"/></a:hlink>
          <a:folHlink><a:srgbClr val="800080"/></a:folHlink>
        </a:clrScheme>
      </a:themeElements>
    </a:theme>
    """

    private func buildZip(_ entries: [(name: String, content: Data)]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50)                  // local file header signature
            body += le16(20)                            // version needed to extract
            body += le16(0)                              // general purpose bit flag
            body += le16(0)                              // compression method: stored
            body += le16(0) + le16(0)                    // mod time, mod date
            body += le32(0)                               // crc-32 (unused by ZipArchive)
            body += le32(UInt32(content.count))           // compressed size == uncompressed for stored
            body += le32(UInt32(content.count))           // uncompressed size
            body += le16(UInt16(nameBytes.count))
            body += le16(0)                                // extra field length
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var centralDirectory = [UInt8]()
        for p in prepared {
            centralDirectory += le32(0x0201_4b50)          // central directory signature
            centralDirectory += le16(20) + le16(20)         // version made by, version needed
            centralDirectory += le16(0)                       // general purpose bit flag
            centralDirectory += le16(0)                       // compression method: stored
            centralDirectory += le16(0) + le16(0)              // mod time, mod date
            centralDirectory += le32(0)                        // crc-32
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(0)                        // extra field length
            centralDirectory += le16(0)                        // file comment length
            centralDirectory += le16(0)                        // disk number start
            centralDirectory += le16(0)                        // internal attributes
            centralDirectory += le32(0)                        // external attributes
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
        }
        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)                       // end of central directory signature
        archive += le16(0) + le16(0)                         // disk number, disk with CD start
        archive += le16(UInt16(entries.count))                // records on this disk
        archive += le16(UInt16(entries.count))                // total records
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)                                     // comment length
        return Data(archive)
    }

    private func doc(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document><w:body>\(body)</w:body></w:document>"
    }

    private func read(
        document: String, styles: String? = nil, numbering: String? = nil, footnotes: String? = nil,
        endnotes: String? = nil
    ) throws -> [OfficeBlock] {
        let zip = buildDocx(document: doc(document), styles: styles, numbering: numbering, footnotes: footnotes, endnotes: endnotes)
        let archive = try ZipArchive(data: zip)
        return try DocxReader.read(archive).blocks
    }

    /// Full result (not just blocks) so page-width parsing off the body `w:sectPr` is assertable.
    private func readResult(
        _ document: String, rels: String? = nil, extraParts: [(path: String, xml: String)] = []
    ) throws -> OfficeReadResult {
        try DocxReader.read(try ZipArchive(data: buildDocx(document: doc(document), rels: rels, extraParts: extraParts)))
    }

    // MARK: page content width (body w:sectPr → pgSz − pgMar, twips÷20 = pt)

    func testPageContentWidthFromBodySectPr() throws {
        // A4: pgSz w:w=11906 twips (595.3pt); pgMar left/right=1701 twips (85pt) → body 425.2pt.
        let r = try readResult(
            "<w:p><w:r><w:t>x</w:t></w:r></w:p>"
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
            + "<w:pgMar w:left=\"1701\" w:right=\"1701\" w:top=\"1440\" w:bottom=\"1440\"/></w:sectPr>")
        XCTAssertEqual(r.pageContentWidth ?? -1, (11906.0 - 1701 - 1701) / 20, accuracy: 0.01)
    }

    func testPageContentWidthNilWhenNoSectPr() throws {
        // No page setup declared → nil → reader keeps window-filling column (byte-identical).
        XCTAssertNil(try readResult("<w:p><w:r><w:t>x</w:t></w:r></w:p>").pageContentWidth)
    }

    func testPageContentWidthUsesFullPageWhenNoMargins() throws {
        // pgSz without pgMar → margins default 0 → body = full page width (US Letter 12240 twips).
        let r = try readResult("<w:sectPr><w:pgSz w:w=\"12240\"/></w:sectPr>")
        XCTAssertEqual(r.pageContentWidth ?? -1, 12240.0 / 20, accuracy: 0.01)  // 612pt
    }

    func testPageContentWidthNilWhenMarginsExceedPage() throws {
        // Degenerate: margins ≥ page → computed ≤0 → nil, never a negative column.
        XCTAssertNil(try readResult(
            "<w:sectPr><w:pgSz w:w=\"2000\"/><w:pgMar w:left=\"1200\" w:right=\"1200\"/></w:sectPr>").pageContentWidth)
    }

    // MARK: page content HEIGHT + top/bottom margins (body w:sectPr → pgSz@w:h − pgMar@top/bottom)

    func testPageContentHeightAndVerticalMarginsFromBodySectPr() throws {
        // The reference document's own declared numbers: h=16838 twips (841.9pt), top=1985 twips
        // (99.25pt), bottom=1418 twips (70.9pt) → content height 841.9 - 99.25 - 70.9 = 671.75pt.
        let r = try readResult(
            "<w:p><w:r><w:t>x</w:t></w:r></w:p>"
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
            + "<w:pgMar w:left=\"1701\" w:right=\"1701\" w:top=\"1985\" w:bottom=\"1418\"/></w:sectPr>")
        XCTAssertEqual(r.pageContentHeight ?? -1, 671.75, accuracy: 0.01)
        XCTAssertEqual(r.pageMarginTop ?? -1, 99.25, accuracy: 0.01)
        XCTAssertEqual(r.pageMarginBottom ?? -1, 70.9, accuracy: 0.01)
        // Width/left/right are untouched by adding height/margins.
        XCTAssertEqual(r.pageContentWidth ?? -1, (11906.0 - 1701 - 1701) / 20, accuracy: 0.01)
    }

    func testPageContentHeightNilWhenNoSectPr() throws {
        let r = try readResult("<w:p><w:r><w:t>x</w:t></w:r></w:p>")
        XCTAssertNil(r.pageContentHeight)
        XCTAssertNil(r.pageMarginTop)
        XCTAssertNil(r.pageMarginBottom)
    }

    func testPageContentHeightNilWhenPgSzHasNoHeightButWidthSurvives() throws {
        // `w:pgSz` with no `w:h` at all → height/top/bottom nil, but width/left/right (which do not
        // depend on height) must be untouched — the two guards are independent.
        let r = try readResult(
            "<w:sectPr><w:pgSz w:w=\"11906\"/><w:pgMar w:left=\"1701\" w:right=\"1701\" w:top=\"1985\" w:bottom=\"1418\"/></w:sectPr>")
        XCTAssertNil(r.pageContentHeight)
        XCTAssertNil(r.pageMarginTop)
        XCTAssertNil(r.pageMarginBottom)
        XCTAssertEqual(r.pageContentWidth ?? -1, (11906.0 - 1701 - 1701) / 20, accuracy: 0.01)
    }

    func testPageContentHeightUsesFullPageWhenNoVerticalMargins() throws {
        // pgSz@w:h without pgMar top/bottom → margins default 0 → height = full page height.
        let r = try readResult("<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/></w:sectPr>")
        XCTAssertEqual(r.pageContentHeight ?? -1, 15840.0 / 20, accuracy: 0.01)  // 792pt
        XCTAssertEqual(r.pageMarginTop ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(r.pageMarginBottom ?? -1, 0, accuracy: 0.01)
    }

    func testPageContentHeightNilWhenVerticalMarginsExceedPage() throws {
        // Degenerate: top+bottom ≥ h → computed ≤0 → nil, but width stays valid (independent guard).
        let r = try readResult(
            "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"2000\"/>"
            + "<w:pgMar w:left=\"1701\" w:right=\"1701\" w:top=\"1200\" w:bottom=\"1200\"/></w:sectPr>")
        XCTAssertNil(r.pageContentHeight)
        XCTAssertNil(r.pageMarginTop)
        XCTAssertNil(r.pageMarginBottom)
        XCTAssertEqual(r.pageContentWidth ?? -1, (11906.0 - 1701 - 1701) / 20, accuracy: 0.01)
    }

    private func read(document: String, rels: String?, media: [(name: String, bytes: [UInt8])] = []) throws -> [OfficeBlock] {
        let zip = buildDocx(document: doc(document), rels: rels, media: media)
        let archive = try ZipArchive(data: zip)
        return try DocxReader.read(archive).blocks
    }

    private func read(document: String, styles: String?, theme: String?) throws -> [OfficeBlock] {
        let zip = buildDocx(document: doc(document), styles: styles, theme: theme)
        let archive = try ZipArchive(data: zip)
        return try DocxReader.read(archive).blocks
    }

    /// A bare 6-digit hex → `NSColor`, matching `DocxReader.colorFromHex`'s own reading — used by
    /// tests to assert an expected literal without reaching into that private function.
    private func rgb(_ hex: String) -> NSColor {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        let value = UInt32(digits, radix: 16)!
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    // MARK: Run reassembly

    func testFiveRunsWithIdenticalFormattingReassembleIntoOneSpan() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Hello</w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>, </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>world</w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>! </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Bye</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Hello, world! Bye", bold: true)])])
    }

    func testRunsWithDifferentFormattingStaySeparateInOrder() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Bold</w:t></w:r>
          <w:r><w:t>Plain</w:t></w:r>
          <w:r><w:rPr><w:i/></w:rPr><w:t>Italic</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "Bold", bold: true),
            Span(text: "Plain"),
            Span(text: "Italic", italic: true),
        ])])
    }

    func testExplicitlyDisabledBoldIsNotBold() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>NotBold</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "NotBold", bold: false)])])
    }

    /// The symptom that named this defect: `appendMerging`'s equality check decides whether two
    /// adjacent runs become ONE span, and it KEEPS THE FIRST run's attributes — so any field it
    /// forgets to compare is not merely "ignored", it is the SECOND run's value being silently
    /// replaced by the first's. Colour, highlight, size and family were all missing, which is why
    /// this is asserted on the resolved value and not just on the span COUNT: a check that only
    /// counted spans would still pass if a future merge kept the second run's colour instead.
    func testTwoRunsDifferingOnlyInColourStayTwoSpansEachKeepingItsOwnColour() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:color w:val="FF0000"/></w:rPr><w:t>Red</w:t></w:r>
          <w:r><w:rPr><w:color w:val="0000FF"/></w:rPr><w:t>Blue</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "Red", textColor: rgb("FF0000")),
            Span(text: "Blue", textColor: rgb("0000FF")),
        ])])
    }

    func testTwoRunsDifferingOnlyInHighlightStayTwoSpansEachKeepingItsOwnHighlight() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:highlight w:val="yellow"/></w:rPr><w:t>Y</w:t></w:r>
          <w:r><w:rPr><w:highlight w:val="green"/></w:rPr><w:t>G</w:t></w:r>
        </w:p>
        """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        guard spans.count == 2 else { return XCTFail("expected two spans, got \(spans.map(\.text))") }
        XCTAssertEqual(spans.map(\.text), ["Y", "G"])
        XCTAssertNotEqual(spans[0].highlightColor, spans[1].highlightColor)
    }

    func testTwoRunsDifferingOnlyInSizeStayTwoSpansEachKeepingItsOwnSize() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:sz w:val="24"/></w:rPr><w:t>Twelve</w:t></w:r>
          <w:r><w:rPr><w:sz w:val="40"/></w:rPr><w:t>Twenty</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "Twelve", fontSize: 12),
            Span(text: "Twenty", fontSize: 20),
        ])])
    }

    /// The one that BLOCKS per-script fonts (`docs/per-script-font-design.md` §5.1): once each run
    /// resolves its own family per script, adjacent runs differ in family constantly, and a merge
    /// that ignores family would flatten exactly what that feature produces.
    func testTwoRunsDifferingOnlyInFontFamilyStayTwoSpansEachKeepingItsOwnFamily() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:rFonts w:ascii="Georgia"/></w:rPr><w:t>Serif</w:t></w:r>
          <w:r><w:rPr><w:rFonts w:ascii="Verdana"/></w:rPr><w:t>Sans</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "Serif", fontName: "Georgia"),
            Span(text: "Sans", fontName: "Verdana"),
        ])])
    }

    /// The other half of the contract, and the reason the guard is a field-by-field comparison
    /// rather than "never merge anything that names a colour/size/family": runs that AGREE must
    /// still collapse. Fragmentation is ~93% of the build stage
    /// (`SpanFragmentationProbeTests`), so a guard that over-splits would trade one defect for a
    /// measured performance regression.
    func testRunsAgreeingOnColourSizeAndFamilyStillMergeIntoOneSpan() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:color w:val="FF0000"/><w:sz w:val="24"/><w:rFonts w:ascii="Georgia"/></w:rPr><w:t>One </w:t></w:r>
          <w:r><w:rPr><w:color w:val="FF0000"/><w:sz w:val="24"/><w:rFonts w:ascii="Georgia"/></w:rPr><w:t>span</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "One span", textColor: rgb("FF0000"), fontSize: 12, fontName: "Georgia"),
        ])])
    }

    /// A completeness guard over the whole `Span` vocabulary rather than the four fields this
    /// defect happened to name: every run property a `.docx` can carry gets one row here, so a
    /// future field added to `Span` and to `buildSpan` but forgotten in `appendMerging` fails HERE
    /// instead of silently smearing across a merge. `code` is deliberately absent — `buildSpan`
    /// hard-codes `code: false` (inline code is a markdown concept; Word has no equivalent run
    /// property), so no `.docx` can produce two runs differing in it. `bookmarks`/`commentIds` are
    /// absent too: those are never compared but never merged either, guarded one line earlier by
    /// their own `isEmpty` check and covered by their own tests.
    func testEveryRunPropertyADocxCanCarryKeepsAdjacentRunsApart() throws {
        let cases: [(field: String, a: String, b: String)] = [
            ("bold", "<w:b/>", ""),
            ("italic", "<w:i/>", ""),
            ("underline", "<w:u/>", ""),
            ("underlineStyle", "<w:u w:val=\"single\"/>", "<w:u w:val=\"double\"/>"),
            ("caps", "<w:caps/>", ""),
            ("smallCaps", "<w:smallCaps/>", ""),
            ("strikethrough", "<w:strike/>", ""),
            ("superscript", "<w:vertAlign w:val=\"superscript\"/>", ""),
            ("subscripted", "<w:vertAlign w:val=\"subscript\"/>", ""),
            ("rtl", "<w:rtl/>", ""),
            ("textColor", "<w:color w:val=\"FF0000\"/>", "<w:color w:val=\"00FF00\"/>"),
            ("highlightColor", "<w:highlight w:val=\"yellow\"/>", "<w:highlight w:val=\"green\"/>"),
            ("fontSize", "<w:sz w:val=\"24\"/>", "<w:sz w:val=\"40\"/>"),
            ("fontName", "<w:rFonts w:ascii=\"Georgia\"/>", "<w:rFonts w:ascii=\"Verdana\"/>"),
        ]
        for (field, a, b) in cases {
            let blocks = try read(document: """
            <w:p>
              <w:r><w:rPr>\(a)</w:rPr><w:t>A</w:t></w:r>
              <w:r><w:rPr>\(b)</w:rPr><w:t>B</w:t></w:r>
            </w:p>
            """)
            guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
            XCTAssertEqual(spans.map(\.text), ["A", "B"],
                           "two runs differing only in \(field) were merged — the second run's \(field) is lost")
        }
    }

    /// `link` is threaded onto the span AFTER `buildSpan` returns (`w:hyperlink` carries its target
    /// as an attribute of a WRAPPER element, not as a run property), so it cannot be expressed as a
    /// `w:rPr` row in the table above and gets its own case.
    func testARunInsideAHyperlinkIsNeverMergedWithTheBareRunBesideIt() throws {
        let blocks = try read(
            document: """
            <w:p>
              <w:hyperlink r:id="rId1"><w:r><w:t>Linked</w:t></w:r></w:hyperlink>
              <w:r><w:t>Bare</w:t></w:r>
            </w:p>
            """,
            rels: """
            <?xml version="1.0" encoding="UTF-8"?><Relationships>
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com" TargetMode="External"/>
            </Relationships>
            """)
        guard case .paragraph(let spans, _, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        guard spans.count == 2 else { return XCTFail("expected two spans, got \(spans.map(\.text))") }
        XCTAssertEqual(spans.map(\.text), ["Linked", "Bare"])
        XCTAssertEqual(spans[0].link, "https://example.com")
        XCTAssertNil(spans[1].link)
    }

    // MARK: Headings via outlineLvl

    private let headingStyles = """
    <w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading2"><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading3"><w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading4"><w:pPr><w:outlineLvl w:val="3"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading5"><w:pPr><w:outlineLvl w:val="4"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading6"><w:pPr><w:outlineLvl w:val="5"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading7"><w:pPr><w:outlineLvl w:val="6"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading8"><w:pPr><w:outlineLvl w:val="7"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading9"><w:pPr><w:outlineLvl w:val="8"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="TOCHeading"><w:pPr><w:outlineLvl w:val="9"/></w:pPr></w:style>
    </w:styles>
    """

    func testOutlineLevelsZeroThroughFiveMapToHeadingLevelsOneThroughSix() throws {
        let paragraphs = (1...6).map { "<w:p><w:pPr><w:pStyle w:val=\"Heading\($0)\"/></w:pPr><w:r><w:t>H\($0)</w:t></w:r></w:p>" }
        let blocks = try read(document: paragraphs.joined(), styles: headingStyles)
        XCTAssertEqual(blocks, (1...6).map { .heading(level: $0, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelsSixSevenEightClampToHeadingLevelSix() throws {
        let paragraphs = (7...9).map { "<w:p><w:pPr><w:pStyle w:val=\"Heading\($0)\"/></w:pPr><w:r><w:t>H\($0)</w:t></w:r></w:p>" }
        let blocks = try read(document: paragraphs.joined(), styles: headingStyles)
        XCTAssertEqual(blocks, (7...9).map { .heading(level: 6, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelNineIsNotAHeading() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"TOCHeading\"/></w:pPr><w:r><w:t>Contents</w:t></w:r></w:p>",
            styles: headingStyles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Contents")])])
    }

    func testUnknownParagraphStyleIsAnOrdinaryParagraph() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Compact\"/></w:pPr><w:r><w:t>Text</w:t></w:r></w:p>",
            styles: headingStyles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")])])
    }

    // MARK: S3 — the three ways Word marks a heading (mechanisms a/b/c of the sprint brief)

    /// Mechanism (a): a paragraph can be marked a heading directly, via its OWN `w:pPr/w:outlineLvl`,
    /// with no style involved at all.
    func testParagraphOwnOutlineLvlIsAHeadingWithNoStyleAtAll() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:r><w:t>Direct</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Direct")])])
    }

    /// Mechanism (a)'s own TOCHeading guard: a paragraph's own `outlineLvl` of 9 is not a heading
    /// either — the same rule as a style-level 9, now checked at the paragraph level.
    func testParagraphOwnOutlineLvlNineIsNotAHeading() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:outlineLvl w:val="9"/></w:pPr><w:r><w:t>Contents</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Contents")])])
    }

    /// Mechanism (b): `Heading3`'s style DEFINITION carries no `w:outlineLvl` at all — Word very
    /// often omits it because the built-in id already says what it is — and it must still be read
    /// as a level-3 heading, purely from the id.
    func testBuiltInHeadingStyleIdWithNoOutlineLvlInItsOwnDefinitionIsStillAHeading() throws {
        let styles = "<w:styles><w:style w:type=\"paragraph\" w:styleId=\"Heading3\"/></w:styles>"
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Heading3\"/></w:pPr><w:r><w:t>No outlineLvl</w:t></w:r></w:p>",
            styles: styles)
        XCTAssertEqual(blocks, [.heading(level: 3, spans: [Span(text: "No outlineLvl")])])
    }

    /// Mechanism (c): a CUSTOM style based on `Heading2` — carrying no `w:outlineLvl` of its own,
    /// and `Heading2`'s own definition also carrying none (mechanism (b)'s whole premise) — must
    /// resolve to level 2 by walking the `w:basedOn` chain up to the built-in id.
    func testCustomStyleBasedOnHeading2WithNoOutlineLvlAnywhereInTheChainIsStillAHeading() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="Heading2"/>
          <w:style w:type="paragraph" w:styleId="ClauseHeading"><w:basedOn w:val="Heading2"/></w:style>
        </w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"ClauseHeading\"/></w:pPr><w:r><w:t>Inherited</w:t></w:r></w:p>",
            styles: styles)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Inherited")])])
    }

    /// A `w:basedOn` CYCLE (malformed document) must not hang the reader — the walk detects the
    /// revisit and reports "not a heading" instead of looping forever.
    func testBasedOnCycleDoesNotHangAndIsNotTreatedAsAHeading() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="A"><w:basedOn w:val="B"/></w:style>
          <w:style w:type="paragraph" w:styleId="B"><w:basedOn w:val="A"/></w:style>
        </w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"A\"/></w:pPr><w:r><w:t>Cycle</w:t></w:r></w:p>",
            styles: styles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Cycle")])])
    }

    // MARK: Empty markers and revision wrappers

    func testBookmarksAndProofErrProduceNoPhantomSpansAndDoNotSplitARunPair() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>A</w:t></w:r>
          <w:bookmarkStart w:id="0" w:name="_GoBack"/>
          <w:bookmarkEnd w:id="0"/>
          <w:proofErr w:type="spellStart"/>
          <w:r><w:rPr><w:b/></w:rPr><w:t>B</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "AB", bold: true)])])
    }

    func testDeletedContentIsSkippedAndInsertedContentIsKept() throws {
        let blocks = try read(document: """
        <w:p>
          <w:del w:id="1" w:author="x"><w:r><w:delText>Deleted</w:delText></w:r></w:del>
          <w:ins w:id="2" w:author="x"><w:r><w:t>Inserted</w:t></w:r></w:ins>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Inserted")])])
    }

    // MARK: Tracked moves — S6 item 1: a guaranteed duplication bug before this fix
    //
    // `w:moveFrom` wraps the moved text at its ORIGINAL location, `w:moveTo` wraps the SAME text
    // at its NEW one. Before this fix neither name was excluded from `collectSpans`'s permissive
    // walk, so both rendered — every tracked move duplicated its own text, 100% reproducibly.

    /// The core acceptance case from the sprint brief: the moved text appears EXACTLY ONCE, at the
    /// new location — never at the old one, and never twice.
    func testTrackedMoveRendersItsTextExactlyOnceFromTheNewLocation() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:t>Before </w:t></w:r>
          <w:moveFrom w:id="1" w:author="x"><w:r><w:t>Moved</w:t></w:r></w:moveFrom>
          <w:r><w:t>after</w:t></w:r>
        </w:p>
        <w:p>
          <w:moveTo w:id="2" w:author="x"><w:r><w:t>Moved</w:t></w:r></w:moveTo>
        </w:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Before after")]),
            .paragraph(spans: [Span(text: "Moved")]),
        ])
        // Belt-and-braces on the acceptance criterion itself, not just structural equality above:
        // the word "Moved" must occur exactly once across the whole document.
        let fullText = blocks.compactMap { block -> String? in
            if case .paragraph(let spans, _, _, _, _) = block { return spans.map(\.text).joined() }
            return nil
        }.joined()
        XCTAssertEqual(fullText.components(separatedBy: "Moved").count - 1, 1,
                       "a tracked move must render its text exactly once, not once per location")
    }

    /// `w:moveFromRangeStart`/`w:moveFromRangeEnd` are empty boundary markers (no `w:t` of their
    /// own) — must not contribute any text even though they sit right next to real content.
    func testMoveFromRangeMarkersContributeNoText() throws {
        let blocks = try read(document: """
        <w:p>
          <w:moveFromRangeStart w:id="1" w:author="x" w:name="move1"/>
          <w:r><w:t>Kept</w:t></w:r>
          <w:moveFromRangeEnd w:id="1"/>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Kept")])])
    }

    // MARK: Breaks, tabs, whitespace

    func testLineBreakAndTabSurviveIntoText() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>Line1</w:t><w:br/><w:t>Line2</w:t><w:tab/><w:t>Col2</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Line1\nLine2\tCol2")])])
    }

    func testPreserveSpaceKeepsLeadingAndTrailingSpaces() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t xml:space="preserve">  spaced  </w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "  spaced  ")])])
    }

    /// CLAUDE.md S2 item 2: `w:noBreakHyphen`, `w:softHyphen` and `w:ptab` are text, and used to be
    /// silently dropped by `buildSpan`'s `default: continue` — the author's character just vanished.
    func testNoBreakHyphenSurvivesAsNonBreakingHyphen() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>well</w:t><w:noBreakHyphen/><w:t>known</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "well\u{2011}known")])])
    }

    func testSoftHyphenSurvivesAsSoftHyphen() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>super</w:t><w:softHyphen/><w:t>cali</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "super\u{00AD}cali")])])
    }

    func testPtabSurvivesAsTab() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>Col1</w:t><w:ptab w:relativeTo="margin" w:alignment="left" w:leader="none"/><w:t>Col2</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Col1\tCol2")])])
    }

    // MARK: Lists

    private let bulletThenDecimalNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="1">
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="5"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """

    func testNestedListLevelsAndFormatsResolveViaNumbering() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Bullet</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Decimal</w:t></w:r></w:p>
        """, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: false, spans: [Span(text: "Bullet")]),
            .listItem(level: 1, ordered: true, spans: [Span(text: "Decimal")]),
        ])
    }

    func testHeadingStyleWithNumPrStillEmitsHeadingNotListItem() throws {
        let blocks = try read(
            document: """
            <w:p>
              <w:pPr>
                <w:pStyle w:val="Heading2"/>
                <w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr>
              </w:pPr>
              <w:r><w:t>Interpretation</w:t></w:r>
            </w:p>
            """,
            styles: headingStyles, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Interpretation")])])
    }

    func testNumPrWithoutHeadingStyleStillEmitsListItem() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>
        """, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    func testOutlineLevelNineWithNumPrStillEmitsListItem() throws {
        let blocks = try read(
            document: """
            <w:p>
              <w:pPr>
                <w:pStyle w:val="TOCHeading"/>
                <w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr>
              </w:pPr>
              <w:r><w:t>Contents</w:t></w:r>
            </w:p>
            """,
            styles: headingStyles, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 1, ordered: true, spans: [Span(text: "Contents")])])
    }

    func testMissingNumberingXMLDefaultsListsToUnordered() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    // MARK: S5 — clause and list numbering (the reader computes marker text)

    /// `%1.` decimal at level 0, `%1.%2` decimal.lowerLetter at level 1 — the shape a real
    /// multi-level clause numbering uses.
    private let clauseNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="1">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="7"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """

    private func numberedItem(_ numId: String, _ ilvl: Int, _ text: String) -> String {
        "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    /// Mechanism: counters continue across an intervening PLAIN paragraph. A document with no
    /// interruption at all would pass this same assertion for the wrong reason (nothing to reset
    /// in the first place), so this specifically inserts a non-list paragraph between two level-0
    /// items and asserts the second is still "2.", not "1." again.
    func testCounterContinuesAcrossAnInterveningPlainParagraph() throws {
        let blocks = try read(document: """
        \(numberedItem("7", 0, "First"))
        <w:p><w:r><w:t>Ordinary paragraph in between.</w:t></w:r></w:p>
        \(numberedItem("7", 0, "Second"))
        """, numbering: clauseNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "First")], marker: "1."),
            .paragraph(spans: [Span(text: "Ordinary paragraph in between.")]),
            .listItem(level: 0, ordered: true, spans: [Span(text: "Second")], marker: "2."),
        ])
    }

    /// Mechanism: a shallower item resets deeper levels; a deeper run does not disturb the
    /// shallower counter (`1. / a. / b. / 2.`, mirroring the old builder-side rule now proven at
    /// the numId granularity the reader itself uses).
    func testShallowerItemResetsDeeperLevelsButDeeperRunDoesNotDisturbShallower() throws {
        let blocks = try read(document: """
        \(numberedItem("7", 0, "One"))
        \(numberedItem("7", 1, "a"))
        \(numberedItem("7", 1, "b"))
        \(numberedItem("7", 0, "Two"))
        \(numberedItem("7", 1, "restart"))
        """, numbering: clauseNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")], marker: "1."),
            .listItem(level: 1, ordered: true, spans: [Span(text: "a")], marker: "1.a"),
            .listItem(level: 1, ordered: true, spans: [Span(text: "b")], marker: "1.b"),
            .listItem(level: 0, ordered: true, spans: [Span(text: "Two")], marker: "2."),
            .listItem(level: 1, ordered: true, spans: [Span(text: "restart")], marker: "2.a"),
        ])
    }

    /// Mechanism: `%1.%2.%3` with level 2 in letters (per its own `w:numFmt`), levels 1/3 decimal.
    func testThreeLevelLvlTextSubstitutesEachLevelsOwnFormat() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="2">
            <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1"/></w:lvl>
            <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2"/></w:lvl>
            <w:lvl w:ilvl="2"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2.%3"/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="3"><w:abstractNumId w:val="2"/></w:num>
        </w:numbering>
        """
        let blocks = try read(document: """
        \(numberedItem("3", 0, "One"))
        \(numberedItem("3", 1, "a"))
        \(numberedItem("3", 2, "deep"))
        """, numbering: numbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")], marker: "1"),
            .listItem(level: 1, ordered: true, spans: [Span(text: "a")], marker: "1.a"),
            .listItem(level: 2, ordered: true, spans: [Span(text: "deep")], marker: "1.a.1"),
        ])
    }

    /// Mechanism: `w:startOverride` of 5 produces 5.
    func testStartOverrideChangesTheFirstValueEmitted() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="8">
            <w:abstractNumId w:val="1"/>
            <w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride>
          </w:num>
        </w:numbering>
        """
        let blocks = try read(document: numberedItem("8", 0, "Fifth"), numbering: numbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Fifth")], marker: "5.")])
    }

    /// Mechanism: `w:lvlOverride/w:lvl` replaces the WHOLE level definition for this numId only —
    /// here swapping decimal for upperRoman, which a shared-abstract-num lookup alone could never
    /// produce.
    func testLvlOverrideReplacingALevelDefinitionTakesEffect() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="8">
            <w:abstractNumId w:val="1"/>
            <w:lvlOverride w:ilvl="0">
              <w:lvl w:ilvl="0"><w:numFmt w:val="upperRoman"/><w:lvlText w:val="%1."/></w:lvl>
            </w:lvlOverride>
          </w:num>
        </w:numbering>
        """
        let blocks = try read(document: """
        \(numberedItem("8", 0, "One"))
        \(numberedItem("8", 0, "Two"))
        """, numbering: numbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")], marker: "I."),
            .listItem(level: 0, ordered: true, spans: [Span(text: "Two")], marker: "II."),
        ])
    }

    /// Mechanism: `numId="0"` is Word's sentinel for "not numbered at all" — a plain paragraph,
    /// never a `.listItem`, regardless of whatever `word/numbering.xml` otherwise contains.
    func testNumIdZeroProducesAPlainParagraphNotAListItem() throws {
        let blocks = try read(document: numberedItem("0", 0, "Not a list"), numbering: clauseNumbering)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Not a list")])])
    }

    /// Mechanism: upper/lower Roman and upper/lower letter formats.
    func testRomanAndLetterFormatsUpperAndLower() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="4">
            <w:lvl w:ilvl="0"><w:numFmt w:val="upperRoman"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="5">
            <w:lvl w:ilvl="0"><w:numFmt w:val="lowerRoman"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="6">
            <w:lvl w:ilvl="0"><w:numFmt w:val="upperLetter"/><w:lvlText w:val="%1)"/></w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="7">
            <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1)"/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="40"><w:abstractNumId w:val="4"/></w:num>
          <w:num w:numId="50"><w:abstractNumId w:val="5"/></w:num>
          <w:num w:numId="60"><w:abstractNumId w:val="6"/></w:num>
          <w:num w:numId="70"><w:abstractNumId w:val="7"/></w:num>
        </w:numbering>
        """
        // Four INDEPENDENT numIds, each incremented three times, so a run of 1/2/3 in each format
        // is checked rather than just its first value.
        let body = (1...3).map { numberedItem("40", 0, "R\($0)") }.joined()
            + (1...3).map { numberedItem("50", 0, "r\($0)") }.joined()
            + (1...3).map { numberedItem("60", 0, "L\($0)") }.joined()
            + (1...3).map { numberedItem("70", 0, "l\($0)") }.joined()
        let blocks = try read(document: body, numbering: numbering)
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(_, _, _, let marker, _, _, _, _) = block { return marker }
            return nil
        }
        XCTAssertEqual(markers, [
            "I.", "II.", "III.",
            "i.", "ii.", "iii.",
            "A)", "B)", "C)",
            "a)", "b)", "c)",
        ])
    }

    /// Mechanism: an unknown `w:numFmt` falls back to decimal and still produces a number, rather
    /// than throwing or leaving the marker blank.
    func testUnknownNumFmtFallsBackToDecimal() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="chineseCounting"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="9"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        let blocks = try read(document: numberedItem("9", 0, "Item"), numbering: numbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Item")], marker: "1.")])
    }

    /// Mechanism: an unresolvable numId (absent from `word/numbering.xml` entirely) still produces
    /// today's pre-sprint fallback — unordered, no fabricated marker — never a made-up number.
    func testUnresolvableNumIdStillFallsBackRatherThanFabricatingANumber() throws {
        let blocks = try read(document: numberedItem("999", 0, "Item"), numbering: clauseNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    // MARK: numFmt — non-Latin numbering (P2R — §17.18.59 ST_NumberFormat)

    /// `ideographDigital` is DIGIT SUBSTITUTION (one ideograph per decimal digit), not positional
    /// Chinese counting — `12` becomes `一二`, not `十二`. Three independent increments so the
    /// substitution is checked across more than the first digit.
    func testIdeographDigitalNumFmtSubstitutesCjkNumeralsPerDigit() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="ideographDigital"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="9"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        let body = (1...3).map { numberedItem("9", 0, "Item\($0)") }.joined()
        let blocks = try read(document: body, numbering: numbering)
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(_, _, _, let marker, _, _, _, _) = block { return marker }
            return nil
        }
        XCTAssertEqual(markers, ["一.", "二.", "三."])
    }

    func testKoreanDigitalNumFmtSubstitutesHangulNumeralsPerDigit() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="koreanDigital"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="9"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        let blocks = try read(document: numberedItem("9", 0, "Item"), numbering: numbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Item")], marker: "일.")])
    }

    /// `decimalEnclosedCircle` — Word's circled-number style (①②③…), covered here only within
    /// Unicode's single-glyph range (1–20); outside that range the format falls back to plain
    /// decimal rather than fabricating a glyph (see `formatNumber`'s own doc).
    func testDecimalEnclosedCircleNumFmtRendersCircledDigits() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="decimalEnclosedCircle"/><w:lvlText w:val="%1"/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="9"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        let body = (1...3).map { numberedItem("9", 0, "Item\($0)") }.joined()
        let blocks = try read(document: body, numbering: numbering)
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(_, _, _, let marker, _, _, _, _) = block { return marker }
            return nil
        }
        XCTAssertEqual(markers, ["\u{2460}", "\u{2461}", "\u{2462}"])
    }

    // MARK: Heading numbering — a HeadingN style's own numPr renders into the heading's text
    //
    // Reference document's own shape (a real Korean services contract): numId 1 → abstractNumId
    // 7, ilvl0 decimal "%1." suff=space, ilvl1 decimal "%1.%2." suff=nothing, ilvl2 ganada "%3."
    // suff=nothing — and the heading PARAGRAPHS carry only `w:pStyle`; the `w:numPr` lives on the
    // `HeadingN` STYLE definitions in `styles.xml`, which is exactly what `resolvedNumPr`'s
    // `w:basedOn` walk exists to reach.

    private let headingClauseNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="7">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:suff w:val="space"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2."/><w:suff w:val="nothing"/></w:lvl>
        <w:lvl w:ilvl="2"><w:numFmt w:val="ganada"/><w:lvlText w:val="%3."/><w:suff w:val="nothing"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="1"><w:abstractNumId w:val="7"/></w:num>
    </w:numbering>
    """

    /// `w:numPr` on the STYLE, never on the paragraph — mirrors the reference document exactly.
    private let numberedHeadingStyles = """
    <w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1">
        <w:pPr><w:outlineLvl w:val="0"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading2">
        <w:pPr><w:outlineLvl w:val="1"/><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr></w:pPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading3">
        <w:pPr><w:outlineLvl w:val="2"/><w:numPr><w:ilvl w:val="2"/><w:numId w:val="1"/></w:numPr></w:pPr>
      </w:style>
    </w:styles>
    """

    /// (a) The core mechanism this sprint exists for: numbering declared on the STYLE, never
    /// repeated on the paragraph, still produces the marker — the exact shape that used to render
    /// "서비스 사용" with no leading "1." at all.
    func testHeadingNumberingDeclaredOnTheStyleNotTheParagraphProducesTheMarker() throws {
        let blocks = try read(
            document: """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>서비스 사용</w:t></w:r></w:p>
            """,
            styles: numberedHeadingStyles, numbering: headingClauseNumbering)
        XCTAssertEqual(blocks, [
            .heading(level: 1, spans: [Span(text: "1. "), Span(text: "서비스 사용")]),
        ])
    }

    /// (b) The multi-level case: a level-0 heading followed by two level-1 headings gives
    /// "1." then "1.1." then "1.2." — the level-0 counter feeding `%1` without being re-incremented
    /// by the level-1 items, exactly as `testShallowerItemResetsDeeperLevelsButDeeperRunDoesNotDisturbShallower`
    /// already proves for plain list items.
    func testHeadingNumberingMultiLevelGivesOneThenOnePointOneThenOnePointTwo() throws {
        let blocks = try read(
            document: """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>서비스 사용</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>서비스 신규 신청</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>서비스 이용 정지</w:t></w:r></w:p>
            """,
            styles: numberedHeadingStyles, numbering: headingClauseNumbering)
        XCTAssertEqual(blocks, [
            .heading(level: 1, spans: [Span(text: "1. "), Span(text: "서비스 사용")]),
            .heading(level: 2, spans: [Span(text: "1.1."), Span(text: "서비스 신규 신청")]),
            .heading(level: 2, spans: [Span(text: "1.2."), Span(text: "서비스 이용 정지")]),
        ])
    }

    /// (c) `ganada` at ilvl2 gives 가. 나. 다. — the format the reference document actually uses
    /// for its third heading level.
    func testHeadingNumberingGanadaGivesGaNaDa() throws {
        let blocks = try read(
            document: """
            <w:p><w:pPr><w:pStyle w:val="Heading3"/></w:pPr><w:r><w:t>First</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading3"/></w:pPr><w:r><w:t>Second</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading3"/></w:pPr><w:r><w:t>Third</w:t></w:r></w:p>
            """,
            styles: numberedHeadingStyles, numbering: headingClauseNumbering)
        XCTAssertEqual(blocks, [
            .heading(level: 3, spans: [Span(text: "가."), Span(text: "First")]),
            .heading(level: 3, spans: [Span(text: "나."), Span(text: "Second")]),
            .heading(level: 3, spans: [Span(text: "다."), Span(text: "Third")]),
        ])
    }

    /// (d) `w:suff="space"` (ilvl0) yields a literal space between marker and suffix; `w:suff="nothing"`
    /// (ilvl1) yields none at all — asserted directly against the exact marker-span text rather
    /// than inferred from (a)/(b) above.
    func testSuffSpaceYieldsASpaceAndSuffNothingYieldsNone() throws {
        let blocks = try read(
            document: """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Top</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Sub</w:t></w:r></w:p>
            """,
            styles: numberedHeadingStyles, numbering: headingClauseNumbering)
        guard case .heading(_, let topSpans, _, _, _, _) = blocks[0],
              case .heading(_, let subSpans, _, _, _, _) = blocks[1]
        else { return XCTFail("expected two headings") }
        XCTAssertEqual(topSpans.first?.text, "1. ", "suff=space must produce a trailing space")
        XCTAssertEqual(subSpans.first?.text, "1.1.", "suff=nothing must produce no trailing separator at all")
    }

    /// (e) invariant 37's own contract, restated for this sprint: a heading with NO numbering
    /// anywhere (no styleNumbering, no numbering.xml at all) renders byte-identical to every
    /// pre-sprint heading test above it in this file — a single span, no marker prepended.
    func testHeadingWithNoNumberingAnywhereIsUnchanged() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Heading2\"/></w:pPr><w:r><w:t>Plain heading</w:t></w:r></w:p>",
            styles: headingStyles)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Plain heading")])])
    }

    /// (f) the marker span carries the heading's own run formatting (bold + size here), never a
    /// reader-invented default — it is a copy of `spans[0]` with only its text replaced.
    func testMarkerSpanCarriesTheHeadingsOwnBoldAndSize() throws {
        let blocks = try read(
            document: """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
              <w:r><w:rPr><w:b/><w:sz w:val="32"/></w:rPr><w:t>서비스 사용</w:t></w:r>
            </w:p>
            """,
            styles: numberedHeadingStyles, numbering: headingClauseNumbering)
        XCTAssertEqual(blocks, [
            .heading(level: 1, spans: [
                Span(text: "1. ", bold: true, fontSize: 16),
                Span(text: "서비스 사용", bold: true, fontSize: 16),
            ]),
        ])
    }

    // MARK: Tables

    func testTwoByTwoTableWithAnEmptyCellKeepsShapeAndReportsHeaderRow() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr><w:trPr><w:tblHeader/></w:trPr>
            <w:tc><w:p><w:r><w:t>H1</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>H2</w:t></w:r></w:p></w:tc>
          </w:tr>
          <w:tr>
            <w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc>
            <w:tc><w:p></w:p></w:tc>
          </w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "H1")]), Cell(spans: [Span(text: "H2")])],
            // A cell whose only content is Word's own placeholder `<w:p></w:p>` is truly empty —
            // `Cell(blocks: [])`, no phantom `.paragraph(spans: [])` (see `collectCellBlocks`).
            [Cell(spans: [Span(text: "A1")]), Cell(blocks: [])],
        ], headerRows: 1)])
    }

    func testTableWithNoTblHeaderMarkerReportsZeroHeaderRows() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>D</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "A")]), Cell(spans: [Span(text: "B")])],
            [Cell(spans: [Span(text: "C")]), Cell(spans: [Span(text: "D")])],
        ], headerRows: 0)])
    }

    // MARK: Tables — merged cells (corpus-measured: 31 gridSpan / 16 vMerge in the TAGO guide,
    // 13 of those 16 with no `w:val` at all)

    private func tc(_ cellXML: String) -> String { "<w:tc>\(cellXML)</w:tc>" }
    private func para(_ text: String) -> String { "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>" }

    /// The #1 footgun, and the majority case in the real corpus: a bare `<w:vMerge/>` with no
    /// `w:val` means CONTINUE, not restart. A reader that gets this backwards turns a real vertical
    /// merge into two separate one-row cells and silently loses the span.
    func testBareVMergeWithNoValContinuesTheMergeAbove() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>
            \(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))
            \(tc(para("B0")))
          </w:tr>
          <w:tr>
            \(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para(""))"))
            \(tc(para("B1")))
          </w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 2), Cell(spans: [Span(text: "B0")])],
            [Cell(spans: [Span(text: "B1")])],
        ], headerRows: 0)])
    }

    /// Same as above but with an EXPLICIT `val="continue"` — the non-default spelling of the same
    /// footgun, kept as its own test since a reader could special-case the missing-attribute form
    /// and still mishandle this one.
    func testExplicitValContinueAlsoContinuesTheMerge() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"continue\"/></w:tcPr>\(para(""))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 2)],
            [],
        ], headerRows: 0)])
    }

    /// Word routinely leaves stale leftover paragraph text inside a `continue` cell from before the
    /// merge existed — that text is dead and must never surface as a phantom extra line.
    func testStaleContentInAContinueCellIsDiscardedNotRendered() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para("Leftover stale text"))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 2)],
            [],
        ], headerRows: 0)])
    }

    /// A three-row chain: `restart` then two bare `continue`s must accumulate `rowSpan` to 3, not
    /// reset or double-count partway through.
    func testThreeRowVerticalMergeAccumulatesRowSpanAcrossTwoContinuations() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para(""))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para(""))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 3)],
            [],
            [],
        ], headerRows: 0)])
    }

    func testGridSpanSetsColSpanOnTheAnchorCell() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:gridSpan w:val=\"3\"/></w:tcPr>\(para("Title band"))"))</w:tr>
          <w:tr>\(tc(para("A")))\(tc(para("B")))\(tc(para("C")))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Title band")], colSpan: 3)],
            [Cell(spans: [Span(text: "A")]), Cell(spans: [Span(text: "B")]), Cell(spans: [Span(text: "C")])],
        ], headerRows: 0)])
    }

    /// A merged 2×2 region: row N's anchor is BOTH `gridSpan`'d and `vMerge`'d, row N+1's matching
    /// cell is a `gridSpan`'d `continue` — both the column-span and the row-span must land on the
    /// SAME logical cell, and the covered 2-column-wide footprint in row N+1 must vanish entirely
    /// (not leave one of its two columns behind as a phantom cell).
    func testCombinedGridSpanAndVMergeAppliesBothSpansToTheSameCell() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>
            \(tc("<w:tcPr><w:gridSpan w:val=\"2\"/><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Merged"))"))
            \(tc(para("Side0")))
          </w:tr>
          <w:tr>
            \(tc("<w:tcPr><w:gridSpan w:val=\"2\"/><w:vMerge/></w:tcPr>\(para(""))"))
            \(tc(para("Side1")))
          </w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Merged")], rowSpan: 2, colSpan: 2), Cell(spans: [Span(text: "Side0")])],
            [Cell(spans: [Span(text: "Side1")])],
        ], headerRows: 0)])
    }

    /// A `continue` cell whose grid column has NO open merge above it (a malformed/hand-edited
    /// document — there is no `restart` anywhere earlier at that column) must not be fabricated
    /// into a normal cell of its own; it is simply dropped, same as a genuinely covered position.
    func testContinueWithNoOpenMergeAboveIsDroppedNotFabricatedIntoANewCell() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc(para("A0")))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para("Orphaned"))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "A0")])],
            [],
        ], headerRows: 0)])
    }

    // MARK: Tables — w:tblGrid → columnWidths (P3, jagged-column fix)

    /// The table's own `w:tblGrid` is the AUTHORITATIVE column-width source — 2000/2000/6000
    /// twips converted to 100/100/300 points (÷20, the same conversion `cellWidth` uses for a
    /// per-cell `w:tcW`), in grid order.
    func testTblGridColumnsAreReadAsPointsInGridOrder() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tblGrid>
            <w:gridCol w:w="2000"/>
            <w:gridCol w:w="2000"/>
            <w:gridCol w:w="6000"/>
          </w:tblGrid>
          <w:tr>\(tc(para("A")))\(tc(para("B")))\(tc(para("C")))</w:tr>
        </w:tbl>
        """)
        guard case .table(_, _, let columnWidths, _) = blocks.first else { return XCTFail("expected a table block") }
        XCTAssertEqual(columnWidths, [100, 100, 300])
    }

    /// A table with no `w:tblGrid` at all reports `columnWidths: []` — "no grid known" — so the
    /// builder falls back to its pre-existing per-cell/auto layout.
    func testTableWithNoTblGridReportsEmptyColumnWidths() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc(para("A")))\(tc(para("B")))</w:tr>
        </w:tbl>
        """)
        guard case .table(_, _, let columnWidths, _) = blocks.first else { return XCTFail("expected a table block") }
        XCTAssertEqual(columnWidths, [])
    }

    /// A content control inside a table cell — a very common Word form/template shape ("click
    /// here to enter a value" inside a template row) — must not make that cell's text disappear.
    /// This is the THIRD place `w:sdt` can wrap real content (body-level and inline-in-a-paragraph
    /// are covered above); a table cell is a distinct code path and was the one this fix closes.
    func testContentControlInsideATableCellIsUnwrappedNotDropped() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr>\(tc("<w:sdt><w:sdtPr/><w:sdtContent>\(para("Filled in"))</w:sdtContent></w:sdt>"))</w:tr></w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [[Cell(spans: [Span(text: "Filled in")])]], headerRows: 0)])
    }

    // MARK: S8 — images, lists (and their combination) inside table cells (gap-list rows 6/7)

    /// `%1.` decimal at level 0 only — a simpler numbering def than `clauseNumbering`, used where a
    /// test only needs one level of real ordered-marker text.
    private let flatDecimalNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="3">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="7"><w:abstractNumId w:val="3"/></w:num>
    </w:numbering>
    """

    private let bulletNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="4">
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="\u{f0b7}"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="8"><w:abstractNumId w:val="4"/></w:num>
    </w:numbering>
    """

    func testImageInsideTableCellProducesAnImageBlockWithReservedSize() throws {
        let zip = buildDocx(
            document: doc("<w:tbl><w:tr>\(tc("<w:p><w:r>\(drawing(cx: 914_400, cy: 457_200, embed: "rId1"))</w:r></w:p>"))</w:tr></w:tbl>"),
            rels: rels([(id: "rId1", target: "media/image1.png", external: false)]))
        let blocks = try DocxReader.read(try ZipArchive(data: zip)).blocks
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(blocks: [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 36))])],
        ], headerRows: 0)])
    }

    /// A cell's numbered list must continue the DOCUMENT's own numbering, not restart at 1 — a
    /// numId's counters are document-scoped in Word, which continues them across an intervening
    /// table exactly as it does across an ordinary paragraph. Item before the table is "1.", the
    /// cell's own item is "2.", the item after the table is "3." — a restart would show "1." twice.
    func testNumberedListInsideTableCellContinuesTheDocumentsNumbering() throws {
        let document = """
        \(numberedItem("7", 0, "Before"))
        <w:tbl><w:tr>\(tc(numberedItem("7", 0, "In cell")))</w:tr></w:tbl>
        \(numberedItem("7", 0, "After"))
        """
        let blocks = try read(document: document, numbering: flatDecimalNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "Before")], marker: "1."),
            .table(rows: [
                [Cell(blocks: [.listItem(level: 0, ordered: true, spans: [Span(text: "In cell")], marker: "2.")])],
            ], headerRows: 0),
            .listItem(level: 0, ordered: true, spans: [Span(text: "After")], marker: "3."),
        ])
    }

    func testBulletedListInsideTableCellKeepsBullets() throws {
        let document = "<w:tbl><w:tr>\(tc(numberedItem("8", 0, "Bullet item")))</w:tr></w:tbl>"
        let blocks = try read(document: document, numbering: bulletNumbering)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(blocks: [.listItem(level: 0, ordered: false, spans: [Span(text: "Bullet item")])])],
        ], headerRows: 0)])
    }

    /// Text, then a numbered list item, then an image, all inside ONE cell — must keep all three, in
    /// the order the source wrote them, exactly like a paragraph carrying its own trailing picture
    /// does at the body level (`parseParagraph`'s doc comment).
    func testMixedContentInTableCellKeepsTextListAndImageInSourceOrder() throws {
        let cellXML = para("Intro") + numberedItem("7", 0, "Listed")
            + "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId1"))</w:r></w:p>"
        let zip = buildDocx(
            document: doc("<w:tbl><w:tr>\(tc(cellXML))</w:tr></w:tbl>"), numbering: flatDecimalNumbering,
            rels: rels([(id: "rId1", target: "media/image1.png", external: false)]))
        let blocks = try DocxReader.read(try ZipArchive(data: zip)).blocks
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(blocks: [
                .paragraph(spans: [Span(text: "Intro")]),
                .listItem(level: 0, ordered: true, spans: [Span(text: "Listed")], marker: "1."),
                .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
            ])],
        ], headerRows: 0)])
    }

    /// The vertical-merge continuation rule (invariant: a `continue` cell's content is DISCARDED,
    /// never rendered) must hold even when that discarded content is an image, not text — a naive
    /// fix that only special-cased spans could resurrect a picture from a stale merge remnant.
    func testMergeContinuationCellWithAnImageStillContributesNothing() throws {
        let document = """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr><w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId1"))</w:r></w:p>"))</w:tr>
        </w:tbl>
        """
        let zip = buildDocx(document: doc(document), rels: rels([(id: "rId1", target: "media/image1.png", external: false)]))
        let blocks = try DocxReader.read(try ZipArchive(data: zip)).blocks
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 2)],
            [],
        ], headerRows: 0)])
    }

    /// A cell whose only content is Word's own placeholder `<w:p></w:p>` must produce no block at
    /// all — `Cell(blocks: [])`, never a phantom `.paragraph(spans: [])`.
    func testEmptyCellProducesNoPhantomBlock() throws {
        let blocks = try read(document: "<w:tbl><w:tr>\(tc("<w:p></w:p>"))</w:tr></w:tbl>")
        XCTAssertEqual(blocks, [.table(rows: [[Cell(blocks: [])]], headerRows: 0)])
    }

    /// A `<w:tbl>` nested directly inside a `<w:tc>` — `Cell` has no case for a nested `.table`
    /// block, so its text is FLATTENED into the containing cell's spans (a tab between the nested
    /// table's cells, a newline after each of its non-empty rows) rather than silently dropped —
    /// mirrors `OdtReader`'s identical handling of ODF's equivalent construct, and the same loose
    /// "the words all survive somewhere" assertion style its test uses, since flattening does not
    /// merge every span into one and pinning exact span boundaries would over-specify the point.
    func testNestedTableInsideACellFlattensToTextRatherThanDisappearing() throws {
        // Same shape as OdtReaderTests' equivalent: the outer cell's own paragraph ("Outer")
        // alongside a nested table whose own cell says "Nested" — both must survive somewhere.
        let cellContent = para("Outer") + "<w:tbl><w:tr>\(tc(para("Nested")))</w:tr></w:tbl>"
        let blocks = try read(document: "<w:tbl><w:tr>\(tc(cellContent))</w:tr></w:tbl>")
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table block") }
        // `Cell` holds `blocks`, not `spans`, since S7 — the reader still flattens a nested table
        // into a single `.paragraph` at parse time, so pull its spans back out for this assertion.
        let allText = rows.flatMap { $0 }.flatMap { $0.blocks }.flatMap { block -> [Span] in
            if case .paragraph(let spans, _, _, _, _) = block { return spans }
            return []
        }.map(\.text).joined()
        XCTAssertTrue(allText.contains("Outer"), "the cell's own paragraph text must survive")
        XCTAssertTrue(allText.contains("Nested"), "the nested table's text must survive, not disappear")
    }

    // MARK: Hyperlinks

    func testHyperlinkResolvesRIdThroughRelationshipsToSpanLink() throws {
        let zip = buildDocx(
            document: doc("<w:p><w:hyperlink r:id=\"rId5\"><w:r><w:t>click here</w:t></w:r></w:hyperlink></w:p>"),
            rels: rels([(id: "rId5", target: "https://example.com/", external: true)]))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocxReader.read(archive).blocks
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "click here", link: "https://example.com/")])])
    }

    /// The relationship id doesn't resolve (edited/malformed document) — the text must survive;
    /// only the link itself is allowed to go missing.
    func testHyperlinkWithUnresolvableRelationshipKeepsTextButLeavesLinkNil() throws {
        let blocks = try read(
            document: "<w:p><w:hyperlink r:id=\"rIdMissing\"><w:r><w:t>text</w:t></w:r></w:hyperlink></w:p>",
            rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "text")])])
    }

    /// An internal same-document link (a cross-reference to a heading/bookmark) carries no `r:id`
    /// at all — only `w:anchor` — and becomes a `#`-prefixed fragment.
    func testInternalHyperlinkAnchorProducesAFragmentLink() throws {
        let blocks = try read(
            document: "<w:p><w:hyperlink w:anchor=\"_Toc1\"><w:r><w:t>See above</w:t></w:r></w:hyperlink></w:p>",
            rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "See above", link: "#_Toc1")])])
    }

    /// Text outside a hyperlink and text inside one must stay in separate spans even when every
    /// OTHER formatting flag matches — merging them would make the link boundary invisible to the
    /// renderer.
    func testTextBeforeAndInsideAHyperlinkStaySeparateSpans() throws {
        let zip = buildDocx(
            document: doc("""
            <w:p>
              <w:r><w:t>See </w:t></w:r>
              <w:hyperlink r:id="rId5"><w:r><w:t>this page</w:t></w:r></w:hyperlink>
              <w:r><w:t> for details</w:t></w:r>
            </w:p>
            """),
            rels: rels([(id: "rId5", target: "https://example.com/", external: true)]))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocxReader.read(archive).blocks
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "See "),
            Span(text: "this page", link: "https://example.com/"),
            Span(text: " for details"),
        ])])
    }

    // MARK: Bookmarks (in-document link TARGETS, not the links themselves)

    /// The common real-world shape: a bookmark wraps the run it names, closing again inside the
    /// same paragraph. `_Toc1` must land on the span, not vanish the way `w:bookmarkStart`/`End`
    /// alone do.
    func testBookmarkWrappingARunAttachesItsNameToThatSpan() throws {
        let blocks = try read(document: """
        <w:p>
          <w:bookmarkStart w:id="0" w:name="_Toc1"/>
          <w:r><w:t>Clause 7</w:t></w:r>
          <w:bookmarkEnd w:id="0"/>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Clause 7", bookmarks: ["_Toc1"])])])
    }

    /// MUTATION CHECK (invariant 30): without the `!span.bookmarks.isEmpty` merge guard in
    /// `appendMerging`, this run would merge into a same-formatted neighbour and the name would be
    /// silently dropped rather than misplaced — this asserts the name actually reaches the span,
    /// which a test only checking "no crash" would not catch.
    func testBookmarkedRunDoesNotMergeIntoAnIdenticallyFormattedNeighbour() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:t>See </w:t></w:r>
          <w:bookmarkStart w:id="0" w:name="_Ref9"/>
          <w:r><w:t>clause 7</w:t></w:r>
          <w:bookmarkEnd w:id="0"/>
          <w:r><w:t> above</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "See "),
            Span(text: "clause 7", bookmarks: ["_Ref9"]),
            Span(text: " above"),
        ])])
    }

    /// Word's own auto-inserted "last edit location" bookmark — real corpus noise in nearly every
    /// document, never a real cross-reference target. Regression guard for the existing
    /// `testBookmarksAndProofErrProduceNoPhantomSpansAndDoNotSplitARunPair` merge behaviour: if
    /// `_GoBack` were recorded like any other name, that test's "AB" would split into two spans.
    func testGoBackBookmarkIsNeverRecorded() throws {
        let blocks = try read(document: """
        <w:p>
          <w:bookmarkStart w:id="0" w:name="_GoBack"/>
          <w:bookmarkEnd w:id="0"/>
          <w:r><w:t>Text</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")])])
    }

    /// `r:id` and `w:anchor` both present — per ECMA-376 §17.16.22, `id` wins and `anchor` names a
    /// location WITHIN that external target, not this document; see `hyperlinkTarget`'s doc comment.
    func testHyperlinkWithBothRIdAndAnchorFollowsRId() throws {
        let blocks = try read(
            document: "<w:p><w:hyperlink r:id=\"rId5\" w:anchor=\"Ignored\"><w:r><w:t>go</w:t></w:r></w:hyperlink></w:p>",
            rels: "<Relationships xmlns=\"x\"><Relationship Id=\"rId5\" Type=\"x\" Target=\"https://example.com/doc\" TargetMode=\"External\"/></Relationships>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "go", link: "https://example.com/doc")])])
    }

    // MARK: Content controls (`w:sdt`) — unwrapped, never skipped

    func testContentControlWrappingAParagraphIsUnwrappedNotSkipped() throws {
        let blocks = try read(document: """
        <w:sdt><w:sdtPr><w:alias w:val="Field"/></w:sdtPr><w:sdtContent>
          <w:p><w:r><w:t>Inside a content control</w:t></w:r></w:p>
        </w:sdtContent></w:sdt>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Inside a content control")])])
    }

    func testContentControlWrappingATableIsUnwrappedNotSkipped() throws {
        let blocks = try read(document: """
        <w:sdt><w:sdtContent>
          <w:tbl><w:tr>\(tc(para("Cell")))</w:tr></w:tbl>
        </w:sdtContent></w:sdt>
        """)
        XCTAssertEqual(blocks, [.table(rows: [[Cell(spans: [Span(text: "Cell")])]], headerRows: 0)])
    }

    func testNestedContentControlsAreUnwrappedAllTheWayDown() throws {
        let blocks = try read(document: """
        <w:sdt><w:sdtContent>
          <w:sdt><w:sdtContent>
            <w:p><w:r><w:t>Doubly wrapped</w:t></w:r></w:p>
          </w:sdtContent></w:sdt>
        </w:sdtContent></w:sdt>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Doubly wrapped")])])
    }

    /// An INLINE content control — `w:sdt` wrapping a run inside an ordinary paragraph, rather than
    /// the whole paragraph — must be unwrapped transparently too: its text is recovered at all (the
    /// content that must never disappear), and since it carries no formatting difference from the
    /// text around it, it reassembles into the SAME single span exactly as identically-formatted
    /// plain runs already do (see the five-runs test above) — that merge is what "transparently"
    /// verifies here, not two separate spans surviving the wrapper.
    func testInlineContentControlInsideAParagraphIsUnwrappedTransparently() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:t>Name: </w:t></w:r>
          <w:sdt><w:sdtPr/><w:sdtContent><w:r><w:t>Jane Doe</w:t></w:r></w:sdtContent></w:sdt>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Name: Jane Doe")])])
    }

    // MARK: w:sym — no w:t fallback, must never silently vanish

    /// The placeholder carries no formatting difference from the plain text run before it, so it
    /// reassembles into the SAME span (the point being tested is that the character survives at
    /// all — not that it stays visually distinct from its neighbour).
    func testSymCharacterEmitsAVisiblePlaceholderRatherThanDisappearing() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>See </w:t></w:r><w:r><w:sym w:font="Wingdings" w:char="F0E0"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "See ▯")])])
    }

    // MARK: w:sym — S6 item 3, the small confidently-cited Wingdings mapping

    /// `U+F0FC`/`U+F0FB` are Word's own Wingdings "checked"/"crossed-out" glyphs (the published
    /// Microsoft/Unicode Wingdings-to-Unicode correspondence — see the comment above
    /// `mappedSymbolCharacter`), mapped to real check-mark/ballot-X characters instead of ▯.
    func testMappedWingdingsCheckMarkAndBallotXRenderTheirRealCharacters() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:sym w:font="Wingdings" w:char="F0FC"/><w:sym w:font="Wingdings" w:char="F0FB"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "\u{2713}\u{2717}")])])
    }

    /// A `w:char` this reader is NOT confident about (bullet/arrow/phone/envelope-shaped, or simply
    /// unlisted) keeps the honest ▯ fallback — never guessed. This is the DEFAULT for the mapping
    /// table, not an edge case.
    func testUnmappedWingdingsCharacterStillFallsBackToThePlaceholder() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:sym w:font="Wingdings" w:char="F021"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "▯")])])
    }

    /// The mapping is keyed by FONT, not just `w:char` — the same code point in a different
    /// (non-Wingdings) symbol font means something else entirely, so it must not silently map.
    func testMatchingCharCodeInADifferentFontDoesNotMap() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:sym w:font="Symbol" w:char="F0FC"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "▯")])])
    }

    /// P2R's extension to the mapping table (bullet/box/arrow/telephone/envelope — see
    /// `mappedSymbolCharacter`'s doc for the source), spot-checked one code per category rather
    /// than every entry, since they all go through the identical `switch`.
    func testP2RExtendedWingdingsCodesRenderTheirRealCharacters() throws {
        let blocks = try read(document: """
        <w:p><w:r>
          <w:sym w:font="Wingdings" w:char="F09F"/>
          <w:sym w:font="Wingdings" w:char="F06E"/>
          <w:sym w:font="Wingdings" w:char="F0F0"/>
        </w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "\u{2022}\u{25A0}\u{21E8}")])])
    }

    /// A code NOT in the (still deliberately incomplete) table keeps the honest ▯ fallback even
    /// after this sprint's extension — the point isn't "map everything", only what can be cited.
    func testACodeStillOutsideTheExtendedTableStillFallsBackToThePlaceholder() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:sym w:font="Wingdings" w:char="F099"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "▯")])])
    }

    // MARK: w:vanish — S6 item 2, hidden text (never displayed in Word's Normal view)

    func testVanishedRunProducesNoSpanWhileAnOrdinaryRunBesideItStillRenders() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:vanish/></w:rPr><w:t>Hidden</w:t></w:r>
          <w:r><w:t>Visible</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Visible")])])
    }

    /// `<w:vanish w:val="0"/>` is Word's explicit "not hidden" — the same toggle-off convention
    /// `isOn` already honours for bold/italic/underline/strike (see `testExplicitlyDisabled…`).
    func testExplicitlyDisabledVanishStillRenders() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:vanish w:val="0"/></w:rPr><w:t>Shown</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Shown")])])
    }

    /// A paragraph made ENTIRELY of vanished runs must still be a real (empty-spans) paragraph
    /// block, never crash or vanish the block itself — this reader only hides the RUN's text.
    func testParagraphOfOnlyVanishedRunsProducesAnEmptyParagraphNotACrash() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:vanish/></w:rPr><w:t>AllHidden</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [])])
    }

    // MARK: caps / smallCaps (P2R — §17.3.2.5 / §17.3.2.33)

    func testCapsRunPropertyParses() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:caps/></w:rPr><w:t>Shout</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Shout", caps: true)])])
    }

    func testSmallCapsRunPropertyParses() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:smallCaps/></w:rPr><w:t>Whisper</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Whisper", smallCaps: true)])])
    }

    /// Same explicitly-disabled-toggle convention `isOn` already applies to bold/italic/underline —
    /// `w:val="0"` turns an inherited `w:caps` back off, it is not read as ON-by-presence.
    func testExplicitlyDisabledCapsIsNotCaps() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:caps w:val=\"0\"/></w:rPr><w:t>Plain</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain", caps: false)])])
    }

    // MARK: underline style (P2R — §17.18.99 ST_Underline)

    func testUnderlineValDoubleParsesToTheDoubleUnderlineStyle() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:u w:val=\"double\"/></w:rPr><w:t>Lined</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Lined", underline: true, underlineStyle: .double)])])
    }

    func testUnderlineValDottedParsesToTheDottedUnderlineStyle() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:u w:val=\"dotted\"/></w:rPr><w:t>Lined</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Lined", underline: true, underlineStyle: .dotted)])])
    }

    func testUnderlineValWaveParsesToTheWavyUnderlineStyle() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:u w:val=\"wave\"/></w:rPr><w:t>Lined</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Lined", underline: true, underlineStyle: .wavy)])])
    }

    /// An ORDINARY `w:u` with no `@w:val` (or `@w:val="single"`) means the plain default this
    /// reader already produced for every underlined run before this field existed.
    func testPlainUnderlineWithNoValAttributeStaysTheSingleStyle() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:u/></w:rPr><w:t>Lined</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Lined", underline: true, underlineStyle: .single)])])
    }

    // MARK: strikethrough / superscript / subscript

    func testStrikethroughRunPropertyParses() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:strike/></w:rPr><w:t>Struck</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Struck", strikethrough: true)])])
    }

    func testExplicitlyDisabledStrikethroughIsNotStrikethrough() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:strike w:val=\"0\"/></w:rPr><w:t>NotStruck</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "NotStruck", strikethrough: false)])])
    }

    func testSuperscriptAndSubscriptViaVertAlign() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:t>sup</w:t></w:r>
          <w:r><w:rPr><w:vertAlign w:val="subscript"/></w:rPr><w:t>sub</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "sup", superscript: true),
            Span(text: "sub", subscripted: true),
        ])])
    }

    // MARK: Writing direction (RTL) — S12

    /// `w:pPr/w:bidi` is a PARAGRAPH-level marker — read the same on/off way `w:b`/`w:i` already
    /// are (see `isOn`), never by mere presence alone.
    func testBidiParagraphGetsRightToLeftBaseWritingDirection() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:bidi/></w:pPr><w:r><w:t>\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")], rtl: true)])
    }

    /// The trap this sprint's brief calls out by name: a toggle explicitly turned back OFF
    /// (`w:val="0"`) must not be read as RTL just because the element is present.
    func testExplicitlyDisabledBidiIsNotRTL() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:bidi w:val="0"/></w:pPr><w:r><w:t>Plain</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")], rtl: false)])
    }

    /// `w:rPr/w:rtl` is a RUN-level marker, independent of the paragraph's own `w:bidi` — an LTR
    /// paragraph can carry one RTL run (a Hebrew phrase embedded in an English sentence).
    func testRTLRunCarriesRunLevelDirectionIndependentOfParagraph() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:t>Plain then </w:t></w:r>
          <w:r><w:rPr><w:rtl/></w:rPr><w:t>\u{05E2}\u{05D1}\u{05E8}\u{05D9}\u{05EA}</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "Plain then "),
            Span(text: "\u{05E2}\u{05D1}\u{05E8}\u{05D9}\u{05EA}", rtl: true),
        ], rtl: false)])
    }

    /// Same trap as `w:bidi`, at run level: `w:val="false"` (Word writes both spellings) is
    /// explicitly OFF, not ON-by-presence.
    func testExplicitlyDisabledRunRTLIsNotRTL() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:rtl w:val="false"/></w:rPr><w:t>Plain</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain", rtl: false)])])
    }

    /// A heading and a list item read `w:bidi` exactly the same way a plain paragraph does — this
    /// is the SAME field on every span-carrying case (see `OfficeBlock`'s doc), not re-derived per
    /// case.
    func testBidiHeadingAndListItemAlsoGetRightToLeftBaseWritingDirection() throws {
        let headingBlocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Heading1\"/><w:bidi/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>",
            styles: """
            <?xml version="1.0" encoding="UTF-8"?><w:styles>
              <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
            </w:styles>
            """)
        XCTAssertEqual(headingBlocks, [.heading(level: 1, spans: [Span(text: "Title")], rtl: true)])

        let listBlocks = try read(document: """
        <w:p><w:pPr><w:bidi/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
          <w:r><w:t>Item</w:t></w:r></w:p>
        """, numbering: """
        <?xml version="1.0" encoding="UTF-8"?><w:numbering>
          <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
          <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        </w:numbering>
        """)
        XCTAssertEqual(listBlocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")], rtl: true)])
    }

    /// The regression guard this sprint's brief demands: an LTR document's parsed blocks are
    /// unchanged. Every existing `.paragraph(spans:)`/`.heading(level:spans:)`/
    /// `.listItem(level:ordered:spans:marker:)` construction across this whole file defaults
    /// `rtl` to `false` and still compares equal (`Equatable`) to a block this reader produces from
    /// markup with no `w:bidi`/`w:rtl` anywhere — this one test states that explicitly rather than
    /// leaving it implied by every other test in the file still passing unmodified.
    func testDocumentWithNoBidiOrRtlMarkupProducesRtlFalseEverywhere() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Ordinary</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Ordinary")])])
        guard case .paragraph(_, let rtl, _, _, _) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertFalse(rtl)
    }

    // MARK: Images

    private func rels(_ pairs: [(id: String, target: String, external: Bool)]) -> String {
        let entries = pairs.map { pair -> String in
            let mode = pair.external ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(pair.id)\" Type=\"x\" Target=\"\(pair.target)\"\(mode)/>"
        }.joined()
        return "<Relationships xmlns=\"x\">\(entries)</Relationships>"
    }

    private func drawing(cx: Int, cy: Int, embed: String? = nil, link: String? = nil) -> String {
        let blipAttr = embed.map { "r:embed=\"\($0)\"" } ?? link.map { "r:link=\"\($0)\"" } ?? ""
        return """
        <w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/>
          <a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip \(blipAttr)/></pic:blipFill></pic:pic></a:graphicData></a:graphic>
        </wp:inline></w:drawing>
        """
    }

    private func vmlPict(style: String, rId: String) -> String {
        "<w:pict><v:shape style=\"\(style)\"><v:imagedata r:id=\"\(rId)\"/></v:shape></w:pict>"
    }

    func testEmbeddedDrawingResolvesToMediaEntryNameAndConvertsEMUToPoints() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 6_400_800, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 504, height: 72))])
    }

    /// A picture inherits the alignment of the paragraph it sits in (`w:jc`). Word puts a centred
    /// figure in a centred paragraph — the drawing itself says nothing about alignment — so a reader
    /// that only looks at the drawing renders every figure hard left, which is what this one did.
    func testImageInheritsItsParagraphsAlignment() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        guard case let .image(_, _, alignment) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected an image block, got \(blocks)")
        }
        XCTAssertEqual(alignment, .center)
    }

    /// …and a paragraph that states no alignment leaves the picture unaligned, so a document that
    /// never centres anything renders exactly as it did before this existed.
    func testImageInAnUnalignedParagraphCarriesNoAlignment() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        guard case let .image(_, _, alignment) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected an image block, got \(blocks)")
        }
        XCTAssertNil(alignment)
    }

    /// `w:tblGrid` is the table's own width, and a picture in a cell is scaled against it rather than
    /// the page (`TableFormat.sourceWidth`) — the reader stretches tables to the reading column, so a
    /// page-scaled picture would shrink relative to the cell that grew around it.
    func testTableCarriesItsOwnSourceWidthFromTheGrid() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="3000"/></w:tblGrid>
        <w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """)
        guard case let .table(_, _, _, format) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a table, got \(blocks)")
        }
        XCTAssertEqual(try XCTUnwrap(format.sourceWidth), 250, accuracy: 0.01,
                       "5000 twips ⇒ 250pt, the table's own width as Word laid it out")
    }

    func testAlternateContentEmitsOnlyTheChoiceImageNeverTheFallback() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><mc:AlternateContent>
              <mc:Choice Requires="wpg">\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</mc:Choice>
              <mc:Fallback>\(vmlPict(style: "width:72pt;height:72pt", rId: "rId8"))</mc:Fallback>
            </mc:AlternateContent></w:r></w:p>
            """,
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: Linked (external) images — S6 item 4
    //
    // A `r:link` target is a REAL reference, just outside the archive — marked with its own
    // `docx-external-link:` prefix (never `docx-unresolvable:`) so `MarkdownDocument` can route it
    // to the same folder-grant placeholder a blocked markdown sibling image already gets, instead
    // of the generic "this reference doesn't resolve to anything" broken-image icon.

    func testLinkedExternalImageEmitsAnExternalLinkIdCarryingItsTargetAndNeverZeroSize() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, link: "rId9"))</w:r></w:p>",
            rels: rels([(id: "rId9", target: "file:///Users/x/pic.png", external: true)]))
        XCTAssertEqual(blocks, [.image(id: "docx-external-link:file:///Users/x/pic.png", size: CGSize(width: 72, height: 72))])
    }

    /// A dangling/unnamed relationship — genuinely unresolvable, not merely external — must stay on
    /// the OLD `docx-unresolvable:` prefix, distinct from a real external link.
    func testDanglingRelationshipStillUsesTheGenericUnresolvablePrefixNotTheExternalLinkOne() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rIdMissing"))</w:r></w:p>",
            rels: rels([(id: "rId9", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "docx-unresolvable:rIdMissing", size: CGSize(width: 72, height: 72))])
    }

    func testStandaloneVMLPictWithNoAlternateContentEmitsOneImageSizedFromStyle() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(vmlPict(style: "width:7in;height:185.25pt", rId: "rId10"))</w:r></w:p>",
            rels: rels([(id: "rId10", target: "media/image2.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image2.png", size: CGSize(width: 504, height: 185.25))])
    }

    func testVMLStyleUnitsAllConvertToPoints() throws {
        let cases: [(style: String, expected: CGSize)] = [
            ("width:72pt;height:36pt", CGSize(width: 72, height: 36)),
            ("width:1in;height:2in", CGSize(width: 72, height: 144)),
            ("width:96px;height:48px", CGSize(width: 72, height: 36)),
            ("width:2.54cm;height:1cm", CGSize(width: 72, height: 72 / 2.54)),
            ("width:25.4mm;height:12.7mm", CGSize(width: 72, height: 36)),
            ("width:100;height:50", CGSize(width: 100, height: 50)),
        ]
        for (index, testCase) in cases.enumerated() {
            let rId = "rIdVml\(index)"
            let blocks = try read(
                document: "<w:p><w:r>\(vmlPict(style: testCase.style, rId: rId))</w:r></w:p>",
                rels: rels([(id: rId, target: "media/image\(index).png", external: false)]))
            XCTAssertEqual(blocks, [.image(id: "word/media/image\(index).png", size: testCase.expected)],
                            "style '\(testCase.style)'")
        }
    }

    /// A single `w:drawing` grouping several `pic:pic` (Word's "two logos side by side" shape)
    /// must yield ONE image block PER embedded picture, never just the first — measured live on
    /// the real government-guide test file, where dropping this produced only 1 of 2 real images.
    func testDrawingGroupingMultiplePicturesEmitsOneImagePerPictureNotJustTheFirst() throws {
        let groupedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <pic:pic><pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill></pic:pic>
            <pic:pic><pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill></pic:pic>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(groupedDrawing)</w:r></w:p>",
            rels: rels([
                (id: "rId8", target: "media/image1.png", external: false),
                (id: "rId9", target: "media/image2.png", external: false),
            ]))
        XCTAssertEqual(blocks, [
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
            .image(id: "word/media/image2.png", size: CGSize(width: 72, height: 72)),
        ])
    }

    /// A group's own `wpg:grpSpPr/a:xfrm` declares BOTH its real-EMU box (`a:ext`) and the
    /// coordinate space its children are measured in (`a:chExt`) — a child's own extent (in child
    /// units) converts to real EMU via `ext ÷ chExt` per axis. Numbers measured on the real
    /// government-guide test file's group (an intermediate group inside a larger nest, used here
    /// standalone as the minimal case): group `ext 6400800×2352675`, `chExt 10080×3705`, one
    /// picture with its OWN `ext 1665×3705` (child units) → `1665 × (6400800/10080) ÷ 12700 =
    /// 83.25 pt`, `3705 × (2352675/3705) ÷ 12700 = 185.25 pt`.
    func testGroupedPictureSizedByChainingGroupExtOverChExtScale() throws {
        let groupedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="6400800" cy="2352675"/>
          <wpg:wgp>
            <wpg:grpSpPr><a:xfrm><a:ext cx="6400800" cy="2352675"/><a:chExt cx="10080" cy="3705"/></a:xfrm></wpg:grpSpPr>
            <pic:pic>
              <pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill>
              <pic:spPr><a:xfrm><a:ext cx="1665" cy="3705"/></a:xfrm></pic:spPr>
            </pic:pic>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(groupedDrawing)</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 83.25, height: 185.25))])
    }

    /// End-to-end nested chain (group → group → group → two pictures), reproducing the REAL
    /// government-guide file's exact structure and numbers: three levels deep, the inner two
    /// levels each an identity scale (`ext == chExt`), only the outermost level actually rescales
    /// (`×635` both axes). Confirms the chain multiplies correctly across levels rather than only
    /// working for a single level, and that two DIFFERENTLY-sized pictures in the same nest each
    /// get their OWN correct size, not the group's shared outer box.
    func testNestedThreeLevelGroupChainProducesEachPicturesOwnCorrectSize() throws {
        let nestedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="6400800" cy="2352675"/>
          <wpg:wgp>
            <wpg:grpSpPr><a:xfrm><a:ext cx="6400800" cy="2352675"/><a:chExt cx="10080" cy="3705"/></a:xfrm></wpg:grpSpPr>
            <wpg:grpSp>
              <wpg:grpSpPr><a:xfrm><a:ext cx="1665" cy="3705"/><a:chExt cx="1665" cy="3705"/></a:xfrm></wpg:grpSpPr>
              <wpg:grpSp>
                <wpg:grpSpPr><a:xfrm><a:ext cx="1665" cy="2160"/><a:chExt cx="1665" cy="2160"/></a:xfrm></wpg:grpSpPr>
                <pic:pic>
                  <pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill>
                  <pic:spPr><a:xfrm><a:ext cx="1140" cy="2160"/></a:xfrm></pic:spPr>
                </pic:pic>
                <pic:pic>
                  <pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill>
                  <pic:spPr><a:xfrm><a:ext cx="1080" cy="1080"/></a:xfrm></pic:spPr>
                </pic:pic>
              </wpg:grpSp>
            </wpg:grpSp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(nestedDrawing)</w:r></w:p>",
            rels: rels([
                (id: "rId8", target: "media/image1.png", external: false),
                (id: "rId9", target: "media/image2.png", external: false),
            ]))
        XCTAssertEqual(blocks, [
            .image(id: "word/media/image1.png", size: CGSize(width: 57, height: 108)),
            .image(id: "word/media/image2.png", size: CGSize(width: 54, height: 54)),
        ])
    }

    /// A group with a picture that has no own `pic:spPr/a:xfrm/a:ext` falls back to the whole
    /// drawing's `wp:extent` rather than 0.
    func testPictureInGroupWithNoOwnExtentFallsBackToWholeDrawingExtent() throws {
        let groupedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <wpg:grpSpPr><a:xfrm><a:ext cx="914400" cy="914400"/><a:chExt cx="100" cy="100"/></a:xfrm></wpg:grpSpPr>
            <pic:pic><pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill></pic:pic>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(groupedDrawing)</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: Non-picture shapes (text boxes, decoration) — never a fake image placeholder

    /// A `w:drawing`/`w:pict` with no picture inside is NOT an image (no "unresolvable" placeholder
    /// drawn for it) — measured on the real government-guide file's decorative "목차" callout box,
    /// a shape GROUP with no `pic:pic` at all, only `wps:wsp` AutoShapes carrying `w:txbxContent`
    /// text. Its typed text is recovered as an ordinary paragraph instead of being silently lost.
    func testDrawingWithNoPictureButRealTextEmitsThatTextNotAnImagePlaceholder() throws {
        let shapeGroup = """
        <w:drawing><wp:inline><wp:extent cx="1115695" cy="799465"/>
          <wpg:wgp>
            <wps:wsp><wps:txbx><w:txbxContent><w:p><w:r><w:t>목 차</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(document: "<w:p><w:r>\(shapeGroup)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "목 차")])])
    }

    /// A shape with neither a picture nor any typed text (Word's placeholder `<w:p/>` inside an
    /// otherwise-empty text frame) contributes NOTHING OF ITS OWN — no image placeholder, no text
    /// block for its empty placeholder paragraph. The containing paragraph is left with exactly
    /// what it would have if the drawing weren't there at all: since it ALSO carries no other
    /// text, it still emits the ordinary empty-paragraph "blank line" block every other empty
    /// paragraph in a document body does (unchanged, pre-existing behaviour — not something this
    /// shape adds).
    func testDrawingWithNoPictureAndNoTextContributesNothingOfItsOwn() throws {
        let emptyShape = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <wps:wsp><wps:txbx><w:txbxContent><w:p/></w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(document: "<w:p><w:r>\(emptyShape)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [])])
    }

    /// The precise version of the above: a paragraph that has OTHER real text alongside the
    /// empty, picture-less shape must show ONLY that text — proving the shape truly contributes
    /// nothing of its own, rather than the previous test merely coinciding with an already-empty
    /// paragraph.
    func testDrawingWithNoPictureAndNoTextAddsNothingAlongsideRealParagraphText() throws {
        let emptyShape = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <wps:wsp><wps:txbx><w:txbxContent><w:p/></w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r><w:t>Body text</w:t></w:r><w:r>\(emptyShape)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Body text")])])
    }

    /// `mc:Fallback` text is skipped exactly like a Fallback picture — a text box wrapped in
    /// `mc:AlternateContent` must not have its caption appear twice.
    func testAlternateContentTextBoxEmitsTextOnlyOnceNeverFromFallback() throws {
        let shapeGroup = """
        <mc:AlternateContent>
          <mc:Choice Requires="wpg">
            <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
              <wpg:wgp><wps:wsp><wps:txbx><w:txbxContent><w:p><w:r><w:t>Caption</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp></wpg:wgp>
            </wp:inline></w:drawing>
          </mc:Choice>
          <mc:Fallback>\(vmlPict(style: "width:72pt;height:72pt", rId: "rIdFallback"))</mc:Fallback>
        </mc:AlternateContent>
        """
        let blocks = try read(document: "<w:p><w:r>\(shapeGroup)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Caption")])])
    }

    /// Same double-render guard as the test above, on the OTHER real structural family the
    /// measurement phase found (§3a: an UNGROUPED shape — `wps:wsp/wps:txbx/w:txbxContent` directly
    /// under `a:graphicData`, no `wpg:wgp` at all — the mammoth `text-box.docx` fixture's own
    /// shape). Also covers "a modern wps text box's text appears" in its own right: this fixture
    /// has no `pic:pic` anywhere, so `.paragraph(["Datum plane"])` can only come from the Choice
    /// half's `w:txbxContent`. If the Fallback's `w:pict`/`v:imagedata` were ALSO walked, the
    /// result would carry an extra `.image` block (or the same text twice) instead of exactly one
    /// paragraph — the assertion below rules out both.
    func testUngroupedModernTextBoxTextAppearsOnceNeverFromVMLFallback() throws {
        let ungroupedShape = """
        <mc:AlternateContent>
          <mc:Choice Requires="wps">
            <w:drawing><wp:anchor><wp:extent cx="914400" cy="914400"/>
              <a:graphic><a:graphicData>
                <wps:wsp><wps:txbx><w:txbxContent><w:p><w:r><w:t>Datum plane</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp>
              </a:graphicData></a:graphic>
            </wp:anchor></w:drawing>
          </mc:Choice>
          <mc:Fallback>\(vmlPict(style: "width:72pt;height:72pt", rId: "rIdFallback"))</mc:Fallback>
        </mc:AlternateContent>
        """
        let blocks = try read(document: "<w:p><w:r>\(ungroupedShape)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Datum plane")])])
    }

    /// OOXML permits a `w:tbl` as a direct child of `w:txbxContent` (a table typed inside a text
    /// box) alongside `w:p` — the measurement phase found `textBoxBlocks` only ever looked at `w:p`
    /// children, silently dropping this (unexercised by the real corpus, but a real gap). Routing
    /// through the SAME `parseBodyChild` the body uses closes it: this asserts a real `.table`
    /// block (not a flattened/raw dump) comes out of a text box's own table, with the cell's text
    /// intact.
    func testTextBoxContainingATableProducesARealTableBlock() throws {
        let shapeGroup = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <wps:wsp><wps:txbx><w:txbxContent>
              <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            </w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(document: "<w:p><w:r>\(shapeGroup)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let rows, _, _, _) = blocks.first else {
            return XCTFail("expected a real table block from inside the text box, got \(blocks)")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 1)
        XCTAssertEqual(rows[0][0].blocks, [.paragraph(spans: [Span(text: "Cell")])])
    }

    /// A group can hold a real picture AND a captioned shape as separate siblings (a background
    /// photo with a text label on top of it) — the pre-fix code computed `imageBlocks` first and,
    /// the moment it found a picture, `continue`d without ever calling `textBoxBlocks` for that same
    /// `w:drawing`, silently dropping the caption. Both must survive, in the drawing's own document
    /// order (the picture's `pic:pic` precedes the caption's `wps:wsp` in this fixture, same as the
    /// blocks array below).
    func testDrawingWithBothAPictureAndATextBoxYieldsBothInDocumentOrder() throws {
        let shapeGroup = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <pic:pic><pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill></pic:pic>
            <wps:wsp><wps:txbx><w:txbxContent><w:p><w:r><w:t>Caption</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(shapeGroup)</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
            .paragraph(spans: [Span(text: "Caption")]),
        ])
    }

    /// A plain picture-only drawing (no `w:txbxContent` anywhere in it) renders EXACTLY as before
    /// the "both survive" fix — `collectDrawingBlocks` now always computes `textBoxBlocks` alongside
    /// `imageBlocks` rather than skipping it once a picture is found, but that computation is always
    /// empty here (no text box at all), so the result is unchanged. Same fixture as
    /// `testDrawingGroupingMultiplePicturesEmitsOneImagePerPictureNotJustTheFirst`, re-asserted to
    /// prove the change is additive for the common (no-text-box) case, not a behaviour change.
    func testDrawingWithNoTextBoxAtAllIsUnaffectedByTheBothSurviveChange() throws {
        let groupedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <pic:pic><pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill></pic:pic>
            <pic:pic><pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill></pic:pic>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(groupedDrawing)</w:r></w:p>",
            rels: rels([
                (id: "rId8", target: "media/image1.png", external: false),
                (id: "rId9", target: "media/image2.png", external: false),
            ]))
        XCTAssertEqual(blocks, [
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
            .image(id: "word/media/image2.png", size: CGSize(width: 72, height: 72)),
        ])
    }

    // MARK: Charts / SmartArt (S9) — mc:Fallback picture recovery, and the placeholder frame
    //
    // Word wraps a chart/SmartArt `w:drawing` in `mc:AlternateContent`: `mc:Choice` holds the
    // graphicFrame (`c:chart`/`dgm:relIds`) this reader has no vector renderer for, `mc:Fallback`
    // holds an already-rendered VML picture of that very chart/diagram for an older reader. Since
    // this reader never reached `mc:Fallback` before this sprint, both objects vanished with zero
    // trace (gap-list rows 11/12) — these tests prove the fallback picture is now reached, and that
    // the placeholder only appears when there is genuinely nothing else to show.

    private func chartGraphicFrame(cx: Int, cy: Int) -> String {
        """
        <w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/>
          <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">
            <c:chart r:id="rId99"/>
          </a:graphicData></a:graphic>
        </wp:inline></w:drawing>
        """
    }

    private func smartArtGraphicFrame(cx: Int, cy: Int) -> String {
        """
        <w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/>
          <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram">
            <dgm:relIds r:dm="rId10" r:lo="rId11" r:qs="rId12" r:cs="rId13"/>
          </a:graphicData></a:graphic>
        </wp:inline></w:drawing>
        """
    }

    /// The win the sprint exists for: a chart's `mc:Choice` resolves to nothing (no `a:blip`, no
    /// `w:txbxContent`), so the reader now reaches into `mc:Fallback` and recovers the picture Word
    /// already rendered there — the user sees the actual chart, not an empty gap.
    func testChartWithUsableVMLFallbackRendersThatPictureNotAPlaceholder() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><mc:AlternateContent>
              <mc:Choice Requires="c">\(chartGraphicFrame(cx: 914_400, cy: 914_400))</mc:Choice>
              <mc:Fallback>\(vmlPict(style: "width:180pt;height:90pt", rId: "rIdFallback"))</mc:Fallback>
            </mc:AlternateContent></w:r></w:p>
            """,
            rels: rels([(id: "rIdFallback", target: "media/chart1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/chart1.png", size: CGSize(width: 180, height: 90))])
    }

    /// Same recovery for SmartArt (`dgm:relIds`, no `c:chart`) — proves the fallback path isn't
    /// chart-specific.
    func testSmartArtWithUsableVMLFallbackRendersThatPictureNotAPlaceholder() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><mc:AlternateContent>
              <mc:Choice Requires="dgm">\(smartArtGraphicFrame(cx: 914_400, cy: 914_400))</mc:Choice>
              <mc:Fallback>\(vmlPict(style: "width:200pt;height:100pt", rId: "rIdFallback"))</mc:Fallback>
            </mc:AlternateContent></w:r></w:p>
            """,
            rels: rels([(id: "rIdFallback", target: "media/diagram1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/diagram1.png", size: CGSize(width: 200, height: 100))])
    }

    /// No `mc:Fallback` element at all — the placeholder is the only honest option, sized from the
    /// SAME `wp:extent` a picture would have used, labelled for a reader ("Chart"), never the XML
    /// element name.
    func testChartWithNoFallbackAtAllProducesVisiblePlaceholderAtDeclaredSize() throws {
        let blocks = try read(
            document: "<w:p><w:r><mc:AlternateContent><mc:Choice Requires=\"c\">\(chartGraphicFrame(cx: 6_400_800, cy: 2_352_675))</mc:Choice></mc:AlternateContent></w:r></w:p>",
            rels: nil)
        XCTAssertEqual(blocks, [.unsupportedGraphic(label: "Chart", size: CGSize(width: 504, height: 185.25))])
    }

    /// `mc:Fallback` IS present but resolves to no picture (an unresolvable relationship id) — still
    /// the placeholder, not a crash and not silence.
    func testChartWithUnresolvableFallbackStillProducesPlaceholder() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><mc:AlternateContent>
              <mc:Choice Requires="c">\(chartGraphicFrame(cx: 914_400, cy: 914_400))</mc:Choice>
              <mc:Fallback></mc:Fallback>
            </mc:AlternateContent></w:r></w:p>
            """,
            rels: nil)
        XCTAssertEqual(blocks, [.unsupportedGraphic(label: "Chart", size: CGSize(width: 72, height: 72))])
    }

    /// A standalone chart graphicFrame with NO `mc:AlternateContent` wrapper at all (some producers
    /// skip the legacy-fallback ceremony entirely) — there is no Fallback to try, so this is the
    /// placeholder's only chance, reached through the plain `w:drawing` case, not the
    /// `mc:AlternateContent` one.
    func testStandaloneChartWithNoAlternateContentWrapperProducesPlaceholder() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(chartGraphicFrame(cx: 914_400, cy: 914_400))</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.unsupportedGraphic(label: "Chart", size: CGSize(width: 72, height: 72))])
    }

    /// Regression: a PLAIN picture inside `mc:AlternateContent` (the pre-existing, most common
    /// case) must still render exactly as before — Choice yields a real image, so the new
    /// Fallback/placeholder machinery must never engage at all. Mirrors
    /// `testAlternateContentEmitsOnlyTheChoiceImageNeverTheFallback` above; kept here too because
    /// mutation testing this exact scenario is what proves the new three-way branch didn't regress
    /// the two-way one it replaced.
    func testPlainPictureInAlternateContentIsUnaffectedByTheNewChartFallbackLogic() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><mc:AlternateContent>
              <mc:Choice Requires="wpg">\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</mc:Choice>
              <mc:Fallback>\(vmlPict(style: "width:72pt;height:72pt", rId: "rId8"))</mc:Fallback>
            </mc:AlternateContent></w:r></w:p>
            """,
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72))])
    }

    /// Invariant 29: a chart-bearing document must be reachable through `MarkdownDocument`'s own
    /// read path (`DocumentTypes.readOffice`), not merely through `DocxReader.read` called
    /// directly — the same blindness invariant 29 already caught once for `.odt`.
    func testChartFallbackPictureIsReachedThroughDocumentTypesReadOfficeNotJustDocxReaderDirectly() throws {
        let document = doc("""
        <w:p><w:r><mc:AlternateContent>
          <mc:Choice Requires="c">\(chartGraphicFrame(cx: 914_400, cy: 914_400))</mc:Choice>
          <mc:Fallback>\(vmlPict(style: "width:100pt;height:50pt", rId: "rIdFallback"))</mc:Fallback>
        </mc:AlternateContent></w:r></w:p>
        """)
        let zip = buildDocx(document: document, rels: rels([(id: "rIdFallback", target: "media/chart1.png", external: false)]))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocumentTypes.readOffice(archive, extension: "docx").blocks
        XCTAssertEqual(blocks, [.image(id: "word/media/chart1.png", size: CGSize(width: 100, height: 50))])
    }

    func testVMLShapeWithUnparseableStyleEmitsNonZeroFallbackSizeNotZero() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:pict><v:shape><v:imagedata r:id=\"rId10\"/></v:shape></w:pict></w:r></w:p>",
            rels: rels([(id: "rId10", target: "media/image1.png", external: false)]))
        guard case .image(_, let size, _) = blocks.first else { return XCTFail("expected an image block") }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testEmbedIdWithNoMatchingRelationshipEmitsUnresolvableSizedBlockWithoutCrashing() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rIdMissing"))</w:r></w:p>",
            rels: nil)
        XCTAssertEqual(blocks, [.image(id: "docx-unresolvable:rIdMissing", size: CGSize(width: 72, height: 72))])
    }

    func testImagesAppearInDocumentOrderRelativeToSurroundingParagraphs() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><w:t>Before</w:t></w:r></w:p>
            <w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>
            <w:p><w:r><w:t>After</w:t></w:r></w:p>
            """,
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Before")]),
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
            .paragraph(spans: [Span(text: "After")]),
        ])
    }

    func testImageOnlyParagraphEmitsNoPhantomEmptyTextBlock() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72))])
    }

    func testParagraphWithBothTextAndAnImageEmitsTextBlockFollowedByImageNotReordered() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Caption</w:t></w:r><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Caption")]),
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
        ])
    }

    func testDocumentWithNoImagesAndNoRelsPartStillParsesExactlyAsBefore() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Plain text</w:t></w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain text")])])
    }

    // MARK: Archive-level failure and absent optional parts

    func testArchiveWithNoDocumentXMLThrows() throws {
        let zip = buildZip([("word/styles.xml", Data(headingStyles.utf8))])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try DocxReader.read(archive)) { error in
            XCTAssertEqual(error as? DocxReader.ReadError, .missingDocumentXML)
        }
    }

    func testMissingStylesXMLStillParsesWithNoHeadingsAndNoCrash() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Plain text</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain text")])])
    }

    // MARK: Footnotes / endnotes
    //
    // NOTE ON EVIDENCE: unlike the table/list/hyperlink fixtures elsewhere in this file, none of
    // this section is corpus-backed. All eight of the user's real contracts carry a
    // `word/footnotes.xml` part, but every one of them holds ONLY the two boilerplate entries Word
    // writes into essentially every document (`w:type="separator"`/`"continuationSeparator"`) — zero
    // real footnotes, zero `w:footnoteReference` in any of their bodies, measured before this sprint
    // was written. These fixtures are synthetic, built from the OOXML spec shape, not from a
    // measured file.

    private func footnoteReferenceRun(id: String) -> String {
        "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(id)\"/></w:r>"
    }

    private func endnoteReferenceRun(id: String) -> String {
        "<w:r><w:rPr><w:rStyle w:val=\"EndnoteReference\"/></w:rPr><w:endnoteReference w:id=\"\(id)\"/></w:r>"
    }

    /// The two boilerplate separator entries every real docx carries, plus zero or more real notes.
    private func footnotesXML(_ notes: [(id: String, text: String)]) -> String {
        var body = """
        <w:footnote w:type="separator" w:id="-1"><w:p/></w:footnote>
        <w:footnote w:type="continuationSeparator" w:id="0"><w:p/></w:footnote>
        """
        for note in notes {
            body += """
            <w:footnote w:id="\(note.id)">
              <w:p>
                <w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>
                <w:r><w:t>\(note.text)</w:t></w:r>
              </w:p>
            </w:footnote>
            """
        }
        return "<w:footnotes>\(body)</w:footnotes>"
    }

    private func endnotesXML(_ notes: [(id: String, text: String)]) -> String {
        var body = """
        <w:endnote w:type="separator" w:id="-1"><w:p/></w:endnote>
        <w:endnote w:type="continuationSeparator" w:id="0"><w:p/></w:endnote>
        """
        for note in notes {
            body += """
            <w:endnote w:id="\(note.id)">
              <w:p>
                <w:r><w:rPr><w:rStyle w:val="EndnoteReference"/></w:rPr><w:endnoteRef/></w:r>
                <w:r><w:t>\(note.text)</w:t></w:r>
              </w:p>
            </w:endnote>
            """
        }
        return "<w:endnotes>\(body)</w:endnotes>"
    }

    func testFootnoteReferenceEmitsSuperscriptMarkerAndBodyIsAppendedAtDocumentEnd() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>See note</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p>",
            footnotes: footnotesXML([(id: "1", text: " Note text.")]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See note"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Note text.")]),
        ])
    }

    /// The single concrete bug this sprint exists to avoid: a reader that renders every `w:footnote`
    /// it finds appends two phantom notes to every real contract, none of which has any actual
    /// footnotes. `w:type` is the only reliable filter (see `DocxReader.parseNoteBodies`).
    func testDocumentWithOnlyBoilerplateSeparatorEntriesAndNoRealFootnoteAppendsNothing() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Plain paragraph, no citations.</w:t></w:r></w:p>",
            footnotes: footnotesXML([]))
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain paragraph, no citations.")])])
    }

    /// Numbers are assigned by CITATION order in the body, not by the `w:id` values Word happened to
    /// assign — real documents can delete/reorder footnotes leaving non-sequential/out-of-order ids
    /// behind, but the reader must still display "1", "2", … in reading order, matching what Word
    /// itself shows.
    func testFootnotesAreNumberedByCitationOrderNotByIdValue() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><w:t>First</w:t></w:r>\(footnoteReferenceRun(id: "9"))</w:p>
            <w:p><w:r><w:t>Second</w:t></w:r>\(footnoteReferenceRun(id: "3"))</w:p>
            """,
            footnotes: footnotesXML([(id: "3", text: " Third note."), (id: "9", text: " Ninth note.")]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "First"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "Second"), Span(text: "2", superscript: true)]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Ninth note.")]),
            .paragraph(spans: [Span(text: "2", superscript: true), Span(text: " Third note.")]),
        ])
    }

    /// Footnotes and endnotes are separate numbering sequences in Word (both commonly start at 1) —
    /// this asserts they don't share one counter, and that both kinds of note body are appended, in
    /// the order they were cited.
    func testFootnotesAndEndnotesAreNumberedIndependentlyAndBothAppendedInCitationOrder() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><w:t>A footnote</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p>
            <w:p><w:r><w:t>An endnote</w:t></w:r>\(endnoteReferenceRun(id: "1"))</w:p>
            """,
            footnotes: footnotesXML([(id: "1", text: " Footnote body.")]),
            endnotes: endnotesXML([(id: "1", text: " Endnote body.")]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "A footnote"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "An endnote"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Footnote body.")]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Endnote body.")]),
        ])
    }

    /// A `w:footnoteReference` whose id never appears in `footnotes.xml` at all (malformed/edited
    /// document) still shows its citation marker — honest, since something WAS cited there — but
    /// fabricates no body text, since there is none to show.
    func testFootnoteReferenceWithNoMatchingBodyStillShowsMarkerButAppendsNothing() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Orphaned citation</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p>",
            footnotes: footnotesXML([]))
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Orphaned citation"), Span(text: "1", superscript: true)])])
    }

    /// A footnote reference isn't only ever inside a plain body paragraph — Word allows one inside a
    /// table cell just as freely, and `collectCellSpans`/`collectSpans` must thread the same
    /// numbering through there too.
    func testFootnoteReferenceInsideATableCellIsNumberedAndAppended() throws {
        let blocks = try read(
            document: """
            <w:tbl>
              <w:tr><w:tc><w:p><w:r><w:t>Cell text</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p></w:tc></w:tr>
            </w:tbl>
            """,
            footnotes: footnotesXML([(id: "1", text: " Cell footnote.")]))
        XCTAssertEqual(blocks, [
            .table(rows: [[Cell(spans: [Span(text: "Cell text"), Span(text: "1", superscript: true)])]], headerRows: 0),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Cell footnote.")]),
        ])
    }

    // MARK: - S10: OMML equations (m:oMath / m:oMathPara)

    /// Wraps `content` (raw OMML, no `m:oMath` of its own) in a minimal single-equation
    /// `m:oMathPara` and reads it as a standalone paragraph — the shape every per-construct test
    /// below shares.
    private func formula(_ content: String) throws -> OfficeBlock {
        let blocks = try read(document: "<w:p><m:oMathPara><m:oMath>\(content)</m:oMath></m:oMathPara></w:p>")
        guard blocks.count == 1 else { XCTFail("expected exactly one block, got \(blocks)"); throw ReadFixtureError.wrongShape }
        return blocks[0]
    }

    private enum ReadFixtureError: Error { case wrongShape }

    private func run(_ text: String) -> String { "<m:r><m:t>\(text)</m:t></m:r>" }

    // MARK: m:r / m:t

    func testRunTextTranslatesVerbatim() throws {
        XCTAssertEqual(try formula(run("x")), .formula(latex: "x"))
    }

    // MARK: m:f (fraction)

    func testFractionTranslatesToFracCommand() throws {
        let xml = "<m:f><m:num>\(run("1"))</m:num><m:den>\(run("2"))</m:den></m:f>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\frac{1}{2}"))
    }

    // MARK: m:sSup / m:sSub / m:sSubSup

    func testSuperscriptTranslatesToCaret() throws {
        let xml = "<m:sSup><m:e>\(run("x"))</m:e><m:sup>\(run("2"))</m:sup></m:sSup>"
        XCTAssertEqual(try formula(xml), .formula(latex: "{x}^{2}"))
    }

    func testSubscriptTranslatesToUnderscore() throws {
        let xml = "<m:sSub><m:e>\(run("a"))</m:e><m:sub>\(run("i"))</m:sub></m:sSub>"
        XCTAssertEqual(try formula(xml), .formula(latex: "{a}_{i}"))
    }

    func testSubSupTranslatesBothAtOnce() throws {
        let xml = "<m:sSubSup><m:e>\(run("x"))</m:e><m:sub>\(run("i"))</m:sub><m:sup>\(run("2"))</m:sup></m:sSubSup>"
        XCTAssertEqual(try formula(xml), .formula(latex: "{x}_{i}^{2}"))
    }

    // MARK: m:rad (radical)

    func testRadicalWithDegreeTranslatesToBracketedSqrt() throws {
        let xml = "<m:rad><m:deg>\(run("3"))</m:deg><m:e>\(run("x"))</m:e></m:rad>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\sqrt[3]{x}"))
    }

    func testRadicalWithHiddenDegreeOmitsTheBracket() throws {
        let xml = "<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(run("x"))</m:e></m:rad>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\sqrt{x}"))
    }

    // MARK: m:d (delimiters)

    func testDelimiterDefaultsToParenthesesWhenNoneDeclared() throws {
        let xml = "<m:d><m:e>\(run("x"))</m:e></m:d>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\left( x \\right)"))
    }

    func testDelimiterHonoursDeclaredBracketCharacters() throws {
        let xml = """
        <m:d><m:dPr><m:begChr m:val="["/><m:endChr m:val="]"/></m:dPr><m:e>\(run("x"))</m:e></m:d>
        """
        XCTAssertEqual(try formula(xml), .formula(latex: "\\left[ x \\right]"))
    }

    // MARK: m:nary (sum/product/integral)

    func testNaryWithSumGlyphTranslatesToSumWithBoundsAndOperand() throws {
        let xml = """
        <m:nary><m:naryPr><m:chr m:val="\u{2211}"/></m:naryPr>
          <m:sub>\(run("i=1"))</m:sub><m:sup>\(run("n"))</m:sup><m:e>\(run("i"))</m:e>
        </m:nary>
        """
        XCTAssertEqual(try formula(xml), .formula(latex: "\\sum_{i=1}^{n} i"))
    }

    func testNaryWithHiddenBoundsOmitsThem() throws {
        let xml = """
        <m:nary><m:naryPr><m:chr m:val="\u{222B}"/><m:subHide m:val="1"/><m:supHide m:val="1"/></m:naryPr>
          <m:sub>\(run("a"))</m:sub><m:sup>\(run("b"))</m:sup><m:e>\(run("f"))</m:e>
        </m:nary>
        """
        XCTAssertEqual(try formula(xml), .formula(latex: "\\int f"))
    }

    /// An operator glyph this translator doesn't know is kept literally, never dropped.
    func testNaryWithUnmappedGlyphKeepsTheGlyphLiterally() throws {
        let xml = "<m:nary><m:naryPr><m:chr m:val=\"\u{2295}\"/></m:naryPr><m:e>\(run("x"))</m:e></m:nary>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\u{2295} x"))
    }

    // MARK: m:m / m:mr (matrix)

    func testMatrixTranslatesRowsAndColumnsWithAmpersandAndDoubleBackslash() throws {
        let xml = """
        <m:m>
          <m:mr>\(["a", "b"].map { "<m:e>\(run($0))</m:e>" }.joined())</m:mr>
          <m:mr>\(["c", "d"].map { "<m:e>\(run($0))</m:e>" }.joined())</m:mr>
        </m:m>
        """
        XCTAssertEqual(try formula(xml), .formula(latex: "\\begin{matrix} a & b \\\\ c & d \\end{matrix}"))
    }

    // MARK: m:func (function application)

    func testFuncTranslatesNameApplication() throws {
        let xml = "<m:func><m:fName>\(run("sin"))</m:fName><m:e>\(run("x"))</m:e></m:func>"
        XCTAssertEqual(try formula(xml), .formula(latex: "sin\\left(x\\right)"))
    }

    // MARK: m:limLow / m:limUpp

    func testLimLowTranslatesToSubscript() throws {
        let xml = "<m:limLow><m:e>\(run("lim"))</m:e><m:lim>\(run("x\\to 0"))</m:lim></m:limLow>"
        XCTAssertEqual(try formula(xml), .formula(latex: "lim_{x\\to 0}"))
    }

    func testLimUppTranslatesToSuperscript() throws {
        let xml = "<m:limUpp><m:e>\(run("f"))</m:e><m:lim>\(run("n"))</m:lim></m:limUpp>"
        XCTAssertEqual(try formula(xml), .formula(latex: "f^{n}"))
    }

    // MARK: m:bar (over/underline)

    func testBarDefaultsToOverline() throws {
        let xml = "<m:bar><m:e>\(run("x"))</m:e></m:bar>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\overline{x}"))
    }

    func testBarWithBottomPositionUnderlines() throws {
        let xml = "<m:bar><m:barPr><m:pos m:val=\"bot\"/></m:barPr><m:e>\(run("x"))</m:e></m:bar>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\underline{x}"))
    }

    // MARK: m:acc (accents)

    func testAccentCircumflexTranslatesToHat() throws {
        let xml = "<m:acc><m:accPr><m:chr m:val=\"\u{0302}\"/></m:accPr><m:e>\(run("x"))</m:e></m:acc>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\hat{x}"))
    }

    /// An accent glyph this translator doesn't know is kept literally alongside the base.
    func testAccentUnmappedGlyphKeepsTheGlyphLiterally() throws {
        let xml = "<m:acc><m:accPr><m:chr m:val=\"\u{0327}\"/></m:accPr><m:e>\(run("x"))</m:e></m:acc>"
        XCTAssertEqual(try formula(xml), .formula(latex: "x\u{0327}"))
    }

    // MARK: m:groupChr (over/underbrace)

    func testGroupChrOverbraceAtTop() throws {
        let xml = """
        <m:groupChr><m:groupChrPr><m:chr m:val="\u{23DE}"/><m:pos m:val="top"/></m:groupChrPr><m:e>\(run("x+y"))</m:e></m:groupChr>
        """
        XCTAssertEqual(try formula(xml), .formula(latex: "\\overbrace{x+y}"))
    }

    // MARK: m:eqArr (stacked equations)

    func testEqArrTranslatesEachRowOnItsOwnLine() throws {
        let xml = "<m:eqArr><m:e>\(run("x=1"))</m:e><m:e>\(run("y=2"))</m:e></m:eqArr>"
        XCTAssertEqual(try formula(xml), .formula(latex: "\\begin{aligned} x=1 \\\\ y=2 \\end{aligned}"))
    }

    // MARK: Fallback — unrecognized construct degrades to its own text, never to nothing

    /// `m:box` isn't one of the constructs this translator specifically knows how to shape — it
    /// must still surface the author's symbol rather than vanish.
    func testUnrecognizedConstructFallsBackToItsOwnText() throws {
        let xml = "<m:box>\(run("z"))</m:box>"
        XCTAssertEqual(try formula(xml), .formula(latex: "z"))
    }

    /// An equation with genuinely NOTHING translatable (no `m:t` anywhere, only property elements)
    /// must still produce something visible — never a formula block with empty LaTeX.
    func testEquationWithNoTranslatableContentDegradesToAVisiblePlaceholder() throws {
        let blocks = try read(document: "<w:p><m:oMathPara><m:oMath><m:radPr/></m:oMath></m:oMathPara></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "[equation]")])])
    }

    // MARK: Inline vs. standalone (WebBlock has no inline placeholder this sprint)

    /// A display equation — wrapped in `m:oMathPara`, alone in its own paragraph — becomes a
    /// `.formula` block, with no accompanying (empty) text block.
    func testStandaloneOMathParaBecomesAFormulaBlockAlone() throws {
        let blocks = try read(document: "<w:p><m:oMathPara><m:oMath>\(run("E=mc^2"))</m:oMath></m:oMathPara></w:p>")
        XCTAssertEqual(blocks, [.formula(latex: "E=mc^2")])
    }

    /// A BARE `m:oMath` (no `m:oMathPara` wrapper) mixed into a sentence has no web-block
    /// placeholder this sprint — it degrades to its own text, merged in place with the runs around
    /// it, so the sentence stays one block rather than being broken into three for one symbol.
    func testInlineBareOMathMixedIntoASentenceDegradesToTextInPlace() throws {
        let xml = "<w:p><w:r><w:t>Before </w:t></w:r><m:oMath>\(run("x"))</m:oMath><w:r><w:t> after</w:t></w:r></w:p>"
        let blocks = try read(document: xml)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Before x after")])])
    }

    /// A BARE `m:oMath` standing entirely alone in its own paragraph (the `m:oMathPara` wrapper
    /// omitted — some producers do this) still degrades to text under this sprint's rule: only the
    /// explicit `m:oMathPara` wrapper is read as "the author asked for a display equation".
    func testBareStandaloneOMathWithoutParaWrapperStillDegradesToText() throws {
        let blocks = try read(document: "<w:p><m:oMath>\(run("y"))</m:oMath></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "y")])])
    }

    // MARK: S14 — run colour, highlight, size, font family; paragraph alignment/tabs; cell
    // shading/borders/width; document default body size; style inheritance.

    /// A document with none of this sprint's new signals must render exactly as it did before it —
    /// every new `Span`/`Cell` field stays at its own default (`nil`).
    func testUnstyledDocumentSetsNoneOfThisSprintsNewFieldsAtAll() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Plain</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")])])
    }

    // MARK: w:color — literal, auto, theme

    func testRunColorLiteralHexIsReadAsTheLiteralColor() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:color w:val=\"FF0000\"/></w:rPr><w:t>Red</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Red", textColor: rgb("FF0000"))])])
    }

    /// `w:val="auto"` is Word's OWN "let the reader decide" sentinel — it must resolve to `nil`
    /// (the theme's own text colour), never to a fabricated black.
    func testRunColorValAutoIsUnsetNotBlack() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:color w:val=\"auto\"/></w:rPr><w:t>Auto</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Auto")])])
    }

    func testThemeColorResolvesAgainstTheThemePartsLiteralValue() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:color w:themeColor=\"accent1\"/></w:rPr><w:t>Theme</w:t></w:r></w:p>",
            styles: nil, theme: sampleTheme)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Theme", textColor: rgb("4F81BD"))])])
    }

    /// `"text2"`/`"background1"` are the semantically-named spellings of the SAME `dk2`/`lt1` scheme
    /// slots `"dark2"`/`"light1"` name — both must resolve to the identical literal.
    func testThemeColorSemanticTextAndDarkSpellingsResolveToTheSameSlot() throws {
        let semantic = try read(
            document: "<w:p><w:r><w:rPr><w:color w:themeColor=\"text2\"/></w:rPr><w:t>T</w:t></w:r></w:p>",
            styles: nil, theme: sampleTheme)
        let literal = try read(
            document: "<w:p><w:r><w:rPr><w:color w:themeColor=\"dark2\"/></w:rPr><w:t>T</w:t></w:r></w:p>",
            styles: nil, theme: sampleTheme)
        XCTAssertEqual(semantic, [.paragraph(spans: [Span(text: "T", textColor: rgb("1F497D"))])])
        XCTAssertEqual(semantic, literal)
    }

    /// No `word/theme/theme1.xml` at all (most real documents never carry one) must degrade to no
    /// colour, never crash and never fabricate one.
    func testThemeColorWithNoThemePartPresentDegradesWithoutCrashing() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:color w:themeColor=\"accent1\"/></w:rPr><w:t>NoTheme</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "NoTheme")])])
    }

    // MARK: w:highlight — named colours, not hex

    func testHighlightNamedColorResolvesToItsStandardRGB() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:highlight w:val=\"yellow\"/></w:rPr><w:t>Hi</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Hi", highlightColor: rgb("FFFF00"))])])
    }

    func testHighlightNoneMeansNoHighlight() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:highlight w:val=\"none\"/></w:rPr><w:t>Hi</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Hi")])])
    }

    // MARK: w:sz — half-points → points

    func testHalfPointFontSizeConvertsToPoints() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:sz w:val=\"24\"/></w:rPr><w:t>Sized</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Sized", fontSize: 12)])])
    }

    // MARK: w:rFonts — w:ascii chosen, w:hAnsi fallback

    func testRFontsAsciiIsChosenForBasicLatinText() throws {
        // Latin text selects `w:ascii`, and the `w:eastAsia` face declared beside it is simply never
        // reached — there is no East Asian character here to reach it. One family, so one span.
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia" w:eastAsia="MS Mincho"/></w:rPr><w:t>Font</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Font", fontName: "Georgia")])])
    }

    /// This test used to assert the opposite, and the behaviour it asserted was invented.
    ///
    /// The reader read `w:ascii ?? w:hAnsi`, on the stated reasoning that "Word requires at least one
    /// of the two on any `w:rFonts` that names a Latin font at all". MS-OI29500 §17.3.2.26 has no
    /// such cross-slot fallback: Basic Latin selects `ascii`, High ANSI selects `hAnsi`, and a run
    /// that declares only `hAnsi` has said nothing about its Basic Latin text. What Word draws there
    /// is its own application default, which for this reader is `nil` — the theme's body font.
    ///
    /// Keeping the old rule would not have been a harmless approximation once the other three slots
    /// arrived: `<w:rFonts w:hAnsi="Calibri" w:eastAsia="바탕"/>` would have put Calibri on the Latin
    /// text AND, through the same coalesce, hidden the fact that the ascii slot was never set.
    func testRFontsDoesNotBorrowHAnsiForBasicLatinWhenAsciiIsAbsent() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:rFonts w:hAnsi=\"Calibri\"/></w:rPr><w:t>Font</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Font", fontName: nil)])])
    }

    /// …and the same declaration DOES apply to text that genuinely lives in the hAnsi range. Thai is
    /// absent from the spec's table altogether, so it falls to the catch-all — which is the only
    /// reason `w:hAnsi` is reachable at all in a document with no `w:hint`.
    func testRFontsHAnsiAppliesToTextTheTableDoesNotClassify() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:rFonts w:hAnsi=\"Calibri\"/></w:rPr><w:t>ไทย</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "ไทย", fontName: "Calibri")])])
    }

    // MARK: w:rFonts — four slots, the theme font scheme, and the cascade under them

    /// The shape measured in five of five real Office themes in this project's corpus: `a:ea` and
    /// `a:cs` are EMPTY, and the families that matter live in the `a:font script=` list. A fixture
    /// that filled `a:ea` in would test a theme no real document has.
    private let sampleFontTheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
      <a:themeElements>
        <a:fontScheme name="Office">
          <a:majorFont>
            <a:latin typeface="Cambria"/><a:ea typeface=""/><a:cs typeface=""/>
            <a:font script="Hang" typeface="맑은 고딕 Semilight"/>
          </a:majorFont>
          <a:minorFont>
            <a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/>
            <a:font script="Hang" typeface="맑은 고딕"/>
            <a:font script="Jpan" typeface="ＭＳ 明朝"/>
          </a:minorFont>
        </a:fontScheme>
      </a:themeElements>
    </a:theme>
    """

    private func styles(_ body: String) -> String { "<w:styles>\(body)</w:styles>" }

    private func spans(_ blocks: [OfficeBlock]) throws -> [Span] {
        guard case let .paragraph(spans, _, _, _, _) = try XCTUnwrap(blocks.first) else {
            XCTFail("expected one paragraph, got \(blocks)")
            return []
        }
        return spans
    }

    /// `w:docDefaults/w:rPrDefault/w:rPr/w:rFonts` is the floor of the cascade (ISO/IEC 29500-1
    /// §17.7.5.1) and was read by nothing at all before this work — four of the six documents in
    /// this project's corpus declare one, and in the largest it IS the document's whole base font.
    func testDocDefaultsRFontsSuppliesTheFamilyWhenNothingElseDoes() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Body</w:t></w:r></w:p>",
            styles: styles("<w:docDefaults><w:rPrDefault><w:rPr>"
                           + "<w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\"/></w:rPr></w:rPrDefault></w:docDefaults>"))
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Body", fontName: "Georgia")])])
    }

    /// A paragraph naming no style of its own inherits the `w:default="1"` paragraph style. Five of
    /// six corpus documents declare one, and `walkStyleChain` returns immediately for a nil style
    /// id, so before this every unstyled paragraph skipped the document's own Normal entirely.
    func testTheDefaultParagraphStyleAppliesToAParagraphThatNamesNoStyle() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Body</w:t></w:r></w:p>",
            styles: styles("<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\">"
                           + "<w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\"/></w:rPr></w:style>"))
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Body", fontName: "Georgia")])])
    }

    /// …and a paragraph that DOES name a style reaches Normal only if its own `w:basedOn` chain
    /// leads there, which is what `w:default="1"` means. Characterises the boundary so that
    /// widening it later is a deliberate change rather than a drift.
    func testAParagraphNamingItsOwnStyleDoesNotAlsoInheritTheDefaultStyle() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Rooted\"/></w:pPr><w:r><w:t>Body</w:t></w:r></w:p>",
            styles: styles("<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\">"
                           + "<w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\"/></w:rPr></w:style>"
                           + "<w:style w:type=\"paragraph\" w:styleId=\"Rooted\"><w:rPr><w:sz w:val=\"24\"/></w:rPr></w:style>"))
        XCTAssertEqual(try spans(blocks).map(\.fontName), [nil])
    }

    /// The reason each slot needs its OWN walk. The child style names only a Latin face; resolving
    /// the whole `w:rFonts` in one walk would stop there and read the child's silence about East
    /// Asian text as an answer, losing the ancestor's 바탕.
    func testEachFontSlotCascadesIndependentlyThroughTheStyleChain() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Child\"/></w:pPr><w:r><w:t>가A</w:t></w:r></w:p>",
            styles: styles("<w:style w:type=\"paragraph\" w:styleId=\"Base\">"
                           + "<w:rPr><w:rFonts w:eastAsia=\"바탕\"/></w:rPr></w:style>"
                           + "<w:style w:type=\"paragraph\" w:styleId=\"Child\"><w:basedOn w:val=\"Base\"/>"
                           + "<w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\"/></w:rPr></w:style>"))
        XCTAssertEqual(try spans(blocks).map { [$0.text, $0.fontName ?? "nil"] },
                       [["가", "바탕"], ["A", "Georgia"]])
    }

    /// The headline case of this unit, and the one no synthetic assumption could have found: on a
    /// real Office theme `a:ea` is empty, so `minorEastAsia` resolves through the `a:font
    /// script="Hang"` entry or not at all. A reader parsing only `a:latin`/`a:ea`/`a:cs` gets the
    /// empty string here and gains nothing on any real Korean document.
    func testAnEastAsiaThemeReferenceResolvesThroughTheThemesOwnScriptList() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>한글English</w:t></w:r></w:p>",
            styles: styles("<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme=\"minorHAnsi\""
                           + " w:hAnsiTheme=\"minorHAnsi\" w:eastAsiaTheme=\"minorEastAsia\"/>"
                           + "</w:rPr></w:rPrDefault></w:docDefaults>"),
            theme: sampleFontTheme)
        XCTAssertEqual(try spans(blocks).map { [$0.text, $0.fontName ?? "nil"] },
                       [["한글", "맑은 고딕"], ["English", "Calibri"]])
    }

    /// The theme part must be read even when `word/styles.xml` is missing — a direct run can carry a
    /// theme reference with no style involved. This is the exact early-return bug the theme COLOUR
    /// reader already caught once (`parseStyles`' own comment says so); repeating it for fonts was
    /// one guard away.
    func testThemeFontsAreReadEvenWhenStylesXmlIsAbsent() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:rFonts w:eastAsiaTheme=\"minorEastAsia\"/></w:rPr><w:t>한글</w:t></w:r></w:p>",
            styles: nil, theme: sampleFontTheme)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "한글", fontName: "맑은 고딕")])])
    }

    /// MS-OI29500 §17.3.2.26 note e, across levels: an inherited `w:eastAsia` overrides a previously
    /// specified `w:eastAsia` OR `w:eastAsiaTheme`. Modelling literal and theme as two independent
    /// optionals would let the docDefaults theme reference leak past the style's literal.
    func testALiteralSlotAtALowerLevelReplacesAnInheritedThemeReference() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Body\"/></w:pPr><w:r><w:t>한글</w:t></w:r></w:p>",
            styles: styles("<w:docDefaults><w:rPrDefault><w:rPr>"
                           + "<w:rFonts w:eastAsiaTheme=\"minorEastAsia\"/></w:rPr></w:rPrDefault></w:docDefaults>"
                           + "<w:style w:type=\"paragraph\" w:styleId=\"Body\">"
                           + "<w:rPr><w:rFonts w:eastAsia=\"바탕\"/></w:rPr></w:style>"),
            theme: sampleFontTheme)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "한글", fontName: "바탕")])])
    }

    /// The same note, WITHIN one element: the theme reference wins over the literal beside it.
    func testAThemeReferenceWinsOverALiteralOnTheSameRFontsElement() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr>"
                + "<w:rFonts w:eastAsia=\"바탕\" w:eastAsiaTheme=\"minorEastAsia\"/></w:rPr><w:t>한글</w:t></w:r></w:p>",
            styles: nil, theme: sampleFontTheme)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "한글", fontName: "맑은 고딕")])])
    }

    /// The ONLY way the complex-script slot is ever reached: a run-level `w:cs` toggle puts the
    /// whole run in `cs` *"regardless of the Unicode character values of the run's content"*, so the
    /// Korean and the Latin here share one family and one span.
    func testARunLevelComplexScriptToggleUsesTheCsSlotForEveryCharacter() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:cs/>"
                + "<w:rFonts w:ascii=\"Georgia\" w:eastAsia=\"바탕\" w:cs=\"Arial\"/></w:rPr><w:t>가A</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "가A", fontName: "Arial")])])
    }

    func testARunLevelRtlToggleAlsoSelectsTheCsSlot() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:rtl/>"
                + "<w:rFonts w:ascii=\"Georgia\" w:eastAsia=\"바탕\" w:cs=\"Arial\"/></w:rPr><w:t>가A</w:t></w:r></w:p>")
        XCTAssertEqual(try spans(blocks).map { [$0.text, $0.fontName ?? "nil"] }, [["가A", "Arial"]])
    }

    /// Word's legacy exception: `eastAsia="Times New Roman"` beside two equal Latin slots is what
    /// Word writes when nobody ever set an East Asian font, so it is read as unset and the Korean
    /// text takes the ascii face — one family, one span.
    func testTheLegacyTimesNewRomanEastAsiaIsReadAsUnset() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\""
                + " w:eastAsia=\"Times New Roman\"/></w:rPr><w:t>가A</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "가A", fontName: "Georgia")])])
    }

    /// `w:hint="eastAsia"` is what makes twenty-three of the table's rows do anything at all. Greek
    /// is one of them and, unlike the symbol blocks, survives absorption to ask.
    func testTheEastAsiaHintSendsGreekToTheEastAsiaSlot() throws {
        let hinted = try read(
            document: "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\""
                + " w:eastAsia=\"바탕\" w:hint=\"eastAsia\"/></w:rPr><w:t>αA</w:t></w:r></w:p>")
        XCTAssertEqual(try spans(hinted).map { [$0.text, $0.fontName ?? "nil"] }, [["α", "바탕"], ["A", "Georgia"]])
        let unhinted = try read(
            document: "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\""
                + " w:eastAsia=\"바탕\"/></w:rPr><w:t>αA</w:t></w:r></w:p>")
        XCTAssertEqual(try spans(unhinted).map { [$0.text, $0.fontName ?? "nil"] }, [["αA", "Georgia"]])
    }

    /// Invariant 37, structurally: pieces break on the resolved FAMILY, never on the slot, so a
    /// document pointing all four slots at one face comes back as the single span it always was —
    /// no matter how many times the text alternates between writing systems.
    func testARunWhoseFourSlotsNameOneFamilyIsNeverSplit() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\""
                + " w:eastAsia=\"Georgia\" w:cs=\"Georgia\"/></w:rPr><w:t>가A1 나B2 다C</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "가A1 나B2 다C", fontName: "Georgia")])])
    }

    /// …and a document that declares no font at all is byte-identical to before any of this existed.
    func testARunDeclaringNoFontAtAllIsUnchanged() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>가A1 나B2</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "가A1 나B2", fontName: nil)])])
    }

    /// A run made only of script-neutral characters has no neighbour to absorb into. The splitter's
    /// own reading of that is "no family", which for Word is wrong rather than conservative — its
    /// table says outright that Basic Latin selects `ascii`. Leaving it uncorrected silently dropped
    /// declared families and ADDED spans, because such runs then matched none of their neighbours.
    func testARunOfNothingButNeutralCharactersStillTakesTheTablesAnswer() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\""
                + " w:eastAsia=\"바탕\"/></w:rPr><w:t>2026 (3)</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "2026 (3)", fontName: "Georgia")])])
    }

    /// Splitting must not lose or duplicate a character, and must not cut a grapheme cluster —
    /// asserted on the traps Word's own table would otherwise break: a combining accent (its base is
    /// `ascii`, the mark is `hAnsi`), and a ZWJ emoji pair (both emoji are `eastAsia`, the joiner
    /// between them is `hAnsi`).
    func testSplittingPreservesEveryCharacterAndNeverCutsACluster() throws {
        let text = "e\u{0301}가A\u{1F468}\u{200D}\u{1F469}나 2026"
        let blocks = try read(
            document: "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Calibri\""
                + " w:eastAsia=\"바탕\"/></w:rPr><w:t>\(text)</w:t></w:r></w:p>")
        let produced = try spans(blocks)
        XCTAssertEqual(produced.map(\.text).joined(), text, "concatenating the pieces must reproduce the run")
        XCTAssertFalse(produced.contains { $0.text.isEmpty }, "no piece may be empty")
        for piece in produced {
            XCTAssertFalse(piece.text.unicodeScalars.first.map { UnicodeScript.of($0).isAbsorbing } ?? false,
                           "a piece must never START on cluster machinery: \(piece.text.debugDescription)")
        }
    }

    /// Invariant 29: the parser being right says nothing about the application reaching it. This is
    /// the same document through `DocumentTypes.readOffice`, which is what `MarkdownDocument` and
    /// `--extract` both call, and which also runs `resolvingFontSubstitution()` on the way out.
    func testPerSlotFontsSurviveTheRealOfficeDispatch() throws {
        let zip = buildDocx(
            document: doc("<w:p><w:r><w:t>한글English</w:t></w:r></w:p>"),
            styles: styles("<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme=\"minorHAnsi\""
                           + " w:hAnsiTheme=\"minorHAnsi\" w:eastAsiaTheme=\"minorEastAsia\"/>"
                           + "</w:rPr></w:rPrDefault></w:docDefaults>"),
            theme: sampleFontTheme)
        let result = try DocumentTypes.readOffice(try ZipArchive(data: zip), extension: "docx")
        XCTAssertEqual(try spans(result.blocks).map { [$0.text, $0.fontName ?? "nil"] },
                       [["한글", "맑은 고딕"], ["English", "Calibri"]])
    }

    // MARK: w:docDefaults — the document's own default body size

    func testDocumentDefaultFontSizeIsReadFromDocDefaults() throws {
        let styles = "<w:styles><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val=\"20\"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>"
        let zip = buildDocx(document: doc("<w:p><w:r><w:t>Body</w:t></w:r></w:p>"), styles: styles)
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(DocxReader.documentDefaultBodyFontSize(archive), 10)
    }

    /// 10, not the 11 this asserted for a long time. 11 is what modern Word WRITES into a new
    /// document's `w:docDefaults`; it is not what Word ASSUMES when the element is absent, and this
    /// test asserted the former while the reader needed the latter. Measured against Word's own
    /// output on a real Korean report that declares no `w:sz` anywhere: Word draws its body at a
    /// 10.03pt em. Under the paged model this number is the theme base size, so it decided 99.1% of
    /// that document's characters.
    func testDocumentDefaultFontSizeFallsBackToTenWhenNotDeclared() throws {
        let zip = buildDocx(document: doc("<w:p><w:r><w:t>Body</w:t></w:r></w:p>"))
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(DocxReader.documentDefaultBodyFontSize(archive), 10)
    }

    // MARK: w:tblCellMar through the table-style chain, and w:docGrid

    /// Word puts its stock cell margin in the DEFAULT TABLE STYLE, not on the table, so a table that
    /// declares no `w:tblCellMar` of its own is NOT saying "nothing" — it is inheriting
    /// `top=0 left=108 bottom=0 right=108`. Reading only `w:tblPr` made every such table fall through
    /// to `TableBlockBuilder.defaultCellPadding` (7pt) on all four edges; measured on a real report,
    /// that is 14pt of vertical padding the document had explicitly set to ZERO, and the bulk of a
    /// 28.3pt row where Word draws 18.5pt.
    func testTableCellMarginIsInheritedFromTheDefaultTableStyle() throws {
        let styles = """
        <w:styles><w:style w:type="table" w:default="1" w:styleId="a1"><w:name w:val="Normal Table"/>\
        <w:tblPr><w:tblCellMar><w:top w:w="0"/><w:left w:w="108"/><w:bottom w:w="0"/><w:right w:w="108"/>\
        </w:tblCellMar></w:tblPr></w:style></w:styles>
        """
        let table = "<w:tbl><w:tblPr/><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        let blocks = try read(document: table, styles: styles)
        guard case let .table(_, _, _, format)? = blocks.first(where: { if case .table = $0 { return true }; return false })
        else { return XCTFail("expected a table block") }
        let padding = try XCTUnwrap(format.defaultPadding, "the default table style's cell margin must reach TableFormat")
        XCTAssertEqual(padding.top, 0, "the document said ZERO top margin — not 'nothing'")
        XCTAssertEqual(padding.bottom, 0)
        XCTAssertEqual(try XCTUnwrap(padding.left), 5.4, accuracy: 0.001, "108 twips")
        XCTAssertEqual(try XCTUnwrap(padding.right), 5.4, accuracy: 0.001)
    }

    /// A table's OWN `w:tblCellMar` still wins over the style it would otherwise inherit — the
    /// cascade is direct > named style > default style, exactly as Word resolves it.
    func testATablesOwnCellMarginBeatsTheDefaultTableStyle() throws {
        let styles = """
        <w:styles><w:style w:type="table" w:default="1" w:styleId="a1"><w:name w:val="Normal Table"/>\
        <w:tblPr><w:tblCellMar><w:top w:w="0"/><w:left w:w="108"/><w:bottom w:w="0"/><w:right w:w="108"/>\
        </w:tblCellMar></w:tblPr></w:style></w:styles>
        """
        let table = """
        <w:tbl><w:tblPr><w:tblCellMar><w:top w:w="40"/><w:left w:w="40"/><w:bottom w:w="40"/><w:right w:w="40"/>\
        </w:tblCellMar></w:tblPr><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """
        let blocks = try read(document: table, styles: styles)
        guard case let .table(_, _, _, format)? = blocks.first(where: { if case .table = $0 { return true }; return false })
        else { return XCTFail("expected a table block") }
        let padding = try XCTUnwrap(format.defaultPadding)
        XCTAssertEqual(try XCTUnwrap(padding.top), 2, accuracy: 0.001, "40 twips — the table's own value, not the style's 0")
    }

    /// A table in a document with no table styles at all keeps reading as "nothing declared", so
    /// every existing fixture and every document that never wrote one is byte-identical (invariant 37).
    func testATableInADocumentWithNoTableStyleStillDeclaresNoPadding() throws {
        let table = "<w:tbl><w:tblPr/><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        let blocks = try read(document: table)
        guard case let .table(_, _, _, format)? = blocks.first(where: { if case .table = $0 { return true }; return false })
        else { return XCTFail("expected a table block") }
        XCTAssertNil(format.defaultPadding)
    }

    /// `w:docGrid` is how a Korean/Japanese Word document says "every line sits on an N-point grid".
    /// Only the two types that grid the LINE axis count — `default` grids nothing and `chars` grids
    /// only the horizontal axis, so reading either as a line height would impose a floor Word does
    /// not apply.
    func testDocGridLinePitchIsReadOnlyForLineGriddingTypes() throws {
        func pitch(_ sectPr: String) throws -> CGFloat? {
            let zip = buildDocx(document: doc("<w:p><w:r><w:t>Body</w:t></w:r></w:p>" + sectPr))
            return try DocxReader.read(ZipArchive(data: zip)).lineGridPitch
        }
        XCTAssertEqual(try pitch("<w:sectPr><w:docGrid w:type=\"lines\" w:linePitch=\"360\"/></w:sectPr>"), 18)
        XCTAssertEqual(try pitch("<w:sectPr><w:docGrid w:type=\"linesAndChars\" w:linePitch=\"312\"/></w:sectPr>"), 15.6)
        XCTAssertNil(try pitch("<w:sectPr><w:docGrid w:type=\"default\" w:linePitch=\"360\"/></w:sectPr>"))
        XCTAssertNil(try pitch("<w:sectPr><w:docGrid w:type=\"chars\" w:linePitch=\"360\"/></w:sectPr>"))
        XCTAssertNil(try pitch("<w:sectPr><w:docGrid w:type=\"lines\" w:linePitch=\"0\"/></w:sectPr>"),
                     "a non-positive pitch is malformed, not an instruction")
        XCTAssertNil(try pitch("<w:sectPr/>"), "no grid → nil, so every document without one is unchanged")
    }

    // MARK: w:jc — alignment, and winning over the rtl default

    /// The reader must populate `alignment` even on an `rtl` paragraph — that is what lets
    /// `OfficeTextBuilder` give an EXPLICIT alignment precedence over `rtl`'s own implicit edge
    /// (see `OfficeBlock`'s doc on the two).
    func testExplicitJcIsPopulatedAlongsideRtlSoItCanWinOverTheImplicitDefault() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:bidi/><w:jc w:val="left"/></w:pPr><w:r><w:t>Text</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")], rtl: true, alignment: .left)])
    }

    func testJcBothMapsToJustifiedAlignment() throws {
        let blocks = try read(document: "<w:p><w:pPr><w:jc w:val=\"both\"/></w:pPr><w:r><w:t>Text</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")], alignment: .justified)])
    }

    // MARK: w:tabs — twips → points, w:val="clear" skipped

    func testTabStopsConvertTwipsToPoints() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/><w:tab w:val="right" w:pos="1440"/></w:tabs></w:pPr><w:r><w:t>Tabbed</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Tabbed")],
                                            tabStops: [TabStop(position: 36, alignment: .left),
                                                       TabStop(position: 72, alignment: .right)])])
    }

    func testTabStopsClearEntryIsSkippedNotEmittedAsAPhantomStop() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:tabs><w:tab w:val="clear" w:pos="720"/><w:tab w:val="left" w:pos="1440"/></w:tabs></w:pPr><w:r><w:t>Tabbed</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Tabbed")], tabStops: [TabStop(position: 72)])])
    }

    /// P2b — `@w:val` (`ST_TabJc`) resolves into `TabStop.alignment`: `center`/`decimal` each get
    /// their own case, and `@w:leader` is carried (not drawn — see `TabLeader`'s doc) alongside it.
    func testTabAlignmentAndLeaderResolveFromWVal() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:tabs>
          <w:tab w:val="center" w:pos="720"/>
          <w:tab w:val="decimal" w:pos="1440" w:leader="dot"/>
        </w:tabs></w:pPr><w:r><w:t>Numbers</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Numbers")],
                                            tabStops: [TabStop(position: 36, alignment: .center),
                                                       TabStop(position: 72, alignment: .decimal, leader: .dot)])])
    }

    /// `w:val="bar"` (a vertical rule, not a text stop) has no place in this vocabulary, exactly
    /// like `"clear"` — it must be skipped, never emitted as a phantom `.left` stop.
    func testTabBarValueIsSkipped() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:tabs><w:tab w:val="bar" w:pos="720"/><w:tab w:val="left" w:pos="1440"/></w:tabs></w:pPr><w:r><w:t>Tabbed</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Tabbed")], tabStops: [TabStop(position: 72)])])
    }

    // MARK: Style inheritance — direct > style > basedOn ancestor, per-property

    func testColorInheritedFromParagraphStyleWhenRunDoesNotSetItsOwn() throws {
        let styles = """
        <w:styles><w:style w:type="paragraph" w:styleId="Warn"><w:rPr><w:color w:val="FF0000"/></w:rPr></w:style></w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Warn\"/></w:pPr><w:r><w:t>Danger</w:t></w:r></w:p>", styles: styles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Danger", textColor: rgb("FF0000"))])])
    }

    func testDirectRunColorWinsOverItsParagraphStylesColor() throws {
        let styles = """
        <w:styles><w:style w:type="paragraph" w:styleId="Warn"><w:rPr><w:color w:val="FF0000"/></w:rPr></w:style></w:styles>
        """
        let blocks = try read(document: """
        <w:p><w:pPr><w:pStyle w:val="Warn"/></w:pPr><w:r><w:rPr><w:color w:val="00FF00"/></w:rPr><w:t>Override</w:t></w:r></w:p>
        """, styles: styles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Override", textColor: rgb("00FF00"))])])
    }

    /// Neither `Leaf` nor `Mid` sets a colour — only their common ancestor `Base` does — so
    /// resolving it correctly proves the chain climbs past a style with NO answer for this
    /// property, not just one level.
    func testColorResolvesThroughATwoLevelBasedOnChainWhenNeitherNearerStyleSetsIt() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="Base"><w:rPr><w:color w:val="112233"/></w:rPr></w:style>
          <w:style w:type="paragraph" w:styleId="Mid"><w:basedOn w:val="Base"/></w:style>
          <w:style w:type="paragraph" w:styleId="Leaf"><w:basedOn w:val="Mid"/></w:style>
        </w:styles>
        """
        let blocks = try read(document: "<w:p><w:pPr><w:pStyle w:val=\"Leaf\"/></w:pPr><w:r><w:t>Chain</w:t></w:r></w:p>", styles: styles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Chain", textColor: rgb("112233"))])])
    }

    func testAlignmentInheritedFromParagraphStyleWhenParagraphDoesNotRestateIt() throws {
        let styles = """
        <w:styles><w:style w:type="paragraph" w:styleId="Centered"><w:pPr><w:jc w:val="center"/></w:pPr></w:style></w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Centered\"/></w:pPr><w:r><w:t>Text</w:t></w:r></w:p>", styles: styles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")], alignment: .center)])
    }

    func testTabStopsInheritedFromParagraphStyleWhenParagraphDoesNotDeclareItsOwn() throws {
        let styles = """
        <w:styles><w:style w:type="paragraph" w:styleId="Indented"><w:pPr><w:tabs><w:tab w:val="left" w:pos="360"/></w:tabs></w:pPr></w:style></w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Indented\"/></w:pPr><w:r><w:t>Text</w:t></w:r></w:p>", styles: styles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")], tabStops: [TabStop(position: 18)])])
    }

    // MARK: Table cells — w:shd, w:tcBorders, w:tcW

    func testCellShadingFillIsReadAsBackgroundColor() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:shd w:fill="FFCC00"/></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].backgroundColor, rgb("FFCC00"))
    }

    func testCellShadingAutoFillIsUnshaded() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:shd w:fill="auto"/></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].backgroundColor)
    }

    func testCellBorderColorAndWidthAreReadFromTheTopEdge() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcBorders><w:top w:val="single" w:sz="8" w:color="336699"/></w:tcBorders></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].borderColor, rgb("336699"))
        XCTAssertEqual(rows[0][0].borderWidth, 1)
    }

    /// `w:top`'s `w:val="none"` (no border drawn on that edge) must be skipped in favour of the
    /// next drawn edge, not read as though it were a real border.
    func testCellBorderNoneEdgeIsSkippedInFavorOfTheNextDrawnEdge() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcBorders><w:top w:val="none"/><w:left w:val="single" w:sz="16" w:color="112233"/></w:tcBorders></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].borderColor, rgb("112233"))
        XCTAssertEqual(rows[0][0].borderWidth, 2)
    }

    func testCellWidthDxaConvertsTwipsToPoints() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcW w:w="2880" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].width, 144)
    }

    /// `w:type="pct"` (a percentage of the table's own available width) is out of this sprint's
    /// scope — it must be skipped (`nil`), never misread as an absolute point value.
    func testCellWidthPctTypeIsSkipped() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcW w:w="2500" w:type="pct"/></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].width)
    }

    // MARK: P3b — table-level default border/shading (w:tblPr/w:tblBorders, w:tblPr/w:shd)

    /// A table-level `w:tblBorders` is carried as `TableFormat.defaultBorderColor`/`.defaultBorderWidth`
    /// — a cell that declares no `w:tcBorders` of its own must NOT see it baked into `Cell.borderColor`/
    /// `.borderWidth` (those stay `nil`, exactly as before this sprint); the table default is a
    /// separate, later-resolved layer (`TableBlockBuilder`'s job), not something the reader smears
    /// onto every cell.
    func testTableLevelBordersAreCarriedOnTableFormatNotSmearedOntoEveryCell() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="8" w:color="336699"/></w:tblBorders></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].borderColor)
        XCTAssertNil(rows[0][0].borderWidth)
        XCTAssertEqual(format.defaultBorderColor, rgb("336699"))
        XCTAssertEqual(format.defaultBorderWidth, 1)
    }

    /// A cell's own `w:tcBorders` is unaffected by a table-level default existing alongside it —
    /// still read exactly as `testCellBorderColorAndWidthAreReadFromTheTopEdge` already covers.
    func testCellOwnBorderIsStillReadWhenATableLevelDefaultAlsoExists() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="8" w:color="336699"/></w:tblBorders></w:tblPr>
        <w:tr><w:tc><w:tcPr><w:tcBorders><w:top w:val="single" w:sz="16" w:color="112233"/></w:tcBorders></w:tcPr>
        <w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].borderColor, rgb("112233"))
        XCTAssertEqual(rows[0][0].borderWidth, 2)
        XCTAssertEqual(format.defaultBorderColor, rgb("336699"))
    }

    func testTableLevelShadingIsCarriedOnTableFormat() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:shd w:fill="FFCC00"/></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].backgroundColor)
        XCTAssertEqual(format.defaultShading, rgb("FFCC00"))
    }

    /// A table with no `w:tblPr` at all — every markdown table, and most docx tables — constructs
    /// the all-`nil` `TableFormat()` default.
    func testTableWithNoTblPrGetsAnAllNilTableFormat() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(_, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(format, TableFormat())
    }

    // MARK: Per-edge borders — the THREE states (declared / suppressed / never mentioned)

    /// The `BorderSide` a `.drawn` declaration carries; `nil` for `.suppressed` and for an edge the
    /// document never mentioned — so a test can read a width/colour without repeating the `case let`.
    private func drawn(_ decl: BorderDecl?) -> BorderSide? {
        if case .drawn(let side) = decl { return side }
        return nil
    }

    /// A `w:tblBorders` that names only SOME edges leaves the rest UNSPECIFIED (`nil`). "The
    /// document said nothing about the left edge" must not arrive looking like "the document turned
    /// the left edge off" — the renderer treats the two differently once a cell has its own say.
    func testTableEdgesNamedOnlyPartlyLeaveTheRestUnspecified() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="8" w:color="336699"/>
        <w:bottom w:val="single" w:sz="8" w:color="336699"/></w:tblBorders></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(_, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(format.edgeBorders)
        XCTAssertEqual(drawn(edges.top)?.width, 1)
        XCTAssertEqual(drawn(edges.top)?.color, rgb("336699"))
        XCTAssertEqual(drawn(edges.bottom)?.width, 1)
        XCTAssertNil(edges.left, "an edge the document never mentioned stays unspecified")
        XCTAssertNil(edges.right)
        XCTAssertNil(edges.insideH)
        XCTAssertNil(edges.insideV)
    }

    /// `w:val="none"` (and its twin `"nil"`) is an explicit OFF — `.suppressed`, a declaration in its
    /// own right, never the same `nil` an unmentioned edge gets. Everything downstream depends on
    /// telling those two apart: one draws nothing, the other may be filled in.
    func testEdgeValNoneAndNilAreSuppressedNotUnspecified() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="none"/><w:bottom w:val="nil"/>
        <w:left w:val="single" w:sz="16" w:color="112233"/></w:tblBorders></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(_, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(format.edgeBorders)
        XCTAssertEqual(edges.top, .suppressed)
        XCTAssertEqual(edges.bottom, .suppressed)
        XCTAssertEqual(drawn(edges.left)?.width, 2)
        XCTAssertNil(edges.right, "still unspecified — different from the two suppressed edges")
    }

    /// A cell's own `w:tcBorders` reads per edge exactly as the table's does.
    func testCellEdgesAreReadPerEdgeToo() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcBorders><w:left w:val="single" w:sz="24" w:color="112233"/>
        <w:right w:val="none"/></w:tcBorders></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(rows[0][0].edgeBorders)
        XCTAssertEqual(drawn(edges.left)?.width, 3)
        XCTAssertEqual(drawn(edges.left)?.color, rgb("112233"))
        XCTAssertEqual(edges.right, .suppressed)
        XCTAssertNil(edges.top)
    }

    /// A table that turns EVERY border off must survive as an all-`.suppressed` declaration. Erasing
    /// it (which is what an `isEmpty` that counted suppressed edges as nothing would do) hands the
    /// renderer the same input as a document that never mentioned borders — and that renders with
    /// the theme's own default rule, i.e. exactly the border the author removed.
    func testATableThatTurnsEveryBorderOffSurvivesAsADeclaration() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="none"/><w:left w:val="none"/><w:bottom w:val="none"/>
        <w:right w:val="none"/><w:insideH w:val="none"/><w:insideV w:val="none"/></w:tblBorders></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(_, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(format.edgeBorders, "an all-off declaration must not be erased as silence")
        XCTAssertFalse(edges.isEmpty, "every edge off is a declaration, not an absence of one")
        for edge in [edges.top, edges.left, edges.bottom, edges.right, edges.insideH, edges.insideV] {
            XCTAssertEqual(edge, .suppressed)
        }
    }

    /// A drawn `w:val` with NO `w:sz` stays UNSPECIFIED — a deliberate choice (the element states no
    /// width and this renderer draws with widths), not an oversight. Pinned so a later reader can see
    /// the behaviour was chosen rather than assume the missing case was forgotten.
    func testADrawnEdgeWithNoSizeStaysUnspecifiedDeliberately() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="single" w:color="336699"/>
        <w:bottom w:val="single" w:sz="8"/></w:tblBorders></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(_, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(format.edgeBorders)
        XCTAssertNil(edges.top, "no w:sz → unspecified, never a fabricated width")
        XCTAssertEqual(drawn(edges.bottom)?.width, 1)
    }

    /// A table that mentions borders NOWHERE carries no edge declaration at all — this is the input
    /// that keeps the renderer on its own theme default (invariant 37's unspecified case).
    func testATableWithNoBorderElementsAtAllHasNoEdgeDeclaration() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(format.edgeBorders)
        XCTAssertNil(rows[0][0].edgeBorders)
    }

    // MARK: P3b — cell vertical alignment (w:tcPr/w:vAlign)

    func testCellVAlignCenterIsReadAsCellVAlignCenter() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:vAlign w:val="center"/></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].verticalAlignment, .center)
    }

    func testCellWithNoVAlignHasNilVerticalAlignment() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].verticalAlignment)
    }

    // MARK: P3b — cell margins (w:tcPr/w:tcMar, w:tblPr/w:tblCellMar)

    /// `w:tcMar/w:start` in TWIPS converts to points the same way every other twips field does
    /// (÷20) — 200 twips → 10pt.
    func testCellOwnTcMarConvertsTwipsToPoints() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcMar><w:start w:w="200" w:type="dxa"/></w:tcMar></w:tcPr>
        <w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].padding, 10)
    }

    /// A cell with no `w:tcMar` of its own inherits the table's `w:tblPr/w:tblCellMar` — 160
    /// twips → 8pt, deliberately NOT `TableBlockBuilder`'s own 7pt fallback, so this test can't
    /// pass by accident if the inheritance chain were dropped and `Cell.padding` stayed `nil`.
    func testCellWithNoOwnTcMarInheritsTheTableDefaultCellMargin() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblCellMar><w:start w:w="160" w:type="dxa"/></w:tblCellMar></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].padding, 8)
    }

    /// A cell's OWN `w:tcMar` wins over the table's default when both are present.
    func testCellOwnTcMarWinsOverTheTableDefaultCellMargin() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblCellMar><w:start w:w="140" w:type="dxa"/></w:tblCellMar></w:tblPr>
        <w:tr><w:tc><w:tcPr><w:tcMar><w:start w:w="200" w:type="dxa"/></w:tcMar></w:tcPr>
        <w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].padding, 10)
    }

    /// Neither the cell nor the table declares a margin — `Cell.padding` stays `nil`, exactly as
    /// before this field existed (`TableBlockBuilder` keeps its own 7pt default).
    func testCellWithNeitherOwnNorTableMarginHasNilPadding() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].padding)
    }

    // MARK: PAGED per-edge cell margins (Cell.edgePadding, TableFormat.defaultPadding) — the SAME
    // `w:tcMar`/`w:tblCellMar` elements the P3b tests above read, but all FOUR edges independently,
    // consulted only by the PAGED table-geometry model.

    /// Word's own STOCK default (`left=start 108, right=end 108, top=0, bottom=0` twips = 5.4pt
    /// sides, EXPLICITLY zero top/bottom) must survive as a real zero, not be smeared with the
    /// left/start value the way the single-value `padding` above necessarily reduces it to.
    func testCellOwnTcMarPerEdgeKeepsAnExplicitZeroDistinctFromTheSideValue() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcMar>
        <w:top w:w="0" w:type="dxa"/><w:start w:w="108" w:type="dxa"/>
        <w:bottom w:w="0" w:type="dxa"/><w:end w:w="108" w:type="dxa"/>
        </w:tcMar></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(rows[0][0].edgePadding)
        XCTAssertEqual(edges.top, 0)
        XCTAssertEqual(edges.bottom, 0)
        XCTAssertEqual(edges.left ?? -1, 5.4, accuracy: 0.001)
        XCTAssertEqual(edges.right ?? -1, 5.4, accuracy: 0.001)
    }

    /// A `w:tcMar` that only states SOME edges leaves the others genuinely `nil` (undeclared), not
    /// zero — an edge the document never mentioned must fall through the cascade, not be read as an
    /// explicit zero it never asked for.
    func testCellOwnTcMarLeavesUnstatedEdgesNil() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:tcPr><w:tcMar>
        <w:start w:w="200" w:type="dxa"/>
        </w:tcMar></w:tcPr><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(rows[0][0].edgePadding)
        XCTAssertEqual(edges.left, 10)
        XCTAssertNil(edges.top, "an edge the document never mentioned must stay nil, not fall to 0")
        XCTAssertNil(edges.bottom)
        XCTAssertNil(edges.right)
    }

    /// The table's own `w:tblCellMar`, per edge, reaches `TableFormat.defaultPadding` — the PAGED
    /// fallback layer beneath a cell's own `edgePadding`.
    func testTableWideTblCellMarPerEdgeReachesTableFormatDefaultPadding() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblCellMar>
        <w:top w:w="0" w:type="dxa"/><w:start w:w="160" w:type="dxa"/>
        <w:bottom w:w="0" w:type="dxa"/><w:end w:w="160" w:type="dxa"/>
        </w:tblCellMar></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(_, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        let edges = try XCTUnwrap(format.defaultPadding)
        XCTAssertEqual(edges.top, 0)
        XCTAssertEqual(edges.bottom, 0)
        XCTAssertEqual(edges.left, 8)
        XCTAssertEqual(edges.right, 8)
    }

    /// A cell's own `edgePadding` is kept SEPARATE from the table's default — `TableBlockBuilder`'s
    /// own cascade combines the two, the reader must not pre-merge them (unlike the single-value
    /// `padding` above, which pre-merges by necessity since it has no per-edge fallback to defer to).
    func testCellOwnEdgePaddingIsNotPreMergedWithTheTableDefault() throws {
        let blocks = try read(document: """
        <w:tbl><w:tblPr><w:tblCellMar><w:start w:w="140" w:type="dxa"/></w:tblCellMar></w:tblPr>
        <w:tr><w:tc><w:tcPr><w:tcMar><w:start w:w="200" w:type="dxa"/></w:tcMar></w:tcPr>
        <w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].edgePadding?.left, 10, "the cell's own declared edge, untouched by the table default")
        XCTAssertEqual(format.defaultPadding?.left, 7, "the table's own default, kept as its own separate layer")
    }

    /// Neither the cell nor the table declares a margin — `edgePadding`/`defaultPadding` both stay
    /// `nil`, exactly like `padding` above.
    func testCellWithNeitherOwnNorTableMarginHasNilEdgePadding() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        guard case .table(let rows, _, _, let format) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].edgePadding)
        XCTAssertNil(format.defaultPadding)
    }

    // MARK: P5 — table-STYLE shading/border cascade (w:tblStyle + w:tblStylePr + w:tblLook)

    /// A table style with a whole-table border, a `firstRow` shading and `band1Horz`/`band2Horz`
    /// shadings, referenced by a table whose `w:tblLook` enables `firstRow` + banding: the header
    /// cell gets the `firstRow` shading, body row 1 gets `band1Horz`, body row 2 gets `band2Horz`,
    /// and every cell gets the whole-table border — MUST-have coverage per the sprint brief.
    private let gridTableStyles = """
    <w:styles>
      <w:style w:type="table" w:styleId="TestGrid">
        <w:tblPr><w:tblBorders><w:top w:val="single" w:sz="8" w:color="336699"/></w:tblBorders></w:tblPr>
        <w:tblStylePr w:type="firstRow"><w:tcPr><w:shd w:fill="FFCC00"/></w:tcPr></w:tblStylePr>
        <w:tblStylePr w:type="band1Horz"><w:tcPr><w:shd w:fill="EEEEEE"/></w:tcPr></w:tblStylePr>
        <w:tblStylePr w:type="band2Horz"><w:tcPr><w:shd w:fill="CCCCCC"/></w:tcPr></w:tblStylePr>
      </w:style>
    </w:styles>
    """

    private func gridTable(extraTblPr: String = "") -> String {
        """
        <w:tbl>
          <w:tblPr><w:tblStyle w:val="TestGrid"/>
            <w:tblLook w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="0"/>
            \(extraTblPr)
          </w:tblPr>
          <w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:t>H</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>R1</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>R2</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """
    }

    func testHeaderRowGetsFirstRowStyleShadingAndEveryRowGetsTheWholeTableStyleBorder() throws {
        let blocks = try read(document: gridTable(), styles: gridTableStyles)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].styleShading, rgb("FFCC00"))
        for r in 0..<3 {
            XCTAssertEqual(rows[r][0].styleBorderColor, rgb("336699"), "row \(r)")
            XCTAssertEqual(rows[r][0].styleBorderWidth, 1, "row \(r)")
        }
    }

    func testBodyRowsAlternateBand1AndBand2HorzStyleShading() throws {
        let blocks = try read(document: gridTable(), styles: gridTableStyles)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[1][0].styleShading, rgb("EEEEEE"), "first body row = band1Horz")
        XCTAssertEqual(rows[2][0].styleShading, rgb("CCCCCC"), "second body row = band2Horz")
    }

    /// A cell's OWN direct `w:tcPr/w:shd` still wins over the table-style layer — precedence is
    /// resolved downstream (`TableBlockBuilder`), so the reader must still carry BOTH values
    /// through rather than suppressing the style one because a direct one exists.
    func testCellOwnDirectShadingCoexistsWithButOutrPrioritizesTheStyleLayer() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tblPr><w:tblStyle w:val="TestGrid"/>
            <w:tblLook w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="0"/>
          </w:tblPr>
          <w:tr><w:trPr><w:tblHeader/></w:trPr>
          <w:tc><w:tcPr><w:shd w:fill="FF0000"/></w:tcPr><w:p><w:r><w:t>H</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """, styles: gridTableStyles)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].backgroundColor, rgb("FF0000"))
        XCTAssertEqual(rows[0][0].styleShading, rgb("FFCC00"))
    }

    /// `w:tblLook`'s `noHBand="1"` disables horizontal banding entirely — a body row that would
    /// otherwise get `band1Horz` gets no table-style shading at all.
    func testTblLookNoHBandDisablesHorizontalBandingEntirely() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tblPr><w:tblStyle w:val="TestGrid"/>
            <w:tblLook w:firstRow="0" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="1" w:noVBand="0"/>
          </w:tblPr>
          <w:tr><w:tc><w:p><w:r><w:t>R1</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>R2</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """, styles: gridTableStyles)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].styleShading)
        XCTAssertNil(rows[1][0].styleShading)
    }

    /// `w:tblLook`'s older HEX `@w:val` bitmask form (no boolean attributes at all) — exercises
    /// `parseTblLook`'s hex branch, which every other P5 test leaves untouched. `0x0620` =
    /// `0x0020`(firstRow) | `0x0200`(noHBand) | `0x0400`(noVBand): row 0 still gets the `firstRow`
    /// style shading (proves the firstRow BIT is read), and both body rows get none at all — even
    /// though `TestGrid` defines `band1Horz`/`band2Horz` — because the `noHBand` BIT is SET (proves
    /// the inversion: a set bit means banding is OFF, not on).
    func testTblLookHexValBitmaskFormIsReadTheSameAsTheAttributeForm() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tblPr><w:tblStyle w:val="TestGrid"/>
            <w:tblLook w:val="0620"/>
          </w:tblPr>
          <w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:t>H</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>R1</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>R2</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """, styles: gridTableStyles)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].styleShading, rgb("FFCC00"), "0x0020 firstRow bit must apply")
        XCTAssertNil(rows[1][0].styleShading, "0x0200 noHBand bit must disable banding")
        XCTAssertNil(rows[2][0].styleShading, "0x0200 noHBand bit must disable banding")
    }

    /// A table style with NO content of its own beyond `w:basedOn` inherits its whole-table
    /// shading from the parent style it's based on — the `walkStyleChain` climb this cascade
    /// shares with every other style-chain resolver in this reader.
    func testTableStyleWithNoOwnContentInheritsWholeTableShadingFromItsBasedOnParent() throws {
        let styles = """
        <w:styles>
          <w:style w:type="table" w:styleId="ParentGrid">
            <w:tblPr><w:shd w:fill="00FF00"/></w:tblPr>
          </w:style>
          <w:style w:type="table" w:styleId="ChildGrid">
            <w:basedOn w:val="ParentGrid"/>
          </w:style>
        </w:styles>
        """
        let blocks = try read(document: """
        <w:tbl>
          <w:tblPr><w:tblStyle w:val="ChildGrid"/></w:tblPr>
          <w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """, styles: styles)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[0][0].styleShading, rgb("00FF00"))
    }

    /// A table with no `w:tblStyle` at all — every markdown table, and most docx tables — leaves
    /// every cell's style-layer fields `nil`, byte-identical to before this cascade existed.
    func testTableWithNoTblStyleLeavesEveryCellsStyleLayerFieldsNil() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """, styles: gridTableStyles)
        guard case .table(let rows, _, _, _) = blocks.first else { return XCTFail("expected a table") }
        XCTAssertNil(rows[0][0].styleShading)
        XCTAssertNil(rows[0][0].styleBorderColor)
        XCTAssertNil(rows[0][0].styleBorderWidth)
    }

    // MARK: Invariant 29 — reached through `MarkdownDocument`'s own read path

    /// A theme-coloured run must resolve identically through `DocumentTypes.readOffice` — not
    /// merely through `DocxReader.read` called directly — the same blindness invariant 29 has
    /// already caught twice in this roadmap (`.odt` unreachable end-to-end, a chart placeholder
    /// unreachable end-to-end).
    func testThemeColoredRunIsReachedThroughDocumentTypesReadOfficeNotJustDocxReaderDirectly() throws {
        let document = doc("<w:p><w:r><w:rPr><w:color w:themeColor=\"accent1\"/></w:rPr><w:t>Theme</w:t></w:r></w:p>")
        let zip = buildDocx(document: document, theme: sampleTheme)
        let archive = try ZipArchive(data: zip)
        let blocks = try DocumentTypes.readOffice(archive, extension: "docx").blocks
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Theme", textColor: rgb("4F81BD"))])])
    }

    // MARK: P2 — the spacing/indent/line-height/contextualSpacing cascade (spec areas 5/6/9)

    /// The spec's own worked example (sprint brief): `w:before="240" w:after="120" w:line="360"
    /// w:lineRule="auto"` → `12pt`/`6pt` (twips ÷ 20) and `lineHeightMultiple == 1.5` (`360 / 240`).
    /// Set entirely at `w:docDefaults/w:pPrDefault/w:pPr` — the cascade's absolute floor — with no
    /// style and no direct `w:pPr` at all, proving the floor layer alone is enough to reach a plain
    /// paragraph.
    func testDocDefaultsAloneSuppliesSpacingAndLineHeightWithNoStyleOrDirectPPr() throws {
        let styles = """
        <w:styles>
          <w:docDefaults><w:pPrDefault><w:pPr>
            <w:spacing w:before="240" w:after="120" w:line="360" w:lineRule="auto"/>
          </w:pPr></w:pPrDefault></w:docDefaults>
        </w:styles>
        """
        let blocks = try read(document: "<w:p><w:r><w:t>Plain</w:t></w:r></w:p>", styles: styles)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.spacingBefore, 12)
        XCTAssertEqual(format.spacingAfter, 6)
        XCTAssertEqual(format.lineHeight, .multiple(1.5))
    }

    /// `w:ind/@w:start` set on `Normal` (the root of the chain) must reach a paragraph styled
    /// `Body`, `w:basedOn="Normal"`, that never mentions indentation at all — proving the style
    /// chain layer (not just docDefaults or a paragraph's own direct `pPr`) resolves a property.
    /// `720` twips → `36`pt.
    func testIndentInheritsThroughTheBasedOnChainWhenNeitherTheLeafStyleNorTheParagraphSetsIt() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="Normal"><w:pPr><w:ind w:start="720"/></w:pPr></w:style>
          <w:style w:type="paragraph" w:styleId="Body"><w:basedOn w:val="Normal"/></w:style>
        </w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Body\"/></w:pPr><w:r><w:t>Inherited</w:t></w:r></w:p>",
            styles: styles)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.indentStart, 36)
    }

    /// The paragraph's OWN direct `w:pPr/w:ind` (`360` twips → `18`pt) must win over its style's
    /// `720` twips → `36`pt — direct-wins-highest, the top of the cascade.
    func testParagraphsOwnDirectIndentWinsOverItsStylesIndent() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="Body"><w:pPr><w:ind w:start="720"/></w:pPr></w:style>
        </w:styles>
        """
        let blocks = try read(document: """
        <w:p><w:pPr><w:pStyle w:val="Body"/><w:ind w:start="360"/></w:pPr><w:r><w:t>Direct</w:t></w:r></w:p>
        """, styles: styles)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.indentStart, 18)
    }

    /// A malformed `w:basedOn` CYCLE must not hang the P2 cascade either — `resolvedParagraphFormat`
    /// reuses `walkStyleChain`'s existing cycle guard (proven for outline levels above), and this
    /// is the same guard exercised for the spacing/indent walk specifically. NEITHER style in the
    /// cycle sets any spacing/indent/line-height/contextualSpacing at all, so a walk that failed to
    /// terminate would hang this test rather than merely return a wrong value — the guard is what
    /// lets this test complete (and complete FAST, asserted below) instead of timing out.
    func testBasedOnCycleDoesNotHangTheParagraphFormatCascadeEither() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="A"><w:basedOn w:val="B"/></w:style>
          <w:style w:type="paragraph" w:styleId="B"><w:basedOn w:val="A"/></w:style>
        </w:styles>
        """
        let start = Date()
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"A\"/></w:pPr><w:r><w:t>Cycle</w:t></w:r></w:p>",
            styles: styles)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a cycle must be guarded, not looped forever")
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format, ParagraphFormat())
    }

    /// The SAME cycle, but with a real value sitting on the far side of it (`A`, discoverable by
    /// climbing FROM `B`) — proving the guard only stops a walk that revisits a style, not a walk
    /// that legitimately reaches a style it hasn't seen yet. `100` twips → `5`pt.
    func testBasedOnCycleStillResolvesARealValueReachableBeforeTheRevisit() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="A"><w:basedOn w:val="B"/><w:pPr><w:spacing w:before="100"/></w:pPr></w:style>
          <w:style w:type="paragraph" w:styleId="B"><w:basedOn w:val="A"/></w:style>
        </w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"B\"/></w:pPr><w:r><w:t>Cycle</w:t></w:r></w:p>",
            styles: styles)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.spacingBefore, 5)
    }

    /// Mutation check for twips→points: `÷20` must actually run — `480` twips must become `24`pt,
    /// not `480`pt (forgetting the divisor) and not `10`pt (an off-by-factor error the other way).
    func testSpacingTwipsToPointsConversionIsDivisionByTwentyNotSomeOtherFactor() throws {
        let styles = """
        <w:styles>
          <w:docDefaults><w:pPrDefault><w:pPr><w:spacing w:before="480"/></w:pPr></w:pPrDefault></w:docDefaults>
        </w:styles>
        """
        let blocks = try read(document: "<w:p><w:r><w:t>X</w:t></w:r></w:p>", styles: styles)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.spacingBefore, 24)
    }

    /// `w:lineRule="exact"`/`"atLeast"` are `line/20` points, NOT `line/240` (the `"auto"` ratio) —
    /// a mutation that dropped the `switch` on `@w:lineRule` and always used the `auto` formula
    /// would turn `480` twips-as-exact into a `2.0` ratio instead of `24`pt; this pins the actual
    /// spec-correct unit for both non-`auto` rules in one fixture.
    func testExactAndAtLeastLineRulesAreTwentiethsOfAPointNotThe240thsAutoRatio() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:spacing w:line="480" w:lineRule="exact"/></w:pPr><w:r><w:t>Exact</w:t></w:r></w:p>
        <w:p><w:pPr><w:spacing w:line="300" w:lineRule="atLeast"/></w:pPr><w:r><w:t>Floor</w:t></w:r></w:p>
        """)
        guard case .paragraph(_, _, _, _, let exactFormat) = blocks[0] else { return XCTFail("expected a paragraph") }
        guard case .paragraph(_, _, _, _, let floorFormat) = blocks[1] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(exactFormat.lineHeight, .exact(24))
        XCTAssertEqual(floorFormat.lineHeight, .atLeast(15))
    }

    /// `w:contextualSpacing` is a bare-tag on/off toggle exactly like `w:b`/`w:i` — its mere
    /// presence, with no `@w:val`, must read as ON.
    func testBareContextualSpacingTagWithNoValReadsAsOn() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:contextualSpacing/></w:pPr><w:r><w:t>Tight</w:t></w:r></w:p>
        """)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertTrue(format.contextualSpacing)
    }

    /// `w:contextualSpacing` unset anywhere in the cascade must default to `false` — matching
    /// `ParagraphFormat`'s own default and every pre-P2 paragraph's implicit behaviour.
    func testUnspecifiedContextualSpacingDefaultsToFalse() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Plain</w:t></w:r></w:p>")
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertFalse(format.contextualSpacing)
    }

    /// A paragraph whose cascade resolves EVERY field to `nil` (no docDefaults, no style, no
    /// direct `w:pPr` formatting at all) must produce the exact default `ParagraphFormat()` —
    /// the "unspecified = identical" invariant the sprint brief requires: this is what makes every
    /// pre-P2 fixture in this file (none of which declare `w:spacing`/`w:ind`) still pass unchanged.
    func testFullyUnspecifiedCascadeProducesTheDefaultParagraphFormat() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Untouched</w:t></w:r></w:p>")
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format, ParagraphFormat())
    }

    // MARK: Bold/italic through the STYLE chain, not just the run's own w:rPr

    /// A Word heading's bold lives in its STYLE, essentially never in its runs — measured on four
    /// real documents (TeamBridge: 39 headings, ZERO run-level `w:b`, `heading 1/2/3` all carrying
    /// `<w:b/>`; the OpenAPI guide: 38 and 0). Reading only the run's direct `w:rPr` reported every
    /// one of them as not bold. That was invisible while the builder drew all headings semibold on
    /// its own, and would have un-bolded all of them the moment that app-side default was removed
    /// for the paged model — so the weight has to come from the document, resolved the same way
    /// `resolvedFontSize` resolves size.
    func testBoldDeclaredByTheParagraphStyleReachesTheRunEvenWhenTheRunSaysNothing() throws {
        let styles = """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
            <w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
        </w:styles>
        """
        let document = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
          <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>제목</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let archive = try ZipArchive(data: buildDocx(document: document, styles: styles))
        let blocks = try DocxReader.read(archive).blocks
        guard case let .heading(_, spans, _, _, _, _) = blocks.first else {
            return XCTFail("expected a heading, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(spans.first?.bold, true,
                       "the run declares no w:b — its bold must come from the Heading1 style")
        XCTAssertEqual(spans.first?.fontSize, 12,
                       "and the same chain still supplies the size, as it did before")
    }

    /// The other half, and the reason the style props are three-state: a run that EXPLICITLY turns
    /// bold off must not inherit its style's bold. `isOn` collapses "absent" and "off" into false,
    /// which is right for a run read in isolation and wrong for a chain — the same "silent is not
    /// the same as off" distinction invariant 47 draws for table borders.
    func testRunExplicitlyTurningBoldOffIsNotOverriddenByABoldStyle() throws {
        let styles = """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
            <w:rPr><w:b/></w:rPr></w:style>
        </w:styles>
        """
        let document = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
          <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
            <w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>보통</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let archive = try ZipArchive(data: buildDocx(document: document, styles: styles))
        let blocks = try DocxReader.read(archive).blocks
        guard case let .heading(_, spans, _, _, _, _) = blocks.first else {
            return XCTFail("expected a heading, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(spans.first?.bold, false,
                       "an explicit <w:b w:val=\"0\"/> must stop the climb, not fall through to the style")
    }

    // MARK: P2b — paragraph shading (w:pPr/w:shd) and border (w:pPr/w:pBdr)

    /// `w:pPr/w:shd/@w:fill` reads exactly like `Cell`'s own shading — a direct fixture, no style
    /// involved, is the cascade's simplest layer (paragraph's own `w:pPr` wins outright).
    func testParagraphShadingFillIsReadIntoParagraphFormat() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:shd w:fill="FFCC00"/></w:pPr><w:r><w:t>Shaded</w:t></w:r></w:p>
        """)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.shading, rgb("FFCC00"))
    }

    /// `@w:fill="auto"` is Word's own "no fill" sentinel — reads as unshaded, same as the cell's.
    func testParagraphShadingAutoFillIsUnshaded() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:shd w:fill="auto"/></w:pPr><w:r><w:t>Plain</w:t></w:r></w:p>
        """)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertNil(format.shading)
    }

    /// `w:pPr/w:pBdr`'s first drawn edge (top/left/bottom/right) supplies the paragraph's ONE
    /// colour/width — `@w:sz` is EIGHTHS of a point (`16` → `2`pt), not the half-point unit run/
    /// paragraph-mark sizes use.
    func testParagraphBorderColorAndWidthAreReadFromTheTopEdge() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:pBdr><w:top w:val="single" w:sz="16" w:color="336699"/></w:pBdr></w:pPr><w:r><w:t>Boxed</w:t></w:r></w:p>
        """)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.borderColor, rgb("336699"))
        XCTAssertEqual(format.borderWidth, 2)
    }

    /// `w:top`'s `w:val="none"` must be skipped in favour of the next drawn edge — the same rule
    /// `cellBorder` already applies, exercised here for the paragraph reader's own copy of it.
    func testParagraphBorderNoneEdgeIsSkippedInFavorOfTheNextDrawnEdge() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:pBdr><w:top w:val="none"/><w:left w:val="single" w:sz="8" w:color="112233"/></w:pBdr></w:pPr><w:r><w:t>Boxed</w:t></w:r></w:p>
        """)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.borderColor, rgb("112233"))
        XCTAssertEqual(format.borderWidth, 1)
    }

    /// Shading/border join the SAME `basedOn` cascade the spacing/indent fields already use — a
    /// leaf style with no `w:shd`/`w:pBdr` of its own must still resolve them from its ancestor,
    /// not just from a paragraph's own direct `w:pPr`.
    func testShadingAndBorderResolveThroughTheBasedOnStyleChain() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="Callout">
            <w:pPr>
              <w:shd w:fill="FFEE99"/>
              <w:pBdr><w:top w:val="single" w:sz="8" w:color="998800"/></w:pBdr>
            </w:pPr>
          </w:style>
        </w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Callout\"/></w:pPr><w:r><w:t>Note</w:t></w:r></w:p>", styles: styles)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.shading, rgb("FFEE99"))
        XCTAssertEqual(format.borderColor, rgb("998800"))
        XCTAssertEqual(format.borderWidth, 1)
    }

    /// The paragraph's OWN direct `w:pPr/w:shd` must win over its style's — direct-wins-highest,
    /// same priority order the spacing/indent cascade already proves.
    func testParagraphsOwnDirectShadingWinsOverItsStylesShading() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="Callout"><w:pPr><w:shd w:fill="FFEE99"/></w:pPr></w:style>
        </w:styles>
        """
        let blocks = try read(document: """
        <w:p><w:pPr><w:pStyle w:val="Callout"/><w:shd w:fill="112233"/></w:pPr><w:r><w:t>Note</w:t></w:r></w:p>
        """, styles: styles)
        guard case .paragraph(_, _, _, _, let format) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(format.shading, rgb("112233"))
    }

    // MARK: Headers/footers — w:sectPr's headerReference/footerReference (header-footer-design.md §2)

    func testDefaultHeaderAndFooterResolvedFromSectPrReferences() throws {
        let result = try readResult(
            """
            <w:p><w:r><w:t>Body</w:t></w:r></w:p>
            <w:sectPr>
              <w:headerReference w:type="default" r:id="rId10"/>
              <w:footerReference w:type="default" r:id="rId11"/>
            </w:sectPr>
            """,
            rels: rels([(id: "rId10", target: "header1.xml", external: false),
                        (id: "rId11", target: "footer1.xml", external: false)]),
            extraParts: [
                (path: "word/header1.xml", xml: "<w:hdr><w:p><w:r><w:t>Header text</w:t></w:r></w:p></w:hdr>"),
                (path: "word/footer1.xml", xml: "<w:ftr><w:p><w:r><w:t>Footer text</w:t></w:r></w:p></w:ftr>"),
            ])
        XCTAssertEqual(result.headers, [
            OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [.paragraph(spans: [Span(text: "Header text")])]),
        ])
        XCTAssertEqual(result.footers, [
            OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [.paragraph(spans: [Span(text: "Footer text")])]),
        ])
    }

    /// TRAP (header-footer-design.md §2b): a header/footer part carries its OWN relationship
    /// id-space. The body's `rId1` here resolves to something else entirely (a customizations
    /// part), and the header's `rId1` — same id, different table — resolves to its own image.
    /// Getting this wrong (resolving the header's `r:embed="rId1"` against the BODY's table)
    /// would silently pick up the wrong target or none.
    func testHeaderPartResolvesImagesThroughItsOwnRelationshipsNotTheBodys() throws {
        let bodyRels = rels([
            (id: "rId1", target: "customizations.xml", external: false),
            (id: "rId10", target: "header1.xml", external: false),
        ])
        let headerRels = rels([(id: "rId1", target: "media/headerimg.png", external: false)])
        let result = try readResult(
            """
            <w:p><w:r><w:t>Body</w:t></w:r></w:p>
            <w:sectPr><w:headerReference w:type="default" r:id="rId10"/></w:sectPr>
            """,
            rels: bodyRels,
            extraParts: [
                (path: "word/header1.xml",
                 xml: "<w:hdr><w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId1"))</w:r></w:p></w:hdr>"),
                (path: "word/_rels/header1.xml.rels", xml: headerRels),
            ])
        XCTAssertEqual(result.headers.count, 1)
        XCTAssertEqual(result.headers[0].appliesTo, .defaultPages)
        XCTAssertEqual(result.headers[0].blocks, [.image(id: "word/media/headerimg.png", size: CGSize(width: 72, height: 72))])
    }

    /// header-footer-design.md §2d — the counter-intuitive rule: `w:titlePg` set, a `first`-type
    /// FOOTER reference that resolves to real (if blank) content, but NO `first`-type HEADER
    /// reference at all. Per OOXML this does not mean "use the default header on page one" — it
    /// means a BLANK header for the first page, represented here as an explicit `.firstPage` entry
    /// with empty blocks, never as `.defaultPages`' content reused. The footer, which DOES have an
    /// actual `first`-type reference, reads that part's own (empty) content instead.
    func testTitlePgWithNoFirstHeaderReferenceSynthesizesABlankFirstPageEntryNotTheDefault() throws {
        let result = try readResult(
            """
            <w:p><w:r><w:t>Body</w:t></w:r></w:p>
            <w:sectPr>
              <w:headerReference w:type="default" r:id="rId10"/>
              <w:footerReference w:type="default" r:id="rId11"/>
              <w:footerReference w:type="first" r:id="rId12"/>
              <w:titlePg/>
            </w:sectPr>
            """,
            rels: rels([(id: "rId10", target: "header1.xml", external: false),
                        (id: "rId11", target: "footer1.xml", external: false),
                        (id: "rId12", target: "footer2.xml", external: false)]),
            extraParts: [
                (path: "word/header1.xml", xml: "<w:hdr><w:p><w:r><w:t>Running header</w:t></w:r></w:p></w:hdr>"),
                (path: "word/footer1.xml", xml: "<w:ftr><w:p><w:r><w:t>Running footer</w:t></w:r></w:p></w:ftr>"),
                (path: "word/footer2.xml", xml: "<w:ftr><w:p/><w:p/></w:ftr>"),
            ])
        // The running header/footer are present as `.defaultPages`, and the first page gets its OWN
        // entry — never `.defaultPages`' text reused under a `.firstPage` label.
        XCTAssertEqual(result.headers.count, 2, "expected .defaultPages plus a synthesized blank .firstPage")
        XCTAssertEqual(result.headers[0], OfficeHeaderFooter(
            appliesTo: .defaultPages, blocks: [.paragraph(spans: [Span(text: "Running header")])]))
        XCTAssertEqual(result.headers[1].appliesTo, .firstPage)
        XCTAssertEqual(result.headers[1].blocks, [], "no headerReference type=\"first\" + titlePg = a BLANK header, not the default's text")

        // The footer DOES have a real first-type reference (footer2.xml — two empty paragraphs, the
        // reference document's own shape), so its `.firstPage` entry reads THAT part's content.
        XCTAssertEqual(result.footers.count, 2)
        XCTAssertEqual(result.footers[0], OfficeHeaderFooter(
            appliesTo: .defaultPages, blocks: [.paragraph(spans: [Span(text: "Running footer")])]))
        XCTAssertEqual(result.footers[1].appliesTo, .firstPage)
        XCTAssertEqual(result.footers[1].blocks.count, 2)
        for block in result.footers[1].blocks {
            guard case .paragraph(let spans, _, _, _, _) = block else { return XCTFail("expected a paragraph") }
            XCTAssertTrue(spans.isEmpty)
        }
    }

    /// No `w:titlePg` at all, and no `first`-type reference either — the ordinary case, and the one
    /// every ACTUAL real single-section document without a cover page has. No `.firstPage` entry is
    /// synthesized; the section never differentiated a first page, so there is nothing to represent.
    func testNoTitlePgAndNoFirstReferenceProducesNoFirstPageEntry() throws {
        let result = try readResult(
            """
            <w:p><w:r><w:t>Body</w:t></w:r></w:p>
            <w:sectPr><w:headerReference w:type="default" r:id="rId10"/></w:sectPr>
            """,
            rels: rels([(id: "rId10", target: "header1.xml", external: false)]),
            extraParts: [(path: "word/header1.xml", xml: "<w:hdr><w:p><w:r><w:t>H</w:t></w:r></w:p></w:hdr>")])
        XCTAssertEqual(result.headers.count, 1)
        XCTAssertEqual(result.headers[0].appliesTo, .defaultPages)
    }

    /// A document with NO header/footer references at all — invariant 37's "unspecified → nothing"
    /// contract, restated for this feature: `headers`/`footers` are simply empty, exactly as they
    /// default for every document this reader parsed before this feature existed.
    func testDocumentWithNoHeaderFooterReferencesProducesEmptyArrays() throws {
        let result = try readResult("<w:p><w:r><w:t>Body</w:t></w:r></w:p><w:sectPr/>")
        XCTAssertEqual(result.headers, [])
        XCTAssertEqual(result.footers, [])
    }

    /// An even-page header/footer — the third `w:type`, otherwise untested above.
    func testEvenPageHeaderAndFooterResolvedFromSectPrReferences() throws {
        let result = try readResult(
            """
            <w:p><w:r><w:t>Body</w:t></w:r></w:p>
            <w:sectPr>
              <w:headerReference w:type="even" r:id="rId10"/>
              <w:footerReference w:type="even" r:id="rId11"/>
            </w:sectPr>
            """,
            rels: rels([(id: "rId10", target: "header1.xml", external: false),
                        (id: "rId11", target: "footer1.xml", external: false)]),
            extraParts: [
                (path: "word/header1.xml", xml: "<w:hdr><w:p><w:r><w:t>Even header</w:t></w:r></w:p></w:hdr>"),
                (path: "word/footer1.xml", xml: "<w:ftr><w:p><w:r><w:t>Even footer</w:t></w:r></w:p></w:ftr>"),
            ])
        XCTAssertEqual(result.headers.map(\.appliesTo), [.evenPages])
        XCTAssertEqual(result.footers.map(\.appliesTo), [.evenPages])
    }

    // MARK: Page-number fields — w:fldSimple and w:fldChar/w:instrText (header-footer-design.md §5)

    /// The `fldChar`/`instrText`/`separate`/`end` encoding, with a real cached result run in
    /// between — footer1.xml's own shape ("- 2 -"). The marked span must NOT merge with the plain
    /// text around it (a page-number marker's exact boundary has to survive for later substitution).
    func testPageFieldViaFldCharMarksOnlyTheCachedResultSpan() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:t xml:space="preserve">- </w:t></w:r>
          <w:r><w:fldChar w:fldCharType="begin"/></w:r>
          <w:r><w:instrText>PAGE   \\* MERGEFORMAT</w:instrText></w:r>
          <w:r><w:fldChar w:fldCharType="separate"/></w:r>
          <w:r><w:t>2</w:t></w:r>
          <w:r><w:fldChar w:fldCharType="end"/></w:r>
          <w:r><w:t xml:space="preserve"> -</w:t></w:r>
        </w:p>
        """)
        guard case .paragraph(let spans, _, _, _, _) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(spans.map(\.text), ["- ", "2", " -"], "the field marker must prevent merging with its neighbours")
        XCTAssertEqual(spans.map(\.pageNumberField), [nil, .page, nil])
    }

    /// `NUMPAGES` — the other field name this reader recognizes.
    func testNumPagesFieldViaFldCharIsMarked() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:fldChar w:fldCharType="begin"/></w:r>
          <w:r><w:instrText xml:space="preserve"> NUMPAGES  \\* MERGEFORMAT </w:instrText></w:r>
          <w:r><w:fldChar w:fldCharType="separate"/></w:r>
          <w:r><w:t>5</w:t></w:r>
          <w:r><w:fldChar w:fldCharType="end"/></w:r>
        </w:p>
        """)
        guard case .paragraph(let spans, _, _, _, _) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(spans, [Span(text: "5", pageNumberField: .numPages)])
    }

    /// TRAP (header-footer-design.md §5): `STYLEREF` in this reader's own reference document has NO
    /// `separate` and no result run at all — straight from `begin`+`instrText` to `end`. This must
    /// not crash, and must produce no text and no marker (nothing to mark — the field never opened a
    /// result region).
    func testStyleRefFieldWithNoSeparateAndNoResultProducesNoTextAndNoMarker() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:fldChar w:fldCharType="begin"/></w:r>
          <w:r><w:instrText xml:space="preserve"> STYLEREF  "Project Name"  \\* MERGEFORMAT </w:instrText></w:r>
          <w:r><w:fldChar w:fldCharType="end"/></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [])])
    }

    /// The OTHER field encoding: `w:fldSimple`'s own `w:instr` attribute wraps an ordinary cached-
    /// result run, no `begin`/`separate`/`end` pair. `PAGE` here must be marked exactly like the
    /// compound-field form above.
    func testPageFieldViaFldSimpleIsMarked() throws {
        let blocks = try read(document: """
        <w:p><w:fldSimple w:instr=" PAGE  \\* MERGEFORMAT "><w:r><w:t>3</w:t></w:r></w:fldSimple></w:p>
        """)
        guard case .paragraph(let spans, _, _, _, _) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(spans, [Span(text: "3", pageNumberField: .page)])
    }

    /// `STYLEREF` via `w:fldSimple` (header1.xml's own "Documment Name" field) — cached text
    /// survives, exactly as it always did, but with NO marker (header-footer-design.md §7: no live
    /// value is planned for `STYLEREF`).
    func testStyleRefFieldViaFldSimpleProducesNoMarker() throws {
        let blocks = try read(document: """
        <w:p><w:fldSimple w:instr=" STYLEREF  &quot;Documment Name&quot;  \\* MERGEFORMAT "><w:r><w:t>OpenAPI Guide</w:t></w:r></w:fldSimple></w:p>
        """)
        guard case .paragraph(let spans, _, _, _, _) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(spans, [Span(text: "OpenAPI Guide")])
    }
}
