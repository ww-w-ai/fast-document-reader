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

use comrak::nodes::{AstNode, ListType, NodeValue};
use comrak::{parse_document, Arena, Options};

use super::markdown_renderer::markdown::{
    BlockQuote, Checkbox, CodeBlock, Document, Emphasis, HTMLBlock, Heading, Image, InlineCode,
    InlineHTML, Link, ListItem, Markup, OrderedList, Paragraph, SourceLocation, SourceRange,
    Strikethrough, Strong, Table, TableBody, TableCell, TableHead, TableRow, Text, ThematicBreak,
    UnorderedList,
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
    // swift-markdown parses through cmark-gfm with smart punctuation ON, so this reader has always
    // shown curly quotes, en/em dashes and ellipses for the ASCII an author typed. Off here, the
    // engine produced `'` where the app produces `’` on all five documents it ships — a difference
    // no structural test can see, because the tree is identical and only the leaf text changes.
    options.parse.smart = true;
    let root = parse_document(&arena, markdown, &options);
    Document {
        children: root.children().filter_map(map_node).collect(),
    }
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
        NodeValue::Table(_) => {
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
            })
        }
        // Items are reached through their list, cells through their table; anything else this
        // parser can produce has no shape in the walker's vocabulary and is dropped rather than
        // guessed at (the Swift walker never sees it either).
        _ => return None,
    })
}

fn table_cells<'a>(row: &'a AstNode<'a>) -> Vec<TableCell> {
    row.children()
        .map(|cell| TableCell {
            children: kids(cell),
        })
        .collect()
}
