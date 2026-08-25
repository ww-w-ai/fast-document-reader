//! The one place the engine asks a question only a live text stack can answer: how tall is this
//! text at this width.
//!
//! `page_band_geometry.rs:225-240` (`built_height`) builds a running header's text through
//! `OfficeTextBuilder`, hands the result to TextKit, and reads back a used-rect height —
//! `textkit.rs` names every primitive that ritual calls `todo!("phase B (host-resident)")`, and
//! this crate does not reimplement glyph metrics or line breaking to fill them in (S5's plan,
//! "out of scope"). So the port does not expose the ritual; it exposes the QUESTION the ritual
//! exists to answer:
//!
//! ```text
//! measure(resolved_text, width_points) -> height_points
//! ```
//!
//! `resolved_text` is `OfficeTextBuilder`'s OUTPUT, not the canonical tree's runs — paragraph
//! style, tab stops, hanging indents, line height and list numbering are all INTERPRETED by the
//! builder, and a host handed raw tree runs would have to redo that interpretation to reach the
//! same height. That redoing is exactly the decision this sprint keeps in Rust. So this module
//! carries, per paragraph, the resolved attributes that affect height, and per run, either a
//! resolved font + text or — for an attachment — the box `SizedAttachmentCell` already fitted.
//! Paragraph shading and borders are deliberately absent: `office_text_builder.rs:473` records
//! them as draw-time attributes, so they do not contribute to a used rect.
//!
//! Shaped after `font_provider.rs` on purpose (S5's dependency on S2B): a callback table
//! installed once through the FFI, a typed absence (`try_measurer`) rather than a panic, and the
//! same containment guard every export already goes through.
//!
//! ## Ownership of the bytes that cross
//!
//! The payload (`TextMeasurePayload` and everything it points into) is built by Rust immediately
//! before the callback runs, borrowed by the host for the DURATION OF THAT ONE CALL, and dropped
//! by Rust the moment the callback returns. A host that wants to keep any of it — a family name,
//! a paragraph's tab stops — copies it before returning. This is stated explicitly because the
//! font provider's callbacks pass scalars and a single NUL-terminated string, so its ownership
//! rule was small enough to leave implicit; a struct with two array fields is not, and a rule
//! discovered during implementation is a rule that drifts between the two sides.

use crate::attributed_string::{AttrValue, NSAttributedString, NSAttributedStringKey};
use crate::color_font::{NSFont, NSFontDescriptorSymbolicTraits};
use crate::foundation::NSRange;
use crate::geometry::CGFloat;
use crate::paragraph_style::{NSParagraphStyle, NSTextAlignment};
use std::ffi::CString;
use std::os::raw::c_char;

// -------------------------------------------------------------------------------------------
// The resolved payload, as an owned Rust value. Easy to build and to assert on directly; the C
// ABI shape below is a projection of this, not the other way round.
// -------------------------------------------------------------------------------------------

/// One resolved tab stop — `NSParagraphStyle.tabStops`' own shape, flattened.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResolvedTabStop {
    pub alignment: NSTextAlignment,
    pub location: CGFloat,
}

/// A run inside a resolved paragraph: either text set in a resolved face, or an attachment whose
/// reserved box the builder already computed (`SizedAttachmentCell::new(fitted)`).
#[derive(Debug, Clone, PartialEq)]
pub enum ResolvedRun {
    Text {
        font_name: String,
        size: CGFloat,
        bold: bool,
        italic: bool,
        text: String,
    },
    Attachment {
        width: CGFloat,
        height: CGFloat,
    },
}

/// One paragraph's resolved height-affecting attributes, plus its runs in order.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedParagraph {
    pub alignment: NSTextAlignment,
    pub line_spacing: CGFloat,
    pub line_height_multiple: CGFloat,
    pub minimum_line_height: CGFloat,
    pub maximum_line_height: CGFloat,
    pub spacing_before: CGFloat,
    pub spacing_after: CGFloat,
    pub first_line_head_indent: CGFloat,
    pub head_indent: CGFloat,
    pub tail_indent: CGFloat,
    pub tab_stops: Vec<ResolvedTabStop>,
    pub runs: Vec<ResolvedRun>,
}

impl ResolvedParagraph {
    fn from_style(style: &NSParagraphStyle) -> Self {
        Self {
            alignment: style.alignment,
            line_spacing: style.lineSpacing,
            line_height_multiple: style.lineHeightMultiple,
            minimum_line_height: style.minimumLineHeight,
            maximum_line_height: style.maximumLineHeight,
            spacing_before: style.paragraphSpacingBefore,
            spacing_after: style.paragraphSpacing,
            first_line_head_indent: style.firstLineHeadIndent,
            head_indent: style.headIndent,
            tail_indent: style.tailIndent,
            tab_stops: style
                .tabStops
                .iter()
                .map(|t| ResolvedTabStop {
                    alignment: t.alignment,
                    location: t.location,
                })
                .collect(),
            runs: Vec::new(),
        }
    }
}

/// A whole text's worth of resolved paragraphs, in document order.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ResolvedText {
    pub paragraphs: Vec<ResolvedParagraph>,
}

/// Why `from_attributed_string` refused to build a payload — refusing rather than guessing a
/// box or dropping a byte, the same call this port already makes about an uninstalled provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveError {
    /// An attachment run carried no `SizedAttachmentCell`, so its box is unknown. A run list
    /// carrying only fonts and text would silently drop its contribution to the height — the
    /// failure this module's header calls out by name — so this refuses instead.
    UnresolvedAttachmentSize,
    /// A run's text contained an interior NUL, which cannot cross as a NUL-terminated C string.
    /// Real office text never does; this stays a checked path rather than a lossy truncation
    /// because it crosses the ABI.
    InteriorNul,
}

impl std::fmt::Display for ResolveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnresolvedAttachmentSize => {
                f.write_str("an attachment run has no reserved size to measure with")
            }
            Self::InteriorNul => f.write_str("a run's text contains an interior NUL byte"),
        }
    }
}

impl std::error::Error for ResolveError {}

impl ResolvedText {
    /// Flattens `OfficeTextBuilder`'s output into the port's payload. Mechanical only — it reads
    /// the attributes the builder already decided and copies them; it makes no document-semantic
    /// decision of its own (that is `office_text_builder.rs`'s job, and stays there).
    ///
    /// Paragraph boundaries are taken from the `ParagraphStyle` attribute's own run ranges: the
    /// builder sets exactly one such run per paragraph (`office_text_builder.rs:382`, `:401`,
    /// `:434`), so this does not re-derive paragraphs by splitting on `\n`.
    ///
    /// The RUN text handed to `resolved_runs_in`, though, is the paragraph range MINUS its own
    /// trailing terminator when that terminator carries a `Font` attribute — which it always
    /// does, because the builder applies the paragraph's inheritable attributes (`Font` included)
    /// to the "\n" it appends, the same way `Sources/FastDocReader/Render/Office/
    /// RustEngineMeasure.swift`'s own `makePayload` states it for the Swift-built case. Left in,
    /// that "\n" becomes a literal run of TEXT, and the measurer on the other side of the port
    /// (`RustEngineMeasure.measure`) appends its OWN synthetic "\n" per paragraph — a real
    /// paragraph carrying two terminators, one line too tall, in every payload this function
    /// ever built. `RustEngineBridgeTests` caught it the moment the live cross-process call was
    /// wired up: a single-paragraph header measured 67.8pt through the port against 41.9pt from
    /// the host's own `PageBandGeometry.builtHeight` for the identical content — a whole extra
    /// line, not rounding.
    pub fn from_attributed_string(attr: &NSAttributedString) -> Result<Self, ResolveError> {
        let whole = NSRange::new(0, attr.length());
        let mut paragraphs = Vec::new();

        attr.enumerateAttribute(&NSAttributedStringKey::ParagraphStyle, whole, |value, range, _stop| {
            if let Some(AttrValue::ParagraphStyle(style)) = value {
                paragraphs.push((range, ResolvedParagraph::from_style(style)));
            }
        });

        for (range, paragraph) in &mut paragraphs {
            let content_range = trim_trailing_terminator(attr, *range);
            paragraph.runs = resolved_runs_in(attr, content_range)?;
        }

        Ok(ResolvedText {
            paragraphs: paragraphs.into_iter().map(|(_, p)| p).collect(),
        })
    }
}

/// `range` minus its own last character when that character is the paragraph's own "\n"
/// terminator (UTF-16 code unit 10) — never more than one character, and never touching a range
/// that does not end in one, so a paragraph whose content legitimately ends some other way is
/// returned unchanged.
fn trim_trailing_terminator(attr: &NSAttributedString, range: NSRange) -> NSRange {
    if range.length == 0 {
        return range;
    }
    let last = range.location + range.length - 1;
    if attr.characterAt(last) == 10 {
        NSRange::new(range.location, range.length - 1)
    } else {
        range
    }
}

/// The runs inside one paragraph's range, attachments and text merged into document order.
///
/// An attachment occupies the `U+FFFC` object-replacement character and carries no `Font`
/// attribute of its own (`NSMutableAttributedString::from_attachment`), so the two attribute
/// enumerations below are disjoint in practice; the overlap guard exists so a future builder
/// change that DID set both cannot silently double-count a span as both a box and a glyph run.
fn resolved_runs_in(attr: &NSAttributedString, range: NSRange) -> Result<Vec<ResolvedRun>, ResolveError> {
    enum Event {
        Attachment(Option<crate::geometry::NSSize>),
        Text(NSFont),
    }

    let mut events: Vec<(NSRange, Event)> = Vec::new();
    attr.enumerateAttribute(&NSAttributedStringKey::Attachment, range, |value, run_range, _stop| {
        if let Some(AttrValue::Attachment(attachment)) = value {
            let size = attachment.attachmentCell.as_ref().map(|cell| cell.reservedSize);
            events.push((run_range, Event::Attachment(size)));
        }
    });
    attr.enumerateAttribute(&NSAttributedStringKey::Font, range, |value, run_range, _stop| {
        if let Some(AttrValue::Font(font)) = value {
            let covered = events.iter().any(|(other, event)| {
                matches!(event, Event::Attachment(_))
                    && other.location <= run_range.location
                    && run_range.maxRange() <= other.maxRange()
            });
            if !covered {
                events.push((run_range, Event::Text(font.clone())));
            }
        }
    });
    events.sort_by_key(|(r, _)| r.location);

    let mut runs = Vec::with_capacity(events.len());
    for (run_range, event) in events {
        match event {
            Event::Attachment(Some(size)) => runs.push(ResolvedRun::Attachment {
                width: size.width,
                height: size.height,
            }),
            Event::Attachment(None) => return Err(ResolveError::UnresolvedAttachmentSize),
            Event::Text(font) => {
                let text = attr.attributed_substring(run_range).string().to_string();
                if text.contains('\0') {
                    return Err(ResolveError::InteriorNul);
                }
                let traits = font.fontDescriptor().symbolicTraits();
                runs.push(ResolvedRun::Text {
                    font_name: font.fontName(),
                    size: font.pointSize(),
                    bold: traits.contains(NSFontDescriptorSymbolicTraits::bold),
                    italic: traits.contains(NSFontDescriptorSymbolicTraits::italic),
                    text,
                });
            }
        }
    }
    Ok(runs)
}

// -------------------------------------------------------------------------------------------
// The C ABI shape: one contiguous array of paragraphs and one contiguous array of runs, each
// with its length — not a callback invoked per run (S5-01). A run names which paragraph it
// belongs to rather than nesting, so both arrays are flat.
// -------------------------------------------------------------------------------------------

fn alignment_code(alignment: NSTextAlignment) -> u8 {
    match alignment {
        NSTextAlignment::Left => 0,
        NSTextAlignment::Right => 1,
        NSTextAlignment::Center => 2,
        NSTextAlignment::Justified => 3,
        NSTextAlignment::Natural => 4,
    }
}

/// swift: one `NSTextTab` — see this module's header for who owns the pointee's lifetime.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextMeasureTabStop {
    /// `NSTextAlignment`'s wire code — `alignment_code`'s ordering: left=0, right=1, center=2,
    /// justified=3, natural=4.
    pub alignment: u8,
    pub location: CGFloat,
}

/// One resolved paragraph's height-affecting attributes. `tab_stops`/`tab_stop_count` is this
/// paragraph's own contiguous array, borrowed for the call like everything else here.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextMeasureParagraph {
    pub alignment: u8,
    pub line_spacing: CGFloat,
    pub line_height_multiple: CGFloat,
    pub minimum_line_height: CGFloat,
    pub maximum_line_height: CGFloat,
    pub spacing_before: CGFloat,
    pub spacing_after: CGFloat,
    pub first_line_head_indent: CGFloat,
    pub head_indent: CGFloat,
    pub tail_indent: CGFloat,
    pub tab_stops: *const TextMeasureTabStop,
    pub tab_stop_count: usize,
}

/// A run's kind — which half of `TextMeasureRun`'s fields are meaningful.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextMeasureRunKind {
    Text = 0,
    Attachment = 1,
}

/// One run. `paragraph_index` indexes `TextMeasurePayload::paragraphs`, which is how a flat run
/// array names its paragraph without nesting. `family`/`text` are borrowed, NUL-terminated UTF-8,
/// valid ONLY on `kind == Text`; `attachment_width`/`attachment_height` are valid only on
/// `kind == Attachment`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextMeasureRun {
    pub paragraph_index: usize,
    pub kind: TextMeasureRunKind,
    /// The face's OWN name, not its family. `NSFont(name:size:)` wants a face; handing it a
    /// family silently falls back to the system font for any family whose face name differs, and
    /// the metric difference then accumulates line by line — measured as 8pt on a three-line band
    /// and 25pt on a taller one before this was named correctly.
    pub font_name: *const c_char,
    pub size: CGFloat,
    pub bold: bool,
    pub italic: bool,
    pub text: *const c_char,
    pub attachment_width: CGFloat,
    pub attachment_height: CGFloat,
}

/// The whole payload crossing in one call: two contiguous arrays, each with its own length.
#[repr(C)]
pub struct TextMeasurePayload {
    pub paragraphs: *const TextMeasureParagraph,
    pub paragraph_count: usize,
    pub runs: *const TextMeasureRun,
    pub run_count: usize,
}

/// Everything a `TextMeasurePayload` points into, kept alive for exactly the duration of one
/// callback invocation and dropped — by ordinary Rust ownership, not a manual `Drop` impl — the
/// moment `CallbackMeasurer::measure` returns. A `CString`'s bytes live on its own heap
/// allocation independent of the `Vec` that holds it, so pushing further entries never moves a
/// pointer already handed to the host.
struct OwnedPayload {
    _families: Vec<CString>,
    _texts: Vec<CString>,
    _tab_stops: Vec<Vec<TextMeasureTabStop>>,
    paragraphs: Vec<TextMeasureParagraph>,
    runs: Vec<TextMeasureRun>,
}

impl OwnedPayload {
    fn build(resolved: &ResolvedText) -> Self {
        let mut families = Vec::new();
        let mut texts = Vec::new();
        let mut tab_stop_vecs: Vec<Vec<TextMeasureTabStop>> = Vec::new();
        let mut paragraphs = Vec::with_capacity(resolved.paragraphs.len());
        let mut runs = Vec::new();

        for (index, paragraph) in resolved.paragraphs.iter().enumerate() {
            let tab_stops: Vec<TextMeasureTabStop> = paragraph
                .tab_stops
                .iter()
                .map(|t| TextMeasureTabStop {
                    alignment: alignment_code(t.alignment),
                    location: t.location,
                })
                .collect();
            tab_stop_vecs.push(tab_stops);
            let stops = tab_stop_vecs.last().expect("just pushed");

            paragraphs.push(TextMeasureParagraph {
                alignment: alignment_code(paragraph.alignment),
                line_spacing: paragraph.line_spacing,
                line_height_multiple: paragraph.line_height_multiple,
                minimum_line_height: paragraph.minimum_line_height,
                maximum_line_height: paragraph.maximum_line_height,
                spacing_before: paragraph.spacing_before,
                spacing_after: paragraph.spacing_after,
                first_line_head_indent: paragraph.first_line_head_indent,
                head_indent: paragraph.head_indent,
                tail_indent: paragraph.tail_indent,
                tab_stops: stops.as_ptr(),
                tab_stop_count: stops.len(),
            });

            for run in &paragraph.runs {
                match run {
                    ResolvedRun::Text { font_name, size, bold, italic, text } => {
                        families.push(CString::new(font_name.as_str()).unwrap_or_default());
                        texts.push(CString::new(text.as_str()).unwrap_or_default());
                        runs.push(TextMeasureRun {
                            paragraph_index: index,
                            kind: TextMeasureRunKind::Text,
                            font_name: families.last().expect("just pushed").as_ptr(),
                            size: *size,
                            bold: *bold,
                            italic: *italic,
                            text: texts.last().expect("just pushed").as_ptr(),
                            attachment_width: 0.0,
                            attachment_height: 0.0,
                        });
                    }
                    ResolvedRun::Attachment { width, height } => {
                        runs.push(TextMeasureRun {
                            paragraph_index: index,
                            kind: TextMeasureRunKind::Attachment,
                            font_name: std::ptr::null(),
                            size: 0.0,
                            bold: false,
                            italic: false,
                            text: std::ptr::null(),
                            attachment_width: *width,
                            attachment_height: *height,
                        });
                    }
                }
            }
        }

        Self { _families: families, _texts: texts, _tab_stops: tab_stop_vecs, paragraphs, runs }
    }

    fn as_ffi(&self) -> TextMeasurePayload {
        TextMeasurePayload {
            paragraphs: self.paragraphs.as_ptr(),
            paragraph_count: self.paragraphs.len(),
            runs: self.runs.as_ptr(),
            run_count: self.runs.len(),
        }
    }
}

// -------------------------------------------------------------------------------------------
// Installation, typed absence and the host-answered implementation — the same shape
// `font_provider.rs` already proved (S2B).
// -------------------------------------------------------------------------------------------

/// swift: the parts of a live text stack the ported layout decisions ask for. Exactly one
/// primitive today — see `the_port_has_exactly_one_primitive_and_it_is_justified` below for why
/// growing this list is a decision, not a convenience.
pub trait TextMeasurer: Send + Sync {
    /// Builds `resolved` in a column `width_points` wide with unbounded height and no padding
    /// (the ritual `page_band_geometry.rs:230-238` performs today) and reports the used height.
    fn measure(&self, resolved: &ResolvedText, width_points: CGFloat) -> CGFloat;
}

static MEASURER: std::sync::OnceLock<Box<dyn TextMeasurer>> = std::sync::OnceLock::new();

/// Declares the text stack this process measures with. Call once; a second call is ignored
/// rather than swapped, for the same reason `font_provider::install` refuses a second one — two
/// halves of one document measured against different text stacks is worse than either.
pub fn install(measurer: Box<dyn TextMeasurer>) -> bool {
    MEASURER.set(measurer).is_ok()
}

/// Why `try_measurer` could not answer: nothing was ever installed on this process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextMeasurerMissing;

impl std::fmt::Display for TextMeasurerMissing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("no TextMeasurer installed — call swiftshim::text_measure::install() first")
    }
}

impl std::error::Error for TextMeasurerMissing {}

/// The installed measurer, as a typed absence rather than a panic — the entry point a caller
/// that must not panic across an FFI boundary uses, exactly as `font_provider::try_provider`
/// documents for its own callers.
pub fn try_measurer() -> Result<&'static dyn TextMeasurer, TextMeasurerMissing> {
    MEASURER.get().map(|b| b.as_ref()).ok_or(TextMeasurerMissing)
}

/// Whether a measurer has been installed, for callers that must not panic (probes, tests).
pub fn is_installed() -> bool {
    MEASURER.get().is_some()
}

/// The one primitive, as C function pointers.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextMeasureCallbacks {
    /// swift: build `payload` at `width_points` with unbounded height and no padding, ensure
    /// layout, and return the used rect's height. `payload` is borrowed for the duration of this
    /// call only — see this module's header for the full ownership rule.
    pub measure: extern "C" fn(payload: *const TextMeasurePayload, width_points: CGFloat) -> CGFloat,
}

// SAFETY: the callback is a plain function pointer into host code that must itself be safe to
// call from any thread (documented on `install_callbacks`), and this struct holds no state of
// its own.
unsafe impl Send for TextMeasureCallbacks {}
unsafe impl Sync for TextMeasureCallbacks {}

struct CallbackMeasurer(TextMeasureCallbacks);

impl TextMeasurer for CallbackMeasurer {
    fn measure(&self, resolved: &ResolvedText, width_points: CGFloat) -> CGFloat {
        let owned = OwnedPayload::build(resolved);
        let payload = owned.as_ffi();
        // `owned` outlives this call (it is not dropped until this function returns), which is
        // what makes every pointer inside `payload` valid for the callback's duration.
        (self.0.measure)(&payload as *const TextMeasurePayload, width_points)
    }
}

/// Installs a host-answered measurer. Same one-shot rule as `install`.
///
/// # Safety
/// `callbacks.measure` must remain valid for the life of the process and must be safe to call
/// from any thread; it may itself call back into a guarded export (`ffi_guard::contain`'s
/// save/restore is what makes that re-entrant call safe, the same hazard the font provider's
/// callback already introduced).
pub fn install_callbacks(callbacks: TextMeasureCallbacks) -> bool {
    install(Box::new(CallbackMeasurer(callbacks)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attributed_string::{NSAttributedStringKey, NSMutableAttributedString};
    use crate::color_font::NSFontDescriptorSymbolicTraits;
    use crate::drawing_misc::{NSTextAttachment, SizedAttachmentCell};
    use crate::geometry::NSSize;
    use crate::paragraph_style::NSTextTab;
    use std::cell::RefCell;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn text_font(family: &str, size: CGFloat, bold: bool) -> NSFont {
        let mut traits = NSFontDescriptorSymbolicTraits::empty();
        if bold {
            traits.insert(NSFontDescriptorSymbolicTraits::bold);
        }
        NSFont::for_metrics_test_with_traits(family, family, size, traits)
    }

    /// Builds the shape `office_text_builder.rs` produces for one paragraph: a `ParagraphStyle`
    /// run over the whole paragraph, then a `Font` run per span of text. Local, not a copy of
    /// the builder itself — this is the CONTRACT `from_attributed_string` reads, not its
    /// implementation.
    fn attributed_paragraph(style: NSParagraphStyle, spans: &[(&str, NSFont)]) -> NSMutableAttributedString {
        let mut result = NSMutableAttributedString::new();
        for (text, font) in spans {
            let start = result.length();
            result.append(&NSAttributedString::new(*text));
            let range = NSRange::new(start, text.encode_utf16().count());
            result.addAttribute(NSAttributedStringKey::Font, AttrValue::Font(font.clone()), range);
        }
        let whole = NSRange::new(0, result.length());
        result.addAttribute(
            NSAttributedStringKey::ParagraphStyle,
            AttrValue::ParagraphStyle(style),
            whole,
        );
        result
    }

    fn body_style() -> NSParagraphStyle {
        NSParagraphStyle {
            alignment: NSTextAlignment::Left,
            lineSpacing: 2.0,
            paragraphSpacingBefore: 4.0,
            paragraphSpacing: 6.0,
            tabStops: vec![NSTextTab::new(NSTextAlignment::Right, 120.0, Default::default())],
            ..NSParagraphStyle::default()
        }
    }

    #[test]
    fn from_attributed_string_flattens_paragraph_style_and_run_fonts() {
        let attr = attributed_paragraph(
            body_style(),
            &[("hello ", text_font("Helvetica", 12.0, false)), ("world", text_font("Helvetica-Bold", 12.0, true))],
        );
        let resolved = ResolvedText::from_attributed_string(attr.asAttributedString()).expect("resolves");
        assert_eq!(resolved.paragraphs.len(), 1);
        let paragraph = &resolved.paragraphs[0];
        assert_eq!(paragraph.line_spacing, 2.0);
        assert_eq!(paragraph.spacing_before, 4.0);
        assert_eq!(paragraph.spacing_after, 6.0);
        assert_eq!(paragraph.tab_stops.len(), 1);
        assert_eq!(paragraph.tab_stops[0].location, 120.0);
        assert_eq!(paragraph.tab_stops[0].alignment, NSTextAlignment::Right);
        assert_eq!(paragraph.runs.len(), 2);
        match &paragraph.runs[0] {
            ResolvedRun::Text { font_name, size, bold, text, .. } => {
                assert_eq!(font_name, "Helvetica");
                assert_eq!(*size, 12.0);
                assert!(!bold);
                assert_eq!(text, "hello ");
            }
            other => panic!("expected a text run, got {other:?}"),
        }
        match &paragraph.runs[1] {
            ResolvedRun::Text { bold, text, .. } => {
                assert!(*bold, "the second span's font carries the bold trait");
                assert_eq!(text, "world");
            }
            other => panic!("expected a text run, got {other:?}"),
        }
    }

    #[test]
    fn a_third_case_carries_an_attachment_and_its_reserved_size_survives() {
        let mut result = NSMutableAttributedString::new();
        result.append(&NSAttributedString::new("caption "));
        let font_range = NSRange::new(0, "caption ".encode_utf16().count());
        result.addAttribute(
            NSAttributedStringKey::Font,
            AttrValue::Font(text_font("Helvetica", 12.0, false)),
            font_range,
        );
        let mut attachment = NSTextAttachment::new();
        attachment.attachmentCell = Some(SizedAttachmentCell::new(NSSize::new(64.0, 32.0)));
        let attachment_start = result.length();
        result.append(&NSMutableAttributedString::with_attachment(attachment).asAttributedString().clone());
        let whole = NSRange::new(0, result.length());
        result.addAttribute(
            NSAttributedStringKey::ParagraphStyle,
            AttrValue::ParagraphStyle(body_style()),
            whole,
        );

        let resolved = ResolvedText::from_attributed_string(result.asAttributedString()).expect("resolves");
        let runs = &resolved.paragraphs[0].runs;
        assert_eq!(runs.len(), 2, "one text run and one attachment run");
        assert!(attachment_start > 0);
        match &runs[1] {
            ResolvedRun::Attachment { width, height } => {
                assert_eq!(*width, 64.0);
                assert_eq!(*height, 32.0);
            }
            other => panic!("expected an attachment run, got {other:?}"),
        }
    }

    /// The regression `RustEngineBridgeTests` (Swift, `FMD_RUST_ENGINE=1`) found the moment the
    /// live cross-process call was wired up: `office_text_builder.rs` applies the paragraph's
    /// `Font` attribute to its own terminating "\n" (the same convention
    /// `RustEngineMeasure.swift`'s `makePayload` documents for the Swift-built case), which this
    /// binding does not auto-merge into the preceding text run — it arrives as ITS OWN separate
    /// run whose text is the single character "\n". Left uncut, that run crossed the port as
    /// literal text and `RustEngineMeasure.measure` then appended its own synthetic "\n" on top
    /// of it: two terminators for one paragraph, a whole extra line, in every real header this
    /// port ever measured.
    #[test]
    fn the_paragraphs_own_terminator_run_is_never_carried_across_as_run_text() {
        let font = text_font("Helvetica", 12.0, false);
        let attr = attributed_paragraph(body_style(), &[("RUNNING HEADER", font.clone()), ("\n", font)]);
        let resolved = ResolvedText::from_attributed_string(attr.asAttributedString()).expect("resolves");
        assert_eq!(resolved.paragraphs.len(), 1);
        let runs = &resolved.paragraphs[0].runs;
        assert_eq!(runs.len(), 1, "the terminator's own run must not cross the port at all");
        match &runs[0] {
            ResolvedRun::Text { text, .. } => assert_eq!(text, "RUNNING HEADER", "no trailing \\n in the run text"),
            other => panic!("expected a text run, got {other:?}"),
        }
    }

    #[test]
    fn an_attachment_with_no_reserved_size_is_a_typed_refusal_not_a_guess() {
        let mut result = NSMutableAttributedString::new();
        let attachment = NSTextAttachment::new(); // no attachmentCell — size unknown
        result.append(&NSMutableAttributedString::with_attachment(attachment).asAttributedString().clone());
        let whole = NSRange::new(0, result.length());
        result.addAttribute(
            NSAttributedStringKey::ParagraphStyle,
            AttrValue::ParagraphStyle(body_style()),
            whole,
        );

        let outcome = ResolvedText::from_attributed_string(result.asAttributedString());
        assert_eq!(outcome, Err(ResolveError::UnresolvedAttachmentSize));
    }

    /// S5-01: the port is what the ported code ACTUALLY calls, not what would be convenient. One
    /// primitive today, each one named with the decision that needs it — adding a variant here
    /// without a real call site is the growth S5's pre-mortem warns against.
    #[test]
    fn the_port_has_exactly_one_primitive_and_it_is_justified() {
        enum PortPrimitive {
            Measure,
        }
        impl PortPrimitive {
            fn justification(&self) -> &'static str {
                match self {
                    // S5B wires this call site; page_band_geometry.rs's design note records that
                    // the table gaps (table_block_builder.rs:334,1111) need a DIFFERENT surface
                    // — enumerateAttribute over LIVE storage — so they are not a call site here.
                    Self::Measure => "the running-header band height, page_band_geometry.rs:225-240",
                }
            }
        }
        let primitives = [PortPrimitive::Measure];
        assert_eq!(primitives.len(), 1, "the port grew — add its call site, not just this count");
        for primitive in &primitives {
            assert!(!primitive.justification().is_empty());
        }
    }

    /// `(paragraph_index, kind, bold, family, text)` for one recorded run.
    type SeenRun = (usize, usize, bool, String, String);

    thread_local! {
        static SEEN: RefCell<Vec<SeenRun>> = const { RefCell::new(Vec::new()) };
        static SEEN_PARAGRAPHS: RefCell<usize> = const { RefCell::new(0) };
    }
    static CALL_COUNT: AtomicUsize = AtomicUsize::new(0);

    /// Reads every field the payload carries and records a summary the test can assert on —
    /// proving the round trip rather than assuming the C struct's memory layout is honoured.
    extern "C" fn recording_measure(payload: *const TextMeasurePayload, width_points: CGFloat) -> CGFloat {
        CALL_COUNT.fetch_add(1, Ordering::SeqCst);
        // SAFETY: `payload` is valid for the duration of this call, per this module's ownership
        // rule, and the test that installs this callback upholds it.
        let payload = unsafe { &*payload };
        SEEN_PARAGRAPHS.with(|slot| *slot.borrow_mut() = payload.paragraph_count);
        SEEN.with(|slot| {
            let mut seen = slot.borrow_mut();
            seen.clear();
            let runs = unsafe { std::slice::from_raw_parts(payload.runs, payload.run_count) };
            for run in runs {
                let (family, text) = if run.kind == TextMeasureRunKind::Text {
                    let family = unsafe { std::ffi::CStr::from_ptr(run.font_name) }.to_str().unwrap().to_string();
                    let text = unsafe { std::ffi::CStr::from_ptr(run.text) }.to_str().unwrap().to_string();
                    (family, text)
                } else {
                    (String::new(), String::new())
                };
                seen.push((run.paragraph_index, run.kind as usize, run.bold, family, text));
            }
        });
        // A deterministic function of the payload, so the test can tell whether it read THIS
        // call's data rather than a stale one: width times the run count, plus the paragraph
        // count.
        width_points * payload.run_count as CGFloat + payload.paragraph_count as CGFloat
    }

    extern "C" fn other_measure(_payload: *const TextMeasurePayload, _width_points: CGFloat) -> CGFloat {
        -1.0 // a value `recording_measure` never returns, so a swap would be unmistakable.
    }

    /// S5-02 end to end: absence before install, installation, the payload's round trip, a
    /// second installation being ignored, and repeated calls neither leaking nor corrupting the
    /// borrowed pointers. One test, not several, because `MEASURER` is a process-global
    /// `OnceLock` shared by every test in this binary — see `font_provider.rs`'s own single-test
    /// precedent for why.
    #[test]
    fn install_once_then_measure_round_trips_and_repeats_safely() {
        assert!(
            !is_installed(),
            "a prior test in this binary already installed a measurer; this test needs a clean slot"
        );
        let missing = match try_measurer() {
            Err(error) => error,
            Ok(_) => panic!("no measurer was installed"),
        };
        assert_eq!(missing, TextMeasurerMissing);
        assert!(missing.to_string().contains("no TextMeasurer installed"));

        let resolved = ResolvedText::from_attributed_string(
            attributed_paragraph(
                body_style(),
                &[("alpha", text_font("Helvetica", 12.0, false)), ("beta", text_font("Helvetica-Bold", 12.0, true))],
            )
            .asAttributedString(),
        )
        .expect("resolves");

        assert!(install_callbacks(TextMeasureCallbacks { measure: recording_measure }));
        assert!(is_installed());

        // A second installation is ignored, not swapped — proven by value, not by inspection:
        // if it had taken, the next call would return `other_measure`'s `-1.0`.
        assert!(!install_callbacks(TextMeasureCallbacks { measure: other_measure }));

        let measurer = try_measurer().expect("installed above");
        for _ in 0..200 {
            let height = measurer.measure(&resolved, 300.0);
            assert_eq!(height, 300.0 * 2.0 + 1.0, "300 width * 2 runs + 1 paragraph, from the FIRST callback");
        }
        assert_eq!(CALL_COUNT.load(Ordering::SeqCst), 200);
        assert_eq!(SEEN_PARAGRAPHS.with(|slot| *slot.borrow()), 1);
        SEEN.with(|slot| {
            let seen = slot.borrow();
            assert_eq!(seen.len(), 2);
            assert_eq!(seen[0], (0, TextMeasureRunKind::Text as usize, false, "Helvetica".to_string(), "alpha".to_string()));
            assert_eq!(seen[1], (0, TextMeasureRunKind::Text as usize, true, "Helvetica-Bold".to_string(), "beta".to_string()));
        });
    }
}
