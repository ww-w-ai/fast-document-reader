//! swift: Render/Office/DocxReader.swift
//!
//! First half of the transliteration of `DocxReader.swift` (lines 1-1975 of 3938). The file was
//! split across two Rust files only because two workers ported it in parallel; the seam is the
//! source's own `// MARK: Images` boundary (line 1976), so no declaration is cut in half. See
//! `docx_reader/mod.rs` for the reunification and `docs/plans/rust-port-convention.md` for the
//! phase-A rules this file follows: copy structure/order/names/comments, convert syntax only,
//! `todo!("swift:<lines> <what>")` for anything not yet expressible, never drop a branch.
//!
//! `XMLNode` is defined later in the Swift file (line 3859, this file's own `buildTree` at 3572)
//! — inside the SIBLING half (`part_b.rs`) of this same source file, not this range. It is
//! referenced here by its Swift name, `super::XMLNode`, exactly as the convention prescribes for
//! a type this worker did not port. Likewise `OfficeBlock`/`Span`/`TabStop`/… come from
//! `Render/Office/OfficeBlock.swift` and `WordRFonts`/`WordThemeFonts`/… from
//! `Render/Office/WordFontSlots.swift` — both in the port manifest, both possibly still being
//! ported by other workers when this file was written. Referenced by their Swift names.

// swift: Render/Office/DocxReader.swift:1-3
use swiftshim::{CGFloat, NSColor, NSTextAlignment};

use crate::render::office::zip_archive::ZipArchive;
// OfficeBlock.swift's vocabulary — not yet known to exist as a module member list, referenced by
// the Swift names used throughout this file.
use crate::render::office::office_block::{
    EdgePadding, HeaderFooterApplicability, LineHeight, OfficeBlock, OfficeComment,
    OfficeHeaderFooter, OfficeReadResult, ParagraphFormat, RectEdge, Span, TabAlignment,
    TabLeader, TabStop,
};
// WordFontSlots.swift's vocabulary.
use crate::render::office::word_font_slots::{WordFontDecl, WordFontSlot, WordRFonts, WordThemeFonts};

// The sibling half of this same Swift file (part_b.rs) owns `XMLNode` and `buildTree` — both
// referenced here by name, not defined here.
use super::XMLNode;

/// `.docx` bytes → `[OfficeBlock]`. Word's own container is three XML parts inside the ZIP
/// `ZipArchive` already knows how to open: `word/document.xml` (the body, required), and two
/// optional ones this reader consults to resolve what the body only references by id —
/// `word/styles.xml` (a paragraph style's `w:outlineLvl`, which is what actually makes it a
/// heading) and `word/numbering.xml` (whether a list level is a bullet or a number). Neither
/// being absent is an error — Word omits `numbering.xml` from documents with no lists at all —
/// so both fall back to an empty table and the body still parses.
///
/// `enum DocxReader: OfficeDocumentReader` in Swift is a case-less enum used purely as a
/// namespace for `static func`s — no instance is ever created. Ported as a case-less Rust enum
/// with every member an associated function, the same "namespace, never a value" shape. The
/// `OfficeDocumentReader` conformance itself is not modeled here: that protocol is declared
/// outside this file's scope (`DocumentTypes.swift`, not in the port manifest for this sprint),
/// so there is nothing in this crate yet to `impl` it against.
// swift: Render/Office/DocxReader.swift:12-12
pub enum DocxReader {}

// swift: Render/Office/DocxReader.swift:13-29
/// `DocxReader.ReadError` — the errors `DocxReader::read` can throw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DocxReaderReadError {
    /// `word/document.xml` is missing from the archive. Returning an empty document here
    /// would look like a genuinely blank file — the worst failure mode for a reader — so
    /// this throws instead.
    MissingDocumentXML,
    /// A required XML part did not parse (malformed XML). Named by its archive path so the
    /// error is actionable.
    MalformedXML(String),
}

// swift: Render/Office/DocxReader.swift:22-29
impl DocxReaderReadError {
    pub fn error_description(&self) -> String {
        match self {
            DocxReaderReadError::MissingDocumentXML => {
                "This .docx file has no word/document.xml — it may be corrupt.".to_string()
            }
            DocxReaderReadError::MalformedXML(part) => {
                format!("\"{}\" could not be parsed as XML.", part)
            }
        }
    }
}

impl std::fmt::Display for DocxReaderReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.error_description())
    }
}

impl std::error::Error for DocxReaderReadError {}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:30-90
    /// This reader emits `.image` blocks (see `collectImages`) — PARSING only. Resolving an
    /// emitted id to actual pixels (reading the archive entry, drawing a placeholder for an
    /// unresolvable one) is a later sprint's job.
    pub fn read(archive: &ZipArchive) -> Result<OfficeReadResult, DocxReaderReadError> {
        if !archive.contains("word/document.xml") {
            return Err(DocxReaderReadError::MissingDocumentXML);
        }
        let document_root = Self::build_tree(
            &archive
                .data_for("word/document.xml")
                .map_err(|_| DocxReaderReadError::MalformedXML("word/document.xml".to_string()))?
                .0,
        )
        .map_err(|_| DocxReaderReadError::MalformedXML("word/document.xml".to_string()))?;
        let theme_colors = Self::parse_theme_colors(archive);
        let theme_fonts = Self::parse_theme_fonts(archive);
        let style_info = Self::parse_styles(archive, &theme_colors, &theme_fonts);
        let numbering = Self::parse_numbering(archive);
        let relationships = Self::parse_relationships(archive, "word/document.xml");
        let Some(body) = document_root.child("w:body") else {
            return Ok(OfficeReadResult { blocks: vec![], ..Default::default() });
        };
        // Footnote/endnote numbering is resolved BEFORE the body is walked for real: Word doesn't
        // stamp an explicit display number on `w:footnoteReference`/`w:endnoteReference` (unlike
        // ODF's `text:note-citation`, which literally contains its own marker text) — the number is
        // purely positional, so it has to come from a first pass over the whole body in document
        // order, footnotes and endnotes counted separately (each is its own sequence in Word, both
        // starting at 1). This is "auto-number", not "invented" — it's the same number Word itself
        // would display.
        let (footnote_number_by_id, endnote_number_by_id, citation_order) =
            Self::number_note_references(&body);
        let notes = NoteNumbering { footnote: footnote_number_by_id, endnote: endnote_number_by_id };
        // Comment RANGE numbering — same "resolve positional numbering in a first pass" approach as
        // footnotes/endnotes above, from the order `w:commentRangeStart` ids first appear in the
        // body (see `CommentRangeTracking`'s own doc for why this is a class, not a struct).
        let comment_number_by_id = Self::number_comment_references(&body);
        let comments = CommentRangeTracking::new(comment_number_by_id.clone());
        // ONE numbering-counter state for the whole read() call — body, then footnotes, then
        // endnotes, all walked from here in that order — because a numId's counters belong to the
        // numId, not to which of those three regions a paragraph happens to sit in (see
        // `ListNumberingState`).
        let list_state = swiftshim::new_ref(ListNumberingState::default());
        let body_blocks = Self::parse_body(
            &body, &style_info, &numbering, &relationships, &notes, &comments, &list_state,
        );
        let footnote_bodies = Self::parse_note_bodies(archive, "word/footnotes.xml", "w:footnote");
        let endnote_bodies = Self::parse_note_bodies(archive, "word/endnotes.xml", "w:endnote");
        let note_blocks = Self::collect_note_blocks(
            &citation_order, &footnote_bodies, &endnote_bodies, &style_info, &numbering,
            &relationships, &notes, &comments, &list_state,
        );
        let office_comments = Self::parse_comments(archive, &comment_number_by_id);
        let page = Self::page_geometry(&body);
        // header-footer-design.md step 2 — read ONLY, nothing renders these yet.
        let headers = Self::header_footer_entries(
            &body, "w:headerReference", &relationships, archive, &style_info, &numbering,
        );
        let footers = Self::header_footer_entries(
            &body, "w:footerReference", &relationships, archive, &style_info, &numbering,
        );
        let mut blocks = body_blocks;
        blocks.extend(note_blocks);
        Ok(OfficeReadResult {
            blocks,
            comments: office_comments,
            page_content_width: page.as_ref().map(|p| p.content),
            page_margin_left: page.as_ref().map(|p| p.left),
            page_margin_right: page.as_ref().map(|p| p.right),
            page_content_height: page.as_ref().and_then(|p| p.height),
            page_margin_top: page.as_ref().and_then(|p| p.top),
            page_margin_bottom: page.as_ref().and_then(|p| p.bottom),
            page_header_distance: page.as_ref().and_then(|p| p.header_distance),
            page_footer_distance: page.as_ref().and_then(|p| p.footer_distance),
            headers,
            footers,
            line_grid_pitch: Self::line_grid_pitch(&body),
            ..Default::default()
        })
    }

    // swift: Render/Office/DocxReader.swift:92-101
    /// The body section's line-grid pitch in points, or nil when it declares none — see
    /// `OfficeReadResult.lineGridPitch` for what it is FOR.
    ///
    /// Only the two `w:type` values that put lines on a grid count. `"default"` means no grid at all
    /// and `"chars"` grids the horizontal axis only, so neither may set a line height; reading them
    /// as one would impose an 18pt floor on documents Word leaves alone. A non-positive pitch is
    /// discarded for the same reason `pageGeometry` guards its width — a malformed number must not
    /// become a layout instruction.
    fn line_grid_pitch(body: &XMLNode) -> Option<CGFloat> {
        let sect_pr = Self::typeset_section_properties(body)?;
        let grid = sect_pr.child("w:docGrid")?;
        let kind = grid.attributes.get("w:type").cloned().unwrap_or_else(|| "default".to_string());
        if kind != "lines" && kind != "linesAndChars" {
            return None;
        }
        let pitch_str = grid.attributes.get("w:linePitch")?;
        let twips: f64 = pitch_str.parse().ok()?;
        if twips <= 0.0 {
            return None;
        }
        Some((twips / 20.0) as CGFloat)
    }

    // swift: Render/Office/DocxReader.swift:103-124
    /// The section properties this document is TYPESET on — the section holding the most paragraphs,
    /// not the last one the body happens to end with.
    ///
    /// Word states a page per SECTION exactly as HWP does, and invariant 73 measured what taking the
    /// wrong one costs there: a 14-section manual typeset on its title page's margins came out 64
    /// pages long. The docx equivalent is the mirror image — the body's TRAILING `w:sectPr` is the
    /// LAST section's, so a report whose final section is a landscape appendix or a one-page
    /// colophon typesets the whole document on that page. A section ends at the paragraph whose
    /// `w:pPr/w:sectPr` closes it, and the body's own trailing one closes the last section; counting
    /// the paragraphs between those boundaries is the same "most content wins" rule HWP uses, with
    /// ties going to the EARLIER section.
    ///
    /// A single-section document — the overwhelming majority — has exactly one candidate, so this
    /// returns precisely what `children.last` returned before it existed.
    fn typeset_section_properties(body: &XMLNode) -> Option<&XMLNode> {
        let mut sections: Vec<(&XMLNode, i32)> = Vec::new();
        let mut paragraphs = 0;
        for child in body.children.iter() {
            match child.name.as_str() {
                "w:p" => {
                    paragraphs += 1;
                    if let Some(sect_pr) = child.child("w:pPr").and_then(|p| p.child("w:sectPr")) {
                        sections.push((sect_pr, paragraphs));
                        paragraphs = 0;
                    }
                }
                "w:tbl" => {
                    // A table is content too — a section made of one long table must not read as empty.
                    paragraphs += 1;
                }
                "w:sectPr" => {
                    sections.push((child, paragraphs));
                    paragraphs = 0;
                }
                _ => continue,
            }
        }
        if sections.is_empty() {
            return None;
        }
        // `max(by:)` returns the LAST maximum, which would silently prefer the later section on a
        // tie — the same trap invariant 73 names for HWP's `max_by_key`.
        let mut best = sections[0];
        for section in sections.iter().skip(1) {
            if section.1 > best.1 {
                best = *section;
            }
        }
        Some(best.0)
    }

    // swift: Render/Office/DocxReader.swift:154-164
    /// The document's page BODY width in points — the body-level `w:sectPr`'s `w:pgSz@w:w` minus its
    /// `w:pgMar@w:left`/`@w:right`, all in twips (÷20 = pt). The body's OWN trailing `w:sectPr` is the
    /// last section's page setup (invariant: `read`'s `:1789` note — the body's trailing `w:sectPr` is
    /// section properties, not a block). `orient="landscape"` needs no swap: Word stores the pgSz
    /// `w:w`/`w:h` already rotated for landscape. Returns nil when there is no `w:sectPr`/`w:pgSz` or
    /// the computed width is ≤0 → the reader keeps its window-filling column (byte-identical to a
    /// document that declares no page size). Twips÷20 matches every other length in this reader
    /// (`gridCol`, indents).
    #[allow(dead_code)]
    fn page_content_width(body: &XMLNode) -> Option<CGFloat> {
        Self::page_geometry(body).map(|g| g.content)
    }

    // swift: Render/Office/DocxReader.swift:166-221
    /// The body `w:sectPr`'s page geometry in points: the printable column and the margins either
    /// side of it, PLUS the vertical twin of that same pair — the printable row span and the margins
    /// above/below it (`OfficeReadResult.pageContentHeight`). The margins were always computed here in
    /// order to be SUBTRACTED; they are kept now because a paged view reproduces the PAPER
    /// (`left + content + right`, `top + height + bottom`), not just the column — see
    /// `OfficeReadResult.pageMarginLeft`.
    ///
    /// Height/top/bottom are a SEPARATE guard from width/left/right above: a document that states
    /// `w:pgSz@w:w` but not `@w:h` (or whose vertical geometry computes to ≤0) must not lose its
    /// WIDTH, which the width guard already protects on its own without needing `w:pgMar` to exist at
    /// all — so a bad/missing height clamps only `height`/`top`/`bottom` to nil, never the whole
    /// return value.
    fn page_geometry(body: &XMLNode) -> Option<PageGeometry> {
        let sect_pr = Self::typeset_section_properties(body)?;
        let pg_sz = sect_pr.child("w:pgSz")?;
        let w: f64 = pg_sz.attributes.get("w:w")?.parse().ok()?;
        let mar = sect_pr.child("w:pgMar");
        let left = mar.as_ref().and_then(|m| m.attributes.get("w:left")).and_then(|v| v.parse().ok()).unwrap_or(0.0);
        let right = mar.as_ref().and_then(|m| m.attributes.get("w:right")).and_then(|v| v.parse().ok()).unwrap_or(0.0);
        let content = (w - left - right) / 20.0; // twips → pt
        if content <= 0.0 {
            return None;
        }
        // A negative margin is legal in the schema and meaningless as white space — clamp rather than
        // let it eat into the paper width and produce a sheet narrower than its own text column.
        let mut height: Option<CGFloat> = None;
        let mut top: Option<CGFloat> = None;
        let mut bottom: Option<CGFloat> = None;
        if let Some(h_str) = pg_sz.attributes.get("w:h") {
            if let Ok(h) = h_str.parse::<f64>() {
                let t = mar.as_ref().and_then(|m| m.attributes.get("w:top")).and_then(|v| v.parse().ok()).unwrap_or(0.0);
                let b = mar.as_ref().and_then(|m| m.attributes.get("w:bottom")).and_then(|v| v.parse().ok()).unwrap_or(0.0);
                let content_height = (h - t - b) / 20.0;
                if content_height > 0.0 {
                    height = Some(content_height as CGFloat);
                    top = Some((t.max(0.0) / 20.0) as CGFloat);
                    bottom = Some((b.max(0.0) / 20.0) as CGFloat);
                }
            }
        }
        // The running header's/footer's own distance from the SHEET's edge (`w:pgMar/@w:header`,
        // `@w:footer`) — a different quantity from the body margins above, and the one that makes the
        // band's spacing identical on every page. Only meaningful alongside a real page height, and
        // only when it actually fits inside its own margin: a header distance past the top margin
        // would place the header inside the body text, which no document means.
        let mut header_distance: Option<CGFloat> = None;
        let mut footer_distance: Option<CGFloat> = None;
        if height.is_some() {
            if let Some(raw) = mar.as_ref().and_then(|m| m.attributes.get("w:header")).and_then(|v| v.parse::<f64>().ok()) {
                if raw >= 0.0 {
                    let d = (raw / 20.0) as CGFloat;
                    if d < top.unwrap_or(0.0) {
                        header_distance = Some(d);
                    }
                }
            }
            if let Some(raw) = mar.as_ref().and_then(|m| m.attributes.get("w:footer")).and_then(|v| v.parse::<f64>().ok()) {
                if raw >= 0.0 {
                    let d = (raw / 20.0) as CGFloat;
                    if d < bottom.unwrap_or(0.0) {
                        footer_distance = Some(d);
                    }
                }
            }
        }
        Some(PageGeometry {
            content: content as CGFloat,
            left: (left.max(0.0) / 20.0) as CGFloat,
            right: (right.max(0.0) / 20.0) as CGFloat,
            height,
            top,
            bottom,
            header_distance,
            footer_distance,
        })
    }

    // swift: Render/Office/DocxReader.swift:223-249
    /// The source document's own default BODY run size, in points — `word/styles.xml`'s
    /// `w:docDefaults/w:rPrDefault/w:rPr/w:sz` (HALF-points), or **10pt** when the document declares
    /// none at all (no `word/styles.xml`, no `w:docDefaults`, or no `w:sz` inside it).
    ///
    /// 10, not the 11 this shipped with, and the difference is measured rather than looked up. 11 is
    /// what MODERN Word WRITES into a new document's `w:docDefaults`; it is not what Word ASSUMES
    /// when the element is missing, and the two are easy to confuse. On a real Korean report that
    /// declares no `w:sz` anywhere, Word's own PDF draws 국경일 30.08pt wide across three full-width
    /// glyphs — a 10.03pt em. Under the paged model this constant IS the theme base size, so it
    /// decided 99.1% of that document's characters (9,567 of 9,657) and made every one of them ~10%
    /// too large.
    ///
    /// A document that DOES declare a size is untouched, which is the case invariant 37 protects.
    /// This is the OTHER half of `OfficeTextBuilder.build`'s font-size model — see its
    /// `documentDefaultFontSize` parameter's own doc. Named (and shaped) to match `OfficeDocumentReader`
    /// exactly, and reached ONLY through `DocumentTypes.officeDefaultBodyFontSize` — see that file for
    /// why a second, direct call site would risk the same reader/extension divergence invariant 29
    /// records.
    pub fn document_default_body_font_size(archive: &ZipArchive) -> CGFloat {
        if !archive.contains("word/styles.xml") {
            return 10.0;
        }
        let Ok(data) = archive.data_for("word/styles.xml") else { return 10.0 };
        let Ok(root) = Self::build_tree(&data.0) else { return 10.0 };
        let Some(sz_val) = root
            .child("w:docDefaults")
            .and_then(|n| n.child("w:rPrDefault"))
            .and_then(|n| n.child("w:rPr"))
            .and_then(|n| n.child("w:sz"))
            .and_then(|n| n.attributes.get("w:val").cloned())
        else {
            return 10.0;
        };
        let Ok(half) = sz_val.parse::<f64>() else { return 10.0 };
        (half / 2.0) as CGFloat
    }
}

/// `pageGeometry`'s return tuple, named because Rust doesn't spell an inline 8-field tuple type
/// as tersely as Swift's labeled tuple return — same fields, same order.
// swift: Render/Office/DocxReader.swift:178-178
#[derive(Debug, Clone, Copy)]
struct PageGeometry {
    content: CGFloat,
    left: CGFloat,
    right: CGFloat,
    height: Option<CGFloat>,
    top: Option<CGFloat>,
    bottom: Option<CGFloat>,
    header_distance: Option<CGFloat>,
    footer_distance: Option<CGFloat>,
}

// swift: Render/Office/DocxReader.swift:251-251
// MARK: Comments (word/comments.xml + w:commentRangeStart/End/Reference)

/// Shared state for one body walk that tracks currently-OPEN comment ranges
/// (`w:commentRangeStart` … `w:commentRangeEnd`) so every `Span` emitted while a range is open
/// can carry that comment's id (see `Span.commentIds`). A class, not a struct, because a
/// start/end pair is encountered as an isolated, order-dependent side effect deep inside
/// `collectSpans`' walk — passing this BY REFERENCE keeps every call site (`parseBody` down to
/// `collectSpans`, text boxes, table cells, nested tables) in sync with the same "what's open
/// right now" state, the same threading pattern `NoteNumbering` uses for read-only footnote/
/// endnote numbers, just mutable. `numberById` is precomputed once, before the walk starts (see
/// `numberCommentReferences`), from first-appearance order of `w:commentRangeStart` in the body.
// swift: Render/Office/DocxReader.swift:262-268
pub struct CommentRangeTracking {
    pub(crate) number_by_id: std::collections::HashMap<String, i32>,
    pub(crate) active_ids: std::cell::RefCell<Vec<String>>,
}

impl CommentRangeTracking {
    pub(crate) fn new(number_by_id: std::collections::HashMap<String, i32>) -> Self {
        CommentRangeTracking { number_by_id, active_ids: std::cell::RefCell::new(Vec::new()) }
    }
    pub(crate) fn start(&self, id: String) {
        self.active_ids.borrow_mut().push(id);
    }
    pub(crate) fn end(&self, id: &str) {
        self.active_ids.borrow_mut().retain(|x| x != id);
    }
    pub(crate) fn active_ids_snapshot(&self) -> Vec<String> {
        self.active_ids.borrow().clone()
    }
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:270-289
    /// First pass over the body (mirrors `numberNoteReferences`): assigns each comment id the
    /// 1-based number of the ORDER its `w:commentRangeStart` first appears, document order,
    /// depth-first — the same number a comment sidebar would show. A comment id that never opens a
    /// range in the body (comments.xml lists it, but nothing in the body anchors it) is absent from
    /// this map; `parseComments` assigns it a trailing number, continuing the sequence.
    fn number_comment_references(body: &XMLNode) -> std::collections::HashMap<String, i32> {
        let mut number_by_id: std::collections::HashMap<String, i32> = std::collections::HashMap::new();
        let mut next = 1;
        fn walk(node: &XMLNode, number_by_id: &mut std::collections::HashMap<String, i32>, next: &mut i32) {
            for child in node.children.iter() {
                if child.name == "w:commentRangeStart" {
                    if let Some(id) = child.attributes.get("w:id") {
                        if !number_by_id.contains_key(id) {
                            number_by_id.insert(id.clone(), *next);
                            *next += 1;
                        }
                    }
                }
                walk(child, number_by_id, next);
            }
        }
        walk(body, &mut number_by_id, &mut next);
        number_by_id
    }

    // swift: Render/Office/DocxReader.swift:291-324
    /// `word/comments.xml` — a flat `w:comments/w:comment` list, each `@w:id`/`@w:author`/`@w:date`
    /// plus the comment's own `w:p` paragraphs as its text. Absent entirely (no document part) is
    /// not an error — most documents have no comments — and yields no `OfficeComment`s. `numberById`
    /// is the SAME body first-pass `read()` already computed (`numberCommentReferences`), so a
    /// comment actually anchored in the body gets the number matching its anchor; one that ISN'T
    /// (present in `comments.xml` with no matching `w:commentRangeStart`/`w:commentReference` in the
    /// body) still lists, numbered by continuing the sequence in comments.xml's own file order — it
    /// anchors nothing, but the author's comment text is never silently dropped. The final array is
    /// sorted by `number` so callers see comments in the same order a sidebar would.
    fn parse_comments(
        archive: &ZipArchive, number_by_id: &std::collections::HashMap<String, i32>,
    ) -> Vec<OfficeComment> {
        if !archive.contains("word/comments.xml") {
            return vec![];
        }
        let Ok(data) = archive.data_for("word/comments.xml") else { return vec![] };
        let Ok(root) = Self::build_tree(&data.0) else { return vec![] };
        let mut result: Vec<OfficeComment> = Vec::new();
        let mut next_trailing_number = number_by_id.values().copied().max().unwrap_or(0) + 1;
        for node in root.children.iter().filter(|n| n.name == "w:comment") {
            let Some(id) = node.attributes.get("w:id").cloned() else { continue };
            let author = node.attributes.get("w:author").cloned();
            let date_iso = node.attributes.get("w:date").cloned();
            let text = node
                .children
                .iter()
                .filter(|c| c.name == "w:p")
                .map(Self::paragraph_plain_text)
                .collect::<Vec<_>>()
                .join("\n");
            let number = if let Some(anchored) = number_by_id.get(&id) {
                *anchored
            } else {
                let n = next_trailing_number;
                next_trailing_number += 1;
                n
            };
            result.push(OfficeComment {
                id: id.into(),
                author: author.map(Into::into),
                date_iso: date_iso.map(Into::into),
                text: text.into(),
                number: number as i64,
            });
        }
        result.sort_by_key(|c| c.number);
        result
    }

    // swift: Render/Office/DocxReader.swift:326-344
    /// A comment's own paragraph, flattened to plain text (no run formatting — `OfficeComment.text`
    /// carries no `Span`s of its own, unlike a document paragraph) — every `w:t` under this node,
    /// concatenated, with `w:br`/`w:tab` turned into `\n`/`\t` exactly like `buildSpan`'s own text
    /// assembly, so a multi-run or wrapped comment reads the same as the author typed it.
    fn paragraph_plain_text(p: &XMLNode) -> String {
        let mut text = String::new();
        fn walk(node: &XMLNode, text: &mut String) {
            for child in node.children.iter() {
                match child.name.as_str() {
                    "w:t" => text.push_str(&child.text),
                    "w:br" => text.push('\n'),
                    "w:tab" => text.push('\t'),
                    _ => walk(child, text),
                }
            }
        }
        walk(p, &mut text);
        text
    }
}

// swift: Render/Office/DocxReader.swift:346-346
// MARK: Footnotes / endnotes

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:348-369
    /// `word/footnotes.xml` (and the identically-shaped `word/endnotes.xml`) is a flat list of
    /// `w:footnote`/`w:endnote` elements keyed by `w:id`, each holding ordinary `w:p` paragraphs —
    /// the note's actual author-written text. Two ids are reserved and carry NO real content:
    /// `w:type="separator"` and `w:type="continuationSeparator"` are the little horizontal rule
    /// Word draws above notes on a page (and its continuation), present in essentially every real
    /// `.docx` whether or not the document has a single real footnote. Filtering by `w:type` (not
    /// by id, e.g. "ids ≤ 0 are boilerplate") is the only reliable signal — a document's real notes
    /// happen to start at id 1 in practice, but nothing in the spec guarantees that, while the type
    /// attribute is exactly what Word itself uses to tell them apart. A note with no `w:type` at all
    /// is real content, never boilerplate.
    fn parse_note_bodies(
        archive: &ZipArchive, part: &str, note_element_name: &str,
    ) -> std::collections::HashMap<String, XMLNode> {
        if !archive.contains(part) {
            return std::collections::HashMap::new();
        }
        let Ok(data) = archive.data_for(part) else { return std::collections::HashMap::new() };
        let Ok(root) = Self::build_tree(&data.0) else { return std::collections::HashMap::new() };
        let mut map: std::collections::HashMap<String, XMLNode> = std::collections::HashMap::new();
        for note in root.children.iter().filter(|n| n.name == note_element_name) {
            let Some(id) = note.attributes.get("w:id").cloned() else { continue };
            let kind = note.attributes.get("w:type");
            if kind.map(|k| k.as_str()) == Some("separator") || kind.map(|k| k.as_str()) == Some("continuationSeparator") {
                continue;
            }
            map.insert(id, note.clone());
        }
        map
    }
}

// swift: Render/Office/DocxReader.swift:371-371
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NoteKind {
    Footnote,
    Endnote,
}

/// Number → the marker rendered at both the citation point and the note body it points to.
/// Separate maps because footnotes and endnotes are separate numbering sequences in Word (both
/// commonly start at 1) — collapsing them into one counter would make a document's second
/// footnote and its first endnote fight over "2".
// swift: Render/Office/DocxReader.swift:377-380
#[derive(Debug, Clone, Default)]
pub struct NoteNumbering {
    pub(crate) footnote: std::collections::HashMap<String, i32>,
    pub(crate) endnote: std::collections::HashMap<String, i32>,
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:382-417
    /// One recursive walk of the ENTIRE body — not two separate searches — so the two kinds of
    /// reference come back in one true document order regardless of how they're nested (inside a
    /// table cell, a text box, a grouped drawing, an `w:sdt` wrapper …); interleaving them correctly
    /// only matters for `citationOrder` (what gets appended at the end, and in what sequence), since
    /// footnotes and endnotes are numbered independently of each other. A repeated reference to the
    /// SAME id (unusual, but not forbidden) reuses the number already assigned instead of adding a
    /// second entry to `citationOrder` — the note body is only appended once.
    fn number_note_references(
        body: &XMLNode,
    ) -> (std::collections::HashMap<String, i32>, std::collections::HashMap<String, i32>, Vec<(NoteKind, String, i32)>) {
        let mut footnote_number_by_id: std::collections::HashMap<String, i32> = std::collections::HashMap::new();
        let mut endnote_number_by_id: std::collections::HashMap<String, i32> = std::collections::HashMap::new();
        let mut citation_order: Vec<(NoteKind, String, i32)> = Vec::new();
        // Deliberately NOT a `switch`-with-`default: continue` — a footnote/endnote reference is
        // nested INSIDE a run (`w:r`), which is nested inside a paragraph, which may itself be
        // nested inside a table cell, a text box, an `w:sdt` wrapper, … `continue`-ing out of a
        // switch's default case would skip recursing into every one of those non-matching wrappers,
        // silently missing every reference not sitting at the top level. Every node is walked
        // unconditionally; matching is a plain check alongside that walk, not a branch that gates it.
        fn walk(
            node: &XMLNode,
            footnote_number_by_id: &mut std::collections::HashMap<String, i32>,
            endnote_number_by_id: &mut std::collections::HashMap<String, i32>,
            citation_order: &mut Vec<(NoteKind, String, i32)>,
        ) {
            for child in node.children.iter() {
                if child.name == "w:footnoteReference" {
                    if let Some(id) = child.attributes.get("w:id") {
                        if !footnote_number_by_id.contains_key(id) {
                            let number = footnote_number_by_id.len() as i32 + 1;
                            footnote_number_by_id.insert(id.clone(), number);
                            citation_order.push((NoteKind::Footnote, id.clone(), number));
                        }
                    }
                } else if child.name == "w:endnoteReference" {
                    if let Some(id) = child.attributes.get("w:id") {
                        if !endnote_number_by_id.contains_key(id) {
                            let number = endnote_number_by_id.len() as i32 + 1;
                            endnote_number_by_id.insert(id.clone(), number);
                            citation_order.push((NoteKind::Endnote, id.clone(), number));
                        }
                    }
                }
                walk(child, footnote_number_by_id, endnote_number_by_id, citation_order);
            }
        }
        walk(body, &mut footnote_number_by_id, &mut endnote_number_by_id, &mut citation_order);
        (footnote_number_by_id, endnote_number_by_id, citation_order)
    }

    // swift: Render/Office/DocxReader.swift:419-453
    /// Turns each cited note into ordinary blocks, appended in citation order at document's end —
    /// never inlined at the reference point (see the sprint brief: Word keeps them visually
    /// separated). Reuses `parseBodyChild` for the note's own paragraphs/tables, exactly the same
    /// walk the document body itself gets, rather than a second flattener. A note whose id doesn't
    /// resolve to any real part (a malformed/edited document) contributes nothing — its marker still
    /// appears at the citation point, honestly showing "something was cited here", but there is no
    /// text to fabricate for it.
    fn collect_note_blocks(
        citation_order: &[(NoteKind, String, i32)],
        footnote_bodies: &std::collections::HashMap<String, XMLNode>,
        endnote_bodies: &std::collections::HashMap<String, XMLNode>,
        style_info: &StyleInfo, numbering: &NumberingInfo, relationships: &Relationships,
        notes: &NoteNumbering, comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
    ) -> Vec<OfficeBlock> {
        citation_order
            .iter()
            .flat_map(|entry| {
                let (kind, id, number) = entry;
                let note_element = match kind {
                    NoteKind::Footnote => footnote_bodies.get(id),
                    NoteKind::Endnote => endnote_bodies.get(id),
                };
                let Some(note_element) = note_element else { return vec![] };
                let mut blocks: Vec<OfficeBlock> = note_element
                    .children
                    .iter()
                    .flat_map(|c| {
                        Self::parse_body_child(
                            c, style_info, numbering, relationships, notes, comments, list_state,
                        )
                    })
                    .collect();
                // Never fabricated — this is the SAME marker text emitted at the citation point
                // (`collectSpans`'s `w:footnoteReference`/`w:endnoteReference` case), so a reader can
                // visually match a note back to where it was cited.
                let marker = Span { text: format!("{}", number).into(), superscript: true, ..Default::default() };
                if let Some(first) = blocks.first().cloned() {
                    if let Some(marked_first) = Self::prepending_marker(marker.clone(), first) {
                        blocks[0] = marked_first;
                    } else {
                        // Empty note body, or one that opens with a table/image — neither has anywhere to
                        // splice a span into, so the marker becomes its own small leading paragraph instead
                        // of being silently dropped.
                        blocks.insert(0, OfficeBlock::Paragraph { spans: vec![marker], rtl: false, alignment: None, tab_stops: vec![], format: ParagraphFormat::default() });
                    }
                } else {
                    blocks.insert(0, OfficeBlock::Paragraph { spans: vec![marker], rtl: false, alignment: None, tab_stops: vec![], format: ParagraphFormat::default() });
                }
                blocks
            })
            .collect()
    }

    // swift: Render/Office/DocxReader.swift:455-468
    /// `nil` for `.table`/`.image` — there is no `[Span]` inside either to prepend into — so the
    /// caller falls back to a standalone marker paragraph instead.
    fn prepending_marker(marker: Span, block: OfficeBlock) -> Option<OfficeBlock> {
        match block {
            OfficeBlock::Paragraph { spans, rtl, alignment, tab_stops, format } => {
                let mut new_spans = vec![marker];
                new_spans.extend(spans);
                Some(OfficeBlock::Paragraph { spans: new_spans, rtl, alignment, tab_stops, format })
            }
            OfficeBlock::Heading { level, spans, rtl, alignment, tab_stops, format } => {
                let mut new_spans = vec![marker];
                new_spans.extend(spans);
                Some(OfficeBlock::Heading { level, spans: new_spans, rtl, alignment, tab_stops, format })
            }
            OfficeBlock::ListItem { level, ordered, spans, marker: item_marker, rtl, alignment, tab_stops, format, numbering } => {
                let mut new_spans = vec![marker];
                new_spans.extend(spans);
                Some(OfficeBlock::ListItem {
                    level, ordered, spans: new_spans, marker: item_marker, rtl, alignment, tab_stops,
                    format, numbering,
                })
            }
            OfficeBlock::Table { .. }
            | OfficeBlock::Image { .. }
            | OfficeBlock::UnsupportedGraphic { .. }
            | OfficeBlock::Formula { .. } => None,
        }
    }
}

// swift: Render/Office/DocxReader.swift:470-470
// MARK: styles.xml — styleId → outlineLvl (+ basedOn chain)

/// A style's NAME is not a safe signal — a localized Word install renames "Heading1" to
/// something like 제목 1, but a style's ID is NOT localized: a Korean, Japanese or German Word
/// install still writes `w:styleId="Heading2"` even though the NAME it shows the user differs.
/// That is what makes mechanism (b) below safe to use — matching the id, never the name.
/// A style's own run formatting — `w:rPr` on a `w:style`, resolved to the SAME literal shape
/// `Span` itself carries (colour already resolved against the theme, size already in points),
/// so `resolvedColor`/`resolvedFontSize`/… never have to re-resolve anything once they find an
/// entry here. `nil` per field means that field, specifically, wasn't set at this style — the
/// caller's chain walk keeps climbing `basedOn` for THAT field alone, not the whole struct.
///
/// `w:rFonts` is deliberately NOT one of these fields. Its four slots each cascade on their own
/// (`resolvedRFonts`), so collapsing them into a single `fontName?` here would have exactly the
/// effect this per-script work exists to undo: it would stop the walk at the first ancestor that
/// mentioned ANY slot and lose the East Asian family declared further up.
// swift: Render/Office/DocxReader.swift:486-497
#[derive(Debug, Clone, Default)]
struct RunStyleProps {
    color: Option<NSColor>,
    highlight: Option<NSColor>,
    font_size: Option<CGFloat>,
    /// `w:b` / `w:i` as the STYLE states them — three-state on purpose. `nil` = this level said
    /// nothing, so the walk keeps climbing; `false` = this level explicitly turned it OFF
    /// (`<w:b w:val="0"/>`), which must STOP the walk rather than fall through to a bold
    /// ancestor. Collapsing the two would make a deliberately un-bolded run inherit its parent
    /// style's bold — the same "silent ≠ off" mistake invariant 47 records for table borders.
    bold: Option<bool>,
    italic: Option<bool>,
}

/// A style's own paragraph formatting relevant to this sprint — `w:jc`/`w:tabs` off a
/// `w:style`'s `w:pPr`. `tabStops == nil` means this style declared none (keep climbing);
/// an EXPLICIT empty list never occurs from `parseTabStops` (see its own doc), so there is no
/// "explicitly no tabs" state to lose by using `nil` for both meanings.
///
/// The eight fields below (P2) are the SAME `w:pPr` reduced further, for the spacing/indent/
/// line-height/contextualSpacing cascade — each `nil` means "this level (docDefaults, one
/// style, or a paragraph's own direct `w:pPr`) didn't set that property", so the per-property
/// walk (`resolvedSpacingBefore` etc., and `resolvedParagraphFormat`'s docDefaults fallback)
/// keeps climbing for that one field alone, exactly like `alignment`/`tabStops` above.
/// `contextualSpacing` is `Bool?`, not `Bool`, for the same reason: a level that never mentions
/// `w:contextualSpacing` at all must be transparent to it (climb further), which a plain `Bool`
/// defaulting to `false` could never distinguish from an explicit `w:val="0"`.
// swift: Render/Office/DocxReader.swift:512-532
#[derive(Debug, Clone, Default)]
struct ParaStyleProps {
    alignment: Option<NSTextAlignment>,
    tab_stops: Option<Vec<TabStop>>,
    spacing_before: Option<CGFloat>,
    spacing_after: Option<CGFloat>,
    line_height: Option<LineHeight>,
    indent_start: Option<CGFloat>,
    indent_end: Option<CGFloat>,
    first_line_indent: Option<CGFloat>,
    hanging_indent: Option<CGFloat>,
    contextual_spacing: Option<bool>,
    /// P2b — `w:pPr/w:shd/@w:fill`, read exactly like `Cell`'s own shading (`cellShading`):
    /// `nil` means this level didn't set it (keep climbing); `"auto"`/absent is unshaded, same
    /// sentinel as the cell's.
    shading: Option<NSColor>,
    /// P2b — `w:pPr/w:pBdr`, read exactly like `Cell`'s own border (`cellBorder`): the first
    /// drawn edge's colour/width, checked top/left/bottom/right. Carried as ONE optional pair
    /// (not two independent optionals) because a resolved border is only meaningful with both —
    /// see `ParagraphFormat.borderColor`/`.borderWidth`'s own "mirrors Cell" doc.
    border: Option<(Option<NSColor>, Option<CGFloat>, RectEdge)>,
}

// swift: Render/Office/DocxReader.swift:534-611
#[derive(Debug, Clone, Default)]
pub struct StyleInfo {
    /// styleId → its OWN declared `w:outlineLvl`, only for styles that declare one at all
    /// (most custom styles, and many built-in `HeadingN` styles that instead rely on their id —
    /// see `builtInHeadingLevel`).
    outline_levels: std::collections::HashMap<String, i32>,
    /// styleId → the styleId it's `w:basedOn`, for styles that declare one.
    based_on: std::collections::HashMap<String, String>,
    /// styleId → its own `w:rPr`, only for styles that set at least one of the three fields.
    run_props: std::collections::HashMap<String, RunStyleProps>,
    /// styleId → its own `w:rPr/w:rFonts`, only for styles that declare at least one slot or a
    /// `w:hint`. Separate from `runProps` because each of the four slots climbs the `w:basedOn`
    /// chain independently — see `RunStyleProps`' own note.
    r_fonts: std::collections::HashMap<String, WordRFonts>,
    /// `w:docDefaults/w:rPrDefault/w:rPr/w:rFonts` — the floor of the font cascade, applied
    /// before any style per ISO/IEC 29500-1 §17.7.5.1 (*"These properties are applied first in
    /// the style hierarchy"*). Four of the six documents in this project's corpus declare one,
    /// and in the largest it is the document's ENTIRE base font expressed as four theme
    /// references, so a reader that skips this level reads nothing at all for most of its runs.
    doc_defaults_r_fonts: WordRFonts,
    /// The `w:style w:type="paragraph" w:default="1"` id — the style a paragraph that names none
    /// of its own inherits from. Present in five of six corpus documents and, until this work,
    /// never consulted: `walkStyleChain` returns immediately for a nil id, so every unstyled
    /// paragraph skipped the document's own Normal style entirely.
    ///
    /// Used ONLY by `resolvedRFonts`. Extending it to colour, size, spacing and indent would
    /// change what those cascade to in every document that declares a default style — a real
    /// improvement, and a separate invariant-37 event that has to be measured on its own rather
    /// than smuggled in beside a font change.
    default_paragraph_style_id: Option<String>,
    /// styleId → its own `w:pPr`'s `w:jc`/`w:tabs`/spacing/indent/line-height/contextualSpacing,
    /// only for styles that set at least one.
    para_props: std::collections::HashMap<String, ParaStyleProps>,
    /// `word/styles.xml`'s `w:docDefaults/w:pPrDefault/w:pPr` — the document's absolute floor
    /// for the P2 spacing/indent/line-height/contextualSpacing cascade (spec area 6, layer 1),
    /// mirroring `documentDefaultBodyFontSize`'s own read of `w:rPrDefault/w:rPr/w:sz` a few
    /// lines below. A document with no `styles.xml`, or one with no `w:docDefaults`/
    /// `w:pPrDefault`, leaves every field of this `nil` — `resolvedParagraphFormat`'s floor
    /// layer then simply contributes nothing, exactly like every other absent layer.
    doc_defaults_para_props: ParaStyleProps,
    /// The document's theme colour scheme (`word/theme/theme1.xml`), keyed by scheme slot name
    /// (`"dk1"`, `"accent1"`, …) — carried ON `StyleInfo` rather than threaded as its own
    /// parameter through every function that already takes `styleInfo`, since every one of
    /// those call sites needs it for exactly the same reason (resolving a run's `w:themeColor`)
    /// this struct's OWN `runProps` were already resolved against it. Empty when
    /// `word/theme/theme1.xml` is absent or malformed — every theme-colour lookup then simply
    /// misses, degrading to "no colour" (`resolvedColorElement`), never a crash.
    pub(crate) theme_colors: std::collections::HashMap<String, NSColor>,
    /// The document's theme FONT scheme (`word/theme/theme1.xml`'s `a:fontScheme`), carried here
    /// for the same reason `themeColors` is — every `w:asciiTheme`/`w:eastAsiaTheme` lookup, at
    /// any level of the cascade, needs it and every call site already holds a `StyleInfo`. Empty
    /// when the theme part is absent or malformed, which makes every theme reference resolve to
    /// `nil`, i.e. the reader's own body font — the same answer as a document that named no font.
    pub(crate) theme_fonts: WordThemeFonts,
    /// styleId → the TABLE style it declares (`w:style w:type="table"`) — P5's table-STYLE
    /// shading/border cascade (`w:tblStylePr` conditional formatting). Only styles that
    /// declare a whole-table default OR at least one conditional region are present; a
    /// `w:basedOn` on a table style is recorded in the SAME `basedOn` map above (that field
    /// is not itself type-scoped — see `parseStyles`'s unconditional read of it), so
    /// `walkStyleChain` climbs a table style's ancestry exactly like every other style kind.
    table_styles: std::collections::HashMap<String, TableStyle>,
    /// styleId → that TABLE style's own `w:tblPr/w:tblCellMar`, per edge. Kept OUTSIDE
    /// `tableStyles` on purpose: that map admits a style only when it declares shading or a
    /// border, and the style this exists for — Word's stock `Normal Table` — declares neither.
    /// It carries nothing but the cell margin, and dropping it is what made every table in a
    /// document that never wrote its own `w:tblCellMar` fall back to the reader's own 7pt on
    /// all four edges while the document had explicitly said `top=0 bottom=0`.
    pub(crate) table_cell_margins: std::collections::HashMap<String, EdgePadding>,
    /// `w:style w:type="table" w:default="1"` — the table style a table that names none of its
    /// own inherits from, the table-side twin of `defaultParagraphStyleId`. Word writes exactly
    /// one; a malformed document marking several keeps the first, matching that field's rule.
    pub(crate) default_table_style_id: Option<String>,
    /// styleId → its own `w:pPr/w:numPr` — see `WordNumPr`'s own doc for why this exists at
    /// all: a numbered HEADING style. Only styles that declare a `w:numPr` are present;
    /// resolved through the SAME `w:basedOn` chain as every other per-style property here
    /// (`resolvedNumPr`), so a style silent about numbering is transparent to it, exactly like
    /// `runProps`/`paraProps`/`rFonts` are silent about whatever THEY don't set.
    style_numbering: std::collections::HashMap<String, WordNumPr>,
}

/// One resolved layer of a table style's conditional formatting — either the style's own
/// whole-table default (`w:tblPr`/`w:tcPr` directly on the `w:style`) or one `w:tblStylePr`
/// region block's shading/border. `nil` fields mean this level didn't say — the SAME
/// transparent-cascade reading every other style-chain resolver in this reader uses.
// swift: Render/Office/DocxReader.swift:617-621
#[derive(Debug, Clone, Default)]
struct TableConditionalStyle {
    shading: Option<NSColor>,
    border_color: Option<NSColor>,
    border_width: Option<CGFloat>,
}

/// One `w:style w:type="table"` — a whole-table default plus a region→conditional map keyed
/// by `w:tblStylePr`'s own `@w:type` (`"firstRow"`, `"lastRow"`, `"firstCol"`, `"lastCol"`,
/// `"band1Horz"`/`"band2Horz"`, `"band1Vert"`/`"band2Vert"`, the four corner cells). See
/// `resolveCellTableStyle` for how a cell's grid position picks which of these apply and in
/// what precedence.
// swift: Render/Office/DocxReader.swift:628-631
#[derive(Debug, Clone, Default)]
struct TableStyle {
    whole_table: TableConditionalStyle,
    regions: std::collections::HashMap<String, TableConditionalStyle>,
}

/// A table's `w:tblPr/w:tblLook` — which of the named style's conditional regions are ACTIVE
/// for this particular table (ECMA-376 §17.4.63/§17.4.64). Two authoring forms exist and this
/// reads either: modern Word emits explicit `w:firstRow`/`w:lastRow`/`w:firstColumn`/
/// `w:lastColumn`/`w:noHBand`/`w:noVBand` boolean attributes; older documents instead carry
/// only a hex `@w:val` bitmask (`0x0020` firstRow, `0x0040` lastRow, `0x0080` firstColumn,
/// `0x0100` lastColumn, `0x0200` noHBand, `0x0400` noVBand) — see `parseTblLook`.
// swift: Render/Office/DocxReader.swift:639-646
#[derive(Debug, Clone, Default)]
struct TblLook {
    first_row: bool,
    last_row: bool,
    first_column: bool,
    last_column: bool,
    no_h_band: bool,
    no_v_band: bool,
}

/// One style's own `w:pPr/w:numPr` — the mechanism a numbered HEADING STYLE attaches its clause
/// numbering through. Word writes `w:numPr` on the `HeadingN` style DEFINITION itself, not on
/// every paragraph that uses it (the same "declared once, on the style" shape `w:outlineLvl`'s
/// mechanism (b) already relies on for the level itself) — so a heading paragraph naming only
/// `w:pStyle` needs this resolved through the `w:basedOn` chain to find its numbering at all
/// (`resolvedNumPr`). `ilvl` is `Int?`, not a defaulted `Int`, for the same reason every other
/// per-style optional here is: a style that names `w:numId` but omits `w:ilvl` still means
/// something (level 0), and `resolvedNumPr` is where that default is actually applied, not here.
// swift: Render/Office/DocxReader.swift:656-659
#[derive(Debug, Clone, Default)]
struct WordNumPr {
    num_id: Option<String>,
    ilvl: Option<i32>,
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:661-749
    /// Reads every per-style signal this reader now resolves through the `w:basedOn` chain:
    /// `resolvedOutlineLevel`'s pair (`w:outlineLvl`, `w:basedOn`), plus this sprint's own run
    /// (`RunStyleProps`) and paragraph (`ParaStyleProps`) formatting. `themeColors` is resolved
    /// ONCE by the caller (`read`) and passed in so a style's own `w:color/@w:themeColor` resolves
    /// to the same literal every direct-run lookup does. A style declaring none of these is simply
    /// absent from every map — `resolvedOutlineLevel`'s existing "not a heading" reading, and the
    /// new resolvers' "keep climbing" reading, both already treat absence that way.
    fn parse_styles(
        archive: &ZipArchive, theme_colors: &std::collections::HashMap<String, NSColor>,
        theme_fonts: &WordThemeFonts,
    ) -> StyleInfo {
        // `themeColors` must survive even when `word/styles.xml` itself is absent — a direct RUN
        // can carry a `w:themeColor` with no style involved at all, and that lookup goes through
        // THIS `StyleInfo`'s `themeColors` field (see `buildSpan`). An early `StyleInfo()` here,
        // discarding the parameter, was a real bug this sprint caught: it silently dropped every
        // theme colour in any document with no styles part. `themeFonts` is assigned in the same
        // breath and for the identical reason — a direct run's `w:rFonts/@w:asciiTheme` resolves
        // through this field with no style involved either, so repeating that early-return bug for
        // fonts was one guard away.
        let mut info = StyleInfo::default();
        info.theme_colors = theme_colors.clone();
        info.theme_fonts = theme_fonts.clone();
        if !archive.contains("word/styles.xml") {
            return info;
        }
        let Ok(data) = archive.data_for("word/styles.xml") else { return info };
        let Ok(root) = Self::build_tree(&data.0) else { return info };
        info.doc_defaults_para_props = Self::parse_para_style_props(
            root.child("w:docDefaults").and_then(|n| n.child("w:pPrDefault")).and_then(|n| n.child("w:pPr")),
        );
        info.doc_defaults_r_fonts = Self::parse_r_fonts(
            root.child("w:docDefaults").and_then(|n| n.child("w:rPrDefault")).and_then(|n| n.child("w:rPr")),
        );
        for style in root.children.iter().filter(|s| s.name == "w:style") {
            let Some(id) = style.attributes.get("w:styleId").cloned() else { continue };
            // Word marks exactly one paragraph style `w:default="1"`; if a malformed document marks
            // several, the FIRST wins, matching every other "first one that answers" rule here.
            if style.attributes.get("w:type").map(String::as_str) == Some("paragraph")
                && style.attributes.get("w:default").map(String::as_str) == Some("1")
                && info.default_paragraph_style_id.is_none()
            {
                info.default_paragraph_style_id = Some(id.clone());
            }
            if let Some(val) = style.child("w:pPr").and_then(|n| n.child("w:outlineLvl")).and_then(|n| n.attributes.get("w:val").cloned()) {
                if let Ok(level) = val.parse::<i32>() {
                    info.outline_levels.insert(id.clone(), level);
                }
            }
            if let Some(parent) = style.child("w:basedOn").and_then(|n| n.attributes.get("w:val").cloned()) {
                info.based_on.insert(id.clone(), parent);
            }
            let run_props = Self::parse_run_style_props(style.child("w:rPr"), theme_colors);
            if run_props.color.is_some() || run_props.highlight.is_some() || run_props.font_size.is_some()
                || run_props.bold.is_some() || run_props.italic.is_some()
            {
                info.run_props.insert(id.clone(), run_props);
            }
            let r_fonts = Self::parse_r_fonts(style.child("w:rPr"));
            if !r_fonts.is_empty() {
                info.r_fonts.insert(id.clone(), r_fonts);
            }
            let para_props = Self::parse_para_style_props(style.child("w:pPr"));
            if para_props.alignment.is_some() || para_props.tab_stops.is_some() || para_props.spacing_before.is_some()
                || para_props.spacing_after.is_some() || para_props.line_height.is_some() || para_props.indent_start.is_some()
                || para_props.indent_end.is_some() || para_props.first_line_indent.is_some() || para_props.hanging_indent.is_some()
                || para_props.contextual_spacing.is_some() || para_props.shading.is_some() || para_props.border.is_some()
            {
                info.para_props.insert(id.clone(), para_props);
            }
            // A numbered HEADING style's `w:numPr` — see `WordNumPr`'s own doc. Kept OUTSIDE
            // `ParaStyleProps` deliberately: that struct feeds `resolvedParagraphFormat`'s P2
            // cascade, which invariant 37 requires to stay byte-identical for a document that sets
            // none of ITS fields, and numbering is a wholly separate concern from spacing/indent.
            if let Some(num_pr) = style.child("w:pPr").and_then(|n| n.child("w:numPr")) {
                let num_id = num_pr.child("w:numId").and_then(|n| n.attributes.get("w:val").cloned());
                let ilvl = num_pr.child("w:ilvl").and_then(|n| n.attributes.get("w:val").cloned()).and_then(|v| v.parse().ok());
                if num_id.is_some() || ilvl.is_some() {
                    info.style_numbering.insert(id.clone(), WordNumPr { num_id, ilvl });
                }
            }
            if style.attributes.get("w:type").map(String::as_str) == Some("table") {
                if style.attributes.get("w:default").map(String::as_str) == Some("1") && info.default_table_style_id.is_none() {
                    info.default_table_style_id = Some(id.clone());
                }
                if let Some(margins) = Self::cell_edge_padding(
                    style.child("w:tblPr").and_then(|n| n.child("w:tblCellMar")),
                ) {
                    info.table_cell_margins.insert(id.clone(), margins);
                }
                let mut table_style = TableStyle::default();
                table_style.whole_table = Self::parse_table_conditional_style(style);
                for pr in style.children.iter().filter(|p| p.name == "w:tblStylePr") {
                    let Some(region) = pr.attributes.get("w:type").cloned() else { continue };
                    let cond = Self::parse_table_conditional_style(pr);
                    if cond.shading.is_some() || cond.border_color.is_some() || cond.border_width.is_some() {
                        table_style.regions.insert(region, cond);
                    }
                }
                let wt = &table_style.whole_table;
                if wt.shading.is_some() || wt.border_color.is_some() || wt.border_width.is_some() || !table_style.regions.is_empty() {
                    info.table_styles.insert(id.clone(), table_style);
                }
            }
        }
        info
    }

    // swift: Render/Office/DocxReader.swift:751-777
    /// One level of a table style's conditional formatting — either the `w:style` element itself
    /// (its own whole-table `w:tblPr`/`w:tcPr`) or one of its `w:tblStylePr` children (a region's
    /// `w:tcPr`/`w:tblPr`). Shading and border are each read cell-level (`w:tcPr/w:shd`,
    /// `w:tcPr/w:tcBorders`) FIRST, falling to the rarer table-level spelling
    /// (`w:tblPr/w:shd`/`w:tblPr/w:tblBorders`) only when the cell-level one is entirely absent —
    /// mirroring `cellShading`/`cellBorder`'s own "auto"/absent-edge sentinel reading via
    /// `colorFromHex`/`resolveBorder`, reused here rather than re-implemented.
    fn parse_table_conditional_style(node: &XMLNode) -> TableConditionalStyle {
        let mut result = TableConditionalStyle::default();
        let tc_pr = node.child("w:tcPr");
        let tbl_pr = node.child("w:tblPr");
        if let Some(fill) = tc_pr.as_ref().and_then(|n| n.child("w:shd")).and_then(|n| n.attributes.get("w:fill").cloned()) {
            if fill.to_lowercase() != "auto" {
                result.shading = Self::color_from_hex(&fill);
            }
        } else if let Some(fill) = tbl_pr.as_ref().and_then(|n| n.child("w:shd")).and_then(|n| n.attributes.get("w:fill").cloned()) {
            if fill.to_lowercase() != "auto" {
                result.shading = Self::color_from_hex(&fill);
            }
        }
        let cell_border = Self::resolve_border(tc_pr.as_ref().and_then(|n| n.child("w:tcBorders")));
        if cell_border.0.is_some() || cell_border.1.is_some() {
            result.border_color = cell_border.0;
            result.border_width = cell_border.1;
        } else {
            let table_border = Self::resolve_border(tbl_pr.as_ref().and_then(|n| n.child("w:tblBorders")));
            result.border_color = table_border.0;
            result.border_width = table_border.1;
        }
        result
    }

    // swift: Render/Office/DocxReader.swift:779-807
    /// `w:tblPr/w:tblLook` — see `TblLook`'s own doc for the two authoring forms. The attribute
    /// form wins whenever ANY of the six boolean attributes is present (a document that authors
    /// even one of them is using the modern form; a missing attribute among those six then means
    /// an explicit `false`, not "fall to the hex bitmask"). Only when NONE of the six attributes
    /// is present does the hex `@w:val` bitmask apply. No `w:tblLook` at all — most hand-authored
    /// or older documents — leaves every flag `false`, meaning no conditional region of the named
    /// style is active and a cell's resolved style format collapses to the whole-table default
    /// alone (see `resolveCellTableStyle`).
    #[allow(dead_code)]
    pub(crate) fn parse_tbl_look(tbl_pr: Option<&XMLNode>) -> TblLook {
        let mut look = TblLook::default();
        let Some(node) = tbl_pr.and_then(|n| n.child("w:tblLook")) else { return look };
        let attr_keys = ["w:firstRow", "w:lastRow", "w:firstColumn", "w:lastColumn", "w:noHBand", "w:noVBand"];
        if attr_keys.iter().any(|k| node.attributes.get(*k).is_some()) {
            look.first_row = Self::tbl_look_flag(&node, "w:firstRow");
            look.last_row = Self::tbl_look_flag(&node, "w:lastRow");
            look.first_column = Self::tbl_look_flag(&node, "w:firstColumn");
            look.last_column = Self::tbl_look_flag(&node, "w:lastColumn");
            look.no_h_band = Self::tbl_look_flag(&node, "w:noHBand");
            look.no_v_band = Self::tbl_look_flag(&node, "w:noVBand");
        } else if let Some(hex) = node.attributes.get("w:val") {
            if let Ok(bits) = u16::from_str_radix(hex, 16) {
                look.first_row = bits & 0x0020 != 0;
                look.last_row = bits & 0x0040 != 0;
                look.first_column = bits & 0x0080 != 0;
                look.last_column = bits & 0x0100 != 0;
                look.no_h_band = bits & 0x0200 != 0;
                look.no_v_band = bits & 0x0400 != 0;
            }
        }
        look
    }

    // swift: Render/Office/DocxReader.swift:809-812
    #[allow(dead_code)]
    fn tbl_look_flag(node: &XMLNode, key: &str) -> bool {
        let Some(val) = node.attributes.get(key) else { return false };
        val != "0" && val.to_lowercase() != "false"
    }
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:814-837
    /// Resolves ONE region's (or the whole-table default's, when `region` is `nil`) conditional
    /// style by climbing `styleId`'s `w:basedOn` chain (`walkStyleChain` — the same cycle-guarded
    /// walk every other per-property resolver in this reader shares) until a style in the chain
    /// declares SOMETHING for that region. A style with no `tableStyles` entry at all (an
    /// empty style that exists only to declare `w:basedOn`) is transparent — the walk keeps
    /// climbing past it rather than stopping — but the granularity beyond that is per REGION,
    /// not per individual field within one: a style that sets ONLY that region's shading (leaving
    /// its border unset) still wins outright over an ancestor that set the region's border, rather
    /// than the two merging field-by-field. Mirrors `Cell.borderColor`'s own documented
    /// simplification (one uniform value, not a four-edge model) — a real per-field cascade WITHIN
    /// one region is out of this sprint's scope; `resolveCellTableStyle`'s own layering (below) is
    /// what still gives per-field precedence ACROSS different regions on the same cell.
    #[allow(dead_code)]
    fn resolved_table_conditional(
        region: Option<&str>, style_id: &str, style_info: &StyleInfo,
    ) -> Option<TableConditionalStyle> {
        Self::walk_style_chain(Some(style_id.to_string()), style_info, |id| {
            let table_style = style_info.table_styles.get(id)?;
            match region {
                None => {
                    let wt = &table_style.whole_table;
                    if wt.shading.is_some() || wt.border_color.is_some() || wt.border_width.is_some() {
                        Some(wt.clone())
                    } else {
                        None
                    }
                }
                Some(region) => table_style.regions.get(region).cloned(),
            }
        })
    }

    // swift: Render/Office/DocxReader.swift:839-889
    /// Resolves a single cell's table-STYLE shading/border (P5) — the layer `Cell.styleShading`/
    /// `.styleBorderColor`/`.styleBorderWidth` carry — from the table's named style
    /// (`w:tblPr/w:tblStyle`) and this cell's position in the grid. Layers every APPLICABLE
    /// conditional region onto the whole-table default, LOW to HIGH precedence, overriding
    /// per-FIELD (not as a whole-object swap) so a region that only sets shading, say, still
    /// leaves a higher layer's untouched border in place from whatever set it: `wholeTable` <
    /// vertical banding < horizontal banding < `firstCol`/`lastCol` < `firstRow`/`lastRow` <
    /// the four corner cells — the corners winning over everything else because a document that
    /// bothers to style them (`nwCell` etc.) is deliberately calling out that ONE cell.
    ///
    /// Banding counts BODY rows/columns — rows after `headerRows` (the table's OWN declared
    /// header rows, `w:tblHeader`, independent of `look.firstRow`) and columns after column 0
    /// when `look.firstColumn` is active — so band 1 is always the first body row/column, band 2
    /// the second, alternating from there; `look.noHBand`/`.noVBand` disables the corresponding
    /// axis entirely rather than just skipping the alternation.
    #[allow(dead_code, clippy::too_many_arguments)]
    pub(crate) fn resolve_cell_table_style(
        style_id: &str, style_info: &StyleInfo, look: &TblLook, row: i32, col: i32, row_count: i32,
        col_count: i32, header_rows: i32,
    ) -> (Option<NSColor>, Option<NSColor>, Option<CGFloat>) {
        let mut order: Vec<Option<String>> = vec![None]; // whole-table default, lowest precedence
        let body_col_start = if look.first_column { 1 } else { 0 };
        if !look.no_v_band && col >= body_col_start {
            order.push(Some(if (col - body_col_start) % 2 == 0 { "band1Vert".to_string() } else { "band2Vert".to_string() }));
        }
        if !look.no_h_band && row >= header_rows {
            order.push(Some(if (row - header_rows) % 2 == 0 { "band1Horz".to_string() } else { "band2Horz".to_string() }));
        }
        let is_first_col = look.first_column && col == 0;
        let is_last_col = look.last_column && col_count > 1 && col == col_count - 1;
        let is_first_row = look.first_row && row == 0;
        let is_last_row = look.last_row && row_count > 1 && row == row_count - 1;
        if is_first_col { order.push(Some("firstCol".to_string())); }
        if is_last_col { order.push(Some("lastCol".to_string())); }
        if is_first_row { order.push(Some("firstRow".to_string())); }
        if is_last_row { order.push(Some("lastRow".to_string())); }
        if is_first_row && is_first_col { order.push(Some("nwCell".to_string())); }
        if is_first_row && is_last_col { order.push(Some("neCell".to_string())); }
        if is_last_row && is_first_col { order.push(Some("swCell".to_string())); }
        if is_last_row && is_last_col { order.push(Some("seCell".to_string())); }

        let mut shading: Option<NSColor> = None;
        let mut border_color: Option<NSColor> = None;
        let mut border_width: Option<CGFloat> = None;
        for region in order {
            let Some(cond) = Self::resolved_table_conditional(region.as_deref(), style_id, style_info) else { continue };
            if let Some(s) = cond.shading { shading = Some(s); }
            if let Some(bc) = cond.border_color { border_color = Some(bc); }
            if let Some(bw) = cond.border_width { border_width = Some(bw); }
        }
        (shading, border_color, border_width)
    }

    // swift: Render/Office/DocxReader.swift:891-907
    /// One style's (or one run's own) `w:rPr`, reduced to the four fields this sprint resolves —
    /// shared by `parseStyles` (a style's `w:rPr`) and `buildSpan` (a run's direct `w:rPr`), so a
    /// literal-colour hex, a themeColor reference, a half-point size and an `w:rFonts` choice are
    /// each read exactly once, the same way, regardless of which level of the chain they came from.
    fn parse_run_style_props(
        r_pr: Option<&XMLNode>, theme_colors: &std::collections::HashMap<String, NSColor>,
    ) -> RunStyleProps {
        let mut props = RunStyleProps::default();
        props.color = Self::resolved_color_element(r_pr.and_then(|n| n.child("w:color")), theme_colors);
        if let Some(val) = r_pr.and_then(|n| n.child("w:highlight")).and_then(|n| n.attributes.get("w:val").cloned()) {
            props.highlight = Self::highlight_color(&val);
        }
        if let Some(sz_val) = r_pr.and_then(|n| n.child("w:sz")).and_then(|n| n.attributes.get("w:val").cloned()) {
            if let Ok(half) = sz_val.parse::<f64>() {
                props.font_size = Some((half / 2.0) as CGFloat);
            }
        }
        props.bold = Self::toggle_state(r_pr, "w:b");
        props.italic = Self::toggle_state(r_pr, "w:i");
        props
    }

    // swift: Render/Office/DocxReader.swift:909-917
    /// An OOXML on/off toggle (§17.17.4 `ST_OnOff`) as THREE states: the element absent (`nil` — this
    /// level says nothing), present and on (`true`), present and explicitly off (`false`). `isOn` —
    /// which every direct-run read uses — collapses the last two, which is right for a run's own
    /// properties but wrong for a style CHAIN, where "off" has to stop the climb.
    pub(crate) fn toggle_state(r_pr: Option<&XMLNode>, name: &str) -> Option<bool> {
        let node = r_pr.and_then(|n| n.child(name))?;
        let Some(val) = node.attributes.get("w:val") else { return Some(true) }; // bare <w:b/> means on
        Some(!(val == "0" || val == "false" || val == "off"))
    }

    // swift: Render/Office/DocxReader.swift:919-952
    /// One level's `w:rPr/w:rFonts`, read into all four slots plus `w:hint`.
    ///
    /// Each slot accepts either a literal attribute (`w:ascii`) or a theme reference
    /// (`w:asciiTheme`), and within one element the theme reference WINS — MS-OI29500 §17.3.2.26
    /// note e: *"If the asciiTheme attribute is also specified, then this attribute shall be ignored
    /// and that value shall be used instead"*. That precedence is per-element only; ACROSS levels
    /// the two forms replace each other wholesale, which is why `WordFontDecl` is one cell.
    ///
    /// The complex-script theme attribute is `w:cstheme`, lowercase `t` — Word's own spelling, and
    /// the odd one out among the four. `w:csTheme` is accepted too so a producer that regularised
    /// the casing is not silently ignored; nothing else in the document can be spelled that way.
    ///
    /// An EMPTY attribute value is read as absent rather than as a family named "". Word does not
    /// write one, but a producer that does would otherwise set a slot to a name no font can match,
    /// and — worse — block the level below it from being consulted at all. That is the exact shape
    /// of the live ODT defect recorded in `docs/per-script-font-design.md` §5.2, which cost that
    /// format its inheritance; there is no reason to re-earn it here.
    pub(crate) fn parse_r_fonts(r_pr: Option<&XMLNode>) -> WordRFonts {
        let mut decl = WordRFonts::default();
        let Some(node) = r_pr.and_then(|n| n.child("w:rFonts")) else { return decl };
        let read = |literal: &str, theme_attributes: &[&str]| -> Option<WordFontDecl> {
            for name in theme_attributes {
                if let Some(reference) = node.attributes.get(*name) {
                    if !reference.is_empty() {
                        return Some(WordFontDecl::Theme(reference.clone()));
                    }
                }
            }
            if let Some(name) = node.attributes.get(literal) {
                if !name.is_empty() {
                    return Some(WordFontDecl::Literal(name.clone()));
                }
            }
            None
        };
        decl.ascii = read("w:ascii", &["w:asciiTheme"]);
        decl.h_ansi = read("w:hAnsi", &["w:hAnsiTheme"]);
        decl.east_asia = read("w:eastAsia", &["w:eastAsiaTheme"]);
        decl.cs = read("w:cs", &["w:cstheme", "w:csTheme"]);
        if let Some(hint) = node.attributes.get("w:hint") {
            if !hint.is_empty() {
                decl.hint = Some(hint.clone());
            }
        }
        decl
    }

    // swift: Render/Office/DocxReader.swift:954-1013
    /// One style's (or one paragraph's own, or `w:docDefaults/w:pPrDefault`'s) `w:pPr`, reduced to
    /// `w:jc`/`w:tabs` plus (P2) `w:spacing`'s before/after/line/lineRule, `w:ind`'s
    /// start-or-left/end-or-right/firstLine/hanging, and `w:contextualSpacing` — shared by
    /// `parseStyles` (a style's OWN `w:pPr`, and `w:docDefaults`' floor), and `resolvedParagraphFormat`'s
    /// direct-`pPr` read, the same way `parseRunStyleProps` is shared across levels of its own cascade.
    ///
    /// Twips (`ST_TwipsMeasure`/`ST_SignedTwipsMeasure`, 20ths of a point) → points is `÷20`
    /// throughout — spec area 5's `w:spacing`/`w:ind` table. `w:line`'s unit depends entirely on
    /// `@w:lineRule` (spec area 5's "load-bearing fact for readable body text"): `auto` (the
    /// default when `w:spacing` sets `@w:line` but omits `@w:lineRule`) is `line/240` as a
    /// MULTIPLE of the font's own single-spaced height, never a point value; `exact`/`atLeast` are
    /// both `line/20` points, differing only in whether the result is a hard cap or a floor.
    fn parse_para_style_props(p_pr: Option<&XMLNode>) -> ParaStyleProps {
        let mut props = ParaStyleProps::default();
        if let Some(val) = p_pr.and_then(|n| n.child("w:jc")).and_then(|n| n.attributes.get("w:val").cloned()) {
            props.alignment = Self::alignment_from_jc(&val);
        }
        if let Some(tabs_node) = p_pr.and_then(|n| n.child("w:tabs")) {
            let stops = Self::parse_tab_stops(&tabs_node);
            if !stops.is_empty() {
                props.tab_stops = Some(stops);
            }
        }
        if let Some(spacing) = p_pr.and_then(|n| n.child("w:spacing")) {
            if let Some(val) = spacing.attributes.get("w:before") {
                if let Ok(twips) = val.parse::<f64>() {
                    props.spacing_before = Some((twips / 20.0) as CGFloat);
                }
            }
            if let Some(val) = spacing.attributes.get("w:after") {
                if let Ok(twips) = val.parse::<f64>() {
                    props.spacing_after = Some((twips / 20.0) as CGFloat);
                }
            }
            if let Some(val) = spacing.attributes.get("w:line") {
                if let Ok(line) = val.parse::<f64>() {
                    props.line_height = Some(match spacing.attributes.get("w:lineRule").map(String::as_str) {
                        Some("exact") => LineHeight::Exact((line / 20.0) as CGFloat),
                        Some("atLeast") => LineHeight::AtLeast((line / 20.0) as CGFloat),
                        _ => LineHeight::Multiple((line / 240.0) as CGFloat), // absent or "auto"
                    });
                }
            }
        }
        if let Some(ind) = p_pr.and_then(|n| n.child("w:ind")) {
            if let Some(val) = ind.attributes.get("w:start").or_else(|| ind.attributes.get("w:left")) {
                if let Ok(twips) = val.parse::<f64>() {
                    props.indent_start = Some((twips / 20.0) as CGFloat);
                }
            }
            if let Some(val) = ind.attributes.get("w:end").or_else(|| ind.attributes.get("w:right")) {
                if let Ok(twips) = val.parse::<f64>() {
                    props.indent_end = Some((twips / 20.0) as CGFloat);
                }
            }
            if let Some(val) = ind.attributes.get("w:firstLine") {
                if let Ok(twips) = val.parse::<f64>() {
                    props.first_line_indent = Some((twips / 20.0) as CGFloat);
                }
            }
            if let Some(val) = ind.attributes.get("w:hanging") {
                if let Ok(twips) = val.parse::<f64>() {
                    props.hanging_indent = Some((twips / 20.0) as CGFloat);
                }
            }
        }
        props.contextual_spacing = Self::on_off_value(p_pr, "w:contextualSpacing");
        if let Some(shd) = p_pr.and_then(|n| n.child("w:shd")) {
            if let Some(fill) = shd.attributes.get("w:fill") {
                if fill.to_lowercase() != "auto" {
                    props.shading = Self::color_from_hex(fill);
                }
            }
        }
        if let Some(p_bdr) = p_pr.and_then(|n| n.child("w:pBdr")) {
            let border = Self::paragraph_border(&p_bdr);
            if !border.2.is_empty() {
                props.border = Some(border);
            }
        }
        props
    }

    // swift: Render/Office/DocxReader.swift:1015-1039
    /// `w:pPr/w:pBdr`'s edges, reduced to ONE colour/width (see `ParaStyleProps.border`'s doc) —
    /// structurally identical to `cellBorder`'s own `w:tcBorders` walk (each edge is `w:top`/
    /// `w:left`/`w:bottom`/`w:right`, `@w:val` present-and-not-`nil`/`none` means drawn, `@w:sz` is
    /// EIGHTHS of a point), duplicated rather than shared because the two live under different
    /// parent element names (`w:pBdr` also has `w:between`/`w:bar`, which a paragraph border never
    /// reduces to — this reader only reads the box edges a `Cell`'s single colour/width can express).
    fn paragraph_border(p_bdr: &XMLNode) -> (Option<NSColor>, Option<CGFloat>, RectEdge) {
        let mut found: Option<(Option<NSColor>, Option<CGFloat>)> = None;
        let mut edges = RectEdge::empty();
        // EVERY edge, not the first one that speaks. Word's own stock Title and Heading styles rule
        // the BOTTOM only, and returning at the first declared edge lost which one it was, so the
        // drawer boxed the paragraph on all four sides — a heading with a rule under it came out
        // inside a rectangle. The colour/width simplification stays (see `ParagraphFormat`), so the
        // first declared edge still supplies those; what is new is that the others are not drawn.
        for (name, edge) in [
            ("w:top", RectEdge::TOP), ("w:left", RectEdge::LEFT),
            ("w:bottom", RectEdge::BOTTOM), ("w:right", RectEdge::RIGHT),
        ] {
            let Some(e) = p_bdr.child(name) else { continue };
            let Some(val) = e.attributes.get("w:val") else { continue };
            if val == "nil" || val == "none" {
                continue;
            }
            edges |= edge;
            if found.is_none() {
                found = Some((
                    e.attributes.get("w:color").and_then(|c| if c.to_lowercase() == "auto" { None } else { Self::color_from_hex(c) }),
                    e.attributes.get("w:sz").and_then(|s| s.parse::<f64>().ok()).map(|s| (s / 8.0) as CGFloat),
                ));
            }
        }
        let Some(found) = found else { return (None, None, RectEdge::empty()) };
        (found.0, found.1, edges)
    }

    // swift: Render/Office/DocxReader.swift:1041-1051
    /// A `Bool?` sibling of `isOn` (below): `nil` when the tag is entirely absent — "this level has
    /// no opinion, keep climbing the cascade" — vs. an explicit `true`/`false` when it's present.
    /// `isOn` itself can't express that middle state (it collapses "absent" and "explicitly off" to
    /// the same `false`), which is fine for run toggles read at a single level (a run's OWN `w:rPr`)
    /// but wrong for `w:contextualSpacing`'s per-property cascade, where "this style didn't mention
    /// it" must be transparent rather than an implicit "off".
    fn on_off_value(p_pr: Option<&XMLNode>, tag: &str) -> Option<bool> {
        let element = p_pr.and_then(|n| n.child(tag))?;
        let Some(val) = element.attributes.get("w:val") else { return Some(true) };
        Some(val != "0" && val != "false")
    }

    // swift: Render/Office/DocxReader.swift:1053-1068
    /// `w:jc`'s values per ECMA-376 §17.18.44 (`ST_Jc`): `"both"`/`"distribute"` are Word's two
    /// justify-both-edges variants (this reader doesn't distinguish letter-spacing distribution
    /// from ordinary justification — `NSTextAlignment` has no third option), `"start"`/`"end"` are
    /// the writing-direction-relative synonyms for `"left"`/`"right"` newer Word versions also
    /// emit. Anything else (`"center"` aside, every value here) that ISN'T one of these seven is
    /// left unresolved (`nil`) — the paragraph then falls back to whatever `rtl`/the theme's own
    /// default decides, exactly as an absent `w:jc` already does.
    pub(crate) fn alignment_from_jc(val: &str) -> Option<NSTextAlignment> {
        match val {
            "left" | "start" => Some(NSTextAlignment::Left),
            "right" | "end" => Some(NSTextAlignment::Right),
            "center" => Some(NSTextAlignment::Center),
            "both" | "distribute" => Some(NSTextAlignment::Justified),
            _ => None,
        }
    }
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1070-1107
    /// `w:tabs`'s own `w:tab` children, each `w:pos` in TWIPS (Word's unit here, 20ths of a point —
    /// the SAME unit `w:tblW`/`w:tcW` use, see `cellWidth`) converted to points. A `w:val="clear"`
    /// entry REMOVES an inherited stop at that position rather than adding one of its own — this
    /// reader has no per-position merge against an ancestor's stops to remove FROM (an inherited
    /// list is taken or left whole, never spliced — see `ParaStyleProps`'s doc), so a `clear` entry
    /// is simply skipped rather than emitted as a phantom stop at that position. A `w:tab` missing
    /// `w:pos` entirely (malformed) is skipped the same way — there is no position to place it at.
    ///
    /// P2b — `@w:val` (spec §17.3.1.37, `ST_TabJc`) is read into `TabStop.alignment`: `"start"`/
    /// `"left"` (and every value not otherwise named here) → `.left`, `"center"` → `.center`,
    /// `"end"`/`"right"` → `.right`, `"decimal"` → `.decimal`. `"bar"` (a vertical rule, not a text
    /// stop at all) is skipped exactly like `"clear"` — neither has a place in this vocabulary.
    /// `@w:leader` is read into `TabStop.leader` (`"dot"`/`"hyphen"`/`"underscore"` → their cases,
    /// everything else, including absent, → `.none`) and carried through UNDRAWN this sprint — see
    /// `TabLeader`'s own doc.
    pub(crate) fn parse_tab_stops(tabs_node: &XMLNode) -> Vec<TabStop> {
        tabs_node
            .children
            .iter()
            .filter_map(|tab| {
                if tab.name != "w:tab" {
                    return None;
                }
                let val = tab.attributes.get("w:val").map(String::as_str);
                if val == Some("clear") || val == Some("bar") {
                    return None;
                }
                let pos_str = tab.attributes.get("w:pos")?;
                let pos: f64 = pos_str.parse().ok()?;
                let alignment = match val {
                    Some("center") => TabAlignment::Center,
                    Some("end") | Some("right") => TabAlignment::Right,
                    Some("decimal") => TabAlignment::Decimal,
                    _ => TabAlignment::Left, // "start"/"left"/anything else this reader doesn't special-case
                };
                let leader = match tab.attributes.get("w:leader").map(String::as_str) {
                    Some("dot") => TabLeader::Dot,
                    Some("hyphen") => TabLeader::Hyphen,
                    Some("underscore") => TabLeader::Underscore,
                    _ => TabLeader::None,
                };
                Some(TabStop { position: (pos / 20.0) as CGFloat, alignment, leader })
            })
            .collect()
    }

    // swift: Render/Office/DocxReader.swift:1109-1125
    /// Walks a style's `w:basedOn` chain (cycle-guarded exactly like `resolvedOutlineLevel`, whose
    /// walk this generalizes) trying `resolve` at each style in turn: the NEAREST style that has an
    /// answer wins, and a style with no answer for THIS property is transparent — the walk keeps
    /// climbing past it rather than stopping. This is what makes "direct run wins over style, style
    /// wins over its ancestors" hold per-PROPERTY, not per-style: a style can set `w:sz` and leave
    /// colour to ITS ancestor, and this walk still finds the ancestor's colour.
    pub(crate) fn walk_style_chain<T>(
        p_style_id: Option<String>, style_info: &StyleInfo, resolve: impl Fn(&str) -> Option<T>,
    ) -> Option<T> {
        let mut current_id = p_style_id?;
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        loop {
            if visited.contains(&current_id) {
                return None;
            }
            visited.insert(current_id.clone());
            if let Some(value) = resolve(&current_id) {
                return Some(value);
            }
            let Some(parent) = style_info.based_on.get(&current_id).cloned() else { return None };
            current_id = parent;
        }
    }

    // swift: Render/Office/DocxReader.swift:1127-1129
    #[allow(dead_code)]
    pub(crate) fn resolved_color(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<NSColor> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.run_props.get(id)?.color.clone())
    }

    // swift: Render/Office/DocxReader.swift:1131-1133
    #[allow(dead_code)]
    pub(crate) fn resolved_highlight(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<NSColor> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.run_props.get(id)?.highlight.clone())
    }

    // swift: Render/Office/DocxReader.swift:1135-1147
    /// `w:b` / `w:i` resolved through the `w:basedOn` chain, the same way `resolvedFontSize` resolves
    /// size. Measured on four real documents: a Word heading's bold lives in its STYLE, not in its
    /// runs — TeamBridge declares 39 headings with ZERO run-level `w:b` while its `heading 1/2/3`
    /// styles each carry `<w:b/>`, and the OpenAPI guide is 38 and 0. Reading only the run's direct
    /// `w:rPr` therefore reported every one of those headings as not bold, which was invisible for as
    /// long as the builder drew all headings semibold on its own — and would have un-bolded every one
    /// of them the moment that app-side default was removed.
    ///
    /// Returns `nil` when nothing in the chain mentions the toggle, so the caller can tell "the
    /// document never said" from "the document said off".
    #[allow(dead_code)]
    pub(crate) fn resolved_bold(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<bool> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.run_props.get(id)?.bold)
    }

    // swift: Render/Office/DocxReader.swift:1149-1151
    #[allow(dead_code)]
    pub(crate) fn resolved_italic(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<bool> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.run_props.get(id)?.italic)
    }

    // swift: Render/Office/DocxReader.swift:1153-1155
    #[allow(dead_code)]
    pub(crate) fn resolved_font_size(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<CGFloat> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.run_props.get(id)?.font_size)
    }

    // swift: Render/Office/DocxReader.swift:1157-1188
    /// The four font slots and the hint, each resolved on its OWN through the whole cascade:
    /// direct `w:rPr` → the paragraph style's `w:basedOn` chain → the document's default paragraph
    /// style → `w:docDefaults`. Later levels win, and a level silent about ONE slot is transparent
    /// to that slot alone.
    ///
    /// Five independent walks, not one. Resolving the whole element in a single walk would stop at
    /// the first style that set ANY slot and take that style's silence about the others as an
    /// answer — which is how a heading style naming only a Latin face would erase the East Asian
    /// face its ancestor declared. This is `walkStyleChain`'s own per-PROPERTY contract, applied
    /// five times rather than bent once.
    ///
    /// The default paragraph style stands in only when the paragraph names none of its own, which is
    /// what `w:default="1"` means; a paragraph that DOES name a style reaches Normal (or does not)
    /// through its own `w:basedOn` chain, exactly as Word resolves it.
    ///
    /// Character styles (`w:rPr/w:rStyle`) are a level of the real cascade and are still not read —
    /// they sit between the paragraph style chain and direct formatting. Measured at 29 of 12,482
    /// runs (0.23%) in this project's corpus. Adding them would change colour and size as well as
    /// fonts, so it belongs to whichever change measures those, not to this one.
    #[allow(dead_code)]
    pub(crate) fn resolved_r_fonts(p_style_id: Option<String>, style_info: &StyleInfo, direct: &WordRFonts) -> WordRFonts {
        let style_id = p_style_id.or_else(|| style_info.default_paragraph_style_id.clone());
        let mut out = WordRFonts::default();
        for slot in WordFontSlot::ALL {
            let value = direct.get(slot).cloned().or_else(|| {
                Self::walk_style_chain(style_id.clone(), style_info, |id| style_info.r_fonts.get(id)?.get(slot).cloned())
            }).or_else(|| style_info.doc_defaults_r_fonts.get(slot).cloned());
            out.set(slot, value);
        }
        out.hint = direct.hint.clone()
            .or_else(|| Self::walk_style_chain(style_id.clone(), style_info, |id| style_info.r_fonts.get(id)?.hint.clone()))
            .or_else(|| style_info.doc_defaults_r_fonts.hint.clone());
        out
    }

    // swift: Render/Office/DocxReader.swift:1190-1213
    /// Resolves one paragraph's numbering to a `(numId, ilvl)` pair for the HEADING-numbering path
    /// (`parseParagraph`'s heading branch) — the paragraph's OWN `w:numPr`, if it has one, wins as
    /// a WHOLE element (Word technically lets `w:numId` and `w:ilvl` be inherited independently,
    /// but a paragraph that carries `w:numPr` at all is stating both together, and this reader
    /// deliberately doesn't split them — same posture as every other "resolve the whole element,
    /// not field-by-field" choice already made for numbering); failing that, the `w:basedOn` chain
    /// is walked for the NEAREST style that declared its own `w:numPr` (`resolvedRFonts`'s own
    /// `walkStyleChain` pattern, reused here) — this is the mechanism that makes a document whose
    /// headings carry ONLY `w:pStyle` (numbering lives on the `HeadingN` style, never repeated per
    /// paragraph) number themselves at all. `ilvl` defaults to 0 when the winning source omitted
    /// it, matching every other numPr read in this file (`parseParagraph`'s own `.listItem`
    /// branch). `nil` means neither the paragraph nor any style in its chain declared numbering.
    #[allow(dead_code)]
    pub(crate) fn resolved_num_pr(
        p_pr: Option<&XMLNode>, p_style_id: Option<String>, style_info: &StyleInfo,
    ) -> Option<(Option<String>, i32)> {
        if let Some(own_num_pr) = p_pr.and_then(|n| n.child("w:numPr")) {
            let num_id = own_num_pr.child("w:numId").and_then(|n| n.attributes.get("w:val").cloned());
            let ilvl = own_num_pr.child("w:ilvl").and_then(|n| n.attributes.get("w:val").cloned()).and_then(|v| v.parse().ok()).unwrap_or(0);
            return Some((num_id, ilvl));
        }
        let inherited = Self::walk_style_chain(p_style_id, style_info, |id| style_info.style_numbering.get(id).cloned())?;
        Some((inherited.num_id, inherited.ilvl.unwrap_or(0)))
    }

    // swift: Render/Office/DocxReader.swift:1215-1217
    #[allow(dead_code)]
    pub(crate) fn resolved_alignment(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<NSTextAlignment> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.alignment.clone())
    }

    // swift: Render/Office/DocxReader.swift:1219-1221
    #[allow(dead_code)]
    pub(crate) fn resolved_tab_stops(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<Vec<TabStop>> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.tab_stops.clone())
    }

    // swift: Render/Office/DocxReader.swift:1223-1225
    fn resolved_shading(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<NSColor> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.shading.clone())
    }

    // swift: Render/Office/DocxReader.swift:1227-1229
    fn resolved_border(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<(Option<NSColor>, Option<CGFloat>, RectEdge)> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.border.clone())
    }

    // swift: Render/Office/DocxReader.swift:1231-1233
    fn resolved_spacing_before(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<CGFloat> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.spacing_before)
    }

    // swift: Render/Office/DocxReader.swift:1235-1237
    fn resolved_spacing_after(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<CGFloat> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.spacing_after)
    }

    // swift: Render/Office/DocxReader.swift:1239-1241
    fn resolved_line_height(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<LineHeight> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.line_height.clone())
    }

    // swift: Render/Office/DocxReader.swift:1243-1245
    fn resolved_indent_start(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<CGFloat> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.indent_start)
    }

    // swift: Render/Office/DocxReader.swift:1247-1249
    fn resolved_indent_end(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<CGFloat> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.indent_end)
    }

    // swift: Render/Office/DocxReader.swift:1251-1253
    fn resolved_first_line_indent(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<CGFloat> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.first_line_indent)
    }

    // swift: Render/Office/DocxReader.swift:1255-1257
    fn resolved_hanging_indent(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<CGFloat> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.hanging_indent)
    }

    // swift: Render/Office/DocxReader.swift:1259-1261
    fn resolved_contextual_spacing(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<bool> {
        Self::walk_style_chain(p_style_id, style_info, |id| style_info.para_props.get(id)?.contextual_spacing)
    }

    // swift: Render/Office/DocxReader.swift:1263-1289
    /// The P2 cascade itself (spec area 9's `resolve_paragraph_properties`, restricted to the
    /// spacing/indent/line-height/contextualSpacing fields this sprint covers): for EACH property
    /// independently, low priority → high — `docDefaults` floor, then the style chain (`walkStyleChain`
    /// already returns the NEAREST ancestor that set it, which is equivalent to applying root→leaf
    /// and taking the last setter — see its own doc), then this paragraph's own direct `w:pPr` —
    /// the first non-nil wins. `contextualSpacing`'s final "still unset" case defaults to `false`
    /// (`ParagraphFormat`'s own default), matching every property this cascade never touches.
    pub(crate) fn resolved_paragraph_format(p_pr: Option<&XMLNode>, p_style_id: Option<String>, style_info: &StyleInfo) -> ParagraphFormat {
        let direct = Self::parse_para_style_props(p_pr);
        let defaults = &style_info.doc_defaults_para_props;
        let mut format = ParagraphFormat::default();
        format.spacing_before = direct.spacing_before.or_else(|| Self::resolved_spacing_before(p_style_id.clone(), style_info)).or(defaults.spacing_before);
        format.spacing_after = direct.spacing_after.or_else(|| Self::resolved_spacing_after(p_style_id.clone(), style_info)).or(defaults.spacing_after);
        format.line_height = direct.line_height.or_else(|| Self::resolved_line_height(p_style_id.clone(), style_info)).or(defaults.line_height.clone());
        format.indent_start = direct.indent_start.or_else(|| Self::resolved_indent_start(p_style_id.clone(), style_info)).or(defaults.indent_start);
        format.indent_end = direct.indent_end.or_else(|| Self::resolved_indent_end(p_style_id.clone(), style_info)).or(defaults.indent_end);
        format.first_line_indent = direct.first_line_indent.or_else(|| Self::resolved_first_line_indent(p_style_id.clone(), style_info)).or(defaults.first_line_indent);
        format.hanging_indent = direct.hanging_indent.or_else(|| Self::resolved_hanging_indent(p_style_id.clone(), style_info)).or(defaults.hanging_indent);
        format.contextual_spacing = direct.contextual_spacing.or_else(|| Self::resolved_contextual_spacing(p_style_id.clone(), style_info)).or(defaults.contextual_spacing).unwrap_or(false);
        // P2b — shading/border join the SAME cascade, one property at a time, same priority order.
        format.shading = direct.shading.clone().or_else(|| Self::resolved_shading(p_style_id.clone(), style_info)).or(defaults.shading.clone());
        let border = direct.border.clone().or_else(|| Self::resolved_border(p_style_id.clone(), style_info)).or(defaults.border.clone());
        format.border_color = border.clone().and_then(|b| b.0);
        format.border_width = border.clone().and_then(|b| b.1);
        format.border_edges = border.map(|b| b.2).unwrap_or_else(RectEdge::empty);
        format
    }
}

// swift: Render/Office/DocxReader.swift:1291-1291
// MARK: word/theme/theme1.xml — theme colour scheme

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1293-1317
    /// `word/theme/theme1.xml`'s `a:clrScheme` names twelve fixed slots (`a:dk1`, `a:lt1`, `a:dk2`,
    /// `a:lt2`, `a:accent1`…`a:accent6`, `a:hlink`, `a:folHlink`), each holding either a literal
    /// `a:srgbClr/@val` or a `a:sysClr` (a named system colour, e.g. `"windowText"`) whose
    /// `@lastClr` attribute is Office's own cached literal RGB for it — read here exactly like
    /// `a:srgbClr`'s `val`, since that cached value is what Word itself actually painted with.
    /// Absent or malformed (no `word/theme/theme1.xml` at all, or one without `a:clrScheme`)
    /// degrades to an empty table, never a crash — every `w:themeColor` lookup against it then
    /// simply misses, same as a document with no theme colours ever declared.
    fn parse_theme_colors(archive: &ZipArchive) -> std::collections::HashMap<String, NSColor> {
        if !archive.contains("word/theme/theme1.xml") {
            return std::collections::HashMap::new();
        }
        let Ok(data) = archive.data_for("word/theme/theme1.xml") else { return std::collections::HashMap::new() };
        let Ok(root) = Self::build_tree(&data.0) else { return std::collections::HashMap::new() };
        let Some(clr_scheme) = root.first_descendant("a:clrScheme") else { return std::collections::HashMap::new() };
        let mut colors: std::collections::HashMap<String, NSColor> = std::collections::HashMap::new();
        for slot in clr_scheme.children.iter().filter(|s| s.name.starts_with("a:")) {
            let key = slot.name[2..].to_string();
            if let Some(hex) = slot.child("a:srgbClr").and_then(|n| n.attributes.get("val").cloned()) {
                if let Some(color) = Self::color_from_hex(&hex) {
                    colors.insert(key, color);
                    continue;
                }
            }
            if let Some(hex) = slot.child("a:sysClr").and_then(|n| n.attributes.get("lastClr").cloned()) {
                if let Some(color) = Self::color_from_hex(&hex) {
                    colors.insert(key, color);
                }
            }
        }
        colors
    }

    // swift: Render/Office/DocxReader.swift:1319-1362
    /// `word/theme/theme1.xml`'s `a:fontScheme` — the same shape, guard for guard, as
    /// `parseThemeColors` above: the part path is fixed, `archive.contains` gates it, the scheme is
    /// found by `firstDescendant`, and anything absent or malformed degrades to an EMPTY scheme
    /// rather than throwing, so a `w:asciiTheme` in a document with no theme part simply resolves to
    /// nothing (the reader's own body font) exactly as it did before this existed.
    ///
    /// `a:majorFont`/`a:minorFont` each hold `a:latin`/`a:ea`/`a:cs` plus a list of
    /// `a:font script="…" typeface="…"` entries. The attributes are unprefixed, like `a:srgbClr`'s
    /// `val` beside them.
    ///
    /// An empty `typeface=""` is read as ABSENT, which is the load-bearing case rather than a
    /// nicety: `a:ea typeface=""` appears in five of five real themes measured here, and Brandwares'
    /// reading of it — *"a setting of typeface='' means it has no theme font for that charset type"*
    /// — is what makes the `a:font script=` list the only non-empty source of an East Asian family
    /// in a real Office theme. Storing `""` instead would resolve `minorEastAsia` to a family name
    /// no font can match and hide the script list behind it.
    fn parse_theme_fonts(archive: &ZipArchive) -> WordThemeFonts {
        if !archive.contains("word/theme/theme1.xml") {
            return WordThemeFonts::default();
        }
        let Ok(data) = archive.data_for("word/theme/theme1.xml") else { return WordThemeFonts::default() };
        let Ok(root) = Self::build_tree(&data.0) else { return WordThemeFonts::default() };
        let Some(font_scheme) = root.first_descendant("a:fontScheme") else { return WordThemeFonts::default() };
        fn scheme(font_scheme: &XMLNode, name: &str) -> crate::render::office::word_font_slots::WordThemeScheme {
            let mut out = crate::render::office::word_font_slots::WordThemeScheme::default();
            let Some(node) = font_scheme.child(name) else { return out };
            let typeface = |child: &str| -> Option<String> {
                let value = node.child(child)?.attributes.get("typeface").cloned()?;
                if value.is_empty() { None } else { Some(value) }
            };
            out.latin = typeface("a:latin");
            out.east_asian = typeface("a:ea");
            out.complex = typeface("a:cs");
            for font in node.children.iter().filter(|f| f.name == "a:font") {
                let (Some(script), Some(face)) = (
                    font.attributes.get("script").filter(|s| !s.is_empty()),
                    font.attributes.get("typeface").filter(|f| !f.is_empty()),
                ) else { continue };
                out.by_script.insert(script.clone(), face.clone());
            }
            out
        }
        let mut fonts = WordThemeFonts::default();
        fonts.major = scheme(&font_scheme, "a:majorFont");
        fonts.minor = scheme(&font_scheme, "a:minorFont");
        fonts
    }

    // swift: Render/Office/DocxReader.swift:1364-1383
    /// `w:themeColor`'s enumeration (ECMA-376 §17.18.98, `ST_ThemeColor`) names TEN colour roles —
    /// `"dark1"`/`"light1"`/`"dark2"`/`"light2"` AND the semantically-named `"text1"`/
    /// `"background1"`/`"text2"`/`"background2"` are two spellings for the SAME four scheme slots
    /// (`dk1`/`lt1`/`dk2`/`lt2`) — plus `"accent1"`…`"accent6"` (spelled identically to their
    /// scheme slot names, so no translation needed) and `"hyperlink"`/`"followedHyperlink"` (the
    /// scheme's `hlink`/`folHlink`, abbreviated). `nil` for anything else (there is nothing else in
    /// the enumeration, but a malformed document could carry a stray value) — the caller then finds
    /// no colour, same as a `w:themeColor` slot the theme part itself never defined.
    fn theme_slot_name(theme_color: &str) -> Option<String> {
        match theme_color {
            "dark1" | "text1" => Some("dk1".to_string()),
            "light1" | "background1" => Some("lt1".to_string()),
            "dark2" | "text2" => Some("dk2".to_string()),
            "light2" | "background2" => Some("lt2".to_string()),
            "accent1" | "accent2" | "accent3" | "accent4" | "accent5" | "accent6" => Some(theme_color.to_string()),
            "hyperlink" => Some("hlink".to_string()),
            "followedHyperlink" => Some("folHlink".to_string()),
            _ => None,
        }
    }

    // swift: Render/Office/DocxReader.swift:1385-1408
    /// A `w:color` element (a run's own `w:rPr/w:color`, or a style's), resolved to a literal —
    /// EITHER its literal `w:val` hex, OR — measured at 10% of the real corpus, a mechanism worth
    /// doing properly rather than approximating — a `w:themeColor` reference resolved against
    /// `themeColors`. `w:val="auto"` (Word's own "let the reader decide" sentinel) and an
    /// unresolvable `w:themeColor` (an unrecognized slot name, or a theme part that doesn't define
    /// it) both mean exactly what no `w:color` at all means — `nil`, "the theme's own text colour
    /// decides" — never a fabricated black. `w:themeColor` wins when BOTH are present (Word always
    /// writes a literal `w:val` alongside a `w:themeColor` as an older-reader fallback — the two are
    /// never in real conflict, but the theme reference is the author's actual intent).
    ///
    /// `w:themeTint`/`w:themeShade` (a lightened/darkened variant of the resolved slot) are read off
    /// the element by callers that want them but DELIBERATELY IGNORED here — see this sprint's
    /// return report. Applying them correctly is a luminance-space transform (ECMA-376's own
    /// algorithm operates in HSL, not a flat per-channel blend), and getting that wrong would be
    /// worse than the brief's own explicitly offered fallback: resolve the base slot colour, as
    /// authored, and leave it there.
    pub(crate) fn resolved_color_element(
        color_node: Option<&XMLNode>, theme_colors: &std::collections::HashMap<String, NSColor>,
    ) -> Option<NSColor> {
        let color_node = color_node?;
        if let Some(theme_color) = color_node.attributes.get("w:themeColor") {
            if let Some(slot) = Self::theme_slot_name(theme_color) {
                if let Some(resolved) = theme_colors.get(&slot) {
                    return Some(resolved.clone());
                }
            }
        }
        let val = color_node.attributes.get("w:val")?;
        if val.to_lowercase() == "auto" {
            return None;
        }
        Self::color_from_hex(val)
    }

    // swift: Render/Office/DocxReader.swift:1410-1440
    /// `w:highlight`'s value (ECMA-376 §17.18.40, `ST_HighlightColor`) is a NAME from a fixed
    /// 17-entry enumeration, not a hex value — unlike `w:color`/`w:shd`, which are always literal
    /// or theme-relative. The sixteen real colours' RGB equivalents below are the standard values
    /// every Open XML implementation (Word itself, the published Open XML SDK enumeration) assigns
    /// to these exact names — read FROM the spec's own enumeration semantics, not copied out of
    /// another project's lookup table (this project's licence rule forbids that; see
    /// `mappedSymbolCharacter`'s doc for the same reasoning applied to `w:sym`). `"none"` and
    /// anything unrecognized both return `nil` — no highlight — never a guessed colour.
    pub(crate) fn highlight_color(name: &str) -> Option<NSColor> {
        let hex: Option<&str> = match name {
            "black" => Some("000000"),
            "blue" => Some("0000FF"),
            "cyan" => Some("00FFFF"),
            "darkBlue" => Some("00008B"),
            "darkCyan" => Some("008B8B"),
            "darkGray" => Some("A9A9A9"),
            "darkGreen" => Some("006400"),
            "darkMagenta" => Some("8B008B"),
            "darkRed" => Some("8B0000"),
            "darkYellow" => Some("808000"),
            "green" => Some("00FF00"),
            "lightGray" => Some("D3D3D3"),
            "magenta" => Some("FF00FF"),
            "red" => Some("FF0000"),
            "white" => Some("FFFFFF"),
            "yellow" => Some("FFFF00"),
            _ => None, // "none", or anything unrecognized.
        };
        hex.and_then(Self::color_from_hex)
    }

    // swift: Render/Office/DocxReader.swift:1442-1454
    /// A bare 6-digit `RRGGBB` hex string (docx never emits alpha in `w:val`/`w:fill`/`@lastClr`) →
    /// `NSColor`. `nil` for anything that isn't exactly 6 hex digits (a malformed document, or —
    /// for `w:fill` specifically — the literal string `"auto"`, already filtered by every caller
    /// before it reaches here).
    pub(crate) fn color_from_hex(hex: &str) -> Option<NSColor> {
        let mut digits = hex.to_string();
        if let Some(stripped) = digits.strip_prefix('#') {
            digits = stripped.to_string();
        }
        if digits.chars().count() != 6 {
            return None;
        }
        let value = u32::from_str_radix(&digits, 16).ok()?;
        Some(NSColor::srgb(
            ((value >> 16) & 0xFF) as CGFloat / 255.0,
            ((value >> 8) & 0xFF) as CGFloat / 255.0,
            (value & 0xFF) as CGFloat / 255.0,
            1.0,
        ))
    }

    // swift: Render/Office/DocxReader.swift:1456-1466
    /// Mechanism (b): a built-in heading style's id IS its heading level — `Heading1`…`Heading9`,
    /// compared case-insensitively (Word has written both `Heading1` and `heading1` over the years)
    /// against ONLY these nine ASCII ids, never against a style's (localized) name. Returns the same
    /// 0-based scale `w:outlineLvl` uses (`Heading1` → 0), so callers treat it identically to an
    /// explicit `outlineLvl`.
    fn built_in_heading_level(style_id: &str) -> Option<i32> {
        let lower = style_id.to_lowercase();
        let rest = lower.strip_prefix("heading")?;
        let digit: i32 = rest.parse().ok()?;
        if (1..=9).contains(&digit) {
            Some(digit - 1)
        } else {
            None
        }
    }

    // swift: Render/Office/DocxReader.swift:1468-1486
    /// Resolves a paragraph style's outline level by walking its `w:basedOn` chain: at each style,
    /// an explicit `w:outlineLvl` wins; failing that, the style's own id being a built-in `HeadingN`
    /// counts as that level (this is what makes a CUSTOM style based on `Heading2` — which itself
    /// usually carries no `w:outlineLvl` of its own, mechanism (b)'s whole premise — resolve to
    /// level 1 without needing its own declaration); failing both, the walk continues to the
    /// `w:basedOn` parent. A style id revisited during the walk means a cycle in a malformed
    /// document — the walk stops and reports "not a heading" rather than looping forever.
    fn resolved_outline_level(p_style_id: Option<String>, style_info: &StyleInfo) -> Option<i32> {
        let mut current_id = p_style_id?;
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        loop {
            if visited.contains(&current_id) {
                return None;
            }
            visited.insert(current_id.clone());
            if let Some(level) = style_info.outline_levels.get(&current_id) {
                return Some(*level);
            }
            if let Some(level) = Self::built_in_heading_level(&current_id) {
                return Some(level);
            }
            let Some(parent) = style_info.based_on.get(&current_id).cloned() else { return None };
            current_id = parent;
        }
    }

    // swift: Render/Office/DocxReader.swift:1488-1501
    /// `outlineLvl` 0–8 are real heading levels; 9 is what Word gives its own `TOCHeading` style
    /// and must NOT be treated as a heading (it would otherwise put a table-of-contents label at
    /// sidebar depth 10) — that guard applies whether the level came from the paragraph's own
    /// `w:pPr/w:outlineLvl` (checked first — an author can mark a single paragraph as a heading with
    /// no style at all) or from its style, INCLUDING one inherited through `w:basedOn`. The emitted
    /// level is clamped to 1–6 — the vocabulary `OfficeBlock` offers — so an `outlineLvl` of 6, 7 or
    /// 8 all render as level 6 rather than being refused.
    pub(crate) fn heading_level(p_pr: Option<&XMLNode>, p_style_id: Option<String>, style_info: &StyleInfo) -> Option<i32> {
        if let Some(own_val) = p_pr.and_then(|n| n.child("w:outlineLvl")).and_then(|n| n.attributes.get("w:val").cloned()) {
            if let Ok(own_level) = own_val.parse::<i32>() {
                if own_level <= 8 {
                    return Some((own_level + 1).min(6));
                }
            }
        }
        let level = Self::resolved_outline_level(p_style_id, style_info)?;
        if level > 8 {
            return None;
        }
        Some((level + 1).min(6))
    }
}

// swift: Render/Office/DocxReader.swift:1503-1503
// MARK: numbering.xml — numId → abstractNumId → level → format/text/start, with per-numId overrides

/// One level's numbering definition, whether it came from `w:abstractNum` directly or replaced
/// wholesale by a `w:num`'s `w:lvlOverride/w:lvl` (same element shape either way — see
/// `parseLevel`). `lvlText` is the raw `"%1.%2."`-style pattern this level substitutes counters
/// into; `nil` when the source never declared one (rare, but not an error — `numberedListInfo`
/// falls back to `OfficeTextBuilder`'s own counting in that case, same as an unresolvable
/// numId). `start` defaults to 1 — Word omits `w:start` whenever a level simply starts there.
// swift: Render/Office/DocxReader.swift:1511-1528
#[derive(Debug, Clone)]
pub(crate) struct AbstractLevel {
    num_fmt: String,
    lvl_text: Option<String>,
    start: i32,
    /// Word's "legal numbering" toggle (`w:isLgl`): when set, EVERY substituted sub-level in
    /// this level's `lvlText` displays as plain Arabic digits regardless of that sub-level's
    /// OWN `w:numFmt` — the convention real contracts use so `1.a.i` still shows as `1.1.1`.
    is_lgl: bool,
    /// The separator Word draws between this level's substituted marker and whatever follows
    /// it — `w:suff` (§17.9.22 `ST_LevelSuffix`), already mapped to the literal string to
    /// insert (`"tab"` → `"\t"`, `"space"` → `" "`, `"nothing"` → `""`) rather than the raw XML
    /// token, so every caller just concatenates it. ECMA-376's own default when the element is
    /// absent is `"tab"` — Word only writes `w:suff` when a level deviates from that. Consumed
    /// ONLY by the heading-numbering path this field was added for (`parseParagraph`'s heading
    /// branch): the pre-existing `.listItem` path spaces its marker `OfficeTextBuilder`'s own
    /// way and must keep doing so byte-for-byte, so nothing there reads this field.
    pub(crate) suff: String,
}

/// A single level's per-numId override, from `w:num/w:lvlOverride`: `startOverride` resets
/// where that level's counter begins (`w:startOverride`), `lvlReplacement` replaces the WHOLE
/// level definition for this numId only (`w:lvlOverride/w:lvl`) — Word allows either, both, or
/// neither on the same `w:lvlOverride` element.
// swift: Render/Office/DocxReader.swift:1534-1537
#[derive(Debug, Clone, Default)]
struct NumOverride {
    start_override: Option<i32>,
    lvl_replacement: Option<AbstractLevel>,
}

// swift: Render/Office/DocxReader.swift:1539-1543
#[derive(Debug, Clone, Default)]
pub struct NumberingInfo {
    abstract_num_id_by_num_id: std::collections::HashMap<String, String>,
    abstract_levels_by_id: std::collections::HashMap<String, std::collections::HashMap<i32, AbstractLevel>>,
    num_id_level_overrides: std::collections::HashMap<String, std::collections::HashMap<i32, NumOverride>>,
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1545-1591
    /// Parses BOTH `w:abstractNum` (the shared level definitions) and each `w:num`'s own
    /// `w:lvlOverride`s (a per-list exception to those shared definitions — a start value reset,
    /// or an entirely different level) — reading only `w:numFmt` as the old version of this
    /// function did would tell a bullet from a number apart but throws away everything
    /// `numberedListInfo` now needs to compute the actual marker text and honour overrides.
    fn parse_numbering(archive: &ZipArchive) -> NumberingInfo {
        if !archive.contains("word/numbering.xml") {
            return NumberingInfo::default();
        }
        let Ok(data) = archive.data_for("word/numbering.xml") else { return NumberingInfo::default() };
        let Ok(root) = Self::build_tree(&data.0) else { return NumberingInfo::default() };
        let mut info = NumberingInfo::default();
        for child in root.children.iter() {
            match child.name.as_str() {
                "w:abstractNum" => {
                    let Some(abstract_id) = child.attributes.get("w:abstractNumId").cloned() else { continue };
                    let mut levels: std::collections::HashMap<i32, AbstractLevel> = std::collections::HashMap::new();
                    for lvl in child.children.iter().filter(|l| l.name == "w:lvl") {
                        let Some(ilvl_string) = lvl.attributes.get("w:ilvl") else { continue };
                        let Ok(ilvl) = ilvl_string.parse::<i32>() else { continue };
                        if let Some(level) = Self::parse_level(lvl) {
                            levels.insert(ilvl, level);
                        }
                    }
                    info.abstract_levels_by_id.insert(abstract_id, levels);
                }
                "w:num" => {
                    let (Some(num_id), Some(abstract_ref)) = (
                        child.attributes.get("w:numId").cloned(),
                        child.child("w:abstractNumId").and_then(|n| n.attributes.get("w:val").cloned()),
                    ) else { continue };
                    info.abstract_num_id_by_num_id.insert(num_id.clone(), abstract_ref);
                    let mut overrides: std::collections::HashMap<i32, NumOverride> = std::collections::HashMap::new();
                    for lvl_override in child.children.iter().filter(|l| l.name == "w:lvlOverride") {
                        let Some(ilvl_string) = lvl_override.attributes.get("w:ilvl") else { continue };
                        let Ok(ilvl) = ilvl_string.parse::<i32>() else { continue };
                        let mut override_ = NumOverride::default();
                        if let Some(start_val) = lvl_override.child("w:startOverride").and_then(|n| n.attributes.get("w:val").cloned()) {
                            if let Ok(start) = start_val.parse::<i32>() {
                                override_.start_override = Some(start);
                            }
                        }
                        if let Some(lvl_node) = lvl_override.child("w:lvl") {
                            override_.lvl_replacement = Self::parse_level(&lvl_node);
                        }
                        if override_.start_override.is_some() || override_.lvl_replacement.is_some() {
                            overrides.insert(ilvl, override_);
                        }
                    }
                    if !overrides.is_empty() {
                        info.num_id_level_overrides.insert(num_id, overrides);
                    }
                }
                _ => continue,
            }
        }
        info
    }
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1593-1608
    /// A level missing `w:numFmt` entirely is not returned — there is nothing to classify it by,
    /// and the caller's existing "unresolvable" fallback (never fabricate a number) already covers
    /// that. `w:start`'s absence means 1, not "no start" — Word only writes the element when the
    /// level starts somewhere else.
    fn parse_level(lvl: &XMLNode) -> Option<AbstractLevel> {
        let fmt = lvl.child("w:numFmt")?.attributes.get("w:val").cloned()?;
        let lvl_text = lvl.child("w:lvlText").and_then(|n| n.attributes.get("w:val").cloned());
        let start = lvl.child("w:start").and_then(|n| n.attributes.get("w:val").cloned()).and_then(|v| v.parse().ok()).unwrap_or(1);
        let suff = match lvl.child("w:suff").and_then(|n| n.attributes.get("w:val").cloned()).as_deref() {
            Some("space") => " ".to_string(),
            Some("nothing") => "".to_string(),
            _ => "\t".to_string(), // "tab", and an absent element (ECMA-376's own default), both mean tab
        };
        Some(AbstractLevel { num_fmt: fmt, lvl_text, start, is_lgl: lvl.child("w:isLgl").is_some(), suff })
    }

    // swift: Render/Office/DocxReader.swift:1610-1624
    /// Resolves one `(numId, ilvl)` to its effective definition: the abstract level, with any
    /// `w:lvlOverride` for THIS numId layered on top (a full replacement first, since Word treats
    /// `w:lvlOverride/w:lvl` as swapping the entire level; then `w:startOverride`, which can apply
    /// even without a replacement — resetting where a shared, unmodified level starts for just
    /// this one list). `nil` when the numId itself doesn't resolve to any abstract definition, or
    /// that abstract definition never declared this level at all.
    pub(crate) fn resolved_level(num_id: &str, ilvl: i32, info: &NumberingInfo) -> Option<AbstractLevel> {
        let abstract_id = info.abstract_num_id_by_num_id.get(num_id)?;
        let mut level = info.abstract_levels_by_id.get(abstract_id).and_then(|m| m.get(&ilvl)).cloned();
        if let Some(override_) = info.num_id_level_overrides.get(num_id).and_then(|m| m.get(&ilvl)) {
            if let Some(replacement) = &override_.lvl_replacement {
                level = Some(replacement.clone());
            }
            if let Some(start_override) = override_.start_override {
                if let Some(l) = level.as_mut() {
                    l.start = start_override;
                }
            }
        }
        level
    }
}

/// Per-`(numId, level)` running counts — a numbering definition's counters belong to the numId
/// (Word continues them across whatever body content intervenes between two paragraphs that
/// share one), never to where in the document a paragraph happens to sit, so this is a
/// REFERENCE shared across the whole `read()` call (body, then footnotes, then endnotes, all
/// walked from one `read()`) rather than a value threaded through every function's parameters
/// with `inout`.
// swift: Render/Office/DocxReader.swift:1632-1632
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ListCounterKey {
    num_id: String,
    level: i32,
}

// swift: Render/Office/DocxReader.swift:1633-1633
#[derive(Debug, Clone, Default)]
pub struct ListNumberingState {
    counters: std::collections::HashMap<ListCounterKey, i32>,
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1635-1644
    /// Clears every counter for this numId at `level` and DEEPER — used both when a
    /// shallower-or-equal ordered item breaks a deeper run (deeper only: `from: ilvl + 1`) and
    /// when a `bullet`/`none` item at `ilvl` breaks any ordered run AT that level too (self and
    /// deeper: `from: ilvl`). Scoped to `numId` alone — an unrelated list sharing the same `ilvl`
    /// must never see its counters disturbed by this one.
    pub(crate) fn clear_counters(num_id: &str, from_level: i32, state: &swiftshim::Ref<ListNumberingState>) {
        state.borrow_mut().counters.retain(|key, _| !(key.num_id == num_id && key.level >= from_level));
    }

    // swift: Render/Office/DocxReader.swift:1646-1688
    /// The reader's own resolved rendering info for one numbered paragraph: `ordered` still drives
    /// `OfficeTextBuilder`'s indentation/bullet fallback (see `OfficeBlock.listItem`), `marker` is
    /// this item's pre-formatted display text when the source's numbering resolves that far. The
    /// OUTER `nil` means `numId="0"` — Word's own sentinel for "this paragraph carries `w:numPr`
    /// but is explicitly NOT numbered" — the caller must emit a plain `.paragraph`, never a
    /// `.listItem`, for that case.
    pub(crate) fn numbered_list_info(
        num_id: Option<String>, ilvl: i32, info: &NumberingInfo, state: &swiftshim::Ref<ListNumberingState>,
    ) -> Option<(bool, Option<String>)> {
        let Some(num_id) = num_id else { return Some((false, None)) };
        if num_id == "0" {
            return None;
        }
        // Unresolvable numId, or a level the abstract definition never declared — today's
        // pre-sprint fallback: never fabricate a number, but the paragraph is still a list item
        // (same reasoning the removed `isOrdered` carried).
        let Some(level) = Self::resolved_level(&num_id, ilvl, info) else { return Some((false, None)) };
        match level.num_fmt.as_str() {
            "bullet" => {
                Self::clear_counters(&num_id, ilvl, state);
                return Some((false, None));
            }
            "none" => {
                // A real numbering level that simply displays nothing — distinct from `bullet`
                // (which `OfficeTextBuilder` draws its own glyph for): passing `""` (not `nil`) tells
                // the builder "render this marker verbatim", i.e. nothing, rather than falling back to
                // a bullet glyph the source never asked for.
                Self::clear_counters(&num_id, ilvl, state);
                return Some((false, Some(String::new())));
            }
            _ => {}
        }
        Self::clear_counters(&num_id, ilvl + 1, state);
        let key = ListCounterKey { num_id: num_id.clone(), level: ilvl };
        let next = state.borrow().counters.get(&key).copied().unwrap_or(level.start - 1) + 1;
        state.borrow_mut().counters.insert(key, next);
        // No `w:lvlText` to substitute into — the level is still genuinely ordered, but this
        // reader has no way to compute display text for it; `nil` marker tells
        // `OfficeTextBuilder` to fall back to its own simple "N." counting for this item, exactly
        // as it did before this sprint.
        let Some(lvl_text) = level.lvl_text.clone() else { return Some((true, None)) };
        let marker = Self::substitute_level_text(&lvl_text, &num_id, ilvl, next, level.is_lgl, info, state);
        Some((true, Some(marker)))
    }

    // swift: Render/Office/DocxReader.swift:1690-1720
    /// Substitutes every `%1`…`%9` token in `lvlText` with that level's counter, formatted by
    /// EITHER that level's own `w:numFmt` (the common case — e.g. `%1` decimal, `%2` letters) OR,
    /// when the CURRENT level is `w:isLgl`, always as decimal (Word's legal-numbering override —
    /// see `AbstractLevel.isLgl`). The level being substituted (`refLevel`) is read from the
    /// counter STATE when it's the current level (the value just incremented by the caller) or
    /// when a shallower level has already been visited; a level never yet reached in this walk
    /// falls back to its own declared `start` — a document whose `lvlText` references a level
    /// that hasn't appeared yet is unusual, but showing that level's start value beats showing
    /// nothing.
    fn substitute_level_text(
        lvl_text: &str, num_id: &str, current_level: i32, current_value: i32, is_lgl: bool,
        info: &NumberingInfo, state: &swiftshim::Ref<ListNumberingState>,
    ) -> String {
        let mut result = lvl_text.to_string();
        for k in 1..=9 {
            let token = format!("%{}", k);
            if !result.contains(&token) {
                continue;
            }
            let ref_level = k - 1;
            let value = if ref_level == current_level {
                current_value
            } else if let Some(existing) = state.borrow().counters.get(&ListCounterKey { num_id: num_id.to_string(), level: ref_level }) {
                *existing
            } else {
                Self::resolved_level(num_id, ref_level, info).map(|l| l.start).unwrap_or(1)
            };
            let format = if is_lgl {
                "decimal".to_string()
            } else {
                Self::resolved_level(num_id, ref_level, info).map(|l| l.num_fmt).unwrap_or_else(|| "decimal".to_string())
            };
            result = result.replace(&token, &Self::format_number(value, &format));
        }
        result
    }

    // swift: Render/Office/DocxReader.swift:1722-1756
    /// Formats one counter value per Word's `w:numFmt`. Only the formats the sprint brief lists as
    /// actually occurring in real documents get their own case; anything else — an exotic or
    /// future format this reader doesn't specifically know — falls back to plain decimal rather
    /// than throwing or producing no text: a wrong-LOOKING number is honest about "something is
    /// numbered here", a missing one is not (the same posture `w:sym`'s ▯ placeholder takes for an
    /// unmappable glyph).
    fn format_number(n: i32, format: &str) -> String {
        match format {
            "decimalZero" => if n >= 0 && n < 10 { format!("0{}", n) } else { format!("{}", n) },
            "upperRoman" => Self::roman_numeral(n),
            "lowerRoman" => Self::roman_numeral(n).to_lowercase(),
            "upperLetter" => Self::letter_sequence(n).to_uppercase(),
            "lowerLetter" => Self::letter_sequence(n),
            // `ideographDigital`/`koreanDigital` (§17.18.59 `ST_NumberFormat`) are DIGIT SUBSTITUTION,
            // not full positional counting (Chinese/Korean "counting" numerals — e.g. 12 as "십이"/
            // "十二" — are a materially different algorithm this reader doesn't attempt): each decimal
            // digit of `n` is replaced one-for-one with its ideograph/Hangul numeral. `digitGlyphs`
            // covers only 0–9, so a negative `n` falls back to `decimal` (its `-` has no glyph) same as
            // any other unrecognized format.
            "ideographDigital" => Self::digit_glyphs(n, &CHINESE_DIGIT_GLYPHS).unwrap_or_else(|| format!("{}", n)),
            "koreanDigital" => Self::digit_glyphs(n, &KOREAN_DIGIT_GLYPHS).unwrap_or_else(|| format!("{}", n)),
            // `decimalEnclosedCircle` — Word's circled-number list style (①②③…). Unicode's own
            // "Enclosed Alphanumerics" block only covers 1–20 as single circled-digit code points
            // (U+2460…U+2473); outside that range there is no single glyph to substitute, so it falls
            // back to plain `decimal` rather than fabricating a multi-character approximation.
            "decimalEnclosedCircle" if n >= 1 && n <= 20 => {
                char::from_u32(0x2460 + (n - 1) as u32).map(String::from).unwrap_or_else(|| format!("{}", n))
            }
            // `ganada` (§17.18.59 `ST_NumberFormat`) — Korea's usual outline letter-list format, the
            // rough equivalent of `lowerLetter`'s a/b/c: Word cycles through 14 consonant-vowel
            // syllables. See `ganadaSequence`'s own doc for the algorithm and what is and isn't
            // verified about it.
            "ganada" => Self::ganada_sequence(n),
            _ => format!("{}", n),
        }
    }
}

/// `가나다라마바사아자차카타파하` — the 14 `w:numFmt="ganada"` glyphs, in Word's own cycling
/// order. Verified against a real document's `1.`/`가.`/`나.`/`다.` clause numbering (1–3 only).
// swift: Render/Office/DocxReader.swift:1760-1762
const GANADA_GLYPHS: [char; 14] =
    ['가', '나', '다', '라', '마', '바', '사', '아', '자', '차', '카', '타', '파', '하'];

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1764-1795
    /// `n` (1-based) → its `ganada` glyph. 1...14 is settled; the overflow is a REASONED CHOICE
    /// between three real conventions, recorded here so it isn't re-litigated from scratch.
    ///
    /// ECMA-376 §17.18.59 defines `ganada` in one sentence — *"sequential numbers from the Korean
    /// Ganada format"* — and never states the glyph table or what happens past its end (it is
    /// equally thin for `upperLetter`, which is the same shape of problem). `[MS-DOCX]`'s numFmt
    /// extensions do pin the glyphs (U+AC00, U+B098, U+B2E4 … = 가, 나, 다) and confirm `ganada`
    /// (syllables) is a DIFFERENT format from `chosung` (the 14 bare jamo ㄱㄴㄷ…ㅎ), which this
    /// reader does not implement. Past the 14th item, three genuinely different conventions exist
    /// and no source pins Word itself:
    ///   - repeat the glyph once per completed cycle (15th → 가가, 29th → 가가가) — the algorithm
    ///     Microsoft DOES document, verbatim, for the structurally identical Turkish/Bulgarian/Greek
    ///     fixed alphabets in the same numFmt-extensions note; chosen here as the closest thing to
    ///     evidence about Word's own numbering engine;
    ///   - plain modulo wrap (15th → 가 again) — what LibreOffice actually ships
    ///     (`bRecycleSymbol`), rejected because it renders items 1 and 15 identically, which is
    ///     worse than wrong for a reader;
    ///   - 거/너/더… (swap the vowel) — Korea's own 사무관리규정 시행규칙 for official documents; a
    ///     real convention, but not evidence about Word.
    /// So: 1...14 verified against a real document's 가./나./다. clause numbering; beyond that this
    /// is inference by analogy, deliberately made, and worth re-checking if a real 15-item ganada
    /// level ever turns up.
    ///
    /// `letterSequence` follows the SAME repeat rule for the same reason (it used to do positional
    /// base-26 — z → aa → ab — which matches LibreOffice but not Word); the two are deliberately
    /// consistent rather than one silently disagreeing with the other.
    fn ganada_sequence(n: i32) -> String {
        if n <= 0 {
            return format!("{}", n);
        }
        let index = ((n - 1) % 14) as usize;
        let repeats = ((n - 1) / 14 + 1) as usize;
        GANADA_GLYPHS[index].to_string().repeat(repeats)
    }
}

/// Ideograph numeral digits 0–9 (〇一二三四五六七八九) — CJK Unified Ideographs, the digit
/// glyphs `w:numFmt="ideographDigital"` substitutes in place of each decimal digit.
// swift: Render/Office/DocxReader.swift:1797-1799
const CHINESE_DIGIT_GLYPHS: [char; 10] = ['〇', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
/// Hangul numeral digits 0–9 (영일이삼사오육칠팔구) — the digit glyphs
/// `w:numFmt="koreanDigital"` substitutes in place of each decimal digit.
// swift: Render/Office/DocxReader.swift:1800-1802
const KOREAN_DIGIT_GLYPHS: [char; 10] = ['영', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1804-1816
    /// One decimal digit → one glyph, in order — `nil` for any input a digit-substitution table
    /// can't represent (negative `n`), so the caller's own `??` falls back to plain decimal.
    fn digit_glyphs(n: i32, table: &[char; 10]) -> Option<String> {
        if n < 0 {
            return None;
        }
        if n == 0 {
            return Some(table[0].to_string());
        }
        let mut remainder = n;
        let mut digits: Vec<char> = Vec::new();
        while remainder > 0 {
            digits.push(table[(remainder % 10) as usize]);
            remainder /= 10;
        }
        digits.reverse();
        Some(digits.into_iter().collect())
    }

    // swift: Render/Office/DocxReader.swift:1818-1833
    fn roman_numeral(n: i32) -> String {
        if n <= 0 {
            return format!("{}", n);
        }
        let values: [(i32, &str); 13] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ];
        let mut remainder = n;
        let mut result = String::new();
        for (value, symbol) in values {
            while remainder >= value {
                result.push_str(symbol);
                remainder -= value;
            }
        }
        result
    }

    // swift: Render/Office/DocxReader.swift:1835-1851
    /// `w:numFmt="lowerLetter"`/`"upperLetter"`: 1→a … 26→z, then 27→aa, 28→bb, 29→cc — the letter
    /// REPEATED once per completed cycle, which is what Word draws. Lowercase; `formatNumber`
    /// uppercases it for `upperLetter`.
    ///
    /// This was spreadsheet-style positional base-26 (z → aa → ab → ac), which is what LibreOffice
    /// ships and what a programmer reaches for, but it is not Word: past Z, Word's own Latin lists go
    /// AA, BB, CC. Microsoft documents exactly that repeat rule for the structurally identical
    /// Turkish, Bulgarian and Greek fixed alphabets in its numFmt-extensions note, and `ganada` above
    /// already follows it for Korean — the two schemes now agree instead of one silently disagreeing
    /// with the other. ECMA-376 §17.18.59 says nothing either way, which is why the divergence
    /// survived this long; the correction shows only past the 26th item of a list.
    fn letter_sequence(n: i32) -> String {
        if n <= 0 {
            return format!("{}", n);
        }
        let index = (n - 1) % 26;
        let repeats = ((n - 1) / 26 + 1) as usize;
        let letter = (97u8 + index as u8) as char;
        letter.to_string().repeat(repeats)
    }
}

// swift: Render/Office/DocxReader.swift:1853-1853
// MARK: word/_rels/document.xml.rels — relationship id → target

// swift: Render/Office/DocxReader.swift:1855-1861
pub(crate) struct Relationship {
    /// Embedded: the archive entry path (`"word/media/image1.png"`) `ZipArchive.data(for:)`
    /// can read directly. External: the raw `Target` (a `file:///…` URL) — never a path into
    /// THIS archive, since the bytes live outside it.
    pub(crate) target: String,
    pub(crate) external: bool,
}

// swift: Render/Office/DocxReader.swift:1863-1865
#[derive(Debug, Clone, Default)]
pub struct Relationships {
    pub(crate) by_id: std::collections::HashMap<String, Relationship>,
}

impl Clone for Relationship {
    fn clone(&self) -> Self {
        Relationship { target: self.target.clone(), external: self.external }
    }
}
impl std::fmt::Debug for Relationship {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Relationship").field("target", &self.target).field("external", &self.external).finish()
    }
}

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1867-1879
    /// The relationships PART for a given content part, per OPC convention: `<dir>/_rels/<file>.rels`
    /// sits alongside the `_rels` folder in the SAME directory as the part itself. Every content
    /// part carries its OWN relationship id-space — `word/header1.xml`'s `rId1` can point somewhere
    /// completely different than `word/document.xml`'s `rId1` — so resolving one part's `r:embed`
    /// against another's table silently returns the wrong target or none (header-footer-design.md
    /// §2b). Parameterizing THIS function (mirroring `parseNoteBodies`'s own `part:` argument,
    /// rather than a second mechanism) is what lets a header/footer part resolve through its own
    /// table instead of the body's.
    fn rels_path(part: &str) -> String {
        // swift: Render/Office/DocxReader.swift:1876-1877 — (part as NSString).deletingLastPathComponent / .lastPathComponent
        let (dir, file) = match part.rfind('/') {
            Some(idx) => (&part[..idx], &part[idx + 1..]),
            None => ("", part),
        };
        if dir.is_empty() {
            format!("_rels/{}.rels", file)
        } else {
            format!("{}/_rels/{}.rels", dir, file)
        }
    }

    // swift: Render/Office/DocxReader.swift:1881-1911
    /// Absent from an image-less document exactly like `styles.xml`/`numbering.xml` — falls back
    /// to an empty table, so every `r:embed`/`r:link` lookup below simply misses and the reader
    /// still produces `.image` blocks (marked unresolvable) instead of crashing. Also the normal
    /// case for a footer part: `footer1.xml`/`footer2.xml` commonly have NO `_rels` part at all
    /// (nothing in them ever needs a relationship), which this same fallback handles — absent is
    /// normal, not an error, exactly like a document with no images.
    fn parse_relationships(archive: &ZipArchive, part: &str) -> Relationships {
        let rels_part = Self::rels_path(part);
        if !archive.contains(&rels_part) {
            return Relationships::default();
        }
        let Ok(data) = archive.data_for(&rels_part) else { return Relationships::default() };
        let Ok(root) = Self::build_tree(&data.0) else { return Relationships::default() };
        let mut rels = Relationships::default();
        // A relationship's Target is relative to the PART's own directory, not always "word/" — a
        // header/footer part's rels live in "word/_rels/", and its embedded targets are relative to
        // "word/" exactly like the body's, since Word keeps every part directly under "word/" with
        // no further nesting. Computed from `part`'s own directory rather than hardcoded so this
        // stays correct if that ever changes.
        let part_dir = match part.rfind('/') {
            Some(idx) => &part[..idx],
            None => "",
        };
        for rel in root.children.iter().filter(|r| r.name == "Relationship") {
            let (Some(id), Some(target)) = (
                rel.attributes.get("Id").cloned(),
                rel.attributes.get("Target").cloned(),
            ) else { continue };
            let external = rel.attributes.get("TargetMode").map(String::as_str) == Some("External");
            // An embedded Target is package-relative to the part's own directory ("media/image1.png"
            // under "word/"); an external Target is already a complete `file:///…`/`http://…`
            // reference and must not be rewritten into a path that looks like it lives in this
            // archive.
            let resolved = if external {
                target
            } else if part_dir.is_empty() {
                target
            } else {
                format!("{}/{}", part_dir, target)
            };
            rels.by_id.insert(id, Relationship { target: resolved, external });
        }
        rels
    }
}

// swift: Render/Office/DocxReader.swift:1913-1913
// MARK: Headers/footers — w:sectPr's headerReference/footerReference (header-footer-design.md §2)

impl DocxReader {
    // swift: Render/Office/DocxReader.swift:1915-1974
    /// The body's own trailing `w:sectPr`'s header/footer references (`tag` is
    /// `"w:headerReference"` or `"w:footerReference"`), resolved through `relationships` (the
    /// BODY's own table — `w:headerReference/@r:id` is one of the body's relationship ids, unlike
    /// the CONTENT of the part it points to, which carries its own separate table) to a part path,
    /// each part then read through its OWN relationships (§2b) and the SAME `parseBody` every
    /// other body/note/text-box walk in this reader already uses (§2c — zero new block-parsing
    /// code). A document with more than one section (an inline `w:pPr/w:sectPr` mid-body) can
    /// declare a DIFFERENT header/footer per section; this reader resolves only the body's trailing
    /// section, matching `pageGeometry`'s own documented scope and every real single-section
    /// document this feature was measured against.
    ///
    /// The counter-intuitive rule (§2d) is encoded here, not left for a later consumer to
    /// rediscover: when `w:titlePg` is set and NO `first`-type reference resolves, OOXML does not
    /// mean "use `.defaultPages` on page one" — it means Word created a BLANK header/footer for the
    /// first page, because this is the section's own title page. That is represented EXPLICITLY, as
    /// a `.firstPage` entry with empty `blocks`, rather than by the entry's mere absence — an
    /// absent `.firstPage` entry means "this section never differentiated a first page at all", and
    /// conflating the two would put the running header back on the cover page, the exact bug this
    /// rule exists to prevent. `w:titlePg` present alongside an ACTUAL `first`-type reference reads
    /// that reference's own (possibly non-empty) content instead — footer2.xml in the reference
    /// document is exactly this case: a real reference to a part that happens to hold two empty
    /// paragraphs.
    fn header_footer_entries(
        body: &XMLNode, tag: &str, relationships: &Relationships, archive: &ZipArchive,
        style_info: &StyleInfo, numbering: &NumberingInfo,
    ) -> Vec<OfficeHeaderFooter> {
        let Some(sect_pr) = Self::typeset_section_properties(body) else { return vec![] };
        let title_pg = sect_pr.child("w:titlePg").is_some();
        let mut blocks_by_type: std::collections::HashMap<String, Vec<OfficeBlock>> = std::collections::HashMap::new();
        for reference in sect_pr.children.iter().filter(|r| r.name == tag) {
            let (Some(kind), Some(r_id)) = (
                reference.attributes.get("w:type").cloned(),
                reference.attributes.get("r:id").cloned(),
            ) else { continue };
            let Some(target) = relationships.by_id.get(&r_id) else { continue };
            if target.external || !archive.contains(&target.target) {
                continue;
            }
            let Ok(data) = archive.data_for(&target.target) else { continue };
            let Ok(part_root) = Self::build_tree(&data.0) else { continue };
            // Every part gets its OWN fresh footnote/comment/list-numbering state — a header/footer
            // in real documents carries none of these, and starting fresh (rather than threading the
            // body's own, still-live state into a part the body never actually contains) keeps this
            // read from mutating counters the body's own walk still owns.
            let part_relationships = Self::parse_relationships(archive, &target.target);
            let blocks = Self::parse_body(
                &part_root, style_info, numbering, &part_relationships,
                &NoteNumbering::default(), &CommentRangeTracking::new(std::collections::HashMap::new()),
                &swiftshim::new_ref(ListNumberingState::default()),
            );
            blocks_by_type.insert(kind, blocks);
        }
        let mut entries: Vec<OfficeHeaderFooter> = Vec::new();
        if let Some(blocks) = blocks_by_type.get("default") {
            entries.push(OfficeHeaderFooter { applies_to: HeaderFooterApplicability::DefaultPages, blocks: blocks.clone(), section: None });
        }
        if let Some(blocks) = blocks_by_type.get("even") {
            entries.push(OfficeHeaderFooter { applies_to: HeaderFooterApplicability::EvenPages, blocks: blocks.clone(), section: None });
        }
        if let Some(blocks) = blocks_by_type.get("first") {
            entries.push(OfficeHeaderFooter { applies_to: HeaderFooterApplicability::FirstPage, blocks: blocks.clone(), section: None });
        } else if title_pg {
            entries.push(OfficeHeaderFooter { applies_to: HeaderFooterApplicability::FirstPage, blocks: vec![], section: None });
        }
        entries
    }
}

// -----------------------------------------------------------------------------------------------
// Cross-file / cross-half dependencies this half calls but does not define.
//
// `buildTree` (Swift line 3572) and `parseBody`/`parseBodyChild` (the body-walk entry points that
// turn an `XMLNode` into `[OfficeBlock]`) live in the sibling half (`part_b.rs`, Swift lines
// 1976-3944) since they sit textually after the `// MARK: Images` seam. `cellEdgePadding` and
// `resolveBorder` are `Cell`-border helpers this half calls (`parseStyles`'s table-margin read,
// `parseTableConditionalStyle`'s border resolution) but does not itself define — they too are
// declared later in the source file, inside part_b's range.
//
// Per the phase-A convention (§4/§6): a worker does not stub around a symbol a sibling half
// owns — doing so here would define `DocxReader::build_tree`/`parse_body`/… TWICE once both
// halves exist (a hard compile error, and a real one, not a phase-A-doesn't-care one). Calls to
// `Self::build_tree(...)`, `Self::parse_body(...)`, `Self::parse_body_child(...)`,
// `Self::cell_edge_padding(...)` and `Self::resolve_border(...)` above are left as plain calls by
// Swift name; `part_b.rs` supplies the associated functions they resolve to once both halves are
// unioned by `docx_reader/mod.rs`'s `pub use part_a::*; pub use part_b::*;`.

// -----------------------------------------------------------------------------------------------
// Boundary-line provenance: blank lines, closing braces, and doc-comment lines that sit between
// two declarations' own `// swift: ...` ranges above but were not swept into either one. Every
// range below is boilerplate structure (a brace, a blank separator line, a `// MARK:` line, or a
// paragraph of doc comment already reproduced verbatim on the declaration it documents above) —
// nothing here is unported logic. Listed separately, grouped, rather than widening 97 individual
// `// swift:` comments above, because the boundary itself carries no additional content to name.
// swift: Render/Office/DocxReader.swift:4-11
// swift: Render/Office/DocxReader.swift:91-91
// swift: Render/Office/DocxReader.swift:102-102
// swift: Render/Office/DocxReader.swift:125-153
// swift: Render/Office/DocxReader.swift:165-165
// swift: Render/Office/DocxReader.swift:222-222
// swift: Render/Office/DocxReader.swift:250-250
// swift: Render/Office/DocxReader.swift:252-261
// swift: Render/Office/DocxReader.swift:269-269
// swift: Render/Office/DocxReader.swift:290-290
// swift: Render/Office/DocxReader.swift:325-325
// swift: Render/Office/DocxReader.swift:345-345
// swift: Render/Office/DocxReader.swift:347-347
// swift: Render/Office/DocxReader.swift:370-370
// swift: Render/Office/DocxReader.swift:372-376
// swift: Render/Office/DocxReader.swift:381-381
// swift: Render/Office/DocxReader.swift:418-418
// swift: Render/Office/DocxReader.swift:454-454
// swift: Render/Office/DocxReader.swift:469-469
// swift: Render/Office/DocxReader.swift:471-485
// swift: Render/Office/DocxReader.swift:498-511
// swift: Render/Office/DocxReader.swift:533-533
// swift: Render/Office/DocxReader.swift:612-616
// swift: Render/Office/DocxReader.swift:622-627
// swift: Render/Office/DocxReader.swift:632-638
// swift: Render/Office/DocxReader.swift:647-655
// swift: Render/Office/DocxReader.swift:660-660
// swift: Render/Office/DocxReader.swift:750-750
// swift: Render/Office/DocxReader.swift:778-778
// swift: Render/Office/DocxReader.swift:808-808
// swift: Render/Office/DocxReader.swift:813-813
// swift: Render/Office/DocxReader.swift:838-838
// swift: Render/Office/DocxReader.swift:890-890
// swift: Render/Office/DocxReader.swift:908-908
// swift: Render/Office/DocxReader.swift:918-918
// swift: Render/Office/DocxReader.swift:953-953
// swift: Render/Office/DocxReader.swift:1014-1014
// swift: Render/Office/DocxReader.swift:1040-1040
// swift: Render/Office/DocxReader.swift:1052-1052
// swift: Render/Office/DocxReader.swift:1069-1069
// swift: Render/Office/DocxReader.swift:1108-1108
// swift: Render/Office/DocxReader.swift:1126-1126
// swift: Render/Office/DocxReader.swift:1130-1130
// swift: Render/Office/DocxReader.swift:1134-1134
// swift: Render/Office/DocxReader.swift:1148-1148
// swift: Render/Office/DocxReader.swift:1152-1152
// swift: Render/Office/DocxReader.swift:1156-1156
// swift: Render/Office/DocxReader.swift:1189-1189
// swift: Render/Office/DocxReader.swift:1214-1214
// swift: Render/Office/DocxReader.swift:1218-1218
// swift: Render/Office/DocxReader.swift:1222-1222
// swift: Render/Office/DocxReader.swift:1226-1226
// swift: Render/Office/DocxReader.swift:1230-1230
// swift: Render/Office/DocxReader.swift:1234-1234
// swift: Render/Office/DocxReader.swift:1238-1238
// swift: Render/Office/DocxReader.swift:1242-1242
// swift: Render/Office/DocxReader.swift:1246-1246
// swift: Render/Office/DocxReader.swift:1250-1250
// swift: Render/Office/DocxReader.swift:1254-1254
// swift: Render/Office/DocxReader.swift:1258-1258
// swift: Render/Office/DocxReader.swift:1262-1262
// swift: Render/Office/DocxReader.swift:1290-1290
// swift: Render/Office/DocxReader.swift:1292-1292
// swift: Render/Office/DocxReader.swift:1318-1318
// swift: Render/Office/DocxReader.swift:1363-1363
// swift: Render/Office/DocxReader.swift:1384-1384
// swift: Render/Office/DocxReader.swift:1409-1409
// swift: Render/Office/DocxReader.swift:1441-1441
// swift: Render/Office/DocxReader.swift:1455-1455
// swift: Render/Office/DocxReader.swift:1467-1467
// swift: Render/Office/DocxReader.swift:1487-1487
// swift: Render/Office/DocxReader.swift:1502-1502
// swift: Render/Office/DocxReader.swift:1504-1510
// swift: Render/Office/DocxReader.swift:1529-1533
// swift: Render/Office/DocxReader.swift:1538-1538
// swift: Render/Office/DocxReader.swift:1544-1544
// swift: Render/Office/DocxReader.swift:1592-1592
// swift: Render/Office/DocxReader.swift:1609-1609
// swift: Render/Office/DocxReader.swift:1625-1631
// swift: Render/Office/DocxReader.swift:1634-1634
// swift: Render/Office/DocxReader.swift:1645-1645
// swift: Render/Office/DocxReader.swift:1689-1689
// swift: Render/Office/DocxReader.swift:1721-1721
// swift: Render/Office/DocxReader.swift:1757-1759
// swift: Render/Office/DocxReader.swift:1763-1763
// swift: Render/Office/DocxReader.swift:1796-1796
// swift: Render/Office/DocxReader.swift:1803-1803
// swift: Render/Office/DocxReader.swift:1817-1817
// swift: Render/Office/DocxReader.swift:1834-1834
// swift: Render/Office/DocxReader.swift:1852-1852
// swift: Render/Office/DocxReader.swift:1854-1854
// swift: Render/Office/DocxReader.swift:1862-1862
// swift: Render/Office/DocxReader.swift:1866-1866
// swift: Render/Office/DocxReader.swift:1880-1880
// swift: Render/Office/DocxReader.swift:1912-1912
// swift: Render/Office/DocxReader.swift:1914-1914
// swift: Render/Office/DocxReader.swift:1975-1975

