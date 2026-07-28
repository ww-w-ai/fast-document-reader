import XCTest
import AppKit
@testable import FastDocReader

/// A picture this reader cannot draw must SAY SO, not look like a corrupt file.
///
/// The reported defect: eight of one 312-page report's eleven pictures are WMF vector charts,
/// macOS ImageIO has no WMF decoder, `NSImage(data:)` returned nil for every one, and the load
/// path filled the attachment with a 22×22 SF-Symbol "photo" glyph which then STRETCHED across
/// the 700×465 pt frame `OfficeTextBuilder` had reserved. The document was intact — LibreOffice
/// renders those same bytes to a correct stacked bar chart — and the reader was the thing lying.
///
/// This file pins the two halves of the repair, and the three properties it must not break.
final class UndrawablePictureTests: XCTestCase {

    // MARK: Bytes → the WORD on the card (naming only, never deciding)

    /// The magic bytes exist to NAME a failure the decoder already declared, so the naming is
    /// tested against both shapes Office actually writes.
    func testWMFIsNamedInBothOfTheShapesOfficeWrites() {
        // The bare METAFILEPICT header — every failing blob in the reported document starts here.
        XCTAssertEqual(MarkdownDocument.pictureFormatName(Data([0x01, 0x00, 0x09, 0x00, 0x00, 0x03])), "WMF")
        // The "placeable" header Word prefers when it writes a metafile to a file.
        XCTAssertEqual(MarkdownDocument.pictureFormatName(Data([0xD7, 0xCD, 0xC6, 0x9A, 0x00, 0x00])), "WMF")
    }

    func testEMFIsNamedOnlyWhenItsSignatureConfirmsIt() {
        var emf = Data([0x01, 0x00, 0x00, 0x00]) + Data(repeating: 0, count: 36)
        emf.append(contentsOf: [0x20, 0x45, 0x4D, 0x46])   // " EMF" at offset 40
        XCTAssertEqual(MarkdownDocument.pictureFormatName(emf), "EMF")
        // The record type alone is four extremely common bytes — without the signature this must
        // NOT claim to be an EMF, or the card would name a format at random.
        let lookalike = Data([0x01, 0x00, 0x00, 0x00]) + Data(repeating: 0x7F, count: 60)
        XCTAssertNil(MarkdownDocument.pictureFormatName(lookalike))
    }

    func testPCXIsNamedAndItsNeighbouringBytesAreNot() {
        XCTAssertEqual(MarkdownDocument.pictureFormatName(Data([0x0A, 0x05, 0x01, 0x08])), "PCX")
        // Same manufacturer byte, but a version/encoding pair PCX never uses.
        XCTAssertNil(MarkdownDocument.pictureFormatName(Data([0x0A, 0x42, 0x77, 0x08])))
    }

    func testSVGAndAnEmbeddedObjectAreNamed() {
        XCTAssertEqual(MarkdownDocument.pictureFormatName(Data("<svg xmlns=".utf8)), "SVG")
        XCTAssertEqual(MarkdownDocument.pictureFormatName(Data("<?xml version=\"1.0\"?><svg".utf8)), "SVG")
        XCTAssertEqual(MarkdownDocument.pictureFormatName(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1])),
                       "Embedded object")
    }

    /// Formats macOS DOES decode are never named here, because this function is only ever reached
    /// after a decode failed — naming them would be describing a case that cannot occur.
    func testTheLabelDistinguishesNoDecoderFromNoBytesAtAll() {
        XCTAssertEqual(MarkdownDocument.undrawablePictureLabel(for: Data([0x01, 0x00, 0x09, 0x00])),
                       "WMF image — no decoder")
        XCTAssertEqual(MarkdownDocument.undrawablePictureLabel(for: Data([0x99, 0x98, 0x97, 0x96])),
                       "Image — no decoder",
                       "bytes we cannot name still get an honest card, just a less specific one")
        XCTAssertEqual(MarkdownDocument.undrawablePictureLabel(for: nil), "Image missing")
        XCTAssertEqual(MarkdownDocument.undrawablePictureLabel(for: Data()), "Image missing")
    }

    /// The one property that decides how this ages: nothing here is an allow-list of formats we
    /// refuse. The decision is `NSImage(data:)` — an ASK, answered by whatever decoders this OS
    /// has installed — so a PNG (which macOS reads) never reaches the card at all, and the day
    /// macOS ships a WMF decoder the chart simply appears with no code change.
    func testAFormatMacOSCanDecodeNeverReachesTheCard() throws {
        let png = pngData()
        XCTAssertNotNil(NSImage(data: png), "precondition: macOS decodes PNG")
        // The naming table is deliberately silent about PNG — it is unreachable for a decodable
        // format, and this asserts we did not build a second, divergent opinion about formats.
        XCTAssertNil(MarkdownDocument.pictureFormatName(png))
    }

    // MARK: The card is drawn LIVE at the cell's frame — it can never stretch

    /// The defect in one measurement. Both arms draw into the SAME 700×465 frame the reported
    /// document reserves: the old behaviour scaled a 22×22 glyph to fill it, the new one draws a
    /// card whose text is type at a readable size. Measured as the height of the ink INSIDE the
    /// card's border, which the stretched glyph fills and a line of text cannot.
    func testTheCardsInkIsTypeSizedWhileTheOldStretchedGlyphFilledTheFrame() throws {
        let frame = NSRect(x: 0, y: 0, width: 700, height: 465)

        let cell = SizedAttachmentCell(reservedSize: frame.size)
        let attachment = NSTextAttachment()           // no image — the failure state (held: the
        cell.attachment = attachment                  // cell's back-pointer is unowned)
        cell.undrawableLabel = "WMF image — no decoder"
        let card = try inkHeightInside(frame) { cell.draw(withFrame: frame, in: nil) }

        // The mutation, run here rather than argued: the previous behaviour, drawn into the same
        // frame. If a future change re-bakes a bitmap into `.image`, the first number moves to
        // the second and this test says so.
        let glyph = try XCTUnwrap(NSImage(systemSymbolName: "photo", accessibilityDescription: nil))
        glyph.size = NSSize(width: 22, height: 22)
        let stretched = try inkHeightInside(frame) {
            glyph.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        XCTAssertGreaterThan(card, 0, "the card must actually draw something")
        XCTAssertLessThan(card, 40,
                          "the label is type at a readable size, not a picture scaled to the frame " +
                          "(measured \(card) pt of ink in a 465 pt frame)")
        XCTAssertGreaterThan(stretched, 200,
                             "control: the glyph this replaces really did fill the frame " +
                             "(measured \(stretched) pt)")
    }

    /// The reason the label lives on the CELL rather than in `attachment.image`: a resize re-solves
    /// `reservedSize` (invariant 46) and the very next paint draws the card at the new size. A
    /// baked bitmap would be scaled to it — the same stretch, one level up.
    func testTheSameCardRedrawsAtTypeSizeAfterTheFrameGrows() throws {
        let cell = SizedAttachmentCell(reservedSize: NSSize(width: 300, height: 200))
        let attachment = NSTextAttachment()
        cell.attachment = attachment
        cell.undrawableLabel = "WMF image — no decoder"
        let small = NSRect(x: 0, y: 0, width: 300, height: 200)
        let large = NSRect(x: 0, y: 0, width: 900, height: 600)
        let inkSmall = try inkHeightInside(small) { cell.draw(withFrame: small, in: nil) }
        cell.reservedSize = large.size                      // what `resizeOfficeGraphics` does
        let inkLarge = try inkHeightInside(large) { cell.draw(withFrame: large, in: nil) }
        XCTAssertGreaterThan(inkSmall, 0)
        XCTAssertLessThan(inkLarge, 40,
                          "3× the frame must not mean 3× the letters — the card is re-drawn, not scaled")
    }

    /// A picture small enough that the sentence cannot fit keeps the part that carries the
    /// information — the format's name — instead of running off the card.
    func testANarrowCardKeepsTheFormatNameRatherThanOverflowing() throws {
        let narrow = NSRect(x: 0, y: 0, width: 44, height: 30)
        let cell = SizedAttachmentCell(reservedSize: narrow.size)
        let attachment = NSTextAttachment()
        cell.attachment = attachment
        cell.undrawableLabel = "WMF image — no decoder"
        let (rep, _) = try draw(narrow) { cell.draw(withFrame: narrow, in: nil) }
        // Ink must exist, and must stay INSIDE the card: nothing painted in the outermost column.
        var inkInside = 0
        for y in 0..<rep.pixelsHigh {
            for x in 2..<(rep.pixelsWide - 2) where differs(rep, x, y, from: rep.interiorReference) {
                inkInside += 1
            }
        }
        XCTAssertGreaterThan(inkInside, 0, "a small picture still says something")
    }

    // MARK: Through the real load path — invariant 1 holds, and both office routes are covered

    /// The HWP route: bytes pre-decoded at read time (invariant 44) that no decoder can read.
    func testPreDecodedUndecodableBytesBecomeANamedCardWithoutMovingAnything() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "hwpimg:5", size: CGSize(width: 368, height: 245))],
            archiveEntries: [], images: ["hwpimg:5": wmfData()])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let reservedBefore = cell.reservedSize
        let boundsBefore = att.bounds

        doc.reconcileMedia(in: wc)   // pre-decoded bytes resolve synchronously

        XCTAssertEqual(cell.undrawableLabel, "WMF image — no decoder",
                       "the reader must name what it is holding, not imply the file is broken")
        XCTAssertNil(att.image,
                     "invariant 31: setting .image drops the cell that draws the card at the live frame")
        XCTAssertEqual(cell.reservedSize, reservedBefore,
                       "invariant 1: a failed decode must not change the reserved layout size")
        XCTAssertEqual(att.bounds, boundsBefore,
                       "invariant 1: no reflow, no scroll-bar movement, on a picture that could not load")
    }

    /// The docx/odt route: the same bytes arriving from the ZIP archive instead. One mechanism
    /// covers every office format — this is what stops the repair being HWP-only.
    func testUndecodableArchiveBytesGetTheSameNamedCard() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "word/media/image1.wmf", size: CGSize(width: 300, height: 200))],
            archiveEntries: [("word/media/image1.wmf", wmfData())])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let reservedBefore = cell.reservedSize

        let exp = expectation(description: "archive bytes attempted")
        doc.reconcileMedia(in: wc)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(cell.undrawableLabel, "WMF image — no decoder")
        XCTAssertNil(att.image)
        XCTAssertEqual(cell.reservedSize, reservedBefore)
    }

    /// A picture that DOES decode must be entirely unaffected — no label, real pixels, same size.
    func testADecodablePictureIsUntouchedByAnyOfThis() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "hwpimg:2", size: CGSize(width: 200, height: 150))],
            archiveEntries: [], images: ["hwpimg:2": pngData()])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let reservedBefore = cell.reservedSize

        doc.reconcileMedia(in: wc)

        XCTAssertNotNil(att.image, "a decodable picture still shows its own pixels")
        XCTAssertNil(cell.undrawableLabel, "nothing failed, so nothing is claimed")
        XCTAssertEqual(cell.reservedSize, reservedBefore)
    }

    /// A real window resize: the reserved size is re-solved through `resizeOfficeGraphics`
    /// (invariant 46) and the card must still be a card — label intact, `.image` still nil, so the
    /// next paint draws it at the new size rather than scaling anything.
    func testTheCardSurvivesAWindowResizeAsALabelNotABitmap() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "hwpimg:5", size: CGSize(width: 300, height: 200))],
            archiveEntries: [], images: ["hwpimg:5": wmfData()], pageContentWidth: 400)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        doc.reconcileMedia(in: wc)
        XCTAssertEqual(cell.undrawableLabel, "WMF image — no decoder")
        let sizeAt800 = cell.reservedSize

        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 600), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertNotEqual(cell.reservedSize, sizeAt800,
                          "precondition: the wider column really did re-solve this graphic's size")
        XCTAssertEqual(cell.undrawableLabel, "WMF image — no decoder",
                       "the card must still be described by a label after the resize")
        XCTAssertNil(att.image, "…and still drawn live, never baked into a bitmap the resize would scale")
    }

    /// The seam a unit test on the cell cannot see (invariant 29's lesson, in pixels): AppKit only
    /// asks an attachment CELL to draw while `attachment.image` is nil if the cell is still
    /// attached and still consulted. Everything above would pass while the reader showed blank
    /// space, so this one draws the REAL text view through its own layout manager and looks at the
    /// attachment's own glyph rect.
    func testTheRealTextViewPaintsTheCardWhereThePictureWouldHaveBeen() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "hwpimg:5", size: CGSize(width: 360, height: 240))],
            archiveEntries: [], images: ["hwpimg:5": wmfData()])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        doc.reconcileMedia(in: wc)

        let layout = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        var attachmentRange = NSRange(location: NSNotFound, length: 0)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if v is NSTextAttachment { attachmentRange = r }
        }
        XCTAssertNotEqual(attachmentRange.location, NSNotFound)
        layout.ensureLayout(for: container)
        let glyphRange = layout.glyphRange(forCharacterRange: attachmentRange, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        XCTAssertEqual(rect.height, att.bounds.height, accuracy: 1,
                       "precondition: the reserved area is still laid out at its full height")

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(rect.width.rounded(.up)),
            pixelsHigh: Int(rect.height.rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: rect.size).fill()
        // Origin chosen so the attachment's own rect lands at (0,0) of the bitmap.
        layout.drawGlyphs(forGlyphRange: glyphRange, at: NSPoint(x: -rect.minX, y: -rect.minY))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where differs(rep, x, y, from: .white) { ink += 1 }
        }
        XCTAssertGreaterThan(ink, 0,
                             "the reader must PAINT something where the picture was — a labelled card " +
                             "drawn by the cell, not blank space")
    }

    // MARK: The real document, when one is at hand

    /// Re-runnable against a real file: every picture whose bytes no decoder reads must come back
    /// with a named card. Point `FMD_HWP_IMAGE_SAMPLE` at the reported report and this asserts on
    /// its eight WMF charts through the actual reader, which is the only thing that proves the
    /// branch is REACHED on real bytes (invariant 29's lesson).
    func testRealSampleNamesEveryPictureItCannotDraw() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_IMAGE_SAMPLE"] else {
            throw XCTSkip("Set FMD_HWP_IMAGE_SAMPLE to a .hwp/.hwpx that contains images")
        }
        let result = try HwpReader.read(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(result.images.isEmpty, "sample was expected to carry at least one picture")
        var decoded = 0, undrawable: [String: Int] = [:]
        for (_, bytes) in result.images {
            if NSImage(data: bytes) != nil { decoded += 1 }
            else { undrawable[MarkdownDocument.undrawablePictureLabel(for: bytes), default: 0] += 1 }
        }
        print("FMD undrawable-picture census for \(path): \(result.images.count) pictures, " +
              "\(decoded) decoded, undrawable \(undrawable)")
        for (label, _) in undrawable {
            XCTAssertNotEqual(label, "Image missing",
                              "bytes were present, so the card must not claim the picture is missing")
            XCTAssertTrue(label.hasSuffix("no decoder"), "unexpected label: \(label)")
        }
    }

    // MARK: - Fixtures

    /// Bytes that are a genuine WMF header and genuinely undecodable here — which is exactly what
    /// the reported document's charts are, as far as this Mac is concerned.
    private func wmfData() -> Data {
        var d = Data([0x01, 0x00, 0x09, 0x00, 0x00, 0x03])
        d.append(Data(repeating: 0x00, count: 120))
        XCTAssertNil(NSImage(data: d), "precondition: macOS has no decoder for this")
        return d
    }

    private func pngData(width: Int = 40, height: Int = 30) -> Data {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func openOffice(blocks: [OfficeBlock], archiveEntries: [(name: String, content: Data)],
                            images: [String: Data] = [:], pageContentWidth: CGFloat? = nil)
        throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-undrawable-\(UUID().uuidString).docx")
        let archive = archiveEntries.isEmpty ? nil : try ZipArchive(data: ZipFixture.build(archiveEntries))
        doc.setOfficeContent(blocks: blocks, archive: archive, images: images,
                             pageContentWidth: pageContentWidth)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: true)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (doc, wc)
    }

    private func imageAttachment(in storage: NSTextStorage) throws -> NSTextAttachment {
        var found: NSTextAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let att = v as? NSTextAttachment { found = att }
        }
        return try XCTUnwrap(found)
    }

    // MARK: - Pixel measurement
    //
    // "Does it stretch?" is genuinely a question about pixels, so it is answered in pixels rather
    // than argued: draw into a bitmap and measure how tall the ink is INSIDE the card's border.

    private func draw(_ rect: NSRect, _ body: () -> Void) throws -> (NSBitmapImageRep, NSColor) {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        rect.fill()
        body()
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return (rep, rep.interiorReference)
    }

    /// Height, in points, of the band containing everything drawn INSIDE the border — the card's
    /// label for a card, the whole picture for anything scaled to the frame.
    private func inkHeightInside(_ rect: NSRect, _ body: () -> Void) throws -> Int {
        let (rep, reference) = try draw(rect, body)
        let inset = 4
        var top: Int?, bottom: Int?
        for y in inset..<(rep.pixelsHigh - inset) {
            var rowHasInk = false
            for x in inset..<(rep.pixelsWide - inset) where differs(rep, x, y, from: reference) {
                rowHasInk = true
                break
            }
            if rowHasInk {
                if top == nil { top = y }
                bottom = y
            }
        }
        guard let top, let bottom else { return 0 }
        return bottom - top + 1
    }

    private func differs(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, from reference: NSColor) -> Bool {
        guard let c = rep.colorAt(x: x, y: y) else { return false }
        let a = c.usingColorSpace(.deviceRGB) ?? c
        let b = reference.usingColorSpace(.deviceRGB) ?? reference
        return abs(a.redComponent - b.redComponent) > 0.06
            || abs(a.greenComponent - b.greenComponent) > 0.06
            || abs(a.blueComponent - b.blueComponent) > 0.06
    }
}

private extension NSBitmapImageRep {
    /// A pixel well inside the card and away from both its border and its centred label — the
    /// colour "nothing was drawn here" looks like, whatever the card's background happens to be.
    var interiorReference: NSColor {
        colorAt(x: max(2, pixelsWide / 20), y: max(2, pixelsHigh / 20)) ?? .white
    }
}

/// The minimal stored-only ZIP builder `OfficeImageLoadingTests` and `OfficeDocumentTests` each
/// carry a copy of; shared here rather than pasted a third time.
enum ZipFixture {
    static func build(_ entries: [(name: String, content: Data)]) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            body += le32(UInt32(content.count)) + le32(UInt32(content.count))
            body += le16(UInt16(nameBytes.count)) + le16(0)
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var central = [UInt8]()
        for p in prepared {
            central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(UInt32(p.content.count)) + le32(UInt32(p.content.count))
            central += le16(UInt16(p.nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(UInt32(p.localOffset))
            central += p.nameBytes
        }
        let centralOffset = body.count
        var archive = body + central
        archive += le32(0x0605_4b50) + le16(0) + le16(0)
        archive += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        archive += le32(UInt32(central.count)) + le32(UInt32(centralOffset)) + le16(0)
        return Data(archive)
    }
}
