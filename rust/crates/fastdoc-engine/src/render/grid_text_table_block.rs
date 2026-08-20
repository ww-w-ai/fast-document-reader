//! swift: Render/GridTextTableBlock.swift
//! swift-range: 1-2
//! swift-range: 19-19
//! swift-range: 50-50
//! swift-range: 80-80
//! swift-range: 92-92
//! swift-range: 100-100
//! swift-range: 111-111
//! swift-range: 116-116
//! swift-range: 123-123
//! swift-range: 129-129
//! swift-range: 145-145
//! swift-range: 222-222
//! swift-range: 252-252

use std::collections::HashMap;

use swiftshim::{
    CGFloat, NSBezierPath, NSColor, NSImage, NSLayoutManager, NSPoint, NSRange, NSRect,
    NSRectEdge, NSTextTableBlock, NSView,
};

use crate::render::office::office_block::{BorderLineStyle, BorderSide, CellDiagonal};

// swift: Render/GridTextTableBlock.swift:3-18
// A table cell that knows a page can pass THROUGH it, and paints itself accordingly.
//
// `NSTextTableBlock` paints one background and one border box around the block's whole frame. When
// a cell's own text is divided between two pages — which is what happens to a row taller than the
// page body (invariant 64) — that single box spans the desk gap between the two sheets: a border
// drawn across empty paper, and the reader's own header and page number sitting inside a cell.
//
// The owner's rule, given on sight of it: *"셀 중간이 잘리는 경우에는 라인이 없고, 셀로 구분되어 잘릴
// 때는 라인이 있는 것은 동일"* — a cut through a cell's middle shows NO rule on either side of the
// gap, so the two halves read as one cell continuing, while a break at a real cell boundary keeps
// its rules. This class is that rule, and nothing else: it changes only what is DRAWN. Geometry
// still belongs to AppKit (invariants 39/42) — the frame it is handed is the frame it paints in.
//
// The page geometry is read from the layout manager's own delegate, which is the object that made
// the gaps in the first place (`PageBandLayoutDelegate.openedBands`), so there is no second source
// of truth about where a page ends.
//
// swift: `final class GridTextTableBlock: NSTextTableBlock` — class -> struct wrapping the
// superclass's shim state (convention §3's `class` mapping is `Ref<T>`; this is a subclass that
// overrides a drawing callback, so the superclass surface is held as a field rather than double
// wrapped — `base` stands in for everything `NSTextTableBlock` itself carries, e.g. `.table`,
// `.startingRow`, `.backgroundColor`, `.width(for:edge:)`, `.setWidth(...)`, `.borderColor(for:)`).
pub struct GridTextTableBlock {
    pub base: NSTextTableBlock,

    // swift: Render/GridTextTableBlock.swift:93-99
    /// Background plus the edges this segment is allowed to show. A cut edge shows nothing — that is
    /// the whole point — and every other edge keeps the width and colour invariant 47 resolved for it.
    /// How each edge is DRAWN, by edge. `NSTextTableBlock` carries a width and a colour per edge and
    /// nothing else, so a document's dotted or double rule had nowhere to go and was painted solid.
    /// Set by `TableBlockBuilder` from the resolved `BorderSide`; an edge absent here is solid, which
    /// is what every markdown table and every rule this reader invents itself is.
    pub edge_styles: HashMap<NSRectEdge, BorderLineStyle>,

    // swift: Render/GridTextTableBlock.swift:101-110
    /// What the document said this edge's rule MEASURES, when that is not what layout reserved for
    /// it. `NSTextTableBlock` draws a rule at the width it was given, and the width it is given has
    /// to be a whole point or the geometry stops adding up (`TableBlockBuilder.laidOutBorderWidth`) —
    /// so a 0.1mm hairline and a 0.4mm rule were both handed up rounded, and a real contract's six
    /// declared widths (0.28 / 0.34 / 1.13 / 1.42 / 1.70 / 1.98pt) came out as two. The document's
    /// own hierarchy of weights disappeared, which is what reads as a ragged grid.
    ///
    /// So the reserved band stays whole-point and the RULE is drawn at its declared width, centred
    /// in that band. Nothing moves: the geometry is the same number layout already charged for.
    pub declared_widths: HashMap<NSRectEdge, CGFloat>,

    // swift: Render/GridTextTableBlock.swift:112-115
    /// The cell's own picture fill (`Cell.backgroundImage`). Painted per SEGMENT, like the shading
    /// and the side rules, so a cell a page break crosses shows its image on each sheet and nothing
    /// on the desk between them.
    pub background_image: Option<NSImage>,

    // swift: Render/GridTextTableBlock.swift:117-122
    /// The rule this cell draws ACROSS itself, when the document drew one. Painted per SEGMENT like
    /// everything else here, so a diagonal in a cell a page break crosses appears on each sheet and
    /// never on the desk between them — and, because it is drawn per segment, each piece's diagonal
    /// spans that piece rather than the whole original box, which is the only reading that stays
    /// inside the paper.
    pub diagonal: Option<CellDiagonal>,
}

impl GridTextTableBlock {
    // swift: Render/GridTextTableBlock.swift:124-128
    /// True when any edge needs a stroke this class has to draw itself. `super` paints solid bars, so
    /// only a non-solid edge forces the override on a cell no page break crosses.
    pub fn has_styled_edge(&self) -> bool {
        self.edge_styles.values().any(|s| *s != BorderLineStyle::Solid)
            || !self.declared_widths.is_empty()
            || self.diagonal.is_some()
    }

    // swift: Render/GridTextTableBlock.swift:20-49
    /// swift: override func drawBackground(withFrame:in:characterRange:layoutManager:)
    pub fn draw_background(
        &self,
        frame_rect: NSRect,
        control_view: &NSView,
        char_range: NSRange,
        layout_manager: &NSLayoutManager,
    ) {
        // THE TWO COORDINATE SYSTEMS. `frameRect` arrives in the VIEW's coordinates, while
        // `openedBands` is recorded from line fragment rects, which are the TEXT CONTAINER's — the
        // difference is `NSTextView.textContainerOrigin`, 28pt in this reader. Comparing them raw put
        // every cut 27.6pt too high: measured by scanning the rendered view, the side rules stopped at
        // text-y 756.9 and resumed at 882.7 against a band running 784.5…910.6, so a strip of cell was
        // drawn on the desk and a strip of paper left blank above the text that follows.
        let origin_y = control_view
            .asTextView()
            .map(|tv| tv.textContainerOrigin().y)
            .unwrap_or(0.0);
        let gaps = Self::gaps_crossing(frame_rect, layout_manager, char_range, origin_y);
        // A styled edge has to be drawn by `paint` even on a cell no band crosses — `super` knows
        // only solid bars. One segment, no cuts: the same picture as `super` for every solid edge.
        if gaps.is_empty() {
            if self.has_styled_edge() || self.background_image.is_some() {
                self.paint(frame_rect, false, false);
                return;
            }
            self.base.drawBackground(frame_rect, control_view, char_range, layout_manager);
            return;
        }
        // One segment per piece of paper this cell appears on. `super` cannot be used for them: it
        // would paint a full border box around each segment, which is the rule at the cut that the
        // owner's rule says must not be there.
        let segments = Self::segments(frame_rect, &gaps);
        let n = segments.len();
        for (i, segment) in segments.into_iter().enumerate() {
            self.paint(segment, i > 0, i < n - 1);
        }
    }

    // swift: Render/GridTextTableBlock.swift:51-79
    /// The empty bands this cell's box reaches across.
    ///
    /// NOTHING IS EVER PAINTED INSIDE A BAND. A band is empty paper — the desk between two sheets —
    /// so a cell whose box spans one is drawn in pieces whether or not its OWN text continues on the
    /// far side. The left-hand label of the reported document is exactly that case: its two lines sit
    /// at the top of a row 750pt tall, so its text is entirely above the gap while its box runs
    /// 448.9…1198.8, and painting that box whole put the cell's shading and side rules straight
    /// across the desk and on into the next sheet.
    ///
    /// The band's own edges ARE where the text is cut — `PageBandLayoutDelegate` records a band as
    /// `[where the moved line was going to start, where it now starts]`, and the line before it ends
    /// exactly at that first number. So the cut aligns with the text by construction, and it aligns
    /// for EVERY cell of the row at once. Deriving it per cell instead was built and measured wrong:
    /// each cell then cut at its own last line, and a label whose text stops 300pt above the row's
    /// bottom was drawn as a 6.4pt sliver (`segs=["442.5…448.9", "910.6…1198.8"]`).
    ///
    /// Only a band strictly INSIDE the frame counts. One that merely touches an edge is the ordinary
    /// case of a cell ending at a page bottom, and treating it as a cut erased the rules of a whole
    /// table that merely FOLLOWED a piece carried to the next page.
    fn gaps_crossing(
        frame: NSRect,
        layout_manager: &NSLayoutManager,
        _char_range: NSRange,
        origin_y: CGFloat,
    ) -> Vec<(CGFloat, CGFloat)> {
        // swift: guard let delegate = layoutManager.delegate as? PageBandLayoutDelegate,
        //        !delegate.openedBands.isEmpty else { return [] }
        let Some(delegate) = layout_manager.page_band_delegate() else {
            return Vec::new();
        };
        let opened_bands = delegate.opened_bands();
        if opened_bands.is_empty() {
            return Vec::new();
        }
        let mut out: Vec<(CGFloat, CGFloat)> = opened_bands
            .into_iter()
            .map(|b| (b.top + origin_y, b.height))
            .filter(|(top, height)| {
                *top > frame.minY() + 0.5 && *top + *height < frame.maxY() - 0.5
            })
            .collect();
        out.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        out
    }

    // swift: Render/GridTextTableBlock.swift:81-91
    fn segments(frame: NSRect, gaps: &[(CGFloat, CGFloat)]) -> Vec<NSRect> {
        let mut out: Vec<NSRect> = Vec::new();
        let mut y = frame.minY();
        for (top, height) in gaps {
            out.push(NSRect::new(frame.minX(), y, frame.width(), *top - y));
            y = *top + *height;
        }
        out.push(NSRect::new(frame.minX(), y, frame.width(), frame.maxY() - y));
        out.into_iter().filter(|r| r.height() > 0.5).collect()
    }

    // swift: Render/GridTextTableBlock.swift:130-144
    /// The thickness this edge's rule is DRAWN at, and where inside its reserved band it sits.
    /// Absent from `declaredWidths` = draw the whole band, which is what every markdown table and
    /// every rule this reader invents itself does.
    pub fn rule(&self, band: NSRect, edge: NSRectEdge) -> NSRect {
        let reserved = if band.width().max(band.height()) == band.width() {
            band.height()
        } else {
            band.width()
        };
        let Some(declared) = self.declared_widths.get(&edge).copied() else {
            return band;
        };
        if !(declared < reserved) {
            return band;
        }
        // A rule the document declared is never drawn away to nothing: below about a quarter point
        // it stops being a line on any display and becomes a smudge, which reads as a MISSING rule
        // rather than a fine one.
        let drawn = declared.max(0.25);
        let inset = (reserved - drawn) / 2.0;
        if band.width() >= band.height() {
            NSRect::new(band.minX(), band.minY() + inset, band.width(), drawn)
        } else {
            NSRect::new(band.minX() + inset, band.minY(), drawn, band.height())
        }
    }

    // swift: Render/GridTextTableBlock.swift:146-221
    fn paint(&self, rect: NSRect, cut_above: bool, cut_below: bool) {
        if let Some(background) = self.base.backgroundColor() {
            background.setFill();
            rect.fill();
        }
        if let Some(image) = &self.background_image {
            image.draw_in(rect, NSPoint::zero(), /* .source_over */ true);
        }
        let edges: [(NSRectEdge, NSRect); 4] = [
            (
                NSRectEdge::MinX,
                NSRect::new(
                    rect.minX(),
                    rect.minY(),
                    self.width_for_border(NSRectEdge::MinX),
                    rect.height(),
                ),
            ),
            (
                NSRectEdge::MaxX,
                NSRect::new(
                    rect.maxX() - self.width_for_border(NSRectEdge::MaxX),
                    rect.minY(),
                    self.width_for_border(NSRectEdge::MaxX),
                    rect.height(),
                ),
            ),
            (
                NSRectEdge::MinY,
                NSRect::new(
                    rect.minX(),
                    rect.minY(),
                    rect.width(),
                    self.width_for_border(NSRectEdge::MinY),
                ),
            ),
            (
                NSRectEdge::MaxY,
                NSRect::new(
                    rect.minX(),
                    rect.maxY() - self.width_for_border(NSRectEdge::MaxY),
                    rect.width(),
                    self.width_for_border(NSRectEdge::MaxY),
                ),
            ),
        ];
        for (edge, band) in edges {
            if edge == NSRectEdge::MinY && cut_above {
                continue;
            }
            if edge == NSRectEdge::MaxY && cut_below {
                continue;
            }
            if !(band.width() > 0.0 && band.height() > 0.0) {
                continue;
            }
            let bar = self.rule(band, edge);
            let colour = self.border_color(edge).unwrap_or(NSColor::clear());
            match self.edge_styles.get(&edge).copied().unwrap_or(BorderLineStyle::Solid) {
                BorderLineStyle::Solid => {
                    colour.setFill();
                    if self.declared_widths.contains_key(&edge) {
                        // `NSRect.fill()` SNAPS to whole device pixels, so a 0.3pt and a 0.9pt rule land
                        // on the same single pixel and the declared width is thrown away again — on
                        // screen only; the PDF, being vector, kept it. A bezier fill is antialiased, so
                        // a fine rule reads as a fine rule at any scale. Whole-point rules keep the
                        // snapped fill they have always had: crisp is right when the width is exact.
                        NSBezierPath::fromRect(bar).fill();
                    } else {
                        bar.fill();
                    }
                }
                BorderLineStyle::Dashed | BorderLineStyle::Dotted => {
                    // A dash is STROKED down the middle of the bar the solid case fills, so a dotted and
                    // a solid rule of the same declared width occupy the same band and the geometry the
                    // layout already accounted for does not move. The pattern is in multiples of the
                    // rule's own width — a fixed 3pt dash disappears on a 0.3pt hairline and looks like
                    // a chain on a 3pt frame.
                    let unit = if bar.width().max(bar.height()) == bar.width() {
                        bar.height()
                    } else {
                        bar.width()
                    };
                    let thickness = unit.max(0.5);
                    let pattern: [CGFloat; 2] =
                        if self.edge_styles.get(&edge).copied() == Some(BorderLineStyle::Dotted) {
                            [thickness, thickness * 2.0]
                        } else {
                            [thickness * 4.0, thickness * 2.0]
                        };
                    let mut path = NSBezierPath::new();
                    if bar.width() >= bar.height() {
                        // horizontal edge
                        let y = bar.midY();
                        path.moveTo(NSPoint::new(bar.minX(), y));
                        path.lineTo(NSPoint::new(bar.maxX(), y));
                    } else {
                        // vertical edge
                        let x = bar.midX();
                        path.moveTo(NSPoint::new(x, bar.minY()));
                        path.lineTo(NSPoint::new(x, bar.maxY()));
                    }
                    path.set_line_width(thickness);
                    path.setLineDash(&pattern, 0.0);
                    colour.setStroke();
                    path.stroke();
                }
                BorderLineStyle::Double => {
                    // Two rules inside the SAME band, each a third of it, with a third of clear between —
                    // the band's total is what the document declared and what layout reserved, so a
                    // double rule cannot push a cell's content.
                    colour.setFill();
                    if bar.width() >= bar.height() {
                        let t = (bar.height() / 3.0).max(0.5);
                        NSRect::new(bar.minX(), bar.minY(), bar.width(), t).fill();
                        NSRect::new(bar.minX(), bar.maxY() - t, bar.width(), t).fill();
                    } else {
                        let t = (bar.width() / 3.0).max(0.5);
                        NSRect::new(bar.minX(), bar.minY(), t, bar.height()).fill();
                        NSRect::new(bar.maxX() - t, bar.minY(), t, bar.height()).fill();
                    }
                }
            }
        }
        self.draw_diagonal(rect);
    }

    /// swift: `width(for: .border, edge:)` read through `base` — kept as a tiny helper so `paint`'s
    /// edge table above reads the same as the Swift call sites it mirrors.
    fn width_for_border(&self, edge: NSRectEdge) -> CGFloat {
        self.base.width_for_border(edge)
    }

    /// swift: `borderColor(for:)` read through `base`.
    fn border_color(&self, edge: NSRectEdge) -> Option<NSColor> {
        self.base.borderColor(edge)
    }

    // swift: Render/GridTextTableBlock.swift:223-251
    /// The cell's diagonal, drawn corner to corner of the segment.
    ///
    /// AFTER the edges, deliberately: the two meet at the corners, and a diagonal drawn first has
    /// its ends buried under the frame, which reads as a line that stops short of the corner. The
    /// edges are bars the layout already reserved, so painting over their inner half costs nothing.
    ///
    /// A dash pattern is scaled by the line's own width, the same rule the edges use — a fixed
    /// pattern turns a hairline into a dotted trace and a 3pt line into a chain.
    fn draw_diagonal(&self, rect: NSRect) {
        let Some(diagonal) = &self.diagonal else { return };
        if !(rect.width() > 0.5 && rect.height() > 0.5) {
            return;
        }
        let mut path = NSBezierPath::new();
        use crate::render::office::office_block::CellDiagonalDirection;
        if diagonal.direction != CellDiagonalDirection::Backslash {
            // slash: ↙ → ↗
            path.moveTo(NSPoint::new(rect.minX(), rect.minY()));
            path.lineTo(NSPoint::new(rect.maxX(), rect.maxY()));
        }
        if diagonal.direction != CellDiagonalDirection::Slash {
            // backslash: ↖ → ↘
            path.moveTo(NSPoint::new(rect.minX(), rect.maxY()));
            path.lineTo(NSPoint::new(rect.maxX(), rect.minY()));
        }
        let thickness = diagonal.side.width.max(0.25);
        path.set_line_width(thickness);
        match diagonal.side.style {
            BorderLineStyle::Dashed => path.setLineDash(&[thickness * 4.0, thickness * 2.0], 0.0),
            BorderLineStyle::Dotted => path.setLineDash(&[thickness, thickness * 2.0], 0.0),
            BorderLineStyle::Solid | BorderLineStyle::Double => {}
        }
        diagonal.side.color.unwrap_or(NSColor::clear()).setStroke();
        path.stroke();
    }
}
