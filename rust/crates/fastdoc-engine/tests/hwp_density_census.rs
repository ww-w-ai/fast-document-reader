use std::collections::BTreeMap;

use fastdoc_engine::render::office::hwp_reader::HwpReader;
use fastdoc_engine::render::office::office_block::{OfficeBlock, OfficeReadResult};
use serde_json::Value;
use swiftshim::Data;

fn add(map: &mut BTreeMap<String, usize>, key: impl Into<String>) {
    *map.entry(key.into()).or_default() += 1;
}

fn raw_blocks(value: &Value, counts: &mut BTreeMap<String, usize>, in_table: bool) {
    match value {
        Value::Object(object) => {
            if let Some(kind) = object.get("t").and_then(Value::as_str) {
                let empty = kind == "para"
                    && object
                        .get("spans")
                        .and_then(Value::as_array)
                        .is_none_or(|spans| {
                            spans.iter().all(|span| {
                                span.get("text")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .trim()
                                    .is_empty()
                            })
                        });
                add(counts, format!("raw/{kind}"));
                if empty {
                    add(counts, "raw/para-empty");
                    add(counts, if in_table { "raw/cell-para-empty" } else { "raw/body-para-empty" });
                    if !in_table {
                        for key in object.keys() {
                            add(counts, format!("raw/body-empty-key/{key}"));
                        }
                    }
                    for child_kind in ["table", "image", "shape", "equation"] {
                        let has_child = object.values().any(|child| contains_kind(child, child_kind));
                        if has_child {
                            add(counts, format!("raw/para-empty-with-{child_kind}"));
                        }
                    }
                }
            }
            let enters_table = in_table || object.get("t").and_then(Value::as_str) == Some("table");
            for child in object.values() {
                raw_blocks(child, counts, enters_table);
            }
        }
        Value::Array(items) => {
            for item in items {
                raw_blocks(item, counts, in_table);
            }
        }
        _ => {}
    }
}

fn contains_kind(value: &Value, wanted: &str) -> bool {
    match value {
        Value::Object(object) => {
            object.get("t").and_then(Value::as_str) == Some(wanted)
                || object.values().any(|child| contains_kind(child, wanted))
        }
        Value::Array(items) => items.iter().any(|item| contains_kind(item, wanted)),
        _ => false,
    }
}

fn live_blocks(blocks: &[OfficeBlock], counts: &mut BTreeMap<String, usize>, in_table: bool) {
    for block in blocks {
        match block {
            OfficeBlock::Paragraph { spans, .. } => {
                add(counts, "live/paragraph");
                if spans.iter().all(|span| span.text.trim().is_empty()) {
                    add(counts, "live/paragraph-empty");
                    add(counts, if in_table { "live/cell-paragraph-empty" } else { "live/body-paragraph-empty" });
                }
            }
            OfficeBlock::Heading { spans, .. } => {
                add(counts, "live/heading");
                if spans.iter().all(|span| span.text.trim().is_empty()) {
                    add(counts, "live/heading-empty");
                }
            }
            OfficeBlock::ListItem { spans, .. } => {
                add(counts, "live/list-item");
                if spans.iter().all(|span| span.text.trim().is_empty()) {
                    add(counts, "live/list-item-empty");
                }
            }
            OfficeBlock::Table { rows, .. } => {
                add(counts, "live/table");
                for row in rows {
                    for cell in row {
                        live_blocks(&cell.blocks, counts, true);
                    }
                }
            }
            OfficeBlock::Image { .. } => add(counts, "live/image"),
            OfficeBlock::UnsupportedGraphic { .. } => add(counts, "live/unsupported"),
            _ => add(counts, "live/other"),
        }
    }
}

fn count_true_key(value: &Value, key: &str) -> usize {
    match value {
        Value::Object(object) => {
            usize::from(object.get(key).and_then(Value::as_bool) == Some(true))
                + object
                    .values()
                    .map(|child| count_true_key(child, key))
                    .sum::<usize>()
        }
        Value::Array(items) => items.iter().map(|item| count_true_key(item, key)).sum(),
        _ => 0,
    }
}

#[test]
fn compare_raw_and_live_empty_block_counts() {
    let Some(path) = std::env::var_os("FMD_HWP_DENSITY_CENSUS") else {
        eprintln!("skipped: set FMD_HWP_DENSITY_CENSUS=<document>");
        return;
    };
    let data = Data(std::fs::read(path).expect("read census document"));
    let json = HwpReader::export_document_json(&data).expect("export raw HWP JSON");
    let raw: Value = serde_json::from_str(&json).expect("parse raw HWP JSON");
    let live: OfficeReadResult =
        HwpReader::read_before_host_font_substitution(&data).expect("map live HWP blocks");

    let mut counts = BTreeMap::new();
    raw_blocks(&raw, &mut counts, false);
    live_blocks(&live.blocks, &mut counts, false);
    println!(
        "HWP_DENSITY raw/hideEmptyLine-true={}",
        count_true_key(&raw, "hideEmptyLine")
    );
    for (key, value) in counts {
        println!("HWP_DENSITY {key}={value}");
    }
}
