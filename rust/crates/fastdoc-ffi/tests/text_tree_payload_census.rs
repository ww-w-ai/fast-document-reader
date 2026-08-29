//! What the markdown producer costs on the wire, before any host is built to decode it.
//!
//! The office port learned this the expensive way: the first wiring shipped a payload 77 MB wide
//! for a 10.7 MB document, and the P-series spent four phases getting it back. The markdown wiring
//! starts from the other end — measure the payload FIRST, write the ceiling down, and let a change
//! that widens it fall here rather than in a reader.
//!
//! Set `FMD_TEXT_PAYLOAD_CENSUS` to a colon-separated list of files to measure real documents;
//! with nothing set it measures a small built-in source so the numbers are never absent.

use std::ffi::{CStr, CString};
use std::time::Instant;

use fastdoc_engine_ffi::{fastdoc_read_text_tree, fastdoc_string_free};

/// The same work the export does, but with the three stages timed apart — parse, tree, encode.
/// A single "produce took N ms" cannot say whether the cost is comrak, the builder, or serde, and
/// those have completely different fixes.
fn decompose(name: &str, bytes: &[u8]) {
    use std::time::Instant;
    let source_name = "document.md";
    let t0 = Instant::now();
    let tree = match fastdoc_engine::render::markdown::produce(bytes, source_name) {
        Ok(tree) => tree,
        Err(error) => {
            println!("TEXTSTAGE name={name} produceFailed={error:?}");
            return;
        }
    };
    let produce_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let t1 = Instant::now();
    let json = tree.encode_json().expect("the tree must encode");
    let encode_ms = t1.elapsed().as_secs_f64() * 1000.0;
    println!(
        "TEXTSTAGE name={name} produceMs={produce_ms:.1} encodeJsonMs={encode_ms:.1} jsonBytes={}",
        json.len()
    );
}

fn measure(name: &str, bytes: &[u8], extension: &str) {
    let ext = CString::new(extension).unwrap();
    let started = Instant::now();
    let envelope = unsafe {
        let raw = fastdoc_read_text_tree(bytes.as_ptr(), bytes.len(), ext.as_ptr());
        assert!(!raw.is_null(), "{name}: the envelope could not be built at all");
        let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
        fastdoc_string_free(raw);
        text
    };
    let elapsed = started.elapsed().as_secs_f64() * 1000.0;
    assert!(
        envelope.contains("\"ok\""),
        "{name}: expected a readable document, got {}",
        &envelope[..envelope.len().min(200)]
    );
    if let Ok(dir) = std::env::var("FMD_TEXT_PAYLOAD_DUMP") {
        let _ = std::fs::write(format!("{dir}/{name}.envelope.json"), &envelope);
    }
    let ratio = envelope.len() as f64 / bytes.len().max(1) as f64;
    println!(
        "TEXTPAYLOAD name={name} ext={extension} sourceBytes={} envelopeBytes={} ratio={ratio:.1}x produceMs={elapsed:.1}",
        bytes.len(),
        envelope.len()
    );
}

#[test]
fn what_a_markdown_tree_costs_on_the_wire() {
    let built_in = "# Title\n\nA para with **bold** and `code`.\n\n- one\n- two\n";
    measure("built-in", built_in.as_bytes(), "md");

    let Ok(list) = std::env::var("FMD_TEXT_PAYLOAD_CENSUS") else { return };
    for path in list.split(':').filter(|p| !p.is_empty()) {
        let Ok(bytes) = std::fs::read(path) else {
            println!("TEXTPAYLOAD name={path} unreadable=1");
            continue;
        };
        let extension = std::path::Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("md");
        let name = std::path::Path::new(path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(path);
        measure(name, &bytes, extension);
        if extension == "md" {
            decompose(name, &bytes);
        }
    }
}
