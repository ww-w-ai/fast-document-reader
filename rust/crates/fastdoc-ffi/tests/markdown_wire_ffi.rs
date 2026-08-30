//! `fastdoc_render_markdown`'s FFI contract, exercised through the real `extern "C"` export.
//!
//! `markdown_wire_projection.rs` (in the engine) already proves the wire's SHAPE — columns line
//! up, pools collapse, a table's cells all point at one table, the JSON round-trips. None of that
//! says a host can reach it. This file is about the DOOR: that the symbol exists, that it wraps
//! the wire in the same `{"ffiVersion":1,"ok":…}` envelope every other export uses, that the
//! caller owns the string, and that the three ways to call it wrongly come back as values rather
//! than as a crash.
//!
//! Invariant 29's rule, in FFI form: a mechanism test does not prove a caller can get there.

use std::ffi::{CStr, CString};

use swiftshim::font_provider::{FaceId, FaceInfo, FontProvider};
use swiftshim::{NSFontDescriptorSymbolicTraits, NSFontWeight};

use fastdoc_engine_ffi::{fastdoc_render_markdown, fastdoc_string_free};

/// Present and consistent, never realistic — the same stand-in `engine_stage_cost` installs. The
/// renderer asks for faces while it builds, and without a provider it panics; which glyphs come
/// back does not change the wire's shape, only the numbers inside a `WireFont`.
struct FakeFontProvider;

impl FontProvider for FakeFontProvider {
    fn face_named(&self, _name: &str) -> Option<FaceId> { Some(FaceId(1)) }
    fn resolve(&self, _descriptor: &swiftshim::color_font::NSFontDescriptor) -> Option<FaceId> {
        Some(FaceId(1))
    }
    fn system_face(&self, _weight: NSFontWeight, _monospaced: bool) -> FaceId { FaceId(1) }
    fn describe(&self, _face: FaceId) -> FaceInfo {
        FaceInfo {
            name: "Helvetica".to_string(),
            family: Some("Helvetica".to_string()),
            traits: NSFontDescriptorSymbolicTraits::empty(),
        }
    }
    fn covers(&self, _face: FaceId, _scalar: u32) -> bool { true }
    fn substitute(&self, _declared: FaceId, _scalar: u32) -> Option<FaceId> { None }
}

fn with_fonts() {
    if !swiftshim::font_provider::is_installed() {
        swiftshim::font_provider::install(Box::new(FakeFontProvider));
    }
}

/// Call the symbol and hand back the envelope as a `String`, freeing the library's copy.
fn render(source: &[u8], base_font_size: f64) -> String {
    with_fonts();
    unsafe {
        let raw = fastdoc_render_markdown(source.as_ptr(), source.len(), base_font_size);
        assert!(
            !raw.is_null(),
            "NULL is reserved for an envelope that could not be built at all"
        );
        let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
        fastdoc_string_free(raw);
        text
    }
}

/// The ok half, parsed as the wire the engine writes. Decoding it HERE, with the engine's own
/// type, is what proves the two sides agree — a `contains("\"v\":1")` would pass on a wire whose
/// columns had silently changed name.
fn wire_of(envelope: &str) -> fastdoc_engine::render::markdown_wire::MarkdownWire {
    let value: serde_json::Value =
        serde_json::from_str(envelope).unwrap_or_else(|e| panic!("envelope is JSON: {e}: {envelope}"));
    assert_eq!(value["ffiVersion"], 1, "the envelope versions itself: {envelope}");
    let ok = value.get("ok").unwrap_or_else(|| panic!("expected an ok half: {envelope}"));
    serde_json::from_value(ok.clone()).expect("the ok half IS a MarkdownWire")
}

#[test]
fn a_rendered_document_crosses_as_the_wire_the_engine_writes() {
    let envelope = render(b"# Title\n\nA paragraph with **bold** and a [link](https://ww-w.ai).\n", 16.0);
    let wire = wire_of(&envelope);

    assert_eq!(
        wire.v,
        fastdoc_engine::render::markdown_wire::MARKDOWN_WIRE_VERSION,
        "the wire carries its OWN version, separate from ffiVersion"
    );
    assert!(wire.text.contains("Title"), "the text made the crossing: {:?}", wire.text);
    assert!(wire.text.contains("bold"), "so did the emphasised run: {:?}", wire.text);

    // Typography, not structure: this door exists because 86% of a markdown read is the build, so
    // an envelope with text and no attributes would be the office tree by another name.
    assert!(!wire.fonts.is_empty(), "a rendered document names fonts");
    assert!(!wire.paragraph_styles.is_empty(), "and paragraph styles");
    assert!(
        !wire.layer_location.is_empty() && wire.layer_length.len() == wire.layer_location.len(),
        "the layer columns arrive paired"
    );
    assert_eq!(
        wire.link_targets,
        vec!["https://ww-w.ai".to_string()],
        "the link's target crossed as a pooled string"
    );
}

/// The theme is one number, and it must be the caller's number — a door that ignored it would
/// look correct in every shape assertion above and render every document at one size.
#[test]
fn the_base_font_size_the_caller_asks_for_is_the_size_that_crosses() {
    let small = wire_of(&render(b"plain paragraph\n", 12.0));
    let large = wire_of(&render(b"plain paragraph\n", 24.0));

    let biggest = |w: &fastdoc_engine::render::markdown_wire::MarkdownWire| {
        w.fonts.iter().map(|f| f.size).fold(0.0_f64, f64::max)
    };
    assert!(
        biggest(&large) > biggest(&small),
        "24pt must produce larger faces than 12pt: {} vs {}",
        biggest(&large),
        biggest(&small)
    );
}

/// A failure is a VALUE, the same rule `fastdoc_read_text_tree` follows: the envelope comes back,
/// owned, with the reason inside it.
#[test]
fn source_that_is_not_utf8_is_an_envelope_not_a_crash() {
    let envelope = render(&[0xff, 0xfe, 0xfd], 16.0);
    assert!(envelope.contains("\"error\""), "{envelope}");
    assert!(
        envelope.contains("invalidArgument"),
        "and it names the kind: {envelope}"
    );
}

/// The size is the one argument a host can get arbitrarily wrong (an uninitialised preference, a
/// zoom multiplied twice), and a renderer asked for a 0pt or 10,000pt body is not worth running.
#[test]
fn a_base_font_size_outside_the_allowed_range_is_refused() {
    for size in [0.0, -16.0, 1024.0] {
        let envelope = render(b"paragraph\n", size);
        assert!(
            envelope.contains("\"error\"") && envelope.contains("invalidArgument"),
            "base font size {size} must be refused: {envelope}"
        );
    }
}

/// A NULL pointer is caught before anything is dereferenced.
#[test]
fn a_null_argument_is_an_envelope_too() {
    with_fonts();
    let envelope = unsafe {
        let raw = fastdoc_render_markdown(std::ptr::null(), 7, 16.0);
        assert!(!raw.is_null(), "a NULL source still gets an envelope back");
        let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
        fastdoc_string_free(raw);
        text
    };
    assert!(envelope.contains("\"error\""), "{envelope}");
    assert!(envelope.contains("invalidArgument"), "{envelope}");
}

/// An empty document is legal, not an error — a host that opens a new file must get a usable
/// wire, not a diagnostic.
#[test]
fn an_empty_document_renders_to_an_empty_wire_rather_than_an_error() {
    let wire = wire_of(&render(b"", 16.0));
    assert_eq!(wire.text, "", "no text");
    assert!(wire.layer_location.is_empty(), "and no layers to replay");
    let _unused = CString::new("keeps the CString import honest").unwrap();
}

/// The progressive door: open, take pieces, finish, close.
///
/// Front-first paint is the one markdown path that needs STATE across FFI calls — block ids count
/// up across chunks and each chunk's source offsets continue where the last stopped — so what this
/// checks is not that a chunk renders (the whole-document tests above cover that) but that the
/// handle carries the render forward and reports when it is done.
mod progressive {
    use super::*;
    use fastdoc_engine_ffi::{
        fastdoc_markdown_progressive_close, fastdoc_markdown_progressive_is_finished,
        fastdoc_markdown_progressive_next, fastdoc_markdown_progressive_open,
    };

    fn source() -> Vec<u8> {
        (1..=6)
            .map(|n| format!("## Section {n}\n\nParagraph {n} with **bold** text.\n"))
            .collect::<Vec<_>>()
            .join("\n")
            .into_bytes()
    }

    fn chunk(handle: *mut fastdoc_engine_ffi::FastdocMarkdownProgressive, blocks: usize) -> String {
        unsafe {
            let raw = fastdoc_markdown_progressive_next(handle, blocks);
            assert!(!raw.is_null(), "a chunk always comes back as an envelope");
            let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
            fastdoc_string_free(raw);
            text
        }
    }

    #[test]
    fn the_pieces_join_up_to_the_whole_document() {
        with_fonts();
        let bytes = source();
        let whole = wire_of(&render(&bytes, 16.0));

        let handle = unsafe { fastdoc_markdown_progressive_open(bytes.as_ptr(), bytes.len(), 16.0) };
        assert!(!handle.is_null(), "the source is valid, so the handle opens");
        let mut joined = String::new();
        let mut pieces = 0;
        while unsafe { fastdoc_markdown_progressive_is_finished(handle) } == 0 {
            joined.push_str(&wire_of(&chunk(handle, 2)).text);
            pieces += 1;
            assert!(pieces < 100, "the handle must reach finished");
        }
        unsafe { fastdoc_markdown_progressive_close(handle) };

        assert!(pieces > 1, "twelve blocks two at a time is more than one piece, got {pieces}");
        assert_eq!(
            joined, whole.text,
            "the pieces must join up to exactly what one whole render produces"
        );
    }

    /// Block ids must keep counting across pieces. Two neighbouring blocks that share an id read as
    /// ONE stop for the reading cursor (invariant 19), which is precisely what a handle that reset
    /// its builder every call would produce.
    #[test]
    fn block_ids_keep_counting_across_pieces() {
        with_fonts();
        let bytes = source();
        let handle = unsafe { fastdoc_markdown_progressive_open(bytes.as_ptr(), bytes.len(), 16.0) };
        assert!(!handle.is_null());
        let mut ids: Vec<i64> = Vec::new();
        // Bounded, like its sibling above. A handle that never advances turns this loop into a
        // hang rather than a failure, and a test that hangs takes its own cleanup down with it —
        // which is exactly what happened while proving these checks bite.
        let mut pieces = 0;
        while unsafe { fastdoc_markdown_progressive_is_finished(handle) } == 0 {
            pieces += 1;
            assert!(pieces < 100, "the handle must reach finished");
            let wire = wire_of(&chunk(handle, 2));
            for extra in &wire.extras {
                if extra.key == "mdBlockId" {
                    if let fastdoc_engine::render::markdown_wire::WireExtraValue::Int(id) = extra.value {
                        ids.push(id);
                    }
                }
            }
        }
        unsafe { fastdoc_markdown_progressive_close(handle) };

        assert!(ids.len() > 2, "the document has blocks in more than one piece, got {}", ids.len());
        let mut sorted = ids.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), ids.len(), "no two blocks may share an id: {ids:?}");
    }

    /// A NULL handle is a value, not a crash — on both the answer and the render.
    #[test]
    fn a_null_handle_is_refused_rather_than_dereferenced() {
        assert_eq!(
            unsafe { fastdoc_markdown_progressive_is_finished(std::ptr::null()) },
            -1,
            "a negative can never be mistaken for finished or unfinished"
        );
        let envelope = unsafe {
            let raw = fastdoc_markdown_progressive_next(std::ptr::null_mut(), 1);
            assert!(!raw.is_null());
            let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
            fastdoc_string_free(raw);
            text
        };
        assert!(envelope.contains("invalidArgument"), "{envelope}");
        // Closing NULL is a no-op, the same rule `fastdoc_string_free(NULL)` follows.
        unsafe { fastdoc_markdown_progressive_close(std::ptr::null_mut()) };
    }

    /// Source that is not UTF-8 refuses at OPEN rather than on the first chunk — there is no
    /// half-usable handle to hand back.
    #[test]
    fn a_source_that_is_not_utf8_refuses_at_open() {
        with_fonts();
        let bytes = [0xffu8, 0xfe, 0xfd];
        let handle = unsafe { fastdoc_markdown_progressive_open(bytes.as_ptr(), bytes.len(), 16.0) };
        assert!(handle.is_null(), "a handle must not be returned for a source that cannot be read");
    }
}
