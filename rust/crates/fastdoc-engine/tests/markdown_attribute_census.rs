//! What the ported markdown renderer actually PUTS on a string — measured, so the wire that
//! carries it to the host is sized by the vocabulary in use rather than by the vocabulary the
//! shim can express.
//!
//!     FMD_MD_ATTR_CENSUS=<dir-or-file> cargo test -p fastdoc-engine \
//!       --test markdown_attribute_census --release -- --nocapture
//!
//! Without the variable it censuses the repo's own `demo/` files, so a default run still says
//! something. The report is (key, value kind) pairs with occurrence counts: every pair listed is
//! a case the wire must carry, and a pair NOT listed is one nothing has to be designed for yet.

use std::collections::BTreeMap;
use swiftshim::color_font::{NSFontDescriptor, NSFontDescriptorSymbolicTraits, NSFontWeight};
use swiftshim::font_provider::{self, FaceId, FaceInfo, FontProvider};
use swiftshim::{AttrValue, NSAttributedStringKey};

/// The same blind one-face world `markdown_renderer_port` installs: this census counts WHICH
/// attributes appear, never which typeface was chosen, so a world that answers every name with
/// one face changes nothing it reports.
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

fn kind(v: &AttrValue) -> &'static str {
    match v {
        AttrValue::Font(_) => "Font",
        AttrValue::Color(_) => "Color",
        AttrValue::ParagraphStyle(_) => "ParagraphStyle",
        AttrValue::Range(_) => "Range",
        AttrValue::Int(_) => "Int",
        AttrValue::Double(_) => "Double",
        AttrValue::Bool(_) => "Bool",
        AttrValue::Text(_) => "Text",
        AttrValue::UnderlineStyle(_) => "UnderlineStyle",
        AttrValue::Attachment(_) => "Attachment",
        AttrValue::Any(_) => "Any (UNSERIALISABLE — the wire cannot carry this)",
    }
}

fn key_name(k: &NSAttributedStringKey) -> String {
    match k {
        NSAttributedStringKey::Font => "font".into(),
        NSAttributedStringKey::ForegroundColor => "foregroundColor".into(),
        NSAttributedStringKey::ParagraphStyle => "paragraphStyle".into(),
        NSAttributedStringKey::Link => "link".into(),
        NSAttributedStringKey::StrikethroughStyle => "strikethroughStyle".into(),
        NSAttributedStringKey::UnderlineStyle => "underlineStyle".into(),
        NSAttributedStringKey::Attachment => "attachment".into(),
        NSAttributedStringKey::Custom(name) => format!("custom:{name}"),
    }
}

fn markdown_files(root: &std::path::Path) -> Vec<std::path::PathBuf> {
    if root.is_file() {
        return vec![root.to_path_buf()];
    }
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if matches!(path.extension().and_then(|e| e.to_str()), Some("md" | "markdown")) {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

#[test]
fn what_the_markdown_renderer_puts_on_a_string() {
    let _ = font_provider::install(Box::new(SingleFaceWorld));

    let given = std::env::var("FMD_MD_ATTR_CENSUS").ok();
    let root = match &given {
        Some(p) => std::path::PathBuf::from(p),
        None => std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../demo"),
    };
    let files = markdown_files(&root);
    assert!(!files.is_empty(), "no markdown under {}", root.display());

    let theme = fastdoc_engine::render::render_theme::RenderTheme::current(16.0);
    let mut pairs: BTreeMap<(String, &'static str), usize> = BTreeMap::new();
    let mut runs_total = 0usize;
    let mut chars_total = 0usize;

    for file in &files {
        let Ok(text) = std::fs::read_to_string(file) else { continue };
        chars_total += text.chars().count();
        let rendered = fastdoc_engine::render::markdown_renderer::MarkdownRenderer::render(&text, &theme);
        for (_range, attrs) in rendered.runs() {
            runs_total += 1;
            for (k, v) in attrs {
                *pairs.entry((key_name(k), kind(v))).or_insert(0) += 1;
            }
        }
    }

    println!(
        "MD-ATTR-CENSUS {} files, {} source chars, {} runs",
        files.len(), chars_total, runs_total
    );
    for ((key, kind), count) in &pairs {
        println!("  {count:>8}  {key} : {kind}");
    }

    // The wire cannot carry `Any`. If markdown ever starts using it the census says so here
    // rather than the serializer discovering it on a real document.
    let opaque: Vec<&(String, &str)> = pairs.keys().filter(|(_, k)| k.starts_with("Any")).collect();
    assert!(opaque.is_empty(), "markdown puts opaque payloads on a string: {opaque:?}");
    assert!(runs_total > 0, "nothing was rendered — the census means nothing");
}
