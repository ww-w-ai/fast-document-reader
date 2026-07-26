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
