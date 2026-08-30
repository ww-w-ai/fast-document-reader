//! The markdown wire, projected from a real render.
//!
//! The census (`markdown_attribute_census`) says what the renderer produces; this says the wire
//! carries it, that the pools actually collapse, and — the one that is correctness rather than
//! size — that every cell of one table still points at ONE table.

use fastdoc_engine::render::markdown_renderer::MarkdownRenderer;
use fastdoc_engine::render::markdown_wire::{self, MarkdownWire};
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::color_font::{NSFontDescriptor, NSFontDescriptorSymbolicTraits, NSFontWeight};
use swiftshim::font_provider::{self, FaceId, FaceInfo, FontProvider};

struct SingleFaceWorld;

impl FontProvider for SingleFaceWorld {
    fn face_named(&self, _name: &str) -> Option<FaceId> { Some(FaceId(1)) }
    fn resolve(&self, _descriptor: &NSFontDescriptor) -> Option<FaceId> { Some(FaceId(1)) }
    fn system_face(&self, _weight: NSFontWeight, _monospaced: bool) -> FaceId { FaceId(1) }
    fn describe(&self, _face: FaceId) -> FaceInfo {
        FaceInfo {
            name: "TestFace-Regular".to_string(),
            family: Some("TestFace".to_string()),
            traits: NSFontDescriptorSymbolicTraits::default(),
        }
    }
    fn covers(&self, _face: FaceId, _scalar: u32) -> bool { true }
    fn substitute(&self, _declared: FaceId, _scalar: u32) -> Option<FaceId> { None }
}

fn wire_for(markdown: &str) -> MarkdownWire {
    let _ = font_provider::install(Box::new(SingleFaceWorld));
    let theme = RenderTheme::current(16.0);
    markdown_wire::project(&MarkdownRenderer::render(markdown, &theme), &theme)
}

#[test]
fn the_wire_carries_the_text_and_one_column_entry_per_layer() {
    let wire = wire_for("# Heading\n\nSome *emphasis* and `code`.\n");
    assert!(!wire.text.is_empty());
    let runs = wire.layer_location.len();
    assert!(runs > 0, "a document with text must produce layers");
    assert_eq!(wire.layer_length.len(), runs, "every layer column is the same length");
    for column in [&wire.layer_font, &wire.layer_color, &wire.layer_paragraph, &wire.layer_attachment] {
        assert_eq!(column.len(), runs, "every layer column is the same length");
    }
    // Layers are a call log, so they overlap and run backwards — what must hold is that none of
    // them points outside the string, which is what would make the host throw on a range.
    let units = wire.text.encode_utf16().count() as u32;
    for (location, length) in wire.layer_location.iter().zip(&wire.layer_length) {
        assert!(
            location.saturating_add(*length) <= units,
            "layer {location}+{length} reaches past the {units}-unit string"
        );
    }
}

#[test]
fn the_pools_actually_collapse() {
    // A document that says the same thing many times must not pay for it many times.
    let body = (0..200)
        .map(|i| format!("Paragraph {i} with *emphasis* and `code`."))
        .collect::<Vec<_>>()
        .join("\n\n");
    let wire = wire_for(&body);
    assert!(wire.layer_location.len() > 400, "the fixture must produce many layers");
    assert!(
        wire.fonts.len() < 10,
        "200 identical paragraphs should share a handful of fonts, got {}",
        wire.fonts.len()
    );
    assert!(
        wire.colors.len() < 10,
        "and a handful of colours, got {}",
        wire.colors.len()
    );
}

/// The one that is correctness. AppKit lays a table out by the IDENTITY of its `NSTextTable`, so
/// every cell of one grid has to arrive pointing at the same pool entry. By value they would each
/// become their own one-cell table and the grid would come apart — a failure invisible in the
/// bytes, which is why it is asserted here rather than left to look right.
#[test]
fn every_cell_of_one_table_points_at_one_table() {
    let wire = wire_for("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n");
    let blocks: Vec<u32> = wire
        .paragraph_styles
        .iter()
        .flat_map(|style| style.text_blocks.iter().map(|b| b.table))
        .collect();
    assert!(!blocks.is_empty(), "a markdown table must produce text blocks");
    assert_eq!(wire.tables.len(), 1, "one table in the document, one entry in the pool");
    assert!(blocks.iter().all(|&t| t == 0), "every block points at that entry: {blocks:?}");
}

#[test]
fn the_wire_round_trips_through_json() {
    let wire = wire_for("# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nSome [link](https://example.com).\n");
    let json = serde_json::to_string(&wire).expect("serialises");
    let back: MarkdownWire = serde_json::from_str(&json).expect("deserialises");
    assert_eq!(back, wire, "the wire must survive its own encoding");
    assert_eq!(back.v, markdown_wire::MARKDOWN_WIRE_VERSION);
}

/// Not a threshold, a report: what one real document costs on this wire, so the host-side decode
/// measurement has a size to be judged against.
#[test]
fn what_one_real_document_weighs() {
    let Ok(path) = std::env::var("FMD_MD_WIRE_SIZE") else {
        eprintln!("skipped: set FMD_MD_WIRE_SIZE to a markdown file");
        return;
    };
    let text = std::fs::read_to_string(&path).expect("readable");
    let wire = wire_for(&text);
    let json = serde_json::to_string(&wire).expect("serialises");
    println!(
        "MD-WIRE {} — {} source chars, {} runs, {} bytes (text {}, fonts {}, colours {}, styles {}, tables {}, extras {})",
        path,
        text.chars().count(),
        wire.layer_location.len(),
        json.len(),
        wire.text.len(),
        wire.fonts.len(),
        wire.colors.len(),
        wire.paragraph_styles.len(),
        wire.tables.len(),
        wire.extras.len()
    );
    assert!(!wire.layer_location.is_empty(), "an empty projection would report nothing");
}
