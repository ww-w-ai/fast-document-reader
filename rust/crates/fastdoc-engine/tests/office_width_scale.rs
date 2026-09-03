use std::collections::HashMap;

use fastdoc_engine::render::office::office_block::Span;
use fastdoc_engine::render::office::office_text_builder::OfficeTextBuilder;
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::color_font::{NSFontDescriptor, NSFontDescriptorSymbolicTraits, NSFontWeight};
use swiftshim::font_provider::{self, FaceId, FaceInfo, FontProvider};
use swiftshim::{AttrValue, NSAttributedStringKey, NSColor, NSFont};

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

#[test]
fn authored_width_scale_reaches_the_font_attribute() {
    let _ = font_provider::install(Box::new(SingleFaceWorld));
    let span = Span {
        text: "장평".into(),
        width_scale_percent: Some(95.0),
        ..Span::default()
    };
    let base_font = NSFont::systemFont(10.0);
    let rendered = OfficeTextBuilder::spans_attributed_string(
        &[span],
        &base_font,
        &NSColor::black(),
        &RenderTheme::current(10.0),
        1.0,
        true,
        &HashMap::new(),
    );

    let Some((AttrValue::Font(font), _)) = rendered.attribute(&NSAttributedStringKey::Font, 0) else {
        panic!("rendered span must carry a font attribute");
    };
    assert_eq!(font.widthScale(), 0.95);
}
