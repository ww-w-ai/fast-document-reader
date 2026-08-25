//! S5-03: the running-header band height decided IN RUST, through the measurement port rather
//! than a `todo!()` TextKit ritual — `page_band_geometry.rs`'s `built_height` now builds through
//! `OfficeTextBuilder` exactly as before and asks `swiftshim::text_measure::try_measurer()` for
//! the used height, and this file is where that wiring is proven.
//!
//! `swiftshim::text_measure`'s `MEASURER` is a process-global `OnceLock` (S5-02's one-shot
//! installation rule — two halves of one document measured against different text stacks would
//! be worse than either), and `cargo test` runs every `#[test]` in ONE integration-test file
//! inside the SAME process. So this file installs a measurer once, and every test in it observes
//! that same installation — which is also why the "nothing installed" case
//! (`page_band_measure_port_absence.rs`) lives in its OWN file: a separate `tests/*.rs` file is a
//! separate binary and therefore a separate process, the only way to observe `MEASURER` unset.
//!
//! The measurer here is a deterministic FAKE, not AppKit — this file proves the port's plumbing
//! (the right resolved payload reaches the right call and its answer comes back), not that
//! TextKit measures glyphs correctly. It sums a fixed per-paragraph allowance plus a
//! per-character allowance for every text run, plus an attachment's own reserved height verbatim
//! — so a longer header, a header with more paragraphs, AND a header carrying an image each move
//! the answer, and nothing here can be satisfied by a function that ignores its input.

use fastdoc_engine::render::office::office_block::{OfficeBlock, ParagraphFormat, Span};
use fastdoc_engine::render::office::page_band_geometry::{MeasureError, PageBandGeometry};
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::font_provider::{FaceId, FaceInfo, FontProvider};
use swiftshim::geometry::CGSize;
use swiftshim::text_measure::{ResolvedRun, ResolvedText, TextMeasurer};
use swiftshim::{CGFloat, NSFontDescriptorSymbolicTraits, NSFontWeight, NSTextAlignment};

/// `OfficeTextBuilder::build` resolves `theme.body_font()` through the SAME font port S2B already
/// proved, so a test that reaches it needs a font world installed too — one issued face id for
/// everything, deliberately generic: this file is proving the MEASUREMENT port's wiring, not font
/// resolution, so the font side only has to be present and consistent, never realistic.
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

const COLUMN_WIDTH: CGFloat = 400.0;
const DEFAULT_FONT_SIZE: CGFloat = 12.0;

/// Fixed per-paragraph allowance (stands in for a line's own height) plus a per-character
/// allowance (stands in for glyph advance) plus an attachment's reserved height taken verbatim —
/// deliberately arithmetic simple enough to hand-check in each assertion below.
struct FakeMeasurer;

impl TextMeasurer for FakeMeasurer {
    fn measure(&self, resolved: &ResolvedText, _width_points: CGFloat) -> CGFloat {
        let mut height: CGFloat = 0.0;
        for paragraph in &resolved.paragraphs {
            height += 20.0;
            for run in &paragraph.runs {
                match run {
                    ResolvedRun::Text { text, .. } => height += text.chars().count() as CGFloat * 2.0,
                    ResolvedRun::Attachment { height: h, .. } => height += *h,
                }
            }
        }
        height
    }
}

/// Installs `FakeMeasurer` exactly once for this process — `swiftshim::text_measure::install`
/// already refuses a second installation (S5-02), so a second call from a later test is a no-op
/// rather than an error, and every test in this file shares the one instance.
fn ensure_measurer_installed() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        assert!(
            swiftshim::font_provider::install(Box::new(FakeFontProvider)),
            "the first font-provider installation in this process must succeed"
        );
        assert!(
            swiftshim::text_measure::install(Box::new(FakeMeasurer)),
            "the first installation in this process must succeed"
        );
    });
}

fn text_paragraph(text: &str) -> OfficeBlock {
    OfficeBlock::Paragraph {
        spans: vec![Span { text: text.into(), ..Span::default() }],
        rtl: false,
        alignment: None,
        tab_stops: vec![],
        format: ParagraphFormat::default(),
    }
}

/// A picture-only paragraph — `OfficeBlock::Image` with an explicit alignment, so
/// `OfficeTextBuilder::apply_graphic_alignment` sets the `ParagraphStyle` attribute the port's
/// `ResolvedText::from_attributed_string` walks by (an image with `alignment: None` sets NO
/// paragraph style at all, and would silently vanish from the resolved payload — this test's
/// image block deliberately avoids that pit rather than proving nothing).
fn image_paragraph(width: CGFloat, height: CGFloat) -> OfficeBlock {
    OfficeBlock::Image { id: "logo".into(), size: CGSize::new(width, height), alignment: Some(NSTextAlignment::Left) }
}

fn built_height(blocks: &[OfficeBlock]) -> Result<CGFloat, MeasureError> {
    let theme = RenderTheme::current(DEFAULT_FONT_SIZE);
    PageBandGeometry::built_height(blocks, &theme, COLUMN_WIDTH, DEFAULT_FONT_SIZE, None)
}

#[test]
fn two_headers_of_different_lengths_get_two_different_heights() {
    ensure_measurer_installed();

    let short = built_height(&[text_paragraph("Q3 report")]).expect("measurer is installed");
    let long = built_height(&[
        text_paragraph("Q3 report — Consolidated Results for the Fiscal Year"),
        text_paragraph("Prepared by the Finance division, subject to audit"),
    ])
    .expect("measurer is installed");

    assert_ne!(short, long, "a constant would pass this — the port must carry the real text through");
    assert!(long > short, "the longer, multi-paragraph header must measure taller, not merely different");
}

#[test]
fn a_header_with_an_image_is_taller_than_the_same_header_without_it() {
    ensure_measurer_installed();

    let text_only = built_height(&[text_paragraph("Annual Report")]).expect("measurer is installed");
    let with_image =
        built_height(&[text_paragraph("Annual Report"), image_paragraph(64.0, 40.0)]).expect("measurer is installed");

    // This is S5-03's third case by name: a fonts-and-text-only payload would drop the
    // attachment's contribution entirely and this assertion would fail. Attachment height (40.0)
    // must show up in the difference, not just any positive delta.
    assert!(
        with_image > text_only + 39.0,
        "the attachment's own reserved height (40.0) must reach the measurer, not just its paragraph"
    );
}

#[test]
fn an_empty_header_measures_zero_without_asking_the_port_at_all() {
    ensure_measurer_installed();

    // `blocks.is_empty()` refuses before ever building or resolving anything — proven by the fact
    // that this passes even though no attachment size is reachable in an empty slice.
    assert_eq!(built_height(&[]).expect("empty is never a port question"), 0.0);
}
