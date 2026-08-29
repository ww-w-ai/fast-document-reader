import XCTest
import AppKit
@testable import FastDocReader

/// The gate on the single most expensive thing a scrolled frame of a paged Korean document did.
///
/// A 바탕쪽's full-page artwork is drawn on every page the template applies to, on every draw pass,
/// and `MasterPagePainter` is a draw-time painter with no layout phase to prepare anything in. So it
/// scaled a several-thousand-pixel picture down to a 395pt-wide sheet sixty times a second.
///
/// Measured on the 542-page reference document with the whole-reader probe, one `case` skipped at a
/// time: a scrolled viewport cost a median **55.0 ms**, and skipping the image case alone took it to
/// **16.0 ms** — while skipping the text case gave 48.5 and the vector case 46.8, so neither of those
/// is where the time was. Decoding once and drawing a fresh `NSImage` around the `CGImage` was not
/// enough either (48.6 ms): the cost is the RESAMPLE, not the decode, which is why the cache is
/// keyed by the size the artwork is actually drawn at. With it, **51.3 → 41.2 ms**.
///
/// Nothing else could see this. The pixels are identical either way — that is what makes it a
/// latency regression rather than a defect, and latency is what no other test here can see
/// (invariant 113). So this counts rasterisations, the way S8B's resize gate counts attribute
/// queries and `PageGridMemoTests` counts grid builds.
final class MasterPageArtworkCacheTests: XCTestCase {

    /// Scrolling redraws the same artwork at the same size, frame after frame. It must be scaled
    /// once, no matter how many frames ask for it.
    func testArtworkIsScaledOncePerSizeRatherThanOncePerDrawPass() throws {
        let content = contentWithArtwork()
        let sheets = [CGRect(x: 0, y: 0, width: 200, height: 260)]

        let before = MasterPagePainter.artworkRasterisations
        for _ in 0..<10 {
            withOffscreenBitmap(width: 200, height: 260) {
                MasterPagePainter.draw(content, sheets: sheets, totalPages: 1,
                                       visibleRect: NSRect(x: 0, y: 0, width: 200, height: 260))
            }
        }
        let rasterised = MasterPagePainter.artworkRasterisations - before

        XCTAssertGreaterThan(rasterised, 0, """
            ten draw passes scaled the artwork zero times, which means the image case was never \
            reached and nothing below is being tested — check the sheet actually intersects the \
            visible rect and the template actually applies to page 0.
            """)
        XCTAssertEqual(rasterised, 1, """
            ten draw passes over the SAME artwork at the SAME size scaled it \\(rasterised) times. \
            Scrolling redraws the same page furniture every frame; on the 542-page reference \
            document rescaling it per frame is 39 ms of a 55 ms viewport.
            """)
    }

    /// The other half, and the one that keeps the cache honest: a MAGNIFIED page is drawn at more
    /// device pixels, and must be scaled for that, not served the bitmap made for the unmagnified
    /// one. Without this a cache that ignores the drawn size passes the test above perfectly while
    /// serving a zoomed-in reader a blurry picture.
    ///
    /// The sheet is NOT what changes here — an object's frame is its own, so a bigger sheet draws
    /// the same 200×260 box and is correctly a cache hit. What changes the drawn size is the
    /// transform, which is what page zoom actually is (invariant 46's neighbourhood: a paged press
    /// is a view transform and rebuilds nothing).
    func testAMagnifiedPageIsScaledAgainRatherThanServedTheUnmagnifiedBitmap() throws {
        let content = contentWithArtwork()
        let sheets = [CGRect(x: 0, y: 0, width: 200, height: 260)]
        let visible = NSRect(x: 0, y: 0, width: 200, height: 260)

        let before = MasterPagePainter.artworkRasterisations
        withOffscreenBitmap(width: 200, height: 260, scale: 1) {
            MasterPagePainter.draw(content, sheets: sheets, totalPages: 1, visibleRect: visible)
        }
        let afterFirst = MasterPagePainter.artworkRasterisations
        XCTAssertEqual(afterFirst - before, 1, "the unmagnified size must have been scaled once")

        withOffscreenBitmap(width: 400, height: 520, scale: 2) {
            MasterPagePainter.draw(content, sheets: sheets, totalPages: 1, visibleRect: visible)
        }
        XCTAssertEqual(MasterPagePainter.artworkRasterisations - afterFirst, 1,
                       "a page drawn at twice the device resolution must be scaled for that "
                       + "resolution, not served the bitmap made for the smaller one")

        // And back again: returning to the size already in hand must not scale anything.
        let afterSecond = MasterPagePainter.artworkRasterisations
        withOffscreenBitmap(width: 200, height: 260, scale: 1) {
            MasterPagePainter.draw(content, sheets: sheets, totalPages: 1, visibleRect: visible)
        }
        XCTAssertEqual(MasterPagePainter.artworkRasterisations, afterSecond,
                       "zooming back out must find the bitmap it already made")
    }

    /// The ceiling, and why it is in BYTES.
    ///
    /// The first version of this cache capped it at 64 ENTRIES, which is not a bound: one scaled
    /// artwork was measured at 2652×1940 device pixels — 20 MB — so sixty-four of them is a third
    /// of a gigabyte. The integrated re-measure caught it, reporting the footprint after a full
    /// read-through at 640 MB against 521 at the start of the run. Ten milliseconds a frame is not
    /// worth that, and no scroll test can see it.
    ///
    /// Four pages drawn at 2000×2000 points are 16 MB of scaled pixels each — 64 MB against a
    /// 48 MB ceiling, so the least recently used must be gone. Redrawing it has to rasterise
    /// again, which is what says it was evicted rather than merely reported as absent.
    func testTheArtworkCacheIsBoundedInBytesRatherThanInEntries() {
        let big = { (tag: Int) -> MasterPageContent in
            let object = OfficeMasterObject(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000),
                                            content: .image(self.artwork(width: 64 + tag, height: 64)))
            let page = OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [object])
            return MasterPageContent(pages: [page], sectionsHidingMasterPage: [],
                                     theme: RenderTheme(baseFontSize: 13),
                                     documentDefaultFontSize: 11, pageContentWidth: 180)
        }
        let sheets = [CGRect(x: 0, y: 0, width: 2000, height: 2000)]
        let visible = NSRect(x: 0, y: 0, width: 2000, height: 2000)
        let contents = (0..<4).map(big)

        for content in contents {
            withOffscreenBitmap(width: 64, height: 64) {
                MasterPagePainter.draw(content, sheets: sheets, totalPages: 1, visibleRect: visible)
            }
        }
        XCTAssertGreaterThan(MasterPagePainter.artworkByteCeiling, 0, "there must be a ceiling at all")

        // The FIRST one again: if the ceiling held, it is no longer in the cache and has to be
        // scaled a second time.
        let before = MasterPagePainter.artworkRasterisations
        withOffscreenBitmap(width: 64, height: 64) {
            MasterPagePainter.draw(contents[0], sheets: sheets, totalPages: 1, visibleRect: visible)
        }
        XCTAssertGreaterThan(MasterPagePainter.artworkRasterisations, before, """
            four 16 MB artworks all survived a \(MasterPagePainter.artworkByteCeiling / 1024 / 1024) MB             ceiling, so the cache is counting entries rather than bytes — which is how it once grew             to hundreds of megabytes while looking capped.
            """)
    }

    /// Invariant 121: the blit must be ONE-TO-ONE.
    ///
    /// Caching the artwork at its drawn size is only half the win. The cached copy is a whole
    /// number of pixels and the rectangle it lands in is fractional — on the reference document a
    /// 1111-pixel bitmap into 1111.18 device pixels — and CoreGraphics answers a destination that
    /// is not the source's own size by RESAMPLING the whole picture. Measured on 1.69 megapixels,
    /// medians of 40 draws: **16.0 ms fractional at high interpolation against 7.2 ms one-to-one**,
    /// and one-to-one at high interpolation is 7.25, so it is the alignment and not the filter.
    ///
    /// The pixels are identical either way, which is why nothing else here can see it and why this
    /// reads the destination rectangle rather than a clock (invariant 113).
    func testTheArtworkIsCopiedOneToOneRatherThanResampledIntoAFractionalRectangle() throws {
        // A deliberately awkward frame: 200.09 × 260.07 points at scale 2 is 400.18 × 520.14 device
        // pixels, so a draw that simply uses the rectangle it was given cannot be one-to-one.
        let object = OfficeMasterObject(frame: CGRect(x: 3.4, y: 7.6, width: 200.09, height: 260.07),
                                        content: .image(artwork(width: 1200, height: 1560)))
        let page = OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [object])
        let content = MasterPageContent(pages: [page], sectionsHidingMasterPage: [],
                                        theme: RenderTheme(baseFontSize: 13),
                                        documentDefaultFontSize: 11, pageContentWidth: 180)
        let sheets = [CGRect(x: 0, y: 0, width: 220, height: 280)]

        MasterPagePainter.resetLastArtworkBlit()
        withOffscreenBitmap(width: 440, height: 560, scale: 2) {
            MasterPagePainter.draw(content, sheets: sheets, totalPages: 1,
                                   visibleRect: NSRect(x: 0, y: 0, width: 220, height: 280))
        }
        let blit = try XCTUnwrap(MasterPagePainter.lastArtworkBlit, """
            the draw pass never blitted any artwork, so nothing below is being tested — check the \
            object still intersects the visible rect and that the image case still goes through \
            `drawArtwork`.
            """)

        XCTAssertEqual(blit.device.width, CGFloat(blit.pixelWidth), accuracy: 0.0001, """
            the artwork was drawn into a \(blit.device.width)-pixel-wide rectangle from a \
            \(blit.pixelWidth)-pixel bitmap. A destination that is not the bitmap's own size makes \
            CoreGraphics resample the entire picture on every frame — measured at 16.0 ms against \
            7.2 for the same pixels copied.
            """)
        XCTAssertEqual(blit.device.height, CGFloat(blit.pixelHeight), accuracy: 0.0001,
                       "the same, vertically: \(blit.device.height) into \(blit.pixelHeight)")
        XCTAssertEqual(blit.device.minX, blit.device.minX.rounded(), accuracy: 0.0001,
                       "a destination that starts between two device pixels is resampled too — "
                       + "x was \(blit.device.minX)")
        XCTAssertEqual(blit.device.minY, blit.device.minY.rounded(), accuracy: 0.0001,
                       "the same, vertically — y was \(blit.device.minY)")
    }

    // MARK: - Fixtures

    /// One template, applying to every page, carrying one full-page picture — the shape a Korean
    /// document's 바탕쪽 has.
    private func contentWithArtwork() -> MasterPageContent {
        let object = OfficeMasterObject(frame: CGRect(x: 0, y: 0, width: 200, height: 260),
                                        content: .image(artwork(width: 1200, height: 1560)))
        let page = OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [object])
        return MasterPageContent(pages: [page], sectionsHidingMasterPage: [],
                                 theme: RenderTheme(baseFontSize: 13),
                                 documentDefaultFontSize: 11, pageContentWidth: 180)
    }

    /// Deliberately much larger than the sheet it is drawn on — that size difference IS the cost
    /// this gate exists for, and an artwork the size of its box would not exercise the resample.
    private func artwork(width: Int, height: Int) -> NSImage {
        let size = NSSize(width: CGFloat(width), height: CGFloat(height))
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func withOffscreenBitmap(width: Int, height: Int, scale: CGFloat = 1,
                                     _ body: () -> Void) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let g = NSGraphicsContext(bitmapImageRep: rep) else {
            return XCTFail("could not make an offscreen context to draw into")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(height))
        flip.scaleX(by: scale, yBy: -scale)
        flip.concat()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
