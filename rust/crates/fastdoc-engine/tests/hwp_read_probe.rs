//! PROBE — which real HWP documents does the engine's own reader get through, and where does it stop?
use std::path::{Path, PathBuf};

#[test]
fn read_every_real_hwp_and_report_where_it_stops() {
    let dir = Path::new("/Users/taehyoungkim/Documents/DEV/ww-w-ai/fast-md-reader/testdocs");
    let (mut ok, mut bad) = (0, 0);
    for p in walk(dir) {
        let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
        if ext != "hwp" && ext != "hwpx" { continue; }
        let bytes = std::fs::read(&p).unwrap();
        let data = swiftshim::Data::fromBytes(bytes);
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        match std::panic::catch_unwind(|| {
            fastdoc_engine::render::office::hwp_reader::mapping::HwpReader::read(&data)
        }) {
            Ok(Ok(r)) => { ok += 1; eprintln!("OK    {name}  blocks={}", r.blocks.len()); }
            Ok(Err(e)) => { bad += 1; eprintln!("ERR   {name}  {e}"); }
            Err(panic) => {
                bad += 1;
                let msg = panic.downcast_ref::<String>().cloned()
                    .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                    .unwrap_or_else(|| "<non-string panic>".into());
                eprintln!("PANIC {name}  {msg}");
            }
        }
    }
    eprintln!("--- ok={ok} bad={bad}");
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() { out.extend(walk(&p)); } else { out.push(p); }
        }
    }
    out
}
