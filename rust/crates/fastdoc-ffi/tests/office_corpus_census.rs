//! S6-5a — the leader's own 400-document corpus census, re-measured after the two fixes through
//! the SAME path the leader's baseline (`ok=385 / failed=15`) was measured through: the real
//! `fastdoc_read_office_tree` FFI symbol, not a direct `ValidatedRenderTree::from_office` call.
//! The two are NOT interchangeable for this purpose — `from_office` called directly needs a
//! caller-supplied `resources` map, and an empty one (easy to reach for) makes every docx/odt
//! with an image refuse with `MissingResource` regardless of this sprint's fixes, which is a
//! different measurement entirely, not a smaller or larger version of the same one.
//!
//! Real-corpus probe, gated by an env var — this repo's own convention (`FMD_RENDER_CORPUS` et
//! al., `CLAUDE.md`'s probe table) for a check that needs real documents this repo does not ship
//! in its own test fixtures. Run:
//!
//!     FMD_OFFICE_TREE_CENSUS=1 cargo test -p fastdoc-ffi --test office_corpus_census -- --nocapture
//!
//! Walks `Vendor/rhwp-src/samples`, `testdocs`, `demo`, `docs/fixtures` for `.docx`/`.odt`/`.hwp`/
//! `.hwpx`, sorted, first 400 — exactly the leader's own walk — and tabulates outcomes by parsing
//! the SAME envelope shape a real host does: `{"error":{"kind","message",...}}` or `{"ok":...}`.

use std::collections::BTreeMap;
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

/// The real `extern "C"` export, called and freed exactly the way `office_tree_ffi.rs` does.
fn call_read_office_tree(data: &[u8], extension: &str) -> Option<String> {
    let extension_c = CString::new(extension).ok()?;
    let ptr = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_tree(data.as_ptr(), data.len(), extension_c.as_ptr())
    };
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(ptr) }.to_str().ok()?.to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    Some(text)
}

/// The enum variant name a `format!("{error:?}")` message starts with (`MissingResource("...")`
/// -> `"MissingResource"`), so two different keys/details under the same refusal REASON still
/// tabulate as one row — the same grouping the leader's own manual count used.
fn error_variant(message: &str) -> String {
    message.split('(').next().unwrap_or(message).trim().to_string()
}

#[test]
fn office_tree_census_after_s6_5a() {
    let Ok(_) = std::env::var("FMD_OFFICE_TREE_CENSUS") else {
        eprintln!(
            "skip: set FMD_OFFICE_TREE_CENSUS=1 to run the corpus census (slow — walks the real \
             corpus; needs Vendor/rhwp-src checked out)"
        );
        return;
    };

    let root = repo_root();
    let mut files: Vec<PathBuf> = Vec::new();
    for sub in ["Vendor/rhwp-src/samples", "testdocs", "demo", "docs/fixtures"] {
        walk(&root.join(sub), &mut files);
    }
    files.sort();
    // The WHOLE corpus by default — 669 office documents, not the first 400.
    //
    // The cap was here to reproduce the leader's own walk against its `ok=385 / failed=15`
    // baseline, which was a good reason for one measurement and the wrong default to leave behind:
    // `CLAUDE.md` cites this census as the authority on how many documents the canonical tree
    // accepts, and that is a live judgement, not a re-measurement. The 269 documents past the cut
    // are also where the interesting answers are — every document whose projection falls back to
    // the reader path sorts past it.
    //
    // To reproduce the historical baseline, ask for the cap: FMD_OFFICE_TREE_CENSUS_LIMIT=400.
    // What a cap dropped is printed with the result, so no run can read as complete when it wasn't.
    let found = files.len();
    if let Some(limit) = std::env::var("FMD_OFFICE_TREE_CENSUS_LIMIT")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
    {
        files.truncate(limit);
    }
    let dropped = found - files.len();

    let mut ok = 0usize;
    let mut failed_by_kind: BTreeMap<String, usize> = BTreeMap::new();
    let mut examples_by_kind: BTreeMap<String, Vec<String>> = BTreeMap::new();

    for path in &files {
        let name = path.strip_prefix(&root).unwrap_or(path).to_string_lossy().to_string();
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or_default().to_ascii_lowercase();
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(e) => {
                *failed_by_kind.entry(format!("io error: {e}")).or_default() += 1;
                continue;
            }
        };

        let Some(envelope) = call_read_office_tree(&bytes, &ext) else {
            *failed_by_kind.entry("fastdoc_read_office_tree returned NULL".to_string()).or_default() += 1;
            examples_by_kind
                .entry("fastdoc_read_office_tree returned NULL".to_string())
                .or_default()
                .push(name);
            continue;
        };
        let value: serde_json::Value = match serde_json::from_str(&envelope) {
            Ok(v) => v,
            Err(e) => {
                *failed_by_kind.entry(format!("envelope did not decode: {e}")).or_default() += 1;
                continue;
            }
        };

        match value.get("error") {
            None => ok += 1,
            Some(error) => {
                let message = error.get("message").and_then(|m| m.as_str()).unwrap_or("(no message)");
                let kind = error_variant(message);
                *failed_by_kind.entry(kind.clone()).or_default() += 1;
                let list = examples_by_kind.entry(kind).or_default();
                if list.len() < 5 {
                    list.push(name.clone());
                }
            }
        }
    }

    let failed: usize = failed_by_kind.values().sum();
    println!("\n=== S6-5a office_tree census, {} documents (via fastdoc_read_office_tree) ===", files.len());
    if dropped > 0 {
        println!("CAPPED: {dropped} of {found} documents were NOT examined");
    }
    println!("ok={ok} failed={failed}");
    for (kind, count) in &failed_by_kind {
        let examples = examples_by_kind.get(kind).cloned().unwrap_or_default();
        println!("  {kind}: {count} (e.g. {examples:?})");
    }
    println!("=== end census ===\n");
}
