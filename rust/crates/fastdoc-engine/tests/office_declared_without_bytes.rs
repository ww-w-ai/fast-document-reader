//! S6-5a — a picture the document declared but supplied no bytes for must not cost the whole
//! document.
//!
//! Regression test for the fix: before it, `ValidatedRenderTree::from_office` refused any of the
//! 12 real documents from S6-5's own measured census (`.ww-w-ai/cowork-sprint/plans/s6.md`,
//! "S6-5 — 잔여 거절 15건") with `MissingResource("hwpimg:N")`, because `HwpReader::collect_images`
//! silently skipped a picture whose `binDataIDRef` resolves to no bytes (an empty reference, an
//! external link, or bin_data_id's own "no bin data" sentinel `0`) rather than recording the fact.
//! This test fails if that fix is reverted: it asserts BOTH that `HwpReader` records the fact
//! (`OfficeReadResult.pictures_declared_without_bytes` is non-empty) and that the tree is
//! produced with an `image` node whose `resourceId` is absent — not merely that no error occurred,
//! which a totally different (and wrong) fix, such as dropping the picture block outright, could
//! also satisfy.

use fastdoc_engine::render::office::hwp_reader::mapping::HwpReader;
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};

use std::collections::BTreeMap;
use std::path::PathBuf;

fn corpus_fixture(rel_path: &str) -> Vec<u8> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../..").join(rel_path);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

#[test]
fn a_picture_declared_without_bytes_renders_an_empty_box_instead_of_refusing_the_document() {
    // One of S6-5's own measured `MissingResource("hwpimg:0")` documents — a table cell carries
    // `<hc:img binaryItemIDRef=""/>` (an empty reference).
    let bytes = corpus_fixture(
        "Vendor/rhwp-src/samples/hwpx/opengov/36385464_결재문서본문_근무변경(반포수난구조대, 2026-06).hwpx",
    );

    let result =
        HwpReader::read_before_host_font_substitution(&swiftshim::Data::fromBytes(bytes.clone()))
            .expect("HwpReader::read succeeds on this fixture");

    // The truth is established HERE, by the reader that just asked its own image FFI and got
    // nothing back — never guessed downstream by the adapter.
    assert!(
        !result.pictures_declared_without_bytes.is_empty(),
        "expected this fixture to declare at least one picture with no bytes behind it \
         (empty binDataIDRef) — if this is empty, either the fixture changed or `collect_images` \
         stopped recording the fact"
    );

    // The document must be ACCEPTED, not refused — the whole point of this fix.
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Hwpx,
        source_name: "document.hwpx",
        source_bytes: &bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| {
        panic!(
            "from_office refused a document with a declared-without-bytes picture (S6-5a \
             regression — MissingResource must not fire for this case any more): {e:?}"
        )
    });

    // And the tree must say WHY the picture is empty as a positive fact — an `image` node with
    // NO `resourceId` — not merely that no error occurred (a picture silently dropped from the
    // tree entirely would also produce a non-error, wrong-for-a-different-reason result).
    let json = tree.encode_json().expect("tree re-encodes to JSON");
    let value: serde_json::Value = serde_json::from_slice(&json).expect("tree JSON decodes");
    let nodes = value["nodes"].as_array().expect("envelope has a nodes array");
    let declared_without_bytes_image_nodes = nodes
        .iter()
        .filter(|n| n["type"] == "image" && n.get("resourceId").is_none())
        .count();
    assert!(
        declared_without_bytes_image_nodes >= 1,
        "expected at least one `image` node with `resourceId` omitted (the declared-without-bytes \
         case) in the tree; nodes: {nodes:#?}"
    );
}
