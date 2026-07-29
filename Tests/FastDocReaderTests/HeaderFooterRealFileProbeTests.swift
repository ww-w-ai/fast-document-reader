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
        let parsed: OfficeReadResult = DocumentTypes.isHwp(ext)
            ? try HwpReader.read(data)
            : try DocumentTypes.readOffice(try ZipArchive(data: data), extension: ext)
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
        let hasRealHeader = parsed.headers.contains { !$0.blocks.isEmpty }
        let hasRealFooter = parsed.footers.contains { !$0.blocks.isEmpty }
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
            let coverDrawsNothing = firstPageHeader?.blocks.isEmpty ?? true
            if coverDrawsNothing {
                XCTAssertEqual(wc.pageBandDelegate.leadingBand, 0,
                               "no header reaches page 0 (absent or blank) — must reserve nothing above it")
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
            guard entries.contains(where: { !$0.blocks.isEmpty }) else { continue }
            // The first three pages, not just the first: page 1 is exactly where a document puts its
            // DELIBERATELY blank cover band, so stopping there would report "draws nothing" for a
            // file whose real running header starts on page 2 — which is every .odt with a
            // `style:header-first` and every .docx with `w:titlePg`.
            var drewSomething = false
            for pageIndex in 0..<3 {
                guard let entry = PageBandPainter.applicableEntry(entries, pageIndex: pageIndex),
                      !entry.blocks.isEmpty else { continue }
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
    }
}
