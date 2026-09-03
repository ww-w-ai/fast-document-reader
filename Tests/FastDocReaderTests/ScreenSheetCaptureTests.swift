import XCTest
import AppKit
@testable import FastDocReader

/// Draw what the SCREEN shows for a given sheet, straight out of the reader's own text view.
///
/// Synthetic scrolling does not reach this app's window (accessibility blocks the CGEvent), so a
/// screenshot of a running reader cannot be aimed at a chosen page. Drawing the text view's own
/// layer for one sheet's y-range answers the same question and is deterministic: it is the SCREEN
/// path — the text view TextKit laid out — not the print path, which is a separate route and is
/// known to lose content this reader has already typeset.
///
/// `FMD_SHEET_CAPTURE=<file>` with `FMD_SHEET_PAGES=1,19,20,21` and `FMD_SHEET_OUT=<dir>`.
final class ScreenSheetCaptureTests: XCTestCase {
    func testCaptureSheets() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_SHEET_CAPTURE"] else {
            throw XCTSkip("set FMD_SHEET_CAPTURE=<document> to draw sheets from the screen path")
        }
        let outDir = ProcessInfo.processInfo.environment["FMD_SHEET_OUT"] ?? NSTemporaryDirectory()
        let wanted = (ProcessInfo.processInfo.environment["FMD_SHEET_PAGES"] ?? "1")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)

        let tv = wc.textView
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        XCTAssertGreaterThan(pitch, 0, "no page pitch — this document is not paged")

        for page in wanted {
            let rect = NSRect(x: 0, y: CGFloat(page - 1) * pitch, width: tv.frame.width, height: pitch)
            guard let rep = tv.bitmapImageRepForCachingDisplay(in: rect) else { continue }
            tv.cacheDisplay(in: rect, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let dest = URL(fileURLWithPath: outDir).appendingPathComponent("sheet-\(page).png")
            try png.write(to: dest)
            print("PROBE wrote \(dest.path)  (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            if page == 1, ProcessInfo.processInfo.environment["FMD_SHEET_ASSERT_COVER_UPRIGHT"] != nil {
                let left = 0..<(rep.pixelsWide / 2)
                let third = rep.pixelsHigh / 3
                func darkPixels(_ ys: Range<Int>) -> Int {
                    ys.reduce(0) { count, y in
                        count + left.reduce(0) { row, x in
                            guard let color = rep.colorAt(x: x, y: y) else { return row }
                            return row + (max(color.redComponent, color.greenComponent,
                                              color.blueComponent) < 0.4 ? 1 : 0)
                        }
                    }
                }
                let top = darkPixels(0..<third)
                let bottom = darkPixels((rep.pixelsHigh - third)..<rep.pixelsHigh)
                print("PROBE cover dark pixels top=\(top) bottom=\(bottom)")
                XCTAssertGreaterThan(bottom, top,
                                     "the decoded HWP cover is vertically mirrored on screen")
            }

            // WHAT OCCUPIES THE SHEET — an empty page is either nothing laid out there, or one
            // fragment reserving the whole of it. The two have different causes and the picture
            // cannot tell them apart.
            if let lm = tv.layoutManager, let container = tv.textContainer {
                let glyphs = lm.glyphRange(forBoundingRect: rect, in: container)
                let ns = (tv.textStorage?.string ?? "") as NSString
                var idx = glyphs.location
                var shown = 0
                while idx < glyphs.location + glyphs.length, shown < 40 {
                    var eff = NSRange(location: 0, length: 0)
                    let r = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &eff)
                    let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                    var text = ""
                    if cr.location + cr.length <= ns.length {
                        text = ns.substring(with: cr).replacingOccurrences(of: "\n", with: "\\n")
                    }
                    var attach = ""
                    if cr.length > 0, cr.location < ns.length,
                       let a = tv.textStorage?.attribute(.attachment, at: cr.location,
                                                         effectiveRange: nil) {
                        attach = "  ATTACHMENT \(type(of: a))"
                    }
                    // Letter spacing and alignment decide how much text a line of a given width
                    // holds — the two things a fragment count cannot show and a picture only hints at.
                    if cr.length > 0, cr.location < ns.length, let st = tv.textStorage {
                        let kern = (st.attribute(.kern, at: cr.location, effectiveRange: nil) as? CGFloat) ?? 0
                        let fontName = (st.attribute(.font, at: cr.location, effectiveRange: nil) as? NSFont)
                            .map { "\($0.fontName)@\(String(format: "%.1f", $0.pointSize))" } ?? "?"
                        let align = (st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil)
                            as? NSParagraphStyle)?.alignment.rawValue ?? -1
                        let used = lm.lineFragmentUsedRect(forGlyphAt: idx, effectiveRange: nil)
                        attach += String(format: "  kern=%.2f align=%d used=%.1f font=%@",
                                         kern, align, used.width, fontName)
                    }
                    print(String(format: "  sheet %d  y=%.1f h=%.1f chars=%d  %@%@",
                                 page, r.minY, r.height, cr.length,
                                 String(text.prefix(46)), attach))
                    shown += 1
                    idx = eff.length > 0 ? eff.location + eff.length : idx + 1
                }
                print("  sheet \(page): \(shown) fragments shown of glyph range \(glyphs.length)")

                // WHAT COMES NEXT, wherever it landed — the gap's cause is a property of the block
                // that declined to fill this page, not of the page.
                let after = glyphs.location + glyphs.length
                var j = after
                var more = 0
                while j < lm.numberOfGlyphs, more < 8 {
                    var eff = NSRange(location: 0, length: 0)
                    let r = lm.lineFragmentRect(forGlyphAt: j, effectiveRange: &eff)
                    let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                    var text = ""
                    var notes: [String] = []
                    if cr.location + cr.length <= ns.length {
                        text = ns.substring(with: cr).replacingOccurrences(of: "\n", with: "\\n")
                    }
                    if cr.length > 0, cr.location < ns.length, let st = tv.textStorage {
                        st.enumerateAttributes(in: NSRange(location: cr.location, length: 1),
                                               options: []) { attrs, _, _ in
                            for (k, v) in attrs where k != .font && k != .foregroundColor {
                                if k == .paragraphStyle, let ps = v as? NSParagraphStyle {
                                    notes.append(String(format: "ps(before %.1f after %.1f minLH %.1f blocks %d)",
                                                        ps.paragraphSpacingBefore, ps.paragraphSpacing,
                                                        ps.minimumLineHeight, ps.textBlocks.count))
                                } else {
                                    notes.append("\(k.rawValue)")
                                }
                            }
                        }
                    }
                    print(String(format: "  NEXT y=%.1f (sheet %d) h=%.1f chars=%d  %@  [%@]",
                                 r.minY, Int(r.midY / pitch) + 1, r.height, cr.length,
                                 String(text.prefix(40)), notes.joined(separator: " ")))
                    more += 1
                    j = eff.length > 0 ? eff.location + eff.length : j + 1
                }
            }
        }
    }
}
