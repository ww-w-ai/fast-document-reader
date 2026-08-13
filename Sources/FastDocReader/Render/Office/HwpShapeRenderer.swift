import Foundation
import AppKit

/// Draws an HWP drawing object — the arrows, boxes and connector lines a Korean document uses to
/// diagram a process — from the flattened paths rhwp exports.
///
/// WHY THIS EXISTS AND WHY IT DRAWS A PDF. Before it, every shape reached this reader as
/// `{"label":"shape","w":0,"h":0}`: no geometry and not even a size, so a page whose diagram is
/// four labels joined by six arrows rendered as four labels floating in space (measured: 79 shapes
/// in `2025_행정업무운영편람_최종.hwp`). Rather than teach the block vocabulary, the builder, the
/// serializer and the substitution walk about a new kind of content, the shape is drawn HERE, at
/// read time, into a **PDF** — which is exactly what an embedded picture already is to the rest of
/// the app: bytes under an id, reconciled and sized by the same code (invariants 1/2/11). PDF, not
/// a bitmap, because the reader zooms: a rasterised arrow at 16pt is a blur at 32.
enum HwpShapeRenderer {

    /// One path of a shape, already in POINTS relative to the object's own box (top-left origin).
    struct Path {
        var commands: [Command]
        var stroke: BorderSide?
        var fill: NSColor?
        var arrowStart = false
        var arrowEnd = false

        enum Command {
            case move(CGPoint)
            case line(CGPoint)
            case curve(CGPoint, CGPoint, CGPoint)   // two controls, then the end point
            case close
        }
    }

    /// PDF bytes for one shape, or nil when there is nothing to draw (no path, or a zero-sized box).
    ///
    /// The page is the object's own box, so the caller reserves exactly the space the document gave
    /// the object and the drawing fills it. HWP's y grows DOWNWARD and PDF's grows upward, so the
    /// context is flipped once here rather than by negating every coordinate — a per-point negation
    /// is the kind of thing that survives review and then puts one arrowhead upside down.
    static func pdf(paths: [Path], size: CGSize) -> Data? {
        guard !paths.isEmpty, size.width > 0.5, size.height > 0.5 else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        for path in paths { draw(path, in: ctx) }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func draw(_ path: Path, in ctx: CGContext) {
        let cg = CGMutablePath()
        var start: CGPoint?, startDirection: CGPoint?
        var end: CGPoint?, endDirection: CGPoint?
        var previous: CGPoint?
        for command in path.commands {
            switch command {
            case .move(let p):
                cg.move(to: p)
                if start == nil { start = p }
                previous = p
            case .line(let p):
                cg.addLine(to: p)
                if startDirection == nil, let s = start, s != p { startDirection = p }
                endDirection = previous
                end = p
                previous = p
            case .curve(let c1, let c2, let p):
                cg.addCurve(to: p, control1: c1, control2: c2)
                if startDirection == nil { startDirection = c1 }
                endDirection = c2
                end = p
                previous = p
            case .close:
                cg.closeSubpath()
            }
        }
        if let fill = path.fill {
            ctx.addPath(cg)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        guard let stroke = path.stroke else { return }
        ctx.addPath(cg)
        ctx.setStrokeColor((stroke.color ?? .black).cgColor)
        ctx.setLineWidth(max(stroke.width, 0.25))
        switch stroke.style {
        case .solid, .double:
            ctx.setLineDash(phase: 0, lengths: [])
        case .dashed:
            ctx.setLineDash(phase: 0, lengths: [max(stroke.width, 0.5) * 4, max(stroke.width, 0.5) * 2])
        case .dotted:
            ctx.setLineDash(phase: 0, lengths: [max(stroke.width, 0.5), max(stroke.width, 0.5) * 2])
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Arrowheads are drawn by this reader, not by the document: HWP states only WHICH head a
        // line has, in the border line's attribute bits, and leaves the geometry to the renderer.
        // A head scaled to the rule's own width keeps a hairline connector from carrying a barb the
        // size of a glyph, and a 3pt frame from carrying one nobody can see.
        let head = max(stroke.width, 0.5) * 6
        if path.arrowEnd, let tip = end, let from = endDirection {
            arrowHead(at: tip, from: from, size: head, colour: stroke.color ?? .black, in: ctx)
        }
        if path.arrowStart, let tip = start, let from = startDirection {
            arrowHead(at: tip, from: from, size: head, colour: stroke.color ?? .black, in: ctx)
        }
    }

    private static func arrowHead(at tip: CGPoint, from: CGPoint, size: CGFloat,
                                  colour: NSColor, in ctx: CGContext) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.01 else { return }
        let ux = dx / length, uy = dy / length
        // A 30° barb — the same proportion a word processor draws, and narrow enough that two
        // arrows meeting at a box do not read as a solid triangle.
        let spread = size * 0.38
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let head = CGMutablePath()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - uy * spread, y: base.y + ux * spread))
        head.addLine(to: CGPoint(x: base.x + uy * spread, y: base.y - ux * spread))
        head.closeSubpath()
        ctx.addPath(head)
        ctx.setFillColor(colour.cgColor)
        ctx.fillPath()
    }
}
