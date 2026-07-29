import XCTest
@testable import FastDocReader

/// The paged-model typography rules `OfficeTextBuilder` applies when a document declared a page body
/// width — and, paired with every one of them, the assertion that a document which declared NO page
/// width is untouched. That pairing is the point: "where the document stated something, the document
/// wins" is only half the contract; the other half is that the window-filling model these rules
/// replace must stay byte-identical for markdown, plain text, and an office document with no page.
///
/// A paged build is exactly what `MarkdownDocument.render` produces for one: the theme is built at
/// the DOCUMENT's own default body size, so `OfficeTextBuilder.fontSizeScale` is 1 (see `build`'s own
/// doc), and `pageContentWidth` is the column. `unpaged(...)` mirrors the old model — the reader's
/// 16pt base over an 11pt document, no page width.
final class PagedBuilderTypographyTests: XCTestCase {
    /// A real Korean report's shape: 11pt default body, A4 body column.
    private let documentDefault: CGFloat = 11
    private let page: CGFloat = 451.3

    private var pagedTheme: RenderTheme { RenderTheme.current(size: documentDefault) }
    private var unpagedTheme: RenderTheme { RenderTheme.current(size: 16) }

    private func paged(_ blocks: [OfficeBlock], marginRight: CGFloat? = nil) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: pagedTheme, columnWidth: page,
                                documentDefaultFontSize: documentDefault, pageContentWidth: page,
                                pageMarginRight: marginRight)
    }

    private func unpaged(_ blocks: [OfficeBlock]) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: unpagedTheme, columnWidth: page,
                                documentDefaultFontSize: documentDefault, pageContentWidth: nil)
    }

    private func font(_ s: NSAttributedString, at i: Int) -> NSFont {
        s.attribute(.font, at: i, effectiveRange: nil) as! NSFont
    }

    private func style(_ s: NSAttributedString, at i: Int) -> NSParagraphStyle {
        s.attribute(.paragraphStyle, at: i, effectiveRange: nil) as! NSParagraphStyle
    }

    // MARK: (1) A half-point size is a real size

    /// Word's `w:sz` is in HALF-points, so 21 half-points IS 10.5pt — an ordinary authored size, and
    /// one this reader used to round away. Under paged `fontSizeScale` is 1, so rounding could only
    /// ever destroy what the author stated.
    func testPagedKeepsAnAuthoredHalfPointSize() {
        let out = paged([.paragraph(spans: [Span(text: "half", fontSize: 10.5)])])
        XCTAssertEqual(font(out, at: 0).pointSize, 10.5, accuracy: 0.0001,
                       "a paged document must draw 10.5pt at 10.5pt, not at 10 or 11")
    }

    /// The other half of the contract. Unpaged still rounds: there the size has been through a real
    /// `fontSizeScale` (16 ÷ 11) and lands on an arbitrary fraction, and rounding is what keeps those
    /// coalescing into few attribute runs.
    func testUnpagedStillRoundsTheScaledSize() {
        let out = unpaged([.paragraph(spans: [Span(text: "half", fontSize: 10.5)])])
        let expected = (10.5 * (16 / documentDefault)).rounded()
        XCTAssertEqual(font(out, at: 0).pointSize, expected, accuracy: 0.0001)
        XCTAssertEqual(font(out, at: 0).pointSize, font(out, at: 0).pointSize.rounded(), accuracy: 0.0001,
                       "the unpaged model still lands on whole points")
    }

    // MARK: (3) A heading's line height comes from the heading's own size

    /// The floor used to be a ratio of `RenderTheme.headingSize(level:)` — the app's ladder over the
    /// DOCUMENT's default body size, which under paged has nothing to do with what the heading was
    /// authored at. An 11pt-default report whose H1 states 19pt got 11 × 1.875 × 1.25 = 26pt of
    /// leading under a 19pt line.
    func testPagedHeadingLineHeightFollowsItsOwnAuthoredSize() {
        let out = paged([.heading(level: 1, spans: [Span(text: "제목", fontSize: 19)])])
        let expected = (19 * pagedTheme.headingLineHeightRatio).rounded()
        XCTAssertEqual(style(out, at: 0).minimumLineHeight, expected, accuracy: 0.0001)
        XCTAssertLessThan(style(out, at: 0).minimumLineHeight,
                          (pagedTheme.headingSize(level: 1) * pagedTheme.headingLineHeightRatio).rounded(),
                          "the ladder's own floor was the number this replaces")
    }

    /// Where the runs state no size, the floor follows the size the heading is ACTUALLY drawn at.
    ///
    /// SUBJECT CHANGED (not the number): this used to assert the floor fell back to the app's
    /// heading ladder, which was the truth until the ladder was removed for paged. It now pins the
    /// replacement — the document's own default body size — so the floor still describes a size
    /// something is really drawn at rather than one nothing is.
    func testPagedHeadingWithNoAuthoredSizeTakesItsFloorFromTheDocumentDefault() {
        let out = paged([.heading(level: 1, spans: [Span(text: "제목")])])
        XCTAssertEqual(style(out, at: 0).minimumLineHeight,
                       (documentDefault * pagedTheme.headingLineHeightRatio).rounded(),
                       accuracy: 0.0001)
        XCTAssertEqual(style(out, at: 0).minimumLineHeight,
                       (font(out, at: 0).pointSize * pagedTheme.headingLineHeightRatio).rounded(),
                       accuracy: 0.0001,
                       "the floor and the drawn size must not be able to drift apart")
    }

    func testUnpagedHeadingLineHeightIsUnchangedByAnAuthoredSize() {
        let out = unpaged([.heading(level: 1, spans: [Span(text: "제목", fontSize: 19)])])
        XCTAssertEqual(style(out, at: 0).minimumLineHeight,
                       (unpagedTheme.headingSize(level: 1) * unpagedTheme.headingLineHeightRatio).rounded(),
                       accuracy: 0.0001,
                       "the window-filling model keeps deriving the floor from its own ladder")
    }

    /// A MIXED-size heading takes its floor from the LARGEST run — a floor under the smallest would
    /// sit beneath the tallest glyphs on the same line.
    func testPagedHeadingFloorTakesTheLargestRun() {
        let out = paged([.heading(level: 2, spans: [Span(text: "small", fontSize: 12),
                                                    Span(text: "BIG", fontSize: 20)])])
        XCTAssertEqual(style(out, at: 0).minimumLineHeight,
                       (20 * pagedTheme.headingLineHeightRatio).rounded(), accuracy: 0.0001)
    }

    // MARK: (5) `w:tblHeader` is a repeat flag, not emphasis

    /// ECMA-376 defines `w:tblHeader` as "repeat this row at the top of each page". Bolding on it
    /// states something the document did not — and a bold Korean face is wider, so the header row
    /// wraps at different points than the body rows under it.
    func testPagedHeaderRowIsNotBoldedByTheRepeatFlag() {
        let out = paged([.table(rows: [[Cell(spans: [Span(text: "머리")])],
                                       [Cell(spans: [Span(text: "본문")])]], headerRows: 1)])
        let i = (out.string as NSString).range(of: "머리").location
        XCTAssertFalse(font(out, at: i).fontDescriptor.symbolicTraits.contains(.bold),
                       "a repeat-header row must not be drawn bold in a paged document")
    }

    /// A header row whose RUNS say bold still is — the change hands the decision to the document,
    /// it does not forbid the weight.
    func testPagedHeaderRowKeepsBoldWhenItsOwnRunsSaySo() {
        let out = paged([.table(rows: [[Cell(spans: [Span(text: "머리", bold: true)])]], headerRows: 1)])
        let i = (out.string as NSString).range(of: "머리").location
        XCTAssertTrue(font(out, at: i).fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testUnpagedHeaderRowIsStillBolded() {
        let out = unpaged([.table(rows: [[Cell(spans: [Span(text: "머리")])]], headerRows: 1)])
        let i = (out.string as NSString).range(of: "머리").location
        XCTAssertTrue(font(out, at: i).fontDescriptor.symbolicTraits.contains(.bold),
                      "the app's own header convention is unchanged where there is no page")
    }

    // MARK: (6) A list marker matches the item it belongs to

    func testPagedListMarkerTakesTheFirstSpansSizeAndColour() {
        let red = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let out = paged([.listItem(level: 0, ordered: false,
                                   spans: [Span(text: "커다란 항목", textColor: red, fontSize: 14)])])
        XCTAssertEqual(font(out, at: 0).pointSize, 14, accuracy: 0.0001,
                       "the bullet must be drawn at the item's own size, not the document default")
        let colour = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, OfficeTextBuilder.resolvedTextColor(red, theme: pagedTheme))
    }

    /// Size and colour only. The marker must not become monospaced because the item happens to open
    /// with a code run, and must not pick up bold/italic from the word after it.
    func testPagedListMarkerKeepsTheBodyFamilyAndNoTraits() {
        let out = paged([.listItem(level: 0, ordered: true,
                                   spans: [Span(text: "code", bold: true, italic: true, code: true, fontSize: 14)])])
        let marker = font(out, at: 0)
        XCTAssertEqual(marker.familyName, pagedTheme.bodyFont.familyName)
        XCTAssertFalse(marker.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(marker.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(marker.pointSize, 14, accuracy: 0.0001)
    }

    func testUnpagedListMarkerIsStillTheThemeBodyFontAndInk() {
        let red = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let out = unpaged([.listItem(level: 0, ordered: false,
                                     spans: [Span(text: "item", textColor: red, fontSize: 14)])])
        XCTAssertEqual(font(out, at: 0).pointSize, unpagedTheme.bodyFont.pointSize, accuracy: 0.0001)
        XCTAssertEqual(out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       unpagedTheme.textColor)
    }

    /// The marker is still the FIRST thing in the rendered item — reading the spans early to style
    /// the marker must not reorder anything.
    func testPagedListItemStillReadsMarkerThenText() {
        let out = paged([.listItem(level: 0, ordered: true, spans: [Span(text: "text", fontSize: 14)])])
        XCTAssertEqual(out.string, "1.\ttext\n")
    }

    // MARK: (7) A paged document's tab stops stay where the author put them

    /// The fill-margin rebuild exists to correct a page↔column MISMATCH. A paged column IS the page
    /// body, so there is nothing to correct — and because the controller skips
    /// `reanchorFillMarginTabs` when paged, a rebuild here would be permanent.
    func testPagedKeepsAnAuthoredTrailingRightTabExactlyWhereItIs() {
        let stops = [TabStop(position: 40, alignment: .left),
                     TabStop(position: 430, alignment: .right, leader: .dot)]
        let out = paged([.paragraph(spans: [Span(text: "1장\t서론\t7")], tabStops: stops)])
        XCTAssertEqual(style(out, at: 0).tabStops.map(\.location), [40, 430])
    }

    /// The sharper half of the same defect: a right tab the author placed MID-column is yanked out
    /// to the margin, because `fillMarginTabInfo` picks the rightmost right tab with no proximity
    /// test at all.
    func testPagedDoesNotYankAMidColumnRightTabOutToTheMargin() {
        let out = paged([.paragraph(spans: [Span(text: "a\tb")],
                                    tabStops: [TabStop(position: 200, alignment: .right)])])
        XCTAssertEqual(style(out, at: 0).tabStops.map(\.location), [200])
    }

    func testUnpagedStillReAnchorsTheTrailingRightTabToTheColumn() {
        let stops = [TabStop(position: 40, alignment: .left),
                     TabStop(position: 430, alignment: .right, leader: .dot)]
        let out = unpaged([.paragraph(spans: [Span(text: "1장\t서론\t7")], tabStops: stops)])
        XCTAssertEqual(style(out, at: 0).tabStops.map(\.location),
                       [40, page - OfficeTextBuilder.fillMarginTrailingInset],
                       "the window-filling model still rebuilds the margin tab at the column")
    }

    /// A heading is the other block kind that carries tab stops (a running head), and it takes the
    /// same rule.
    func testPagedHeadingKeepsItsAuthoredTabsToo() {
        let out = paged([.heading(level: 2, spans: [Span(text: "a\tb")],
                                  tabStops: [TabStop(position: 300, alignment: .right)])])
        XCTAssertEqual(style(out, at: 0).tabStops.map(\.location), [300])
    }

    // MARK: (8) A paged picture may run past the body column, as far as it can be DRAWN

    /// THE reason the bleed is gated off, stated as a test so nobody turns it back on without moving
    /// the container first. A picture wider than the body is SHRUNK, not allowed past the column,
    /// **even when the document's right margin would appear to have room for it** — because AppKit
    /// clips an attachment to the TEXT CONTAINER, so "allowed past the column" renders as a picture
    /// with its right side cut off. Measured pixel by pixel; the table is in `bleedAllowance`'s doc.
    ///
    /// This is the assertion to change — not delete — when `settleReadingColumn` gives the container
    /// the whole sheet. At that point 90pt of margin really is 90pt of room.
    func testAPagedPictureIsShrunkToTheColumnEvenWhereAMarginLooksAvailable() {
        let out = paged([.image(id: "i", size: CGSize(width: page + 20, height: 100))], marginRight: 90)
        let bounds = (out.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment).bounds
        XCTAssertEqual(bounds.width, page.rounded(), accuracy: 0.0001,
                       "the container is the body, so anything past it would be CROPPED, not bled")
        XCTAssertLessThan(bounds.height, 100, "shrinking stays aspect-preserving")
    }

    /// No margin parsed is the same answer by a second route, so the gate cannot be mistaken for the
    /// margin merely being absent.
    func testAPagedPictureWithNoKnownMarginIsAlsoClampedToTheColumn() {
        let out = paged([.image(id: "i", size: CGSize(width: page + 20, height: 100))], marginRight: nil)
        let bounds = (out.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment).bounds
        XCTAssertEqual(bounds.width, page.rounded(), accuracy: 0.0001)
    }

    /// A picture NARROWER than the column is untouched by any of this — the clamp only ever shrinks.
    func testAPagedPictureInsideTheColumnKeepsItsAuthoredWidth() {
        let out = paged([.image(id: "i", size: CGSize(width: 200, height: 100))], marginRight: 90)
        let bounds = (out.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment).bounds
        XCTAssertEqual(bounds.width, 200, accuracy: 0.0001)
        XCTAssertEqual(bounds.height, 100, accuracy: 0.0001)
    }

    func testAnUnpagedPictureIsStillClampedToTheColumn() {
        let out = unpaged([.image(id: "i", size: CGSize(width: page + 20, height: 100))])
        let bounds = (out.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment).bounds
        XCTAssertEqual(bounds.width, page.rounded(), accuracy: 0.0001)
    }

    /// A picture in a CELL is clamped whether paged or not — the fixed column geometry invariant 39
    /// depends on has no spare room to bleed into, and an unclamped cell picture blows the grid apart.
    func testAPagedCellPictureIsStillClampedToItsCell() {
        let out = paged([.table(rows: [[Cell(blocks: [.image(id: "i", size: CGSize(width: 900, height: 100))])]],
                                headerRows: 0)], marginRight: 90)
        var widths: [CGFloat] = []
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if let a = v as? NSTextAttachment { widths.append(a.bounds.width) }
        }
        XCTAssertEqual(widths.count, 1)
        XCTAssertLessThanOrEqual(widths[0], page,
                                 "a cell picture must not overrun the table, paged or not")
    }

    // MARK: (2) A heading's WEIGHT is the document's to state

    /// `RenderTheme.headingFont(level:)` is `.systemFont(weight: .semibold)`, so every office heading
    /// was drawn semibold whatever its runs said. Under paged the weight comes off and `Span.bold`
    /// decides. Asserted on the WEIGHT TRAIT, not on symbolic traits and not on the face name:
    /// semibold is a weight on the same family and never sets `.bold`, so the trait check that reads
    /// naturally here would pass against the old behaviour and prove nothing — while the face NAME is
    /// reported abstractly (`.AppleSystemUIFont`) before a descriptor round-trip and concretely
    /// (`.SFNS-Regular`) after one, so comparing names compares two spellings of the same font.
    func testPagedHeadingIsNotForcedSemiboldWhenItsRunsAreNot() {
        let out = paged([.heading(level: 1, spans: [Span(text: "제목", fontSize: 19)])])
        XCTAssertNotEqual(Self.weight(NSFont.systemFont(ofSize: 19)),
                          Self.weight(NSFont.systemFont(ofSize: 19, weight: .semibold)),
                          "precondition: the two weights must be distinguishable")
        XCTAssertEqual(Self.weight(font(out, at: 0)), Self.weight(NSFont.systemFont(ofSize: 19)),
                       accuracy: 0.0001,
                       "a heading whose runs are not bold must not be drawn at a weight it never asked for")
    }

    /// The declared weight of a font, as AppKit records it (0 regular, 0.3 semibold) — stable across
    /// the `NSFont(descriptor:size:)` round-trip the builder performs, which the face name is not.
    private static func weight(_ f: NSFont) -> CGFloat {
        let traits = f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }

    /// The change hands the decision to the document; it does not forbid the weight. This is the case
    /// `DocxReader.resolvedBold` supplies for a Word heading bolded by its STYLE rather than its run.
    func testPagedHeadingWhoseRunsAreBoldIsStillDrawnBold() {
        let out = paged([.heading(level: 1, spans: [Span(text: "제목", bold: true, fontSize: 19)])])
        XCTAssertTrue(font(out, at: 0).fontDescriptor.symbolicTraits.contains(.bold),
                      "a heading the document DID bold must stay bold")
    }

    func testUnpagedHeadingIsStillDrawnSemibold() {
        let out = unpaged([.heading(level: 1, spans: [Span(text: "제목", fontSize: 19)])])
        let size = font(out, at: 0).pointSize
        XCTAssertEqual(Self.weight(font(out, at: 0)),
                       Self.weight(NSFont.systemFont(ofSize: size, weight: .semibold)), accuracy: 0.0001,
                       "the window-filling model keeps the app's own heading weight")
    }

    /// A heading's AUTHORED size must survive the weight change — dropping semibold must not also
    /// drop the size the document stated.
    ///
    /// SUBJECT CHANGED (not the number): the second half used to assert that a heading stating no
    /// size falls back to `theme.headingFont(level:)`, i.e. the app's 1.875x ladder. The ladder is
    /// gone for paged — the owner's rule is that an unstated value resolves to the DOCUMENT's own
    /// default, never to a scale of ours — so the assertion now pins the thing that replaced it.
    func testAPagedHeadingKeepsItsAuthoredSizeAndOtherwiseTakesTheDocumentDefault() {
        let stated = paged([.heading(level: 1, spans: [Span(text: "제목", fontSize: 19)])])
        XCTAssertEqual(font(stated, at: 0).pointSize, 19, accuracy: 0.0001,
                       "a stated heading size is drawn verbatim")
        let unstated = paged([.heading(level: 1, spans: [Span(text: "제목")])])
        XCTAssertEqual(font(unstated, at: 0).pointSize, documentDefault, accuracy: 0.0001,
                       "an unstated heading size is the document's own default, not a ladder of ours")
        XCTAssertNotEqual(font(unstated, at: 0).pointSize,
                          pagedTheme.headingSize(level: 1), accuracy: 0.0001,
                          "precondition: the ladder would have given a visibly different number")
    }
}
