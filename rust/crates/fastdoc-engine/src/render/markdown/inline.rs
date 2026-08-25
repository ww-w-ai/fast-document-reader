//! comrak inline AST -> wire inline vocabulary (S3-04, S3-10): emphasis, strong, inline code,
//! strikethrough, links (including autolinks), hard line breaks, and raw inline HTML. Soft breaks
//! are NOT a node — see the section below for why, with the `file:line` this pass matched
//! against.
//!
//! ## The soft-break decision
//!
//! `MarkdownRenderer.swift:400-402` (`case is SoftBreak: return NSAttributedString(string: " ",
//! ...)`) turns a source newline inside a paragraph into a plain space, appended to whatever run
//! is already being built — it is not a distinct element with its own attributes, and no
//! `MDAttr` is attached to it. This pass's acceptance is equivalence with that SHIPPING renderer
//! (`s3.md`'s WorkList, S3-04), not CommonMark's own suggestion that a soft break MAY become a
//! `<br>`. So a soft break here is one space character folded into whichever text run is
//! accumulating at that point (`RunState`-aware, same as any other literal text) — never a
//! `lineBreak` node. `lineBreak` (this module's dedicated node) is reserved for what the Swift
//! renderer treats differently: `case is LineBreak: return NSAttributedString(string: "\n", ...)`
//! (`MarkdownRenderer.swift:396-398`), the GFM HARD break (two trailing spaces or a backslash).
//!
//! ## Run merging, not per-comrak-node runs
//!
//! comrak's own inline AST is a NODE per formatting change, but adjacent nodes that end up with
//! the SAME resolved style (e.g. two `Text` nodes comrak split around smart punctuation, or plain
//! text either side of a soft break) collapse into ONE `textRun`. [`RunState`] carries the
//! resolved style+link down the recursion; [`Builder::push_text`] only starts a new run when that
//! state actually differs from the run already being accumulated. Nesting itself
//! (`**_bold italic_**`) is NOT represented as nested nodes — it is `RunState` accumulating both
//! flags on the way down, so the leaf `Text` node inside both wrappers emits ONE run carrying
//! `bold: true, italic: true` together, matching the design's "run-level flags, not a node tree"
//! (`s3.md` S3-04's "중첩을 노드로 만들지 마라").
//!
//! ## Math and images (S3-05, S3-06)
//!
//! `Builder::walk` checks `ctx.math_hit` before dispatching on `kind_of`, for the same reason
//! `blocks::map_block` does — the smallest node comrak produced for a `$$` span might be an
//! inline one (a one-liner formula sitting on its own line inside an otherwise ordinary
//! multi-line paragraph, where the PARAGRAPH is not entirely inside the span but the inline
//! `Text` node for that one line is). `NodeValue::Image` is intercepted the same way, right after
//! the math check: its URL and alt text (collected from its own children, since comrak parses
//! `![alt](url)`'s alt as inline content rather than a plain string) become one `image` node
//! (`build_image`), and the image's own children are never walked as text — matching the
//! shipping renderer, which never renders alt text as visible content either.
//!
//! Footnote references are NOT mapped to their own nodes here (out of scope for this sprint —
//! `s3.md`'s "Out of scope") — anything comrak nests under an unhandled inline kind still
//! contributes its own literal text through the catch-all recursion below, unstyled, so a
//! paragraph containing one is not silently emptied.
//!
//! ## No source spans on inline nodes
//!
//! `s3.md`'s Design fixes source-span granularity at the BLOCK level: "Inline spans would be more
//! data with no consumer" (Design, "Source spans, because markdown is the format that can"). Every
//! node this module creates carries `source_spans: vec![]`.

use comrak::nodes::{AstNode, NodeValue};

use crate::render::render_tree::{
    Alignment, CharacterStyle, Formula as WireFormula, Image as WireImage,
    LineBreak as WireLineBreak, LineBreakKind, NodePayload, RawHtml as WireRawHtml,
    RenderNodeDraft, Size as WireSize, TextRun as WireTextRun,
};

use super::{Ctx, MathHit};

/// The resolved style+link state at one point in the inline tree — accumulated top-down, never
/// read back out of a comrak node. Two positions with an equal `RunState` merge into one run.
#[derive(Clone, PartialEq, Eq, Default)]
struct RunState {
    bold: bool,
    italic: bool,
    strike: bool,
    inline_code: bool,
    link: Option<String>,
}

/// What one comrak inline node means to THIS pass, extracted through a single short-lived borrow
/// (owned copies only) so the recursive walk below never holds two overlapping borrows of the
/// same `RefCell` — the same discipline `blocks.rs`'s `map_block` already uses (extract first,
/// branch after the borrow drops).
enum Kind {
    Text(String),
    Code(String),
    SoftBreak,
    HardBreak,
    Html(String),
    Emph,
    Strong,
    Strike,
    /// A link's destination URL. Covers both `[text](url)` and autolinks (`<https://x>` and GFM
    /// bare-URL autolinks all parse as `NodeValue::Link` — comrak gives autolinks no distinct
    /// node kind, so no separate case is needed here).
    Link(String),
    /// Everything this pass does not special-case (images, math, footnote refs, wikilinks, …):
    /// its own children are still walked so any literal text inside survives.
    Other,
}

fn kind_of<'a>(node: &'a AstNode<'a>) -> Kind {
    match &node.data.borrow().value {
        NodeValue::Text(text) => Kind::Text(text.to_string()),
        NodeValue::Code(code) => Kind::Code(code.literal.clone()),
        NodeValue::SoftBreak => Kind::SoftBreak,
        NodeValue::LineBreak => Kind::HardBreak,
        NodeValue::HtmlInline(html) => Kind::Html(html.clone()),
        NodeValue::Emph => Kind::Emph,
        NodeValue::Strong => Kind::Strong,
        NodeValue::Strikethrough => Kind::Strike,
        NodeValue::Link(link) => Kind::Link(link.url.clone()),
        _ => Kind::Other,
    }
}

/// The mutable accumulation state for one inline walk: the run currently being built (flushed to
/// a `textRun` node the moment the style changes or a non-text node interrupts it) and the flat
/// list of child node ids produced so far, in source order.
struct Builder<'ctx, 'a> {
    ctx: &'ctx mut Ctx<'a>,
    parent_id: u64,
    pending: Option<(String, RunState)>,
    out: Vec<u64>,
}

impl<'ctx, 'a> Builder<'ctx, 'a> {
    fn push_text(&mut self, state: &RunState, text: &str) {
        if text.is_empty() {
            return;
        }
        match &mut self.pending {
            Some((buf, pending_state)) if pending_state == state => buf.push_str(text),
            _ => {
                self.flush();
                self.pending = Some((text.to_string(), state.clone()));
            }
        }
    }

    fn flush(&mut self) {
        if let Some((text, state)) = self.pending.take() {
            let id = self.ctx.new_node_id();
            self.ctx.push(RenderNodeDraft {
                id,
                parent_id: Some(self.parent_id),
                children: vec![],
                source_spans: vec![],
                edit: None,
                payload: NodePayload::TextRun(WireTextRun {
                    text,
                    style: CharacterStyle {
                        bold: state.bold,
                        italic: state.italic,
                        strike: state.strike,
                        inline_code: state.inline_code,
                        ..CharacterStyle::default()
                    },
                    direction: None,
                    link: state.link,
                    bookmark_ids: vec![],
                    comment_ids: vec![],
                    field: None,
                    footnote_reference_number: None,
                    form_control: None,
                    page_number_field: None,
                    column_flow: None,
                }),
            });
            self.out.push(id);
        }
    }

    fn push_leaf_empty_text_run(&mut self) {
        self.push_leaf(NodePayload::TextRun(WireTextRun {
            text: String::new(),
            style: CharacterStyle::default(),
            direction: None,
            link: None,
            bookmark_ids: vec![],
            comment_ids: vec![],
            field: None,
            footnote_reference_number: None,
            form_control: None,
            page_number_field: None,
            column_flow: None,
        }));
    }

    fn push_leaf(&mut self, payload: NodePayload) {
        self.flush();
        let id = self.ctx.new_node_id();
        self.ctx.push(RenderNodeDraft {
            id,
            parent_id: Some(self.parent_id),
            children: vec![],
            source_spans: vec![],
            edit: None,
            payload,
        });
        self.out.push(id);
    }

    fn walk_children<'b>(&mut self, node: &'b AstNode<'b>, state: &RunState) {
        for child in node.children() {
            self.walk(child, state);
        }
    }

    fn walk<'b>(&mut self, node: &'b AstNode<'b>, state: &RunState) {
        let sourcepos = node.data.borrow().sourcepos;
        match self.ctx.math_hit(sourcepos) {
            MathHit::Emit(tex) => {
                self.push_leaf(NodePayload::Formula(WireFormula {
                    source: tex,
                    display: true,
                    alignment: Alignment::Natural,
                }));
                return;
            }
            MathHit::Suppressed => return,
            MathHit::NotMath => {}
        }
        let image_url = match &node.data.borrow().value {
            NodeValue::Image(link) => Some(link.url.clone()),
            _ => None,
        };
        if let Some(url) = image_url {
            let alt = collect_alt_text(node);
            let image = build_image(self.ctx, &url, &alt);
            self.push_leaf(NodePayload::Image(image));
            return;
        }
        match kind_of(node) {
            Kind::Text(text) => self.push_text(state, &text),
            Kind::SoftBreak => self.push_text(state, " "),
            Kind::Code(literal) => {
                let mut s = state.clone();
                s.inline_code = true;
                self.push_text(&s, &literal);
            }
            Kind::HardBreak => {
                self.push_leaf(NodePayload::LineBreak(WireLineBreak { kind: LineBreakKind::Hard }))
            }
            Kind::Html(source) => {
                self.push_leaf(NodePayload::RawHtml(WireRawHtml { block: false, source }))
            }
            Kind::Emph => {
                let mut s = state.clone();
                s.italic = true;
                self.walk_children(node, &s);
            }
            Kind::Strong => {
                let mut s = state.clone();
                s.bold = true;
                self.walk_children(node, &s);
            }
            Kind::Strike => {
                let mut s = state.clone();
                s.strike = true;
                self.walk_children(node, &s);
            }
            Kind::Link(url) => {
                let mut s = state.clone();
                s.link = Some(url);
                self.walk_children(node, &s);
            }
            Kind::Other => self.walk_children(node, state),
        }
    }
}

/// Every inline child of a block-level container (paragraph, heading, table cell, a list item's
/// own bare line) mapped to zero or more wire nodes — `textRun` (merged runs, S3-04),
/// `lineBreak` (hard breaks only) and `rawHtml` (inline HTML, S3-10) — appended to `ctx` and
/// returned as an ordered id list for the caller to install as `children`.
///
/// Never empty: an inline sequence with no text at all (an empty paragraph) still returns one
/// empty `textRun`, matching pass A's contract that a paragraph/heading always has exactly one
/// text-bearing child (`markdown_block_producer.rs`'s existing assertions read `children[0]`
/// unconditionally).
pub(super) fn map_inline_children<'a>(node: &'a AstNode<'a>, parent_id: u64, ctx: &mut Ctx) -> Vec<u64> {
    let mut builder = Builder { ctx, parent_id, pending: None, out: Vec::new() };
    builder.walk_children(node, &RunState::default());
    builder.flush();
    if builder.out.is_empty() {
        // `push_text`'s empty-string guard means an inline sequence with no text at all leaves
        // nothing pending to flush — force the one empty `textRun` this function promises.
        builder.push_leaf_empty_text_run();
    }
    builder.out
}

/// An image's alt text, flattened to plain characters — comrak parses `![alt](url)`'s alt as
/// inline CONTENT (its `Image` node's own children), not a plain string, but the shipping
/// renderer never renders that content as visible text either way (`imageString`'s `alt`
/// parameter is metadata, not a run), so this producer only needs the text, not its markup.
fn collect_alt_text<'b>(node: &'b AstNode<'b>) -> String {
    let mut buf = String::new();
    for child in node.children() {
        match &child.data.borrow().value {
            NodeValue::Text(text) => buf.push_str(text),
            NodeValue::Code(code) => buf.push_str(&code.literal),
            NodeValue::SoftBreak => buf.push(' '),
            _ => buf.push_str(&collect_alt_text(child)),
        }
    }
    buf
}

/// One `![alt](url)` -> the wire `Image` payload. Resource registration and the size-declared
/// vs. size-unknown honesty tradeoff are `Ctx::resolve_image_resource`'s doc comment; this
/// function owns only the Obsidian `![alt|size]` syntax the alt text may carry.
fn build_image(ctx: &mut Ctx, url: &str, alt: &str) -> WireImage {
    let (alt_clean, display_size, display_width_fraction) = parse_sized_alt(alt);
    let resource_id = ctx.resolve_image_resource(url);
    WireImage {
        resource_id,
        // `{0, 0}` is a finite, honest "not resolved" sentinel, never a guess — see
        // `Ctx::resolve_image_resource`'s doc comment for why this pass carries no real
        // intrinsic size at all.
        intrinsic_size: WireSize { width: 0.0, height: 0.0 },
        display_size,
        display_width_fraction,
        alignment: Alignment::Natural,
        alt_text: if alt_clean.is_empty() { None } else { Some(alt_clean) },
    }
}

/// A port of `parseSizedAlt` (`MarkdownRenderer.swift:302-311`): Obsidian's `![alt|300]` /
/// `![alt|300x200]` / `![alt|50%]` syntax, size stripped off the LAST `|` in the alt text. No
/// size suffix (or a suffix that fails to parse as a width) leaves the alt text untouched.
fn parse_sized_alt(alt: &str) -> (String, Option<WireSize>, Option<f64>) {
    let Some(pipe_idx) = alt.rfind('|') else {
        return (alt.to_string(), None, None);
    };
    let size_part = alt[pipe_idx + 1..].trim();
    let width_tok = size_part.split('x').next().unwrap_or(size_part);
    let (pts, pct) = parse_width_spec(width_tok);
    if pts.is_none() && pct.is_none() {
        return (alt.to_string(), None, None);
    }
    let clean_alt = alt[..pipe_idx].trim().to_string();
    // A point width has no declared height (Obsidian's `|300` names only a column width, the
    // same single dimension `MarkdownRenderer.swift`'s `imageWidth` attribute carries) — `{w, 0}`
    // is `build_image`'s same honest-unknown sentinel, not a square guess.
    let display_size = pts.map(|width| WireSize { width, height: 0.0 });
    (clean_alt, display_size, pct)
}

/// A port of `parseWidthSpec` (`MarkdownRenderer.swift:313-317`): `"300"`/`"300px"` -> points,
/// `"50%"` -> a 0–1 fraction. Neither shape -> `(None, None)`, leaving the caller's alt text
/// untouched (the `|` might be ordinary text, not a size suffix).
fn parse_width_spec(s: &str) -> (Option<f64>, Option<f64>) {
    let t = s.trim();
    if let Some(stripped) = t.strip_suffix('%') {
        if let Ok(n) = stripped.parse::<f64>() {
            return (None, Some(n / 100.0));
        }
    }
    if let Ok(n) = t.replace("px", "").parse::<f64>() {
        return (Some(n), None);
    }
    (None, None)
}
