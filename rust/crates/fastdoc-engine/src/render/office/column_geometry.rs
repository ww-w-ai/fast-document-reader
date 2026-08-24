//! swift: Render/Office/ColumnGeometry.swift
//! swift-range: 1-2

use std::collections::HashMap;
use swiftshim::{CGFloat, NSColor};

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum OfficeColumnFlowType {
    Normal,
    Distribute,
    Parallel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum OfficeColumnDirection {
    LeftToRight,
    RightToLeft,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) enum OfficeColumnLayoutError {
    Count(u16),
    SeparatorType(u8),
    SeparatorWidthCode(u8),
}

/// What a document declares when it says "from here on, N columns", and where those columns sit.
///
/// The declaration arrives at a PARAGRAPH, not on the section: HWP puts a `ColumnDef` control in the
/// text, so one document can switch layout partway and switch back. Measured over the 637-sample
/// corpus (`examples/scan_columns.rs`, counts only): **64 documents (10.0%) declare more than one
/// column somewhere**, across 149 declarations — 125 of two columns, 20 of three, and single
/// documents at four, five and nine. That is three times as common as a footnote, and the paragraphs
/// living under such a declaration are 22,204 of 558,452 (3.98%).
///
/// This type and `ColumnGeometry` are the ARITHMETIC only. Nothing here lays anything out or draws
/// anything — deciding which line belongs to which column, and moving it there, is the layout half
/// and is deliberately separate, exactly as `FootnoteBandSettle` was separated from the settle loop
/// it feeds (invariant 98).
// swift: Render/Office/ColumnGeometry.swift:3-45
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OfficeColumnLayout {
    pub flow_type: Option<OfficeColumnFlowType>,
    /// How many columns the text flows through. `1` is the ordinary single column and is carried
    /// rather than dropped: a document that RETURNS to one column says so with a declaration, and
    /// throwing it away would leave the previous one in force for the rest of the document.
    pub count: i64,
    /// The gap between two columns, in points, as the document measures it. Needed whether or not
    /// the columns are equal — an equal split is `(width − spacing × (count − 1)) ÷ count`.
    pub spacing: CGFloat,
    /// Per-column widths and the gap after each, for a document that did NOT ask for equal columns
    /// — 57 of the 149 declarations (38%). Empty means equal.
    ///
    /// The UNIT is whatever `proportional` says, which is the format's own two-mindedness rather
    /// than ours: HWP 5 binary states shares that sum to 32,768 while HWPX states absolute lengths.
    pub widths: Vec<CGFloat>,
    pub gaps: Vec<CGFloat>,
    /// Whether `widths`/`gaps` are shares of the whole (`true`) or points (`false`).
    pub proportional: bool,
    pub same_width: bool,
    pub direction: OfficeColumnDirection,
    /// The rule drawn between columns — `0` is no rule, which is what 93 of the 149 declarations
    /// say. The other 56 (38%) do draw one.
    pub separator_type: i64,
    pub separator_width_code: u8,
    pub separator_width_pt: CGFloat,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub separator_color: Option<NSColor>,
    pub separator_color_ref: Option<u32>,
    pub source_raw_attributes: Option<u16>,
}

impl Default for OfficeColumnLayout {
    fn default() -> Self {
        OfficeColumnLayout {
            flow_type: None,
            count: 1,
            spacing: 0.0,
            widths: Vec::new(),
            gaps: Vec::new(),
            proportional: false,
            same_width: true,
            direction: OfficeColumnDirection::LeftToRight,
            separator_type: 0,
            separator_width_code: 0,
            separator_width_pt: 0.1 * 72.0 / 25.4,
            separator_color: None,
            separator_color_ref: None,
            source_raw_attributes: None,
        }
    }
}

impl OfficeColumnLayout {
    #[allow(dead_code)]
    pub(crate) fn from_rhwp_column_def(
        source: &rhwp::model::page::ColumnDef,
    ) -> Result<Self, OfficeColumnLayoutError> {
        use rhwp::model::page::{ColumnDirection, ColumnType};

        let rhwp::model::page::ColumnDef {
            column_type,
            column_count,
            direction,
            same_width,
            spacing,
            widths,
            gaps,
            proportional_widths,
            separator_type,
            separator_width,
            separator_color,
            raw_attr,
        } = source;
        if *column_count == 0 {
            return Err(OfficeColumnLayoutError::Count(*column_count));
        }
        if *separator_type > 7 {
            return Err(OfficeColumnLayoutError::SeparatorType(*separator_type));
        }

        let flow_type = match column_type {
            ColumnType::Normal => OfficeColumnFlowType::Normal,
            ColumnType::Distribute => OfficeColumnFlowType::Distribute,
            ColumnType::Parallel => OfficeColumnFlowType::Parallel,
        };
        let direction = match direction {
            ColumnDirection::LeftToRight => OfficeColumnDirection::LeftToRight,
            ColumnDirection::RightToLeft => OfficeColumnDirection::RightToLeft,
        };
        let width_pt = column_width_code_points(*separator_width).ok_or(
            OfficeColumnLayoutError::SeparatorWidthCode(*separator_width),
        )?;
        let raw_color = *separator_color;
        let color = NSColor::srgb(
            f64::from(raw_color & 0xff) / 255.0,
            f64::from((raw_color >> 8) & 0xff) / 255.0,
            f64::from((raw_color >> 16) & 0xff) / 255.0,
            1.0,
        );
        Ok(Self {
            flow_type: Some(flow_type),
            count: i64::from(*column_count),
            spacing: f64::from(*spacing) / 100.0,
            widths: widths
                .iter()
                .map(|value| {
                    if *proportional_widths {
                        f64::from(*value)
                    } else {
                        f64::from(*value) / 100.0
                    }
                })
                .collect(),
            gaps: gaps
                .iter()
                .map(|value| {
                    if *proportional_widths {
                        f64::from(*value)
                    } else {
                        f64::from(*value) / 100.0
                    }
                })
                .collect(),
            proportional: *proportional_widths,
            same_width: *same_width,
            direction,
            separator_type: i64::from(*separator_type),
            separator_width_code: *separator_width,
            separator_width_pt: width_pt,
            separator_color: (*separator_type != 0).then_some(color),
            separator_color_ref: Some(raw_color),
            source_raw_attributes: Some(*raw_attr),
        })
    }

    /// Whether this declaration actually splits the text. A `count` of one is a declaration to
    /// STOP, and every consumer wants to tell the two apart without repeating the comparison.
    // swift: Render/Office/ColumnGeometry.swift:41-41
    pub fn splits_text(&self) -> bool {
        self.count > 1
    }

    /// Whether a rule is drawn between the columns.
    // swift: Render/Office/ColumnGeometry.swift:43-43
    pub fn draws_separator(&self) -> bool {
        self.separator_type != 0 && self.splits_text()
    }
}

pub(crate) fn column_width_code_points(code: u8) -> Option<CGFloat> {
    const MILLIMETERS: [CGFloat; 16] = [
        0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0,
    ];
    MILLIMETERS
        .get(usize::from(code))
        .map(|mm| mm * 72.0 / 25.4)
}

#[cfg(test)]
mod s2a1d_tests {
    use super::*;
    use rhwp::model::page::{ColumnDef, ColumnDirection, ColumnType};

    #[test]
    fn pinned_column_def_fields_are_converted_without_loss() {
        let source = ColumnDef {
            column_type: ColumnType::Parallel,
            column_count: 3,
            direction: ColumnDirection::RightToLeft,
            same_width: false,
            spacing: 250,
            widths: vec![1000, 1100, 1200],
            gaps: vec![100, 101, 102],
            proportional_widths: false,
            separator_type: 4,
            separator_width: 7,
            separator_color: 0xaa33_2211,
            raw_attr: 0xabcd,
        };
        let actual = OfficeColumnLayout::from_rhwp_column_def(&source).unwrap();
        assert_eq!(actual.flow_type, Some(OfficeColumnFlowType::Parallel));
        assert_eq!(actual.count, 3);
        assert_eq!(actual.direction, OfficeColumnDirection::RightToLeft);
        assert!(!actual.same_width && !actual.proportional);
        assert_eq!(actual.spacing, 2.5);
        assert_eq!(actual.widths, vec![10.0, 11.0, 12.0]);
        assert_eq!(actual.gaps, vec![1.0, 1.01, 1.02]);
        assert_eq!((actual.separator_type, actual.separator_width_code), (4, 7));
        assert_eq!(actual.separator_color_ref, Some(0xaa33_2211));
        assert_eq!(actual.source_raw_attributes, Some(0xabcd));
        assert_eq!(
            actual.separator_color.unwrap().redComponent(),
            0x11 as f64 / 255.0
        );
    }

    #[test]
    fn pinned_column_def_rejects_invalid_closed_values() {
        let mut source = ColumnDef::default();
        assert_eq!(
            OfficeColumnLayout::from_rhwp_column_def(&source),
            Err(OfficeColumnLayoutError::Count(0))
        );
        source.column_count = 1;
        source.separator_type = 8;
        assert_eq!(
            OfficeColumnLayout::from_rhwp_column_def(&source),
            Err(OfficeColumnLayoutError::SeparatorType(8))
        );
        source.separator_type = 0;
        source.separator_width = 16;
        assert_eq!(
            OfficeColumnLayout::from_rhwp_column_def(&source),
            Err(OfficeColumnLayoutError::SeparatorWidthCode(16))
        );
    }
}

/// Where each column sits inside a body width.
// swift: Render/Office/ColumnGeometry.swift:46-53
pub struct ColumnGeometry;

/// One column's horizontal extent, in the same coordinates the body text is laid out in.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Column {
    pub x: CGFloat,
    pub width: CGFloat,
}

impl ColumnGeometry {
    /// The columns a declaration produces inside `bodyWidth`.
    ///
    /// Returns ONE column spanning the whole width for any declaration that does not split the text
    /// — a single column, a nonsensical count, or a width nothing can fit in. Callers therefore
    /// never branch on "is this document multi-column"; they lay out into whatever comes back, and a
    /// document that declares nothing gets exactly the geometry it has always had.
    // swift: Render/Office/ColumnGeometry.swift:54-79
    pub fn columns(body_width: CGFloat, layout: &OfficeColumnLayout) -> Vec<Column> {
        let whole = vec![Column { x: 0.0, width: body_width }];
        if !(body_width > 0.0) || !(layout.count > 1) {
            return whole;
        }

        // The document listed its own widths — honour them, in whichever unit it used.
        if !layout.widths.is_empty() && layout.widths.len() as i64 >= layout.count {
            if let Some(explicit) = Self::explicit_columns(body_width, layout) {
                return explicit;
            }
        }

        let gaps = layout.spacing * ((layout.count - 1) as CGFloat);
        let each = (body_width - gaps) / (layout.count as CGFloat);
        // A spacing wider than the page would give every column a negative width and put the text
        // outside the paper. The declaration is then unusable and the single column is the honest
        // answer: too wide is a document that will not fit, not a document to be drawn inside out.
        if !(each > 0.0) {
            return whole;
        }
        (0..layout.count)
            .map(|i| Column { x: (i as CGFloat) * (each + layout.spacing), width: each })
            .collect()
    }

    /// Columns from the per-column widths a document listed, or `nil` when they do not describe a
    /// usable layout and the equal split should stand.
    // swift: Render/Office/ColumnGeometry.swift:80-113
    fn explicit_columns(body_width: CGFloat, layout: &OfficeColumnLayout) -> Option<Vec<Column>> {
        let widths: Vec<CGFloat> = layout.widths.iter().copied().take(layout.count as usize).collect();
        // A gap list may be shorter than the column list, and the last column's gap is meaningless
        // — pad rather than index past the end.
        let gaps: Vec<CGFloat> = (0..layout.count)
            .map(|i| {
                let idx = i as usize;
                if idx < layout.gaps.len() {
                    layout.gaps[idx]
                } else {
                    0.0
                }
            })
            .collect();

        let mut scale: CGFloat = 1.0;
        if layout.proportional {
            // Shares, summing to the format's own 32,768 — but taken from the actual total rather
            // than that constant, so a document whose numbers are slightly off still lands inside
            // the page instead of overflowing it by the size of its own rounding error.
            let total: CGFloat = widths.iter().sum::<CGFloat>() + gaps.iter().sum::<CGFloat>();
            if !(total > 0.0) {
                return None;
            }
            scale = body_width / total;
        }

        let mut out: Vec<Column> = Vec::new();
        let mut x: CGFloat = 0.0;
        for i in 0..(layout.count as usize) {
            let w = widths[i] * scale;
            if !(w > 0.0) {
                return None;
            }
            out.push(Column { x, width: w });
            x += w + gaps[i] * scale;
        }
        // Absolute widths can simply be wrong for this page — a document written for wider paper, or
        // a reader zoomed past what it declared. Falling back to the equal split keeps the text on
        // the sheet, which matters more than honouring a number that does not fit.
        let last_gap = gaps.last().copied().unwrap_or(0.0);
        if !(x - last_gap * scale <= body_width + 0.5) {
            return None;
        }
        Some(out)
    }

    /// Where each line of a columned run belongs, worked out from ONE measurement of the run laid
    /// out as a single tall stack.
    ///
    /// **Why a map and not a rule.** The obvious design — look at the line about to be set, see that
    /// it has run past the foot of its column, move it — was built and measured, and it is wrong for
    /// a reason nothing in the page-band machinery hints at: `shouldSetLineFragmentRect` can move a
    /// line's `x`, but the typesetter does NOT carry that `x` to the following line. It carries the
    /// `y` (which is what invariant 58's spike measured, and why the page band works) and re-derives
    /// `x` from the paragraph every time. So the first line of column 2 lands correctly and every
    /// line after it returns to column 1's left edge: measured on `samples/basic/shortcut.hwp`, 32
    /// lines moved and 1,200 stayed, which draws as a narrow single column, not as two.
    ///
    /// With `x` unable to carry the state, the column a line belongs to cannot be read back out of
    /// the laid-out page at all — so it is decided ONCE, from the flow, and keyed by the line's own
    /// CHARACTER LOCATION, which no transform can move. That also makes the whole thing idempotent
    /// by construction rather than by argument: re-laying out asks the map, and the map does not
    /// change.
    ///
    /// The flow is a single stack `columnHeight` tall per column, `count` columns per page: reading
    /// down column 1 of a sheet, then column 2, then the next sheet.
    ///
    /// **TWO COLUMN HEIGHTS, because a run does not have to begin at a page top.** HWP puts a column
    /// declaration in the TEXT, so a document can go to two columns halfway down a sheet. That run's
    /// first page offers only what is LEFT of it, and every page after offers the whole body — one
    /// run, two heights. Passing the leftover as the only height (which is what this took before)
    /// makes every later sheet as short as the first, so the columns stop a third of the way down
    /// the page and the run spills onto sheets it did not need. `firstColumnHeight` defaults to
    /// `columnHeight`, and when a run DOES begin at a page top the two are equal and every number
    /// below reduces algebraically to what it was — which is what keeps the runs that already
    /// worked provably untouched.
    ///
    /// `runOrigin` is where the run's own first column starts, which is NOT a page top for such a
    /// run: the lines above it belong to the single-column flow and must not be drawn over.
    // swift: Render/Office/ColumnGeometry.swift:114-206
    #[allow(clippy::too_many_arguments)]
    pub fn placements(
        lines: &[(i64, CGFloat, CGFloat)],
        run_origin: CGFloat,
        first_page: CGFloat,
        columns: &[Column],
        column_height: CGFloat,
        pitch: CGFloat,
        leading_band: CGFloat,
        first_column_height: Option<CGFloat>,
    ) -> HashMap<i64, (CGFloat, CGFloat)> {
        let first_height = first_column_height.unwrap_or(column_height);
        if !(columns.len() > 1) || !(column_height > 0.0) || !(first_height > 0.0) || !(pitch > 0.0) {
            return HashMap::new();
        }
        let count = columns.len() as CGFloat;
        let per_page = column_height * count;
        let first_per_page = first_height * count;
        let mut out: HashMap<i64, (CGFloat, CGFloat)> = HashMap::new();
        for line in lines {
            let (location, top, line_height) = *line;
            let d = top - run_origin;
            if !(d >= -0.01) {
                continue;
            }
            // Which sheet of the run this line falls on. The first sheet is measured separately
            // because it is the short one; every later sheet is the same full one, so the rest is
            // the original division shifted by that first sheet — the same `1e-6` of tolerance, for
            // the same measured reason as `column(atFlowOffset:)`.
            let on_first_page = (d / first_per_page) + 1e-6 < 1.0;
            let page_offset: CGFloat;
            let within_page: CGFloat;
            let height: CGFloat;
            if on_first_page {
                page_offset = 0.0;
                within_page = d;
                height = first_height;
            } else {
                let rest = d - first_per_page;
                page_offset = ((rest / per_page) + 1e-6).floor() + 1.0;
                within_page = rest - (page_offset - 1.0) * per_page;
                height = column_height;
            }
            let mut column_index = (((within_page / height) + 1e-6).floor()) as i64;
            column_index = column_index.max(0).min(columns.len() as i64 - 1);
            let within_column = within_page - (column_index as CGFloat) * height;
            let mut page = first_page + page_offset;
            // Where THIS sheet's columns begin. The run's own first sheet begins where the run does;
            // every later one at its page top.
            let mut column_top = if page_offset == 0.0 { run_origin } else { page * pitch + leading_band };
            // A line taller than what is left of its column would be drawn across the foot of the
            // page. Pushing it whole to the next column is the same answer the page band gives a
            // line that would straddle a sheet boundary, and for the same reason.
            let mut top_within = within_column;
            if within_column + line_height > height + 0.01 {
                if column_index + 1 < columns.len() as i64 {
                    column_index += 1;
                } else {
                    column_index = 0;
                    page += 1.0;
                    // A sheet reached by overflowing is a LATER sheet, so it starts at its own top
                    // even when the line came off the run's short first one.
                    column_top = page * pitch + leading_band;
                }
                top_within = 0.0;
            }
            out.insert(location, (columns[column_index as usize].x, column_top + top_within));
        }
        out
    }

    /// Which column a point sits in, and how far down that column it is.
    ///
    /// The text flows down column 0 to the bottom of the body, then to the TOP of column 1, and so
    /// on — so a distance measured from the start of the multi-column run maps to a column by the
    /// same division that maps a page to a sheet (`PageBandLayoutDelegate.page(of:leadingBand:)`),
    /// and carries the same hair of tolerance for the same measured reason: a line placed at exactly
    /// a boundary comes back a fraction under it and would otherwise read as the column before.
    ///
    /// Returns `nil` past the last column — that is the text overflowing the columned run, which is
    /// the layout's problem to report rather than something to answer with a wrong column.
    // swift: Render/Office/ColumnGeometry.swift:207-224
    pub fn column_at_flow_offset(offset: CGFloat, column_height: CGFloat, count: i64) -> Option<(i64, CGFloat)> {
        if !(column_height > 0.0) || !(count > 0) || !(offset >= 0.0) {
            return None;
        }
        let index = (((offset / column_height) + 1e-6).floor()) as i64;
        if !(index < count) {
            return None;
        }
        Some((index, offset - (index as CGFloat) * column_height))
    }
}
