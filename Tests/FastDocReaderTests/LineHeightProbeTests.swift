import XCTest
import AppKit
@testable import FastDocReader

/// What line height this reader actually lays a real document's body out at, and what it was
/// derived from — the numbers a comparison against Word's own PDF is judged by.
///
/// `FMD_LINEHEIGHT_PROBE=<path to a .docx/.odt/.hwp/.hwpx>`.
final class LineHeightProbeTests: XCTestCase {
    /// Does the page sheet list depend on how much of the document happens to be laid out?
    func testSheetsAgainstLayoutCompleteness() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_LINEHEIGHT_PROBE"] else {
            throw XCTSkip("set FMD_LINEHEIGHT_PROBE")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        let lm = wc.textView.layoutManager!, tc = wc.textView.textContainer!
        lm.ensureLayout(for: tc)
        print("[sheets] 완전 레이아웃: used=\(lm.usedRect(for: tc).height) pages=\(wc.printPageCount) sheets=\(wc.pageSheets.count)")

        // Clicking BELOW the last page puts the caret at the very end — which is where AppKit
        // recomputes its own extra line fragment, the rect `applyTrailingFooterBand` reserved.
        let end = wc.textView.textStorage!.length
        wc.textView.setSelectedRange(NSRange(location: end, length: 0))
        lm.ensureLayout(for: tc)
        print("[sheets] 끝으로 캐럿   : used=\(lm.usedRect(for: tc).height) pages=\(wc.printPageCount) sheets=\(wc.pageSheets.count) extra=\(lm.extraLineFragmentRect)")

        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: wc.textView.textStorage!.length),
                            actualCharacterRange: nil)
        print("[sheets] 무효화 직후 : used=\(lm.usedRect(for: tc).height) pages=\(wc.printPageCount) sheets=\(wc.pageSheets.count)")
        lm.ensureLayout(for: tc)
        print("[sheets] 재레이아웃  : used=\(lm.usedRect(for: tc).height) pages=\(wc.printPageCount) sheets=\(wc.pageSheets.count)")
    }

    /// Does the PRINTED page count come from the reader's own sheets (invariant 59) or from AppKit?
    func testPrintPathPageCount() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_LINEHEIGHT_PROBE"] else {
            throw XCTSkip("set FMD_LINEHEIGHT_PROBE")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        if let tc = wc.textView.textContainer { wc.textView.layoutManager?.ensureLayout(for: tc) }
        wc.applyTrailingFooterBand()
        print("[print] 인쇄 전 : bandActive=\(wc.pageBandDelegate.isActive) printPageCount=\(wc.printPageCount) printSheets=\(wc.printSheets.count) pageSheets=\(wc.pageSheets.count) opts=outline:\(PageViewOptionsStore.current.outline),split:\(PageViewOptionsStore.current.splitTables) pushed=\(wc.pageBandDelegate.pushedTables.count) opened=\(wc.pageBandDelegate.openedBoundaries.count)")

        print("[margin] \(marginReport(wc))")

        // (b): does settling FROM SCRATCH reach a canonical answer, or a third one?
        if let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer,
           let st = wc.textView.textStorage {
            print("[scratch] 리셋 전: pushed=\(wc.pageBandDelegate.pushedTables.count) pages=\(wc.printPageCount)")
            for round in 1...3 {
                wc.pageBandDelegate.pushedTables = [:]
                wc.pageBandDelegate.resetOpenedBoundaries()
                lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: st.length),
                                    actualCharacterRange: nil)
                lm.ensureLayout(for: tc)
                wc.settlePagedTablesFully()
                print("[scratch] 라운드\(round): pushed=\(wc.pageBandDelegate.pushedTables.count) pages=\(wc.printPageCount) used=\(lm.usedRect(for: tc).height)")
            }
        }

        let op = wc.makePrintOperation()   // settles paged tables synchronously, like ⌘P and --pdf
        var range = NSRange(location: 0, length: 0)
        let knows = wc.textView.knowsPageRange(&range)
        print("[print] 인쇄 후 : printPageCount=\(wc.printPageCount) printSheets=\(wc.printSheets.count) knowsPageRange=\(knows) range=\(range)")
        print("[print] paper=\(op.printInfo.paperSize) 여백=\(op.printInfo.topMargin)/\(op.printInfo.bottomMargin)")
        print("[print] pitch=\(PagePagination.pitch(pageContentHeight: wc.pageBandDelegate.pageContentHeight, band: wc.pageBandDelegate.band)) leading=\(wc.pageBandDelegate.leadingBand) trailing=\(wc.pageBandDelegate.trailingBand)")
        if let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer {
            let last = lm.numberOfGlyphs - 1
            print("[print] used=\(lm.usedRect(for: tc).height) lastLineMaxY=\(last >= 0 ? lm.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY : 0) container=\(tc.size.width) frame=\(wc.textView.frame.width)")
        }

        // Actually run it, exactly as `--pdf` does, and see what came out.
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe-\(UUID().uuidString).pdf")
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        XCTAssertTrue(op.run())
        let data = try Data(contentsOf: out)
        let pdf = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        print("[print] 실제 PDF=\(pdf.numberOfPages)쪽")
        if let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer {
            let last = lm.numberOfGlyphs - 1
            print("[print] 인쇄 뒤 : printPageCount=\(wc.printPageCount) used=\(lm.usedRect(for: tc).height) lastLineMaxY=\(last >= 0 ? lm.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY : 0) container=\(tc.size.width) frame=\(wc.textView.frame.width)")
        }
        try? FileManager.default.removeItem(at: out)
    }

    /// How many laid-out lines end below their own page's text bottom — i.e. print inside a margin
    /// (invariant 61/64's metric). Identical arithmetic to `HeadlessPDF`'s copy so the two paths are
    /// comparable number for number.
    private func marginReport(_ wc: DocumentWindowController) -> String {
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer else { return "-" }
        let d = wc.pageBandDelegate
        let pitch = PagePagination.pitch(pageContentHeight: d.pageContentHeight, band: d.band)
        guard pitch > 0 else { return "pitch 0" }
        var over = 0, lines = 0, worst: CGFloat = 0
        var g = 0
        while g < lm.numberOfGlyphs {
            var eff = NSRange()
            let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
            lines += 1
            let page = floor((r.minY - d.leadingBand) / pitch + 0.001)
            let bottom = d.leadingBand + page * pitch + d.pageContentHeight
            if r.maxY > bottom + 0.01 { over += 1; worst = max(worst, r.maxY - bottom) }
            g = max(g + 1, NSMaxRange(eff))
        }
        return "여백 침범 \(over)/\(lines)줄, 최대 초과 \(String(format: "%.2f", worst))pt"
    }

    func testDumpResolvedLineHeights() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_LINEHEIGHT_PROBE"] else {
            throw XCTSkip("set FMD_LINEHEIGHT_PROBE=<path to a document> to measure a real one")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        let storage = wc.textView.textStorage!
        let lm = wc.textView.layoutManager!
        let tc = wc.textView.textContainer!
        lm.ensureLayout(for: tc)

        print("[lineheight] \(url.lastPathComponent) paged=\(wc.isPaged) defaultBody=\(doc.officeDefaultBodyFontSize) grid=\(String(describing: doc.officeLineGridPitch))")

        var shown = 0
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            guard shown < 12, let ps = v as? NSParagraphStyle, r.length > 8 else { return }
            var fonts: [String] = []
            storage.enumerateAttribute(.font, in: r) { fv, fr, _ in
                if let f = fv as? NSFont {
                    let d = String(format: "%@@%.1f(nat %.2f)", f.fontName, f.pointSize, lm.defaultLineHeight(for: f))
                    if !fonts.contains(d) { fonts.append(d) }
                }
                _ = fr
            }
            let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            let natural = font.map { lm.defaultLineHeight(for: $0) } ?? 0
            if shown < 4 { print("[lineheight]   fonts in paragraph: \(fonts.joined(separator: "  "))") }
            if shown == 2 {   // one multi-line body paragraph, line by line
                var i = r.location
                while i < NSMaxRange(r) {
                    var eff = NSRange()
                    let g = lm.glyphIndexForCharacter(at: i)
                    let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
                    let chars = NSRange(location: i, length: max(1, lm.characterIndexForGlyph(at: NSMaxRange(eff)) - i))
                    var onLine: [String] = []
                    storage.enumerateAttribute(.font, in: NSIntersectionRange(chars, r)) { fv, _, _ in
                        if let f = fv as? NSFont {
                            let d = String(format: "%@@%.1f/nat%.2f", f.fontName, f.pointSize, lm.defaultLineHeight(for: f))
                            if !onLine.contains(d) { onLine.append(d) }
                        }
                    }
                    print(String(format: "[lineheight]     line h=%.2f  %@", rect.height, onLine.joined(separator: " + ")))
                    let next = lm.characterIndexForGlyph(at: NSMaxRange(eff))
                    if next <= i { break }
                    i = next
                }
            }
            if shown < 4 {
                storage.enumerateAttribute(.font, in: r) { fv, fr, _ in
                    guard let f = fv as? NSFont, f.fontName.hasPrefix("Helvetica") else { return }
                    let s = (storage.string as NSString).substring(with: fr)
                        .replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
                    print("[lineheight]    ↳ Helvetica run at \(fr) = \"\(s)\"")
                }
            }
            // Every line fragment this paragraph actually occupies.
            var rects: [CGFloat] = []
            var i = r.location
            while i < NSMaxRange(r), rects.count < 4 {
                var eff = NSRange()
                let g = lm.glyphIndexForCharacter(at: i)
                let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
                rects.append(rect.height)
                let next = lm.characterIndexForGlyph(at: NSMaxRange(eff))
                if next <= i { break }
                i = next
            }
            let text = (storage.string as NSString).substring(with: NSRange(location: r.location, length: min(18, r.length)))
                .replacingOccurrences(of: "\n", with: "⏎")
            print(String(format: "[lineheight]  size=%.1f %@ natural=%.2f min=%.2f max=%.2f mult=%.2f spacingBefore=%.1f after=%.1f fragments=%@ | %@",
                         font?.pointSize ?? 0, font?.fontName ?? "-", natural,
                         ps.minimumLineHeight, ps.maximumLineHeight, ps.lineHeightMultiple,
                         ps.paragraphSpacingBefore, ps.paragraphSpacing,
                         rects.map { String(format: "%.2f", $0) }.joined(separator: ","), text))
            shown += 1
            if shown >= 12 { stop.pointee = true }
        }
    }
}
