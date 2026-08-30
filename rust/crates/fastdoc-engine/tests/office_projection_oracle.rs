//! S4 Pass A — the equality oracle between the reader's own `to_json` and the tree's own
//! `project`, and the instrument tests that prove the oracle itself measures what it claims to.
//!
//! `office_export::to_json(&OfficeReadResult)` is read here, never written to — the untouched
//! half of the comparison. `office_project::project(&ValidatedRenderTree)` is the other half; its
//! own signature never mentions `OfficeReadResult` (see that module's doc), so nothing in THIS
//! file can smuggle the reader's answer into the projector either — both sides of every
//! comparison below are built from the SAME `OfficeReadResult`, independently, through two
//! functions this crate keeps physically incapable of consulting each other.

use fastdoc_engine::render::office::hwp_reader::HwpReader;
use fastdoc_engine::render::office::office_block::{
    Cell, HeaderFooterApplicability, OfficeBlock, OfficeHeaderFooter, OfficePageNumberRestart,
    OfficeReadResult, ParagraphFormat, Span, TableFormat,
};
use fastdoc_engine::render::office::office_export::to_json;
use fastdoc_engine::render::office::office_project::project;
use fastdoc_engine::render::render_tree::{DocumentFormat, OfficeAdapterInput, ValidatedRenderTree};
use swiftshim::{CGSize, Data, NSColor, NSEdgeInsets};

use std::collections::BTreeMap;
use std::path::PathBuf;

// -------------------------------------------------------------------------------------------
// The comparator itself: canonical `serde_json::Value` equality (this crate's `Cargo.toml`
// carries no `preserve_order` feature, so `Value::Object` is key-sorted internally — see
// `office_block.rs:2037-2063`'s own `map_eq` for why that matters at the `OfficeReadResult`
// level too), plus a JSON-pointer path reporter for when it disagrees.
// -------------------------------------------------------------------------------------------

/// Every path, in JSON-pointer form (`/blocks/7/spans/2/fontSize`), where `a` and `b` differ.
/// Empty means canonically equal. Walks objects by key (order-independent — a `Value::Object` is
/// already a `BTreeMap`) and arrays by index (order-DEPENDENT, deliberately: a reordered array is
/// a real difference this walk must report, not paper over).
fn json_pointer_diffs(a: &serde_json::Value, b: &serde_json::Value, path: &str, out: &mut Vec<String>) {
    use serde_json::Value;
    match (a, b) {
        (Value::Object(oa), Value::Object(ob)) => {
            let mut keys: Vec<&String> = oa.keys().chain(ob.keys()).collect();
            keys.sort();
            keys.dedup();
            for k in keys {
                let next = format!("{path}/{k}");
                match (oa.get(k), ob.get(k)) {
                    (Some(va), Some(vb)) => json_pointer_diffs(va, vb, &next, out),
                    (Some(_), None) => out.push(format!("{next} (present only on the left)")),
                    (None, Some(_)) => out.push(format!("{next} (present only on the right)")),
                    (None, None) => unreachable!(),
                }
            }
        }
        (Value::Array(aa), Value::Array(ba)) => {
            if aa.len() != ba.len() {
                out.push(format!("{path} (length {} vs {})", aa.len(), ba.len()));
            }
            for (i, (va, vb)) in aa.iter().zip(ba.iter()).enumerate() {
                json_pointer_diffs(va, vb, &format!("{path}/{i}"), out);
            }
        }
        // Two numbers get an epsilon, everything else (strings, bools, null) stays byte-exact.
        // `page_content_width` round-trips through `paper.width_points - margins.left -
        // margins.right`, where `width_points` was itself built as `left + content + right`
        // (`office_adapter::build_paper`/`office_block::PaperGeometry::paper_width`) — the SAME
        // fact, carried through a sum then a subtraction, which float addition/subtraction is not
        // guaranteed to invert exactly (425.2 measured back as 425.19999999999993 on a real
        // document). That is a representation artifact of the round trip, not a semantic gap the
        // tree failed to carry, so it is tolerated here rather than added to a fixture's allowed
        // gap list.
        (Value::Number(na), Value::Number(nb)) => {
            let (fa, fb) = (na.as_f64(), nb.as_f64());
            let equal = match (fa, fb) {
                (Some(fa), Some(fb)) => (fa - fb).abs() <= 1e-6 * fa.abs().max(fb.abs()).max(1.0),
                _ => na == nb,
            };
            if !equal {
                out.push(format!("{path} ({na} vs {nb})"));
            }
        }
        (va, vb) => {
            if va != vb {
                out.push(format!("{path} ({va} vs {vb})"));
            }
        }
    }
}

fn assert_projection_matches(result: &OfficeReadResult, source_name: &str) {
    let reader_json = to_json(result).unwrap_or_else(|e| {
        panic!("{source_name}: to_json refused a result this test expected exportable: {e:?}")
    });
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Docx,
        source_name,
        source_bytes: source_name.as_bytes(),
        result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("{source_name}: from_office failed: {e:?}"));
    let projected_json = project(&tree).unwrap_or_else(|e| {
        panic!("{source_name}: project returned {e:?} on a fixture this test expected to project")
    });

    let a: serde_json::Value = serde_json::from_str(&reader_json).expect("to_json output is valid JSON");
    let b: serde_json::Value = serde_json::from_str(&projected_json).expect("project output is valid JSON");
    let mut diffs = Vec::new();
    json_pointer_diffs(&a, &b, "", &mut diffs);
    assert!(
        diffs.is_empty(),
        "{source_name}: to_json and project disagree at:\n{}",
        diffs.join("\n")
    );
}

// -------------------------------------------------------------------------------------------
// Instrument self-tests (S4-02's own acceptance): the oracle must prove what it measures before
// any fixture result is trusted.
// -------------------------------------------------------------------------------------------

#[test]
fn map_insertion_order_alone_compares_equal() {
    let a: serde_json::Value = serde_json::from_str(r#"{"a":1,"b":2,"c":3}"#).unwrap();
    let b: serde_json::Value = serde_json::from_str(r#"{"c":3,"a":1,"b":2}"#).unwrap();
    assert_eq!(a, b, "two objects differing only in key insertion order must compare EQUAL");
    let mut diffs = Vec::new();
    json_pointer_diffs(&a, &b, "", &mut diffs);
    assert!(diffs.is_empty(), "the pointer-diff walk must also see no difference: {diffs:?}");
}

#[test]
fn array_reordering_compares_unequal() {
    let a: serde_json::Value = serde_json::from_str(r#"{"xs":[1,2,3]}"#).unwrap();
    let b: serde_json::Value = serde_json::from_str(r#"{"xs":[3,2,1]}"#).unwrap();
    assert_ne!(a, b, "two arrays differing only in element order must compare UNEQUAL");
    let mut diffs = Vec::new();
    json_pointer_diffs(&a, &b, "", &mut diffs);
    assert!(
        diffs.iter().any(|d| d.starts_with("/xs/0") || d.starts_with("/xs/2")),
        "the pointer-diff walk must name the reordered array positions: {diffs:?}"
    );
}

/// The known, documented blind spot: `serde_json`'s default object parsing keeps only the LAST
/// occurrence of a repeated key (`preserve_order` is not enabled in this workspace), so a
/// duplicate-key mutation on one side of a comparison is silently absorbed before canonical
/// equality ever runs — a BYTE comparison of the raw JSON strings would catch it (the strings
/// differ), canonical `Value` equality cannot (both parse to the identical map). This test does
/// not close the hole; it proves the hole exists and is a known, checked property of this
/// instrument rather than something a mutation battery could discover by surprise.
#[test]
fn a_duplicate_key_is_invisible_to_canonical_comparison_by_design() {
    let honest: serde_json::Value = serde_json::from_str(r#"{"fontSize":12}"#).unwrap();
    // The same document, mutated: an attacker (or a bug) prepends a duplicate `fontSize` with a
    // WRONG value before the correct one. Byte-for-byte the two source strings are different.
    let mutated: serde_json::Value =
        serde_json::from_str(r#"{"fontSize":999,"fontSize":12}"#).unwrap();
    assert_eq!(
        honest, mutated,
        "serde_json's last-key-wins parse must make this pair canonically EQUAL — \
         proving canonical comparison alone cannot see a duplicate-key mutation"
    );
}

// -------------------------------------------------------------------------------------------
// Fixture comparisons — hand-built `OfficeReadResult`s (no zip/HWP dependency needed to exercise
// the block vocabulary itself), plus real HWP documents for the real-parser half.
// -------------------------------------------------------------------------------------------

fn plain_span(text: &str) -> Span {
    Span { text: text.into(), ..Span::default() }
}

#[test]
fn a_single_plain_paragraph_projects_identically() {
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Paragraph {
            spans: vec![plain_span("hello office")],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        }],
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "single-paragraph.docx");
}

#[test]
fn a_heading_and_a_styled_paragraph_project_identically() {
    let bold = Span { bold: true, italic: true, ..plain_span("Title") };
    let result = OfficeReadResult {
        blocks: vec![
            OfficeBlock::Heading {
                level: 1,
                spans: vec![bold],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            },
            OfficeBlock::Paragraph {
                spans: vec![plain_span("Body text, unstyled.")],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            },
        ],
        default_body_font_size: 12.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "heading-and-body.docx");
}

#[test]
fn a_two_by_two_table_projects_identically() {
    let cell = |t: &str| Cell::new_with_spans(vec![plain_span(t)], 1, 1);
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Table {
            rows: vec![
                vec![cell("A1"), cell("B1")],
                vec![cell("A2"), cell("B2")],
            ],
            header_rows: 1,
            column_widths: vec![],
            format: TableFormat::default(),
        }],
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "two-by-two-table.docx");
}

/// S4-04's own acceptance in end-to-end form: an image AND a vector graphic each roundtrip their
/// document-declared key (`source_key`) through the wire tree and back out into `images`/
/// `vector_graphics`, keyed exactly as the document named them — not by the tree's own sequential
/// resource id.
#[test]
fn an_image_and_a_vector_graphic_round_trip_their_source_keys() {
    let mut images = std::collections::HashMap::new();
    images.insert(
        SwiftStr::from("docximg:1"),
        Data::fromBytes(vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]),
    );
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Image {
            id: "docximg:1".into(),
            size: CGSize::new(40.0, 30.0),
            alignment: None,
        }],
        images,
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "image-source-key.docx");
}

/// The VECTOR half of the same contract, and it is a separate test because the first one did not
/// cover it: `map_image_or_vector` (`office_adapter.rs:848-858`) only takes the vector branch when
/// the key is present in `vector_graphics`, and a fixture with an empty `vector_graphics` map runs
/// `map_image` for every graphic no matter what its name says. Dropping `wire::Vector.source_key`
/// while leaving `Resource.source_key` in place left the suite green until this existed.
#[test]
fn a_vector_graphic_alone_round_trips_its_source_key_through_the_vector_branch() {
    let mut vector_graphics = std::collections::HashMap::new();
    vector_graphics.insert(
        SwiftStr::from("hwpshape:7"),
        VectorGraphic {
            paths: vec![PathSpec {
                commands: vec![
                    PathCommand::Move(CGPoint::new(0.0, 0.0)),
                    PathCommand::Line(CGPoint::new(10.0, 10.0)),
                ],
                stroke: None,
                fill: None,
                arrow_start: false,
                arrow_end: false,
            }],
            size: CGSize::new(20.0, 12.0),
        },
    );
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Image {
            id: "hwpshape:7".into(),
            size: CGSize::new(20.0, 12.0),
            alignment: None,
        }],
        vector_graphics,
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "vector-source-key.hwp");
}

/// S6-2 — an anchored object round-trips through the SAME oracle every other office fact does:
/// `to_json` (schema-v4, `office_export.rs` no longer refuses it) against `project` (the wire
/// tree, `office_adapter::build_anchored_object_node` + `office_project::anchored_object`), built
/// from one `OfficeReadResult` neither function can see the other's answer for. Covers both halves
/// of `wire::AnchoredObject`'s own invariant: a paper-relative object here (`y` final,
/// `paragraph_anchor` absent) — the paragraph-relative half (`y` absent, `paragraph_anchor`
/// present) is `a_paragraph_anchored_object_round_trips_with_no_final_y` below, since a single
/// result can only ever carry one or the other for a given object.
#[test]
fn an_anchored_object_round_trips_its_frame_and_vector_content() {
    use fastdoc_engine::render::office::office_block::{
        OfficeAnchoredObject, OfficeMasterObject, OfficeMasterObjectContent,
    };
    use swiftshim::CGRect;
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Paragraph {
            spans: vec![],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        }],
        anchored_objects: vec![OfficeAnchoredObject {
            block_index: 0,
            object: OfficeMasterObject {
                frame: CGRect::new(12.5, 34.0, 48.0, 48.0),
                content: OfficeMasterObjectContent::Vector(VectorGraphic {
                    paths: vec![PathSpec {
                        commands: vec![PathCommand::Move(CGPoint::new(0.0, 0.0))],
                        stroke: None,
                        fill: None,
                        arrow_start: false,
                        arrow_end: false,
                    }],
                    size: CGSize::new(48.0, 48.0),
                }),
            },
            paragraph_anchor: None,
        }],
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "anchored-vector.hwp");
}

/// The paragraph-relative half: `paragraph_anchor` present, `object.frame.origin.y` a
/// placeholder — `to_json` serializes that placeholder verbatim (it is a real, if meaningless,
/// number on the `OfficeReadResult` side), while `project` reconstructs it as `0.0` from
/// `wire::AnchoredObject.y == None` (`office_project::anchored_object`'s own doc). So the
/// placeholder used here IS `0.0`, the only value the two sides are contracted to agree on — a
/// real reader's placeholder value is never read back by anything, `paragraph_anchor` alone is.
#[test]
fn a_paragraph_anchored_object_round_trips_with_no_final_y() {
    use fastdoc_engine::render::office::office_block::{
        OfficeAnchoredObject, OfficeMasterObject, OfficeMasterObjectContent, ParagraphAnchor,
        ParagraphAnchorAlign,
    };
    use swiftshim::CGRect;
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Paragraph {
            spans: vec![],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        }],
        anchored_objects: vec![OfficeAnchoredObject {
            block_index: 0,
            object: OfficeMasterObject {
                frame: CGRect::new(342.6, 0.0, 48.0, 48.0),
                content: OfficeMasterObjectContent::Vector(VectorGraphic {
                    paths: vec![PathSpec {
                        commands: vec![PathCommand::Move(CGPoint::new(0.0, 0.0))],
                        stroke: None,
                        fill: None,
                        arrow_start: false,
                        arrow_end: false,
                    }],
                    size: CGSize::new(48.0, 48.0),
                }),
            },
            paragraph_anchor: Some(ParagraphAnchor { align: ParagraphAnchorAlign::Top, offset: 155.3 }),
        }],
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "anchored-paragraph.hwp");
}

/// The document's own font table — S4 Pass C's unit: `wire::Document.declared_faces` now carries
/// what `hwp_reader::mapping.rs` reads off the document (`nominated_substitute`, `is_embedded`,
/// `type_info`), and `project` reads it back rather than emitting `{}`. Two entries, one with every
/// optional field populated and one bare, so a dropped `Option` would surface as a real diff.
#[test]
fn the_document_s_own_font_table_round_trips_through_declared_faces() {
    use fastdoc_engine::render::office::declared_font_kind::DeclaredFace;

    let mut declared_faces = std::collections::HashMap::new();
    declared_faces.insert(
        SwiftStr::from("HY견고딕"),
        DeclaredFace {
            nominated_substitute: Some("Malgun Gothic".to_string()),
            is_embedded: true,
            type_info: Some(vec![2, 11, 6, 0, 0, 0, 0, 0, 0, 0]),
        },
    );
    declared_faces.insert(SwiftStr::from("바탕"), DeclaredFace::default());
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Paragraph {
            spans: vec![plain_span("declared-faces round trip")],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        }],
        declared_faces,
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "declared-faces.hwp");
}

use fastdoc_engine::render::office::hwp_shape_path::{PathCommand, PathSpec, VectorGraphic};
use swiftshim::{CGPoint, SwiftString as SwiftStr};

// -------------------------------------------------------------------------------------------
// Real HWP documents through the full pipeline.
// -------------------------------------------------------------------------------------------

fn rhwp_saved_fixture(name: &str) -> Vec<u8> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let path = manifest_dir.join("../../..").join("Vendor/rhwp-src/saved").join(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

/// Every diff `json_pointer_diffs` can report on a REAL HWP/HWPX document that this pass's
/// projector still cannot match byte-for-byte, without that being a regression — the module doc's
/// own "known, deliberate exceptions" list, restated as predicates over a diff line rather than
/// prose, so a real fixture's residual diffs can be checked against it instead of eyeballed.
fn is_a_documented_real_document_gap(diff: &str) -> bool {
    // `default_body_font_size` / a run's own `fontSize`: the MODE-reconstruction heuristic this
    // module's own doc names — a span whose declared size happens to equal the reconstructed
    // document default nulls out on the project side, so it is only ever "present only on to_json".
    (diff.contains("/font_size ") && diff.ends_with("(present only on to_json)"))
    // `sections` / `section_start_blocks`: the ONE remaining ambiguity this module's own doc
    // names — `wire::Document.declared_section_count == 0`, a source that declared no section at
    // all, which the synthetic single-section tree docx/odt always build is indistinguishable
    // from. No real HWP/HWPX sample in this corpus hits it (every one declares at least one
    // section), so this predicate is defensive rather than presently exercised; kept for a future
    // format or fixture that does declare none.
}

/// Runs the oracle on a real HWP/HWPX document and asserts every residual diff is one of this
/// module's own DOCUMENTED, named exceptions — never a silent pass on an undocumented one. A new,
/// undocumented diff fails this test by name and position, exactly like a strict equality would.
fn assert_projects_within_documented_gaps(bytes: &[u8], source_name: &str, format: DocumentFormat) {
    let data = Data::fromBytes(bytes.to_vec());
    let result = HwpReader::read_before_host_font_substitution(&data)
        .unwrap_or_else(|e| panic!("{source_name}: HwpReader::read failed: {e:?}"));
    let reader_json = to_json(&result)
        .unwrap_or_else(|e| panic!("{source_name}: to_json refused a fixture expected exportable: {e:?}"));
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format,
        source_name,
        source_bytes: bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("{source_name}: from_office failed: {e:?}"));
    let projected_json = project(&tree)
        .unwrap_or_else(|e| panic!("{source_name}: project refused a fixture expected to project: {e:?}"));

    let a: serde_json::Value = serde_json::from_str(&reader_json).expect("to_json output is valid JSON");
    let b: serde_json::Value = serde_json::from_str(&projected_json).expect("project output is valid JSON");
    let mut diffs = Vec::new();
    json_pointer_diffs(&a, &b, "", &mut diffs);
    let undocumented: Vec<&String> =
        diffs.iter().filter(|d| !is_a_documented_real_document_gap(d)).collect();
    assert!(
        undocumented.is_empty(),
        "{source_name}: project diverges from to_json at an UNDOCUMENTED path (not one of this \
         module's own named exceptions):\n{}",
        undocumented.iter().map(|d| d.as_str()).collect::<Vec<_>>().join("\n")
    );
}

/// `blank2010.hwp` is a single-section document, and a real one — proof the column-layout inversion
/// (`office_project::column_layout_back`) closes the gap the S4 Pass A evidence recorded here
/// (`ProjectionError::Field("span.column_layout")`): `project` now succeeds, and every remaining
/// difference from `to_json` is one this module's own doc names, not a new one.
#[test]
fn a_real_single_section_hwp_document_projects_within_documented_gaps() {
    let bytes = rhwp_saved_fixture("blank2010.hwp");
    assert_projects_within_documented_gaps(&bytes, "blank2010.hwp", DocumentFormat::Hwp);
}

/// The same fixture, but asserting `declared_faces` directly rather than trusting the oracle's
/// documented-gap list — that list is what used to excuse `{}`, and removing the exemption is only
/// proof if a real document's non-empty table is checked by name, not just "no undocumented diff".
#[test]
fn a_real_hwp_document_s_font_table_round_trips_by_name() {
    let bytes = rhwp_saved_fixture("blank2010.hwp");
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data)
        .unwrap_or_else(|e| panic!("blank2010.hwp: HwpReader::read failed: {e:?}"));
    assert!(
        !result.declared_faces.is_empty(),
        "blank2010.hwp: expected a non-empty declared-faces table — if the fixture no longer          declares one, this is not this test's acceptance document any more"
    );
    let reader_json = to_json(&result)
        .unwrap_or_else(|e| panic!("blank2010.hwp: to_json refused a fixture expected exportable: {e:?}"));
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Hwp,
        source_name: "blank2010.hwp",
        source_bytes: &bytes,
        result: &result,
        resources: BTreeMap::new(),
    })
    .unwrap_or_else(|e| panic!("blank2010.hwp: from_office failed: {e:?}"));
    let projected_json = project(&tree)
        .unwrap_or_else(|e| panic!("blank2010.hwp: project failed: {e:?}"));

    let a: serde_json::Value = serde_json::from_str(&reader_json).expect("to_json output is valid JSON");
    let b: serde_json::Value = serde_json::from_str(&projected_json).expect("project output is valid JSON");
    assert_eq!(
        a.get("declared_faces"),
        b.get("declared_faces"),
        "blank2010.hwp: declared_faces did not round-trip through the tree"
    );
    assert_ne!(
        b.get("declared_faces"),
        Some(&serde_json::json!({})),
        "blank2010.hwp: projected declared_faces was empty — the table did not actually carry"
    );
}

/// `hwpx-01-saved.hwpx` is this unit's own acceptance document — a genuinely MULTI-section tree
/// (more than one `Section` node under the document root), and this sprint's own real success-path
/// comparison for it: `wire::Section` now carries every one of `OfficeSectionDeclaration`'s six
/// previously-refused fields, so `project` no longer refuses `Field("sections")` on this document
/// at all. Runs the same documented-gap oracle the single-section `blank2010.hwp` test uses
/// (`assert_projects_within_documented_gaps`) rather than strict equality, because a real document
/// can still carry this module's OTHER named gaps (the `font_size` mode-reconstruction heuristic);
/// what changed is that `/sections` and `/section_start_blocks` are no longer among them for a
/// document that declares more than one section (`is_a_documented_real_document_gap`'s own doc).
#[test]
fn a_real_multi_section_hwpx_document_projects_within_documented_gaps() {
    let bytes = rhwp_saved_fixture("hwpx-01-saved.hwpx");
    let data = Data::fromBytes(bytes.clone());
    let result = HwpReader::read_before_host_font_substitution(&data)
        .unwrap_or_else(|e| panic!("hwpx-01-saved.hwpx: HwpReader::read failed: {e:?}"));
    assert!(
        result.sections.len() > 1,
        "hwpx-01-saved.hwpx: expected the source itself to declare more than one section — if it \
         no longer does, this is not this test's acceptance document any more"
    );
    assert_projects_within_documented_gaps(&bytes, "hwpx-01-saved.hwpx", DocumentFormat::Hwpx);
}

/// A span whose column layout DRAWS a separator (`separator_type != 0`) — the branch
/// `column_layout_back` gets wrong if it always reconstructs `separator_color` as `Some`: the
/// source only ever carries one when a rule is actually drawn
/// (`OfficeColumnLayout::from_rhwp_column_def`'s own `(separator_type != 0).then_some(color)`).
/// Every real HWP/HWPX sample in this corpus happens to declare `separator_type == 0` (no rule),
/// so this bug was invisible on real documents and needs a hand-built fixture to catch it.
#[test]
fn a_span_with_a_drawn_column_separator_round_trips_its_layout() {
    use fastdoc_engine::render::office::column_geometry::{OfficeColumnFlowType, OfficeColumnLayout};
    use swiftshim::NSColor;

    let layout = OfficeColumnLayout {
        flow_type: Some(OfficeColumnFlowType::Normal),
        count: 2,
        separator_type: 1, // Solid — draws a rule, so a colour is required.
        separator_color: Some(NSColor::srgb(1.0, 0.0, 0.0, 1.0)),
        separator_color_ref: Some(0x0000_00FF),
        source_raw_attributes: Some(0),
        ..OfficeColumnLayout::default()
    };
    let span = Span { column_layout: Some(layout), ..plain_span("two columns from here") };
    let result = OfficeReadResult {
        blocks: vec![OfficeBlock::Paragraph {
            spans: vec![span],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        }],
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "drawn-column-separator.docx");
}

/// A genuine two-section document, walked and compared byte-for-byte against `to_json` —
/// `assert_projection_matches` diffs EVERY field, so this is strictly stronger than a proof that
/// section two's content merely walks: it also proves each section's own six previously-refused
/// fields (`footnote_separator`, `page_border`, `hides_header`, `hides_footer`,
/// `hides_master_page`, `is_vertical`) reconstruct correctly, and — the point this fixture is built
/// to pin — that section TWO's declaration is read from section two's own node, not duplicated or
/// defaulted from section one. Section one stays `OfficeSectionDeclaration::default()`; section two
/// carries a non-default value on every one of those six fields plus `page_number_start` and
/// `line_grid_pitch`, so a projector that silently read section one's declaration twice, or
/// defaulted section two's, fails this comparison at a named JSON pointer rather than passing by
/// accident.
#[test]
fn a_second_sections_ordinary_content_walks_cleanly_and_carries_its_own_declaration() {
    use fastdoc_engine::render::office::office_block::{
        BorderDecl, BorderLineStyle, BorderSide, EdgeBorders, OfficeFootnoteSeparator,
        OfficePageBorder, OfficeSectionDeclaration, PaperGeometry,
    };

    let section_two = OfficeSectionDeclaration {
        footnote_separator: Some(OfficeFootnoteSeparator {
            line_type: 1,
            line_width_pt: 0.5,
            color: Some(NSColor::srgb(0.2, 0.2, 0.2, 1.0)),
            length_pt: Some(72.0),
            margin_top_pt: 6.0,
            margin_bottom_pt: 4.0,
            note_spacing_pt: 2.0,
        }),
        page_border: Some(OfficePageBorder {
            borders: Some(EdgeBorders {
                top: Some(BorderDecl::Drawn(BorderSide {
                    width: 1.0,
                    color: Some(NSColor::srgb(0.0, 0.0, 0.0, 1.0)),
                    style: BorderLineStyle::Solid,
                })),
                left: Some(BorderDecl::Suppressed),
                bottom: None,
                right: None,
                inside_h: None,
                inside_v: None,
            }),
            background: Some(NSColor::srgb(0.9, 0.9, 0.9, 1.0)),
            spacing: NSEdgeInsets { top: 10.0, left: 10.0, bottom: 10.0, right: 10.0 },
            measured_from_paper: true,
        }),
        paper: Some(PaperGeometry {
            content_width: 400.0,
            content_height: 600.0,
            margin_left: 60.0,
            margin_top: 60.0,
            margin_right: 60.0,
            margin_bottom: 60.0,
        }),
        hides_header: true,
        hides_footer: true,
        hides_master_page: true,
        page_number_start: Some(1),
        line_grid_pitch: Some(20.0),
        is_vertical: true,
    };
    let result = OfficeReadResult {
        blocks: vec![
            OfficeBlock::Paragraph {
                spans: vec![plain_span("section one body")],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            },
            OfficeBlock::Paragraph {
                spans: vec![plain_span("section two body")],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            },
        ],
        sections: vec![OfficeSectionDeclaration::default(), section_two],
        section_start_blocks: vec![0, 1],
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "two-sections-second-has-its-own-declaration.docx");
}

/// THE THREE FIELDS THE ACCOUNTING LEDGER CALLED REFUSED.
///
/// `office_result_accounting` recorded `OfficeHeaderFooter.applies_to`,
/// `OfficePageNumberRestart.block` and `.number` as REFUSED — "the canonical tree cannot carry
/// this" — while the adapter has been carrying all three (`office_adapter.rs:591`, `:653`) and the
/// projection has been reading them back (`office_project.rs:431`, `:635`). The ledger was stale,
/// in the conservative direction: it under-reported the tree's fidelity, and a sprint planning what
/// the tree still cannot express would have read three gaps that are not there.
///
/// A label is not evidence, so the label is not changed on the strength of reading the code. This
/// is the round trip that says so: a first-page-only header, an even-pages footer, and a section
/// whose page numbering restarts at 7 — projected back and compared canonically, whole.
#[test]
fn header_applicability_and_a_page_number_restart_project_identically() {
    let result = OfficeReadResult {
        blocks: vec![
            OfficeBlock::Paragraph {
                spans: vec![plain_span("first page body")],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            },
            OfficeBlock::Paragraph {
                spans: vec![plain_span("the page numbering starts over here")],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            },
        ],
        headers: vec![OfficeHeaderFooter {
            applies_to: HeaderFooterApplicability::FirstPage,
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![plain_span("title page head")],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            section: None,
        }],
        footers: vec![OfficeHeaderFooter {
            applies_to: HeaderFooterApplicability::EvenPages,
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![plain_span("left-hand foot")],
                rtl: false,
                alignment: None,
                tab_stops: vec![],
                format: ParagraphFormat::default(),
            }],
            section: None,
        }],
        page_number_restart_blocks: vec![OfficePageNumberRestart { block: 1, number: 7 }],
        default_body_font_size: 11.0,
        ..OfficeReadResult::default()
    };
    assert_projection_matches(&result, "header-applicability-and-restart.docx");
}

// -------------------------------------------------------------------------------------------
// P4b — the edge-border table has to be built by the assembler a REAL document reaches.
//
// P4a shipped its first pooling into `office_export::to_json` alone, which no real document goes
// through, and the payload did not move by a single byte: the failure showed up as NO CHANGE, not
// as a red test, which is exactly the shape that reads as a pass. The oracle above cannot catch it
// either — it asserts the two assemblers AGREE, so a pooling missing from both agrees perfectly.
//
// So this asserts the property directly, on a fixture built to have something to pool.
// -------------------------------------------------------------------------------------------

use fastdoc_engine::render::office::office_block::{BorderDecl, EdgeBorders};

/// One declaration, worn by four cells.
fn repeated_edge_border_result() -> OfficeReadResult {
    let silenced = EdgeBorders {
        top: Some(BorderDecl::Suppressed),
        left: Some(BorderDecl::Suppressed),
        bottom: Some(BorderDecl::Suppressed),
        right: Some(BorderDecl::Suppressed),
        ..Default::default()
    };
    let cell = |borders: &EdgeBorders| Cell {
        blocks: vec![OfficeBlock::Paragraph {
            spans: vec![plain_span("x")],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        }],
        edge_borders: Some(borders.clone()),
        ..Cell::default()
    };
    OfficeReadResult {
        blocks: vec![OfficeBlock::Table {
            rows: vec![
                vec![cell(&silenced), cell(&silenced)],
                vec![cell(&silenced), cell(&silenced)],
            ],
            header_rows: 0,
            column_widths: vec![100.0, 100.0],
            format: TableFormat::default(),
        }],
        ..Default::default()
    }
}

#[test]
fn the_projection_assembler_pools_repeated_edge_borders() {
    let result = repeated_edge_border_result();
    let tree = ValidatedRenderTree::from_office(OfficeAdapterInput {
        format: DocumentFormat::Docx,
        source_name: "repeated-edge-borders",
        source_bytes: b"repeated-edge-borders",
        result: &result,
        resources: BTreeMap::new(),
    })
    .expect("from_office");
    let projected: serde_json::Value =
        serde_json::from_str(&project(&tree).expect("project")).expect("valid JSON");

    // Four cells, one declaration: the table carries it once and nobody carries it inline.
    let pool = projected["edge_border_pool"]
        .as_array()
        .unwrap_or_else(|| panic!("the projection wrote no edge_border_pool:\n{projected:#}"));
    assert_eq!(pool.len(), 1, "one distinct declaration, one entry");

    let mut inline = 0usize;
    let mut slots = 0usize;
    fn count(v: &serde_json::Value, inline: &mut usize, slots: &mut usize) {
        match v {
            serde_json::Value::Object(map) => {
                for (k, child) in map {
                    if k == "edge_borders" {
                        *inline += 1;
                    }
                    if k == "edge_borders_ref" {
                        *slots += 1;
                    }
                    count(child, inline, slots);
                }
            }
            serde_json::Value::Array(items) => {
                for item in items {
                    count(item, inline, slots);
                }
            }
            _ => {}
        }
    }
    // The pool's own entries are `EdgeBorders` objects, not `edge_borders` KEYS, so they are not
    // counted by the walk above — which is what makes "inline == 0" a real assertion.
    count(&projected, &mut inline, &mut slots);
    assert_eq!(inline, 0, "a pooled document must carry no inline declaration:\n{projected:#}");
    assert_eq!(slots, 4, "every one of the four cells must carry a slot");
}

/// And the two assemblers must still agree on that fixture — the oracle's own job, applied to the
/// case the oracle previously had no example of.
#[test]
fn both_assemblers_agree_on_a_document_with_repeated_edge_borders() {
    assert_projection_matches(&repeated_edge_border_result(), "repeated-edge-borders");
}
