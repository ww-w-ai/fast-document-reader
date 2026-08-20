//! swift: Render/Office/OfficeMarkdownSerializer.swift
//! swift-range: 1-20

// swift: Render/Office/OfficeMarkdownSerializer.swift:1-18
// Turns the format-neutral office block vocabulary (`OfficeBlock`, the SAME thing the reader
// renders — invariant 29's `OfficeReadResult.blocks`) into GitHub-flavoured Markdown, for the
// headless `--extract` path. Pure and view-free: `[OfficeBlock] -> String`, so it is fully unit
// testable without AppKit layout.
//
// Policy (conservative + honest, agreed with the owner):
//   - Map to real Markdown ONLY when it is unambiguous — headings, paragraphs, lists, simple
//     rectangular tables, inline bold/italic/strike/code/links, standalone formulas.
//   - When a construct can't be safely mapped (a merged-cell table, block content inside a cell),
//     do NOT fabricate a structure that would read as correct — dump the region's plain TEXT inside
//     a `<raw>…</raw>` marker instead. The CLI wrapper appends a one-line legend explaining `<raw>`
//     at the top of the document (the "footnote-style note" the owner asked for).
//   - Escaping is deliberately minimal (an AI consumer tolerates messy text far better than a
//     mangled table): only what would corrupt a structure WE emit — the `|` inside a pipe-table
//     cell, and newlines folded to spaces inside a span.
pub struct OfficeMarkdownSerializer;

impl OfficeMarkdownSerializer {
    // swift: Render/Office/OfficeMarkdownSerializer.swift:21-25
    /// The marker the CLI legend refers to. Callers check `output.contains(rawOpen)` to decide
    /// whether to include the `<raw>` explanation in the header note.
    pub const RAW_OPEN: &'static str = "<raw>";
    pub const RAW_CLOSE: &'static str = "</raw>";

    // swift: Render/Office/OfficeMarkdownSerializer.swift:26-61
    /// `footnotes` are appended as a trailing section, because they are no longer IN `blocks`.
    ///
    /// This is a data-loss guard, not a formatting choice. S14 lifted footnote bodies out of the
    /// body flow so they could be drawn at the foot of their own page; a serializer that only ever
    /// sees `blocks` would then silently drop them, and `--extract` exists precisely so a tool can
    /// read a document WITHOUT the reader — losing a third of a scholarly page's content there is
    /// the worst kind of failure, because nothing reports it. Endnotes need no such handling: they
    /// are still ordinary trailing blocks.
    pub fn serialize(
        blocks: &[crate::render::office::office_block::OfficeBlock],
        footnotes: &[crate::render::office::office_block::OfficeFootnote],
    ) -> String {
        let mut pieces: Vec<(String, bool)> = Vec::new();
        for block in blocks {
            let rendered = Self::render(block);
            if rendered.0.is_empty() {
                continue;
            }
            pieces.push(rendered);
        }
        let mut out = String::new();
        for (i, p) in pieces.iter().enumerate() {
            if i > 0 {
                // Consecutive list items stay in one list (single newline); everything else is
                // separated by a blank line so paragraphs/headings/tables don't run together.
                if p.1 && pieces[i - 1].1 {
                    out.push('\n');
                } else {
                    out.push_str("\n\n");
                }
            }
            out.push_str(&p.0);
        }
        if footnotes.is_empty() {
            return out;
        }
        // Markdown's own footnote spelling, so a tool reading this gets the association back rather
        // than a loose list of numbered lines. The body's marker is a superscript digit run and is
        // left as it is — rewriting it in place would mean editing spans the reader also draws.
        for note in footnotes {
            let body = Self::serialize(&note.blocks, &[]);
            if body.is_empty() {
                continue;
            }
            if !out.is_empty() {
                out.push_str("\n\n");
            }
            out.push_str(&format!(
                "[^{}]: {}",
                note.number,
                body.replace('\n', "\n    ")
            ));
        }
        out
    }

    // MARK: - Blocks
    // swift: Render/Office/OfficeMarkdownSerializer.swift:62-64

    // swift: Render/Office/OfficeMarkdownSerializer.swift:65-106
    fn render(block: &crate::render::office::office_block::OfficeBlock) -> (String, bool) {
        use crate::render::office::office_block::OfficeBlock;
        match block {
            OfficeBlock::heading { level, spans, .. } => {
                let hashes = "#".repeat((*level).clamp(1, 6) as usize);
                (
                    format!("{} {}", hashes, Self::inline(spans, false)),
                    false,
                )
            }
            OfficeBlock::paragraph { spans, .. } => (Self::inline(spans, false), false),
            OfficeBlock::listItem {
                level,
                ordered,
                spans,
                marker,
                ..
            } => {
                let indent = "  ".repeat((*level).max(0) as usize);
                let mark: String = if *ordered {
                    // Preserve the document's OWN resolved label (e.g. "1.", "a.", "1.1.2", a legal
                    // clause number) literally rather than letting Markdown auto-number — a real number
                    // the reader shows must survive extraction.
                    if let Some(m) = marker {
                        if !m.trim().is_empty() {
                            if m.ends_with(' ') {
                                m.clone()
                            } else {
                                format!("{} ", m)
                            }
                        } else {
                            "1. ".to_string()
                        }
                    } else {
                        "1. ".to_string()
                    }
                } else {
                    "- ".to_string()
                };
                (
                    format!("{}{}{}", indent, mark, Self::inline(spans, false)),
                    true,
                )
            }
            OfficeBlock::table { rows, header_rows, .. } => {
                (Self::render_table(rows, *header_rows), false)
            }
            OfficeBlock::image { id, .. } => (format!("![image]({})", id), false),
            OfficeBlock::unsupportedGraphic { label, .. } => {
                // The reader shows an honest placeholder for a chart/SmartArt with no picture fallback;
                // extraction mirrors that rather than inventing text that was never there.
                (format!("*[{}]*", label), false)
            }
            OfficeBlock::formula { latex } => (format!("$$\n{}\n$$", latex), false),
        }
    }

    // MARK: - Tables
    // swift: Render/Office/OfficeMarkdownSerializer.swift:106-108

    // swift: Render/Office/OfficeMarkdownSerializer.swift:109-117
    fn render_table(rows: &[Vec<crate::render::office::office_block::Cell>], header_rows: i32) -> String {
        let _ = header_rows;
        if rows.is_empty() {
            return String::new();
        }
        if Self::is_simple_grid(rows) {
            Self::pipe_table(rows)
        } else {
            Self::raw_table(rows)
        }
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:118-134
    /// A grid a GFM pipe table can hold: rectangular, no merged cells, and every cell's content is
    /// plain paragraph text (no nested table, list, image, or formula inside a cell).
    fn is_simple_grid(rows: &[Vec<crate::render::office::office_block::Cell>]) -> bool {
        use crate::render::office::office_block::OfficeBlock;
        use std::collections::HashSet;
        let widths: HashSet<usize> = rows.iter().map(|r| r.len()).collect();
        if widths.len() != 1 {
            return false;
        }
        let width = match widths.iter().next() {
            Some(w) => *w,
            None => return false,
        };
        if width == 0 {
            return false;
        }
        for row in rows {
            for cell in row {
                if cell.row_span != 1 || cell.col_span != 1 {
                    return false;
                }
                for b in &cell.blocks {
                    match b {
                        OfficeBlock::paragraph { .. } => continue,
                        _ => return false,
                    }
                }
            }
        }
        true
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:135-148
    fn pipe_table(rows: &[Vec<crate::render::office::office_block::Cell>]) -> String {
        let width = rows[0].len();
        let row_line = |row: &[crate::render::office::office_block::Cell]| -> String {
            format!(
                "| {} |",
                row.iter()
                    .map(|c| Self::cell_inline(c))
                    .collect::<Vec<_>>()
                    .join(" | ")
            )
        };
        // GFM requires a header row + a delimiter line. The office model may report `headerRows == 0`
        // (an un-styled table — see `OfficeBlock.table`'s doc), but a pipe table has no "no header"
        // form, so row 0 becomes the header and every other row is body. No cell is dropped.
        let mut lines = vec![
            row_line(&rows[0]),
            format!("| {} |", vec!["---"; width].join(" | ")),
        ];
        for row in rows.iter().skip(1) {
            lines.push(row_line(row));
        }
        lines.join("\n")
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:149-157
    fn raw_table(rows: &[Vec<crate::render::office::office_block::Cell>]) -> String {
        let mut lines = vec![
            Self::RAW_OPEN.to_string(),
            "[table — merged cells or block content; structure not mapped, cells below are literal]"
                .to_string(),
        ];
        for row in rows {
            lines.push(
                row.iter()
                    .map(|c| Self::plain_cell(c))
                    .collect::<Vec<_>>()
                    .join(" | "),
            );
        }
        lines.push(Self::RAW_CLOSE.to_string());
        lines.join("\n")
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:158-168
    fn cell_inline(cell: &crate::render::office::office_block::Cell) -> String {
        use crate::render::office::office_block::OfficeBlock;
        let mut parts: Vec<String> = Vec::new();
        for b in &cell.blocks {
            if let OfficeBlock::paragraph { spans, .. } = b {
                let s = Self::inline(spans, true);
                if !s.is_empty() {
                    parts.push(s);
                }
            }
        }
        parts.join(" ")
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:169-179
    fn plain_cell(cell: &crate::render::office::office_block::Cell) -> String {
        let joined = cell
            .blocks
            .iter()
            .map(|b| Self::plain_block(b))
            .collect::<Vec<_>>()
            .join(" ");
        joined.replace('\n', " ")
    }

    // MARK: - Inline spans
    // swift: Render/Office/OfficeMarkdownSerializer.swift:173-175

    // swift: Render/Office/OfficeMarkdownSerializer.swift:176-178
    fn inline(spans: &[crate::render::office::office_block::Span], inCell: bool) -> String {
        Self::coalesced(spans)
            .iter()
            .map(|s| Self::span(s, inCell))
            .collect::<Vec<_>>()
            .join("")
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:180-206
    /// Undoes `FontSubstitutionResolver`'s read-time span splitting before any Markdown delimiter is
    /// emitted. That resolver cuts one logical run into several `Span`s purely so `OfficeTextBuilder`
    /// can assign each piece its own on-screen substitute FONT (invariant 37/§`docs/font-substitution
    /// -cost-design.md`) — a rendering concern this serializer has no notion of and must not leak
    /// through: `span(_:inCell:)` wraps EVERY `Span` in its own delimiters, so two adjacent pieces of
    /// one bold run that the resolver split (e.g. one Korean substitute for `'18`, another for `년`)
    /// would otherwise close and reopen `**…**` between them, corrupting the Markdown an AI receives
    /// (`**'18****년**`) and the code/link fencing the same way. Two adjacent spans are merged back
    /// into one when they are equal in EVERY field this serializer or a future one could read except
    /// `text` and `resolvedFontDescriptor` — which is exactly the shape the resolver's split leaves
    /// behind, since it only ever divides one source `Span` into contiguous pieces with everything
    /// but those two fields copied verbatim.
    fn coalesced(
        spans: &[crate::render::office::office_block::Span],
    ) -> Vec<crate::render::office::office_block::Span> {
        if spans.len() <= 1 {
            return spans.to_vec();
        }
        let mut out: Vec<crate::render::office::office_block::Span> = Vec::with_capacity(spans.len());
        for s in spans {
            let mut merged = false;
            if let Some(last) = out.last_mut() {
                if last.footnote_ref.is_none()
                    && s.footnote_ref.is_none()
                    && Self::same_markdown_identity(last, s)
                {
                    last.text.push_str(&s.text);
                    merged = true;
                }
            }
            if !merged {
                out.push(s.clone());
            }
        }
        out
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:207-230
    /// Two adjacent spans are the SAME as far as Markdown is concerned iff they agree on every
    /// property Markdown can actually write down.
    ///
    /// **Stated as the short list of what counts, not as a growing list of what to ignore.** The
    /// authority is `span(_:inCell:)` immediately below, which reads exactly these five fields and
    /// nothing else: a `Span` also carries colour, highlight, size, family, underline style, caps,
    /// small-caps, super/subscript, bookmarks and comment ids, and Markdown has no syntax for any of
    /// them. Comparing all twenty fields therefore split emphasis on differences the output cannot
    /// even express — `**text****more**`, an opening and closing marker around nothing, which is
    /// exactly the corruption invariant 40 exists to keep out of what an AI reads.
    ///
    /// The subtractive version this replaces cleared `text` and `resolvedFontDescriptor`, which was
    /// right for the one read-time pass that existed when it was written and silently wrong for
    /// every pass added since. Per-script fonts (`docs/per-script-font-design.md`) split on
    /// `fontName`, and on a real HWP report `제Ⅰ장 서론10` came out as `**제****Ⅰ****장 서론10**`
    /// because Ⅰ (U+2160 ROMAN NUMERAL ONE) is Script=Latin, so the document's Hangul and Latin
    /// families cut one heading into three. A list of exclusions has to be updated by whoever adds
    /// the next splitting pass, and will not be; a list of inclusions only has to be updated by
    /// whoever teaches `span(_:inCell:)` a new piece of Markdown syntax, which is the same edit.
    fn same_markdown_identity(
        a: &crate::render::office::office_block::Span,
        b: &crate::render::office::office_block::Span,
    ) -> bool {
        a.code == b.code
            && a.bold == b.bold
            && a.italic == b.italic
            && a.strikethrough == b.strikethrough
            && a.link == b.link
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:231-257
    fn span(s: &crate::render::office::office_block::Span, inCell: bool) -> String {
        // A footnote marker becomes the markdown reference that points at the note this serializer
        // already emits at the end (`[^3]: …`). Without it the extraction keeps every note's TEXT
        // and loses every note's PLACE: the reader that lifted the note out of the body flow is the
        // only thing that knows which sentence called it, so a tool reading the extraction would
        // see five notes and no way to tell what any of them annotates. The marker's own glyphs
        // (`3)`) are dropped deliberately — markdown writes the reference itself.
        if let Some(r) = s.footnote_ref {
            return format!("[^{}]", r);
        }
        if s.text.is_empty() {
            return String::new();
        }
        if s.code {
            // Inline code is verbatim — no other Markdown applies inside it. Bump the fence past any
            // backticks the code itself contains so it can't close early.
            let ticks = "`".repeat(Self::longest_backtick_run(&s.text) + 1);
            let pad = if s.text.starts_with('`') || s.text.ends_with('`') {
                " "
            } else {
                ""
            };
            return format!("{}{}{}{}{}", ticks, pad, s.text, pad, ticks);
        }
        let mut t = Self::escape_text(&s.text, inCell);
        if s.strikethrough {
            t = format!("~~{}~~", t);
        }
        if s.bold && s.italic {
            t = format!("***{}***", t);
        } else if s.bold {
            t = format!("**{}**", t);
        } else if s.italic {
            t = format!("*{}*", t);
        }
        if let Some(link) = &s.link {
            if !link.trim().is_empty() {
                t = format!("[{}]({})", t, link);
            }
        }
        t
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:258-266
    /// Minimal, per policy: fold hard newlines to spaces (a span is inline, not a block), and inside
    /// a pipe-table cell escape `|` so a literal bar can't split the column. Prose keeps its literal
    /// `*`/`#`/`_` — an AI reader tolerates that far better than an over-escaped wall of backslashes.
    fn escape_text(text: &str, inCell: bool) -> String {
        let mut t = text.replace('\n', " ");
        if inCell {
            t = t.replace('|', "\\|");
        }
        t
    }

    // swift: Render/Office/OfficeMarkdownSerializer.swift:267-273
    fn longest_backtick_run(s: &str) -> usize {
        let mut longest = 0usize;
        let mut cur = 0usize;
        for ch in s.chars() {
            if ch == '`' {
                cur += 1;
                longest = longest.max(cur);
            } else {
                cur = 0;
            }
        }
        longest
    }

    // MARK: - Plain-text extraction (for <raw> dumps)
    // swift: Render/Office/OfficeMarkdownSerializer.swift:274-276

    // swift: Render/Office/OfficeMarkdownSerializer.swift:277-289
    fn plain_block(block: &crate::render::office::office_block::OfficeBlock) -> String {
        use crate::render::office::office_block::OfficeBlock;
        match block {
            OfficeBlock::heading { spans, .. } => {
                spans.iter().map(|s| s.text.clone()).collect::<Vec<_>>().join("")
            }
            OfficeBlock::paragraph { spans, .. } => {
                spans.iter().map(|s| s.text.clone()).collect::<Vec<_>>().join("")
            }
            OfficeBlock::listItem { spans, .. } => {
                spans.iter().map(|s| s.text.clone()).collect::<Vec<_>>().join("")
            }
            OfficeBlock::table { rows, .. } => rows
                .iter()
                .map(|row| {
                    row.iter()
                        .map(|c| Self::plain_cell(c))
                        .collect::<Vec<_>>()
                        .join(" | ")
                })
                .collect::<Vec<_>>()
                .join("\n"),
            OfficeBlock::image { id, .. } => format!("[image {}]", id),
            OfficeBlock::unsupportedGraphic { label, .. } => format!("[{}]", label),
            OfficeBlock::formula { latex } => latex.clone(),
        }
    }
}
