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

use comrak::nodes::AlertType;

use crate::render::markdown_renderer::{html_attribute, html_block_lines, ALERT_COLORS};
use crate::render::render_tree::{
    Alignment, BlockQuote as WireBlockQuote, CharacterStyle, CodeBlock as WireCodeBlock,
    Diagram as WireDiagram, DiagramLanguage, Empty,
    Formula as WireFormula, Heading as WireHeading, List as WireList, ListItem as WireListItem,
    ListNumberingGlyphs, NodePayload, Numbering, Paragraph as WireParagraph, ParagraphStyle,
    RawHtml as WireRawHtml, RenderNodeDraft, Table as WireTable, TableCell as WireTableCell,
    TableRow as WireTableRow, TableStyle, TaskListItem as WireTaskListItem,
};

use super::inline::{build_image, color, map_bold_inline_children, map_inline_children, push_text_run};
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
                style: ParagraphStyle {
                    head_indent: ctx.paragraph_head_indent,
                    ..ParagraphStyle::default()
                },
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
        // `## Title {#id}`: comrak hides the attribute text; the id is the heading's jump target.
        let anchor = node
            .data
            .borrow()
            .attrs
            .as_ref()
            .and_then(|attrs| attrs.id.clone())
            .filter(|id| !id.is_empty());
        if let Some(anchor) = anchor {
            ctx.add_bookmark(anchor, id);
        }
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
    // `>>> … <<<` is the same quote as `> …`; an alert is a quote that names its kind and opens
    // with a title paragraph.
    let quote = match &node.data.borrow().value {
        NodeValue::BlockQuote | NodeValue::MultilineBlockQuote(_) => Some(None),
        NodeValue::Alert(alert) => Some(Some((alert.alert_type, alert.title.clone()))),
        _ => None,
    };
    if let Some(alert) = quote {
        map_quote(node, parent_id, alert, ctx, out);
        return;
    }
    if matches!(node.data.borrow().value, NodeValue::DescriptionList) {
        map_description_list(node, parent_id, ctx, out);
        return;
    }
    if matches!(node.data.borrow().value, NodeValue::FootnoteDefinition(_)) {
        // A definition outside the document's own trailing run of them is still shown.
        map_footnote_section(&mut vec![node], parent_id, ctx, out);
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
            // S8-B3: `runs` is `None` for a fence language the highlighter's scanner does not
            // recognise (`is_known`), `Some` (possibly empty) once it does — the same distinction
            // `CodeHighlighter::highlight` makes between "plain fallback" and "nothing to colour".
            let runs = language
                .as_deref()
                .filter(|l| crate::render::code_highlighter::CodeHighlighter::is_known(Some(l)))
                .map(|l| crate::render::code_highlighter::CodeHighlighter::tokenize(&text, l));
            NodePayload::CodeBlock(WireCodeBlock { language, fenced, text, runs })
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
    // The verbatim source stays on the node; what a reader shows is its children: a lone `<img>`
    // as the picture, anything else as its text (tags dropped, `<summary>` bold, comments hidden).
    let mut children = Vec::new();
    if let Some((src, alt)) = lone_img(&source) {
        let image_id = ctx.new_node_id();
        let image = build_image(ctx, &src, &alt);
        ctx.push(RenderNodeDraft {
            id: image_id,
            parent_id: Some(id),
            children: vec![],
            source_spans: vec![],
            edit: None,
            payload: NodePayload::Image(image),
        });
        children.push(image_id);
    } else {
        for line in html_block_lines(&source) {
            let style = CharacterStyle { bold: line.bold, ..CharacterStyle::default() };
            push_paragraph(ctx, id, &line.text, style, &mut children);
        }
    }
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children,
        source_spans: ctx.span_for(sourcepos),
        edit: None,
        payload: NodePayload::RawHtml(WireRawHtml { block: true, source }),
    });
    out.push(id);
}

/// `<img src="x" alt="y">` and nothing else: its `src` and `alt`.
fn lone_img(source: &str) -> Option<(String, String)> {
    let trimmed = source.trim();
    if !trimmed.to_ascii_lowercase().starts_with("<img") {
        return None;
    }
    let end = trimmed.find('>')?;
    if !trimmed[end + 1..].trim().is_empty() {
        return None;
    }
    let tag = &trimmed[..=end];
    let src = html_attribute(tag, "src").filter(|s| !s.is_empty())?;
    Some((src, html_attribute(tag, "alt").unwrap_or_default()))
}

/// One paragraph holding one text run, appended to `out`.
fn push_paragraph(ctx: &mut Ctx, parent_id: u64, text: &str, style: CharacterStyle, out: &mut Vec<u64>) {
    let id = ctx.new_node_id();
    let run = push_text_run(ctx, id, text, style, None);
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children: vec![run],
        source_spans: vec![],
        edit: None,
        payload: NodePayload::Paragraph(WireParagraph {
            style: ParagraphStyle { head_indent: ctx.paragraph_head_indent, ..ParagraphStyle::default() },
            tab_stops: vec![],
            pagination: Default::default(),
        }),
    });
    out.push(id);
}

/// A quote, or an alert (`alert` = comrak's kind and the author's title, if any).
fn map_quote<'a>(
    node: &'a AstNode<'a>,
    parent_id: u64,
    alert: Option<(AlertType, Option<String>)>,
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    let sourcepos = node.data.borrow().sourcepos;
    let id = ctx.new_node_id();
    let mut children = Vec::new();
    let mut kind_name = None;
    if let Some((kind, title)) = alert {
        let (name, title_default) = match kind {
            AlertType::Note => ("note", "Note"),
            AlertType::Tip => ("tip", "Tip"),
            AlertType::Important => ("important", "Important"),
            AlertType::Warning => ("warning", "Warning"),
            AlertType::Caution => ("caution", "Caution"),
        };
        let &(_, _, r, g, b) = ALERT_COLORS.iter().find(|(_, n, ..)| *n == name).expect("alert colour");
        let style = CharacterStyle {
            bold: true,
            foreground: Some(color((r, g, b, 1.0))),
            ..CharacterStyle::default()
        };
        let text = title.filter(|t| !t.is_empty()).unwrap_or_else(|| title_default.to_string());
        push_paragraph(ctx, id, &text, style, &mut children);
        kind_name = Some(name.to_string());
    }
    for child in node.children() {
        map_block(child, id, ctx, &mut children);
    }
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children,
        source_spans: ctx.span_for(sourcepos),
        edit: None,
        payload: NodePayload::BlockQuote(WireBlockQuote { alert: kind_name }),
    });
    out.push(id);
}

/// `Term` / `: details`: the term as a bold paragraph, each details' blocks hung under it.
fn map_description_list<'a>(node: &'a AstNode<'a>, parent_id: u64, ctx: &mut Ctx, out: &mut Vec<u64>) {
    const DETAILS_INDENT_POINTS: f64 = 18.0;
    for item in node.children() {
        for part in item.children() {
            let value = part.data.borrow().value.clone();
            match value {
                NodeValue::DescriptionTerm => {
                    let id = ctx.new_node_id();
                    let paragraphs: Vec<_> = part
                        .children()
                        .filter(|c| matches!(c.data.borrow().value, NodeValue::Paragraph))
                        .collect();
                    let mut children = Vec::new();
                    if paragraphs.is_empty() {
                        children.extend(map_bold_inline_children(part, id, ctx));
                    }
                    for paragraph in paragraphs {
                        children.extend(map_bold_inline_children(paragraph, id, ctx));
                    }
                    ctx.push(RenderNodeDraft {
                        id,
                        parent_id: Some(parent_id),
                        children,
                        source_spans: ctx.span_for(part.data.borrow().sourcepos),
                        edit: None,
                        payload: NodePayload::Paragraph(WireParagraph {
                            style: ParagraphStyle::default(),
                            tab_stops: vec![],
                            pagination: Default::default(),
                        }),
                    });
                    out.push(id);
                }
                NodeValue::DescriptionDetails => {
                    let outer = ctx.paragraph_head_indent.replace(DETAILS_INDENT_POINTS);
                    for child in part.children() {
                        map_block(child, parent_id, ctx, out);
                    }
                    ctx.paragraph_head_indent = outer;
                }
                _ => {}
            }
        }
    }
}

pub(super) fn is_footnote_definition<'a>(node: &'a AstNode<'a>) -> bool {
    matches!(node.data.borrow().value, NodeValue::FootnoteDefinition(_))
}

/// The notes section: a rule, then one numbered item per note (`n.` marker, the note's blocks, and
/// an arrow back to the note's first reference). Each note is a `fn:<name>` jump target, which its
/// references link to. Drains `notes`.
pub(super) fn map_footnote_section<'a>(
    notes: &mut Vec<&'a AstNode<'a>>,
    parent_id: u64,
    ctx: &mut Ctx,
    out: &mut Vec<u64>,
) {
    if notes.is_empty() {
        return;
    }
    let rule_id = ctx.new_node_id();
    ctx.push(RenderNodeDraft {
        id: rule_id,
        parent_id: Some(parent_id),
        children: vec![],
        source_spans: vec![],
        edit: None,
        payload: NodePayload::ThematicBreak(Empty {}),
    });
    out.push(rule_id);

    let list_id = ctx.new_node_id();
    let mut items = Vec::new();
    for (index, note) in notes.drain(..).enumerate() {
        let name = match &note.data.borrow().value {
            NodeValue::FootnoteDefinition(definition) => definition.name.clone(),
            _ => continue,
        };
        let item_id = ctx.new_node_id();
        ctx.add_bookmark(format!("fn:{name}"), item_id);
        let referenced = ctx.has_bookmark(&format!("fnref:{name}"));
        let mut children = Vec::new();
        let mut arrow_pending = referenced;
        for child in note.children() {
            let is_paragraph = matches!(child.data.borrow().value, NodeValue::Paragraph);
            if is_paragraph && children.is_empty() {
                children.extend(map_inline_children(child, item_id, ctx));
                if arrow_pending {
                    arrow_pending = false;
                    let style = CharacterStyle::default();
                    children.push(push_text_run(ctx, item_id, " \u{21A9}", style, Some(format!("#fnref:{name}"))));
                }
            } else {
                map_block(child, item_id, ctx, &mut children);
            }
        }
        ctx.push(RenderNodeDraft {
            id: item_id,
            parent_id: Some(list_id),
            children,
            // An inline note (`^[…]`) has no block of its own in the source to point at.
            source_spans: vec![],
            edit: None,
            payload: NodePayload::ListItem(WireListItem {
                level: 1,
                ordered: true,
                marker: Some(format!("{}.", index + 1)),
                numbering: None,
                style: ParagraphStyle::default(),
                tab_stops: vec![],
                pagination: Default::default(),
            }),
        });
        items.push(item_id);
    }
    ctx.push(RenderNodeDraft {
        id: list_id,
        parent_id: Some(parent_id),
        children: items,
        source_spans: vec![],
        edit: None,
        payload: NodePayload::List(WireList {
            numbering: Numbering { glyphs: ListNumberingGlyphs::Decimal, start_number: Some(1) },
        }),
    });
    out.push(list_id);
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
            // markdown has no table row height to declare.
            declared_height: None,
            minimum_row_height: None,
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

