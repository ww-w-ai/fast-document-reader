//! S5C1-01: the opaque document handle's ABI contract, exercised through the real `extern "C"`
//! symbols (not the crate's private Rust functions) — `office_tree_ffi.rs`'s own reasoning for why
//! that matters applies here unchanged.
//!
//! Fixture: a docx built the same byte-for-byte way `office_tree_ffi.rs` builds one (stored-only
//! ZIP, same `ZIP_XML` payloads) — duplicated rather than imported because integration test
//! binaries in different crates (and different files within the same `tests/` directory) cannot
//! share a `tests/` helper.

use std::ffi::CString;

// -------------------------------------------------------------------------------------------
// Fixture bytes — see office_tree_ffi.rs for the recipe this reproduces.
// -------------------------------------------------------------------------------------------

const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";
const DOCX_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>FastDoc baseline</w:t></w:r></w:p></w:body></w:document>\n";

struct ZipEntry {
    name: &'static str,
    data: &'static [u8],
}

fn build_stored_zip(entries: &[ZipEntry]) -> Vec<u8> {
    const LOCAL_FILE_HEADER_SIG: u32 = 0x0403_4b50;
    const CENTRAL_DIRECTORY_SIG: u32 = 0x0201_4b50;
    const END_OF_CENTRAL_DIRECTORY_SIG: u32 = 0x0605_4b50;
    const DOS_DATE_1980_01_01: u16 = 0x0021;
    const DOS_TIME_MIDNIGHT: u16 = 0x0000;
    const VERSION_NEEDED: u16 = 20;
    const VERSION_MADE_BY: u16 = (3u16 << 8) | 20;
    const EXTERNAL_ATTR_0100644: u32 = 0o100644 << 16;

    let mut body = Vec::new();
    let mut central = Vec::new();

    for entry in entries {
        let name = entry.name.as_bytes();
        let data = entry.data;
        let crc = crc32(data);
        let offset = body.len() as u32;

        body.extend_from_slice(&LOCAL_FILE_HEADER_SIG.to_le_bytes());
        body.extend_from_slice(&VERSION_NEEDED.to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes());
        body.extend_from_slice(&DOS_TIME_MIDNIGHT.to_le_bytes());
        body.extend_from_slice(&DOS_DATE_1980_01_01.to_le_bytes());
        body.extend_from_slice(&crc.to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&(name.len() as u16).to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes());
        body.extend_from_slice(name);
        body.extend_from_slice(data);

        central.extend_from_slice(&CENTRAL_DIRECTORY_SIG.to_le_bytes());
        central.extend_from_slice(&VERSION_MADE_BY.to_le_bytes());
        central.extend_from_slice(&VERSION_NEEDED.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&DOS_TIME_MIDNIGHT.to_le_bytes());
        central.extend_from_slice(&DOS_DATE_1980_01_01.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&EXTERNAL_ATTR_0100644.to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name);
    }

    let central_offset = body.len() as u32;
    let central_size = central.len() as u32;
    let mut out = body;
    out.extend_from_slice(&central);
    out.extend_from_slice(&END_OF_CENTRAL_DIRECTORY_SIG.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn docx_zip_bytes() -> Vec<u8> {
    let mut entries = vec![
        ZipEntry { name: "[Content_Types].xml", data: DOCX_CONTENT_TYPES.as_bytes() },
        ZipEntry { name: "_rels/.rels", data: DOCX_RELS.as_bytes() },
        ZipEntry { name: "word/document.xml", data: DOCX_DOCUMENT_XML.as_bytes() },
    ];
    entries.sort_by_key(|e| e.name);
    build_stored_zip(&entries)
}

/// Reads `fastdoc_take_last_error`'s `"kind"` field, freeing the diagnostic afterward — the same
/// ownership rule every other export in this crate already follows.
fn last_error_kind() -> Option<String> {
    let ptr = fastdoc_engine_ffi::fastdoc_take_last_error();
    if ptr.is_null() {
        return None;
    }
    // SAFETY: `ptr` came from this library, is NUL-terminated, and is freed exactly once below.
    let text = unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    value.get("kind")?.as_str().map(str::to_owned)
}

// -------------------------------------------------------------------------------------------
// S5C1-01: open/close round-trips.
// -------------------------------------------------------------------------------------------

/// A document the engine CAN read: open returns non-NULL, and close does not crash or leak
/// (Miri/ASan are not wired into this suite, so "does not crash" is what a `cargo test` run can
/// prove; the ownership shape itself — box-in, box-out, one drop — is what `ffi_ownership.rs`'s
/// existing string-pointer tests already establish for this crate's other owned resource).
#[test]
fn open_of_a_readable_document_round_trips_with_close() {
    let data = docx_zip_bytes();
    let extension = CString::new("docx").unwrap();
    // SAFETY: `data` and `extension` are valid, NUL-terminated where required, and outlive the
    // call.
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr())
    };
    assert!(!handle.is_null(), "a real docx must open");
    // SAFETY: `handle` is a live pointer this call just returned, closed exactly once.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}

/// A document the engine CANNOT read: open returns NULL and names WHY, rather than a handle to
/// nothing. `fastdoc_office_open` must never hand back a pointer worth calling `fastdoc_office_close`
/// on for bytes that never parsed.
#[test]
fn open_of_garbage_returns_null_with_a_named_error_kind() {
    let data = b"not a zip archive at all".to_vec();
    let extension = CString::new("docx").unwrap();
    // SAFETY: `data` and `extension` are valid for the duration of the call.
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr())
    };
    assert!(handle.is_null(), "garbage bytes must not open");
    let kind = last_error_kind();
    assert_eq!(kind.as_deref(), Some("invalidArchive"), "{kind:?}");
}

/// `fastdoc_office_close(NULL)` must be a no-op, matching this crate's existing
/// `fastdoc_string_free(NULL)` rule — a caller that closes defensively without branching on NULL
/// first must be safe.
#[test]
fn close_of_null_is_a_no_op() {
    // SAFETY: NULL is an explicitly documented no-op input for this function.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(std::ptr::null_mut()) };
}

// -------------------------------------------------------------------------------------------
// S5C1-02: the band query re-expressed over the handle.
// -------------------------------------------------------------------------------------------

/// The synthetic fixture (`docx_zip_bytes`) declares no `w:sectPr`, so `read_office` returns a
/// document with EMPTY `headers`/`footers` — `PageBandGeometry::measure`'s own empty short-circuit
/// (`page_band_geometry.rs`) answers `Sides{0,0,0}` WITHOUT ever asking the measurement port. This
/// proves the handle's headers/footers actually reach the query (a wrong marshalling would either
/// crash reading a dangling/garbage `Vec` or answer something other than exactly zero) and that
/// `headers_on`/`footers_on` cross the FFI without corrupting the call — in a process where no
/// measurer is EVER installed, so a wrong wiring that accidentally required one would fail loudly
/// rather than silently pass. The measurer-REQUIRED path (a real declared header, a real margin)
/// is proven on the real corpus at the Swift layer (`RustEngineBridgeTests`,
/// `docs/fixtures/office/paged-visual/prosepages.docx`) — this file has no synthetic document with
/// a real header part to exercise that path honestly.
#[test]
fn band_sides_answers_zero_for_a_document_with_no_declared_header_or_footer() {
    let data = docx_zip_bytes();
    let extension = CString::new("docx").unwrap();
    // SAFETY: valid, NUL-terminated where required, outlives the call.
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr())
    };
    assert!(!handle.is_null());

    let mut out = [-999.0_f64; 3];
    // SAFETY: `handle` is live; `out` is a writable 3-element buffer for the call's duration.
    let answered = unsafe {
        fastdoc_engine_ffi::fastdoc_office_band_sides(
            handle, 400.0, 0.0, false, 0.0, false, 0.0, false, true, true, false, 0.0, false,
            out.as_mut_ptr(),
        )
    };
    assert!(answered, "a document with no header/footer must not need a measurer to answer");
    assert_eq!(out, [0.0, 0.0, 0.0], "no declared header or footer must reserve nothing");

    // SAFETY: closed exactly once.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}

/// `separates_pages`/`desk_gap` must actually cross the FFI, not just the header/footer entries:
/// a document with NEITHER declared still gets a non-zero band in outline mode, because two
/// stacked sheets need desk space between them even when nothing is drawn in it
/// (`RenderTheme::PAGE_DESK_GAP`). If either parameter were dropped on the way across (this
/// export's own `has_desk_gap`-less predecessor did exactly this by hardcoding `false, None`),
/// this would answer zero and pass — proven wrong only by checking against the SAME arithmetic
/// through the crate directly, not by eyeballing "some positive number".
#[test]
fn band_sides_carries_separates_pages_and_desk_gap_across_the_ffi() {
    let data = docx_zip_bytes();
    let extension = CString::new("docx").unwrap();
    // SAFETY: valid, NUL-terminated where required, outlives the call.
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr())
    };
    assert!(!handle.is_null());

    let mut out = [-999.0_f64; 3];
    // SAFETY: `handle` is live; `out` is a writable 3-element buffer for the call's duration.
    let answered = unsafe {
        fastdoc_engine_ffi::fastdoc_office_band_sides(
            handle, 400.0, 0.0, false, 0.0, false, 0.0, false, true, true, true, 0.0, false,
            out.as_mut_ptr(),
        )
    };
    assert!(answered, "no header/footer still needs no measurer, even in outline mode");
    assert_eq!(out, [0.0, 0.0, fastdoc_engine::render::render_theme::RenderTheme::PAGE_DESK_GAP],
               "outline mode must reserve the desk gap even with nothing else in the band");

    // A caller-supplied desk_gap of 0 (S5C1's own `forPrinting` case) must override the default,
    // not be ignored in favour of it.
    let mut printed = [-999.0_f64; 3];
    let printed_answered = unsafe {
        fastdoc_engine_ffi::fastdoc_office_band_sides(
            handle, 400.0, 0.0, false, 0.0, false, 0.0, false, true, true, true, 0.0, true,
            printed.as_mut_ptr(),
        )
    };
    assert!(printed_answered);
    assert_eq!(printed, [0.0, 0.0, 0.0], "an explicit desk_gap of 0 must be honoured, not defaulted");

    // SAFETY: closed exactly once.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}

/// A NULL handle or NULL `out` must refuse the same way any other invalid-argument case in this
/// crate does — named, not a crash.
#[test]
fn band_sides_refuses_a_null_handle() {
    let mut out = [0.0_f64; 3];
    // SAFETY: NULL handle is an explicitly documented refusal input; `out` is a valid buffer.
    let answered = unsafe {
        fastdoc_engine_ffi::fastdoc_office_band_sides(
            std::ptr::null(), 400.0, 0.0, false, 0.0, false, 0.0, false, true, true, false, 0.0, false,
            out.as_mut_ptr(),
        )
    };
    assert!(!answered);
    assert_eq!(last_error_kind().as_deref(), Some("invalidArgument"));
}

// -------------------------------------------------------------------------------------------
// U3: `fastdoc_office_tree_json` — the canonical-tree export re-expressed over the handle.
// -------------------------------------------------------------------------------------------

/// Calls the real `extern "C"` export and returns the envelope as an owned Rust `String`, after
/// freeing the FFI-owned pointer through `fastdoc_string_free` the same way a real host must —
/// same shape as `office_tree_ffi.rs::call_read_office_tree`, but this export never returns NULL
/// for a document-level failure (only for an unencodable envelope, which none of this file's
/// cases trigger), so unlike that helper this one does not need an `Option`.
fn call_office_tree_json(
    handle: *const fastdoc_engine_ffi::FastdocOfficeDocument,
    bytes: *const u8,
    len: usize,
) -> String {
    // SAFETY: caller-supplied `handle`/`bytes`/`len` describe a call this file's own tests make
    // with either a live handle and its own bytes, or a deliberately NULL argument the export
    // documents as a defined, checked case.
    let ptr = unsafe { fastdoc_engine_ffi::fastdoc_office_tree_json(handle, bytes, len) };
    assert!(!ptr.is_null(), "this export must return an envelope, never NULL, for these inputs");
    // SAFETY: `ptr` came from this library, is NUL-terminated, and is freed exactly once below.
    let text = unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    text
}

/// Success: an open handle's tree projects to the SAME "ok" envelope shape
/// `fastdoc_read_office_tree` returns for the identical bytes — this export is a second
/// projection of the handle's already-parsed model, not a different tree.
#[test]
fn tree_json_returns_an_ok_envelope_matching_read_office_tree_for_the_same_bytes() {
    let data = docx_zip_bytes();
    let extension = CString::new("docx").unwrap();
    // SAFETY: valid, NUL-terminated where required, outlives the call.
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr())
    };
    assert!(!handle.is_null());

    let via_handle = call_office_tree_json(handle, data.as_ptr(), data.len());
    // SAFETY: `data`/`extension` outlive this call.
    let via_fresh_read = unsafe {
        let ptr = fastdoc_engine_ffi::fastdoc_read_office_tree(data.as_ptr(), data.len(), extension.as_ptr());
        assert!(!ptr.is_null());
        let text = std::ffi::CStr::from_ptr(ptr).to_str().unwrap().to_owned();
        fastdoc_engine_ffi::fastdoc_string_free(ptr);
        text
    };

    let via_handle_json: serde_json::Value = serde_json::from_str(&via_handle).expect("envelope is JSON");
    let via_fresh_json: serde_json::Value = serde_json::from_str(&via_fresh_read).expect("envelope is JSON");
    assert!(via_handle_json.get("ok").is_some(), "{via_handle}");
    assert!(via_handle_json.get("error").is_none(), "{via_handle}");
    assert_eq!(via_handle_json, via_fresh_json, "the handle's second projection must match a fresh read byte for byte");

    // SAFETY: closed exactly once.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}

/// A NULL handle refuses with the same `{"ffiVersion":1,"error":{"kind":"invalidArgument",...}}`
/// envelope `fastdoc_read_office_tree` uses for its own NULL-argument cases — never NULL, and
/// never `fastdoc_take_last_error`, matching this export's documented ownership rule.
#[test]
fn tree_json_refuses_a_null_handle_with_an_error_envelope() {
    let data = docx_zip_bytes();
    let envelope = call_office_tree_json(std::ptr::null(), data.as_ptr(), data.len());
    let parsed: serde_json::Value = serde_json::from_str(&envelope).expect("envelope is JSON");
    assert_eq!(parsed["ffiVersion"], 1);
    assert!(parsed.get("ok").is_none(), "an error envelope must not also carry \"ok\": {envelope}");
    assert_eq!(parsed["error"]["kind"], "invalidArgument", "{envelope}");
}

/// A closed handle is documented as undefined behaviour to query — this proves the OTHER
/// documented invalid-argument case instead: a live handle with NULL `bytes`, which this export
/// must refuse.
#[test]
fn tree_json_refuses_null_bytes_on_an_otherwise_live_handle_with_an_error_envelope() {
    let data = docx_zip_bytes();
    let extension = CString::new("docx").unwrap();
    // SAFETY: valid, NUL-terminated where required, outlives the call.
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr())
    };
    assert!(!handle.is_null());

    let envelope = call_office_tree_json(handle, std::ptr::null(), 0);
    let parsed: serde_json::Value = serde_json::from_str(&envelope).expect("envelope is JSON");
    assert!(parsed.get("ok").is_none(), "an error envelope must not also carry \"ok\": {envelope}");
    assert_eq!(parsed["error"]["kind"], "invalidArgument", "{envelope}");

    // SAFETY: closed exactly once.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}
