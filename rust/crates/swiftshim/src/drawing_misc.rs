//! swift: the small remainder — `NSTextAttachment` (an attributed-string run's image/graphic
//! placeholder), `NSBezierPath`, and the handful of `NSColor`/`NSImage`/`CGRect` drawing calls
//! GridTextTableBlock.swift and TableBlockBuilder.swift make directly (not through the
//! excluded, host-resident painters — see rust/PORT-MANIFEST.txt). `CGRect.fill()` in
//! particular lives here rather than in `geometry.rs`: geometry.rs is pure data with no notion
//! of a graphics context, and this is the one drawing operation the in-scope table-border code
//! calls straight on a rect.

use crate::color_font::NSImage;
use crate::geometry::{CGFloat, CGPoint, CGRect};

/// swift: NSTextAttachment
#[derive(Debug, Clone, Default)]
pub struct NSTextAttachment {
    pub image: Option<NSImage>,
    pub bounds: CGRect,
}

impl NSTextAttachment {
    pub fn new() -> Self {
        Self::default()
    }
}

/// swift: NSBezierPath — the reader's few in-scope path-drawing call sites (rules under a
/// footnote band, bar underlines) build a path with `.move(to:)`/`.line(to:)`/`.stroke()`.
/// Drawing itself needs a live graphics context, so it stays `todo!()`; the path's own point
/// list is real because later code (bounding-box math, if any) can use it without a context.
#[derive(Debug, Clone, Default)]
pub struct NSBezierPath {
    pub points: Vec<CGPoint>,
    pub lineWidth: CGFloat,
}

impl NSBezierPath {
    pub fn new() -> Self {
        Self::default()
    }

    /// swift: NSBezierPath(rect:) — GridTextTableBlock.swift's whole-point-width rule fill.
    pub fn fromRect(rect: CGRect) -> Self {
        Self {
            points: vec![
                CGPoint::new(rect.minX(), rect.minY()),
                CGPoint::new(rect.maxX(), rect.minY()),
                CGPoint::new(rect.maxX(), rect.maxY()),
                CGPoint::new(rect.minX(), rect.maxY()),
            ],
            lineWidth: 0.0,
        }
    }

    pub fn moveTo(&mut self, point: CGPoint) {
        self.points.push(point);
    }

    pub fn lineTo(&mut self, point: CGPoint) {
        self.points.push(point);
    }

    pub fn close(&mut self) {
        if let Some(&first) = self.points.first() {
            self.points.push(first);
        }
    }

    /// swift: .setLineDash(_:count:phase:) — GridTextTableBlock.swift's dashed/dotted table
    /// rules. `count` is redundant with `pattern.len()` in Swift too (CoreGraphics's own API
    /// shape); kept as a parameter so the call site transliterates without reshaping.
    pub fn setLineDash(&mut self, _pattern: &[CGFloat], _count: usize, _phase: CGFloat) {
        todo!("swift: NSBezierPath.setLineDash(_:count:phase:) — phase B (needs a live graphics context)")
    }

    pub fn stroke(&self) {
        todo!("swift: NSBezierPath.stroke() — phase B (needs a live graphics context)")
    }

    pub fn fill(&self) {
        todo!("swift: NSBezierPath.fill() — phase B (needs a live graphics context)")
    }
}

/// swift: CGRect.fill() — an AppKit/CoreGraphics extension on the rect itself
/// (GridTextTableBlock.swift: `rect.fill()`, `NSRect(...).fill()`).
impl CGRect {
    pub fn fill(&self) {
        todo!("swift: NSRect.fill() — phase B (needs a live graphics context)")
    }
}

/// swift: NSCompositingOperation — `NSImage.draw(in:from:operation:fraction:respectFlipped:
/// hints:)`'s `operation:` argument. Only `.sourceOver` appears in the in-scope files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NSCompositingOperation {
    SourceOver,
}

/// swift: the `NSImage.draw(in:from:operation:fraction:respectFlipped:hints:)` extension the
/// in-scope table-background code calls directly (TableBlockBuilder.swift:21,
/// GridTextTableBlock.swift:151).
impl NSImage {
    pub fn draw(
        &self,
        _in_rect: CGRect,
        _from_rect: CGRect,
        _operation: NSCompositingOperation,
        _fraction: CGFloat,
        _respect_flipped: bool,
        _hints: Option<()>,
    ) {
        todo!("swift: NSImage.draw(in:from:operation:fraction:respectFlipped:hints:) — phase B")
    }
}
