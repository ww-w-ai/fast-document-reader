import XCTest
import AppKit
@testable import FastDocReader

/// The two ways a cell's own geometry is the DOCUMENT's answer rather than the content's:
/// a label that must not be broken, and a row that holds no text at all.
///
/// Both were found by putting this reader's page beside the source renderer's and looking, after
/// measurement alone had pointed at the wrong cause twice — the numbers fit two different stories
/// and only the picture separated them.
final class CellBandAndLabelTests: XCTestCase {

    // MARK: - A label that cannot be broken

    private func label(_ text: String, size: CGFloat = 25, headIndent: CGFloat = 5)
        -> TableBlockBuilder.CellContent {
        let ps = NSMutableParagraphStyle()
        ps.headIndent = headIndent
        ps.firstLineHeadIndent = headIndent
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .paragraphStyle: ps,
        ])
        return TableBlockBuilder.CellContent(content: s)
    }

    private func width(of cell: TableBlockBuilder.CellContent) -> CGFloat {
        cell.content.size().width.rounded(.up)
    }

    func testATokenThatFitsAsksForNothing() {
        let cell = label("44.")
        let roomy = width(of: cell) + 20
        XCTAssertNil(TableBlockBuilder.oneTokenPaddingRelief(
            content: cell.content, contentWidth: roomy, rightPadding: 5))
    }

    func testATokenThatMissesTakesExactlyWhatItMissesBy() {
        let cell = label("44.")
        // Two points short of fitting, once the head indent is taken off.
        let contentWidth = width(of: cell) + 5 - 2
        let relieved = TableBlockBuilder.oneTokenPaddingRelief(
            content: cell.content, contentWidth: contentWidth, rightPadding: 5)
        XCTAssertEqual(relieved, 3, "5pt of margin less the 2pt the token misses by")
    }

    func testATokenWiderThanTheWholeMarginTakesAllOfIt() {
        let cell = label("사이시옷적용오류", size: 10)
        let relieved = TableBlockBuilder.oneTokenPaddingRelief(
            content: cell.content, contentWidth: 12, rightPadding: 5)
        XCTAssertEqual(relieved, 0, "surrendered entirely — it still wraps, into fewer lines")
    }

    func testTextWithASpaceIsLeftAlone() {
        // A break opportunity of the document's own is not ours to undo.
        let cell = label("가 나", size: 25)
        XCTAssertNil(TableBlockBuilder.oneTokenPaddingRelief(
            content: cell.content, contentWidth: 4, rightPadding: 5))
    }

    func testAMarginOfZeroHasNothingToGive() {
        let cell = label("44.")
        XCTAssertNil(TableBlockBuilder.oneTokenPaddingRelief(
            content: cell.content, contentWidth: 1, rightPadding: 0))
    }

    // MARK: - A row the document sized itself

    private func empty(declaredHeight: CGFloat?) -> TableBlockBuilder.CellContent {
        var c = TableBlockBuilder.CellContent(content: NSAttributedString(string: "\n"))
        c.declaredHeight = declaredHeight
        return c
    }

    func testAThinBandGivesUpItsPaddingToKeepItsDeclaredHeight() {
        let band = TableBlockBuilder.decorativeBand(
            cell: empty(declaredHeight: 2.82), paged: true, paddingTop: 5, paddingBottom: 5)
        let unwrapped = try? XCTUnwrap(band)
        XCTAssertEqual(unwrapped?.top, 0)
        XCTAssertEqual(unwrapped?.bottom, 0)
        XCTAssertEqual(unwrapped?.line ?? 0, 2.82, accuracy: 0.001)
    }

    func testABandTallerThanItsPaddingKeepsThePaddingItAskedFor() {
        let band = TableBlockBuilder.decorativeBand(
            cell: empty(declaredHeight: 40), paged: true, paddingTop: 5, paddingBottom: 5)
        XCTAssertEqual(band?.top, 5)
        XCTAssertEqual(band?.bottom, 5)
        XCTAssertEqual(band?.line, 30)
    }

    func testAnAsymmetricPaddingShrinksInProportion() {
        // room = 6 - 1 = 5, asked = 9 → 5·6/9 = 3.33 → 3, 5·3/9 = 1.66 → 1.
        let band = TableBlockBuilder.decorativeBand(
            cell: empty(declaredHeight: 6), paged: true, paddingTop: 6, paddingBottom: 3)
        XCTAssertEqual(band?.top, 3)
        XCTAssertEqual(band?.bottom, 1)
        XCTAssertEqual(band?.line, 2)
    }

    func testACellWithTextMeasuresItselfAsBefore() {
        var c = TableBlockBuilder.CellContent(content: NSAttributedString(string: "값\n"))
        c.declaredHeight = 2.82
        XCTAssertNil(TableBlockBuilder.decorativeBand(
            cell: c, paged: true, paddingTop: 5, paddingBottom: 5))
    }

    func testAnEmptyCellBesideTextIsNotTreatedAsAnEmptyRowBand() {
        XCTAssertNil(TableBlockBuilder.decorativeBand(
            cell: empty(declaredHeight: 40), paged: true, rowIsEmpty: false,
            paddingTop: 5, paddingBottom: 5))
    }

    func testACellTheDocumentSaidNothingAboutMeasuresItselfAsBefore() {
        XCTAssertNil(TableBlockBuilder.decorativeBand(
            cell: empty(declaredHeight: nil), paged: true, paddingTop: 5, paddingBottom: 5))
    }

    func testTheNonPagedModelIsUntouched() {
        XCTAssertNil(TableBlockBuilder.decorativeBand(
            cell: empty(declaredHeight: 2.82), paged: false, paddingTop: 5, paddingBottom: 5))
    }
}

/// An indent pair a shape's text box brought with it from a WIDER frame, landing in a narrow cell.
///
/// Found by looking, again: the 편람's 정책연구 flow chart (sheet 267) drew every label one
/// character per line — 「차/별/성/검/토」 straight down the page — while the reference renderer
/// fits two characters to a line. The line dump named the cause without ambiguity: a cell 181.0pt
/// wide holding paragraphs indented `head 0.0 / tail -330.1`, so the width left to lay a line in
/// was negative and TextKit took what it could get.
final class CellIndentThatCannotFitTests: XCTestCase {

    private func cell(head: CGFloat, tail: CGFloat) -> TableBlockBuilder.CellContent {
        let ps = NSMutableParagraphStyle()
        ps.headIndent = head
        ps.firstLineHeadIndent = head
        ps.tailIndent = tail
        return TableBlockBuilder.CellContent(content: NSAttributedString(
            string: "차별성검토", attributes: [.font: NSFont.systemFont(ofSize: 9.5),
                                            .paragraphStyle: ps]))
    }

    private func styles(_ built: NSAttributedString) -> [NSParagraphStyle] {
        var out: [NSParagraphStyle] = []
        built.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: built.length)) { v, _, _ in
            if let ps = v as? NSParagraphStyle { out.append(ps) }
        }
        return out
    }

    func testAnIndentPairThatLeavesNoWidthIsDropped() {
        // The measured shape: a right indent larger than the whole cell.
        let built = TableBlockBuilder.build(rows: [[cell(head: 0, tail: -330.1)]],
                                            headerRows: 0, theme: RenderTheme.current(size: 11),
                                            width: 181)
        for ps in styles(built) {
            XCTAssertEqual(ps.tailIndent, 0, "a tail indent wider than the cell is not this cell's")
            XCTAssertEqual(ps.headIndent, 0)
        }
    }

    func testTheOtherMeasuredPairIsDroppedToo() {
        let built = TableBlockBuilder.build(rows: [[cell(head: 78.7, tail: -267.4)]],
                                            headerRows: 0, theme: RenderTheme.current(size: 11),
                                            width: 181)
        for ps in styles(built) {
            XCTAssertEqual(ps.headIndent, 0)
            XCTAssertEqual(ps.firstLineHeadIndent, 0)
            XCTAssertEqual(ps.tailIndent, 0)
        }
    }

    func testAnIndentThatStillLeavesRoomIsLeftAlone() {
        // Tight is allowed — a document may indent a cell hard, and only the IMPOSSIBLE pair is
        // this rule's business. Without this arm the fix could clamp every indent and still pass.
        let built = TableBlockBuilder.build(rows: [[cell(head: 20, tail: -20)]],
                                            headerRows: 0, theme: RenderTheme.current(size: 11),
                                            width: 181)
        XCTAssertTrue(styles(built).contains { $0.headIndent == 20 && $0.tailIndent == -20 },
                      "an indent the cell can honour must survive untouched")
    }
}
