//! S3 pass A: `render::markdown::produce`'s block vocabulary and source-span conversion
//! (S3-03, S3-11). Every assertion inspects the wire JSON directly (`serde_json::Value`), the
//! same pattern `render_tree_v1.rs` uses, since `ValidatedRenderTree` keeps its inner graph
//! private outside the crate.

use fastdoc_engine::render::markdown::produce;
use fastdoc_engine::render::render_tree::ValidatedRenderTree;
use serde_json::Value;

fn nodes_of(markdown: &str) -> Vec<Value> {
    let tree = produce(markdown.as_bytes(), "test.md").unwrap();
    let json = tree.encode_json().unwrap();
    let value: Value = serde_json::from_slice(&json).unwrap();
    value["nodes"].as_array().unwrap().clone()
}

fn nodes_by_tag<'a>(nodes: &'a [Value], tag: &str) -> Vec<&'a Value> {
    nodes.iter().filter(|n| n["type"] == tag).collect()
}

fn children_of(nodes: &[Value], id: u64) -> Vec<&Value> {
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

// ---------------------------------------------------------------------------------------------
// Every block kind this pass produces actually reaches the tree, non-empty first (a round trip
// on an EMPTY tree is trivially perfect, so presence is asserted before anything else).
// ---------------------------------------------------------------------------------------------

#[test]
fn heading_reaches_a_validated_tree() {
    let nodes = nodes_of("# Title\n");
    let headings = nodes_by_tag(&nodes, "heading");
    assert_eq!(headings.len(), 1, "expected exactly one heading node, got {nodes:?}");
    assert_eq!(headings[0]["data"]["level"], 1);
    let text_children = children_of(&nodes, node_id(headings[0]));
    assert_eq!(text_children.len(), 1);
    assert_eq!(text_children[0]["type"], "textRun");
    assert_eq!(text_children[0]["data"]["text"], "Title");
}

#[test]
fn paragraph_reaches_a_validated_tree() {
    let nodes = nodes_of("A plain paragraph.\n");
    let paragraphs = nodes_by_tag(&nodes, "paragraph");
    assert_eq!(paragraphs.len(), 1, "expected exactly one paragraph, got {nodes:?}");
    let text_children = children_of(&nodes, node_id(paragraphs[0]));
    assert_eq!(text_children[0]["data"]["text"], "A plain paragraph.");
}

#[test]
fn block_quote_reaches_a_validated_tree_with_its_paragraph_inside() {
    let nodes = nodes_of("> quoted text\n");
    let quotes = nodes_by_tag(&nodes, "blockQuote");
    assert_eq!(quotes.len(), 1, "expected exactly one blockQuote, got {nodes:?}");
    let inner = children_of(&nodes, node_id(quotes[0]));
    assert_eq!(inner.len(), 1);
    assert_eq!(inner[0]["type"], "paragraph");
}

#[test]
fn fenced_code_block_carries_language_and_text() {
    let nodes = nodes_of("```rust\nfn main() {}\n```\n");
    let code_blocks = nodes_by_tag(&nodes, "codeBlock");
    assert_eq!(code_blocks.len(), 1, "expected exactly one codeBlock, got {nodes:?}");
    assert_eq!(code_blocks[0]["data"]["language"], "rust");
    assert_eq!(code_blocks[0]["data"]["fenced"], true);
    assert_eq!(code_blocks[0]["data"]["text"], "fn main() {}\n");
}

#[test]
fn indented_code_block_is_unfenced_with_no_language() {
    let nodes = nodes_of("    indented code\n");
    let code_blocks = nodes_by_tag(&nodes, "codeBlock");
    assert_eq!(code_blocks.len(), 1, "expected exactly one codeBlock, got {nodes:?}");
    assert_eq!(code_blocks[0]["data"]["fenced"], false);
    assert!(code_blocks[0]["data"]["language"].is_null());
}

/// S8-B3: a fence with a language the highlighter's scanner recognises carries `runs` — one entry
/// per `CodeHighlighter::tokenize` span, `role` serialized camelCase (`wire::CodeRole`).
#[test]
fn fenced_code_block_with_known_language_carries_runs() {
    let nodes = nodes_of("```rust\nfn main() {}\n```\n");
    let code_blocks = nodes_by_tag(&nodes, "codeBlock");
    let runs = code_blocks[0]["data"]["runs"].as_array().expect("runs must be present and an array");
    assert!(!runs.is_empty(), "\"fn\"/\"main\" tokens are expected to produce at least one run");
    let fn_run = runs
        .iter()
        .find(|r| r["role"] == "keyword")
        .expect("the `fn` keyword must produce a keyword run");
    assert_eq!(fn_run["start"], 0);
    assert_eq!(fn_run["end"], 2);
}

/// A fence whose info string the scanner does not recognise gets `runs: null` (`None`), never an
/// empty array — that distinction is how the producer tells "nothing to colour" (known language,
/// empty `Vec`) apart from "unknown language" (`CodeHighlighter::is_known` false).
#[test]
fn fenced_code_block_with_unknown_language_has_no_runs() {
    let nodes = nodes_of("```not-a-real-language\nsome text\n```\n");
    let code_blocks = nodes_by_tag(&nodes, "codeBlock");
    assert!(code_blocks[0]["data"]["runs"].is_null());
}

/// A fence with no info string at all (unfenced/indented code, or a bare ``` fence) is also an
/// unknown language, so `runs` stays absent.
#[test]
fn indented_code_block_has_no_runs() {
    let nodes = nodes_of("    indented code\n");
    let code_blocks = nodes_by_tag(&nodes, "codeBlock");
    assert!(code_blocks[0]["data"]["runs"].is_null());
}

#[test]
fn thematic_break_reaches_a_validated_tree() {
    let nodes = nodes_of("above\n\n---\n\nbelow\n");
    let breaks = nodes_by_tag(&nodes, "thematicBreak");
    assert_eq!(breaks.len(), 1, "expected exactly one thematicBreak, got {nodes:?}");
}

// ---------------------------------------------------------------------------------------------
// Lists: ordered/unordered and tight/loose.
// ---------------------------------------------------------------------------------------------

#[test]
fn unordered_tight_list_collapses_each_item_straight_to_a_text_run() {
    let nodes = nodes_of("- one\n- two\n");
    let lists = nodes_by_tag(&nodes, "list");
    assert_eq!(lists.len(), 1, "expected exactly one list, got {nodes:?}");
    let items = children_of(&nodes, node_id(lists[0]));
    assert_eq!(items.len(), 2);
    for item in &items {
        assert_eq!(item["type"], "listItem");
        assert_eq!(item["data"]["ordered"], false);
        let item_children = children_of(&nodes, node_id(item));
        assert_eq!(
            item_children.len(),
            1,
            "tight list item should have exactly one child, got {item_children:?}"
        );
        assert_eq!(
            item_children[0]["type"], "textRun",
            "tight list item's own paragraph must collapse to a bare textRun (no paragraph wrapper)"
        );
    }
}

#[test]
fn loose_list_keeps_the_paragraph_wrapper_the_tight_list_collapses() {
    // A blank line between items makes the list LOOSE per CommonMark.
    let nodes = nodes_of("- one\n\n- two\n");
    let lists = nodes_by_tag(&nodes, "list");
    assert_eq!(lists.len(), 1, "expected exactly one list, got {nodes:?}");
    let items = children_of(&nodes, node_id(lists[0]));
    assert_eq!(items.len(), 2);
    for item in &items {
        let item_children = children_of(&nodes, node_id(item));
        assert_eq!(item_children.len(), 1);
        assert_eq!(
            item_children[0]["type"], "paragraph",
            "loose list item must keep its paragraph node — this is what tells tight and loose \
             apart in a schema with no dedicated field for it"
        );
    }
}

#[test]
fn ordered_list_carries_its_start_number_and_marks_items_ordered() {
    let nodes = nodes_of("3. third\n4. fourth\n");
    let lists = nodes_by_tag(&nodes, "list");
    assert_eq!(lists.len(), 1, "expected exactly one list, got {nodes:?}");
    assert_eq!(lists[0]["data"]["numbering"]["startNumber"], 3);
    let items = children_of(&nodes, node_id(lists[0]));
    for item in &items {
        assert_eq!(item["type"], "listItem");
        assert_eq!(item["data"]["ordered"], true);
    }
}

#[test]
fn task_list_items_carry_their_checked_state() {
    let nodes = nodes_of("- [ ] todo\n- [x] done\n");
    let lists = nodes_by_tag(&nodes, "list");
    assert_eq!(lists.len(), 1, "expected exactly one list, got {nodes:?}");
    let items = children_of(&nodes, node_id(lists[0]));
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["type"], "taskListItem");
    assert_eq!(items[0]["data"]["checked"], false);
    assert_eq!(items[1]["type"], "taskListItem");
    assert_eq!(items[1]["data"]["checked"], true);
}

#[test]
fn nested_list_gets_a_deeper_level() {
    let nodes = nodes_of("- outer\n  - inner\n");
    let lists = nodes_by_tag(&nodes, "list");
    assert_eq!(lists.len(), 2, "expected an outer and a nested list, got {nodes:?}");
    let items = nodes_by_tag(&nodes, "listItem");
    let levels: Vec<i64> = items.iter().map(|i| i["data"]["level"].as_i64().unwrap()).collect();
    assert!(levels.contains(&1), "expected a level-1 item, got {levels:?}");
    assert!(levels.contains(&2), "expected a level-2 (nested) item, got {levels:?}");
}

// ---------------------------------------------------------------------------------------------
// Table: alignment survives per column, as the cell's own paragraph alignment.
// ---------------------------------------------------------------------------------------------

#[test]
fn table_preserves_left_center_right_column_alignment() {
    let markdown = "| L | C | R |\n|:--|:-:|--:|\n| a | b | c |\n";
    let nodes = nodes_of(markdown);
    let tables = nodes_by_tag(&nodes, "table");
    assert_eq!(tables.len(), 1, "expected exactly one table, got {nodes:?}");
    assert_eq!(tables[0]["data"]["headerRows"], 1);

    let rows = children_of(&nodes, node_id(tables[0]));
    assert_eq!(rows.len(), 2, "expected a header row and one body row");
    assert_eq!(rows[0]["data"]["header"], true);
    assert_eq!(rows[1]["data"]["header"], false);

    let body_cells = children_of(&nodes, node_id(rows[1]));
    assert_eq!(body_cells.len(), 3);
    let expected = ["left", "center", "right"];
    for (cell, expected_alignment) in body_cells.iter().zip(expected.iter()) {
        let paragraph = &children_of(&nodes, node_id(cell))[0];
        assert_eq!(
            paragraph["type"], "paragraph",
            "cell content must be wrapped so its alignment has somewhere to live"
        );
        assert_eq!(paragraph["data"]["style"]["alignment"], *expected_alignment);
    }
}

// ---------------------------------------------------------------------------------------------
// Source spans (S3-11): the measurement `tests/comrak_sourcepos_probe.rs` settled — byte columns,
// no tab expansion, inclusive end — fixed as behaviour here, on a fixture mixing Korean, an
// emoji, and multiple blocks so an ASCII-only conversion could not pass this by accident.
// ---------------------------------------------------------------------------------------------

fn text_span(node: &Value) -> (u64, u64, u64, u64) {
    let segment = &node["sourceSpans"][0]["segments"][0];
    assert_eq!(segment["kind"], "text", "expected a Text range segment, got {segment:?}");
    (
        segment["utf8Start"].as_u64().unwrap(),
        segment["utf8End"].as_u64().unwrap(),
        segment["utf16Start"].as_u64().unwrap(),
        segment["utf16End"].as_u64().unwrap(),
    )
}

#[test]
fn source_spans_locate_korean_and_emoji_blocks_at_their_real_byte_and_utf16_offsets() {
    let source = "# 안녕 🎉\n\n둘째 문단입니다.\n";
    let nodes = nodes_of(source);

    let heading = &nodes_by_tag(&nodes, "heading")[0];
    let (h_utf8_start, h_utf8_end, h_utf16_start, h_utf16_end) = text_span(heading);
    let heading_line = "# 안녕 🎉"; // line 1, no trailing newline in the span
    assert_eq!(h_utf8_start, 0);
    assert_eq!(h_utf8_end, heading_line.len() as u64);
    assert_eq!(h_utf16_start, 0);
    assert_eq!(h_utf16_end, heading_line.encode_utf16().count() as u64);
    // ASCII-only assumptions would put the heading's end at its CHARACTER count (7: '#',' ','안',
    // '녕',' ','🎉' is 6 chars — even fewer) instead of its BYTE count; this pins the byte count.
    assert_eq!(h_utf8_end, 13, "\"# 안녕 🎉\" is 13 UTF-8 bytes: 1+1+3+3+1+4");
    assert_eq!(h_utf16_end, 7, "\"# 안녕 🎉\" is 7 UTF-16 code units: '#',' ','안','녕',' ' are one unit each, the emoji is a surrogate pair (2)");

    let paragraph = &nodes_by_tag(&nodes, "paragraph")[0];
    let (p_utf8_start, p_utf8_end, p_utf16_start, p_utf16_end) = text_span(paragraph);
    let prefix_bytes = heading_line.len() as u64 + 2; // '\n' + blank line's '\n'
    let paragraph_text = "둘째 문단입니다.";
    assert_eq!(p_utf8_start, prefix_bytes);
    assert_eq!(p_utf8_end, prefix_bytes + paragraph_text.len() as u64);
    let prefix_utf16 = heading_line.encode_utf16().count() as u64 + 2;
    assert_eq!(p_utf16_start, prefix_utf16);
    assert_eq!(p_utf16_end, prefix_utf16 + paragraph_text.encode_utf16().count() as u64);

    // Round trip: the source's own text_content is what the validator recomputed utf16Start/End
    // against (`validate.rs`'s `utf16_offset`), so a byte slice of the ORIGINAL source at
    // [utf8Start, utf8End) must equal the text the node actually holds.
    let text_run = &children_of(&nodes, node_id(paragraph))[0];
    assert_eq!(
        &source[p_utf8_start as usize..p_utf8_end as usize],
        text_run["data"]["text"].as_str().unwrap()
    );
}

#[test]
fn editing_one_paragraph_moves_only_that_nodes_span() {
    let before = nodes_of("first paragraph\n\nsecond paragraph\n");
    let after = nodes_of("first paragraph\n\nSECOND PARAGRAPH, EDITED\n");

    let (before_first, before_second) = (&nodes_by_tag(&before, "paragraph")[0], &nodes_by_tag(&before, "paragraph")[1]);
    let (after_first, after_second) = (&nodes_by_tag(&after, "paragraph")[0], &nodes_by_tag(&after, "paragraph")[1]);

    assert_eq!(text_span(before_first), text_span(after_first), "unedited paragraph's span must not move");
    assert_ne!(
        text_span(before_second),
        text_span(after_second),
        "the edited paragraph's own span must move to cover its new text"
    );
}

// ---------------------------------------------------------------------------------------------
// Round trip: encode -> decode -> encode is stable, and no node is emitted with an empty tag.
// ---------------------------------------------------------------------------------------------

#[test]
fn encode_decode_encode_is_stable_and_every_node_tag_is_non_empty() {
    let source = "# Title\n\nA paragraph with a\n\n> quote\n\n- one\n- two\n\n1. a\n2. b\n\n\
                  - [ ] todo\n- [x] done\n\n```rust\nfn f() {}\n```\n\n---\n\n\
                  | L | C | R |\n|:--|:-:|--:|\n| a | b | c |\n";
    let tree = produce(source.as_bytes(), "roundtrip.md").unwrap();
    let once = tree.encode_json().unwrap();
    let twice = ValidatedRenderTree::decode_json(&once).unwrap().encode_json().unwrap();
    assert_eq!(once, twice);

    for tag in tree.node_tags() {
        assert!(!tag.is_empty());
    }
    assert!(
        tree.node_tags().len() > 10,
        "expected the full fixture to produce a non-trivial node count, got {}",
        tree.node_tags().len()
    );
}

#[test]
fn invalid_utf8_bytes_are_rejected_rather_than_silently_replaced() {
    let invalid = [0x66u8, 0x6f, 0x6f, 0xff, 0xfe];
    let err = produce(&invalid, "bad.md").unwrap_err();
    assert_eq!(err, fastdoc_engine::render::markdown::MarkdownError::InvalidUtf8);
}
