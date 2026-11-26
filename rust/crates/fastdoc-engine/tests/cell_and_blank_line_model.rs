//! The builder's two HWP-only line rules (invariant 207), mirrored from `OfficeTextBuilder.swift`:
//! a one-paragraph cell's last line hands its spacing back only when the paragraph puts its spacing
//! below the glyphs (HWP, 161b) — a docx line grid stays the whole line — and a blank HWP body
//! paragraph's terminator carries the char shape's own size.

use std::collections::{HashMap, HashSet};

use fastdoc_engine::render::office::office_block::{Cell, LineHeight, OfficeBlock, ParagraphFormat, Span, TableFormat};
use fastdoc_engine::render::office::office_text_builder::OfficeTextBuilder;
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::color_font::{NSFontDescriptor, NSFontDescriptorSymbolicTraits, NSFontWeight};
use swiftshim::font_provider::{self, FaceId, FaceInfo, FontProvider};
use swiftshim::{AttrValue, NSAttributedString, NSAttributedStringKey};

struct OneFace;

impl FontProvider for OneFace {
    fn face_named(&self, _name: &str) -> Option<FaceId> { Some(FaceId(1)) }
    fn resolve(&self, _descriptor: &NSFontDescriptor) -> Option<FaceId> { Some(FaceId(1)) }
    fn system_face(&self, _weight: NSFontWeight, _monospaced: bool) -> FaceId { FaceId(1) }
    fn describe(&self, _face: FaceId) -> FaceInfo {
        FaceInfo { name: "TestFace-Regular".to_string(), family: Some("TestFace".to_string()), traits: NSFontDescriptorSymbolicTraits::default() }
    }
    fn covers(&self, _face: FaceId, _scalar: u32) -> bool { true }
    fn substitute(&self, _declared: FaceId, _scalar: u32) -> Option<FaceId> { None }
}

fn para(text: &str, size: f64, format: ParagraphFormat) -> OfficeBlock {
    OfficeBlock::Paragraph {
        spans: vec![Span { text: text.into(), font_size: Some(size), ..Span::default() }],
        rtl: false,
        alignment: None,
        tab_stops: vec![],
        format,
        format_ref: None,
    }
}

fn build(blocks: &[OfficeBlock], grid: Option<f64>) -> NSAttributedString {
    let _ = font_provider::install(Box::new(OneFace));
    OfficeTextBuilder::build(
        blocks, &RenderTheme::current(16.0), 400.0, 16.0, Some(400.0), None, Some(400.0), grid, None,
        &[], &HashSet::new(), &[], &[], &[], &[], &[], &HashMap::new(),
    )
}

fn style_at(out: &NSAttributedString, at: usize) -> swiftshim::NSMutableParagraphStyle {
    match out.attribute(&NSAttributedStringKey::ParagraphStyle, at) {
        Some((AttrValue::ParagraphStyle(s), _)) => s.clone(),
        _ => panic!("no paragraph style at {at}"),
    }
}

fn one_cell(cell: OfficeBlock) -> OfficeBlock {
    OfficeBlock::Table {
        rows: vec![vec![Cell { blocks: vec![cell], ..Cell::default() }]],
        header_rows: 0,
        column_widths: vec![],
        format: TableFormat::default(),
    }
}

#[test]
fn a_one_line_cell_on_a_line_grid_keeps_the_whole_pitch() {
    let out = build(&[one_cell(para("격자", 10.0, ParagraphFormat::default()))], Some(18.0));
    let s = style_at(&out, 0);
    assert_eq!(s.minimumLineHeight, 18.0, "the grid floors the cell's line");
    assert_eq!(s.lineSpacing, 0.0);
    assert_eq!(s.paragraphSpacing, 0.0, "and its last line keeps the pitch");
}

#[test]
fn an_unpaged_cell_keeps_the_readers_own_last_line_rule() {
    let _ = font_provider::install(Box::new(OneFace));
    let out = OfficeTextBuilder::build(
        &[one_cell(para("흐름", 10.0, ParagraphFormat::default()))], &RenderTheme::current(16.0), 400.0, 16.0,
        None, None, Some(400.0), None, None, &[], &HashSet::new(), &[], &[], &[], &[], &[], &HashMap::new(),
    );
    assert!(style_at(&out, 0).paragraphSpacing < 0.0, "the one-paragraph cell's last line drops its gap");
}

#[test]
fn a_one_line_hwp_cell_still_hands_its_spacing_back() {
    let f = ParagraphFormat { line_height: Some(LineHeight::AtLeast(16.8)), line_spacing_below: Some(true), ..ParagraphFormat::default() };
    let out = build(&[one_cell(para("한글", 10.5, f))], None);
    let s = style_at(&out, 0);
    assert!((s.lineSpacing - 6.3).abs() < 1e-6);
    assert!((s.paragraphSpacing + 6.3).abs() < 1e-6, "the last line is the character size alone");
}

#[test]
fn a_blank_hwp_body_paragraph_carries_its_declared_size() {
    let hwp = ParagraphFormat { line_height: Some(LineHeight::AtLeast(4.8)), line_spacing_below: Some(true), ..ParagraphFormat::default() };
    let out = build(&[para("", 3.0, hwp), para("끝", 10.0, ParagraphFormat::default())], None);
    match out.attribute(&NSAttributedStringKey::Font, 0) {
        Some((AttrValue::Font(font), _)) => assert_eq!(font.pointSize(), 3.0),
        _ => panic!("the blank paragraph's terminator carries no font"),
    }
    let other = ParagraphFormat { line_height: Some(LineHeight::AtLeast(4.8)), ..ParagraphFormat::default() };
    let out = build(&[para("", 3.0, other)], None);
    assert!(out.attribute(&NSAttributedStringKey::Font, 0).is_none(), "a non-HWP blank is unchanged");
}
