//! S6-6 measurement probe — NOT a gate, NOT wired into CI.
//!
//! Answers, over real documents, which of `OfficeSectionDeclaration`'s six fields with no home in
//! `wire::Section` (`office_project.rs`'s own module doc: `footnote_separator`, `page_border`,
//! `hides_header`, `hides_footer`, `hides_master_page`, `is_vertical`) real documents actually
//! declare a non-default value for — the number `Field("sections")`'s cost is measured against.
//!
//! Reads each corpus document through its own reader directly (`DocxReader::read`/
//! `OdtReader::read`/`HwpReader::read`), never through `from_office`/`project` — this is a
//! property of the READER'S OWN OUTPUT (`OfficeReadResult.sections`), independent of whether the
//! tree can carry it.
//!
//! Run:
//!
//!     FMD_OFFICE_SECTION_FIELD_CENSUS=1 cargo test -p fastdoc-engine --test office_section_field_census -- --nocapture

use fastdoc_engine::render::office::docx_reader::DocxReader;
use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::office::odt_reader::OdtReader;
use fastdoc_engine::render::office::office_block::{OfficeReadResult, OfficeSectionDeclaration};
use fastdoc_engine::render::office::zip_archive::ZipArchive;
use swiftshim::font_provider::{FaceId, FaceInfo, FontProvider};
use swiftshim::{Data, NSFontDescriptorSymbolicTraits, NSFontWeight};

use std::path::{Path, PathBuf};

/// A minimal, deterministic font world — this probe measures `OfficeReadResult.sections`, never
/// glyph metrics, so the font side only needs to be present and consistent (same posture as
/// `page_band_measure_port.rs`'s `FakeFontProvider`), never realistic.
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

/// Whether `decl` differs from `OfficeSectionDeclaration::default()` on exactly the six fields
/// `office_project.rs` names as having no home in `wire::Section`. Returns one flag per field so
/// the caller can tabulate them independently rather than as one combined yes/no.
fn declares(decl: &OfficeSectionDeclaration) -> [bool; 6] {
    let d = OfficeSectionDeclaration::default();
    [
        decl.footnote_separator.is_some(), // default is None
        decl.page_border.is_some(),        // default is None
        decl.hides_header != d.hides_header,
        decl.hides_footer != d.hides_footer,
        decl.hides_master_page != d.hides_master_page,
        decl.is_vertical != d.is_vertical,
    ]
}

#[test]
fn office_section_field_census() {
    if std::env::var("FMD_OFFICE_SECTION_FIELD_CENSUS").is_err() {
        eprintln!("skipped: set FMD_OFFICE_SECTION_FIELD_CENSUS=1 to run");
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
    // those are not a random 269, they are whatever sorts last. Ask for a cap with `FMD_SECTION_FIELD_CENSUS_LIMIT` if a
    // quick run is wanted; what it dropped is printed with the result (INVARIANTS.md 111).
    let found = files.len();
    if let Some(limit) = std::env::var("FMD_SECTION_FIELD_CENSUS_LIMIT")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
    {
        files.truncate(limit);
    }
    let dropped = found - files.len();

    const NAMES: [&str; 6] = [
        "footnote_separator",
        "page_border",
        "hides_header",
        "hides_footer",
        "hides_master_page",
        "is_vertical",
    ];

    let mut read_ok = 0usize;
    let mut multi_section = 0usize;
    let mut field_doc_counts = [0usize; 6];
    let mut examples: [Vec<String>; 6] = Default::default();

    for path in &files {
        let Some(result) = read_result(path) else { continue };
        read_ok += 1;
        if result.sections.len() > 1 {
            multi_section += 1;
        }
        let mut hit = [false; 6];
        for decl in &result.sections {
            let flags = declares(decl);
            for i in 0..6 {
                hit[i] |= flags[i];
            }
        }
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("?").to_string();
        for i in 0..6 {
            if hit[i] {
                field_doc_counts[i] += 1;
                if examples[i].len() < 5 {
                    examples[i].push(name.clone());
                }
            }
        }
    }

    println!("=== office_section_field_census ===");
    if dropped > 0 {
        println!("CAPPED: {dropped} of {found} documents were NOT examined");
    }
    println!("total examined: {}", files.len());
    println!("read successfully: {read_ok}");
    println!("multi-section (sections.len() > 1): {multi_section}");
    println!();
    for i in 0..6 {
        println!(
            "{}: {} document(s) declare non-default -- e.g. {:?}",
            NAMES[i], field_doc_counts[i], examples[i]
        );
    }
}
