//! S2B-03: `fastdoc_read_office_tree`'s FFI contract, exercised through the real `extern "C"`
//! symbols (not the crate's private Rust functions) — a `cargo test` on this file is the only
//! thing in this crate that proves the ABI itself, not just the Rust it wraps.
//!
//! Fixtures: a docx built the same byte-for-byte way
//! `crates/fastdoc-engine/tests/office_reader_reachability.rs` builds one (stored-only ZIP, same
//! `ZIP_XML` payloads), and `Vendor/rhwp-src/saved/blank2010.hwp`, a real vendored HWP — both
//! chosen so this file duplicates as little of that test's machinery as a real ZIP still needs.

use fastdoc_engine::render::office::docx_reader::DocxReader;
use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::office::zip_archive::ZipArchive;
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};

use std::collections::BTreeMap;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;

// -------------------------------------------------------------------------------------------
// Fixture bytes — see `office_reader_reachability.rs` for the recipe these reproduce.
// -------------------------------------------------------------------------------------------

const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";
const DOCX_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>FastDoc baseline</w:t></w:r></w:p></w:body></w:document>\n";

struct ZipEntry {
    name: &'static str,
    data: &'static [u8],
}

/// Stored-only ZIP, identical layout to `office_reader_reachability.rs::build_stored_zip` (that
/// file is the authority for why each field has the value it has); duplicated rather than
/// imported because integration test binaries in different crates cannot share a `tests/` helper.
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

fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(data))
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

/// `Vendor/rhwp-src/saved/<name>`, resolved from `CARGO_MANIFEST_DIR` — this crate is
/// `rust/crates/fastdoc-ffi`, the vendor tree is three levels up at `rust/../Vendor`, same as
/// `office_reader_reachability.rs::rhwp_saved_fixture` resolves it from its own crate dir.
fn rhwp_saved_fixture(name: &str) -> Vec<u8> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../..").join("Vendor/rhwp-src/saved").join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

// -------------------------------------------------------------------------------------------
// FFI call + envelope helpers
// -------------------------------------------------------------------------------------------

/// Calls the real `extern "C"` export and returns the envelope as an owned Rust `String`, after
/// freeing the FFI-owned pointer through `fastdoc_string_free` the same way a real host must.
///
/// # Safety
/// Caller-supplied `data`/`extension` must outlive the call, which they do here (both are local
/// bindings kept alive for the duration of each test body).
fn call_read_office_tree(data: &[u8], extension: &str) -> Option<String> {
    let extension_c = CString::new(extension).unwrap();
    let ptr = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_tree(
            data.as_ptr(),
            data.len(),
            extension_c.as_ptr(),
        )
    };
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    Some(text)
}

/// Calls the export with a raw pointer for `bytes` (letting the caller pass NULL) and a real
/// extension, freeing the result the same way.
unsafe fn call_read_office_tree_raw(bytes: *const u8, len: usize, extension: *const c_char) -> Option<String> {
    let ptr = fastdoc_engine_ffi::fastdoc_read_office_tree(bytes, len, extension);
    if ptr.is_null() {
        return None;
    }
    let text = CStr::from_ptr(ptr).to_str().unwrap().to_owned();
    fastdoc_engine_ffi::fastdoc_string_free(ptr);
    Some(text)
}

/// Splits `{"ffiVersion":1,"ok":<...>}` (or the `error` shape) into the parsed envelope and, for
/// the ok shape, the EXACT raw substring the `ok` key's value occupies in the original text —
/// found by byte offset rather than re-serializing the parsed `Value`, because re-serializing
/// would silently prove the wrong thing (S2B-03's contract is that the tree bytes cross verbatim,
/// which a round-trip through `serde_json::Value` cannot witness).
fn ok_raw_value_bytes(envelope_text: &str) -> Vec<u8> {
    let parsed: serde_json::Value = serde_json::from_str(envelope_text).expect("envelope is JSON");
    assert!(parsed.get("ok").is_some(), "envelope has no \"ok\" key: {envelope_text}");
    assert!(parsed.get("error").is_none(), "an ok envelope must not also carry \"error\": {envelope_text}");
    assert_eq!(parsed["ffiVersion"], 1);

    let key = "\"ok\":";
    let start = envelope_text.find(key).expect("envelope has no ok key text") + key.len();
    // The `ok` value runs from `start` to the closing brace that matches its own opening `{`.
    let rest = &envelope_text.as_bytes()[start..];
    assert_eq!(rest[0], b'{', "the ok value is expected to be a JSON object");
    let mut depth = 0i32;
    let mut end = 0usize;
    for (i, &b) in rest.iter().enumerate() {
        match b {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    end = i + 1;
                    break;
                }
            }
            _ => {}
        }
    }
    assert!(end > 0, "could not find the end of the ok value in: {envelope_text}");
    rest[..end].to_vec()
}

/// The tree this crate's `document_format`/`from_office` call would itself produce for the same
/// bytes/extension — the independent half of the S2B-03 byte-equivalence assertion. Kept in this
/// test file rather than calling into `fastdoc-ffi`'s private functions, since the whole point is
/// two INDEPENDENT constructions of the same tree agreeing byte for byte.
fn expected_tree_json(format: DocumentFormat, extension: &str, bytes: &[u8], result: &fastdoc_engine::render::office::office_block::OfficeReadResult) -> Vec<u8> {
    let source_name = format!("document.{extension}");
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name: &source_name,
        source_bytes: bytes,
        result,
        resources: BTreeMap::new(),
    })
    .expect("from_office must succeed for a valid fixture");
    tree.encode_json().expect("encode_json must succeed for a valid fixture")
}

// -------------------------------------------------------------------------------------------
// A. byte equivalence — the S2B-03 acceptance criterion
// -------------------------------------------------------------------------------------------

#[test]
fn docx_envelope_ok_matches_the_tree_built_directly_byte_for_byte() {
    let bytes = docx_zip_bytes();
    let archive = ZipArchive::new(swiftshim::Data::fromBytes(bytes.clone())).unwrap();
    let result = DocxReader::read(&archive).unwrap();
    let expected = expected_tree_json(DocumentFormat::Docx, "docx", &bytes, &result);

    let envelope = call_read_office_tree(&bytes, "docx").expect("a valid docx must not return NULL");
    let actual = ok_raw_value_bytes(&envelope);

    assert_eq!(actual, expected, "the FFI envelope's \"ok\" bytes diverge from encode_json() built directly");
}

#[test]
fn hwp_envelope_ok_matches_the_tree_built_directly_byte_for_byte() {
    let bytes = rhwp_saved_fixture("blank2010.hwp");
    let data = swiftshim::Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data).unwrap();
    let expected = expected_tree_json(DocumentFormat::Hwp, "hwp", &bytes, &result);

    let envelope = call_read_office_tree(&bytes, "hwp").expect("a valid hwp must not return NULL");
    let actual = ok_raw_value_bytes(&envelope);

    assert_eq!(actual, expected, "the FFI envelope's \"ok\" bytes diverge from encode_json() built directly");
}

// -------------------------------------------------------------------------------------------
// B. the tree is actually from THIS document, not an empty pass-through
// -------------------------------------------------------------------------------------------

#[test]
fn docx_envelope_ties_back_to_the_input_bytes() {
    let bytes = docx_zip_bytes();
    let envelope = call_read_office_tree(&bytes, "docx").unwrap();
    let ok_bytes = ok_raw_value_bytes(&envelope);
    let ok: serde_json::Value = serde_json::from_slice(&ok_bytes).unwrap();

    let sources = ok["sources"].as_array().expect("sources array");
    assert_eq!(sources.len(), 1, "expected exactly one source descriptor, got {sources:?}");
    assert_eq!(
        sources[0]["sha256"].as_str(),
        Some(sha256_hex(&bytes).as_str()),
        "recorded source sha256 does not match the digest of the bytes handed to the FFI call"
    );

    let nodes = ok["nodes"].as_array().expect("nodes array");
    assert!(!nodes.is_empty(), "the ok tree has no nodes — an empty tree round-trips perfectly and proves nothing");

    // Ties the content, not just the count, back to the document's own declared text — a tree
    // that is non-empty but wrong would still pass the two checks above.
    let ok_text = String::from_utf8_lossy(&ok_bytes);
    assert!(ok_text.contains("FastDoc baseline"), "the tree does not contain the docx's own declared text");
}

// -------------------------------------------------------------------------------------------
// C. failure path — an error envelope, never NULL, with the expected kind
// -------------------------------------------------------------------------------------------

#[test]
fn unsupported_extension_returns_an_error_envelope_with_its_kind() {
    let bytes = b"irrelevant bytes";
    let envelope = call_read_office_tree(bytes, "pptx").expect("an error still comes back as an owned string, not NULL");

    let parsed: serde_json::Value = serde_json::from_str(&envelope).expect("error envelope is JSON");
    assert_eq!(parsed["ffiVersion"], 1);
    assert!(parsed.get("ok").is_none(), "an error envelope must not also carry \"ok\": {envelope}");
    assert_eq!(parsed["error"]["kind"], "unsupportedExtension", "{envelope}");
    assert!(parsed["error"]["message"].as_str().unwrap().contains("pptx"), "{envelope}");
}

#[test]
fn corrupt_archive_bytes_return_an_error_envelope_with_its_kind() {
    let bytes = b"this is not a zip file";
    let envelope = call_read_office_tree(bytes, "docx").expect("an error still comes back as an owned string, not NULL");

    let parsed: serde_json::Value = serde_json::from_str(&envelope).expect("error envelope is JSON");
    assert_eq!(parsed["error"]["kind"], "invalidArchive", "{envelope}");
}

#[test]
fn broken_hwp_bytes_return_an_error_envelope_with_its_kind() {
    let bytes = b"not an HWP document";
    let envelope = call_read_office_tree(bytes, "hwp").expect("an error still comes back as an owned string, not NULL");

    let parsed: serde_json::Value = serde_json::from_str(&envelope).expect("error envelope is JSON");
    assert_eq!(parsed["error"]["kind"], "hwpReadFailed", "{envelope}");
}

// -------------------------------------------------------------------------------------------
// D. NULL arguments — defined behaviour, not UB, and still a freeable envelope
// -------------------------------------------------------------------------------------------

#[test]
fn null_bytes_pointer_is_reported_not_undefined() {
    let extension_c = CString::new("docx").unwrap();
    // SAFETY: `fastdoc_read_office_tree` documents NULL `bytes` as a defined, checked case (it
    // is checked before the pointer is ever dereferenced); `len` is arbitrary but unread on this
    // path. `extension_c` outlives the call.
    let envelope = unsafe { call_read_office_tree_raw(std::ptr::null(), 7, extension_c.as_ptr()) }
        .expect("a NULL bytes pointer must still return an owned error envelope, not NULL");

    let parsed: serde_json::Value = serde_json::from_str(&envelope).expect("error envelope is JSON");
    assert_eq!(parsed["error"]["kind"], "invalidArgument", "{envelope}");
}

#[test]
fn null_extension_pointer_is_reported_not_undefined() {
    let bytes = docx_zip_bytes();
    // SAFETY: `fastdoc_read_office_tree` documents NULL `extension_` as a defined, checked case,
    // checked before the pointer is dereferenced. `bytes` is a valid, live slice for the call.
    let envelope = unsafe { call_read_office_tree_raw(bytes.as_ptr(), bytes.len(), std::ptr::null()) }
        .expect("a NULL extension pointer must still return an owned error envelope, not NULL");

    let parsed: serde_json::Value = serde_json::from_str(&envelope).expect("error envelope is JSON");
    assert_eq!(parsed["error"]["kind"], "invalidArgument", "{envelope}");
}

#[test]
fn freeing_a_null_pointer_is_defined_and_safe() {
    // SAFETY: `fastdoc_string_free`'s own contract explicitly permits NULL.
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(std::ptr::null_mut()) };
}
