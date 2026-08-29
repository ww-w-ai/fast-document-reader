import XCTest
import AppKit
@testable import FastDocReader

/// Where the 30 ms a scrolled frame still spends on a 바탕쪽 actually goes.
///
/// Invariant 118 established that a scrolled viewport is this app's own draw code, and that caching
/// the artwork at the size it is DRAWN at took the median from 51.3 ms to 41.0. What remains is a
/// blit of a bitmap that is already the right size — which ought to be close to a memory copy and
/// measurably is not. This probe answers WHY before anything structural is proposed, by timing the
/// same pixels through four paths that differ in one thing each:
///
/// | variant | differs by |
/// |---|---|
/// | A | what ships today: RGBA, `.sourceOver`, `NSImage.draw(respectFlipped:)` |
/// | B | `.copy` instead of `.sourceOver` — isolates per-pixel BLENDING |
/// | C | an OPAQUE rep drawn `.copy` — isolates carrying an alpha channel at all |
/// | D | `CGContext.draw` of the `CGImage` — isolates `NSImage`'s own rep selection |
///
/// Reports `BLIT key=value` lines. Skips unless `FMD_ARTWORK_BLIT_PROBE` names a real document that
/// HAS a master page carrying a picture; it fails rather than print a number it did not measure.
final class MasterArtworkBlitProbeTests: XCTestCase {

    private func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
    private func f(_ x: Double) -> String { String(format: "%.2f", x) }
    private func blit(_ line: String) { print("BLIT " + line) }

    func testWhereTheRemainingArtworkBlitTimeGoes() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_ARTWORK_BLIT_PROBE"] else {
            throw XCTSkip("set FMD_ARTWORK_BLIT_PROBE to an absolute path naming a document with a 바탕쪽 picture")
        }
        let url = URL(fileURLWithPath: path)
        let uti: String = {
            switch url.pathExtension.lowercased() {
            case "odt": return "org.oasis-open.opendocument.text"
            case "hwp", "hwpx": return "com.hancom.hwp"
            default: return "org.openxmlformats.wordprocessingml.document"
            }
        }()
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: uti)
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 900), display: false)

        let content = try XCTUnwrap(wc.masterPageContent, "this document declares no master page")
        let sheets = wc.printSheets
        XCTAssertFalse(sheets.isEmpty, "the document must paginate for a sheet-sized blit to mean anything")
        let sheet = try XCTUnwrap(sheets.first)

        var found: (NSImage, NSRect)?
        for page in content.pages {
            for object in page.objects {
                if case .image(let image) = object.content {
                    found = (image, NSRect(x: sheet.minX + object.frame.minX,
                                           y: sheet.minY + object.frame.minY,
                                           width: object.frame.width, height: object.frame.height))
                    break
                }
            }
            if found != nil { break }
        }
        guard let (source, rect) = found else {
            throw XCTSkip("no master page in this document carries a picture")
        }

        let scale: CGFloat = 2
        let pw = max(1, Int((rect.width * scale).rounded()))
        let ph = max(1, Int((rect.height * scale).rounded()))
        let srcRep = source.representations.first
        blit("stage=source pointW=\(f(source.size.width)) pointH=\(f(source.size.height)) "
             + "pixelW=\(srcRep?.pixelsWide ?? -1) pixelH=\(srcRep?.pixelsHigh ?? -1) "
             + "alpha=\(srcRep?.hasAlpha ?? false) bpp=\((srcRep as? NSBitmapImageRep)?.bitsPerPixel ?? -1) "
             + "space=\((srcRep as? NSBitmapImageRep)?.colorSpace.localizedName ?? "?")")
        blit("stage=dest pointW=\(f(rect.width)) pointH=\(f(rect.height)) pixelW=\(pw) pixelH=\(ph) "
             + "megapixels=\(f(Double(pw * ph) / 1_000_000))")

        // The pre-scaled copies, made once — this is what the shipped cache holds. Built through
        // `CGContext` rather than `NSBitmapImageRep` because the opaque variant is the whole point
        // of variant C and `NSBitmapImageRep` cannot express it: 4 samples requires an alpha
        // channel, 3 samples has no `CGBitmapContext` at all. `noneSkipLast` is the shape that says
        // "32 bits, alpha byte ignored".
        func rendered(opaque: Bool) throws -> CGImage {
            let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
            let ctx = try XCTUnwrap(CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: alpha.rawValue),
                                    "no \(pw)x\(ph) context (opaque=\(opaque))")
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            let ns = try XCTUnwrap(NSGraphicsContext(cgContext: ctx, flipped: false))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            source.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero,
                        operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(ctx.makeImage(), "the scaled copy did not come back out")
        }
        let alphaCG = try rendered(opaque: false)
        let opaqueCG = try rendered(opaque: true)
        let alphaImage = NSImage(cgImage: alphaCG, size: rect.size)
        let opaqueImage = NSImage(cgImage: opaqueCG, size: rect.size)

        // The destination: a device-pixel bitmap under the same flip+scale a screen draw runs with.
        let dest = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        dest.size = rect.size
        let destCtx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: dest),
                                    "could not make a \(pw)x\(ph) destination context to blit into")

        let rounds = 40
        func time(_ name: String, _ body: () -> Void) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = destCtx
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: rect.height * scale)
            flip.scaleX(by: scale, yBy: -scale)
            flip.concat()
            body()                                   // one warm pass, not counted
            var samples: [Double] = []
            for _ in 0..<rounds {
                let t = Date()
                body()
                samples.append(ms(t))
            }
            NSGraphicsContext.restoreGraphicsState()
            let sorted = samples.sorted()
            blit("variant=\(name) median=\(f(sorted[rounds / 2])) min=\(f(sorted[0])) max=\(f(sorted[rounds - 1]))")
        }

        let at = NSRect(origin: .zero, size: rect.size)
        time("A-sourceOver-alpha-NSImage") {
            alphaImage.draw(in: at, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
        }
        time("B-copy-alpha-NSImage") {
            alphaImage.draw(in: at, from: .zero, operation: .copy, fraction: 1,
                            respectFlipped: true, hints: nil)
        }
        time("C-copy-opaque-NSImage") {
            opaqueImage.draw(in: at, from: .zero, operation: .copy, fraction: 1,
                             respectFlipped: true, hints: nil)
        }
        // E and F ask the question the first four could not: the cached bitmap is an INTEGER number
        // of pixels (`.rounded()`), and the rect it is drawn into is fractional — 1111 px into
        // 1111.18 pt·scale. A blit whose source and destination do not line up on a pixel is not a
        // blit; CoreGraphics resamples the whole picture. E turns interpolation off, F additionally
        // snaps the destination to whole device pixels.
        time("E-cgcontext-nointerp") {
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            cg.interpolationQuality = .none
            cg.translateBy(x: 0, y: rect.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(alphaCG, in: at)
            cg.restoreGState()
        }
        let snapped = NSRect(x: 0, y: 0,
                             width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        time("F-cgcontext-snapped") {
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            cg.translateBy(x: 0, y: snapped.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(alphaCG, in: snapped)
            cg.restoreGState()
        }
        // G and H are the question E leaves open: 7 ms for 1.69 megapixels is still ten times a
        // memory copy, because even with interpolation off the picture is being RESAMPLED — the
        // destination is 1111.18 device pixels wide and the bitmap is 1111. These two undo the
        // view's own transform and draw in DEVICE space, where the rectangle can be made exactly
        // the bitmap's own pixel count and the copy is one-to-one. H keeps interpolation high, so
        // the pair separates "aligned" from "not interpolating".
        func inDeviceSpace(_ quality: CGInterpolationQuality) {
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            cg.concatenate(cg.ctm.inverted())        // back to device pixels
            cg.interpolationQuality = quality
            cg.translateBy(x: 0, y: CGFloat(ph))
            cg.scaleBy(x: 1, y: -1)
            cg.draw(alphaCG, in: CGRect(x: 0, y: 0, width: CGFloat(pw), height: CGFloat(ph)))
            cg.restoreGState()
        }
        time("G-device-1to1-nointerp") { inDeviceSpace(.none) }
        time("H-device-1to1-highinterp") { inDeviceSpace(.high) }

        blit("stage=alignment destPx=\(f(rect.width * scale))x\(f(rect.height * scale)) "
             + "bitmapPx=\(pw)x\(ph) snappedPt=\(f(snapped.width))x\(f(snapped.height))")

        time("D-cgcontext-draw") {
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            cg.translateBy(x: 0, y: rect.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(alphaCG, in: at)
            cg.restoreGState()
        }
    }
}
