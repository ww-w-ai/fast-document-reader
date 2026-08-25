//! The four documents this app actually ships, driven through the markdown producer.
//!
//! The feature-level parity harness (`markdown_parity.rs`) checks one construct at a time against
//! what the Swift audit asserts. This file asks the other question: does the producer survive the
//! real files, at their real size, with everything mixed together — code fences beside mermaid,
//! math beside prose, and a 1.2 MB novel.
//!
//! `moby-dick.md` is deliberately included. Invariant 101's first-paint measurement came from it,
//! and a producer that is correct on a twelve-line fixture and quadratic on a real book is a
//! producer that has not been tested.

use std::path::PathBuf;

fn demo(name: &str) -> Option<Vec<u8>> {
    // tests run from the crate dir; the demo corpus is three levels up at the repo root.
    let path: PathBuf = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../demo")
        .join(name);
    std::fs::read(path).ok()
}

/// Every shipped document reaches a validated tree, and the tree is not empty.
///
/// "Not empty" is the assertion that matters: a producer that silently returned a tree with no
/// nodes would round-trip perfectly and pass every structural check written so far.
#[test]
fn every_shipped_demo_document_reaches_a_non_empty_validated_tree() {
    let names = ["code-blocks.md", "images.md", "math.md", "moby-dick.md"];
    let mut checked = 0;
    for name in names {
        let Some(bytes) = demo(name) else {
            continue; // a checkout without the demo corpus is not a failing producer
        };
        let tree = fastdoc_engine::render::markdown::produce(&bytes, name)
            .unwrap_or_else(|e| panic!("{name}: the producer refused a shipped document: {e:?}"));
        let tags = tree.node_tags();
        assert!(
            !tags.is_empty(),
            "{name}: the producer returned a tree with no nodes — it did not error, but nothing \
             from the document survived"
        );
        let encoded = tree
            .encode_json()
            .unwrap_or_else(|e| panic!("{name}: encode_json failed: {e:?}"));
        let decoded = fastdoc_engine::render::render_tree::ValidatedRenderTree::decode_json(&encoded)
            .unwrap_or_else(|e| panic!("{name}: its own encode did not decode: {e:?}"));
        assert_eq!(decoded.node_tags(), tags, "{name}: node tags did not survive decode");
        checked += 1;
    }
    assert!(checked > 0, "no demo document was found — this test proved nothing");
}

/// The documents that carry the constructs this sprint added actually exercise them.
///
/// Without this, the test above passes on four files of plain paragraphs and reports coverage it
/// does not have.
#[test]
fn the_demo_corpus_exercises_the_constructs_this_sprint_added() {
    if let Some(bytes) = demo("code-blocks.md") {
        let tree = fastdoc_engine::render::markdown::produce(&bytes, "code-blocks.md").unwrap();
        let tags = tree.node_tags();
        assert!(tags.contains(&"codeBlock"), "code-blocks.md has no codeBlock node");
        assert!(tags.contains(&"diagram"), "code-blocks.md ships mermaid fences; none became a diagram");
    }
    if let Some(bytes) = demo("math.md") {
        let tree = fastdoc_engine::render::markdown::produce(&bytes, "math.md").unwrap();
        assert!(tree.node_tags().contains(&"formula"), "math.md produced no formula node");
    }
    if let Some(bytes) = demo("images.md") {
        let tree = fastdoc_engine::render::markdown::produce(&bytes, "images.md").unwrap();
        assert!(tree.node_tags().contains(&"image"), "images.md produced no image node");
    }
}
