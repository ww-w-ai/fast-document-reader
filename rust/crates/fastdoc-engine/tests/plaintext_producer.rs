//! S3-07: `render::plaintext::produce`'s block vocabulary, line splitting, encoding rejection
//! and source-span conversion. Same JSON-inspection pattern `markdown_block_producer.rs` and
//! `render_tree_v1.rs` use, since `ValidatedRenderTree` keeps its inner graph private outside
//! the crate.

use fastdoc_engine::render::plaintext::{produce, PlainTextError};
use serde_json::Value;

fn nodes_of(text: &str) -> Vec<Value> {
    let tree = produce(text.as_bytes(), "test.txt").unwrap();
    let json = tree.encode_json().unwrap();
    let value: Value = serde_json::from_slice(&json).unwrap();
    value["nodes"].as_array().unwrap().clone()
}

fn nodes_by_tag<'a>(nodes: &'a [Value], tag: &str) -> Vec<&'a Value> {
    nodes.iter().filter(|n| n["type"] == tag).collect()
}

fn children_of<'a>(nodes: &'a [Value], id: u64) -> Vec<&'a Value> {
    let ids: Vec<u64> = nodes
        .iter()
        .find(|n| n["id"].as_u64() == Some(id))
        .and_then(|n| n["children"].as_array())
        .unwrap()
        .iter()
        .map(|c| c.as_u64().unwrap())
        .collect();
    ids.into_iter()
        .map(|cid| nodes.iter().find(|n| n["id"].as_u64() == Some(cid)).unwrap())
        .collect()
}

fn node_id(node: &Value) -> u64 {
    node["id"].as_u64().unwrap()
}

fn doc_node(nodes: &[Value]) -> &Value {
    nodes.iter().find(|n| n["type"] == "document").unwrap()
}

// ---------------------------------------------------------------------------------------------
// Multi-line text reaches a validated tree with non-empty nodes.
// ---------------------------------------------------------------------------------------------

#[test]
fn multi_line_text_reaches_a_validated_tree_non_empty() {
    let nodes = nodes_of("first line\nsecond line\nthird line\n");
    assert!(!nodes.is_empty(), "expected a non-empty node list");
    let paragraphs = nodes_by_tag(&nodes, "paragraph");
    assert_eq!(paragraphs.len(), 3, "expected one paragraph per line, got {nodes:?}");
    let texts: Vec<String> = paragraphs
        .iter()
        .map(|p| {
            let children = children_of(&nodes, node_id(p));
            assert_eq!(children.len(), 1);
            assert_eq!(children[0]["type"], "textRun");
            children[0]["data"]["text"].as_str().unwrap().to_string()
        })
        .collect();
    assert_eq!(texts, vec!["first line", "second line", "third line"]);
}

// ---------------------------------------------------------------------------------------------
// The three line endings this format allows all produce the SAME paragraph text.
// ---------------------------------------------------------------------------------------------

#[test]
fn the_three_line_endings_agree() {
    let lf = nodes_of("a\nb\n");
    let crlf = nodes_of("a\r\nb\r\n");
    let cr = nodes_of("a\rb\r");

    for nodes in [&lf, &crlf, &cr] {
        let paragraphs = nodes_by_tag(nodes, "paragraph");
        assert_eq!(paragraphs.len(), 2, "expected 2 paragraphs, got {nodes:?}");
        let texts: Vec<String> = paragraphs
            .iter()
            .map(|p| {
                let children = children_of(nodes, node_id(p));
                children[0]["data"]["text"].as_str().unwrap().to_string()
            })
            .collect();
        assert_eq!(texts, vec!["a", "b"]);
    }
}

// ---------------------------------------------------------------------------------------------
// Markdown punctuation at the start of a line stays plain text: no heading, list or table.
// ---------------------------------------------------------------------------------------------

#[test]
fn heading_punctuation_stays_plain_text() {
    let nodes = nodes_of("# not a heading\n");
    assert_eq!(nodes_by_tag(&nodes, "heading").len(), 0);
    let paragraphs = nodes_by_tag(&nodes, "paragraph");
    assert_eq!(paragraphs.len(), 1);
    let children = children_of(&nodes, node_id(paragraphs[0]));
    assert_eq!(children[0]["data"]["text"], "# not a heading");
}

#[test]
fn list_and_table_punctuation_stays_plain_text() {
    let nodes = nodes_of("* not a list item\n| not | a | table |\n");
    assert_eq!(nodes_by_tag(&nodes, "list").len(), 0);
    assert_eq!(nodes_by_tag(&nodes, "listItem").len(), 0);
    assert_eq!(nodes_by_tag(&nodes, "table").len(), 0);
    let paragraphs = nodes_by_tag(&nodes, "paragraph");
    assert_eq!(paragraphs.len(), 2);
    let first = children_of(&nodes, node_id(paragraphs[0]));
    assert_eq!(first[0]["data"]["text"], "* not a list item");
    let second = children_of(&nodes, node_id(paragraphs[1]));
    assert_eq!(second[0]["data"]["text"], "| not | a | table |");
}

// ---------------------------------------------------------------------------------------------
// Blank lines are their own paragraph, matching PlainTextRenderer.swift — not merged into the
// surrounding lines and not treated as a markdown-style paragraph separator.
// ---------------------------------------------------------------------------------------------

#[test]
fn blank_lines_are_their_own_paragraph() {
    let nodes = nodes_of("first\n\nthird\n");
    let paragraphs = nodes_by_tag(&nodes, "paragraph");
    assert_eq!(paragraphs.len(), 3, "expected 3 paragraphs (blank line included), got {nodes:?}");
    let texts: Vec<String> = paragraphs
        .iter()
        .map(|p| {
            let children = children_of(&nodes, node_id(p));
            children[0]["data"]["text"].as_str().unwrap().to_string()
        })
        .collect();
    assert_eq!(texts, vec!["first", "", "third"]);
}

// ---------------------------------------------------------------------------------------------
// Document root's children are exactly its paragraphs, in source order.
// ---------------------------------------------------------------------------------------------

#[test]
fn document_root_lists_paragraphs_in_order() {
    let nodes = nodes_of("one\ntwo\n");
    let doc = doc_node(&nodes);
    let children = children_of(&nodes, node_id(doc));
    assert_eq!(children.len(), 2);
    assert_eq!(children[0]["type"], "paragraph");
    assert_eq!(children[1]["type"], "paragraph");
}

// ---------------------------------------------------------------------------------------------
// Non-UTF-8 bytes are refused with a typed error naming the offending offset, never silently
// lossy-converted.
// ---------------------------------------------------------------------------------------------

#[test]
fn invalid_utf8_is_rejected_with_a_typed_error() {
    // "ab" followed by a lone continuation byte (0x80), which is never valid on its own.
    let bytes: &[u8] = &[b'a', b'b', 0x80];
    let result = produce(bytes, "test.txt");
    match result {
        Err(PlainTextError::InvalidUtf8 { valid_up_to }) => assert_eq!(valid_up_to, 2),
        other => panic!("expected InvalidUtf8, got {other:?}"),
    }
}

#[test]
fn ascii_and_valid_utf8_are_accepted() {
    let result = produce("hello\n".as_bytes(), "test.txt");
    assert!(result.is_ok());
}

// ---------------------------------------------------------------------------------------------
// Source spans: UTF-8/UTF-16 offsets actually slice the original text back out, for a line
// mixing Korean and an emoji (multi-byte in UTF-8, surrogate-pair-wide in UTF-16).
// ---------------------------------------------------------------------------------------------

#[test]
fn source_spans_slice_korean_and_emoji_text_correctly() {
    let source = "안녕 🎉\nsecond\n";
    let tree = produce(source.as_bytes(), "test.txt").unwrap();
    let json = tree.encode_json().unwrap();
    let value: Value = serde_json::from_slice(&json).unwrap();
    let nodes = value["nodes"].as_array().unwrap();
    let paragraphs = nodes_by_tag(nodes, "paragraph");
    assert_eq!(paragraphs.len(), 2);

    let span = &paragraphs[0]["sourceSpans"][0]["segments"][0];
    let utf8_start = span["utf8Start"].as_u64().unwrap() as usize;
    let utf8_end = span["utf8End"].as_u64().unwrap() as usize;
    let utf16_start = span["utf16Start"].as_u64().unwrap();
    let utf16_end = span["utf16End"].as_u64().unwrap();

    // The byte slice this span names must equal the line's own text exactly.
    assert_eq!(&source[utf8_start..utf8_end], "안녕 🎉");

    // The UTF-16 slice (via UTF-16 code units) must agree too — the emoji is a surrogate pair.
    let utf16_units: Vec<u16> = source.encode_utf16().collect();
    let utf16_slice: String = char::decode_utf16(
        utf16_units[utf16_start as usize..utf16_end as usize].iter().copied(),
    )
    .map(|c| c.unwrap())
    .collect();
    assert_eq!(utf16_slice, "안녕 🎉");
}

// ---------------------------------------------------------------------------------------------
// Round trip: encode -> decode -> encode is stable.
// ---------------------------------------------------------------------------------------------

#[test]
fn round_trip_is_stable() {
    let tree = produce("first\n\nsecond 안녕 🎉\nthird".as_bytes(), "test.txt").unwrap();
    let first_json = tree.encode_json().unwrap();
    let decoded = fastdoc_engine::render::render_tree::ValidatedRenderTree::decode_json(&first_json)
        .unwrap();
    let second_json = decoded.encode_json().unwrap();
    assert_eq!(first_json, second_json);
}
