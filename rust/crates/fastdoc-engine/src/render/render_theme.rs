//! swift: Render/RenderTheme.swift

use swiftshim::{CGFloat, NSColor, NSFont};

/// swift: `NSColor(rgb:alpha:)` — a 0xRRGGBB literal to sRGB. `swiftshim::NSColor` has no such
/// constructor (only `NSColor::srgb(red,green,blue,alpha)` on 0.0-1.0 components, see
/// color_font.rs's own header), so this file keeps the hex-literal decode local rather than
/// widening the shim for one call site.
fn rgb(hex: u32, alpha: CGFloat) -> NSColor {
    let r = ((hex >> 16) & 0xFF) as CGFloat / 255.0;
    let g = ((hex >> 8) & 0xFF) as CGFloat / 255.0;
    let b = (hex & 0xFF) as CGFloat / 255.0;
    NSColor::srgb(r, g, b, alpha)
}

/// swift: `NSColor.dynamic(light:dark:)` resolves against the live `NSAppearance` at draw time
/// in real AppKit. `swiftshim::NSColor::dynamic` has no appearance to resolve against, so it
/// returns a `DynamicColor` carrying both variants, and `DynamicColor::resolve` makes the choice.
/// Every call site here needs a concrete `NSColor` today (attribute values, `.setFill()`), so
/// this stays as a one-line spelling for the 17 of them.
///
/// The CHOICE itself is deliberately not here. `resolve` picks the light variant for now, and it
/// is the ONLY place in the tree that does — the shim's system colours go through the same
/// function. That matters on the day a host starts passing an appearance in: with one decision
/// point that day is one edit, and with two it is one edit plus a dark window whose code blocks
/// are still painted in light-mode colours.
fn dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor::dynamic(light, dark).resolve()
}

// swift: NSColor.dynamic
// extension NSColor {
//     /// sRGB from a 0xRRGGBB literal.
//     convenience init(rgb: UInt32, alpha: CGFloat = 1) { ... }
//     /// A light/dark dynamic color — resolves against whatever appearance is drawing it, so
//     /// it adapts automatically without asset catalogs.
//     static func dynamic(light: NSColor, dark: NSColor) -> NSColor { ... }
// }
//
// These two constructors live on `swiftshim::NSColor` itself (`NSColor::rgb` / `NSColor::dynamic`)
// rather than as free functions here, mirroring the Swift `extension NSColor`.

/// Notion-inspired reading palette. Warm near-neutral everything, with ONE reddish accent
/// (inline code) — the single deliberate spot of color, per the Notion reading view. Links
/// keep a restrained blue since they're now clickable (affordance). All values are
/// light/dark dynamic.
// swift: Palette
pub struct Palette;

impl Palette {
    pub fn text() -> NSColor {
        dynamic(rgb(0x373530, 1.0), rgb(0xD4D4D4, 1.0))
    }
    pub fn secondary() -> NSColor {
        dynamic(rgb(0x787774, 1.0), rgb(0x9B9B9B, 1.0))
    }
    pub fn inline_code_text() -> NSColor {
        dynamic(rgb(0xC4554D, 1.0), rgb(0xBE524B, 1.0))
    }
    // warm neutral chip, both modes
    pub fn inline_code_bg() -> NSColor {
        rgb(0x878378, 0.15)
    }
    pub fn code_card_bg() -> NSColor {
        dynamic(rgb(0xF7F6F3, 1.0), rgb(0x2F3437, 1.0))
    }
    pub fn code_card_border() -> NSColor {
        dynamic(rgb(0x000000, 0.09), rgb(0xFFFFFF, 0.12))
    }
    pub fn hairline() -> NSColor {
        dynamic(rgb(0x37352F, 0.12), rgb(0xFFFFFF, 0.14))
    }
    pub fn quote_bar() -> NSColor {
        dynamic(rgb(0x37352F, 0.30), rgb(0xFFFFFF, 0.30))
    }
    pub fn link() -> NSColor {
        dynamic(rgb(0x2E7AB8, 1.0), rgb(0x6CB0F5, 1.0))
    }
    // The band under the line the reading cursor sits on. Faint enough to be ambient, not read as a
    // selection — a touch of the link hue so it reads as "you are here", warm-neutral in both modes.
    pub fn reading_line() -> NSColor {
        dynamic(rgb(0x2E7AB8, 0.07), rgb(0x6CB0F5, 0.10))
    }
    pub fn table_border() -> NSColor {
        dynamic(rgb(0x37352F, 0.16), rgb(0xFFFFFF, 0.16))
    }
    // swift: Palette
    /// The colour a rule the DOCUMENT DREW takes when the document left the colour to us — Word's
    /// `w:color="auto"`, which means "the application decides" and which Word itself decides as
    /// BLACK. Only a PAGED document reaches this (`TableBlockBuilder.build`'s `paged`), where the
    /// reader is reproducing the author's own page: there, an ordinary ruled contract table drawn at
    /// `table_border`'s 16% tint renders washed out beside its own text — and worse, RAGGED, because
    /// the edges that did state a hex colour drew dark immediately next to it. Measured across three
    /// real reports, 2,184 of 10,832 drawn cell edges (20.2%) are `auto` with nothing stated
    /// anywhere above them, and one report alone mixes 1,853 such edges against 3,568 that carry
    /// their own colour — the same table, two weights, for no reason the reader can see.
    ///
    /// NOT Word's literal black. Blended over the page this is ≈ RGB(85,84,80) in light mode, a hair
    /// LIGHTER than the reader's own body text (`text`, RGB(55,53,48)): a 1pt pure-black grid on a
    /// backlit screen reads heavier than the prose it rules, inverting the hierarchy a reader wants,
    /// so one step back from black keeps the table unmistakably ruled while the words stay the
    /// darkest thing on the page. Dark mode mirrors that RELATIONSHIP rather than the value (≈
    /// RGB(192) against text at RGB(212) — a black rule would simply vanish there).
    ///
    /// Deliberately DISTINCT from `table_border`, which is unchanged and now means only two things:
    /// the reader's OWN invented stand-in rule, for an edge nothing in the document ever mentioned
    /// (invariant 47's third state, which must not start asserting itself as though an author had
    /// drawn it), and every non-paged table — markdown, and office with no page width — which
    /// invariant 36's parity harness holds byte-identical.
    pub fn table_border_authored() -> NSColor {
        dynamic(rgb(0x37352F, 0.85), rgb(0xFFFFFF, 0.70))
    }
    // warm neutral, both modes
    pub fn table_header_bg() -> NSColor {
        rgb(0x878378, 0.10)
    }
    /// The DESK a paged document's sheets lie on — drawn only where the page outline is on
    /// (`PageViewOptions`), in the `RenderTheme.PAGE_DESK_GAP` between one sheet and the next AND, as
    /// `NSScrollView.backgroundColor`, in the space beside a page narrower than the window.
    ///
    /// **OPAQUE on purpose.** It began as a translucent tint of the text colour, which composites
    /// correctly inside the text view (over paper) and WRONGLY beside it (over the window), so the two
    /// halves of the same desk were visibly different greys. These are the composited values —
    /// `0x37352F` at 11% over white, and black at 32% over the dark paper — stated once so both
    /// surfaces are literally the same colour rather than two that ought to match.
    ///
    /// Retuned from 4.5% before that: at that tint the space between two sheets was almost
    /// indistinguishable from the paper, so the pages read as one continuous run with a hairline in it
    /// rather than as separate sheets.
    pub fn page_desk() -> NSColor {
        dynamic(rgb(0xE9E9E8, 1.0), rgb(0x141414, 1.0))
    }
    /// The sheet's own edge — and, when the outline is OFF but a band still exists, the page-break
    /// hairline that closes it. Without one of the two the band reads as a hole in the document
    /// rather than as a page ending: the reader sees a long blank stretch and a header floating in
    /// it, with nothing saying why.
    pub fn page_gap_edge() -> NSColor {
        dynamic(rgb(0x37352F, 0.14), rgb(0xFFFFFF, 0.10))
    }
    // P6b: comment highlight — a faint amber wash behind a commented span (only drawn while the
    // comments panel is open, see `drawCommentMarks`), and the number badge it's paired with. Amber
    // rather than the reading-line's blue tint so the two "you should look here" signals never read
    // as the same kind of thing.
    pub fn comment_highlight() -> NSColor {
        dynamic(rgb(0xE9A23B, 0.16), rgb(0xE9A23B, 0.22))
    }
    // solid amber, both modes
    pub fn comment_badge_bg() -> NSColor {
        rgb(0xE9A23B, 1.0)
    }
}

// swift: RenderTheme
#[derive(Clone, Copy)]
pub struct RenderTheme {
    pub base_font_size: CGFloat,
}

impl RenderTheme {
    // swift: RenderTheme.current
    pub fn current(size: CGFloat) -> RenderTheme {
        RenderTheme { base_font_size: size }
    }

    // swift: RenderTheme.headingSize
    // Notion heading scale relative to a 16pt base: H1 30 / H2 24 / H3 20 / H4+ ~18.
    pub fn heading_size(&self, level: i32) -> CGFloat {
        match level {
            1 => self.base_font_size * 1.875,
            2 => self.base_font_size * 1.5,
            3 => self.base_font_size * 1.25,
            _ => self.base_font_size * 1.15,
        }
    }

    pub fn body_font(&self) -> NSFont {
        NSFont::systemFont(self.base_font_size)
    }
    // swift: RenderTheme.headingFont
    pub fn heading_font(&self, level: i32) -> NSFont {
        NSFont::systemFontWeight(self.heading_size(level), swiftshim::NSFontWeight::semibold)
    }
    pub fn code_font(&self) -> NSFont {
        NSFont::monospacedSystemFont(self.base_font_size * 0.9, swiftshim::NSFontWeight::regular)
    }

    pub fn text_color(&self) -> NSColor {
        Palette::text()
    }
    pub fn secondary_color(&self) -> NSColor {
        Palette::secondary()
    }
    pub fn link_color(&self) -> NSColor {
        Palette::link()
    }
    pub fn inline_code_color(&self) -> NSColor {
        Palette::inline_code_text()
    }
    pub fn inline_code_background(&self) -> NSColor {
        Palette::inline_code_bg()
    }
}

// MARK: - Rhythm tokens (shared BASE, every format)
//
// The same handful of ratios (line height, paragraph spacing, indent step, …) used to be
// hand-typed as `b * 1.45` / `b * 0.9` / … independently in `MarkdownRenderer`,
// `OfficeTextBuilder`, `TableBlockBuilder` and `PlainTextRenderer` — one literal per site, no
// single source of truth. These are that source: a bare ratio, multiplied by whatever base size
// (`base_font_size`, a heading size, the code font's point size) the ORIGINAL call site used —
// this hoist changes naming only, never the arithmetic or where `.rounded()` is applied, so
// rendered output stays byte-identical (see the P0 parity harness in `RenderThemeParityTests`).
// A ratio that only one format needs stays out of here and lives on that format's own thin
// style type instead (`MarkdownStyle` / `OfficeStyle` / `PlainTextStyle`, below).
impl RenderTheme {
    /// Within-paragraph line leading, as a multiple of the base font size. (Body text, image
    /// paragraphs, list items, plain text minimum line — every format's "normal" line.)
    pub fn line_height_ratio(&self) -> CGFloat {
        1.45
    }
    /// Gap AFTER a paragraph/body block, as a multiple of the base font size.
    pub fn paragraph_spacing_ratio(&self) -> CGFloat {
        0.9
    }
    /// The smaller gap used where blocks sit closer together (list items, headings' space-after).
    pub fn tight_spacing_ratio(&self) -> CGFloat {
        0.3
    }
    /// One list-indent step, as a multiple of the base font size (marker/text hang distance).
    pub fn list_hang_ratio(&self) -> CGFloat {
        1.7
    }
    /// Heading line leading, as a multiple of THAT heading's own font size (tighter than body).
    pub fn heading_line_height_ratio(&self) -> CGFloat {
        1.25
    }
    /// Gap AFTER a heading, as a multiple of the base font size (small — the heading should
    /// bond to the text below it).
    pub fn heading_spacing_after_ratio(&self) -> CGFloat {
        0.4
    }
    /// Code line leading, as a multiple of the code font's own point size (open enough to read
    /// as a bit more airy than a raw terminal). Also reused, applied to `base_font_size`, for a
    /// table cell's line height — the same "slightly open" rhythm, just off a different base.
    pub fn code_line_height_ratio(&self) -> CGFloat {
        1.4
    }
}

// MARK: - Rule widths (shared BASE, ABSOLUTE points)
//
// Unlike the rhythm ratios above these are not multiples of a font size — a hairline is a hairline
// at any reading size — but they follow the same rule: one definition, read by every renderer,
// never re-inlined as a literal at a call site (invariant 36).
impl RenderTheme {
    /// The reader's own table rule width, in ABSOLUTE points: what a cell edge draws at when neither
    /// the document, its table style, nor the table's own default states a width. Deliberately an INTEGER — a cell's
    /// content width subtracts its left and right rules from an integer column edge, so a fractional
    /// rule puts the boundary back on a fractional pixel, which is the drift invariant 42 records.
    /// The space BETWEEN two drawn sheets — the desk you can see between two pieces of paper lying on
    /// it. Reserved in layout only while the page outline is on, and NEVER printed.
    ///
    /// **This is not invariant 57(e)'s invented gap coming back, and the difference is the whole
    /// point.** That constant claimed to be the document's own inter-page space, which the document
    /// had actually stated (bottom margin + next top margin) and which the reader was overriding. This
    /// one is the opposite kind of number: two stacked sheets of paper TOUCH, so no document anywhere
    /// declares how far apart to draw them — it is a property of the desk, not of the page, and there
    /// is nothing to read it from. Word makes the same decision and lets you collapse it. Turn the
    /// outline off and it is not reserved at all.
    pub const PAGE_DESK_GAP: CGFloat = 12.0;

    pub const TABLE_BORDER_WIDTH: CGFloat = 1.0;
}

/// Markdown-only rhythm: values no other format needs, kept off the shared base per the
/// sprint's base-vs-branch split (see `RenderTheme`'s rhythm tokens doc above).
// swift: MarkdownStyle
pub struct MarkdownStyle {
    pub theme: RenderTheme,
}

impl MarkdownStyle {
    // swift: MarkdownStyle.headingSpacingBefore
    /// Block-quote left indent (head + first-line), as a multiple of the base font size.
    pub fn quote_indent_ratio(&self) -> CGFloat {
        1.25
    }
    // swift: MarkdownStyle.headingSpacingBefore
    /// Space BEFORE a heading — roomier for H1/H2 than H3+, so the top two levels read as
    /// clearly starting a new section.
    pub fn heading_spacing_before(&self, level: i32) -> CGFloat {
        self.theme.base_font_size * (if level <= 2 { 1.9 } else { 1.4 })
    }
}

/// Office (.docx/.odt)-only rhythm: values no other format needs.
// swift: OfficeStyle
pub struct OfficeStyle {
    pub theme: RenderTheme,
}

impl OfficeStyle {
    /// Readability FLOOR for office body line height, as a multiple of the paragraph's own font
    /// size. A `.docx`/`.odt` commonly declares a near-single line rule (`w:line="260" w:lineRule=
    /// "auto"` = 1.083×) that, measured against the reader's substituted body font (system font,
    /// natural line ≈ 1.13× — SHORTER than the CJK fonts Word lays these against, ≈ 1.3×), renders
    /// noticeably tighter than Word shows AND than this same reader's own MARKDOWN body (`lineHeight
    /// Ratio` 1.45×). In a reader-first viewer, one editor rendering the same prose far tighter than
    /// another reads as a defect, so office body never drops below this floor — while a document that
    /// asks for MORE than the floor still gets exactly what it asked for (the floor is a minimum, the
    /// maximum stays cleared). Kept a hair under `line_height_ratio` so a deliberately-tightened
    /// document still reads a touch denser than the app's own default, not identical to it.
    pub fn body_min_line_height_ratio(&self) -> CGFloat {
        1.4
    }
    // swift: OfficeStyle.headingSpacingBefore
    /// Readability FLOOR for the gap AFTER an office body paragraph, as a multiple of the base font
    /// size. A dense document commonly sets a tiny `w:after` (this doc: `w:after="30"` = 1.5pt on 206
    /// of its paragraphs), which renders consecutive bullets/lines packed almost edge to edge — the
    /// "따닥 붙어 있는" feeling — far tighter than this same reader's markdown body. So a POSITIVE
    /// author gap never renders below this floor, while a LARGER gap (a section break's 9pt) is kept
    /// as-is. A gap the author (or `contextualSpacing`) set to EXACTLY zero stays zero — that is a
    /// deliberate "no space between these" the floor must not override.
    pub fn body_min_paragraph_spacing_ratio(&self) -> CGFloat {
        0.35
    }
    // swift: OfficeStyle.headingSpacingBefore
    /// Space BEFORE a heading — same shape as `MarkdownStyle`'s (roomier for H1/H2), kept as
    /// this format's own copy rather than merged into the base per the sprint's design (a value
    /// only one format uses lives on that format's branch, even when two branches happen to
    /// agree on the number).
    pub fn heading_spacing_before(&self, level: i32) -> CGFloat {
        self.theme.base_font_size * (if level <= 2 { 1.9 } else { 1.4 })
    }
}

/// Plain-text (.txt/.csv/.log…)-only rhythm: values no other format needs.
// swift: PlainTextStyle
pub struct PlainTextStyle {
    pub theme: RenderTheme,
}

impl PlainTextStyle {
    /// Monospace font size, as a fraction of the base font size (slightly smaller than prose).
    pub fn mono_size_ratio(&self) -> CGFloat {
        0.95
    }
}
