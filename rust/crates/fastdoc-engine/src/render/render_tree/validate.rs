//! Canonical graph, source, edit, and resource invariant validation.

use super::{wire, DecodeError};
use base64::Engine;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn validate(tree: &wire::EnvelopeV1) -> Result<(), DecodeError> {
    schema(tree)?;
    let sources = validate_sources(tree)?;
    let resources = validate_resources(tree)?;
    let (comments, bookmarks) = validate_annotations(tree)?;
    validate_nodes(tree, &sources, &resources, &comments, &bookmarks)
}

fn invalid(message: impl Into<String>) -> DecodeError {
    DecodeError::Invariant(message.into())
}

fn schema(tree: &wire::EnvelopeV1) -> Result<(), DecodeError> {
    if tree.schema_version != 1 || tree.producer.schema_version != 1 {
        return Err(DecodeError::Schema(
            "RenderTree schema version must be 1".into(),
        ));
    }
    if tree.producer.engine_version.is_empty() || tree.document.root_node_id == 0 {
        return Err(invalid("producer or root metadata is invalid"));
    }
    Ok(())
}

fn sorted_unique_nonzero<I>(values: I, label: &str) -> Result<(), DecodeError>
where
    I: IntoIterator<Item = u64>,
{
    let mut previous = 0;
    for value in values {
        if value == 0 || value <= previous {
            return Err(invalid(format!(
                "{label} IDs are not strictly increasing non-zero values"
            )));
        }
        previous = value;
    }
    Ok(())
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

fn validate_sources(
    tree: &wire::EnvelopeV1,
) -> Result<BTreeMap<u64, &wire::SourceDescriptor>, DecodeError> {
    sorted_unique_nonzero(tree.sources.iter().map(|s| s.id), "source")?;
    let map: BTreeMap<_, _> = tree.sources.iter().map(|s| (s.id, s)).collect();
    sorted_unique_nonzero(tree.document.source_ids.iter().copied(), "document source")?;
    if tree
        .document
        .source_ids
        .iter()
        .any(|id| !map.contains_key(id))
    {
        return Err(invalid("document references an unknown source"));
    }
    if tree
        .document
        .source_ids
        .iter()
        .copied()
        .collect::<BTreeSet<_>>()
        != map.keys().copied().collect::<BTreeSet<_>>()
    {
        return Err(invalid("source table contains an unlisted document source"));
    }
    for source in &tree.sources {
        if source.name.is_empty() || source.revision.is_empty() || !valid_hash(&source.sha256) {
            return Err(invalid("source metadata is incomplete"));
        }
        let text_kind = matches!(
            source.kind,
            wire::SourceKind::DecodedText | wire::SourceKind::LogicalText
        );
        if text_kind {
            let text = source
                .text_content
                .as_ref()
                .ok_or_else(|| invalid("text source has no canonical content"))?;
            let bytes = text.as_bytes();
            if source.byte_length != Some(bytes.len() as u64)
                || source.utf8_length != Some(bytes.len() as u64)
                || source.utf16_length != Some(text.encode_utf16().count() as u64)
                || source.sha256 != format!("{:x}", Sha256::digest(bytes))
            {
                return Err(invalid(
                    "text source length/hash differs from canonical UTF-8 content",
                ));
            }
        } else if source.text_content.is_some()
            || source.utf8_length.is_some()
            || source.utf16_length.is_some()
        {
            return Err(invalid("binary source carries text content/length"));
        } else if source.byte_length.is_none() {
            return Err(invalid("binary source has no byte length"));
        }
        if source.editable && (!text_kind || !tree.document.editable) {
            return Err(invalid("invalid editable source authority"));
        }
    }
    Ok(map)
}

fn finite_nonnegative(value: f64) -> bool {
    value.is_finite() && value >= 0.0
}
fn valid_size(size: &wire::Size) -> bool {
    finite_nonnegative(size.width) && finite_nonnegative(size.height)
}

fn validate_resources(
    tree: &wire::EnvelopeV1,
) -> Result<BTreeMap<u64, &wire::Resource>, DecodeError> {
    sorted_unique_nonzero(tree.resources.iter().map(|r| r.id), "resource")?;
    let mut hashes = BTreeMap::<&str, Vec<u8>>::new();
    for resource in &tree.resources {
        if !valid_hash(&resource.sha256) || !valid_mime(&resource.mime_type) {
            return Err(invalid("resource hash or MIME is invalid"));
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&resource.bytes_base64)
            .map_err(|_| invalid("resource base64 is invalid"))?;
        if bytes.len() as u64 != resource.byte_length
            || format!("{:x}", Sha256::digest(&bytes)) != resource.sha256
        {
            return Err(invalid("resource length/hash differs from embedded bytes"));
        }
        if resource
            .intrinsic_size
            .as_ref()
            .is_some_and(|s| !valid_size(s))
        {
            return Err(invalid("resource intrinsic size is invalid"));
        }
        if hashes.insert(&resource.sha256, bytes).is_some() {
            return Err(invalid("duplicate content-addressed resource hash"));
        }
    }
    Ok(tree.resources.iter().map(|r| (r.id, r)).collect())
}

fn valid_mime(value: &str) -> bool {
    let Some((kind, subtype)) = value.split_once('/') else {
        return false;
    };
    valid_mime_token(kind) && valid_mime_token(subtype)
}

fn valid_mime_token(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|b| {
            b.is_ascii_alphanumeric()
                || matches!(
                    b,
                    b'!' | b'#'
                        | b'$'
                        | b'%'
                        | b'&'
                        | b'\''
                        | b'*'
                        | b'+'
                        | b'-'
                        | b'.'
                        | b'^'
                        | b'_'
                        | b'`'
                        | b'|'
                        | b'~'
                )
        })
}

fn validate_annotations(
    tree: &wire::EnvelopeV1,
) -> Result<(BTreeSet<u64>, BTreeSet<u64>), DecodeError> {
    sorted_unique_nonzero(tree.annotations.comments.iter().map(|c| c.id), "comment")?;
    sorted_unique_nonzero(tree.annotations.bookmarks.iter().map(|b| b.id), "bookmark")?;
    if tree
        .annotations
        .comments
        .iter()
        .any(|c| c.author.is_empty() && c.text.is_empty())
        || tree.annotations.bookmarks.iter().any(|b| b.name.is_empty())
    {
        return Err(invalid("annotation content is empty"));
    }
    Ok((
        tree.annotations.comments.iter().map(|c| c.id).collect(),
        tree.annotations.bookmarks.iter().map(|b| b.id).collect(),
    ))
}

fn validate_nodes(
    tree: &wire::EnvelopeV1,
    sources: &BTreeMap<u64, &wire::SourceDescriptor>,
    resources: &BTreeMap<u64, &wire::Resource>,
    comments: &BTreeSet<u64>,
    bookmarks: &BTreeSet<u64>,
) -> Result<(), DecodeError> {
    sorted_unique_nonzero(tree.nodes.iter().map(|n| n.id), "node")?;
    let map: BTreeMap<_, _> = tree.nodes.iter().map(|n| (n.id, n)).collect();
    let root = map
        .get(&tree.document.root_node_id)
        .ok_or_else(|| invalid("root node is missing"))?;
    if root.parent_id.is_some()
        || !matches!(root.payload, wire::NodePayload::Document(_))
        || tree.nodes.iter().filter(|n| n.parent_id.is_none()).count() != 1
    {
        return Err(invalid(
            "tree does not have exactly one parentless document root",
        ));
    }
    for bookmark in &tree.annotations.bookmarks {
        if !map.contains_key(&bookmark.target_node_id) {
            return Err(invalid("bookmark target is missing"));
        }
    }
    for node in &tree.nodes {
        let unique: BTreeSet<_> = node.children.iter().copied().collect();
        if unique.len() != node.children.len() {
            return Err(invalid("node has duplicate child edges"));
        }
        for child_id in &node.children {
            let child = map
                .get(child_id)
                .ok_or_else(|| invalid("child node is missing"))?;
            if child.parent_id != Some(node.id) {
                return Err(invalid("parent/child relationship disagrees"));
            }
        }
        if let Some(parent_id) = node.parent_id {
            let parent = map
                .get(&parent_id)
                .ok_or_else(|| invalid("parent node is missing"))?;
            if !parent.children.contains(&node.id) {
                return Err(invalid("child is absent from parent ordering"));
            }
            validate_parent_kind(node, parent)?;
        }
        validate_spans(tree, node, sources)?;
        validate_payload(node, &map, resources, comments, bookmarks)?;
    }
    let mut cycle_visited = BTreeSet::new();
    for id in map.keys().copied() {
        let mut visiting = BTreeSet::new();
        detect_cycle(id, &map, &mut visiting, &mut cycle_visited)?;
    }
    let mut visited = BTreeSet::new();
    collect_reachable(tree.document.root_node_id, &map, &mut visited);
    if visited.len() != tree.nodes.len() {
        return Err(invalid("tree contains unreachable nodes"));
    }
    Ok(())
}

fn detect_cycle(
    id: u64,
    map: &BTreeMap<u64, &wire::Node>,
    visiting: &mut BTreeSet<u64>,
    visited: &mut BTreeSet<u64>,
) -> Result<(), DecodeError> {
    if visited.contains(&id) {
        return Ok(());
    }
    if !visiting.insert(id) {
        return Err(invalid("tree contains a cycle"));
    }
    for child in &map[&id].children {
        detect_cycle(*child, map, visiting, visited)?;
    }
    visiting.remove(&id);
    visited.insert(id);
    Ok(())
}

fn collect_reachable(id: u64, map: &BTreeMap<u64, &wire::Node>, visited: &mut BTreeSet<u64>) {
    if !visited.insert(id) {
        return;
    }
    for child in &map[&id].children {
        collect_reachable(*child, map, visited);
    }
}

fn validate_parent_kind(node: &wire::Node, parent: &wire::Node) -> Result<(), DecodeError> {
    use wire::NodePayload as P;
    let valid = match &node.payload {
        P::TableRow(_) => matches!(parent.payload, P::Table(_)),
        P::TableCell(_) => matches!(parent.payload, P::TableRow(_)),
        P::ListItem(_) | P::TaskListItem(_) => matches!(parent.payload, P::List(_)),
        _ => !matches!(parent.payload, P::Table(_) | P::TableRow(_) | P::List(_)),
    };
    if valid {
        Ok(())
    } else {
        Err(invalid("node kind is invalid for its parent kind"))
    }
}

fn validate_spans(
    tree: &wire::EnvelopeV1,
    node: &wire::Node,
    sources: &BTreeMap<u64, &wire::SourceDescriptor>,
) -> Result<(), DecodeError> {
    let mut editable_text = String::new();
    let mut editable_source = None;
    let mut previous_edit_end = 0u64;
    let mut editable_span_count = 0usize;
    for span in &node.source_spans {
        let source = sources
            .get(&span.source_id)
            .ok_or_else(|| invalid("span source is missing"))?;
        if span.segments.is_empty() {
            return Err(invalid("source span has no segments"));
        }
        if matches!(span.purpose, wire::SpanPurpose::Editable)
            && !matches!(span.affinity, wire::Affinity::Exact)
        {
            return Err(invalid("editable span affinity is not exact"));
        }
        if matches!(span.purpose, wire::SpanPurpose::Editable) {
            editable_span_count += 1;
            if editable_source.is_some_and(|id| id != span.source_id) {
                return Err(invalid("editable spans mix source domains"));
            }
            editable_source = Some(span.source_id);
        }
        let mut previous = (0, 0);
        for segment in &span.segments {
            match segment {
                wire::RangeSegment::Byte { start, end } => {
                    if source.text_content.is_some()
                        || start > end
                        || *end > source.byte_length.unwrap_or(0)
                        || (*start, *end) < previous
                    {
                        return Err(invalid("byte source range is invalid"));
                    }
                    previous = (*start, *end);
                }
                wire::RangeSegment::Text {
                    utf8_start,
                    utf8_end,
                    utf16_start,
                    utf16_end,
                } => {
                    let text = source
                        .text_content
                        .as_ref()
                        .ok_or_else(|| invalid("text range targets binary source"))?;
                    let (a, b) = (*utf8_start as usize, *utf8_end as usize);
                    if a > b
                        || b > text.len()
                        || !text.is_char_boundary(a)
                        || !text.is_char_boundary(b)
                        || (*utf8_start, *utf8_end) < previous
                    {
                        return Err(invalid("UTF-8 source range is invalid"));
                    }
                    if utf16_offset(text, a) != Some(*utf16_start)
                        || utf16_offset(text, b) != Some(*utf16_end)
                    {
                        return Err(invalid("UTF-16 source range is invalid"));
                    }
                    previous = (*utf8_start, *utf8_end);
                    if matches!(span.purpose, wire::SpanPurpose::Editable) {
                        if *utf8_start < previous_edit_end {
                            return Err(invalid(
                                "editable ranges overlap or are globally out of order",
                            ));
                        }
                        previous_edit_end = *utf8_end;
                        editable_text.push_str(&text[a..b]);
                    }
                }
            }
        }
    }
    if let Some(edit) = &node.edit {
        if edit.editable {
            if editable_span_count == 0 {
                return Err(invalid("editable metadata has no editable source span"));
            }
            if !tree.document.editable {
                return Err(invalid("node is editable in a read-only document"));
            }
            let source_id = edit
                .source_id
                .ok_or_else(|| invalid("editable node has no source"))?;
            let source = sources
                .get(&source_id)
                .ok_or_else(|| invalid("editable node source is missing"))?;
            if !source.editable
                || edit.revision.as_deref() != Some(source.revision.as_str())
                || editable_source != Some(source_id)
            {
                return Err(invalid("editable node source/revision differs"));
            }
            let expected = node_text(&node.payload)
                .ok_or_else(|| invalid("edit is attached to a node without exact-cover text"))?;
            if editable_text != expected {
                return Err(invalid("editable ranges do not exactly cover node text"));
            }
        } else if edit.source_id.is_some()
            || edit.revision.is_some()
            || edit.operation_class.is_some()
        {
            return Err(invalid("non-editable metadata carries edit authority"));
        } else if editable_span_count != 0 {
            return Err(invalid("non-editable metadata has editable source spans"));
        }
    } else if editable_span_count != 0 {
        return Err(invalid("editable source spans have no edit metadata"));
    }
    Ok(())
}

fn utf16_offset(text: &str, byte: usize) -> Option<u64> {
    text.is_char_boundary(byte)
        .then(|| text[..byte].encode_utf16().count() as u64)
}

fn node_text(payload: &wire::NodePayload) -> Option<&str> {
    match payload {
        wire::NodePayload::TextRun(v) => Some(&v.text),
        wire::NodePayload::CodeBlock(v) => Some(&v.text),
        wire::NodePayload::Diagram(v) => Some(&v.source),
        wire::NodePayload::RawHtml(v) => Some(&v.source),
        wire::NodePayload::Unsupported(v) => v.preserved_text.as_deref(),
        _ => None,
    }
}

fn validate_payload(
    node: &wire::Node,
    nodes: &BTreeMap<u64, &wire::Node>,
    resources: &BTreeMap<u64, &wire::Resource>,
    comments: &BTreeSet<u64>,
    bookmarks: &BTreeSet<u64>,
) -> Result<(), DecodeError> {
    use wire::NodePayload as P;
    match &node.payload {
        P::Heading(v) => {
            validate_paragraph_style(&v.style)?;
            validate_tab_stops(&v.tab_stops)?;
        }
        P::TextRun(v) => {
            sorted_unique_nonzero(v.comment_ids.iter().copied(), "text run comment")?;
            sorted_unique_nonzero(v.bookmark_ids.iter().copied(), "text run bookmark")?;
            if v.comment_ids.iter().any(|id| !comments.contains(id))
                || v.bookmark_ids.iter().any(|id| !bookmarks.contains(id))
            {
                return Err(invalid("text run annotation is missing"));
            }
            validate_character_style(&v.style)?;
        }
        P::ListItem(v) if !(1..=32).contains(&v.level) => {
            return Err(invalid("list level is invalid"));
        }
        P::ListItem(v) => {
            validate_paragraph_style(&v.style)?;
            validate_tab_stops(&v.tab_stops)?;
        }
        P::TaskListItem(v) if !matches!(v.level, Some(1..=32)) => {
            return Err(invalid("task list level is invalid"))
        }
        P::Table(v) => {
            if v.grid_widths.iter().any(|x| !finite_nonnegative(*x))
                || v.preferred_width.is_some_and(|x| !finite_nonnegative(x))
            {
                return Err(invalid("table width is invalid"));
            }
            validate_table(node, v, nodes)?;
        }
        P::TableRow(v) if v.height.is_some_and(|x| !finite_nonnegative(x)) => {
            return Err(invalid("row height is invalid"))
        }
        P::TableCell(v) => {
            if v.row_span == 0 || v.column_span == 0 {
                return Err(invalid("table cell topology is invalid"));
            }
            validate_border_set(&v.borders, true)?;
            if let Some(padding) = &v.edge_padding {
                validate_optional_insets(padding)?;
            }
            if let Some(diagonal) = &v.diagonal {
                validate_drawn_border_width(&diagonal.side)?;
            }
            check_colors(table_cell_colors(v))?;
        }
        P::Image(v) => {
            require_resource(v.resource_id, resources)?;
            if !valid_size(&v.intrinsic_size)
                || v.display_size.as_ref().is_some_and(|s| !valid_size(s))
            {
                return Err(invalid("image size is invalid"));
            }
        }
        P::Vector(v) => {
            if let Some(id) = v.resource_id {
                require_resource(id, resources)?;
            }
            if !valid_size(&v.intrinsic_size)
                || v.display_size.as_ref().is_some_and(|s| !valid_size(s))
                || v.commands
                    .iter()
                    .flat_map(|c| &c.values)
                    .any(|x| !x.is_finite())
            {
                return Err(invalid("vector data is invalid"));
            }
        }
        P::Diagram(v) => {
            if let Some(id) = v.rendered_resource_id {
                require_resource(id, resources)?;
            }
        }
        P::Footnote(v) => match nodes.get(&v.body_flow_id) {
            Some(target) if matches!(target.payload, P::Flow(_)) => {}
            _ => {
                return Err(invalid(
                    "footnote body flow is missing or has the wrong kind",
                ))
            }
        },
        P::Section(v) => {
            sorted_unique_nonzero(v.header_ids.iter().copied(), "section header")?;
            sorted_unique_nonzero(v.footer_ids.iter().copied(), "section footer")?;
            for id in v.header_ids.iter().chain(&v.footer_ids) {
                let target = nodes
                    .get(id)
                    .ok_or_else(|| invalid("section header/footer is missing"))?;
                let right_kind = v.header_ids.contains(id)
                    && matches!(target.payload, P::Header(_))
                    || v.footer_ids.contains(id) && matches!(target.payload, P::Footer(_));
                if !right_kind {
                    return Err(invalid("section header/footer is missing"));
                }
            }
            if v.line_grid_points.is_some_and(|x| !finite_nonnegative(x)) {
                return Err(invalid("line grid is invalid"));
            }
        }
        P::Unsupported(v) => {
            if v.source_format_tag.is_empty() || v.reason.is_empty() {
                return Err(invalid("unsupported provenance is empty"));
            }
            sorted_unique_nonzero(v.resource_ids.iter().copied(), "unsupported resource")?;
            for id in &v.resource_ids {
                require_resource(*id, resources)?;
            }
        }
        P::Paragraph(v) => {
            validate_paragraph_style(&v.style)?;
            validate_tab_stops(&v.tab_stops)?;
        }
        _ => {}
    }
    Ok(())
}

fn require_resource(
    id: u64,
    resources: &BTreeMap<u64, &wire::Resource>,
) -> Result<(), DecodeError> {
    if resources.contains_key(&id) {
        Ok(())
    } else {
        Err(invalid("node resource is missing"))
    }
}
fn valid_color(c: &wire::Color) -> bool {
    [c.red, c.green, c.blue, c.alpha]
        .into_iter()
        .all(|x| x.is_finite() && (0.0..=1.0).contains(&x))
}

fn check_colors<const N: usize>(
    colors: [(&'static str, Option<&wire::Color>); N],
) -> Result<(), DecodeError> {
    for (path, color) in colors {
        if color.is_some_and(|c| !valid_color(c)) {
            return Err(invalid(format!("color component is invalid at {path}")));
        }
    }
    Ok(())
}

fn border_declaration_color(decl: &wire::BorderDeclaration) -> Option<&wire::Color> {
    match decl {
        wire::BorderDeclaration::Suppressed => None,
        wire::BorderDeclaration::Drawn(drawn) => {
            let wire::DrawnBorder {
                width_points: _,
                color,
                style: _,
            } = drawn;
            color.as_ref()
        }
    }
}

fn border_set_colors(set: Option<&wire::BorderSet>) -> [(&'static str, Option<&wire::Color>); 6] {
    let paths = [
        "borders/top/color",
        "borders/right/color",
        "borders/bottom/color",
        "borders/left/color",
        "borders/insideHorizontal/color",
        "borders/insideVertical/color",
    ];
    let Some(wire::BorderSet {
        top,
        right,
        bottom,
        left,
        inside_horizontal,
        inside_vertical,
    }) = set
    else {
        return paths.map(|path| (path, None));
    };
    [
        (paths[0], top.as_ref().and_then(border_declaration_color)),
        (paths[1], right.as_ref().and_then(border_declaration_color)),
        (paths[2], bottom.as_ref().and_then(border_declaration_color)),
        (paths[3], left.as_ref().and_then(border_declaration_color)),
        (
            paths[4],
            inside_horizontal
                .as_ref()
                .and_then(border_declaration_color),
        ),
        (
            paths[5],
            inside_vertical.as_ref().and_then(border_declaration_color),
        ),
    ]
}

fn diagonal_colors(diagonal: Option<&wire::CellDiagonal>) -> (&'static str, Option<&wire::Color>) {
    let path = "diagonal/side/color";
    let Some(wire::CellDiagonal { direction: _, side }) = diagonal else {
        return (path, None);
    };
    let wire::DrawnBorder {
        width_points: _,
        color,
        style: _,
    } = side;
    (path, color.as_ref())
}

pub(super) fn character_style_colors(
    v: &wire::CharacterStyle,
) -> [(&'static str, Option<&wire::Color>); 4] {
    let wire::CharacterStyle {
        bold: _,
        italic: _,
        strike: _,
        inline_code: _,
        caps: _,
        small_caps: _,
        underline: _,
        vertical_position: _,
        letter_spacing_percent: _,
        baseline_offset_percent: _,
        underline_color,
        strikethrough_color,
        declared_font_name: _,
        font_families: _,
        font_size_points: _,
        foreground,
        background,
        baseline_offset_points: _,
        language: _,
        script: _,
        feature_flags: _,
    } = v;
    [
        ("underlineColor", underline_color.as_ref()),
        ("strikethroughColor", strikethrough_color.as_ref()),
        ("foreground", foreground.as_ref()),
        ("background", background.as_ref()),
    ]
}

pub(super) fn paragraph_style_colors(
    v: &wire::ParagraphStyle,
) -> [(&'static str, Option<&wire::Color>); 7] {
    let wire::ParagraphStyle {
        alignment: _,
        direction: _,
        first_line_indent: _,
        head_indent: _,
        tail_indent: _,
        spacing_before: _,
        spacing_after: _,
        line_height: _,
        borders,
        shading,
        columns: _,
        list_text_distance: _,
        hanging_indent: _,
        contextual_spacing: _,
        east_asian_line_break: _,
        latin_line_break: _,
        auto_space_east_asian_latin: _,
        auto_space_east_asian_number: _,
        line_height_from_font_metrics: _,
    } = v;
    let [top, right, bottom, left, inside_horizontal, inside_vertical] =
        border_set_colors(borders.as_ref());
    [
        ("shading", shading.as_ref()),
        top,
        right,
        bottom,
        left,
        inside_horizontal,
        inside_vertical,
    ]
}

pub(super) fn table_cell_colors(v: &wire::TableCell) -> [(&'static str, Option<&wire::Color>); 8] {
    let wire::TableCell {
        row: _,
        column: _,
        row_span: _,
        column_span: _,
        borders,
        edge_padding: _,
        diagonal,
        fill,
        vertical_alignment: _,
    } = v;
    let [top, right, bottom, left, inside_horizontal, inside_vertical] =
        border_set_colors(Some(borders));
    let diagonal_side = diagonal_colors(diagonal.as_ref());
    [
        ("fill", fill.as_ref()),
        top,
        right,
        bottom,
        left,
        inside_horizontal,
        inside_vertical,
        diagonal_side,
    ]
}

fn validate_character_style(v: &wire::CharacterStyle) -> Result<(), DecodeError> {
    if !strictly_sorted_unique_strings(&v.feature_flags) {
        return Err(invalid("character feature flags are not canonical"));
    }
    if v.font_size_points.is_some_and(|x| !finite_nonnegative(x))
        || v.baseline_offset_points.is_some_and(|x| !x.is_finite())
        || v.letter_spacing_percent.is_some_and(|x| !x.is_finite())
        || v.baseline_offset_percent.is_some_and(|x| !x.is_finite())
    {
        return Err(invalid("character metric is invalid"));
    }
    check_colors(character_style_colors(v))?;
    if v.underline_color.is_some() && v.underline.is_none() {
        return Err(invalid("underline color exists while underline is off"));
    }
    if v.strikethrough_color.is_some() && !v.strike {
        return Err(invalid("strikethrough color exists while strike is off"));
    }
    Ok(())
}

fn strictly_sorted_unique_strings(values: &[String]) -> bool {
    values.windows(2).all(|pair| pair[0] < pair[1])
}
fn validate_paragraph_style(v: &wire::ParagraphStyle) -> Result<(), DecodeError> {
    for x in [
        v.first_line_indent,
        v.head_indent,
        v.tail_indent,
        v.spacing_before,
        v.spacing_after,
        v.list_text_distance,
        v.hanging_indent,
    ]
    .into_iter()
    .flatten()
    {
        if !x.is_finite() {
            return Err(invalid("paragraph metric is invalid"));
        }
    }
    if v.line_height
        .as_ref()
        .is_some_and(|x| !finite_nonnegative(x.value))
    {
        return Err(invalid("line height is invalid"));
    }
    if let Some(columns) = &v.columns {
        if columns.count == 0
            || columns
                .widths
                .iter()
                .chain(&columns.gaps)
                .any(|x| !finite_nonnegative(*x))
        {
            return Err(invalid("column declaration is invalid"));
        }
    }
    if let Some(borders) = &v.borders {
        validate_border_set(borders, false)?;
    }
    check_colors(paragraph_style_colors(v))
}

fn validate_drawn_border_width(drawn: &wire::DrawnBorder) -> Result<(), DecodeError> {
    if !finite_nonnegative(drawn.width_points) {
        return Err(invalid("border width is invalid"));
    }
    Ok(())
}

fn validate_border_declaration(decl: &wire::BorderDeclaration) -> Result<(), DecodeError> {
    match decl {
        wire::BorderDeclaration::Suppressed => Ok(()),
        wire::BorderDeclaration::Drawn(drawn) => validate_drawn_border_width(drawn),
    }
}

fn validate_border_set(set: &wire::BorderSet, allow_inside_edges: bool) -> Result<(), DecodeError> {
    let wire::BorderSet {
        top,
        right,
        bottom,
        left,
        inside_horizontal,
        inside_vertical,
    } = set;
    if !allow_inside_edges && (inside_horizontal.is_some() || inside_vertical.is_some()) {
        return Err(invalid("paragraph border set may not declare inside edges"));
    }
    for decl in [top, right, bottom, left, inside_horizontal, inside_vertical]
        .into_iter()
        .flatten()
    {
        validate_border_declaration(decl)?;
    }
    Ok(())
}

fn validate_optional_insets(v: &wire::OptionalInsets) -> Result<(), DecodeError> {
    let wire::OptionalInsets {
        top,
        right,
        bottom,
        left,
    } = v;
    if [top, right, bottom, left]
        .into_iter()
        .flatten()
        .any(|x| !finite_nonnegative(*x))
    {
        return Err(invalid("cell padding is invalid"));
    }
    Ok(())
}

/// Which of a table cell's four logical edges is being resolved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellSide {
    Top,
    Right,
    Bottom,
    Left,
}

/// The pure outcome of cascading a cell border declaration against its table context.
#[derive(Debug, Clone, Copy)]
pub struct ResolvedEdge<'a> {
    pub side: Option<&'a wire::DrawnBorder>,
    pub explicit: bool,
}

fn select_table_declaration(
    table: &wire::BorderSet,
    side: CellSide,
    is_perimeter: bool,
) -> Option<&wire::BorderDeclaration> {
    match (side, is_perimeter) {
        (CellSide::Top, true) => table.top.as_ref(),
        (CellSide::Top, false) => table.inside_horizontal.as_ref(),
        (CellSide::Bottom, true) => table.bottom.as_ref(),
        (CellSide::Bottom, false) => table.inside_horizontal.as_ref(),
        (CellSide::Left, true) => table.left.as_ref(),
        (CellSide::Left, false) => table.inside_vertical.as_ref(),
        (CellSide::Right, true) => table.right.as_ref(),
        (CellSide::Right, false) => table.inside_vertical.as_ref(),
    }
}

/// Resolves a single cell edge against its selected table declaration. Pure and allocation-free.
fn resolve_border_side<'a>(
    cell: Option<&'a wire::BorderDeclaration>,
    table: Option<&'a wire::BorderDeclaration>,
    table_drew_any_edge: bool,
    fallback: Option<&'a wire::DrawnBorder>,
) -> ResolvedEdge<'a> {
    match cell {
        Some(wire::BorderDeclaration::Drawn(drawn)) => ResolvedEdge {
            side: Some(drawn),
            explicit: true,
        },
        Some(wire::BorderDeclaration::Suppressed) => ResolvedEdge {
            side: None,
            explicit: true,
        },
        None => match table {
            Some(wire::BorderDeclaration::Drawn(drawn)) => ResolvedEdge {
                side: Some(drawn),
                explicit: true,
            },
            Some(wire::BorderDeclaration::Suppressed) => ResolvedEdge {
                side: None,
                explicit: true,
            },
            None if table_drew_any_edge => ResolvedEdge {
                side: None,
                explicit: false,
            },
            None => ResolvedEdge {
                side: fallback,
                explicit: false,
            },
        },
    }
}

/// Resolves all four logical cell edges against their table context. Pure and allocation-free.
pub fn resolve_cell_borders<'a>(
    cell: &'a wire::BorderSet,
    table: &'a wire::BorderSet,
    perimeter: [bool; 4],
    table_drew_any_edge: bool,
    fallback: Option<&'a wire::DrawnBorder>,
) -> [ResolvedEdge<'a>; 4] {
    let sides = [
        CellSide::Top,
        CellSide::Right,
        CellSide::Bottom,
        CellSide::Left,
    ];
    let cell_fields = [
        cell.top.as_ref(),
        cell.right.as_ref(),
        cell.bottom.as_ref(),
        cell.left.as_ref(),
    ];
    std::array::from_fn(|i| {
        let table_decl = select_table_declaration(table, sides[i], perimeter[i]);
        resolve_border_side(cell_fields[i], table_decl, table_drew_any_edge, fallback)
    })
}

fn resolve_padding_edge(cell: Option<f64>, table: Option<f64>, fallback: f64) -> f64 {
    cell.or(table).unwrap_or(fallback)
}

/// Resolves paged cell padding against its table context, edge by edge. Pure and allocation-free.
pub fn resolve_cell_padding(
    cell: &wire::OptionalInsets,
    table: &wire::OptionalInsets,
    fallback: wire::Insets,
) -> wire::Insets {
    wire::Insets {
        top: resolve_padding_edge(cell.top, table.top, fallback.top),
        right: resolve_padding_edge(cell.right, table.right, fallback.right),
        bottom: resolve_padding_edge(cell.bottom, table.bottom, fallback.bottom),
        left: resolve_padding_edge(cell.left, table.left, fallback.left),
    }
}

fn validate_tab_stops(values: &[wire::TabStop]) -> Result<(), DecodeError> {
    let mut previous = None;
    for value in values {
        if !finite_nonnegative(value.position_points)
            || previous.is_some_and(|position| value.position_points <= position)
        {
            return Err(invalid(
                "tab stops are not finite strictly increasing positions",
            ));
        }
        previous = Some(value.position_points);
    }
    Ok(())
}
fn validate_table(
    node: &wire::Node,
    table: &wire::Table,
    nodes: &BTreeMap<u64, &wire::Node>,
) -> Result<(), DecodeError> {
    if table.grid_widths.is_empty() {
        return Err(invalid("table grid is empty"));
    }
    let mut occupied = BTreeSet::new();
    let row_count = node.children.len() as u32;
    for (row_index, row_id) in node.children.iter().enumerate() {
        let row = nodes
            .get(row_id)
            .ok_or_else(|| invalid("table row is missing"))?;
        let wire::NodePayload::TableRow(row_value) = &row.payload else {
            return Err(invalid("table child is not a row"));
        };
        if row_value.row != row_index as u32 {
            return Err(invalid(
                "table row coordinates are not contiguous and canonical",
            ));
        }
        let mut previous_column = None;
        for cell_id in &row.children {
            let cell = nodes
                .get(cell_id)
                .ok_or_else(|| invalid("table cell is missing"))?;
            let wire::NodePayload::TableCell(value) = &cell.payload else {
                return Err(invalid("row child is not a cell"));
            };
            if value.row != row_value.row {
                return Err(invalid(
                    "cell row coordinate differs from its containing row",
                ));
            }
            if previous_column.is_some_and(|column| value.column <= column) {
                return Err(invalid("table cells are not in canonical column order"));
            }
            previous_column = Some(value.column);
            if value.column.saturating_add(value.column_span) as usize > table.grid_widths.len() {
                return Err(invalid("cell exceeds table grid"));
            }
            if value.row.saturating_add(value.row_span) > row_count {
                return Err(invalid("cell row span exceeds table rows"));
            }
            for r in value.row..value.row.saturating_add(value.row_span) {
                for c in value.column..value.column.saturating_add(value.column_span) {
                    if !occupied.insert((r, c)) {
                        return Err(invalid("table cells overlap"));
                    }
                }
            }
        }
        for column in 0..table.grid_widths.len() as u32 {
            if !occupied.contains(&(row_value.row, column)) {
                return Err(invalid("table grid has an uncovered cell coordinate"));
            }
        }
    }
    Ok(())
}
