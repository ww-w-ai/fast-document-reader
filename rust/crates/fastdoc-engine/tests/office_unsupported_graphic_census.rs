//! S6-6 measurement probe — NOT a gate, NOT wired into CI.
//!
//! Recovers the "before" `Field(unsupportedGraphic.size)`/`Field(sections)` fallback rate WITHOUT
//! re-running any prior code state — both refusal reasons are properties of the READER'S OWN
//! output (`OfficeReadResult`) that can be counted directly, on the current (clean) tree, rather
//! than reproduced by re-triggering `project()` against a since-changed source:
//!
//!   A) documents whose `OfficeReadResult` contains at least one `OfficeBlock::UnsupportedGraphic`,
//!      anywhere a block can appear — top-level `blocks`, `headers`/`footers`/`footnotes`, and
//!      recursively inside table cells (`Cell.blocks`, which can themselves hold nested tables —
//!      `office_block.rs::Cell`'s own doc: "another table — flattened, never a real nested grid").
//!   B) of those, how many ALSO have `sections.len() > 1` (the overlap with the OTHER refusal
//!      reason, so A and C are not simply additive).
//!   C) documents with `sections.len() > 1` (the same `Field(sections)` predicate as
//!      `office_section_field_census.rs`, repeated here so A/B/C come from ONE run over the SAME
//!      400-document ordering).
//!
//! `before = 400 - |A union C|`, `after = 400 - |C|` (once `unsupportedGraphic.size` is fixed).
//!
//! Run:
//!
//!     FMD_OFFICE_UNSUPPORTED_GRAPHIC_CENSUS=1 cargo test -p fastdoc-engine --test office_unsupported_graphic_census -- --nocapture

use fastdoc_engine::render::office::docx_reader::DocxReader;
use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::office::odt_reader::OdtReader;
use fastdoc_engine::render::office::office_block::{Cell, OfficeBlock, OfficeReadResult};
use fastdoc_engine::render::office::zip_archive::ZipArchive;
use swiftshim::font_provider::{FaceId, FaceInfo, FontProvider};
use swiftshim::{Data, NSFontDescriptorSymbolicTraits, NSFontWeight};

use std::path::{Path, PathBuf};

/// Same posture as `office_section_field_census.rs`'s `FakeFontProvider` — present and
/// consistent, never realistic; this probe counts block shapes, not glyph metrics.
struct FakeFontProvider;

impl FontProvider for FakeFontProvider {
    fn face_named(&self, _name: &str) -> Option<FaceId> {
        Some(FaceId(1))
    }
    fn resolve(&self, _descriptor: &swiftshim::color_font::NSFontDescriptor) -> Option<FaceId> {
        Some(FaceId(1))
    }
    fn system_face(&self, _weight: NSFontWeight, _monospaced: bool) -> FaceId {
        FaceId(1)
    }
    fn describe(&self, _face: FaceId) -> FaceInfo {
        FaceInfo { name: "Helvetica".to_string(), family: Some("Helvetica".to_string()), traits: NSFontDescriptorSymbolicTraits::empty() }
    }
    fn covers(&self, _face: FaceId, _scalar: u32) -> bool {
        true
    }
    fn substitute(&self, _declared: FaceId, _scalar: u32) -> Option<FaceId> {
        None
    }
}

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

fn read_result(path: &Path) -> Option<OfficeReadResult> {
    let bytes = std::fs::read(path).ok()?;
    let ext = path.extension().and_then(|e| e.to_str())?.to_ascii_lowercase();
    match ext.as_str() {
        "docx" => {
            let archive = ZipArchive::new(Data::fromBytes(bytes)).ok()?;
            DocxReader::read(&archive).ok()
        }
        "odt" => {
            let archive = ZipArchive::new(Data::fromBytes(bytes)).ok()?;
            OdtReader::read(&archive).ok()
        }
        "hwp" | "hwpx" => {
            let data = Data::fromBytes(bytes);
            HwpReader::read(&data).ok()
        }
        _ => None,
    }
}

/// True if `blocks` (or anything it recursively contains, through table cells) holds at least one
/// `OfficeBlock::UnsupportedGraphic` — the exact shape `office_project.rs::map_single_block`
/// refuses on (`wire::NodePayload::Unsupported(_) => Err(Field("unsupportedGraphic.size"))`).
fn contains_unsupported_graphic(blocks: &[OfficeBlock]) -> bool {
    blocks.iter().any(block_contains_unsupported_graphic)
}

fn block_contains_unsupported_graphic(block: &OfficeBlock) -> bool {
    match block {
        OfficeBlock::UnsupportedGraphic { .. } => true,
        OfficeBlock::Table { rows, .. } => rows
            .iter()
            .flat_map(|row| row.iter())
            .any(|cell: &Cell| contains_unsupported_graphic(&cell.blocks)),
        _ => false,
    }
}

fn document_has_unsupported_graphic(result: &OfficeReadResult) -> bool {
    contains_unsupported_graphic(&result.blocks)
        || result.headers.iter().any(|h| contains_unsupported_graphic(&h.blocks))
        || result.footers.iter().any(|f| contains_unsupported_graphic(&f.blocks))
        || result.footnotes.iter().any(|f| contains_unsupported_graphic(&f.blocks))
}

#[test]
fn office_unsupported_graphic_census() {
    if std::env::var("FMD_OFFICE_UNSUPPORTED_GRAPHIC_CENSUS").is_err() {
        eprintln!("skipped: set FMD_OFFICE_UNSUPPORTED_GRAPHIC_CENSUS=1 to run");
        return;
    }
    swiftshim::font_provider::install(Box::new(FakeFontProvider));

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
    // The whole corpus, not a prefix of it. This walk finds 669 office documents and used to stop
    // at 400 without saying so, which biases every count below by the 269 it never opened — and
    // those are not a random 269, they are whatever sorts last. Ask for a cap with `FMD_UNSUPPORTED_GRAPHIC_CENSUS_LIMIT` if a
    // quick run is wanted; what it dropped is printed with the result (INVARIANTS.md 111).
    let found = files.len();
    if let Some(limit) = std::env::var("FMD_UNSUPPORTED_GRAPHIC_CENSUS_LIMIT")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
    {
        files.truncate(limit);
    }
    let dropped = found - files.len();

    let mut read_ok = 0usize;
    let mut a_unsupported = 0usize; // A: has >=1 UnsupportedGraphic anywhere
    let mut c_multi_section = 0usize; // C: sections.len() > 1
    let mut b_overlap = 0usize; // B: A and C both true
    let mut a_examples: Vec<String> = Vec::new();
    let mut overlap_examples: Vec<String> = Vec::new();

    for path in &files {
        let Some(result) = read_result(path) else { continue };
        read_ok += 1;
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("?").to_string();

        let has_unsupported = document_has_unsupported_graphic(&result);
        let multi_section = result.sections.len() > 1;

        if has_unsupported {
            a_unsupported += 1;
            if a_examples.len() < 8 {
                a_examples.push(name.clone());
            }
        }
        if multi_section {
            c_multi_section += 1;
        }
        if has_unsupported && multi_section {
            b_overlap += 1;
            if overlap_examples.len() < 8 {
                overlap_examples.push(name.clone());
            }
        }
    }

    let a_union_c = a_unsupported + c_multi_section - b_overlap;

    println!("=== office_unsupported_graphic_census ===");
    if dropped > 0 {
        println!("CAPPED: {dropped} of {found} documents were NOT examined");
    }
    println!("total examined: {}", files.len());
    println!("read successfully: {read_ok}");
    println!();
    println!("A) has >=1 UnsupportedGraphic block (anywhere, incl. nested table cells): {a_unsupported}");
    println!("   e.g. {:?}", a_examples);
    println!("C) sections.len() > 1 (multi-section): {c_multi_section}");
    println!("B) overlap (A and C both true): {b_overlap}");
    println!("   e.g. {:?}", overlap_examples);
    println!();
    println!("|A union C| = {a_union_c}");
    println!("A \\ C (unsupported-only, not multi-section) = {}", a_unsupported - b_overlap);
    println!();
    println!("before (current, both holes open) = 400 - |A union C| = {}", 400 - a_union_c);
    println!("after (unsupportedGraphic fixed, sections still open) = 400 - |C| = {}", 400 - c_multi_section);
}
