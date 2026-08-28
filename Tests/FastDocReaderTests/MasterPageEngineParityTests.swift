import XCTest
import AppKit
@testable import FastDocReader

/// S5C3-05 — checks the wiring `ReaderTextView.drawMasterPages`'s `masterTemplateSelectionClosure`
/// now does, from `MasterPagePainter.draw`'s own side.
///
/// A value comparison alone cannot tell "the engine answered" from "the host's own `applicablePage`
/// answered and the two happened to agree" — S5C1's own finding: replacing the live call with
/// `nil` at the call site changed no number and passed the whole suite. So this file asserts BOTH
/// halves `s5c3.md`'s S5C3-05 item names:
///   1. the engine's answers equal the host's `applicablePage` answers for a real handle, across a
///      battery of pages, sections, an unknown section and a vetoed section (`testEngineAndHost…`);
///   2. the engine was actually the ONE asked — `RustOfficeDocumentHandle.answeredQueries`, the
///      same observable S5C1 used, and exactly one crossing for a whole batch of visible pages, not
///      one per page (`testTheDrawPassAsksTheEngineExactlyOnceForTheWholeVisibleBatch`).
/// Plus the fallback S5C-1 established for every engine query before this one: when the engine
/// cannot answer, the host answers instead and the furniture still draws
/// (`testWhenTheEngineCannotAnswerTheHostAnswersAndFurnitureStillDraws`).
final class MasterPageEngineParityTests: XCTestCase {

    // MARK: - A real handle, and the battery both answers are asked

    /// A real engine handle, opened on a small committed HWP fixture. Its OWN master pages are
    /// irrelevant to every test below: `fastdoc_office_master_selection`'s templates, pages and
    /// veto set are ALL caller-supplied (`s5c3.md`'s own API — "the engine never reads its own
    /// parse"), so any successfully-opened handle answers this export for any synthetic battery.
    private func openHandle() throws -> RustOfficeDocumentHandle {
        // FONTS only — opening a document needs the font world, not the measurer (a font-less
        // panic is `read_office`'s own precondition, per `RustEngineBridgeTests`' own comment).
        // `fastdoc_office_master_selection` is pure integer arithmetic over caller-supplied
        // buffers and touches neither global, so installing the measurer here would needlessly
        // poison `RustEngineBridgeTests`' one-shot "measurer never installed" precondition, which
        // can only be observed once per PROCESS and depends on running before ANY test installs it.
        RustEngineFonts.install()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/rhwp-src/saved/blank2010.hwp")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(RustOfficeDocumentHandle(data: data, extension: "hwp"),
                             "blank2010.hwp must open through the engine")
    }

    /// Three templates spanning two sections and every `HeaderFooterApplicability` case a master
    /// page can carry, plus section 3 vetoed — the shape `applicablePage`'s own five branches need
    /// (section filter, even/odd parity, `nil`-section fallback, empty-candidates, veto).
    private func templates() -> [OfficeMasterPage] {
        func page(_ section: Int, _ appliesTo: HeaderFooterApplicability) -> OfficeMasterPage {
            OfficeMasterPage(section: section, appliesTo: appliesTo, objects: [])
        }
        return [
            page(1, .defaultPages),
            page(1, .evenPages),
            page(2, .defaultPages),
        ]
    }

    /// A battery covering: section 1 odd (its default template), section 1 even (its even
    /// template), section 2 (its only template, any parity), an unknown section on an even page
    /// number (`nil` — falls back to every template, so parity still picks section 1's even
    /// template out of the whole set), and section 3 (declared no template of its own AND vetoed —
    /// `applicablePage`'s empty-candidates guard and the veto both answer "none" here).
    private func battery() -> [MasterPageSelectionQuery] {
        [
            MasterPageSelectionQuery(pageIndex: 0, section: 1),   // odd page number, section 1
            MasterPageSelectionQuery(pageIndex: 1, section: 1),   // even page number, section 1
            MasterPageSelectionQuery(pageIndex: 2, section: 2),
            MasterPageSelectionQuery(pageIndex: 3, section: nil),
            MasterPageSelectionQuery(pageIndex: 4, section: 3),
        ]
    }

    // MARK: - 1. Values agree

    func testEngineAndHostAgreeAcrossSectionsParityAndAVetoedSection() throws {
        let handle = try openHandle()
        let templates = templates()
        let vetoed: Set<Int> = [3]

        let hostAnswers = battery().map { query in
            MasterPagePainter.applicablePage(templates, pageIndex: query.pageIndex, section: query.section)
                .flatMap { templates.firstIndex(of: $0) }
        }
        let engineAnswers = try XCTUnwrap(handle.masterTemplateSelection(
            templates: templates, vetoedSections: vetoed,
            pages: battery().map { ($0.pageIndex, $0.section) }),
            "the engine must answer a well-formed batch")

        XCTAssertEqual(engineAnswers, hostAnswers,
                       "the engine's per-page template index must match applicablePage's own, "
                       + "including the vetoed page (host applicablePage does not itself veto — "
                       + "section 3 has no candidates of its own either way, so both read none)")
    }

    // MARK: - 2. The engine was actually asked, and only once for the whole batch

    func testTheDrawPassAsksTheEngineExactlyOnceForTheWholeVisibleBatch() throws {
        let handle = try openHandle()
        let content = MasterPageContent(pages: templates(), sectionsHidingMasterPage: [3],
                                        theme: RenderTheme(baseFontSize: 13),
                                        documentDefaultFontSize: 11, pageContentWidth: 80)
        let sheets = (0..<5).map { CGRect(x: 0, y: CGFloat($0) * 120, width: 80, height: 100) }
        let sections: [Int: Int] = [0: 1, 1: 1, 2: 2, 4: 3]   // page 3 left unknown, on purpose

        // Captured BEFORE this test asks the handle anything itself — otherwise the count below
        // includes this test's OWN setup rather than only what the draw pass asked.
        let before = handle.answeredQueries

        withOffscreenBitmap(width: 100, height: 700) {
            MasterPagePainter.draw(content, sheets: sheets, totalPages: sheets.count,
                                   visibleRect: NSRect(x: 0, y: 0, width: 100, height: 700),
                                   sectionOfPage: { sections[$0] },
                                   templateSelection: { queries in
                                       handle.masterTemplateSelection(
                                           templates: content.pages,
                                           vetoedSections: content.sectionsHidingMasterPage,
                                           pages: queries.map { ($0.pageIndex, $0.section) })
                                   })
        }

        // ONE crossing for a whole draw pass over FIVE visible pages, not one per page — the shape
        // `s5c3.md`'s API section requires ("one crossing per page at scroll frequency is the shape
        // this plan rejected twice"). Page 4 (section 3) is vetoed before either answer is asked
        // (`MasterPagePainter.draw`'s own gather pass), so the batch the engine actually sees is 4
        // pages, still ONE call.
        XCTAssertEqual(handle.answeredQueries, before + 1,
                       "the draw pass must ask the engine exactly once, batching every visible page")
    }

    // MARK: - 3. Fallback: the engine cannot answer, the host answers, furniture still draws

    func testWhenTheEngineCannotAnswerTheHostAnswersAndFurnitureStillDraws() throws {
        let object = OfficeMasterObject(frame: CGRect(x: 0, y: 0, width: 60, height: 60),
                                        content: .image(blackSquare(size: NSSize(width: 60, height: 60))))
        let page = OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [object])
        let content = MasterPageContent(pages: [page], sectionsHidingMasterPage: [],
                                        theme: RenderTheme(baseFontSize: 13),
                                        documentDefaultFontSize: 11, pageContentWidth: 80)
        let sheet = CGRect(x: 10, y: 10, width: 80, height: 100)

        // `templateSelection` returning `nil` is exactly what a failed engine call would hand
        // `draw` (`RustOfficeDocumentHandle.masterTemplateSelection`'s own documented failure
        // return) — this is `draw`'s fallback branch, exercised directly rather than through a
        // manufactured FFI failure, matching S5C-1's own "the same failure direction" rule.
        let drew = withOffscreenBitmap(width: 100, height: 120) {
            MasterPagePainter.draw(content, sheets: [sheet], totalPages: 1,
                                   visibleRect: NSRect(x: 0, y: 0, width: 100, height: 120),
                                   sectionOfPage: { _ in 1 },
                                   templateSelection: { _ in nil })
        }

        XCTAssertTrue(inkAt(drew, x: 40, y: 40),
                      "the engine could not answer — the host's own applicablePage must have "
                      + "answered instead, and the page's furniture must still have painted")
    }

    // MARK: - 4. The answer is not merely asked for — it DECIDES what is drawn

    /// The gap the other three leave open, found by mutation: making `draw` call the engine and
    /// then IGNORE its reply (`offset < engineAnswers.count` → `offset < 0`) passed all of them.
    /// Call-count proves the engine was ASKED; values agreeing proves the two implementations
    /// agree. Neither proves the engine's answer is the one that reached the page — a wiring that
    /// silently discarded it would read as fully engine-backed.
    ///
    /// So: hand `draw` an answer the host would NEVER give, and require the ink to follow it.
    /// Section 1's default template is index 0, which is what `applicablePage` picks for page 0;
    /// this closure says index 1 instead, and only the engine's reply can put the square on the
    /// right-hand side of the sheet.
    func testTheSelectionAnswerDecidesWhichTemplateIsDrawn() throws {
        func square(atX x: CGFloat) -> OfficeMasterObject {
            OfficeMasterObject(frame: CGRect(x: x, y: 0, width: 20, height: 20),
                               content: .image(blackSquare(size: NSSize(width: 20, height: 20))))
        }
        // Both templates are section 1 `.defaultPages`, so `applicablePage` can only ever pick the
        // FIRST — the host has no way to reach index 1 for this page.
        let pages = [
            OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [square(atX: 0)]),
            OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [square(atX: 50)]),
        ]
        let content = MasterPageContent(pages: pages, sectionsHidingMasterPage: [],
                                        theme: RenderTheme(baseFontSize: 13),
                                        documentDefaultFontSize: 11, pageContentWidth: 80)
        let sheet = CGRect(x: 0, y: 0, width: 80, height: 40)

        XCTAssertEqual(MasterPagePainter.applicablePage(pages, pageIndex: 0, section: 1), pages[0],
                       "precondition: the host answers template 0 here, so template 1 can only "
                       + "have come from the selection reply")

        let drew = withOffscreenBitmap(width: 80, height: 40) {
            MasterPagePainter.draw(content, sheets: [sheet], totalPages: 1,
                                   visibleRect: NSRect(x: 0, y: 0, width: 80, height: 40),
                                   sectionOfPage: { _ in 1 },
                                   templateSelection: { _ in [1] })
        }

        XCTAssertTrue(inkAt(drew, x: 60, y: 10),
                      "the reply named template 1, whose square sits on the right — the drawn page "
                      + "must follow the reply, not the host's own answer")
        XCTAssertFalse(inkAt(drew, x: 10, y: 10),
                       "template 0's square must NOT be on the page: drawing it means the reply "
                       + "was discarded and the host answered")
    }

    // MARK: - Small offscreen-draw harness, the same flipped-CTM shape `MasterPageSectionVetoTests` uses

    private func blackSquare(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    @discardableResult
    private func withOffscreenBitmap(width: Int, height: Int, _ body: () -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(height))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        body()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func inkAt(_ rep: NSBitmapImageRep?, x: Int, y: Int) -> Bool {
        guard let colour = rep?.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return colour.redComponent < 0.5 && colour.greenComponent < 0.5 && colour.blueComponent < 0.5
    }
}
