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
        // Large on purpose: it is one landmark per PAGE on an empty desk, not a per-line marker, and
        // it is the only thing out here to read. Sized at the owner's own call ("4배 정도 더 크게").
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont, .foregroundColor: Palette.secondary.withAlphaComponent(0.45)
        ]
        for (index, sheet) in sheets.enumerated() {
            // The sheet's own top-left, in THIS view's coordinates — AppKit applies the scroll and
            // the magnification, so a zoomed page keeps its number beside it.
            let corner = convert(NSPoint(x: sheet.minX, y: sheet.minY), from: textView)
            let text = NSAttributedString(string: String(index + 1), attributes: attrs)
            let size = text.size()
            // Generous room on both sides of the paper's corner: clear of the sheet's left edge, and
            // dropped below its top rule so the number reads as sitting BESIDE the page rather than
            // hanging off it ("왼쪽에 여유있는 여백 포함해서… 페이지 윗 라인에 너무 딱 붙이지 말 것").
            let x = corner.x - size.width - 36
            let y = corner.y + 18
            let box = NSRect(x: x, y: y, width: size.width, height: size.height)
            guard box.intersects(dirtyRect), x > 2 else { continue }
            text.draw(at: NSPoint(x: x, y: y))
        }
    }
}
