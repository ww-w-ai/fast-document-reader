import XCTest
import AppKit
@testable import FastDocReader

/// The five docx density defects invariant 163 charges a 20-25% page-count gap to, each through
/// the real `DocumentTypes.readOffice` dispatch or the real builder — a page break carried as a
/// line break, a paragraph's own `pageBreakBefore`/`keepNext` never read, Word's built-in cell
/// margin falling to the renderer's 7pt, a cell's paragraph spacing trimmed on paper, and a
/// declared 맑은 고딕 laid out at its substitute's 1.2× line instead of Word's 1.733×.
final class DocxDensityTests: XCTestCase {

    // MARK: A real (stored-only) ZIP, built in memory — same shape as `DocxReaderTests`'s builder

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
            body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            body += le32(UInt32(content.count)) + le32(UInt32(content.count))
            body += le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var central = [UInt8]()
        for p in prepared {
            central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(UInt32(p.content.count)) + le32(UInt32(p.content.count))
            central += le16(UInt16(p.nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(UInt32(p.localOffset)) + p.nameBytes
        }
        let centralOffset = body.count
        var archive = body + central
        archive += le32(0x0605_4b50) + le16(0) + le16(0)
        archive += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        archive += le32(UInt32(central.count)) + le32(UInt32(centralOffset)) + le16(0)
        return Data(archive)
    }

    private func docx(_ body: String) -> Data {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document><w:body>\(body)</w:body></w:document>"
        return buildZip([(name: "word/document.xml", content: Data(xml.utf8))])
    }

    private func read(_ body: String) throws -> OfficeReadResult {
        try DocumentTypes.readOffice(try ZipArchive(data: docx(body)), extension: "docx")
    }

    private func paragraph(_ block: OfficeBlock) -> (text: String, format: ParagraphFormat)? {
        switch block {
        case let .paragraph(spans, _, _, _, format), let .heading(_, spans, _, _, _, format):
            return (spans.map(\.text).joined(), format)
        default:
            return nil
        }
    }

    private func p(_ text: String) -> String { "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>" }

    // MARK: page breaks

    func testAPageBreakRunSplitsItsParagraphAndTheRemainderOpensThePage() throws {
        let body = p("앞 문단") +
            "<w:p><w:r><w:t>앞</w:t></w:r><w:r><w:br w:type=\"page\"/></w:r><w:r><w:t>뒤</w:t></w:r></w:p>"
        let result = try read(body)
        let paras = result.blocks.compactMap(paragraph)
        XCTAssertEqual(paras.map(\.text), ["앞 문단", "앞", "뒤"], "the break splits the paragraph in two")
        guard paras.count == 3 else { return }
        XCTAssertFalse(paras.contains { $0.text.contains("\u{0C}") }, "the form feed never reaches a span")
        XCTAssertEqual(paras[2].format.pageBreakBefore, true)
        XCTAssertNil(paras[1].format.pageBreakBefore)
        XCTAssertEqual(result.pageBreakBlocks, [2], "the remainder is the block a page opens on")
    }

    func testAParagraphHoldingOnlyAPageBreakOpensThePageItself() throws {
        // The shape 58 of 58 breaks in a real 60-page report take: an otherwise empty paragraph
        // before the next heading. Word starts the new page with that paragraph's own empty line.
        let body = p("앞 문단") + "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" + p("다음 장")
        let result = try read(body)
        let paras = result.blocks.compactMap(paragraph)
        XCTAssertEqual(paras.map(\.text), ["앞 문단", "", "다음 장"])
        guard paras.count == 3 else { return }
        XCTAssertEqual(paras[1].format.pageBreakBefore, true)
        XCTAssertEqual(result.pageBreakBlocks, [1])
    }

    func testAParagraphWithoutABreakComesBackAsItWas() throws {
        let result = try read(p("한 문단") + "<w:p><w:r><w:t>줄</w:t><w:br/><w:t>바꿈</w:t></w:r></w:p>")
        let paras = result.blocks.compactMap(paragraph)
        XCTAssertEqual(paras.map(\.text), ["한 문단", "줄\n바꿈"], "a plain line break stays inside its paragraph")
        XCTAssertEqual(result.pageBreakBlocks, [])
    }

    func testPageBreakBeforeAndKeepNextAreReadFromTheParagraph() throws {
        let body = p("앞 문단") +
            "<w:p><w:pPr><w:pageBreakBefore/><w:keepNext w:val=\"0\"/></w:pPr><w:r><w:t>새 장</w:t></w:r></w:p>" +
            "<w:p><w:pPr><w:keepNext/></w:pPr><w:r><w:t>제목</w:t></w:r></w:p>" + p("본문")
        let result = try read(body)
        let paras = result.blocks.compactMap(paragraph)
        guard paras.count == 4 else { return XCTFail("expected four paragraphs, got \(paras.map(\.text))") }
        XCTAssertEqual(paras[1].format.pageBreakBefore, true)
        XCTAssertEqual(paras[1].format.keepWithNext, false, "an explicit off is off, not unsaid")
        XCTAssertEqual(paras[2].format.keepWithNext, true)
        XCTAssertNil(paras[3].format.keepWithNext)
        XCTAssertEqual(result.pageBreakBlocks, [1])
        XCTAssertEqual(result.keepWithNextBlocks, [2])
    }

    // MARK: cells

    private func table(_ tblPr: String, cells: [String]) -> String {
        "<w:tbl>\(tblPr)<w:tr>" + cells.map { "<w:tc>\($0)</w:tc>" }.joined() + "</w:tr></w:tbl>"
    }

    private func firstTable(_ result: OfficeReadResult) throws -> (rows: [[Cell]], format: TableFormat) {
        for block in result.blocks {
            if case let .table(rows, _, _, format) = block { return (rows, format) }
        }
        throw XCTSkip("no table came back")
    }

    func testWordsOwnCellMarginSitsBeneathWhateverTheTableDeclares() throws {
        let bare = try firstTable(try read(table("", cells: [p("값")])))
        XCTAssertEqual(bare.format.defaultPadding, EdgePadding(top: 0, left: 5.4, bottom: 0, right: 5.4),
                       "0 above and below, 108 twips at the sides — never the renderer's 7pt")
        let declared = try firstTable(try read(table(
            "<w:tblPr><w:tblCellMar><w:top w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>", cells: [p("값")])))
        XCTAssertEqual(declared.format.defaultPadding, EdgePadding(top: 5, left: 5.4, bottom: 0, right: 5.4),
                       "a declared edge wins; the others still fall to Word's own")
    }

    func testAnEmptyParagraphBesideContentKeepsItsLineAndABlankCellStaysBlockless() throws {
        let t = try firstTable(try read(table("", cells: ["<w:p/>" + p("라벨") + "<w:p/>", "<w:p/>", "<w:p/><w:p/>"])))
        XCTAssertEqual(t.rows[0][0].blocks.count, 3, "the blank lines above and below the label are lines Word draws")
        XCTAssertEqual(t.rows[0][1].blocks.count, 0, "the placeholder <w:p/> of an empty cell is not a line")
        XCTAssertEqual(t.rows[0][2].blocks.count, 0, "nor are two of them")
    }

    /// An empty paragraph carries its MARK's size and face as a text-less run (invariant 170); a
    /// cell of nothing but such paragraphs is still blockless.
    func testAnEmptyParagraphCarriesItsParagraphMarksSizeAndFace() throws {
        let mark = "<w:p><w:pPr><w:rPr><w:rFonts w:eastAsia=\"맑은 고딕\"/><w:sz w:val=\"18\"/></w:rPr></w:pPr></w:p>"
        let t = try firstTable(try read(table("", cells: [p("라벨") + mark, mark + mark])))
        XCTAssertEqual(t.rows[0][0].blocks.count, 2)
        guard case let .paragraph(spans, _, _, _, _) = t.rows[0][0].blocks[1] else { return XCTFail("a paragraph") }
        XCTAssertEqual(spans.map(\.text), [""], "one text-less run")
        XCTAssertEqual(spans.first?.fontSize, 9)
        XCTAssertEqual(spans.first?.fontName, "맑은 고딕")
        XCTAssertEqual(t.rows[0][1].blocks.count, 0, "marks alone do not make a cell non-blank")
    }

    func testADeclaredRowHeightReachesEveryCellOfTheRow() throws {
        let t = try firstTable(try read(
            "<w:tbl><w:tr><w:trPr><w:trHeight w:val=\"340\"/></w:trPr><w:tc>" + p("가") + "</w:tc><w:tc>" + p("나") + "</w:tc></w:tr>"
            + "<w:tr><w:tc>" + p("다") + "</w:tc></w:tr></w:tbl>"))
        XCTAssertEqual(t.rows[0].map(\.minimumRowHeight), [17, 17], "340 twips is 17pt, on both cells")
        XCTAssertEqual(t.rows[1].first?.minimumRowHeight, nil, "a row that said nothing stays nil")
        XCTAssertEqual(t.rows[0].map(\.declaredHeight), [nil, nil], "a floor is not a drawn height")
    }

    /// A one-line cell in a paged row is held to the row height the document declared; a cell that
    /// wraps, an exact line height, and the screen are left alone (invariant 166).
    func testAOneLineCellIsHeldToTheDeclaredRowHeightOnPaperOnly() throws {
        func cellOf(_ text: String, declared: CGFloat?, exact: CGFloat? = nil) -> Cell {
            var f = ParagraphFormat(); if let exact { f.lineHeight = .exact(exact) }
            var c = Cell(blocks: [.paragraph(spans: [Span(text: text, fontSize: 9)], format: f)])
            c.minimumRowHeight = declared; c.edgePadding = EdgePadding(top: 0, left: 0, bottom: 0, right: 0)
            return c
        }
        let long = String(repeating: "긴 글이 여러 줄로 감깁니다 ", count: 8)
        let rows = [[cellOf("한 줄", declared: 30), cellOf(long, declared: 30)],
                    [cellOf("고정", declared: 30, exact: 12), cellOf("말 없음", declared: nil)]]
        let blocks: [OfficeBlock] = [.table(rows: rows, headerRows: 0)]
        let paged = OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: 16,
                                            pageContentWidth: 300, tableWidth: 300, pageContentHeight: 700)
        XCTAssertEqual(try style(of: paged, at: "한 줄").minimumLineHeight, 30, accuracy: 0.01, "held to the row")
        XCTAssertLessThan(try style(of: paged, at: "긴 글이").minimumLineHeight, 20, "a wrapping cell is left alone")
        XCTAssertEqual(try style(of: paged, at: "고정").maximumLineHeight, 12, accuracy: 0.01, "an exact height is the document's own")
        XCTAssertLessThan(try style(of: paged, at: "말 없음").minimumLineHeight, 20)
        let screen = OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: 16, tableWidth: 300)
        XCTAssertLessThan(try style(of: screen, at: "한 줄").minimumLineHeight, 30, "the screen keeps its reading rhythm")
    }

    // MARK: the builder

    private let theme = RenderTheme.current(size: 16)

    private func style(of out: NSAttributedString, at text: String) throws -> NSParagraphStyle {
        let r = (out.string as NSString).range(of: text)
        XCTAssertNotEqual(r.location, NSNotFound)
        return try XCTUnwrap(out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    func testAPagedCellKeepsItsParagraphsOwnSpacingAndAScreenCellTrimsIt() throws {
        var f = ParagraphFormat()
        f.spacingBefore = 6; f.spacingAfter = 8
        let cell = Cell(blocks: [.paragraph(spans: [Span(text: "첫째")], format: f),
                                 .paragraph(spans: [Span(text: "둘째")], format: f)])
        let blocks: [OfficeBlock] = [.table(rows: [[cell]], headerRows: 0)]
        let paged = OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: 16,
                                            pageContentWidth: 500, tableWidth: 300, pageContentHeight: 700)
        XCTAssertEqual(try style(of: paged, at: "첫째").paragraphSpacingBefore, 6, accuracy: 0.01,
                       "Word lays the first paragraph's space-before inside the row")
        XCTAssertEqual(try style(of: paged, at: "둘째").paragraphSpacing, 8, accuracy: 0.01,
                       "and the last paragraph's space-after")
        let screen = OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: 16, tableWidth: 300)
        XCTAssertEqual(try style(of: screen, at: "첫째").paragraphSpacingBefore, 0, accuracy: 0.01)
        XCTAssertEqual(try style(of: screen, at: "둘째").paragraphSpacing, 0, accuracy: 0.01)
    }

    /// `<w:br/>` is a line break INSIDE its paragraph: the line after it owes no paragraph spacing.
    /// Carried as `\n` it was a TextKit paragraph, and the document's own 4pt space-after landed
    /// under every stanza line of a 137-page transcript (invariant 165).
    func testAForcedLineBreakStaysInsideItsParagraphAndOwesNoParagraphSpacing() throws {
        var f = ParagraphFormat(); f.spacingAfter = 4
        let blocks: [OfficeBlock] = [.paragraph(spans: [Span(text: "첫 줄\n둘째 줄", fontSize: 12)], format: f),
                                     .paragraph(spans: [Span(text: "다음 문단", fontSize: 12)], format: f)]
        let out = OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: 16, pageContentWidth: 500)
        XCTAssertTrue(out.string.contains("\u{2028}"), "the break is a line separator")
        XCTAssertEqual(out.string.components(separatedBy: "\n").count - 1, 2, "two paragraphs, two terminators")
        let storage = NSTextStorage(attributedString: out)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc); lm.ensureLayout(for: tc)
        var rects: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, _, _ in rects.append(rect) }
        guard rects.count >= 3 else { return XCTFail("expected three lines, got \(rects)") }
        // TextKit folds a paragraph's space-after into its LAST line's fragment rect, so the line
        // before the break must be 4pt shorter than the paragraph's last line, and the first
        // paragraph's last line as tall as the second's (both carry the 4pt).
        XCTAssertEqual(rects[1].height - rects[0].height, 4, accuracy: 0.01,
                       "the line before the break owes no space-after; heights \(rects.map(\.height))")
        XCTAssertEqual(rects[1].height, rects[2].height, accuracy: 0.01)
    }

    func testADeclaredMalgunGothicLineIsFlooredAtWordsRatioWhateverFaceDrawsIt() throws {
        var single = ParagraphFormat()
        var multiple = ParagraphFormat(); multiple.lineHeight = .multiple(1.15)
        var exact = ParagraphFormat(); exact.lineHeight = .exact(12)
        let blocks: [OfficeBlock] = [
            .paragraph(spans: [Span(text: "맑은 고딕 9pt", fontSize: 9, fontName: "맑은 고딕")], format: single),
            .paragraph(spans: [Span(text: "배수 1.15", fontSize: 9, fontName: "Malgun Gothic")], format: multiple),
            .paragraph(spans: [Span(text: "고정 12", fontSize: 9, fontName: "맑은 고딕")], format: exact),
            .paragraph(spans: [Span(text: "다른 글꼴", fontSize: 9, fontName: "Helvetica")], format: single),
        ]
        // PAGED: on paper every line is the document's own size, not the theme's reading floor.
        let out = OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: 16, pageContentWidth: 500)
        XCTAssertEqual(try style(of: out, at: "맑은 고딕 9pt").minimumLineHeight, 15.6, accuracy: 0.02,
                       "9 × 1.733, Word's own 맑은 고딕 line — not Apple SD Gothic Neo's 10.8")
        XCTAssertEqual(try style(of: out, at: "배수 1.15").minimumLineHeight, 15.6 * 1.15, accuracy: 0.02,
                       "the paragraph's own multiple rides on top of the face's line")
        let fixed = try style(of: out, at: "고정 12")
        XCTAssertEqual(fixed.maximumLineHeight, 12, accuracy: 0.01, "an exact height is the document's own")
        XCTAssertLessThanOrEqual(fixed.minimumLineHeight, 12)
        XCTAssertLessThan(try style(of: out, at: "다른 글꼴").minimumLineHeight, 15,
                          "a face Word lays out at its own metrics is untouched")
    }
}
