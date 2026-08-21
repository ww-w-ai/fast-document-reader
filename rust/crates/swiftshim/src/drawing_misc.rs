//! swift: the small remainder — `NSTextAttachment` (an attributed-string run's image/graphic
//! placeholder), `NSBezierPath`, and the handful of `NSColor`/`NSImage`/`CGRect` drawing calls
//! GridTextTableBlock.swift and TableBlockBuilder.swift make directly (not through the
//! excluded, host-resident painters — see rust/PORT-MANIFEST.txt). `CGRect.fill()` in
//! particular lives here rather than in `geometry.rs`: geometry.rs is pure data with no notion
//! of a graphics context, and this is the one drawing operation the in-scope table-border code
//! calls straight on a rect.

use crate::color_font::NSImage;
use crate::geometry::{CGFloat, CGPoint, CGRect, NSSize};

/// swift: NSTextAttachment
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NSTextAttachment {
    pub image: Option<NSImage>,
    pub bounds: CGRect,
    pub attachmentCell: Option<SizedAttachmentCell>,
}

/// swift: Render/SizedAttachmentCell.swift — the cell that OWNS its layout size independently of
/// whether pixels are loaded, so lazily loading or purging an image never moves the document.
///
/// Only the SIZE crosses into the engine. The cell's drawing (`draw(withFrame:in:)`, the
/// undrawable-format label card) stays with the host, which is where a graphics context exists —
/// see `CROSS-PLATFORM.md` §2: the engine lays out and the host paints. What layout needs from
/// this type is the one thing the Swift class exists to guarantee: a reserved box that does not
/// change when the pixels do.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SizedAttachmentCell {
    pub reservedSize: NSSize,
}

impl SizedAttachmentCell {
    /// swift: `SizedAttachmentCell(reservedSize:)`
    pub fn new(reservedSize: NSSize) -> Self {
        Self { reservedSize }
    }
}

impl NSTextAttachment {
    pub fn new() -> Self {
        Self::default()
    }

    /// swift: `.bounds = _` — a plain field assignment (Swift property syntax), spelled as a
    /// setter here because the in-scope call sites invoke it as a message, not `att.bounds = _`.
    pub fn set_bounds(&mut self, bounds: CGRect) {
        self.bounds = bounds;
    }

    /// swift: `.image = _`
    pub fn set_image(&mut self, image: NSImage) {
        self.image = Some(image);
    }
}

/// swift: NSBezierPath — the reader's few in-scope path-drawing call sites (rules under a
/// footnote band, bar underlines) build a path with `.move(to:)`/`.line(to:)`/`.stroke()`.
/// Drawing itself needs a live graphics context, so it stays `todo!()`; the path's own point
/// list is real because later code (bounding-box math, if any) can use it without a context.
#[derive(Debug, Clone, Default)]
pub struct NSBezierPath {
    pub points: Vec<CGPoint>,
    pub lineWidth: CGFloat,
}

impl NSBezierPath {
    pub fn new() -> Self {
        Self::default()
    }

    /// swift: NSBezierPath(rect:) — GridTextTableBlock.swift's whole-point-width rule fill.
    pub fn fromRect(rect: CGRect) -> Self {
        Self::with_rect(rect)
    }

    /// swift: NSBezierPath(rect:) — same initializer as `fromRect` above, under this crate's own
    /// documented convention for a Swift initializer (a label list, not an identifier): a
    /// snake_case Rust-only name (`with_attributes`/`with_descriptor` set the precedent this
    /// follows; `fromRect` predates that convention and is kept only for its existing caller).
    pub fn with_rect(rect: CGRect) -> Self {
        Self {
            points: vec![
                CGPoint::new(rect.minX(), rect.minY()),
                CGPoint::new(rect.maxX(), rect.minY()),
                CGPoint::new(rect.maxX(), rect.maxY()),
                CGPoint::new(rect.minX(), rect.maxY()),
            ],
            lineWidth: 0.0,
        }
    }

    pub fn moveTo(&mut self, point: CGPoint) {
        self.points.push(point);
    }

    pub fn lineTo(&mut self, point: CGPoint) {
        self.points.push(point);
    }

    /// swift: `.lineWidth = _` — spelled as a setter (see `NSTextAttachment.set_bounds` above)
    /// because the in-scope call sites invoke it as a message.
    pub fn set_line_width(&mut self, width: CGFloat) {
        self.lineWidth = width;
    }

    pub fn close(&mut self) {
        if let Some(&first) = self.points.first() {
            self.points.push(first);
        }
    }

    /// swift: .setLineDash(_:count:phase:) — GridTextTableBlock.swift's dashed/dotted table
    /// rules. `count` is redundant with `pattern.len()` in Swift too (CoreGraphics's own API
    /// shape); kept as a parameter so the call site transliterates without reshaping.
    pub fn setLineDash(&mut self, _pattern: &[CGFloat], _count: usize, _phase: CGFloat) {
        todo!("swift: NSBezierPath.setLineDash(_:count:phase:) — phase B (needs a live graphics context)")
    }

    pub fn stroke(&self) {
        todo!("swift: NSBezierPath.stroke() — phase B (needs a live graphics context)")
    }

    pub fn fill(&self) {
        todo!("swift: NSBezierPath.fill() — phase B (needs a live graphics context)")
    }
}

/// swift: CGRect.fill() — an AppKit/CoreGraphics extension on the rect itself
/// (GridTextTableBlock.swift: `rect.fill()`, `NSRect(...).fill()`).
impl CGRect {
    pub fn fill(&self) {
        todo!("swift: NSRect.fill() — phase B (needs a live graphics context)")
    }
}

/// swift: NSCompositingOperation — `NSImage.draw(in:from:operation:fraction:respectFlipped:
/// hints:)`'s `operation:` argument. Only `.sourceOver` appears in the in-scope files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NSCompositingOperation {
    SourceOver,
}

/// swift: the `NSImage.draw(in:from:operation:fraction:respectFlipped:hints:)` extension the
/// in-scope table-background code calls directly (TableBlockBuilder.swift:21,
/// GridTextTableBlock.swift:151).
impl NSImage {
    pub fn draw(
        &self,
        _in_rect: CGRect,
        _from_rect: CGRect,
        _operation: NSCompositingOperation,
        _fraction: CGFloat,
        _respect_flipped: bool,
        _hints: Option<()>,
    ) {
        todo!("swift: NSImage.draw(in:from:operation:fraction:respectFlipped:hints:) — phase B")
    }
}

/// swift: no Apple original — this crate's own decision of what to do with a character
/// `rhwp`'s font-metric table has no answer for (an off-table face, or a codepoint the matched
/// face's own `latin_ranges`/`hangul` tables don't cover).
///
/// `size_with_attributes` below MUST keep returning a concrete `NSSize` — it mirrors
/// `NSString.size(withAttributes:)`'s real signature, which every call site depends on — so the
/// measured/guessed distinction cannot live in ITS return type. It lives here instead, one layer
/// down: a single, named, grep-able point where a miss is decided, rather than a guess folded
/// silently into a width number nobody downstream can tell apart from a real measurement.
///
/// Team-lead review 2026-08-21: do NOT copy `rhwp`'s own miss fallback (a flat CJK-1.0em/
/// narrow-punctuation-0.3em guess, in its private `measure_char_width_embedded` — not `pub`,
/// unreachable from here regardless). That is the right answer for a renderer with no OS to ask;
/// this app runs on a machine with the real font installed, so the right LONG-RUN answer is a
/// CoreText glyph-advance query on the actual installed face — deliberately not wired yet (this
/// is the door left open for it, see `Estimated`'s doc). Until it lands, misses use OUR OWN
/// interim policy (`estimate_unmeasured_advance`), chosen independently, not inherited.
enum GlyphAdvance {
    /// Points. Read straight out of `rhwp`'s font-metric table for this exact (face, bold,
    /// italic, character) — real data, not a guess.
    Measured(CGFloat),
    /// Points. INVENTED by `estimate_unmeasured_advance` because nothing better exists yet.
    /// This is the seam a future CoreText-backed query replaces: swap what constructs this
    /// variant, not the summation loop in `size_with_attributes` that consumes it.
    Estimated(CGFloat),
}

impl GlyphAdvance {
    fn points(&self) -> CGFloat {
        match self {
            GlyphAdvance::Measured(w) | GlyphAdvance::Estimated(w) => *w,
        }
    }
}

/// swift: no Apple original — see `GlyphAdvance`'s doc for why this exists and why it does NOT
/// mirror `rhwp`'s own (unreachable, private) fallback. A CJK-range character is almost always
/// drawn full-width by any real installed CJK face, so it gets the full em; everything else
/// (Latin, punctuation, symbols outside the table) gets half — the same rough split typography
/// commonly defaults to absent real metrics. This is a placeholder, not a measurement; it exists
/// so `size_with_attributes` has SOMETHING to return today rather than panicking on any
/// off-table face, and it is meant to be replaced wholesale, not tuned, once a CoreText path
/// exists.
fn estimate_unmeasured_advance(ch: char, font_size_pt: CGFloat) -> CGFloat {
    let code = ch as u32;
    let is_wide = matches!(
        code,
        0x1100..=0x11FF   // Hangul Jamo
        | 0x2E80..=0xA4CF // CJK radicals through Yi syllables
        | 0xAC00..=0xD7A3 // Hangul syllables (should already be covered by a matched face's
                          // `hangul` table — this branch is the belt-and-braces case: an
                          // off-table FACE entirely, not a covered face missing a syllable)
        | 0xF900..=0xFAFF // CJK compatibility ideographs
        | 0xFF00..=0xFFEF // halfwidth/fullwidth forms
    );
    if is_wide {
        font_size_pt
    } else {
        font_size_pt * 0.5
    }
}

/// swift: no Apple original — one character's advance, real if `rhwp`'s table covers it.
///
/// UNITS, stated once here rather than re-derived at each call site: `FontMetric.em_size` is
/// the face's OWN design-space em (1000 for most faces in the table, 1024 for a handful of
/// bitmap-shaped Windows system fonts — read straight off the struct, never assumed). The table's
/// `widths`/`get_width` values are in THAT em's units. `font_size_pt` is a real point size (what
/// every call site in this crate already works in). The conversion, done exactly once, right
/// here, is `raw_units * font_size_pt / em_size` — get this backwards and every measured string
/// in the whole document scales by the same wrong factor, silently, in only the direction that
/// makes text either overflow every container or float in the middle of empty space.
///
/// Hangul composition is NOT reimplemented here: `FontMetric::get_width` already walks the
/// syllable's cho/jung/jong group indices into `HangulMetric.widths` for U+AC00–U+D7A3 — calling
/// it per character, as this does, reproduces that composition exactly rather than re-deriving
/// the group-index arithmetic a second time (see `rhwp`'s own `font_metrics_data.rs` for the
/// canonical implementation this defers to).
fn glyph_advance(
    metric: Option<&rhwp::renderer::font_metrics_data::FontMetric>,
    ch: char,
    font_size_pt: CGFloat,
) -> GlyphAdvance {
    if let Some(m) = metric {
        if let Some(raw_units) = m.get_width(ch) {
            let em = m.em_size as CGFloat;
            return GlyphAdvance::Measured(raw_units as CGFloat * font_size_pt / em);
        }
    }
    GlyphAdvance::Estimated(estimate_unmeasured_advance(ch, font_size_pt))
}

/// swift: `NSString.size(withAttributes:)` — how much room a run of text takes at a given font.
///
/// WIDTH is real: summed per-character from `rhwp`'s 595-face metric table (see `glyph_advance`
/// for the unit conversion and the Hangul composition note, `GlyphAdvance`/
/// `estimate_unmeasured_advance` for the miss policy). No `.font` attribute defaults to an empty
/// face name (→ every character misses the table → the estimate policy) at 12pt, matching
/// Apple's own documented default for this method when no font is specified.
///
/// HEIGHT is NOT real. `rhwp`'s table carries advance WIDTHS only (`em_size`, `latin_ranges`,
/// `hangul`) — no ascender, descender or leading, so there is nothing in it to compute a real
/// line height from. `font_size_pt * 1.2` is a placeholder (a common rough em-to-line-height
/// ratio), on the same "known gap, not a measurement" footing as `GlyphAdvance::Estimated`
/// above, and needs its own CoreText-backed answer later — this is that gap's door, left open
/// but not walked through, per team-lead instruction (2026-08-21) not to build the CoreText path
/// yet.
pub fn size_with_attributes(
    text: &str,
    attributes: &std::collections::HashMap<crate::NSAttributedStringKey, crate::AttrValue>,
) -> crate::geometry::NSSize {
    let (font_name, font_size_pt, bold, italic) =
        match attributes.get(&crate::NSAttributedStringKey::Font) {
            Some(crate::AttrValue::Font(font)) => {
                let traits = font.fontDescriptor().symbolicTraits();
                (
                    font.fontName(),
                    font.pointSize(),
                    traits.contains(crate::color_font::NSFontDescriptorSymbolicTraits::bold),
                    traits.contains(crate::color_font::NSFontDescriptorSymbolicTraits::italic),
                )
            }
            // swift: `NSString.size(withAttributes:)` with no `.font` key — Apple's own
            // documented default is the system font at 12pt; an empty face name misses the
            // table (every char goes through the estimate policy) exactly as a genuinely
            // off-table face would, so this needs no separate branch below.
            _ => (String::new(), 12.0, false, false),
        };

    let metric = rhwp::renderer::font_metrics_data::find_metric(&font_name, bold, italic)
        .map(|found| found.metric);

    let width: CGFloat = text
        .chars()
        .map(|ch| glyph_advance(metric, ch, font_size_pt).points())
        .sum();
    let height = font_size_pt * 1.2;

    crate::geometry::NSSize::new(width, height)
}

/// swift: `NSString.draw(at:withAttributes:)` — paints a label into the current graphics context.
///
/// Drawing is the host's, not the engine's (`CROSS-PLATFORM.md` §2). This call site survives the
/// transliteration because `OfficeTextBuilder.swift` builds a placeholder card's label and paints it
/// in the same routine; Phase B replaces it with a `RenderTree` node the host paints.
pub fn draw_string_at(
    _text: &str,
    _at: crate::geometry::NSPoint,
    _attributes: &std::collections::HashMap<crate::NSAttributedStringKey, crate::AttrValue>,
) {
    todo!("host paints — see CROSS-PLATFORM.md §2")
}

#[cfg(test)]
mod font_metric_tests {
    use super::*;
    use crate::{AttrValue, NSAttributedStringKey};
    use std::collections::HashMap;

    // `NSFont`'s real constructors (`named`, `with_descriptor`, `systemFont`, …) all defer to
    // CoreText (`todo!()`), and there is no other public way to fill an `NSFont`'s private
    // fields from outside `color_font.rs`. `size_with_attributes` itself never needs a populated
    // `NSFont` to have a real face behind it (it only reads whatever `fontName`/`pointSize`/
    // `fontDescriptor` say), so these tests exercise the two things that ARE independently
    // testable: `glyph_advance` directly against a real `find_metric` lookup, and
    // `size_with_attributes`'s documented no-`.font`-key default path.

    #[test]
    fn measured_latin_advance_uses_the_table_not_the_estimate() {
        let found = rhwp::renderer::font_metrics_data::find_metric("Arial", false, false)
            .expect("Arial is one of the 595 faces the table carries");
        let advance = glyph_advance(Some(found.metric), 'A', 12.0);
        match advance {
            GlyphAdvance::Measured(w) => assert!(w > 0.0 && w < 12.0, "got {w}"),
            GlyphAdvance::Estimated(_) => panic!("Arial's 'A' must be a real table hit, not a guess"),
        }
    }

    #[test]
    fn off_table_face_is_honestly_estimated_not_silently_measured() {
        let found = rhwp::renderer::font_metrics_data::find_metric("NoSuchFaceXYZ", false, false);
        assert!(found.is_none());
        let advance = glyph_advance(None, 'A', 12.0);
        match advance {
            GlyphAdvance::Estimated(w) => assert_eq!(w, 6.0, "narrow-script estimate is half the em"),
            GlyphAdvance::Measured(_) => panic!("an off-table face must never report Measured"),
        }
    }

    #[test]
    fn hangul_syllable_composes_through_get_width_at_a_non_1000_em_size() {
        // "Malgun Gothic" (regular) carries `em_size: 2048` — deliberately not the common 1000,
        // to prove the conversion divides by the FACE'S OWN em rather than a hardcoded 1000.
        let found = rhwp::renderer::font_metrics_data::find_metric("Malgun Gothic", false, false)
            .expect("Malgun Gothic regular is in the table with hangul data");
        assert!(found.metric.hangul.is_some());
        assert_eq!(found.metric.em_size, 2048);
        let advance = glyph_advance(Some(found.metric), '가', 20.0); // U+AC00, first syllable
        match advance {
            GlyphAdvance::Measured(w) => {
                // A Hangul syllable at 20pt should land somewhere well under a full 20pt em
                // and well above zero — not a hardcoded, not an overflow from a units bug
                // (dividing by the wrong em would push this either near 0 or far past 20).
                assert!(w > 5.0 && w <= 20.0, "got {w} — check the em_size conversion");
            }
            GlyphAdvance::Estimated(_) => panic!("U+AC00 in a matched hangul-carrying face must be Measured"),
        }
    }

    #[test]
    fn size_with_attributes_estimates_height_on_the_off_table_default_path() {
        let attrs = HashMap::from([(
            NSAttributedStringKey::ForegroundColor,
            AttrValue::Color(crate::NSColor::black()),
        )]); // no `.font` key — exercises the documented "default to 12pt, empty face" path
        let size = size_with_attributes("AB", &attrs);
        // Two chars against an off-table (empty-name) face: both estimated at half of 12pt.
        assert_eq!(size.width, 12.0);
        assert_eq!(size.height, 12.0 * 1.2);
    }

    /// The one test that reaches `size_with_attributes` through its PUBLIC surface (not
    /// `glyph_advance` directly) with a real `.font` key that resolves to a table hit — every
    /// other caller in the engine goes through exactly this path. An earlier version of this test
    /// only asserted `width == font_size` for a 2-char off-table string, which is invariant under
    /// the em/pt conversion entirely (it never touches the table) — team-lead mutation testing
    /// caught it: inverting `raw * font_size / em` to `raw * em / font_size` still passed. This
    /// version computes its expected width from the table's OWN numbers, independently of
    /// `glyph_advance`'s own arithmetic, specifically so an inverted or transposed conversion
    /// shows up as a real mismatch.
    #[test]
    fn size_with_attributes_matches_the_tables_own_measured_width_for_a_real_face() {
        let font = crate::color_font::NSFont::for_metrics_test("Arial", 12.0);
        let attrs = HashMap::from([(NSAttributedStringKey::Font, AttrValue::Font(font))]);

        let found = rhwp::renderer::font_metrics_data::find_metric("Arial", false, false)
            .expect("Arial is one of the 595 faces the table carries");
        let em = found.metric.em_size as CGFloat;
        // Independently computed, not by calling `glyph_advance`: raw table units → points, the
        // same `raw * font_size / em` conversion stated (and only stated once) in that function's
        // doc — restated HERE, separately, is what lets a mutation in the real implementation
        // show up as a numeric mismatch instead of agreeing with itself.
        let expected: CGFloat = "AB"
            .chars()
            .map(|ch| {
                let raw = found.metric.get_width(ch).expect("Arial covers plain ASCII 'A' and 'B'");
                raw as CGFloat * 12.0 / em
            })
            .sum();
        assert!(expected > 0.0, "sanity: the table must report a nonzero width for 'AB'");

        let size = size_with_attributes("AB", &attrs);
        assert!(
            (size.width - expected).abs() < 1e-9,
            "got {}, expected {expected} (table em_size={em})",
            size.width
        );
    }
}
