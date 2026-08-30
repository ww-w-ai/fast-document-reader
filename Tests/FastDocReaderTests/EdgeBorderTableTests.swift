import XCTest
@testable import FastDocReader

/// The host half of P4b's edge-border pooling (invariant 129). The engine writes each distinct
/// per-edge declaration once and leaves a slot at every use; this is the resolution that turns a
/// slot back into borders while the document decodes.
final class EdgeBorderTableTests: XCTestCase {
    private func borders(_ top: BorderDecl?) -> EdgeBorders {
        EdgeBorders(top: top, left: nil, bottom: nil, right: nil)
    }

    func testAnInlineDeclarationWinsAndASlotIsLookedUp() throws {
        let table = [borders(.suppressed), borders(.drawn(BorderSide(width: 1, color: .black)))]
        try EdgeBorderTable.withPool(table) {
            // The wire never sends both, but if it did, the value in hand is the honest answer.
            XCTAssertEqual(try EdgeBorderTable.resolve(borders(.suppressed), ref: 1),
                           borders(.suppressed))
            XCTAssertEqual(try EdgeBorderTable.resolve(nil, ref: 0), table[0])
            XCTAssertEqual(try EdgeBorderTable.resolve(nil, ref: 1), table[1])
            // Neither: the cell said nothing per-edge, which is a real state (invariant 47).
            XCTAssertNil(try EdgeBorderTable.resolve(nil, ref: nil))
        }
    }

    /// A slot the table cannot answer must THROW. Returning nil would spell "this cell declared no
    /// edges", so a truncated envelope would render as a document whose borders are quietly gone —
    /// the exact confusion invariant 47 exists to keep out of this vocabulary.
    func testASlotOutsideTheTableIsAnError() {
        try? EdgeBorderTable.withPool([borders(.suppressed)]) {
            XCTAssertThrowsError(try EdgeBorderTable.resolve(nil, ref: 1))
            XCTAssertThrowsError(try EdgeBorderTable.resolve(nil, ref: -1))
        }
    }

    /// The pool is scoped to one decode. A slot resolved outside one is a bug, not a fallback.
    func testThereIsNoPoolOutsideADecode() {
        XCTAssertTrue(EdgeBorderTable.pool.isEmpty)
        XCTAssertThrowsError(try EdgeBorderTable.resolve(nil, ref: 0))
    }
}
