import XCTest
import AppKit
@testable import FastDocReader

/// HOW FULL each sheet actually is — the one number that decides a paged document's page COUNT.
///
/// A reader that lays out the same lines as its reference but stops each page early needs more
/// sheets for the same text, and neither a line count nor a character count can see that: both
/// agree while the page count diverges. So this walks every line fragment once, buckets it by the
/// sheet the band rule puts it on, and reports the dead space at the head and the foot of each.
///
/// `FMD_SHEET_FILL=<document>`; `FMD_SHEET_FILL_LIST=1` also prints the worst sheets one per line.
final class SheetFillProbeTests: XCTestCase {
    func testSheetFill() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_SHEET_FILL"] else {
            throw XCTSkip("set FMD_SHEET_FILL=<document> to measure how full each sheet is")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)

        let tv = wc.textView
        guard let lm = tv.layoutManager, let container = tv.textContainer else { return }
        lm.ensureLayout(for: container)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        guard pitch > 0 else { throw XCTSkip("not a paged document") }
        // The origin the sheet grid actually starts at — the app's own inset plus the room reserved
        // above the first line for page 0's header. Derived here rather than assumed, because a
        // guessed origin turns an ordinary full page into an apparent 100pt hole.
        // `leadingBand` alone. The delegate shifts a line to `(page + 1) * pitch + leadingBand`,
        // which is a TEXT CONTAINER coordinate and carries no `textContainerOrigin`; adding the
        // view's inset here slides every sheet boundary by the app's padding and reports ordinary
        // full sheets as holes. Measured: the same document read 30 mostly-blank sheets with the
        // inset added and 75 without, and only the second agrees with where the fragments are.
        let origin = d.leadingBand

        var lo: [Int: CGFloat] = [:], hi: [Int: CGFloat] = [:]
        var idx = 0
        while idx < lm.numberOfGlyphs {
            var eff = NSRange(location: 0, length: 0)
            let r = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &eff)
            let page = Int(((r.midY - origin) / pitch).rounded(.down))
            if page >= 0 {
                lo[page] = min(lo[page] ?? .greatestFiniteMagnitude, r.minY)
                hi[page] = max(hi[page] ?? -.greatestFiniteMagnitude, r.maxY)
            }
            idx = eff.length > 0 ? eff.location + eff.length : idx + 1
        }

        let pages = lo.keys.sorted()
        var leadSum: CGFloat = 0, tailSum: CGFloat = 0, worst: [(Int, CGFloat, CGFloat)] = []
        for p in pages {
            let top = origin + CGFloat(p) * pitch
            let bottom = top + d.pageContentHeight - (d.noteBands[p] ?? 0)
            let lead = max(0, lo[p]! - top), tail = max(0, bottom - hi[p]!)
            leadSum += lead; tailSum += tail
            worst.append((p + 1, lead, tail))
        }
        let n = CGFloat(max(1, pages.count))
        print("PROBE sheets measured    : \(pages.count)  pitch \(String(format: "%.2f", pitch))  body \(String(format: "%.2f", d.pageContentHeight))")
        print("PROBE mean head gap      : \(String(format: "%.1f", leadSum / n)) pt")
        print("PROBE mean foot gap      : \(String(format: "%.1f", tailSum / n)) pt")
        print("PROBE dead space total   : \(String(format: "%.0f", leadSum + tailSum)) pt  = \(String(format: "%.1f", (leadSum + tailSum) / d.pageContentHeight)) sheets")
        let bad = worst.filter { $0.1 + $0.2 > d.pageContentHeight / 2 }
        print("PROBE sheets over half empty: \(bad.count)")
        print("PROBE worst 20           : " + bad.sorted { $0.1 + $0.2 > $1.1 + $1.2 }.prefix(20)
            .map { "\($0.0)(h\(Int($0.1))/f\(Int($0.2)))" }.joined(separator: " "))
        if ProcessInfo.processInfo.environment["FMD_SHEET_FILL_LIST"] != nil {
            for (p, l, t) in worst { print("  sheet \(p) head \(String(format: "%.1f", l)) foot \(String(format: "%.1f", t))") }
        }
    }

    /// The SAME four-way split the reference renderer's own tree gives — a line is in a table cell
    /// or it is not, and it carries text or it does not — because a page-count difference is either
    /// more lines or taller lines, and only this split says which.
    func testLineCensus() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_LINE_CENSUS"] else {
            throw XCTSkip("set FMD_LINE_CENSUS=<document> for the four-way line census")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        let tv = wc.textView
        guard let lm = tv.layoutManager, let container = tv.textContainer,
              let st = tv.textStorage else { return }
        lm.ensureLayout(for: container)
        let ns = st.string as NSString
        var n = [String: Int](), h = [String: CGFloat]()
        var idx = 0
        while idx < lm.numberOfGlyphs {
            var eff = NSRange(location: 0, length: 0)
            let r = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &eff)
            let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
            var inCell = false, hasText = false
            if cr.length > 0, cr.location < ns.length {
                let ps = st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil) as? NSParagraphStyle
                inCell = !(ps?.textBlocks.isEmpty ?? true)
                hasText = !ns.substring(with: cr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let key = (inCell ? "cell" : "prose") + (hasText ? "/text" : "/empty")
            n[key, default: 0] += 1
            h[key, default: 0] += r.height
            idx = eff.length > 0 ? eff.location + eff.length : idx + 1
        }
        for key in ["cell/text", "cell/empty", "prose/text", "prose/empty"] {
            let c = n[key] ?? 0, t = h[key] ?? 0
            print(String(format: "PROBE ours %-12@ n=%6d  h~%6.2f  total~%9.0fpt", key as NSString, c, c > 0 ? t / CGFloat(c) : 0, t))
        }
        print("PROBE ours sum           : \(String(format: "%.0f", h.values.reduce(0, +)))pt")
    }

    /// EVERY reserved graphic in the flow, by the height it takes from the page it lands on.
    ///
    /// KEPT although no WorkList row asked for it: this probe is the evidence that killed the
    /// "an in-flow image is not clamped by height" diagnosis, which two rounds of planning were
    /// built on. It answers 0 of 109 attachments taller than a page, tallest 471pt against a
    /// 555.59pt body. Delete it and the attribution's dismissal of that cause has nothing behind it.
    ///
    /// An image is fitted to the reading column by WIDTH (invariant 46) and to nothing by height,
    /// so a picture taller than the page reserves more than a page and pushes whatever shares its
    /// paragraph onto a sheet that then looks empty. A three-sheet sample cannot tell that from a
    /// document that simply has blank pages in it; a census over every attachment can.
    ///
    /// `FMD_ATTACHMENT_CENSUS=<document>`.
    func testAttachmentCensus() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_ATTACHMENT_CENSUS"] else {
            throw XCTSkip("set FMD_ATTACHMENT_CENSUS=<document> for the reserved-graphic census")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        let tv = wc.textView
        guard let lm = tv.layoutManager, let container = tv.textContainer,
              let st = tv.textStorage else { return }
        lm.ensureLayout(for: container)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        let origin = d.leadingBand   // see testSheetFill for why the view's inset is not added
        let body = d.pageContentHeight

        var found: [(sheet: Int, w: CGFloat, h: CGFloat, kind: String)] = []
        st.enumerateAttribute(.attachment, in: NSRange(location: 0, length: st.length)) { value, range, _ in
            guard let a = value as? NSTextAttachment else { return }
            let glyph = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyph.length > 0 else { return }
            let r = lm.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            // The attachment's own bounds IS the space it reserves — asking the cell would need a
            // container and answers the same question one indirection later.
            let size = a.bounds.size
            found.append((Int(((r.midY - origin) / pitch).rounded(.down)) + 1,
                          size.width, size.height, "\(type(of: a.attachmentCell ?? NSTextAttachmentCell()))"))
        }
        // A LINE taller than the page it must fit on — the shape a chapter divider takes when a
        // text box's own paragraph is left in the flow (invariant 31) and its line height is the
        // box's font times the document's line-spacing percent. Such a line can never be laid out
        // on any page, so it always costs its own sheet plus whatever it pushed off the previous
        // one. Counted here beside the attachments because a picture and a line height produce the
        // SAME symptom and only this tells them apart.
        var tall: [(Int, CGFloat, String)] = []
        var gi = 0
        while gi < lm.numberOfGlyphs {
            var eff = NSRange(location: 0, length: 0)
            let r = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &eff)
            if r.height > body {
                let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                let ns = st.string as NSString
                let txt = cr.location + cr.length <= ns.length
                    ? ns.substring(with: cr).replacingOccurrences(of: "\n", with: "") : ""
                tall.append((Int(((r.midY - origin) / pitch).rounded(.down)) + 1, r.height,
                             String(txt.prefix(12))))
            }
            gi = eff.length > 0 ? eff.location + eff.length : gi + 1
        }
        print("PROBE lines taller than a page: \(tall.count)  total \(String(format: "%.0f", tall.reduce(0) { $0 + $1.1 }))pt")
        print("PROBE   -> " + tall.prefix(20).map { "s\($0.0):\(Int($0.1))pt:\($0.2)" }.joined(separator: " "))

        let over = found.filter { $0.h > body }
        let nearly = found.filter { $0.h > body / 2 && $0.h <= body }
        print("PROBE attachments in flow : \(found.count)   page body \(String(format: "%.2f", body))pt")
        print("PROBE taller than a page  : \(over.count)")
        print("PROBE over half a page    : \(nearly.count)")
        print("PROBE tallest 15          : " + found.sorted { $0.h > $1.h }.prefix(15)
            .map { "s\($0.sheet):\(Int($0.w))x\(Int($0.h))" }.joined(separator: " "))
        // The sheets the fill probe reports as more than 400pt empty, so the two measurements can
        // be read against each other instead of assumed to agree.
        let blank = Set([8, 14, 30, 31, 97, 107, 113, 133, 158, 164, 174, 176, 181, 185, 202,
                         236, 240, 241, 261, 301, 335, 339, 340, 352, 354, 377, 378, 435, 458, 496])
        let onBlank = found.filter { blank.contains($0.sheet) || blank.contains($0.sheet + 1) }
        print("PROBE on/just before a >400pt-empty sheet: \(onBlank.count) -> " + onBlank
            .map { "s\($0.sheet):\(Int($0.h))" }.joined(separator: " "))
    }

    /// WHAT IS ON a sheet the reader left mostly blank, and what sits on either side of it.
    ///
    /// A sheet more than 400pt empty has one of two very different stories: nothing was laid out
    /// there, or one thing was laid out that could not share it. The fill probe cannot tell them
    /// apart and a picture cannot either — both look like a blank page. This prints the fragments
    /// actually on each such sheet, plus the one before and the one after, with the height and the
    /// attribute names that decide placement.
    ///
    /// `FMD_BLANK_SHEET_REPORT=<document>`; `FMD_BLANK_SHEET_MIN=<pt>` (default 400).
    func testBlankSheetReport() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_BLANK_SHEET_REPORT"] else {
            throw XCTSkip("set FMD_BLANK_SHEET_REPORT=<document> to itemise the mostly-blank sheets")
        }
        let minDead = CGFloat(ProcessInfo.processInfo.environment["FMD_BLANK_SHEET_MIN"]
            .flatMap { Double($0) } ?? 400)
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        let tv = wc.textView
        guard let lm = tv.layoutManager, let container = tv.textContainer,
              let st = tv.textStorage else {
            // A silent `return` here reads exactly like "no sheet qualified", which is a different
            // answer and sent one run of this probe down the wrong path.
            print("PROBE ABORTED: no layout manager / container / storage")
            return
        }
        lm.ensureLayout(for: container)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        let origin = d.leadingBand
        let ns = st.string as NSString
        // The sheet grid's origin is derived, not assumed — the delegate shifts a line to
        // `(page + 1) * pitch + leadingBand`, which is a TEXT CONTAINER coordinate and carries no
        // `textContainerOrigin`. Adding the view's inset here would slide every sheet boundary by
        // the app's own padding and turn ordinary full sheets into apparent holes. Both candidates
        // are printed so a reader of this output can see which one the data agrees with.
        print("PROBE glyphs=\(lm.numberOfGlyphs) pitch=\(String(format: "%.2f", pitch)) body=\(String(format: "%.2f", d.pageContentHeight))")
        print("PROBE leadingBand=\(String(format: "%.2f", d.leadingBand)) textContainerOrigin.y=\(String(format: "%.2f", tv.textContainerOrigin.y)) originUsed=\(String(format: "%.2f", origin))")
        var firstY: CGFloat = -1
        if lm.numberOfGlyphs > 0 { firstY = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY }
        print("PROBE first fragment y=\(String(format: "%.2f", firstY))  (page 0 top should equal this or be just above it)")
        guard pitch > 0 else { print("PROBE ABORTED: not a paged document"); return }

        // One pass, kept in order, so "the fragment before" is a neighbour in this array rather
        // than a second walk that could disagree with the first about what a fragment is.
        struct Frag { var sheet: Int; var y: CGFloat; var h: CGFloat; var text: String; var notes: String }
        var frags: [Frag] = []
        var i = 0
        while i < lm.numberOfGlyphs {
            var eff = NSRange(location: 0, length: 0)
            let r = lm.lineFragmentRect(forGlyphAt: i, effectiveRange: &eff)
            let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
            var text = "", notes = ""
            if cr.length > 0, cr.location + cr.length <= ns.length {
                text = ns.substring(with: cr).replacingOccurrences(of: "\n", with: "\\n")
                var keys: [String] = []
                st.enumerateAttributes(in: NSRange(location: cr.location, length: 1), options: []) { a, _, _ in
                    for (k, v) in a where k != .foregroundColor {
                        if k == .font, let f = v as? NSFont { keys.append("font=\(f.fontName)@\(Int(f.pointSize))") }
                        else if k == .paragraphStyle, let ps = v as? NSParagraphStyle {
                            keys.append(String(format: "minLH=%.0f before=%.0f after=%.0f blocks=%d",
                                               ps.minimumLineHeight, ps.paragraphSpacingBefore,
                                               ps.paragraphSpacing, ps.textBlocks.count))
                        } else if k != .font { keys.append(k.rawValue) }
                    }
                }
                notes = keys.joined(separator: " ")
            }
            frags.append(Frag(sheet: Int(((r.midY - origin) / pitch).rounded(.down)) + 1,
                              y: r.minY, h: r.height, text: String(text.prefix(34)), notes: notes))
            i = eff.length > 0 ? eff.location + eff.length : i + 1
        }

        var lo: [Int: CGFloat] = [:], hi: [Int: CGFloat] = [:], firstIdx: [Int: Int] = [:], lastIdx: [Int: Int] = [:]
        for (n, f) in frags.enumerated() where f.sheet >= 0 {
            if lo[f.sheet] == nil { lo[f.sheet] = f.y; firstIdx[f.sheet] = n }
            lo[f.sheet] = min(lo[f.sheet]!, f.y)
            hi[f.sheet] = max(hi[f.sheet] ?? -.greatestFiniteMagnitude, f.y + f.h)
            lastIdx[f.sheet] = n
        }
        var bySheet: [Int: [Frag]] = [:]
        for f in frags where f.sheet >= 0 { bySheet[f.sheet, default: []].append(f) }
        var reported = 0
        for sheet in lo.keys.sorted() {
            let top = origin + CGFloat(sheet - 1) * pitch
            let bottom = top + d.pageContentHeight - (d.noteBands[sheet - 1] ?? 0)
            let dead = max(0, lo[sheet]! - top) + max(0, bottom - hi[sheet]!)
            guard dead > minDead else { continue }
            reported += 1
            let on = bySheet[sheet] ?? []
            print(String(format: "PROBE == sheet %d  dead %.0f (head %.0f foot %.0f)  top %.1f bottom %.1f  used [%.1f,%.1f]  fragments %d",
                         sheet, dead, max(0, lo[sheet]! - top), max(0, bottom - hi[sheet]!),
                         top, bottom, lo[sheet]!, hi[sheet]!, on.count))
            if let f = firstIdx[sheet], f > 0 {
                let p = frags[f - 1]
                print(String(format: "PROBE    prev  s%d h=%.0f %@ | %@", p.sheet, p.h, p.text, p.notes))
            }
            for f in on.prefix(6) {
                print(String(format: "PROBE    on    y=%.1f h=%.0f %@ | %@", f.y, f.h, f.text, f.notes))
            }
            if let l = lastIdx[sheet], l + 1 < frags.count {
                let n = frags[l + 1]
                print(String(format: "PROBE    next  s%d h=%.0f %@ | %@", n.sheet, n.h, n.text, n.notes))
            }
        }
        print("PROBE sheets reported    : \(reported)  (dead > \(Int(minDead))pt)")

        // THE ONE NUMBER BOTH SIDES CAN BE MEASURED BY, defined identically: the vertical span a
        // page's content actually occupies (its last line's bottom less its first line's top),
        // summed over pages, beside the line count and the band that held them. Every earlier
        // comparison in this run mixed a fragment HEIGHT on one side with a line ADVANCE on the
        // other, or a per-group mean with a whole-document total, and each time the ratio that came
        // out was wrong. One definition, applied to both, is the only kind of number that settles it.
        var occupied: CGFloat = 0, bandTotal: CGFloat = 0, counted = 0
        for sheet in lo.keys.sorted() {
            occupied += hi[sheet]! - lo[sheet]!
            bandTotal += d.pageContentHeight - (d.noteBands[sheet - 1] ?? 0)
            counted += 1
        }
        print(String(format: "PROBE ours: pages %d  lines %d  occupied span total %.0fpt  band total %.0fpt",
                     counted, frags.count, occupied, bandTotal))
        print(String(format: "PROBE       per page: %.1fpt occupied of %.1fpt band, %.2f lines",
                     occupied / CGFloat(counted), bandTotal / CGFloat(counted),
                     CGFloat(frags.count) / CGFloat(counted)))
        print(String(format: "PROBE       per line: %.2fpt", occupied / CGFloat(max(1, frags.count))))

        // WHERE THE UNUSED BAND GOES. `band - occupied` and `head + foot` are the same quantity only
        // while content stays inside its page. When a line is drawn PAST the page bottom the foot
        // term clamps at zero and the two diverge — so printing both, and the overflow explicitly,
        // says whether a page is under-filled or over-run. They disagreed by 78pt/page on the first
        // reading of this document, which is what put this here.
        var headSum: CGFloat = 0, footSum: CGFloat = 0, overflowSum: CGFloat = 0, overflowing = 0
        for sheet in lo.keys.sorted() {
            let top = origin + CGFloat(sheet - 1) * pitch
            let bottom = top + d.pageContentHeight - (d.noteBands[sheet - 1] ?? 0)
            headSum += max(0, lo[sheet]! - top)
            footSum += max(0, bottom - hi[sheet]!)
            if hi[sheet]! > bottom { overflowSum += hi[sheet]! - bottom; overflowing += 1 }
        }
        print(String(format: "PROBE       head %.0fpt  foot %.0fpt  dead %.0fpt (%.1f sheets)",
                     headSum, footSum, headSum + footSum, (headSum + footSum) / d.pageContentHeight))
        print(String(format: "PROBE       overflow past the page bottom: %.0fpt on %d sheets",
                     overflowSum, overflowing))
        print(String(format: "PROBE       band - occupied = %.0fpt   head+foot = %.0fpt   difference %.0fpt",
                     bandTotal - occupied, headSum + footSum, (bandTotal - occupied) - (headSum + footSum)))
        print("PROBE       rhwp for comparison: pages 394  lines 13896  occupied 189074pt  band 208722pt  13.61pt/line")

        // WHY EACH PAGE STOPPED WHERE IT DID. The foot gap is the single largest cause of this
        // document needing more sheets than its reference, and it has four possible reasons that
        // want four different answers. Only counting them apart says which is worth fixing: a gap
        // the DOCUMENT asked for is not a defect at all, and a gap left by a line that would have
        // fitted is.
        var reason: [String: (n: Int, pt: CGFloat)] = [:]
        func charge(_ key: String, _ pt: CGFloat) {
            var e = reason[key] ?? (0, 0); e.n += 1; e.pt += pt; reason[key] = e
        }
        for sheet in lo.keys.sorted() {
            let top = origin + CGFloat(sheet - 1) * pitch
            let bottom = top + d.pageContentHeight - (d.noteBands[sheet - 1] ?? 0)
            let foot = bottom - hi[sheet]!
            guard foot > 1 else { continue }
            // The first fragment of the NEXT sheet is the thing that declined to fill this one.
            guard let l = lastIdx[sheet], l + 1 < frags.count else { charge("end of document", foot); continue }
            let n = frags[l + 1]
            if n.notes.contains("mdStartsPage") { charge("the document declared a page break", foot) }
            else if n.notes.contains("mdTableKeepsWhole") { charge("a table that may not be split", foot) }
            else if n.notes.contains("blocks=1") || n.notes.contains("blocks=2") { charge("inside a table", foot) }
            else if n.h > foot { charge("the next line is taller than the gap", foot) }
            else { charge("UNEXPLAINED - the next line would have fitted", foot) }
        }
        // THE SPILL SIGNATURE. If a 10% capacity loss is what costs 119 sheets, the mechanism is
        // amplification, not addition: a run of text that just fitted one of the reference's pages
        // overflows ours by a little, and the remainder takes a whole sheet that is then nearly
        // empty. That predicts a population of sheets holding very little content, each following a
        // sheet that ended full. A flat 10% loss with no amplification predicts no such population.
        var spill = 0, spillPt: CGFloat = 0
        let sheets = lo.keys.sorted()
        for sheet in sheets {
            let used = hi[sheet]! - lo[sheet]!
            guard used < 150 else { continue }
            spill += 1; spillPt += d.pageContentHeight - used
        }
        print(String(format: "PROBE sheets holding under 150pt of content: %d  (%.0fpt unused = %.1f sheets)",
                     spill, spillPt, spillPt / d.pageContentHeight))
        var hist = [Int](repeating: 0, count: 6)
        for sheet in sheets {
            let used = hi[sheet]! - lo[sheet]!
            hist[min(5, Int(used / 100))] += 1
        }
        print("PROBE content per sheet, 100pt buckets: " + hist.enumerated()
            .map { "\($0.offset * 100)-\($0.offset * 100 + 99):\($0.element)" }.joined(separator: " "))

        print("PROBE == why each page stopped early")
        for (k, v) in reason.sorted(by: { $0.value.pt > $1.value.pt }) {
            print(String(format: "PROBE    %-46@ %4d sheets  %7.0fpt  = %5.1f sheets",
                         k as NSString, v.n, v.pt, v.pt / d.pageContentHeight))
        }
    }

    /// HOW MUCH HEIGHT AN OBJECT RESERVES that it does not fill.
    ///
    /// Invariant 86 records the approximation this measures: an object the document says HOLDS
    /// space (어울림 / 자연스럽게 / 통과 / 위아래) is kept in the flow as a FULL-WIDTH block, which
    /// reserves more height than HWP's own side-by-side wrap, and the fix for that — a real
    /// exclusion path — was built, measured at 45ms against 301ms, and deliberately not shipped
    /// (invariant 32). So this is not a defect hunting for a cause; it is a known, deliberate
    /// over-reservation whose SIZE on this document was never measured.
    ///
    /// It reports, for every graphic in the flow, the height its line reserves against the height
    /// the graphic itself declares. The difference is what a side-by-side wrap would give back.
    ///
    /// `FMD_WRAP_RESERVE=<document>`.
    func testWrapReservation() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_WRAP_RESERVE"] else {
            throw XCTSkip("set FMD_WRAP_RESERVE=<document> to measure over-reserved graphic height")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let env = ProcessInfo.processInfo.environment
        let w = CGFloat(Double(env["FMD_LINE_DUMP_W"] ?? "") ?? 820)
        let h = CGFloat(Double(env["FMD_LINE_DUMP_H"] ?? "") ?? 640)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: h), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        let tv = wc.textView
        guard let lm = tv.layoutManager, let container = tv.textContainer,
              let st = tv.textStorage else { print("PROBE ABORTED"); return }
        print("PROBE window \(w)x\(h)  sheets=\(wc.pageSheets.count)")
        lm.ensureLayout(for: container)
        let body = wc.pageBandDelegate.pageContentHeight
        let column = container.size.width - 2 * container.lineFragmentPadding

        var n = 0, narrow = 0
        var reserved: CGFloat = 0, declaredArea: CGFloat = 0, recoverable: CGFloat = 0
        st.enumerateAttribute(.attachment, in: NSRange(location: 0, length: st.length)) { value, range, _ in
            guard let a = value as? NSTextAttachment else { return }
            let glyph = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyph.length > 0 else { return }
            let line = lm.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            let size = a.bounds.size
            n += 1
            reserved += line.height
            declaredArea += size.height
            // A graphic narrower than the column is one HWP could have set text beside. The height
            // its line reserves is then height a side-by-side wrap would have shared.
            if size.width < column * 0.75 { narrow += 1; recoverable += line.height }
        }
        print(String(format: "PROBE graphics in flow    : %d   column %.1fpt   page body %.1fpt", n, column, body))
        print(String(format: "PROBE height reserved     : %.0fpt = %.1f sheets", reserved, reserved / body))
        print(String(format: "PROBE height declared     : %.0fpt", declaredArea))
        print(String(format: "PROBE narrower than 75%% of the column: %d  reserving %.0fpt = %.1f sheets",
                     narrow, recoverable, recoverable / body))
    }

    /// EVERY line this reader lays out, as `sheet<TAB>y<TAB>height<TAB>text`, for diffing against
    /// the reference renderer's own per-page tree.
    ///
    /// Written because four rounds of AGGREGATE comparison in one session each produced a confident
    /// ratio that was wrong: a fragment height against a line advance, a per-group mean against a
    /// whole-document total, and a span-per-line that a table's side-by-side cells inflate on
    /// whichever side has wider tables. Two renderers placing the same text can be compared line for
    /// line, and a line-for-line comparison cannot be biased by how either side aggregates.
    ///
    /// `FMD_LINE_DUMP=<document>` and `FMD_LINE_DUMP_OUT=<file>`.
    func testLineDump() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_LINE_DUMP"],
              let out = ProcessInfo.processInfo.environment["FMD_LINE_DUMP_OUT"] else {
            throw XCTSkip("set FMD_LINE_DUMP=<document> and FMD_LINE_DUMP_OUT=<file>")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        let tv = wc.textView
        guard let lm = tv.layoutManager, let container = tv.textContainer,
              let st = tv.textStorage else { print("PROBE ABORTED"); return }
        lm.ensureLayout(for: container)
        let d = wc.pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        let origin = d.leadingBand
        let ns = st.string as NSString

        var lines: [String] = []
        var i = 0
        while i < lm.numberOfGlyphs {
            var eff = NSRange(location: 0, length: 0)
            let r = lm.lineFragmentRect(forGlyphAt: i, effectiveRange: &eff)
            let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
            var text = ""
            if cr.length > 0, cr.location + cr.length <= ns.length {
                text = ns.substring(with: cr)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
            }
            let sheet = Int(((r.midY - origin) / pitch).rounded(.down)) + 1
            lines.append(String(format: "%d\t%.1f\t%.1f\t%@", sheet, r.minY, r.height, text))
            i = eff.length > 0 ? eff.location + eff.length : i + 1
        }
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("PROBE wrote \(lines.count) lines to \(out)")
    }
}
