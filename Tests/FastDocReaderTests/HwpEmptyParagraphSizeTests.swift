import XCTest
@testable import FastDocReader

/// A paragraph's percentage line height is measured against ITS OWN character size — including when
/// it has no characters.
///
/// HWP's 글자에 따라 N% is N% of the text's own size, which the reader already took from the
/// paragraph's runs. A paragraph with no runs has no size to take, and it fell back to the DOCUMENT's
/// default — which this document may never have stated, in which case the basis was a hardcoded 11pt
/// guess. Measured on `2025 행정업무운영 편람`: 808 of its 2,789 paragraphs are empty and 793 of those
/// carry no spans at all, and the file declares no default size — so 28% of the document was spaced
/// against a number nothing in it had ever said. Every paragraph has a char shape whether or not it
/// has text, so the export carries it (`baseSizePt`).
final class HwpEmptyParagraphSizeTests: XCTestCase {

    private func format(_ json: String) throws -> ParagraphFormat {
        let blocks = try HwpReader.mapJSON(
            "{\"v\":1,\"pageContentWidth\":396,\"pageContentHeight\":556,\"blocks\":[\(json)]}").blocks
        guard case .paragraph(_, _, _, _, let f) = try XCTUnwrap(blocks.first) else {
            throw XCTSkip("expected a paragraph")
        }
        return f
    }

    /// An EMPTY paragraph at 160% of its own 12pt is 19.2pt — not 160% of a default it never stated.
    func testAnEmptyParagraphIsSpacedAgainstItsOwnSize() throws {
        let f = try format("""
        {"t":"para","spans":[],"baseSizePt":12,"lineHeight":{"type":"percent","value":160}}
        """)
        guard case .atLeast(let pt) = try XCTUnwrap(f.lineHeight) else {
            return XCTFail("a percentage is a floor, never a fixed height")
        }
        XCTAssertEqual(pt, 12 * 1.6, accuracy: 0.01)
    }

    /// A paragraph WITH text still takes its basis from the runs — the largest one, as before. The new
    /// field must not take over a case that was already right.
    func testAParagraphWithRunsStillUsesItsLargestRun() throws {
        let f = try format("""
        {"t":"para","baseSizePt":9,"lineHeight":{"type":"percent","value":100},
         "spans":[{"text":"가","size":2000}]}
        """)
        guard case .atLeast(let pt) = try XCTUnwrap(f.lineHeight) else { return XCTFail("floor") }
        XCTAssertEqual(pt, 20, accuracy: 0.01, "the run's 20pt, not the paragraph's 9pt base")
    }

    /// A parser predating the field says nothing, and the reader falls back exactly as it did.
    func testWithNoBaseSizeTheOldFallbackStillApplies() throws {
        let f = try format("""
        {"t":"para","spans":[],"lineHeight":{"type":"percent","value":100}}
        """)
        guard case .atLeast(let pt) = try XCTUnwrap(f.lineHeight) else { return XCTFail("floor") }
        XCTAssertEqual(pt, 11, accuracy: 0.01, "the reader's own default, unchanged")
    }
}
