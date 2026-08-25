//! S3 pass B: `render::markdown::produce`'s inline vocabulary and raw HTML (S3-04, S3-10). Same
//! wire-JSON inspection pattern `markdown_block_producer.rs` uses.

use fastdoc_engine::render::markdown::produce;
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

fn first_paragraph_runs(markdown: &str) -> Vec<Value> {
    let nodes = nodes_of(markdown);
    let paragraph = &nodes_by_tag(&nodes, "paragraph")[0];
    children_of(&nodes, node_id(paragraph)).into_iter().cloned().collect()
}

// ---------------------------------------------------------------------------------------------
// Each style flag stands ALONE — a bold test that also happened to leave italic true would prove
// nothing (S3-04's own acceptance wording).
// ---------------------------------------------------------------------------------------------

#[test]
fn strong_sets_bold_and_nothing_else() {
    let runs = first_paragraph_runs("**bold**\n");
    assert_eq!(runs.len(), 1, "expected exactly one run, got {runs:?}");
    let style = &runs[0]["data"]["style"];
    assert_eq!(runs[0]["data"]["text"], "bold");
    assert_eq!(style["bold"], true);
    assert_eq!(style["italic"], false);
    assert_eq!(style["strike"], false);
    assert_eq!(style["inlineCode"], false);
}

#[test]
fn emphasis_sets_italic_and_nothing_else() {
    let runs = first_paragraph_runs("_italic_\n");
    assert_eq!(runs.len(), 1, "expected exactly one run, got {runs:?}");
    let style = &runs[0]["data"]["style"];
    assert_eq!(runs[0]["data"]["text"], "italic");
    assert_eq!(style["italic"], true);
    assert_eq!(style["bold"], false);
    assert_eq!(style["strike"], false);
    assert_eq!(style["inlineCode"], false);
}

#[test]
fn inline_code_sets_inline_code_and_nothing_else() {
    let runs = first_paragraph_runs("`code`\n");
    assert_eq!(runs.len(), 1, "expected exactly one run, got {runs:?}");
    let style = &runs[0]["data"]["style"];
    assert_eq!(runs[0]["data"]["text"], "code");
    assert_eq!(style["inlineCode"], true);
    assert_eq!(style["bold"], false);
    assert_eq!(style["italic"], false);
    assert_eq!(style["strike"], false);
}

// GFM strikethrough is an extension comrak leaves OFF by default — invariant 41's exact failure
// (strikethrough and task checkboxes both shipped dead once because nothing turned an option on).
// A test that only checked the flag once enabled would not catch a regression that turned the
// extension back off; this one is written so it FAILS if `Options.extension.strikethrough` were
// ever left unset — the run's very shape (a single styled run, not two plain-text runs split
// around literal `~~`) depends on the extension being on.
#[test]
fn strikethrough_is_a_gfm_extension_and_must_be_explicitly_enabled() {
    let runs = first_paragraph_runs("~~struck~~\n");
    assert_eq!(
        runs.len(),
        1,
        "if the strikethrough extension were off, comrak would parse this as plain text — \
         probably still one run, but never carrying strike:true; got {runs:?}"
    );
    let style = &runs[0]["data"]["style"];
    assert_eq!(runs[0]["data"]["text"], "struck");
    assert_eq!(
        style["strike"], true,
        "strikethrough must be a set flag on the run, not silently dropped (invariant 41)"
    );
    assert_eq!(style["bold"], false);
    assert_eq!(style["italic"], false);
    assert_eq!(style["inlineCode"], false);
}

// ---------------------------------------------------------------------------------------------
// Nesting: bold+italic together stand on ONE run, not a tree of nodes (S3-04: "중첩을 노드로
// 만들지 마라").
// ---------------------------------------------------------------------------------------------

#[test]
fn bold_and_italic_nest_onto_a_single_run() {
    let runs = first_paragraph_runs("**_both_**\n");
    assert_eq!(
        runs.len(),
        1,
        "nested emphasis must merge onto one run-level style, not become nested nodes, got {runs:?}"
    );
    let style = &runs[0]["data"]["style"];
    assert_eq!(runs[0]["data"]["text"], "both");
    assert_eq!(style["bold"], true);
    assert_eq!(style["italic"], true);
    assert_eq!(style["strike"], false);
}

// ---------------------------------------------------------------------------------------------
// Links and autolinks: the destination survives on `textRun.link`.
// ---------------------------------------------------------------------------------------------

#[test]
fn link_carries_its_destination_url() {
    let runs = first_paragraph_runs("[text](https://example.com/path)\n");
    assert_eq!(runs.len(), 1, "expected exactly one run, got {runs:?}");
    assert_eq!(runs[0]["data"]["text"], "text");
    assert_eq!(runs[0]["data"]["link"], "https://example.com/path");
}

#[test]
fn autolink_carries_its_destination_url_too() {
    let runs = first_paragraph_runs("<https://example.com/auto>\n");
    assert_eq!(runs.len(), 1, "expected exactly one run, got {runs:?}");
    assert_eq!(runs[0]["data"]["text"], "https://example.com/auto");
    assert_eq!(runs[0]["data"]["link"], "https://example.com/auto");
}

#[test]
fn bare_url_gfm_autolink_carries_its_destination_url() {
    // GFM's OTHER autolink form — no angle brackets — needs `Options.extension.autolink`, a
    // second extension distinct from the angle-bracket form CommonMark itself already covers.
    let runs = first_paragraph_runs("See www.example.com for more.\n");
    let linked: Vec<&Value> = runs.iter().filter(|r| !r["data"]["link"].is_null()).collect();
    assert_eq!(linked.len(), 1, "expected exactly one linked run, got {runs:?}");
    assert!(
        linked[0]["data"]["link"].as_str().unwrap().contains("example.com"),
        "expected the bare URL to resolve to a link destination, got {linked:?}"
    );
}

// ---------------------------------------------------------------------------------------------
// Hard breaks become a dedicated `lineBreak` node; soft breaks do NOT (see `inline.rs`'s module
// doc for the `file:line` this decision matched — `MarkdownRenderer.swift:396-402`).
// ---------------------------------------------------------------------------------------------

#[test]
fn hard_break_is_its_own_line_break_node() {
    // Two trailing spaces before the newline force a hard break per CommonMark.
    let runs = first_paragraph_runs("first  \nsecond\n");
    assert_eq!(runs.len(), 3, "expected text, lineBreak, text — got {runs:?}");
    assert_eq!(runs[0]["type"], "textRun");
    assert_eq!(runs[0]["data"]["text"], "first");
    assert_eq!(runs[1]["type"], "lineBreak");
    assert_eq!(runs[1]["data"]["kind"], "hard");
    assert_eq!(runs[2]["type"], "textRun");
    assert_eq!(runs[2]["data"]["text"], "second");
}

#[test]
fn soft_break_is_a_space_inside_the_run_not_a_node() {
    // A plain source newline (no trailing spaces, no backslash) is a SOFT break.
    let runs = first_paragraph_runs("first\nsecond\n");
    assert_eq!(
        runs.len(),
        1,
        "a soft break must fold into the surrounding text run as a space, matching \
         MarkdownRenderer.swift:400-402's `case is SoftBreak` — not become a lineBreak node, \
         got {runs:?}"
    );
    assert_eq!(runs[0]["type"], "textRun");
    assert_eq!(runs[0]["data"]["text"], "first second");
}

// ---------------------------------------------------------------------------------------------
// Raw HTML: block and inline each reach `rawHtml`, with `block` set correctly and the source
// carried verbatim — S3-10, `MarkdownRenderer.swift:391` (InlineHTML) and `:543` (visitHTMLBlock).
// ---------------------------------------------------------------------------------------------

#[test]
fn inline_html_reaches_a_raw_html_node_with_block_false() {
    let nodes = nodes_of("before <br> after\n");
    let raw = nodes_by_tag(&nodes, "rawHtml");
    assert_eq!(raw.len(), 1, "expected exactly one rawHtml node, got {nodes:?}");
    assert_eq!(raw[0]["data"]["block"], false);
    assert_eq!(raw[0]["data"]["source"], "<br>");
}

#[test]
fn block_html_reaches_a_raw_html_node_with_block_true_and_verbatim_source() {
    let source = "<div class=\"note\">\n  <p>hello</p>\n</div>\n";
    let nodes = nodes_of(source);
    let raw = nodes_by_tag(&nodes, "rawHtml");
    assert_eq!(raw.len(), 1, "expected exactly one rawHtml node, got {nodes:?}");
    assert_eq!(raw[0]["data"]["block"], true);
    assert_eq!(
        raw[0]["data"]["source"], source,
        "block HTML must be carried verbatim, not parsed or escaped"
    );
}

#[test]
fn block_html_node_carries_a_source_span_like_any_other_block_node() {
    let nodes = nodes_of("<div>x</div>\n");
    let raw = &nodes_by_tag(&nodes, "rawHtml")[0];
    assert!(
        !raw["sourceSpans"].as_array().unwrap().is_empty(),
        "a block-level rawHtml node is block granularity and must carry a source span like every \
         other block node (S3-11), got {raw:?}"
    );
}

#[test]
fn inline_html_node_carries_no_source_span() {
    let nodes = nodes_of("before <br> after\n");
    let raw = &nodes_by_tag(&nodes, "rawHtml")[0];
    assert!(
        raw["sourceSpans"].as_array().unwrap().is_empty(),
        "inline nodes carry no source span in this schema (Design: block granularity only), \
         got {raw:?}"
    );
}

// ---------------------------------------------------------------------------------------------
// Regression: pass A's block-level fixtures, unchanged text expectations, still hold once every
// paragraph/heading/table-cell/list-item routes through the inline vocabulary instead of a flat
// plain-text collapse.
// ---------------------------------------------------------------------------------------------

#[test]
fn plain_paragraph_with_no_formatting_still_collapses_to_one_run() {
    let runs = first_paragraph_runs("A plain paragraph.\n");
    assert_eq!(runs.len(), 1, "expected exactly one run, got {runs:?}");
    assert_eq!(runs[0]["data"]["text"], "A plain paragraph.");
    assert!(runs[0]["data"]["link"].is_null());
}

#[test]
fn korean_and_emoji_text_survives_inline_mapping_unchanged() {
    let source = "# 안녕 🎉\n\n둘째 문단입니다.\n";
    let nodes = nodes_of(source);
    let heading = &nodes_by_tag(&nodes, "heading")[0];
    let heading_runs = children_of(&nodes, node_id(heading));
    assert_eq!(heading_runs.len(), 1);
    assert_eq!(heading_runs[0]["data"]["text"], "안녕 🎉");

    let paragraph = &nodes_by_tag(&nodes, "paragraph")[0];
    let paragraph_runs = children_of(&nodes, node_id(paragraph));
    assert_eq!(paragraph_runs.len(), 1);
    assert_eq!(paragraph_runs[0]["data"]["text"], "둘째 문단입니다.");
}

#[test]
fn table_cell_with_bold_text_still_carries_its_alignment_paragraph() {
    let markdown = "| L |\n|:--|\n| **bold** |\n";
    let nodes = nodes_of(markdown);
    let cells = nodes_by_tag(&nodes, "tableCell");
    // header cell + one body cell
    assert_eq!(cells.len(), 2, "expected header + body cell, got {nodes:?}");
    let body_cell = cells[1];
    let paragraph = &children_of(&nodes, node_id(body_cell))[0];
    assert_eq!(paragraph["type"], "paragraph");
    assert_eq!(paragraph["data"]["style"]["alignment"], "left");
    let run = &children_of(&nodes, node_id(paragraph))[0];
    assert_eq!(run["data"]["text"], "bold");
    assert_eq!(run["data"]["style"]["bold"], true);
}

#[test]
fn tight_list_item_with_a_link_still_collapses_straight_to_its_run() {
    let nodes = nodes_of("- [text](https://example.com)\n");
    let items = nodes_by_tag(&nodes, "listItem");
    assert_eq!(items.len(), 1);
    let children = children_of(&nodes, node_id(items[0]));
    assert_eq!(
        children.len(),
        1,
        "tight list item must still collapse straight to its run (no paragraph wrapper), \
         got {children:?}"
    );
    assert_eq!(children[0]["type"], "textRun");
    assert_eq!(children[0]["data"]["link"], "https://example.com");
}

#[test]
fn empty_paragraph_still_produces_one_empty_text_run() {
    // A one-line ATX heading with no text after the marker is the simplest way to reach an empty
    // inline sequence without comrak simply refusing to parse a block at all.
    let nodes = nodes_of("#\n");
    let headings = nodes_by_tag(&nodes, "heading");
    assert_eq!(headings.len(), 1, "expected exactly one heading, got {nodes:?}");
    let children = children_of(&nodes, node_id(headings[0]));
    assert_eq!(children.len(), 1, "expected exactly one (empty) run, got {children:?}");
    assert_eq!(children[0]["type"], "textRun");
    assert_eq!(children[0]["data"]["text"], "");
}
