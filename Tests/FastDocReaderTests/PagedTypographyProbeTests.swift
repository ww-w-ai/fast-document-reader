import XCTest
@testable import FastDocReader

/// The instrument behind the paged-typography numbers, kept for `DocxFontSlotProbeTests`' reason:
/// a figure quoted in a report has to be re-derivable by running something. It prints; it asserts
/// only what must hold of ANY corpus, because the counts belong to whichever documents are on the
/// machine.
///
/// Everything goes through `DocumentTypes.readOffice` / `HwpReader.read` — invariant 29: a number
/// taken off a parser says nothing about what the application produces, and those are also where
/// `resolvingFontSubstitution()` runs, so what this counts is what `OfficeTextBuilder` is handed.
///
/// `FMD_PAGED_PROBE=<colon-separated paths>` — any mix of .docx/.odt/.hwp/.hwpx.
final class PagedTypographyProbeTests: XCTestCase {
    func testHeadingWeightAndSizeProvenance() throws {
        let paths = (ProcessInfo.processInfo.environment["FMD_PAGED_PROBE"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        try XCTSkipIf(paths.isEmpty, "set FMD_PAGED_PROBE=<path:path:…> to measure real documents")
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            let data = try Data(contentsOf: url)
            let result: OfficeReadResult
            let defaultBody: CGFloat
            if DocumentTypes.isHwp(ext) {
                result = try HwpReader.read(data)
                defaultBody = result.defaultBodyFontSize
            } else {
                let archive = try ZipArchive(data: data)
                result = try DocumentTypes.readOffice(archive, extension: ext)
                defaultBody = DocumentTypes.officeDefaultBodyFontSize(archive, extension: ext)
            }
            report(name: url.lastPathComponent + " [\(ext)]", result: result, defaultBody: defaultBody)
        }
    }

    private func report(name: String, result: OfficeReadResult, defaultBody: CGFloat) {
        var headings = 0, headingsAnyBold = 0, headingsAllBold = 0, headingsWithSize = 0
        var bodyRuns = 0, fractionalSizes = 0
        var listItems = 0, listItemsFirstSpanSized = 0
        var tables = 0, headerRowTables = 0
        var pictures = 0, picturesWiderThanPage = 0
        var widestPicture: CGFloat = 0
        let page = result.pageContentWidth ?? 0

        func walk(_ blocks: [OfficeBlock]) {
            for b in blocks {
                switch b {
                case let .heading(_, spans, _, _, _, _):
                    headings += 1
                    let real = spans.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                    if real.contains(where: { $0.bold }) { headingsAnyBold += 1 }
                    if !real.isEmpty, real.allSatisfy({ $0.bold }) { headingsAllBold += 1 }
                    if real.contains(where: { $0.fontSize != nil }) { headingsWithSize += 1 }
                    count(real)
                case let .paragraph(spans, _, _, _, _):
                    count(spans)
                case let .listItem(_, _, spans, _, _, _, _, _):
                    listItems += 1
                    if spans.first(where: { !$0.text.isEmpty })?.fontSize != nil { listItemsFirstSpanSized += 1 }
                    count(spans)
                case let .table(rows, headerRows, _, _):
                    tables += 1
                    if headerRows > 0 { headerRowTables += 1 }
                    for row in rows { for cell in row { walk(cell.blocks) } }
                case let .image(_, size, _), let .unsupportedGraphic(_, size, _):
                    pictures += 1
                    widestPicture = max(widestPicture, size.width)
                    if page > 0, size.width > page { picturesWiderThanPage += 1 }
                case .formula: break
                }
            }
        }
        func count(_ spans: [Span]) {
            for s in spans {
                bodyRuns += 1
                if let size = s.fontSize, size != size.rounded() { fractionalSizes += 1 }
            }
        }
        walk(result.blocks)

        print("[paged-probe] \(name)")
        print("[paged-probe]   page=\(page) defaultBody=\(defaultBody)")
        print("[paged-probe]   headings=\(headings) anyBold=\(headingsAnyBold) allBold=\(headingsAllBold) withOwnSize=\(headingsWithSize)")
        print("[paged-probe]   spans=\(bodyRuns) fractionalSizes=\(fractionalSizes)")
        print("[paged-probe]   listItems=\(listItems) firstSpanSized=\(listItemsFirstSpanSized)")
        print("[paged-probe]   tables=\(tables) withHeaderRows=\(headerRowTables)")
        print("[paged-probe]   pictures=\(pictures) widerThanPage=\(picturesWiderThanPage) widest=\(widestPicture)")
    }
}

/// Measures what a text container of the PAGED width actually does with an attachment wider than
/// itself — the question invariant-46's "may a picture bleed" decision turns on. Kept because the
/// answer ("it overflows the container, and the text view's own frame is what clips it") is not
/// derivable from any documentation and had to be measured.
final class PagedBleedProbeTests: XCTestCase {
    func testAnOversizeAttachmentOverflowsTheContainerAndIsClippedByTheFrame() {
        let page: CGFloat = 451.3
        let inset: CGFloat = 32          // DocumentWindowController.minSideInset
        for authoredWidth in [page, page + 40, page + 144, page * 1.5] {
            let att = NSTextAttachment()
            att.bounds = NSRect(x: 0, y: 0, width: authoredWidth, height: 100)
            att.attachmentCell = SizedAttachmentCell(reservedSize: CGSize(width: authoredWidth, height: 100))
            let s = NSMutableAttributedString(attachment: att)
            s.append(NSAttributedString(string: "\n"))

            let storage = NSTextStorage(attributedString: s)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: page, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 5
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
            let drawableRight = page + 2 * inset          // the text view's frame width
            print("[bleed-probe] authored=\(authoredWidth) usedWidth=\(used.width) glyphMaxX=\(glyph.maxX) " +
                  "container=\(page) drawableMaxX=\(drawableRight - inset) fitsInFrame=\(glyph.maxX + inset <= drawableRight)")
        }
    }

    /// The decisive one: the reported rects above are CLAMPED to the container, so they say nothing
    /// about pixels. This draws a real `NSTextView` in the paged geometry and finds the rightmost
    /// pixel actually painted.
    func testHowFarAnOversizePictureIsActuallyPainted() {
        let page: CGFloat = 451.3
        let inset: CGFloat = 32
        // The last two are CONTROLS: the same oversize picture in a container wide enough to hold it.
        // Without them "it stopped at 482" proves nothing — it could be the frame, the bitmap, or the
        // probe itself.
        for (authoredWidth, container) in [(page - 40, page), (page, page), (page + 30, page),
                                           (page + 100, page), (page + 200, page),
                                           (page + 100, page + 100), (page + 200, page + 200)] {
            let red = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { r in
                NSColor.red.setFill(); r.fill(); return true
            }
            let att = NSTextAttachment()
            att.image = red
            att.bounds = NSRect(x: 0, y: 0, width: authoredWidth, height: 40)
            let s = NSMutableAttributedString(attachment: att)
            s.append(NSAttributedString(string: "\n"))

            // Exactly `DocumentWindowController.settleReadingColumn`'s paged branch.
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: container + 2 * inset, height: 200))
            tv.textContainerInset = NSSize(width: inset, height: 12)
            tv.textContainer?.containerSize = NSSize(width: container, height: .greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = false
            tv.autoresizingMask = []
            tv.backgroundColor = .white
            tv.textStorage?.setAttributedString(s)
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)

            guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { continue }
            tv.cacheDisplay(in: tv.bounds, to: rep)
            var rightmost: CGFloat = -1
            for x in stride(from: 0, to: Int(rep.pixelsWide), by: 1) {
                var found = false
                for y in 0..<Int(rep.pixelsHigh) where !found {
                    if let c = rep.colorAt(x: x, y: y), c.redComponent > 0.5,
                       c.greenComponent < 0.4, c.blueComponent < 0.4 { found = true }
                }
                if found { rightmost = CGFloat(x) * (tv.bounds.width / CGFloat(rep.pixelsWide)) }
            }
            print("[paint-probe] authored=\(authoredWidth) container=\(container) frame=\(tv.bounds.width) " +
                  "rightmostPaintedX=\(rightmost) containerRightEdge=\(inset + container) " +
                  "wouldReachIfUnclipped=\(inset + 5 + authoredWidth)")
        }
    }
}

/// What a real document's headings are actually DRAWN in once the paged builder has run — the
/// end-to-end check behind the "a heading whose bold came from its STYLE is silently un-bolded"
/// finding. Reads through `DocumentTypes.readOffice` (invariant 29) and builds through the real
/// `OfficeTextBuilder.build` in the paged shape `MarkdownDocument.render` produces.
final class PagedHeadingWeightProbeTests: XCTestCase {
    func testHeadingWeightsOnRealDocuments() throws {
        let paths = (ProcessInfo.processInfo.environment["FMD_PAGED_PROBE"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        try XCTSkipIf(paths.isEmpty, "set FMD_PAGED_PROBE=<path:path:…>")
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            guard !DocumentTypes.isHwp(ext) else { continue }
            let archive = try ZipArchive(data: try Data(contentsOf: url))
            let result = try DocumentTypes.readOffice(archive, extension: ext)
            let defaultBody = DocumentTypes.officeDefaultBodyFontSize(archive, extension: ext)
            guard let page = result.pageContentWidth else { continue }

            let out = OfficeTextBuilder.build(result.blocks, theme: RenderTheme.current(size: defaultBody),
                                              columnWidth: page, documentDefaultFontSize: defaultBody,
                                              pageContentWidth: page)
            var headingChars = 0, boldChars = 0
            out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { v, r, _ in
                guard v != nil, r.length > 0 else { return }
                out.enumerateAttribute(.font, in: r) { f, fr, _ in
                    guard let font = f as? NSFont else { return }
                    headingChars += fr.length
                    let w = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])
                        .flatMap { $0[.weight] as? CGFloat } ?? 0
                    if font.fontDescriptor.symbolicTraits.contains(.bold) || w >= 0.2 { boldChars += fr.length }
                }
            }
            print("[weight-probe] \(url.lastPathComponent.prefix(40)): headingChars=\(headingChars) " +
                  "drawnBoldOrHeavier=\(boldChars) (\(headingChars == 0 ? 0 : boldChars * 100 / headingChars)%)")
        }
    }
}

/// The exact blast radius of "a paged heading is based on the BODY weight and `Span.bold` decides".
/// A heading span that got a resolved SUBSTITUTE is immune — `FontSubstitutionResolver` probes a
/// heading at `.semibold` and the builder uses that descriptor verbatim (it must not be re-traited),
/// so the base font never reaches it. Only spans with NO substitute change, and among those only the
/// ones whose runs do not say bold.
final class PagedHeadingBlastRadiusProbeTests: XCTestCase {
    func testHowManyHeadingCharsActuallyChangeWeight() throws {
        let paths = (ProcessInfo.processInfo.environment["FMD_PAGED_PROBE"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        try XCTSkipIf(paths.isEmpty, "set FMD_PAGED_PROBE=<path:path:…>")
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            let result: OfficeReadResult
            if DocumentTypes.isHwp(ext) {
                result = try HwpReader.read(try Data(contentsOf: url))
            } else {
                result = try DocumentTypes.readOffice(try ZipArchive(data: try Data(contentsOf: url)),
                                                      extension: ext)
            }
            var total = 0, substituted = 0, freeAndBold = 0, freeAndNotBold = 0
            func walk(_ blocks: [OfficeBlock]) {
                for b in blocks {
                    switch b {
                    case let .heading(_, spans, _, _, _, _):
                        for s in spans {
                            let n = s.text.count
                            total += n
                            if s.resolvedFontDescriptor != nil { substituted += n }
                            else if s.bold { freeAndBold += n }
                            else { freeAndNotBold += n }
                        }
                    case let .table(rows, _, _, _):
                        for row in rows { for c in row { walk(c.blocks) } }
                    default: break
                    }
                }
            }
            walk(result.blocks)
            print("[radius-probe] \(url.lastPathComponent.prefix(38)): headingChars=\(total) " +
                  "immuneSubstituted=\(substituted) staysBold=\(freeAndBold) " +
                  "SEMIBOLD→REGULAR=\(freeAndNotBold)")
        }
    }
}
