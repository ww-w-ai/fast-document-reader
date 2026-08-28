//! The size of what the engine hands the host, as a number a change has to keep.
//!
//! `office_payload_size_census.rs` answers "where do the bytes go" across a corpus. This asks a
//! narrower question with a pass/fail answer: for ONE named document, is the payload still at or
//! below what it was when this ceiling was recorded? That is the number the P series is spending,
//! and a ceiling is the only form in which a spend is visible later.
//!
//! Wall clock is deliberately not measured here. This repo's suite is a documented false-failure
//! under load, and a byte count is the same on a busy machine as on an idle one (invariant 113).
//!
//!     FMD_PAYLOAD_BUDGET=/path/to/2025_행정업무운영편람_최종.hwp \
//!       cargo test -p fastdoc-ffi --test payload_budget -- --nocapture
//!
//! Set `FMD_PAYLOAD_BUDGET_CEILING` to judge a different document against a different number.

use std::ffi::{CStr, CString};

/// Measured on `2025_행정업무운영편람_최종.hwp` (10.7 MB, 542 pages, 109 pictures).
///
/// At `117f388`: 77,946,260 bytes, of which 53,937,512 (69%) were base64'd pictures.
/// At P2c: **27,169,703** — every picture the document NAMED is now carried by reference and
/// fetched when something draws it (`fastdoc_office_image_base64`), which took 50,774,496 bytes
/// out of the payload. What remains of the picture bytes is 3,163,016 in table fills and anchored
/// objects, which carry pixels in the vocabulary itself and have no key to be fetched by
/// (`office_picture_key_split.rs` measures that split and gates the keyed half at zero).
/// At P4a: **13,181,914** — the export used to write a picture's bytes once per USE, 692 times for
/// 61 distinct pictures (610 table cells share 44 background images). They now travel once, in
/// `picture_pool`, keyed by content (`office/picture_pool.rs`).
///
/// The ceiling is the measurement, not a budget with slack: a change that puts bytes back fails
/// here, and a change that removes more is the next ceiling asking to be written down.
const RECORDED_CEILING: usize = 13_181_914;

/// Document paths come from the environment, and `cargo test` runs this binary with its CWD set to
/// the PACKAGE directory — so a path written relative to the repo (`testdocs/...`, the way every
/// other command in this repo is written) misses. Resolve those against the repo root rather than
/// making the caller notice.
fn resolve(path: &str) -> std::path::PathBuf {
    let given = std::path::Path::new(path);
    if given.is_absolute() || given.exists() {
        return given.to_path_buf();
    }
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join(given)
}


#[test]
fn the_payload_for_one_real_document_stays_within_its_recorded_ceiling() {
    let Ok(path) = std::env::var("FMD_PAYLOAD_BUDGET") else {
        eprintln!("skipped: set FMD_PAYLOAD_BUDGET to a document path");
        return;
    };
    let ceiling: usize = std::env::var("FMD_PAYLOAD_BUDGET_CEILING")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(RECORDED_CEILING);

    let path = resolve(&path);
    let data = std::fs::read(&path).expect("readable document");
    let extension = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default();
    let ext_c = CString::new(extension).unwrap();

    let json = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_json(data.as_ptr(), data.len(), ext_c.as_ptr())
    };
    assert!(!json.is_null(), "{}: the engine could not export this document", path.display());
    let bytes = unsafe { CStr::from_ptr(json) }.to_bytes().len();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(json) };

    // A vacuity guard: an export that shrank to nothing would pass a ceiling test silently.
    assert!(
        bytes > 100_000,
        "{}: exported only {bytes} bytes — that is not this document, it is an empty answer",
        path.display()
    );
    println!(
        "PAYLOAD {bytes} bytes (ceiling {ceiling}, {:.1}% of it)  {}",
        bytes as f64 / ceiling as f64 * 100.0,
        path.display()
    );
    assert!(
        bytes <= ceiling,
        "payload grew: {bytes} bytes against a recorded ceiling of {ceiling}"
    );
}
