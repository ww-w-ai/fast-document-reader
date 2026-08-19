import XCTest
@testable import FastDocReader

/// A PAGE THAT RESERVES A NOTE BAND IS A SHORTER PAGE, AND THE TABLE RULES HAVE TO KNOW.
///
/// `PageBandLayoutDelegate.textBottom` was written because three layout rules each held their own
/// copy of `page × pitch + pageContentHeight` and a note band made that number vary per page — "three
/// chances to disagree about where a page ends, which shows up as a line drawn over a footnote rather
/// than as a failed check". The table PAGINATION rules were a fourth copy nobody moved, and they went
/// on asking the flat number.
///
/// MEASURED on a 30-note fiscal report (`samples/2010-01-06.hwp`): every sheet carries a table of
/// ~686pt and a five-note band of 286pt on a body of 700pt. Judged against the whole body each table
/// "fitted", so none was registered to move — and sheet 3's table was drawn to y=802 of an 841.9pt
/// sheet, interleaved line for line with the four note lines beneath it. Notes drawn: 27 of 30.
/// With the rules below sharing one definition of where a page ends: **30 of 30**, and no sheet
/// overruns. Across all 31 footnote-citing documents in the corpus: notes drawn 449 → 454, pages
/// whose content ran off the sheet 47 → 39, and not one document got worse.
///
/// The other half of the same defect was an ORDERING one, and it is asserted here too by the
/// property that makes it impossible to reintroduce silently: a table settled before any band exists
/// is settled against a page that is about to shrink.
final class PagedTableNoteBandTests: XCTestCase {

    /// Page 0's text runs 0…100, page 1's 120…220 — the same geometry `PagedTableOverrunTests` uses,
    /// so the two files' numbers can be read against each other.
    private let pageContentHeight: CGFloat = 100
    private let band: CGFloat = 20
    private let leadingBand: CGFloat = 0

    private func decide(_ tables: [PagePagination.LaidOutTable],
                        noteBands: [Int: CGFloat]) -> [Int: PagePagination.TableMetrics] {
        PagePagination.tablesToPush(tables, pageContentHeight: pageContentHeight, band: band,
                                    leadingBand: leadingBand, noteBands: noteBands)
    }

    // MARK: - One definition of where a page ends

    /// A document that cites no footnote must get the number it got before any of this existed. This
    /// is what keeps the other 626 corpus documents provably unaffected by the change.
    func testWithoutNotesThePageEndsExactlyWhereItAlwaysDid() {
        for page in 0...3 {
            let p = CGFloat(page)
            XCTAssertEqual(PagePagination.textBottom(ofPage: p, pageContentHeight: pageContentHeight,
                                                     band: band, noteBands: [:]),
                           p * (pageContentHeight + band) + pageContentHeight, accuracy: 0.0001)
            XCTAssertEqual(PagePagination.bodyHeight(ofPage: p, pageContentHeight: pageContentHeight,
                                                     noteBands: [:]),
                           pageContentHeight, accuracy: 0.0001)
        }
    }

    /// The band comes off the page it is reserved on, and off no other.
    func testABandShortensOnlyItsOwnPage() {
        let bands: [Int: CGFloat] = [1: 40]
        XCTAssertEqual(PagePagination.textBottom(ofPage: 0, pageContentHeight: pageContentHeight,
                                                 band: band, noteBands: bands),
                       100, accuracy: 0.0001)
        XCTAssertEqual(PagePagination.textBottom(ofPage: 1, pageContentHeight: pageContentHeight,
                                                 band: band, noteBands: bands),
                       180, accuracy: 0.0001)   // 120 + 100 − 40
        XCTAssertEqual(PagePagination.bodyHeight(ofPage: 1, pageContentHeight: pageContentHeight,
                                                 noteBands: bands), 60, accuracy: 0.0001)
    }

    /// THE PROPERTY THIS FILE EXISTS FOR: the layout rule and the pagination rules must answer this
    /// question identically. They are two call sites of one function now; this fails the moment
    /// someone re-inlines either of them.
    func testTheLayoutRuleAndThePaginationRuleAgreeExactly() {
        let delegate = PageBandLayoutDelegate(pageContentHeight: pageContentHeight, band: band,
                                              leadingBand: leadingBand)
        delegate.noteBands = [0: 37.5, 2: 12]
        for page in 0...3 {
            let p = CGFloat(page)
            XCTAssertEqual(delegate.textBottom(ofPage: p),
                           PagePagination.textBottom(ofPage: p, pageContentHeight: pageContentHeight,
                                                     band: band, noteBands: delegate.noteBands),
                           accuracy: 0.0001, "page \(page)")
        }
    }

    // MARK: - The decision the defect was hiding in

    /// The exact shape of the reported sheet: a table that fits the WHOLE page and does not fit the
    /// body a note band leaves it. Before, this table was declared to fit and left where it stood —
    /// which is a table drawn over its own footnotes.
    func testATableThatFitsTheSheetButNotTheBandIsMoved() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 10, bottom: 80, firstLineTop: 10)
        XCTAssertNotNil(decide([t], noteBands: [0: 40])[10],
                        "70pt of table into the 60pt a 40pt band leaves must be moved")
    }

    /// …and the band is what decided it. The identical table on a page reserving nothing stays put,
    /// so this pair cannot both pass unless the band is actually being read.
    func testTheSameTableWithNoBandStaysWhereItIs() {
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 10, bottom: 80, firstLineTop: 10)
        XCTAssertTrue(decide([t], noteBands: [:]).isEmpty,
                      "70pt of table into a 100pt page fits, and nothing may move it")
    }

    /// A table is CARRIED to the next page, so whether it can be carried is a question about THAT
    /// page. When every page reserves the same band there is nowhere to carry it to, and moving it
    /// on would march it one sheet per round until the settle's cap stopped it — it is broken where
    /// it stands instead.
    func testATableThatFitsNoLandingPageIsNotCarried() {
        let rows = (0..<4).map { i -> PagePagination.LaidOutRow in
            let y = CGFloat(10 + i * 18)
            return PagePagination.LaidOutRow(firstChar: 100 + i, top: y, bottom: y + 18,
                                             firstLineTop: y, canBreakAbove: true)
        }
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 10, bottom: 82,
                                            firstLineTop: 10, lastChar: 200, rows: rows)
        // Page 0 and page 1 both reserve 40 of their 100, so 72pt of table fits neither.
        XCTAssertNil(decide([t], noteBands: [0: 40, 1: 40])[10],
                     "carrying a table onto a page that cannot hold it either is not a move")
    }

    // MARK: - Broken in place, judged against the body the page actually offers

    /// `oversizedPieces` asks "is this taller than a page". With a band on that page the honest
    /// answer changes, and it is the answer that decides whether the rows may be broken at all.
    func testAPieceIsOversizedAgainstTheBodyItsPageOffers() {
        let rows = (0..<4).map { i -> PagePagination.LaidOutRow in
            let y = CGFloat(10 + i * 18)
            return PagePagination.LaidOutRow(firstChar: 100 + i, top: y, bottom: y + 18,
                                             firstLineTop: y, canBreakAbove: true)
        }
        let t = PagePagination.LaidOutTable(firstChar: 10, visualTop: 10, bottom: 82,
                                            firstLineTop: 10, lastChar: 200, rows: rows)
        let withBand = PagePagination.oversizedPieces([t], pageContentHeight: pageContentHeight,
                                                      band: band, leadingBand: leadingBand,
                                                      noteBands: [0: 40])
        XCTAssertFalse(withBand.isEmpty,
                       "72pt of table into the 60pt a band leaves is over-tall for that page")
        let without = PagePagination.oversizedPieces([t], pageContentHeight: pageContentHeight,
                                                     band: band, leadingBand: leadingBand,
                                                     noteBands: [:])
        XCTAssertTrue(without.isEmpty,
                      "the same table on a page reserving nothing fits, and nothing may break it")
    }

    /// The default arguments are the old signature, and they must still mean the old thing — this is
    /// what every existing caller and test in the repo is relying on.
    func testTheOldSignatureStillMeansWhatItMeant() {
        let rows = (0..<3).map { i -> PagePagination.LaidOutRow in
            let y = CGFloat(0 + i * 60)
            return PagePagination.LaidOutRow(firstChar: 100 + i, top: y, bottom: y + 60,
                                             firstLineTop: y, canBreakAbove: true)
        }
        let tall = PagePagination.LaidOutTable(firstChar: 10, visualTop: 0, bottom: 180,
                                               firstLineTop: 0, lastChar: 200, rows: rows)
        XCTAssertEqual(PagePagination.oversizedPieces([tall], pageContentHeight: pageContentHeight),
                       PagePagination.oversizedPieces([tall], pageContentHeight: pageContentHeight,
                                                      band: band, leadingBand: leadingBand,
                                                      noteBands: [:]))
    }
}
