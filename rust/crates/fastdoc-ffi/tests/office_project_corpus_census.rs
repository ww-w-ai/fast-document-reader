//! S6-6 measurement probe — NOT a gate, NOT wired into CI.
//!
//! Walks the same real-document corpus `office_corpus_census.rs` walks and runs EVERY document
//! through the real `fastdoc_read_office_json` FFI symbol — the production path, which tries
//! `ValidatedRenderTree::from_office` -> `office_project::project` first and only falls back to
//! `office_export::to_json(&OfficeReadResult)` on a refusal at either stage
//! (`fastdoc-ffi/src/lib.rs::project_or_fall_back`). Every fallback is recorded, un-silently, in
//! `projection_ledger` — this probe clears the ledger before each document and snapshots it after,
//! so a document that took the tree path leaves the ledger empty and a document that fell back
//! leaves exactly the `kind` string the fallback was recorded under.
//!
//! This answers, over real documents rather than fixtures: how many hit the `sections`/
//! `span.comment_ids` holes `office_project.rs`'s own module doc names, and how many hit something
//! else (a genuine `OfficeAdapterError` from `from_office`, before `project` is ever reached).
//!
//! Run:
//!
//!     FMD_OFFICE_PROJECT_CENSUS=1 cargo test -p fastdoc-ffi --test office_project_corpus_census -- --nocapture

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

/// The real `extern "C"` export — same call pattern `office_fallback_ledger_ffi.rs` establishes.
fn call_read_office_json(data: &[u8], extension: &str) -> Option<String> {
    let extension_c = CString::new(extension).ok()?;
    let ptr = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_json(data.as_ptr(), data.len(), extension_c.as_ptr())
    };
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(ptr) }.to_str().ok()?.to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    Some(text)
}

#[test]
fn office_project_corpus_census() {
    if std::env::var("FMD_OFFICE_PROJECT_CENSUS").is_err() {
        eprintln!("skipped: set FMD_OFFICE_PROJECT_CENSUS=1 to run");
        return;
    }

    let mut files = Vec::new();
    for dir in [
        repo_root().join("Vendor/rhwp-src/samples"),
        repo_root().join("testdocs"),
        repo_root().join("demo"),
        repo_root().join("docs/fixtures"),
    ] {
        walk(&dir, &mut files);
    }
    files.sort();
    // The whole corpus, not a prefix of it. This walk used to stop at 400 of the 669 office
    // documents it finds, and the cap was silent — the census reported "took tree path: 400,
    // fell back: 0" and read as "nothing falls back". Every document that DOES fall back was in
    // the 269 it never examined: `GnBS_IM_20260401.docx`,
    // `사업타당성검토보고서_덕소5B구역.docx`, `카카오톡대화_피고진성호.docx`,
    // `OpenAPI활용가이드_특일정보_v1.4.docx` and `tago-tables.odt` all sort past the cut.
    // A cap that removes exactly the cases a census exists to count is worse than no census
    // (INVARIANTS.md 111 — a scope narrowed for a good reason is an unread scope by Friday).
    //
    // A cap is still available for a quick run, but it must be ASKED for, and what it dropped is
    // printed with the result rather than left to be inferred from a number that looks complete.
    let found = files.len();
    let limit = std::env::var("FMD_OFFICE_PROJECT_CENSUS_LIMIT")
        .ok()
        .and_then(|v| v.parse::<usize>().ok());
    if let Some(limit) = limit {
        files.truncate(limit);
    }
    let dropped = found - files.len();

    let mut took_tree_path = 0usize;
    let mut null_returns = 0usize; // read_office itself failed, before from_office/project ran
    let mut by_kind: BTreeMap<String, Vec<String>> = BTreeMap::new();

    for path in &files {
        let Ok(bytes) = std::fs::read(path) else { continue };
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("?").to_string();

        fastdoc_engine::render::office::projection_ledger::clear();
        let result = call_read_office_json(&bytes, &ext);
        let entries = fastdoc_engine::render::office::projection_ledger::snapshot();

        if result.is_none() {
            null_returns += 1;
            continue;
        }
        if entries.is_empty() {
            took_tree_path += 1;
        } else {
            // One document can only take one path per call; record its FIRST (and normally only)
            // fallback kind — `from_office` and `project` are sequential, not both-attempted.
            let kind = entries[0].kind.clone();
            by_kind.entry(kind).or_default().push(name);
        }
    }

    println!("=== office_project_corpus_census ===");
    if dropped > 0 {
        println!(
            "CAPPED: {dropped} of {found} documents were NOT examined \
             (FMD_OFFICE_PROJECT_CENSUS_LIMIT={})",
            files.len()
        );
    }
    println!("total examined: {}", files.len());
    println!("took tree path (project succeeded): {took_tree_path}");
    println!("fell back to reader path (project or from_office refused): {}",
        by_kind.values().map(|v| v.len()).sum::<usize>());
    println!("read_office itself returned NULL (no path reached): {null_returns}");
    println!();
    for (kind, names) in &by_kind {
        println!("-- {kind}: {} document(s)", names.len());
        for n in names.iter().take(8) {
            println!("     {n}");
        }
        if names.len() > 8 {
            println!("     ... and {} more", names.len() - 8);
        }
    }
}
