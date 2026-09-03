import XCTest
import AppKit
@testable import FastDocReader

/// Real-document confirmation of the running-header/footer EDGES fix (`PageBandReservationTests`'
/// new "§5 Edges" section covers the decision/geometry with synthetic fixtures; this is the same
/// claim against an actual docx, following this repo's own convention for a real document it does
/// not ship — see CLAUDE.md's `FMD_TABLE_PROBE`/`FMD_HWP_STYLE_PROBE` family. Skipped by default.
///
/// `FMD_HEADER_FOOTER_PROBE=<file>` — a real `.docx`, `.odt`, `.hwp` or `.hwpx` with a running header
/// and/or footer (the docx one used while diagnosing this bug was purpose-built: a short page, a
/// centred header, and a footer carrying a live `PAGE` field, with no `w:titlePg` — i.e. the header
/// legitimately applies to page 0 too). The three formats share one drawing path, so this probe takes
/// whichever it is given and dispatches exactly as the app does: it is the only thing that can say a
/// non-docx header reaches the screen, which a reader unit test cannot (invariant 29).
final class HeaderFooterRealFileProbeTests: XCTestCase {
    /// Pinned to the shape this probe's assertions were written against — the BAND mechanism, with no
    /// page outline. Not cosmetic: with the outline on (the shipped default) the first and last pages
    /// reserve their FULL margins rather than just the header's (invariant 60d), so `leadingBand` is
    /// `max(header, marginTop)` and the "a document whose cover has no header reserves nothing above
    /// it" arm below cannot hold. Found by running this probe on a real `.hwpx` whose only header is
    /// `evenPages`: it reserved 138.9pt where the assertion demanded 0, which is invariant 60d working
    /// correctly against an assertion that predates it. `PageBandReservationTests` pins the same shape
    /// for the same reason.
    override func setUp() {
        super.setUp()
        // The shipped shape, and the ONLY one that has page furniture at all: `header`, `footer`
        // and `separatesPages` are all `outline` now (`PageViewOptions`), so the state these
        // assertions were first written against — `outline: false, header: true, footer: true`,
        // furniture on and sheets off — no longer exists. Turning the pin off to recover the old
        // reservation rule turns the header and footer off with it and measures a band of zero.
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
    }

    /// The pin above is load-bearing, not setup noise: with the outline ON the first page reserves
    /// its FULL margin (invariant 60d), so "a cover with no header reserves nothing above it" is
    /// false by design rather than by defect. Asserting the pin keeps the next mechanical rewrite of
    /// `PageViewOptions` from turning these assertions into a report about the wrong mechanism.
    func testTheProbeIsPinnedToTheStateThatHasFurnitureAtAll() {
        XCTAssertTrue(PageViewOptionsStore.startingOptions.outline,
                      "one switch drives header, footer and sheets — off means nothing to measure")
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    func testRealDocumentReservesBothOuterEdges() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HEADER_FOOTER_PROBE"] else {
            throw XCTSkip("set FMD_HEADER_FOOTER_PROBE=<office file with a header/footer> to run this")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        // Parse directly first — cheap, and pins down what the fixture actually declares before
        // trusting the full production stack's own numbers to it. Through the SAME two-branch
        // dispatch `MarkdownDocument.read` uses, so a `.hwp` (CFB, not a zip) never reaches
        // `ZipArchive` (invariant 44).
        let ext = url.pathExtension
        // THROUGH THE ENGINE, because that is what the window below is drawing. This read used to
        // branch to `HwpReader.read` for a `.hwp` — the Swift reader, which `DocumentTypes` says in
        // its first line nothing in the app calls any more: it is the REFERENCE the engine is
        // checked against. So the probe was measuring one half of the app and asserting about the
        // other, and on the 편람 the two disagree exactly where it matters — the Swift reader hands
        // back a header and two footers, the engine drops them because they belong to a section the
        // body is not typeset on (invariant 77), and the probe then demanded a band for entries the
        // reader had correctly discarded. `resolvingFontSubstitution` is applied here for the same
        // reason: it is part of what `DocumentTypes.readOffice` returns to the app, and the band is
        // measured from the resolved fonts.
        guard let engineRead = RustEngine.readOffice(data, extension: ext) else {
            return XCTFail("the engine could not read \(url.lastPathComponent)")
        }
        let parsed: OfficeReadResult = engineRead.resolvingFontSubstitution()
        print("PROBE parsed: headers=\(parsed.headers.count) footers=\(parsed.footers.count) " +
              "pageContentHeight=\(String(describing: parsed.pageContentHeight))")
        for h in parsed.headers {
            print("PROBE header appliesTo=\(h.appliesTo) empty=\(h.blocks.isEmpty)")
        }
        for f in parsed.footers {
            print("PROBE footer appliesTo=\(f.appliesTo) empty=\(f.blocks.isEmpty)")
        }
        guard parsed.pageContentHeight != nil else {
            throw XCTSkip("fixture has no declared page height — not a paged document, nothing to reserve")
        }
        // "Has blocks" is NOT "has something to draw", and 26 of the 94 real HWP/HWPX documents that
        // declare a header or footer at all declare one made of nothing but empty paragraphs. Asking
        // the same question `PageBandGeometry` asks keeps this probe measuring the reader rather than
        // demanding a band the document never had anything to put in.
        func draws(_ e: OfficeHeaderFooter) -> Bool {
            PageBandGeometry.entryDraws(e, theme: RenderTheme.current(size: 11), columnWidth: 400,
                                        documentDefaultFontSize: parsed.defaultBodyFontSize,
                                        pageContentWidth: parsed.pageContentWidth)
        }
        let hasRealHeader = parsed.headers.contains(where: draws)
        let hasRealFooter = parsed.footers.contains(where: draws)
        guard hasRealHeader || hasRealFooter else {
            throw XCTSkip("fixture declares no non-empty header/footer — nothing for this probe to prove")
        }

        // Now the real end-to-end path: MarkdownDocument.read → makeWindowControllers, exactly the
        // seam `OfficeDocumentTests` already drives office fixtures through (invariant 29).
        let doc = MarkdownDocument()
        doc.fileURL = url          // this, not the UTI, is what `kind` and the reader branch read
        try doc.read(from: data, ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()

        print("PROBE wired: leadingBand=\(wc.pageBandDelegate.leadingBand) " +
              "trailingBand=\(wc.pageBandDelegate.trailingBand) band=\(wc.pageBandDelegate.band) " +
              "pageContentHeight=\(wc.pageBandDelegate.pageContentHeight)")

        // THE DEFECT, closed: a real header with no separate first-page entry reserves real leading
        // room; a real footer reserves real trailing room. (A fixture that DOES declare a blank
        // first-page header, or no footer, would legitimately show 0 on the corresponding side —
        // this probe only asserts the side(s) the fixture actually declared non-empty.)
        if hasRealHeader {
            // Three cases, and only the third reserves room. A document can carry a real header that
            // simply does not REACH page 0 — a `.hwp` whose only header is `evenPages` is the case
            // that found this, and treating "no entry applies" the same as "an entry applies and has
            // content" made the probe demand a band the document never asked for. Nil (nothing
            // applies) and empty (a deliberately blank cover, w:titlePg / style:header-first) are the
            // same answer to the reader: reserve nothing.
            let firstPageHeader = PageBandPainter.applicableEntry(parsed.headers, pageIndex: 0)
            let coverDrawsNothing = !(firstPageHeader.map(draws) ?? false)
            // The floor is the page's OWN top margin, not zero. Drawing sheets, the first and last
            // pages get their full margins (invariant 60d) — without it the first sheet begins one
            // margin above the view and shows no top edge at all. So "no header reaches page 0" no
            // longer means "reserve nothing"; it means the header adds NOTHING TO the margin, which
            // is the claim worth pinning and the one this arm now makes.
            let marginTop = parsed.pageMarginTop ?? 0
            if coverDrawsNothing {
                XCTAssertEqual(wc.pageBandDelegate.leadingBand, marginTop, accuracy: 0.5,
                               "no header reaches page 0 — the margin, and not one point more")
            } else {
                XCTAssertGreaterThan(wc.pageBandDelegate.leadingBand, 0,
                                     "a real header applying to page 0 must reserve room above the first line")
                let layout = try XCTUnwrap(wc.textView.layoutManager)
                let container = try XCTUnwrap(wc.textView.textContainer)
                layout.ensureLayout(for: container)
                var rects: [NSRect] = []
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in
                    rects.append(rect)
                }
                let firstLine = try XCTUnwrap(rects.first)
                XCTAssertEqual(firstLine.minY, wc.pageBandDelegate.leadingBand, accuracy: 0.5,
                               "the document's own first line must start exactly one leading band down")
            }
        }
        // Reserving room is only half the claim: the band must have something to PUT there. The
        // painter's own drawing is AppKit and format-neutral (`PageBandPainterTests` covers it), but
        // what it draws is whatever `OfficeTextBuilder` makes of THIS file's header blocks — so build
        // exactly what the painter would and assert real glyphs come out. This is the step a reader
        // unit test cannot reach: an .odt or .hwp header can parse into blocks that the builder then
        // turns into nothing at all, and the band would sit there empty with every test still green.
        for (label, entries) in [("header", parsed.headers), ("footer", parsed.footers)] {
            guard entries.contains(where: draws) else { continue }
            // The first three pages, not just the first: page 1 is exactly where a document puts its
            // DELIBERATELY blank cover band, so stopping there would report "draws nothing" for a
            // file whose real running header starts on page 2 — which is every .odt with a
            // `style:header-first` and every .docx with `w:titlePg`.
            var drewSomething = false
            for pageIndex in 0..<3 {
                guard let entry = PageBandPainter.applicableEntry(entries, pageIndex: pageIndex),
                      draws(entry) else { continue }
                let built = OfficeTextBuilder.build(entry.blocks, theme: RenderTheme.current(size: 11),
                                                    columnWidth: 400,
                                                    documentDefaultFontSize: parsed.defaultBodyFontSize,
                                                    pageContentWidth: parsed.pageContentWidth)
                let live = PageBandPainter.substitutingPageFields(built, page: pageIndex + 1, totalPages: 9)
                print("PROBE \(label) page \(pageIndex + 1) draws: \(live.string.debugDescription)")
                if live.string.contains(where: { !$0.isWhitespace }) { drewSomething = true }
            }
            XCTAssertTrue(drewSomething,
                          "this document declares a non-empty \(label), so one of its first three "
                          + "pages must build to real glyphs — an empty band is the silent failure")
        }

        if hasRealFooter {
            // Decision only here (the absolute-extent GEOMETRY proof — "the laid-out extent ends
            // exactly one trailing band past the last line" — is `PageBandReservationTests.
            // testTrailingFooterBandIsReservedBelowTheLastLine`'s job, against a synthetic document
            // whose render pipeline this probe does not fully replicate: a real `.docx` opened
            // through `MarkdownDocument.read` may already have run `precomputeLayout`'s own
            // `applyTrailingFooterBand` call once before this test manually calls it again, and
            // re-deriving that exact interleaving here would test this probe's own plumbing more
            // than the feature). What matters for THIS document is simply: is real room reserved.
            XCTAssertGreaterThan(wc.pageBandDelegate.trailingBand, 0,
                                 "a real footer must reserve room below the last line")
        }

        // ⌘P on this same real document. Printing goes through the SAME window controller a reader
        // uses, so a format whose page geometry parses differently (ODF measures its top margin to
        // the HEADER, not to the body) is caught here rather than on paper. Run to a FILE — no print
        // panel, no printer — so the page count and the paper are ordinary assertions.
        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        layout.ensureLayout(for: container)
        wc.applyTrailingFooterBand()
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-probe-print-\(UUID().uuidString).pdf")
        let op = wc.makePrintOperation()
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        // NOT the number ⌘P gives a reader, and reading it as one costs an afternoon. This probe
        // wires the band itself, with the SCREEN's `RenderTheme.pageDeskGap` still in it — the desk
        // you see between two sheets. The app's own print path passes `deskGap: 0`
        // (`MarkdownDocument`, `forPrinting`), which is what makes the pitch exactly one sheet:
        // measured on the 편람, 555.59 + (210.43 − 12) = 754.02, the paper to the point. So this
        // count runs high — 523 where `--pdf` and the screen both say 503 — and what the assertion
        // below is worth is the INTERNAL one: whatever this window paginated, the PDF has that many
        // pages. Parity with the screen belongs to `--pdf` (invariant 66), which has it.
        print("PROBE print pages=\(wc.printPageCount) (screen band, desk gap included — see above) " +
              "paper=\(op.printInfo.paperSize) " +
              "sheet0=\(wc.printSheets.first.map { "\($0)" } ?? "none")")
        XCTAssertTrue(op.run(), "⌘P must produce a job for this real document")
        defer { try? FileManager.default.removeItem(at: out) }
        let provider = try XCTUnwrap(CGDataProvider(data: try Data(contentsOf: out) as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        print("PROBE print pdfPages=\(pdf.numberOfPages) " +
              "box=\(try XCTUnwrap(pdf.page(at: 1)).getBoxRect(CGPDFBox.mediaBox))")
        XCTAssertEqual(pdf.numberOfPages, wc.printPageCount,
                       "the printout must have the same page count the reader itself reports")
    }
}
