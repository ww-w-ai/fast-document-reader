//! swift: Render/CodeCardLayoutManager.swift:7-12 — the code card's four measurements.
//!
//! The Swift file they live in stays with the host: it is an `NSLayoutManager` subclass and a
//! background-pass draw routine, neither of which the engine has. These four numbers are not
//! drawing, though — they are the indents and spacing a code paragraph is BUILT with, so the
//! renderer needs them to lay a card out at all. Splitting the value half out is the same rule
//! `CROSS-PLATFORM.md` §2 draws everywhere else: the engine measures, the host paints.

use swiftshim::CGFloat;

/// swift: `enum CodeCardMetrics`
pub struct CodeCardMetrics;

impl CodeCardMetrics {
    /// Gap from the text-area edges.
    pub const HORIZONTAL_MARGIN: CGFloat = 4.0;
    /// Extra height above/below the code text.
    pub const VERTICAL_PADDING: CGFloat = 11.0;
    pub const CORNER_RADIUS: CGFloat = 7.0;
    /// Left/right padding of code inside the card.
    pub const TEXT_INSET: CGFloat = 14.0;
}
