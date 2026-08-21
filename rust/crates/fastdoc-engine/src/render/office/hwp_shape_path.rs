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
