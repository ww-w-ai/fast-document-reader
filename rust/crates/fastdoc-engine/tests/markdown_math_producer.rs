//! S3 pass C: `render::markdown::produce`'s source-scanned math layer (S3-05). Math is taken from
//! the RAW SOURCE before comrak ever parses it — invariant 12: `_`/`^` are markdown syntax and a
//! lone `=` line under a matrix reads as a setext heading, shredding the formula across several
//! nodes. `markdown_block_producer.rs`'s `source_spans_locate_korean_and_emoji_blocks_...` proved
//! the block-span contract on math-free input; this file proves scan-first survives the exact
//! shape that contract's own module doc names as the risk, and that adding math changes nothing
//! about a document's OTHER block spans.

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

// ---------------------------------------------------------------------------------------------
// The one-liner shape: `$$ x = 1 $$` alone on its own line.
// ---------------------------------------------------------------------------------------------

#[test]
fn a_oneliner_dollar_formula_reaches_a_formula_node_with_its_tex_intact() {
    let source = "Before.\n\n$$ x = 1 $$\n\nAfter.\n";
    let nodes = nodes_of(source);
    let formulas = nodes_by_tag(&nodes, "formula");
    assert_eq!(formulas.len(), 1, "expected exactly one formula node, got {nodes:?}");
    assert_eq!(formulas[0]["data"]["source"], "x = 1");
    assert_eq!(formulas[0]["data"]["display"], true);

    // The surrounding paragraphs still reach the tree untouched — the math layer claims only its
    // own span.
    let paragraphs = nodes_by_tag(&nodes, "paragraph");
    assert_eq!(paragraphs.len(), 2, "expected the before/after paragraphs, got {nodes:?}");
}

#[test]
fn an_unterminated_dollar_fence_stays_plain_text() {
    // `scanMathSpans`'s own rule: an opening `$$` with no closing line before EOF is never a
    // span — it stays plain text, matching `MarkdownRenderer.swift:466`'s `if i + 1 <
    // lineStarts.count`.
    let source = "$$\nnever closed\n";
    let nodes = nodes_of(source);
    assert!(
        nodes_by_tag(&nodes, "formula").is_empty(),
        "an unterminated $$ fence must not become a formula, got {nodes:?}"
    );
}

// ---------------------------------------------------------------------------------------------
// The acceptance test this unit is judged by: a multiline matrix containing a lone `=` line and
// `_`/`^`-shaped content — exactly what invariant 12 says a parse-first design shreds into a
// setext heading plus emphasis-mangled paragraphs. Scan-first must carry every byte of the tex.
// ---------------------------------------------------------------------------------------------

#[test]
fn a_multiline_matrix_that_parse_first_would_shred_survives_intact() {
    let matrix_lines = [
        r"\begin{pmatrix}",
        r"a_1 & b^2 \\",
        r"=",
        r"c_1 & d^2 \\",
        r"\end{pmatrix}",
    ];
    let source = format!("$$\n{}\n$$\n", matrix_lines.join("\n"));

    // Sanity check on the fixture itself, not the producer: this input really does contain the
    // three shapes invariant 12 names as parse-first's failure mode, so a passing test could not
    // be an accident of a fixture that was never actually dangerous.
    assert!(matrix_lines.iter().any(|l| l.trim() == "="), "fixture needs a lone '=' line");
    assert!(matrix_lines.iter().any(|l| l.contains('_')), "fixture needs a '_' character");
    assert!(matrix_lines.iter().any(|l| l.contains('^')), "fixture needs a '^' character");

    let nodes = nodes_of(&source);
    let formulas = nodes_by_tag(&nodes, "formula");
    assert_eq!(formulas.len(), 1, "expected exactly one formula node, got {nodes:?}");
    let expected_tex = matrix_lines.join("\n");
    assert_eq!(
        formulas[0]["data"]["source"].as_str().unwrap(),
        expected_tex,
        "every byte of the matrix tex must survive — parse-first would have split this across a \
         heading and several paragraphs instead"
    );
    assert_eq!(formulas[0]["data"]["display"], true);

    // Nothing else from the shredded interior leaks into the tree: comrak's own misparse would
    // have produced a `heading` (from the `=` line) — the map layer must have suppressed every
    // node comrak produced inside the span, not just the first.
    assert!(
        nodes_by_tag(&nodes, "heading").is_empty(),
        "a node from inside the math span must never surface as its own block, got {nodes:?}"
    );
}

// ---------------------------------------------------------------------------------------------
// S3-11's block-span contract is unaffected by math scanning: a normal paragraph elsewhere in the
// SAME document still gets an exact source span, proving `Ctx::math_hit` does not perturb
// `span_for` for nodes outside every scanned span.
// ---------------------------------------------------------------------------------------------

#[test]
fn block_source_spans_are_unaffected_by_a_math_span_elsewhere_in_the_document() {
    let source = "$$\nx = 1\n$$\n\nAn ordinary paragraph.\n";
    let nodes = nodes_of(source);
    let paragraphs = nodes_by_tag(&nodes, "paragraph");
    assert_eq!(paragraphs.len(), 1, "expected exactly the ordinary paragraph, got {nodes:?}");
    let segment = &paragraphs[0]["sourceSpans"][0]["segments"][0];
    assert_eq!(segment["kind"], "text");
    let utf8_start = segment["utf8Start"].as_u64().unwrap() as usize;
    let utf8_end = segment["utf8End"].as_u64().unwrap() as usize;
    assert_eq!(
        &source[utf8_start..utf8_end],
        "An ordinary paragraph.",
        "the paragraph's own span must still slice out exactly its own text"
    );
}
