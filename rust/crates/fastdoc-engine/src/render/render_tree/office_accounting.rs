//! Mechanical S2A1b decisions for the current Office run/paragraph/list source vocabulary.
#![cfg_attr(not(test), allow(dead_code))]

use super::wire;
use crate::render::office::column_geometry::{
    OfficeColumnDirection, OfficeColumnFlowType, OfficeColumnLayout,
};
use crate::render::office::office_block::{
    BorderSide, Cell, CellDiagonal, EdgeBorders, EdgePadding, ListNumbering, OfficeBlock,
    ParagraphFormat, Span, TabStop, TableFormat,
};
use std::collections::BTreeMap;

const EXPECTED_DECISIONS: usize = 73;
const EXPECTED_KEYS: &[&str] = &[
    "Span.text",
    "Span.bold",
    "Span.italic",
    "Span.underline",
    "Span.underline_style",
    "Span.code",
    "Span.caps",
    "Span.small_caps",
    "Span.link",
    "Span.strikethrough",
    "Span.superscript",
    "Span.footnote_ref",
    "Span.form_control",
    "Span.subscripted",
    "Span.rtl",
    "Span.bookmarks",
    "Span.comment_ids",
    "Span.text_color",
    "Span.highlight_color",
    "Span.letter_spacing_percent",
    "Span.width_scale_percent",
    "Span.baseline_offset_percent",
    "Span.underline_color",
    "Span.strikethrough_color",
    "Span.font_size",
    "Span.font_name",
    "Span.page_number_field",
    "Span.resolved_font_descriptor",
    "Span.column_layout",
    "ParagraphFormat.list_text_distance",
    "ParagraphFormat.spacing_before",
    "ParagraphFormat.spacing_after",
    "ParagraphFormat.line_height",
    "ParagraphFormat.indent_start",
    "ParagraphFormat.indent_end",
    "ParagraphFormat.first_line_indent",
    "ParagraphFormat.hanging_indent",
    "ParagraphFormat.contextual_spacing",
    "ParagraphFormat.shading",
    "ParagraphFormat.border_color",
    "ParagraphFormat.border_width",
    "ParagraphFormat.border_edges",
    "ParagraphFormat.east_asian_line_break",
    "ParagraphFormat.latin_line_break",
    "ParagraphFormat.auto_space_east_asian_latin",
    "ParagraphFormat.auto_space_east_asian_number",
    "ParagraphFormat.line_height_from_font_metrics",
    "ParagraphFormat.line_spacing_below",
    "TabStop.position",
    "TabStop.alignment",
    "TabStop.leader",
    "ListNumbering.glyphs",
    "ListNumbering.start_number",
    "OfficeBlock.Heading.level",
    "OfficeBlock.Heading.spans",
    "OfficeBlock.Heading.rtl",
    "OfficeBlock.Heading.alignment",
    "OfficeBlock.Heading.tab_stops",
    "OfficeBlock.Heading.format",
    "OfficeBlock.Paragraph.spans",
    "OfficeBlock.Paragraph.rtl",
    "OfficeBlock.Paragraph.alignment",
    "OfficeBlock.Paragraph.tab_stops",
    "OfficeBlock.Paragraph.format",
    "OfficeBlock.ListItem.level",
    "OfficeBlock.ListItem.ordered",
    "OfficeBlock.ListItem.spans",
    "OfficeBlock.ListItem.marker",
    "OfficeBlock.ListItem.rtl",
    "OfficeBlock.ListItem.alignment",
    "OfficeBlock.ListItem.tab_stops",
    "OfficeBlock.ListItem.format",
    "OfficeBlock.ListItem.numbering",
];

const TABLE_EXPECTED_DECISIONS: usize = 50;
const TABLE_EXPECTED_KEYS: &[&str] = &[
    "Cell.blocks",
    "Cell.row_span",
    "Cell.col_span",
    "Cell.background_color",
    "Cell.background_image",
    "Cell.background_gradient",
    "Cell.border_color",
    "Cell.border_width",
    "Cell.edge_borders",
    "Cell.edge_borders_ref",
    "Cell.width",
    "Cell.vertical_alignment",
    "Cell.padding",
    "Cell.edge_padding",
    "Cell.declared_height",
    "Cell.diagonal",
    "Cell.style_shading",
    "Cell.style_border_color",
    "Cell.style_border_width",
    "CellDiagonal.direction",
    "CellDiagonal.side",
    "BorderSide.width",
    "BorderSide.color",
    "BorderSide.style",
    "EdgeBorders.top",
    "EdgeBorders.left",
    "EdgeBorders.bottom",
    "EdgeBorders.right",
    "EdgeBorders.inside_h",
    "EdgeBorders.inside_v",
    "EdgePadding.top",
    "EdgePadding.left",
    "EdgePadding.bottom",
    "EdgePadding.right",
    "TableFormat.default_border_color",
    "TableFormat.default_border_width",
    "TableFormat.default_shading",
    "TableFormat.background_image",
    "TableFormat.background_gradient",
    "TableFormat.source_width",
    "TableFormat.edge_borders",
    "TableFormat.edge_borders_ref",
    "TableFormat.default_padding",
    "TableFormat.repeat_header_rows",
    "TableFormat.page_break_policy",
    "TableFormat.outer_margin",
    "OfficeBlock.Table.rows",
    "OfficeBlock.Table.header_rows",
    "OfficeBlock.Table.column_widths",
    "OfficeBlock.Table.format",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountingError {
    DuplicateDecision(String),
    DecisionSetMismatch {
        missing: Vec<String>,
        unexpected: Vec<String>,
    },
    WrongBlockVariant(&'static str),
    ConflictingVerticalPosition,
    HostResolvedFontAtSemanticBoundary,
    InvalidOfficeColumnCount(i64),
    InvalidOfficeColumnSeparatorType(i64),
    IncompleteOfficeColumnAuthority,
    InvalidOfficeColumnSeparatorWidth,
    InvalidOfficeColumnSeparatorColor,
    UnknownParagraphBorderBits(i64),
    InvalidRowSpan(i64),
    InvalidColumnSpan(i64),
    InvalidHeaderRows(i64),
    HeaderRowsExceedRowCount {
        header_rows: u32,
        row_count: usize,
    },
    CellBackgroundImageRequiresResourceBytes {
        path: String,
    },
    TableBackgroundImageRequiresResourceBytes {
        path: String,
    },
}

/// S6-4 removed this file's last `Refused` producer (the two background-fill fields) — every
/// field this file accounts for is now `Mapped` or `Deferred`, so the variant that used to exist
/// for the third case was removed with it rather than left never-constructed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DecisionKind {
    Mapped,
    /// A field the WIRE owns rather than any source layer — filled by the exporter and drained by
    /// `from_json`, so a reader's own value is always empty. Counted with the mapped ones because
    /// it IS accounted for; what it is not is a decision still owed (`Deferred`).
    Derived,
    Deferred,
}

struct DecisionToken {
    key: &'static str,
    kind: DecisionKind,
}

#[derive(Debug)]
pub struct FieldDecisionLedger {
    decisions: BTreeMap<&'static str, DecisionKind>,
}

impl FieldDecisionLedger {
    fn new() -> Self {
        Self {
            decisions: BTreeMap::new(),
        }
    }
    fn record(&mut self, token: DecisionToken) -> Result<(), AccountingError> {
        if self.decisions.insert(token.key, token.kind).is_some() {
            return Err(AccountingError::DuplicateDecision(token.key.into()));
        }
        Ok(())
    }
    fn finish(self) -> Result<Self, AccountingError> {
        self.finish_expected(EXPECTED_KEYS, EXPECTED_DECISIONS)
    }
    fn finish_expected(
        self,
        expected_keys: &[&'static str],
        expected_count: usize,
    ) -> Result<Self, AccountingError> {
        let expected: std::collections::BTreeSet<_> = expected_keys.iter().copied().collect();
        let actual: std::collections::BTreeSet<_> = self.decisions.keys().copied().collect();
        if actual != expected {
            return Err(AccountingError::DecisionSetMismatch {
                missing: expected
                    .difference(&actual)
                    .map(|value| (*value).into())
                    .collect(),
                unexpected: actual
                    .difference(&expected)
                    .map(|value| (*value).into())
                    .collect(),
            });
        }
        debug_assert_eq!(self.decisions.len(), expected_count);
        Ok(self)
    }
    pub fn decision_count(&self) -> usize {
        self.decisions.len()
    }
    pub fn deferred_count(&self) -> usize {
        self.decisions
            .values()
            .filter(|kind| matches!(kind, DecisionKind::Deferred))
            .count()
    }
    /// Fields the WIRE owns — see `DecisionKind::Derived`. Kept apart from `mapped_count` so a
    /// count keeps meaning what its name says.
    pub fn derived_count(&self) -> usize {
        self.decisions
            .values()
            .filter(|kind| matches!(kind, DecisionKind::Derived))
            .count()
    }

    pub fn mapped_count(&self) -> usize {
        self.decisions
            .values()
            .filter(|kind| matches!(kind, DecisionKind::Mapped))
            .count()
    }
}

fn mapped(key: &'static str) -> DecisionToken {
    DecisionToken {
        key,
        kind: DecisionKind::Mapped,
    }
}
/// A field the WIRE owns and no source layer maps — the exporter fills it and `from_json` drains
/// it, so a reader's own value is always empty. Named to match `office_result_accounting`'s helper
/// of the same name rather than inventing a second word for one idea.
fn derived(key: &'static str) -> DecisionToken {
    DecisionToken {
        key,
        kind: DecisionKind::Derived,
    }
}
fn deferred(key: &'static str) -> DecisionToken {
    DecisionToken {
        key,
        kind: DecisionKind::Deferred,
    }
}

macro_rules! record {
    ($ledger:ident, $prefix:literal, $($field:ident),+ $(,)?) => {$({
        let _ = &$field;
        $ledger.record(mapped(concat!($prefix, ".", stringify!($field))))?;
    })+};
}

pub(crate) fn account_current_office_slice(
    span: &Span,
    paragraph_format: &ParagraphFormat,
    tab_stop: &TabStop,
    numbering: &ListNumbering,
    heading: &OfficeBlock,
    paragraph: &OfficeBlock,
    list_item: &OfficeBlock,
) -> Result<FieldDecisionLedger, AccountingError> {
    let mut ledger = FieldDecisionLedger::new();

    let Span {
        text,
        bold,
        italic,
        underline,
        underline_style,
        code,
        caps,
        small_caps,
        link,
        strikethrough,
        superscript,
        footnote_ref,
        form_control,
        column_layout,
        subscripted,
        rtl,
        bookmarks,
        comment_ids,
        text_color,
        highlight_color,
        letter_spacing_percent,
        width_scale_percent,
        baseline_offset_percent,
        underline_color,
        strikethrough_color,
        font_size,
        font_name,
        resolved_font_descriptor,
        page_number_field,
    } = span;
    if *superscript && *subscripted {
        return Err(AccountingError::ConflictingVerticalPosition);
    }
    record!(
        ledger,
        "Span",
        text,
        bold,
        italic,
        underline,
        underline_style,
        code,
        caps,
        small_caps,
        link,
        strikethrough,
        superscript,
        footnote_ref,
        form_control,
        subscripted,
        rtl,
        bookmarks,
        comment_ids,
        text_color,
        highlight_color,
        letter_spacing_percent,
        width_scale_percent,
        baseline_offset_percent,
        underline_color,
        strikethrough_color,
        font_size,
        font_name,
        page_number_field
    );
    if resolved_font_descriptor.is_some() {
        return Err(AccountingError::HostResolvedFontAtSemanticBoundary);
    }
    ledger.record(deferred("Span.resolved_font_descriptor"))?;
    if let Some(layout) = column_layout {
        let _ = column_flow_from_office(layout)?;
    }
    ledger.record(mapped("Span.column_layout"))?;

    let ParagraphFormat {
        list_text_distance,
        spacing_before,
        spacing_after,
        line_height,
        indent_start,
        indent_end,
        first_line_indent,
        hanging_indent,
        contextual_spacing,
        shading,
        border_color,
        border_width,
        border_edges,
        east_asian_line_break,
        latin_line_break,
        auto_space_east_asian_latin,
        auto_space_east_asian_number,
        line_height_from_font_metrics,
        line_spacing_below,
    } = paragraph_format;
    let unknown_border_bits =
        border_edges.raw_value & !crate::render::office::office_block::RectEdge::ALL.raw_value;
    if unknown_border_bits != 0 {
        return Err(AccountingError::UnknownParagraphBorderBits(
            unknown_border_bits,
        ));
    }
    record!(
        ledger,
        "ParagraphFormat",
        list_text_distance,
        spacing_before,
        spacing_after,
        line_height,
        indent_start,
        indent_end,
        first_line_indent,
        hanging_indent,
        contextual_spacing,
        shading,
        border_color,
        border_width,
        border_edges,
        east_asian_line_break,
        latin_line_break,
        auto_space_east_asian_latin,
        auto_space_east_asian_number,
        line_height_from_font_metrics,
        line_spacing_below
    );

    let TabStop {
        position,
        alignment,
        leader,
    } = tab_stop;
    record!(ledger, "TabStop", position, alignment, leader);
    let ListNumbering {
        glyphs,
        start_number,
    } = numbering;
    record!(ledger, "ListNumbering", glyphs, start_number);

    let OfficeBlock::Heading {
        level,
        spans,
        rtl,
        alignment,
        tab_stops,
        format, .. } = heading
    else {
        return Err(AccountingError::WrongBlockVariant("Heading"));
    };
    record!(
        ledger,
        "OfficeBlock.Heading",
        level,
        spans,
        rtl,
        alignment,
        tab_stops,
        format
    );
    let OfficeBlock::Paragraph {
        spans,
        rtl,
        alignment,
        tab_stops,
        format, .. } = paragraph
    else {
        return Err(AccountingError::WrongBlockVariant("Paragraph"));
    };
    record!(
        ledger,
        "OfficeBlock.Paragraph",
        spans,
        rtl,
        alignment,
        tab_stops,
        format
    );
    let OfficeBlock::ListItem {
        level,
        ordered,
        spans,
        marker,
        rtl,
        alignment,
        tab_stops,
        format,
        numbering, .. } = list_item
    else {
        return Err(AccountingError::WrongBlockVariant("ListItem"));
    };
    record!(
        ledger,
        "OfficeBlock.ListItem",
        level,
        ordered,
        spans,
        marker,
        rtl,
        alignment,
        tab_stops,
        format,
        numbering
    );

    ledger.finish()
}

pub(crate) fn column_flow_from_office(
    layout: &OfficeColumnLayout,
) -> Result<wire::ColumnFlowDeclaration, AccountingError> {
    let OfficeColumnLayout {
        flow_type,
        count,
        spacing,
        widths,
        gaps,
        proportional,
        same_width,
        direction,
        separator_type,
        separator_width_code,
        separator_width_pt,
        separator_color,
        separator_color_ref,
        source_raw_attributes,
    } = layout;
    let count = u32::try_from(*count)
        .ok()
        .filter(|count| *count > 0)
        .ok_or(AccountingError::InvalidOfficeColumnCount(*count))?;
    let flow_type = match flow_type
        .as_ref()
        .ok_or(AccountingError::IncompleteOfficeColumnAuthority)?
    {
        OfficeColumnFlowType::Normal => wire::ColumnFlowType::Normal,
        OfficeColumnFlowType::Distribute => wire::ColumnFlowType::Distribute,
        OfficeColumnFlowType::Parallel => wire::ColumnFlowType::Parallel,
    };
    let direction = match direction {
        OfficeColumnDirection::LeftToRight => wire::ColumnFlowDirection::LeftToRight,
        OfficeColumnDirection::RightToLeft => wire::ColumnFlowDirection::RightToLeft,
    };
    let style = match *separator_type {
        0 => wire::ColumnSeparatorStyle::None,
        1 => wire::ColumnSeparatorStyle::Solid,
        2 => wire::ColumnSeparatorStyle::Dash,
        3 => wire::ColumnSeparatorStyle::Dot,
        4 => wire::ColumnSeparatorStyle::DashDot,
        5 => wire::ColumnSeparatorStyle::DashDotDot,
        6 => wire::ColumnSeparatorStyle::LongDash,
        7 => wire::ColumnSeparatorStyle::Circle,
        other => return Err(AccountingError::InvalidOfficeColumnSeparatorType(other)),
    };
    let raw = separator_color_ref.ok_or(AccountingError::IncompleteOfficeColumnAuthority)?;
    let source_raw_attributes =
        source_raw_attributes.ok_or(AccountingError::IncompleteOfficeColumnAuthority)?;
    let expected_width =
        crate::render::office::column_geometry::column_width_code_points(*separator_width_code)
            .ok_or(AccountingError::InvalidOfficeColumnSeparatorWidth)?;
    if (*separator_width_pt - expected_width).abs() > 1e-9 {
        return Err(AccountingError::InvalidOfficeColumnSeparatorWidth);
    }
    let expected_color = [
        f64::from(raw & 0xff) / 255.0,
        f64::from((raw >> 8) & 0xff) / 255.0,
        f64::from((raw >> 16) & 0xff) / 255.0,
    ];
    let color_matches = separator_color.as_ref().is_some_and(|color| {
        [
            color.redComponent(),
            color.greenComponent(),
            color.blueComponent(),
        ]
        .into_iter()
        .zip(expected_color)
        .all(|(actual, expected)| (actual - expected).abs() <= 1e-12)
            && (color.alphaComponent() - 1.0).abs() <= 1e-12
    });
    if (*separator_type == 0 && separator_color.is_some())
        || (*separator_type != 0 && !color_matches)
    {
        return Err(AccountingError::InvalidOfficeColumnSeparatorColor);
    }
    Ok(wire::ColumnFlowDeclaration {
        count,
        spacing_points: *spacing,
        widths: widths.clone(),
        gaps: gaps.clone(),
        flow_type,
        direction,
        // The last arm used to claim `Absolute` — that the document declared per-column widths —
        // when all it actually knew was that neither flag was set (invariant 108). A real
        // document that says `colCount="2" sameSz="0"` and writes no `<hp:colLine>` at all lands
        // here, and the validator then demanded a widths array nobody wrote, costing the whole
        // document. `Unspecified` says what is true: columns were declared, their widths were not.
        width_mode: if *same_width {
            wire::ColumnWidthMode::Equal
        } else if *proportional {
            wire::ColumnWidthMode::Proportional
        } else if widths.is_empty() && gaps.is_empty() {
            wire::ColumnWidthMode::Unspecified
        } else {
            wire::ColumnWidthMode::Absolute
        },
        source_same_width: *same_width,
        source_proportional_widths: *proportional,
        source_raw_attributes,
        separator: wire::ColumnSeparator {
            style,
            source_width_code: *separator_width_code,
            width_points: *separator_width_pt,
            source_color_ref: raw,
            color: wire::Color {
                red: f64::from(raw & 0xff) / 255.0,
                green: f64::from((raw >> 8) & 0xff) / 255.0,
                blue: f64::from((raw >> 16) & 0xff) / 255.0,
                alpha: 1.0,
                space: wire::ColorSpace::Srgb,
            },
        },
    })
}

pub(crate) fn account_table_cell_source_layers(
    cell: &Cell,
    cell_diagonal: &CellDiagonal,
    border_side: &BorderSide,
    edge_borders: &EdgeBorders,
    edge_padding: &EdgePadding,
    table_format: &TableFormat,
    table_block: &OfficeBlock,
) -> Result<FieldDecisionLedger, AccountingError> {
    let mut ledger = FieldDecisionLedger::new();
    let Cell {
        blocks,
        row_span,
        col_span,
        background_color,
        background_image,
        background_gradient,
        border_color,
        border_width,
        edge_borders: cell_edge_borders,
        edge_borders_ref: cell_edge_borders_ref,
        width,
        vertical_alignment,
        padding,
        edge_padding: cell_edge_padding,
        declared_height,
        diagonal,
        style_shading,
        style_border_color,
        style_border_width,
    } = cell;
    ledger.record(deferred("Cell.blocks"))?;
    // S6-4: a real picture becomes a resource reference (`office_adapter::background_resource`,
    // S6-2's mechanism) and a declared gradient becomes `wire::Gradient` — the mutual exclusion
    // that used to make one field ambiguous is now two fields, each honestly mapped.
    ledger.record(mapped("Cell.background_image"))?;
    ledger.record(mapped("Cell.background_gradient"))?;
    ledger.record(mapped("Cell.edge_borders"))?;
    // A WIRE field, like `OfficeReadResult.picture_pool`: `edge_border_pool` fills it on the way
    // out and drains it on the way in, so a reader's own cell never carries one and there is no
    // source layer for it to be mapped from.
    debug_assert!(
        cell_edge_borders_ref.is_none(),
        "Cell.edge_borders_ref is a wire field, not a reader's output"
    );
    let _ = cell_edge_borders_ref;
    ledger.record(derived("Cell.edge_borders_ref"))?;
    ledger.record(mapped("Cell.edge_padding"))?;
    ledger.record(mapped("Cell.declared_height"))?;
    record!(
        ledger,
        "Cell",
        row_span,
        col_span,
        background_color,
        border_color,
        border_width,
        width,
        vertical_alignment,
        padding,
        diagonal,
        style_shading,
        style_border_color,
        style_border_width
    );
    let CellDiagonal { direction, side } = cell_diagonal;
    record!(ledger, "CellDiagonal", direction, side);
    let BorderSide {
        width,
        color,
        style,
    } = border_side;
    record!(ledger, "BorderSide", width, color, style);
    let EdgeBorders {
        top,
        left,
        bottom,
        right,
        inside_h,
        inside_v,
    } = edge_borders;
    record!(
        ledger,
        "EdgeBorders",
        top,
        left,
        bottom,
        right,
        inside_h,
        inside_v
    );
    let EdgePadding {
        top,
        left,
        bottom,
        right,
    } = edge_padding;
    record!(ledger, "EdgePadding", top, left, bottom, right);
    let TableFormat {
        default_border_color,
        default_border_width,
        default_shading,
        background_image: table_background_image,
        background_gradient: table_background_gradient,
        source_width,
        edge_borders: table_edge_borders,
        edge_borders_ref: table_edge_borders_ref,
        default_padding,
        repeat_header_rows,
        page_break_policy,
        outer_margin,
    } = table_format;
    ledger.record(mapped("TableFormat.background_image"))?;
    ledger.record(mapped("TableFormat.background_gradient"))?;
    ledger.record(mapped("TableFormat.edge_borders"))?;
    debug_assert!(
        table_edge_borders_ref.is_none(),
        "TableFormat.edge_borders_ref is a wire field, not a reader's output"
    );
    let _ = table_edge_borders_ref;
    ledger.record(derived("TableFormat.edge_borders_ref"))?;
    record!(
        ledger,
        "TableFormat",
        default_border_color,
        default_border_width,
        default_shading,
        source_width,
        default_padding,
        repeat_header_rows,
        page_break_policy,
        outer_margin
    );
    let OfficeBlock::Table {
        rows,
        header_rows,
        column_widths,
        format,
    } = table_block
    else {
        return Err(AccountingError::WrongBlockVariant("Table"));
    };
    ledger.record(deferred("OfficeBlock.Table.rows"))?;
    record!(
        ledger,
        "OfficeBlock.Table",
        header_rows,
        column_widths,
        format
    );
    let _ = (
        blocks,
        background_image,
        background_gradient,
        cell_edge_borders,
        cell_edge_padding,
        table_background_image,
        table_background_gradient,
        table_edge_borders,
        rows,
    );
    ledger.finish_expected(TABLE_EXPECTED_KEYS, TABLE_EXPECTED_DECISIONS)
}

pub(crate) fn checked_row_span(value: i64) -> Result<u32, AccountingError> {
    u32::try_from(value)
        .ok()
        .filter(|value| *value > 0)
        .ok_or(AccountingError::InvalidRowSpan(value))
}

pub(crate) fn checked_column_span(value: i64) -> Result<u32, AccountingError> {
    u32::try_from(value)
        .ok()
        .filter(|value| *value > 0)
        .ok_or(AccountingError::InvalidColumnSpan(value))
}

pub(crate) fn checked_header_rows(value: i64, row_count: usize) -> Result<u32, AccountingError> {
    let header_rows =
        u32::try_from(value).map_err(|_| AccountingError::InvalidHeaderRows(value))?;
    if usize::try_from(header_rows)
        .ok()
        .is_none_or(|count| count > row_count)
    {
        return Err(AccountingError::HeaderRowsExceedRowCount {
            header_rows,
            row_count,
        });
    }
    Ok(header_rows)
}

pub(crate) fn refuse_table_background_images(
    rows: &[Vec<Cell>],
    format: &TableFormat,
    path: &str,
) -> Result<(), AccountingError> {
    if format.background_image.is_some() {
        return Err(AccountingError::TableBackgroundImageRequiresResourceBytes {
            path: format!("{path}/format/backgroundImage"),
        });
    }
    for (row_index, row) in rows.iter().enumerate() {
        for (cell_index, cell) in row.iter().enumerate() {
            refuse_cell_background_images(
                cell,
                &format!("{path}/rows/{row_index}/cells/{cell_index}"),
            )?;
        }
    }
    Ok(())
}

fn refuse_cell_background_images(cell: &Cell, path: &str) -> Result<(), AccountingError> {
    if cell.background_image.is_some() {
        return Err(AccountingError::CellBackgroundImageRequiresResourceBytes {
            path: format!("{path}/backgroundImage"),
        });
    }
    for (block_index, block) in cell.blocks.iter().enumerate() {
        refuse_block_background_images(block, &format!("{path}/blocks/{block_index}"))?;
    }
    Ok(())
}

fn refuse_block_background_images(block: &OfficeBlock, path: &str) -> Result<(), AccountingError> {
    if let OfficeBlock::Table { rows, format, .. } = block {
        refuse_table_background_images(rows, format, path)?;
    }
    Ok(())
}

#[cfg(test)]
#[allow(clippy::field_reassign_with_default)]
mod tests {
    use super::*;
    use crate::render::office::column_geometry::OfficeColumnLayout;
    use crate::render::office::office_block::{
        LineBreakGranularity, LineHeight, ListNumberingGlyphs, OfficeFormControl,
        OfficeFormControlKind, PageNumberField, RectEdge, TabAlignment, TabLeader, UnderlineStyle,
    };
    use swiftshim::{CGSize, NSColor, NSFontDescriptor, NSImage, NSTextAlignment, SwiftString};

    /// A column layout as a real document states one, with only the two flags and the arrays
    /// varying — everything else is the same in all three cases so the mode is the only thing
    /// under test.
    fn column_layout(
        same_width: bool,
        proportional: bool,
        widths: Vec<f64>,
        gaps: Vec<f64>,
    ) -> OfficeColumnLayout {
        OfficeColumnLayout {
            // Required by the ledger, not incidental: a layout with no flow type is a shape no
            // reader produces, and `column_flow_from_office` refuses it rather than guess.
            flow_type: Some(crate::render::office::column_geometry::OfficeColumnFlowType::Normal),
            count: 2,
            spacing: 0.0,
            widths,
            gaps,
            proportional,
            same_width,
            direction: crate::render::office::column_geometry::OfficeColumnDirection::LeftToRight,
            separator_type: 0,
            separator_width_code: 0,
            // Derived from the code rather than typed in: the ledger cross-checks the two, so a
            // literal here would be testing whether someone copied a constant correctly.
            separator_width_pt: crate::render::office::column_geometry::column_width_code_points(0)
                .expect("code 0 is a real width"),
            separator_color: None,
            // Also required by the ledger — the separator's own source colour word.
            separator_color_ref: Some(0),
            // The ledger refuses a layout that carries no raw attribute word — a real document
            // always states one, and accepting `None` here would test a shape no reader produces.
            source_raw_attributes: Some(0),
        }
    }

    /// The width mode must be a statement about what the DOCUMENT said, and the last arm of the
    /// flag chain used to claim `Absolute` — that per-column widths were declared — when all it
    /// knew was that neither flag was set (invariant 108). A real document
    /// (`issue2019_floating_form_74312.hwpx`) states `colCount="2" sameSz="0"` and writes no
    /// `<hp:colLine>` at all, so it landed on `Absolute` and `validate` then demanded a widths
    /// array nobody wrote, costing the whole document.
    ///
    /// `Equal` would be wrong for it too, even though the host does lay such a document out as an
    /// equal split: the source explicitly said `sameSz="0"`, NOT same size, and `Equal` asserts
    /// the opposite of what the document stated. The document is internally inconsistent — it
    /// declined to say the widths after saying they differ — and `Unspecified` is the only name
    /// that reports that honestly while leaving `source_same_width` carrying the source's own word.
    #[test]
    fn a_declaration_that_named_no_per_column_widths_says_so_rather_than_claiming_absolute() {
        let unspecified = column_flow_from_office(&column_layout(false, false, vec![], vec![]))
            .expect("maps");
        assert_eq!(unspecified.width_mode, wire::ColumnWidthMode::Unspecified);
        assert!(!unspecified.source_same_width, "the source's own flag is carried unchanged");

        let absolute =
            column_flow_from_office(&column_layout(false, false, vec![100.0, 100.0], vec![0.0, 0.0]))
                .expect("maps");
        assert_eq!(
            absolute.width_mode,
            wire::ColumnWidthMode::Absolute,
            "widths that ARE declared still read as absolute"
        );

        let equal = column_flow_from_office(&column_layout(true, false, vec![], vec![])).expect("maps");
        assert_eq!(equal.width_mode, wire::ColumnWidthMode::Equal);

        let proportional =
            column_flow_from_office(&column_layout(false, true, vec![1.0, 1.0], vec![0.0, 0.0]))
                .expect("maps");
        assert_eq!(proportional.width_mode, wire::ColumnWidthMode::Proportional);
    }

    fn fixture(
        span: Span,
    ) -> (
        Span,
        ParagraphFormat,
        TabStop,
        ListNumbering,
        OfficeBlock,
        OfficeBlock,
        OfficeBlock,
    ) {
        let color = NSColor::srgb(0.1, 0.2, 0.3, 1.0);
        let format = ParagraphFormat {
            list_text_distance: Some(8.0),
            spacing_before: Some(2.0),
            spacing_after: Some(3.0),
            line_height: Some(LineHeight::Exact(18.0)),
            indent_start: Some(4.0),
            indent_end: Some(5.0),
            first_line_indent: Some(6.0),
            hanging_indent: Some(7.0),
            contextual_spacing: true,
            shading: Some(color),
            border_color: Some(color),
            border_width: Some(1.0),
            border_edges: RectEdge::ALL,
            east_asian_line_break: Some(LineBreakGranularity::Character),
            latin_line_break: Some(LineBreakGranularity::Hyphen),
            auto_space_east_asian_latin: Some(true),
            auto_space_east_asian_number: Some(false),
            line_height_from_font_metrics: Some(true),
            line_spacing_below: Some(true),
        };
        let tab = TabStop::new(36.0, TabAlignment::Decimal, TabLeader::Dot);
        let numbering = ListNumbering {
            glyphs: ListNumberingGlyphs::RomanLower,
            start_number: Some(0),
        };
        let heading = OfficeBlock::Heading {
            level: 9,
            spans: vec![span.clone()],
            rtl: true,
            alignment: Some(NSTextAlignment::Right),
            tab_stops: vec![tab],
            format, format_ref: None,
        };
        let paragraph = OfficeBlock::Paragraph {
            spans: vec![span.clone()],
            rtl: true,
            alignment: Some(NSTextAlignment::Justified),
            tab_stops: vec![tab],
            format, format_ref: None,
        };
        let list = OfficeBlock::ListItem {
            level: 2,
            ordered: true,
            spans: vec![span.clone()],
            marker: Some(SwiftString::from("")),
            rtl: false,
            alignment: Some(NSTextAlignment::Left),
            tab_stops: vec![tab],
            format, format_ref: None,
            numbering: Some(numbering),
        };
        (span, format, tab, numbering, heading, paragraph, list)
    }

    fn account(span: Span) -> Result<FieldDecisionLedger, AccountingError> {
        let (span, format, tab, numbering, heading, paragraph, list) = fixture(span);
        account_current_office_slice(
            &span, &format, &tab, &numbering, &heading, &paragraph, &list,
        )
    }

    #[test]
    fn real_source_destructuring_accounts_exactly_seventy_three_decisions() {
        let mut span = Span::default();
        span.text = SwiftString::from("accounted");
        span.bold = true;
        span.italic = true;
        span.underline = true;
        span.strikethrough = true;
        span.superscript = true;
        span.underline_style = UnderlineStyle::Double;
        span.code = true;
        span.caps = true;
        span.small_caps = true;
        span.rtl = true;
        span.bookmarks = vec![SwiftString::from("mark")];
        span.comment_ids = vec![SwiftString::from("comment")];
        span.link = Some(SwiftString::from(""));
        span.font_name = Some(SwiftString::from(""));
        span.footnote_ref = Some(0);
        span.letter_spacing_percent = Some(-5.0);
        span.baseline_offset_percent = Some(-10.0);
        span.page_number_field = Some(PageNumberField::Page);
        let color = NSColor::srgb(0.1, 0.2, 0.3, 1.0);
        span.text_color = Some(color);
        span.highlight_color = Some(color);
        span.underline_color = Some(color);
        span.strikethrough_color = Some(color);
        span.font_size = Some(12.0);
        span.form_control = Some(OfficeFormControl {
            kind: OfficeFormControlKind::CheckBox,
            caption: SwiftString::from(""),
            text: SwiftString::from(""),
            value: 1,
            enabled: true,
        });
        let ledger = account(span).unwrap();
        assert_eq!(ledger.decision_count(), 73);
        assert_eq!(ledger.deferred_count(), 1);
    }

    #[test]
    fn source_conflicts_and_deferred_host_values_are_typed_failures() {
        let mut conflict = Span::default();
        conflict.superscript = true;
        conflict.subscripted = true;
        assert_eq!(
            account(conflict).unwrap_err(),
            AccountingError::ConflictingVerticalPosition
        );
        let mut font = Span::default();
        font.resolved_font_descriptor = Some(NSFontDescriptor::default());
        assert_eq!(
            account(font).unwrap_err(),
            AccountingError::HostResolvedFontAtSemanticBoundary
        );
        let mut columns = Span::default();
        columns.column_layout = Some(OfficeColumnLayout::default());
        assert_eq!(
            account(columns).unwrap_err(),
            AccountingError::IncompleteOfficeColumnAuthority
        );
        let mut invalid = ParagraphFormat::default();
        invalid.border_edges = RectEdge { raw_value: 0x20 };
        let span = Span::default();
        let (_, _, tab, numbering, heading, paragraph, list) = fixture(span.clone());
        assert_eq!(
            account_current_office_slice(
                &span, &invalid, &tab, &numbering, &heading, &paragraph, &list,
            )
            .unwrap_err(),
            AccountingError::UnknownParagraphBorderBits(0x20)
        );
    }

    #[test]
    fn reconciled_office_column_fields_map_once_and_check_derived_values() {
        let mut layout = OfficeColumnLayout {
            flow_type: Some(OfficeColumnFlowType::Distribute),
            count: 2,
            spacing: 12.0,
            widths: vec![100.0, 200.0],
            gaps: vec![10.0, 20.0],
            proportional: true,
            same_width: false,
            direction: OfficeColumnDirection::RightToLeft,
            separator_type: 2,
            separator_width_code: 7,
            separator_width_pt: crate::render::office::column_geometry::column_width_code_points(7)
                .unwrap(),
            separator_color: Some(NSColor::srgb(
                0x11 as f64 / 255.0,
                0x22 as f64 / 255.0,
                0x33 as f64 / 255.0,
                1.0,
            )),
            separator_color_ref: Some(0x0033_2211),
            source_raw_attributes: Some(0),
        };
        let flow = column_flow_from_office(&layout).unwrap();
        assert_eq!(
            (flow.count, flow.widths, flow.gaps),
            (2, vec![100.0, 200.0], vec![10.0, 20.0])
        );
        assert_eq!(flow.flow_type, wire::ColumnFlowType::Distribute);
        assert_eq!(flow.direction, wire::ColumnFlowDirection::RightToLeft);
        assert_eq!(flow.width_mode, wire::ColumnWidthMode::Proportional);
        assert_eq!(flow.separator.source_color_ref, 0x0033_2211);

        layout.separator_width_pt = 0.0;
        assert!(matches!(
            column_flow_from_office(&layout),
            Err(AccountingError::InvalidOfficeColumnSeparatorWidth)
        ));
        layout.separator_width_pt =
            crate::render::office::column_geometry::column_width_code_points(7).unwrap();
        layout.separator_color = Some(NSColor::black());
        assert!(matches!(
            column_flow_from_office(&layout),
            Err(AccountingError::InvalidOfficeColumnSeparatorColor)
        ));
    }

    #[test]
    fn ledger_rejects_duplicate_and_missing_decisions() {
        let mut duplicate = FieldDecisionLedger::new();
        duplicate.record(mapped("x")).unwrap();
        assert!(matches!(
            duplicate.record(mapped("x")),
            Err(AccountingError::DuplicateDecision(_))
        ));
        let mut missing = FieldDecisionLedger::new();
        missing.record(mapped("one")).unwrap();
        assert!(matches!(
            missing.finish(),
            Err(AccountingError::DecisionSetMismatch { .. })
        ));

        let mut substituted = FieldDecisionLedger::new();
        for key in EXPECTED_KEYS.iter().skip(1) {
            substituted.record(mapped(key)).unwrap();
        }
        substituted.record(mapped("bogus.same_count.key")).unwrap();
        assert_eq!(substituted.decisions.len(), 73);
        let AccountingError::DecisionSetMismatch {
            missing,
            unexpected,
        } = substituted.finish().unwrap_err()
        else {
            panic!("same-count key substitution was accepted or misclassified");
        };
        assert_eq!(missing, vec!["Span.text"]);
        assert_eq!(unexpected, vec!["bogus.same_count.key"]);
    }

    #[test]
    fn table_expected_keys_are_exactly_forty_seven() {
        assert_eq!(TABLE_EXPECTED_KEYS.len(), TABLE_EXPECTED_DECISIONS);
    }

    fn table_source_fixture() -> (
        Cell,
        CellDiagonal,
        BorderSide,
        EdgeBorders,
        EdgePadding,
        TableFormat,
        OfficeBlock,
    ) {
        use crate::render::office::office_block::{
            BorderDecl, BorderLineStyle, CellDiagonalDirection, CellVAlign, TablePageBreakPolicy,
        };
        let color = NSColor::srgb(0.1, 0.2, 0.3, 1.0);
        let side = BorderSide {
            width: 1.0,
            color: Some(color),
            style: BorderLineStyle::Dashed,
        };
        let edges = EdgeBorders {
            top: Some(BorderDecl::Drawn(side)),
            left: Some(BorderDecl::Suppressed),
            bottom: Some(BorderDecl::Drawn(side)),
            right: Some(BorderDecl::Suppressed),
            inside_h: Some(BorderDecl::Drawn(side)),
            inside_v: Some(BorderDecl::Drawn(side)),
        };
        let padding = EdgePadding {
            top: Some(0.0),
            left: Some(2.0),
            bottom: Some(3.0),
            right: Some(4.0),
        };
        let diagonal = CellDiagonal {
            direction: CellDiagonalDirection::Both,
            side,
        };
        let cell = Cell {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(), format_ref: None,
            }],
            row_span: 2,
            col_span: 3,
            background_color: Some(color),
            background_image: None,
            background_gradient: None,
            border_color: Some(color),
            border_width: Some(1.0),
            edge_borders: Some(edges),
            edge_borders_ref: None,
            width: Some(100.0),
            vertical_alignment: Some(CellVAlign::Center),
            padding: Some(5.0),
            edge_padding: Some(padding),
            declared_height: Some(24.0),
            diagonal: Some(diagonal),
            style_shading: Some(color),
            style_border_color: Some(color),
            style_border_width: Some(0.5),
        };
        let format = TableFormat {
            default_border_color: Some(color),
            default_border_width: Some(1.0),
            default_shading: Some(color),
            background_image: None,
            background_gradient: None,
            source_width: Some(200.0),
            edge_borders: Some(edges),
            edge_borders_ref: None,
            default_padding: Some(padding),
            repeat_header_rows: Some(true),
            page_break_policy: Some(TablePageBreakPolicy::AtRowBoundary),
            outer_margin: Some(padding),
        };
        let table = OfficeBlock::Table {
            rows: vec![vec![cell.clone()]],
            header_rows: 1,
            column_widths: vec![200.0],
            format: format.clone(),
        };
        (cell, diagonal, side, edges, padding, format, table)
    }

    /// S6-4: the two background fields flipped refused -> mapped, and two new
    /// (`Cell`/`TableFormat`).background_gradient` keys joined already mapped — 45 -> 47 total,
    /// 41 -> 45 mapped, 2 deferred unchanged. Nothing is refused any more (`DecisionKind::Refused`
    /// was removed from this file along with its last producer — see that enum's own doc).
    #[test]
    fn s2a1c3_exact_forty_nine_field_ledger_classifies_47_2() {
        let (cell, diagonal, side, edges, padding, format, table) = table_source_fixture();
        let ledger = account_table_cell_source_layers(
            &cell, &diagonal, &side, &edges, &padding, &format, &table,
        )
        .unwrap();
        // P4b added `edge_borders_ref` to both `Cell` and `TableFormat` — wire fields with no
        // source layer, so they are `derived`, counted on their own: 47 -> 49 total, mapped and
        // deferred both unchanged. Invariant 152's `Cell.declared_height` — the row height the
        // document itself states — is a mapped source field: 49 -> 50 total, 45 -> 46 mapped.
        assert_eq!(ledger.decision_count(), 50);
        assert_eq!(ledger.mapped_count(), 46);
        assert_eq!(ledger.derived_count(), 2);
        assert_eq!(ledger.deferred_count(), 2);
    }

    #[test]
    fn s2a1c3_ledger_rejects_same_count_substituted_key() {
        let mut ledger = FieldDecisionLedger::new();
        for key in TABLE_EXPECTED_KEYS.iter().skip(1) {
            ledger.record(mapped(key)).unwrap();
        }
        ledger.record(mapped("bogus.same_count.key")).unwrap();
        let AccountingError::DecisionSetMismatch {
            missing,
            unexpected,
        } = ledger
            .finish_expected(TABLE_EXPECTED_KEYS, TABLE_EXPECTED_DECISIONS)
            .unwrap_err()
        else {
            panic!("same-count table key substitution was accepted")
        };
        assert_eq!(missing, vec!["Cell.blocks"]);
        assert_eq!(unexpected, vec!["bogus.same_count.key"]);
    }

    #[test]
    fn s2a1c3_checked_spans_reject_non_positive_and_overflow() {
        assert_eq!(checked_row_span(1), Ok(1));
        assert_eq!(checked_column_span(1), Ok(1));
        for value in [0, -1, i64::from(u32::MAX) + 1] {
            assert_eq!(
                checked_row_span(value),
                Err(AccountingError::InvalidRowSpan(value))
            );
            assert_eq!(
                checked_column_span(value),
                Err(AccountingError::InvalidColumnSpan(value))
            );
        }
    }

    #[test]
    fn s2a1c3_checked_header_rows_reject_invalid_classes() {
        assert_eq!(checked_header_rows(0, 1), Ok(0));
        assert_eq!(checked_header_rows(1, 1), Ok(1));
        for value in [-1, i64::from(u32::MAX) + 1] {
            assert_eq!(
                checked_header_rows(value, usize::MAX),
                Err(AccountingError::InvalidHeaderRows(value))
            );
        }
        assert_eq!(
            checked_header_rows(2, 1),
            Err(AccountingError::HeaderRowsExceedRowCount {
                header_rows: 2,
                row_count: 1
            }),
        );
    }

    #[test]
    fn s2a1c3_recursive_refusal_finds_both_nested_background_image_kinds() {
        let image = NSImage::withSize(CGSize {
            width: 1.0,
            height: 1.0,
        });
        let (mut cell, _, _, _, _, mut format, _) = table_source_fixture();
        cell.background_image = Some(image.clone());
        let error = refuse_table_background_images(&[vec![cell]], &TableFormat::default(), "root")
            .unwrap_err();
        assert_eq!(
            error,
            AccountingError::CellBackgroundImageRequiresResourceBytes {
                path: "root/rows/0/cells/0/backgroundImage".into(),
            }
        );

        format.background_image = Some(image);
        let nested = Cell {
            blocks: vec![OfficeBlock::Table {
                rows: vec![],
                header_rows: 0,
                column_widths: vec![],
                format,
            }],
            ..Cell::default()
        };
        let error =
            refuse_table_background_images(&[vec![nested]], &TableFormat::default(), "root")
                .unwrap_err();
        assert_eq!(
            error,
            AccountingError::TableBackgroundImageRequiresResourceBytes {
                path: "root/rows/0/cells/0/blocks/0/format/backgroundImage".into(),
            }
        );
    }
}
