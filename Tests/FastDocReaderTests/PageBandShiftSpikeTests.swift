import XCTest
import AppKit
@testable import FastDocReader

/// Running-header feasibility spike — NOT the feature, a controlled experiment against this app's
/// REAL TextKit 1 stack (contiguous `NSLayoutManager`, explicit `NSTextContainer`) to answer the one
/// question the whole design rests on BEFORE any production code is written:
/// **can a line fragment be pushed down, and does the typesetter carry every following line with it?**
///
/// Why it matters: a header repeated at every page boundary needs vertical space reserved for it, and
/// the two obvious ways to reserve space are both closed. `NSTextContainer.exclusionPaths` invalidates
/// the whole container per change — invariant 32 measured 45ms with none against 301ms with twelve and
/// that feature was deliberately not shipped. Inserting the band into the text storage splits a
/// paragraph at every boundary and puts the furniture into the real document string, where ⌘F finds it
/// and a copied range carries it. What is left is to move the LINES, which costs no storage mutation
/// and no exclusion path — if AppKit honours it.
///
/// The technique under test is deliberately the delegate, NOT an `NSLayoutManager` subclass override
/// of `setLineFragmentRect`. That method RECORDS a rect the layout manager has already decided on;
/// nothing promises the typesetter places the NEXT line relative to a value changed on the way past,
/// and if it keeps its own cursor a shifted line simply overlaps its successor.
/// `shouldSetLineFragmentRect` is the documented place to modify a rect before it is set. Assertion
/// (b) below is precisely the test of that difference: if the typesetter ignored us, the following
/// lines would not move.
///
/// The rule under test is also the real one, not a toy: pages are a fixed pitch, and a line that would
/// straddle a boundary is pushed whole to the next page's text top. It is computed from the incoming
/// rect rather than from a running counter, so it is idempotent — AppKit re-lays out invalidated
/// ranges from wherever they start, and a counter would double-count on the second pass.
final class PageBandShiftSpikeTests: XCTestCase {

    /// The app's real stack shape: contiguous layout, explicit container width, no padding — the same
    /// three properties `FloatWrapExclusionSpikeTests` pins for the same reason.
    private func makeStack(columnWidth: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    private func body(paragraphs: Int) -> NSAttributedString {
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk. "
        let out = NSMutableAttributedString()
        for i in 0..<paragraphs {
            out.append(NSAttributedString(
                string: String(repeating: sentence, count: 3) + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .paragraphStyle: NSParagraphStyle.default]))
            _ = i
        }
        return out
    }

    private func lineRects(_ layout: NSLayoutManager, _ container: NSTextContainer) -> [NSRect] {
        layout.ensureLayout(for: container)
        var rects: [NSRect] = []
        let glyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    /// Pushes any line that would straddle a page boundary down to the next page's text top.
    /// `pageHeight` is the text region of one page; `band` is the space reserved between one page's
    /// text and the next page's text — in the real feature, footer + gap + header.
    private final class PageBandDelegate: NSObject, NSLayoutManagerDelegate {
        let pageHeight: CGFloat
        let band: CGFloat
        private(set) var shifts = 0
        init(pageHeight: CGFloat, band: CGFloat) {
            self.pageHeight = pageHeight
            self.band = band
        }
        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                           lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                           baselineOffset: UnsafeMutablePointer<CGFloat>,
                           in textContainer: NSTextContainer,
                           forGlyphRange glyphRange: NSRange) -> Bool {
            let pitch = pageHeight + band
            let rect = lineFragmentRect.pointee
            let page = (rect.minY / pitch).rounded(.down)
            let textBottom = page * pitch + pageHeight
            guard rect.maxY > textBottom else { return false }
            let target = (page + 1) * pitch
            let shift = target - rect.minY
            lineFragmentRect.pointee.origin.y += shift
            lineFragmentUsedRect.pointee.origin.y += shift
            shifts += 1
            return true
        }
    }

    /// The whole spike. Same document, same stack, laid out twice — once plainly, once with the
    /// delegate installed — and every claim the design makes about the result is asserted against the
    /// baseline rather than against a hardcoded number, so it stays true if the font metrics move.
    func testPushingALineToTheNextPageCarriesEveryFollowingLineWithIt() throws {
        let column: CGFloat = 400
        let text = body(paragraphs: 40)

        let (plainStorage, plainLayout, plainContainer) = makeStack(columnWidth: column)
        plainStorage.setAttributedString(text)
        let plain = lineRects(plainLayout, plainContainer)
        XCTAssertGreaterThan(plain.count, 60, "the spike needs enough lines to cross several pages")

        // A page short enough that this document crosses it many times, and a band big enough that a
        // failure to reserve it is unmistakable rather than a rounding artefact.
        let lineHeight = plain[1].minY - plain[0].minY
        let pageHeight = (lineHeight * 12).rounded()
        let band: CGFloat = 40

        let (storage, layout, container) = makeStack(columnWidth: column)
        let delegate = PageBandDelegate(pageHeight: pageHeight, band: band)
        layout.delegate = delegate
        storage.setAttributedString(text)
        let paged = lineRects(layout, container)

        XCTAssertEqual(paged.count, plain.count, "paginating must not change how the text WRAPS")
        XCTAssertGreaterThan(delegate.shifts, 2, "the document must cross several page boundaries")

        // (a) THE MECHANISM. If AppKit ignored the modified rect, nothing moved at all.
        XCTAssertGreaterThan(paged.last!.minY, plain.last!.minY,
                             "AppKit ignored the modified line fragment rect — the whole approach is dead")

        // (b) THE TYPESETTER FOLLOWED. Every line after a shifted one must have moved by the same
        // amount, which is what distinguishes "the delegate works" from "one rect was edited and the
        // next line overlapped it".
        let pitch = pageHeight + band
        for (i, rect) in paged.enumerated() {
            let page = (rect.minY / pitch).rounded(.down)
            XCTAssertEqual(rect.minY - plain[i].minY, page * band, accuracy: 0.5,
                           "line \(i) should sit exactly one band lower per page boundary above it")
        }

        // (c) NO LINE STRADDLES A BOUNDARY — the property the feature actually needs, since a header
        // is drawn in the space this reserves.
        for (i, rect) in paged.enumerated() {
            let page = (rect.minY / pitch).rounded(.down)
            XCTAssertLessThanOrEqual(rect.maxY, page * pitch + pageHeight + 0.5,
                                     "line \(i) runs into the band reserved for the page furniture")
        }

        // (d) NOTHING OVERLAPS, which a naive per-rect edit would break immediately.
        for i in 1..<paged.count {
            XCTAssertGreaterThanOrEqual(paged[i].minY, paged[i - 1].maxY - 0.5,
                                        "line \(i) overlaps its predecessor")
        }

        // (e) THE DOCUMENT GREW BY EXACTLY THE RESERVED SPACE, no more and no less.
        let pagesCrossed = (paged.last!.minY / pitch).rounded(.down)
        XCTAssertEqual(paged.last!.maxY - plain.last!.maxY, pagesCrossed * band, accuracy: 0.5,
                       "total height must grow by exactly one band per boundary crossed")
    }

    /// IDEMPOTENCE. AppKit re-lays out an invalidated range starting from wherever that range begins,
    /// so the rule must depend only on the rect it is handed. A version carrying a running counter
    /// passes the test above and then double-shifts the moment anything invalidates mid-document —
    /// which every window resize and every ⌘F does.
    func testRelayingOutFromTheMiddleDoesNotShiftTwice() throws {
        let column: CGFloat = 400
        let text = body(paragraphs: 40)
        let (storage, layout, container) = makeStack(columnWidth: column)
        let lineHeight: CGFloat = 16
        let delegate = PageBandDelegate(pageHeight: (lineHeight * 12).rounded(), band: 40)
        layout.delegate = delegate
        storage.setAttributedString(text)
        let first = lineRects(layout, container)

        layout.invalidateLayout(forCharacterRange: NSRange(location: storage.length / 2,
                                                           length: storage.length - storage.length / 2),
                                actualCharacterRange: nil)
        let second = lineRects(layout, container)

        XCTAssertEqual(first.count, second.count, "re-layout changed the number of lines")
        for i in 0..<min(first.count, second.count) {
            XCTAssertEqual(first[i].minY, second[i].minY, accuracy: 0.5,
                           "line \(i) moved on re-layout — the rule is not idempotent")
        }
    }
}
