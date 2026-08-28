//! Where the ENGINE's share of a document read goes.
//!
//! `OfficeTransportCostTests` (Swift) measured the two sides of one read and found the engine at
//! 919.9 ms against the host's 622.3 ms on the 편람. Everything this sprint has done since P2c has
//! been to the WIRE, and the wire is only the last of the engine's four stages — so before a second
//! wire change is designed, this says how much of that 919.9 ms a wire change can even reach.
//!
//! The four stages, in the order a read pays them:
//!
//!   1. read    — `read_office`: the format's own parser (rhwp / the zip readers) into `OfficeBlock`
//!   2. tree    — `ValidatedRenderTree::from_office`: the canonical tree, plus its validation
//!   3. project — `office_project::project`: tree back down to schema-v4 as a `serde_json::Map`
//!   4. (3 includes serialization: `project` returns a String)
//!
//! Stage 3 is the only one a wire format touches. If it is a small share, then no amount of pooling,
//! flattening or range-pulling reaches the target, and the target has to be met somewhere else — a
//! fact that costs one measurement to learn and a redesign to learn the hard way.
//!
//!     FMD_ENGINE_STAGE_COST=<document> cargo test -p fastdoc-ffi --test engine_stage_cost \
//!       --release -- --nocapture

use std::path::PathBuf;
use std::time::Instant;

use swiftshim::font_provider::{FaceId, FaceInfo, FontProvider};
use swiftshim::{NSFontDescriptorSymbolicTraits, NSFontWeight};

use fastdoc_engine::render::office::hwp_reader::HwpReader;
use fastdoc_engine::render::office::office_project;
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};

/// Present and consistent, never realistic — the same posture the other corpus probes take. This
/// measures where TIME goes, not which glyphs are chosen, and a read panics without a provider.
struct FakeFontProvider;

impl FontProvider for FakeFontProvider {
    fn face_named(&self, _name: &str) -> Option<FaceId> { Some(FaceId(1)) }
    fn resolve(&self, _descriptor: &swiftshim::color_font::NSFontDescriptor) -> Option<FaceId> {
        Some(FaceId(1))
    }
    fn system_face(&self, _weight: NSFontWeight, _monospaced: bool) -> FaceId { FaceId(1) }
    fn describe(&self, _face: FaceId) -> FaceInfo {
        FaceInfo {
            name: "Helvetica".to_string(),
            family: Some("Helvetica".to_string()),
            traits: NSFontDescriptorSymbolicTraits::empty(),
        }
    }
    fn covers(&self, _face: FaceId, _scalar: u32) -> bool { true }
    fn substitute(&self, _declared: FaceId, _scalar: u32) -> Option<FaceId> { None }
}

fn resolve(path: &str) -> PathBuf {
    let p = PathBuf::from(path);
    if p.is_absolute() { return p; }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..").join(p)
}

#[test]
fn what_each_stage_of_a_read_costs() {
    let Ok(path) = std::env::var("FMD_ENGINE_STAGE_COST") else {
        eprintln!("skipped: set FMD_ENGINE_STAGE_COST to a document path");
        return;
    };
    let path = resolve(&path);
    let bytes = std::fs::read(&path).expect("readable document");
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("?");

    // HWP only, deliberately: the dispatch that picks a reader lives in the FFI crate and is
    // private to it, and the document this probe exists to explain is an HWP. A docx/odt answer
    // would need the zip readers named here too, which is work to do when there is a question
    // about a docx — not before.
    assert!(
        ext == "hwp" || ext == "hwpx",
        "this probe reads HWP; {name} is .{ext}"
    );
    if !swiftshim::font_provider::is_installed() {
        swiftshim::font_provider::install(Box::new(FakeFontProvider));
    }
    let read_start = Instant::now();
    // `read_before_host_font_substitution`, NOT `read`: the FFI a host actually calls takes this
    // path and leaves substitution to AppKit (see that function's own doc). Timing `read` would
    // charge the engine for a pass production does not run here — the same mistake as measuring
    // `office_export::to_json`, which no real document reaches.
    let result = HwpReader::read_before_host_font_substitution(&swiftshim::Data(bytes.clone()))
        .expect("the engine reads this document");
    let read_ms = read_start.elapsed().as_secs_f64() * 1000.0;

    let format = DocumentFormat::Hwp;
    let tree_start = Instant::now();
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name: name,
        source_bytes: &bytes,
        result: &result,
        resources: std::collections::BTreeMap::new(),
    })
    .expect("the tree builds for this document");
    let tree_ms = tree_start.elapsed().as_secs_f64() * 1000.0;

    let project_start = Instant::now();
    let json = office_project::project(&tree).expect("the projection succeeds");
    let project_ms = project_start.elapsed().as_secs_f64() * 1000.0;

    // Stage 1 again, split: everything before our own code runs (rhwp's parse of the CFB binary
    // plus the JSON it emits) against the mapping walk that turns that JSON into `OfficeBlock`.
    // Only the second half is ours to change.
    let vendor_start = Instant::now();
    let vendor_json = HwpReader::export_document_json(&swiftshim::Data(bytes.clone()))
        .expect("rhwp parses this document");
    let vendor_ms = vendor_start.elapsed().as_secs_f64() * 1000.0;
    let vendor_bytes = vendor_json.len();
    let map_start = Instant::now();
    let _ = HwpReader::map_json(&vendor_json, None, &Default::default());
    let map_ms = map_start.elapsed().as_secs_f64() * 1000.0;

    // rhwp + mapping does not add up to `read`, and the difference is what a mapping run WITHOUT a
    // picture provider skips: a table fill's bytes are decoded during the walk so the cell knows
    // its size. `NSImage::fromData` decodes the WHOLE bitmap to learn two numbers, so this is
    // measured rather than assumed.
    let (_kept, retained) =
        HwpReader::read_retaining_parse(&swiftshim::Data(bytes.clone()), false)
            .expect("the parse stays open");
    let fills_start = Instant::now();
    let provider: Box<dyn Fn(i64) -> Option<swiftshim::Data>> = Box::new(move |bin_data_id: i64| {
        match retained.picture_for_id(&format!("hwpimg:{bin_data_id}")) {
            fastdoc_engine::render::office::hwp_reader::mapping::PictureBytes::Bytes(d) => Some(d),
            _ => None,
        }
    });
    let _ = HwpReader::map_json(&vendor_json, Some(provider), &Default::default());
    let fills_ms = fills_start.elapsed().as_secs_f64() * 1000.0;

    let total = read_ms + tree_ms + project_ms;
    println!(
        "STAGES {name}\n  \
         read     {read_ms:8.1} ms  {:5.1}%   the format's own parser into OfficeBlock\n  \
         tree     {tree_ms:8.1} ms  {:5.1}%   from_office + validation\n  \
         project  {project_ms:8.1} ms  {:5.1}%   tree -> schema-v4 JSON, INCLUDING serialization\n  \
         total    {total:8.1} ms          payload {} bytes\n  \
         ── read, split ──\n  \
         rhwp     {vendor_ms:8.1} ms          the vendored parser: CFB -> its own JSON ({vendor_bytes} bytes)\n  \
         mapping  {map_ms:8.1} ms          that JSON -> OfficeBlock, no picture provider\n  \
         + fills  {fills_ms:8.1} ms          the same mapping WITH one — the difference is bitmap decoding",
        read_ms * 100.0 / total,
        tree_ms * 100.0 / total,
        project_ms * 100.0 / total,
        json.len(),
    );
    // Vacuity guard: a document that produced nothing would print a tidy set of small numbers.
    assert!(json.len() > 1000, "{name} projected {} bytes", json.len());
}
