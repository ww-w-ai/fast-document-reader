import XCTest
@testable import FastDocReader

final class HwpReaderTests: XCTestCase {
    // Link smoke (S2): the rhwp FFI symbols must resolve — this test failing to
    // COMPILE/LINK is the signal that the xcframework isn't wired. Empty input must
    // return nil (null handle) without crashing.
    func testEmptyInputReturnsNil() {
        XCTAssertNil(HwpReader.exportDocumentJSON(Data()))
    }

    // Real-parse smoke, gated on a sample path — the repo ships no HWP fixture yet
    // (a licensed sample corpus lands in S7). Point FMD_HWP_SAMPLE at a .hwp/.hwpx.
    func testRealSampleParsesWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_SAMPLE"] else {
            throw XCTSkip("Set FMD_HWP_SAMPLE to a .hwp/.hwpx path to run this")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try XCTUnwrap(HwpReader.exportDocumentJSON(data))
        XCTAssertTrue(json.contains("\"v\":1"), "expected structured JSON envelope")
        XCTAssertTrue(json.contains("\"blocks\""), "expected blocks array")
    }

    // End-to-end default-body-size, gated on a sample path. Proves the WHOLE chain the pure
    // `HwpMappingTests` can't reach: real bytes → rhwp FFI (the freshly vendored binary) → envelope
    // `defaultFontSizePt` → `result.defaultBodyFontSize`. Point FMD_HWP_SAMPLE at a .hwp/.hwpx; a
    // document declaring its own body size surfaces a positive value (para-001.hwp → 10pt), never a
    // hardcoded 11. Optionally assert an exact expected value via FMD_HWP_EXPECT_PT.
    func testRealSampleSurfacesDefaultBodyFontSize() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_SAMPLE"] else {
            throw XCTSkip("Set FMD_HWP_SAMPLE to a .hwp/.hwpx path to run this")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try HwpReader.read(data)
        XCTAssertGreaterThan(result.defaultBodyFontSize, 0, "a real document should surface a positive default body size")
        if let expect = ProcessInfo.processInfo.environment["FMD_HWP_EXPECT_PT"].flatMap(Double.init) {
            XCTAssertEqual(result.defaultBodyFontSize, CGFloat(expect), accuracy: 0.001,
                           "surfaced default body size should match the document's declared size")
        }
        print("FMD_HWP_SAMPLE defaultBodyFontSize = \(result.defaultBodyFontSize)")
    }

    // End-to-end running-head distances (S5a), gated on a sample path. The synthetic mapping tests
    // prove the decode; only a real file proves the chain reaches production — a `sections` array
    // that never arrives, or a body section whose page block is absent, leaves both nil while every
    // synthetic test still passes. Prints the measured pair so a corpus can be surveyed with it.
    func testRealSampleSurfacesTheRunningHeadDistances() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_SAMPLE"] else {
            throw XCTSkip("Set FMD_HWP_SAMPLE to a .hwp/.hwpx path to run this")
        }
        let result = try HwpReader.read(Data(contentsOf: URL(fileURLWithPath: path)))
        print("FMD_HWP_SAMPLE headerDistance=\(String(describing: result.pageHeaderDistance))"
              + " footerDistance=\(String(describing: result.pageFooterDistance))"
              + " marginTop=\(String(describing: result.pageMarginTop))"
              + " marginBottom=\(String(describing: result.pageMarginBottom))")
        // Whatever the document declared, a surfaced distance must sit INSIDE its own margin —
        // otherwise the running head would be placed among the body text.
        if let h = result.pageHeaderDistance {
            XCTAssertGreaterThan(h, 0)
            if let top = result.pageMarginTop { XCTAssertLessThan(h, top) }
        }
        if let f = result.pageFooterDistance {
            XCTAssertGreaterThan(f, 0)
            if let bottom = result.pageMarginBottom { XCTAssertLessThan(f, bottom) }
        }
    }

    // End-to-end page-content-width, gated on a sample path. Proves the WHOLE chain: real bytes →
    // rhwp FFI → PageAreas.body_area ÷100 → envelope `pageContentWidth` → `result.pageContentWidth`.
    // A real A4 document surfaces a positive width near the A4 body (~476pt at 30mm margins); the
    // exact value is document-dependent, so assert only positivity and (optionally) an expected value
    // via FMD_HWP_EXPECT_WIDTH_PT. Prints the value so a real document's page width is observable.
    func testRealSampleSurfacesPageContentWidth() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_SAMPLE"] else {
            throw XCTSkip("Set FMD_HWP_SAMPLE to a .hwp/.hwpx path to run this")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try HwpReader.read(data)
        print("""
            FMD_HWP_SAMPLE geometry \
            content=\(String(describing: result.pageContentWidth))x\(String(describing: result.pageContentHeight)) \
            margins L=\(String(describing: result.pageMarginLeft)) R=\(String(describing: result.pageMarginRight)) \
            T=\(String(describing: result.pageMarginTop)) B=\(String(describing: result.pageMarginBottom))
            """)
        if let expect = ProcessInfo.processInfo.environment["FMD_HWP_EXPECT_WIDTH_PT"].flatMap(Double.init) {
            let w = try XCTUnwrap(result.pageContentWidth, "expected a page width for this sample")
            XCTAssertEqual(w, CGFloat(expect), accuracy: 0.5)
        } else if let w = result.pageContentWidth {
            XCTAssertGreaterThan(w, 0, "a page width, when present, must be positive")
            XCTAssertLessThan(w, 2000, "a sane page body width is well under 2000pt")
        }
        // The margins are the whole point of surfacing geometry at all: rhwp used to hand over the
        // BODY width alone, so a document declaring A4 with 40mm margins opened as a 432pt "page"
        // (the app's own 32pt side inset either side of a 368pt body) instead of the 595pt sheet the
        // file actually declares. Reconstructing the paper from left + body + right is what proves
        // they arrived, and it is the one relation that must hold for every document: a margin is
        // never negative (rhwp derives it by subtracting the body's edges from a resolved paper
        // size, so a corrupt file could otherwise push it below zero), and the sheet they rebuild
        // has to be a sheet. Pass FMD_HWP_EXPECT_PAPER_PT to pin the exact width for a known file —
        // 595.28 for A4 portrait.
        for (name, value) in [("left", result.pageMarginLeft), ("right", result.pageMarginRight),
                              ("top", result.pageMarginTop), ("bottom", result.pageMarginBottom)] {
            if let value { XCTAssertGreaterThanOrEqual(value, 0, "a \(name) margin must not be negative") }
        }
        if let body = result.pageContentWidth, let left = result.pageMarginLeft, let right = result.pageMarginRight {
            let paper = left + body + right
            XCTAssertGreaterThan(paper, body, "the sheet must be wider than its own body")
            XCTAssertLessThan(paper, 3000, "a sane sheet is well under 3000pt")
            if let expect = ProcessInfo.processInfo.environment["FMD_HWP_EXPECT_PAPER_PT"].flatMap(Double.init) {
                XCTAssertEqual(paper, CGFloat(expect), accuracy: 0.5,
                               "left + body + right must rebuild the declared sheet")
            }
        }
    }

    // Read-time image pre-decode, gated on a sample that ACTUALLY HAS an embedded image.
    // Point FMD_HWP_IMAGE_SAMPLE at a .hwp/.hwpx with a picture. Asserts `read` collects the
    // bytes (they can't be resolved later — no archive, and the rhwp handle is closed by return),
    // keyed by the same `hwpimg:*` id the blocks carry, with non-empty decoded Data.
    func testReadPreDecodesEmbeddedImages() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_IMAGE_SAMPLE"] else {
            throw XCTSkip("Set FMD_HWP_IMAGE_SAMPLE to a .hwp/.hwpx that contains an image")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try HwpReader.read(data)
        XCTAssertFalse(result.images.isEmpty, "sample was expected to carry at least one embedded image")
        for (id, bytes) in result.images {
            XCTAssertTrue(id.hasPrefix("hwpimg:"), "image key should be an embedded-image id, got \(id)")
            XCTAssertFalse(bytes.isEmpty, "decoded image bytes should be non-empty for \(id)")
        }
    }
}
