//! The arrowhead's geometry is the engine's, and it has to keep meaning what the Swift meant.
//!
//! This landed late: the file split that sent `HwpShapeRenderer` to the host took the whole
//! function with it, because it ends by filling the path it computes. Eleven of its fourteen lines
//! never touch a graphics context. The test exists so the arithmetic is pinned now that it is back
//! on the engine side — an arrowhead drawn from slightly wrong points still looks like an
//! arrowhead, which is exactly the kind of wrong nobody reports.

use fastdoc_engine::render::office::hwp_shape_path::{arrow_head_points, arrow_head_size};
use swiftshim::CGPoint;

#[test]
fn the_head_grows_with_the_stroke_but_never_vanishes() {
    // swift: HwpShapeRenderer.swift:105 — max(stroke.width, 0.5) * 6
    assert_eq!(arrow_head_size(2.0), 12.0);
    // A hairline still gets a head: the floor applies before the multiply, not after.
    assert_eq!(arrow_head_size(0.25), 3.0);
    assert_eq!(arrow_head_size(0.0), 3.0);
}

#[test]
fn the_barbs_sit_perpendicular_to_the_direction_of_travel() {
    // Pointing straight right: tip at (10,0), coming from the origin, head size 10.
    // Base lands one head-length back at (0,0); the barbs offset perpendicular by size * 0.38.
    let pts = arrow_head_points(CGPoint { x: 10.0, y: 0.0 }, CGPoint { x: 0.0, y: 0.0 }, 10.0)
        .expect("a well-formed direction produces a head");
    assert_eq!(pts[0], CGPoint { x: 10.0, y: 0.0 }, "first point is the tip itself");
    assert!((pts[1].x - 0.0).abs() < 1e-9 && (pts[1].y - 3.8).abs() < 1e-9, "got {:?}", pts[1]);
    assert!((pts[2].x - 0.0).abs() < 1e-9 && (pts[2].y + 3.8).abs() < 1e-9, "got {:?}", pts[2]);
}

#[test]
fn a_degenerate_direction_has_no_head_rather_than_a_zero_sized_one() {
    // swift: `guard length > 0.01 else { return }` — the Swift draws NOTHING here. None keeps
    // "there is no arrowhead" distinct from "there is one, of size zero"; collapsing the two puts
    // a degenerate triangle at the origin of every zero-length arrow.
    assert!(arrow_head_points(CGPoint { x: 5.0, y: 5.0 }, CGPoint { x: 5.0, y: 5.0 }, 10.0).is_none());
    assert!(arrow_head_points(CGPoint { x: 5.0, y: 5.0 }, CGPoint { x: 5.005, y: 5.0 }, 10.0).is_none());
}
