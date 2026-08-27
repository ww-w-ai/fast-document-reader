//! comrak AST -> wire block vocabulary (S3-03), and the tight/loose list encoding it settles on.
//!
//! A block's own inline content (a paragraph/heading/table cell/tight list item's line) is mapped
//! by `inline::map_inline_children` (S3-04/S3-10) — emphasis, strong, inline code, strikethrough,
//! links/autolinks, hard breaks, raw inline HTML and images (S3-06). This module owns the
//! block-level HTML case (`map_html_block`, S3-10) and fenced code, which SPLITS into two wire
//! node kinds depending on its info string: a `mermaid` fence becomes a `diagram` node
//! (`map_code_block`, S3-05 — no source-scan needed, since a fenced block reaches the parser
//! intact), every other language stays `codeBlock`.
//!
//! **Math** (S3-05) is not a block kind of its own here — `map_block`'s very first line is
//! `ctx.math_hit`, checked before any block-kind dispatch, because a scanned `$$` span can be
//! claimed by whatever comrak happened to shred it into (a heading, a paragraph, several of
//! either) at TOP level or nested inside a quote/list. See `math.rs` and `Ctx::math_hit`
//! (`mod.rs`) for the full mechanism.
//!
//! **Tight vs loose lists** (S3-03's acceptance: "tight/loose 구분이 보존된다"). The wire schema
//! has no dedicated field for it (`s3.md` Dependencies: this sprint adds no node tags beyond the
//! one `Image` field another work item owns), and comrak's own AST does not differ structurally
//! either — `NodeList.tight` is a plain bool sitting beside an otherwise-identical `Item ->
//! Paragraph -> ...` shape regardless of tightness (verified by reading
//! `comrak::parser::determine_list_tight`, which only flips this flag; it never changes what gets
//! parsed underneath). So this producer creates the only distinction available: a TIGHT list's
//! own item collapses its paragraph child straight to a `textRun` (no `paragraph` wrapper) — the
//! same choice the shipping Swift renderer already makes for every list item, tight or loose
//! (`MarkdownRenderer.swift:609`'s `renderList` never wraps an item's own line in a nested
//! paragraph). A LOOSE list keeps the `paragraph` node, so the two are told apart by node tag: a
//! `listItem`/`taskListItem` with a `textRun` child directly vs. one with a `paragraph` child.

use comrak::nodes::{AstNode, ListType, NodeValue, TableAlignment as ComrakAlignment};

use crate::render::render_tree::{
    Alignment, CodeBlock as WireCodeBlock, Diagram as WireDiagram, DiagramLanguage, Empty,
    Formula as WireFormula, Heading as WireHeading, List as WireList, ListItem as WireListItem,
    ListNumberingGlyphs, NodePayload, Numbering, Paragraph as WireParagraph, ParagraphStyle,
    RawHtml as WireRawHtml, RenderNodeDraft, Table as WireTable, TableCell as WireTableCell,
    TableRow as WireTableRow, TableStyle, TaskListItem as WireTaskListItem,
};

use super::inline::map_inline_children;
use super::{Ctx, MathHit};

/// One block-level comrak node -> zero or one wire node, appended to `out`. Node kinds outside
/// this pass's vocabulary (front matter, description lists, alerts, footnote definitions — later
/// passes' or permanently out of scope) are skipped silently: they emit nothing rather than a
/// node no test names (invariant 41's failure, repeated). HTML blocks are IN this pass's
/// vocabulary (S3-10) — see `map_html_block`.
pub(super) fn map_block<'a>(
    node: &'a AstNode<'a>,
    parent_id: u64,
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    let sourcepos = node.data.borrow().sourcepos;
    // S3-05, checked before anything else: whatever comrak turned a scanned `$$` span's source
    // into (heading, paragraph, several of either), the FIRST one entirely inside the span
    // becomes one `formula` node and every later one is dropped — see `math.rs`'s module doc.
    match ctx.math_hit(sourcepos) {
        MathHit::Emit(tex) => {
            let id = ctx.new_node_id();
            ctx.push(RenderNodeDraft {
                id,
                parent_id: Some(parent_id),
                children: vec![],
                source_spans: ctx.span_for(sourcepos),
                edit: None,
                payload: NodePayload::Formula(WireFormula {
                    source: tex,
                    display: true,
                    alignment: Alignment::Natural,
                }),
            });
            out.push(id);
            return;
        }
        MathHit::Suppressed => return,
        MathHit::NotMath => {}
    }
    let is_paragraph = matches!(node.data.borrow().value, NodeValue::Paragraph);
    if is_paragraph {
        let id = ctx.new_node_id();
        let children = map_inline_children(node, id, ctx);
        ctx.push(RenderNodeDraft {
            id,
            parent_id: Some(parent_id),
            children,
            source_spans: ctx.span_for(sourcepos),
            edit: None,
            payload: NodePayload::Paragraph(WireParagraph {
                style: ParagraphStyle::default(),
                tab_stops: vec![],
                pagination: Default::default(),
            }),
        });
        out.push(id);
        return;
    }
    let heading_level = match node.data.borrow().value {
        NodeValue::Heading(h) => Some(h.level as i64),
        _ => None,
    };
    if let Some(level) = heading_level {
        let id = ctx.new_node_id();
        let children = map_inline_children(node, id, ctx);
        ctx.push(RenderNodeDraft {
            id,
            parent_id: Some(parent_id),
            children,
            source_spans: ctx.span_for(sourcepos),
            edit: None,
            payload: NodePayload::Heading(WireHeading {
                level,
                style: ParagraphStyle::default(),
                tab_stops: vec![],
                pagination: Default::default(),
            }),
        });
        out.push(id);
        return;
    }
    if matches!(node.data.borrow().value, NodeValue::BlockQuote) {
        let id = ctx.new_node_id();
        let mut children = Vec::new();
        for child in node.children() {
            map_block(child, id, ctx, &mut children);
        }
        ctx.push(RenderNodeDraft {
            id,
            parent_id: Some(parent_id),
            children,
            source_spans: ctx.span_for(sourcepos),
            edit: None,
            payload: NodePayload::BlockQuote(Empty {}),
        });
        out.push(id);
        return;
    }
    let code_block = match &node.data.borrow().value {
        NodeValue::CodeBlock(cb) => Some((
            cb.info.split_whitespace().next().map(str::to_string),
            cb.fenced,
            cb.literal.clone(),
        )),
        _ => None,
    };
    if let Some((language, fenced, text)) = code_block {
        let id = ctx.new_node_id();
        // A `mermaid` info string needs no source-scan (S3-05's second half): the fence already
        // reaches the parser intact, so the language on the SAME node this pass already extracted
        // decides `diagram` versus `codeBlock` — nothing else about the mapping changes.
        let payload = if language.as_deref() == Some("mermaid") {
            NodePayload::Diagram(WireDiagram {
                language: DiagramLanguage::Mermaid,
                source: text,
                rendered_resource_id: None,
            })
        } else {
            NodePayload::CodeBlock(WireCodeBlock { language, fenced, text })
        };
        ctx.push(RenderNodeDraft {
            id,
            parent_id: Some(parent_id),
            children: vec![],
            source_spans: ctx.span_for(sourcepos),
            edit: None,
            payload,
        });
        out.push(id);
        return;
    }
    if matches!(node.data.borrow().value, NodeValue::ThematicBreak) {
        let id = ctx.new_node_id();
        ctx.push(RenderNodeDraft {
            id,
            parent_id: Some(parent_id),
            children: vec![],
            source_spans: ctx.span_for(sourcepos),
            edit: None,
            payload: NodePayload::ThematicBreak(Empty {}),
        });
        out.push(id);
        return;
    }
    if matches!(node.data.borrow().value, NodeValue::List(_)) {
        map_list(node, parent_id, 1, ctx, out);
        return;
    }
    let table_alignments = match &node.data.borrow().value {
        NodeValue::Table(t) => Some(t.alignments.clone()),
        _ => None,
    };
    if let Some(alignments) = table_alignments {
        let id = ctx.new_node_id();
        let mut row_ids = Vec::new();
        for (row_idx, row_node) in node.children().enumerate() {
            map_table_row(row_node, id, row_idx as u32, &alignments, ctx, &mut row_ids);
        }
        let header_rows = if node.children().count() > 0 { 1 } else { 0 };
        // No column width lives in a markdown table's own syntax (unlike Word/ODT's declared
        // grid), and `validate_table` requires a non-empty grid to bound cells against. Zero is a
        // finite, honest placeholder for "this document did not say" — S5 resolves real widths.
        let grid_widths = vec![0.0; alignments.len().max(1)];
        ctx.push(RenderNodeDraft {
            id,
            parent_id: Some(parent_id),
            children: row_ids,
            source_spans: ctx.span_for(sourcepos),
            edit: None,
            payload: NodePayload::Table(WireTable {
                grid_widths,
                alignment: Alignment::Natural,
                preferred_width: None,
                header_rows,
                source_column_widths: vec![],
                style: TableStyle::default(),
            }),
        });
        out.push(id);
        return;
    }
    let html_block_literal = match &node.data.borrow().value {
        NodeValue::HtmlBlock(html) => Some(html.literal.clone()),
        _ => None,
    };
    if let Some(source) = html_block_literal {
        map_html_block(source, parent_id, sourcepos, ctx, out);
    }
    // Every other comrak block kind is out of this pass's vocabulary; skipped, not substituted.
}

/// A block-level HTML region (`visitHTMLBlock`, `MarkdownRenderer.swift:543`) -> one `rawHtml`
/// node with `block: true`, its literal text carried verbatim — not parsed, not escaped, per
/// `s3.md`'s S3-10 acceptance ("원문 텍스트를 그대로 싣는다"). Unlike an inline `rawHtml`
/// (`inline.rs`), this one gets the same block-granularity `source_spans` every other block node
/// carries (S3-11) — it sits directly among the document's other top-level/nested block children.
fn map_html_block(
    source: String,
    parent_id: u64,
    sourcepos: comrak::nodes::Sourcepos,
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    let id = ctx.new_node_id();
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children: vec![],
        source_spans: ctx.span_for(sourcepos),
        edit: None,
        payload: NodePayload::RawHtml(WireRawHtml { block: true, source }),
    });
    out.push(id);
}

/// A list (ordered or unordered) at nesting `depth` (1-based, matching the office adapter's own
/// `ListItem.level` convention — `office_adapter.rs`'s `map_list_group`).
fn map_list<'a>(node: &'a AstNode<'a>, parent_id: u64, depth: u32, ctx: &mut Ctx, out: &mut Vec<u64>) {
    let sourcepos = node.data.borrow().sourcepos;
    let (ordered, tight, start_number) = {
        let ast = node.data.borrow();
        let NodeValue::List(l) = &ast.value else {
            unreachable!("map_list is only called on a List node")
        };
        let ordered = matches!(l.list_type, ListType::Ordered);
        let start_number = if ordered { Some(l.start as i64) } else { None };
        (ordered, l.tight, start_number)
    };
    let id = ctx.new_node_id();
    let mut children = Vec::new();
    for item in node.children() {
        map_list_item(item, id, ordered, tight, depth, ctx, &mut children);
    }
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children,
        source_spans: ctx.span_for(sourcepos),
        edit: None,
        payload: NodePayload::List(WireList {
            numbering: Numbering { glyphs: ListNumberingGlyphs::Decimal, start_number },
        }),
    });
    out.push(id);
}

/// One `listItem`/`taskListItem` — a task item if comrak parsed it as `NodeValue::TaskItem`
/// (GFM's `- [ ]`/`- [x]`, gated on `Options.extension.tasklist`), a plain item otherwise.
fn map_list_item<'a>(
    node: &'a AstNode<'a>,
    parent_id: u64,
    ordered: bool,
    tight: bool,
    depth: u32,
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    let sourcepos = node.data.borrow().sourcepos;
    let checked = match &node.data.borrow().value {
        NodeValue::TaskItem(t) => Some(t.symbol.is_some()),
        _ => None,
    };
    let id = ctx.new_node_id();
    let mut children = Vec::new();
    for child in node.children() {
        map_item_child(child, id, tight, depth, ctx, &mut children);
    }
    let level = depth.clamp(1, 32);
    let payload = match checked {
        Some(checked) => NodePayload::TaskListItem(WireTaskListItem { checked, level: Some(level) }),
        None => NodePayload::ListItem(WireListItem {
            level,
            ordered,
            marker: None,
            numbering: None,
            style: ParagraphStyle::default(),
            tab_stops: vec![],
            pagination: Default::default(),
        }),
    };
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children,
        source_spans: ctx.span_for(sourcepos),
        edit: None,
        payload,
    });
    out.push(id);
}

/// One block inside a list item's own content — see this module's doc comment for the tight/loose
/// encoding this function is the heart of.
fn map_item_child<'a>(
    node: &'a AstNode<'a>,
    item_id: u64,
    tight: bool,
    depth: u32,
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    if tight && matches!(node.data.borrow().value, NodeValue::Paragraph) {
        out.extend(map_inline_children(node, item_id, ctx));
        return;
    }
    if matches!(node.data.borrow().value, NodeValue::List(_)) {
        map_list(node, item_id, depth + 1, ctx, out);
        return;
    }
    map_block(node, item_id, ctx, out);
}

/// A table row. comrak's own `NodeValue::TableRow(bool)` already states whether it is the header
/// row — the same fact this producer's `header_rows` count on the parent table derives from
/// (GFM permits exactly one, the first).
fn map_table_row<'a>(
    node: &'a AstNode<'a>,
    parent_id: u64,
    row_idx: u32,
    alignments: &[ComrakAlignment],
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    let sourcepos = node.data.borrow().sourcepos;
    let header = matches!(node.data.borrow().value, NodeValue::TableRow(true));
    let id = ctx.new_node_id();
    let mut cell_ids = Vec::new();
    for (col_idx, cell_node) in node.children().enumerate() {
        let alignment = alignments.get(col_idx).copied().unwrap_or(ComrakAlignment::None);
        map_table_cell(cell_node, id, row_idx, col_idx as u32, alignment, ctx, &mut cell_ids);
    }
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children: cell_ids,
        source_spans: ctx.span_for(sourcepos),
        edit: None,
        payload: NodePayload::TableRow(WireTableRow { row: row_idx, header, cant_split: false, height: None }),
    });
    out.push(id);
}

/// A table cell. GFM's per-column alignment (`:--`/`:-:`/`--:`) has no home on `TableCell` or
/// `Table` in the wire schema (neither carries a horizontal `Alignment`) — it is a PARAGRAPH
/// property everywhere else in this schema (Word/ODT cells carry their alignment the same way, on
/// the paragraph inside), so the cell's plain-text content is wrapped in one synthetic `paragraph`
/// node whose `style.alignment` carries it. That paragraph has no `source_spans` of its own (its
/// span would exactly duplicate the cell's), matching how this producer already leaves inline
/// nodes unspanned.
fn map_table_cell<'a>(
    node: &'a AstNode<'a>,
    parent_id: u64,
    row: u32,
    column: u32,
    alignment: ComrakAlignment,
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    let sourcepos = node.data.borrow().sourcepos;
    let id = ctx.new_node_id();
    let paragraph_id = ctx.new_node_id();
    let children = map_inline_children(node, paragraph_id, ctx);
    ctx.push(RenderNodeDraft {
        id: paragraph_id,
        parent_id: Some(id),
        children,
        source_spans: vec![],
        edit: None,
        payload: NodePayload::Paragraph(WireParagraph {
            style: ParagraphStyle {
                alignment: Some(convert_table_alignment(alignment)),
                ..ParagraphStyle::default()
            },
            tab_stops: vec![],
            pagination: Default::default(),
        }),
    });
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children: vec![paragraph_id],
        source_spans: ctx.span_for(sourcepos),
        edit: None,
        payload: NodePayload::TableCell(WireTableCell {
            row,
            column,
            row_span: 1,
            column_span: 1,
            direct_shading: None,
            direct_uniform_border: None,
            direct_edge_borders: None,
            declared_width_points: None,
            vertical_alignment: None,
            uniform_padding_points: None,
            edge_padding: None,
            diagonal: None,
            style_shading: None,
            style_uniform_border: None,
            background_resource_id: None,
            background_gradient: None,
        }),
    });
    out.push(id);
}

fn convert_table_alignment(alignment: ComrakAlignment) -> Alignment {
    match alignment {
        ComrakAlignment::None => Alignment::Natural,
        ComrakAlignment::Left => Alignment::Left,
        ComrakAlignment::Center => Alignment::Center,
        ComrakAlignment::Right => Alignment::Right,
    }
}

