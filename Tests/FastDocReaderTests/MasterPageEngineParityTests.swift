import XCTest
import AppKit
@testable import FastDocReader

/// The master page behind each sheet is the page plan's choice (`PlannedPage.master`, decided by
/// the engine's `plan_furniture` with the section veto). These pin the wiring from the plan to
/// `MasterPagePainter.draw`: the plan's answer is what is drawn, and a page outside the plan falls
/// back to `applicablePage` so the furniture still paints.
final class MasterPageEngineParityTests: XCTestCase {

    // MARK: - 1. The plan's per-sheet answer is what the painter is handed

    func testPlannedSelectionReadsThePlansMasterAndRefusesAPageOutsideThePlan() {
        let planned: [DocumentWindowController.PlannedPage] = [
            .init(section: 0, number: 1, hidesNumber: false, master: 2),
            .init(section: 0, number: 2, hidesNumber: false, master: nil),
            .init(section: 1, number: 3, hidesNumber: false, master: 0),
        ]
        let lookup: (Int) -> DocumentWindowController.PlannedPage? = {
            $0 >= 0 && $0 < planned.count ? planned[$0] : nil
        }
        let inside = MasterPagePainter.plannedSelection(
            [.init(pageIndex: 2, section: 1), .init(pageIndex: 0, section: 0), .init(pageIndex: 1, section: 0)],
            plannedPage: lookup)
        XCTAssertEqual(inside, [0, 2, nil], "each query gets its own page's planned master, nil kept as 'none'")
        XCTAssertNil(MasterPagePainter.plannedSelection(
            [.init(pageIndex: 0, section: 0), .init(pageIndex: 3, section: 1)], plannedPage: lookup),
            "a page the plan does not cover must hand the whole batch back to applicablePage")
    }

    func testThePlanParsesEachSheetsHeadFootAndMaster() {
        let plan: [String: Any] = ["pages": [
            ["section": 0, "number": 1, "header": 1, "footer": 0, "master": 3],
            ["section": 2, "number": 7, "numberHidden": true],
        ]]
        let pages = DocumentWindowController.PlannedPage.list(from: plan)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].header, 1)
        XCTAssertEqual(pages[0].footer, 0)
        XCTAssertEqual(pages[0].master, 3)
        XCTAssertNil(pages[1].header)
        XCTAssertNil(pages[1].footer)
        XCTAssertNil(pages[1].master)
        XCTAssertEqual(pages[1].section, 2)
        XCTAssertEqual(pages[1].number, 7)
        XCTAssertTrue(pages[1].hidesNumber)
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

        // `templateSelection` returning `nil` is what `plannedSelection` hands `draw` for a page
        // outside the plan: the fallback branch.
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
