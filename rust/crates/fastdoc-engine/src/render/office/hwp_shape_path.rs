//! swift: Render/Office/HwpShapeRenderer.swift:17-31 — one shape's path, in points, relative to the
//! object's own box.
//!
//! The Swift file's other half (`pdf(paths:size:)`, which opens a `CGContext` and rasterises) stays
//! with the host. A path is not a picture: it is geometry the engine both PRODUCES, while mapping an
//! HWP drawing record, and CONSUMES, to size an object whose record declares no box of its own. Both
//! are layout, and `CROSS-PLATFORM.md` §2 puts layout in the engine.

use crate::render::office::office_block::BorderSide;
use swiftshim::{CGPoint, NSColor};

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
