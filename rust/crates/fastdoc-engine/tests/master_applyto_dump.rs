//! What a real HWP's 바탕쪽 and running heads declare for `applyTo` — the raw value
//! `map_header_footer_apply_to` folds into two cases. Ignored by default: needs a document this
//! repo does not ship.
//!
//! ```text
//! FMD_APPLYTO_DUMP=<file.hwp> cargo test -p fastdoc-engine --test master_applyto_dump -- --ignored --nocapture
//! ```

use fastdoc_engine::render::office::hwp_reader::HwpReader;
use swiftshim::Data;

#[test]
#[ignore = "requires an external HWP document"]
fn dump_raw_apply_to() {
    let path = std::env::var("FMD_APPLYTO_DUMP").ok().filter(|p| !p.is_empty())
        .expect("set FMD_APPLYTO_DUMP=<file.hwp>");
    let bytes = Data(std::fs::read(&path).expect("read document"));
    let json = HwpReader::export_document_json(&bytes).expect("rhwp document json");
    let v: serde_json::Value = serde_json::from_str(&json).expect("parse envelope");
    for key in ["masterPages", "headers", "footers"] {
        match v.get(key).and_then(|x| x.as_array()) {
            Some(list) => {
                println!("APPLYTO {key}: {} entries", list.len());
                for (i, e) in list.iter().enumerate() {
                    println!("APPLYTO   [{i}] section={} applyTo={}",
                        e.get("section").map(|x| x.to_string()).unwrap_or_else(|| "-".into()),
                        e.get("applyTo").map(|x| x.to_string()).unwrap_or_else(|| "-".into()));
                }
            }
            None => println!("APPLYTO {key}: absent"),
        }
    }
}
