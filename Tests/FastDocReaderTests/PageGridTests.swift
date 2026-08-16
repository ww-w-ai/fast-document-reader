import XCTest
@testable import FastDocReader

/// The page table that replaces "a page is `k · pitch`".
///
/// Every office format defines a page per SECTION, and this reader takes one geometry for the whole
/// document (invariant 73). Measured on `2025 행정업무운영 편람`: 14 sections, 5 distinct geometries,
/// with the appendix declaring 612.3pt of body height against the 555.6 it is being given.
final class PageGridTests: XCTestCase {

    private func paper(_ height: CGFloat, width: CGFloat = 396.86) -> PaperGeometry {
        PaperGeometry(contentWidth: width, contentHeight: height,
                      marginLeft: 73.7, marginTop: 110.6, marginRight: 86.2, marginBottom: 87.9)
    }

    private let band: CGFloat = 20

    // MARK: it is the old rule when the document has one paper

    /// The whole reason the two can live side by side: for a document that declares one geometry the
    /// table must produce exactly the strips the scalar produces, page for page.
    func testAUniformDocumentReproducesTheScalarPitchExactly() {
        let body = paper(555.59)
        let pitch = PagePagination.pitch(pageContentHeight: body.contentHeight, band: band)
        let grid = PageGrid.build(pageCount: 5, band: band, documentPaper: body,
                                  sections: [OfficeSectionDeclaration(paper: body)],
                                  sectionOfPage: { _ in 0 })
        XCTAssertTrue(grid.isUniform)
        for page in 0..<5 {
            XCTAssertEqual(grid.textTop(ofPage: page), CGFloat(page) * pitch, accuracy: 0.001,
                           "page \(page) must sit where the scalar rule puts it")
        }
    }

    /// A section that declared no paper of its own falls back to the document's — the answer the
    /// reader gives today, which a page table must not change.
    func testASectionWithNoPaperOfItsOwnUsesTheDocumentPaper() {
        let grid = PageGrid.build(pageCount: 2, band: band, documentPaper: paper(555.59),
                                  sections: [OfficeSectionDeclaration()],
                                  sectionOfPage: { _ in 0 })
        XCTAssertEqual(grid.pages[0].paper.contentHeight, 555.59, accuracy: 0.001)
        XCTAssertTrue(grid.isUniform)
    }

    // MARK: it is a different rule when the document has more than one

    /// The 편람's own shape: body pages at 555.59, appendix pages at 612.32. Each page must occupy
    /// its OWN height, so the appendix stops being given 56.7pt less than it declares.
    func testEachPageOccupiesItsOwnSectionsHeight() {
        let body = paper(555.59)
        let appendix = paper(612.32, width: 413.87)
        // Pages 0–1 are body, pages 2–3 appendix.
        let grid = PageGrid.build(pageCount: 4, band: band, documentPaper: body,
                                  sections: [OfficeSectionDeclaration(paper: body),
                                             OfficeSectionDeclaration(paper: appendix)],
                                  sectionOfPage: { $0 < 2 ? 0 : 1 })
        XCTAssertFalse(grid.isUniform)
        let bodyPitch = 555.59 + band
        let appendixPitch = 612.32 + band
        XCTAssertEqual(grid.textTop(ofPage: 0), 0, accuracy: 0.001)
        XCTAssertEqual(grid.textTop(ofPage: 1), bodyPitch, accuracy: 0.001)
        XCTAssertEqual(grid.textTop(ofPage: 2), 2 * bodyPitch, accuracy: 0.001)
        // The appendix page is TALLER, so the page after it starts further down than the scalar rule
        // would put it — this is the whole difference, in one number.
        XCTAssertEqual(grid.textTop(ofPage: 3), 2 * bodyPitch + appendixPitch, accuracy: 0.001)
        XCTAssertEqual(grid.textTop(ofPage: 3) - grid.textTop(ofPage: 2), appendixPitch, accuracy: 0.001)
        XCTAssertGreaterThan(grid.textTop(ofPage: 3), 3 * bodyPitch,
                             "a uniform grid would have put page 3 here, 56.7pt too high")
        // The width the section declared is CARRIED even though one container cannot honour it.
        XCTAssertEqual(grid.pages[3].paper.contentWidth, 413.87, accuracy: 0.001)
        XCTAssertEqual(grid.pages[3].section, 1)
    }

    // MARK: the inverse lookup

    func testAPointFindsThePageItFallsOn() {
        let body = paper(555.59)
        let appendix = paper(612.32)
        let grid = PageGrid.build(pageCount: 3, band: band, documentPaper: body,
                                  sections: [OfficeSectionDeclaration(paper: body),
                                             OfficeSectionDeclaration(paper: appendix)],
                                  sectionOfPage: { $0 == 0 ? 0 : 1 })
        XCTAssertEqual(grid.page(containing: 0), 0)
        XCTAssertEqual(grid.page(containing: 100), 0)
        // One point below page 0's bottom is page 1, and one point above it is still page 0.
        let firstBottom = grid.pages[0].pitch
        XCTAssertEqual(grid.page(containing: firstBottom - 0.5), 0)
        XCTAssertEqual(grid.page(containing: firstBottom + 0.5), 1)
        XCTAssertEqual(grid.page(containing: grid.textTop(ofPage: 2) + 1), 2)
        // Round-trip: every page's own top lands on that page.
        for page in 0..<grid.count {
            XCTAssertEqual(grid.page(containing: grid.textTop(ofPage: page) + 1), page)
        }
    }

    /// Printing walks off the end of a document, and asking past the last page must answer where the
    /// next sheet WOULD start rather than folding back onto the last one.
    func testAskingPastTheEndExtendsTheLastPage() {
        let body = paper(555.59)
        let grid = PageGrid.build(pageCount: 2, band: band, documentPaper: body,
                                  sections: [], sectionOfPage: { _ in nil })
        let pitch = 555.59 + band
        XCTAssertEqual(grid.textTop(ofPage: 2), 2 * pitch, accuracy: 0.001)
        XCTAssertEqual(grid.textTop(ofPage: 4), 4 * pitch, accuracy: 0.001)
    }

    func testAnEmptyDocumentHasNoPagesAndAnswersZero() {
        let grid = PageGrid.build(pageCount: 0, band: band, documentPaper: paper(555.59),
                                  sections: [], sectionOfPage: { _ in nil })
        XCTAssertEqual(grid.count, 0)
        XCTAssertEqual(grid.textTop(ofPage: 3), 0)
        XCTAssertEqual(grid.page(containing: 999), 0)
        XCTAssertTrue(grid.isUniform)
    }
}
