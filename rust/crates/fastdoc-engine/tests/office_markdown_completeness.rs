//! All semantic channels must survive the complete-result extraction boundary.
use fastdoc_engine::render::office::{
    office_block::*, office_markdown_serializer::OfficeMarkdownSerializer,
};

fn paragraph(text: &str) -> OfficeBlock {
    OfficeBlock::Paragraph {
        spans: vec![Span {
            text: text.into(),
            ..Default::default()
        }],
        rtl: false,
        alignment: None,
        tab_stops: vec![],
        format: Default::default(),
        format_ref: None,
    }
}

fn table(blocks: Vec<OfficeBlock>, merged: bool) -> OfficeBlock {
    OfficeBlock::Table {
        rows: vec![vec![Cell {
            blocks,
            col_span: if merged { 2 } else { 1 },
            ..Default::default()
        }]],
        header_rows: 0,
        column_widths: vec![],
        format: Default::default(),
    }
}

fn object(text: &str) -> OfficeMasterObject {
    OfficeMasterObject {
        frame: swiftshim::CGRect::zero(),
        content: OfficeMasterObjectContent::Text(vec![paragraph(text)]),
    }
}

#[test]
fn every_semantic_channel_is_preserved_once_in_source_order() {
    let mut result = OfficeReadResult::default();
    result.blocks = vec![
        paragraph("BODY_SENTINEL"),
        table(vec![paragraph("SIMPLE_SENTINEL")], false),
        table(
            vec![
                paragraph("MERGED_SENTINEL"),
                table(vec![paragraph("NESTED_SENTINEL")], false),
                OfficeBlock::Formula {
                    latex: "FORMULA_SENTINEL".into(),
                },
                OfficeBlock::Image {
                    id: "IMAGE_SENTINEL".into(),
                    size: swiftshim::CGSize::zero(),
                    alignment: None,
                },
            ],
            true,
        ),
        paragraph("ENDNOTE_SENTINEL"),
    ];
    result.anchored_objects = vec![
        OfficeAnchoredObject {
            block_index: 0,
            object: object("ANCHOR_SENTINEL"),
            paragraph_anchor: None,
        },
        OfficeAnchoredObject {
            block_index: -1,
            object: object("NEGATIVE_SENTINEL"),
            paragraph_anchor: None,
        },
        OfficeAnchoredObject {
            block_index: 999,
            object: object("TAIL_SENTINEL"),
            paragraph_anchor: None,
        },
    ];
    result.headers.push(OfficeHeaderFooter {
        applies_to: HeaderFooterApplicability::DefaultPages,
        blocks: vec![paragraph("HEADER_SENTINEL")],
        section: None,
    });
    result.footers.push(OfficeHeaderFooter {
        applies_to: HeaderFooterApplicability::DefaultPages,
        blocks: vec![paragraph("FOOTER_SENTINEL")],
        section: None,
    });
    result.master_pages.push(OfficeMasterPage {
        section: 0,
        applies_to: HeaderFooterApplicability::DefaultPages,
        objects: vec![object("MASTER_SENTINEL")],
    });
    result.footnotes.push(OfficeFootnote {
        number: 7,
        blocks: vec![paragraph("FOOTNOTE_SENTINEL")],
        section: None,
    });
    result.comments.push(OfficeComment {
        id: "9".into(),
        number: 1,
        author: Some("Reviewer".into()),
        date_iso: None,
        text: "COMMENT_SENTINEL".into(),
    });
    let output = OfficeMarkdownSerializer::serialize_result(&result);
    for sentinel in [
        "BODY_SENTINEL",
        "SIMPLE_SENTINEL",
        "MERGED_SENTINEL",
        "NESTED_SENTINEL",
        "FORMULA_SENTINEL",
        "IMAGE_SENTINEL",
        "ENDNOTE_SENTINEL",
        "ANCHOR_SENTINEL",
        "NEGATIVE_SENTINEL",
        "TAIL_SENTINEL",
        "HEADER_SENTINEL",
        "FOOTER_SENTINEL",
        "MASTER_SENTINEL",
        "FOOTNOTE_SENTINEL",
        "COMMENT_SENTINEL",
    ] {
        assert_eq!(
            output.matches(sentinel).count(),
            1,
            "missing or duplicate {sentinel}: {output}"
        );
    }
    assert!(output.find("BODY_SENTINEL") < output.find("ANCHOR_SENTINEL"));
    assert!(output.find("ANCHOR_SENTINEL") < output.find("SIMPLE_SENTINEL"));
    assert!(output.find("ENDNOTE_SENTINEL") < output.find("TAIL_SENTINEL"));
    for label in [
        "## Headers",
        "## Footers",
        "## Master pages",
        "**Comment 1 (Reviewer)**",
        "[^7]:",
    ] {
        assert!(output.contains(label), "missing section {label}");
    }
    assert!(output.contains("<raw>"));
}

#[test]
fn large_body_keeps_last_cell_and_trailing_comment() {
    let mut result = OfficeReadResult::default();
    result.blocks = (0..20000)
        .map(|i| paragraph(&format!("Paragraph {i}")))
        .collect();
    result
        .blocks
        .push(table(vec![paragraph("FINAL_CELL_SENTINEL")], true));
    result.comments.push(OfficeComment {
        id: "last".into(),
        number: 1,
        author: None,
        date_iso: None,
        text: "LAST_COMMENT_SENTINEL".into(),
    });
    let output = OfficeMarkdownSerializer::serialize_result(&result);
    assert!(output.contains("Paragraph 19999"));
    assert!(output.contains("FINAL_CELL_SENTINEL"));
    assert!(output.ends_with("LAST_COMMENT_SENTINEL"));
}
