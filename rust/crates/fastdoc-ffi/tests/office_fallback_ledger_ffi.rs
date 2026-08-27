//! S4-05 (the fallback ledger) and S4-07 (`fastdoc_read_office_json` rewired through the tree) —
//! exercised through the real `extern "C"` symbol, not the crate's private Rust functions, same
//! discipline `office_tree_ffi.rs` already establishes for `fastdoc_read_office_tree`.
//!
//! Two failure directions this sprint must not change, each its own test:
//! - a fixture `from_office` and `project` both accept must come back from `fastdoc_read_office_json`
//!   IDENTICAL (canonically) to `office_project::project`'s own output — the tree path, not a
//!   coincidence that it matches;
//! - a fixture `from_office` refuses must come back IDENTICAL to `office_export::to_json`'s own
//!   output — exactly what this export returned before S4-07, because the fallback exists so that
//!   direction never regresses.
//!
//! The ledger cross-check (S4-05's real acceptance) rides on the SAME calls: for each refused
//! fixture, `from_office` is called directly to name the expected kind, `fastdoc_read_office_json`
//! is called through the real FFI symbol (which records into the SAME in-process ledger via
//! `projection_ledger`), and the two are compared per kind — not "the ledger is non-empty", which
//! would still pass if every refusal but one were swallowed.

use fastdoc_engine::render::office::docx_reader::DocxReader;
use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::office::office_export::to_json;
use fastdoc_engine::render::office::office_project::project;
use fastdoc_engine::render::office::projection_ledger;
use fastdoc_engine::render::office::zip_archive::ZipArchive;
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};

use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::path::PathBuf;

// -------------------------------------------------------------------------------------------
// Fixture bytes — same recipe `office_tree_ffi.rs` and `office_reader_reachability.rs` use,
// reproduced rather than imported (integration test binaries cannot share a `tests/` helper
// across files, per `office_tree_ffi.rs`'s own doc comment).
// -------------------------------------------------------------------------------------------

const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";
const DOCX_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>FastDoc baseline</w:t></w:r></w:p></w:body></w:document>\n";

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

/// A docx with ONE inline picture (`w:drawing`/`a:blip r:embed="rId2"`) whose relationship
/// resolves to `media/image1.png` — a path this zip never actually stores. That absence does not
/// matter to `DocxReader::read`: `OfficeBlock::Image.id` is the relationship TARGET string
/// (`part_b.rs::resolve_id`), not a lookup into the archive, so this document reads cleanly and
/// hands the adapter one `.image(id: "media/image1.png")`. The refusal this fixture exists to
/// prove comes from a different, PERMANENT fact: `call_read_office_json`'s own FFI contract
/// always supplies an EMPTY `resources` map (see the doc comment on the test below), and docx has
/// no `OfficeReadResult.images` pre-decode (that is HWP-only — the zip readers resolve pixels
/// lazily from the archive at reconcile time, which this synthetic path never reaches). So this
/// key can resolve through NEITHER map, `MissingResource` fires, and it will keep firing exactly
/// as long as `call_read_office_json` keeps its resources map empty — a structural property of
/// the export, not a bug some future sprint will fix out from under this test (unlike a real
/// document picked for CURRENTLY having a defect, which the fix this sprint exists to make stops
/// having).
const DOCX_RELS_WITH_IMAGE: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image1.png\"/></Relationships>\n";
const DOCX_DOCUMENT_XML_WITH_IMAGE: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body><w:p><w:r><w:drawing><wp:extent cx=\"914400\" cy=\"914400\"/><a:blip r:embed=\"rId2\"/></w:drawing></w:r></w:p></w:body></w:document>\n";

fn docx_zip_bytes_with_unresolvable_image() -> Vec<u8> {
    let mut entries = vec![
        ZipEntry { name: "[Content_Types].xml", data: DOCX_CONTENT_TYPES.as_bytes() },
        ZipEntry { name: "_rels/.rels", data: DOCX_RELS.as_bytes() },
        ZipEntry { name: "word/_rels/document.xml.rels", data: DOCX_RELS_WITH_IMAGE.as_bytes() },
        ZipEntry { name: "word/document.xml", data: DOCX_DOCUMENT_XML_WITH_IMAGE.as_bytes() },
    ];
    entries.sort_by_key(|e| e.name);
    build_stored_zip(&entries)
}

/// `Vendor/rhwp-src/<subdir>/<name>`, resolved from `CARGO_MANIFEST_DIR` — this crate is
/// `rust/crates/fastdoc-ffi`, matching `office_tree_ffi.rs::rhwp_saved_fixture`.
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
// FFI call helper.
// -------------------------------------------------------------------------------------------

/// Calls the real `fastdoc_read_office_json` export and returns its payload as an owned `String`
/// (or `None` for NULL), freeing the FFI-owned pointer the same way a real host must.
///
/// # Safety
/// `data`/`extension` are local bindings kept alive for the whole call, matching every other use
/// of this pattern in this crate's test suite.
fn call_read_office_json(data: &[u8], extension: &str) -> Option<String> {
    let extension_c = CString::new(extension).unwrap();
    let ptr = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_json(data.as_ptr(), data.len(), extension_c.as_ptr())
    };
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(ptr) };
    Some(text)
}

/// Canonical `serde_json::Value` equality — same instrument `office_projection_oracle.rs` (S4-02)
/// proves and uses, because `OfficeReadResult`'s `HashMap` fields make byte equality meaningless
/// (`office_block.rs:2037-2063`).
/// This binary's three tests share ONE in-process ledger (`projection_ledger` is a process-wide
/// `static`) — the two tests that read it must not run concurrently with each other, or one
/// test's `clear()`/entries interleave with another's. `cargo test` runs test FUNCTIONS within a
/// binary on a thread pool by default; this lock serializes just the ledger-touching tests
/// without forcing the whole binary to `--test-threads=1`.
static LEDGER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn assert_canonically_equal(a: &str, b: &str, context: &str) {
    let va: serde_json::Value = serde_json::from_str(a).unwrap_or_else(|e| panic!("{context}: left is not JSON: {e}"));
    let vb: serde_json::Value = serde_json::from_str(b).unwrap_or_else(|e| panic!("{context}: right is not JSON: {e}"));
    assert_eq!(va, vb, "{context}: canonical JSON disagrees");
}

// -------------------------------------------------------------------------------------------
// S4-07: a fixture the tree accepts comes back from the tree path.
// -------------------------------------------------------------------------------------------

#[test]
fn an_accepted_fixture_comes_back_from_the_projection_path() {
    let bytes = docx_zip_bytes();
    let archive =
        fastdoc_engine::render::office::zip_archive::ZipArchive::new(swiftshim::Data::fromBytes(bytes.clone()))
            .expect("valid zip");
    let result = fastdoc_engine::render::office::docx_reader::DocxReader::read(&archive)
        .expect("DocxReader::read succeeds on this fixture");
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Docx,
        source_name: "document.docx",
        source_bytes: &bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .expect("this fixture is accepted by from_office");
    let projected = project(&tree).expect("this fixture is accepted by project");

    let ffi_output =
        call_read_office_json(&bytes, "docx").expect("fastdoc_read_office_json must not return NULL");

    assert_canonically_equal(
        &ffi_output,
        &projected,
        "accepted fixture: FFI output must equal project(tree) directly",
    );
}

// -------------------------------------------------------------------------------------------
// S4-07: a fixture the tree refuses comes back exactly as it did before this sprint, AND
// S4-05: the ledger records it under the same kind `from_office` produced directly.
// -------------------------------------------------------------------------------------------

/// This fixture used to be a real HWP document picked because it CURRENTLY had a defect
/// (`SO-SUEOP.hwp`, `MissingResource("hwpshape:1")`, then `59043_regulatory_analysis.hwp`,
/// `Canonicalization("cell padding is invalid")`) — the wrong direction, per `INVARIANTS.md` 109:
/// a test that needs a real document to STAY broken breaks again every time that document gets
/// fixed, and the fix is exactly this roadmap's job. `docx_zip_bytes_with_unresolvable_image`
/// (above) refuses for a reason that is a PERMANENT property of the export being tested here, not
/// a defect this or any future sprint will remove: `call_read_office_json` always calls
/// `from_office` with an empty `resources` map (S4-07's own design — unchanged from
/// `fastdoc_read_office_tree`'s pre-existing behaviour), and docx has no reader-side pre-decode to
/// fall back on (that is HWP-only), so ANY docx declaring an image refuses at this FFI boundary,
/// forever, by construction.
#[test]
fn a_refused_fixture_still_comes_back_from_the_reader_path_and_the_ledger_names_it() {
    let _lock = LEDGER_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let bytes = docx_zip_bytes_with_unresolvable_image();
    let archive = ZipArchive::new(swiftshim::Data::fromBytes(bytes.clone()))
        .unwrap_or_else(|e| panic!("not a valid zip: {e:?}"));
    let result =
        DocxReader::read(&archive).unwrap_or_else(|e| panic!("DocxReader::read failed: {e}"));

    let expected_kind = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Docx,
        source_name: "document.docx",
        source_bytes: &bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .err()
    .map(|e| projection_ledger::adapter_error_kind(&e).to_string())
    .expect("this fixture is refused by from_office (an unresolvable image, by construction)");

    let reader_json = to_json(&result).expect("to_json accepts this fixture (no master page/anchored object)");

    projection_ledger::clear();
    let ffi_output =
        call_read_office_json(&bytes, "docx").expect("fastdoc_read_office_json must not return NULL");

    assert_canonically_equal(
        &ffi_output,
        &reader_json,
        "refused fixture: FFI output must equal office_export::to_json unchanged",
    );

    let entries = projection_ledger::snapshot();
    let matching: Vec<_> = entries
        .iter()
        .filter(|e| e.document_name == "document.docx" && e.kind == expected_kind)
        .collect();
    assert_eq!(
        matching.len(),
        1,
        "expected exactly one ledger entry for document.docx under kind {expected_kind:?}, got: {entries:?}"
    );
}

// -------------------------------------------------------------------------------------------
// S4-05's real acceptance: a per-kind CROSS-CHECK between refusals counted directly and
// refusals the ledger recorded through the FFI symbol, over several fixtures at once — never a
// non-emptiness assertion, which forty-nine swallowed refusals out of fifty would still pass.
// -------------------------------------------------------------------------------------------

#[test]
fn the_ledgers_per_kind_counts_match_from_office_called_directly_over_several_fixtures() {
    let _lock = LEDGER_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let fixtures: Vec<(DocumentFormat, &str, Vec<u8>)> = vec![
        (DocumentFormat::Hwp, "so-sueop.hwp", rhwp_fixture("samples", "SO-SUEOP.hwp")),
        (
            DocumentFormat::Hwp,
            "tac-img-02.hwp",
            rhwp_fixture("samples", "tac-img-02.hwp"),
        ),
        (
            DocumentFormat::Hwpx,
            "issue2083_hide_fill_page.hwpx",
            rhwp_fixture("samples", "issue2083_hide_fill_page.hwpx"),
        ),
    ];

    // `fastdoc_read_office_json` never sees a fixture's real file name — it synthesizes
    // `source_name` as `document.<extension>` (S4-07's design; unchanged from
    // `fastdoc_read_office_tree`'s own pre-existing behaviour), so the direct call below uses the
    // SAME synthesized name rather than each fixture's own label, or a per-fixture
    // `document_name` comparison against the ledger would never match.
    projection_ledger::clear();
    let mut expected_by_kind: BTreeMap<String, usize> = BTreeMap::new();

    for (format, name, bytes) in &fixtures {
        let result = HwpReader::read_before_host_font_substitution(&swiftshim::Data::fromBytes(bytes.clone()))
            .unwrap_or_else(|e| panic!("{name}: HwpReader::read failed: {e:?}"));
        let extension = if matches!(format, DocumentFormat::Hwpx) { "hwpx" } else { "hwp" };
        let source_name = format!("document.{extension}");
        let direct = ValidatedRenderTree::from_office(OfficeAdapterInput {
            format: *format,
            source_name: &source_name,
            source_bytes: bytes,
            result: &result,
            resources: BTreeMap::new(),
        });
        // The ledger records BOTH layers the FFI symbol walks, so the expected side must walk
        // both too. Counting only the adapter's refusals leaves the export layer unwitnessed: a
        // document the adapter ACCEPTS goes on to `project`, and a refusal swallowed there would
        // never appear on this side of the comparison. Measured — `issue2083_hide_fill_page.hwpx`
        // declares three sections, so it clears the adapter and is refused by `project` as
        // `Field("sections")`; before S6-4 the adapter refused it first and the export layer was
        // never reached, which is how this hole stayed invisible.
        match &direct {
            Err(error) => {
                *expected_by_kind
                    .entry(projection_ledger::adapter_error_kind(error).to_string())
                    .or_default() += 1;
            }
            Ok(tree) => {
                if let Err(error) = project(tree) {
                    *expected_by_kind
                        .entry(projection_ledger::projection_error_kind(&error))
                        .or_default() += 1;
                }
            }
        }

        // Drive the SAME bytes through the real FFI symbol — the ledger records this call
        // itself, not the `direct` call above.
        let _ = call_read_office_json(bytes, extension);
    }

    assert!(
        !expected_by_kind.is_empty(),
        "this fixture set must contain at least one refusal for the cross-check to be meaningful"
    );

    // The ledger's whole snapshot IS this test's window: it was cleared immediately above and
    // `LEDGER_TEST_LOCK` keeps every other test in this binary from writing to it meanwhile, so
    // every entry present now was produced by one of the three FFI calls just made — no
    // `document_name` filter is needed to isolate them.
    let ledger = projection_ledger::snapshot();
    let mut actual_by_kind: BTreeMap<String, usize> = BTreeMap::new();
    for entry in &ledger {
        *actual_by_kind.entry(entry.kind.clone()).or_default() += 1;
    }

    assert_eq!(
        actual_by_kind, expected_by_kind,
        "ledger's per-kind counts (from the real FFI symbol) must equal from_office's own \
         per-kind counts (called directly on the same bytes) — a non-emptiness check would pass \
         even if some refusals were swallowed"
    );
}
