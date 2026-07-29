import XCTest
import AppKit
@testable import FastDocReader

/// header-footer-design.md build step 5 — "PAINT THE BAND": the DECISIONS a paint pass makes
/// (which header/footer entry applies to a page, what a PAGE/NUMPAGES field shows), tested as pure
/// functions rather than by pixels — this repo cannot drive synthetic scroll and does not test by
/// screenshot (CLAUDE.md). `PageBandPainter.draw` itself (the actual `NSAttributedString.draw(in:)`
/// calls) is exercised only through the production stack in `PageBandReservationTests`' 4th layer,
/// proving it wires up and never fires when there is nothing to paint.
final class PageBandPainterTests: XCTestCase {

    // MARK: - applicableEntry (which header/footer entry applies to a page)

    /// header-footer-design.md §2d: an explicit blank `.firstPage` entry (empty `blocks`) is the
    /// deliberate "no header on the cover" a reader's own parts already synthesize for `w:titlePg`
    /// with no `type="first"` reference — it must still be SELECTED (not skipped in favour of
    /// `.defaultPages`), even though painting it later draws nothing.
    func testFirstPageEntryWinsOnPageZeroEvenWhenBlank() {
        let blankFirst = OfficeHeaderFooter(appliesTo: .firstPage, blocks: [])
        let default_ = OfficeHeaderFooter(appliesTo: .defaultPages,
                                          blocks: [.paragraph(spans: [Span(text: "Default header")])])
        let chosen = PageBandPainter.applicableEntry([blankFirst, default_], pageIndex: 0)
        XCTAssertEqual(chosen?.appliesTo, .firstPage)
        XCTAssertEqual(chosen?.blocks, [])
    }

    func testDefaultEntryUsedOnPageZeroWhenNoFirstPageEntryDeclared() {
        let default_ = OfficeHeaderFooter(appliesTo: .defaultPages,
                                          blocks: [.paragraph(spans: [Span(text: "Default header")])])
        let chosen = PageBandPainter.applicableEntry([default_], pageIndex: 0)
        XCTAssertEqual(chosen?.appliesTo, .defaultPages)
    }

    /// Page index 1 is HUMAN page 2 — even — so `.evenPages` must win there over `.defaultPages`.
    func testEvenPagesEntryWinsOnEvenHumanPageNumbers() {
        let even = OfficeHeaderFooter(appliesTo: .evenPages,
                                      blocks: [.paragraph(spans: [Span(text: "Even header")])])
        let default_ = OfficeHeaderFooter(appliesTo: .defaultPages,
                                          blocks: [.paragraph(spans: [Span(text: "Default header")])])
        XCTAssertEqual(PageBandPainter.applicableEntry([even, default_], pageIndex: 1)?.appliesTo, .evenPages,
                       "page index 1 is human page 2 — even")
        XCTAssertEqual(PageBandPainter.applicableEntry([even, default_], pageIndex: 0)?.appliesTo, .defaultPages,
                       "page index 0 is human page 1 — odd")
        XCTAssertEqual(PageBandPainter.applicableEntry([even, default_], pageIndex: 2)?.appliesTo, .defaultPages,
                       "page index 2 is human page 3 — odd")
    }

    /// header-footer-design.md §7: even/odd DIFFERENCE is deferred past v1, but a document that
    /// declares only a default entry must still get it repeated on every page, including even ones —
    /// the single-sided fallback every format uses when it never declared the other side.
    func testDefaultEntryFallsBackOnEvenPagesWhenNoEvenPagesEntryDeclared() {
        let default_ = OfficeHeaderFooter(appliesTo: .defaultPages,
                                          blocks: [.paragraph(spans: [Span(text: "Default header")])])
        XCTAssertEqual(PageBandPainter.applicableEntry([default_], pageIndex: 1)?.appliesTo, .defaultPages)
    }

    /// header-footer-design.md §7: an `.evenPages`-only document (no `.defaultPages` at all) must
    /// return `nil` on an odd page rather than silently reusing the even entry on the wrong page.
    func testNoMatchingEntryReturnsNilWhenNoDefaultDeclaredEither() {
        let evenOnly = OfficeHeaderFooter(appliesTo: .evenPages,
                                          blocks: [.paragraph(spans: [Span(text: "Even only")])])
        XCTAssertNil(PageBandPainter.applicableEntry([evenOnly], pageIndex: 0), "page 0 is odd, no default declared")
        XCTAssertNil(PageBandPainter.applicableEntry([], pageIndex: 1), "no entries at all")
    }

    // MARK: - totalPages (ceil(documentHeight / pitch), header-footer-design.md §5)

    func testTotalPagesIsCeilingOfDocumentHeightOverPitch() {
        // Exactly 3 pitches → exactly 3 pages (not 4 — the boundary itself must not round up).
        XCTAssertEqual(PageBandPainter.totalPages(documentHeight: 300, pitch: 100), 3)
        // A hair over 2 pitches → rounds up to 3.
        XCTAssertEqual(PageBandPainter.totalPages(documentHeight: 201, pitch: 100), 3)
        // A hair under 1 pitch → still 1 page.
        XCTAssertEqual(PageBandPainter.totalPages(documentHeight: 99, pitch: 100), 1)
    }

    func testTotalPagesIsAtLeastOneEvenForDegenerateInputs() {
        XCTAssertEqual(PageBandPainter.totalPages(documentHeight: 0, pitch: 100), 1)
        XCTAssertEqual(PageBandPainter.totalPages(documentHeight: 500, pitch: 0), 1,
                       "pitch <= 0 means 'not paginating' — never divide by it")
    }

    /// `PageBandPainter.draw`'s own doc explains why it subtracts `leadingBand`/`trailingBand` back
    /// out of the laid-out extent before judging `totalPages`: those two outer reservations are
    /// real laid-out height by the time either is non-zero (`leadingBand` via a line shift,
    /// `trailingBand` via `applyTrailingFooterBand`'s extra line fragment), so leaving them IN would
    /// silently manufacture a phantom extra page the instant their own size pushed the total just
    /// past a `pitch` multiple — this is that claim, proven directly against `totalPages` (the one
    /// piece of that arithmetic exposed as a pure function) rather than trusted by reading the
    /// comment. A document whose BODY is exactly 3 pitches must read 3 pages whether or not its
    /// leading+trailing reservations are folded into the height handed in — the caller's job is to
    /// have already subtracted them, and this is why.
    func testTotalPagesMustBeJudgedAgainstBodyHeightNotTheFullLaidOutExtentIncludingTheOuterBands() {
        let pitch: CGFloat = 166
        let bodyHeight = pitch * 3               // exactly 3 pitches of real page content
        let leading: CGFloat = 27                // a real measured header height
        let trailing: CGFloat = 27                // a real measured footer height

        XCTAssertEqual(PageBandPainter.totalPages(documentHeight: bodyHeight, pitch: pitch), 3,
                       "the body alone, correctly judged, is exactly 3 pages")
        XCTAssertEqual(PageBandPainter.totalPages(documentHeight: bodyHeight + leading + trailing, pitch: pitch), 4,
                       "the SAME body, judged with the outer bands still folded in, manufactures a " +
                       "phantom 4th page — exactly the bug `draw`'s own `bodyHeight` subtraction exists to avoid")
    }

    // MARK: - substitutingPageFields (live PAGE/NUMPAGES substitution, header-footer-design.md §5)

    private let theme = RenderTheme.current(size: 11)

    /// The 96.7%-of-real-headers case: a `PAGE` field's cached text ("2", Word's stale last computed
    /// value) must be replaced with the live page number for whatever page this header is drawn on.
    func testPageFieldSubstitutesTheLiveValueNotTheStaleCachedText() {
        let span = Span(text: "2", pageNumberField: .page)
        let built = OfficeTextBuilder.build([.paragraph(spans: [span])], theme: theme)
        // Precondition: the builder actually stamped the field (otherwise this test is vacuous).
        var stamped: PageNumberField?
        built.enumerateAttribute(MDAttr.pageNumberField, in: NSRange(location: 0, length: built.length)) { v, _, _ in
            // `enumerateAttribute` also calls back for the neighbouring nil-valued run (the
            // paragraph's trailing "\n", which carries no field) — only a non-nil hit counts.
            if let field = v as? PageNumberField { stamped = field }
        }
        XCTAssertEqual(stamped, .page, "precondition: OfficeTextBuilder must stamp MDAttr.pageNumberField")

        let sub = PageBandPainter.substitutingPageFields(built, page: 7, totalPages: 40)
        XCTAssertEqual(sub.string, "7\n", "the stale cached \"2\" must be replaced with the live page number")
    }

    func testNumPagesFieldSubstitutesTheTotal() {
        let span = Span(text: "5", pageNumberField: .numPages)
        let built = OfficeTextBuilder.build([.paragraph(spans: [span])], theme: theme)
        let sub = PageBandPainter.substitutingPageFields(built, page: 1, totalPages: 40)
        XCTAssertEqual(sub.string, "40\n")
    }

    /// An ordinary span (no `pageNumberField`) must survive untouched — this function's scope is
    /// exactly the spans marked for it, nothing else in the same header/footer paragraph.
    func testASpanWithNoPageNumberFieldIsNeverTouched() {
        let plain = Span(text: "Confidential")
        let field = Span(text: "2", pageNumberField: .page)
        let built = OfficeTextBuilder.build([.paragraph(spans: [plain, field])], theme: theme)
        let sub = PageBandPainter.substitutingPageFields(built, page: 3, totalPages: 10)
        XCTAssertEqual(sub.string, "Confidential3\n", "only the marked run changes; the plain run is untouched")
    }

    /// A mix of PAGE and NUMPAGES in the SAME paragraph ("Page 3 of 40") — both must resolve
    /// independently, and replacing back-to-front must not corrupt the earlier range's offset.
    func testPageAndNumPagesBothSubstituteInTheSameParagraph() {
        let spans = [Span(text: "Page "), Span(text: "2", pageNumberField: .page),
                    Span(text: " of "), Span(text: "5", pageNumberField: .numPages)]
        let built = OfficeTextBuilder.build([.paragraph(spans: spans)], theme: theme)
        let sub = PageBandPainter.substitutingPageFields(built, page: 9, totalPages: 40)
        XCTAssertEqual(sub.string, "Page 9 of 40\n")
    }

    /// A header/footer with no field at all — the overwhelmingly common non-field case — must come
    /// back byte-identical (no allocation surprises, no accidental mutation of ordinary text).
    func testAHeaderWithNoFieldAtAllIsReturnedUnchanged() {
        let built = OfficeTextBuilder.build([.paragraph(spans: [Span(text: "Confidential Draft")])], theme: theme)
        let sub = PageBandPainter.substitutingPageFields(built, page: 2, totalPages: 9)
        XCTAssertEqual(sub.string, built.string)
    }
}
