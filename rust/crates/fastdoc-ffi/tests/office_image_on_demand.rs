//! P2b — a picture fetched from the still-open parse is the SAME picture the read used to embed.
//!
//! The read decodes every embedded picture and puts it in `OfficeReadResult.images`, because after
//! `rhwp_close` those pixels are unreachable (an `.hwp` is CFB binary; there is no archive to
//! re-open). P2b keeps the parse alive so a host can ask for one picture instead. That is only a
//! safe trade if the two answers are the same bytes — not "a valid image", not "the right size",
//! the same bytes. Anything less and P2c would quietly change what a reader draws.
//!
//! **A cropped occurrence is the case that already broke.** The first implementation fetched the
//! raw picture and let the crop fall to the caller; this test caught it answering an uncropped
//! picture for `hwpimg:1!crop=…`. So the coverage assertion below demands a cropped picture, not
//! merely "some pictures" — without that, the one regression this file exists for walks straight
//! back in.
//!
//! Scope is DECLARED, not silently cut: the vendored corpus is 413 documents and 419 MB, which a
//! debug-build gate cannot walk on every run. The default takes the first documents that actually
//! carry pictures and PRINTS which ones and how many, so the report says what was covered.
//! `FMD_HWP_PICTURE_CORPUS=1` walks every sample instead.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};

/// Documents examined by default. The plan's gate is "real HWP documents, pictures exhaustive" —
/// exhaustive over each document's pictures, which is the axis the crop bug lived on, not over the
/// corpus, which only re-measures the same code on more bytes.
const DEFAULT_DOCUMENTS_WITH_PICTURES: usize = 3;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn samples() -> Vec<PathBuf> {
    let dir = repo_root().join("Vendor/rhwp-src/samples");
    let Ok(entries) = std::fs::read_dir(&dir) else { return Vec::new() };
    let mut out: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            matches!(
                p.extension().and_then(|e| e.to_str()),
                Some("hwp") | Some("hwpx")
            )
        })
        .collect();
    // Smallest first, and by name within a size, so the default set is deterministic AND cheap —
    // a run that picked whatever the filesystem listed first would cover different documents on
    // different machines and report a number nobody could reproduce.
    out.sort_by_key(|p| {
        (
            std::fs::metadata(p).map(|m| m.len()).unwrap_or(u64::MAX),
            p.clone(),
        )
    });
    out
}

/// The pictures the read embedded, as `(key, bytes)` — read straight out of the schema-v4 export
/// so this compares what a HOST is handed, not what an internal type holds.
fn embedded_pictures(json: &str) -> Vec<(String, Vec<u8>)> {
    let value: serde_json::Value = serde_json::from_str(json).expect("export is JSON");
    let Some(images) = value.get("images").and_then(|i| i.as_object()) else {
        return Vec::new();
    };
    use base64::Engine;
    let mut out: Vec<(String, Vec<u8>)> = images
        .iter()
        .filter(|(key, _)| key.starts_with("hwpimg:"))
        .filter_map(|(key, value)| {
            let base64 = value.as_str()?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(base64).ok()?;
            Some((key.clone(), bytes))
        })
        .collect();
    out.sort();
    out
}

struct Opened {
    handle: *mut fastdoc_engine_ffi::FastdocOfficeDocument,
    json: String,
}

fn open(path: &Path) -> Option<Opened> {
    let data = std::fs::read(path).ok()?;
    let extension = path.extension()?.to_str()?;
    let ext_c = CString::new(extension).ok()?;
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), ext_c.as_ptr())
    };
    if handle.is_null() {
        return None;
    }
    let json = unsafe {
        fastdoc_engine_ffi::fastdoc_office_content_json(handle, data.as_ptr(), data.len())
    };
    if json.is_null() {
        unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
        return None;
    }
    let owned = unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(json) };
    Some(Opened { handle, json: owned })
}

fn fetch(handle: *mut fastdoc_engine_ffi::FastdocOfficeDocument, key: &str) -> Option<Vec<u8>> {
    let key_c = CString::new(key).ok()?;
    let fetched =
        unsafe { fastdoc_engine_ffi::fastdoc_office_image_base64(handle, key_c.as_ptr()) };
    if fetched.is_null() {
        return None;
    }
    let base64 = unsafe { CStr::from_ptr(fetched) }.to_string_lossy().into_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(fetched) };
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(&base64).ok()
}

#[test]
fn a_picture_fetched_from_the_open_parse_is_byte_identical_to_the_one_the_read_embedded() {
    let whole_corpus = std::env::var("FMD_HWP_PICTURE_CORPUS").is_ok();
    let mut documents: Vec<String> = Vec::new();
    let mut pictures_compared = 0usize;
    let mut cropped_compared = 0usize;
    let mut skipped_for_scope = 0usize;

    for path in samples() {
        if !whole_corpus && documents.len() >= DEFAULT_DOCUMENTS_WITH_PICTURES {
            skipped_for_scope += 1;
            continue;
        }
        let Some(opened) = open(&path) else { continue };
        let embedded = embedded_pictures(&opened.json);
        if !embedded.is_empty() {
            documents.push(format!(
                "{} ({} pictures)",
                path.file_name().unwrap_or_default().to_string_lossy(),
                embedded.len()
            ));
        }
        for (key, expected) in embedded {
            let actual = fetch(opened.handle, &key).unwrap_or_else(|| {
                panic!(
                    "{}: the open parse could not produce {key}, which the read had embedded",
                    path.display()
                )
            });
            assert_eq!(
                actual,
                expected,
                "{}: {key} differs between the read's copy and the parse's",
                path.display()
            );
            pictures_compared += 1;
            if key.contains("!crop=") {
                cropped_compared += 1;
            }
        }
        unsafe { fastdoc_engine_ffi::fastdoc_office_close(opened.handle) };
    }

    // Coverage, asserted rather than hoped for. The first of these stops the whole test passing on
    // a corpus with no pictures in it; the second keeps the crop case — the one defect this file
    // actually caught — inside the default run rather than only in the corpus sweep.
    assert!(
        pictures_compared >= 1,
        "compared no pictures at all across {} documents", documents.len()
    );
    assert!(
        cropped_compared >= 1,
        "compared {pictures_compared} pictures but not one CROPPED one — the regression this test \
         exists for (a cropped key answering the uncropped original) would pass unnoticed. \
         Documents examined: {documents:?}"
    );
    println!(
        "P2B compared {pictures_compared} pictures ({cropped_compared} cropped) across {} \
         documents{}: {documents:?}",
        documents.len(),
        if skipped_for_scope > 0 {
            format!(", {skipped_for_scope} further samples not examined (set FMD_HWP_PICTURE_CORPUS=1 for all)")
        } else {
            String::new()
        }
    );
}

/// A key nobody declared answers NULL rather than something a caller could mistake for a picture.
#[test]
fn a_key_this_document_does_not_have_answers_nothing() {
    let Some(path) = samples().into_iter().next() else { return };
    let Some(opened) = open(&path) else { return };
    for key in ["hwpimg:65000", "not-a-key", "hwpimg:", "hwpimg:abc"] {
        assert!(
            fetch(opened.handle, key).is_none(),
            "{key} answered something"
        );
    }
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(opened.handle) };
}
