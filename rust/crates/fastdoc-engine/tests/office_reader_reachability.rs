//! S2A2 Pass C, unit C item S2A2-07's reachability half.
//!
//! Every other test touching `ValidatedRenderTree::from_office` (`render_tree_v1.rs`) starts from
//! a hand-built `OfficeReadResult` — synthetic JSON, never a real parser. The only test that opens
//! a real HWP/HWPX file is `hwp_column_key_parity.rs`, and it is `#[ignore]`d by default (it needs
//! a corpus this repo does not ship) and never reaches `from_office` at all. So nothing in this
//! crate proves the chain real bytes -> real reader -> `OfficeReadResult` -> `from_office` ->
//! wire JSON -> decode actually holds for any of the four Office formats. This file closes that
//! gap, unconditionally (no env gate, no `#[ignore]`) — it runs on every `cargo test`.
//!
//! Fixtures, byte for byte:
//! - DOCX/ODT: generated in-process by `docx_zip`/`odt_zip` below, which reproduce
//!   `Scripts/rust-baseline.py`'s `zipbytes()` recipe (stored-only ZIP, fixed 1980-01-01 mtime,
//!   `create_system=3`, `external_attr=0o100644<<16`) byte for byte. Each is asserted against the
//!   `expectedSha256` recorded for it in `Tests/Baseline/fixtures.json`, so this is not "a docx
//!   that parses" — it is *the* docx the baseline provenance already committed to.
//! - HWP/HWPX: real files already vendored for the rhwp submodule
//!   (`Vendor/rhwp-src/saved/blank2010.hwp`, `.../hwpx-01-saved.hwpx`), read from disk relative to
//!   `CARGO_MANIFEST_DIR` — never an absolute author path.

use fastdoc_engine::render::office::docx_reader::DocxReader;
use fastdoc_engine::render::office::hwp_reader::HwpReader;
use fastdoc_engine::render::office::odt_reader::OdtReader;
use fastdoc_engine::render::office::zip_archive::ZipArchive;
use fastdoc_engine::render::render_tree::{
    DocumentFormat, OfficeAdapterInput, ValidatedRenderTree,
};
use swiftshim::Data;

use std::collections::BTreeMap;
use std::path::PathBuf;

// ---------------------------------------------------------------------------------------------
// Fixture bytes
// ---------------------------------------------------------------------------------------------

/// The exact XML payloads `Scripts/rust-baseline.py`'s `ZIP_XML` dict holds — copied verbatim,
/// byte for byte, including trailing newlines. Changing a single byte here changes the sha256
/// this test asserts against, which is the whole point: it proves this function is not merely "a
/// docx" but the one the baseline manifest already recorded provenance for.
const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";
const DOCX_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>FastDoc baseline</w:t></w:r></w:p></w:body></w:document>\n";

const ODT_MANIFEST: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>\n";
const ODT_CONTENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:text><text:p>FastDoc baseline</text:p></office:text></office:body></office:document-content>\n";
const ODT_MIMETYPE: &str = "application/vnd.oasis.opendocument.text";

/// The `expectedSha256` this fixture id carries in `Tests/Baseline/fixtures.json`, read from the
/// manifest at test time rather than copied into a constant here. A copy would go stale silently:
/// change the recipe, update the manifest, and a duplicated literal keeps asserting the old digest
/// while reporting success. The manifest is the single authority for a fixture's provenance, so the
/// test asks it.
fn manifest_expected_sha256(fixture_id: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("Tests/Baseline/fixtures.json");
    let bytes = std::fs::read(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture manifest {} ({e})", path.display()));
    let manifest: serde_json::Value = serde_json::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("fixture manifest {} is not valid JSON ({e})", path.display()));
    let sources = manifest["sources"]
        .as_array()
        .unwrap_or_else(|| panic!("fixture manifest has no `sources` array"));
    let entry = sources
        .iter()
        .find(|s| s["id"].as_str() == Some(fixture_id))
        .unwrap_or_else(|| panic!("fixture manifest declares no source with id {fixture_id:?}"));
    entry["expectedSha256"]
        .as_str()
        .unwrap_or_else(|| panic!("fixture {fixture_id:?} has no `expectedSha256` in the manifest"))
        .to_string()
}

/// A stored-only ZIP entry, laid out exactly as `zipfile.ZipInfo(name, (1980,1,1,0,0,0))` with
/// `create_system=3` and `external_attr=0o100644<<16` produces it — the fields
/// `Scripts/rust-baseline.py:133-145` pins.
struct ZipEntry {
    name: &'static str,
    data: &'static [u8],
}

/// Builds a stored-only ZIP archive from `entries`, IN ORDER — the caller is responsible for
/// sorting (docx: plain sort; odt: `mimetype` first, then sorted) exactly as
/// `Scripts/rust-baseline.py:zipbytes()` does, since entry order is part of the byte-identical
/// contract this test proves against `expectedSha256`.
fn build_stored_zip(entries: &[ZipEntry]) -> Vec<u8> {
    const LOCAL_FILE_HEADER_SIG: u32 = 0x0403_4b50;
    const CENTRAL_DIRECTORY_SIG: u32 = 0x0201_4b50;
    const END_OF_CENTRAL_DIRECTORY_SIG: u32 = 0x0605_4b50;
    const DOS_DATE_1980_01_01: u16 = 0x0021; // (0 << 9) | (1 << 5) | 1
    const DOS_TIME_MIDNIGHT: u16 = 0x0000;
    const VERSION_NEEDED: u16 = 20;
    const VERSION_MADE_BY: u16 = (3u16 << 8) | 20; // create_system=3 (unix), version=20
    const EXTERNAL_ATTR_0100644: u32 = 0o100644 << 16;

    let mut body = Vec::new();
    let mut central = Vec::new();

    for entry in entries {
        let name = entry.name.as_bytes();
        let data = entry.data;
        let crc = crc32(data);
        let offset = body.len() as u32;

        // Local file header (30 bytes + name, no extra field).
        body.extend_from_slice(&LOCAL_FILE_HEADER_SIG.to_le_bytes());
        body.extend_from_slice(&VERSION_NEEDED.to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes()); // general purpose flag
        body.extend_from_slice(&0u16.to_le_bytes()); // compression method: stored
        body.extend_from_slice(&DOS_TIME_MIDNIGHT.to_le_bytes());
        body.extend_from_slice(&DOS_DATE_1980_01_01.to_le_bytes());
        body.extend_from_slice(&crc.to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes()); // compressed size
        body.extend_from_slice(&(data.len() as u32).to_le_bytes()); // uncompressed size
        body.extend_from_slice(&(name.len() as u16).to_le_bytes());
        body.extend_from_slice(&0u16.to_le_bytes()); // extra field length
        body.extend_from_slice(name);
        body.extend_from_slice(data);

        // Central directory entry (46 bytes + name, no extra field, no comment).
        central.extend_from_slice(&CENTRAL_DIRECTORY_SIG.to_le_bytes());
        central.extend_from_slice(&VERSION_MADE_BY.to_le_bytes());
        central.extend_from_slice(&VERSION_NEEDED.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // general purpose flag
        central.extend_from_slice(&0u16.to_le_bytes()); // compression method
        central.extend_from_slice(&DOS_TIME_MIDNIGHT.to_le_bytes());
        central.extend_from_slice(&DOS_DATE_1980_01_01.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // extra field length
        central.extend_from_slice(&0u16.to_le_bytes()); // comment length
        central.extend_from_slice(&0u16.to_le_bytes()); // disk number start
        central.extend_from_slice(&0u16.to_le_bytes()); // internal file attributes
        central.extend_from_slice(&EXTERNAL_ATTR_0100644.to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name);
    }

    let central_offset = body.len() as u32;
    let central_size = central.len() as u32;
    let mut out = body;
    out.extend_from_slice(&central);
    out.extend_from_slice(&END_OF_CENTRAL_DIRECTORY_SIG.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // this disk number
    out.extend_from_slice(&0u16.to_le_bytes()); // disk with central directory start
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes()); // entries on this disk
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes()); // entries total
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment length
    out
}

/// IEEE 802.3 CRC-32 (the ZIP format's checksum), computed byte at a time — no external crate:
/// `flate2` (this workspace's only zip-adjacent dependency) exposes no CRC32 API without a feature
/// this crate does not enable, and the table-driven form is the standard textbook one, unchanged
/// from any reference implementation.
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

fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(data))
}

/// Reproduces `zipbytes("docx")`: plain sorted entry order.
fn docx_zip_bytes() -> Vec<u8> {
    let mut entries = vec![
        ZipEntry { name: "[Content_Types].xml", data: DOCX_CONTENT_TYPES.as_bytes() },
        ZipEntry { name: "_rels/.rels", data: DOCX_RELS.as_bytes() },
        ZipEntry { name: "word/document.xml", data: DOCX_DOCUMENT_XML.as_bytes() },
    ];
    entries.sort_by_key(|e| e.name);
    build_stored_zip(&entries)
}

/// Reproduces `zipbytes("odt")`: `mimetype` first, then the rest sorted —
/// `Scripts/rust-baseline.py:138-140`.
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

/// `Vendor/rhwp-src/saved/<name>`, resolved from `CARGO_MANIFEST_DIR` (this crate is
/// `rust/crates/fastdoc-engine`; the vendor tree is three levels up, at `rust/../Vendor`) — never
/// an absolute author path.
fn rhwp_saved_fixture(name: &str) -> Vec<u8> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir
        .join("../../..")
        .join("Vendor/rhwp-src/saved")
        .join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

/// `Vendor/rhwp-src/samples/<name>` — the larger corpus vendored for the `hwp_column_key_parity`
/// probe, read the same way `rhwp_saved_fixture` reads `/saved` (relative to `CARGO_MANIFEST_DIR`,
/// never an absolute author path). Neither `/saved` fixture declares a column layout, so a column
/// reachability proof needs a file from here instead.
fn rhwp_sample_fixture(name: &str) -> Vec<u8> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir
        .join("../../..")
        .join("Vendor/rhwp-src/samples")
        .join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

// ---------------------------------------------------------------------------------------------
// The chain each format must complete: real bytes -> real reader -> OfficeReadResult ->
// from_office -> encode -> decode -> re-encode == encode.
// ---------------------------------------------------------------------------------------------

/// HWP/HWPX go through `HwpReader::read_before_host_font_substitution`, not `::read` — `::read`
/// resolves fonts against a host `swiftshim::font_provider::FontProvider`, which is installed by
/// the macOS app process this crate is embedded in, not by a Rust integration test (there is no
/// mock `FontProvider` anywhere in this repo to install one with). The
/// `_before_host_font_substitution` path is the reader's own documented split for exactly this: a
/// host that owns font discovery separately (`mapping.rs`'s doc comment on that function). It is
/// still the real reader parsing real bytes — only the font-resolution sub-step is deferred.
fn assert_reachable(
    format: DocumentFormat,
    source_name: &str,
    source_bytes: &[u8],
    result: &fastdoc_engine::render::office::office_block::OfficeReadResult,
    declared_text: Option<&str>,
) {
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name,
        source_bytes,
        result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("{source_name}: from_office failed: {e:?}"));

    let encoded = tree.encode_json().unwrap_or_else(|e| panic!("{source_name}: encode_json failed: {e:?}"));
    let decoded = ValidatedRenderTree::decode_json(&encoded)
        .unwrap_or_else(|e| panic!("{source_name}: decode_json of its own encode failed: {e:?}"));
    let re_encoded = decoded.encode_json().unwrap_or_else(|e| panic!("{source_name}: re-encode failed: {e:?}"));
    assert_eq!(encoded, re_encoded, "{source_name}: encode -> decode -> encode is not stable");
    assert_eq!(decoded.schema_version(), 1);

    // Stability alone is a hollow gate: an adapter that emitted an EMPTY document round-trips
    // perfectly, and a wire schema that silently drops a field drops it from both sides of
    // `encoded == re_encoded` identically. Both assertions below tie the tree back to the bytes
    // the reader actually parsed, which is the only thing that makes this a reachability proof.
    let tags = tree.node_tags();
    assert!(
        !tags.is_empty(),
        "{source_name}: the adapter produced a tree with no nodes — the chain did not error, but nothing from the document survived"
    );
    assert_eq!(
        decoded.node_tags(),
        tags,
        "{source_name}: the node tags did not survive decode"
    );
    // Binary provenance is a claim about THESE bytes. Nothing else in the suite ties the recorded
    // source hash back to the input, so a fabricated digest would travel unnoticed.
    let doc: serde_json::Value = serde_json::from_slice(&encoded).expect("encoded tree is JSON");
    let sources = doc["sources"].as_array().expect("sources array");
    assert_eq!(sources.len(), 1, "{source_name}: expected exactly one source descriptor");
    assert_eq!(
        sources[0]["sha256"].as_str(),
        Some(sha256_hex(source_bytes).as_str()),
        "{source_name}: the recorded source sha256 is not the digest of the bytes that were read"
    );

    if let Some(text) = declared_text {
        let encoded_text = String::from_utf8_lossy(&encoded);
        assert!(
            encoded_text.contains(text),
            "{source_name}: the document declares {text:?} but it is absent from the encoded tree"
        );
    }
}

#[test]
fn docx_bytes_match_the_baseline_manifest_sha256() {
    let bytes = docx_zip_bytes();
    assert_eq!(
        sha256_hex(&bytes),
        manifest_expected_sha256("docx"),
        "generated docx bytes diverge from Tests/Baseline/fixtures.json's recorded expectedSha256 for id \"docx\""
    );
}

#[test]
fn odt_bytes_match_the_baseline_manifest_sha256() {
    let bytes = odt_zip_bytes();
    assert_eq!(
        sha256_hex(&bytes),
        manifest_expected_sha256("odt"),
        "generated odt bytes diverge from Tests/Baseline/fixtures.json's recorded expectedSha256 for id \"odt\""
    );
}

#[test]
fn docx_reader_reaches_a_validated_render_tree_from_real_bytes() {
    let bytes = docx_zip_bytes();
    let archive = ZipArchive::new(Data::fromBytes(bytes.clone()))
        .unwrap_or_else(|e| panic!("docx: ZipArchive::new failed on generated bytes: {e:?}"));
    let result = DocxReader::read(&archive).unwrap_or_else(|e| panic!("docx: DocxReader::read failed: {e:?}"));
    assert_reachable(DocumentFormat::Docx, "baseline.docx", &bytes, &result, Some("FastDoc baseline"));
}

#[test]
fn odt_reader_reaches_a_validated_render_tree_from_real_bytes() {
    let bytes = odt_zip_bytes();
    let archive = ZipArchive::new(Data::fromBytes(bytes.clone()))
        .unwrap_or_else(|e| panic!("odt: ZipArchive::new failed on generated bytes: {e:?}"));
    let result = OdtReader::read(&archive).unwrap_or_else(|e| panic!("odt: OdtReader::read failed: {e:?}"));
    assert_reachable(DocumentFormat::Odt, "baseline.odt", &bytes, &result, Some("FastDoc baseline"));
}

#[test]
fn hwp_reader_reaches_a_validated_render_tree_from_real_bytes() {
    let bytes = rhwp_saved_fixture("blank2010.hwp");
    assert_eq!(bytes.len(), 13_824, "blank2010.hwp is not the size the sprint spec records — wrong file?");
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data)
        .unwrap_or_else(|e| panic!("hwp: HwpReader::read_before_host_font_substitution failed: {e:?}"));
    assert_reachable(DocumentFormat::Hwp, "blank2010.hwp", &bytes, &result, None);
}

#[test]
fn hwpx_reader_reaches_a_validated_render_tree_from_real_bytes() {
    let bytes = rhwp_saved_fixture("hwpx-01-saved.hwpx");
    assert_eq!(bytes.len(), 11_227, "hwpx-01-saved.hwpx is not the size the sprint spec records — wrong file?");
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data)
        .unwrap_or_else(|e| panic!("hwpx: HwpReader::read_before_host_font_substitution failed: {e:?}"));
    assert_reachable(DocumentFormat::Hwpx, "hwpx-01-saved.hwpx", &bytes, &result, None);
}

/// Neither `blank2010.hwp` nor `hwpx-01-saved.hwpx` (the `/saved` fixtures both tests above read)
/// declares a column layout — both are single-column documents, and `hwp_column_key_parity`'s own
/// corpus scan records zero column declarations for either. `hwp-multi-001.hwp`, named for exactly
/// this and listed among that probe's own `multi_column_candidates`, does declare one, so it is
/// what proves a real document's columns reach the ENCODED wire tree, not merely the office reader.
#[test]
fn hwp_reader_column_declaration_reaches_the_encoded_tree() {
    let bytes = rhwp_sample_fixture("hwp-multi-001.hwp");
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data).unwrap_or_else(|e| {
        panic!("hwp-multi-001.hwp: HwpReader::read_before_host_font_substitution failed: {e:?}")
    });
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Hwp,
        source_name: "hwp-multi-001.hwp",
        source_bytes: &bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("hwp-multi-001.hwp: from_office failed: {e:?}"));

    let encoded = tree.encode_json().unwrap_or_else(|e| panic!("hwp-multi-001.hwp: encode_json failed: {e:?}"));
    let encoded_text = String::from_utf8_lossy(&encoded);

    // Pin that the path was actually entered before trusting either count: a tree with zero
    // nodes, or one the adapter built without ever visiting a Section/TextRun payload, would pass
    // the assertions below vacuously.
    let tags = tree.node_tags();
    assert!(!tags.is_empty(), "hwp-multi-001.hwp: the adapter produced a tree with no nodes");
    let section_count = tags.iter().filter(|t| **t == "section").count();
    let text_run_count = tags.iter().filter(|t| **t == "textRun").count();
    assert!(section_count > 0, "hwp-multi-001.hwp: no Section node reached the tree at all");
    assert!(text_run_count > 0, "hwp-multi-001.hwp: no TextRun node reached the tree at all");

    let section_columns_hits = encoded_text.matches("\"columns\":{").count();
    let run_column_flow_hits = encoded_text.matches("\"columnFlow\":{").count();
    assert!(
        section_columns_hits > 0 || run_column_flow_hits > 0,
        "hwp-multi-001.hwp: the document declares a column layout but neither Section.columns \
         nor TextRun.columnFlow reached the encoded tree (sectionHits={section_columns_hits}, \
         runHits={run_column_flow_hits})"
    );
}
