//! S6-5a — a picture the document declared but supplied no bytes for must not cost the whole
//! document.
//!
//! Regression test for the fix: before it, `ValidatedRenderTree::from_office` refused any of the
//! 12 real documents from S6-5's own measured census (`.ww-w-ai/cowork-sprint/plans/s6.md`,
//! "S6-5 — 잔여 거절 15건") with `MissingResource("hwpimg:N")`, because `HwpReader::collect_images`
//! silently skipped a picture whose `binDataIDRef` resolves to no bytes (an empty reference, an
//! external link, or bin_data_id's own "no bin data" sentinel `0`) rather than recording the fact.
//! This test fails if that fix is reverted: it asserts BOTH that the document is ACCEPTED and
//! that its picture is still IN the tree — not merely that no error occurred, which a totally
//! different (and wrong) fix, such as dropping the picture block outright, could also satisfy.
//!
//! P2c moved WHERE the "no bytes" fact is established. It used to be recorded at read, by a walk
//! that fetched every picture in the document — the walk P2c removed, because fetching 109
//! pictures to draw none of them is what made this reader slower than the one it replaced. The
//! fact is not lost: it is answered by the same call a host makes when it is about to draw the
//! picture, and this test now asks through THAT door. That is the door that matters — the old
//! assertion checked a set nothing outside the adapter ever read.

use fastdoc_engine::render::office::hwp_reader::mapping::{HwpReader, PictureBytes};
use fastdoc_engine::render::office::office_block::OfficeBlock;
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

    let (result, retained) =
        HwpReader::read_retaining_parse(&swiftshim::Data::fromBytes(bytes.clone()), false)
            .expect("HwpReader::read succeeds on this fixture");

    // The truth is established by ASKING — the same call the host makes when it is about to draw
    // this picture, answering `DeclaredWithoutBytes` rather than a blank the caller has to guess
    // about. Walking the document for the ids keeps this honest about which picture it found.
    fn picture_ids(blocks: &[OfficeBlock], out: &mut Vec<String>) {
        for block in blocks {
            match block {
                OfficeBlock::Image { id, .. } => out.push(id.to_string()),
                OfficeBlock::Table { rows, .. } => {
                    for row in rows {
                        for cell in row {
                            picture_ids(&cell.blocks, out);
                        }
                    }
                }
                _ => {}
            }
        }
    }
    let mut ids = Vec::new();
    picture_ids(&result.blocks, &mut ids);
    for hf in result.headers.iter().chain(result.footers.iter()) {
        picture_ids(&hf.blocks, &mut ids);
    }
    for footnote in &result.footnotes {
        picture_ids(&footnote.blocks, &mut ids);
    }
    let declared_without_bytes: Vec<&String> = ids
        .iter()
        .filter(|id| matches!(retained.picture_for_id(id), PictureBytes::DeclaredWithoutBytes))
        .collect();
    assert!(
        !declared_without_bytes.is_empty(),
        "expected this fixture to declare at least one picture with no bytes behind it \
         (empty binDataIDRef). Ids walked: {ids:?}"
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
    // The picture must still BE in the tree, carrying the key it was declared under, so the host
    // has something to ask about. A picture dropped from the tree would also produce no error.
    let carried: Vec<&serde_json::Value> = nodes
        .iter()
        .filter(|n| {
            n["type"] == "image"
                && declared_without_bytes
                    .iter()
                    .any(|id| n["data"]["sourceKey"] == ***id)
        })
        .collect();
    assert!(
        !carried.is_empty(),
        "the declared-without-bytes picture is not in the tree at all — a host cannot draw an \
         empty box for a node that does not exist. Looking for {declared_without_bytes:?}"
    );
}
