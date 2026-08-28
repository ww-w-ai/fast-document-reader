import XCTest
import AppKit
@testable import FastDocReader

/// P7's gate: the decoded-image caches have a CEILING, and every entry counts toward it.
///
/// Invariant 65 settled when these caches are emptied — when the last document closes — and left
/// what they may hold between those moments unbounded, on the reading that `NSCache` evicts under
/// real memory pressure. It does, at the system's discretion; what it does not do is stop one
/// session from accumulating every picture of every document opened since launch, which is the
/// shape invariant 65 measured (224 MB with nothing open, 471 MB after 44 hours).
///
/// The trap this file exists for: **`NSCache` treats a costless insert as free.** A cache whose
/// `totalCostLimit` is set and whose `setObject` calls pass no cost is exactly as unbounded as one
/// with no limit, and it looks configured — a limit is not a property any behaviour test can see,
/// because the pictures are identical either way (invariant 113's shape again).
final class ImageCacheCeilingTests: XCTestCase {

    /// A picture's cost is what it OCCUPIES, and that is pixels — a 2× picture is four times the
    /// memory at the same point size, so charging by `size` would undercount it by exactly the
    /// factor that matters on the machines this ships to.
    func testAPicturesCostIsItsPixelsRatherThanItsPoints() {
        let hundredBy50 = image(pixelsWide: 100, pixelsHigh: 50, pointSize: NSSize(width: 100, height: 50))
        XCTAssertEqual(MarkdownDocument.decodedByteCost(hundredBy50), 100 * 50 * 4)

        // Same POINT size, twice the pixels on each axis — four times the memory.
        let retina = image(pixelsWide: 200, pixelsHigh: 100, pointSize: NSSize(width: 100, height: 50))
        XCTAssertEqual(MarkdownDocument.decodedByteCost(retina), 200 * 100 * 4,
                       "a 2× picture must cost four times a 1× one of the same point size")
    }

    /// Never zero. A costless entry is an uncounted one, and a cache of uncounted entries has no
    /// ceiling however high the ceiling is set.
    func testAPictureWithNoPixelBackedRepresentationStillCostsSomething() {
        let empty = NSImage(size: NSSize(width: 8, height: 4))
        XCTAssertGreaterThan(MarkdownDocument.decodedByteCost(empty), 0)
    }

    /// The limit is installed by the door itself, so there is no order of operations in which a
    /// cache is used before it is bounded.
    func testAnInsertInstallsTheCeilingOnTheCacheItWentInto() {
        let cache = NSCache<NSString, NSImage>()
        XCTAssertEqual(cache.totalCostLimit, 0, "a fresh NSCache is unbounded — that is the default this guards")

        MarkdownDocument.cache(cache, image(pixelsWide: 4, pixelsHigh: 4,
                                            pointSize: NSSize(width: 4, height: 4)),
                              forKey: "k" as NSString)

        XCTAssertEqual(cache.totalCostLimit, MarkdownDocument.imageCacheByteCeiling,
                       "the insert must have bounded the cache it went into")
        XCTAssertNotNil(cache.object(forKey: "k" as NSString), "and the picture must still be in it")
    }

    /// The one that matters, and the one the first version of this file missed: the insert must
    /// actually CHARGE. `decodedByteCost` being right proves nothing if `setObject` is handed a
    /// zero — measured, that mutation left all four of the other tests green.
    ///
    /// `NSCache` exposes no way to read back what an entry cost, so this asks the only question it
    /// does answer: with a ceiling far smaller than what is being put in, an entry that costs
    /// something must be evicted, and an entry that costs nothing never is. The ceiling is set here
    /// BEFORE the insert, which the door leaves alone (it installs its own only when there is none).
    func testTheInsertChargesForThePictureRatherThanFilingItForFree() {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 8 * 1024          // 8 KB — one of the pictures below does not fit

        // 64×64 at 4 bytes a pixel is 16 KB, twice the ceiling on its own.
        for i in 0..<8 {
            MarkdownDocument.cache(cache, image(pixelsWide: 64, pixelsHigh: 64,
                                                pointSize: NSSize(width: 64, height: 64)),
                                   forKey: "k\(i)" as NSString)
        }
        let survivors = (0..<8).filter { cache.object(forKey: "k\($0)" as NSString) != nil }.count

        XCTAssertLessThan(survivors, 8, """
            all eight 16 KB pictures are still in a cache limited to 8 KB, which means they were             filed at no cost. NSCache counts what it is told; a costless insert is outside every             ceiling, and the cache then looks bounded while it is not.
            """)
        XCTAssertEqual(cache.totalCostLimit, 8 * 1024,
                       "the door must not overwrite a ceiling someone already set")
    }

    /// The structural half, and the one a behaviour test cannot reach: nothing may put a picture
    /// into either cache except through the door that charges for it. A bare `setObject` compiles,
    /// passes every other test, and silently removes the ceiling for whatever it inserts.
    ///
    /// Written as a source check for the same reason `RustEngineBridgeTests`' adapter guard is:
    /// the defect is the ABSENCE of a call, and absence has no runtime signature.
    func testNothingPutsAPictureIntoTheseCachesWithoutPayingForIt() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FastDocReader/App/MarkdownDocument.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let offenders = text.split(separator: "\n").enumerated().filter { _, line in
            (line.contains("imageCache.setObject") || line.contains("officeImageCache.setObject"))
        }
        XCTAssertTrue(offenders.isEmpty, """
            MarkdownDocument.swift inserts into an image cache directly at \
            \(offenders.map { "line \($0.offset + 1)" }.joined(separator: ", ")). NSCache treats a \
            costless insert as free, so that entry is outside the ceiling and the cache looks \
            bounded while it is not. Go through MarkdownDocument.cache(_:_:forKey:).
            """)
    }

    private func image(pixelsWide: Int, pixelsHigh: Int, pointSize: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }
}
