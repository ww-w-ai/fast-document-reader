import XCTest
import AppKit
@testable import FastDocReader

/// Real-document confirmation that A PAGE RESERVING A NOTE BAND ACTUALLY GETS A SHORTER BODY —
/// the half of the note-band contract no synthetic fixture can see, following this repo's own
/// convention for a real document it does not ship (CLAUDE.md's `FMD_TABLE_PROBE` family).
/// `PagedTableNoteBandTests` pins the arithmetic; this pins that the arithmetic is REACHED.
///
/// `FMD_FOOTNOTE_DRAW_PROBE=<file>` — a real `.hwp`/`.hwpx`/`.docx`/`.odt` that cites footnotes.
/// The document this was written against (`refs/rhwp/samples/2010-01-06.hwp`) is the sharpest case
/// in a 31-document footnote corpus: nine sheets, each carrying a ~686pt table and a five-note band
/// of 286pt on a 700pt body.
///
/// **Why a probe and not a unit test.** The defect was an ORDERING one — `settlePagedTablesFully`
/// settled the tables, then the notes, and never re-asked the tables. At the moment the table pass
/// ran nothing had reserved a band, so every table was judged against the whole sheet, declared to
/// fit, and left where it stood. Nothing about that is visible in either rule on its own: both were
/// individually correct, and only running them in the wrong order against a real layout produces it.
/// MEASURED before the alternating loop: sheet 3's table ran to y=802 of an 841.9pt sheet, drawn
/// line for line through the four note lines beneath it, and 27 of the document's 30 notes could be
/// read out of the printed page. After: **30 of 30**, and no sheet overruns.
final class FootnoteBandRealFileProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PageViewOptionsStore.startingOptions = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    func testNoBodyLineIsDrawnIntoItsPagesNoteBand() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_FOOTNOTE_DRAW_PROBE"] else {
            throw XCTSkip("set FMD_FOOTNOTE_DRAW_PROBE=<office file citing footnotes> to run this")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.textView.postsFrameChangedNotifications = false
        wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        wc.updateTextInset()

        guard !wc.footnotes.isEmpty else {
            throw XCTSkip("fixture cites no footnote — nothing for this probe to prove")
        }
        guard wc.pageBandDelegate.paginates else {
            throw XCTSkip("fixture is not paged — a note band has no page to sit at the foot of")
        }

        // The SAME settle printing uses, which is where the ordering defect lived. Driving the
        // asynchronous walk instead would test the other path, whose `||` chain re-asks the tables
        // every round and never had this defect.
        wc.settlePagedTablesFully()

        let delegate = wc.pageBandDelegate
        print("PROBE bands=\(delegate.noteBands.sorted { $0.key < $1.key })")
        print("PROBE pages=\(wc.footnotePages.sorted { $0.key < $1.key })")
        guard !delegate.noteBands.isEmpty else {
            throw XCTSkip("no page reserved a note band — the fixture's notes are all on unpaged flow")
        }

        // EVERY PAGE THAT CITES A NOTE MUST RESERVE ONE. The assignment is frozen with the bands
        // (invariant 98), so a page in one and not the other is the two halves of the ruling having
        // drifted apart — which draws a note on a page that left it no room.
        for (page, numbers) in wc.footnotePages where !numbers.isEmpty {
            XCTAssertNotNil(delegate.noteBands[page],
                            "page \(page) cites notes \(numbers) and reserves nothing for them")
        }

        // IS EACH NOTE ON THE PAGE THAT CITES IT? The drawn assignment is the one the ruling froze;
        // the true one is where the markers ACTUALLY ended up in the layout that shipped. Derived
        // here from the definition rather than by calling back into the code under test, and by the
        // same arithmetic every other rule uses (`PageBandLayoutDelegate.page(of:leadingBand:pitch:)`).
        do {
            let lm = try XCTUnwrap(wc.textView.layoutManager)
            let storage = try XCTUnwrap(wc.textView.textStorage)
            let pitch = PagePagination.pitch(pageContentHeight: delegate.pageContentHeight,
                                             band: delegate.band)
            if pitch > 0 {
                var truth: [Int: Int] = [:]      // note number -> page its marker landed on
                var seen = Set<Int>()
                storage.enumerateAttribute(MDAttr.footnoteRef,
                                           in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    guard let n = (value as? NSNumber)?.intValue, !seen.contains(n) else { return }
                    let glyph = lm.glyphIndexForCharacter(at: range.location)
                    let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let page = PageBandLayoutDelegate.page(of: frag.minY,
                                                           leadingBand: delegate.leadingBand, pitch: pitch)
                    guard page >= 0 else { return }
                    seen.insert(n)
                    truth[n] = Int(page)
                }
                var drawn: [Int: Int] = [:]
                for (page, numbers) in wc.footnotePages { for n in numbers { drawn[n] = page } }
                let judged = truth.keys.filter { drawn[$0] != nil }
                let onOwnPage = judged.filter { truth[$0] == drawn[$0] }
                print("PROBE notes with a located marker=\(truth.count) drawn=\(drawn.count) " +
                      "judged=\(judged.count) onItsOwnPage=\(onOwnPage.count)")
            }
        }

        let lm = try XCTUnwrap(wc.textView.layoutManager)
        let container = try XCTUnwrap(wc.textView.textContainer)
        lm.ensureLayout(for: container)
        let pitch = PagePagination.pitch(pageContentHeight: delegate.pageContentHeight,
                                         band: delegate.band)
        try XCTSkipIf(pitch <= 0, "no pitch — nothing is paged")

        // A piece taller than the body it sits on has nowhere to be carried and is broken where it
        // stands, overrunning honestly — `PageBandLayoutDelegate.pushWholeTable` says so in as many
        // words. Those lines are counted and reported rather than asserted on; every OTHER line is
        // the contract.
        func insideOversized(_ location: Int) -> Bool {
            delegate.oversizedPieces.contains { location >= $0.key && location < $0.value }
        }

        var checked = 0
        var overrunOrdinary: [(page: Int, over: CGFloat)] = []
        var overrunOversized = 0
        var glyph = 0
        while glyph < lm.numberOfGlyphs {
            var effective = NSRange(location: 0, length: 0)
            let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            defer { glyph = max(glyph + 1, NSMaxRange(effective)) }
            let page = PageBandLayoutDelegate.page(of: frag.minY,
                                                   leadingBand: delegate.leadingBand, pitch: pitch)
            guard page >= 0, delegate.noteBands[Int(page)] != nil else { continue }
            checked += 1
            // One point of slack: a line's own rounding, the same order the layout rule's own
            // tolerance works at. The measured defect overran by hundreds of points.
            let over = (frag.maxY - delegate.leadingBand) - delegate.textBottom(ofPage: page)
            guard over > 1 else { continue }
            let location = lm.characterRange(forGlyphRange: effective, actualGlyphRange: nil).location
            if insideOversized(location) {
                overrunOversized += 1
            } else {
                overrunOrdinary.append((Int(page), over))
            }
        }

        print("PROBE lines on a banded page=\(checked)  ordinary overruns=\(overrunOrdinary.count)  " +
              "over-tall-piece overruns=\(overrunOversized)")
        for o in overrunOrdinary.prefix(8) {
            print("PROBE overrun page=\(o.page) by=\(String(format: "%.1f", o.over))pt")
        }
        XCTAssertGreaterThan(checked, 0,
                             "no line was laid out on a page reserving a band — this probe checked nothing")
        XCTAssertEqual(overrunOrdinary.count, 0,
                       "\(overrunOrdinary.count) body lines are drawn into the room their own page " +
                       "reserved for its footnotes")
    }
}
