//! The `swift-markdown` PACKAGE, standing behind the transliteration in `markdown_renderer.rs`.
//!
//! This file is deliberately NOT part of the port. `Render/MarkdownRenderer.swift` is a client of
//! Apple's `swift-markdown` package: it never parses anything itself, it walks a tree the package
//! hands it. So the transliteration declared the package's types locally and left four methods as
//! `todo!()` — `Document(parsing:)`, `Markup.children`, `Markup.range` and `Markup.accept(_:)` —
//! which is the whole of what a walker's client actually touches. Everything here fills exactly
//! those four, and nothing else: no rendering decision lives in this file, because every one of
//! them is in the transliteration next door and must stay comparable to the Swift line it came from.
//!
//! `swift-markdown` is cmark-gfm; the parser here is **comrak**, the same CommonMark+GFM parser the
//! canonical-tree producer already uses, with the same three extensions it settled on. Autolink is
//! deliberately OFF although the producer turns it on: `MarkdownRenderer.finishPasses` runs its own
//! `NSDataDetector` autolink pass over the rendered string, and a parser that had already made
//! links would have that pass run over its own output.

use comrak::nodes::{AlertType, AstNode, ListType, NodeValue, TableAlignment};
use comrak::{parse_document, Arena, Options};

use super::markdown_renderer::markdown::{
    Alert, AlertKind, BlockQuote, Checkbox, CodeBlock, ColumnAlignment, DescriptionItem,
    DescriptionList, Document, Emphasis, FootnoteDefinition, FootnoteReference, HTMLBlock, Heading,
    Image, InlineCode, InlineHTML, InlineKind, InlineStyle, Link, ListItem, Markup, OrderedList,
    Paragraph, SourceLocation, SourceRange, Strikethrough, Strong, Table, TableBody, TableCell,
    TableHead, TableRow, Text, ThematicBreak, UnorderedList,
};

/// What a `Markup` hands a walker, so `accept` can dispatch the way `MarkupWalker` does.
///
/// The default of every method is to descend, which is `MarkupWalker`'s own default — a walker that
/// overrides nothing still reaches every leaf.
pub trait MarkupWalker {
    fn visit(&mut self, markup: &Markup);
    fn descend_into(&mut self, markup: &Markup);
    fn visit_heading(&mut self, node: &Heading) {
        self.descend_into(&Markup::Heading(node.clone()))
    }
    fn visit_paragraph(&mut self, node: &Paragraph) {
        self.descend_into(&Markup::Paragraph(node.clone()))
    }
    fn visit_html_block(&mut self, node: &HTMLBlock) {
        self.descend_into(&Markup::HTMLBlock(node.clone()))
    }
    fn visit_block_quote(&mut self, node: &BlockQuote) {
        self.descend_into(&Markup::BlockQuote(node.clone()))
    }
    fn visit_unordered_list(&mut self, node: &UnorderedList) {
        self.descend_into(&Markup::UnorderedList(node.clone()))
    }
    fn visit_ordered_list(&mut self, node: &OrderedList) {
        self.descend_into(&Markup::OrderedList(node.clone()))
    }
    fn visit_code_block(&mut self, node: &CodeBlock) {
        self.descend_into(&Markup::CodeBlock(node.clone()))
    }
    fn visit_thematic_break(&mut self, node: &ThematicBreak) {
        self.descend_into(&Markup::ThematicBreak(node.clone()))
    }
    fn visit_table(&mut self, node: &Table) {
        self.descend_into(&Markup::Table(node.clone()))
    }
    fn visit_alert(&mut self, node: &Alert) {
        self.descend_into(&Markup::Alert(node.clone()))
    }
    fn visit_footnote_definition(&mut self, node: &FootnoteDefinition) {
        self.descend_into(&Markup::FootnoteDefinition(node.clone()))
    }
    fn visit_description_list(&mut self, node: &DescriptionList) {
        self.descend_into(&Markup::DescriptionList(node.clone()))
    }
}

/// `Markup.accept(_:)` — double dispatch into the walker's matching method.
///
/// A variant the Swift walker does not override reaches `visit`'s default, which descends. That is
/// why the inline variants are not listed one by one: `MarkdownRenderer` overrides nine `visit*`
/// methods and handles every inline shape inside them, exactly as it does against the real package.
pub fn accept<W: MarkupWalker + ?Sized>(markup: &Markup, walker: &mut W) {
    match markup {
        Markup::Heading(node) => walker.visit_heading(node),
        Markup::Paragraph(node) => walker.visit_paragraph(node),
        Markup::HTMLBlock(node) => walker.visit_html_block(node),
        Markup::BlockQuote(node) => walker.visit_block_quote(node),
        Markup::UnorderedList(node) => walker.visit_unordered_list(node),
        Markup::OrderedList(node) => walker.visit_ordered_list(node),
        Markup::CodeBlock(node) => walker.visit_code_block(node),
        Markup::ThematicBreak(node) => walker.visit_thematic_break(node),
        Markup::Table(node) => walker.visit_table(node),
        Markup::Alert(node) => walker.visit_alert(node),
        Markup::FootnoteDefinition(node) => walker.visit_footnote_definition(node),
        Markup::DescriptionList(node) => walker.visit_description_list(node),
        other => walker.descend_into(other),
    }
}

/// `Markup.children` — a container's children, an empty list for a leaf.
pub fn children(markup: &Markup) -> Vec<Markup> {
    match markup {
        Markup::Document(node) => node.children.clone(),
        Markup::Emphasis(node) => node.children.clone(),
        Markup::Strong(node) => node.children.clone(),
        Markup::Strikethrough(node) => node.children.clone(),
        Markup::Link(node) => node.children.clone(),
        Markup::Heading(node) => node.children.clone(),
        Markup::Paragraph(node) => node.children.clone(),
        Markup::BlockQuote(node) => node.children.clone(),
        Markup::ListItem(node) => node.children.clone(),
        Markup::TableCell(node) => node.children.clone(),
        Markup::InlineStyle(node) => node.children.clone(),
        Markup::Alert(node) => node.children.clone(),
        Markup::FootnoteDefinition(node) => node.children.clone(),
        Markup::UnorderedList(node) => {
            node.list_items.iter().cloned().map(Markup::ListItem).collect()
        }
        Markup::OrderedList(node) => {
            node.list_items.iter().cloned().map(Markup::ListItem).collect()
        }
        Markup::Table(node) => {
            let mut out: Vec<Markup> = node.head.cells.iter().cloned().map(Markup::TableCell).collect();
            for row in &node.body.rows {
                out.extend(row.cells.iter().cloned().map(Markup::TableCell));
            }
            out
        }
        Markup::Text(_)
        | Markup::InlineCode(_)
        | Markup::InlineHTML(_)
        | Markup::LineBreak
        | Markup::SoftBreak
        | Markup::Image(_)
        | Markup::CodeBlock(_)
        | Markup::ThematicBreak(_)
        | Markup::FootnoteReference(_)
        | Markup::DescriptionList(_)
        | Markup::HTMLBlock(_) => Vec::new(),
    }
}

/// `Markup.range` — the source range for the block shapes that carry one.
///
/// Only blocks record it, and only line numbers are ever read (`source_offsets` in the
/// transliteration ignores columns entirely), which is why an inline answers `None` rather than a
/// fabricated span.
pub fn range(markup: &Markup) -> Option<SourceRange> {
    match markup {
        Markup::Heading(node) => node.range,
        Markup::Paragraph(node) => node.range,
        Markup::HTMLBlock(node) => node.range,
        Markup::BlockQuote(node) => node.range,
        Markup::UnorderedList(node) => node.range,
        Markup::OrderedList(node) => node.range,
        Markup::CodeBlock(node) => node.range,
        Markup::ThematicBreak(node) => node.range,
        Markup::Table(node) => node.range,
        Markup::Alert(node) => node.range,
        Markup::FootnoteDefinition(node) => node.range,
        Markup::DescriptionList(node) => node.range,
        _ => None,
    }
}

/// `Document(parsing:)`.
pub fn parse_document_text(markdown: &str) -> Document {
    let arena = Arena::new();
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.tasklist = true;
    options.extension.strikethrough = true;
    // Everything below is rendered by `markdown_renderer.rs`. An extension is enabled here only
    // together with its renderer case (invariant 41: a feature can ship DEAD).
    if starts_with_front_matter(markdown) {
        options.extension.front_matter_delimiter = Some("---".to_string());
    }
    options.extension.footnotes = true;
    options.extension.inline_footnotes = true;
    options.extension.alerts = true;
    options.extension.description_lists = true;
    options.extension.superscript = true; // ^x^
    options.extension.highlight = true; // ==x==
    options.extension.insert = true; // ++x++
    options.extension.spoiler = true; // ||x||
    options.extension.multiline_block_quotes = true; // >>> … <<<
    options.extension.cjk_friendly_emphasis = true;
    options.extension.wikilinks_title_after_pipe = true; // [[target|text]]
    options.extension.header_attributes = true; // ## Title {#id}
    options.parse.relaxed_tasklist_matching = true;
    options.parse.tasklist_in_table = true;
    // DELIBERATELY OFF, and each for a measured reason:
    //  - `extension.underline` makes `__bold__` underline instead of bold; `<u>` and `++x++` cover it.
    //  - `extension.subscript` makes `~x~` subscript, which breaks GFM `~strike~`; `<sub>` covers it.
    //  - `greentext` turns every `>text` line into a styled non-quote.
    //  - `tagfilter` would escape the raw HTML the renderer interprets (`<u>`, `<br>`, `<mark>`).
    //  - `math_dollars` / `math_code`: formulas are claimed from the SOURCE by `scan_math_spans`
    //    before parsing (invariant 12); a second, parser-side `$…$` reading would fight that pass
    //    and turn prices ("$5 and $10") into formulas. `link_attributes` would swallow the Pandoc
    //    `![](x){width=N}` that `parse_pandoc_attr` already reads. `shortcodes` needs comrak's
    //    `emojis` crate, which this build does not carry.
    // swift-markdown parses through cmark-gfm with smart punctuation ON, so this reader has always
    // shown curly quotes, en/em dashes and ellipses for the ASCII an author typed. Off here, the
    // engine produced `'` where the app produces `’` on all five documents it ships — a difference
    // no structural test can see, because the tree is identical and only the leaf text changes.
    options.parse.smart = true;
    let root = parse_document(&arena, markdown, &options);
    let mut children: Vec<Markup> = root.children().filter_map(map_node).collect();
    finish_footnote_numbers(&mut children);
    Document { children }
}

/// Does the document open with a YAML front-matter block — `---`, key/value lines, `---`?
///
/// comrak's own rule is only "first line `---`, closed by another `---`", which also swallows a
/// document that merely OPENS with a thematic break and has another further down (everything
/// between them would vanish as "front matter"). So the block must also READ as YAML: every line
/// blank, a comment, indented, a `- ` item or a `key:` line.
pub(crate) fn starts_with_front_matter(markdown: &str) -> bool {
    let mut lines = markdown.trim_start_matches('\u{feff}').lines();
    if lines.next().map(str::trim_end) != Some("---") {
        return false;
    }
    let mut body = 0usize;
    for line in lines {
        let t = line.trim_end();
        if t == "---" || t == "..." {
            return body > 0;
        }
        if t.is_empty() {
            continue;
        }
        if t.starts_with('#') || t.starts_with(' ') || t.starts_with('\t') || t.starts_with("- ") {
            body += 1;
            continue;
        }
        let key = t.split(':').next().unwrap_or("");
        let is_key = t.contains(':')
            && !key.is_empty()
            && key.chars().all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | '"' | '\''));
        if !is_key {
            return false;
        }
        body += 1;
    }
    false
}

fn span<'a>(node: &'a AstNode<'a>) -> Option<SourceRange> {
    let pos = node.data.borrow().sourcepos;
    Some(SourceRange {
        lower_bound: SourceLocation {
            line: pos.start.line,
            column: pos.start.column,
        },
        upper_bound: SourceLocation {
            line: pos.end.line,
            column: pos.end.column,
        },
    })
}

fn kids<'a>(node: &'a AstNode<'a>) -> Vec<Markup> {
    node.children().filter_map(map_node).collect()
}

/// The plain text under a node, which is what an image's `plainText` is: its alt text.
fn plain_text<'a>(node: &'a AstNode<'a>) -> String {
    let mut out = String::new();
    fn walk<'a>(node: &'a AstNode<'a>, out: &mut String) {
        match &node.data.borrow().value {
            NodeValue::Text(text) => out.push_str(text),
            NodeValue::Code(code) => out.push_str(&code.literal),
            NodeValue::SoftBreak | NodeValue::LineBreak => out.push(' '),
            _ => {}
        }
        for child in node.children() {
            walk(child, out);
        }
    }
    walk(node, &mut out);
    out
}

fn list_items<'a>(node: &'a AstNode<'a>) -> Vec<ListItem> {
    node.children()
        .filter_map(|child| match &child.data.borrow().value {
            NodeValue::Item(_) => Some(ListItem {
                children: kids(child),
                checkbox: None,
            }),
            NodeValue::TaskItem(state) => Some(ListItem {
                children: kids(child),
                checkbox: Some(if state.symbol.is_some() {
                    Checkbox::Checked
                } else {
                    Checkbox::Unchecked
                }),
            }),
            _ => None,
        })
        .collect()
}

fn map_node<'a>(node: &'a AstNode<'a>) -> Option<Markup> {
    let value = node.data.borrow().value.clone();
    Some(match value {
        NodeValue::Document => Markup::Document(Document {
            children: kids(node),
        }),
        NodeValue::Heading(heading) => Markup::Heading(Heading {
            level: i32::from(heading.level),
            children: kids(node),
            range: span(node),
            anchor: node
                .data
                .borrow()
                .attrs
                .as_ref()
                .and_then(|attrs| attrs.id.clone())
                .filter(|id| !id.is_empty()),
        }),
        // A list's task items are read through `list_items`; one met here is a `[x]` that is the
        // whole content of a table cell (`tasklist_in_table`), which draws as the same box glyph.
        NodeValue::TaskItem(state) => Markup::Text(Text {
            string: if state.symbol.is_some() { "\u{2611}" } else { "\u{2610}" }.to_string(),
        }),
        NodeValue::Highlight => inline_style(node, InlineKind::Highlight),
        NodeValue::Insert => inline_style(node, InlineKind::Insert),
        NodeValue::Superscript => inline_style(node, InlineKind::Superscript),
        NodeValue::SpoileredText => inline_style(node, InlineKind::Spoiler),
        NodeValue::WikiLink(_) => inline_style(node, InlineKind::Plain),
        NodeValue::FootnoteReference(reference) => Markup::FootnoteReference(FootnoteReference {
            name: reference.name,
            number: reference.ix,
            first: reference.ref_num <= 1,
        }),
        NodeValue::FootnoteDefinition(definition) => {
            Markup::FootnoteDefinition(FootnoteDefinition {
                name: definition.name,
                // 1-based place among the notes; `finish_footnote_numbers` fills it in once the
                // whole document is mapped, because only the definitions' ORDER is known here.
                number: 0,
                children: kids(node),
                range: span(node),
            })
        }
        NodeValue::Alert(alert) => Markup::Alert(Alert {
            kind: match alert.alert_type {
                AlertType::Note => AlertKind::Note,
                AlertType::Tip => AlertKind::Tip,
                AlertType::Important => AlertKind::Important,
                AlertType::Warning => AlertKind::Warning,
                AlertType::Caution => AlertKind::Caution,
            },
            title: alert.title,
            children: kids(node),
            range: span(node),
        }),
        NodeValue::MultilineBlockQuote(_) => Markup::BlockQuote(BlockQuote {
            children: kids(node),
            range: span(node),
        }),
        NodeValue::DescriptionList => Markup::DescriptionList(DescriptionList {
            items: node.children().filter_map(description_item).collect(),
            range: span(node),
        }),
        NodeValue::Paragraph => Markup::Paragraph(Paragraph {
            children: kids(node),
            range: span(node),
        }),
        NodeValue::Text(text) => Markup::Text(Text { string: text.to_string() }),
        NodeValue::Emph => Markup::Emphasis(Emphasis {
            children: kids(node),
        }),
        NodeValue::Strong => Markup::Strong(Strong {
            children: kids(node),
        }),
        NodeValue::Strikethrough => Markup::Strikethrough(Strikethrough {
            children: kids(node),
        }),
        NodeValue::Code(code) => Markup::InlineCode(InlineCode {
            code: code.literal.to_string(),
        }),
        NodeValue::Link(link) => Markup::Link(Link {
            children: kids(node),
            destination: Some(link.url),
        }),
        NodeValue::Image(link) => Markup::Image(Image {
            source: Some(link.url),
            plain_text: plain_text(node),
        }),
        NodeValue::HtmlInline(raw) => Markup::InlineHTML(InlineHTML { raw_html: raw }),
        NodeValue::HtmlBlock(block) => Markup::HTMLBlock(HTMLBlock {
            raw_html: block.literal,
            range: span(node),
        }),
        NodeValue::LineBreak => Markup::LineBreak,
        NodeValue::SoftBreak => Markup::SoftBreak,
        NodeValue::BlockQuote => Markup::BlockQuote(BlockQuote {
            children: kids(node),
            range: span(node),
        }),
        NodeValue::List(list) => {
            let items = list_items(node);
            if list.list_type == ListType::Ordered {
                Markup::OrderedList(OrderedList {
                    list_items: items,
                    range: span(node),
                    start: list.start,
                })
            } else {
                Markup::UnorderedList(UnorderedList {
                    list_items: items,
                    range: span(node),
                })
            }
        }
        NodeValue::CodeBlock(block) => {
            let info = block.info.trim();
            Markup::CodeBlock(CodeBlock {
                language: if info.is_empty() {
                    None
                } else {
                    Some(info.split_whitespace().next().unwrap_or(info).to_string())
                },
                code: block.literal,
                range: span(node),
            })
        }
        NodeValue::ThematicBreak => Markup::ThematicBreak(ThematicBreak { range: span(node) }),
        NodeValue::Table(table) => {
            let alignments = table
                .alignments
                .iter()
                .map(|a| match a {
                    TableAlignment::None => ColumnAlignment::None,
                    TableAlignment::Left => ColumnAlignment::Left,
                    TableAlignment::Center => ColumnAlignment::Center,
                    TableAlignment::Right => ColumnAlignment::Right,
                })
                .collect();
            let mut rows = node.children();
            let head = rows
                .next()
                .map(|row| TableHead {
                    cells: table_cells(row),
                })
                .unwrap_or(TableHead { cells: Vec::new() });
            let body = TableBody {
                rows: rows
                    .map(|row| TableRow {
                        cells: table_cells(row),
                    })
                    .collect(),
            };
            Markup::Table(Table {
                head,
                body,
                range: span(node),
                alignments,
            })
        }
        // Items are reached through their list, cells through their table; anything else this
        // parser can produce has no shape in the walker's vocabulary and is dropped rather than
        // guessed at (the Swift walker never sees it either).
        _ => return None,
    })
}

fn inline_style<'a>(node: &'a AstNode<'a>, kind: InlineKind) -> Markup {
    Markup::InlineStyle(InlineStyle {
        kind,
        children: kids(node),
    })
}

/// A description item: its term's inline content and the blocks of each details.
fn description_item<'a>(item: &'a AstNode<'a>) -> Option<DescriptionItem> {
    if !matches!(item.data.borrow().value, NodeValue::DescriptionItem(_)) {
        return None;
    }
    let mut out = DescriptionItem::default();
    for part in item.children() {
        let value = part.data.borrow().value.clone();
        match value {
            NodeValue::DescriptionTerm => {
                // A term's content arrives as a paragraph; the renderer wants the inlines.
                for child in kids(part) {
                    match child {
                        Markup::Paragraph(p) => out.term.extend(p.children),
                        other => out.term.push(other),
                    }
                }
            }
            NodeValue::DescriptionDetails => out.details.push(kids(part)),
            _ => {}
        }
    }
    Some(out)
}

/// The notes comrak appended at the end are numbered in the order it sorted them — the order of
/// their first reference — which is the number every reference already carries.
fn finish_footnote_numbers(children: &mut [Markup]) {
    let mut next = 0u32;
    for child in children.iter_mut() {
        if let Markup::FootnoteDefinition(definition) = child {
            next += 1;
            definition.number = next;
        }
    }
}

fn table_cells<'a>(row: &'a AstNode<'a>) -> Vec<TableCell> {
    row.children()
        .map(|cell| TableCell {
            children: kids(cell),
        })
        .collect()
}
