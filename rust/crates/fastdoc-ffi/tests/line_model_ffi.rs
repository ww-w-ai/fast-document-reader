//! S3: `fastdoc_office_line_model_json` through the real `extern "C"` symbol — the envelope shape,
//! the placed line heights and row heights a host reads back, and the refusals it must be able to
//! branch on. The arithmetic needs no document, so unlike `page_plan_ffi.rs` there is no fixture.

use std::ffi::{CStr, CString};

fn call(input: &str) -> serde_json::Value {
    let input = CString::new(input).unwrap();
    // SAFETY: `input` is NUL-terminated and outlives the call.
    let out = unsafe { fastdoc_engine_ffi::fastdoc_office_line_model_json(input.as_ptr()) };
    assert!(!out.is_null(), "the envelope itself must always be built");
    // SAFETY: `out` is a NUL-terminated string this library owns, freed exactly once below.
    let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(out) };
    serde_json::from_str(&text).unwrap()
}

#[test]
fn an_hwp_paragraph_stands_at_its_floor_and_a_cell_row_follows_from_its_lines() {
    let hwp = r#"{"lines":[14.5,14.5],"rule":{"mode":"atLeast","value":16},"charSize":10,"lineSpacingBelow":true}"#;
    let reply = call(&format!(
        r#"{{"version":1,"paragraphs":[{hwp}],
            "tables":[{{"rowCount":1,"emptyLine":10,"rowPadding":4,
                        "cells":[{{"row":0,"vPadding":4,"items":[{{"kind":"text","paragraphs":[{hwp}]}}]}}]}}]}}"#
    ));
    assert_eq!(reply["ffiVersion"], 1);
    let ok = &reply["ok"];
    assert_eq!(ok["modelVersion"], 1);
    assert_eq!(ok["paragraphs"][0]["heights"], serde_json::json!([16.0, 16.0]));
    assert_eq!(ok["paragraphs"][0]["trailing"], 6.0);
    // The cell's paragraph is its only one, so its last line hands the spacing back: 16 + 10.
    assert_eq!(ok["tables"][0]["rowHeights"], serde_json::json!([30.0]));
    assert_eq!(ok["tables"][0]["cells"][0]["items"][0]["paragraphs"][0]["tops"], serde_json::json!([0.0, 16.0]));
}

#[test]
fn a_bad_input_is_an_error_envelope_not_a_null_or_a_guess() {
    for input in [
        "not json",
        r#"{"version":2}"#,
        r#"{"version":1,"tables":[{"rowCount":1,"emptyLine":10,"cells":[{"row":4}]}]}"#,
        r#"{"version":1,"paragraphs":[{"lines":[1],"rule":{"mode":"sideways","value":1}}]}"#,
    ] {
        let reply = call(input);
        assert_eq!(reply["error"]["kind"], "invalidArgument", "{input}: {reply}");
        assert!(reply.get("ok").is_none());
    }
}

#[test]
fn a_null_input_is_refused() {
    // SAFETY: a NULL input is the documented refusal.
    let out = unsafe { fastdoc_engine_ffi::fastdoc_office_line_model_json(std::ptr::null()) };
    assert!(!out.is_null());
    // SAFETY: `out` is a NUL-terminated string this library owns, freed exactly once.
    let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(out) };
    let reply: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["error"]["kind"], "invalidArgument");
}
