//! Reads real documents, writes them as the host envelope, reads them BACK, and requires the
//! result to equal what was read.
//!
//! `OfficeReadResult` is `PartialEq` over every field, so this is the check that says the boundary
//! is lossless — and it is aimed squarely at the five `#[serde(skip)]`s. A skip is invisible: the
//! document still decodes, still renders, and the missing piece shows up much later as a table
//! with no shading or a paragraph in the wrong face. Here it shows up as an inequality, by field.
//!
//! Ignored by default for the same reason as the other corpus probes: the documents are real and
//! this repository cannot ship them. Run it explicitly with a corpus named.
//!
//! ```text
//! FMD_EXPORT_CORPUS=~/Documents cargo test -p fastdoc-engine --test export_round_trip -- --ignored --nocapture
//! ```

use fastdoc_engine::render::office::{
    docx_reader::DocxReader, odt_reader::OdtReader, office_block::OfficeReadResult,
    office_export, zip_archive::ZipArchive,
};

#[test]
#[ignore = "requires explicit external corpus"]
fn a_document_survives_the_envelope_unchanged() {
    let dirs = std::env::var("FMD_EXPORT_CORPUS").unwrap_or_else(|_| {
        panic!("set FMD_EXPORT_CORPUS before running this ignored corpus probe")
    });

    let mut documents = Vec::new();
    for dir in dirs.split(':').filter(|d| !d.is_empty()) {
        collect(std::path::Path::new(dir), &mut documents);
    }
    documents.sort();
    assert!(!documents.is_empty(), "FMD_EXPORT_CORPUS matched no documents under {dirs}");

    let (mut identical, mut unreadable, mut refused) = (0usize, 0usize, 0usize);
    let mut differing: Vec<String> = Vec::new();

    for path in &documents {
        let Some(original) = read(path) else {
            unreadable += 1;
            continue;
        };
        let json = match office_export::to_json(&original) {
            Ok(json) => json,
            // A refusal is a PASS, not a skip: it means the guard saw something the envelope
            // cannot carry and said so, which is the whole point of it existing.
            Err(_) => {
                refused += 1;
                continue;
            }
        };
        // Read back through the export's OWN door. `to_json` pools each picture's bytes into the
        // result's image map (`picture_pool`) and `from_json` puts them back; decoding by hand here
        // would compare a pooled result against an unpooled one and call the pooling a regression.
        let version: serde_json::Value = serde_json::from_str(&json).expect("the export is JSON");
        assert_eq!(version["v"], office_export::SCHEMA_VERSION);
        let decoded = match office_export::from_json(&json) {
            Ok(r) => r,
            Err(e) => {
                differing.push(format!("{} — could not be read back: {e}", path.display()));
                continue;
            }
        };
        if decoded == original {
            identical += 1;
        } else {
            differing.push(format!("{} — decoded result differs from what was read", path.display()));
        }
    }

    eprintln!(
        "{} documents: {identical} survived unchanged, {refused} refused by the guard, {unreadable} unreadable, {} differing",
        documents.len(),
        differing.len()
    );
    assert!(differing.is_empty(), "the envelope lost something:\n{}", differing.join("\n"));
    assert!(identical > 0, "no document actually round-tripped");
}

fn read(path: &std::path::Path) -> Option<OfficeReadResult> {
    let data = swiftshim::Data::contentsOf(&swiftshim::URL::fileURL(&path.to_string_lossy())).ok()?;
    let archive = ZipArchive::new(data).ok()?;
    let extension = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if extension == "odt" {
        OdtReader::read(&archive).ok()
    } else {
        DocxReader::read(&archive).ok()
    }
}

fn collect(dir: &std::path::Path, into: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect(&path, into);
            continue;
        }
        if path.file_name().is_some_and(|n| n.to_string_lossy().starts_with("._")) {
            continue;
        }
        let extension = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        if matches!(extension.as_str(), "docx" | "docm" | "dotx" | "dotm" | "odt") {
            into.push(path);
        }
    }
}
