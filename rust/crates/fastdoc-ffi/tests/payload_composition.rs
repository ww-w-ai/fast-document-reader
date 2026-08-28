//! P4 preliminary — what the payload is actually MADE of, before anything decides how to send it.
//!
//! P3 measured the cost of taking delivery (942.7 ms on the 편람, 905.5 ms of it `Decodable`) and
//! the size that cost is proportional to: 27,169,703 bytes for 3,207 blocks — 8.4 KB per block for
//! a text document. A number that large is a claim about CONTENT, and choosing a wire format
//! without reading it is choosing on the assumption that the bytes are irreducible.
//!
//! So this attributes every byte of the encoded tree to the key path it sits under, with array
//! indices collapsed (`ok.nodes[].data.spans[]`), and prints the heaviest paths. Sizes are
//! INCLUSIVE — a parent counts its children — so the output reads as a tree and the drop between
//! a path and its child is where that path's own overhead lives.
//!
//! What it can settle: if the weight is in repeated STYLE objects, interning them costs a field on
//! both sides and removes bytes from the serialize AND the decode, which is a far smaller change
//! than a new wire format. If the weight is in the text and geometry themselves, it does not.
//!
//!     FMD_PAYLOAD_COMPOSITION=<document> cargo test -p fastdoc-ffi --test payload_composition \
//!       --release -- --nocapture

use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::path::PathBuf;

fn resolve(path: &str) -> PathBuf {
    let p = PathBuf::from(path);
    if p.is_absolute() { return p; }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..").join(p)
}

/// Serialized length of `v`, and the same length credited to `path` and to every ancestor.
fn attribute(v: &serde_json::Value, path: &str, out: &mut BTreeMap<String, (usize, usize)>) -> usize {
    let size = match v {
        serde_json::Value::Object(map) => {
            let mut n = 2; // {}
            for (k, child) in map {
                let child_path = format!("{path}.{k}");
                n += k.len() + 3; // "k":
                n += attribute(child, &child_path, out);
            }
            n + map.len().saturating_sub(1) // commas
        }
        serde_json::Value::Array(items) => {
            let mut n = 2; // []
            let child_path = format!("{path}[]");
            for child in items {
                n += attribute(child, &child_path, out);
            }
            n + items.len().saturating_sub(1)
        }
        other => other.to_string().len(),
    };
    let entry = out.entry(path.to_string()).or_insert((0, 0));
    entry.0 += size;
    entry.1 += 1;
    size
}

/// Every value stored under `field`, anywhere in the tree, keyed by its own serialization.
fn collect_field(
    v: &serde_json::Value,
    field: &str,
    seen: &mut BTreeMap<String, usize>,
    occurrences: &mut usize,
    bytes: &mut usize,
) {
    match v {
        serde_json::Value::Object(map) => {
            for (k, child) in map {
                if k == field && !child.is_null() {
                    let text = child.to_string();
                    *bytes += text.len();
                    *occurrences += 1;
                    *seen.entry(text).or_insert(0) += 1;
                }
                collect_field(child, field, seen, occurrences, bytes);
            }
        }
        serde_json::Value::Array(items) => {
            for child in items {
                collect_field(child, field, seen, occurrences, bytes);
            }
        }
        _ => {}
    }
}

#[test]
fn what_the_payload_is_made_of() {
    let Ok(path) = std::env::var("FMD_PAYLOAD_COMPOSITION") else {
        eprintln!("skipped: set FMD_PAYLOAD_COMPOSITION to a document path");
        return;
    };
    let path = resolve(&path);
    let data = std::fs::read(&path).expect("readable document");
    let ext = CString::new(path.extension().unwrap().to_str().unwrap()).unwrap();
    // Which payload: the canonical TREE, or the schema-v4 export the HOST actually decodes.
    // They are different documents of different sizes, and a composition measured on one does not
    // transfer to the other — `FMD_PAYLOAD_COMPOSITION_TREE=1` asks for the tree explicitly.
    let want_tree = std::env::var("FMD_PAYLOAD_COMPOSITION_TREE").is_ok();
    let json = unsafe {
        if want_tree {
            fastdoc_engine_ffi::fastdoc_read_office_tree(data.as_ptr(), data.len(), ext.as_ptr())
        } else {
            fastdoc_engine_ffi::fastdoc_read_office_json(data.as_ptr(), data.len(), ext.as_ptr())
        }
    };
    assert!(!json.is_null(), "the engine refused {}", path.display());
    let owned = unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(json) };
    let total = owned.len();

    let value: serde_json::Value = serde_json::from_str(&owned).expect("tree is JSON");
    let mut by_path: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    attribute(&value, "", &mut by_path);

    let mut rows: Vec<(&String, &(usize, usize))> = by_path.iter().collect();
    rows.sort_by(|a, b| b.1 .0.cmp(&a.1 .0));
    println!("COMPOSITION {} [{}] total={total} bytes", path.display(), if want_tree { "tree" } else { "v4 export — what the host decodes" });
    for (p, (bytes, count)) in rows.iter().take(40) {
        let share = *bytes as f64 * 100.0 / total as f64;
        println!("  {share:5.1}%  {bytes:>11}  n={count:<7} {p}");
    }
    // How much of that weight is the SAME object written again. A document declares a handful of
    // paragraph looks and then repeats them once per node; if that is what the bytes are, the
    // repair is a table and an index, not a new encoding — and it takes bytes out of the engine's
    // serialize and the host's decode at the same time.
    for field in [
        // tree vocabulary
        "style", "directEdgeBorders", "pagination", "tabStops", "edgePadding",
        // schema-v4 vocabulary — the export the HOST decodes spells the same ideas differently,
        // and it is the one whose weight has to come down.
        "background_image", "data", "format", "edge_borders", "spans",
    ] {
        let mut seen: BTreeMap<String, usize> = BTreeMap::new();
        let mut occurrences = 0usize;
        let mut bytes = 0usize;
        collect_field(&value, field, &mut seen, &mut occurrences, &mut bytes);
        if occurrences == 0 { continue; }
        let distinct_bytes: usize = seen.keys().map(String::len).sum();
        println!(
            "  DEDUP {field:<20} {occurrences:>7} occurrences / {:>5} distinct — \
             {bytes:>10} bytes would become {distinct_bytes:>8} + {occurrences} indices",
            seen.len()
        );
    }
    // Vacuity guard: an empty tree would print a tidy nothing and read as "measured".
    assert!(total > 1000, "{} produced a {total}-byte tree", path.display());
}
