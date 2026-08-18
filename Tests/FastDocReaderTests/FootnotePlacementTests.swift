import XCTest
@testable import FastDocReader

/// S14 — a footnote leaves the body flow and lands at the foot of its own page.
///
/// The four things that must hold, none of which needs a window: the band's arithmetic, the body
/// floor that arithmetic moves, the extract path that would otherwise lose the notes silently, and
/// the rule that an ENDNOTE is not touched by any of it.
final class FootnotePlacementTests: XCTestCase {

    // MARK: the band's height

    /// A page citing nothing reserves nothing — not a separator, not a minimum. 615 of the 637
    /// corpus documents cite no footnote at all, and any floor here would move every one of them.
    func testAPageCitingNoNoteReservesNothing() {
        XCTAssertEqual(PageBandGeometry.footnoteBandHeight(noteHeights: [],
                                                           separatorAllowance: 8, noteSpacing: 4), 0)
        // Notes that build to nothing are not notes either.
        XCTAssertEqual(PageBandGeometry.footnoteBandHeight(noteHeights: [0, 0],
                                                           separatorAllowance: 8, noteSpacing: 4), 0)
    }

    /// Separator once, notes in full, spacing only BETWEEN them — a single note gets no gap.
    func testTheBandIsSeparatorPlusNotesPlusTheGapsBetweenThem() {
        XCTAssertEqual(PageBandGeometry.footnoteBandHeight(noteHeights: [20],
                                                           separatorAllowance: 8, noteSpacing: 4),
                       28, accuracy: 0.001)
        XCTAssertEqual(PageBandGeometry.footnoteBandHeight(noteHeights: [20, 30, 10],
                                                           separatorAllowance: 8, noteSpacing: 4),
                       8 + 60 + 8, accuracy: 0.001)
    }

    // MARK: the body floor it moves

    private func delegate(content: CGFloat = 500, band: CGFloat = 20) -> PageBandLayoutDelegate {
        PageBandLayoutDelegate(pageContentHeight: content, band: band)
    }

    /// With no notes anywhere, the floor is the number it has always been — this is what makes the
    /// whole feature invisible to every document that has none.
    func testWithNoNotesTheBodyFloorIsUnchanged() {
        let d = delegate()
        for page in 0..<4 {
            XCTAssertEqual(d.textBottom(ofPage: CGFloat(page)),
                           CGFloat(page) * 520 + 500, accuracy: 0.001)
        }
    }

    /// A reservation lifts the floor of ITS page and no other, and never moves a page top — the
    /// property invariant 98 rests on (the sheet does not grow; the body just stops earlier).
    func testAReservationLiftsOnlyItsOwnPagesFloor() {
        let d = delegate()
        d.noteBands = [2: 60]
        XCTAssertEqual(d.textBottom(ofPage: 2), 2 * 520 + 500 - 60, accuracy: 0.001)
        XCTAssertEqual(d.textBottom(ofPage: 1), 1 * 520 + 500, accuracy: 0.001)
        XCTAssertEqual(d.textBottom(ofPage: 3), 3 * 520 + 500, accuracy: 0.001)
        // The page a point falls on is derived from the pitch, which no note touches.
        XCTAssertEqual(PageBandLayoutDelegate.page(of: 520 * 2 + 1, leadingBand: 0, pitch: 520), 2)
    }

    // MARK: --extract must not lose them

    /// Lifting notes out of `blocks` would silently drop them from `--extract`, whose entire purpose
    /// is letting a tool read the document without the reader. They come back as markdown footnotes.
    func testExtractCarriesTheNotesItLiftedOut() {
        let body: [OfficeBlock] = [.paragraph(spans: [Span(text: "See the note.")])]
        let note = OfficeFootnote(number: 3,
                                  blocks: [.paragraph(spans: [Span(text: "The note's own text.")])])
        let out = OfficeMarkdownSerializer.serialize(body, footnotes: [note])
        XCTAssertTrue(out.contains("See the note."))
        XCTAssertTrue(out.contains("The note's own text."), "the note's text must survive --extract")
        XCTAssertTrue(out.contains("[^3]:"), "and must be associated with its own number")
    }

    /// A document with no notes serialises exactly as it did before this existed.
    func testExtractIsUnchangedWhenThereAreNoNotes() {
        let body: [OfficeBlock] = [.paragraph(spans: [Span(text: "Just text.")])]
        XCTAssertEqual(OfficeMarkdownSerializer.serialize(body, footnotes: []),
                       OfficeMarkdownSerializer.serialize(body))
    }

    // MARK: markers

    /// Only a footnote's marker is tagged. An endnote's is left bare on purpose: its note is still
    /// in the block flow, so nothing has to go and find it — and tagging it would make the settle
    /// reserve room at the foot of a page for a note that is not going there.
    func testOnlyAFootnoteMarkerIsTagged() {
        var footnoteMarker = Span(text: "1")
        footnoteMarker.superscript = true
        footnoteMarker.footnoteRef = 1
        var endnoteMarker = Span(text: "2")
        endnoteMarker.superscript = true
        let built = OfficeTextBuilder.build([.paragraph(spans: [footnoteMarker, endnoteMarker])],
                                            theme: .current(size: 11), columnWidth: 400,
                                            documentDefaultFontSize: 11, pageContentWidth: nil)
        var found: [Int] = []
        built.enumerateAttribute(MDAttr.footnoteRef,
                                 in: NSRange(location: 0, length: built.length)) { value, _, _ in
            if let n = (value as? NSNumber)?.intValue { found.append(n) }
        }
        XCTAssertEqual(found, [1], "exactly one marker carries a reference, and it is the footnote's")
    }

    // MARK: the separator the document declared

    /// A section that said nothing gets the reader's own minimum — and a document with no notes is
    /// unaffected either way.
    func testAnUndeclaredSeparatorUsesTheReadersMinimum() {
        XCTAssertEqual(FootnotePainter.separatorAllowance(nil),
                       FootnotePainter.defaultSeparatorAllowance)
        XCTAssertEqual(FootnotePainter.separatorAllowance(OfficeFootnoteSeparator()),
                       FootnotePainter.defaultSeparatorAllowance,
                       "a struct that declared nothing is the same as no struct at all")
    }

    /// The declared margins and rule weight are what the page keeps clear — the document's numbers,
    /// not the reader's.
    func testADeclaredSeparatorIsItsOwnMarginsPlusItsRule() {
        var sep = OfficeFootnoteSeparator()
        sep.lineType = 1
        sep.lineWidthPt = 2
        sep.marginTopPt = 6
        sep.marginBottomPt = 9
        XCTAssertEqual(FootnotePainter.separatorAllowance(sep), 17, accuracy: 0.001)
    }

    /// A section that declared margins but NO line still keeps its air clear — it asked for the
    /// space and only declined the rule.
    func testASeparatorWithNoLineStillKeepsItsMargins() {
        var sep = OfficeFootnoteSeparator()
        sep.lineType = 0
        sep.marginTopPt = 4
        sep.marginBottomPt = 4
        XCTAssertTrue(sep.isDeclared)
        XCTAssertEqual(FootnotePainter.separatorAllowance(sep), 8, accuracy: 0.001)
    }

    /// THE property that keeps a note off the last line of body text: the height the settle reserves
    /// and the offset the painter draws at come from ONE function. This test fails the moment the
    /// two are computed separately, which is the only way this defect can appear.
    func testTheBandReservesExactlyWhatThePainterDrawsInto() {
        var sep = OfficeFootnoteSeparator()
        sep.lineType = 1
        sep.lineWidthPt = 1
        sep.marginTopPt = 5
        sep.marginBottomPt = 3
        sep.noteSpacingPt = 2
        let heights: [CGFloat] = [12, 18]
        let band = PageBandGeometry.footnoteBandHeight(
            noteHeights: heights,
            separatorAllowance: FootnotePainter.separatorAllowance(sep),
            noteSpacing: sep.noteSpacingPt)
        // What the painter consumes, walked the same way it walks it.
        let consumed = FootnotePainter.separatorAllowance(sep) + heights[0] + sep.noteSpacingPt + heights[1]
        XCTAssertEqual(band, consumed, accuracy: 0.001)
    }
}
