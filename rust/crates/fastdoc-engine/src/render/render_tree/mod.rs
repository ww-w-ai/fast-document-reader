//! Canonical, format-neutral semantic document boundary.
//!
//! S2A1 owns schema version 1. Wire values stay private until validation succeeds.
//!
//! Reference provenance: the page/node/bounding-box hierarchy was evaluated from
//! `Vendor/rhwp-src/src/renderer/render_tree.rs` at
//! `0f7fc78164ab87059f3fd288945d36c0fd86ce6a` (MIT). This module adapts only the proven
//! backend-neutral hierarchy principle. Its flat ID graph, all-format payloads, checked wire model,
//! source/edit authority, and immutable canonical owner are FastDoc-specific divergences.

mod office_accounting;
mod validate;
// Internal producers (S2A2/S3) may construct unchecked wire drafts, but no downstream crate can.
pub(crate) mod wire;

pub use wire::{
    Affinity, Alignment, Annotations as RenderAnnotationsDraft, Bookmark, BorderDeclaration,
    BorderLineStyle, BorderSet, CellDiagonal, CellDiagonalDirection, CharacterStyle, CodeBlock,
    Color, ColorSpace, Columns, Comment, Diagram, DiagramLanguage, Direction,
    Document as RenderDocumentDraft, DocumentFormat, DrawnBorder, EditMetadata, EditOperation,
    Empty, Field, Footnote, FormControl, FormControlKind, Formula, Heading, Image,
    InlineFormControl, Insets, LineBreak, LineBreakGranularity, LineBreakKind, LineHeight, List,
    ListItem, ListNumberingGlyphs, Node as RenderNodeDraft, NodePayload, Numbering, OptionalInsets,
    PageNumberField, PageNumbering, Paper, Paragraph, ParagraphStyle, PathCommand, RangeSegment,
    RawHtml, Resource as RenderResourceDraft, Section, Size, SourceDescriptor as RenderSourceDraft,
    SourceKind, SourceSpan, SpanPurpose, TabAlignment, TabLeader, TabStop, Table, TableCell,
    TablePageBreakPolicy, TableRow, TableStyle, TaskListItem, TextRun, UnderlineStyle,
    UniformBorder, Unsupported, Vector, VerticalAlignment, VerticalPosition,
};

pub use validate::{resolve_cell_borders, resolve_cell_padding, CellSide, ResolvedEdge};

/// A semantic RenderTree whose complete wire graph has passed canonical validation.
#[derive(Debug, Clone)]
pub struct ValidatedRenderTree {
    inner: wire::EnvelopeV1,
}

/// Typed unchecked drafts for engine producers. `build` is the only canonicalization step.
pub struct RenderTreeBuilder {
    engine_version: String,
    document: RenderDocumentDraft,
    sources: Vec<RenderSourceDraft>,
    nodes: Vec<RenderNodeDraft>,
    resources: Vec<RenderResourceDraft>,
    annotations: RenderAnnotationsDraft,
}

impl RenderTreeBuilder {
    pub fn new(engine_version: impl Into<String>, document: RenderDocumentDraft) -> Self {
        Self {
            engine_version: engine_version.into(),
            document,
            sources: Vec::new(),
            nodes: Vec::new(),
            resources: Vec::new(),
            annotations: RenderAnnotationsDraft::default(),
        }
    }

    pub fn add_source(&mut self, source: RenderSourceDraft) {
        self.sources.push(source);
    }
    pub fn add_node(&mut self, node: RenderNodeDraft) {
        self.nodes.push(node);
    }
    pub fn add_resource(&mut self, resource: RenderResourceDraft) {
        self.resources.push(resource);
    }
    pub fn add_comment(&mut self, comment: Comment) {
        self.annotations.comments.push(comment);
    }
    pub fn add_bookmark(&mut self, bookmark: Bookmark) {
        self.annotations.bookmarks.push(bookmark);
    }

    pub fn build(mut self) -> Result<ValidatedRenderTree, DecodeError> {
        self.sources.sort_by_key(|value| value.id);
        self.nodes.sort_by_key(|value| value.id);
        self.resources.sort_by_key(|value| value.id);
        self.annotations.comments.sort_by_key(|value| value.id);
        self.annotations.bookmarks.sort_by_key(|value| value.id);
        self.document.source_ids = self.sources.iter().map(|value| value.id).collect();
        ValidatedRenderTree::try_from_wire(wire::EnvelopeV1 {
            schema_version: 1,
            representation: wire::Representation::Semantic,
            producer: wire::Producer {
                engine_version: self.engine_version,
                schema_version: 1,
            },
            document: self.document,
            sources: self.sources,
            nodes: self.nodes,
            resources: self.resources,
            annotations: self.annotations,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{validate, wire};

    #[test]
    fn every_macro_authoritative_enum_value_round_trips() {
        wire::assert_all_enum_round_trips();
    }

    fn fixture() -> wire::EnvelopeV1 {
        serde_json::from_slice(include_bytes!(
            "../../../tests/fixtures/render-tree-v1-exhaustive.json"
        ))
        .unwrap()
    }

    fn assert_invariant(wire: wire::EnvelopeV1, expected: &str) {
        let error = super::ValidatedRenderTree::try_from_wire(wire).unwrap_err();
        assert!(
            error.detail().contains(expected),
            "expected {expected:?}, got {error:?}"
        );
    }

    #[test]
    fn typed_non_finite_s2a1b_metrics_reach_their_validator_branches() {
        let mut letter = fixture();
        let wire::NodePayload::TextRun(run) = &mut letter.nodes[5].payload else {
            unreachable!()
        };
        run.style.letter_spacing_percent = Some(f64::NAN);
        assert_invariant(letter, "character metric is invalid");

        let mut baseline = fixture();
        let wire::NodePayload::TextRun(run) = &mut baseline.nodes[5].payload else {
            unreachable!()
        };
        run.style.baseline_offset_percent = Some(f64::INFINITY);
        assert_invariant(baseline, "character metric is invalid");

        let mut list_distance = fixture();
        let wire::NodePayload::Paragraph(paragraph) = &mut list_distance.nodes[4].payload else {
            unreachable!()
        };
        paragraph.style.list_text_distance = Some(f64::NAN);
        assert_invariant(list_distance, "paragraph metric is invalid");

        let mut hanging = fixture();
        let wire::NodePayload::Paragraph(paragraph) = &mut hanging.nodes[4].payload else {
            unreachable!()
        };
        paragraph.style.hanging_indent = Some(f64::NEG_INFINITY);
        assert_invariant(hanging, "paragraph metric is invalid");

        let mut tab = fixture();
        let wire::NodePayload::Paragraph(paragraph) = &mut tab.nodes[4].payload else {
            unreachable!()
        };
        paragraph.tab_stops[0].position_points = f64::NAN;
        assert_invariant(tab, "tab stops are not finite strictly increasing");
    }

    fn set_channel(color: &mut wire::Color, channel: usize, value: f64) {
        match channel {
            0 => color.red = value,
            1 => color.green = value,
            _ => color.blue = value,
        }
    }

    #[test]
    fn typed_non_finite_colors_reach_their_validator_branch_across_categories() {
        for (channel, value) in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY]
            .into_iter()
            .enumerate()
        {
            let mut character = fixture();
            let wire::NodePayload::TextRun(run) = &mut character.nodes[5].payload else {
                unreachable!()
            };
            set_channel(run.style.foreground.as_mut().unwrap(), channel, value);
            assert_invariant(character, "color component is invalid at foreground");

            let mut paragraph_edge = fixture();
            let wire::NodePayload::Paragraph(paragraph) = &mut paragraph_edge.nodes[4].payload
            else {
                unreachable!()
            };
            let borders = paragraph.style.borders.as_mut().unwrap();
            let wire::BorderDeclaration::Drawn(top) = borders.top.as_mut().unwrap() else {
                unreachable!()
            };
            set_channel(top.color.as_mut().unwrap(), channel, value);
            assert_invariant(
                paragraph_edge,
                "color component is invalid at borders/top/color",
            );

            let mut table_cell = fixture();
            let wire::NodePayload::TableCell(cell) = &mut table_cell.nodes[15].payload else {
                unreachable!()
            };
            set_channel(cell.direct_shading.as_mut().unwrap(), channel, value);
            assert_invariant(table_cell, "color component is invalid at directShading");

            let mut table_cell_inside = fixture();
            let wire::NodePayload::TableCell(cell) = &mut table_cell_inside.nodes[15].payload
            else {
                unreachable!()
            };
            let wire::BorderDeclaration::Drawn(inside_h) = cell
                .direct_edge_borders
                .as_mut()
                .unwrap()
                .inside_horizontal
                .as_mut()
                .unwrap()
            else {
                unreachable!()
            };
            set_channel(inside_h.color.as_mut().unwrap(), channel, value);
            assert_invariant(
                table_cell_inside,
                "color component is invalid at borders/insideHorizontal/color",
            );

            let mut table_cell_diagonal = fixture();
            let wire::NodePayload::TableCell(cell) = &mut table_cell_diagonal.nodes[15].payload
            else {
                unreachable!()
            };
            set_channel(
                cell.diagonal.as_mut().unwrap().side.color.as_mut().unwrap(),
                channel,
                value,
            );
            assert_invariant(
                table_cell_diagonal,
                "color component is invalid at diagonal/side/color",
            );
        }
    }

    #[test]
    fn typed_non_finite_border_padding_and_diagonal_metrics_reach_their_validator_branches() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut border_width = fixture();
            let wire::NodePayload::TableCell(cell) = &mut border_width.nodes[15].payload else {
                unreachable!()
            };
            let wire::BorderDeclaration::Drawn(left) = cell
                .direct_edge_borders
                .as_mut()
                .unwrap()
                .left
                .as_mut()
                .unwrap()
            else {
                unreachable!()
            };
            left.width_points = value;
            assert_invariant(border_width, "border width is invalid");

            let mut padding = fixture();
            let wire::NodePayload::TableCell(cell) = &mut padding.nodes[15].payload else {
                unreachable!()
            };
            cell.edge_padding.as_mut().unwrap().right = Some(value);
            assert_invariant(padding, "cell padding is invalid");

            let mut diagonal = fixture();
            let wire::NodePayload::TableCell(cell) = &mut diagonal.nodes[15].payload else {
                unreachable!()
            };
            cell.diagonal.as_mut().unwrap().side.width_points = value;
            assert_invariant(diagonal, "border width is invalid");
        }
    }

    #[test]
    fn typed_non_finite_table_source_layer_metrics_reach_their_validator_branches() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut direct_uniform = fixture();
            let wire::NodePayload::TableCell(cell) = &mut direct_uniform.nodes[15].payload else {
                unreachable!()
            };
            cell.direct_uniform_border.as_mut().unwrap().width_points = Some(value);
            assert_invariant(direct_uniform, "uniform border width is invalid");

            let mut style_uniform = fixture();
            let wire::NodePayload::TableCell(cell) = &mut style_uniform.nodes[15].payload else {
                unreachable!()
            };
            cell.style_uniform_border.as_mut().unwrap().width_points = Some(value);
            assert_invariant(style_uniform, "uniform border width is invalid");

            let mut declared_width = fixture();
            let wire::NodePayload::TableCell(cell) = &mut declared_width.nodes[15].payload else {
                unreachable!()
            };
            cell.declared_width_points = Some(value);
            assert_invariant(declared_width, "table cell source metric is invalid");

            let mut uniform_padding = fixture();
            let wire::NodePayload::TableCell(cell) = &mut uniform_padding.nodes[15].payload else {
                unreachable!()
            };
            cell.uniform_padding_points = Some(value);
            assert_invariant(uniform_padding, "table cell source metric is invalid");

            let mut source_column = fixture();
            let wire::NodePayload::Table(table) = &mut source_column.nodes[13].payload else {
                unreachable!()
            };
            table.source_column_widths[0] = value;
            assert_invariant(source_column, "table source column widths are invalid");

            let mut default_uniform = fixture();
            let wire::NodePayload::Table(table) = &mut default_uniform.nodes[13].payload else {
                unreachable!()
            };
            table
                .style
                .default_uniform_border
                .as_mut()
                .unwrap()
                .width_points = Some(value);
            assert_invariant(default_uniform, "uniform border width is invalid");

            let mut source_width = fixture();
            let wire::NodePayload::Table(table) = &mut source_width.nodes[13].payload else {
                unreachable!()
            };
            table.style.source_width_points = Some(value);
            assert_invariant(source_width, "table source width is invalid");

            let mut outer_margin = fixture();
            let wire::NodePayload::Table(table) = &mut outer_margin.nodes[13].payload else {
                unreachable!()
            };
            table.style.outer_margin.as_mut().unwrap().top = Some(value);
            assert_invariant(outer_margin, "table outer margin is invalid");
        }
    }

    #[test]
    fn color_occurrence_visitor_finds_the_exact_stable_path_set_in_the_exhaustive_fixture() {
        let tree = fixture();
        let wire::NodePayload::TextRun(run) = &tree.nodes[5].payload else {
            unreachable!()
        };
        let wire::NodePayload::Paragraph(paragraph) = &tree.nodes[4].payload else {
            unreachable!()
        };
        let wire::NodePayload::TableCell(cell) = &tree.nodes[15].payload else {
            unreachable!()
        };
        let wire::NodePayload::Table(table) = &tree.nodes[13].payload else {
            unreachable!()
        };

        let mut occurrences: Vec<(&str, &str)> = validate::character_style_colors(&run.style)
            .into_iter()
            .filter_map(|(path, color)| color.map(|_| ("character", path)))
            .chain(
                validate::paragraph_style_colors(&paragraph.style)
                    .into_iter()
                    .filter_map(|(path, color)| color.map(|_| ("paragraph", path))),
            )
            .chain(
                validate::table_cell_colors(cell)
                    .into_iter()
                    .filter_map(|(path, color)| color.map(|_| ("tableCell", path))),
            )
            .chain(
                validate::table_colors(table)
                    .into_iter()
                    .filter_map(|(path, color)| color.map(|_| ("table", path))),
            )
            .collect();
        occurrences.sort();

        assert_eq!(
            occurrences,
            vec![
                ("character", "background"),
                ("character", "foreground"),
                ("character", "strikethroughColor"),
                ("character", "underlineColor"),
                ("paragraph", "borders/top/color"),
                ("paragraph", "shading"),
                ("table", "borders/bottom/color"),
                ("table", "borders/insideHorizontal/color"),
                ("table", "borders/insideVertical/color"),
                ("table", "borders/left/color"),
                ("table", "borders/right/color"),
                ("table", "borders/top/color"),
                ("table", "style/defaultShading"),
                ("table", "style/defaultUniformBorder/color"),
                ("tableCell", "borders/bottom/color"),
                ("tableCell", "borders/insideHorizontal/color"),
                ("tableCell", "borders/insideVertical/color"),
                ("tableCell", "borders/left/color"),
                ("tableCell", "borders/right/color"),
                ("tableCell", "borders/top/color"),
                ("tableCell", "diagonal/side/color"),
                ("tableCell", "directShading"),
                ("tableCell", "directUniformBorder/color"),
                ("tableCell", "styleShading"),
                ("tableCell", "styleUniformBorder/color"),
            ]
        );
    }
}

/// Checked decode failures. The implementation distinguishes syntax, version/tag, and invariants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    Syntax(String),
    Schema(String),
    Invariant(String),
}

impl DecodeError {
    pub fn detail(&self) -> &str {
        match self {
            Self::Syntax(value) | Self::Schema(value) | Self::Invariant(value) => value,
        }
    }
}

impl ValidatedRenderTree {
    /// Decode JSON through the private wire model and canonical validator.
    pub fn decode_json(bytes: &[u8]) -> Result<Self, DecodeError> {
        let wire = serde_json::from_slice(bytes).map_err(|error| {
            let message = error.to_string();
            if message.contains("unknown variant") {
                DecodeError::Schema(message)
            } else {
                DecodeError::Syntax(message)
            }
        })?;
        Self::try_from_wire(wire)
    }

    pub fn encode_json(&self) -> Result<Vec<u8>, DecodeError> {
        serde_json::to_vec(&self.inner).map_err(|error| DecodeError::Invariant(error.to_string()))
    }

    pub fn schema_version(&self) -> u32 {
        self.inner.schema_version
    }

    pub(crate) fn try_from_wire(wire: wire::EnvelopeV1) -> Result<Self, DecodeError> {
        validate::validate(&wire)?;
        Ok(Self { inner: wire })
    }

    pub fn supported_node_tags() -> &'static [&'static str] {
        wire::NodePayload::ALL_TAGS
    }
    pub fn supported_enum_values() -> &'static [&'static [&'static str]] {
        wire::ALL_ENUM_VALUES
    }
    pub fn supported_enum_catalog() -> &'static [(&'static str, &'static [&'static str])] {
        wire::ALL_ENUM_CATALOG
    }
    pub fn node_tags(&self) -> Vec<&'static str> {
        self.inner
            .nodes
            .iter()
            .map(|node| node.payload.tag())
            .collect()
    }
}
