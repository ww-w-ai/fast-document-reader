import XCTest
import AppKit
@testable import FastDocReader

/// What a REAL document's 바탕쪽 is made of, which decides which drawing rule paints it.
///
/// `MasterPagePainter.draw` has three picture branches and they do not share a rule:
/// `.image` goes through `drawArtwork`'s device-space blit (gated by `MasterPageArtworkCacheTests`),
/// while `.drawing` and `.vector` are drawn as an `NSImage` with `respectFlipped:`. A cover that
/// comes out mirrored says nothing about WHICH of the three drew it, and the repository ships no
/// document with a master page, so the question cannot be asked without a real file.
///
/// `FMD_MASTER_PAGE_PROBE=<file>` — a real `.hwp`/`.hwpx`/`.docx`/`.odt` with a 바탕쪽 (invariant 78).
/// Skipped by default, following the `FMD_HEADER_FOOTER_PROBE` family's convention.
final class MasterPageRealFileProbeTests: XCTestCase {
    func testWhatTheMasterPageIsMadeOf() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MASTER_PAGE_PROBE"] else {
            throw XCTSkip("set FMD_MASTER_PAGE_PROBE=<office file with a master page> to run this")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension
        let parsed: OfficeReadResult = DocumentTypes.isHwp(ext)
            ? try HwpReader.read(data)
            : try DocumentTypes.readOffice(try ZipArchive(data: data), extension: ext)

        print("PROBE masterPages=\(parsed.masterPages.count) anchored=\(parsed.anchoredObjects.count)")
        var kinds: [String: Int] = [:]
        for (i, page) in parsed.masterPages.enumerated() {
            print("PROBE page[\(i)] appliesTo=\(page.appliesTo) objects=\(page.objects.count)")
            for (j, o) in page.objects.enumerated() {
                let kind: String
                switch o.content {
                case .image: kind = "image"
                case .drawing: kind = "drawing(pdf)"
                case .vector: kind = "vector"
                case .text: kind = "text"
                }
                kinds[kind, default: 0] += 1
                print(String(format: "PROBE   [%d] %-13@ frame=%.1f,%.1f %.1fx%.1f",
                             j, kind as NSString,
                             o.frame.minX, o.frame.minY, o.frame.width, o.frame.height))
            }
        }
        print("PROBE kinds: \(kinds.sorted { $0.key < $1.key })")
    }

    /// Draws the REAL cover two ways into the same flipped bitmap and compares them row by row.
    ///
    /// `MasterPageArtworkCacheTests`' orientation gate proves the rule on a synthetic red/blue
    /// picture; it cannot say whether a real document's cover comes out the same way up, because
    /// "the top of this picture" is not a colour on a real page. This asks the only question that
    /// does not need one: does the painter's own output match the SAME image drawn by the plain
    /// `NSImage.draw(respectFlipped:)` rule, or is it that image's vertical mirror?
    func testTheRealCoverIsDrawnTheSameWayUpAsAPlainImageDraw() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MASTER_PAGE_PROBE"] else {
            throw XCTSkip("set FMD_MASTER_PAGE_PROBE=<office file with a master page> to run this")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let parsed: OfficeReadResult = DocumentTypes.isHwp(url.pathExtension)
            ? try HwpReader.read(data)
            : try DocumentTypes.readOffice(try ZipArchive(data: data), extension: url.pathExtension)
        guard let page = parsed.masterPages.first,
              let object = page.objects.first(where: { if case .image = $0.content { return true }; return false }),
              case .image(let cover) = object.content else {
            throw XCTSkip("this document's master page carries no image")
        }
        let w = 120, h = 160
        let sheet = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))

        func render(_ body: () -> Void) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let g = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: CGFloat(h))
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
            body()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        let scaled = OfficeMasterObject(frame: sheet, content: .image(cover))
        let onePage = OfficeMasterPage(section: page.section, appliesTo: page.appliesTo, objects: [scaled])
        let content = MasterPageContent(pages: [onePage], sectionsHidingMasterPage: [],
                                        theme: RenderTheme(baseFontSize: 13),
                                        documentDefaultFontSize: parsed.defaultBodyFontSize ?? 11,
                                        pageContentWidth: parsed.pageContentWidth ?? 400)
        let painted = try render {
            MasterPagePainter.draw(content, sheets: [sheet], totalPages: 1, visibleRect: sheet)
        }
        let plain = try render {
            cover.draw(in: sheet, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
        func row(_ rep: NSBitmapImageRep, _ y: Int) -> [Double] {
            (0..<w).compactMap { rep.colorAt(x: $0, y: y).map { Double($0.brightnessComponent) } }
        }
        func diff(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
        }
        var same = 0.0, mirrored = 0.0
        for y in stride(from: 4, to: h - 4, by: 6) {
            same += diff(row(painted, y), row(plain, y))
            mirrored += diff(row(painted, y), row(plain, h - 1 - y))
        }
        print(String(format: "PROBE painted-vs-plain  same=%.4f  mirrored=%.4f", same, mirrored))
        print("PROBE VERDICT: " + (mirrored < same ? "the painter draws it UPSIDE DOWN" : "same way up"))
        XCTAssertLessThan(same, mirrored, """
            the master-page painter's output matches the vertical MIRROR of a plain image draw             more closely than the draw itself — the real cover is painted upside down.
            """)
    }

    /// The SAME painter, the SAME bitmap, two images — one made by `lockFocus` (what the synthetic
    /// gate uses) and one decoded from the real document. If they disagree, the orientation depends
    /// on the SOURCE IMAGE's representation, which is why a gate built on a drawn picture can pass
    /// while every real cover is mirrored.
    func testOrientationDependsOnWhichKindOfImageItIs() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MASTER_PAGE_PROBE"] else {
            throw XCTSkip("set FMD_MASTER_PAGE_PROBE=<office file with a master page> to run this")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try HwpReader.read(data)
        guard let page = parsed.masterPages.first,
              let o = page.objects.first(where: { if case .image = $0.content { return true }; return false }),
              case .image(let real) = o.content else { throw XCTSkip("no master image") }

        let w = 120, h = 160
        let sheet = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let drawn = NSImage(size: NSSize(width: w, height: h))
        drawn.lockFocus()
        NSColor.systemRed.setFill(); NSRect(x: 0, y: CGFloat(h)/2, width: CGFloat(w), height: CGFloat(h)/2).fill()
        NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)/2).fill()
        drawn.unlockFocus()

        func render(_ body: () -> Void) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let g = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
            let f = NSAffineTransform(); f.translateX(by: 0, yBy: CGFloat(h)); f.scaleX(by: 1, yBy: -1); f.concat()
            body(); NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func verdict(_ image: NSImage, _ label: String) throws {
            let obj = OfficeMasterObject(frame: sheet, content: .image(image))
            let pg = OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [obj])
            let c = MasterPageContent(pages: [pg], sectionsHidingMasterPage: [],
                                      theme: RenderTheme(baseFontSize: 13),
                                      documentDefaultFontSize: 11, pageContentWidth: 100)
            let painted = try render { MasterPagePainter.draw(c, sheets: [sheet], totalPages: 1,
                                                              visibleRect: sheet) }
            let plain = try render { image.draw(in: sheet, from: .zero, operation: .sourceOver,
                                                fraction: 1, respectFlipped: true, hints: nil) }
            func row(_ r: NSBitmapImageRep, _ y: Int) -> [Double] {
                (0..<w).compactMap { r.colorAt(x: $0, y: y).map { Double($0.brightnessComponent) } }
            }
            func d(_ a: [Double], _ b: [Double]) -> Double {
                zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(max(a.count, 1))
            }
            var same = 0.0, mir = 0.0
            for y in stride(from: 4, to: h - 4, by: 6) {
                same += d(row(painted, y), row(plain, y)); mir += d(row(painted, y), row(plain, h - 1 - y))
            }
            print(String(format: "PROBE %-22@ same=%.4f mirrored=%.4f  -> %@", label as NSString,
                         same, mir, (mir < same ? "UPSIDE DOWN" : "same way up") as NSString))
        }
        try verdict(drawn, "lockFocus (the gate)")
        try verdict(real, "the real document")
    }

    /// Writes what the painter actually puts on a sheet to `FMD_MASTER_PAGE_DUMP`, so the one
    /// question a numeric comparison cannot settle — which way up a reader SEES it — can be looked at.
    func testDumpThePaintedCover() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MASTER_PAGE_PROBE"],
              let out = ProcessInfo.processInfo.environment["FMD_MASTER_PAGE_DUMP"] else {
            throw XCTSkip("set FMD_MASTER_PAGE_PROBE and FMD_MASTER_PAGE_DUMP to write the picture")
        }
        let parsed = try HwpReader.read(try Data(contentsOf: URL(fileURLWithPath: path)))
        guard let page = parsed.masterPages.first,
              let o = page.objects.first(where: { if case .image = $0.content { return true }; return false }),
              case .image(let cover) = o.content else { throw XCTSkip("no master image") }
        let w = 300, h = 410
        let sheet = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let obj = OfficeMasterObject(frame: sheet, content: .image(cover))
        let pg = OfficeMasterPage(section: 1, appliesTo: .defaultPages, objects: [obj])
        let c = MasterPageContent(pages: [pg], sectionsHidingMasterPage: [],
                                  theme: RenderTheme(baseFontSize: 13),
                                  documentDefaultFontSize: 11, pageContentWidth: 200)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let g = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        NSColor.white.setFill(); sheet.fill()
        let f = NSAffineTransform(); f.translateX(by: 0, yBy: CGFloat(h)); f.scaleX(by: 1, yBy: -1); f.concat()
        MasterPagePainter.draw(c, sheets: [sheet], totalPages: 1, visibleRect: sheet)
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
        // The SOURCE, as the document stores it — the only reference for which way up it belongs.
        if let tiff = cover.tiffRepresentation,
           let srcRep = NSBitmapImageRep(data: tiff),
           let srcPng = srcRep.representation(using: .png, properties: [:]) {
            try srcPng.write(to: URL(fileURLWithPath: out + ".source.png"))
            print("PROBE wrote \(out).source.png")
        }
        print("PROBE wrote \(out)")
    }
}

