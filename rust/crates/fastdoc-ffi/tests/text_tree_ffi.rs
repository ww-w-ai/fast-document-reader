//! `fastdoc_read_text_tree`'s FFI contract, exercised through the real `extern "C"` export.
//!
//! Markdown is the format this app is named for and, until this export existed, the only one the
//! host read entirely by itself: `render::markdown::produce` has had parity tests since S3 and no
//! door out of the crate. Everything here is about that door — the envelope shape, who owns the
//! string, and the extension fork — not about markdown parsing, which the engine's own
//! `markdown_*` tests already cover.

use std::ffi::{CStr, CString};

// Through the crate, the way `office_tree_ffi.rs` reaches its own export: these ARE the
// `#[no_mangle] extern "C"` functions, and a bare `extern "C"` block would not link here because
// an integration test binary does not link the cdylib.
use fastdoc_engine_ffi::{fastdoc_read_text_tree, fastdoc_string_free};

/// Call the symbol and hand back the envelope as a `String`, freeing the library's copy.
fn read(source: &[u8], extension: &str) -> String {
    let ext = CString::new(extension).expect("extension has no interior NUL");
    unsafe {
        let raw = fastdoc_read_text_tree(source.as_ptr(), source.len(), ext.as_ptr());
        assert!(
            !raw.is_null(),
            "NULL is reserved for an envelope that could not be built at all"
        );
        let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
        fastdoc_string_free(raw);
        text
    }
}

#[test]
fn markdown_crosses_as_the_same_envelope_an_office_document_does() {
    let envelope = read(b"# Title\n\nA paragraph with **bold**.\n", "md");
    assert!(
        envelope.contains("\"ffiVersion\":1"),
        "the envelope must version itself: {envelope}"
    );
    assert!(
        envelope.contains("\"ok\""),
        "a readable markdown file must produce the ok half: {envelope}"
    );
    assert!(
        envelope.contains("\"schemaVersion\""),
        "the tree inside carries its own version, separate from ffiVersion: {envelope}"
    );
    // The vocabulary is the CANONICAL one, not a markdown-shaped side channel.
    for tag in ["\"heading\"", "\"paragraph\"", "\"textRun\""] {
        assert!(envelope.contains(tag), "expected {tag} in: {envelope}");
    }
}

#[test]
fn plain_text_takes_the_same_door() {
    let envelope = read(b"just some text\nsecond line\n", "txt");
    assert!(envelope.contains("\"ok\""), "{envelope}");
    assert!(envelope.contains("\"schemaVersion\""), "{envelope}");
}

/// The fork must REFUSE what neither producer claims. Reading a `.docx` as plain text would
/// succeed and hand back a page of zip bytes, which is worse than an error because it looks like
/// a document.
#[test]
fn an_office_extension_is_refused_rather_than_read_as_text() {
    let envelope = read(b"PK\x03\x04not really a zip", "docx");
    assert!(
        envelope.contains("\"error\"") && envelope.contains("unsupportedExtension"),
        "expected an unsupportedExtension error envelope, got: {envelope}"
    );
}

/// A failure is a VALUE here, the same as for an office document: the envelope comes back, owned,
/// with the reason inside it. This is the rule `fastdoc_extract_markdown` does NOT follow (it
/// returns NULL and records the reason separately), and the two must not be conflated.
#[test]
fn a_document_level_failure_is_an_envelope_not_a_null() {
    let envelope = read(&[0xff, 0xfe, 0xfd], "md");
    assert!(
        envelope.contains("\"error\""),
        "invalid UTF-8 must come back as an error envelope: {envelope}"
    );
    assert!(
        envelope.contains("readerFailed"),
        "and it must name the producer that refused it: {envelope}"
    );
}

/// A NULL argument is caught before anything is dereferenced.
#[test]
fn a_null_argument_is_an_envelope_too() {
    let ext = CString::new("md").unwrap();
    let envelope = unsafe {
        let raw = fastdoc_read_text_tree(std::ptr::null(), 0, ext.as_ptr());
        assert!(!raw.is_null());
        let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
        fastdoc_string_free(raw);
        text
    };
    assert!(envelope.contains("invalidArgument"), "{envelope}");
}
