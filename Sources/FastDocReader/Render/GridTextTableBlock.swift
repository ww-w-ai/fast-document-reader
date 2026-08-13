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
        // A styled edge has to be drawn by `paint` even on a cell no band crosses — `super` knows
        // only solid bars. One segment, no cuts: the same picture as `super` for every solid edge.
        guard !gaps.isEmpty else {
            if hasStyledEdge || backgroundImage != nil {
                paint(frameRect, cutAbove: false, cutBelow: false)
                return
            }
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
    /// How each edge is DRAWN, by edge. `NSTextTableBlock` carries a width and a colour per edge and
    /// nothing else, so a document's dotted or double rule had nowhere to go and was painted solid.
    /// Set by `TableBlockBuilder` from the resolved `BorderSide`; an edge absent here is solid, which
    /// is what every markdown table and every rule this reader invents itself is.
    var edgeStyles: [NSRectEdge: BorderLineStyle] = [:]

    /// The cell's own picture fill (`Cell.backgroundImage`). Painted per SEGMENT, like the shading
    /// and the side rules, so a cell a page break crosses shows its image on each sheet and nothing
    /// on the desk between them.
    var backgroundImage: NSImage?

    /// True when any edge needs a stroke this class has to draw itself. `super` paints solid bars, so
    /// only a non-solid edge forces the override on a cell no page break crosses.
    var hasStyledEdge: Bool { edgeStyles.values.contains { $0 != .solid } }

    private func paint(_ rect: NSRect, cutAbove: Bool, cutBelow: Bool) {
        if let background = backgroundColor {
            background.setFill()
            rect.fill()
        }
        backgroundImage?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                              respectFlipped: true, hints: nil)
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
            let colour = borderColor(for: edge) ?? .clear
            switch edgeStyles[edge] ?? .solid {
            case .solid:
                colour.setFill()
                bar.fill()
            case .dashed, .dotted:
                // A dash is STROKED down the middle of the bar the solid case fills, so a dotted and
                // a solid rule of the same declared width occupy the same band and the geometry the
                // layout already accounted for does not move. The pattern is in multiples of the
                // rule's own width — a fixed 3pt dash disappears on a 0.3pt hairline and looks like
                // a chain on a 3pt frame.
                let unit = max(bar.width, bar.height) == bar.width ? bar.height : bar.width
                let thickness = max(unit, 0.5)
                let pattern: [CGFloat] = (edgeStyles[edge] == .dotted)
                    ? [thickness, thickness * 2] : [thickness * 4, thickness * 2]
                let path = NSBezierPath()
                if bar.width >= bar.height {                       // horizontal edge
                    let y = bar.midY
                    path.move(to: NSPoint(x: bar.minX, y: y)); path.line(to: NSPoint(x: bar.maxX, y: y))
                } else {                                            // vertical edge
                    let x = bar.midX
                    path.move(to: NSPoint(x: x, y: bar.minY)); path.line(to: NSPoint(x: x, y: bar.maxY))
                }
                path.lineWidth = thickness
                path.setLineDash(pattern, count: 2, phase: 0)
                colour.setStroke()
                path.stroke()
            case .double:
                // Two rules inside the SAME band, each a third of it, with a third of clear between —
                // the band's total is what the document declared and what layout reserved, so a
                // double rule cannot push a cell's content.
                colour.setFill()
                if bar.width >= bar.height {
                    let t = max(bar.height / 3, 0.5)
                    NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: t).fill()
                    NSRect(x: bar.minX, y: bar.maxY - t, width: bar.width, height: t).fill()
                } else {
                    let t = max(bar.width / 3, 0.5)
                    NSRect(x: bar.minX, y: bar.minY, width: t, height: bar.height).fill()
                    NSRect(x: bar.maxX - t, y: bar.minY, width: t, height: bar.height).fill()
                }
            }
        }
    }
}
