//! swift: Render/Office/HwpShapeRenderer.swift
//! one shape's path, in points, relative to the
//! object's own box.
//!
//! The Swift file's other half (`pdf(paths:size:)`, which opens a `CGContext` and rasterises) stays
//! with the host. A path is not a picture: it is geometry the engine both PRODUCES, while mapping an
//! HWP drawing record, and CONSUMES, to size an object whose record declares no box of its own. Both
//! are layout, and `CROSS-PLATFORM.md` §2 puts layout in the engine.

use crate::render::office::office_block::BorderSide;
use swiftshim::{CGFloat, CGPoint, NSColor};

/// swift: `HwpShapeRenderer.Path.Command`
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum PathCommand {
    Move(CGPoint),
    Line(CGPoint),
    /// Two controls, then the end point.
    Curve(CGPoint, CGPoint, CGPoint),
    Close,
}

/// swift: `HwpShapeRenderer.Path`
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PathSpec {
    pub commands: Vec<PathCommand>,
    pub stroke: Option<BorderSide>,
    pub fill: Option<NSColor>,
    pub arrow_start: bool,
    pub arrow_end: bool,
}

/// A vector drawing after layout, ready to cross to a host painter.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct VectorGraphic {
    pub paths: Vec<PathSpec>,
    pub size: swiftshim::CGSize,
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
    let base = CGPoint {
        x: tip.x - ux * size,
        y: tip.y - uy * size,
    };
    Some([
        tip,
        CGPoint {
            x: base.x - uy * spread,
            y: base.y + ux * spread,
        },
        CGPoint {
            x: base.x + uy * spread,
            y: base.y - ux * spread,
        },
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vector_graphic_survives_the_wire_exactly() {
        let graphic = VectorGraphic {
            size: swiftshim::CGSize {
                width: 120.0,
                height: 48.0,
            },
            paths: vec![PathSpec {
                commands: vec![
                    PathCommand::Move(swiftshim::CGPoint { x: 1.0, y: 2.0 }),
                    PathCommand::Curve(
                        swiftshim::CGPoint { x: 3.0, y: 4.0 },
                        swiftshim::CGPoint { x: 5.0, y: 6.0 },
                        swiftshim::CGPoint { x: 7.0, y: 8.0 },
                    ),
                    PathCommand::Close,
                ],
                stroke: Some(BorderSide {
                    width: 1.5,
                    color: Some(swiftshim::NSColor::srgb(0.1, 0.2, 0.3, 1.0)),
                    style: crate::render::office::office_block::BorderLineStyle::Dashed,
                }),
                fill: Some(swiftshim::NSColor::srgb(0.8, 0.7, 0.6, 0.5)),
                arrow_start: true,
                arrow_end: false,
            }],
        };

        let json = serde_json::to_string(&graphic).unwrap();
        let decoded: VectorGraphic = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, graphic);
    }
}
