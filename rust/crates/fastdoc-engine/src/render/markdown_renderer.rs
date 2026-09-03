//! swift: Render/MarkdownRenderer.swift

// swift: this file names types from the `swift-markdown` package (`import Markdown`) — Document,
// Markup, MarkupWalker, Heading, Paragraph, Text, Emphasis, Strong, InlineCode, Link, Image,
// InlineHTML, LineBreak, SoftBreak, Strikethrough, UnorderedList, OrderedList, ListItem,
// BlockQuote, CodeBlock, ThematicBreak, Table (+Cell/Row), HTMLBlock, SourceRange,
// SourceLocation, Checkbox. No other in-scope file touches that package, so its stand-ins are
// declared locally in this module rather than in `swiftshim` (which is Foundation/AppKit only —
// convention §4) or duplicated by a future worker. Real parsing is phase B; every method below is
// `todo!()` until then, exactly like a missing `swiftshim` type would be.
pub mod markdown {
    /// swift: Markdown.SourceLocation
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct SourceLocation {
        pub line: usize,
        pub column: usize,
    }

    /// swift: Markdown.SourceRange
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct SourceRange {
        pub lower_bound: SourceLocation,
        pub upper_bound: SourceLocation,
    }

    /// swift: Markdown.Checkbox
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Checkbox {
        Checked,
        Unchecked,
    }

    /// swift: Markdown.Document
    #[derive(Debug, Clone, Default)]
    pub struct Document {
        pub children: Vec<Markup>,
    }

    impl Document {
        pub fn parsing(markdown: &str) -> Self {
            // The package's own parse, which this file is a CLIENT of — see `markdown_package`.
            crate::render::markdown_package::parse_document_text(markdown)
        }
    }

    /// swift: Markdown.Text
    #[derive(Debug, Clone)]
    pub struct Text {
        pub string: String,
    }

    /// swift: Markdown.Emphasis
    #[derive(Debug, Clone, Default)]
    pub struct Emphasis {
        pub children: Vec<Markup>,
    }

    /// swift: Markdown.Strong
    #[derive(Debug, Clone, Default)]
    pub struct Strong {
        pub children: Vec<Markup>,
    }

    /// swift: Markdown.InlineCode
    #[derive(Debug, Clone)]
    pub struct InlineCode {
        pub code: String,
    }

    /// swift: Markdown.Link
    #[derive(Debug, Clone, Default)]
    pub struct Link {
        pub children: Vec<Markup>,
        pub destination: Option<String>,
    }

    /// swift: Markdown.InlineHTML
    #[derive(Debug, Clone)]
    pub struct InlineHTML {
        pub raw_html: String,
    }

    /// swift: Markdown.Strikethrough
    #[derive(Debug, Clone, Default)]
    pub struct Strikethrough {
        pub children: Vec<Markup>,
    }

    /// swift: Markdown.Image
    #[derive(Debug, Clone, Default)]
    pub struct Image {
        pub source: Option<String>,
        pub plain_text: String,
    }

    /// swift: Markdown.Heading
    #[derive(Debug, Clone, Default)]
    pub struct Heading {
        pub level: i32,
        pub children: Vec<Markup>,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.Paragraph
    #[derive(Debug, Clone, Default)]
    pub struct Paragraph {
        pub children: Vec<Markup>,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.HTMLBlock
    #[derive(Debug, Clone)]
    pub struct HTMLBlock {
        pub raw_html: String,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.BlockQuote
    #[derive(Debug, Clone, Default)]
    pub struct BlockQuote {
        pub children: Vec<Markup>,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.ListItem
    #[derive(Debug, Clone, Default)]
    pub struct ListItem {
        pub children: Vec<Markup>,
        pub checkbox: Option<Checkbox>,
    }

    /// swift: Markdown.UnorderedList
    #[derive(Debug, Clone, Default)]
    pub struct UnorderedList {
        pub list_items: Vec<ListItem>,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.OrderedList
    #[derive(Debug, Clone, Default)]
    pub struct OrderedList {
        pub list_items: Vec<ListItem>,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.CodeBlock
    #[derive(Debug, Clone)]
    pub struct CodeBlock {
        pub language: Option<String>,
        pub code: String,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.ThematicBreak
    #[derive(Debug, Clone)]
    pub struct ThematicBreak {
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.Table.Cell
    #[derive(Debug, Clone, Default)]
    pub struct TableCell {
        pub children: Vec<Markup>,
    }

    /// swift: Markdown.Table.Row
    #[derive(Debug, Clone, Default)]
    pub struct TableRow {
        pub cells: Vec<TableCell>,
    }

    /// swift: Markdown.Table.Head
    #[derive(Debug, Clone, Default)]
    pub struct TableHead {
        pub cells: Vec<TableCell>,
    }

    /// swift: Markdown.Table.Body
    #[derive(Debug, Clone, Default)]
    pub struct TableBody {
        pub rows: Vec<TableRow>,
    }

    /// swift: Markdown.Table
    #[derive(Debug, Clone, Default)]
    pub struct Table {
        pub head: TableHead,
        pub body: TableBody,
        pub range: Option<SourceRange>,
    }

    /// swift: Markdown.Markup — an existential protocol every node conforms to; call sites
    /// downcast with `as?`. Modeled as a closed enum since Rust has no safe dynamic-typing
    /// equivalent worth building for phase A (the same call `swiftshim::AttrValue` makes).
    #[derive(Debug, Clone)]
    pub enum Markup {
        Text(Text),
        Emphasis(Emphasis),
        Strong(Strong),
        InlineCode(InlineCode),
        Link(Link),
        InlineHTML(InlineHTML),
        LineBreak,
        SoftBreak,
        Strikethrough(Strikethrough),
        Image(Image),
        Heading(Heading),
        Paragraph(Paragraph),
        HTMLBlock(HTMLBlock),
        BlockQuote(BlockQuote),
        UnorderedList(UnorderedList),
        OrderedList(OrderedList),
        ListItem(ListItem),
        CodeBlock(CodeBlock),
        ThematicBreak(ThematicBreak),
        Table(Table),
        TableCell(TableCell),
        Document(Document),
    }

    impl Markup {
        /// swift: Markup.children
        pub fn children(&self) -> Vec<Markup> {
            crate::render::markdown_package::children(self)
        }
        /// swift: Markup.range
        pub fn range(&self) -> Option<SourceRange> {
            crate::render::markdown_package::range(self)
        }
        /// swift: Markup.accept(_:) — double dispatch into the visitor's matching `visit*` method.
        pub fn accept<W: crate::render::markdown_package::MarkupWalker + ?Sized>(
            &self,
            walker: &mut W,
        ) {
            crate::render::markdown_package::accept(self, walker)
        }
    }
}

use markdown::{
    BlockQuote, Checkbox, CodeBlock, Document, Emphasis, Heading, HTMLBlock, InlineCode,
    InlineHTML, Link, ListItem, Markup, OrderedList, Paragraph, SourceRange, Strikethrough,
    Strong, Table, TableCell, Text, ThematicBreak, UnorderedList,
};

// swift: MarkdownRenderer

pub struct MarkdownRenderer;

impl MarkdownRenderer {
    // Reuse the parsed tree across renders of the SAME text (e.g. every ⌘+/− zoom step re-renders
    // to rescale fonts but the markdown hasn't changed) so we don't re-parse on each zoom.
    // (Swift's `private static var parseMemo` — a thread-local/static cache; phase B decides the
    // real storage. Left unmodeled here since nothing in this file's signatures depends on it
    // being a field rather than a function-local, and adding one now would be inventing state
    // ahead of a design decision.)

    // swift: MarkdownRenderer.render
    pub fn render(
        markdown: &str,
        theme: &crate::render::render_theme::RenderTheme,
    ) -> swiftshim::NSAttributedString {
        let document = Document::parsing(markdown);
        let mut builder = AttributedBuilder::new(theme.clone(), markdown);
        builder.visit(&Markup::Document(document));
        Self::finish_passes(&mut builder.result);
        builder.result.asAttributedString().clone()
    }

    /// The same render, stopping BEFORE font substitution — the form a host reads over the wire.
    ///
    /// Substitution belongs to whoever owns AppKit, exactly as it does on the office path (see
    /// `HwpReader::read_before_host_font_substitution`). Run here as well, it happens twice: this
    /// crate resolves Hangul through the host's provider bridge and lands on one face, the host
    /// then re-substitutes what arrives and lands on another (`.AppleKoreanFont-Bold` against the
    /// `.AppleSDGothicNeoI-SemiBold` this reader actually draws). Leaving it undone also keeps
    /// every font in the string a THEME font, which is what lets the wire name it by role instead
    /// of by a face name that does not round-trip.
    pub fn render_before_host_font_substitution(
        markdown: &str,
        theme: &crate::render::render_theme::RenderTheme,
    ) -> swiftshim::NSAttributedString {
        let document = Document::parsing(markdown);
        let mut builder = AttributedBuilder::new(theme.clone(), markdown);
        builder.visit(&Markup::Document(document));
        Self::autolink(&mut builder.result);
        builder.result.asAttributedString().clone()
    }

    // swift: MarkdownRenderer.finishPasses
    /// The two range-based passes every rendered run must go through before it is shown. Factored
    /// out because a progressive render runs them on each PIECE rather than once on the whole
    /// string, and both are safe that way: a top-level block boundary cannot fall inside a URL, a
    /// fence or a word, so no match straddles two chunks.
    pub fn finish_passes(s: &mut swiftshim::NSMutableAttributedString) {
        Self::autolink(s);
        // The theme names one font for everything, and it has no Hangul — so without this AppKit
        // fixes the string per character and cuts a run at every word boundary (invariant 52's own
        // rule, applied to the path that has no document to declare a face).
        crate::render::office::font_substitution_resolver::FontSubstitutionResolver::apply_substitutions(
            s,
            &crate::render::office::font_substitution_resolver::FontSubstitutionCache::default(),
        );
    }

    // swift: MarkdownRenderer.renderProgressive
    /// Begin a render that is handed over in pieces instead of all at once.
    ///
    /// The document is PARSED whole (it has to be — a link definition at the end of the file binds
    /// text at the start), and only the walk over its top-level children is sliced. See
    /// `docs/02-planned/markdown-progressive-first-paint.md`.
    pub fn render_progressive(
        markdown: &str,
        theme: &crate::render::render_theme::RenderTheme,
    ) -> ProgressiveMarkdownRender {
        let document = Document::parsing(markdown);
        ProgressiveMarkdownRender::new(
            AttributedBuilder::new(theme.clone(), markdown),
            document.children,
        )
    }

    // swift: MarkdownRenderer.isCode
    /// After rendering, detect bare URLs and file paths in the prose and make them clickable
    /// links. Markdown links (already carrying `.link`) are left untouched.
    // Compiled once, reused across renders (these were rebuilt on every render — incl. every zoom).
    fn link_detector() -> Result<swiftshim::NSDataDetector, swiftshim::EngineError> {
        swiftshim::NSDataDetector::linkDetector()
    }
    fn file_path_re() -> Result<swiftshim::NSRegularExpression, swiftshim::EngineError> {
        swiftshim::NSRegularExpression::new(
            r"(?<=\s|^)(?:~|\.{1,2})?/[\w.\-/@+]+",
            swiftshim::NSRegularExpressionOptions::default(),
        )
    }

    // swift: MarkdownRenderer.isCode
    /// Code is shown, not offered as navigation — nothing inside a fence or a `code span` is
    /// autolinked. Three reasons, and the first is the one you can see: link styling is painted
    /// AFTER highlighting, so a URL in a string turns blue-underlined and the syntax colour dies
    /// right there. Selecting code is also common, and a link answers a click by leaving the app.
    /// GitHub draws the same line. (Explicit markdown links are untouched — those were asked for.)
    fn is_code(s: &swiftshim::NSAttributedString, at: usize) -> bool {
        s.attribute(&crate::render::md_attr::MDAttr::code_block(), at).is_some()
            || s.attribute(&crate::render::md_attr::MDAttr::inline_code(), at).is_some()
    }

    // swift: MarkdownRenderer.autolink
    fn autolink(s: &mut swiftshim::NSMutableAttributedString) {
        let full = swiftshim::NSRange::new(0, s.length());
        // NO TRANSCODE AT ALL — take the store, don't round-trip through Swift.
        //
        // Both scanners below are Objective-C APIs, so they read the text through `getCharacters`,
        // in UTF-16; so does every `NSRange` this function hands to `addAttribute`. UTF-16 is not
        // incidental here, it is what an `NSAttributedString` is indexed in. A native Swift string
        // stores UTF-8, so reading one through those APIs transcodes the range again on every call —
        // MEASURED by `sample` on a 3.5 MB / 2.8 M character markdown file: of 6,029 first-paint
        // samples 2,879 were inside this function, and 2,137 of those inside
        // `__StringStorage.getCharacters` → `UTF16View._nativeCopy`. A Korean document is three
        // bytes to the character, which is why it lands so hard here.
        //
        // `s.string` is the wrong handle: bridging a MUTABLE attributed string's text to `String`
        // copies it into Swift storage (UTF-16 → UTF-8), and handing that back to an NSString API
        // converts it straight back. `mutableString` IS the store, so `copy()` is a UTF-16 memcpy of
        // a snapshot and `as String` on the immutable result wraps it rather than copying again.
        //
        // Worth **6.15 s → 4.48 s** of first paint on that file, three runs each at a load average
        // of 3.2. MEASURE ON A QUIET MACHINE: the same two builds read 10.1 s and 7.5 s at a load
        // average of 12–17, which is a different claim about the same change.
        // swift: `s.mutableString.copy() as! NSString` then `ns as String` — the copy is the
        // snapshot both scanners read, and `str_` wraps it rather than copying a second time.
        let ns = swiftshim::SwiftString::new(&s.mutableString());
        let str_ = ns.as_str();
        let link_attrs: std::collections::HashMap<swiftshim::NSAttributedStringKey, swiftshim::AttrValue> =
            std::collections::HashMap::from([
                (
                    swiftshim::NSAttributedStringKey::ForegroundColor,
                    swiftshim::AttrValue::Color(crate::render::render_theme::Palette::link()),
                ),
                (
                    swiftshim::NSAttributedStringKey::UnderlineStyle,
                    swiftshim::AttrValue::UnderlineStyle(swiftshim::NSUnderlineStyle::single),
                ),
            ]);

        if let Ok(det) = swiftshim::NSDataDetector::linkDetector() {
            det.enumerateMatches(&str_, full, |m| {
                let Some(url) = m.url() else { return };
                if Self::is_code(s.asAttributedString(), m.range.location)
                    || s.attribute(&swiftshim::NSAttributedStringKey::Link, m.range.location)
                        .is_some()
                {
                    return;
                }
                s.addAttribute(
                    swiftshim::NSAttributedStringKey::Link,
                    swiftshim::AttrValue::Text(url.to_string()),
                    m.range,
                );
                s.addAttributes(link_attrs.clone(), m.range);
            });
        }
        // File paths: absolute (/…, ~/…) or explicit relative (./… ../…), only at a word
        // boundary so mid-word slashes ("and/or") are never matched. The raw path is stored;
        // the link handler resolves it against the document's directory.
        //
        // In code this pattern is also plain WRONG, not just unwanted: ` // comment` is a space then
        // slashes, so every C-style comment became a folder shortcut that opened Finder (Dockerfile
        // `COPY /src /usr/local/bin` too).
        if let Ok(re) = Self::file_path_re() {
            let trailing = ".,;:!?)";
            re.enumerateMatches(&str_, full, |m| {
                if Self::is_code(s.asAttributedString(), m.range.location)
                    || s.attribute(&swiftshim::NSAttributedStringKey::Link, m.range.location)
                        .is_some()
                {
                    return;
                }
                let mut range = m.range;
                // Drop trailing sentence punctuation the greedy match swallowed ("./x.md." → "./x.md").
                // `ns` is the one built above rather than a fresh bridge per match, for the same
                // measured reason.
                while range.length > 0 {
                    let u = ns
                        .substring(swiftshim::NSRange::new(range.location + range.length - 1, 1))
                        .chars()
                        .next();
                    match u {
                        Some(c) if trailing.contains(c) => range.length -= 1,
                        _ => break,
                    }
                }
                let path = ns.substring(range);
                if path.contains('/') {
                    s.addAttribute(
                        crate::render::md_attr::MDAttr::file_path(),
                        swiftshim::AttrValue::Text(path.clone()),
                        range,
                    );
                    s.addAttribute(
                        swiftshim::NSAttributedStringKey::Link,
                        swiftshim::AttrValue::Text("fmdpath:file".to_string()),
                        range,
                    );
                    s.addAttributes(link_attrs.clone(), range);
                }
            });
        }
    }
}

// swift: mdPara
/// Build a paragraph style with an ABSOLUTE line height (min == max, in points) rather than a
/// multiple. AppKit's lineHeightMultiple multiplies each font's natural leading — which is
/// larger for Korean than Latin — so it reads loose and uneven; a fixed line height gives
/// tight, consistent leading that scales cleanly with the font size.
///
/// `uncapped` treats `lineHeight` as a FLOOR rather than a fixed cap: `minimumLineHeight` is set,
/// `maximumLineHeight` is cleared (0). A body paragraph passes `true` so a font TALLER than the
/// floor (a large-font body line — the same clipping the office builder fixes) grows the line
/// instead of overlapping; normal-size body is byte-identical because 16pt text's natural height is
/// below the floor, so the floor still governs. Headings/code pass the default `false` and keep
/// their own exact fixed line height (min == max), which is already sized to their font.
#[allow(clippy::too_many_arguments)]
fn md_para(
    line_height: swiftshim::CGFloat,
    spacing_after: swiftshim::CGFloat,
    spacing_before: swiftshim::CGFloat,
    head_indent: swiftshim::CGFloat,
    first_line_indent: swiftshim::CGFloat,
    uncapped: bool,
) -> swiftshim::NSParagraphStyle {
    // swift: mdPara
    let mut p = swiftshim::NSMutableParagraphStyle::default();
    let lh = line_height.round();
    p.minimumLineHeight = lh;
    p.maximumLineHeight = if uncapped { 0.0 } else { lh };
    p.paragraphSpacing = spacing_after;
    p.paragraphSpacingBefore = spacing_before;
    p.headIndent = head_indent;
    p.firstLineHeadIndent = first_line_indent;
    p
}

// swift: AttributedBuilder
struct AttributedBuilder {
    theme: crate::render::render_theme::RenderTheme,
    result: swiftshim::NSMutableAttributedString,
    block_seq: i32,
    body_ps: swiftshim::NSParagraphStyle,
    quote_ps: swiftshim::NSParagraphStyle,
    /// no max line height, so the line grows to fit an image
    image_ps: swiftshim::NSParagraphStyle,
    // swift: AttributedBuilder
    /// The raw markdown, held as an `NSString` rather than a `String`.
    ///
    /// Everything this builder asks the source is a UTF-16 question — `lineStarts` are UTF-16
    /// offsets, `sourceOffsets` returns an `NSRange`, and a block id is a range into the same
    /// coordinates. A native Swift string stores UTF-8, so each of those reads transcoded the range
    /// again: the line scan below is one `character(at:)` per character (2.8 M of them on a 3.5 MB
    /// file), `scanMathSpans` takes a substring per LINE (54,795 of them), and `sourceOffsets` runs
    /// once per BLOCK. MEASURED by `sample`: this initialiser was 705 of 6,029 first-paint samples.
    ///
    /// One `NSString` up front is one transcode and every read after it is an indexed one — worth
    /// **4.48 s → 4.35 s** of first paint on a 3.5 MB file, three runs each at a load average of 3.2.
    /// Less than the sample share suggests, because `NSString(string:)` COPIES (5.6 MB of UTF-16)
    /// where `source as NSString` was a free wrapper — the per-access transcode is traded for one
    /// bulk copy rather than removed. Measure any replacement the same way, on a QUIET machine: the
    /// same build measured 7.5 s at a load average of 12–17, which is the number that nearly got
    /// this change credited with three times its worth.
    source_ns: swiftshim::SwiftString,
    /// UTF-16 offset of each source line start
    line_starts: Vec<usize>,
    math_spans: Vec<(swiftshim::NSRange, String)>,
    /// span starts already turned into a formula
    emitted_math: std::collections::HashSet<usize>,
}

impl AttributedBuilder {
    fn new(theme: crate::render::render_theme::RenderTheme, source: &str) -> Self {
        let sns = swiftshim::SwiftString::new(source);
        let mut ls = vec![0usize];
        for i in 0..sns.length() {
            if sns.characterAt(i) == 10 {
                ls.push(i + 1);
            }
        }
        let math_spans = Self::scan_math_spans(&sns, &ls);
        let b = theme.base_font_size;
        let style = crate::render::render_theme::MarkdownStyle { theme: theme.clone() };
        // All spacing is derived from the base font size with ABSOLUTE line heights, so it
        // scales with ⌘+/− and reads consistently. Within-paragraph leading is tight (1.45×);
        // the gap BETWEEN paragraphs is clearly larger — "near things close, far things far."
        let body_ps = md_para(
            b * theme.line_height_ratio(),
            b * theme.paragraph_spacing_ratio(),
            0.0,
            0.0,
            0.0,
            true, // floor, not cap — a large-font body line grows instead of overlapping
        );
        let quote_ps = md_para(
            b * theme.line_height_ratio(),
            b * theme.paragraph_spacing_ratio(),
            0.0,
            b * style.quote_indent_ratio(),
            b * style.quote_indent_ratio(),
            false,
        );
        let mut ip = swiftshim::NSMutableParagraphStyle::default();
        ip.minimumLineHeight = (b * theme.line_height_ratio()).round(); // floor only — NO ceiling, so a tall image fits
        ip.paragraphSpacing = b * theme.paragraph_spacing_ratio();
        let image_ps = ip;
        Self {
            theme,
            result: swiftshim::NSMutableAttributedString::new(),
            block_seq: 0,
            body_ps: body_ps,
            quote_ps: quote_ps,
            image_ps: image_ps,
            source_ns: sns,
            line_starts: ls,
            math_spans: math_spans,
            emitted_math: std::collections::HashSet::new(),
        }
    }

    // swift: AttributedBuilder.containsImage
    /// True if this markup contains an image anywhere in its subtree — such a paragraph must
    /// not cap its line height (see imagePS) or the image overflows and overlaps neighbors.
    fn contains_image(&self, markup: &Markup) -> bool {
        if matches!(markup, Markup::Image(_)) {
            return true;
        }
        for child in markup.children() {
            if self.contains_image(&child) {
                return true;
            }
        }
        false
    }

    // swift: AttributedBuilder.newline
    fn newline(&mut self, count: usize) {
        self.result.append(&swiftshim::NSAttributedString::new("\n".repeat(count)));
    }

    // swift: AttributedBuilder.tagBlock
    /// Tag everything appended since `start` as one top-level block with a unique id, so a
    /// gutter click can recover this exact block's range. Headings get their own id, cleanly
    /// separated from the paragraph beneath them.
    fn tag_block(&mut self, start: usize, srcRange: Option<SourceRange>) {
        let src_offsets = self.source_offsets(srcRange);
        self.tag_block_offsets(start, src_offsets);
    }

    fn tag_block_offsets(&mut self, start: usize, src_offsets: Option<swiftshim::NSRange>) {
        let r = swiftshim::NSRange::new(start, self.result.length() - start);
        if r.length == 0 {
            return;
        }
        self.result.addAttribute(
            crate::render::md_attr::MDAttr::block_id(),
            swiftshim::AttrValue::Int(self.block_seq as i64),
            r,
        );
        if let Some(so) = src_offsets {
            self.result.addAttribute(
                crate::render::md_attr::MDAttr::src_range(),
                swiftshim::AttrValue::Range(so),
                r,
            );
        }
        self.block_seq += 1;
    }

    // swift: AttributedBuilder.sourceOffsets
    /// Map a swift-markdown SourceRange to a UTF-16 NSRange in the source, by WHOLE LINES (blocks
    /// occupy full lines, so this sidesteps column encoding — safe for CJK). The trailing newline
    /// of the last line is excluded so a replacement keeps the block separators intact.
    fn source_offsets(&self, srcRange: Option<SourceRange>) -> Option<swiftshim::NSRange> {
        let src_range = srcRange?;
        let start_line = src_range.lower_bound.line;
        let end_line = src_range.upper_bound.line;
        if start_line < 1 || start_line > self.line_starts.len() {
            return None;
        }
        let start_off = self.line_starts[start_line - 1];
        let sns = &self.source_ns;
        let mut end_off = if end_line >= 1 && end_line < self.line_starts.len() {
            self.line_starts[end_line] - 1
        } else {
            sns.length()
        };
        // Some blocks (e.g. lists) report a range that runs one line long; trim trailing newlines
        // so the span hugs the block's own text and a replacement can't swallow block separators.
        while end_off > start_off
            && (sns.characterAt(end_off - 1) == 10 || sns.characterAt(end_off - 1) == 13)
        {
            end_off -= 1;
        }
        if end_off < start_off {
            return None;
        }
        Some(swiftshim::NSRange::new(start_off, end_off - start_off))
    }

    // swift: AttributedBuilder.inlineString
    // Inline collection: render children into an attributed run with a base font. Images are
    // handled here (not in inlineFragment) so a trailing Pandoc `{width=…}` text sibling can be
    // consumed as the image's width.
    fn inline_string(
        &self,
        markup: &Markup,
        font: swiftshim::NSFont,
        color: swiftshim::NSColor,
    ) -> swiftshim::NSAttributedString {
        let mut out = swiftshim::NSMutableAttributedString::new();
        let children = markup.children();
        let mut i = 0usize;
        while i < children.len() {
            if let Markup::Image(img) = &children[i] {
                let (alt, pts0, pct0) = self.parse_sized_alt(&img.plain_text); // Obsidian ![alt|N]
                let (mut pts, mut pct) = (pts0, pct0);
                if i + 1 < children.len() {
                    if let Markup::Text(t) = &children[i + 1] {
                        if let Some(attr) = self.parse_pandoc_attr(&t.string) {
                            // Pandoc ![](x){width=N}
                            if pts.is_none() && pct.is_none() {
                                pts = attr.0;
                                pct = attr.1;
                            }
                            out.append(&self.image_string(
                                img.source.clone().unwrap_or_default(),
                                alt,
                                pts,
                                pct,
                            ).asAttributedString().clone());
                            if !attr.2.is_empty() {
                                let attrs = std::collections::HashMap::from([
                                    (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(font.clone())),
                                    (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(color)),
                                ]);
                                out.append(&swiftshim::NSAttributedString::with_attributes(&attr.2, attrs));
                            }
                            i += 2;
                            continue;
                        }
                    }
                }
                out.append(&self.image_string(
                    img.source.clone().unwrap_or_default(),
                    alt,
                    pts,
                    pct,
                ).asAttributedString().clone());
                i += 1;
                continue;
            }
            out.append(&self.inline_fragment(&children[i], font.clone(), color));
            i += 1;
        }
        out.asAttributedString().clone()
    }

    // swift: AttributedBuilder.imageString
    fn image_string(
        &self,
        source: String,
        alt: String,
        width_pts: Option<swiftshim::CGFloat>,
        width_pct: Option<swiftshim::CGFloat>,
    ) -> swiftshim::NSMutableAttributedString {
        let mut att = swiftshim::NSTextAttachment::new();
        // A custom cell OWNS the layout size so image==nil (not-yet-loaded / purged) still reserves
        // the area — the default cell would collapse to zero and make the scroll bar swing. Real
        // size is applied to the cell right after (local images) or on first load (remote).
        let ph = swiftshim::CGSize::new(width_pts.unwrap_or(480.0), 360.0);
        att.bounds = swiftshim::CGRect::new(0.0, 0.0, ph.width, ph.height);
        // swift: att.attachmentCell = SizedAttachmentCell(reservedSize: ph) — `SizedAttachmentCell`
        // lives in Render/SizedAttachmentCell.swift, outside this sprint's scope; referenced by
        // Swift name until that file is ported.
        // swift: att.attachmentCell = SizedAttachmentCell(reservedSize: ph) — `SizedAttachmentCell`
        // lives in Render/SizedAttachmentCell.swift (out of this sprint's scope), referenced by
        // Swift name; `attachment_cell` is a shim addition to `NSTextAttachment`.
        att.attachmentCell = Some(swiftshim::SizedAttachmentCell::new(ph));
        let mut out = swiftshim::NSMutableAttributedString::with_attachment(att);
        let whole = swiftshim::NSRange::new(0, out.length());
        out.addAttribute(
            crate::render::md_attr::MDAttr::image(),
            swiftshim::AttrValue::Text(source),
            whole,
        );
        if !alt.is_empty() {
            out.addAttribute(crate::render::md_attr::MDAttr::image_alt(), swiftshim::AttrValue::Text(alt), whole);
        }
        if let Some(w) = width_pts {
            out.addAttribute(crate::render::md_attr::MDAttr::image_width(), swiftshim::AttrValue::Double(w), whole);
        }
        if let Some(p) = width_pct {
            out.addAttribute(crate::render::md_attr::MDAttr::image_width_pct(), swiftshim::AttrValue::Double(p), whole);
        }
        out
    }

    // swift: AttributedBuilder.parseSizedAlt
    /// Obsidian `![alt|300]` / `![alt|300x200]` → strip the size off the alt.
    fn parse_sized_alt(&self, alt: &str) -> (String, Option<swiftshim::CGFloat>, Option<swiftshim::CGFloat>) {
        let Some(pipe) = alt.rfind('|') else {
            return (alt.to_string(), None, None);
        };
        let size_part = alt[pipe + 1..].trim();
        let width_tok = size_part.split('x').next().unwrap_or(size_part);
        let (pts, pct) = self.parse_width_spec(width_tok);
        if pts.is_some() || pct.is_some() {
            return (alt[..pipe].trim().to_string(), pts, pct);
        }
        (alt.to_string(), None, None)
    }

    // swift: AttributedBuilder.parseWidthSpec
    /// "300", "300px", "50%" → points or a 0–1 fraction.
    fn parse_width_spec(&self, s: &str) -> (Option<swiftshim::CGFloat>, Option<swiftshim::CGFloat>) {
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

    // swift: AttributedBuilder.parsePandocAttr
    /// A leading `{ … }` attribute block (Pandoc). Consumes the braces even without a width=
    /// so the raw attribute never renders as literal text; returns text after `}` as remainder.
    fn parse_pandoc_attr(
        &self,
        s: &str,
    ) -> Option<(Option<swiftshim::CGFloat>, Option<swiftshim::CGFloat>, String)> {
        let trimmed = s.trim_start_matches(' ');
        if !trimmed.starts_with('{') {
            return None;
        }
        let close = trimmed.find('}')?;
        let inside = &trimmed[1..close];
        let remainder = trimmed[close + 1..].to_string();
        if let Ok(re) = swiftshim::NSRegularExpression::new(
            r#"width\s*=\s*"?([0-9.]+%?(?:px)?)"?"#,
            swiftshim::NSRegularExpressionOptions::caseInsensitive,
        ) {
            if let Some(m) = re.firstMatch(inside, swiftshim::NSRange::new(0, inside.encode_utf16().count())) {
                let r = m.range(1);
                if r.location != swiftshim::NS_NOT_FOUND {
                    let captured = &inside[r.location..r.maxRange()];
                    let (pts, pct) = self.parse_width_spec(captured);
                    return Some((pts, pct, remainder));
                }
            }
        }
        Some((None, None, remainder))
    }

    // swift: AttributedBuilder.parseImgTag
    /// Parse an `<img …>` HTML tag → (src, alt, width). nil if it isn't an img tag.
    fn parse_img_tag(
        &self,
        html: &str,
    ) -> Option<(String, String, Option<swiftshim::CGFloat>, Option<swiftshim::CGFloat>)> {
        if !html.to_lowercase().contains("<img") {
            return None;
        }
        // swift: AttributedBuilder.attr
        let attr = |name: &str| -> Option<String> {
            let pattern = format!(r#"{}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, name);
            let re = swiftshim::NSRegularExpression::new(
                &pattern,
                swiftshim::NSRegularExpressionOptions::caseInsensitive,
            )
            .ok()?;
            let m = re.firstMatch(html, swiftshim::NSRange::new(0, html.encode_utf16().count()))?;
            for g in 1..=3 {
                let r = m.range(g);
                if r.location != swiftshim::NS_NOT_FOUND {
                    // An NSRange is UTF-16; byte-slicing it is right for ASCII and wrong for
                    // anything else (and can panic mid-character). `SwiftString` indexes the way
                    // the range is measured.
                    return Some(swiftshim::SwiftString::new(html).substring(r));
                }
            }
            None
        };
        let src = attr("src")?;
        let mut pts = None;
        let mut pct = None;
        if let Some(w) = attr("width") {
            let (p, c) = self.parse_width_spec(&w);
            pts = p;
            pct = c;
        }
        Some((src, attr("alt").unwrap_or_default(), pts, pct))
    }

    // swift: AttributedBuilder.fontAdding
    /// Add bold/italic by keeping the SAME family (via the font descriptor) so vertical metrics
    /// (ascent/descent) don't change — otherwise a bold run shifts the baseline and line spacing
    /// looks jagged under a fixed line height.
    fn font_adding(&self, traits: swiftshim::NSFontDescriptorSymbolicTraits, font: &swiftshim::NSFont) -> swiftshim::NSFont {
        let d = font.fontDescriptor();
        let d = d.withSymbolicTraits(d.symbolicTraits().union(traits));
        swiftshim::NSFont::with_descriptor(&d, font.pointSize()).unwrap_or_else(|| font.clone())
    }

    // swift: AttributedBuilder.inlineFragment
    fn inline_fragment(&self, markup: &Markup, font: swiftshim::NSFont, color: swiftshim::NSColor) -> swiftshim::NSAttributedString {
        match markup {
            Markup::Text(t) => {
                let attrs = std::collections::HashMap::from([
                    (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(font)),
                    (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(color)),
                ]);
                swiftshim::NSAttributedString::with_attributes(&t.string, attrs)
            }
            Markup::Emphasis(e) => {
                let f = self.font_adding(swiftshim::NSFontDescriptorSymbolicTraits::italic, &font);
                self.inline_string(&Markup::Emphasis(e.clone()), f, color)
            }
            Markup::Strong(strong) => {
                let f = self.font_adding(swiftshim::NSFontDescriptorSymbolicTraits::bold, &font);
                self.inline_string(&Markup::Strong(strong.clone()), f, color)
            }
            Markup::InlineCode(c) => {
                // The one deliberate accent in the reading view: subtle muted-red text. The warm
                // chip behind it is drawn by the layout manager (MDAttr.inlineCode) so it hugs the
                // glyphs instead of filling the inflated 1.5× line box.
                let attrs = std::collections::HashMap::from([
                    (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(self.theme.code_font())),
                    (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(self.theme.inline_code_color())),
                    (crate::render::md_attr::MDAttr::inline_code(), swiftshim::AttrValue::Bool(true)),
                ]);
                swiftshim::NSAttributedString::with_attributes(&c.code, attrs)
            }
            Markup::Link(link) => {
                let inner = self.inline_string(&Markup::Link(link.clone()), font, self.theme.link_color());
                let mut m = swiftshim::NSMutableAttributedString::from_attributed_string(&inner);
                let full = swiftshim::NSRange::new(0, m.length());
                m.addAttribute(
                    swiftshim::NSAttributedStringKey::UnderlineStyle,
                    swiftshim::AttrValue::UnderlineStyle(swiftshim::NSUnderlineStyle::single),
                    full,
                );
                if let Some(dest) = &link.destination {
                    if let Some(frag) = dest.strip_prefix('#') {
                        // In-document anchor (TOC). URL(string:) rejects non-ASCII fragments (Korean), so
                        // store the raw slug and use a placeholder link the click handler recognizes.
                        m.addAttribute(crate::render::md_attr::MDAttr::anchor(), swiftshim::AttrValue::Text(frag.to_string()), full);
                        m.addAttribute(swiftshim::NSAttributedStringKey::Link, swiftshim::AttrValue::Text("fmdanchor:jump".to_string()), full);
                    } else {
                        m.addAttribute(swiftshim::NSAttributedStringKey::Link, swiftshim::AttrValue::Text(dest.clone()), full);
                    }
                }
                m.asAttributedString().clone()
            }
            Markup::InlineHTML(sc) => {
                // Inline <img …> becomes an image (with optional width); other inline HTML is text.
                if let Some(tag) = self.parse_img_tag(&sc.raw_html) {
                    self.image_string(tag.0, tag.1, tag.2, tag.3).asAttributedString().clone()
                } else {
                    let attrs = std::collections::HashMap::from([
                        (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(font)),
                        (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(color)),
                    ]);
                    swiftshim::NSAttributedString::with_attributes(&sc.raw_html, attrs)
                }
            }
            Markup::LineBreak => {
                // Hard break (two trailing spaces or a backslash) → a real line break within the block.
                let attrs = std::collections::HashMap::from([
                    (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(font)),
                    (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(color)),
                ]);
                swiftshim::NSAttributedString::with_attributes("\n", attrs)
            }
            Markup::SoftBreak => {
                // Soft break (a plain source newline) → a space, so the paragraph reflows.
                let attrs = std::collections::HashMap::from([
                    (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(font)),
                    (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(color)),
                ]);
                swiftshim::NSAttributedString::with_attributes(" ", attrs)
            }
            Markup::Strikethrough(st) => {
                // GFM `~~text~~`. Render the inner span first (so nested bold/italic/code/links keep
                // their own styling), then lay a single strikethrough line over the whole run. Without
                // this case it fell through to `default` and shipped as unstruck text (invariant 30/34).
                let inner = self.inline_string(&Markup::Strikethrough(st.clone()), font, color);
                let mut m = swiftshim::NSMutableAttributedString::from_attributed_string(&inner);
                m.addAttribute(
                    swiftshim::NSAttributedStringKey::StrikethroughStyle,
                    swiftshim::AttrValue::UnderlineStyle(swiftshim::NSUnderlineStyle::single),
                    swiftshim::NSRange::new(0, m.length()),
                );
                m.asAttributedString().clone()
            }
            _ => self.inline_string(markup, font, color),
        }
    }

    // Readability (research-backed: Butterick / Baymard / WCAG 1.4.12): line height 1.45×,
    // paragraph spacing ~12pt. Column width + margins are handled by the window controller
    // (centered ~660pt measure). Styles are immutable and value-independent of the theme, so
    // they are built ONCE and reused across every block/render (per-block allocation made a
    // 4000-paragraph doc render 6× slower — this keeps it fast).
    // swift: AttributedBuilder.visitHeading
    fn visit_heading(&mut self, heading: &Heading) {
        let font = self.theme.heading_font(heading.level);
        let start = self.result.length();
        let s = self.inline_string(&Markup::Heading(heading.clone()), font, self.theme.text_color());
        self.result.append(&s);
        // Tag the heading run (C5 / spec §5): heading jump offsets are derived by
        // scanning this attribute on the live text — never a stored offsets array.
        self.result.addAttribute(
            crate::render::md_attr::MDAttr::heading(),
            swiftshim::AttrValue::Int(heading.level as i64),
            swiftshim::NSRange::new(start, self.result.length() - start),
        );
        self.newline(1);
        // Tight heading leading (1.25×) with a roomy space-before and small space-after so the
        // heading bonds to the text below it. All scaled to the font size.
        let b = self.theme.base_font_size;
        let style = crate::render::render_theme::MarkdownStyle { theme: self.theme.clone() };
        let ps = md_para(
            self.theme.heading_size(heading.level) * self.theme.heading_line_height_ratio(),
            b * self.theme.heading_spacing_after_ratio(),
            style.heading_spacing_before(heading.level),
            0.0,
            0.0,
            false,
        );
        self.result.addAttribute(
            swiftshim::NSAttributedStringKey::ParagraphStyle,
            swiftshim::AttrValue::ParagraphStyle(ps),
            swiftshim::NSRange::new(start, self.result.length() - start),
        );
        self.tag_block(start, heading.range);
    }

    /// Find every `$$ … $$` span in the RAW source, before markdown ever sees it.
    ///
    /// `$$` is not markdown, so the parser reads a formula's insides as markdown and mangles them:
    /// a lone `=` line under a matrix makes the line above a setext HEADING, `_` becomes emphasis,
    /// `*` opens a list. By the time we hold the tree the formula is shredded across several nodes,
    /// and no node-level test can put it back together — claiming the span from the source first is
    /// the only order that works. (Measured: `\begin{pmatrix} … \\ = \\ … \end{pmatrix}` arrived as
    /// a heading plus a paragraph, and rendered as a giant title.)
    // swift: AttributedBuilder.scanMathSpans
    fn scan_math_spans(ns: &swiftshim::SwiftString, line_starts: &[usize]) -> Vec<(swiftshim::NSRange, String)> {
        let mut out: Vec<(swiftshim::NSRange, String)> = Vec::new();
        let mut open_line: Option<usize> = None;
        for i in 0..line_starts.len() {
            let start = line_starts[i];
            let end = if i + 1 < line_starts.len() { line_starts[i + 1] - 1 } else { ns.length() };
            if end < start {
                continue;
            }
            let line = ns.substring(swiftshim::NSRange::new(start, end - start)).trim().to_string();
            if let Some(open) = open_line {
                // inside a fence: look for its close
                if line != "$$" {
                    continue;
                }
                let from = line_starts[open];
                let tex_start = line_starts[open + 1];
                let tex = ns.substring(swiftshim::NSRange::new(tex_start, start.saturating_sub(tex_start)));
                out.push((swiftshim::NSRange::new(from, end - from), tex.trim().to_string()));
                open_line = None;
                continue;
            }
            if line == "$$" {
                if i + 1 < line_starts.len() {
                    open_line = Some(i);
                } // an unterminated `$$` stays plain text
                continue;
            }
            // One-liner: `$$ x = 1 $$`. Two formulas on one line are left to the text path rather
            // than merged into one bogus render.
            if line.starts_with("$$") && line.ends_with("$$") && line.chars().count() > 4 {
                let inner: String = line.chars().skip(2).take(line.chars().count() - 4).collect();
                if inner.contains("$$") {
                    continue;
                }
                out.push((swiftshim::NSRange::new(start, end - start), inner.trim().to_string()));
            }
        }
        out.into_iter().filter(|(_, tex)| !tex.is_empty()).collect()
    }

    // swift: AttributedBuilder.mathSpan
    /// The span this block was made from, if the block lies ENTIRELY inside one. Containment, not
    /// overlap: the Document (and any list/quote wrapping a formula) merely overlaps, so it keeps
    /// descending until it reaches the nodes the formula itself produced.
    fn math_span(&self, r: swiftshim::NSRange) -> Option<(swiftshim::NSRange, String)> {
        // `visit` runs this for EVERY markup node, so a linear `.first` scan is O(nodes × spans) on a
        // formula-heavy document (paid again on every zoom re-render). `mathSpans` is ascending by
        // location and non-overlapping (`scanMathSpans` walks the source in order), so binary-search the
        // last span starting at or before `r`, then test containment — O(log spans) per node.
        if self.math_spans.is_empty() {
            return None;
        }
        let (mut lo, mut hi): (i64, i64) = (0, self.math_spans.len() as i64 - 1);
        let mut cand: i64 = -1;
        while lo <= hi {
            let mid = (lo + hi) / 2;
            if self.math_spans[mid as usize].0.location <= r.location {
                cand = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        if cand < 0 {
            return None;
        }
        let s = &self.math_spans[cand as usize];
        if r.location + r.length <= s.0.location + s.0.length {
            Some(s.clone())
        } else {
            None
        }
    }

    // swift: AttributedBuilder.visit
    /// Every block goes through here, so a formula is caught wherever the parser put its pieces —
    /// top level, or nested in a list or quote.
    fn visit(&mut self, markup: &Markup) {
        if let Some(so) = self.source_offsets(markup.range()) {
            if let Some(span) = self.math_span(so) {
                // All the nodes of one span collapse into a single formula; emit on the first, drop the
                // rest, and never descend into them — they're fragments of TeX, not text.
                if self.emitted_math.insert(span.0.location) {
                    self.append_web_block(
                        crate::render::web_block::Engine::Math,
                        span.1,
                        Some(span.0),
                        swiftshim::CGSize::new(260.0, 60.0),
                    );
                }
                return;
            }
        }
        markup.accept(self);
    }

    // swift: AttributedBuilder.appendWebBlock
    /// The placeholder for a block WebKit will draw later (mermaid diagram, TeX formula). A real
    /// attachment from the start, so the lazy media manager treats it exactly like an image (load
    /// when on-screen, drop when far) and the size/pixel split holds. The reserved size here is only
    /// a guess; the up-front measure pass replaces it with the exact one before layout.
    fn append_web_block(
        &mut self,
        engine: crate::render::web_block::Engine,
        code: String,
        src_offsets: Option<swiftshim::NSRange>,
        size: swiftshim::CGSize,
    ) {
        let block_start = self.result.length();
        let mut att = swiftshim::NSTextAttachment::new();
        att.bounds = swiftshim::CGRect::new(0.0, 0.0, size.width, size.height);
        // owns size when image==nil
        att.attachmentCell = Some(swiftshim::SizedAttachmentCell::new(size));
        let mut ph = swiftshim::NSMutableAttributedString::with_attachment(att);
        // swift: `engine.attribute` — `WebBlock.Engine` names the ONE `MDAttr` key its code lives
        // under (`.mermaid`/`.math`); the two are matched out locally since `Engine` (web_block.rs,
        // not this file's) carries no such method itself.
        let engine_attribute = match engine {
            crate::render::web_block::Engine::Mermaid => crate::render::md_attr::MDAttr::mermaid(),
            crate::render::web_block::Engine::Math => crate::render::md_attr::MDAttr::math(),
        };
        ph.addAttribute(
            engine_attribute,
            swiftshim::AttrValue::Text(code),
            swiftshim::NSRange::new(0, ph.length()),
        );
        self.result.append(ph.asAttributedString());
        self.newline(2);
        self.tag_block_offsets(block_start, src_offsets);
    }

    // swift: AttributedBuilder.visitParagraph
    fn visit_paragraph(&mut self, paragraph: &Paragraph) {
        let start = self.result.length();
        let s = self.inline_string(&Markup::Paragraph(paragraph.clone()), self.theme.body_font(), self.theme.text_color());
        self.result.append(&s);
        self.newline(1);
        let ps = if self.contains_image(&Markup::Paragraph(paragraph.clone())) { self.image_ps.clone() } else { self.body_ps.clone() };
        self.result.addAttribute(
            swiftshim::NSAttributedStringKey::ParagraphStyle,
            swiftshim::AttrValue::ParagraphStyle(ps),
            swiftshim::NSRange::new(start, self.result.length() - start),
        );
        self.tag_block(start, paragraph.range);
    }

    // swift: AttributedBuilder.visitHTMLBlock
    fn visit_html_block(&mut self, html: &HTMLBlock) {
        // Only a block-level <img> is rendered (as an image); other raw HTML blocks are skipped.
        let Some(tag) = self.parse_img_tag(&html.raw_html) else { return; };
        let start = self.result.length();
        let mut s = self.image_string(tag.0, tag.1, tag.2, tag.3);
        s.addAttribute(
            swiftshim::NSAttributedStringKey::ParagraphStyle,
            swiftshim::AttrValue::ParagraphStyle(self.image_ps.clone()),
            swiftshim::NSRange::new(0, s.length()),
        );
        self.result.append(s.asAttributedString());
        self.newline(1);
        self.tag_block(start, html.range);
    }

    // swift: AttributedBuilder.visitBlockQuote
    fn visit_block_quote(&mut self, blockQuote: &BlockQuote) {
        let start = self.result.length();
        self.descend_into(&Markup::BlockQuote(blockQuote.clone()));
        // A nested code block ends with newline(2), leaving an empty QUOTED line below it (the
        // quote bar would extend past the content). Collapse trailing blank lines to a single \n.
        // The original reads the last two positions through `ns.substring(with: NSRange(...))`,
        // i.e. in UTF-16 units. The first transliteration of that line indexed the UTF-8 string
        // with those UTF-16 offsets, which is correct for ASCII and PANICS mid-character on the
        // first Korean document — `byte index 1242 is not a char boundary; it is inside '한'`.
        // `\n` is one UTF-16 unit and one UTF-8 byte and can never occur inside a multi-byte
        // sequence, so asking the UTF-8 tail is the identical question with no index at all.
        while self.result.length() > start + 1 && self.result.string().ends_with("\n\n") {
            self.result
                .delete_characters(swiftshim::NSRange::new(self.result.length() - 1, 1));
        }
        let range = swiftshim::NSRange::new(start, self.result.length() - start);
        if range.length > 0 {
            // Apply the quote paragraph style + muted color ONLY to the quote's own prose —
            // a nested code block keeps its own card paragraph style and syntax colors instead
            // of being flattened to grey indented text.
            let code_indent = self.theme.base_font_size; // shift nested code right to sit inside the quote
            let quote_ps = self.quote_ps.clone();
            let secondary = self.theme.secondary_color();
            // Collected first, applied after: `NSMutableAttributedString` has no `enumerateAttribute`
            // of its own (only the immutable `NSAttributedString` it wraps does), and mutating the
            // string being enumerated is undefined even where it did exist — the same "collect first"
            // discipline `FontSubstitutionResolver::apply_substitutions` uses for the identical reason.
            enum QuoteEdit {
                Attrs(swiftshim::NSRange, std::collections::HashMap<swiftshim::NSAttributedStringKey, swiftshim::AttrValue>),
                Attr(swiftshim::NSRange, swiftshim::NSAttributedStringKey, swiftshim::AttrValue),
            }
            let mut edits: Vec<QuoteEdit> = Vec::new();
            let snapshot = self.result.asAttributedString().clone();
            snapshot.enumerateAttribute(&crate::render::md_attr::MDAttr::code_block(), range, |code, sub, _stop| {
                if code.is_none() {
                    let attrs = std::collections::HashMap::from([
                        (swiftshim::NSAttributedStringKey::ParagraphStyle, swiftshim::AttrValue::ParagraphStyle(quote_ps.clone())),
                        (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(secondary)),
                    ]);
                    edits.push(QuoteEdit::Attrs(sub, attrs));
                } else {
                    // Nested code keeps its card style but is indented to align with the quote.
                    edits.push(QuoteEdit::Attr(sub, crate::render::md_attr::MDAttr::code_inset(), swiftshim::AttrValue::Double(code_indent)));
                    snapshot.enumerateAttribute(&swiftshim::NSAttributedStringKey::ParagraphStyle, sub, |psv, s2, _stop2| {
                        let Some(swiftshim::AttrValue::ParagraphStyle(psv)) = psv else { return; };
                        let mut mm = psv.clone();
                        mm.headIndent += code_indent;
                        mm.firstLineHeadIndent += code_indent;
                        edits.push(QuoteEdit::Attr(s2, swiftshim::NSAttributedStringKey::ParagraphStyle, swiftshim::AttrValue::ParagraphStyle(mm)));
                    });
                }
            });
            for edit in edits {
                match edit {
                    QuoteEdit::Attrs(r, attrs) => self.result.addAttributes(attrs, r),
                    QuoteEdit::Attr(r, k, v) => self.result.addAttribute(k, v, r),
                }
            }
            self.result.addAttribute(crate::render::md_attr::MDAttr::block_quote(), swiftshim::AttrValue::Bool(true), range); // bar spans the whole quote
        }
        self.tag_block(start, blockQuote.range); // overwrites inner ids: the quote is one block
    }

    // swift: markup.accept(&self)'s default dispatch descending into a container's children —
    // MarkupWalker's own `descendInto`, from the swift-markdown package (not this file); referenced
    // by name since `visitBlockQuote` calls it.
    fn descend_into(&mut self, markup: &Markup) {
        for child in markup.children() {
            self.visit(&child);
        }
    }

    // swift: AttributedBuilder.visitUnorderedList
    fn visit_unordered_list(&mut self, list: &UnorderedList) {
        let start = self.result.length();
        self.render_list(list.list_items.clone(), false, 0);
        self.newline(1);
        self.tag_block(start, list.range);
    }

    // swift: AttributedBuilder.visitOrderedList
    fn visit_ordered_list(&mut self, list: &OrderedList) {
        let start = self.result.length();
        self.render_list(list.list_items.clone(), true, 0);
        self.newline(1);
        self.tag_block(start, list.range);
    }

    /// Render list items at a given nesting `depth`. Each level indents one step further, so
    /// 2nd/3rd/4th-level bullets sit progressively inside. A list item's own text is rendered and
    /// styled first; nested child lists then recurse at depth+1 (they carry their own indent, so
    /// the parent's paragraph style is applied ONLY to the item's own line — not over the nested
    /// range, which would flatten it).
    // swift: AttributedBuilder.renderList
    fn render_list(&mut self, items: Vec<ListItem>, ordered: bool, depth: i32) {
        let hang = self.theme.base_font_size * self.theme.list_hang_ratio(); // one indent step
        let marker_x = depth as swiftshim::CGFloat * hang; // where the bullet / number sits
        let text_x = (depth + 1) as swiftshim::CGFloat * hang; // where the text (and wraps) align
        let ps = self.list_para(marker_x, text_x);
        let mut i = 1i32;
        for item in items {
            let s = self.result.length();
            // A GFM task-list item (`- [ ]` / `- [x]`) carries a `checkbox`; show it as a box glyph
            // in place of the bullet/number, so the checked state is visible. swift-markdown consumes
            // the `[ ]`/`[x]` into `item.checkbox`, so without this the ticks vanished entirely.
            let marker: String = if let Some(box_) = item.checkbox {
                format!("{}\t", if box_ == Checkbox::Checked { "☑" } else { "☐" })
            } else if ordered {
                format!("{}.\t", i)
            } else {
                format!("{}\t", self.bullet(depth))
            };
            let marker_attrs = std::collections::HashMap::from([
                (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(self.theme.body_font())),
                (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(self.theme.text_color())),
            ]);
            self.result.append(&swiftshim::NSAttributedString::with_attributes(&marker, marker_attrs));
            // The item's own paragraph text (skip nested lists — handled after, at depth+1).
            for child in &item.children {
                if !matches!(child, Markup::UnorderedList(_) | Markup::OrderedList(_)) {
                    self.render_block_inline(child);
                }
            }
            self.newline(1);
            self.result.addAttribute(
                swiftshim::NSAttributedStringKey::ParagraphStyle,
                swiftshim::AttrValue::ParagraphStyle(ps.clone()),
                swiftshim::NSRange::new(s, self.result.length() - s),
            );
            // Nested lists follow the item's line, indented one level deeper.
            for child in &item.children {
                match child {
                    Markup::UnorderedList(ul) => self.render_list(ul.list_items.clone(), false, depth + 1),
                    Markup::OrderedList(ol) => self.render_list(ol.list_items.clone(), true, depth + 1),
                    _ => {}
                }
            }
            i += 1;
        }
    }

    // swift: AttributedBuilder.bullet
    /// Bullet glyph per depth so nested levels read distinctly: • → ◦ → ▪ (then repeat).
    fn bullet(&self, depth: i32) -> &'static str {
        match depth.rem_euclid(3) {
            0 => "•",
            1 => "◦",
            _ => "▪",
        }
    }

    // swift: AttributedBuilder.listPara
    /// Hanging-indent paragraph style: marker at `markerX`, a tab pushes text to `textX`, and
    /// wrapped lines align at `textX` — so the item's first line and every wrap share one edge.
    fn list_para(&self, markerX: swiftshim::CGFloat, textX: swiftshim::CGFloat) -> swiftshim::NSParagraphStyle {
        let mut p = swiftshim::NSMutableParagraphStyle::default();
        let lh = (self.theme.base_font_size * self.theme.line_height_ratio()).round();
        p.minimumLineHeight = lh;
        p.maximumLineHeight = lh;
        p.paragraphSpacing = self.theme.base_font_size * self.theme.tight_spacing_ratio();
        p.firstLineHeadIndent = markerX;
        p.headIndent = textX;
        p.tabStops = vec![swiftshim::NSTextTab::new(swiftshim::NSTextAlignment::Left, textX, Default::default())];
        p.defaultTabInterval = textX;
        p
    }

    // swift: AttributedBuilder.renderBlockInline
    // List items contain paragraphs; render their inline content without extra blank lines.
    fn render_block_inline(&mut self, markup: &Markup) {
        if let Markup::Paragraph(p) = markup {
            let s = self.inline_string(&Markup::Paragraph(p.clone()), self.theme.body_font(), self.theme.text_color());
            self.result.append(&s);
        } else {
            let s = self.inline_string(markup, self.theme.body_font(), self.theme.text_color());
            self.result.append(&s);
        }
    }

    // swift: AttributedBuilder.visitCodeBlock
    fn visit_code_block(&mut self, codeBlock: &CodeBlock) {
        let block_start = self.result.length();
        // Fences WebKit draws instead of highlighting; everything else is a highlighted code card.
        match codeBlock.language.clone().unwrap_or_default().to_lowercase().as_str() {
            "mermaid" => {
                let src = self.source_offsets(codeBlock.range);
                self.append_web_block(
                    crate::render::web_block::Engine::Mermaid,
                    codeBlock.code.clone(),
                    src,
                    swiftshim::CGSize::new(480.0, 360.0),
                );
                return;
            }
            "math" | "tex" | "latex" => {
                // GitHub's ```math fence. A fence's content is verbatim, so unlike `$$…$$` there's no
                // emphasis to dodge — the parser hands over exactly what was typed.
                let src = self.source_offsets(codeBlock.range);
                self.append_web_block(
                    crate::render::web_block::Engine::Math,
                    codeBlock.code.clone(),
                    src,
                    swiftshim::CGSize::new(260.0, 60.0),
                );
                return;
            }
            _ => {}
        }
        // Card look: padding inside (head/tail indent) and gaps outside (paragraph spacing).
        // No flat .backgroundColor — CodeCardLayoutManager draws the rounded card backdrop.
        // Slightly open code leading — a bit more air between lines than a raw terminal.
        let code_lh = (self.theme.code_font().pointSize() * self.theme.code_line_height_ratio()).round();
        // The block is TWO paragraphs: a blank HEADER line (reserves room for the Copy / Wrap
        // buttons) and the CODE. Splitting them lets paragraphSpacingBefore on the code add a
        // real gap BELOW the buttons — a single \u{2028}-joined paragraph could not.
        let mut header_ps = swiftshim::NSMutableParagraphStyle::default();
        header_ps.headIndent = crate::render::code_card_metrics::CodeCardMetrics::TEXT_INSET;
        header_ps.firstLineHeadIndent = crate::render::code_card_metrics::CodeCardMetrics::TEXT_INSET;
        header_ps.tailIndent = -crate::render::code_card_metrics::CodeCardMetrics::TEXT_INSET;
        header_ps.paragraphSpacingBefore = crate::render::code_card_metrics::CodeCardMetrics::VERTICAL_PADDING + 6.0; // outer gap above the card
        header_ps.minimumLineHeight = code_lh;
        header_ps.maximumLineHeight = code_lh;

        let mut ps = swiftshim::NSMutableParagraphStyle::default();
        ps.headIndent = crate::render::code_card_metrics::CodeCardMetrics::TEXT_INSET;
        ps.firstLineHeadIndent = crate::render::code_card_metrics::CodeCardMetrics::TEXT_INSET;
        ps.tailIndent = -crate::render::code_card_metrics::CodeCardMetrics::TEXT_INSET;
        ps.paragraphSpacingBefore = 9.0; // breathing room UNDER the header buttons / divider
        ps.paragraphSpacing = crate::render::code_card_metrics::CodeCardMetrics::VERTICAL_PADDING + 6.0; // outer gap below the card
        ps.minimumLineHeight = code_lh;
        ps.maximumLineHeight = code_lh;
        ps.lineBreakMode = swiftshim::NSLineBreakMode::ByCharWrapping; // default: fold long lines (toggle to no-wrap per block)
        // Trailing newlines would render as empty lines inside the card (a 1–2 line gap at the
        // bottom). Drop them so the card hugs the last line of code.
        let mut code = codeBlock.code.clone();
        while code.ends_with('\n') || code.ends_with('\r') {
            code.pop();
        }
        // Header = ZWSP + a REAL newline so it is its own paragraph (2 chars — placeCopyButtons
        // skips them via location+2). The code that follows is ONE paragraph whose lines are
        // joined by U+2028, so no per-line paragraph spacing loosens the code.
        let header_attrs = std::collections::HashMap::from([
            (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(self.theme.code_font())),
            (swiftshim::NSAttributedStringKey::ForegroundColor, swiftshim::AttrValue::Color(self.theme.text_color())),
        ]);
        let mut highlighted = swiftshim::NSMutableAttributedString::with_attributes("\u{200B}\n", header_attrs);
        let mut code_attr = swiftshim::NSMutableAttributedString::from_attributed_string(
            &crate::render::code_highlighter::CodeHighlighter::highlight(&code, codeBlock.language.as_deref(), &self.theme),
        );
        code_attr.mutable_string_replace_occurrences("\n", "\u{2028}", swiftshim::NSRange::new(0, code_attr.length()));
        highlighted.append(code_attr.asAttributedString());
        let full = swiftshim::NSRange::new(0, highlighted.length());
        highlighted.addAttribute(swiftshim::NSAttributedStringKey::ParagraphStyle, swiftshim::AttrValue::ParagraphStyle(header_ps), swiftshim::NSRange::new(0, 2));
        highlighted.addAttribute(swiftshim::NSAttributedStringKey::ParagraphStyle, swiftshim::AttrValue::ParagraphStyle(ps), swiftshim::NSRange::new(2, highlighted.length() - 2));
        // Tag the block (C5: MDAttr, not a literal) with the code + its language so the
        // copy overlay and the no-wrap toggle can rebuild it.
        highlighted.addAttribute(crate::render::md_attr::MDAttr::code_block(), swiftshim::AttrValue::Text(code), full);
        highlighted.addAttribute(crate::render::md_attr::MDAttr::code_lang(), swiftshim::AttrValue::Text(codeBlock.language.clone().unwrap_or_default()), full);
        self.result.append(highlighted.asAttributedString());
        self.newline(2);
        self.tag_block(block_start, codeBlock.range);
    }

    // swift: AttributedBuilder.visitThematicBreak
    fn visit_thematic_break(&mut self, thematicBreak: &ThematicBreak) {
        // A zero-width line the layout manager paints as a full-width hairline.
        let start = self.result.length();
        let mut p = swiftshim::NSMutableParagraphStyle::default();
        p.paragraphSpacing = 10.0;
        p.paragraphSpacingBefore = 10.0;
        let attrs = std::collections::HashMap::from([
            (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(self.theme.body_font())),
            (crate::render::md_attr::MDAttr::rule(), swiftshim::AttrValue::Bool(true)),
            (swiftshim::NSAttributedStringKey::ParagraphStyle, swiftshim::AttrValue::ParagraphStyle(p)),
        ]);
        self.result.append(&swiftshim::NSAttributedString::with_attributes("\u{200B}", attrs));
        self.newline(1);
        self.tag_block(start, thematicBreak.range);
    }

    // swift: AttributedBuilder.visitTable
    fn visit_table(&mut self, table: &Table) {
        let start = self.result.length();
        let header_cells = table.head.cells.clone();
        let body_rows: Vec<Vec<markdown::TableCell>> = table.body.rows.iter().map(|r| r.cells.clone()).collect();
        let ncol = header_cells.len().max(body_rows.iter().map(|r| r.len()).max().unwrap_or(0));
        if ncol == 0 {
            self.newline(1);
            self.tag_block(start, table.range);
            return;
        }

        // swift: AttributedBuilder.renderRow
        // Real bordered grid via the shared `TableBlockBuilder` (also used by office tables) —
        // replaces the old monospaced "|"-joined text that wrapped into mush. Cell content is
        // rendered inline here so `code`, **bold**, and links work inside cells; the builder only
        // lays already-styled strings into `NSTextTableBlock` cells.
        // GFM tables never merge cells, so every cell is its own anchor with rowSpan/columnSpan 1
        // — `TableBlockBuilder.CellContent`'s defaults, unmentioned here.
        // swift: nested func renderRow(_:header:) -> [TableBlockBuilder.CellContent]
        fn render_row(
            this_: &AttributedBuilder,
            cells: &[TableCell],
            header: bool,
        ) -> Vec<crate::render::table_block_builder::CellContent> {
            let font = if header {
                swiftshim::NSFont::systemFontWeight(this_.theme.base_font_size, swiftshim::NSFontWeight::semibold)
            } else {
                this_.theme.body_font()
            };
            cells
                .iter()
                .map(|c| crate::render::table_block_builder::CellContent {
                    content: this_.inline_string(&Markup::TableCell(c.clone()), font.clone(), this_.theme.text_color()),
                    ..Default::default()
                })
                .collect()
        }
        let mut rows = vec![render_row(self, &header_cells, true)];
        rows.extend(body_rows.iter().map(|r| render_row(self, r, false)));
        let built = crate::render::table_block_builder::TableBlockBuilder::build(
            &rows,
            1,
            &self.theme,
            &[],
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            false,
            None,
            crate::render::table_block_builder::TableBlockBuilder::INITIAL_COLUMN_WIDTH,
        );
        self.result.append(&built);
        self.newline(1);
        self.tag_block(start, table.range);
    }
}

/// One markdown render, handed out front to back.
///
/// ONE builder for the whole document, deliberately: its `init` scans the source (line starts, math
/// spans) and was 16% of first paint on a 3.5 MB file, so re-creating it per chunk would pay that
/// again every time. Block ids also keep counting up across chunks, which is what invariant 19 asks
/// for — two neighbours sharing an id read as one stop for the reading cursor.
///
/// Each call returns only what the blocks it just visited ADDED, already through
/// `MarkdownRenderer.finishPasses`, ready to be appended to the storage as-is.
// swift: `final class` — reference semantics, so `swiftshim::Ref<T>` per convention §3; the type
// itself carries the fields, and callers hold it through `new_ref`.
// swift: ProgressiveMarkdownRender
pub struct ProgressiveMarkdownRender {
    builder: AttributedBuilder,
    children: Vec<Markup>,
    /// index of the next top-level child to visit
    next: usize,
    /// how much of `builder.result` has already been handed out
    mark: usize,
    /// How many pieces have been handed over, so a probe can report turns instead of guessing at them.
    chunks_handed_out: i32,
}

impl ProgressiveMarkdownRender {
    // swift: AttributedBuilder.visitTable
    fn new(builder: AttributedBuilder, children: Vec<Markup>) -> Self {
        Self { builder, children, next: 0, mark: 0, chunks_handed_out: 0 }
    }

    // swift: ProgressiveMarkdownRender.nextChunk
    pub fn is_finished(&self) -> bool {
        self.next >= self.children.len()
    }
    // swift: ProgressiveMarkdownRender.nextChunk
    pub fn block_count(&self) -> usize {
        self.children.len()
    }
    // swift: ProgressiveMarkdownRender.nextChunk
    /// Top-level blocks not yet visited — what a caller divides into the turns it is willing to take.
    pub fn remaining_blocks(&self) -> usize {
        self.children.len() - self.next
    }
    /// How many pieces have been handed over, so a probe can report turns instead of guessing at them.
    pub fn chunks_handed_out(&self) -> i32 {
        self.chunks_handed_out
    }

    // swift: ProgressiveMarkdownRender.nextChunk
    /// Visit up to `blocks` more top-level children and return the text they produced.
    pub fn next_chunk(&mut self, blocks: usize) -> swiftshim::NSAttributedString {
        // Clamped by SUBTRACTING from what is left, never by adding to `next`: `blocks` is allowed
        // to be `Int.max` ("all of it"), and `next + blocks` overflows — which trapped on the first
        // real document, in the append turn no probe ever reached.
        let take = blocks.max(1);
        let remaining = self.children.len() - self.next;
        let end = if take >= remaining { self.children.len() } else { self.next + take };
        self.chunk(|next| next >= end, true)
    }

    /// The same piece, stopping BEFORE font substitution — the form a host reads over the wire.
    ///
    /// Same reason as `MarkdownRenderer::render_before_host_font_substitution`: substitution
    /// belongs to whoever owns AppKit, and running it on both sides lands on two different faces
    /// (invariant 130). Autolink still runs over the piece, which is safe chunk by chunk because a
    /// top-level block boundary cannot fall inside a URL, a fence or a word.
    pub fn next_chunk_before_host_font_substitution(
        &mut self,
        blocks: usize,
    ) -> swiftshim::NSAttributedString {
        let take = blocks.max(1);
        let remaining = self.children.len() - self.next;
        let end = if take >= remaining { self.children.len() } else { self.next + take };
        self.chunk(|next| next >= end, false)
    }

    // swift: ProgressiveMarkdownRender.chunk
    /// Visit children until `stop` says so, then take everything those visits added.
    fn chunk(
        &mut self,
        stop: impl Fn(usize) -> bool,
        substitute_fonts: bool,
    ) -> swiftshim::NSAttributedString {
        while self.next < self.children.len() {
            let child = self.children[self.next].clone();
            self.builder.visit(&child);
            self.next += 1;
            if stop(self.next) {
                break;
            }
        }
        self.chunks_handed_out += 1;
        let full = self.builder.result.asAttributedString().clone();
        let mut delta = swiftshim::NSMutableAttributedString::from_attributed_string(
            &full.attributed_substring(swiftshim::NSRange::new(self.mark, full.length() - self.mark)),
        );
        self.mark = full.length();
        if substitute_fonts {
            MarkdownRenderer::finish_passes(&mut delta);
        } else {
            MarkdownRenderer::autolink(&mut delta);
        }
        delta.asAttributedString().clone()
    }
}

// The walker side of the package contract. `AttributedBuilder` already declares every one of these
// as an inherent method — transliterated from the Swift `visit*` overrides — so each of these
// forwards to it rather than restating anything: an inherent method wins name resolution, which is
// what makes `AttributedBuilder::visit_heading(self, node)` the ported body and not this line.
//
// Only the nine the Swift file overrides appear here. Every other shape reaches the trait's own
// default, which descends — `MarkupWalker`'s behaviour in the package, and the reason the Swift
// renderer never has to write a `visitText`.
impl crate::render::markdown_package::MarkupWalker for AttributedBuilder {
    fn visit(&mut self, markup: &markdown::Markup) {
        AttributedBuilder::visit(self, markup)
    }
    fn descend_into(&mut self, markup: &markdown::Markup) {
        AttributedBuilder::descend_into(self, markup)
    }
    fn visit_heading(&mut self, node: &markdown::Heading) {
        AttributedBuilder::visit_heading(self, node)
    }
    fn visit_paragraph(&mut self, node: &markdown::Paragraph) {
        AttributedBuilder::visit_paragraph(self, node)
    }
    fn visit_html_block(&mut self, node: &markdown::HTMLBlock) {
        AttributedBuilder::visit_html_block(self, node)
    }
    fn visit_block_quote(&mut self, node: &markdown::BlockQuote) {
        AttributedBuilder::visit_block_quote(self, node)
    }
    fn visit_unordered_list(&mut self, node: &markdown::UnorderedList) {
        AttributedBuilder::visit_unordered_list(self, node)
    }
    fn visit_ordered_list(&mut self, node: &markdown::OrderedList) {
        AttributedBuilder::visit_ordered_list(self, node)
    }
    fn visit_code_block(&mut self, node: &markdown::CodeBlock) {
        AttributedBuilder::visit_code_block(self, node)
    }
    fn visit_thematic_break(&mut self, node: &markdown::ThematicBreak) {
        AttributedBuilder::visit_thematic_break(self, node)
    }
    fn visit_table(&mut self, node: &markdown::Table) {
        AttributedBuilder::visit_table(self, node)
    }
}
