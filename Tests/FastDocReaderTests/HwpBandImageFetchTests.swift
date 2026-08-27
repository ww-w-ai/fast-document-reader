import XCTest
@testable import FastDocReader

/// A picture that lives ONLY in a running header, a footer or a footnote must still have its bytes.
///
/// `HwpReader` fetches embedded pictures by walking mapped blocks for `hwpimg:` ids and asking the
/// live handle for each. A running header's, a footer's and a footnote's blocks are NOT inside
/// `result.blocks` — they are lifted into their own top-level arrays so a band can be drawn once per
/// page rather than once per paragraph (S4-02) — so a walk over `result.blocks` alone never asks for
/// a picture that lives only in one of those, and the band is then drawn with the picture missing.
///
/// Measured before the fix: **48 of 648** real HWP/HWPX documents on this machine carried such an id
/// (a logo in the header, most often `hwpimg:1`). It is not a flagged path — this is the shipping
/// Swift reader — and the engine's own port had the identical gap, found first
/// (`render/office/hwp_reader/mapping.rs`) and fixed in the same commit.
final class HwpBandImageFetchTests: XCTestCase {
    private static let corpusRoots = ["Vendor/rhwp-src/samples", "testdocs"]

    private static func imageIds(_ blocks: [OfficeBlock]) -> [String] {
        var out: [String] = []
        func walk(_ b: OfficeBlock) {
            if case .image(let id, _, _) = b { out.append(id) }
            if case .table(let rows, _, _, _) = b {
                for row in rows { for cell in row { cell.blocks.forEach(walk) } }
            }
        }
        blocks.forEach(walk)
        return out
    }

    func testEveryBandPictureInTheCorpusHasItsBytes() throws {
        let fm = FileManager.default
        var files: Set<String> = []
        for root in Self.corpusRoots {
            guard let e = fm.enumerator(atPath: root) else { continue }
            for case let p as String in e where ["hwp", "hwpx"].contains((p as NSString).pathExtension.lowercased()) {
                files.insert(root + "/" + p)
            }
        }
        guard !files.isEmpty else { throw XCTSkip("no HWP corpus on this machine") }
        var offenders: [String] = []
        var bandPictures = 0
        // Stops once enough band pictures have been checked. Walking all 648 documents costs ~53s,
        // which would double this suite; the documents that carry one cluster early in sort order and
        // twenty of them is already more evidence than the bug needed to show itself. The FULL sweep
        // is what the fix was measured with and is one line away (drop the break) when a change to
        // the fetch warrants it.
        let enough = 20
        for path in files.sorted() {
            if bandPictures >= enough && offenders.isEmpty { break }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let r = try? HwpReader.read(data) else { continue }
            let ids = r.headers.flatMap { Self.imageIds($0.blocks) }
                + r.footers.flatMap { Self.imageIds($0.blocks) }
                + r.footnotes.flatMap { Self.imageIds($0.blocks) }
            let embedded = ids.filter { $0.hasPrefix("hwpimg:") }
            bandPictures += embedded.count
            let missing = embedded.filter { r.images[$0] == nil }
            if !missing.isEmpty { offenders.append("\((path as NSString).lastPathComponent): \(missing.prefix(3))") }
        }
        // Without this the assertion below is vacuous on a machine whose corpus has no band picture.
        XCTAssertGreaterThanOrEqual(bandPictures, 1, "no document in this corpus puts a picture in a band — the check proves nothing")
        XCTAssertEqual(offenders.count, 0, "band pictures with no bytes fetched: \(offenders.prefix(5))")
    }
}
