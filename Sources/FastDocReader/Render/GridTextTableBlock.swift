import AppKit

/// A table cell that knows a page can pass THROUGH it, and paints itself accordingly.
///
/// `NSTextTableBlock` paints one background and one border box around the block's whole frame. When
/// a cell's own text is divided between two pages — which is what happens to a row taller than the
/// page body (invariant 64) — that single box spans the desk gap between the two sheets: a border
/// drawn across empty paper, and the reader's own header and page number sitting inside a cell.
///
/// The owner's rule, given on sight of it: *"셀 중간이 잘리는 경우에는 라인이 없고, 셀로 구분되어 잘릴
/// 때는 라인이 있는 것은 동일"* — a cut through a cell's middle shows NO rule on either side of the
/// gap, so the two halves read as one cell continuing, while a break at a real cell boundary keeps
/// its rules. This class is that rule, and nothing else: it changes only what is DRAWN. Geometry
/// still belongs to AppKit (invariants 39/42) — the frame it is handed is the frame it paints in.
///
/// The page geometry is read from the layout manager's own delegate, which is the object that made
/// the gaps in the first place (`PageBandLayoutDelegate.openedBands`), so there is no second source
/// of truth about where a page ends.
final class GridTextTableBlock: NSTextTableBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        // THE TWO COORDINATE SYSTEMS. `frameRect` arrives in the VIEW's coordinates, while
        // `openedBands` is recorded from line fragment rects, which are the TEXT CONTAINER's — the
        // difference is `NSTextView.textContainerOrigin`, 28pt in this reader. Comparing them raw put
        // every cut 27.6pt too high: measured by scanning the rendered view, the side rules stopped at
        // text-y 756.9 and resumed at 882.7 against a band running 784.5…910.6, so a strip of cell was
        // drawn on the desk and a strip of paper left blank above the text that follows.
        let originY = (controlView as? NSTextView)?.textContainerOrigin.y ?? 0
        let gaps = Self.gapsCrossing(frameRect, layoutManager: layoutManager, charRange: charRange,
                                     originY: originY)
        guard !gaps.isEmpty else {
            super.drawBackground(withFrame: frameRect, in: controlView,
                                 characterRange: charRange, layoutManager: layoutManager)
            return
        }
        // One segment per piece of paper this cell appears on. `super` cannot be used for them: it
        // would paint a full border box around each segment, which is the rule at the cut that the
        // owner's rule says must not be there.
        let segments = Self.segments(of: frameRect, splitBy: gaps)
        for (i, segment) in segments.enumerated() {
            paint(segment, cutAbove: i > 0, cutBelow: i < segments.count - 1)
        }
    }

    /// The empty bands this cell's box reaches across.
    ///
    /// NOTHING IS EVER PAINTED INSIDE A BAND. A band is empty paper — the desk between two sheets —
    /// so a cell whose box spans one is drawn in pieces whether or not its OWN text continues on the
    /// far side. The left-hand label of the reported document is exactly that case: its two lines sit
    /// at the top of a row 750pt tall, so its text is entirely above the gap while its box runs
    /// 448.9…1198.8, and painting that box whole put the cell's shading and side rules straight
    /// across the desk and on into the next sheet.
    ///
    /// The band's own edges ARE where the text is cut — `PageBandLayoutDelegate` records a band as
    /// `[where the moved line was going to start, where it now starts]`, and the line before it ends
    /// exactly at that first number. So the cut aligns with the text by construction, and it aligns
    /// for EVERY cell of the row at once. Deriving it per cell instead was built and measured wrong:
    /// each cell then cut at its own last line, and a label whose text stops 300pt above the row's
    /// bottom was drawn as a 6.4pt sliver (`segs=["442.5…448.9", "910.6…1198.8"]`).
    ///
    /// Only a band strictly INSIDE the frame counts. One that merely touches an edge is the ordinary
    /// case of a cell ending at a page bottom, and treating it as a cut erased the rules of a whole
    /// table that merely FOLLOWED a piece carried to the next page.
    private static func gapsCrossing(_ frame: NSRect, layoutManager: NSLayoutManager,
                                     charRange: NSRange,
                                     originY: CGFloat) -> [(top: CGFloat, height: CGFloat)] {
        guard let delegate = layoutManager.delegate as? PageBandLayoutDelegate,
              !delegate.openedBands.isEmpty else { return [] }
        return delegate.openedBands.values
            .map { (top: $0.top + originY, height: $0.height) }
            .filter { $0.top > frame.minY + 0.5 && $0.top + $0.height < frame.maxY - 0.5 }
            .sorted { $0.top < $1.top }
    }

    private static func segments(of frame: NSRect, splitBy gaps: [(top: CGFloat, height: CGFloat)])
        -> [NSRect] {
        var out: [NSRect] = []
        var y = frame.minY
        for gap in gaps {
            out.append(NSRect(x: frame.minX, y: y, width: frame.width, height: gap.top - y))
            y = gap.top + gap.height
        }
        out.append(NSRect(x: frame.minX, y: y, width: frame.width, height: frame.maxY - y))
        return out.filter { $0.height > 0.5 }
    }

    /// Background plus the edges this segment is allowed to show. A cut edge shows nothing — that is
    /// the whole point — and every other edge keeps the width and colour invariant 47 resolved for it.
    private func paint(_ rect: NSRect, cutAbove: Bool, cutBelow: Bool) {
        if let background = backgroundColor {
            background.setFill()
            rect.fill()
        }
        let edges: [(NSRectEdge, NSRect)] = [
            (.minX, NSRect(x: rect.minX, y: rect.minY,
                           width: width(for: .border, edge: .minX), height: rect.height)),
            (.maxX, NSRect(x: rect.maxX - width(for: .border, edge: .maxX), y: rect.minY,
                           width: width(for: .border, edge: .maxX), height: rect.height)),
            (.minY, NSRect(x: rect.minX, y: rect.minY,
                           width: rect.width, height: width(for: .border, edge: .minY))),
            (.maxY, NSRect(x: rect.minX, y: rect.maxY - width(for: .border, edge: .maxY),
                           width: rect.width, height: width(for: .border, edge: .maxY))),
        ]
        for (edge, bar) in edges {
            if edge == .minY && cutAbove { continue }
            if edge == .maxY && cutBelow { continue }
            guard bar.width > 0, bar.height > 0 else { continue }
            (borderColor(for: edge) ?? .clear).setFill()
            bar.fill()
        }
    }
}
