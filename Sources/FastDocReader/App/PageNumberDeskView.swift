import AppKit

/// The page number, written LARGE on the desk beside each sheet — outside the page outline, on the
/// grey, where it cannot touch the paper: the owner's placement, *"아예 페이지 아웃라인 밖에 회색
/// 영역에 크게"*.
///
/// **It is not part of the document, structurally rather than by discipline.** A paged document's text
/// view is pinned to the PAPER's width (`pinPagedFrameWidth`), so it cannot paint outside the sheet at
/// all — which is exactly why this lives here instead: a sibling laid over the scroll view, with no
/// text storage, no layout manager and no way to ask a question that makes layout. The strongest form
/// of "information about the document must not be able to change the document".
///
/// Page positions come from the ONE place that already knows them — `DocumentWindowController.pageSheets`,
/// the same rectangles the outline draws and the printer prints (invariants 59/60f) — converted from
/// the text view's coordinates by AppKit, so scrolling, magnification and page centring are handled
/// where they are already solved rather than re-derived here.
final class PageNumberDeskView: NSView {

    /// Unowned-safe: the controller owns this view, and the view is removed with it. Read only from
    /// `draw`, and read through the same weak-mirror discipline invariant 63 demands of a draw path.
    weak var controller: DocumentWindowController?

    override var isFlipped: Bool { true }
    /// Pure furniture — never takes a click, so selecting text through it still works.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let wc = controller else { return }
        let textView = wc.textViewForDesk
        let sheets = wc.pageSheets
        guard !sheets.isEmpty else { return }
        for (index, sheet) in sheets.enumerated() {
            // The sheet's own top-left, in THIS view's coordinates — AppKit applies the scroll and
            // the magnification, so a zoomed page keeps its number beside it.
            let corner = convert(NSPoint(x: sheet.minX, y: sheet.minY), from: textView)
            guard let plan = placement(number: index + 1, deskWidth: corner.x) else { continue }
            // Dropped below the sheet's top rule so the number reads as sitting BESIDE the page rather
            // than hanging off it ("왼쪽에 여유있는 여백 포함해서… 페이지 윗 라인에 너무 딱 붙이지 말 것").
            let origin = NSPoint(x: plan.x, y: corner.y + 18)
            let box = NSRect(origin: origin, size: plan.text.size())
            guard box.intersects(dirtyRect) else { continue }
            plan.text.draw(at: origin)
        }
    }

    /// Where this page's number goes, and how big — decided from the DESK's own width, because the
    /// desk is what is left of the window after the paper and there may be none of it.
    ///
    /// Three answers in one rule, and the last two exist because the first one silently drew nothing:
    /// a 72pt number needs ~90pt of desk, and at the reading zoom the paper routinely fills the
    /// window, so on the owner's screen the numbers were invisible unless the window was very wide
    /// ("좌우 여백이 아주 크지 않으면 안 보임").
    ///
    /// 1. Room on the desk → full size, clear of the paper's edge.
    /// 2. Some desk, not enough → the next size down, to a floor of 24pt (below that it is no longer
    ///    the landmark it exists to be).
    /// 3. No usable desk → just INSIDE the paper's own left margin, fainter. This is white margin the
    ///    author left blank, not the header/footer band that made an in-page number compete with the
    ///    document's own (which is why THAT one was removed and this is not the same decision).
    func placement(number: Int, deskWidth: CGFloat) -> (text: NSAttributedString, x: CGFloat)? {
        func label(_ size: CGFloat, _ alpha: CGFloat) -> NSAttributedString {
            NSAttributedString(string: String(number), attributes: [
                // Large on purpose: one landmark per PAGE on an empty desk, not a per-line marker,
                // and the only thing out here to read. 44pt is the owner's own ceiling, set by looking
                // at it — 72 and 56 were tried on screen first and read as too big.
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                .foregroundColor: Palette.secondary.withAlphaComponent(alpha)
            ])
        }
        // Stepped rather than scaled by a ratio: the width of a numeral is not proportional to its
        // point size, so a ratio has to be re-measured anyway — and a fixed ladder makes the sizes
        // consistent from page to page instead of drifting with the digit count. Three rungs, the
        // first tried twice: once with a generous margin from the paper, then flush against the gutter.
        let gutter: CGFloat = 12
        for (size, margin) in [(44.0, 36.0), (44.0, gutter), (32.0, gutter), (24.0, gutter)] {
            let text = label(size, 0.45)
            let x = deskWidth - text.size().width - margin
            if x > 2 { return (text, x) }
        }
        guard deskWidth > -1 else { return nil }   // the page's left edge is off screen entirely
        return (label(32, 0.22), deskWidth + gutter)
    }
}
