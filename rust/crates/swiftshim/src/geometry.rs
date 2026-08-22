//! swift: Sources/FastDocReader/Render/**/*.swift (CoreGraphics/AppKit geometry only)
//!
//! Pure value types, so they are made real here rather than deferred to phase B — there is no
//! design judgement in a struct of two floats.

use std::ops::{Add, Sub};

/// swift: CGFloat
pub type CGFloat = f64;

/// swift: CGPoint
#[derive(Debug, Clone, Copy, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct CGPoint {
    pub x: CGFloat,
    pub y: CGFloat,
}

impl CGPoint {
    pub fn new(x: CGFloat, y: CGFloat) -> Self {
        Self { x, y }
    }
    pub const fn zero() -> Self {
        Self { x: 0.0, y: 0.0 }
    }
}

/// swift: CGSize
#[derive(Debug, Clone, Copy, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct CGSize {
    pub width: CGFloat,
    pub height: CGFloat,
}

impl CGSize {
    pub fn new(width: CGFloat, height: CGFloat) -> Self {
        Self { width, height }
    }
    pub const fn zero() -> Self {
        Self {
            width: 0.0,
            height: 0.0,
        }
    }
}

/// swift: CGRect — call sites read `.minX`/`.maxX`/`.minY`/`.maxY`/`.midX`/`.midY`/`.width`/
/// `.height`/`.origin`/`.size` as computed properties, mirrored here the same way.
#[derive(Debug, Clone, Copy, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct CGRect {
    pub origin: CGPoint,
    pub size: CGSize,
}

impl CGRect {
    pub fn new(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> Self {
        Self {
            origin: CGPoint::new(x, y),
            size: CGSize::new(width, height),
        }
    }
    pub fn fromOriginSize(origin: CGPoint, size: CGSize) -> Self {
        Self { origin, size }
    }
    pub const fn zero() -> Self {
        Self {
            origin: CGPoint::zero(),
            size: CGSize::zero(),
        }
    }

    pub fn width(&self) -> CGFloat {
        self.size.width
    }
    pub fn height(&self) -> CGFloat {
        self.size.height
    }
    pub fn minX(&self) -> CGFloat {
        self.origin.x
    }
    pub fn minY(&self) -> CGFloat {
        self.origin.y
    }
    pub fn maxX(&self) -> CGFloat {
        self.origin.x + self.size.width
    }
    pub fn maxY(&self) -> CGFloat {
        self.origin.y + self.size.height
    }
    pub fn midX(&self) -> CGFloat {
        self.origin.x + self.size.width / 2.0
    }
    pub fn midY(&self) -> CGFloat {
        self.origin.y + self.size.height / 2.0
    }
}

/// swift: NSPoint (== CGPoint on AppKit; kept as a distinct alias so call sites transliterate
/// literally without deciding whether the two were the same type).
pub type NSPoint = CGPoint;

/// swift: NSSize (== CGSize)
pub type NSSize = CGSize;

/// swift: NSRect — AppKit spells the same shape `NSRect`; call sites use both names.
pub type NSRect = CGRect;

/// swift: NSEdgeInsets
#[derive(Debug, Clone, Copy, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct NSEdgeInsets {
    pub top: CGFloat,
    pub left: CGFloat,
    pub bottom: CGFloat,
    pub right: CGFloat,
}

impl NSEdgeInsets {
    pub fn new(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> Self {
        Self {
            top,
            left,
            bottom,
            right,
        }
    }
}

/// swift: NSRectEdge — an OptionSet in AppKit (`.minX`, `.maxX`, `.minY`, `.maxY`); the reader's
/// per-edge border logic (invariant 47) uses it as a case set, mirrored here as bit flags.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NSRectEdge {
    MinX,
    MinY,
    MaxX,
    MaxY,
}

/// swift: CGGlyph
pub type CGGlyph = u16;

impl Add for CGPoint {
    type Output = CGPoint;
    fn add(self, rhs: CGPoint) -> CGPoint {
        CGPoint::new(self.x + rhs.x, self.y + rhs.y)
    }
}

impl Sub for CGPoint {
    type Output = CGPoint;
    fn sub(self, rhs: CGPoint) -> CGPoint {
        CGPoint::new(self.x - rhs.x, self.y - rhs.y)
    }
}
