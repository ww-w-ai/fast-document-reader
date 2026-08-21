//! swift: Render/PlainTextRenderer.swift
//! swift-range: 1-2

// swift: Render/PlainTextRenderer.swift:3-24
/// Renders a NON-markdown text file (.txt, .csv, .log, …) verbatim. Nothing is parsed, so `#`,
/// `*`, `|` and `_` stay on screen exactly as they sit in the file — a plain text file that
/// happens to contain markdown punctuation must not silently turn into headings and italics.
///
/// Monospaced, because the files that land here (csv rows, logs, fixed-width tables) are written
/// expecting a fixed grid; a proportional font would break the only structure they have.
///
/// EVERY source line is one block — blank lines included — tagged with the same two attributes the
/// markdown renderer emits: `MDAttr.blockId` (a stop for the reading cursor / gutter click) and
/// `MDAttr.srcRange` (its exact span in the file). That is the whole integration: block edit, add,
/// delete and move are written against those attributes, so they work here for free.
///
/// Counting blank lines as blocks is what makes this a TEXT file rather than a prose document, and
/// it fixes two things at once: a blank line can be selected and deleted like any other line, and
/// "add below" inserts exactly one new line instead of copying the gap around the block — in
/// markdown a blank line separates paragraphs, but here it is simply an empty line the author put
/// there, and the app has no business preserving or reproducing it as structure.
///
/// A block's RENDERED range includes the line's terminator (so a blank line, which has no
/// characters of its own, still has something to be), while its SOURCE range covers only the line's
/// text — that keeps a replacement from swallowing the newline that separates it from the next line.
pub struct PlainTextRenderer;

impl PlainTextRenderer {
    // swift: Render/PlainTextRenderer.swift:25-71
    pub fn render(
        source: &str,
        theme: &crate::render::render_theme::RenderTheme,
    ) -> swiftshim::NSMutableAttributedString {
        let mut out = swiftshim::NSMutableAttributedString::new();
        let style = crate::render::render_theme::PlainTextStyle {
            theme: theme.clone(),
        };
        let font = swiftshim::NSFont::monospacedSystemFont(
            theme.base_font_size * style.mono_size_ratio(),
            swiftshim::NSFontWeight::regular,
        );
        let mut ps = swiftshim::NSMutableParagraphStyle::default();
        ps.lineHeightMultiple = 1.0;
        ps.minimumLineHeight = (theme.base_font_size * theme.line_height_ratio()).round();
        // Wrapped continuation lines are indented so a long csv row still reads as ONE row.
        ps.headIndent = theme.base_font_size * 1.5;
        let attrs: std::collections::HashMap<swiftshim::NSAttributedStringKey, swiftshim::AttrValue> =
            std::collections::HashMap::from([
                (swiftshim::NSAttributedStringKey::Font, swiftshim::AttrValue::Font(font.clone())),
                (
                    swiftshim::NSAttributedStringKey::ForegroundColor,
                    swiftshim::AttrValue::Color(theme.text_color()),
                ),
                (
                    swiftshim::NSAttributedStringKey::ParagraphStyle,
                    swiftshim::AttrValue::ParagraphStyle(ps.clone()),
                ),
            ]);

        let ns = swiftshim::SwiftString::new(source);
        let mut block_seq: i32 = 0;
        let mut line_start: usize = 0;
        while line_start < ns.length() {
            // `end` is where the next line begins; `contentsEnd` excludes this line's terminator.
            let (mut end, mut contents_end) = (0usize, 0usize);
            ns.getLineStart(
                None,
                &mut end,
                &mut contents_end,
                swiftshim::NSRange::new(line_start, 0),
            );
            let render_start = out.length();
            // The line INCLUDING its terminator, so the rendered string equals the file exactly —
            // dropping a trailing newline here would silently lose it on the next save.
            out.append(&swiftshim::NSAttributedString::with_attributes(
                &ns.substring(swiftshim::NSRange::new(line_start, end - line_start)),
                attrs.clone(),
            ));
            let content_length = contents_end - line_start;
            // Tag the whole line INCLUDING its terminator: an empty line has no characters of its
            // own, and a zero-length attribute range is no range at all — it would vanish, taking
            // the blank line's existence as a block with it.
            let r = swiftshim::NSRange::new(render_start, out.length() - render_start);
            if r.length > 0 {
                out.addAttribute(
                    crate::render::md_attr::MDAttr::block_id(),
                    swiftshim::AttrValue::Int(block_seq as i64),
                    r,
                );
                // The SOURCE range stays content-only, so replacing a line can't eat the newline
                // that separates it from the next one.
                out.addAttribute(
                    crate::render::md_attr::MDAttr::src_range(),
                    swiftshim::AttrValue::Range(swiftshim::NSRange::new(line_start, content_length)),
                    r,
                );
                block_seq += 1;
            }
            line_start = end;
        }
        // Same reason as the markdown path — see `applySubstitutions`.
        crate::render::office::font_substitution_resolver::FontSubstitutionResolver::apply_substitutions(
            &mut out,
            &crate::render::office::font_substitution_resolver::FontSubstitutionCache::default(),
        );
        out
    }
}
