//! Prints the 바탕쪽 objects this engine builds for ONE real document, so a rendered defect can be
//! checked against the numbers behind it instead of against a screenshot. Ignored by default: it
//! needs a document this repo does not ship.
//!
//! ```text
//! FMD_MASTER_DUMP=<file.hwp> cargo test -p fastdoc-engine --test master_page_dump -- --ignored --nocapture
//! ```

use fastdoc_engine::render::office::hwp_reader::HwpReader;
use fastdoc_engine::render::office::office_block::OfficeMasterObjectContent;
use swiftshim::Data;

#[test]
#[ignore = "requires an external HWP document"]
fn dump_master_page_objects() {
    let path = std::env::var("FMD_MASTER_DUMP").ok().filter(|p| !p.is_empty())
        .expect("set FMD_MASTER_DUMP=<file.hwp>");
    let bytes = Data(std::fs::read(&path).expect("read document"));
    let result = HwpReader::read_before_host_font_substitution(&bytes)
        .expect("HwpReader::read_before_host_font_substitution");
    println!("PAGE content w={:?} h={:?}  margins top={:?} bottom={:?}",
        result.page_content_width, result.page_content_height,
        result.page_margin_top, result.page_margin_bottom);
    println!("headers: {}  footers: {}", result.headers.len(), result.footers.len());
    for (i, h) in result.headers.iter().enumerate() {
        println!("  header[{i}] section={:?} applies_to={:?} blocks={}", h.section, h.applies_to, h.blocks.len());
    }
    for (i, f) in result.footers.iter().enumerate() {
        println!("  footer[{i}] section={:?} applies_to={:?} blocks={}", f.section, f.applies_to, f.blocks.len());
    }
    println!("section_start_blocks: {:?}", result.section_start_blocks);
    println!("page_break_blocks: {} entries", result.page_break_blocks.len());
    println!("blocks: {}", result.blocks.len());
    println!("master pages: {}", result.master_pages.len());
    for (i, mp) in result.master_pages.iter().enumerate() {
        println!("[{i}] section={:?} applies_to={:?} objects={}", mp.section, mp.applies_to, mp.objects.len());
        for (j, o) in mp.objects.iter().enumerate() {
            let kind = match &o.content {
                OfficeMasterObjectContent::Image(_) => "image".to_string(),
                OfficeMasterObjectContent::Drawing(_) => "drawing".to_string(),
                OfficeMasterObjectContent::Vector(v) => format!("vector({} paths, size {:.1}x{:.1})",
                    v.paths.len(), v.size.width, v.size.height),
                OfficeMasterObjectContent::Text(b) => format!("text({} blocks)", b.len()),
            };
            println!("    ({j}) frame ({:.1},{:.1}) {:.1}x{:.1}  {kind}",
                o.frame.origin.x, o.frame.origin.y, o.frame.size.width, o.frame.size.height);
        }
    }
}
