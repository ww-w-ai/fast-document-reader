use fastdoc_engine::render::render_tree::{
    resolve_cell_borders, resolve_cell_padding, BorderDeclaration, BorderLineStyle, BorderSet,
    DecodeError, DocumentFormat, DrawnBorder, Empty, Insets, NodePayload, OptionalInsets,
    RenderDocumentDraft, RenderNodeDraft, RenderSourceDraft, RenderTreeBuilder, SourceKind,
    ValidatedRenderTree,
};
use serde_json::Value;
use std::collections::BTreeSet;

const EXHAUSTIVE: &[u8] = include_bytes!("fixtures/render-tree-v1-exhaustive.json");
const FORMATS: &[u8] = include_bytes!("fixtures/render-tree-v1-formats.json");

fn exhaustive_value() -> Value {
    serde_json::from_slice(EXHAUSTIVE).unwrap()
}
fn decode_value(value: &Value) -> Result<ValidatedRenderTree, DecodeError> {
    ValidatedRenderTree::decode_json(&serde_json::to_vec(value).unwrap())
}

#[test]
fn exhaustive_fixture_is_checked_deterministic_and_covers_every_node_tag() {
    let tree = ValidatedRenderTree::decode_json(EXHAUSTIVE).unwrap();
    assert_eq!(tree.schema_version(), 1);
    assert_eq!(
        tree.node_tags().into_iter().collect::<BTreeSet<_>>(),
        ValidatedRenderTree::supported_node_tags()
            .iter()
            .copied()
            .collect(),
    );
    let once = tree.encode_json().unwrap();
    let twice = ValidatedRenderTree::decode_json(&once)
        .unwrap()
        .encode_json()
        .unwrap();
    assert_eq!(once, twice);
}

#[test]
fn all_six_document_formats_decode_through_the_checked_boundary() {
    let fixtures: Vec<Value> = serde_json::from_slice(FORMATS).unwrap();
    assert_eq!(fixtures.len(), 6);
    for fixture in fixtures {
        decode_value(&fixture).unwrap();
    }
}

fn drawn(width_points: f64) -> DrawnBorder {
    DrawnBorder {
        width_points,
        color: None,
        style: BorderLineStyle::Solid,
    }
}

fn borders_with(side: usize, decl: Option<BorderDeclaration>) -> BorderSet {
    let mut set = BorderSet::default();
    match side {
        0 => set.top = decl,
        1 => set.right = decl,
        2 => set.bottom = decl,
        _ => set.left = decl,
    }
    set
}

fn inside_side(side: usize, decl: Option<BorderDeclaration>) -> BorderSet {
    let mut set = BorderSet::default();
    if side == 0 || side == 2 {
        set.inside_horizontal = decl;
    } else {
        set.inside_vertical = decl;
    }
    set
}

#[test]
fn border_side_resolution_matches_the_six_row_matrix_across_perimeter_and_interior_placements() {
    let fallback = drawn(9.0);
    for side in 0..4usize {
        let mut perimeter = [false; 4];
        perimeter[side] = true;

        // Row 1: cell drawn wins regardless of table declaration or perimeter placement.
        let cell = borders_with(side, Some(BorderDeclaration::Drawn(drawn(1.0))));
        let table = borders_with(side, Some(BorderDeclaration::Suppressed));
        let resolved = resolve_cell_borders(&cell, &table, perimeter, true, Some(&fallback));
        assert!(resolved[side].explicit);
        assert_eq!(resolved[side].side.map(|d| d.width_points), Some(1.0));

        // Row 2: cell suppressed wins over any table declaration.
        let cell = borders_with(side, Some(BorderDeclaration::Suppressed));
        let table = borders_with(side, Some(BorderDeclaration::Drawn(drawn(2.0))));
        let resolved = resolve_cell_borders(&cell, &table, perimeter, true, Some(&fallback));
        assert!(resolved[side].explicit);
        assert!(resolved[side].side.is_none());

        // Row 3: cell unspecified, perimeter table side drawn -> table wins, explicit.
        let cell = BorderSet::default();
        let table = borders_with(side, Some(BorderDeclaration::Drawn(drawn(3.0))));
        let resolved = resolve_cell_borders(&cell, &table, perimeter, true, Some(&fallback));
        assert!(resolved[side].explicit);
        assert_eq!(resolved[side].side.map(|d| d.width_points), Some(3.0));

        // Row 3 (interior selection): same but the span sits on the table interior instead.
        let mut interior_perimeter = [false; 4];
        interior_perimeter[side] = false;
        let table_interior = inside_side(side, Some(BorderDeclaration::Drawn(drawn(3.5))));
        let resolved = resolve_cell_borders(
            &cell,
            &table_interior,
            interior_perimeter,
            true,
            Some(&fallback),
        );
        assert!(resolved[side].explicit);
        assert_eq!(resolved[side].side.map(|d| d.width_points), Some(3.5));

        // Row 4: cell unspecified, table side suppressed -> no side, explicit.
        let table = borders_with(side, Some(BorderDeclaration::Suppressed));
        let resolved = resolve_cell_borders(&cell, &table, perimeter, true, Some(&fallback));
        assert!(resolved[side].explicit);
        assert!(resolved[side].side.is_none());

        // Row 5: both unspecified, table drew some other edge -> no side, implicit.
        let table = BorderSet::default();
        let resolved = resolve_cell_borders(&cell, &table, perimeter, true, Some(&fallback));
        assert!(!resolved[side].explicit);
        assert!(resolved[side].side.is_none());

        // Row 6: both unspecified, table drew nothing -> caller fallback, implicit.
        let resolved = resolve_cell_borders(&cell, &table, perimeter, false, Some(&fallback));
        assert!(!resolved[side].explicit);
        assert_eq!(resolved[side].side.map(|d| d.width_points), Some(9.0));
    }
}

#[test]
fn spanned_placement_selects_inside_and_perimeter_table_declarations_per_side() {
    let cell = BorderSet::default();
    let mut table = BorderSet::default();
    table.top = Some(BorderDeclaration::Drawn(drawn(1.0)));
    table.right = Some(BorderDeclaration::Drawn(drawn(2.0)));
    table.bottom = Some(BorderDeclaration::Drawn(drawn(3.0)));
    table.left = Some(BorderDeclaration::Drawn(drawn(4.0)));
    table.inside_horizontal = Some(BorderDeclaration::Drawn(drawn(5.0)));
    table.inside_vertical = Some(BorderDeclaration::Drawn(drawn(6.0)));

    let (row, column, row_span, column_span, row_count, column_count) = (1, 1, 2, 3, 3, 4);
    let perimeter = [
        row == 0,
        column + column_span >= column_count,
        row + row_span >= row_count,
        column == 0,
    ];
    let resolved = resolve_cell_borders(&cell, &table, perimeter, true, None);
    assert_eq!(
        resolved.map(|edge| edge.side.unwrap().width_points),
        [5.0, 2.0, 3.0, 6.0]
    );
}

#[test]
fn padding_resolution_matches_the_three_row_matrix_including_authored_zero() {
    let fallback = Insets {
        top: 5.0,
        right: 5.0,
        bottom: 5.0,
        left: 5.0,
    };

    // Row 1: cell value wins, including an authored zero.
    let cell = OptionalInsets {
        top: Some(0.0),
        right: Some(1.0),
        bottom: None,
        left: None,
    };
    let table = OptionalInsets {
        top: Some(9.0),
        right: Some(9.0),
        bottom: Some(9.0),
        left: None,
    };
    let resolved = resolve_cell_padding(&cell, &table, fallback);
    assert_eq!(resolved.top, 0.0);
    assert_eq!(resolved.right, 1.0);

    // Row 2: cell unspecified, table value wins, including an authored zero.
    let cell_unspecified = OptionalInsets::default();
    let table_zero = OptionalInsets {
        top: Some(0.0),
        right: None,
        bottom: None,
        left: None,
    };
    let resolved = resolve_cell_padding(&cell_unspecified, &table_zero, fallback);
    assert_eq!(resolved.top, 0.0);

    // Row 3: both unspecified, caller fallback wins.
    let both_unspecified = OptionalInsets::default();
    let resolved = resolve_cell_padding(&both_unspecified, &both_unspecified, fallback);
    assert_eq!(resolved.top, fallback.top);
    assert_eq!(resolved.left, fallback.left);
}

#[test]
fn every_macro_enum_value_is_exercised_by_a_checked_fixture_variant() {
    for (name, values) in ValidatedRenderTree::supported_enum_catalog() {
        for value in *values {
            let mut fixture = exhaustive_value();
            match *name {
                "Representation" => fixture["representation"] = (*value).into(),
                "DocumentFormat" => fixture["document"]["format"] = (*value).into(),
                "SourceKind" => {
                    let source_index = if matches!(*value, "decodedText" | "logicalText") {
                        0
                    } else {
                        1
                    };
                    fixture["sources"][source_index]["kind"] = (*value).into();
                }
                "SpanPurpose" => {
                    let node = if *value == "editable" { 5 } else { 3 };
                    fixture["nodes"][node]["sourceSpans"][0]["purpose"] = (*value).into();
                }
                "Affinity" => {
                    let node = if *value == "exact" { 5 } else { 3 };
                    fixture["nodes"][node]["sourceSpans"][0]["affinity"] = (*value).into();
                }
                "EditOperation" => fixture["nodes"][5]["edit"]["operationClass"] = (*value).into(),
                "Direction" => fixture["nodes"][5]["data"]["direction"] = (*value).into(),
                "Alignment" => fixture["nodes"][16]["data"]["alignment"] = (*value).into(),
                "VerticalAlignment" => {
                    fixture["nodes"][15]["data"]["verticalAlignment"] = (*value).into()
                }
                "UnderlineStyle" => {
                    fixture["nodes"][5]["data"]["style"]["underline"] = (*value).into()
                }
                "LineBreakKind" => fixture["nodes"][6]["data"]["kind"] = (*value).into(),
                "DiagramLanguage" => fixture["nodes"][19]["data"]["language"] = (*value).into(),
                "FormControlKind" => fixture["nodes"][24]["data"]["kind"] = (*value).into(),
                "VerticalPosition" => {
                    fixture["nodes"][5]["data"]["style"]["verticalPosition"] = (*value).into()
                }
                "PageNumberField" => {
                    fixture["nodes"][5]["data"]["pageNumberField"] = (*value).into()
                }
                "TabAlignment" => {
                    fixture["nodes"][4]["data"]["tabStops"][0]["alignment"] = (*value).into()
                }
                "TabLeader" => {
                    fixture["nodes"][4]["data"]["tabStops"][0]["leader"] = (*value).into()
                }
                "LineBreakGranularity" => {
                    fixture["nodes"][11]["data"]["style"]["eastAsianLineBreak"] = (*value).into()
                }
                "ListNumberingGlyphs" => {
                    fixture["nodes"][10]["data"]["numbering"]["glyphs"] = (*value).into()
                }
                "ColorSpace" => {
                    fixture["nodes"][5]["data"]["style"]["foreground"]["space"] = (*value).into()
                }
                "BorderLineStyle" => {
                    fixture["nodes"][15]["data"]["directEdgeBorders"]["top"]["value"]["style"] =
                        (*value).into()
                }
                "CellDiagonalDirection" => {
                    fixture["nodes"][15]["data"]["diagonal"]["direction"] = (*value).into()
                }
                "TablePageBreakPolicy" => {
                    fixture["nodes"][13]["data"]["style"]["pageBreakPolicy"] = (*value).into()
                }
                other => panic!("enum catalog has no checked fixture route: {other}"),
            }
            decode_value(&fixture).unwrap_or_else(|error| panic!("{name}::{value}: {error:?}"));
        }
    }
}

#[test]
fn public_typed_builder_uses_the_same_checked_canonicalization() {
    let document = RenderDocumentDraft {
        format: DocumentFormat::PlainText,
        editable: false,
        root_node_id: 1,
        source_ids: vec![],
        default_locale: None,
    };
    let mut builder = RenderTreeBuilder::new("builder-test", document);
    builder.add_source(RenderSourceDraft {
        id: 1,
        kind: SourceKind::OriginalFile,
        name: "empty.txt".into(),
        encoding: None,
        revision: "r1".into(),
        sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
        byte_length: Some(0),
        utf8_length: None,
        utf16_length: None,
        editable: false,
        text_content: None,
    });
    builder.add_node(RenderNodeDraft {
        id: 1,
        parent_id: None,
        children: vec![],
        source_spans: vec![],
        edit: None,
        payload: NodePayload::Document(Empty {}),
    });
    assert_eq!(builder.build().unwrap().schema_version(), 1);
}

#[test]
fn additive_fields_are_tolerated_but_unknown_tags_and_versions_are_not() {
    let mut additive = exhaustive_value();
    additive
        .as_object_mut()
        .unwrap()
        .insert("futureField".into(), Value::Bool(true));
    decode_value(&additive).unwrap();

    let mut unknown = exhaustive_value();
    unknown["nodes"][0]["type"] = Value::String("futureNode".into());
    assert!(matches!(
        decode_value(&unknown),
        Err(DecodeError::Schema(_))
    ));

    let mut version = exhaustive_value();
    version["schemaVersion"] = Value::from(2);
    assert!(matches!(
        decode_value(&version),
        Err(DecodeError::Schema(_))
    ));
}

#[test]
fn pre_consumer_old_tabs_and_numbering_are_rejected_while_office_values_are_preserved() {
    let mut scalar_tab = exhaustive_value();
    scalar_tab["nodes"][4]["data"]["tabStops"] = serde_json::json!([36]);
    assert!(matches!(
        decode_value(&scalar_tab),
        Err(DecodeError::Syntax(_))
    ));

    let mut free_form_numbering = exhaustive_value();
    free_form_numbering["nodes"][10]["data"]["numbering"] =
        serde_json::json!({"format":"decimal","start":1,"prefix":"","suffix":"."});
    assert!(matches!(
        decode_value(&free_form_numbering),
        Err(DecodeError::Syntax(_))
    ));

    let mut deep_heading_and_negative_start = exhaustive_value();
    deep_heading_and_negative_start["nodes"][3]["data"]["level"] = (-99).into();
    deep_heading_and_negative_start["nodes"][11]["data"]["numbering"]["startNumber"] = (-7).into();
    decode_value(&deep_heading_and_negative_start).unwrap();
}

#[test]
fn s2a1b_fixture_exercises_every_new_run_paragraph_and_list_field_shape() {
    let value = exhaustive_value();
    let required = [
        "/nodes/3/data/tabStops/0/alignment",
        "/nodes/4/data/style/listTextDistance",
        "/nodes/4/data/style/hangingIndent",
        "/nodes/4/data/style/contextualSpacing",
        "/nodes/4/data/style/eastAsianLineBreak",
        "/nodes/4/data/style/latinLineBreak",
        "/nodes/4/data/style/autoSpaceEastAsianLatin",
        "/nodes/4/data/style/autoSpaceEastAsianNumber",
        "/nodes/4/data/style/lineHeightFromFontMetrics",
        "/nodes/4/data/tabStops/0/leader",
        "/nodes/5/data/style/verticalPosition",
        "/nodes/5/data/style/letterSpacingPercent",
        "/nodes/5/data/style/baselineOffsetPercent",
        "/nodes/5/data/style/underlineColor",
        "/nodes/5/data/style/strikethroughColor",
        "/nodes/5/data/style/declaredFontName",
        "/nodes/5/data/footnoteReferenceNumber",
        "/nodes/5/data/formControl/kind",
        "/nodes/5/data/pageNumberField",
        "/nodes/10/data/numbering/glyphs",
        "/nodes/10/data/numbering/startNumber",
        "/nodes/11/data/ordered",
        "/nodes/11/data/marker",
        "/nodes/11/data/numbering/glyphs",
        "/nodes/11/data/style/eastAsianLineBreak",
        "/nodes/11/data/tabStops/0/positionPoints",
    ];
    for pointer in required {
        assert!(
            value.pointer(pointer).is_some(),
            "fixture field absent: {pointer}"
        );
    }
}

#[test]
fn every_required_malformed_schema_mutation_is_killed() {
    type Mutation = (&'static str, Box<dyn Fn(&mut Value)>);
    let mutations: Vec<Mutation> = vec![
        (
            "schema-version",
            Box::new(|v| v["schemaVersion"] = 2.into()),
        ),
        (
            "representation",
            Box::new(|v| v["representation"] = "laidOut".into()),
        ),
        (
            "unknown-tag",
            Box::new(|v| v["nodes"][0]["type"] = "future".into()),
        ),
        ("zero-node-id", Box::new(|v| v["nodes"][0]["id"] = 0.into())),
        (
            "duplicate-node-id",
            Box::new(|v| v["nodes"][1]["id"] = 1.into()),
        ),
        (
            "zero-source-id",
            Box::new(|v| v["sources"][0]["id"] = 0.into()),
        ),
        (
            "duplicate-source-id",
            Box::new(|v| {
                let source = v["sources"][0].clone();
                v["sources"].as_array_mut().unwrap().push(source);
            }),
        ),
        (
            "unlisted-source",
            Box::new(|v| v["document"]["sourceIds"] = serde_json::json!([1])),
        ),
        (
            "zero-resource-id",
            Box::new(|v| v["resources"][0]["id"] = 0.into()),
        ),
        (
            "duplicate-resource-id",
            Box::new(|v| {
                let resource = v["resources"][0].clone();
                v["resources"].as_array_mut().unwrap().push(resource);
            }),
        ),
        (
            "duplicate-resource-hash",
            Box::new(|v| {
                let mut resource = v["resources"][0].clone();
                resource["id"] = 2.into();
                v["resources"].as_array_mut().unwrap().push(resource);
            }),
        ),
        (
            "zero-comment-id",
            Box::new(|v| v["annotations"]["comments"][0]["id"] = 0.into()),
        ),
        (
            "duplicate-comment-id",
            Box::new(|v| {
                let item = v["annotations"]["comments"][0].clone();
                v["annotations"]["comments"]
                    .as_array_mut()
                    .unwrap()
                    .push(item);
            }),
        ),
        (
            "zero-bookmark-id",
            Box::new(|v| v["annotations"]["bookmarks"][0]["id"] = 0.into()),
        ),
        (
            "duplicate-bookmark-id",
            Box::new(|v| {
                let item = v["annotations"]["bookmarks"][0].clone();
                v["annotations"]["bookmarks"]
                    .as_array_mut()
                    .unwrap()
                    .push(item);
            }),
        ),
        (
            "node-order",
            Box::new(|v| v["nodes"].as_array_mut().unwrap().swap(1, 2)),
        ),
        (
            "document-source-order",
            Box::new(|v| v["document"]["sourceIds"] = serde_json::json!([2, 1])),
        ),
        (
            "missing-root",
            Box::new(|v| v["document"]["rootNodeId"] = 99.into()),
        ),
        (
            "multiple-roots",
            Box::new(|v| v["nodes"][1]["parentId"] = Value::Null),
        ),
        (
            "child-parent-order",
            Box::new(|v| {
                v["nodes"][0]["children"]
                    .as_array_mut()
                    .unwrap()
                    .retain(|x| x.as_u64() != Some(2))
            }),
        ),
        (
            "cycle",
            Box::new(|v| {
                v["nodes"][0]["children"]
                    .as_array_mut()
                    .unwrap()
                    .retain(|x| !matches!(x.as_u64(), Some(2) | Some(3)));
                v["nodes"][1]["parentId"] = 3.into();
                v["nodes"][1]["children"] = serde_json::json!([3]);
                v["nodes"][2]["parentId"] = 2.into();
                v["nodes"][2]["children"] = serde_json::json!([2]);
            }),
        ),
        (
            "duplicate-edge",
            Box::new(|v| {
                v["nodes"][0]["children"]
                    .as_array_mut()
                    .unwrap()
                    .push(2.into())
            }),
        ),
        (
            "parent-disagreement",
            Box::new(|v| v["nodes"][1]["parentId"] = 3.into()),
        ),
        (
            "row-parent-kind",
            Box::new(|v| {
                v["nodes"][13]["data"]["headerRows"] = 0.into();
                v["nodes"][13]["children"] = serde_json::json!([]);
                v["nodes"][14]["parentId"] = 1.into();
                let children = v["nodes"][0]["children"].as_array_mut().unwrap();
                children.push(15.into());
                children.sort_by_key(|x| x.as_u64());
            }),
        ),
        (
            "cell-parent-kind",
            Box::new(|v| {
                let mut replacement = v["nodes"][15].clone();
                replacement["id"] = 100.into();
                v["nodes"].as_array_mut().unwrap().push(replacement);
                v["nodes"][14]["children"] = serde_json::json!([100]);
                v["nodes"][15]["parentId"] = 1.into();
                let children = v["nodes"][0]["children"].as_array_mut().unwrap();
                children.push(16.into());
                children.sort_by_key(|x| x.as_u64());
            }),
        ),
        (
            "list-parent-kind",
            Box::new(|v| {
                v["nodes"][10]["children"] = serde_json::json!([13]);
                v["nodes"][11]["parentId"] = 1.into();
                let children = v["nodes"][0]["children"].as_array_mut().unwrap();
                children.push(12.into());
                children.sort_by_key(|x| x.as_u64());
            }),
        ),
        (
            "header-kind",
            Box::new(|v| v["nodes"][1]["data"]["headerIds"] = serde_json::json!([3])),
        ),
        (
            "footer-kind",
            Box::new(|v| v["nodes"][1]["data"]["footerIds"] = serde_json::json!([3])),
        ),
        (
            "footnote-flow-kind",
            Box::new(|v| v["nodes"][21]["data"]["bodyFlowId"] = 4.into()),
        ),
        (
            "section-reference-order",
            Box::new(|v| {
                let mut header = v["nodes"][22].clone();
                header["id"] = 27.into();
                v["nodes"].as_array_mut().unwrap().push(header);
                v["nodes"][0]["children"]
                    .as_array_mut()
                    .unwrap()
                    .push(27.into());
                v["nodes"][1]["data"]["headerIds"] = serde_json::json!([27, 23]);
            }),
        ),
        (
            "dangling-source",
            Box::new(|v| v["nodes"][5]["sourceSpans"][0]["sourceId"] = 99.into()),
        ),
        (
            "dangling-resource",
            Box::new(|v| v["nodes"][16]["data"]["resourceId"] = 99.into()),
        ),
        (
            "dangling-comment",
            Box::new(|v| v["nodes"][5]["data"]["commentIds"] = serde_json::json!([99])),
        ),
        (
            "annotation-reference-order",
            Box::new(|v| {
                let mut comment = v["annotations"]["comments"][0].clone();
                comment["id"] = 2.into();
                v["annotations"]["comments"]
                    .as_array_mut()
                    .unwrap()
                    .push(comment);
                v["nodes"][5]["data"]["commentIds"] = serde_json::json!([2, 1]);
            }),
        ),
        (
            "table-grid-span",
            Box::new(|v| {
                v["nodes"][13]["data"]["gridWidths"] = serde_json::json!([100]);
                v["nodes"][13]["data"]["sourceColumnWidths"] = serde_json::json!([100]);
            }),
        ),
        (
            "table-overlap",
            Box::new(|v| {
                let mut cell = v["nodes"][15].clone();
                cell["id"] = 27.into();
                cell["data"]["column"] = 1.into();
                cell["data"]["columnSpan"] = 1.into();
                v["nodes"][14]["children"]
                    .as_array_mut()
                    .unwrap()
                    .push(27.into());
                v["nodes"].as_array_mut().unwrap().push(cell);
            }),
        ),
        (
            "table-row-coordinate",
            Box::new(|v| v["nodes"][14]["data"]["row"] = 1.into()),
        ),
        (
            "table-cell-row-coordinate",
            Box::new(|v| v["nodes"][15]["data"]["row"] = 1.into()),
        ),
        (
            "table-row-span-bounds",
            Box::new(|v| v["nodes"][15]["data"]["rowSpan"] = 2.into()),
        ),
        (
            "table-grid-hole",
            Box::new(|v| v["nodes"][15]["data"]["columnSpan"] = 1.into()),
        ),
        (
            "table-cell-order",
            Box::new(|v| {
                v["nodes"][15]["data"]["columnSpan"] = 1.into();
                let mut cell = v["nodes"][15].clone();
                cell["id"] = 100.into();
                cell["data"]["column"] = 1.into();
                v["nodes"].as_array_mut().unwrap().push(cell);
                v["nodes"][14]["children"] = serde_json::json!([100, 16]);
            }),
        ),
        (
            "list-level",
            Box::new(|v| v["nodes"][11]["data"]["level"] = 33.into()),
        ),
        (
            "source-domain",
            Box::new(|v| v["sources"][0]["kind"] = "originalFile".into()),
        ),
        (
            "source-text-hash",
            Box::new(|v| v["sources"][0]["sha256"] = "0".repeat(64).into()),
        ),
        (
            "source-text-length",
            Box::new(|v| v["sources"][0]["utf16Length"] = 3.into()),
        ),
        (
            "source-text-missing",
            Box::new(|v| {
                v["sources"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("textContent");
            }),
        ),
        (
            "byte-source-bounds",
            Box::new(|v| v["nodes"][3]["sourceSpans"][0]["segments"][0]["end"] = 11.into()),
        ),
        (
            "source-bounds",
            Box::new(|v| v["nodes"][5]["sourceSpans"][0]["segments"][0]["utf8End"] = 99.into()),
        ),
        (
            "utf8-boundary",
            Box::new(|v| v["nodes"][5]["sourceSpans"][0]["segments"][0]["utf8End"] = 2.into()),
        ),
        (
            "utf16-boundary",
            Box::new(|v| v["nodes"][5]["sourceSpans"][0]["segments"][0]["utf16End"] = 3.into()),
        ),
        (
            "segment-order",
            Box::new(|v| {
                v["nodes"][5]["sourceSpans"][0]["segments"].as_array_mut().unwrap().push(
                serde_json::json!({"kind":"text","utf8Start":0,"utf8End":1,"utf16Start":0,"utf16End":1}));
            }),
        ),
        (
            "edit-revision",
            Box::new(|v| v["nodes"][5]["edit"]["revision"] = "wrong".into()),
        ),
        (
            "editable-global-overlap",
            Box::new(|v| {
                let span = v["nodes"][5]["sourceSpans"][0].clone();
                v["nodes"][5]["sourceSpans"]
                    .as_array_mut()
                    .unwrap()
                    .push(span);
            }),
        ),
        (
            "editable-mixed-source",
            Box::new(|v| {
                v["nodes"][5]["sourceSpans"].as_array_mut().unwrap().push(
                serde_json::json!({"sourceId":2,"purpose":"editable","affinity":"exact","segments":[{"kind":"byte","start":0,"end":1}]}))
            }),
        ),
        (
            "editable-without-metadata",
            Box::new(|v| {
                v["nodes"][5].as_object_mut().unwrap().remove("edit");
            }),
        ),
        (
            "noneditable-with-editable-spans",
            Box::new(|v| v["nodes"][5]["edit"] = serde_json::json!({"editable":false})),
        ),
        (
            "edit-affinity",
            Box::new(|v| v["nodes"][5]["sourceSpans"][0]["affinity"] = "covering".into()),
        ),
        (
            "edit-source-missing",
            Box::new(|v| {
                v["nodes"][5]["edit"]
                    .as_object_mut()
                    .unwrap()
                    .remove("sourceId");
            }),
        ),
        (
            "edit-exact-cover",
            Box::new(|v| v["nodes"][5]["data"]["text"] = "different".into()),
        ),
        (
            "resource-base64",
            Box::new(|v| v["resources"][0]["bytesBase64"] = "%%%".into()),
        ),
        (
            "resource-length",
            Box::new(|v| v["resources"][0]["byteLength"] = 4.into()),
        ),
        (
            "resource-sha",
            Box::new(|v| v["resources"][0]["sha256"] = "0".repeat(64).into()),
        ),
        (
            "resource-mime",
            Box::new(|v| v["resources"][0]["mimeType"] = "invalid".into()),
        ),
        (
            "resource-mime-token",
            Box::new(|v| v["resources"][0]["mimeType"] = "image/???".into()),
        ),
        (
            "resource-dimension",
            Box::new(|v| v["resources"][0]["intrinsicSize"]["width"] = (-1).into()),
        ),
        (
            "unsupported-provenance",
            Box::new(|v| v["nodes"][25]["data"]["reason"] = "".into()),
        ),
        (
            "document-editability",
            Box::new(|v| v["document"]["editable"] = false.into()),
        ),
        (
            "feature-flag-order",
            Box::new(|v| {
                v["nodes"][5]["data"]["style"]["featureFlags"] = serde_json::json!(["z", "a"])
            }),
        ),
        (
            "underline-color-without-underline",
            Box::new(|v| v["nodes"][5]["data"]["style"]["underline"] = Value::Null),
        ),
        (
            "strike-color-without-strike",
            Box::new(|v| v["nodes"][5]["data"]["style"]["strike"] = false.into()),
        ),
        (
            "underline-color-component",
            Box::new(|v| v["nodes"][5]["data"]["style"]["underlineColor"]["red"] = 2.into()),
        ),
        (
            "color-space-missing",
            Box::new(|v| {
                v["nodes"][5]["data"]["style"]["foreground"]
                    .as_object_mut()
                    .unwrap()
                    .remove("space");
            }),
        ),
        (
            "color-space-unknown",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["space"] = "cmyk".into()),
        ),
        (
            "color-red-below-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["red"] = (-0.1).into()),
        ),
        (
            "color-red-above-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["red"] = 1.1.into()),
        ),
        (
            "color-green-below-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["green"] = (-0.1).into()),
        ),
        (
            "color-green-above-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["green"] = 1.1.into()),
        ),
        (
            "color-blue-below-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["blue"] = (-0.1).into()),
        ),
        (
            "color-blue-above-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["blue"] = 1.1.into()),
        ),
        (
            "color-alpha-below-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["alpha"] = (-0.1).into()),
        ),
        (
            "color-alpha-above-range",
            Box::new(|v| v["nodes"][5]["data"]["style"]["foreground"]["alpha"] = 1.1.into()),
        ),
        (
            "negative-tab-position",
            Box::new(|v| v["nodes"][4]["data"]["tabStops"][0]["positionPoints"] = (-1).into()),
        ),
        (
            "duplicate-tab-position",
            Box::new(|v| {
                let tab = v["nodes"][4]["data"]["tabStops"][0].clone();
                v["nodes"][4]["data"]["tabStops"]
                    .as_array_mut()
                    .unwrap()
                    .push(tab);
            }),
        ),
        (
            "border-declaration-kind-missing",
            Box::new(|v| {
                v["nodes"][15]["data"]["directEdgeBorders"]["top"] = serde_json::json!({
                    "widthPoints": 1,
                    "style": "solid",
                    "color": { "red": 0, "green": 0, "blue": 0, "alpha": 1, "space": "sRGB" }
                });
            }),
        ),
        (
            "border-style-unknown",
            Box::new(|v| {
                v["nodes"][4]["data"]["style"]["borders"]["top"]["value"]["style"] = "groove".into()
            }),
        ),
        (
            "border-width-negative",
            Box::new(|v| {
                v["nodes"][15]["data"]["directEdgeBorders"]["left"]["value"]["widthPoints"] =
                    (-1).into()
            }),
        ),
        (
            "paragraph-border-inside-edge",
            Box::new(|v| {
                v["nodes"][4]["data"]["style"]["borders"]["insideHorizontal"] =
                    serde_json::json!({"kind": "suppressed"});
            }),
        ),
        (
            "cell-padding-negative",
            Box::new(|v| v["nodes"][15]["data"]["edgePadding"]["right"] = (-1).into()),
        ),
        (
            "diagonal-width-negative",
            Box::new(|v| v["nodes"][15]["data"]["diagonal"]["side"]["widthPoints"] = (-1).into()),
        ),
        (
            "direct-uniform-border-empty",
            Box::new(|v| v["nodes"][15]["data"]["directUniformBorder"] = serde_json::json!({})),
        ),
        (
            "style-uniform-border-empty",
            Box::new(|v| v["nodes"][15]["data"]["styleUniformBorder"] = serde_json::json!({})),
        ),
        (
            "uniform-border-width-negative",
            Box::new(|v| {
                v["nodes"][15]["data"]["directUniformBorder"]["widthPoints"] = (-1).into()
            }),
        ),
        (
            "declared-cell-width-negative",
            Box::new(|v| v["nodes"][15]["data"]["declaredWidthPoints"] = (-1).into()),
        ),
        (
            "uniform-padding-negative",
            Box::new(|v| v["nodes"][15]["data"]["uniformPaddingPoints"] = (-1).into()),
        ),
        (
            "header-rows-exceed",
            Box::new(|v| v["nodes"][13]["data"]["headerRows"] = 2.into()),
        ),
        (
            "source-column-width-count",
            Box::new(|v| v["nodes"][13]["data"]["sourceColumnWidths"] = serde_json::json!([100])),
        ),
        (
            "source-column-width-negative",
            Box::new(|v| v["nodes"][13]["data"]["sourceColumnWidths"][0] = (-1).into()),
        ),
        (
            "table-source-width-negative",
            Box::new(|v| v["nodes"][13]["data"]["style"]["sourceWidthPoints"] = (-1).into()),
        ),
        (
            "table-default-padding-negative",
            Box::new(|v| v["nodes"][13]["data"]["style"]["defaultPadding"]["left"] = (-1).into()),
        ),
        (
            "table-edge-border-width-negative",
            Box::new(|v| {
                v["nodes"][13]["data"]["style"]["edgeBorders"]["top"]["value"]["widthPoints"] =
                    (-1).into()
            }),
        ),
        (
            "table-policy-unknown",
            Box::new(|v| v["nodes"][13]["data"]["style"]["pageBreakPolicy"] = "rowMaybe".into()),
        ),
        (
            "old-wire-table",
            Box::new(|v| {
                v["nodes"][13]["data"] = serde_json::json!({
                    "gridWidths": [100, 100], "alignment": "center", "preferredWidth": 200
                })
            }),
        ),
        (
            "old-wire-table-cell",
            Box::new(|v| {
                v["nodes"][15]["data"] = serde_json::json!({
                    "row": 0, "column": 0, "rowSpan": 1, "columnSpan": 2,
                    "borders": { "top": null, "right": null, "bottom": null, "left": null },
                    "padding": { "top": 1, "right": 1, "bottom": 1, "left": 1 },
                    "fill": null, "verticalAlignment": "middle"
                });
            }),
        ),
    ];
    let ids: BTreeSet<_> = mutations.iter().map(|(id, _)| *id).collect();
    assert_eq!(ids.len(), mutations.len(), "duplicate mutation IDs");
    assert_eq!(mutations.len(), 103, "mutation inventory drifted");
    let mut killed = 0;
    for (id, mutate) in mutations {
        let mut value = exhaustive_value();
        mutate(&mut value);
        let error = decode_value(&value).expect_err(&format!("mutation survived: {id}"));
        assert!(
            error.detail().contains(expected_detail(id)),
            "mutation {id} hit the wrong branch: {error:?}"
        );
        killed += 1;
    }
    assert_eq!(killed, 103);
}

fn expected_detail(id: &str) -> &'static str {
    match id {
        "schema-version" => "schema version",
        "representation" | "unknown-tag" => "unknown variant",
        "zero-node-id" | "duplicate-node-id" | "node-order" => "node IDs",
        "zero-source-id" | "duplicate-source-id" => "source IDs",
        "unlisted-source" => "unlisted document source",
        "document-source-order" => "document source IDs",
        "zero-resource-id" | "duplicate-resource-id" => "resource IDs",
        "duplicate-resource-hash" => "duplicate content-addressed resource hash",
        "zero-comment-id" | "duplicate-comment-id" => "comment IDs",
        "zero-bookmark-id" | "duplicate-bookmark-id" => "bookmark IDs",
        "missing-root" => "root node is missing",
        "multiple-roots" => "exactly one parentless",
        "child-parent-order" => "child is absent from parent ordering",
        "parent-disagreement" => "parent/child relationship disagrees",
        "row-parent-kind" | "cell-parent-kind" | "list-parent-kind" => {
            "invalid for its parent kind"
        }
        "header-kind" | "footer-kind" => "header/footer is missing",
        "footnote-flow-kind" => "wrong kind",
        "section-reference-order" => "section header IDs",
        "cycle" => "cycle",
        "duplicate-edge" => "duplicate child edges",
        "dangling-source" => "span source is missing",
        "dangling-resource" => "node resource is missing",
        "dangling-comment" => "annotation is missing",
        "annotation-reference-order" => "text run comment IDs",
        "table-grid-span" => "exceeds table grid",
        "table-overlap" => "table cells overlap",
        "table-row-coordinate" => "row coordinates are not contiguous",
        "table-cell-row-coordinate" => "cell row coordinate differs",
        "table-row-span-bounds" => "row span exceeds",
        "table-grid-hole" => "uncovered cell coordinate",
        "table-cell-order" => "not in canonical column order",
        "list-level" => "list level is invalid",
        "source-domain" => "binary source carries text",
        "source-text-hash" | "source-text-length" => "length/hash differs",
        "source-text-missing" => "no canonical content",
        "byte-source-bounds" => "byte source range is invalid",
        "source-bounds" | "utf8-boundary" => "UTF-8 source range is invalid",
        "utf16-boundary" => "UTF-16 source range is invalid",
        "segment-order" => "UTF-8 source range is invalid",
        "edit-revision" => "source/revision differs",
        "editable-global-overlap" => "globally out of order",
        "editable-mixed-source" => "mix source domains",
        "editable-without-metadata" => "no edit metadata",
        "noneditable-with-editable-spans" => "editable source spans",
        "edit-affinity" => "affinity is not exact",
        "edit-source-missing" => "editable node has no source",
        "edit-exact-cover" => "do not exactly cover",
        "resource-base64" => "base64 is invalid",
        "resource-length" | "resource-sha" => "length/hash differs",
        "resource-mime" => "hash or MIME is invalid",
        "resource-mime-token" => "hash or MIME is invalid",
        "resource-dimension" => "intrinsic size is invalid",
        "unsupported-provenance" => "provenance is empty",
        "document-editability" => "invalid editable source authority",
        "feature-flag-order" => "feature flags are not canonical",
        "underline-color-without-underline" => "underline color exists while underline is off",
        "underline-color-component" => "color component is invalid at underlineColor",
        "color-red-below-range"
        | "color-red-above-range"
        | "color-green-below-range"
        | "color-green-above-range"
        | "color-blue-below-range"
        | "color-blue-above-range"
        | "color-alpha-below-range"
        | "color-alpha-above-range" => "color component is invalid at foreground",
        "color-space-missing" => "missing field",
        "color-space-unknown" => "unknown variant",
        "strike-color-without-strike" => "strikethrough color exists while strike is off",
        "negative-tab-position" | "duplicate-tab-position" => {
            "tab stops are not finite strictly increasing"
        }
        "border-declaration-kind-missing" => "missing field",
        "old-wire-table-cell" => "unknown field",
        "border-style-unknown" => "unknown variant",
        "border-width-negative" | "diagonal-width-negative" => "border width is invalid",
        "paragraph-border-inside-edge" => "may not declare inside edges",
        "cell-padding-negative" => "cell padding is invalid",
        "direct-uniform-border-empty" | "style-uniform-border-empty" => "uniform border is empty",
        "uniform-border-width-negative" => "uniform border width is invalid",
        "declared-cell-width-negative" | "uniform-padding-negative" => {
            "table cell source metric is invalid"
        }
        "header-rows-exceed" => "header row count exceeds",
        "source-column-width-count" | "source-column-width-negative" => {
            "source column widths are invalid"
        }
        "table-source-width-negative" => "table source width is invalid",
        "table-default-padding-negative" => "cell padding is invalid",
        "table-edge-border-width-negative" => "border width is invalid",
        "table-policy-unknown" => "unknown variant",
        "old-wire-table" => "missing field",
        other => panic!("mutation has no expected branch: {other}"),
    }
}
