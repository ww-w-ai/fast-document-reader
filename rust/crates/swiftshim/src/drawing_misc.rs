//! swift: the small remainder — `NSTextAttachment` (an attributed-string run's image/graphic
//! placeholder), `NSBezierPath`, and the handful of `NSColor`/`NSImage`/`CGRect` drawing calls
//! GridTextTableBlock.swift and TableBlockBuilder.swift make directly (not through the
//! excluded, host-resident painters — see rust/PORT-MANIFEST.txt). `CGRect.fill()` in
//! particular lives here rather than in `geometry.rs`: geometry.rs is pure data with no notion
//! of a graphics context, and this is the one drawing operation the in-scope table-border code
//! calls straight on a rect.

use crate::color_font::NSImage;
use crate::geometry::{CGFloat, CGPoint, CGRect, NSSize};

/// swift: NSTextAttachment
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NSTextAttachment {
    pub image: Option<NSImage>,
    pub bounds: CGRect,
    pub attachmentCell: Option<SizedAttachmentCell>,
}

/// swift: Render/SizedAttachmentCell.swift — the cell that OWNS its layout size independently of
/// whether pixels are loaded, so lazily loading or purging an image never moves the document.
///
/// Only the SIZE crosses into the engine. The cell's drawing (`draw(withFrame:in:)`, the
/// undrawable-format label card) stays with the host, which is where a graphics context exists —
/// see `CROSS-PLATFORM.md` §2: the engine lays out and the host paints. What layout needs from
/// this type is the one thing the Swift class exists to guarantee: a reserved box that does not
/// change when the pixels do.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SizedAttachmentCell {
    pub reservedSize: NSSize,
}

impl SizedAttachmentCell {
    /// swift: `SizedAttachmentCell(reservedSize:)`
    pub fn new(reservedSize: NSSize) -> Self {
        Self { reservedSize }
    }
}

impl NSTextAttachment {
    pub fn new() -> Self {
        Self::default()
    }

    /// swift: `.bounds = _` — a plain field assignment (Swift property syntax), spelled as a
    /// setter here because the in-scope call sites invoke it as a message, not `att.bounds = _`.
    pub fn set_bounds(&mut self, bounds: CGRect) {
        self.bounds = bounds;
    }

    /// swift: `.image = _`
    pub fn set_image(&mut self, image: NSImage) {
        self.image = Some(image);
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
        Self::with_rect(rect)
    }

    /// swift: NSBezierPath(rect:) — same initializer as `fromRect` above, under this crate's own
    /// documented convention for a Swift initializer (a label list, not an identifier): a
    /// snake_case Rust-only name (`with_attributes`/`with_descriptor` set the precedent this
    /// follows; `fromRect` predates that convention and is kept only for its existing caller).
    pub fn with_rect(rect: CGRect) -> Self {
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

    /// swift: `.lineWidth = _` — spelled as a setter (see `NSTextAttachment.set_bounds` above)
    /// because the in-scope call sites invoke it as a message.
    pub fn set_line_width(&mut self, width: CGFloat) {
        self.lineWidth = width;
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

/// swift: `NSString.size(withAttributes:)` — how much room a run of text takes at a given font.
///
/// Text measurement is layout, so it belongs to the engine, but it cannot be answered without font
/// metrics: the width of a string is a property of the installed typeface, not of the characters.
/// That is `CROSS-PLATFORM.md` §6's "authority for font metrics", and until the engine has one this
/// is the honest shape of the gap.
pub fn size_with_attributes(
    _text: &str,
    _attributes: &std::collections::HashMap<crate::NSAttributedStringKey, crate::AttrValue>,
) -> crate::geometry::NSSize {
    todo!("font metrics — see CROSS-PLATFORM.md §6")
}

/// swift: `NSString.draw(at:withAttributes:)` — paints a label into the current graphics context.
///
/// Drawing is the host's, not the engine's (`CROSS-PLATFORM.md` §2). This call site survives the
/// transliteration because `OfficeTextBuilder.swift` builds a placeholder card's label and paints it
/// in the same routine; Phase B replaces it with a `RenderTree` node the host paints.
pub fn draw_string_at(
    _text: &str,
    _at: crate::geometry::NSPoint,
    _attributes: &std::collections::HashMap<crate::NSAttributedStringKey, crate::AttrValue>,
) {
    todo!("host paints — see CROSS-PLATFORM.md §2")
}
