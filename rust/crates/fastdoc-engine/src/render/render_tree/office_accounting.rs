//! Mechanical S2A1b decisions for the current Office run/paragraph/list source vocabulary.
#![cfg_attr(not(test), allow(dead_code))]

use crate::render::office::office_block::{
    ListNumbering, OfficeBlock, ParagraphFormat, Span, TabStop,
};
use std::collections::BTreeMap;

const EXPECTED_DECISIONS: usize = 71;
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
    ColumnLayoutRequiresFlowSchema,
    UnknownParagraphBorderBits(i64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DecisionKind {
    Mapped,
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
        let expected: std::collections::BTreeSet<_> = EXPECTED_KEYS.iter().copied().collect();
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
        debug_assert_eq!(self.decisions.len(), EXPECTED_DECISIONS);
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
}

fn mapped(key: &'static str) -> DecisionToken {
    DecisionToken {
        key,
        kind: DecisionKind::Mapped,
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
    if column_layout.is_some() {
        return Err(AccountingError::ColumnLayoutRequiresFlowSchema);
    }
    ledger.record(deferred("Span.column_layout"))?;

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
        line_height_from_font_metrics
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
        format,
    } = heading
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
        format,
    } = paragraph
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
        numbering,
    } = list_item
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

#[cfg(test)]
#[allow(clippy::field_reassign_with_default)]
mod tests {
    use super::*;
    use crate::render::office::column_geometry::OfficeColumnLayout;
    use crate::render::office::office_block::{
        LineBreakGranularity, LineHeight, ListNumberingGlyphs, OfficeFormControl,
        OfficeFormControlKind, PageNumberField, RectEdge, TabAlignment, TabLeader, UnderlineStyle,
    };
    use swiftshim::{NSColor, NSFontDescriptor, NSTextAlignment, SwiftString};

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
            format,
        };
        let paragraph = OfficeBlock::Paragraph {
            spans: vec![span.clone()],
            rtl: true,
            alignment: Some(NSTextAlignment::Justified),
            tab_stops: vec![tab],
            format,
        };
        let list = OfficeBlock::ListItem {
            level: 2,
            ordered: true,
            spans: vec![span.clone()],
            marker: Some(SwiftString::from("")),
            rtl: false,
            alignment: Some(NSTextAlignment::Left),
            tab_stops: vec![tab],
            format,
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
    fn real_source_destructuring_accounts_exactly_seventy_one_decisions() {
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
        assert_eq!(ledger.decision_count(), 71);
        assert_eq!(ledger.deferred_count(), 2);
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
            AccountingError::ColumnLayoutRequiresFlowSchema
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
        assert_eq!(substituted.decisions.len(), 71);
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
}
