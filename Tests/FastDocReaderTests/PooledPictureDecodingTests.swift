import XCTest
@testable import FastDocReader

/// A picture the wire carries ONCE still reaches the cell that uses it.
///
/// P4a stopped writing a picture's bytes at every use — 610 table cells of one government manual
/// each carried their own base64 copy of one of 44 backgrounds, 17,193,764 bytes of a 27,169,703-byte
/// payload — and put them in the envelope's `picturePool` under a content key instead. That moved
/// the moment a cell's `backgroundImage` becomes real from "the bytes were right there" to "the key
/// resolved against a pool decoded earlier in the same envelope", and NOTHING in the suite saw the
/// difference: breaking the resolution entirely left all 1,787 tests green.
///
/// A seam no test crosses is a seam that will be broken silently, so these three cross it: the
/// resolution works, a key with no bytes behind it leaves the CELL without a background instead of
/// costing the document its decode, and the same absence on a MASTER PAGE — where the vocabulary
/// holds a real `NSImage` rather than an optional and used to throw — reserves the declared box
/// rather than losing the document with it.
final class PooledPictureDecodingTests: XCTestCase {
    /// A 1×1 PNG, the smallest thing `NSImage(data:)` accepts. Base64 so the envelope below reads
    /// as the wire actually looks.
    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func envelope(poolKey: String?, referenced: String?) -> String {
        let pool = poolKey.map { "\"picture_pool\":{\"\($0)\":\"\(Self.onePixelPNG)\"}," } ?? ""
        let background = referenced.map {
            "\"background_image\":{\"size\":{\"width\":1,\"height\":1},\"data_key\":\"\($0)\"},"
        } ?? ""
        return """
        {"v":\(RustEngine.schemaVersion),\(pool)"blocks":[{"table":{
          "rows":[[{"blocks":[],"row_span":1,"col_span":1,\(background)"blocks_are_empty":true}]],
          "header_rows":0,"column_widths":[100.0],"format":{}}}],
         "comments":[],"images":{},"pictures_declared_without_bytes":[],"vector_graphics":{},
         "default_body_font_size":11.0,"declared_faces":{},"headers":[],"footers":[],"footnotes":[],
         "master_pages":[],"sections":[],"anchored_objects":[],"section_start_blocks":[],
         "keep_with_next_blocks":[],"page_break_blocks":[],"hide_page_number_blocks":[],
         "page_number_restart_blocks":[]}
        """
    }

    private func decode(_ json: String) -> OfficeReadResult? {
        var bytes = Array(json.utf8)
        bytes.append(0)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                RustEngine.decodeOffice(UnsafeMutablePointer(mutating: $0))
            }
        }
    }

    private func firstCellBackground(_ result: OfficeReadResult?) -> NSImage?? {
        guard let result, case .table(let table)? = result.blocks.first else { return nil }
        return table.rows.first?.first?.backgroundImage
    }

    func testACellResolvesItsPictureFromThePool() throws {
        let result = decode(envelope(poolKey: "poolimg:abc", referenced: "poolimg:abc"))
        let background = try XCTUnwrap(firstCellBackground(result), "the document decoded a table")
        XCTAssertNotNil(
            background,
            "a cell naming a pooled picture must resolve it — this is the whole of P4a, and before "
                + "this test nothing in the suite failed when the resolution was disabled entirely")
    }

    /// A master-page picture is the one place the vocabulary holds a real `NSImage` rather than an
    /// optional, so an unresolvable key there used to throw and take the whole document down with it
    /// — exactly the failure P2c and P2d removed everywhere else.
    func testAnUnresolvableMasterPagePictureCostsItsBoxRatherThanTheDocument() throws {
        let json = """
        {"v":\(RustEngine.schemaVersion),"picture_pool":{"poolimg:abc":"\(Self.onePixelPNG)"},
         "blocks":[],"comments":[],"images":{},"pictures_declared_without_bytes":[],
         "vector_graphics":{},"default_body_font_size":11.0,"declared_faces":{},
         "headers":[],"footers":[],"footnotes":[],
         "master_pages":[{"section":0,"applies_to":"defaultPages","objects":[
           {"frame":{"origin":{"x":0,"y":0},"size":{"width":8,"height":4}},
            "content":{"Image":{"size":{"width":8,"height":4},"data_key":"poolimg:missing"}}}]}],
         "sections":[],"anchored_objects":[],"section_start_blocks":[],
         "keep_with_next_blocks":[],"page_break_blocks":[],"hide_page_number_blocks":[],
         "page_number_restart_blocks":[]}
        """
        let result = try XCTUnwrap(decode(json), "one absent picture must not cost the document")
        guard case .image(let image)? = result.masterPages.first?.objects.first?.content else {
            return XCTFail("the master object should still be an image, with its box reserved")
        }
        XCTAssertEqual(image.size, CGSize(width: 8, height: 4),
                       "the box the document declared is what gets reserved")
    }

    func testAKeyWithNoBytesBehindItLeavesTheCellWithoutAPictureRatherThanFailingTheDocument() throws {
        // The pool is present but does not contain the key the cell names. A document is not lost
        // over one absent picture (invariant 108's shape, and the same rule P2c settled for keyed
        // pictures) — the cell simply has no background.
        let result = decode(envelope(poolKey: "poolimg:abc", referenced: "poolimg:missing"))
        let background = try XCTUnwrap(firstCellBackground(result), "the document still decoded")
        XCTAssertNil(background, "an unresolvable key is an absent picture, not a failed decode")
    }
}
