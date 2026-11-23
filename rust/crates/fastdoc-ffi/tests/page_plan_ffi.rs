//! S2: `fastdoc_office_page_plan_json` through the real `extern "C"` symbol — the envelope shape,
//! the keyed answer, and the refusals a host must be able to branch on.
//!
//! The document handle is only a validity gate for this export (the arithmetic needs no document
//! state), so the fixture is the smallest docx that opens: the stored-only zip recipe
//! `office_document_handle_ffi.rs` uses, duplicated because integration test binaries cannot share
//! a helper.

use std::ffi::{CStr, CString};

const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";
const DOCX_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>plan</w:t></w:r></w:p></w:body></w:document>\n";

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

fn stored_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut body = Vec::new();
    let mut central = Vec::new();
    for (name, data) in entries {
        let crc = crc32(data);
        let offset = body.len() as u32;
        body.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        body.extend_from_slice(&20u16.to_le_bytes());
        body.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0x21, 0]);
        body.extend_from_slice(&crc.to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&(name.len() as u16).to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes());
        body.extend_from_slice(name.as_bytes());
        body.extend_from_slice(data);

        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&((3u16 << 8) | 20).to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0x21, 0]);
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&[0u8; 8]);
        central.extend_from_slice(&((0o100644u32) << 16).to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name.as_bytes());
    }
    let central_offset = body.len() as u32;
    let central_size = central.len() as u32;
    let mut out = body;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0, 0, 0, 0]);
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

fn open_handle() -> *mut fastdoc_engine_ffi::FastdocOfficeDocument {
    let data = stored_zip(&[
        ("[Content_Types].xml", DOCX_CONTENT_TYPES.as_bytes()),
        ("_rels/.rels", DOCX_RELS.as_bytes()),
        ("word/document.xml", DOCX_DOCUMENT_XML.as_bytes()),
    ]);
    let extension = CString::new("docx").unwrap();
    // SAFETY: `data` and `extension` outlive the call.
    let handle = unsafe { fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), extension.as_ptr()) };
    assert!(!handle.is_null(), "the fixture docx must open");
    handle
}

fn call(handle: *const fastdoc_engine_ffi::FastdocOfficeDocument, input: &str) -> serde_json::Value {
    let input = CString::new(input).unwrap();
    // SAFETY: `handle` is live (or NULL, which the export refuses) and `input` is NUL-terminated.
    let out = unsafe { fastdoc_engine_ffi::fastdoc_office_page_plan_json(handle, input.as_ptr()) };
    assert!(!out.is_null(), "the envelope itself must always be built");
    // SAFETY: `out` is a NUL-terminated string this library owns, freed exactly once below.
    let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(out) };
    serde_json::from_str(&text).unwrap()
}

#[test]
fn the_plan_comes_back_in_the_tree_envelope_keyed_by_the_hosts_keys() {
    let handle = open_handle();
    let reply = call(
        handle,
        r#"{"planVersion":1,"contentHeight":100,"splitTables":true,
            "blocks":[{"key":4001,"kind":"text","lines":[60,60]},
                      {"key":4002,"kind":"atomic","height":30}]}"#,
    );
    assert_eq!(reply["ffiVersion"], 1);
    let plan = &reply["ok"];
    assert_eq!(plan["planVersion"], 1);
    assert_eq!(plan["pageCount"], 2);
    assert_eq!(plan["pages"][0]["firstKey"], 4001);
    assert_eq!(plan["lines"], serde_json::json!([[0, 0, 0, 0.0], [0, 1, 1, 0.0]]));
    assert_eq!(plan["placements"][0]["key"], 4002);
    assert_eq!(plan["placements"][0]["page"], 1);
    // SAFETY: closed exactly once.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}

#[test]
fn a_bad_input_is_an_error_envelope_not_a_null_or_a_guess() {
    let handle = open_handle();
    for input in [
        "not json",
        r#"{"planVersion":2,"contentHeight":100,"blocks":[]}"#,
        r#"{"planVersion":1,"contentHeight":0,"blocks":[]}"#,
        r#"{"planVersion":1,"contentHeight":100,"blocks":[{"key":1,"kind":"sideways"}]}"#,
    ] {
        let reply = call(handle, input);
        assert_eq!(reply["error"]["kind"], "invalidArgument", "{input}: {reply}");
        assert!(reply.get("ok").is_none());
    }
    // SAFETY: closed exactly once.
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}

#[test]
fn a_table_that_fits_no_page_comes_back_flowed_with_its_cell_lines_and_segments() {
    // One row, one cell of five 40pt lines on a 100pt page: two a page. The cells' lines travel in
    // the row; the answer names where each landed and which pages the row touches.
    let reply = call(
        std::ptr::null(),
        r#"{"planVersion":1,"contentHeight":100,"band":20,"blocks":[
            {"key":9,"kind":"table","rows":[{"height":200,"cells":[{"padTop":0,"padBottom":0,"contentHeight":200,
              "lines":[{"top":0,"height":40},{"top":40,"height":40},{"top":80,"height":40},
                       {"top":120,"height":40},{"top":160,"height":40}]}]}]}]}"#,
    );
    let plan = &reply["ok"];
    assert_eq!(plan["pageCount"], 3, "{reply}");
    assert_eq!(plan["placements"][0]["flowed"], true);
    assert_eq!(plan["cellLines"][0], serde_json::json!([0, 0, 0, 0, 0, 0.0]));
    assert_eq!(plan["cellLines"][2], serde_json::json!([0, 0, 0, 2, 1, 0.0]));
    assert_eq!(plan["rowSegments"].as_array().unwrap().len(), 3);
    assert_eq!(plan["pulledLines"], serde_json::json!([]));
}

#[test]
fn a_null_handle_plans_and_a_null_input_is_refused() {
    let reply = call(std::ptr::null(), r#"{"planVersion":1,"contentHeight":100,"blocks":[]}"#);
    assert_eq!(reply["ok"]["pageCount"], 1, "{reply}");

    // SAFETY: a NULL input is the documented refusal.
    let out = unsafe { fastdoc_engine_ffi::fastdoc_office_page_plan_json(std::ptr::null(), std::ptr::null()) };
    assert!(!out.is_null());
    // SAFETY: `out` is a NUL-terminated string this library owns, freed exactly once.
    let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(out) };
    let reply: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["error"]["kind"], "invalidArgument");
}
