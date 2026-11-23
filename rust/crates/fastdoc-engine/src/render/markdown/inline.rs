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
//! A footnote reference is a superscript run linking to `#fn:<name>`; the note is a bookmarked list
//! item (`blocks::map_footnote_section`), and the first reference is bookmarked `fnref:<name>` for
//! the note's way back. Raw inline HTML (`<u>`, `<mark>`, `<sub>`, `<br>`, …) and the comrak-only
//! spans (`==x==`, `++x++`, `^x^`, `||x||`) become run styles; anything comrak nests under a kind
//! not listed in `Kind` still contributes its literal text through the catch-all recursion.
//!
//! ## No source spans on inline nodes
//!
//! `s3.md`'s Design fixes source-span granularity at the BLOCK level: "Inline spans would be more
//! data with no consumer" (Design, "Source spans, because markdown is the format that can"). Every
//! node this module creates carries `source_spans: vec![]`.

use comrak::nodes::{AstNode, NodeValue};

use crate::render::markdown_renderer::{parse_html_tag, HtmlTag};
use crate::render::render_tree::{
    Alignment, CharacterStyle, Color, ColorSpace, Formula as WireFormula, Image as WireImage,
    LineBreak as WireLineBreak, LineBreakKind, NodePayload, RawHtml as WireRawHtml,
    RenderNodeDraft, Size as WireSize, TextRun as WireTextRun, UnderlineStyle, VerticalPosition,
};

use super::{Ctx, MathHit};

/// `==x==` / `<mark>` fill — the same translucent yellow `markdown_renderer::highlight_color` paints.
pub(super) const HIGHLIGHT_FILL: (f64, f64, f64, f64) = (1.0, 0.85, 0.2, 0.4);
/// `||x||` — the same grey wash `markdown_renderer::spoiler_fill` paints.
const SPOILER_FILL: (f64, f64, f64, f64) = (0.5, 0.5, 0.5, 0.3);

pub(super) fn color((red, green, blue, alpha): (f64, f64, f64, f64)) -> Color {
    Color { red, green, blue, alpha, space: ColorSpace::Srgb }
}

/// The marker fill behind a run.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum Fill {
    #[default]
    None,
    Highlight,
    Spoiler,
}

/// Superscript / subscript position of a run.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum Script {
    #[default]
    Normal,
    Sup,
    Sub,
}

/// The resolved style+link state at one point in the inline tree — accumulated top-down, never
/// read back out of a comrak node. Two positions with an equal `RunState` merge into one run.
#[derive(Clone, PartialEq, Eq, Default)]
pub(super) struct RunState {
    pub(super) bold: bool,
    italic: bool,
    strike: bool,
    inline_code: bool,
    underline: bool,
    fill: Fill,
    script: Script,
    link: Option<String>,
}

/// Raw inline HTML tags opened and not yet closed, as counts per tag: a tag styles the text
/// between it and its close tag (or the end of the container, as a browser would).
#[derive(Default)]
struct HtmlOpen {
    underline: u32,
    strike: u32,
    mark: u32,
    sub: u32,
    sup: u32,
    code: u32,
    bold: u32,
    italic: u32,
    hrefs: Vec<String>,
}

impl HtmlOpen {
    fn counter(&mut self, name: &str) -> Option<&mut u32> {
        Some(match name {
            "u" | "ins" => &mut self.underline,
            "s" | "strike" | "del" => &mut self.strike,
            "mark" => &mut self.mark,
            "sub" => &mut self.sub,
            "sup" => &mut self.sup,
            "kbd" | "code" => &mut self.code,
            "b" | "strong" => &mut self.bold,
            "i" | "em" => &mut self.italic,
            _ => return None,
        })
    }

    fn apply(&self, state: &RunState) -> RunState {
        let mut s = state.clone();
        s.underline |= self.underline > 0;
        s.strike |= self.strike > 0;
        s.inline_code |= self.code > 0;
        s.bold |= self.bold > 0;
        s.italic |= self.italic > 0;
        if self.mark > 0 && s.fill == Fill::None {
            s.fill = Fill::Highlight;
        }
        if self.sup > 0 {
            s.script = Script::Sup;
        } else if self.sub > 0 {
            s.script = Script::Sub;
        }
        if s.link.is_none() {
            s.link = self.hrefs.last().cloned();
        }
        s
    }
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
    /// `==x==`.
    Highlight,
    /// `++x++`.
    Insert,
    /// `^x^`.
    Superscript,
    /// `||x||`.
    Spoiler,
    /// `[^name]`: the name, the note's number and whether this is its first reference.
    FootnoteRef(String, u32, bool),
    /// A `[x]` / `[ ]` that is a whole table cell (`tasklist_in_table`); true when checked.
    Task(bool),
    /// Everything this pass does not special-case (images, math, wikilinks, …):
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
        NodeValue::Highlight => Kind::Highlight,
        NodeValue::Insert => Kind::Insert,
        NodeValue::Superscript => Kind::Superscript,
        NodeValue::SpoileredText => Kind::Spoiler,
        NodeValue::FootnoteReference(r) => Kind::FootnoteRef(r.name.clone(), r.ix, r.ref_num <= 1),
        NodeValue::TaskItem(t) => Kind::Task(t.symbol.is_some()),
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
    html: HtmlOpen,
}

fn style_of(state: &RunState) -> CharacterStyle {
    CharacterStyle {
        bold: state.bold,
        italic: state.italic,
        strike: state.strike,
        inline_code: state.inline_code,
        underline: state.underline.then_some(UnderlineStyle::Single),
        background: match state.fill {
            Fill::None => None,
            Fill::Highlight => Some(color(HIGHLIGHT_FILL)),
            Fill::Spoiler => Some(color(SPOILER_FILL)),
        },
        foreground: (state.fill == Fill::Spoiler).then(|| color((0.4, 0.4, 0.4, 1.0))),
        vertical_position: match state.script {
            Script::Normal => VerticalPosition::Normal,
            Script::Sup => VerticalPosition::Superscript,
            Script::Sub => VerticalPosition::Subscript,
        },
        ..CharacterStyle::default()
    }
}

fn run_payload(text: String, style: CharacterStyle, link: Option<String>) -> NodePayload {
    NodePayload::TextRun(WireTextRun {
        text,
        style,
        direction: None,
        link,
        bookmark_ids: vec![],
        comment_ids: vec![],
        field: None,
        footnote_reference_number: None,
        form_control: None,
        page_number_field: None,
        column_flow: None,
    })
}

/// One free-standing text run under `parent_id` (alert titles, footnote back-arrows).
pub(super) fn push_text_run(
    ctx: &mut Ctx,
    parent_id: u64,
    text: &str,
    style: CharacterStyle,
    link: Option<String>,
) -> u64 {
    let id = ctx.new_node_id();
    ctx.push(RenderNodeDraft {
        id,
        parent_id: Some(parent_id),
        children: vec![],
        source_spans: vec![],
        edit: None,
        payload: run_payload(text.to_string(), style, link),
    });
    id
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
                payload: run_payload(text, style_of(&state), state.link),
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

    /// A raw inline HTML tag opens or closes a style on the text that follows it; `<br>` is a line
    /// break. The tag itself still reaches the tree as a `rawHtml` node (see `walk`).
    fn apply_html_tag(&mut self, source: &str) {
        match parse_html_tag(source) {
            HtmlTag::Hidden => {}
            HtmlTag::Open { name, href } => match name.as_str() {
                "br" => self.push_leaf(NodePayload::LineBreak(WireLineBreak { kind: LineBreakKind::Hard })),
                "a" => {
                    if let Some(href) = href {
                        self.html.hrefs.push(href);
                    }
                }
                other => {
                    if let Some(count) = self.html.counter(other) {
                        *count += 1;
                    }
                }
            },
            HtmlTag::Close(name) => {
                if name == "a" {
                    self.html.hrefs.pop();
                } else if let Some(count) = self.html.counter(&name) {
                    *count = count.saturating_sub(1);
                }
            }
        }
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
            Kind::Text(text) => {
                let s = self.html.apply(state);
                self.push_text(&s, &text)
            }
            Kind::SoftBreak => {
                let s = self.html.apply(state);
                self.push_text(&s, " ")
            }
            Kind::Code(literal) => {
                let mut s = self.html.apply(state);
                s.inline_code = true;
                self.push_text(&s, &literal);
            }
            Kind::HardBreak => {
                self.push_leaf(NodePayload::LineBreak(WireLineBreak { kind: LineBreakKind::Hard }))
            }
            Kind::Html(source) => {
                self.apply_html_tag(&source);
                self.push_leaf(NodePayload::RawHtml(WireRawHtml { block: false, source }))
            }
            Kind::Highlight => {
                let mut s = state.clone();
                s.fill = Fill::Highlight;
                self.walk_children(node, &s);
            }
            Kind::Insert => {
                let mut s = state.clone();
                s.underline = true;
                self.walk_children(node, &s);
            }
            Kind::Superscript => {
                let mut s = state.clone();
                s.script = Script::Sup;
                self.walk_children(node, &s);
            }
            Kind::Spoiler => {
                let mut s = state.clone();
                s.fill = Fill::Spoiler;
                self.walk_children(node, &s);
            }
            Kind::FootnoteRef(name, number, first) => {
                if first {
                    self.ctx.add_bookmark(format!("fnref:{name}"), self.parent_id);
                }
                let style = CharacterStyle {
                    vertical_position: VerticalPosition::Superscript,
                    ..CharacterStyle::default()
                };
                self.push_leaf(run_payload(number.to_string(), style, Some(format!("#fn:{name}"))));
            }
            Kind::Task(checked) => {
                let s = self.html.apply(state);
                self.push_text(&s, if checked { "\u{2611}" } else { "\u{2610}" });
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
    map_inline_children_with(node, parent_id, ctx, RunState::default())
}

/// A description-list term: its inline content in bold.
pub(super) fn map_bold_inline_children<'a>(node: &'a AstNode<'a>, parent_id: u64, ctx: &mut Ctx) -> Vec<u64> {
    map_inline_children_with(node, parent_id, ctx, RunState { bold: true, ..RunState::default() })
}

fn map_inline_children_with<'a>(
    node: &'a AstNode<'a>,
    parent_id: u64,
    ctx: &mut Ctx,
    initial: RunState,
) -> Vec<u64> {
    let mut builder = Builder { ctx, parent_id, pending: None, out: Vec::new(), html: HtmlOpen::default() };
    builder.walk_children(node, &initial);
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
pub(super) fn build_image(ctx: &mut Ctx, url: &str, alt: &str) -> WireImage {
    let (alt_clean, display_size, display_width_fraction) = parse_sized_alt(alt);
    let resource_id = ctx.resolve_image_resource(url);
    WireImage {
        resource_id: Some(resource_id),
        // `{0, 0}` is a finite, honest "not resolved" sentinel, never a guess — see
        // `Ctx::resolve_image_resource`'s doc comment for why this pass carries no real
        // intrinsic size at all.
        intrinsic_size: WireSize { width: 0.0, height: 0.0 },
        display_size,
        display_width_fraction,
        alignment: Alignment::Natural,
        alt_text: if alt_clean.is_empty() { None } else { Some(alt_clean) },
        // Markdown has no separate resource-vs-declaration split (`resolve_image_resource`
        // always resolves or synthesises a resource), so there is no case here needing the id
        // recovered from anywhere but the resource itself — same as office's `Some` path.
        source_key: None,
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
