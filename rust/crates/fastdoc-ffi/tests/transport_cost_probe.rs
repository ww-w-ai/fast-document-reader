//! What the JSON+base64 transport costs, separated from what reading the document costs.
//!
//! `fastdoc_office_open` and `fastdoc_read_office_json` do the SAME read (`read_office`); the second
//! one additionally builds a canonical tree, projects schema-v4, base64s every picture and encodes
//! the whole thing as one C string. Timing both on the same document therefore isolates the
//! transport — which is exactly the part a pull model (`rhwp_image_base64` against a live handle)
//! would remove.
//!
//!     FMD_TRANSPORT_PROBE=/path/to.hwp cargo test -p fastdoc-ffi --test transport_cost_probe -- --nocapture

use std::ffi::{CStr, CString};
use std::time::Instant;

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
fn what_the_json_transport_costs_beyond_reading_the_document() {
    let Ok(paths) = std::env::var("FMD_TRANSPORT_PROBE") else {
        eprintln!("skipped: set FMD_TRANSPORT_PROBE to colon-separated document paths");
        return;
    };
    println!("{:>9} {:>9} {:>9} {:>12} {:>12}  document", "open ms", "json ms", "delta", "json bytes", "src bytes");
    for path in paths.split(':').filter(|p| !p.is_empty()) {
        let path = resolve(path);
        let data = std::fs::read(&path).expect("readable document");
        let extension = path
            .extension().and_then(|e| e.to_str()).unwrap_or_default();
        let ext_c = CString::new(extension).unwrap();

        // Read only: open the document and close it. No tree, no projection, no base64, no JSON.
        let start = Instant::now();
        let handle = unsafe {
            fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), ext_c.as_ptr())
        };
        let open_ms = start.elapsed().as_secs_f64() * 1000.0;
        assert!(!handle.is_null(), "{}: the engine could not open this document", path.display());
        unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };

        // The same read, plus everything the host is handed it through.
        let start = Instant::now();
        let json = unsafe {
            fastdoc_engine_ffi::fastdoc_read_office_json(data.as_ptr(), data.len(), ext_c.as_ptr())
        };
        let json_ms = start.elapsed().as_secs_f64() * 1000.0;
        assert!(!json.is_null(), "{}: the engine could not export this document", path.display());
        let len = unsafe { CStr::from_ptr(json) }.to_bytes().len();
        unsafe { fastdoc_engine_ffi::fastdoc_string_free(json) };

        println!(
            "{open_ms:>9.0} {json_ms:>9.0} {:>9.0} {len:>12} {:>12}  {}",
            json_ms - open_ms,
            data.len(),
            path.file_name().and_then(|n| n.to_str()).unwrap_or_default()
        );
    }
}
