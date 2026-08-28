//! S9-3 — where a document's exported bytes actually GO.
//!
//! The roadmap carries exactly one number against `OfficeBlock`: one real HWP exports a
//! 77,946,260-byte schema-v4 JSON. That number was read as a reason to retire the schema-v4
//! vocabulary in favour of the canonical tree. This census asks the question that reading skipped:
//! how much of those bytes is the VOCABULARY, and how much is the document's own picture payload,
//! which every export carries whichever vocabulary describes it.
//!
//! Both exports are measured through the real `extern "C"` symbols a host calls — the same
//! discipline `office_corpus_census.rs` states for itself, and for the same reason: a direct
//! `from_office` call needs a caller-supplied `resources` map, and an empty one refuses every
//! document with an image, which is a different measurement, not a smaller one.
//!
//! **The picture total is taken from the TREE, and used for both sides.** Reading schema-v4's
//! `images` map instead undercounts it, and silently: a picture can reach the export through at
//! least two other fields — a table's own picture fill (`TableFormat.picture_fill`, which only
//! `HwpReader` sets) and a master page's artwork — neither of which is in that map. Measured on
//! `2025_행정업무운영편람_최종.hwp`: 66 entries in `images`, 127 resources in the tree built FROM
//! that same result, all 127 with DISTINCT sha256 and non-empty bytes, only 66 carrying a
//! `sourceKey`. The tree is the one place every picture is accounted for exactly once, so it is
//! the honest denominator for both columns.
//!
//! Real-corpus probe, env-gated by this repo's convention:
//!
//!     FMD_OFFICE_PAYLOAD_CENSUS=1 cargo test -p fastdoc-ffi --test office_payload_size_census -- --nocapture
//!
//! `FMD_OFFICE_PAYLOAD_DIR` overrides the walk root (default: the repo's `testdocs`).

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk(&path, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if matches!(ext.to_ascii_lowercase().as_str(), "docx" | "odt" | "hwp" | "hwpx") {
                out.push(path);
            }
        }
    }
}

fn call(
    symbol: unsafe extern "C" fn(*const u8, usize, *const std::ffi::c_char) -> *mut std::ffi::c_char,
    data: &[u8],
    extension: &str,
) -> Option<String> {
    let extension_c = CString::new(extension).ok()?;
    let ptr = unsafe { symbol(data.as_ptr(), data.len(), extension_c.as_ptr()) };
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(ptr) }.to_str().ok()?.to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    Some(text)
}

/// Every picture the document has, counted once: resource count, total base64 length, and how many
/// of those resources name a key schema-v4's `images` map would have been able to hold.
fn tree_pictures(json: &str) -> Option<(usize, usize, usize)> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let resources = value.get("ok")?.get("resources")?.as_array()?;
    let bytes = resources
        .iter()
        .filter_map(|r| r.get("bytesBase64")?.as_str())
        .map(str::len)
        .sum();
    let keyed = resources
        .iter()
        .filter(|r| r.get("sourceKey").and_then(serde_json::Value::as_str).is_some())
        .count();
    Some((resources.len(), bytes, keyed))
}

#[test]
fn where_a_document_s_exported_bytes_go() {
    if std::env::var("FMD_OFFICE_PAYLOAD_CENSUS").is_err() {
        eprintln!("skipped: set FMD_OFFICE_PAYLOAD_CENSUS=1 to run");
        return;
    }
    let root = std::env::var("FMD_OFFICE_PAYLOAD_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root().join("testdocs"));
    let mut paths = Vec::new();
    walk(&root, &mut paths);
    paths.sort();
    assert!(!paths.is_empty(), "no office documents under {}", root.display());

    println!(
        "{:>11} {:>11} {:>11} {:>11} {:>11} {:>5} {:>5}  {}",
        "source", "v4-total", "tree-total", "pictures", "v4-descr", "res", "keyed", "document"
    );
    let (mut v4_sum, mut tree_sum, mut picture_sum) = (0usize, 0usize, 0usize);
    for path in &paths {
        let Ok(data) = std::fs::read(path) else { continue };
        let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("?");
        let v4 = call(fastdoc_engine_ffi::fastdoc_read_office_json, &data, extension);
        let tree = call(fastdoc_engine_ffi::fastdoc_read_office_tree, &data, extension);
        let (Some(v4), Some(tree)) = (v4, tree) else {
            println!("{:>11} {:>11} {:>11} {:>11} {:>11} {:>5} {:>5}  {name} (no export)",
                data.len(), "-", "-", "-", "-", "-", "-");
            continue;
        };
        // A tree export can be the error half of the envelope; that is not a size measurement, and
        // without it there is no trustworthy picture total for this document either.
        let Some((count, pictures, keyed)) = tree_pictures(&tree) else {
            println!("{:>11} {:>11} {:>11} {:>11} {:>11} {:>5} {:>5}  {name} (tree refused)",
                data.len(), v4.len(), tree.len(), "-", "-", "-", "-");
            continue;
        };
        v4_sum += v4.len();
        tree_sum += tree.len();
        picture_sum += pictures;
        println!(
            "{:>11} {:>11} {:>11} {:>11} {:>11} {:>5} {:>5}  {name}",
            data.len(),
            v4.len(),
            tree.len(),
            pictures,
            v4.len().saturating_sub(pictures),
            count,
            keyed,
        );
    }
    let v4_described = v4_sum.saturating_sub(picture_sum);
    let tree_described = tree_sum.saturating_sub(picture_sum);
    println!(
        "\nTOTAL  v4 {v4_sum}  tree {tree_sum}  pictures {picture_sum}\n\
         DESCRIPTION  v4 {v4_described}  tree {tree_described}  \
         (tree/v4 = {:.2}x)",
        tree_described as f64 / v4_described.max(1) as f64
    );
}
