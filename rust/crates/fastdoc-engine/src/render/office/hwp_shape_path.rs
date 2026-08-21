//! swift: Render/Office/HwpShapeRenderer.swift:17-31 — one shape's path, in points, relative to the
//! object's own box.
//!
//! The Swift file's other half (`pdf(paths:size:)`, which opens a `CGContext` and rasterises) stays
//! with the host. A path is not a picture: it is geometry the engine both PRODUCES, while mapping an
//! HWP drawing record, and CONSUMES, to size an object whose record declares no box of its own. Both
//! are layout, and `CROSS-PLATFORM.md` §2 puts layout in the engine.

use crate::render::office::office_block::BorderSide;
use swiftshim::{CGFloat, CGPoint, NSColor};

/// swift: `HwpShapeRenderer.Path.Command`
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PathCommand {
    Move(CGPoint),
    Line(CGPoint),
    /// Two controls, then the end point.
    Curve(CGPoint, CGPoint, CGPoint),
    Close,
}

/// swift: `HwpShapeRenderer.Path`
#[derive(Debug, Clone, PartialEq)]
pub struct PathSpec {
    pub commands: Vec<PathCommand>,
    pub stroke: Option<BorderSide>,
    pub fill: Option<NSColor>,
    pub arrow_start: bool,
    pub arrow_end: bool,
}

/// swift: `HwpShapeRenderer.draw`'s own `head` (HwpShapeRenderer.swift:105) — how big an arrowhead
/// is for a given stroke width.
///
/// A line's own width decides it, floored so a hairline still gets a visible head. The Swift
/// comment beside it gives the reason for both ends of that: a 0.25pt frame must not carry an
/// arrowhead the size of a glyph, and a 3pt frame must not carry one nobody can see.
pub fn arrow_head_size(stroke_width: CGFloat) -> CGFloat {
    stroke_width.max(0.5) * 6.0
}

/// swift: `HwpShapeRenderer.arrowHead` (HwpShapeRenderer.swift:114-131) — the three points of an
/// arrowhead: its tip, and the two barb corners.
///
/// This is geometry, not painting. The Swift function ends by filling the path it just computed,
/// which is what made it read as host work at the file split — but eleven of its fourteen lines
/// compute points from a direction and a size, touching no graphics context at all. Only the final
/// `addPath`/`setFillColor`/`fillPath` needs one, and that stays with the host. Arrowhead position
/// is part of where a shape sits on the page, so it belongs on the same side of the boundary as
/// `PathSpec` itself (`CROSS-PLATFORM.md` §2).
///
/// `None` when the direction is degenerate — the Swift guards `length > 0.01` and returns without
/// drawing, so "there is no arrowhead here" is a real answer and not a zero-sized one.
///
/// The barb is a 30° spread: the same proportion a word processor draws, and narrow enough that
/// two arrows meeting at a box do not read as one solid triangle.
pub fn arrow_head_points(tip: CGPoint, from: CGPoint, size: CGFloat) -> Option<[CGPoint; 3]> {
    let (dx, dy) = (tip.x - from.x, tip.y - from.y);
    let length = (dx * dx + dy * dy).sqrt();
    if !(length > 0.01) {
        return None;
    }
    let (ux, uy) = (dx / length, dy / length);
    let spread = size * 0.38;
    let base = CGPoint { x: tip.x - ux * size, y: tip.y - uy * size };
    Some([
        tip,
        CGPoint { x: base.x - uy * spread, y: base.y + ux * spread },
        CGPoint { x: base.x + uy * spread, y: base.y - ux * spread },
    ])
}

/// swift: `HwpShapeRenderer.pdf(paths:size:)` — PDF bytes for one shape, or `None` when there is
/// nothing to draw.
///
/// This is the rasterising half of the Swift file, and it is deliberately NOT implemented here.
/// `docs/plans/rust-phase-b-worklist.md` §1.3 settled it: the engine hands the host a laid-out tree
/// and the host paints, so these ten drawing call sites are replaced by `RenderTree` nodes rather
/// than reimplemented. It exists as a signature because the mapping layer, transliterated from a
/// Swift file that mixed both halves, still calls it at four sites; those calls go away with the
/// node work, and until then this states the boundary instead of hiding it behind a fake return.
///
/// Note what it would take to keep it: a graphics context, a PDF writer, and the y-axis flip the
/// Swift does once (HWP's y grows downward, PDF's upward). None of that is layout.
pub struct HwpShapeRenderer;

impl HwpShapeRenderer {
    pub fn pdf(_paths: &[PathSpec], _size: swiftshim::CGSize) -> Option<swiftshim::Data> {
        todo!("host paints — see docs/plans/rust-phase-b-worklist.md §1.3")
    }
}
