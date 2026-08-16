import XCTest
import AppKit
@testable import FastDocReader

/// A gradient fill is painted as a gradient.
///
/// The stops and the angle were decoded and then dropped: both consumers read `colors[0]`, so a
/// two-colour panel rendered as its first colour and the declared angle was dead data (found by the
/// export audit, invariant 83). There is no gradient in the table/cell vocabulary, so it is rendered
/// into the image slot the picture fill already uses — which the painters draw stretched.
final class HwpGradientFillTests: XCTestCase {

    private func envelope(_ blocks: String, fills: String) -> String {
        "{\"v\":1,\"borderFills\":[\(fills)],\"blocks\":[\(blocks)]}"
    }

    /// A border fill states its four edges whether or not they are drawn, so every fixture here
    /// carries them; only the background differs.
    private let twoStopDown = """
    {"left":{"type":"none"},"right":{"type":"none"},"top":{"type":"none"},"bottom":{"type":"none"},"bgGradient":{"colors":["FF0000","0000FF"],"angle":0}}
    """
    private let table = """
    {"t":"table","cols":1,"colWidths":[1000],"borderFillId":1,
     "rows":[[{"colSpan":1,"rowSpan":1,"borderFillId":1,"blocks":[]}]]}
    """

    private func firstTable(_ blocks: [OfficeBlock]) throws -> (TableFormat, Cell) {
        for block in blocks {
            if case .table(let rows, _, _, let format) = block {
                return (format, try XCTUnwrap(rows.first?.first))
            }
        }
        throw XCTSkip("no table")
    }

    /// Two stops become a real gradient image rather than a flat wash of the first colour.
    func testATwoStopFillIsPaintedAsAGradient() throws {
        let blocks = try HwpReader.mapJSON(envelope(table, fills: twoStopDown)).blocks
        let (format, cell) = try firstTable(blocks)
        let image = try XCTUnwrap(format.backgroundImage, "the table's own gradient must be painted")
        XCTAssertNotNil(cell.backgroundImage, "and the cell's, which resolves the same fill")
        // The document said top-to-bottom red→blue, so the two ends must differ and in that order.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!))
        let top = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 1))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 2))
        XCTAssertGreaterThan(top.redComponent, top.blueComponent, "the top end is the first stop")
        XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent, "the bottom end is the last")
        // A gradient is NOT also flattened onto the shading, which would paint over it.
        XCTAssertNil(format.defaultShading)
    }

    /// The angle is read, not assumed: the same stops at 180° come out the other way up.
    func testTheDeclaredAngleTurnsTheGradient() throws {
        let flipped = "{\"left\":{\"type\":\"none\"},\"right\":{\"type\":\"none\"},\"top\":{\"type\":\"none\"},\"bottom\":{\"type\":\"none\"},\"bgGradient\":{\"colors\":[\"FF0000\",\"0000FF\"],\"angle\":180}}"
        let blocks = try HwpReader.mapJSON(envelope(table, fills: flipped)).blocks
        let (format, _) = try firstTable(blocks)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(format.backgroundImage).tiffRepresentation!))
        let top = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 1))
        XCTAssertGreaterThan(top.blueComponent, top.redComponent,
                             "at 180° the LAST stop is at the top")
    }

    /// One stop is not a gradient — it is a plain fill, and it stays on the colour path.
    func testASingleStopStaysAPlainFill() throws {
        let one = "{\"left\":{\"type\":\"none\"},\"right\":{\"type\":\"none\"},\"top\":{\"type\":\"none\"},\"bottom\":{\"type\":\"none\"},\"bgGradient\":{\"colors\":[\"FF0000\"]}}"
        let blocks = try HwpReader.mapJSON(envelope(table, fills: one)).blocks
        let (format, _) = try firstTable(blocks)
        XCTAssertNil(format.backgroundImage)
        XCTAssertEqual(format.defaultShading?.redComponent, 1.0)
    }
}
