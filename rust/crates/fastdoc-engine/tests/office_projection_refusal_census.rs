//! S4-03 — the refusal census.
//!
//! Every fixture this crate's own manifest (`Tests/Baseline/fixtures.json`) registers for an
//! office format is run through `ValidatedRenderTree::from_office`, and the outcome — accepted, or
//! refused with a named `OfficeAdapterError` kind — is tabulated by KIND, with the fixture names
//! that produced each kind. This is not a pass rate: a later sprint deciding whether the 바탕쪽
//! (master page) work is worth doing needs the counts and the names, not a percentage.
//!
//! Fixture universe, exactly the real documents `Tests/Baseline/fixtures.json` names for an office
//! format:
//! - the four `sources` entries (`docx`, `odt`, `hwp`, `hwpx`) — `office_reader_reachability.rs`
//!   is this file's authority for the docx/odt zip recipe and the hwp/saved paths, reproduced here
//!   (not imported: integration test binaries in this crate cannot share a `tests/` helper across
//!   files any more than across crates, `office_tree_ffi.rs`'s own doc comment says as much for the
//!   cross-crate case);
//! - the nine `featureFixtures` entries with a `sourcePath` (`office_feature_fixtures.rs` reads the
//!   same nine, over `HwpReader` directly rather than `from_office` — this file is the first to run
//!   them through the adapter).
//!
//! This census reports; it does not gate on outcome MIX. `INVARIANTS.md` 109: a real fixture can
//! move from refused to accepted the moment its own bug is fixed (S6-5a moved
//! `issue2083_hide_fill_page.hwpx` that way), so a test that requires "at least one refused" among
//! real fixtures breaks every time this crate's own goal — fewer refusals — succeeds. Whether the
//! machinery can still tell the two outcomes apart at all is proven separately, by a SYNTHETIC
//! input guaranteed to refuse by construction (`office_result_forces_missing_resource_by_omitting_the_resource_map`,
//! below) — a caller that leaves a declared resource key out of its `resources` map is a
//! programming error, not a document fact, and can never be "fixed" out of existence the way a
//! real document's own defect can.
//!
//! `OfficeAdapterError::kind_name` is the one place this bucket-name mapping is written, so this
//! census and any other caller naming a refusal never spell the same variant two different ways.

use fastdoc_engine::render::office::docx_reader::DocxReader;
use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::office::odt_reader::OdtReader;
use fastdoc_engine::render::office::office_block::{
    OfficeAnchoredObject, OfficeBlock, OfficeMasterObject, OfficeMasterObjectContent,
    OfficeReadResult,
};
use fastdoc_engine::render::office::zip_archive::ZipArchive;
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};
use swiftshim::geometry::{CGPoint, CGRect};
use swiftshim::{CGSize, SwiftString};

use std::collections::BTreeMap;
use std::path::PathBuf;

// -------------------------------------------------------------------------------------------
// Docx/odt zip bytes — the same stored-ZIP recipe `office_reader_reachability.rs` builds,
// reproduced rather than imported (see this file's own doc comment).
// -------------------------------------------------------------------------------------------

const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";
const DOCX_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>FastDoc baseline</w:t></w:r></w:p></w:body></w:document>\n";

const ODT_MANIFEST: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>\n";
const ODT_CONTENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:text><text:p>FastDoc baseline</text:p></office:text></office:body></office:document-content>\n";
const ODT_MIMETYPE: &str = "application/vnd.oasis.opendocument.text";

struct ZipEntry {
    name: &'static str,
    data: &'static [u8],
}

fn build_stored_zip(entries: &[ZipEntry]) -> Vec<u8> {
    const LOCAL_FILE_HEADER_SIG: u32 = 0x0403_4b50;
    const CENTRAL_DIRECTORY_SIG: u32 = 0x0201_4b50;
    const END_OF_CENTRAL_DIRECTORY_SIG: u32 = 0x0605_4b50;
    const DOS_DATE_1980_01_01: u16 = 0x0021;
    const DOS_TIME_MIDNIGHT: u16 = 0x0000;
    const VERSION_NEEDED: u16 = 20;
    const VERSION_MADE_BY: u16 = (3u16 << 8) | 20;
    const EXTERNAL_ATTR_0100644: u32 = 0o100644 << 16;

    let mut body = Vec::new();
    let mut central = Vec::new();

    for entry in entries {
        let name = entry.name.as_bytes();
        let data = entry.data;
        let crc = crc32(data);
        let offset = body.len() as u32;

        body.extend_from_slice(&LOCAL_FILE_HEADER_SIG.to_le_bytes());
        body.extend_from_slice(&VERSION_NEEDED.to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes());
        body.extend_from_slice(&DOS_TIME_MIDNIGHT.to_le_bytes());
        body.extend_from_slice(&DOS_DATE_1980_01_01.to_le_bytes());
        body.extend_from_slice(&crc.to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&(name.len() as u16).to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes());
        body.extend_from_slice(name);
        body.extend_from_slice(data);

        central.extend_from_slice(&CENTRAL_DIRECTORY_SIG.to_le_bytes());
        central.extend_from_slice(&VERSION_MADE_BY.to_le_bytes());
        central.extend_from_slice(&VERSION_NEEDED.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&DOS_TIME_MIDNIGHT.to_le_bytes());
        central.extend_from_slice(&DOS_DATE_1980_01_01.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&EXTERNAL_ATTR_0100644.to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name);
    }

    let central_offset = body.len() as u32;
    let central_size = central.len() as u32;
    let mut out = body;
    out.extend_from_slice(&central);
    out.extend_from_slice(&END_OF_CENTRAL_DIRECTORY_SIG.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn docx_zip_bytes() -> Vec<u8> {
    let mut entries = vec![
        ZipEntry { name: "[Content_Types].xml", data: DOCX_CONTENT_TYPES.as_bytes() },
        ZipEntry { name: "_rels/.rels", data: DOCX_RELS.as_bytes() },
        ZipEntry { name: "word/document.xml", data: DOCX_DOCUMENT_XML.as_bytes() },
    ];
    entries.sort_by_key(|e| e.name);
    build_stored_zip(&entries)
}

fn odt_zip_bytes() -> Vec<u8> {
    let mut rest = vec![
        ZipEntry { name: "META-INF/manifest.xml", data: ODT_MANIFEST.as_bytes() },
        ZipEntry { name: "content.xml", data: ODT_CONTENT_XML.as_bytes() },
    ];
    rest.sort_by_key(|e| e.name);
    let mut entries = vec![ZipEntry { name: "mimetype", data: ODT_MIMETYPE.as_bytes() }];
    entries.extend(rest);
    build_stored_zip(&entries)
}

/// `Vendor/rhwp-src/<subdir>/<name>`, resolved from `CARGO_MANIFEST_DIR` (this crate is
/// `rust/crates/fastdoc-engine`; the vendor tree is three levels up at `rust/../Vendor`), matching
/// `office_reader_reachability.rs`'s and `office_feature_fixtures.rs`'s own helpers.
fn rhwp_fixture(subdir: &str, name: &str) -> Vec<u8> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../..").join("Vendor/rhwp-src").join(subdir).join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

// -------------------------------------------------------------------------------------------
// The census.
// -------------------------------------------------------------------------------------------

/// `Ok("accepted")` or the `OfficeAdapterError::kind_name` string — the one outcome vocabulary this file
/// tabulates over.
fn outcome_for(format: DocumentFormat, source_name: &str, source_bytes: &[u8]) -> String {
    let result = match format {
        DocumentFormat::Docx => {
            let archive = ZipArchive::new(swiftshim::Data::fromBytes(source_bytes.to_vec()))
                .unwrap_or_else(|e| panic!("{source_name}: not a valid zip: {e:?}"));
            DocxReader::read(&archive)
                .unwrap_or_else(|e| panic!("{source_name}: DocxReader::read failed: {e}"))
        }
        DocumentFormat::Odt => {
            let archive = ZipArchive::new(swiftshim::Data::fromBytes(source_bytes.to_vec()))
                .unwrap_or_else(|e| panic!("{source_name}: not a valid zip: {e:?}"));
            OdtReader::read(&archive)
                .unwrap_or_else(|e| panic!("{source_name}: OdtReader::read failed: {e:?}"))
        }
        DocumentFormat::Hwp | DocumentFormat::Hwpx => {
            HwpReader::read_before_host_font_substitution(&swiftshim::Data::fromBytes(
                source_bytes.to_vec(),
            ))
            .unwrap_or_else(|e| panic!("{source_name}: HwpReader::read failed: {e:?}"))
        }
        DocumentFormat::Markdown | DocumentFormat::PlainText => {
            panic!("{source_name}: this census covers office formats only")
        }
    };

    match ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name,
        source_bytes,
        result: &result,
        resources: BTreeMap::new(),
    }) {
        Ok(_) => "accepted".to_string(),
        Err(error) => error.kind_name().to_string(),
    }
}

/// Every registered fixture this file's doc comment enumerates: `(format, name, bytes)`.
fn registered_fixtures() -> Vec<(DocumentFormat, &'static str, Vec<u8>)> {
    vec![
        // `sources` (docx/odt/hwp/hwpx) — `Tests/Baseline/fixtures.json`.
        (DocumentFormat::Docx, "sources/docx", docx_zip_bytes()),
        (DocumentFormat::Odt, "sources/odt", odt_zip_bytes()),
        (DocumentFormat::Hwp, "sources/hwp (blank2010.hwp)", rhwp_fixture("saved", "blank2010.hwp")),
        (
            DocumentFormat::Hwpx,
            "sources/hwpx (hwpx-01-saved.hwpx)",
            rhwp_fixture("saved", "hwpx-01-saved.hwpx"),
        ),
        // `featureFixtures` with a `sourcePath` — `Tests/Baseline/fixtures.json`.
        (
            DocumentFormat::Hwp,
            "feature-multi-column-hwp (SO-SUEOP.hwp)",
            rhwp_fixture("samples", "SO-SUEOP.hwp"),
        ),
        (
            DocumentFormat::Hwpx,
            "feature-multi-column-hwpx (SO-SUEOP.hwpx)",
            rhwp_fixture("samples", "SO-SUEOP.hwpx"),
        ),
        (
            DocumentFormat::Hwp,
            "feature-diagonal-hwp (대각선샘플.hwp)",
            rhwp_fixture("samples", "대각선샘플.hwp"),
        ),
        (
            DocumentFormat::Hwpx,
            "feature-diagonal-hwpx (대각선샘플.hwpx)",
            rhwp_fixture("samples", "대각선샘플.hwpx"),
        ),
        (
            DocumentFormat::Hwp,
            "feature-form-control-hwp (form-02.hwp)",
            rhwp_fixture("samples", "form-02.hwp"),
        ),
        (
            DocumentFormat::Hwpx,
            "feature-form-control-hwpx (hwpx/form-02.hwpx)",
            rhwp_fixture("samples/hwpx", "form-02.hwpx"),
        ),
        (
            DocumentFormat::Hwp,
            "feature-nested-table-hwp (tac-img-02.hwp)",
            rhwp_fixture("samples", "tac-img-02.hwp"),
        ),
        (
            DocumentFormat::Hwpx,
            "feature-nested-table-hwpx (tac-img-02.hwpx)",
            rhwp_fixture("samples", "tac-img-02.hwpx"),
        ),
        (
            DocumentFormat::Hwpx,
            "feature-picture-fill-refusal-hwpx (issue2083_hide_fill_page.hwpx)",
            rhwp_fixture("samples", "issue2083_hide_fill_page.hwpx"),
        ),
        // S6-5a fixed the bug this fixture's NAME describes (a declared picture with no bytes
        // behind it now renders an intentionally empty box, parity with the shipped Swift reader,
        // instead of refusing the whole document — `OfficeReadResult
        // .pictures_declared_without_bytes`) — so this entry is `accepted` now. Left in place
        // rather than removed: the census's job is to report what real fixtures actually do, and
        // "used to refuse, now doesn't" is itself the evidence the fix landed. See this file's own
        // doc comment for why nothing here asserts a minimum refused count any more.
    ]
}

/// S4-03's own deliverable: every registered fixture run through `from_office`, tabulated by
/// outcome kind, with the fixture names each kind maps to. Printed unconditionally (`--nocapture`
/// shows it; the leader reads it from there) rather than only on failure, because the table IS
/// the evidence, not a diagnostic for when something goes wrong.
#[test]
fn refusal_census_over_every_registered_fixture() {
    let fixtures = registered_fixtures();
    let mut by_kind: BTreeMap<String, Vec<&'static str>> = BTreeMap::new();

    for (format, name, bytes) in &fixtures {
        let kind = outcome_for(*format, name, bytes);
        by_kind.entry(kind).or_default().push(name);
    }

    println!("\n=== S4-03 refusal census ({} fixtures) ===", fixtures.len());
    println!("{:<55} | {:>5} | fixtures", "outcome kind", "count");
    let mut total = 0usize;
    for (kind, names) in &by_kind {
        println!("{:<55} | {:>5} | {}", kind, names.len(), names.join(", "));
        total += names.len();
    }
    println!("=== end census ===\n");

    // Self-consistency: the table's own counts must sum back to the fixture count — a tabulation
    // bug (a fixture counted twice, or dropped) would otherwise pass silently.
    assert_eq!(
        total,
        fixtures.len(),
        "the census table's counts must sum to the fixture count"
    );

    // Only a floor on ACCEPTED, never on refused — see this file's own doc comment
    // (`INVARIANTS.md` 109): a real fixture's refusal is a bug report, and this crate's whole
    // point is to make those go away. A census that required at least one refused real fixture
    // would fail on the day every one of them is finally fixed, which is success, not a
    // regression. Whether refusal itself still works is proven separately, by a synthetic input
    // guaranteed to refuse by construction — see
    // `office_result_forces_missing_resource_by_omitting_the_resource_map` below.
    assert!(
        by_kind.contains_key("accepted"),
        "expected at least one fixture to be accepted by from_office; census: {by_kind:?}"
    );
}

/// The corroboration `refusal_census_over_every_registered_fixture` used to get from "at least
/// one real fixture refuses" — removed because that made the census fail on the day this crate
/// succeeds at its own goal (`INVARIANTS.md` 109). This proves the SAME thing (the adapter can
/// still refuse, and `outcome_for`/`kind_name` can still NAME the refusal) with an input
/// that refuses by CONSTRUCTION rather than by a real document's current defect.
///
/// It used to use a missing resource key. P2c made that case legal — an unresolved key is now
/// carried by reference for the host to fetch — so the construction moved to an anchored object
/// naming a block index that does not exist. That is a reader-contract violation rather than a
/// document fact (`mapping.rs` leaves an empty paragraph carrier at every anchored index rather
/// than dropping the block), so like the old one it can never stop refusing the way a real
/// fixture's bug can.
#[test]
fn office_result_forces_a_refusal_by_anchoring_to_a_block_that_does_not_exist() {
    let mut result = OfficeReadResult::default();
    result.anchored_objects.push(OfficeAnchoredObject {
        block_index: 99,
        object: OfficeMasterObject {
            frame: CGRect {
                origin: CGPoint { x: 0.0, y: 0.0 },
                size: CGSize { width: 10.0, height: 10.0 },
            },
            content: OfficeMasterObjectContent::Text(Vec::new()),
        },
        paragraph_anchor: None,
    });

    let err = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Docx,
        source_name: "synthetic.docx",
        source_bytes: &[],
        result: &result,
        resources: BTreeMap::new(),
    })
    .expect_err("an anchored object naming no block must refuse, by construction");

    assert_eq!(
        err,
        fastdoc_engine::render::render_tree::OfficeAdapterError::AnchoredObjectTargetMissing(99),
        "expected exactly the anchored-target refusal, got a different kind: {err:?}"
    );
}
