//! swift: Render/TableBlockBuilder.swift and Render/GridTextTableBlock.swift (the latter is
//! in-scope and subclasses `NSTextTableBlock` — its Rust port composes over this shim rather
//! than duplicating it, per convention §3's `extension T: P` → `impl P for T` mapping).
//!
//! `NSTextTable`/`NSTextTableBlock`/`NSTextBlock` are TextKit's declarative table model: a table
//! owns a column count, a block owns a (row, rowSpan, column, columnSpan) cell position plus
//! per-edge width/color/border settings. Fields mirror exactly what TableBlockBuilder.swift and
//! GridTextTableBlock.swift read and set (invariants 39, 42, 47, 50, 51, 72, 74, 76).

use crate::color_font::NSColor;
use crate::geometry::{CGFloat, CGRect, NSRectEdge};

/// swift: NSTextBlock.ValueType
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NSTextBlockValueType {
    AbsoluteValueType,
    PercentageValueType,
}

/// swift: NSTextBlock.Dimension
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NSTextBlockDimension {
    Width,
    MinimumWidth,
    MaximumWidth,
    Height,
    MinimumHeight,
    MaximumHeight,
}

/// swift: NSTextBlock.Layer — border vs. padding vs. margin, the layer `setWidth(_:type:for:)`
/// and `setBorderColor(_:for:)` address.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NSTextBlockLayer {
    Padding,
    Border,
    Margin,
}

#[derive(Debug, Clone, Copy, Default)]
struct EdgeValues<T: Copy + Default> {
    minX: T,
    maxX: T,
    minY: T,
    maxY: T,
}

impl<T: Copy + Default> EdgeValues<T> {
    fn get(&self, edge: NSRectEdge) -> T {
        match edge {
            NSRectEdge::MinX => self.minX,
            NSRectEdge::MaxX => self.maxX,
            NSRectEdge::MinY => self.minY,
            NSRectEdge::MaxY => self.maxY,
        }
    }
    fn set(&mut self, edge: NSRectEdge, value: T) {
        match edge {
            NSRectEdge::MinX => self.minX = value,
            NSRectEdge::MaxX => self.maxX = value,
            NSRectEdge::MinY => self.minY = value,
            NSRectEdge::MaxY => self.maxY = value,
        }
    }
}

/// swift: NSTextBlock — the abstract base `NSTextTableBlock` inherits from. Kept concrete here
/// (rather than a trait) since the reader never subclasses it directly, only `NSTextTableBlock`.
#[derive(Debug, Clone, Default)]
pub struct NSTextBlock {
    widths: EdgeValues<CGFloat>,
    width_types: EdgeValues<Option<NSTextBlockValueType>>,
    border_colors: EdgeValues<Option<NSColor>>,
    content_width: Option<(CGFloat, NSTextBlockValueType)>,
    pub backgroundColor: Option<NSColor>,
    pub verticalAlignment: NSTextBlockVerticalAlignment,
}

impl NSTextBlock {
    pub fn new() -> Self {
        Self::default()
    }

    /// swift: .setWidth(_:type:for:) — the layer-uniform overload (all four edges at once).
    pub fn setWidth(&mut self, value: CGFloat, r#type: NSTextBlockValueType, _for: NSTextBlockLayer) {
        for edge in [
            NSRectEdge::MinX,
            NSRectEdge::MaxX,
            NSRectEdge::MinY,
            NSRectEdge::MaxY,
        ] {
            self.widths.set(edge, value);
            self.width_types.set(edge, Some(r#type));
        }
    }

    /// swift: .setWidth(_:type:for:edge:) — the per-edge overload invariant 47 depends on, to
    /// tell an edge the document silenced apart from one it never mentioned.
    pub fn setWidthForEdge(
        &mut self,
        value: CGFloat,
        r#type: NSTextBlockValueType,
        _for: NSTextBlockLayer,
        edge: NSRectEdge,
    ) {
        self.widths.set(edge, value);
        self.width_types.set(edge, Some(r#type));
    }

    pub fn width(&self, _for: NSTextBlockLayer, edge: NSRectEdge) -> CGFloat {
        self.widths.get(edge)
    }

    pub fn setBorderColorForEdge(&mut self, color: NSColor, edge: NSRectEdge) {
        self.border_colors.set(edge, Some(color));
    }

    pub fn setBorderColor(&mut self, color: NSColor) {
        for edge in [
            NSRectEdge::MinX,
            NSRectEdge::MaxX,
            NSRectEdge::MinY,
            NSRectEdge::MaxY,
        ] {
            self.border_colors.set(edge, Some(color));
        }
    }

    pub fn borderColor(&self, edge: NSRectEdge) -> Option<NSColor> {
        self.border_colors.get(edge)
    }

    /// swift: .setContentWidth(_:type:) — a stored value alongside the per-edge widths above;
    /// no TextKit callback needed to record it. Closed as a phase-A hole (team-lead review,
    /// 2026-08-21): the EdgeValues machinery `setWidth`/`setWidthForEdge` already use was the
    /// only thing this was ever missing, and content width isn't per-edge.
    pub fn setContentWidth(&mut self, value: CGFloat, r#type: NSTextBlockValueType) {
        self.content_width = Some((value, r#type));
    }

    /// swift: `NSTextTable.value(forDimension: .width, row:column:)` reads this back through
    /// the owning table in real AppKit; exposed directly here since this shim has no live
    /// TextKit object graph to route the read through.
    pub fn contentWidth(&self) -> Option<(CGFloat, NSTextBlockValueType)> {
        self.content_width
    }

    pub fn rectForContentSize(
        &self,
        _content_size: crate::geometry::CGSize,
        _layout_manager: &crate::textkit::NSLayoutManager,
    ) -> CGRect {
        todo!("swift: NSTextBlock.rectForContentSize(_:in:) — phase B (TextKit-driven)")
    }

    /// swift: `.setWidth(_:type: .absolute, for: .border, edge:)` — a Rust-only convenience
    /// collapsing the general 4-argument `setWidthForEdge` to the one shape the in-scope
    /// table-border-drawing call sites actually use: an absolute border width on one edge.
    pub fn set_width_border(&mut self, value: CGFloat, edge: NSRectEdge) {
        self.setWidthForEdge(value, NSTextBlockValueType::AbsoluteValueType, NSTextBlockLayer::Border, edge);
    }

    /// swift: `.width(for: .border, edge:)` — the border-layer-fixed counterpart to
    /// `set_width_border` above.
    pub fn width_for_border(&self, edge: NSRectEdge) -> CGFloat {
        self.width(NSTextBlockLayer::Border, edge)
    }

    /// swift: `.setWidth(_:type: .absolute, for: .padding, edge:)` — the padding-layer twin of
    /// `set_width_border`.
    pub fn set_padding_edge(&mut self, value: CGFloat, edge: NSRectEdge) {
        self.setWidthForEdge(value, NSTextBlockValueType::AbsoluteValueType, NSTextBlockLayer::Padding, edge);
    }

    /// swift: `.setWidth(_:type: .absolute, for: .padding)` — the padding-layer twin of the
    /// uniform `setWidth` above.
    pub fn set_padding_all(&mut self, value: CGFloat) {
        self.setWidth(value, NSTextBlockValueType::AbsoluteValueType, NSTextBlockLayer::Padding);
    }

    /// swift: `.setBorderColor(_:for:)` — the per-edge border-color setter under its Rust-only
    /// convenience name (matches `set_width_border`/`set_padding_edge` above).
    pub fn set_border_color_edge(&mut self, color: NSColor, edge: NSRectEdge) {
        self.setBorderColorForEdge(color, edge);
    }
}

/// swift: NSTextBlock.VerticalAlignment
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NSTextBlockVerticalAlignment {
    #[default]
    TopAlignment,
    MiddleAlignment,
    BottomAlignment,
    BaselineAlignment,
}

/// swift: NSTextTableBlock — a cell: a fixed (row, column) position plus row/column span into
/// its owning `NSTextTable`. `GridTextTableBlock` (in scope) subclasses this.
#[derive(Debug, Clone)]
pub struct NSTextTableBlock {
    pub base: NSTextBlock,
    pub table: NSTextTable,
    pub startingRow: i32,
    pub rowSpan: i32,
    pub startingColumn: i32,
    pub columnSpan: i32,
}

impl NSTextTableBlock {
    pub fn new(table: NSTextTable, startingRow: i32, rowSpan: i32, startingColumn: i32, columnSpan: i32) -> Self {
        Self {
            base: NSTextBlock::new(),
            table,
            startingRow,
            rowSpan,
            startingColumn,
            columnSpan,
        }
    }

    /// swift: NSTextTableBlock.drawBackground(withFrame:in:characterRange:layoutManager:) —
    /// GridTextTableBlock.swift (in scope) overrides this and calls `super.drawBackground(...)`
    /// for the no-page-break case, so the base implementation has to exist here, not just the
    /// override. Drawing itself needs a live graphics context (phase B / host-resident).
    pub fn drawBackground(
        &self,
        _frame_rect: CGRect,
        _control_view: &crate::textkit::NSView,
        _character_range: crate::foundation::NSRange,
        _layout_manager: &crate::textkit::NSLayoutManager,
    ) {
        todo!("swift: NSTextTableBlock.drawBackground(withFrame:in:characterRange:layoutManager:) — phase B")
    }
}

/// swift: `NSTextTableBlock : NSTextBlock` — Rust has no class inheritance, so the "is-a" relation
/// is expressed the way this crate's own doc comment above already promises ("per convention §3's
/// `extension T: P` → `impl P for T` mapping" extends the same way to subclassing): `Deref`/
/// `DerefMut` onto the `base` field, so every `NSTextBlock` method (`width`, `borderColor`,
/// `setWidth`, `setContentWidth`, the convenience wrappers above, …) is reachable directly on an
/// `NSTextTableBlock` exactly as Swift's subclassing made them reachable on `NSTextTableBlock`
/// there.
impl std::ops::Deref for NSTextTableBlock {
    type Target = NSTextBlock;
    fn deref(&self) -> &NSTextBlock {
        &self.base
    }
}

impl std::ops::DerefMut for NSTextTableBlock {
    fn deref_mut(&mut self) -> &mut NSTextBlock {
        &mut self.base
    }
}

/// swift: NSTextTable — the table itself: column count plus collapse behaviour.
#[derive(Debug, Clone, Default)]
pub struct NSTextTable {
    pub numberOfColumns: i32,
    pub collapsesBorders: bool,
    pub hidesEmptyCells: bool,
}

impl NSTextTable {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn rectForBlock(
        &self,
        _block: &NSTextTableBlock,
        _layout_manager: &crate::textkit::NSLayoutManager,
        _character_range: crate::foundation::NSRange,
    ) -> CGRect {
        todo!("swift: NSTextTable.rectForBlock(_:layoutManager:atIndex:effectiveRange:) — phase B")
    }

    pub fn value(
        &self,
        _dimension: NSTextBlockDimension,
        _row: i32,
        _column: i32,
    ) -> CGFloat {
        todo!("swift: NSTextTable.value(forDimension:row:column:) — phase B")
    }
}
