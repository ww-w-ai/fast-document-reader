//! S3 pass C: fenced `mermaid` code -> `diagram` node (S3-05's second half). No source-scan is
//! needed here — a fenced block reaches comrak intact, so the language `blocks.rs` already
//! extracts for `codeBlock` is what decides the split.

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

#[test]
fn a_mermaid_fence_reaches_a_diagram_node_carrying_its_source_verbatim() {
    let source = "```mermaid\ngraph TD;\n  A-->B;\n```\n";
    let nodes = nodes_of(source);
    let diagrams = nodes_by_tag(&nodes, "diagram");
    assert_eq!(diagrams.len(), 1, "expected exactly one diagram node, got {nodes:?}");
    assert_eq!(diagrams[0]["data"]["language"], "mermaid");
    assert_eq!(diagrams[0]["data"]["source"], "graph TD;\n  A-->B;\n");
    assert_eq!(diagrams[0]["data"]["renderedResourceId"], Value::Null);
    assert!(
        nodes_by_tag(&nodes, "codeBlock").is_empty(),
        "a mermaid fence must not ALSO surface as a codeBlock, got {nodes:?}"
    );
}

#[test]
fn a_non_mermaid_fence_stays_a_code_block() {
    let source = "```rust\nfn main() {}\n```\n";
    let nodes = nodes_of(source);
    let code_blocks = nodes_by_tag(&nodes, "codeBlock");
    assert_eq!(code_blocks.len(), 1, "expected exactly one codeBlock node, got {nodes:?}");
    assert_eq!(code_blocks[0]["data"]["language"], "rust");
    assert_eq!(code_blocks[0]["data"]["text"], "fn main() {}\n");
    assert!(
        nodes_by_tag(&nodes, "diagram").is_empty(),
        "a non-mermaid fence must not become a diagram, got {nodes:?}"
    );
}
