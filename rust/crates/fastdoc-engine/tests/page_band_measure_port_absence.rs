//! S5-03/S5-05: with no `TextMeasurer` installed, the band-height decision returns a TYPED
//! absence rather than panicking or guessing a plausible height.
//!
//! This has to live in its OWN `tests/*.rs` file: `swiftshim::text_measure`'s `MEASURER` is a
//! process-global `OnceLock`, `cargo test` gives each `tests/*.rs` file its own process, and
//! `page_band_measure_port.rs` installs a measurer for every test IN THAT file. The only way to
//! observe "nothing was ever installed" is a process that never calls `install`/`install_callbacks`
//! at all — this file, and nothing else in it.

use fastdoc_engine::render::office::office_block::{OfficeBlock, ParagraphFormat, Span};
use fastdoc_engine::render::office::page_band_geometry::{MeasureError, PageBandGeometry};
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::font_provider::{FaceId, FaceInfo, FontProvider};
use swiftshim::{NSFontDescriptorSymbolicTraits, NSFontWeight};

/// `OfficeTextBuilder::build` reaches the FONT port before it ever reaches the measurement one —
/// this file is proving the measurement port's absence specifically, so the font world has to be
/// present (this fake, installed once) while the measurement world stays genuinely empty. This is
/// NOT the case under test; it is scaffolding to reach the case under test.
struct FakeFontProvider;

impl FontProvider for FakeFontProvider {
    fn face_named(&self, _name: &str) -> Option<FaceId> {
        Some(FaceId(1))
    }
    fn resolve(&self, _descriptor: &swiftshim::color_font::NSFontDescriptor) -> Option<FaceId> {
        Some(FaceId(1))
    }
    fn system_face(&self, _weight: NSFontWeight, _monospaced: bool) -> FaceId {
        FaceId(1)
    }
    fn describe(&self, _face: FaceId) -> FaceInfo {
        FaceInfo { name: "Helvetica".to_string(), family: Some("Helvetica".to_string()), traits: NSFontDescriptorSymbolicTraits::empty() }
    }
    fn covers(&self, _face: FaceId, _scalar: u32) -> bool {
        true
    }
    fn substitute(&self, _declared: FaceId, _scalar: u32) -> Option<FaceId> {
        None
    }
}

fn ensure_font_provider_installed() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        assert!(swiftshim::font_provider::install(Box::new(FakeFontProvider)), "first font install in this process");
    });
}

#[test]
fn built_height_refuses_rather_than_guessing_when_nothing_is_installed() {
    ensure_font_provider_installed();
    assert!(
        !swiftshim::text_measure::is_installed(),
        "this file must never install a measurer — that is the whole point of it living alone"
    );

    let theme = RenderTheme::current(12.0);
    let blocks = [OfficeBlock::Paragraph {
        spans: vec![Span { text: "A running header with real text in it".into(), ..Span::default() }],
        rtl: false,
        alignment: None,
        tab_stops: vec![],
        format: ParagraphFormat::default(),
    }];

    let result = PageBandGeometry::built_height(&blocks, &theme, 400.0, 12.0, None);

    assert_eq!(
        result,
        Err(MeasureError::NoMeasurer),
        "no measurer installed must be a typed refusal, never a panic and never a stand-in height"
    );
}

#[test]
fn an_empty_header_still_measures_zero_even_with_nothing_installed() {
    // The empty-blocks short-circuit must not even ASK the port — proven here by the fact that it
    // succeeds in a process where asking would refuse.
    let theme = RenderTheme::current(12.0);
    assert_eq!(PageBandGeometry::built_height(&[], &theme, 400.0, 12.0, None), Ok(0.0));
}
