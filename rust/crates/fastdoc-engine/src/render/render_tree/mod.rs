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
    Affinity, Alignment, Annotations as RenderAnnotationsDraft, Bookmark, CharacterStyle,
    CodeBlock, Color, Columns, Comment, Diagram, DiagramLanguage, Direction,
    Document as RenderDocumentDraft, DocumentFormat, Edge, EdgeSet, EditMetadata, EditOperation,
    Empty, Field, Footnote, FormControl, FormControlKind, Formula, Heading, Image,
    InlineFormControl, Insets, LineBreak, LineBreakGranularity, LineBreakKind, LineHeight, List,
    ListItem, ListNumberingGlyphs, Node as RenderNodeDraft, NodePayload, Numbering,
    PageNumberField, PageNumbering, Paper, Paragraph, ParagraphStyle, PathCommand, RangeSegment,
    RawHtml, Resource as RenderResourceDraft, Section, Size, SourceDescriptor as RenderSourceDraft,
    SourceKind, SourceSpan, SpanPurpose, TabAlignment, TabLeader, TabStop, Table, TableCell,
    TableRow, TaskListItem, TextRun, UnderlineStyle, Unsupported, Vector, VerticalAlignment,
    VerticalPosition,
};

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
    use super::wire;

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
