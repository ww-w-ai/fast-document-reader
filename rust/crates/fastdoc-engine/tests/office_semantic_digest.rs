//! S2A2 Pass C, unit C item S2A2-07: the parity oracle.
//!
//! `OfficeSemanticDigest` is a typed, TEST-ONLY projection of a document's meaning, built by TWO
//! INDEPENDENT code paths and then compared:
//! - `digest_from_office_result` exhaustively destructures `OfficeReadResult`/`OfficeBlock` (the
//!   SOURCE side, direct from a real reader).
//! - `digest_from_validated_tree` reads ONLY `ValidatedRenderTree::encode_json()`'s public JSON
//!   (the CANONICAL side) and walks the node graph by `parentId`/`children`.
//! Neither builder calls the other's code, and neither calls `office_adapter.rs` internals — the
//! canonical side never reaches back into `OfficeReadResult`. If `from_office` silently dropped a
//! field, it would show up on one digest and not the other.
//!
//! This file owns no fixtures shared with `office_reader_reachability.rs` — its zip/fixture
//! helpers below are intentionally duplicated (small, self-contained), per this sprint's file
//! ownership: that file belongs to another worker.

use fastdoc_engine::render::office::docx_reader::DocxReader;
use fastdoc_engine::render::office::hwp_reader::HwpReader;
use fastdoc_engine::render::office::odt_reader::OdtReader;
use fastdoc_engine::render::office::office_block::{Cell, OfficeBlock, OfficeFormControlKind, OfficeReadResult, Span};
use fastdoc_engine::render::office::zip_archive::ZipArchive;
use fastdoc_engine::render::render_tree::{
    DocumentFormat, OfficeAdapterError, OfficeAdapterInput, ResolvedOfficeResource, ValidatedRenderTree,
};
use swiftshim::Data;

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;

// =================================================================================================
// Fixture bytes — duplicated from `office_reader_reachability.rs` deliberately (see module doc).
// =================================================================================================

struct ZipEntry {
    name: &'static str,
    data: Vec<u8>,
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
        let data = &entry.data;
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

const DOCX_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";
const DOCX_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>\n";

const ODT_MANIFEST: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>\n";
const ODT_MIMETYPE: &str = "application/vnd.oasis.opendocument.text";

fn docx_document_xml(paragraph_texts: &[&str]) -> String {
    let mut body = String::new();
    for text in paragraph_texts {
        body.push_str(&format!(
            "<w:p><w:r><w:t>{}</w:t></w:r></w:p>",
            text
        ));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>{}</w:body></w:document>\n",
        body
    )
}

/// Builds a real docx zip (stored, sorted entries — the shape every docx reader here accepts) from
/// one or more body paragraphs, so the discrimination tests below drive REAL bytes through the
/// REAL `DocxReader`, not a hand-built `OfficeReadResult`.
fn docx_zip_bytes(paragraph_texts: &[&str]) -> Vec<u8> {
    let document_xml = docx_document_xml(paragraph_texts);
    let mut entries = vec![
        ZipEntry { name: "[Content_Types].xml", data: DOCX_CONTENT_TYPES.as_bytes().to_vec() },
        ZipEntry { name: "_rels/.rels", data: DOCX_RELS.as_bytes().to_vec() },
        ZipEntry { name: "word/document.xml", data: document_xml.into_bytes() },
    ];
    entries.sort_by_key(|e| e.name);
    build_stored_zip(&entries)
}

fn odt_zip_bytes(paragraph_text: &str) -> Vec<u8> {
    let content_xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:text><text:p>{}</text:p></office:text></office:body></office:document-content>\n",
        paragraph_text
    );
    let mut rest = vec![
        ZipEntry { name: "META-INF/manifest.xml", data: ODT_MANIFEST.as_bytes().to_vec() },
        ZipEntry { name: "content.xml", data: content_xml.into_bytes() },
    ];
    rest.sort_by_key(|e| e.name);
    let mut entries = vec![ZipEntry { name: "mimetype", data: ODT_MIMETYPE.as_bytes().to_vec() }];
    entries.extend(rest);
    build_stored_zip(&entries)
}

fn rhwp_saved_fixture(name: &str) -> Vec<u8> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../..").join("Vendor/rhwp-src/saved").join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

// =================================================================================================
// The feature-rich baseline — a SECOND project-authored docx (S2A2 gate item, this sprint's own
// task), carrying what none of the 6 base sources or 9 rhwp-sample featureFixtures above exercise
// on the docx path: two headings at different outline levels (mechanism (b) — a bare `w:pStyle`
// naming a built-in `HeadingN` id, no `word/styles.xml` needed — see `DocxReader::heading_level`),
// and one real embedded image part referenced from the body. Generated in-memory by the SAME
// `build_stored_zip` shape `docx_zip_bytes` above already uses (stored-only entries, sorted names,
// 1980-01-01 timestamps, `create_system = 3`, `external_attr = 0o100644 << 16`) — this is a
// `generated-zip`-kind fixture (like the "docx"/"odt" entries in `fixtures.json`'s `sources`), not
// a `submodule-file` one, so unlike `feature_fixture_bytes` above it carries no `sourcePath` and is
// never read from disk: the manifest entry exists only so the fixture's identity (and its
// `expectedSha256` witness) is recorded, exactly as the base `sources` entries are.
// =================================================================================================

const FEATURE_RICH_CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>\n";

const FEATURE_RICH_DOCUMENT_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image1.png\"/></Relationships>\n";

const FEATURE_RICH_DOCUMENT_XML: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body><w:p><w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t>FastDoc Feature Baseline</w:t></w:r></w:p><w:p><w:r><w:t>Ordinary body text for the feature-rich baseline fixture.</w:t></w:r></w:p><w:p><w:pPr><w:pStyle w:val=\"Heading2\"/></w:pPr><w:r><w:t>Embedded Picture</w:t></w:r></w:p><w:p><w:r><w:drawing><wp:inline><wp:extent cx=\"304800\" cy=\"304800\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:blipFill><a:blip r:embed=\"rId1\"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p></w:body></w:document>\n";

/// A 69-byte, real, decodable 1x1 red PNG (RGB, no palette) — small enough to be "a fixture, not a
/// demo" per this sprint's own instruction, still real bytes a PNG decoder accepts.
fn feature_rich_png_bytes() -> Vec<u8> {
    let hex = "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de0000000c4944415478da63f8cfc0000003010100f70341430000000049454e44ae426082";
    (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("valid hex digit pair")).collect()
}

/// The image's resolved archive path — `word/_rels/document.xml.rels`' `Target="media/image1.png"`
/// resolved against `word/document.xml`'s own directory (`DocxReader::parse_relationships`), which
/// is the SAME string `OfficeBlock::Image.id` carries and the SAME key both `OfficeReadResult` (via
/// the `resources` param this sprint threads through `digest_from_office_result_with_resources`)
/// and `OfficeAdapterInput.resources` must be keyed by for the two sides to agree.
const FEATURE_RICH_IMAGE_RESOURCE_ID: &str = "word/media/image1.png";

/// Builds the feature-rich baseline docx in-memory, byte-for-byte reproducibly (see the module
/// doc above), and returns its bytes alongside the raw PNG bytes its one image part carries.
fn feature_rich_docx_zip_bytes() -> (Vec<u8>, Vec<u8>) {
    let png = feature_rich_png_bytes();
    let mut entries = vec![
        ZipEntry { name: "[Content_Types].xml", data: FEATURE_RICH_CONTENT_TYPES.as_bytes().to_vec() },
        ZipEntry { name: "_rels/.rels", data: DOCX_RELS.as_bytes().to_vec() },
        ZipEntry { name: "word/document.xml", data: FEATURE_RICH_DOCUMENT_XML.as_bytes().to_vec() },
        ZipEntry { name: "word/_rels/document.xml.rels", data: FEATURE_RICH_DOCUMENT_RELS.as_bytes().to_vec() },
        ZipEntry { name: "word/media/image1.png", data: png.clone() },
    ];
    entries.sort_by_key(|e| e.name);
    (build_stored_zip(&entries), png)
}

/// Resolves the manifest's own `featureFixtures` entry for the feature-rich baseline and verifies
/// its `expectedSha256` against the bytes THIS file's own generator actually produces — the same
/// cross-check `feature_fixture_bytes` above performs for a `submodule-file`, adapted for a
/// `generated-zip` fixture that carries no `sourcePath` to read from disk.
fn feature_rich_docx_bytes_checked(manifest: &serde_json::Value) -> (Vec<u8>, Vec<u8>) {
    let entries = manifest["featureFixtures"]
        .as_array()
        .expect("fixture manifest has no `featureFixtures` array");
    let entry = entries
        .iter()
        .find(|e| e["id"].as_str() == Some("feature-rich-docx-baseline"))
        .expect("fixture manifest declares no featureFixtures entry with id \"feature-rich-docx-baseline\"");
    let expected_sha256 =
        entry["expectedSha256"].as_str().expect("feature-rich-docx-baseline entry has no expectedSha256");
    let (zip_bytes, png_bytes) = feature_rich_docx_zip_bytes();
    assert_eq!(
        sha256_hex(&zip_bytes),
        expected_sha256,
        "feature-rich-docx-baseline: generated bytes diverge from the manifest's own expectedSha256"
    );
    (zip_bytes, png_bytes)
}

// =================================================================================================
// OfficeSemanticDigest — the shared, format-neutral, TEST-ONLY projection.
// =================================================================================================

#[derive(Debug, Clone, PartialEq, Default)]
struct OfficeSemanticDigest {
    /// Top-level document body, in document order, list groups already flattened back to
    /// individual `ListItem` blocks (matching the SOURCE side's own flat vocabulary).
    body_blocks: Vec<DigestBlock>,
    /// Sorted by footnote number.
    footnotes: Vec<DigestFootnote>,
    /// In source/registration order (both sides preserve it — see the comment on
    /// `digest_from_office_result`).
    comments: Vec<DigestComment>,
    headers_present: bool,
    footers_present: bool,
}

#[derive(Debug, Clone, PartialEq)]
enum DigestKind {
    Heading { level: i64 },
    Paragraph,
    ListItem { level: i64, ordered: bool },
    Table(DigestTable),
    Image { resource_sha256: Option<String> },
    UnsupportedGraphic { label: String },
    Formula { source: String },
}

#[derive(Debug, Clone, PartialEq)]
struct DigestBlock {
    kind: DigestKind,
    /// Concatenated span/run text, document order, no separator (neither side inserts one).
    text: String,
    /// `footnoteRef`/`footnoteReferenceNumber` values carried by this block's runs, in order.
    footnote_refs: Vec<i64>,
    /// The TEXT of every comment anchored on a run inside this block — sorted, since both sides
    /// dedup/reorder their id lists by numeric id (the id itself is not a shared identity space:
    /// source ids are opaque author strings, canonical ids are adapter-minted `u64`s — see the
    /// named asymmetry below).
    comment_texts: Vec<String>,
    /// Bookmark NAMES anchored on a run inside this block — sorted, same reason as above. Name is
    /// the one identity both sides actually share; canonical `bookmarkIds` are adapter-minted.
    bookmark_names: Vec<String>,
    /// One entry per run inside this block that carries a form control, in run order (NOT sorted —
    /// a form's controls are meaningfully ordered, unlike a set of comment/bookmark references).
    form_controls: Vec<DigestFormControl>,
}

#[derive(Debug, Clone, PartialEq)]
struct DigestTable {
    header_rows: i64,
    /// Grid-normalized: every covered `(row, col)` has an entry, including adapter-synthesized
    /// filler cells for a coordinate the source's anchor cells never covered. Built by
    /// independently replicating the SAME anchor-placement + padding algorithm documented on
    /// `OfficeBlock::Table` (natural left-to-right placement, skip what's occupied, pad the rest)
    /// on the source side, so a filler cell lines up with the identical grid coordinate the
    /// adapter produces on the canonical side.
    rows: Vec<Vec<DigestCell>>,
}

#[derive(Debug, Clone, PartialEq)]
struct DigestCell {
    row_span: i64,
    col_span: i64,
    blocks: Vec<DigestBlock>,
}

#[derive(Debug, Clone, PartialEq)]
struct DigestFootnote {
    number: i64,
    text: String,
}

#[derive(Debug, Clone, PartialEq)]
struct DigestComment {
    text: String,
    /// Normalized the same way the adapter normalizes it: `None` author becomes `""`. Named here
    /// explicitly because it is NOT a literal `Option<String>` round-trip — `wire::Comment.author`
    /// is a bare (non-optional) `String`, so a source comment with no author and one whose author
    /// is the literal empty string are indistinguishable once canonicalized. Both digest builders
    /// apply the identical default, so this asymmetry never shows up as a false mismatch, but it
    /// IS a fact the source format could state that the canonical side cannot recover.
    author: String,
    date_iso: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
struct DigestFormControl {
    /// The wire tag string (`"checkBox"`, `"radioButton"`, …) — independently re-derived from the
    /// SAME tag strings `wire::FormControlKind`'s own macro declares (`wire.rs`'s
    /// `enum_with_str_tags!` invocation), not by calling `convert_form_control_kind`.
    kind: &'static str,
    caption: String,
    text: String,
    value: i64,
    enabled: bool,
}

// =================================================================================================
// SOURCE-side digest: exhaustively destructures `OfficeReadResult`/`OfficeBlock`.
// =================================================================================================

struct SrcCtx<'a> {
    result: &'a OfficeReadResult,
    /// Resource bytes the CALLER (not the reader) knows about, keyed the same way
    /// `OfficeBlock::Image.id` is — the source-side mirror of `Ctx.resources_input` in
    /// `office_adapter.rs`. Checked only when `result.images` (the reader's own pre-decoded map,
    /// HWP-only — see that struct's field doc) has nothing for the id: a zip reader (docx/odt)
    /// never populates `result.images` itself, so without this an image fixture built through the
    /// real `DocxReader` would report `resource_sha256: None` on the source side forever, no
    /// matter what bytes the canonical side's `OfficeAdapterInput.resources` supplies — not a
    /// digest disagreement about the DOCUMENT, just an artifact of which struct a zip reader
    /// happens to leave its bytes in. Empty for every EXISTING call site below (`digest_from_
    /// office_result`), so this changes no prior test's behaviour.
    resources: &'a BTreeMap<String, Vec<u8>>,
}

fn digest_from_office_result(result: &OfficeReadResult) -> OfficeSemanticDigest {
    let empty = BTreeMap::new();
    digest_from_office_result_with_resources(result, &empty)
}

fn digest_from_office_result_with_resources(
    result: &OfficeReadResult,
    resources: &BTreeMap<String, Vec<u8>>,
) -> OfficeSemanticDigest {
    let ctx = SrcCtx { result, resources };
    let body_blocks = digest_blocks_src(&ctx, &result.blocks);

    let mut footnotes: Vec<DigestFootnote> = result
        .footnotes
        .iter()
        .map(|footnote| {
            let blocks = digest_blocks_src(&ctx, &footnote.blocks);
            DigestFootnote {
                number: footnote.number,
                text: blocks.iter().map(|b| b.text.as_str()).collect::<Vec<_>>().join("\n"),
            }
        })
        .collect();
    footnotes.sort_by_key(|f| f.number);

    // `wire::Comment.author` is non-optional (see `DigestComment.author`'s own doc) — the adapter
    // defaults a `None` to `""`; replicated identically here rather than left as `Option`.
    let comments: Vec<DigestComment> = result
        .comments
        .iter()
        .map(|c| DigestComment {
            text: c.text.to_string(),
            author: c.author.as_ref().map(|s| s.to_string()).unwrap_or_default(),
            date_iso: c.date_iso.as_ref().map(|s| s.to_string()),
        })
        .collect();

    OfficeSemanticDigest {
        body_blocks,
        footnotes,
        comments,
        headers_present: !result.headers.is_empty(),
        footers_present: !result.footers.is_empty(),
    }
}

fn digest_blocks_src(ctx: &SrcCtx<'_>, blocks: &[OfficeBlock]) -> Vec<DigestBlock> {
    blocks.iter().map(|block| digest_block_src(ctx, block)).collect()
}

fn digest_block_src(ctx: &SrcCtx<'_>, block: &OfficeBlock) -> DigestBlock {
    // Exhaustive match over every `OfficeBlock` variant — the compiler-enforced field list this
    // sprint's contract asked for: a new variant breaks THIS build, not just the adapter's.
    match block {
        OfficeBlock::Heading { level, spans, .. } => {
            let (text, footnote_refs, comment_texts, bookmark_names, form_controls) = digest_spans_src(ctx, spans);
            DigestBlock { kind: DigestKind::Heading { level: *level }, text, footnote_refs, comment_texts, bookmark_names, form_controls }
        }
        OfficeBlock::Paragraph { spans, .. } => {
            let (text, footnote_refs, comment_texts, bookmark_names, form_controls) = digest_spans_src(ctx, spans);
            DigestBlock { kind: DigestKind::Paragraph, text, footnote_refs, comment_texts, bookmark_names, form_controls }
        }
        OfficeBlock::ListItem { level, ordered, spans, .. } => {
            let (text, footnote_refs, comment_texts, bookmark_names, form_controls) = digest_spans_src(ctx, spans);
            // Matches `wire::ListItem.level`'s own documented construction
            // (`office_adapter.rs::map_list_group`: `((*level + 1).clamp(1, 32)) as u32`) —
            // independently re-derived here from the doc comment's stated formula, not by calling
            // the adapter.
            let wire_level = (*level + 1).clamp(1, 32);
            DigestBlock {
                kind: DigestKind::ListItem { level: wire_level, ordered: *ordered },
                text,
                footnote_refs,
                comment_texts,
                bookmark_names,
                form_controls,
            }
        }
        OfficeBlock::Table { rows, header_rows, .. } => DigestBlock {
            kind: DigestKind::Table(digest_table_src(ctx, rows, *header_rows)),
            text: String::new(),
            footnote_refs: vec![],
            comment_texts: vec![],
            bookmark_names: vec![],
            form_controls: vec![],
        },
        OfficeBlock::Image { id, .. } => {
            let sha = ctx
                .result
                .images
                .get(id)
                .map(|data| sha256_hex(&data.0))
                .or_else(|| ctx.resources.get(id.as_str()).map(|bytes| sha256_hex(bytes)));
            DigestBlock {
                kind: DigestKind::Image { resource_sha256: sha },
                text: String::new(),
                footnote_refs: vec![],
                comment_texts: vec![],
                bookmark_names: vec![],
                form_controls: vec![],
            }
        }
        OfficeBlock::UnsupportedGraphic { label, .. } => {
            let label = if label.as_str().is_empty() { "unsupported graphic".to_string() } else { label.to_string() };
            DigestBlock {
                kind: DigestKind::UnsupportedGraphic { label },
                text: String::new(),
                footnote_refs: vec![],
                comment_texts: vec![],
                bookmark_names: vec![],
                form_controls: vec![],
            }
        }
        OfficeBlock::Formula { latex } => DigestBlock {
            kind: DigestKind::Formula { source: latex.to_string() },
            text: String::new(),
            footnote_refs: vec![],
            comment_texts: vec![],
            bookmark_names: vec![],
            form_controls: vec![],
        },
    }
}

/// Independently re-derives the SAME tag strings `wire::FormControlKind`'s macro declares
/// (`wire.rs`: `checkBox`/`radioButton`/`pushButton`/`comboBox`/`edit`/`listBox`/`scrollBar`/
/// `unknown`) — not by calling `convert_form_control_kind`.
fn form_control_kind_tag_src(kind: OfficeFormControlKind) -> &'static str {
    match kind {
        OfficeFormControlKind::CheckBox => "checkBox",
        OfficeFormControlKind::RadioButton => "radioButton",
        OfficeFormControlKind::PushButton => "pushButton",
        OfficeFormControlKind::ComboBox => "comboBox",
        OfficeFormControlKind::Edit => "edit",
        OfficeFormControlKind::ListBox => "listBox",
        OfficeFormControlKind::ScrollBar => "scrollBar",
        OfficeFormControlKind::Unknown => "unknown",
    }
}

fn digest_spans_src(
    ctx: &SrcCtx<'_>,
    spans: &[Span],
) -> (String, Vec<i64>, Vec<String>, Vec<String>, Vec<DigestFormControl>) {
    let mut text = String::new();
    let mut footnote_refs = Vec::new();
    let mut comment_texts = Vec::new();
    let mut bookmark_names = Vec::new();
    let mut form_controls = Vec::new();
    for span in spans {
        text.push_str(span.text.as_str());
        if let Some(n) = span.footnote_ref {
            footnote_refs.push(n);
        }
        for source_id in &span.comment_ids {
            if let Some(comment) = ctx.result.comments.iter().find(|c| c.id.as_str() == source_id.as_str()) {
                comment_texts.push(comment.text.to_string());
            }
        }
        for name in &span.bookmarks {
            bookmark_names.push(name.to_string());
        }
        if let Some(fc) = &span.form_control {
            form_controls.push(DigestFormControl {
                kind: form_control_kind_tag_src(fc.kind),
                caption: fc.caption.to_string(),
                text: fc.text.to_string(),
                value: fc.value,
                enabled: fc.enabled,
            });
        }
    }
    comment_texts.sort();
    bookmark_names.sort();
    (text, footnote_refs, comment_texts, bookmark_names, form_controls)
}

/// Independently replicates the SAME anchor-placement + padding algorithm the adapter's
/// `map_table` uses (documented on `OfficeBlock::Table`: anchor cells only, left-to-right,
/// skip-what's-occupied, pad any coordinate a row leaves uncovered with an empty 1x1 filler) — not
/// by calling `map_table`, but by re-deriving it from that public doc comment, so a filler cell
/// lands at the identical `(row, col)` on both sides.
fn digest_table_src(ctx: &SrcCtx<'_>, rows: &[Vec<Cell>], header_rows: i64) -> DigestTable {
    let mut occupied: BTreeSet<(usize, usize)> = BTreeSet::new();
    let mut natural: Vec<Vec<(usize, usize, usize)>> = Vec::with_capacity(rows.len());
    for (r, row_cells) in rows.iter().enumerate() {
        let mut col = 0usize;
        let mut placements = Vec::with_capacity(row_cells.len());
        for cell in row_cells {
            while occupied.contains(&(r, col)) {
                col += 1;
            }
            let row_span = (cell.row_span.max(1) as usize).min(rows.len() - r);
            let col_span = cell.col_span.max(1) as usize;
            for rr in r..r + row_span {
                for cc in col..col + col_span {
                    occupied.insert((rr, cc));
                }
            }
            placements.push((col, row_span, col_span));
            col += col_span;
        }
        natural.push(placements);
    }
    let total_cols = occupied.iter().map(|&(_, c)| c + 1).max().unwrap_or(1);

    let mut occupied2: BTreeSet<(usize, usize)> = BTreeSet::new();
    let mut grid_rows = Vec::with_capacity(rows.len());
    for (r, row_cells) in rows.iter().enumerate() {
        let mut entries: Vec<(usize, Option<&Cell>, usize, usize)> = Vec::with_capacity(row_cells.len());
        for (cell, &(col, row_span, col_span)) in row_cells.iter().zip(natural[r].iter()) {
            for rr in r..r + row_span {
                for cc in col..col + col_span {
                    occupied2.insert((rr, cc));
                }
            }
            entries.push((col, Some(cell), row_span, col_span));
        }
        for c in 0..total_cols {
            if !occupied2.contains(&(r, c)) {
                occupied2.insert((r, c));
                entries.push((c, None, 1, 1));
            }
        }
        entries.sort_by_key(|e| e.0);

        let row_digest: Vec<DigestCell> = entries
            .into_iter()
            .map(|(_, cell_opt, row_span, col_span)| match cell_opt {
                Some(cell) => DigestCell {
                    row_span: row_span as i64,
                    col_span: col_span as i64,
                    blocks: digest_blocks_src(ctx, &cell.blocks),
                },
                None => DigestCell { row_span: 1, col_span: 1, blocks: vec![] },
            })
            .collect();
        grid_rows.push(row_digest);
    }

    DigestTable { header_rows: header_rows.max(0).min(rows.len() as i64), rows: grid_rows }
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(bytes))
}

// =================================================================================================
// CANONICAL-side digest: reads ONLY `ValidatedRenderTree::encode_json()`'s public JSON, walked by
// `parentId`/`children`. Never touches `office_adapter.rs` or `OfficeReadResult`.
// =================================================================================================

fn digest_from_validated_tree(tree: &ValidatedRenderTree) -> OfficeSemanticDigest {
    let bytes = tree.encode_json().expect("encode_json of a validated tree must not fail");
    let root: serde_json::Value =
        serde_json::from_slice(&bytes).expect("encode_json must produce valid JSON");
    digest_from_tree_json(&root)
}

fn digest_from_tree_json(root: &serde_json::Value) -> OfficeSemanticDigest {
    let nodes = root["nodes"].as_array().expect("envelope.nodes must be an array");
    let by_id: HashMap<u64, &serde_json::Value> =
        nodes.iter().map(|n| (n["id"].as_u64().expect("node.id"), n)).collect();

    let resources_by_id: HashMap<u64, String> = root["resources"]
        .as_array()
        .expect("envelope.resources must be an array")
        .iter()
        .map(|r| (r["id"].as_u64().expect("resource.id"), r["sha256"].as_str().expect("resource.sha256").to_string()))
        .collect();

    let comments_by_id: HashMap<u64, String> = root["annotations"]["comments"]
        .as_array()
        .expect("annotations.comments must be an array")
        .iter()
        .map(|c| (c["id"].as_u64().expect("comment.id"), c["text"].as_str().expect("comment.text").to_string()))
        .collect();

    let bookmarks_by_id: HashMap<u64, String> = root["annotations"]["bookmarks"]
        .as_array()
        .expect("annotations.bookmarks must be an array")
        .iter()
        .map(|b| (b["id"].as_u64().expect("bookmark.id"), b["name"].as_str().expect("bookmark.name").to_string()))
        .collect();

    let root_id = root["document"]["rootNodeId"].as_u64().expect("document.rootNodeId");
    let doc_node = by_id[&root_id];
    assert_eq!(doc_node["type"].as_str(), Some("document"));

    let mut body_blocks = Vec::new();
    let mut headers_present = false;
    let mut footers_present = false;
    let mut footnotes: Vec<DigestFootnote> = Vec::new();

    let section_ids = doc_node["children"].as_array().expect("document.children");
    for section_id in section_ids {
        let section = by_id[&section_id.as_u64().expect("section id")];
        assert_eq!(section["type"].as_str(), Some("section"));
        for child_id in section["children"].as_array().expect("section.children") {
            let child = by_id[&child_id.as_u64().expect("child id")];
            match child["type"].as_str().expect("node.type") {
                "flow" => {
                    let ids: Vec<u64> = child["children"]
                        .as_array()
                        .expect("flow.children")
                        .iter()
                        .map(|v| v.as_u64().expect("flow child id"))
                        .collect();
                    body_blocks.extend(digest_blocks_canonical(&ids, &by_id, &resources_by_id, &comments_by_id, &bookmarks_by_id));
                }
                "header" => headers_present = true,
                "footer" => footers_present = true,
                // S6-2's sidecar: an `OfficeAnchoredObject` is never in `result.blocks` on the
                // source side (it lives in `result.anchored_objects`, a separate list), so the
                // source-side digest never sees it either — skipped here for the same reason,
                // not folded into `body_blocks`.
                "anchoredObject" => {}
                // S6-3's sidecar: same reasoning as `anchoredObject` above — an
                // `OfficeMasterPage` lives in `result.master_pages`, never `result.blocks`.
                "masterPage" => {}
                "footnote" => {
                    let number = child["data"]["number"].as_i64().expect("footnote.number");
                    let flow_id = child["children"]
                        .as_array()
                        .expect("footnote.children")
                        .first()
                        .expect("footnote must have its body flow as its one child")
                        .as_u64()
                        .expect("footnote body flow id");
                    let flow = by_id[&flow_id];
                    assert_eq!(flow["type"].as_str(), Some("flow"), "a footnote's own child must be a flow node");
                    let ids: Vec<u64> = flow["children"]
                        .as_array()
                        .expect("footnote flow.children")
                        .iter()
                        .map(|v| v.as_u64().expect("footnote flow child id"))
                        .collect();
                    let blocks = digest_blocks_canonical(&ids, &by_id, &resources_by_id, &comments_by_id, &bookmarks_by_id);
                    footnotes.push(DigestFootnote {
                        number,
                        text: blocks.iter().map(|b| b.text.as_str()).collect::<Vec<_>>().join("\n"),
                    });
                }
                other => panic!("unexpected direct child of a section node: {other}"),
            }
        }
    }
    footnotes.sort_by_key(|f| f.number);

    let comments: Vec<DigestComment> = root["annotations"]["comments"]
        .as_array()
        .expect("annotations.comments")
        .iter()
        .map(|c| DigestComment {
            text: c["text"].as_str().expect("comment.text").to_string(),
            author: c["author"].as_str().expect("comment.author").to_string(),
            date_iso: c["dateIso"].as_str().map(|s| s.to_string()),
        })
        .collect();

    OfficeSemanticDigest { body_blocks, footnotes, comments, headers_present, footers_present }
}

fn digest_blocks_canonical(
    ids: &[u64],
    by_id: &HashMap<u64, &serde_json::Value>,
    resources_by_id: &HashMap<u64, String>,
    comments_by_id: &HashMap<u64, String>,
    bookmarks_by_id: &HashMap<u64, String>,
) -> Vec<DigestBlock> {
    let mut out = Vec::with_capacity(ids.len());
    for &id in ids {
        let node = by_id[&id];
        match node["type"].as_str().expect("node.type") {
            // A run of source `ListItem`s becomes one `List` container node whose children are the
            // real `listItem` nodes — flattened back out here to line up with the source side's
            // flat vocabulary (see `map_list_group`'s own doc comment on why the grouping exists).
            "list" => {
                for item_id in node["children"].as_array().expect("list.children") {
                    let item_id = item_id.as_u64().expect("listItem id");
                    out.push(digest_list_item_canonical(item_id, by_id, comments_by_id, bookmarks_by_id));
                }
            }
            _ => out.push(digest_single_block_canonical(id, by_id, resources_by_id, comments_by_id, bookmarks_by_id)),
        }
    }
    out
}

fn digest_list_item_canonical(
    id: u64,
    by_id: &HashMap<u64, &serde_json::Value>,
    comments_by_id: &HashMap<u64, String>,
    bookmarks_by_id: &HashMap<u64, String>,
) -> DigestBlock {
    let node = by_id[&id];
    assert_eq!(node["type"].as_str(), Some("listItem"));
    let level = node["data"]["level"].as_i64().expect("listItem.level");
    let ordered = node["data"]["ordered"].as_bool().expect("listItem.ordered");
    let run_ids: Vec<u64> = node["children"].as_array().expect("listItem.children").iter().map(|v| v.as_u64().unwrap()).collect();
    let (text, footnote_refs, comment_texts, bookmark_names, form_controls) =
        digest_spans_canonical(&run_ids, by_id, comments_by_id, bookmarks_by_id);
    DigestBlock { kind: DigestKind::ListItem { level, ordered }, text, footnote_refs, comment_texts, bookmark_names, form_controls }
}

fn digest_single_block_canonical(
    id: u64,
    by_id: &HashMap<u64, &serde_json::Value>,
    resources_by_id: &HashMap<u64, String>,
    comments_by_id: &HashMap<u64, String>,
    bookmarks_by_id: &HashMap<u64, String>,
) -> DigestBlock {
    let node = by_id[&id];
    let data = &node["data"];
    match node["type"].as_str().expect("node.type") {
        "heading" => {
            let level = data["level"].as_i64().expect("heading.level");
            let run_ids: Vec<u64> = node["children"].as_array().expect("heading.children").iter().map(|v| v.as_u64().unwrap()).collect();
            let (text, footnote_refs, comment_texts, bookmark_names, form_controls) =
                digest_spans_canonical(&run_ids, by_id, comments_by_id, bookmarks_by_id);
            DigestBlock { kind: DigestKind::Heading { level }, text, footnote_refs, comment_texts, bookmark_names, form_controls }
        }
        "paragraph" => {
            let run_ids: Vec<u64> = node["children"].as_array().expect("paragraph.children").iter().map(|v| v.as_u64().unwrap()).collect();
            let (text, footnote_refs, comment_texts, bookmark_names, form_controls) =
                digest_spans_canonical(&run_ids, by_id, comments_by_id, bookmarks_by_id);
            DigestBlock { kind: DigestKind::Paragraph, text, footnote_refs, comment_texts, bookmark_names, form_controls }
        }
        "table" => {
            let header_rows = data["headerRows"].as_i64().expect("table.headerRows");
            let row_ids: Vec<u64> = node["children"].as_array().expect("table.children").iter().map(|v| v.as_u64().unwrap()).collect();
            let mut rows = Vec::with_capacity(row_ids.len());
            for row_id in row_ids {
                let row_node = by_id[&row_id];
                assert_eq!(row_node["type"].as_str(), Some("tableRow"));
                let cell_ids: Vec<u64> = row_node["children"].as_array().expect("tableRow.children").iter().map(|v| v.as_u64().unwrap()).collect();
                let mut row_digest = Vec::with_capacity(cell_ids.len());
                for cell_id in cell_ids {
                    let cell_node = by_id[&cell_id];
                    assert_eq!(cell_node["type"].as_str(), Some("tableCell"));
                    let row_span = cell_node["data"]["rowSpan"].as_i64().expect("tableCell.rowSpan");
                    let col_span = cell_node["data"]["columnSpan"].as_i64().expect("tableCell.columnSpan");
                    let child_ids: Vec<u64> =
                        cell_node["children"].as_array().expect("tableCell.children").iter().map(|v| v.as_u64().unwrap()).collect();
                    let blocks = digest_blocks_canonical(&child_ids, by_id, resources_by_id, comments_by_id, bookmarks_by_id);
                    row_digest.push(DigestCell { row_span, col_span, blocks });
                }
                rows.push(row_digest);
            }
            DigestBlock {
                kind: DigestKind::Table(DigestTable { header_rows, rows }),
                text: String::new(),
                footnote_refs: vec![],
                comment_texts: vec![],
                bookmark_names: vec![],
                form_controls: vec![],
            }
        }
        "image" => {
            let resource_id = data["resourceId"].as_u64().expect("image.resourceId");
            let sha = resources_by_id.get(&resource_id).cloned();
            DigestBlock {
                kind: DigestKind::Image { resource_sha256: sha },
                text: String::new(),
                footnote_refs: vec![],
                comment_texts: vec![],
                bookmark_names: vec![],
                form_controls: vec![],
            }
        }
        // A body-flow `OfficeBlock::Image` whose id resolves to a `VectorGraphic` becomes a
        // "vector" node here (`office_adapter.rs::map_vector`), not an "image" one — but
        // `digest_block_src`'s SOURCE-side twin (above) does not make that distinction: it
        // classifies every `OfficeBlock::Image` as `DigestKind::Image` regardless, and finds no
        // sha for a vector-graphic id in either `result.images` or `ctx.resources` (`None`).
        // `map_vector`'s own doc says its wire node's `resource_id` "stays `None`" too, so the
        // two sides already agree on the fact (no raster resource) — this arm only has to name
        // it under the SAME `DigestKind` the source side already picked, or parity fails on a
        // representation difference neither side considers a content difference.
        "vector" => DigestBlock {
            kind: DigestKind::Image { resource_sha256: None },
            text: String::new(),
            footnote_refs: vec![],
            comment_texts: vec![],
            bookmark_names: vec![],
            form_controls: vec![],
        },
        "unsupported" => {
            let label = data["reason"].as_str().expect("unsupported.reason").to_string();
            DigestBlock {
                kind: DigestKind::UnsupportedGraphic { label },
                text: String::new(),
                footnote_refs: vec![],
                comment_texts: vec![],
                bookmark_names: vec![],
                form_controls: vec![],
            }
        }
        "formula" => {
            let source = data["source"].as_str().expect("formula.source").to_string();
            DigestBlock {
                kind: DigestKind::Formula { source },
                text: String::new(),
                footnote_refs: vec![],
                comment_texts: vec![],
                bookmark_names: vec![],
                form_controls: vec![],
            }
        }
        other => panic!("unexpected node tag in a document body flow: {other}"),
    }
}

fn digest_spans_canonical(
    run_ids: &[u64],
    by_id: &HashMap<u64, &serde_json::Value>,
    comments_by_id: &HashMap<u64, String>,
    bookmarks_by_id: &HashMap<u64, String>,
) -> (String, Vec<i64>, Vec<String>, Vec<String>, Vec<DigestFormControl>) {
    let mut text = String::new();
    let mut footnote_refs = Vec::new();
    let mut comment_texts = Vec::new();
    let mut bookmark_names = Vec::new();
    let mut form_controls = Vec::new();
    for &id in run_ids {
        let node = by_id[&id];
        assert_eq!(node["type"].as_str(), Some("textRun"), "a heading/paragraph/listItem child must be a textRun");
        let data = &node["data"];
        text.push_str(data["text"].as_str().expect("textRun.text"));
        if let Some(n) = data["footnoteReferenceNumber"].as_i64() {
            footnote_refs.push(n);
        }
        if let Some(ids) = data["commentIds"].as_array() {
            for cid in ids {
                let cid = cid.as_u64().expect("commentIds entry");
                if let Some(text) = comments_by_id.get(&cid) {
                    comment_texts.push(text.clone());
                }
            }
        }
        if let Some(ids) = data["bookmarkIds"].as_array() {
            for bid in ids {
                let bid = bid.as_u64().expect("bookmarkIds entry");
                if let Some(name) = bookmarks_by_id.get(&bid) {
                    bookmark_names.push(name.clone());
                }
            }
        }
        if let Some(fc) = data["formControl"].as_object() {
            form_controls.push(DigestFormControl {
                kind: match fc["kind"].as_str().expect("formControl.kind") {
                    "checkBox" => "checkBox",
                    "radioButton" => "radioButton",
                    "pushButton" => "pushButton",
                    "comboBox" => "comboBox",
                    "edit" => "edit",
                    "listBox" => "listBox",
                    "scrollBar" => "scrollBar",
                    "unknown" => "unknown",
                    other => panic!("unexpected formControl.kind tag: {other}"),
                },
                caption: fc["caption"].as_str().expect("formControl.caption").to_string(),
                text: fc["text"].as_str().expect("formControl.text").to_string(),
                value: fc["value"].as_i64().expect("formControl.value"),
                enabled: fc["enabled"].as_bool().expect("formControl.enabled"),
            });
        }
    }
    comment_texts.sort();
    bookmark_names.sort();
    (text, footnote_refs, comment_texts, bookmark_names, form_controls)
}

// =================================================================================================
// Equality across all four formats.
// =================================================================================================

fn build_tree(format: DocumentFormat, source_name: &str, source_bytes: &[u8], result: &OfficeReadResult) -> ValidatedRenderTree {
    ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name,
        source_bytes,
        result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("{source_name}: from_office failed: {e:?}"))
}

/// Asserts both digest builders agree, and that the digest is non-vacuous first (S2A2's own hollow
/// test lesson: an assertion over an empty collection passes for the wrong reason).
fn assert_digest_parity(source_digest: &OfficeSemanticDigest, tree: &ValidatedRenderTree, source_name: &str) {
    assert!(
        !source_digest.body_blocks.is_empty(),
        "{source_name}: the source-side digest has no body blocks — nothing to compare"
    );
    let canonical_digest = digest_from_validated_tree(tree);
    assert_eq!(
        canonical_digest.body_blocks.len(),
        source_digest.body_blocks.len(),
        "{source_name}: block count diverged before content comparison"
    );
    assert_eq!(source_digest, &canonical_digest, "{source_name}: source and canonical digests diverged");
}

#[test]
fn docx_digest_matches_across_source_and_canonical() {
    let bytes = docx_zip_bytes(&["FastDoc baseline"]);
    let archive = ZipArchive::new(Data::fromBytes(bytes.clone())).expect("docx: ZipArchive::new");
    let result = DocxReader::read(&archive).expect("docx: DocxReader::read");
    let tree = build_tree(DocumentFormat::Docx, "baseline.docx", &bytes, &result);
    let digest = digest_from_office_result(&result);
    assert_digest_parity(&digest, &tree, "docx");
}

#[test]
fn odt_digest_matches_across_source_and_canonical() {
    let bytes = odt_zip_bytes("FastDoc baseline");
    let archive = ZipArchive::new(Data::fromBytes(bytes.clone())).expect("odt: ZipArchive::new");
    let result = OdtReader::read(&archive).expect("odt: OdtReader::read");
    let tree = build_tree(DocumentFormat::Odt, "baseline.odt", &bytes, &result);
    let digest = digest_from_office_result(&result);
    assert_digest_parity(&digest, &tree, "odt");
}

#[test]
fn hwp_digest_matches_across_source_and_canonical() {
    let bytes = rhwp_saved_fixture("blank2010.hwp");
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data).expect("hwp: HwpReader::read_before_host_font_substitution");
    let tree = build_tree(DocumentFormat::Hwp, "blank2010.hwp", &bytes, &result);
    let digest = digest_from_office_result(&result);
    // `blank2010.hwp` may legitimately carry zero body blocks (it is the format's "blank document"
    // fixture) — the reachability harness makes no text assertion for it either. Guard the same way
    // here instead of forcing the non-empty assertion `assert_digest_parity` makes for the others.
    let canonical_digest = digest_from_validated_tree(&tree);
    assert_eq!(digest, canonical_digest, "hwp: source and canonical digests diverged");
}

#[test]
fn hwpx_digest_matches_across_source_and_canonical() {
    let bytes = rhwp_saved_fixture("hwpx-01-saved.hwpx");
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data).expect("hwpx: HwpReader::read_before_host_font_substitution");
    let tree = build_tree(DocumentFormat::Hwpx, "hwpx-01-saved.hwpx", &bytes, &result);
    let digest = digest_from_office_result(&result);
    let canonical_digest = digest_from_validated_tree(&tree);
    assert_eq!(digest, canonical_digest, "hwpx: source and canonical digests diverged");
}

// =================================================================================================
// Discrimination — a digest that always agrees proves nothing unless it can also DISAGREE. Both
// cases below are built from real docx bytes through the real `DocxReader`, never a hand-built
// `OfficeReadResult`.
// =================================================================================================

/// Negative case 1: two genuinely different real documents (independently authored XML, not a
/// mutated copy of one another) must produce different digests, at the specific field that
/// actually differs — their body text.
#[test]
fn two_different_real_documents_produce_different_digests() {
    let bytes_a = docx_zip_bytes(&["FastDoc baseline"]);
    let archive_a = ZipArchive::new(Data::fromBytes(bytes_a.clone())).expect("doc a: ZipArchive::new");
    let result_a = DocxReader::read(&archive_a).expect("doc a: DocxReader::read");
    let digest_a = digest_from_office_result(&result_a);

    let bytes_b = docx_zip_bytes(&["Totally unrelated content, never derived from doc A"]);
    let archive_b = ZipArchive::new(Data::fromBytes(bytes_b.clone())).expect("doc b: ZipArchive::new");
    let result_b = DocxReader::read(&archive_b).expect("doc b: DocxReader::read");
    let digest_b = digest_from_office_result(&result_b);

    assert_eq!(digest_a.body_blocks.len(), 1, "doc a: expected exactly one paragraph before comparing its text");
    assert_eq!(digest_b.body_blocks.len(), 1, "doc b: expected exactly one paragraph before comparing its text");
    assert_ne!(
        digest_a.body_blocks[0].text, digest_b.body_blocks[0].text,
        "named field body_blocks[0].text did not discriminate two genuinely different documents"
    );
    assert_ne!(digest_a, digest_b, "whole-digest equality did not discriminate two genuinely different documents");
}

/// Negative case 2: a document compared against a deliberately altered copy of ITSELF (same source
/// bytes, then one field mutated on the parsed structure) must differ in exactly the named field.
#[test]
fn an_altered_copy_of_the_same_document_differs_in_the_named_field() {
    let bytes = docx_zip_bytes(&["FastDoc baseline"]);
    let archive = ZipArchive::new(Data::fromBytes(bytes.clone())).expect("ZipArchive::new");
    let original = DocxReader::read(&archive).expect("DocxReader::read");

    let mut altered = original.clone();
    assert_eq!(altered.blocks.len(), 1, "expected exactly one block before mutating it");
    match &mut altered.blocks[0] {
        OfficeBlock::Paragraph { spans, .. } => {
            assert_eq!(spans.len(), 1, "expected exactly one span before mutating its text");
            spans[0].text = "FastDoc baseline, mutated".into();
        }
        other => panic!("expected the baseline's one block to be a Paragraph, found {other:?}"),
    }

    let digest_original = digest_from_office_result(&original);
    let digest_altered = digest_from_office_result(&altered);

    assert_eq!(digest_original.body_blocks.len(), digest_altered.body_blocks.len());
    assert_ne!(
        digest_original.body_blocks[0].text, digest_altered.body_blocks[0].text,
        "named field body_blocks[0].text did not discriminate a copy altered in exactly that field"
    );
    // Everything else about the two documents is identical, so nothing but this field should move.
    let mut expected = digest_original.clone();
    expected.body_blocks[0].text = digest_altered.body_blocks[0].text.clone();
    assert_eq!(expected, digest_altered, "a field beyond body_blocks[0].text moved after a single-field mutation");
}

// =================================================================================================
// Feature fixtures — 9 real HWP/HWPX documents registered in `Tests/Baseline/fixtures.json`'s
// `featureFixtures` array (by another worker), each carrying a real, non-trivial declaration the
// four minimal fixtures above never exercise: a multi-column layout, cell diagonals, form
// controls, a nested table with picture-fill cells and pre-decoded image resources, and one
// document `from_office` is expected to REFUSE outright. Resolved by manifest id, never by a
// hardcoded path, so a manifest change cannot leave this file asserting against a moved file.
// =================================================================================================

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn load_fixture_manifest() -> serde_json::Value {
    let path = repo_root().join("Tests/Baseline/fixtures.json");
    let bytes = std::fs::read(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture manifest {} ({e})", path.display()));
    serde_json::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("fixture manifest {} is not valid JSON ({e})", path.display()))
}

/// Resolves a `featureFixtures[].id` to its real bytes via the manifest's OWN `sourcePath`, and
/// verifies them against the manifest's OWN `expectedSha256` — so a manifest edit that moves or
/// re-points a fixture is caught here rather than silently asserting against the wrong file.
fn feature_fixture_bytes(manifest: &serde_json::Value, id: &str) -> Vec<u8> {
    let entries = manifest["featureFixtures"]
        .as_array()
        .expect("fixture manifest has no `featureFixtures` array");
    let entry = entries
        .iter()
        .find(|e| e["id"].as_str() == Some(id))
        .unwrap_or_else(|| panic!("fixture manifest declares no featureFixtures entry with id {id:?}"));
    let source_path = entry["sourcePath"]
        .as_str()
        .unwrap_or_else(|| panic!("featureFixtures entry {id:?} has no sourcePath"));
    let expected_sha256 = entry["expectedSha256"]
        .as_str()
        .unwrap_or_else(|| panic!("featureFixtures entry {id:?} has no expectedSha256"));
    let path = repo_root().join(source_path);
    let bytes = std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required feature fixture {id:?} at {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    });
    assert_eq!(
        sha256_hex(&bytes),
        expected_sha256,
        "{id}: bytes at {} diverge from the manifest's own expectedSha256",
        path.display()
    );
    bytes
}

fn feature_fixture_format(manifest: &serde_json::Value, id: &str) -> DocumentFormat {
    let entries = manifest["featureFixtures"].as_array().expect("featureFixtures array");
    let entry = entries.iter().find(|e| e["id"].as_str() == Some(id)).expect("featureFixtures entry");
    match entry["class"].as_str().unwrap_or_else(|| panic!("{id}: featureFixtures entry has no class")) {
        "hwp" => DocumentFormat::Hwp,
        "hwpx" => DocumentFormat::Hwpx,
        other => panic!("{id}: unexpected featureFixtures class {other:?}"),
    }
}

fn read_feature_fixture(manifest: &serde_json::Value, id: &str) -> (Vec<u8>, DocumentFormat, OfficeReadResult) {
    let bytes = feature_fixture_bytes(manifest, id);
    let format = feature_fixture_format(manifest, id);
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data)
        .unwrap_or_else(|e| panic!("{id}: HwpReader::read_before_host_font_substitution failed: {e:?}"));
    (bytes, format, result)
}

// --- raw-fact counters over `OfficeReadResult`, independent of the digest, used ONLY to pin the
// count a fixture is claimed to carry before any digest-equality assertion runs (item 4's own
// requirement: count first, then compare contents — an empty-collection equality passes for the
// wrong reason). ---

fn count_matching_spans(blocks: &[OfficeBlock], pred: &dyn Fn(&Span) -> bool) -> usize {
    let mut count = 0;
    for block in blocks {
        match block {
            OfficeBlock::Heading { spans, .. }
            | OfficeBlock::Paragraph { spans, .. }
            | OfficeBlock::ListItem { spans, .. } => {
                count += spans.iter().filter(|s| pred(s)).count();
            }
            OfficeBlock::Table { rows, .. } => {
                for row in rows {
                    for cell in row {
                        count += count_matching_spans(&cell.blocks, pred);
                    }
                }
            }
            OfficeBlock::Image { .. } | OfficeBlock::UnsupportedGraphic { .. } | OfficeBlock::Formula { .. } => {}
        }
    }
    count
}

fn count_matching_cells(blocks: &[OfficeBlock], pred: &dyn Fn(&Cell) -> bool) -> usize {
    let mut count = 0;
    for block in blocks {
        if let OfficeBlock::Table { rows, .. } = block {
            for row in rows {
                for cell in row {
                    if pred(cell) {
                        count += 1;
                    }
                    count += count_matching_cells(&cell.blocks, pred);
                }
            }
        }
    }
    count
}

fn count_tables(blocks: &[OfficeBlock]) -> usize {
    let mut count = 0;
    for block in blocks {
        if let OfficeBlock::Table { rows, .. } = block {
            count += 1;
            for row in rows {
                for cell in row {
                    count += count_tables(&cell.blocks);
                }
            }
        }
    }
    count
}

/// Sums `DigestBlock.form_controls` recursively through table cells — used to count-pin the
/// DIGEST's own view of "how many form controls survived", as opposed to `count_matching_spans`'s
/// raw `OfficeReadResult` count, so the equality assertion below is checked against a non-trivial
/// number on BOTH sides.
fn count_digest_form_controls(blocks: &[DigestBlock]) -> usize {
    let mut count = 0;
    for block in blocks {
        count += block.form_controls.len();
        if let DigestKind::Table(table) = &block.kind {
            for row in &table.rows {
                for cell in row {
                    count += count_digest_form_controls(&cell.blocks);
                }
            }
        }
    }
    count
}

/// Runs both digest builders over a feature fixture and asserts equality — same pattern as
/// `assert_digest_parity` above, minus the "non-empty" assumption (some families legitimately have
/// zero top-level headings, etc.; the family-specific count-pin below covers the fact that matters
/// for THAT fixture).
fn assert_feature_digest_parity(id: &str, format: DocumentFormat, bytes: &[u8], result: &OfficeReadResult) -> OfficeSemanticDigest {
    let source_digest = digest_from_office_result(result);
    assert!(!source_digest.body_blocks.is_empty(), "{id}: source digest has no body blocks");
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name: id,
        source_bytes: bytes,
        result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("{id}: from_office failed unexpectedly: {e:?} — report this, do not skip it"));
    let canonical_digest = digest_from_validated_tree(&tree);
    assert_eq!(
        source_digest.body_blocks.len(),
        canonical_digest.body_blocks.len(),
        "{id}: block count diverged before content comparison"
    );
    assert_eq!(source_digest, canonical_digest, "{id}: source and canonical digests diverged");
    source_digest
}

/// `feature-multi-column-hwp` and its HWPX sibling do NOT behave the same way through
/// `from_office`, discovered empirically (not assumed): the HWP side's one inline
/// `OfficeBlock::Image` names a resource key (`"hwpshape:1"`) that is present in neither
/// `OfficeReadResult.images` nor `.vector_graphics`, so `from_office` refuses with
/// `MissingResource` before a tree ever exists — reported here rather than caught and skipped, per
/// this sprint's own instruction. The HWPX sibling carries no such image and reaches a tree
/// cleanly, so it gets the full digest-parity treatment the HWP side cannot.
#[test]
fn feature_multi_column_hwp_from_office_refuses_on_a_missing_shape_resource() {
    let manifest = load_fixture_manifest();
    let id = "feature-multi-column-hwp";
    let (bytes, format, result) = read_feature_fixture(&manifest, id);
    let multi_column_spans =
        count_matching_spans(&result.blocks, &|s: &Span| s.column_layout.as_ref().map(|cl| cl.count > 1).unwrap_or(false));
    assert!(multi_column_spans >= 1, "{id}: expected at least one span with column_layout.count > 1, found {multi_column_spans}");
    let err = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name: id,
        source_bytes: &bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .expect_err(&format!("{id}: from_office was expected to refuse on its unresolved \"hwpshape:1\" resource"));
    assert_eq!(
        err,
        OfficeAdapterError::MissingResource("hwpshape:1".to_string()),
        "{id}: from_office refused with an unexpected error — report this, do not silently reclassify it"
    );
}

#[test]
fn feature_multi_column_hwpx_digest_parity() {
    let manifest = load_fixture_manifest();
    let id = "feature-multi-column-hwpx";
    let (bytes, format, result) = read_feature_fixture(&manifest, id);
    let multi_column_spans =
        count_matching_spans(&result.blocks, &|s: &Span| s.column_layout.as_ref().map(|cl| cl.count > 1).unwrap_or(false));
    assert!(multi_column_spans >= 1, "{id}: expected at least one span with column_layout.count > 1, found {multi_column_spans}");
    assert_feature_digest_parity(id, format, &bytes, &result);
}

#[test]
fn feature_diagonal_digest_parity() {
    let manifest = load_fixture_manifest();
    for id in ["feature-diagonal-hwp", "feature-diagonal-hwpx"] {
        let (bytes, format, result) = read_feature_fixture(&manifest, id);
        // Count-pin: the manifest's own `why` claims exactly 9 cells with a diagonal declared.
        let diagonal_cells = count_matching_cells(&result.blocks, &|c: &Cell| c.diagonal.is_some());
        assert_eq!(diagonal_cells, 9, "{id}: expected 9 cells with Cell.diagonal set, found {diagonal_cells}");
        assert_feature_digest_parity(id, format, &bytes, &result);
    }
}

#[test]
fn feature_form_control_digest_parity() {
    let manifest = load_fixture_manifest();
    for id in ["feature-form-control-hwp", "feature-form-control-hwpx"] {
        let (bytes, format, result) = read_feature_fixture(&manifest, id);
        // Count-pin: the manifest's own `why` claims exactly 5 spans carry a form control.
        let raw_form_controls = count_matching_spans(&result.blocks, &|s: &Span| s.form_control.is_some());
        assert_eq!(raw_form_controls, 5, "{id}: expected 5 spans with Span.form_control set, found {raw_form_controls}");
        let source_digest = assert_feature_digest_parity(id, format, &bytes, &result);
        // The digest's OWN count must match too — this is the assertion that would actually catch
        // "a form control dropped" (see the defect-to-fixture answer in the return report).
        let digest_form_controls = count_digest_form_controls(&source_digest.body_blocks);
        assert_eq!(digest_form_controls, 5, "{id}: digest captured {digest_form_controls} form controls, expected 5");
    }
}

/// `feature-nested-table-{hwp,hwpx}` carry 11 `Cell.background_image` cells AND at least one
/// anchored object. Before S6-2, `from_office` refused on `AnchoredObjectPresent`; after S6-2 it
/// refused one step further in, on `CellBackgroundImagePresent`; S6-4 carries that fill instead of
/// refusing it, so this now builds a real tree — the same `assert_feature_digest_parity` every
/// OTHER accepted feature fixture in this file already gets, plus a direct count-pin on WHICH kind
/// of fill the 11 cells actually carry (parity alone would not catch a background silently
/// dropped, or a synthesized bitmap fabricated into a resource: `OfficeSemanticDigest` has no
/// field for either, by design — see this file's own digest struct).
///
/// `Cell.background_image` is `mapping.rs`'s MERGED field (real picture OR a synthesized gradient
/// bitmap), so its count alone does not say which kind these 11 are. rhwp's own
/// `resolve_single_border_style` resolves `image_fill`/`gradient` off the same `fill_type` match,
/// so a fill is never both — measured directly against this fixture's real bytes: all 11 are
/// `FillType::Gradient`, none are `FillType::Image`. `feature_picture_fill_now_accepted_and_carries_a_resource`
/// (below) is the test that proves a REAL picture fill becomes a resource, using a fixture that has one.
#[test]
fn feature_nested_table_source_facts_and_digest_parity() {
    let manifest = load_fixture_manifest();
    for id in ["feature-nested-table-hwp", "feature-nested-table-hwpx"] {
        let (bytes, format, result) = read_feature_fixture(&manifest, id);

        let tables = count_tables(&result.blocks);
        assert!(tables >= 2, "{id}: expected at least a top-level table plus one nested table, found {tables}");

        let picture_fill_cells = count_matching_cells(&result.blocks, &|c: &Cell| c.background_image.is_some());
        assert_eq!(picture_fill_cells, 11, "{id}: expected 11 Cell.background_image cells, found {picture_fill_cells}");

        assert!(
            result.images.len() >= 18,
            "{id}: expected at least 18 pre-decoded OfficeReadResult.images entries, found {}",
            result.images.len()
        );

        assert_feature_digest_parity(id, format, &bytes, &result);

        // This fixture's own `Cell.background_image` is `mapping.rs`'s MERGED field (real picture
        // OR a synthesized gradient bitmap) — the count-pin above only proves 11 cells have SOME
        // background, not which kind. `rhwp`'s own `resolve_single_border_style` resolves
        // `image_fill`/`gradient` off the SAME `fill_type` match, so a fill is never both; measured
        // directly here (fixture-real facts, not an assumption carried over from before S6-4 could
        // tell the two apart): all 11 of this fixture's flagged cells are `FillType::Gradient`, none
        // are `FillType::Image` — so the tree must carry 11 gradient declarations and ZERO resource
        // references. `feature_picture_fill_now_accepted_and_carries_a_resource` (below) is the test
        // that proves a REAL picture fill becomes a resource, using a fixture that actually has one.
        let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
            format,
            source_name: id,
            source_bytes: &bytes,
            result: &result,
            resources: BTreeMap::new(),
        })
        .unwrap_or_else(|e| panic!("{id}: from_office failed unexpectedly: {e:?} — report this, do not skip it"));
        let value: serde_json::Value = serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
        let nodes = value["nodes"].as_array().unwrap();
        let resourced_cells = nodes
            .iter()
            .filter(|n| n["type"] == "tableCell" && n["data"]["backgroundResourceId"].is_u64())
            .count();
        let gradient_cells = nodes
            .iter()
            .filter(|n| n["type"] == "tableCell" && n["data"]["backgroundGradient"].is_object())
            .count();
        assert_eq!(resourced_cells, 0, "{id}: this fixture's fills are all gradients, none are real pictures — a resourced cell here would mean a synthesized bitmap was fabricated into a document resource");
        assert_eq!(gradient_cells, 11, "{id}: expected all 11 gradient-fill cells to carry a backgroundGradient declaration, found {gradient_cells}");
    }
}

/// `feature-picture-fill-refusal-hwpx` was the one fixture this sprint's earlier stages named
/// specifically for a picture-fill refusal boundary. S6-4 removed that boundary — the document now
/// exports and builds a tree, so this asserts acceptance and the same resource-carrying proof the
/// nested-table test above uses, rather than a refusal that no longer happens.
#[test]
fn feature_picture_fill_now_accepted_and_carries_a_resource() {
    let manifest = load_fixture_manifest();
    let id = "feature-picture-fill-refusal-hwpx";
    let (bytes, format, result) = read_feature_fixture(&manifest, id);

    // Count-pin first: the manifest's own `why` says this document's only unexportable-before-S6-4
    // content is one cell picture fill with no master page and no anchored object ahead of it.
    let picture_fill_cells = count_matching_cells(&result.blocks, &|c: &Cell| c.background_image.is_some());
    assert!(picture_fill_cells >= 1, "{id}: expected at least one Cell.background_image picture-fill cell, found {picture_fill_cells}");

    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name: id,
        source_bytes: &bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("{id}: from_office failed unexpectedly: {e:?} — report this, do not skip it"));
    let value: serde_json::Value = serde_json::from_slice(&tree.encode_json().unwrap()).unwrap();
    let resourced_cells = value["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| n["type"] == "tableCell" && n["data"]["backgroundResourceId"].is_u64())
        .count();
    assert!(resourced_cells >= 1, "{id}: expected at least one tableCell with a backgroundResourceId");
}

/// Count-pins the nested-table fixture's own image identity fact (used by the defect-to-fixture
/// answer for "image resource identity replaced by a different hash") independently of whether
/// `from_office` accepts the document — this only inspects `OfficeReadResult`, never the tree.
#[test]
fn feature_nested_table_image_identity_is_present_on_the_source_side() {
    let manifest = load_fixture_manifest();
    for id in ["feature-nested-table-hwp", "feature-nested-table-hwpx"] {
        let (_bytes, _format, result) = read_feature_fixture(&manifest, id);
        let mut inline_images = 0usize;
        fn count_images(blocks: &[OfficeBlock], acc: &mut usize) {
            for block in blocks {
                match block {
                    OfficeBlock::Image { .. } => *acc += 1,
                    OfficeBlock::Table { rows, .. } => {
                        for row in rows {
                            for cell in row {
                                count_images(&cell.blocks, acc);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        count_images(&result.blocks, &mut inline_images);
        assert!(inline_images >= 1, "{id}: expected at least one inline OfficeBlock::Image, found {inline_images}");
        assert!(!result.images.is_empty(), "{id}: expected OfficeReadResult.images to be non-empty");
    }
}

/// The feature-rich baseline — a SECOND project-authored docx (this sprint's own S2A2 gate item,
/// `feature-rich-docx-baseline` in `Tests/Baseline/fixtures.json`'s `featureFixtures`), closing the
/// two holes this sprint's report names: no fixture anywhere in this file carried a single
/// `Heading` block before this one (mutating the adapter to clamp every heading level to 1 left
/// all 116 prior tests green), and every fixture that reaches a canonical tree carried zero
/// images (every image-bearing fixture above refuses in `from_office` before a tree exists).
#[test]
fn feature_rich_docx_baseline_digest_parity_and_defect_coverage() {
    let manifest = load_fixture_manifest();
    let (zip_bytes, png_bytes) = feature_rich_docx_bytes_checked(&manifest);
    let archive =
        ZipArchive::new(Data::fromBytes(zip_bytes.clone())).expect("feature-rich-docx-baseline: ZipArchive::new");
    let result = DocxReader::read(&archive).expect("feature-rich-docx-baseline: DocxReader::read");

    // Count-pin FIRST (item 4's own requirement — an empty-collection equality passes for the
    // wrong reason): exactly 2 headings at 2 DISTINCT levels, and exactly 1 inline image, read
    // straight off `OfficeReadResult`, before any digest is even built.
    let heading_levels: Vec<i64> = result
        .blocks
        .iter()
        .filter_map(|b| match b {
            OfficeBlock::Heading { level, .. } => Some(*level),
            _ => None,
        })
        .collect();
    assert_eq!(heading_levels.len(), 2, "expected exactly 2 top-level headings, found {}", heading_levels.len());
    let distinct_levels: BTreeSet<i64> = heading_levels.iter().copied().collect();
    assert_eq!(distinct_levels.len(), 2, "expected 2 DISTINCT heading levels, found {heading_levels:?}");
    assert_eq!(
        heading_levels,
        vec![1, 2],
        "expected the bare `w:pStyle` Heading1/Heading2 declarations to resolve to levels 1 and 2 respectively \
         (DocxReader::heading_level, mechanism (b) — no styles.xml needed), found {heading_levels:?}"
    );

    let image_ids: Vec<String> = result
        .blocks
        .iter()
        .filter_map(|b| match b {
            OfficeBlock::Image { id, .. } => Some(id.as_str().to_string()),
            _ => None,
        })
        .collect();
    assert_eq!(image_ids.len(), 1, "expected exactly 1 inline OfficeBlock::Image, found {}", image_ids.len());
    assert_eq!(
        image_ids[0], FEATURE_RICH_IMAGE_RESOURCE_ID,
        "the image's resolved OfficeBlock::Image.id diverged from the relationship-resolution this fixture was \
         built to exercise (DocxReader::resolve_id / parse_relationships) — report the real id, do not adjust \
         the constant to match it silently"
    );

    let resource_sha = sha256_hex(&png_bytes);
    let mut resources_for_adapter: BTreeMap<String, ResolvedOfficeResource> = BTreeMap::new();
    resources_for_adapter.insert(
        FEATURE_RICH_IMAGE_RESOURCE_ID.to_string(),
        ResolvedOfficeResource { bytes: png_bytes.clone(), mime_type: "image/png".to_string() },
    );
    let mut resources_for_source_digest: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    resources_for_source_digest.insert(FEATURE_RICH_IMAGE_RESOURCE_ID.to_string(), png_bytes.clone());

    // `DocxReader::read` never populates `OfficeReadResult.images` itself (that map is HWP's
    // pre-decode convenience only — see `SrcCtx.resources`'s own doc) — so the source-side digest
    // is built through `digest_from_office_result_with_resources`, the caller-supplied-bytes
    // variant this sprint added, with the SAME png bytes handed to the canonical side below.
    let source_digest = digest_from_office_result_with_resources(&result, &resources_for_source_digest);
    assert!(!source_digest.body_blocks.is_empty(), "feature-rich-docx-baseline: source digest has no body blocks");

    // The digest's OWN view of the image — this is the assertion that would actually catch defect
    // 2 ("image resource identity swapped for a different hash"): a swap changes this sha, nothing
    // else in the digest.
    let digest_image_shas: Vec<Option<String>> = source_digest
        .body_blocks
        .iter()
        .filter_map(|b| match &b.kind {
            DigestKind::Image { resource_sha256 } => Some(resource_sha256.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(digest_image_shas.len(), 1, "expected exactly 1 digest Image block, found {}", digest_image_shas.len());
    assert_eq!(
        digest_image_shas[0],
        Some(resource_sha.clone()),
        "digest's own DigestKind::Image.resource_sha256 did not resolve to the real PNG bytes' own sha256"
    );

    // The digest's OWN view of the headings — this is the assertion that would actually catch
    // defect 1 ("heading level collapsed to a constant"): a clamp-to-1 would still leave 2
    // `DigestKind::Heading` blocks, but their levels would read `[1, 1]`, not `[1, 2]`.
    let digest_heading_levels: Vec<i64> = source_digest
        .body_blocks
        .iter()
        .filter_map(|b| match &b.kind {
            DigestKind::Heading { level } => Some(*level),
            _ => None,
        })
        .collect();
    assert_eq!(
        digest_heading_levels,
        vec![1, 2],
        "digest's own DigestKind::Heading levels diverged from the source-side count-pin"
    );

    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Docx,
        source_name: "feature-rich-docx-baseline",
        source_bytes: &zip_bytes,
        result: &result,
        resources: resources_for_adapter,
    })
    .unwrap_or_else(|e| {
        panic!("feature-rich-docx-baseline: from_office failed unexpectedly: {e:?} — report this, do not skip it")
    });
    let canonical_digest = digest_from_validated_tree(&tree);

    assert_eq!(
        source_digest.body_blocks.len(),
        canonical_digest.body_blocks.len(),
        "feature-rich-docx-baseline: block count diverged before content comparison"
    );
    assert_eq!(
        source_digest, canonical_digest,
        "feature-rich-docx-baseline: source and canonical digests diverged"
    );
}
