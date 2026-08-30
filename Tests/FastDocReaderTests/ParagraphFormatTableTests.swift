import XCTest
@testable import FastDocReader

/// The host half of the paragraph-format pooling (invariant 133). The engine writes each distinct
/// format once and leaves a slot at every use; this is the resolution that turns a slot back into a
/// format while the document decodes.
///
/// It differs from `EdgeBorderTableTests` in one way that matters: "neither" is not an error and not
/// a `nil` — a paragraph that declared nothing has a DEFAULT format, and the wire now omits the key
/// entirely for it rather than writing an empty object per block.
final class ParagraphFormatTableTests: XCTestCase {
    private func spaced(_ before: CGFloat) -> ParagraphFormat {
        var format = ParagraphFormat()
        format.spacingBefore = before
        return format
    }

    func testAnInlineFormatWinsAndASlotIsLookedUp() throws {
        let table = [spaced(6), spaced(12)]
        try ParagraphFormatTable.withPool(table) {
            // The wire never sends both, but if it did, the value in hand is the honest answer.
            XCTAssertEqual(try ParagraphFormatTable.resolve(spaced(6), ref: 1), spaced(6))
            XCTAssertEqual(try ParagraphFormatTable.resolve(nil, ref: 0), table[0])
            XCTAssertEqual(try ParagraphFormatTable.resolve(nil, ref: 1), table[1])
        }
    }

    /// Neither a format nor a slot means the paragraph declared nothing — the state a default
    /// `ParagraphFormat` renders byte-identically to, and the reason the key can leave the wire at
    /// all. This is the case that separates this table from the edge-border one, where "neither" is
    /// a distinct third state the vocabulary has to keep (invariant 47).
    func testNeitherMeansTheParagraphDeclaredNothing() throws {
        try ParagraphFormatTable.withPool([spaced(6)]) {
            XCTAssertEqual(try ParagraphFormatTable.resolve(nil, ref: nil), ParagraphFormat())
        }
    }

    /// A slot the table cannot answer must THROW. Returning the default would spell "this paragraph
    /// declared nothing", so a truncated envelope would render as a document whose spacing and
    /// indents quietly vanished — indistinguishable from a document that never had any.
    func testASlotOutsideTheTableIsAnError() {
        try? ParagraphFormatTable.withPool([spaced(6)]) {
            XCTAssertThrowsError(try ParagraphFormatTable.resolve(nil, ref: 1))
            XCTAssertThrowsError(try ParagraphFormatTable.resolve(nil, ref: -1))
        }
    }

    /// The pool is scoped to one decode. A slot resolved outside one is a bug, not a fallback.
    func testThereIsNoPoolOutsideADecode() {
        XCTAssertTrue(ParagraphFormatTable.pool.isEmpty)
        XCTAssertThrowsError(try ParagraphFormatTable.resolve(nil, ref: 0))
    }
}
