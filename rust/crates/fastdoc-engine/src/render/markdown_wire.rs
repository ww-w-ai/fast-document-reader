//! The finished markdown string, as the host receives it.
//!
//! Markdown is the one format whose cost is NOT parsing. Measured on `demo/moby-dick.md`
//! (1,224,921 characters, release, minimum of three): the host's `MarkdownRenderer` spends
//! **97.8 ms parsing and 610 ms building the attributed string** — 86% of the bill is typography.
//! So moving markdown onto the engine means moving the TYPOGRAPHY, and what crosses is a finished
//! string rather than a tree for the host to re-typeset (the shape the office formats use, where
//! parsing genuinely is the cost).
//!
//! What the wire has to carry was counted, not guessed (`markdown_attribute_census`): over the
//! repo's own `demo/` corpus the ported renderer produces **47,025 runs** using exactly nineteen
//! (key, value-kind) pairs and no opaque payload. That census is the specification for this
//! module — a pair it does not list is a case deliberately absent here.
//!
//! Three decisions, each earned elsewhere in this repo rather than invented here:
//!
//! **Columnar, not an array of objects.** P4b measured that Foundation's cost is the nested
//! container, not the bytes: 5,494 of them were worth 139.5 ms of one document's decode
//! (invariant 129). 47,025 run objects would repeat that mistake at nine times the scale, so the
//! runs travel as parallel arrays of integers.
//!
//! **Interned, and for tables that is CORRECTNESS, not size.** Every cell of one table must end up
//! sharing ONE `NSTextTable` on the host — AppKit lays out a table by identity. Serialising each
//! cell's table by value would hand the host N separate one-cell tables that look like a shredded
//! grid, and nothing about that failure is visible in the bytes. Fonts, colours and paragraph
//! styles are interned for the ordinary reason: 36,937 font runs share a handful of fonts.
//!
//! **The wire carries LAYERS, not a flat run list — and that is not a shortcut.** The shim stores
//! what `addAttribute` was called with, in call order, as overlapping `(range, attributes)` entries
//! rather than the coalesced, tiling run list AppKit hands back from a finished string. Flattening
//! them here would mean re-deciding precedence in a second place; replaying them in order through
//! `addAttributes(_:range:)` is what AppKit itself does with the same calls, so the host arrives at
//! the string the renderer described by construction. **A reader who assumes these tile will build
//! a broken host**: they overlap, they are not sorted by location, and a character may be covered
//! by none of them.
//!
//! **Fonts travel as name + size + traits, not as a face the engine picked.** A markdown document
//! declares no typeface — the theme names one — so the pool is tiny, and the host rebuilds each
//! font the same way its own theme does. Per-script substitution stays on the host, where the real
//! font world is.

use std::collections::HashMap;
use swiftshim::color_font::{NSColor, NSFont};
use swiftshim::paragraph_style::{NSParagraphStyle, NSUnderlineStyle};
use swiftshim::text_table::{NSTextTable, NSTextTableBlock};
use swiftshim::{AttrValue, NSAttributedString, NSAttributedStringKey, NSRange};

/// Bumped when the shape below changes in a way a host built against the old one would misread.
/// The host refuses a wire it does not know rather than reading fields that have moved.
pub const MARKDOWN_WIRE_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireFont {
    pub name: String,
    pub size: f64,
    /// `NSFontDescriptorSymbolicTraits`' raw bits — bold is `1 << 1`, italic `1 << 0`.
    pub traits: u32,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireColor {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
    /// Which space those components are in — `NSColor(deviceRed:)` and `NSColor(srgbRed:)` are
    /// different colours on screen, so the space crosses with them.
    pub space: String,
}

/// One `NSTextTable`, referenced by index from every block that belongs to it.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireTable {
    pub columns: i32,
    pub collapses_borders: bool,
    pub hides_empty_cells: bool,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireTableBlock {
    /// Index into `tables` — the identity that makes the cells one grid.
    pub table: u32,
    pub row: i32,
    pub row_span: i32,
    pub column: i32,
    pub column_span: i32,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireParagraphStyle {
    pub alignment: i32,
    pub line_spacing: f64,
    pub paragraph_spacing: f64,
    pub paragraph_spacing_before: f64,
    pub first_line_head_indent: f64,
    pub head_indent: f64,
    pub tail_indent: f64,
    pub default_tab_interval: f64,
    pub line_height_multiple: f64,
    pub minimum_line_height: f64,
    pub maximum_line_height: f64,
    pub line_break_mode: i32,
    pub base_writing_direction: i32,
    pub line_break_strategy: u32,
    /// Tab stops as (alignment, location) — markdown sets these for list markers.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tab_stops: Vec<(i32, f64)>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub text_blocks: Vec<WireTableBlock>,
}

/// An attachment reserves a box; the pixels arrive later, from the host's own lazy media pass
/// (invariant 1). Only the size crosses.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireAttachment {
    pub width: f64,
    pub height: f64,
}

/// A custom attribute on one run — the MDAttr keys, sparse enough to travel as a list rather than
/// as twelve more columns that would be empty almost everywhere.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireExtra {
    /// Index into the layer columns.
    pub layer: u32,
    pub key: String,
    #[serde(flatten)]
    pub value: WireExtraValue,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "k", content = "v")]
pub enum WireExtraValue {
    #[serde(rename = "s")]
    Text(String),
    #[serde(rename = "i")]
    Int(i64),
    #[serde(rename = "b")]
    Bool(bool),
    #[serde(rename = "d")]
    Double(f64),
    /// `mdSrcRange` — a UTF-16 range back into the source, as (location, length).
    #[serde(rename = "r")]
    Range(u32, u32),
}

/// The whole document: the text, the pools, and the runs as columns.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct MarkdownWire {
    pub v: u32,
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fonts: Vec<WireFont>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub colors: Vec<WireColor>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub paragraph_styles: Vec<WireParagraphStyle>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tables: Vec<WireTable>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<WireAttachment>,
    /// Layer columns, all the same length and in CALL ORDER. `-1` means "this layer does not set
    /// that attribute". Replay them in order; do not assume they tile.
    pub layer_location: Vec<u32>,
    pub layer_length: Vec<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layer_font: Vec<i32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layer_color: Vec<i32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layer_paragraph: Vec<i32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layer_attachment: Vec<i32>,
    /// `NSUnderlineStyle` raw value, `0` for none. Underline and link travel together on a link
    /// run but are separate attributes, so they get separate columns.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layer_underline: Vec<i32>,
    /// Index into `link_targets`, `-1` for none — links repeat far less than they are long.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layer_link: Vec<i32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub link_targets: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extras: Vec<WireExtra>,
}

/// Interns a value into a pool, returning the index it landed at.
///
/// Keyed by the value's own JSON rather than by a hand-written `Hash`: these are small structs of
/// numbers and strings, the encoding is total and order-stable, and a hand-rolled hash would have
/// to be kept in step with the struct by hand — the same trade `edge_border_pool` makes.
struct Pool<T> {
    items: Vec<T>,
    seen: HashMap<String, u32>,
}

impl<T: serde::Serialize + Clone> Pool<T> {
    fn new() -> Self {
        Self { items: Vec::new(), seen: HashMap::new() }
    }

    fn intern(&mut self, value: T) -> u32 {
        let key = serde_json::to_string(&value).unwrap_or_default();
        if let Some(&index) = self.seen.get(&key) {
            return index;
        }
        let index = self.items.len() as u32;
        self.items.push(value);
        self.seen.insert(key, index);
        index
    }
}

fn wire_font(font: &NSFont) -> WireFont {
    WireFont {
        name: font.fontName(),
        size: font.pointSize(),
        traits: font.fontDescriptor().symbolicTraits().0,
    }
}

fn wire_color(color: &NSColor) -> WireColor {
    WireColor {
        r: color.red,
        g: color.green,
        b: color.blue,
        a: color.alpha,
        space: format!("{:?}", color.space),
    }
}

fn wire_table(table: &NSTextTable) -> WireTable {
    WireTable {
        columns: table.numberOfColumns,
        collapses_borders: table.collapsesBorders,
        hides_empty_cells: table.hidesEmptyCells,
    }
}

fn wire_paragraph_style(style: &NSParagraphStyle, tables: &mut Pool<WireTable>) -> WireParagraphStyle {
    WireParagraphStyle {
        alignment: style.alignment as i32,
        line_spacing: style.lineSpacing,
        paragraph_spacing: style.paragraphSpacing,
        paragraph_spacing_before: style.paragraphSpacingBefore,
        first_line_head_indent: style.firstLineHeadIndent,
        head_indent: style.headIndent,
        tail_indent: style.tailIndent,
        default_tab_interval: style.defaultTabInterval,
        line_height_multiple: style.lineHeightMultiple,
        minimum_line_height: style.minimumLineHeight,
        maximum_line_height: style.maximumLineHeight,
        line_break_mode: style.lineBreakMode as i32,
        base_writing_direction: style.baseWritingDirection as i32,
        line_break_strategy: style.lineBreakStrategy.0,
        tab_stops: style
            .tabStops
            .iter()
            .map(|tab| (tab.alignment as i32, tab.location))
            .collect(),
        text_blocks: style
            .textBlocks
            .iter()
            .map(|block: &NSTextTableBlock| WireTableBlock {
                table: tables.intern(wire_table(&block.table)),
                row: block.startingRow,
                row_span: block.rowSpan,
                column: block.startingColumn,
                column_span: block.columnSpan,
            })
            .collect(),
    }
}

fn extra_value(value: &AttrValue) -> Option<WireExtraValue> {
    Some(match value {
        AttrValue::Text(s) => WireExtraValue::Text(s.clone()),
        AttrValue::Int(i) => WireExtraValue::Int(*i),
        AttrValue::Bool(b) => WireExtraValue::Bool(*b),
        AttrValue::Double(d) => WireExtraValue::Double(*d),
        AttrValue::Range(NSRange { location, length }) => {
            WireExtraValue::Range(*location as u32, *length as u32)
        }
        // Fonts, colours, styles and attachments have their own columns; `Any` cannot cross at all
        // and the census asserts markdown never produces one.
        _ => return None,
    })
}

/// Project a finished markdown string onto the wire.
pub fn project(rendered: &NSAttributedString) -> MarkdownWire {
    let mut fonts = Pool::<WireFont>::new();
    let mut colors = Pool::<WireColor>::new();
    let mut styles = Pool::<WireParagraphStyle>::new();
    let mut tables = Pool::<WireTable>::new();
    let mut links = Pool::<String>::new();
    let mut attachments: Vec<WireAttachment> = Vec::new();

    let runs = rendered.runs();
    let mut wire = MarkdownWire {
        v: MARKDOWN_WIRE_VERSION,
        text: rendered.string().to_string(),
        fonts: Vec::new(),
        colors: Vec::new(),
        paragraph_styles: Vec::new(),
        tables: Vec::new(),
        attachments: Vec::new(),
        layer_location: Vec::with_capacity(runs.len()),
        layer_length: Vec::with_capacity(runs.len()),
        layer_font: vec![-1; runs.len()],
        layer_color: vec![-1; runs.len()],
        layer_paragraph: vec![-1; runs.len()],
        layer_attachment: vec![-1; runs.len()],
        layer_underline: vec![0; runs.len()],
        layer_link: vec![-1; runs.len()],
        link_targets: Vec::new(),
        extras: Vec::new(),
    };

    for (index, (range, attrs)) in runs.iter().enumerate() {
        wire.layer_location.push(range.location as u32);
        wire.layer_length.push(range.length as u32);
        for (key, value) in attrs {
            match (key, value) {
                (NSAttributedStringKey::Font, AttrValue::Font(f)) => {
                    wire.layer_font[index] = fonts.intern(wire_font(f)) as i32;
                }
                (NSAttributedStringKey::ForegroundColor, AttrValue::Color(c)) => {
                    wire.layer_color[index] = colors.intern(wire_color(c)) as i32;
                }
                (NSAttributedStringKey::ParagraphStyle, AttrValue::ParagraphStyle(p)) => {
                    let projected = wire_paragraph_style(p, &mut tables);
                    wire.layer_paragraph[index] = styles.intern(projected) as i32;
                }
                (NSAttributedStringKey::Attachment, AttrValue::Attachment(a)) => {
                    let size = a
                        .attachmentCell
                        .as_ref()
                        .map(|cell| cell.reservedSize)
                        .unwrap_or(swiftshim::NSSize { width: 0.0, height: 0.0 });
                    wire.layer_attachment[index] = attachments.len() as i32;
                    attachments.push(WireAttachment { width: size.width, height: size.height });
                }
                (NSAttributedStringKey::UnderlineStyle, AttrValue::UnderlineStyle(u)) => {
                    wire.layer_underline[index] = u.0 as i32;
                }
                (NSAttributedStringKey::Link, AttrValue::Text(target)) => {
                    wire.layer_link[index] = links.intern(target.clone()) as i32;
                }
                (NSAttributedStringKey::Custom(name), other) => {
                    if let Some(v) = extra_value(other) {
                        wire.extras.push(WireExtra {
                            layer: index as u32,
                            key: name.clone(),
                            value: v,
                        });
                    }
                }
                // A (key, kind) pair the census did not report. Dropping it silently is how a
                // wire quietly loses a feature, so say it once and keep going — the parity oracle
                // is what turns this into a failure.
                (key, value) => {
                    eprintln!(
                        "fastdoc: markdown wire has no column for {key:?} carrying {value:?}"
                    );
                }
            }
        }
    }

    // Extras are emitted in layer order but one layer's attributes come out of a `HashMap`, so the
    // entries WITHIN a layer arrive in an arbitrary order. Sorting makes the wire a function of
    // the document alone, which is what lets two runs of the same build be compared byte for byte.
    wire.extras.sort_by(|a, b| a.layer.cmp(&b.layer).then_with(|| a.key.cmp(&b.key)));

    wire.fonts = fonts.items;
    wire.colors = colors.items;
    wire.paragraph_styles = styles.items;
    wire.tables = tables.items;
    wire.attachments = attachments;
    wire.link_targets = links.items;
    wire
}
