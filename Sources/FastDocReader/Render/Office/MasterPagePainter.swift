import AppKit

/// Everything drawing a document's 바탕쪽 needs, gathered the same way `PageBandContent` gathers a
/// running header's — one struct built by the window controller per render, so the draw pass itself
/// looks nothing up.
struct MasterPageContent {
    var pages: [OfficeMasterPage]
    /// Sections that turned their own master page OFF. A veto the document itself declared, so a
    /// cover that says "no 바탕쪽" gets none even though its section declares templates.
    var sectionsHidingMasterPage: Set<Int> = []
    var theme: RenderTheme
    var documentDefaultFontSize: CGFloat
    var pageContentWidth: CGFloat?
}

/// One VISIBLE page's selection question, batched to the engine as ONE call per draw pass rather
/// than once per page — `MasterPagePainter.draw(_:sheets:…)` assembles the batch itself, from the
/// same `sectionOfPage` and veto set it already reads. Mirrors `applicablePage`'s own two
/// arguments beyond the template list (S5C3-04).
struct MasterPageSelectionQuery {
    var pageIndex: Int
    var section: Int?
}

/// Paints the template a Korean document repeats behind every page — the full-page artwork, the tab
/// down the outer edge, the ruled title line and the page number.
///
/// WHY THIS IS NOT `PageBandPainter`. A running header is a flow laid into a band the reader
/// RESERVED between two pages; a master page is a set of pieces pinned to the SHEET, over the body
/// text as often as beside it. So this needs no band, no reservation and no per-page arithmetic of
/// its own: it takes the sheet rectangles `PagePagination` already computed — the same ones the
/// screen draws and the printer prints (invariant 59) — and puts each object where the paper says.
///
/// It is NOT gated on drawing to screen. The page number a reader sees here IS the document
/// (invariant 77: rhwp's own header and footer bands are empty on a body page and the number comes
/// from the master page), so a printout without it would be missing the document's own furniture.
enum MasterPagePainter {

    /// Which template covers page `pageIndex` (0-based) — the same selection a running header makes,
    /// through the same two-case vocabulary: an `.evenPages` template covers the even PAGE NUMBERS
    /// (page index 1, 3, … — the human's page 2, 4, …), and everything else is covered by the
    /// default one. A document with only an even template leaves the odd pages bare, which is what
    /// it asked for.
    static func applicablePage(_ pages: [OfficeMasterPage], pageIndex: Int,
                               section: Int? = nil) -> OfficeMasterPage? {
        // THE SECTION FIRST. A master page belongs to its own section, and a document that flattens
        // every section into one column still shows each section's own pages — so a page is matched
        // to its section's templates and only then to the parity among them. `nil` (a parser that
        // never said where a section starts) falls back to every template there is, which is the
        // single-answer behaviour this had before per-page selection.
        let candidates = section.map { s in pages.filter { $0.section == s } } ?? pages
        guard !candidates.isEmpty else { return nil }
        let isEvenPageNumber = (pageIndex + 1) % 2 == 0
        if isEvenPageNumber, let even = candidates.first(where: { $0.appliesTo == .evenPages }) {
            return even
        }
        return candidates.first { $0.appliesTo == .defaultPages } ?? candidates.first
    }

    /// Draw every visible sheet's template. `sheets` are in the text view's own flipped coordinates
    /// (`DocumentWindowController.printSheets`), which run the same way a master object's own
    /// coordinates do — down from the paper's top-left — so placing one is an addition and nothing
    /// else. `totalPages` is only needed for a `NUMPAGES` field.
    /// `sectionOfPage` answers which section a given page (0-based) is typeset on — see
    /// `DocumentWindowController.sectionOfPage`, which resolves it from where the section markers
    /// landed in the laid-out text. Returning `nil` for a page means "unknown", and that page falls
    /// back to every template rather than to none.
    ///
    /// `hidesPageNumber` answers whether THIS page's own paragraph vetoed a page number
    /// (`DocumentWindowController.hiddenPageNumberPages`) — passed down to the page's `PAGE` field
    /// only; the rest of the template (title, artwork) is untouched. Defaults to "never hidden" for
    /// every caller that has no such veto (docx/odt, and every HWP page that never declared one).
    ///
    /// `templateSelection` is S5C3-04's engine crossing: given every page this pass is about to
    /// draw, it answers each one's applicable template index (or `nil` for "no template applies"),
    /// in ONE call — never once per page, which is the shape the plan rejected twice. `nil` — the
    /// default, and what a document with no engine handle produces — falls back to `applicablePage`
    /// for the whole batch, unchanged from before this parameter existed. A `nil`
    /// ENTRY inside a non-`nil` array is a real engine answer ("no template applies"), not a gap;
    /// it is trusted rather than re-asked of the host.
    static func draw(_ content: MasterPageContent, sheets: [CGRect], totalPages: Int,
                     visibleRect: NSRect, sectionOfPage: (Int) -> Int? = { _ in nil },
                     hidesPageNumber: (Int) -> Bool = { _ in false },
                     displayedPageNumber: (Int) -> Int = { $0 + 1 },
                     templateSelection: (([MasterPageSelectionQuery]) -> [Int?]?)? = nil) {
        guard !content.pages.isEmpty, !sheets.isEmpty else { return }
        // THE VISIBLE BATCH for this draw pass, gathered once and with the section veto already
        // applied — so neither answer below is ever asked about a vetoed page.
        var visible: [(index: Int, sheet: CGRect, section: Int?)] = []
        visible.reserveCapacity(sheets.count)
        for (index, sheet) in sheets.enumerated() where sheet.intersects(visibleRect) {
            let section = sectionOfPage(index)
            // THE SECTION'S OWN VETO, before anything is chosen: a section that hides its master
            // page shows none, however many templates the document declares for it.
            if let section, content.sectionsHidingMasterPage.contains(section) { continue }
            visible.append((index, sheet, section))
        }
        guard !visible.isEmpty else { return }
        // ONE crossing for the whole batch, not one per page.
        let engineAnswers = templateSelection?(
            visible.map { MasterPageSelectionQuery(pageIndex: $0.index, section: $0.section) })
        for (offset, entry) in visible.enumerated() {
            let page: OfficeMasterPage?
            if let engineAnswers, offset < engineAnswers.count {
                if let templateIndex = engineAnswers[offset], content.pages.indices.contains(templateIndex) {
                    page = content.pages[templateIndex]
                } else {
                    page = nil
                }
            } else {
                page = applicablePage(content.pages, pageIndex: entry.index, section: entry.section)
            }
            guard let page else { continue }
            for object in page.objects {
                draw(object, onSheet: entry.sheet, pageIndex: entry.index, totalPages: totalPages,
                     content: content, visibleRect: visibleRect,
                     pageNumberHidden: hidesPageNumber(entry.index),
                     shownPageNumber: displayedPageNumber(entry.index))
            }
        }
    }

    /// A 바탕쪽's artwork is drawn on EVERY page it applies to, on every draw pass, and this is a
    /// draw-time painter with no layout phase to prepare anything in — so whatever these two cases
    /// do, they do sixty times a second while a reader scrolls.
    ///
    /// Measured on the 542-page reference document, by skipping one `case` at a time and re-running
    /// the whole-reader probe: a scrolled viewport cost a median **55.0 ms**, and skipping the image
    /// case alone took it to **16.0 ms**. Skipping the text case took it to 48.5 and the vector case
    /// to 46.8, so neither of those is where the time is — it is the artwork, and it is the DECODE
    /// rather than the composite. An `NSImage` built from compressed bytes holds the bytes, not a
    /// bitmap, and every `draw(in:)` decodes a full page of JPEG again; `NSImage(data:)` in the
    /// `.drawing` case is worse still, since it re-reads the PDF as well.
    ///
    /// So each is decoded ONCE and the decoded form is what gets drawn. Identity is the object's
    /// own — the content is a document's, held for the document's lifetime, so an entry stays valid
    /// as long as anything can ask for it, and a re-read makes new objects that miss and refill.
    /// The cap is a backstop against a session that opens hundreds of documents, not a working-set
    /// estimate: a master page carries a handful of objects.
    ///
    /// This is NOT `MarkdownDocument.officeImageCache`: that one is keyed by the id a BLOCK carries
    /// and answers "what pixels belong at this attachment", which is a different question from
    /// "what have I already decoded" and is asked on a different path (invariant 1's lazy pixels).
    /// How many times artwork has been scaled to a drawn size — the deterministic axis the gate in
    /// `MasterPageArtworkCacheTests` reads, for the reason invariant 113 gives: the PIXELS are the
    /// same either way, so the whole suite stays green if someone scales it again every frame, and
    /// the only thing that moves is the cost.
    private(set) static var artworkRasterisations = 0

    /// One cached picture: the scaled copy that gets drawn, and THE SOURCE, which is held
    /// deliberately rather than tidily. `ObjectIdentifier` is an address — let the original go and
    /// the next `NSImage` can be handed the same one, and the cache would then answer with a
    /// picture from a document that is no longer open. Holding the source makes the address
    /// unrecyclable for as long as the entry keyed by it can be found. (Found by the gate below,
    /// which read zero rasterisations on its second test because the first test's artwork had been
    /// freed and its address reused.)
    private final class Artwork {
        let source: NSImage
        let ready: CGImage
        let bytes: Int
        init(source: NSImage, ready: CGImage, bytes: Int) {
            self.source = source
            self.ready = ready
            self.bytes = bytes
        }
    }

    /// What the last artwork blit actually asked the graphics system to do, in DEVICE pixels — the
    /// deterministic axis `MasterPageArtworkCacheTests` judges invariant 121 by. A copy and a
    /// resample put identical pixels on the screen, so nothing else in this suite can tell them
    /// apart; the destination rectangle can.
    private(set) static var lastArtworkBlit: (device: CGRect, pixelWidth: Int, pixelHeight: Int)?

    /// So a gate can tell "this draw pass blitted nothing" from "a previous one did" — the entry
    /// assertion invariant 118's own gate had to be given after passing as a shell.
    static func resetLastArtworkBlit() { lastArtworkBlit = nil }

    /// **Bounded in BYTES, not in entries.** The first version of this cache capped it at 64 entries
    /// and that is not a bound at all: a single scaled artwork was measured at 2652×1940 device
    /// pixels — 20 MB — so sixty-four of them is a third of a gigabyte. The integrated re-measure
    /// caught it, reporting the footprint after a full read-through at 640 MB against 521 at the
    /// start of this run, and it is exactly the trade this app must not make: 10 ms a frame is not
    /// worth hundreds of megabytes.
    ///
    /// `NSCache` rather than a dictionary because eviction has to be least-recently-used — the
    /// artwork a reader is looking at now is the one to keep, and a dictionary can only drop
    /// everything. Its own cost accounting is what enforces the ceiling, so every insert charges.
    /// 24 MB, chosen by measuring the cliff rather than by taste. On the reference document the
    /// median viewport is 40.9 ms at 24 MB, 41.0 at 48 and 40.8 at 32 — flat — and **48.5 at 16 MB
    /// and again at 4**, because one of its artworks alone is 20 MB and a ceiling under that
    /// thrashes on it every frame. So this is the smallest bound that keeps the whole win.
    static let artworkByteCeiling = 24 * 1024 * 1024

    private static let scaledArtwork: NSCache<NSString, Artwork> = {
        let cache = NSCache<NSString, Artwork>()
        cache.totalCostLimit = artworkByteCeiling
        return cache
    }()

    private static var decodedDrawings: [Data: NSImage] = [:]
    private static let cacheCap = 64


    /// The artwork at the size it is actually DRAWN, in device pixels, built once per size.
    ///
    /// Decoding once is not enough — measured. Wrapping the decoded `CGImage` in a fresh `NSImage`
    /// and drawing that took the median viewport from 51.3 ms to 48.6, which says the cost is not
    /// the decode but the RESAMPLE: a full page of artwork is several thousand pixels on a side and
    /// every frame scaled all of it down to a 395pt-wide sheet. Scaling once and blitting the result
    /// is what removes it.
    ///
    /// The pixel size is in the key rather than assumed, so magnifying the page does not serve a
    /// blurry copy: a bigger `ctm` scale is a different key and re-renders at the resolution that
    /// zoom now needs.
    /// Draw a 바탕쪽's artwork — the single most expensive thing a scrolled frame of a paged Korean
    /// document does, and the reason this is not simply `image.draw(in:)`.
    ///
    /// **A blit whose destination is not the bitmap's own pixel count is not a blit.** The cached
    /// copy is a whole number of pixels; the rectangle it is drawn into is fractional (measured on
    /// the reference document: a 1111-pixel bitmap into 1111.18 device pixels), and CoreGraphics
    /// answers that by resampling the entire picture at the context's interpolation quality. So the
    /// draw happens in DEVICE space, in a rectangle that is exactly the bitmap, and the copy is
    /// one-to-one. Measured, 1.69 megapixels, medians of 40: **16.0 ms fractional at high quality,
    /// 7.2 ms one-to-one** — and one-to-one at HIGH quality is 7.25, so alignment is the whole of
    /// it and turning interpolation down is not what buys this (invariant 121).
    ///
    /// Rounding the origin moves the artwork by at most half a device pixel.
    static func drawArtwork(_ image: NSImage, in rect: NSRect) {
        // PAPER GETS THE ORIGINAL. A printed page is rendered at the printer's resolution, not the
        // screen's, and serving it a bitmap sized for a 395pt-wide sheet would put a screen-sized
        // picture into the PDF — a silent fidelity loss that `--pdf` reports no error for and that
        // only shows up on the page. The cache exists to make SCROLLING cheap; printing happens once.
        //
        // The question is PRINTING, not "is this context the screen": `cacheDisplay(in:to:)` draws
        // into a bitmap the caller owns and is how both the reader's own probe and this file's gate
        // make a draw provably happen, and excluding it would turn the cache off in exactly the
        // measurements that judge it. `NSPrintOperation.current` names the one case that matters.
        guard NSPrintOperation.current == nil, let cg = NSGraphicsContext.current?.cgContext else {
            // `respectFlipped` because this view IS flipped and an image drawn without it arrives
            // upside down — the one place that matters in this file, since the artwork here is a
            // whole page of it.
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            return
        }
        let ctm = cg.ctm
        // `CGRect.applying` returns the normalised bounding box, so a flipped view's negative
        // vertical scale comes back as a positive height in device coordinates.
        let device = rect.applying(ctm)
        let pixelWidth = max(1, Int(device.width.rounded()))
        let pixelHeight = max(1, Int(device.height.rounded()))
        guard let ready = artwork(image, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                  points: rect.size) else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            return
        }
        let target = CGRect(x: device.minX.rounded(), y: device.minY.rounded(),
                            width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        lastArtworkBlit = (target, pixelWidth, pixelHeight)
        cg.saveGState()
        cg.concatenate(ctm.inverted())      // out of the view's transform, into device pixels
        // Drawn through CoreGraphics rather than `NSImage`: in device space the bitmap is already
        // upright by CG's own convention, so the flipped-view correction this used to need is not a
        // second rule to keep in step with anything.
        cg.draw(ready, in: target)
        cg.restoreGState()
    }

    /// The artwork at the size it is actually DRAWN, in device pixels, built once per size.
    ///
    /// Decoding once is not enough — measured. Wrapping the decoded `CGImage` in a fresh `NSImage`
    /// and drawing that took the median viewport from 51.3 ms to 48.6, which says the cost is not
    /// the decode but the RESAMPLE: a full page of artwork is several thousand pixels on a side and
    /// every frame scaled all of it down to a 395pt-wide sheet. Scaling once and blitting the result
    /// is what removes it.
    ///
    /// The pixel size is in the key rather than assumed, so magnifying the page does not serve a
    /// blurry copy: a bigger `ctm` scale is a different key and re-renders at the resolution that
    /// zoom now needs.
    private static func artwork(_ image: NSImage, pixelWidth: Int, pixelHeight: Int,
                                points: NSSize) -> CGImage? {
        // The address itself, not its hash: two live objects can share a hash and would then be
        // served each other's artwork. The entry holds the source, so while a key can be found the
        // address behind it cannot have been recycled.
        let address = UInt(bitPattern: Unmanaged.passUnretained(image).toOpaque())
        let key = "\(address)|\(pixelWidth)x\(pixelHeight)" as NSString
        if let hit = scaledArtwork.object(forKey: key) { return hit.ready }
        artworkRasterisations += 1
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(pixelWidth) / max(points.width, 0.01),
                    y: CGFloat(pixelHeight) / max(points.height, 0.01))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        image.draw(in: NSRect(origin: .zero, size: points), from: .zero,
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let ready = ctx.makeImage() else { return nil }
        let bytes = pixelWidth * pixelHeight * 4
        scaledArtwork.setObject(Artwork(source: image, ready: ready, bytes: bytes),
                                forKey: key, cost: bytes)
        return ready
    }

    private static func decoded(_ pdf: Data) -> NSImage? {
        if let hit = decodedDrawings[pdf] { return hit }
        guard let image = NSImage(data: pdf) else { return nil }
        if decodedDrawings.count >= cacheCap { decodedDrawings.removeAll() }
        decodedDrawings[pdf] = image
        return image
    }

    /// ONE object, on ONE sheet — shared by the master page and by an object the document pinned to
    /// the paper at a particular place in the text (`OfficeAnchoredObject`). They differ only in
    /// WHICH pages they appear on; where they go on a page, and how they are drawn, is one rule.
    static func draw(_ object: OfficeMasterObject, onSheet sheet: CGRect, pageIndex: Int,
                     totalPages: Int, content: MasterPageContent, visibleRect: NSRect,
                     pageNumberHidden: Bool = false, shownPageNumber: Int? = nil) {
        let rect = NSRect(x: sheet.minX + object.frame.minX, y: sheet.minY + object.frame.minY,
                          width: object.frame.width, height: object.frame.height)
        guard rect.intersects(visibleRect) else { return }
        // CLIPPED TO ITS OWN SHEET. An object can be taller or wider than the paper it is pinned to
        // — a chapter divider's numeral is 736pt on a 754pt sheet and sits low — and with no clip its
        // ink ran off the paper, across the desk gap and onto the NEXT page, which is where the
        // second running header a reader saw beside it came from. Printing never showed this because
        // each printed page clips to its own sheet by construction; only the screen, which draws
        // every sheet into one continuous view, could. Paper is paper: ink outside it is not the
        // document.
        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        defer { ctx?.restoreGraphicsState() }
        ctx?.cgContext.clip(to: sheet)
        switch object.content {
        case .image(let image):
            drawArtwork(image, in: rect)
        case .drawing(let pdf):
            guard let image = decoded(pdf) else { return }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        case .vector(let graphic):
            guard let pdf = HwpShapeRenderer.pdf(paths: graphic.paths, size: graphic.size),
                  let image = NSImage(data: pdf) else { return }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        case .text(let blocks):
            // Built through the SAME `OfficeTextBuilder` the body and every band use (invariant 29),
            // then given this page's live number by the SAME substitution a running header's page
            // field goes through — the box holds an ordinary `MDAttr.pageNumberField` span, so there
            // is no second field mechanism here.
            let built = OfficeTextBuilder.build(blocks, theme: content.theme,
                                                columnWidth: rect.width,
                                                documentDefaultFontSize: content.documentDefaultFontSize,
                                                pageContentWidth: content.pageContentWidth)
            guard built.length > 0 else { return }
            PageBandPainter.substitutingPageFields(built, page: shownPageNumber ?? (pageIndex + 1),
                                                   totalPages: totalPages,
                                                   hidesPageNumber: pageNumberHidden).draw(in: rect)
        }
    }
}
