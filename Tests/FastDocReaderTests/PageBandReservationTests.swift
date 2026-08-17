import XCTest
import AppKit
@testable import FastDocReader

/// header-footer-design.md build steps 4 ("RESERVE THE BAND") and 5 ("PAINT THE BAND"). Four layers,
/// each proving a different half of the claim:
///
///  1. `PageBandGeometry.bandHeight` — the MEASUREMENT (header/footer built through the real
///     `OfficeTextBuilder`, laid out in an isolated stack — never the document's declared offset).
///  2. `PageBandLayoutDelegate` — the ALGORITHM in isolation, productionising
///     `PageBandShiftSpikeTests` verbatim (rect-derived page, not a counter) plus the one thing the
///     spike didn't have to model: a table line must never be shifted.
///  3. The REAL production stack (`MarkdownDocument` + `DocumentWindowController`) — proving the two
///     are actually wired together for a paged office document, and that every other document kind
///     (no header/footer, and markdown) is provably untouched.
///  4. Step 5's own wiring — `DocumentWindowController.pageBandContent`, and that `--extract` cannot
///     see any of it (invariant 40). The DECISIONS `PageBandPainter` makes (which entry applies, what
///     a PAGE/NUMPAGES field shows) are tested as pure functions in `PageBandPainterTests`, not here.
final class PageBandReservationTests: XCTestCase {
    private let theme = RenderTheme.current(size: 11)

    /// This file measures the BAND MECHANISM — what a running header and footer reserve — and every
    /// number in it predates the View menu's page options. Those options can add to the band (the
    /// outline reserves the document's own margins plus a desk between sheets even with nothing
    /// drawn in them), so without pinning them here the file's numbers would depend on a stored
    /// preference: the suite would read differently for a developer who had switched the outline off,
    /// and the shipped default alone would move nine of these assertions.
    ///
    /// Pinned to the shape this file was written against — no sheets, header and footer on — so it
    /// keeps guarding exactly the property it always did. The outline's own effects are
    /// `PageViewOptionsTests`' subject.
    override func setUp() {
        super.setUp()
        // The outline is the MASTER: a header and footer only exist alongside it, so "band, no
        // sheets" — the shape this suite used to pin — is no longer a configuration the reader has.
        PageViewOptionsStore.current = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    // MARK: - 1. PageBandGeometry (measurement)

    func testBandHeightIsZeroWithNoHeaderAndNoFooter() {
        let band = PageBandGeometry.bandHeight(headers: [], footers: [], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertEqual(band, 0, "no header/footer at all must reserve nothing")
    }

    func testBandHeightIsZeroWhenTheOnlyEntryHasNoBlocks() {
        // Exactly the synthesized blank first-page header/footer OOXML creates under `w:titlePg`
        // (header-footer-design.md §2d) — an entry exists but carries no content to measure.
        let blank = OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [])
        let band = PageBandGeometry.bandHeight(headers: [blank], footers: [blank], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertEqual(band, 0, "a present-but-blank header/footer must still reserve nothing")
    }

    /// PRESENT, PRESENT-BUT-EMPTY, ABSENT — three answers, and only the first reserves anything.
    /// `w:titlePg`'s deliberately blank entry arrives with NO blocks and was always handled; this is
    /// the same thing one level deeper, and it is not exotic: **26 of the 94 real HWP/HWPX documents
    /// that declare a header or footer at all — 28% — declare one made of nothing but empty
    /// paragraphs**, and the reference report's own `.odt` declares exactly such a first-page header.
    /// Each of them opened a band on every page and drew nothing in it.
    func testAnEntryOfNothingButEmptyParagraphsReservesNothing() {
        let blank = OfficeHeaderFooter(appliesTo: .defaultPages,
                                       blocks: [.paragraph(spans: []), .paragraph(spans: [])])
        let band = PageBandGeometry.bandHeight(headers: [blank], footers: [], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertEqual(band, 0, "a header that builds to nothing must not reserve a band to put it in")
    }

    /// The counterweight, and why the test is on what it BUILDS rather than on whether there is text:
    /// a header that is only a logo draws no glyph at all and must still reserve. An attachment is
    /// `U+FFFC`, which is not whitespace.
    func testAPictureOnlyHeaderStillReserves() {
        let logo = OfficeHeaderFooter(appliesTo: .defaultPages,
                                      blocks: [.image(id: "logo", size: CGSize(width: 60, height: 20))])
        XCTAssertGreaterThan(
            PageBandGeometry.bandHeight(headers: [logo], footers: [], theme: theme, columnWidth: 400,
                                        documentDefaultFontSize: 11, pageContentWidth: 400), 0)
    }

    /// The other thing that draws without a glyph: a paragraph whose whole content is a RULE or a
    /// shaded band. The blocks are asked directly for those, because nothing reaches the built string.
    func testAHeaderThatIsOnlyARuleStillReserves() {
        let rule = OfficeHeaderFooter(
            appliesTo: .defaultPages,
            blocks: [.paragraph(spans: [], format: ParagraphFormat(borderWidth: 1, borderEdges: .bottom))])
        XCTAssertGreaterThan(
            PageBandGeometry.bandHeight(headers: [rule], footers: [], theme: theme, columnWidth: 400,
                                        documentDefaultFontSize: 11, pageContentWidth: 400), 0)
    }

    /// The single-source predicate the leading-band gate and this measurement now share, so the two
    /// cannot drift into disagreeing about whether a document has a header.
    func testEntryDrawsAnswersTheSameQuestionForAllThreeStates() {
        func draws(_ e: OfficeHeaderFooter?) -> Bool {
            PageBandGeometry.entryDraws(e, theme: theme, columnWidth: 400,
                                        documentDefaultFontSize: 11, pageContentWidth: 400)
        }
        XCTAssertFalse(draws(nil), "absent")
        XCTAssertFalse(draws(OfficeHeaderFooter(appliesTo: .defaultPages, blocks: [])), "blank entry")
        XCTAssertFalse(draws(OfficeHeaderFooter(appliesTo: .defaultPages,
                                                blocks: [.paragraph(spans: [])])), "empty paragraphs")
        XCTAssertTrue(draws(OfficeHeaderFooter(appliesTo: .defaultPages,
                                               blocks: [.paragraph(spans: [Span(text: "Title")])])))
    }

    /// With no margins declared, the band is exactly what this reader must DRAW — the two sides,
    /// nothing added. Checked algebraically rather than against a hardcoded point value (brittle to
    /// font metrics): `both == headerOnly + footerOnly`.
    ///
    /// It used to be `+ 12pt`, a "space between pages" the reader invented; the document's own
    /// margins say it instead now (`testBandTakesTheDocumentsOwnMarginsWhenItDeclaredThem`), and a
    /// document that declared none gets no invented padding at all.
    func testBandHeightIsExactlyHeaderPlusFooterWhenNoMarginsAreDeclared() {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Document Title")])])
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Page footer text")])])
        let headerOnly = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                      columnWidth: 400, documentDefaultFontSize: 11,
                                                      pageContentWidth: 400)
        let footerOnly = PageBandGeometry.bandHeight(headers: [], footers: [footer], theme: theme,
                                                      columnWidth: 400, documentDefaultFontSize: 11,
                                                      pageContentWidth: 400)
        let both = PageBandGeometry.bandHeight(headers: [header], footers: [footer], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertGreaterThan(headerOnly, 0, "must include real header height")
        XCTAssertGreaterThan(footerOnly, 0, "must include real footer height")
        XCTAssertEqual(both, headerOnly + footerOnly, accuracy: 0.5)
    }

    /// invariant 57: the document states the space between two pages — its bottom margin plus the
    /// next page's top margin — and a running header/footer lives INSIDE those margins rather than
    /// on top of them. So the declared pair wins whenever it is roomy enough, and the drawn height
    /// wins only when this reader would otherwise overlap the body.
    func testBandTakesTheDocumentsOwnMarginsWhenItDeclaredThem() {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Document Title")])])
        let drawn = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                columnWidth: 400, documentDefaultFontSize: 11,
                                                pageContentWidth: 400)
        // Roomy margins (the ordinary case — a 1.5cm/1.5cm A4 is 85pt against a ~26pt header).
        let roomy = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                columnWidth: 400, documentDefaultFontSize: 11,
                                                pageContentWidth: 400,
                                                pageMarginTop: 60, pageMarginBottom: 40)
        XCTAssertEqual(roomy, 100, accuracy: 0.01, "the paper's own 60+40 is the space between pages")
        XCTAssertGreaterThan(roomy, drawn, "and it is roomier than the header alone needs")

        // Margins too tight for what we draw: expand to fit rather than paint over the body.
        let tight = PageBandGeometry.bandHeight(headers: [header], footers: [], theme: theme,
                                                columnWidth: 400, documentDefaultFontSize: 11,
                                                pageContentWidth: 400,
                                                pageMarginTop: 1, pageMarginBottom: 1)
        XCTAssertEqual(tight, drawn, accuracy: 0.01,
                       "2pt of declared margin cannot hold the header this reader draws")
    }

    /// header-footer-design.md §7: even/odd headers are deferred past v1. An `.evenPages`-only
    /// entry (no `.defaultPages` entry present at all) must still be measured — it is the ONLY
    /// entry there is — via the `entries.first` fallback, not silently treated as zero.
    func testANonDefaultEntryIsStillMeasuredWhenItIsTheOnlyOne() {
        let evenOnly = OfficeHeaderFooter(appliesTo: .evenPages,
                                          blocks: [.paragraph(spans: [Span(text: "Even page header")])])
        let band = PageBandGeometry.bandHeight(headers: [evenOnly], footers: [], theme: theme,
                                               columnWidth: 400, documentDefaultFontSize: 11,
                                               pageContentWidth: 400)
        XCTAssertGreaterThan(band, 0)
    }

    // MARK: - 2. PageBandLayoutDelegate (algorithm, in isolation)

    private func makeStack(columnWidth: CGFloat, delegate: PageBandLayoutDelegate?)
        -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.delegate = delegate
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    private func body(paragraphs: Int) -> NSAttributedString {
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk. "
        let out = NSMutableAttributedString()
        for _ in 0..<paragraphs {
            out.append(NSAttributedString(
                string: String(repeating: sentence, count: 3) + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .paragraphStyle: NSParagraphStyle.default]))
        }
        return out
    }

    private func lineRects(_ layout: NSLayoutManager, _ container: NSTextContainer) -> [NSRect] {
        layout.ensureLayout(for: container)
        var rects: [NSRect] = []
        let glyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }

    /// The gate: `isActive == false` (band 0, matching a document with no header/footer) must
    /// leave every line exactly where an ordinary layout — no delegate installed at all — puts it.
    /// This is the "a document with no header/footer is unchanged" property, proven at the
    /// algorithm level.
    ///
    /// Mutation target: `PageBandLayoutDelegate.isActive`'s body — replacing the `pageContentHeight
    /// > 0 && band > 0` condition with a constant `true` makes this fail (lines would be pushed to
    /// page boundaries with zero reserved gap the instant any line straddles one).
    func testInactiveDelegateLeavesEveryLineExactlyWhereItWouldLandWithNoDelegateAtAll() {
        let text = body(paragraphs: 40)
        let (plainStorage, plainLayout, plainContainer) = makeStack(columnWidth: 400, delegate: nil)
        plainStorage.setAttributedString(text)
        let plain = lineRects(plainLayout, plainContainer)

        let delegate = PageBandLayoutDelegate(pageContentHeight: 0, band: 0)
        XCTAssertFalse(delegate.isActive, "precondition: zero height/band must be inactive")
        let (storage, layout, container) = makeStack(columnWidth: 400, delegate: delegate)
        storage.setAttributedString(text)
        let paged = lineRects(layout, container)

        XCTAssertEqual(paged.count, plain.count)
        for i in 0..<plain.count {
            XCTAssertEqual(paged[i].minY, plain[i].minY, accuracy: 0.01, "line \(i) moved despite an inactive delegate")
        }
        XCTAssertEqual(delegate.shiftCount, 0)
    }

    /// Productionised spike, verbatim assertions — see `PageBandShiftSpikeTests` for the original
    /// feasibility experiment this reproduces against the shipping class.
    ///
    /// Mutation target: the final `return true` in `PageBandLayoutDelegate.layoutManager(_:should
    /// SetLineFragmentRect:...)` — flipping it to `return false` makes AppKit discard the mutated
    /// rect and recompute its own default, so nothing would move and this fails at (a).
    func testActiveDelegateReservesExactlyOneBandPerPageBoundaryCrossed() throws {
        let column: CGFloat = 400
        let text = body(paragraphs: 40)

        let (plainStorage, plainLayout, plainContainer) = makeStack(columnWidth: column, delegate: nil)
        plainStorage.setAttributedString(text)
        let plain = lineRects(plainLayout, plainContainer)
        XCTAssertGreaterThan(plain.count, 60)

        let lineHeight = plain[1].minY - plain[0].minY
        let pageHeight = (lineHeight * 12).rounded()
        let band: CGFloat = 40
        let delegate = PageBandLayoutDelegate(pageContentHeight: pageHeight, band: band)
        XCTAssertTrue(delegate.isActive)

        let (storage, layout, container) = makeStack(columnWidth: column, delegate: delegate)
        storage.setAttributedString(text)
        let paged = lineRects(layout, container)

        XCTAssertEqual(paged.count, plain.count, "paginating must not change how the text WRAPS")
        XCTAssertGreaterThan(delegate.shiftCount, 2, "the document must cross several page boundaries")

        // (a) THE MECHANISM.
        XCTAssertGreaterThan(paged.last!.minY, plain.last!.minY)

        // (b) THE TYPESETTER FOLLOWED — every line sits exactly `page × band` lower than its
        // unpaginated position.
        let pitch = pageHeight + band
        for (i, rect) in paged.enumerated() {
            let page = (rect.minY / pitch).rounded(.down)
            XCTAssertEqual(rect.minY - plain[i].minY, page * band, accuracy: 0.5,
                           "line \(i) should sit exactly one band lower per page boundary above it")
        }

        // (c) NO LINE STRADDLES A BOUNDARY.
        for rect in paged {
            let page = (rect.minY / pitch).rounded(.down)
            XCTAssertLessThanOrEqual(rect.maxY, page * pitch + pageHeight + 0.5)
        }

        // (d) NOTHING OVERLAPS.
        for i in 1..<paged.count {
            XCTAssertGreaterThanOrEqual(paged[i].minY, paged[i - 1].maxY - 0.5)
        }

        // (e) TOTAL HEIGHT GREW BY EXACTLY THE RESERVED SPACE.
        let pagesCrossed = (paged.last!.minY / pitch).rounded(.down)
        XCTAssertEqual(paged.last!.maxY - plain.last!.maxY, pagesCrossed * band, accuracy: 0.5)
    }

    /// THE TEST THAT WAS MISSING, and whose absence shipped a document that broke pages when
    /// PRINTED and ignored every break on SCREEN.
    ///
    /// The breaks were read inside `configurePageBand`, which the render calls BEFORE `display(_:)`
    /// installs the new text — so the markers being looked for were still the previous document's,
    /// and on a first open there was no text at all. `--pdf` re-applies the band with the text
    /// already in place and so looked correct the whole time, which is exactly why every check that
    /// went through the print path passed. This one goes through the REAL render.
    func testARenderLeavesTheDelegateHoldingTheDocumentsOwnBreaks() throws {
        let doc = MarkdownDocument()
        // A file URL so the document IS an office one — `kind` is decided by the extension, and a
        // document that reads as markdown never runs the office render this test is about.
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-break-render-\(UUID().uuidString).hwp")
        doc.setOfficeContent(
            blocks: [.paragraph(spans: [Span(text: "cover")]),
                     .paragraph(spans: [Span(text: "foreword")]),
                     .paragraph(spans: [Span(text: "body")])],
            comments: [], archive: nil, images: [:], defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 60, pageMarginRight: 60,
            pageContentHeight: 500, pageMarginTop: 60, pageMarginBottom: 60,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "head")])])],
            footers: [], masterPages: [], sectionStartBlocks: [0],
            pageBreakBlocks: [1], keepWithNextBlocks: [],
            sections: [], anchoredObjects: [], lineGridPitch: nil)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)

        XCTAssertGreaterThan(try XCTUnwrap(wc.textStorageRef).length, 0,
                             "the render must actually have painted something")
        XCTAssertFalse(wc.pageBandDelegate.documentPageBreaks.isEmpty,
                       "after a real render the delegate must hold the document's own break, or the " +
                       "screen silently ignores it while printing honours it")
        let storage = try XCTUnwrap(wc.textStorageRef)
        for location in wc.pageBandDelegate.documentPageBreaks {
            XCTAssertLessThan(location, storage.length,
                              "a break location must point INTO the text that is actually installed")
            XCTAssertNotNil(storage.attribute(MDAttr.startsPage, at: location, effectiveRange: nil),
                            "…and at a character the builder actually marked")
        }
    }

    /// The MIRROR of the test above, and the regression fixing that one caused. Printing re-applies
    /// the band on text that is already installed and never calls `display(_:)` again, so clearing
    /// the breaks in `configurePageBand` left the PRINT path ignoring every one of them — the manual
    /// went from 520 pages to 436. Both paths must end up holding the same instruction.
    func testReapplyingTheBandKeepsTheDocumentsBreaks() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-break-print-\(UUID().uuidString).hwp")
        doc.setOfficeContent(
            blocks: [.paragraph(spans: [Span(text: "cover")]),
                     .paragraph(spans: [Span(text: "foreword")]),
                     .paragraph(spans: [Span(text: "body")])],
            comments: [], archive: nil, images: [:], defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 60, pageMarginRight: 60,
            pageContentHeight: 500, pageMarginTop: 60, pageMarginBottom: 60,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "head")])])],
            footers: [], masterPages: [], sectionStartBlocks: [0],
            pageBreakBlocks: [1], keepWithNextBlocks: [],
            sections: [], anchoredObjects: [], lineGridPitch: nil)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        let afterRender = wc.pageBandDelegate.documentPageBreaks
        XCTAssertFalse(afterRender.isEmpty)

        // What printing does: re-apply the band against the text already on screen.
        doc.applyPageBand(to: wc, forPrinting: true)
        XCTAssertEqual(wc.pageBandDelegate.documentPageBreaks, afterRender,
                       "re-applying the band must not lose the document's own breaks — printing " +
                       "never calls display(_:) again, so whatever this leaves is what it prints")
    }

    /// The AUTHOR's page break, not the page's own edge (invariant 82). A line marked
    /// `documentPageBreaks` starts a fresh page even though it would have fitted where it stood —
    /// this is what a document's 쪽 나누기 means, and dropping it is what let a cover, its blank verso
    /// and a foreword run together on one page.
    func testALineTheDocumentBreaksAtStartsAFreshPage() throws {
        let column: CGFloat = 400
        let text = body(paragraphs: 6)

        let (plainStorage, plainLayout, plainContainer) = makeStack(columnWidth: column, delegate: nil)
        plainStorage.setAttributedString(text)
        let plain = lineRects(plainLayout, plainContainer)
        let lineHeight = plain[1].minY - plain[0].minY
        let pageHeight = (lineHeight * 12).rounded()
        let delegate = PageBandLayoutDelegate(pageContentHeight: pageHeight, band: 40)

        // The break goes on the SECOND PARAGRAPH's first character — a line well inside page 0, so
        // "it fits where it stands" is true and only the document's instruction can move it. Taken
        // from the STRING (the character after the first newline) rather than from a line rect: a
        // rect belongs to the layout that produced it, and this one has to be known before layout.
        let paragraphStart = (text.string as NSString).range(of: "\n").upperBound
        let (storage, layout, container) = makeStack(columnWidth: column, delegate: delegate)
        delegate.documentPageBreaks = [paragraphStart]
        storage.setAttributedString(text)
        let paged = lineRects(layout, container)

        let pitch = pageHeight + 40
        XCTAssertEqual(paged.count, plain.count, "a break must not change how the text WRAPS")
        let brokenLine = try XCTUnwrap(paged.enumerated().first { index, _ in
            let glyph = layout.glyphIndexForCharacter(at: paragraphStart)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY == paged[index].minY
        })
        XCTAssertEqual(brokenLine.element.minY, pitch, accuracy: 0.5,
                       "the marked line must start page 1, not sit where it fitted on page 0")
        XCTAssertLessThan(paged[brokenLine.offset - 1].maxY, pitch,
                          "the line before it stays on page 0")
    }

    /// IDEMPOTENCE — re-laying out from the middle of the document must not double-shift. See
    /// `PageBandShiftSpikeTests.testRelayingOutFromTheMiddleDoesNotShiftTwice`'s own doc comment for
    /// why a running counter fails this and a rect-derived rule doesn't.
    ///
    /// Mutation target: replacing `let page = (rect.minY / pitch).rounded(.down)` with a value
    /// derived from a persistent counter incremented once per shift (rather than from the incoming
    /// rect) makes this fail — the counter would have already advanced past the boundaries above
    /// the re-laid-out range, so lines below the invalidation point double-shift.
    func testRelayingOutFromTheMiddleDoesNotShiftTwice() {
        let column: CGFloat = 400
        let text = body(paragraphs: 40)
        let delegate = PageBandLayoutDelegate(pageContentHeight: (16 * 12).rounded(), band: 40)
        let (storage, layout, container) = makeStack(columnWidth: column, delegate: delegate)
        storage.setAttributedString(text)
        let first = lineRects(layout, container)

        layout.invalidateLayout(forCharacterRange: NSRange(location: storage.length / 2,
                                                           length: storage.length - storage.length / 2),
                                actualCharacterRange: nil)
        let second = lineRects(layout, container)

        XCTAssertEqual(first.count, second.count)
        for i in 0..<min(first.count, second.count) {
            XCTAssertEqual(first[i].minY, second[i].minY, accuracy: 0.5, "line \(i) moved on re-layout")
        }
    }

    /// The known hard edge (header-footer-design.md §4/§7), asserted directly against the delegate:
    /// a paragraph carrying an `NSTextTableBlock` must be left alone even when it would otherwise
    /// straddle a page boundary — it is allowed to overrun.
    ///
    /// Mutation target: removing the `if isInsideTable(layoutManager, glyphRange) { return false }`
    /// guard makes this fail — the table's lines would then snap to the page grid like ordinary
    /// text, silently "fixing" the very limitation the design records as open.
    func testALineInsideATextTableIsNeverShifted() {
        let table = GridTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        let cellStyle = NSMutableParagraphStyle()
        cellStyle.textBlocks = [block]

        let out = NSMutableAttributedString()
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk. "
        for _ in 0..<20 {
            out.append(NSAttributedString(
                string: String(repeating: sentence, count: 3) + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: cellStyle]))
        }

        // A tiny page height guarantees this 20-paragraph "table" straddles many boundaries.
        let delegate = PageBandLayoutDelegate(pageContentHeight: 60, band: 40)
        let (storage, layout, container) = makeStack(columnWidth: 400, delegate: delegate)
        storage.setAttributedString(out)
        let rects = lineRects(layout, container)

        XCTAssertEqual(delegate.shiftCount, 0, "no table line should ever be shifted")
        // The overrun the design accepts: some line's bottom edge must exceed what would have been
        // its page's text bottom, proving the boundary genuinely was NOT enforced inside the table.
        let pitch: CGFloat = 100
        let anyOverran = rects.contains { rect in
            let page = (rect.minY / pitch).rounded(.down)
            return rect.maxY > page * pitch + 60 + 0.5
        }
        XCTAssertTrue(anyOverran, "precondition: this table must actually cross a page boundary for the test to mean anything")
        // THE REPORTED DEFECT, from the other side: no boundary was opened, so the painter must have
        // nothing to paint into. It used to compute the boundaries arithmetically and paint them
        // regardless, which put a page number across a real report's table header row and the running
        // title across a data row — the document read as corrupt rather than as missing a header.
        XCTAssertTrue(delegate.openedBoundaries.isEmpty,
                      "a boundary layout could not open must not be reported as painted space")
    }

    /// The same claim where it MATTERS — a document that is part prose, part long table. The prose
    /// boundaries open and must still be painted; the ones inside the table do not and must not be.
    /// A blanket "skip painting whenever a table exists" would pass the test above and lose every
    /// header in a report that happens to contain a table, which is most of them.
    func testOnlyTheBoundariesLayoutOpenedAreOfferedToThePainter() {
        let table = GridTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        let cellStyle = NSMutableParagraphStyle()
        cellStyle.textBlocks = [block]
        let font = NSFont.systemFont(ofSize: 13)
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk. "

        let out = NSMutableAttributedString()
        for _ in 0..<12 {   // prose first: these boundaries CAN be opened
            out.append(NSAttributedString(string: String(repeating: sentence, count: 3) + "\n",
                                          attributes: [.font: font]))
        }
        for _ in 0..<12 {   // then a long table: these cannot
            out.append(NSAttributedString(string: String(repeating: sentence, count: 3) + "\n",
                                          attributes: [.font: font, .paragraphStyle: cellStyle]))
        }

        let delegate = PageBandLayoutDelegate(pageContentHeight: 60, band: 40)
        let (storage, layout, container) = makeStack(columnWidth: 400, delegate: delegate)
        storage.setAttributedString(out)
        _ = lineRects(layout, container)   // the delegate only speaks once layout has actually run

        XCTAssertFalse(delegate.openedBoundaries.isEmpty,
                       "the prose half must still paginate — the fix must not disable headers wholesale")
        XCTAssertEqual(delegate.openedBoundaries.count, delegate.shiftCount,
                       "one opened boundary per shifted line, so the painter's gate and layout agree")
        // Every boundary the table straddles is absent: the highest opened one is inside the prose.
        let proseBoundaries = delegate.openedBoundaries.count
        XCTAssertLessThan(proseBoundaries, 23,
                          "a 24-paragraph document at this pitch crosses far more boundaries than the prose half alone")
    }

    /// THE REPORTED SYMPTOM: "현재 홀수쪽, 짝수쪽의 여백이 다름". The gap layout opens is the
    /// document's own margin PLUS whatever room the previous page's last line left unused, and that
    /// leftover varies with paragraph spacing, headings and tables. Centring the header and footer in
    /// halves of that gap therefore moved them a few points page to page. Anchored to the SHEET's own
    /// edge, using the distances the document states (`w:pgMar/@w:header`/`@w:footer`), the placement
    /// is identical on every page — and the leftover shows where it truly is, as white space above the
    /// footer, which is what a short page looks like in Word.
    func testHeaderAndFooterSitAtTheirDeclaredDistanceFromTheSheetEdgeOnEveryPage() {
        let content: CGFloat = 600, marginTop: CGFloat = 40, marginBottom: CGFloat = 30
        let band = marginTop + marginBottom
        let pitch = content + band
        let headerDistance: CGFloat = 12, footerDistance: CGFloat = 10
        let headerHeight: CGFloat = 14, footerHeight: CGFloat = 14

        /// Page `n`'s boundary, with `leftover` points of its own page left unused by its last line —
        /// the thing that used to move the header and footer.
        func offsets(page: Int, leftover: CGFloat) -> (footerAboveEdge: CGFloat, headerBelowEdge: CGFloat) {
            let gridTop = CGFloat(page) * pitch + content
            let gap = (top: gridTop - leftover, height: band + leftover)
            let edge = try! XCTUnwrap(PageBandPainter.sheetEdge(gridTop: gridTop, gap: gap,
                                                               bottomMargin: marginBottom))
            let footer = PageBandPainter.footerTop(gap: gap, sheetEdge: edge,
                                                  distance: footerDistance, footerHeight: footerHeight)
            let header = PageBandPainter.headerTop(gap: gap, sheetEdge: edge,
                                                   distance: headerDistance, headerHeight: headerHeight)
            return (edge - (footer + footerHeight), header - edge)
        }

        // Three pages, each leaving a DIFFERENT amount of its own page unused — which is the real
        // shape of a document, and what made this drift.
        let a = offsets(page: 0, leftover: 0)
        let b = offsets(page: 1, leftover: 7.5)
        let c = offsets(page: 2, leftover: 17)
        for (label, o) in [("page 0", a), ("page 1", b), ("page 2", c)] {
            XCTAssertEqual(o.footerAboveEdge, footerDistance, accuracy: 0.01,
                           "\(label): the footer sits its own declared distance above the sheet edge")
            XCTAssertEqual(o.headerBelowEdge, headerDistance, accuracy: 0.01,
                           "\(label): and the header its own distance below it")
        }
    }

    /// A document that states no distances keeps the halves it used before they were parsed — every
    /// ODT and HWP document today (invariant 37's "the document said nothing → unchanged").
    func testAnUndeclaredDistanceFallsBackToTheHalvesOfTheGap() {
        let gap = (top: 100 as CGFloat, height: 80 as CGFloat)
        XCTAssertNil(PageBandPainter.sheetEdge(gridTop: 100, gap: gap, bottomMargin: nil))
        XCTAssertEqual(PageBandPainter.footerTop(gap: gap, sheetEdge: nil, distance: nil, footerHeight: 20),
                       110, accuracy: 0.01, "centred in the upper half")
        XCTAssertEqual(PageBandPainter.headerTop(gap: gap, sheetEdge: nil, distance: nil, headerHeight: 20),
                       150, accuracy: 0.01, "centred in the lower half")
    }

    /// Neither side may ever be painted outside the gap layout actually opened — the clamp that keeps
    /// a page whose last line overran (a table) from being drawn over.
    func testPlacementIsClampedInsideTheOpenedGap() {
        let gap = (top: 100 as CGFloat, height: 40 as CGFloat)
        // A footer distance larger than the gap itself would place it above the previous page's text.
        XCTAssertEqual(PageBandPainter.footerTop(gap: gap, sheetEdge: 120, distance: 500, footerHeight: 14),
                       gap.top, accuracy: 0.01)
        // A header distance larger than the gap would place it on its own page's first line.
        XCTAssertEqual(PageBandPainter.headerTop(gap: gap, sheetEdge: 120, distance: 500, headerHeight: 14),
                       gap.top + gap.height - 14, accuracy: 0.01)
        // And the sheet edge itself never leaves the gap.
        XCTAssertEqual(PageBandPainter.sheetEdge(gridTop: 0, gap: gap, bottomMargin: 0), gap.top)
        XCTAssertEqual(PageBandPainter.sheetEdge(gridTop: 1000, gap: gap, bottomMargin: 0),
                       gap.top + gap.height)
    }

    /// The painter's own half of the gate — `PageBandPainter.bandExists(after:in:)`, the SAME function
    /// both between-page arms of `draw` call, not a re-implementation of its condition here. (An
    /// earlier version of this test did re-implement it and passed with the gate removed from the
    /// painter entirely — invariant 30's lesson, self-inflicted.)
    func testThePainterSkipsABoundaryLayoutDidNotOpen() {
        func content(_ openedBoundaries: Set<Int>?) -> PageBandContent {
            var c = PageBandContent(headers: [], footers: [], theme: theme, columnWidth: 400,
                                    documentDefaultFontSize: 11, pageContentWidth: 400,
                                    headerHeight: 20, footerHeight: 0,
                                    leadingBand: 0, trailingBand: 0)
            c.openedBoundaries = openedBoundaries
            return c
        }
        // No information (a caller that never ran layout) → paint every boundary, exactly as before.
        for page in 0..<3 {
            XCTAssertTrue(PageBandPainter.bandExists(after: page, in: content(nil)))
        }
        XCTAssertTrue(PageBandPainter.bandExists(after: 0, in: content([0, 1, 2])))
        XCTAssertTrue(PageBandPainter.bandExists(after: 2, in: content([0, 1, 2])))
        // Only the open one — the others are inside a table and have no space to paint into.
        XCTAssertTrue(PageBandPainter.bandExists(after: 0, in: content([0])))
        XCTAssertFalse(PageBandPainter.bandExists(after: 1, in: content([0])))
        XCTAssertFalse(PageBandPainter.bandExists(after: 2, in: content([0])))
        // Nothing open at all: a document that is one long table paints nothing over it.
        for page in 0..<3 {
            XCTAssertFalse(PageBandPainter.bandExists(after: page, in: content([])))
        }
    }

    // MARK: - 3. The real production stack (MarkdownDocument + DocumentWindowController)

    private func clearSavedWindowFrame() {
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
    }

    private func silenceResizeNotifications(_ wc: DocumentWindowController) {
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
    }

    private func settle(_ wc: DocumentWindowController, windowWidth: CGFloat) {
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: windowWidth, height: 600), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()
    }

    private func longBody(paragraphs: Int = 30) -> [OfficeBlock] {
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk."
        return (0..<paragraphs).map { _ in
            .paragraph(spans: [Span(text: String(repeating: sentence + " ", count: 3))])
        }
    }

    /// Opens a synthetic paged office document — `setOfficeContent` is the same seam
    /// `OfficeDocumentTests`/`PagedZoomTests` drive, independent of any real docx/odt/HWP parser.
    private func openPagedOffice(headers: [OfficeHeaderFooter], footers: [OfficeHeaderFooter],
                                 pageContentHeight: CGFloat, blocks: [OfficeBlock]? = nil)
        throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-pageband-\(UUID().uuidString).docx")
        doc.setOfficeContent(
            blocks: blocks ?? longBody(), archive: nil, defaultBodyFontSize: 11,
            pageContentWidth: 400, pageContentHeight: pageContentHeight,
            headers: headers, footers: footers)
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)
        return (doc, wc)
    }

    private func allLineRects(_ wc: DocumentWindowController) throws -> [NSRect] {
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)
        var rects: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    /// THE feature, through the real document → render → layout-manager-delegate path: a paged
    /// office document with a real header AND footer reserves the measured band between pages, and
    /// the reservation lands at the RIGHT y (an exact multiple of the measured band per boundary),
    /// not merely "somewhere".
    ///
    /// Mutation target: in `MarkdownDocument.render(into:)`'s `.office` case, changing the `band`
    /// ternary's true-branch to always `0` (as if `wc.configurePageBand` were never wired to
    /// `PageBandGeometry` at all) makes this fail — `wc.pageBandDelegate.isActive` would be false
    /// and every line would land back at its unpaginated position.
    func testARealPagedDocumentWithAHeaderAndFooterReservesTheMeasuredBandAtPageBoundaries() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Footer")])])
        let (doc, wc) = try openPagedOffice(headers: [header], footers: [footer], pageContentHeight: 150)
        _ = doc

        XCTAssertTrue(wc.isPaged, "precondition: this document declared a page width")
        XCTAssertTrue(wc.pageBandDelegate.isActive, "a header+footer must activate the reservation")
        XCTAssertGreaterThan(wc.pageBandDelegate.band, 0)

        let rects = try allLineRects(wc)
        XCTAssertGreaterThan(wc.pageBandDelegate.shiftCount, 0,
                             "this document is long enough that it must cross at least one page boundary")

        // Translated by `leadingBand` exactly as `PageBandLayoutDelegate.shouldSetLineFragmentRect`
        // itself is (its own doc: "just translated by leadingBand and back again") — this fixture's
        // header applies to page 0 too (no separate `.firstPage` entry), so `leadingBand` is the
        // measured header height here, not zero.
        let pitch = wc.pageBandDelegate.pageContentHeight + wc.pageBandDelegate.band
        let leading = wc.pageBandDelegate.leadingBand
        for rect in rects {
            let page = ((rect.minY - leading) / pitch).rounded(.down)
            XCTAssertLessThanOrEqual(rect.maxY, page * pitch + leading + wc.pageBandDelegate.pageContentHeight + 0.5,
                                     "a line must never run into the space reserved for the header/footer band")
        }
    }

    /// "A document with no header/footer is unchanged" — same body, same page height, headers/
    /// footers both empty. Every consecutive pair of lines must be exactly contiguous (no page-grid
    /// snapping at all), proving the delegate is a true no-op rather than merely "close enough".
    ///
    /// Mutation target: `PageBandLayoutDelegate.isActive`'s `band > 0` half of the condition —
    /// dropping it (leaving only `pageContentHeight > 0`) makes this fail, because lines would then
    /// snap to a zero-gap page grid the moment any straddled a boundary, producing a jump even
    /// though nothing should have moved.
    func testARealDocumentWithNoHeaderOrFooterIsLaidOutExactlyAsBefore() throws {
        // Nothing to reserve means the OUTLINE is off too — with it on, the desk between
        // sheets is reserved whether or not there is a header (invariant 60c).
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, wc) = try openPagedOffice(headers: [], footers: [], pageContentHeight: 150)

        XCTAssertTrue(wc.isPaged, "precondition: this document is still paged (page WIDTH is what makes it so)")
        XCTAssertFalse(wc.pageBandDelegate.isActive, "no header/footer must never activate the reservation")
        XCTAssertEqual(wc.pageBandDelegate.band, 0)
        XCTAssertEqual(wc.pageBandDelegate.shiftCount, 0)

        let rects = try allLineRects(wc)
        XCTAssertGreaterThan(rects.count, 10, "precondition: enough lines for a jump to be detectable")
        for i in 1..<rects.count {
            XCTAssertEqual(rects[i].minY, rects[i - 1].maxY, accuracy: 0.5,
                           "line \(i) is not contiguous with its predecessor — something shifted it")
        }
    }

    /// Markdown never reaches `officePageContentHeight`/`officeHeaders`/`officeFooters` at all
    /// (they default to nil/empty for every non-office kind), so `configurePageBand` is never even
    /// called for it — proven directly against the one flag every effect in the delegate gates on.
    func testAMarkdownDocumentNeverActivatesTheReservation() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-pageband-md-\(UUID().uuidString).md")
        let source = String(repeating: "A line of ordinary markdown text.\n\n", count: 40)
        try Data(source.utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let doc = MarkdownDocument()
        doc.fileURL = temp
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)

        XCTAssertFalse(wc.isPaged)
        XCTAssertFalse(wc.pageBandDelegate.isActive)
        XCTAssertEqual(wc.pageBandDelegate.pageContentHeight, 0)
        XCTAssertEqual(wc.pageBandDelegate.band, 0)
        XCTAssertEqual(wc.pageBandDelegate.shiftCount, 0)
    }

    /// "A table is not split" — the known hard edge, through the real render path: a table long
    /// enough to cross the tiny page height used here must be left alone by the delegate — proven
    /// directly on the TABLE's OWN geometry (every consecutive pair of table-attributed lines is
    /// exactly contiguous, never jumping to a page-grid boundary), which is the recorded v1
    /// limitation (header-footer-design.md §7) rather than a surprise.
    ///
    /// NOT asserted as a global `wc.pageBandDelegate.shiftCount == 0`, which is what this test
    /// checked before `leadingBand` existed. Once a leading header band is active, the first
    /// NON-table line after an overrunning table legitimately DOES get pushed to the next page's
    /// start — that is exactly what header-footer-design.md §4 means by "the boundary is taken at
    /// the next line after it" (confirmed on this fixture: `TableBlockBuilder.build`'s own
    /// table-closing terminator, invariant 55/`appendTable`'s trailing separator, is not itself part
    /// of the table and is fair game for the page grid). A global shiftCount therefore is no longer
    /// zero on this fixture and asserting so was measuring a coincidence of the old (untranslated)
    /// boundary math, not the actual invariant this test is named for.
    ///
    /// Mutation target: removing `PageBandLayoutDelegate`'s `isInsideTable` guard makes this fail —
    /// the table's own lines would then be laid out with a jump exactly where they cross a page
    /// boundary, instead of the constant per-row spacing this asserts.
    func testARealTableCrossingAPageBoundaryIsNotSplit() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Footer")])])
        let rows: [[Cell]] = (0..<30).map { i in
            [Cell(spans: [Span(text: "Row \(i) — enough text that this table is tall.")])]
        }
        let blocks: [OfficeBlock] = [.table(rows: rows, headerRows: 0)]
        let (_, wc) = try openPagedOffice(headers: [header], footers: [footer],
                                          pageContentHeight: 100, blocks: blocks)

        XCTAssertTrue(wc.pageBandDelegate.isActive)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)

        // Precondition: the document really did build a real NSTextTableBlock-backed table (i.e.
        // this test would be vacuous against a builder that silently degraded the table to plain
        // paragraphs — see invariant 40's `<raw>` fallback for a case where that legitimately
        // happens, just not here).
        var sawTableParagraph = false
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { sawTableParagraph = true }
        }
        XCTAssertTrue(sawTableParagraph, "precondition: the fixture must actually produce a real text-table block")

        // The table is 30 rows at a 100pt page height — it certainly crosses several boundaries. No
        // ROW of it should ever jump to a page-grid position: consecutive rows keep the SAME pitch
        // (each row's own cell padding/border spacing) end to end. `minY(i) - maxY(i-1)` is not 0 —
        // a table row is taller than its own text (cell padding) — so the invariant compared is the
        // row-to-row DELTA, which any page-boundary shift would visibly break by adding `band` to it.
        var tableLineRects: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, glyphRange, _ in
            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.location < storage.length,
                  let style = storage.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil)
                    as? NSParagraphStyle, !style.textBlocks.isEmpty else { return }
            tableLineRects.append(rect)
        }
        XCTAssertEqual(tableLineRects.count, rows.count, "precondition: one line per table row")
        let rowPitch = tableLineRects[1].minY - tableLineRects[0].minY
        XCTAssertGreaterThan(rowPitch, 0, "precondition: rows are laid out top to bottom")
        for i in 1..<tableLineRects.count {
            XCTAssertEqual(tableLineRects[i].minY - tableLineRects[i - 1].minY, rowPitch, accuracy: 0.5,
                           "table row \(i) breaks the uniform row pitch — a table line must never be shifted to a page boundary")
        }
    }

    // MARK: - 4. Painting (build step 5) — wiring only; DECISIONS are PageBandPainterTests' job

    /// A paged document with a real header AND footer must come out of `render(into:)` with
    /// `pageBandContent` populated — the same render call that activates `pageBandDelegate` also
    /// hands the painter what it needs, from the SAME measurement (`PageBandGeometry.measure`).
    ///
    /// Mutation target: in `MarkdownDocument.render(into:)`'s `.office` case, changing the `sides`
    /// ternary's true-branch to `PageBandGeometry.Sides(header: 0, footer: 0, band: 0)` unconditionally
    /// (as if step 5 were never wired to the measurement at all) makes this fail — `wc.pageBandContent`
    /// would be `nil` even though a header and footer were declared.
    func testARealPagedDocumentWithAHeaderAndFooterHasPaintContentWired() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Footer")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [footer], pageContentHeight: 150)

        let content = try XCTUnwrap(wc.pageBandContent, "a header+footer document must get paint content")
        XCTAssertEqual(content.headers, [header])
        XCTAssertEqual(content.footers, [footer])
        XCTAssertGreaterThan(content.headerHeight, 0)
        XCTAssertGreaterThan(content.footerHeight, 0)
        // Identity with the reservation: the SAME two heights step 4 measured (via
        // `PageBandGeometry.measure`) must be what step 5 paints with — not a second, independently
        // measured pair that could silently disagree with the space actually reserved.
        // (This fixture declares no page margins, so the band IS the two drawn heights — see
        // `testBandTakesTheDocumentsOwnMarginsWhenItDeclaredThem` for the case where the paper's own
        // margins are roomier and win instead.)
        XCTAssertEqual(content.headerHeight + content.footerHeight + RenderTheme.pageDeskGap,
                       wc.pageBandDelegate.band, accuracy: 0.01,
                       "the band is the two drawn heights plus the desk the outline reserves")
    }

    /// "A document with no header/footer is unchanged" — step 5's own half of that claim:
    /// `pageBandContent` must be `nil`, not merely empty, so `ReaderTextView.drawBackground` skips
    /// the paint pass entirely rather than iterating over nothing.
    ///
    /// Mutation target: `DocumentWindowController.configurePageBand`'s `band > 0 ? ... : nil`
    /// ternary — replacing the `nil` branch with an always-populated (but empty) `PageBandContent`
    /// would still cost an allocation and a needless per-draw iteration.
    func testARealDocumentWithNoHeaderOrFooterHasNoPaintContentEither() throws {
        // Nothing to reserve means the OUTLINE is off too — with it on, the desk between
        // sheets is reserved whether or not there is a header (invariant 60c).
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, wc) = try openPagedOffice(headers: [], footers: [], pageContentHeight: 150)
        XCTAssertNil(wc.pageBandContent)
    }

    /// Markdown never reaches any of this — same precondition `testAMarkdownDocumentNeverActivatesThe
    /// Reservation` checks for the layout delegate, checked here for the paint content too.
    func testAMarkdownDocumentNeverGetsPaintContentEither() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-pageband-paint-md-\(UUID().uuidString).md")
        let source = String(repeating: "A line of ordinary markdown text.\n\n", count: 10)
        try Data(source.utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let doc = MarkdownDocument()
        doc.fileURL = temp
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        clearSavedWindowFrame()
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        silenceResizeNotifications(wc)
        settle(wc, windowWidth: 800)

        XCTAssertNil(wc.pageBandContent)
    }

    /// invariant 40: running header/footer content is presentation and must never reach `--extract`.
    /// `OfficeMarkdownSerializer.serialize` takes only `[OfficeBlock]` — it cannot see `headers`/
    /// `footers` even in principle, since its signature never accepts them — so this proves the
    /// STRUCTURAL guarantee directly rather than trusting the signature by inspection alone: the
    /// same body blocks serialize identically whether or not the read result also carried a header
    /// and footer.
    func testHeaderAndFooterContentNeverReachesExtract() {
        let body: [OfficeBlock] = [
            .heading(level: 1, spans: [Span(text: "Report Title")]),
            .paragraph(spans: [Span(text: "Ordinary body text.")]),
        ]
        let withoutHeaderFooter = OfficeReadResult(blocks: body)
        let withHeaderFooter = OfficeReadResult(
            blocks: body,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "Running Header")])])],
            footers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "Page "),
                                                                     Span(text: "2", pageNumberField: .page)])])])

        let extractWithout = OfficeMarkdownSerializer.serialize(withoutHeaderFooter.blocks)
        let extractWith = OfficeMarkdownSerializer.serialize(withHeaderFooter.blocks)
        XCTAssertEqual(extractWithout, extractWith,
                       "a header/footer (or a live page-number field inside one) must not change --extract")
        XCTAssertFalse(extractWith.contains("Running Header"))
        XCTAssertFalse(extractWith.contains("Running Footer"))
    }

    // MARK: - 5. Edges — page 0's own leading header, the last page's own trailing footer
    //
    // The between-page reservation/painting above (§§1–4) leaves both OUTER edges untouched — there
    // is no line before page 0's first one for a shift to push down, and no line after the last one
    // for the between-page footer arm to draw beneath. `PageBandLayoutDelegate.leadingBand` (a
    // constant shift applied to EVERY line, not just ones that cross a boundary — see that class's
    // own `page == -1` derivation) and `DocumentWindowController.applyTrailingFooterBand` (which
    // widens the layout manager's own "extra line fragment") are the two different mechanisms that
    // close that gap. `DocumentWindowController.configurePageBand` decides the two numbers;
    // `PageBandPainter.draw`'s `page == 0`/`page == total - 1` arms paint into them (already proven
    // wired via `content.leadingBand`/`content.trailingBand` below — pixel drawing itself is left
    // untested per this repo's own constraint, invariant "cannot drive synthetic scroll").

    /// THE DEFECT this section exists to close: a document whose header applies to every page
    /// (including page 0 — no separate `.firstPage` entry, i.e. no `w:titlePg`/OOXML blank-cover
    /// rule) must reserve real space ABOVE its very first line, not just between pages 1→2, 2→3, …
    ///
    /// Mutation target: `DocumentWindowController.configurePageBand`'s `leading` computation —
    /// hardcoding it to `0` regardless of `firstPageHeader` makes this fail (the geometry assertion
    /// below), reproducing the original bug report exactly ("the first page has no header above it").
    func testLeadingHeaderBandIsReservedWhenNoFirstPageEntryIsDeclared() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [], pageContentHeight: 150)

        XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0,
                             "a header with no separate first-page entry applies to page 0 too")
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertEqual(content.leadingBand, wc.pageBandDelegate.leadingBand,
                       "the delegate (geometry) and the painter (content) must agree on the same reservation")
        XCTAssertEqual(content.leadingBand, content.headerHeight, accuracy: 0.01,
                       "the leading reservation is exactly the measured header height — nothing more")

        // GEOMETRY, not merely the number: the first actual line of BODY text must sit exactly
        // `leadingBand` below where it would with no header at all — proving there is real drawable
        // room above it for the header to paint into, not just a delegate flag that says so.
        let rects = try allLineRects(wc)
        let firstLine = try XCTUnwrap(rects.first)
        XCTAssertEqual(firstLine.minY, wc.pageBandDelegate.leadingBand, accuracy: 0.5,
                       "the document's first line must start exactly one leading band below the top")
    }

    /// The OOXML "no header on the cover" rule (header-footer-design.md §2d): a document that
    /// declares an EXPLICIT, EMPTY `.firstPage` header entry — Word's own way of saying "this
    /// section's first page deliberately has no header" — must reserve NOTHING above page 0, even
    /// though its `.defaultPages` header is real and non-empty (and does get painted from page 1
    /// onward). Reserving space here would grow an unexplained gap above a cover the author
    /// deliberately left bare.
    ///
    /// Mutation target: `configurePageBand`'s `firstPageHeader` gate — replacing
    /// `!(firstPageHeader?.blocks.isEmpty ?? true)` with `firstPageHeader != nil` makes this fail (an
    /// empty-but-present `.firstPage` entry would wrongly count as "there is a cover header").
    func testLeadingHeaderBandIsZeroWhenTheFirstPageIsDeclaredBlank() throws {
        let blankFirstPage = OfficeHeaderFooter(appliesTo: .firstPage, blocks: [])
        let defaultHeader = OfficeHeaderFooter(appliesTo: .defaultPages,
                                               blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [blankFirstPage, defaultHeader], footers: [],
                                          pageContentHeight: 150)

        XCTAssertEqual(wc.pageBandDelegate.leadingBand, 0,
                       "a document that blanked its own cover must not grow an unexplained gap above it")
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertEqual(content.leadingBand, 0)
        // The reservation BETWEEN pages must be entirely unaffected — this document still has a real
        // header from page 1 onward, only page 0's own leading edge is suppressed.
        XCTAssertGreaterThan(content.headerHeight, 0)
        XCTAssertGreaterThan(wc.pageBandDelegate.band, 0)

        // GEOMETRY: with nothing reserved, the very first line sits at its natural, unshifted top —
        // byte-identical to a document with no header at all (`testARealDocumentWithNoHeaderOrFooter
        // IsLaidOutExactlyAsBefore`'s own precondition).
        let rects = try allLineRects(wc)
        let firstLine = try XCTUnwrap(rects.first)
        XCTAssertEqual(firstLine.minY, 0, accuracy: 0.5,
                       "a blanked cover must leave the first line exactly where it would sit with no header")
    }

    /// THE DEFECT's other half: a footer applying to the (unmarked) last page must reserve real
    /// space BELOW the document's very last line — the between-page footer arm only ever draws in
    /// the gap BEFORE the next page, and there is no next page after the last one.
    ///
    /// Mutation target: `applyTrailingFooterBand`'s `width = trailing > 0 ? tc.size.width : 0` /
    /// its `setExtraLineFragmentRect` call — zeroing either makes the frame stop growing, reproducing
    /// "the last page has no footer below it".
    func testTrailingFooterBandIsReservedBelowTheLastLine() throws {
        let footer = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Footer")])])
        let (_, wc) = try openPagedOffice(headers: [], footers: [footer], pageContentHeight: 150)

        XCTAssertGreaterThan(wc.pageBandDelegate.trailingBand, 0)
        let content = try XCTUnwrap(wc.pageBandContent)
        XCTAssertEqual(content.trailingBand, content.footerHeight, accuracy: 0.01)

        // GEOMETRY: AppKit already reserves a default one-line-tall "extra line fragment" past the
        // last real line even with no override at all (confirmed by probe before this was built —
        // header-footer-design.md build step 4's own spike), so `applyTrailingFooterBand` REPLACES
        // that default reservation rather than adding on top of it — the before/after DELTA is not
        // the number to check. What must hold is the ABSOLUTE final extent: the last real line's own
        // `maxY` plus exactly `trailingBand`, proving real, drawable room exists below the last line
        // at precisely the height the footer was measured at.
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)
        let lastGlyph = layout.numberOfGlyphs - 1
        let baseline = lastGlyph >= 0
            ? layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY : 0
        wc.applyTrailingFooterBand()
        let after = layout.usedRect(for: container).height
        XCTAssertEqual(after, baseline + wc.pageBandDelegate.trailingBand, accuracy: 0.5,
                       "the laid-out extent must end exactly one trailing footer band past the last line")
    }

    /// The counterpart to the two tests above: a document with NEITHER a header nor a footer must
    /// reserve nothing at either outer edge, and `applyTrailingFooterBand` — called unconditionally
    /// on every document by `precomputeLayout`'s completion, header/footer or not — must be a true
    /// no-op rather than merely "small".
    func testNeitherEdgeIsReservedWithNoHeaderOrFooter() throws {
        // Nothing to reserve means the OUTLINE is off too — with it on, the desk between
        // sheets is reserved whether or not there is a header (invariant 60c).
        PageViewOptionsStore.current = PageViewOptions(outline: false)
        let (_, wc) = try openPagedOffice(headers: [], footers: [], pageContentHeight: 150)
        XCTAssertEqual(wc.pageBandDelegate.leadingBand, 0)
        XCTAssertEqual(wc.pageBandDelegate.trailingBand, 0)

        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)
        let before = layout.usedRect(for: container).height
        wc.applyTrailingFooterBand()
        let after = layout.usedRect(for: container).height
        XCTAssertEqual(after, before, accuracy: 0.01, "no footer must reserve no trailing space at all")
    }

    /// `restore(_:)`'s own top-of-document snap (invariant 24) must widen to include a reserved
    /// leading header band — otherwise "restore to the top" lands the reader just past the band,
    /// scrolling the header (and the page's own top margin) out of sight instead of showing them.
    /// Geometry only: the clip view's scroll origin after restoring the very first character with
    /// `offsetFromTop == 0` must be exactly `0`, never `leadingBand` short of it.
    ///
    /// Mutation target: `restore(_:)`'s guard — reverting `textView.textContainerInset.height +
    /// pageBandDelegate.leadingBand` back to `textView.textContainerInset.height` alone makes this
    /// fail the moment `leadingBand > 0`.
    func testRestoringToTheTopShowsTheFullLeadingHeaderBand() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [], pageContentHeight: 150)
        XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0, "precondition: a real band is reserved")

        // Scroll away from the top first, so restoring is a real move and not a no-op that would
        // pass this test vacuously.
        let sv = try XCTUnwrap(wc.textView.enclosingScrollView)
        sv.contentView.scroll(to: NSPoint(x: 0, y: 400))
        sv.reflectScrolledClipView(sv.contentView)

        wc.restore(DocumentWindowController.ReadingAnchor(char: 0, offsetFromTop: 0))
        XCTAssertEqual(sv.contentView.bounds.origin.y, 0, accuracy: 0.5,
                       "restoring the very first character must land at the true top, header band included")
    }

    /// `scrollCharToTop`'s identical top-of-document snap, same reasoning as the test above.
    ///
    /// Mutation target: `scrollCharToTop`'s guard — same revert as above.
    func testScrollCharToTopShowsTheFullLeadingHeaderBand() throws {
        let header = OfficeHeaderFooter(appliesTo: .defaultPages,
                                        blocks: [.paragraph(spans: [Span(text: "Running Header")])])
        let (_, wc) = try openPagedOffice(headers: [header], footers: [], pageContentHeight: 150)
        XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0, "precondition: a real band is reserved")

        let sv = try XCTUnwrap(wc.textView.enclosingScrollView)
        sv.contentView.scroll(to: NSPoint(x: 0, y: 400))
        sv.reflectScrolledClipView(sv.contentView)

        wc.scrollCharToTop(0)
        XCTAssertEqual(sv.contentView.bounds.origin.y, 0, accuracy: 0.5,
                       "scrolling character 0 to the top must land at the true top, header band included")
    }

    // MARK: - Which of the document's breaks have work to do (invariant 90)

    /// Builds the shape the rule is about: paragraphs in order, each optionally carrying the
    /// document's own break marker and a section index. Returns the string plus every marker's
    /// character location, so a test names positions by paragraph rather than by counting characters.
    private func markedParagraphs(_ paragraphs: [(text: String, breaks: Bool, section: Int)])
        -> (storage: NSAttributedString, locations: [Int]) {
        let out = NSMutableAttributedString()
        var locations: [Int] = []
        for paragraph in paragraphs {
            let start = out.length
            out.append(NSAttributedString(string: paragraph.text + "\n"))
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(MDAttr.sectionIndex, value: paragraph.section, range: range)
            if paragraph.breaks {
                out.addAttribute(MDAttr.startsPage, value: true, range: range)
                locations.append(start)
            }
        }
        return (out, locations)
    }

    /// Two adjacent paragraphs that both carry the same marker are ONE attribute run, and reading
    /// the run is what silently welds them: measured on the reference manual, 176 runs against 185
    /// marked paragraphs. Both readers of this attribute depend on the split — a lost page break,
    /// and a keep-with-next pair moved as a single block by its first line.
    func testTwoAdjacentMarkedParagraphsAreTwoMarkers() {
        let (storage, locations) = markedParagraphs([
            (text: "A heading", breaks: true, section: 0),
            (text: "Another heading", breaks: true, section: 0),
            (text: "Body", breaks: false, section: 0)
        ])
        let found = PageBandLayoutDelegate.markedParagraphs(MDAttr.startsPage, in: storage)

        XCTAssertEqual(found.count, 2,
                       "two marked paragraphs must read back as two markers — one run is what the " +
                       "attribute store reports, not what the document said")
        XCTAssertEqual(found.map(\.start), locations,
                       "and each must start at its own paragraph")
        XCTAssertEqual(found[0].end, locations[1],
                       "the first block must END where the second begins, or a rule that moves a " +
                       "block by its range moves both")
    }

    /// A break whose page would hold nothing but the empty paragraph the previous break left there
    /// has nothing to do — measured on `2025 행정업무운영 편람`, where honouring it opened a page
    /// carrying only the 바탕쪽 (invariant 90).
    func testABreakAboveNothingIsNotHonoured() {
        let (storage, locations) = markedParagraphs([
            (text: "First page's body", breaks: false, section: 0),
            (text: "", breaks: true, section: 0),          // takes the break, lands alone at a page top
            (text: "Second page's body", breaks: true, section: 0)  // its page holds only the line above
        ])
        let honoured = PageBandLayoutDelegate.honouredPageBreaks(in: storage)

        XCTAssertTrue(honoured.contains(locations[0]),
                      "the break that MADE the page is the one that has work to do")
        XCTAssertFalse(honoured.contains(locations[1]),
                       "a break one empty paragraph below a page top would open a page holding " +
                       "nothing — HWP does not spend a sheet on it and neither may this reader")
    }

    /// The narrowing that keeps a real page: the moment anything glyph-bearing sits between two
    /// breaks, the second one is opening a page over CONTENT and must be honoured.
    func testABreakBelowRealTextIsHonoured() {
        let (storage, locations) = markedParagraphs([
            (text: "First page's body", breaks: false, section: 0),
            (text: "A heading", breaks: true, section: 0),
            (text: "Third page's body", breaks: true, section: 0)
        ])
        let honoured = PageBandLayoutDelegate.honouredPageBreaks(in: storage)

        XCTAssertEqual(honoured, Set(locations),
                       "every break whose page carries text must survive — suppressing one would " +
                       "run two pages of the document together")
    }

    /// 구역 나누기 can change the paper itself (invariant 73), and a section that never starts a page
    /// can never apply the paper it declares — so this one is honoured even over an empty paragraph.
    func testASectionBreakIsHonouredEvenAboveNothing() {
        let (storage, locations) = markedParagraphs([
            (text: "First page's body", breaks: false, section: 0),
            (text: "", breaks: true, section: 0),
            (text: "Landscape appendix", breaks: true, section: 1)
        ])
        let honoured = PageBandLayoutDelegate.honouredPageBreaks(in: storage)

        XCTAssertTrue(honoured.contains(locations[1]),
                      "a break that also begins a section must start a page whatever sits above it, " +
                      "or the section's own paper is never applied")
    }

    /// The document's opening is not a page a break abandoned: on the reference manual page 0's body
    /// is empty only because the cover's artwork is 바탕쪽 (invariant 78), and suppressing there
    /// folded the cover into the page after it.
    func testTheFirstBreakIsAlwaysHonoured() {
        let (storage, locations) = markedParagraphs([
            (text: "", breaks: false, section: 0),
            (text: "", breaks: true, section: 0)
        ])
        let honoured = PageBandLayoutDelegate.honouredPageBreaks(in: storage)

        XCTAssertEqual(honoured, Set(locations),
                       "the first marker has no preceding break to have abandoned a page")
    }
}
