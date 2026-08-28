import XCTest
@testable import FastDocReader

/// The gradient DECLARATION's Swift mirror (S6-4). The engine stopped rasterizing a gradient into a
/// synthetic bitmap and now carries the declaration itself, so `Cell`/`TableFormat` grew a
/// `backgroundGradient`. Nothing DRAWS it yet — which is exactly why these tests exist: without
/// them the decode is unwitnessed, and a wire rename would arrive silently as "the document simply
/// has no gradient" rather than as a failure.
final class OfficeGradientDecodeTests: XCTestCase {
    private func stop(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> [String: Any] {
        ["red": r, "green": g, "blue": b, "alpha": 1.0, "space": "sRGB"]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testACellCarriesItsGradientStopsAndAngle() throws {
        let cell = try decode(Cell.self, [
            "blocks": [], "rowSpan": 1, "colSpan": 1,
            "backgroundGradient": ["stops": [stop(1, 0, 0), stop(0, 0, 1)], "angleDegrees": 45.0],
        ])
        let gradient = try XCTUnwrap(cell.backgroundGradient)
        XCTAssertEqual(gradient.stops.count, 2)
        XCTAssertEqual(gradient.angleDegrees, 45.0)
        // The whole point of S6-4: a gradient must NOT arrive as a fabricated picture resource.
        XCTAssertNil(cell.backgroundImage)
    }

    func testAGradientWithoutAnAngleKeepsTheAbsenceRatherThanInventingZero() throws {
        let cell = try decode(Cell.self, [
            "blocks": [], "rowSpan": 1, "colSpan": 1,
            "backgroundGradient": ["stops": [stop(1, 1, 1), stop(0, 0, 0)]],
        ])
        XCTAssertNil(try XCTUnwrap(cell.backgroundGradient).angleDegrees)
    }

    func testATableFormatCarriesItsOwnGradient() throws {
        let format = try decode(TableFormat.self, [
            "backgroundGradient": ["stops": [stop(0, 1, 0), stop(0, 0, 1)], "angleDegrees": 90.0],
        ])
        let gradient = try XCTUnwrap(format.backgroundGradient)
        XCTAssertEqual(gradient.stops.count, 2)
        XCTAssertEqual(gradient.angleDegrees, 90.0)
        XCTAssertNil(format.backgroundImage)
    }

    func testACellThatDeclaresNoGradientStaysNil() throws {
        let cell = try decode(Cell.self, ["blocks": [], "rowSpan": 1, "colSpan": 1])
        XCTAssertNil(cell.backgroundGradient)
    }
}
