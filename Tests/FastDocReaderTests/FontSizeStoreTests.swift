import XCTest
@testable import FastDocReader

/// `FontSizeStore` now holds only what's genuinely global — the default, the clamp, the step — not
/// a mutable size. The size itself moved to `MarkdownDocument.readingSize`; per-document behaviour
/// (isolation between documents, a fresh document opening at the default regardless of another
/// open document's size) is covered in `PerDocumentFontSizeTests`, which asserts on RENDERED output
/// rather than on these pure functions.
final class FontSizeStoreTests: XCTestCase {
    func testDefaultIs16() { XCTAssertEqual(FontSizeStore.defaultSize, 16) }   // Notion base size

    func testIncreasedStepsByOne() {
        XCTAssertEqual(FontSizeStore.increased(from: 16), 17)
    }

    func testDecreasedStepsByOne() {
        XCTAssertEqual(FontSizeStore.decreased(from: 16), 15)
    }

    func testClampUpper() {
        XCTAssertEqual(FontSizeStore.clamped(100), 36)
    }

    func testClampLower() {
        XCTAssertEqual(FontSizeStore.clamped(1), 10)
    }

    func testIncreasedClampsAtTheUpperBound() {
        XCTAssertEqual(FontSizeStore.increased(from: 36), 36)
    }

    func testDecreasedClampsAtTheLowerBound() {
        XCTAssertEqual(FontSizeStore.decreased(from: 10), 10)
    }
}
