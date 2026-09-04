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
use swiftshim::paragraph_style::{
    NSParagraphStyle, NSTextAlignment, NSUnderlineStyle, NSWritingDirection,
};
use crate::render::render_theme::RenderTheme;
use swiftshim::text_table::{NSTextTable, NSTextTableBlock};
use swiftshim::{AttrValue, NSAttributedString, NSAttributedStringKey, NSRange};

/// Bumped when the shape below changes in a way a host built against the old one would misread.
/// The host refuses a wire it does not know rather than reading fields that have moved.
pub const MARKDOWN_WIRE_VERSION: u32 = 2;

/// A font as the renderer MEANT it: which of the theme's three roles it came from, plus whatever
/// traits were laid on top.
///
/// The resolved face travels too, but only as a fallback. Sending the face as the primary value is
/// what the first version of this wire did, and it was wrong in a way no shape test can see: a
/// system font's descriptor does not round-trip. `NSFont.systemFont(ofSize:weight:)` is the
/// private `.AppleSystemUIFontDemi` UI cascade, and feeding its own descriptor back to
/// `NSFont(descriptor:size:)` yields the concrete `.SFNS-Semibold` instead — a different face,
/// with different metrics (6.33 against 6.41 advance at 30pt) and without the cascade that finds a
/// glyph for a script the base face does not cover. Sending the ROLE instead means the host
/// rebuilds it with the very same AppKit call the renderer would have made, so the two agree by
/// construction rather than by a round trip that happens to work.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireFont {
    /// `body` · `heading` · `code` · `raw` (the theme does not explain this one).
    pub role: String,
    /// Heading level, `0` for the other roles.
    #[serde(default, skip_serializing_if = "is_zero_i32")]
    pub level: i32,
    /// `NSFontDescriptorSymbolicTraits`' raw bits — bold is `1 << 1`, italic `1 << 0`.
    pub traits: u32,
    /// The resolved face and size. Authoritative only for `raw`; elsewhere it is what the engine
    /// happened to resolve, kept so a divergence can be SEEN rather than guessed at.
    pub name: String,
    pub size: f64,
}

fn is_zero_i32(value: &i32) -> bool {
    *value == 0
}

/// A colour as the renderer MEANT it, for the same reason `WireFont` carries a role.
///
/// Every colour markdown uses is one of the theme's palette entries, and every one of THOSE is a
/// light/dark dynamic that resolves against the appearance drawing it. The engine's `NSColor` has
/// no appearance to resolve against, so it keeps the light half (`swiftshim`'s documented phase-A
/// shortcut) — which means a wire carrying components alone renders the whole document in light
/// mode forever, in a build that has supported dark mode since the beginning. The role is what the
/// host needs to rebuild the dynamic colour itself.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireColor {
    /// `text` · `secondary` · `link` · `inlineCode` · `raw`.
    pub role: String,
    /// The resolved components. Authoritative only for `raw` — see the type's own doc.
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
    /// The grid: one share per column summing to 1, the outer margins and the width cap —
    /// what the host's `resizeTables` re-solves a table by on every reflow. Without it the host
    /// built a bare `NSTextTable`, which that pass skips (invariant 162).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub column_proportions: Vec<f64>,
    #[serde(default)]
    pub outer_margin_left: f64,
    #[serde(default)]
    pub outer_margin_right: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_width: Option<f64>,
}

fn all_zero(edges: &[f64; 4]) -> bool {
    edges.iter().all(|w| *w == 0.0)
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WireTableBlock {
    /// Index into `tables` — the identity that makes the cells one grid.
    pub table: u32,
    pub row: i32,
    pub row_span: i32,
    pub column: i32,
    pub column_span: i32,
    /// The cell's box, as the builder decided it — `minX, minY, maxX, maxY` for the two edge
    /// arrays, colours as indices into the colour pool (a rule's colour is a theme ROLE, so it
    /// resolves to the appearance drawing it, like every other colour on this wire). A block that
    /// left the builder with padding, rules and a header tint and arrived at the host with none
    /// is invariant 162.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_width: Option<f64>,
    #[serde(default, skip_serializing_if = "all_zero")]
    pub padding: [f64; 4],
    #[serde(default, skip_serializing_if = "all_zero")]
    pub border: [f64; 4],
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub border_colors: Vec<(i32, u32)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<u32>,
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

    /// Intern under a caller-chosen key rather than under the value's own JSON.
    ///
    /// For everything that is a VALUE — a font, a colour, a paragraph style — two equal things are
    /// one thing, and `intern` is right. A table is not a value: AppKit lays a grid out by which
    /// `NSTextTable` its cells point at, and every markdown table declares the identical thing, so
    /// `intern` would merge them all. `builder` is only called on a miss, so the value need not be
    /// built for a table already in the pool.
    fn intern_by(&mut self, key: impl std::fmt::Display, builder: impl FnOnce() -> T) -> u32 {
        let key = key.to_string();
        if let Some(&index) = self.seen.get(&key) {
            return index;
        }
        let index = self.items.len() as u32;
        self.items.push(builder());
        self.seen.insert(key, index);
        index
    }
}

fn wire_font(font: &NSFont) -> WireFont {
    WireFont {
        role: "raw".to_string(),
        level: 0,
        traits: font.fontDescriptor().symbolicTraits().0,
        name: font.fontName(),
        size: font.pointSize(),
    }
}

/// Every font and colour the theme can produce, keyed by what the renderer would have resolved it
/// to — so a value found in the finished string can be named by the ROLE that made it.
///
/// Built once per document. The four trait combinations are enumerated rather than derived because
/// adding traits goes through the host's font provider (that is the whole point of the provider,
/// invariant 52), so the only honest way to know what `body + bold` resolves to is to ask.
struct ThemeRoles {
    fonts: HashMap<String, (String, i32, u32)>,
    colors: HashMap<String, String>,
}

/// The identity of a resolved font, as a map key: two fonts are the same iff a reader cannot tell
/// them apart.
fn font_key(font: &NSFont) -> String {
    format!(
        "{}|{}|{}",
        font.fontName(),
        font.pointSize(),
        font.fontDescriptor().symbolicTraits().0
    )
}

fn color_key(color: &NSColor) -> String {
    format!(
        "{}|{}|{}|{}|{:?}",
        color.red, color.green, color.blue, color.alpha, color.space
    )
}

impl ThemeRoles {
    fn of(theme: &RenderTheme) -> Self {
        use swiftshim::NSFontDescriptorSymbolicTraits as Traits;
        let mut fonts = HashMap::new();
        let mut bases: Vec<(String, i32, NSFont)> = vec![
            ("body".to_string(), 0, theme.body_font()),
            ("code".to_string(), 0, theme.code_font()),
            // A markdown table's header row, which asks for a system SEMIBOLD directly rather than
            // through any of the theme's three accessors (`MarkdownRenderer.swift:773`). It is a
            // role like the others as far as this wire is concerned: without it the header font
            // falls through to `raw` and comes back as a concrete face.
            (
                "tableHeader".to_string(),
                0,
                NSFont::systemFontWeight(theme.base_font_size, swiftshim::NSFontWeight::semibold),
            ),
        ];
        // Six is markdown's own ceiling — `# ` through `###### `. A level outside that is not a
        // heading, so there is nothing to enumerate past it.
        for level in 1..=6 {
            bases.push(("heading".to_string(), level, theme.heading_font(level)));
        }
        for (role, level, base) in bases {
            // The untouched base goes in AS ITSELF, never through a descriptor: a system font's
            // descriptor does not round-trip (`NSFont.systemFont(ofSize:weight:)` is the private
            // `.AppleSystemUIFontDemi` cascade and rebuilding it yields the concrete
            // `.SFNS-Semibold`), so recomputing it here would key the table on a face the renderer
            // never produced — and every plain heading would then miss its role and be sent as a
            // trait-laden `raw`.
            fonts
                .entry(font_key(&base))
                .or_insert((role.clone(), level, 0));
            for extra in [Traits::bold, Traits::italic, Traits::bold.union(Traits::italic)] {
                let d = base.fontDescriptor();
                let d = d.withSymbolicTraits(d.symbolicTraits().union(extra));
                let resolved =
                    NSFont::with_descriptor(&d, base.pointSize()).unwrap_or_else(|| base.clone());
                // `entry` and not `insert`: the base goes in first for each role, so a face two
                // roles happen to share keeps the FIRST role that named it rather than whichever
                // came last, which would depend on iteration order.
                fonts
                    .entry(font_key(&resolved))
                    .or_insert((role.clone(), level, extra.0));
            }
        }

        let mut colors = HashMap::new();
        use swiftshim::color_font::system_colors;
        for (role, color) in [
            ("text", theme.text_color()),
            ("secondary", theme.secondary_color()),
            ("link", theme.link_color()),
            ("inlineCode", theme.inline_code_color()),
            // Code highlighting paints with AppKit's own named system colours rather than with
            // the palette, and those are dynamic too — a fenced block would otherwise keep its
            // light-appearance keyword colours in dark mode.
            ("systemRed", system_colors::systemRed()),
            ("systemOrange", system_colors::systemOrange()),
            ("systemGreen", system_colors::systemGreen()),
            ("systemPink", system_colors::systemPink()),
            ("systemTeal", system_colors::systemTeal()),
            ("secondaryLabel", system_colors::secondaryLabelColor()),
            ("tableBorder", crate::render::render_theme::Palette::table_border()),
            ("tableBorderAuthored", crate::render::render_theme::Palette::table_border_authored()),
            ("tableHeaderBg", crate::render::render_theme::Palette::table_header_bg()),
        ] {
            colors.entry(color_key(&color)).or_insert(role.to_string());
        }
        ThemeRoles { fonts, colors }
    }
}

fn wire_color(color: &NSColor) -> WireColor {
    WireColor {
        role: "raw".to_string(),
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
        column_proportions: table.column_proportions.clone(),
        outer_margin_left: table.outer_margin_left,
        outer_margin_right: table.outer_margin_right,
        max_width: table.max_width,
    }
}

/// AppKit's `NSRectEdge` raw values, which is what the host decodes the edge as.
const WIRE_EDGES: [(swiftshim::NSRectEdge, i32); 4] = [
    (swiftshim::NSRectEdge::MinX, 0),
    (swiftshim::NSRectEdge::MinY, 1),
    (swiftshim::NSRectEdge::MaxX, 2),
    (swiftshim::NSRectEdge::MaxY, 3),
];

fn interned_color(color: &NSColor, roles: &ThemeRoles, colors: &mut Pool<WireColor>) -> u32 {
    let mut projected = wire_color(color);
    if let Some(role) = roles.colors.get(&color_key(color)) {
        projected.role = role.clone();
    }
    colors.intern(projected)
}

fn wire_table_block(
    block: &NSTextTableBlock,
    tables: &mut Pool<WireTable>,
    roles: &ThemeRoles,
    colors: &mut Pool<WireColor>,
) -> WireTableBlock {
    use swiftshim::NSTextBlockLayer;
    let edge_widths = |layer: NSTextBlockLayer| -> [f64; 4] {
        let mut out = [0.0; 4];
        for (i, (edge, _)) in WIRE_EDGES.iter().enumerate() {
            out[i] = block.base.width(layer, *edge);
        }
        out
    };
    WireTableBlock {
        // Keyed by IDENTITY, never by the table's declaration: every markdown table declares the
        // same thing, so pooling by value merged every table in a document into one grid.
        table: tables.intern_by(block.table.identity(), || wire_table(&block.table)),
        row: block.startingRow,
        row_span: block.rowSpan,
        column: block.startingColumn,
        column_span: block.columnSpan,
        content_width: block.base.contentWidth().map(|(width, _)| width),
        padding: edge_widths(NSTextBlockLayer::Padding),
        border: edge_widths(NSTextBlockLayer::Border),
        border_colors: WIRE_EDGES
            .iter()
            .filter_map(|(edge, code)| {
                block.base.borderColor(*edge).map(|c| (*code, interned_color(&c, roles, colors)))
            })
            .collect(),
        background: block.base.backgroundColor.as_ref().map(|c| interned_color(c, roles, colors)),
    }
}

/// AppKit's OWN raw value for an alignment, which is what the host reconstructs from.
///
/// `as i32` on the shim's enum would send its DECLARATION ORDER instead. That happens to agree
/// for alignment today and does NOT for writing direction, and nothing in the shim promises it
/// ever will — these enums have no explicit discriminants because nothing inside the engine reads
/// them as numbers. The wire is the one place the number matters, so the wire is where it is named.
fn appkit_alignment(alignment: NSTextAlignment) -> i32 {
    match alignment {
        NSTextAlignment::Left => 0,
        NSTextAlignment::Right => 1,
        NSTextAlignment::Center => 2,
        NSTextAlignment::Justified => 3,
        NSTextAlignment::Natural => 4,
    }
}

/// AppKit numbers `natural` as -1, not as 0 — see `appkit_alignment`.
fn appkit_writing_direction(direction: NSWritingDirection) -> i32 {
    match direction {
        NSWritingDirection::Natural => -1,
        NSWritingDirection::LeftToRight => 0,
        NSWritingDirection::RightToLeft => 1,
    }
}

fn wire_paragraph_style(
    style: &NSParagraphStyle,
    tables: &mut Pool<WireTable>,
    roles: &ThemeRoles,
    colors: &mut Pool<WireColor>,
) -> WireParagraphStyle {
    WireParagraphStyle {
        alignment: appkit_alignment(style.alignment),
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
        base_writing_direction: appkit_writing_direction(style.baseWritingDirection),
        line_break_strategy: style.lineBreakStrategy.0,
        tab_stops: style
            .tabStops
            .iter()
            .map(|tab| (appkit_alignment(tab.alignment), tab.location))
            .collect(),
        text_blocks: style
            .textBlocks
            .iter()
            .map(|block: &NSTextTableBlock| wire_table_block(block, tables, roles, colors))
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
///
/// The THEME is a parameter because the wire names fonts and colours by the role that produced
/// them (see `WireFont` and `WireColor`), and only the theme knows which role a resolved value
/// came from. Pass the same theme the string was rendered with; any other one turns every value
/// into a `raw`, which is correct but loses the dark-mode and font-cascade fidelity the roles buy.
pub fn project(rendered: &NSAttributedString, theme: &RenderTheme) -> MarkdownWire {
    let roles = ThemeRoles::of(theme);
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
                    let mut projected = wire_font(f);
                    if let Some((role, level, traits)) = roles.fonts.get(&font_key(f)) {
                        projected.role = role.clone();
                        projected.level = *level;
                        projected.traits = *traits;
                    }
                    wire.layer_font[index] = fonts.intern(projected) as i32;
                }
                (NSAttributedStringKey::ForegroundColor, AttrValue::Color(c)) => {
                    wire.layer_color[index] = interned_color(c, &roles, &mut colors) as i32;
                }
                (NSAttributedStringKey::ParagraphStyle, AttrValue::ParagraphStyle(p)) => {
                    let projected = wire_paragraph_style(p, &mut tables, &roles, &mut colors);
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
