//! S2B-05: the ownership rule stated in `lib.rs`'s module doc, enforced through the real
//! `extern "C"` symbols — every string this library returns (success OR error envelope) is
//! allocated by Rust, freed exactly once by the caller via `fastdoc_string_free`, and a NULL
//! `fastdoc_string_free` argument is a no-op.
//!
//! Deliberately does NOT exercise a double free or a use-after-free: both are undefined
//! behaviour, and a test that runs UB is not proof of anything — it is a second bug pretending to
//! be a check for the first one. §"Ownership" in `lib.rs`'s module doc is the enforcement for
//! those two cases; this file proves everything that CAN be proven by running it once.

use std::ffi::{c_char, CStr, CString};

// -------------------------------------------------------------------------------------------
// Fixture bytes — the smallest input each shape below needs. `fastdoc_read_office_tree` never
// returns NULL for a document-level failure (S2B-03's contract), which is exactly why it is the
// export these tests exercise: both the "ok" and the "error" envelope come back as owned,
// freeable strings from the SAME function, letting A and B share one call shape.
// -------------------------------------------------------------------------------------------

const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";
const DOCX_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>FastDoc ownership</w:t></w:r></w:p></w:body></w:document>\n";

struct ZipEntry {
    name: &'static str,
    data: &'static [u8],
}

/// Stored-only ZIP — same layout `office_tree_ffi.rs::build_stored_zip` uses (that file and
/// `office_reader_reachability.rs` are the authority for why each field has its value);
/// duplicated because integration test binaries in different crates cannot share a `tests/`
/// helper module.
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

/// A well-formed ZIP with none of the office extensions this library understands — the cheapest
/// way to make `fastdoc_read_office_tree` take its `error` branch without touching a real reader.
fn unsupported_extension_bytes() -> Vec<u8> {
    docx_zip_bytes()
}

// -------------------------------------------------------------------------------------------
// A. success path — allocate then free
// -------------------------------------------------------------------------------------------

#[test]
fn ok_envelope_is_allocated_by_rust_and_freed_by_fastdoc_string_free() {
    let bytes = docx_zip_bytes();
    let extension = CString::new("docx").unwrap();

    let ptr = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_tree(bytes.as_ptr(), bytes.len(), extension.as_ptr())
    };
    assert!(!ptr.is_null(), "a valid docx must not return NULL");

    let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    assert!(text.contains("\"ok\":"), "expected an ok envelope: {text}");

    // Freed exactly once. Reading `ptr` again after this point would be use-after-free, which is
    // exactly what this test does not do — see the module doc for why.
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
}

// -------------------------------------------------------------------------------------------
// B. failure path is owned too — the error envelope is not exempt from being freed
// -------------------------------------------------------------------------------------------

#[test]
fn error_envelope_is_also_allocated_by_rust_and_must_be_freed() {
    let bytes = unsupported_extension_bytes();
    let extension = CString::new("xyz").unwrap(); // not a format this library reads

    let ptr = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_tree(bytes.as_ptr(), bytes.len(), extension.as_ptr())
    };
    assert!(
        !ptr.is_null(),
        "fastdoc_read_office_tree never returns NULL for a document-level failure (S2B-03)"
    );

    let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    assert!(text.contains("\"error\":"), "expected an error envelope: {text}");
    assert!(!text.contains("\"ok\":"), "an error envelope must not also carry \"ok\": {text}");

    // The failure is a VALUE, not a reason to skip freeing it.
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
}

// -------------------------------------------------------------------------------------------
// C. NULL is a no-op, not undefined behaviour
// -------------------------------------------------------------------------------------------

#[test]
fn fastdoc_string_free_of_null_does_nothing() {
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(std::ptr::null_mut::<c_char>()) };
    // Reaching this line without aborting/crashing IS the assertion — a NULL argument must be
    // safe to pass, since that is exactly what a caller reading a genuine-absence NULL from
    // `fastdoc_extract_markdown`/`fastdoc_read_office_json`/`fastdoc_take_last_error` would do if
    // it always calls free defensively.
}

// -------------------------------------------------------------------------------------------
// D. repeated allocate/free is safe across many calls — not a leak measurement (out of scope),
//    a check that the free path itself stays correct under repetition.
// -------------------------------------------------------------------------------------------

#[test]
fn repeated_allocate_and_free_stays_safe_across_many_calls() {
    let bytes = docx_zip_bytes();
    let extension = CString::new("docx").unwrap();

    for _ in 0..50 {
        let ptr = unsafe {
            fastdoc_engine_ffi::fastdoc_read_office_tree(bytes.as_ptr(), bytes.len(), extension.as_ptr())
        };
        assert!(!ptr.is_null());
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert!(text.contains("\"ok\":"));
        unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    }
}

// -------------------------------------------------------------------------------------------
// E. fastdoc_take_last_error's result is owned under the same rule
// -------------------------------------------------------------------------------------------

#[test]
fn take_last_error_result_is_also_freed_with_fastdoc_string_free() {
    // `fastdoc_extract_markdown` records a diagnostic on failure (see its doc comment in
    // `lib.rs`) — an unsupported extension is the cheapest way to populate the slot.
    let bytes = unsupported_extension_bytes();
    let extension = CString::new("xyz").unwrap();

    let markdown_ptr = unsafe {
        fastdoc_engine_ffi::fastdoc_extract_markdown(bytes.as_ptr(), bytes.len(), extension.as_ptr())
    };
    assert!(markdown_ptr.is_null(), "an unsupported extension must fail to extract markdown");

    let error_ptr = fastdoc_engine_ffi::fastdoc_take_last_error();
    assert!(!error_ptr.is_null(), "a failure must leave a diagnostic for fastdoc_take_last_error");

    let text = unsafe { CStr::from_ptr(error_ptr) }.to_str().unwrap().to_owned();
    assert!(!text.is_empty());

    unsafe { fastdoc_engine_ffi::fastdoc_string_free(error_ptr) };
}
