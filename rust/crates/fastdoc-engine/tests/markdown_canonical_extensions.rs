//! The markdown the canonical `RenderTree` producer (Windows/Linux host) carries beyond CommonMark+GFM:
//! the same dialect `markdown_package.rs` gives the macOS renderer, mapped onto the shared node and
//! run vocabulary. Each test reads the wire JSON, so a feature that parses but never reaches the
//! tree (invariant 41) fails here.

use fastdoc_engine::render::markdown::produce;
use serde_json::Value;

fn tree_of(markdown: &str) -> Value {
    let tree = produce(markdown.as_bytes(), "test.md").unwrap();
    serde_json::from_slice(&tree.encode_json().unwrap()).unwrap()
}

fn nodes_of(markdown: &str) -> Vec<Value> {
    tree_of(markdown)["nodes"].as_array().unwrap().clone()
}

fn by_tag<'a>(nodes: &'a [Value], tag: &str) -> Vec<&'a Value> {
    nodes.iter().filter(|n| n["type"] == tag).collect()
}

fn node<'a>(nodes: &'a [Value], id: u64) -> &'a Value {
    nodes.iter().find(|n| n["id"].as_u64() == Some(id)).unwrap()
}

fn kids<'a>(nodes: &'a [Value], n: &Value) -> Vec<&'a Value> {
    n["children"].as_array().unwrap().iter().map(|c| node(nodes, c.as_u64().unwrap())).collect()
}

/// The run whose text contains `needle`.
fn run<'a>(nodes: &'a [Value], needle: &str) -> &'a Value {
    by_tag(nodes, "textRun")
        .into_iter()
        .find(|r| r["data"]["text"].as_str().unwrap().contains(needle))
        .unwrap_or_else(|| panic!("no run containing {needle:?}"))
}

fn style<'a>(r: &'a Value) -> &'a Value {
    &r["data"]["style"]
}

fn all_text(nodes: &[Value]) -> String {
    by_tag(nodes, "textRun").iter().map(|r| r["data"]["text"].as_str().unwrap()).collect::<Vec<_>>().join("|")
}

// inline ---------------------------------------------------------------------------------------

#[test]
fn inline_html_tags_style_the_text_between_them() {
    let nodes = nodes_of(
        "a <u>under</u> <mark>hi</mark> H<sub>2</sub>O x<sup>3</sup> <kbd>Ctrl</kbd> <s>old</s> \
         <del>gone</del> <b>bold</b> <i>it</i> <span class=\"x\">plain</span> <ins>added</ins> \
         <a href=\"https://e.x\">site</a>\n",
    );
    assert_eq!(style(run(&nodes, "under"))["underline"], "single");
    assert_eq!(style(run(&nodes, "added"))["underline"], "single");
    assert!(style(run(&nodes, "hi"))["background"].is_object());
    assert_eq!(style(run(&nodes, "2"))["verticalPosition"], "subscript");
    assert_eq!(style(run(&nodes, "3"))["verticalPosition"], "superscript");
    assert_eq!(style(run(&nodes, "Ctrl"))["inlineCode"], true);
    assert_eq!(style(run(&nodes, "old"))["strike"], true);
    assert_eq!(style(run(&nodes, "gone"))["strike"], true);
    assert_eq!(style(run(&nodes, "bold"))["bold"], true);
    assert_eq!(style(run(&nodes, "it"))["italic"], true);
    assert_eq!(run(&nodes, "site")["data"]["link"], "https://e.x");
    // Unknown tag: text kept, no style, and the tag itself is never text.
    let plain = run(&nodes, "plain");
    assert_eq!(style(plain)["underline"], Value::Null);
    assert_eq!(style(plain)["verticalPosition"], "normal");
    assert!(!all_text(&nodes).contains('<'), "{}", all_text(&nodes));
    // The text after a close tag is unstyled again.
    assert_eq!(style(run(&nodes, "O"))["verticalPosition"], "normal");
}

#[test]
fn an_unclosed_tag_styles_to_the_end_of_its_paragraph_only() {
    let nodes = nodes_of("<u>never closed\n\nnext\n");
    assert_eq!(style(run(&nodes, "closed"))["underline"], "single");
    assert_eq!(style(run(&nodes, "next"))["underline"], Value::Null);
}

#[test]
fn html_br_is_a_line_break_including_in_a_table_cell() {
    let nodes = nodes_of("| a<br>b | c |\n|---|---|\n| 1 | 2 |\n");
    let cell = by_tag(&nodes, "tableCell")[0];
    let paragraph = kids(&nodes, cell)[0];
    let tags: Vec<&str> = kids(&nodes, paragraph).iter().map(|k| k["type"].as_str().unwrap()).collect();
    assert!(tags.contains(&"lineBreak"), "{tags:?}");
    let p = nodes_of("one<br/>two\n");
    assert_eq!(by_tag(&p, "lineBreak").len(), 1);
}

#[test]
fn markers_map_to_run_styles() {
    let nodes = nodes_of("x^2^ ==hot== ++new++ ||secret|| [[Page|Shown]] ~~gone~~ [[Bare]]\n");
    assert_eq!(style(run(&nodes, "2"))["verticalPosition"], "superscript");
    assert!(style(run(&nodes, "hot"))["background"].is_object());
    assert_eq!(style(run(&nodes, "new"))["underline"], "single");
    let secret = style(run(&nodes, "secret"));
    assert!(secret["background"].is_object() && secret["foreground"].is_object());
    assert_eq!(style(run(&nodes, "gone"))["strike"], true);
    let text = all_text(&nodes);
    for marker in ["^", "==", "++", "||", "[["] {
        assert!(!text.contains(marker), "{marker} shown: {text}");
    }
    assert!(text.contains("Shown") && text.contains("Bare") && !text.contains("Page"));
}

#[test]
fn excluded_extensions_keep_their_commonmark_meaning() {
    let nodes = nodes_of("__bold__ and ~struck~ and >greentext\n");
    assert_eq!(style(run(&nodes, "bold"))["underline"], Value::Null);
    assert_eq!(style(run(&nodes, "bold"))["bold"], true);
    assert!(all_text(&nodes).contains(">greentext"));
}

#[test]
fn cjk_friendly_emphasis_closes_after_punctuation() {
    let nodes = nodes_of("**「안녕」**입니다\n");
    assert!(!all_text(&nodes).contains("**"), "{}", all_text(&nodes));
    assert_eq!(style(run(&nodes, "안녕"))["bold"], true);
}

#[test]
fn task_items_relaxed_and_in_tables() {
    let nodes = nodes_of("- [x]  done\n- [ ]\tundone\n\n| t |\n|---|\n| [x] |\n");
    let items = by_tag(&nodes, "taskListItem");
    assert_eq!(items.len(), 2, "relaxed matching");
    assert_eq!(items[0]["data"]["checked"], true);
    assert_eq!(items[1]["data"]["checked"], false);
    assert!(all_text(&nodes).contains('\u{2611}') && !all_text(&nodes).contains("[x]"));
}

// footnotes, headings -------------------------------------------------------------------------

fn bookmark_target(tree: &Value, name: &str) -> Option<u64> {
    tree["annotations"]["bookmarks"]
        .as_array()?
        .iter()
        .find(|b| b["name"] == name)
        .map(|b| b["targetNodeId"].as_u64().unwrap())
}

#[test]
fn footnotes_link_a_reference_to_a_numbered_note_and_back() {
    let tree = tree_of("Claim[^a] and again[^a], plus[^b].\n\n[^a]: First note.\n[^b]: Second note.\n");
    let nodes = tree["nodes"].as_array().unwrap().clone();
    let text = all_text(&nodes);
    assert!(!text.contains("[^"), "{text}");
    // The reference: a superscript digit linking to its note.
    let reference = by_tag(&nodes, "textRun")
        .into_iter()
        .find(|r| r["data"]["link"] == "#fn:a")
        .expect("a reference run");
    assert_eq!(reference["data"]["text"], "1");
    assert_eq!(style(reference)["verticalPosition"], "superscript");
    // The notes section: a rule, then a list with the notes numbered.
    let list = by_tag(&nodes, "list").into_iter().last().unwrap();
    let items = kids(&nodes, list);
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["data"]["marker"], "1.");
    assert_eq!(items[1]["data"]["marker"], "2.");
    assert_eq!(bookmark_target(&tree, "fn:a"), items[0]["id"].as_u64());
    // The way back: an arrow run linking to the first reference's block.
    assert!(kids(&nodes, items[0]).iter().any(|k| k["data"]["link"] == "#fnref:a"));
    let first_ref_block = bookmark_target(&tree, "fnref:a").expect("fnref bookmark");
    assert_eq!(node(&nodes, first_ref_block)["type"], "paragraph");
    assert!(by_tag(&nodes, "thematicBreak").len() == 1);
    assert!(text.find("First note.").unwrap() < text.find("Second note.").unwrap());
}

#[test]
fn inline_footnotes_are_shown_as_a_note() {
    let nodes = nodes_of("Text^[an inline note] here.\n");
    let text = all_text(&nodes);
    assert!(text.contains("an inline note") && !text.contains("^["), "{text}");
}

#[test]
fn heading_attributes_are_hidden_and_the_id_is_a_bookmark() {
    let tree = tree_of("## Title {#my-id}\n\ntext\n");
    let nodes = tree["nodes"].as_array().unwrap().clone();
    assert_eq!(all_text(&nodes).split('|').next().unwrap().trim(), "Title");
    let heading = by_tag(&nodes, "heading")[0];
    assert_eq!(bookmark_target(&tree, "my-id"), heading["id"].as_u64());
}

#[test]
fn front_matter_is_hidden_but_a_leading_rule_is_not_front_matter() {
    let hidden = nodes_of("---\ntitle: secret\ntags: [a]\n---\n\nbody\n");
    assert!(!all_text(&hidden).contains("secret") && all_text(&hidden).contains("body"));
    let rule = nodes_of("---\nSome prose between two rules.\n---\n");
    assert!(all_text(&rule).contains("Some prose"), "{}", all_text(&rule));
}

// blocks ---------------------------------------------------------------------------------------

#[test]
fn alerts_are_quotes_that_name_their_kind_and_open_with_a_title() {
    for (marker, title, kind) in [
        ("NOTE", "Note", "note"),
        ("TIP", "Tip", "tip"),
        ("IMPORTANT", "Important", "important"),
        ("WARNING", "Warning", "warning"),
        ("CAUTION", "Caution", "caution"),
    ] {
        let nodes = nodes_of(&format!("> [!{marker}]\n> body text\n"));
        let quote = by_tag(&nodes, "blockQuote")[0];
        assert_eq!(quote["data"]["alert"], kind);
        let first = kids(&nodes, quote)[0];
        let title_run = kids(&nodes, first)[0];
        assert_eq!(title_run["data"]["text"], title);
        assert_eq!(style(title_run)["bold"], true);
        assert!(style(title_run)["foreground"].is_object());
        assert!(!all_text(&nodes).contains("[!"));
    }
    let plain = nodes_of("> ordinary\n");
    assert!(by_tag(&plain, "blockQuote")[0]["data"].get("alert").is_none(), "plain quote carries no alert key");
}

#[test]
fn a_custom_alert_title_replaces_the_default() {
    let nodes = nodes_of("> [!TIP] Pro tip\n> body\n");
    assert_eq!(by_tag(&nodes, "blockQuote")[0]["data"]["alert"], "tip");
    assert!(all_text(&nodes).starts_with("Pro tip"), "{}", all_text(&nodes));
}

#[test]
fn multiline_block_quotes_and_quotes_keep_their_blocks() {
    let nodes = nodes_of(">>>\nfirst\n\nsecond\n>>>\n");
    let quote = by_tag(&nodes, "blockQuote")[0];
    assert_eq!(kids(&nodes, quote).len(), 2);
    let q = nodes_of("> - one\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n\n> ```\n> code\n> ```\n");
    assert_eq!(by_tag(&q, "table").len(), 1);
    assert_eq!(by_tag(&q, "list").len(), 1);
    assert_eq!(by_tag(&q, "codeBlock").len(), 1);
}

#[test]
fn list_items_keep_block_children() {
    let nodes = nodes_of("- item\n\n  ```\n  code line\n  ```\n\n  > quoted\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n");
    let item = by_tag(&nodes, "listItem")[0];
    let tags: Vec<&str> = kids(&nodes, item).iter().map(|k| k["type"].as_str().unwrap()).collect();
    for want in ["codeBlock", "blockQuote", "table"] {
        assert!(tags.contains(&want), "{want} missing from {tags:?}");
    }
}

#[test]
fn description_lists_show_a_bold_term_and_hang_its_details() {
    let nodes = nodes_of("Apple\n: A red fruit\n: Also a company\n\nPear\n: Green\n");
    assert_eq!(style(run(&nodes, "Apple"))["bold"], true);
    assert_eq!(style(run(&nodes, "A red fruit"))["bold"], false);
    let details = by_tag(&nodes, "paragraph")
        .into_iter()
        .find(|p| p["data"]["style"]["headIndent"].is_number())
        .expect("a hung details paragraph");
    assert!(details["data"]["style"]["headIndent"].as_f64().unwrap() > 0.0);
    let text = all_text(&nodes);
    for word in ["Apple", "A red fruit", "Also a company", "Pear", "Green"] {
        assert!(text.contains(word), "{word}: {text}");
    }
}

#[test]
fn table_alignment_and_ordered_start_survive() {
    let nodes = nodes_of("| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n");
    let aligns: Vec<String> = by_tag(&nodes, "tableCell")
        .iter()
        .map(|c| kids(&nodes, c)[0]["data"]["style"]["alignment"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(&aligns[3..], ["left", "center", "right"]);
    let list = nodes_of("3. three\n4. four\n");
    assert_eq!(by_tag(&list, "list")[0]["data"]["numbering"]["startNumber"], 3);
}

#[test]
fn html_blocks_show_their_text_and_a_lone_img_is_an_image() {
    let nodes = nodes_of("<details>\n<summary>The title</summary>\n\nHidden body.\n\n</details>\n");
    let raw = by_tag(&nodes, "rawHtml")[0];
    assert_eq!(raw["data"]["block"], true);
    assert!(raw["data"]["source"].as_str().unwrap().contains("<summary>"), "source stays verbatim");
    let title = run(&nodes, "The title");
    assert_eq!(style(title)["bold"], true);
    assert!(!all_text(&nodes).contains('<'));
    assert!(all_text(&nodes).contains("Hidden body."));

    let comment = nodes_of("<!-- a comment -->\n\ntext\n");
    assert!(!all_text(&comment).contains("comment") && all_text(&comment).contains("text"));

    let table = nodes_of("<table>\n<tr><td>cell A</td><td>cell B</td></tr>\n</table>\n");
    assert!(all_text(&table).contains("cell A") && all_text(&table).contains("cell B"));

    let img = nodes_of("<img src=\"a.png\" alt=\"x\">\n");
    let raw = by_tag(&img, "rawHtml")[0];
    let child = kids(&img, raw)[0];
    assert_eq!(child["type"], "image");
    assert_eq!(child["data"]["altText"], "x");
}

#[test]
fn a_document_without_extensions_has_no_bookmarks_and_plain_quotes_serialize_empty() {
    let tree = tree_of("# Title\n\n> quote\n\ntext\n");
    assert!(tree["annotations"]["bookmarks"].as_array().unwrap().is_empty());
    let nodes = tree["nodes"].as_array().unwrap();
    assert_eq!(by_tag(nodes, "blockQuote")[0]["data"], serde_json::json!({}));
}

#[test]
fn the_whole_dialect_in_one_document_validates() {
    let doc = "---\ntitle: x\n---\n\n# Head {#h}\n\n\
a <u>u</u> <mark>m</mark> H<sub>2</sub>O <sup>s</sup> <kbd>k</kbd> <s>s</s><br>next\n\n\
x^2^ ==hot== ++new++ ||sp|| [[W]] note[^1] and^[inline]\n\n> [!TIP]\n> tip body\n\n\
> - q\n>\n> | a | b |\n> |:-|-:|\n> | 1 | 2 |\n\nTerm\n: Detail\n\n3. three\n\n\
<details>\n<summary>S</summary>\n\nB\n\n</details>\n\n- [x] done\n\n  nested para\n\n  - deeper\n\n[^1]: The note.\n";
    let tree = tree_of(doc);
    assert!(tree["nodes"].as_array().unwrap().len() > 40);
}
