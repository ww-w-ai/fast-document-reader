//! S3-02: parity harness between the Rust markdown producer (`render::markdown::produce`, comrak
//! / cmark-gfm) and the shipping Swift renderer (`MarkdownRenderer.swift`, swift-markdown /
//! cmark-gfm). This sprint's acceptance is NOT "CommonMark compliance" — it is agreement with
//! the renderer already shipping. `Tests/FastDocReaderTests/MarkdownFeatureAuditTests.swift`
//! (the Swift side) is the one and only source of what "agreement" means, feature by feature;
//! this file re-runs each of its 20 assertions against the Rust producer's OWN vocabulary (a
//! wire node tree, not an `NSAttributedString`) and records, by name, whether the same input
//! yields the same semantic fact.
//!
//! ## Why per-feature, not a diff of two trees
//!
//! The two pipelines do not share a representation: Swift bakes presentation into a flat
//! attributed string (list markers, checkbox glyphs, hard-break newlines are literal characters);
//! Rust emits a structural node tree those glyphs are deliberately NOT baked into (`blocks.rs`'s
//! module doc: list numbering is a `Numbering` field, not rendered text — glyph generation is a
//! later, presentation-layer job). A byte/string diff of the two outputs would therefore report
//! false divergence on every list, task item and hard break even though the same fact — ordered
//! vs. unordered, checked vs. unchecked, "a break happened here" — is present in both, just in a
//! different vocabulary. So each `ParityCase` below states the Swift assertion PLUS a `check`
//! closure that looks for the Rust-native equivalent of that same fact. A closure that finds
//! nothing equivalent returns `Diverges` — a real content gap, not a formatting difference — and
//! that name must appear in `KNOWN_DIVERGENCES` below or the test fails.
//!
//! ## The one-line-per-feature contract
//!
//! `PARITY_CASES` is the single data table this file's rigor lives in: feature name, the exact
//! Swift assertion this echoes (`file:line`), the markdown input, and the check. Adding a feature
//! is one array entry. `KNOWN_DIVERGENCES` is a second, DELIBERATELY separate table: every name in
//! it must have `Diverges`, and every `Diverges` must have a name in it — so a new gap can never
//! slip in silently (must be named to pass) and a stale entry can never linger silently either
//! (an entry that stopped diverging fails the test until removed).

use fastdoc_engine::render::markdown::produce;
use serde_json::Value;

// ------------------------------------------------------------------------------------------
// Wire-JSON helpers — same pattern `markdown_block_producer.rs` / `markdown_inline_producer.rs`
// use. Duplicated rather than shared: this file must stand alone as the parity contract, not
// depend on another test file's shape staying stable underneath it.
// ------------------------------------------------------------------------------------------

fn nodes_of(markdown: &str) -> Vec<Value> {
    let tree = produce(markdown.as_bytes(), "parity.md").unwrap();
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

/// The first `textRun` anywhere in the tree whose text contains `needle` — feature checks below
/// only need "a run carrying this text exists with this style/link", not its position, since the
/// Swift assertions they echo make the same textual-substring check (`attr(s, .font, on: sub)`).
fn run_containing<'a>(nodes: &'a [Value], needle: &str) -> Option<&'a Value> {
    nodes_by_tag(nodes, "textRun")
        .into_iter()
        .find(|r| r["data"]["text"].as_str().is_some_and(|t| t.contains(needle)))
}

fn style_flag(run: &Value, flag: &str) -> bool {
    run["data"]["style"][flag].as_bool().unwrap_or(false)
}

// ------------------------------------------------------------------------------------------
// The parity table
// ------------------------------------------------------------------------------------------

enum ParityResult {
    Match(String),
    Diverges(String),
}

struct ParityCase {
    feature: &'static str,
    swift_assertion: &'static str,
    markdown: &'static str,
    check: fn(&[Value]) -> ParityResult,
}

/// Every gap this table is allowed to have, and why. Nothing else may diverge (see `test
/// no_undocumented_divergences` / `test no_stale_divergences` below, which enforce both
/// directions against `PARITY_CASES`).
const KNOWN_DIVERGENCES: &[&str] = &["footnote"];

const PARITY_CASES: &[ParityCase] = &[
    ParityCase {
        feature: "emphasis-italic",
        swift_assertion: "MarkdownFeatureAuditTests.swift:48 testEmphasisIsItalic — \
            font(render(\"a *em* b\"), on: \"em\") is italic",
        markdown: "a *em* b",
        check: |nodes| match run_containing(nodes, "em") {
            Some(r) if style_flag(r, "italic") && !style_flag(r, "bold") => {
                ParityResult::Match("textRun \"em\" carries style.italic=true".into())
            }
            Some(r) => ParityResult::Diverges(format!("run found but style={:?}", r["data"]["style"])),
            None => ParityResult::Diverges("no textRun contains \"em\"".into()),
        },
    },
    ParityCase {
        feature: "strong-bold",
        swift_assertion: "MarkdownFeatureAuditTests.swift:52 testStrongIsBold — \
            font(render(\"a **st** b\"), on: \"st\") is bold",
        markdown: "a **st** b",
        check: |nodes| match run_containing(nodes, "st") {
            Some(r) if style_flag(r, "bold") && !style_flag(r, "italic") => {
                ParityResult::Match("textRun \"st\" carries style.bold=true".into())
            }
            Some(r) => ParityResult::Diverges(format!("run found but style={:?}", r["data"]["style"])),
            None => ParityResult::Diverges("no textRun contains \"st\"".into()),
        },
    },
    ParityCase {
        feature: "nested-strong-emphasis",
        swift_assertion: "MarkdownFeatureAuditTests.swift:56 \
            testNestedStrongEmphasisIsBoldAndItalic — font(render(\"a ***both*** b\"), on: \
            \"both\") is bold AND italic",
        markdown: "a ***both*** b",
        check: |nodes| match run_containing(nodes, "both") {
            Some(r) if style_flag(r, "bold") && style_flag(r, "italic") => {
                ParityResult::Match("textRun \"both\" carries style.bold=true, italic=true".into())
            }
            Some(r) => ParityResult::Diverges(format!("run found but style={:?}", r["data"]["style"])),
            None => ParityResult::Diverges("no textRun contains \"both\"".into()),
        },
    },
    ParityCase {
        feature: "inline-code-monospace",
        swift_assertion: "MarkdownFeatureAuditTests.swift:61 testInlineCodeIsMonospace — \
            font(render(\"a `code` b\"), on: \"code\") is monospace",
        markdown: "a `code` b",
        check: |nodes| match run_containing(nodes, "code") {
            Some(r) if style_flag(r, "inlineCode") => {
                ParityResult::Match("textRun \"code\" carries style.inlineCode=true".into())
            }
            Some(r) => ParityResult::Diverges(format!("run found but style={:?}", r["data"]["style"])),
            None => ParityResult::Diverges("no textRun contains \"code\"".into()),
        },
    },
    ParityCase {
        feature: "strikethrough",
        swift_assertion: "MarkdownFeatureAuditTests.swift:65 testStrikethroughIsStruckThrough — \
            strikethroughStyle attribute on \"gone\" in render(\"a ~~gone~~ b\") is non-zero",
        markdown: "a ~~gone~~ b",
        check: |nodes| match run_containing(nodes, "gone") {
            Some(r) if style_flag(r, "strike") => {
                ParityResult::Match("textRun \"gone\" carries style.strike=true".into())
            }
            Some(r) => ParityResult::Diverges(format!("run found but style={:?}", r["data"]["style"])),
            None => ParityResult::Diverges("no textRun contains \"gone\"".into()),
        },
    },
    ParityCase {
        feature: "markdown-link",
        swift_assertion: "MarkdownFeatureAuditTests.swift:72 testMarkdownLinkIsLinked — \
            .link attribute on \"site\" in render(\"see [site](https://ww-w.ai) now\") is set",
        markdown: "see [site](https://ww-w.ai) now",
        check: |nodes| match run_containing(nodes, "site") {
            Some(r) if r["data"]["link"].as_str() == Some("https://ww-w.ai") => {
                ParityResult::Match("textRun \"site\" carries link=\"https://ww-w.ai\"".into())
            }
            Some(r) => ParityResult::Diverges(format!("run found but link={:?}", r["data"]["link"])),
            None => ParityResult::Diverges("no textRun contains \"site\"".into()),
        },
    },
    ParityCase {
        feature: "bare-url-autolink",
        swift_assertion: "MarkdownFeatureAuditTests.swift:76 testBareURLIsAutolinked — \
            .link attribute on the bare URL in render(\"visit https://ww-w.ai today\") is set",
        markdown: "visit https://ww-w.ai today",
        check: |nodes| match run_containing(nodes, "ww-w.ai") {
            Some(r) if r["data"]["link"].as_str() == Some("https://ww-w.ai") => {
                ParityResult::Match(
                    "textRun \"https://ww-w.ai\" carries link=\"https://ww-w.ai\" via GFM \
                     Options.extension.autolink"
                        .into(),
                )
            }
            Some(r) => ParityResult::Diverges(format!("run found but link={:?}", r["data"]["link"])),
            None => ParityResult::Diverges("no textRun contains \"ww-w.ai\"".into()),
        },
    },
    ParityCase {
        feature: "angle-autolink",
        swift_assertion: "MarkdownFeatureAuditTests.swift:80 testAngleAutolinkIsLinked — \
            .link attribute on the URL in render(\"mail <https://ww-w.ai> here\") is set",
        markdown: "mail <https://ww-w.ai> here",
        check: |nodes| match run_containing(nodes, "ww-w.ai") {
            Some(r) if r["data"]["link"].as_str() == Some("https://ww-w.ai") => {
                ParityResult::Match("textRun \"https://ww-w.ai\" carries link=\"https://ww-w.ai\"".into())
            }
            Some(r) => ParityResult::Diverges(format!("run found but link={:?}", r["data"]["link"])),
            None => ParityResult::Diverges("no textRun contains \"ww-w.ai\"".into()),
        },
    },
    ParityCase {
        feature: "image",
        swift_assertion: "MarkdownFeatureAuditTests.swift:84 testImageProducesImageAttr — \
            MDAttr.image is present somewhere in render(\"![alt](pic.png)\")",
        markdown: "![alt](pic.png)",
        check: |nodes| {
            if nodes_by_tag(nodes, "image").is_empty() {
                ParityResult::Diverges(
                    "no \"image\" node in the tree — inline.rs's Builder::walk intercepts \
                     NodeValue::Image before Kind::Other's catch-all runs, so a missing node here \
                     would be a real regression, not an unimplemented feature (S3-06)"
                        .into(),
                )
            } else {
                ParityResult::Match("image node present".into())
            }
        },
    },
    ParityCase {
        feature: "heading",
        swift_assertion: "MarkdownFeatureAuditTests.swift:90 testHeadingTagged — \
            MDAttr.heading present somewhere in render(\"# Title\")",
        markdown: "# Title",
        check: |nodes| {
            let headings = nodes_by_tag(nodes, "heading");
            if headings.len() == 1 && headings[0]["data"]["level"] == 1 {
                ParityResult::Match("heading node, level=1".into())
            } else {
                ParityResult::Diverges(format!("headings found: {headings:?}"))
            }
        },
    },
    ParityCase {
        feature: "setext-heading",
        swift_assertion: "MarkdownFeatureAuditTests.swift:94 testSetextHeadingTagged — \
            MDAttr.heading present in render(\"Title\\n=====\\n\\nbody\")",
        markdown: "Title\n=====\n\nbody\n",
        check: |nodes| {
            let headings = nodes_by_tag(nodes, "heading");
            if headings.len() == 1 && headings[0]["data"]["level"] == 1 {
                ParityResult::Match("setext (===) heading node, level=1".into())
            } else {
                ParityResult::Diverges(format!("headings found: {headings:?}"))
            }
        },
    },
    ParityCase {
        feature: "blockquote",
        swift_assertion: "MarkdownFeatureAuditTests.swift:98 testBlockquoteTagged — \
            MDAttr.blockQuote present in render(\"> quoted\")",
        markdown: "> quoted",
        check: |nodes| {
            if nodes_by_tag(nodes, "blockQuote").len() == 1 {
                ParityResult::Match("blockQuote node present".into())
            } else {
                ParityResult::Diverges(format!("blockQuote nodes: {:?}", nodes_by_tag(nodes, "blockQuote")))
            }
        },
    },
    ParityCase {
        feature: "code-block",
        swift_assertion: "MarkdownFeatureAuditTests.swift:102 testCodeBlockTagged — \
            MDAttr.codeBlock present in render(\"```\\ncode\\n```\")",
        markdown: "```\ncode\n```\n",
        check: |nodes| {
            let blocks = nodes_by_tag(nodes, "codeBlock");
            if blocks.len() == 1 && blocks[0]["data"]["text"] == "code\n" {
                ParityResult::Match("codeBlock node, text=\"code\\n\"".into())
            } else {
                ParityResult::Diverges(format!("codeBlock nodes: {blocks:?}"))
            }
        },
    },
    ParityCase {
        feature: "thematic-break",
        swift_assertion: "MarkdownFeatureAuditTests.swift:106 testThematicBreakTagged — \
            MDAttr.rule present in render(\"a\\n\\n---\\n\\nb\")",
        markdown: "a\n\n---\n\nb\n",
        check: |nodes| {
            if nodes_by_tag(nodes, "thematicBreak").len() == 1 {
                ParityResult::Match("thematicBreak node present".into())
            } else {
                ParityResult::Diverges(format!(
                    "thematicBreak nodes: {:?}",
                    nodes_by_tag(nodes, "thematicBreak")
                ))
            }
        },
    },
    ParityCase {
        // Swift asserts the RENDERED marker glyph ("1.") is literal text in the attributed
        // string. The wire tree does not bake that glyph — `blocks.rs`'s module doc: marker
        // rendering is a presentation-layer job this producer does not own. The equivalent fact
        // in Rust's own vocabulary is structural: two listItem nodes, both ordered=true, with a
        // Numbering carrying start_number — checked here instead of the "1." substring.
        feature: "ordered-list-marker",
        swift_assertion: "MarkdownFeatureAuditTests.swift:110 testOrderedListMarker — \
            render(\"1. one\\n2. two\").string contains \"1.\" (baked marker glyph)",
        markdown: "1. one\n2. two",
        check: |nodes| {
            let lists = nodes_by_tag(nodes, "list");
            let items = if lists.len() == 1 { children_of(nodes, node_id(lists[0])) } else { vec![] };
            let ok = lists.len() == 1
                && items.len() == 2
                && items.iter().all(|i| i["data"]["ordered"] == true)
                && lists[0]["data"]["numbering"]["startNumber"] == 1;
            if ok {
                ParityResult::Match(
                    "list node with 2 listItem children, ordered=true, numbering.startNumber=1 \
                     (structural equivalent of the baked \"1.\"/\"2.\" glyphs — see comment)"
                        .into(),
                )
            } else {
                ParityResult::Diverges(format!("list={:?} items={items:?}", lists.first()))
            }
        },
    },
    ParityCase {
        // Same reasoning as ordered-list-marker: Swift bakes "•", Rust represents ordered=false
        // structurally.
        feature: "unordered-list-marker",
        swift_assertion: "MarkdownFeatureAuditTests.swift:114 testUnorderedListMarker — \
            render(\"- one\\n- two\").string contains \"•\" (baked marker glyph)",
        markdown: "- one\n- two",
        check: |nodes| {
            let lists = nodes_by_tag(nodes, "list");
            let items = if lists.len() == 1 { children_of(nodes, node_id(lists[0])) } else { vec![] };
            let ok = lists.len() == 1 && items.len() == 2 && items.iter().all(|i| i["data"]["ordered"] == false);
            if ok {
                ParityResult::Match(
                    "list node with 2 listItem children, ordered=false (structural equivalent \
                     of the baked \"•\" glyph — see comment)"
                        .into(),
                )
            } else {
                ParityResult::Diverges(format!("list={:?} items={items:?}", lists.first()))
            }
        },
    },
    ParityCase {
        // Same reasoning: Swift bakes "☐"/"☑", Rust represents checked:bool structurally.
        feature: "task-list-checkboxes",
        swift_assertion: "MarkdownFeatureAuditTests.swift:118 testTaskListShowsCheckboxes — \
            render(\"- [ ] todo\\n- [x] done\").string contains \"☐\" and \"☑\" (baked glyphs)",
        markdown: "- [ ] todo\n- [x] done",
        check: |nodes| {
            let items = nodes_by_tag(nodes, "taskListItem");
            let ok = items.len() == 2
                && items.iter().any(|i| i["data"]["checked"] == false)
                && items.iter().any(|i| i["data"]["checked"] == true);
            if ok {
                ParityResult::Match(
                    "2 taskListItem nodes, one checked=false one checked=true (structural \
                     equivalent of the baked ☐/☑ glyphs — see comment)"
                        .into(),
                )
            } else {
                ParityResult::Diverges(format!("taskListItem nodes: {items:?}"))
            }
        },
    },
    ParityCase {
        feature: "table",
        swift_assertion: "MarkdownFeatureAuditTests.swift:125 testTableRendersAsRealTextTable — \
            render(\"| A | B |\\n|---|---|\\n| 1 | 2 |\") has a real NSTextTable and cell text \
            \"A\"/\"2\" is real document text",
        markdown: "| A | B |\n|---|---|\n| 1 | 2 |\n",
        check: |nodes| {
            let tables = nodes_by_tag(nodes, "table");
            let has_a = run_containing(nodes, "A").is_some();
            let has_2 = run_containing(nodes, "2").is_some();
            if tables.len() == 1 && has_a && has_2 {
                ParityResult::Match(
                    "table node present; cell text \"A\" and \"2\" survive as real textRun nodes".into(),
                )
            } else {
                ParityResult::Diverges(format!("tables={tables:?} has_a={has_a} has_2={has_2}"))
            }
        },
    },
    ParityCase {
        // Swift bakes the hard break as a literal "\n" inside one paragraph's string. Rust
        // represents it as a dedicated `lineBreak` node between two textRuns (documented in
        // inline.rs's module doc, and already unit-tested by
        // markdown_inline_producer.rs::hard_break_is_its_own_line_break_node) — the structural
        // equivalent checked here instead of a baked "\n" substring.
        feature: "hard-line-break",
        swift_assertion: "MarkdownFeatureAuditTests.swift:134 \
            testHardLineBreakStaysInParagraph — render(\"line one  \\nline two\").string \
            contains \"line one\\nline two\" (baked newline, one paragraph)",
        markdown: "line one  \nline two\n",
        check: |nodes| {
            let paragraphs = nodes_by_tag(nodes, "paragraph");
            if paragraphs.len() != 1 {
                return ParityResult::Diverges(format!("expected 1 paragraph, got {paragraphs:?}"));
            }
            let kids = children_of(nodes, node_id(paragraphs[0]));
            let ok = kids.len() == 3
                && kids[0]["type"] == "textRun"
                && kids[0]["data"]["text"] == "line one"
                && kids[1]["type"] == "lineBreak"
                && kids[1]["data"]["kind"] == "hard"
                && kids[2]["type"] == "textRun"
                && kids[2]["data"]["text"] == "line two";
            if ok {
                ParityResult::Match(
                    "one paragraph: textRun(\"line one\"), lineBreak(kind=hard), \
                     textRun(\"line two\") — structural equivalent of the baked newline"
                        .into(),
                )
            } else {
                ParityResult::Diverges(format!("paragraph children: {kids:?}"))
            }
        },
    },
    ParityCase {
        feature: "footnote",
        swift_assertion: "MarkdownFeatureAuditTests.swift:149 \
            testFootnotesAreNotYetRenderedButContentSurvives — render(\"Body.[^1]\\n\\n[^1]: \
            The note.\").string contains the literal \"[^1]\" marker AND \"The note.\" \
            (characterizes non-support: content preserved, not parsed as a footnote)",
        markdown: "Body.[^1]\n\n[^1]: The note.\n",
        check: |nodes| {
            // The Swift side does not support footnotes either (swift-markdown does not parse
            // `[^id]`) — its own test name says so. This producer ALSO leaves
            // `Options.extension.footnotes` unset, so on the surface the two SHOULD agree. But a
            // `footnote` wire node tag exists in the schema (owned by a later pass, S3-05/-06)
            // and this producer emits none — recorded as a known divergence (not "both parse it
            // the same way", but "Rust does not yet have a footnote node kind to compare against
            // at all") rather than silently declared a match on text-preservation alone.
            let has_footnote_node = !nodes_by_tag(nodes, "footnote").is_empty();
            let marker_survives = run_containing(nodes, "[^1]").is_some();
            let note_survives = run_containing(nodes, "The note.").is_some();
            if has_footnote_node {
                ParityResult::Match("footnote node present (would mean footnotes are now parsed)".into())
            } else if marker_survives && note_survives {
                ParityResult::Diverges(
                    "no footnote node kind produced; marker \"[^1]\" and \"The note.\" survive \
                     only as literal paragraph text, same characterization as the Swift side — \
                     footnote mapping is out of this pass's scope (S3-05/S3-06)"
                        .into(),
                )
            } else {
                ParityResult::Diverges(format!(
                    "content dropped: marker_survives={marker_survives} note_survives={note_survives}"
                ))
            }
        },
    },
];

// ------------------------------------------------------------------------------------------
// The parity test itself, plus the two guards that keep KNOWN_DIVERGENCES honest in both
// directions.
// ------------------------------------------------------------------------------------------

fn run_all() -> Vec<(&'static str, ParityResult)> {
    PARITY_CASES
        .iter()
        .map(|case| {
            let nodes = nodes_of(case.markdown);
            (case.feature, (case.check)(&nodes))
        })
        .collect()
}

#[test]
fn every_feature_either_matches_or_is_a_named_known_divergence() {
    let results = run_all();
    let mut unexpected_divergences = Vec::new();
    for (feature, result) in &results {
        if let ParityResult::Diverges(reason) = result {
            if !KNOWN_DIVERGENCES.contains(feature) {
                unexpected_divergences.push(format!("{feature}: {reason}"));
            }
        }
    }
    assert!(
        unexpected_divergences.is_empty(),
        "new, undocumented divergence(s) from the Swift renderer — name each one in \
         KNOWN_DIVERGENCES if it is an accepted gap, or fix the producer if it is a regression:\n{}",
        unexpected_divergences.join("\n")
    );
}

#[test]
fn known_divergences_list_has_no_stale_entries() {
    // The mirror check: an entry that stopped diverging (the producer now matches) must be
    // deleted from KNOWN_DIVERGENCES — otherwise the list only ever grows and a real fix goes
    // unnoticed. Fails loudly by name so removing the stale line is a one-line fix.
    let results = run_all();
    let mut stale = Vec::new();
    for (feature, result) in &results {
        if matches!(result, ParityResult::Match(_)) && KNOWN_DIVERGENCES.contains(feature) {
            stale.push(*feature);
        }
    }
    assert!(
        stale.is_empty(),
        "KNOWN_DIVERGENCES contains feature(s) that now MATCH — remove the stale entry: {stale:?}"
    );
}

#[test]
fn every_parity_case_result_is_printed_by_feature_name() {
    // Not a pass/fail gate on its own (the two tests above are) — this is the human-readable
    // table the sprint report's evidence file quotes verbatim: feature | match-or-diverge |
    // reason, one line each, never a bare ratio.
    let results = run_all();
    for case in PARITY_CASES {
        println!("--- {} ({})", case.feature, case.swift_assertion);
    }
    for (feature, result) in &results {
        match result {
            ParityResult::Match(reason) => println!("[MATCH]    {feature}: {reason}"),
            ParityResult::Diverges(reason) => println!("[DIVERGES] {feature}: {reason}"),
        }
    }
    assert_eq!(results.len(), 20, "expected all 20 audited features present, got {}", results.len());
}
