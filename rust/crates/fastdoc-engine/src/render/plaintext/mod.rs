//! Plain-text (`.txt`/`.csv`/`.log`/…) -> canonical `RenderTree` producer (S3-07).
//!
//! Bytes and a source name become the SAME `ValidatedRenderTree` every other producer builds,
//! through the same `RenderTreeBuilder` door the markdown pass uses (`render/markdown/mod.rs`'s
//! `produce`, read but not touched by this module). Nothing here is parsed: a plain-text file
//! that happens to start a line with `#`, `*` or `|` must not turn into a heading, a list or a
//! table — that is this producer's whole reason to exist, not an incidental property (see
//! `heading_punctuation_stays_plain_text` etc. in `tests/plaintext_producer.rs`).
//!
//! **Paragraph boundary = line, not blank-line-delimited prose.** This pass matches the shipping
//! `Sources/FastDocReader/Render/PlainTextRenderer.swift`, the ONLY existing renderer for this
//! document family, rather than inventing a markdown-style "blank line separates paragraphs"
//! rule: `PlainTextRenderer.swift:39-66`'s `render(_:theme:)` walks the source with
//! `NSString.getLineStart(_:end:contentsEnd:for:)` and tags **every** line — blank ones included
//! — as its own block (`ps.length > 0` at line 56 only guards a zero-length terminator-less tail,
//! not blank lines, which still have their terminator). Its own doc comment states this
//! explicitly: "Counting blank lines as blocks is what makes this a TEXT file rather than a
//! prose document... in markdown a blank line separates paragraphs, but here it is simply an
//! empty line the author put there, and the app has no business preserving or reproducing it as
//! structure." So this producer emits one `paragraph` node per source line (blank lines
//! included), each holding exactly one `textRun` child whose text is that line's content with
//! its terminator stripped — never a `lineBreak` node merging several lines into one paragraph,
//! because the Swift renderer never merges lines either.
//!
//! **Encoding**: this pass draws the line the SPRINT ASKED for, no further. `TextEncodingDetector.swift`
//! sniffs a file's real encoding (BOM, legacy code pages, heuristics); porting that logic is
//! explicitly out of scope here. This producer only tells UTF-8 apart from not-UTF-8: valid
//! UTF-8 is accepted, anything else is a typed [`PlainTextError::InvalidUtf8`] naming the first
//! bad byte's offset — never a silent lossy conversion, which would substitute characters the
//! source never contained.

mod source_position;

use sha2::{Digest, Sha256};

use crate::render::render_tree::{
    CharacterStyle, DecodeError, Direction, DocumentFormat, Empty, NodePayload,
    Paragraph as WireParagraph, ParagraphStyle, RenderDocumentDraft, RenderNodeDraft,
    RenderSourceDraft, RenderTreeBuilder, SourceKind, SourceSpan, SpanPurpose, TextRun as WireTextRun,
    ValidatedRenderTree,
};

use source_position::Utf16Cursor;

/// What this producer refuses, and why. Never a silent drop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlainTextError {
    /// The source bytes are not valid UTF-8. `valid_up_to` is the byte offset of the first byte
    /// that could not be decoded (`std::str::Utf8Error::valid_up_to`) — encoding detection
    /// (`TextEncodingDetector.swift`) is the host's job (module doc, "Encoding"); this producer
    /// only reports where UTF-8 decoding broke rather than guessing an encoding to recover with.
    InvalidUtf8 { valid_up_to: usize },
    /// The tree this producer built failed canonical validation — should never happen for a
    /// correctly implemented producer, but never swallowed.
    Canonicalization(DecodeError),
}

/// One source line's byte span: `[line_start, contents_end)` is the line's text with its
/// terminator stripped, `[line_start, line_end)` is the line INCLUDING whatever terminator
/// follows it (empty at end-of-file if the file's last line has none).
struct LineSpan {
    line_start: usize,
    contents_end: usize,
    line_end: usize,
}

/// Splits `text` into lines the same way `NSString.getLineStart` does for
/// `PlainTextRenderer.swift`: `\n`, `\r\n` and `\r` all end a line, and a final unterminated
/// line is still a line. A file ending in a terminator does NOT get a trailing empty line after
/// it — the loop below stops the moment `line_start` reaches the end of the text, exactly the
/// `while lineStart < ns.length` guard `PlainTextRenderer.swift:41` uses.
///
/// Scans raw bytes rather than `char_indices()`: `\n` (0x0A) and `\r` (0x0D) are ASCII, and an
/// ASCII byte is never a continuation byte of a multi-byte UTF-8 sequence, so every offset this
/// function returns is guaranteed to land on a UTF-8 char boundary.
fn split_lines(text: &str) -> Vec<LineSpan> {
    let bytes = text.as_bytes();
    let len = bytes.len();
    let mut out = Vec::new();
    let mut line_start = 0usize;
    while line_start < len {
        let mut i = line_start;
        while i < len && bytes[i] != b'\n' && bytes[i] != b'\r' {
            i += 1;
        }
        let contents_end = i;
        let line_end = if i >= len {
            i
        } else if bytes[i] == b'\r' && i + 1 < len && bytes[i + 1] == b'\n' {
            i + 2
        } else {
            i + 1
        };
        out.push(LineSpan { line_start, contents_end, line_end });
        line_start = line_end;
    }
    out
}

/// Bytes and a source name to a validated plain-text `RenderTree`.
pub fn produce(bytes: &[u8], source_name: &str) -> Result<ValidatedRenderTree, PlainTextError> {
    let text = std::str::from_utf8(bytes)
        .map_err(|error| PlainTextError::InvalidUtf8 { valid_up_to: error.valid_up_to() })?;

    let mut nodes = Vec::new();
    let mut next_id = 1u64;
    let mut new_id = || {
        let id = next_id;
        next_id += 1;
        id
    };

    let doc_id = new_id();
    let mut utf16 = Utf16Cursor::new(text);
    let mut paragraph_ids = Vec::new();
    for line in split_lines(text) {
        let paragraph_id = new_id();
        let run_id = new_id();
        let line_text = text[line.line_start..line.contents_end].to_string();
        let utf16_start = utf16.advance_to(line.line_start);
        let utf16_end = utf16.advance_to(line.contents_end);
        nodes.push(RenderNodeDraft {
            id: run_id,
            parent_id: Some(paragraph_id),
            children: vec![],
            source_spans: vec![],
            edit: None,
            payload: NodePayload::TextRun(WireTextRun {
                text: line_text,
                style: CharacterStyle::default(),
                direction: None as Option<Direction>,
                link: None,
                bookmark_ids: vec![],
                comment_ids: vec![],
                field: None,
                footnote_reference_number: None,
                form_control: None,
                page_number_field: None,
                column_flow: None,
            }),
        });
        nodes.push(RenderNodeDraft {
            id: paragraph_id,
            parent_id: Some(doc_id),
            children: vec![run_id],
            source_spans: vec![SourceSpan {
                source_id: 1,
                purpose: SpanPurpose::Provenance,
                affinity: crate::render::render_tree::Affinity::Exact,
                segments: vec![crate::render::render_tree::RangeSegment::Text {
                    utf8_start: line.line_start as u64,
                    utf8_end: line.contents_end as u64,
                    utf16_start,
                    utf16_end,
                }],
            }],
            edit: None,
            payload: NodePayload::Paragraph(WireParagraph {
                style: ParagraphStyle::default(),
                tab_stops: vec![],
                pagination: Default::default(),
            }),
        });
        paragraph_ids.push(paragraph_id);
        // Advance the cursor past the terminator too so the NEXT line's offsets are requested
        // in order, even though the terminator itself is not part of any span.
        utf16.advance_to(line.line_end);
    }
    nodes.push(RenderNodeDraft {
        id: doc_id,
        parent_id: None,
        children: paragraph_ids,
        source_spans: vec![],
        edit: None,
        payload: NodePayload::Document(Empty {}),
    });

    let document = RenderDocumentDraft {
        format: DocumentFormat::PlainText,
        editable: false,
        root_node_id: doc_id,
        source_ids: vec![],
        default_locale: None,
        declared_faces: std::collections::BTreeMap::new(),
        // 0.0 = the source stated no body default. Markdown and plain text carry no document-level
        // font declaration at all — the reader's own theme decides — so there is nothing to carry
        // and zero hides nothing (see `wire::Document`'s own field doc).
        default_body_font_size: 0.0,
        // No `Section` node exists anywhere in this tree (this producer's `Document` parents
        // blocks directly) — 0 is "not applicable", the same posture `default_body_font_size`
        // above takes for a format that carries no such fact at all.
        declared_section_count: 0,
        // This producer builds no `Section` node at all, so there is no document sheet or
        // line grid to record -- `None` here is "the source stated none", not a default.
        document_paper: None,
        line_grid_points: None,
    };
    let mut builder = RenderTreeBuilder::new("fastdoc-plaintext-producer", document);

    let sha256 = format!("{:x}", Sha256::digest(bytes));
    builder.add_source(RenderSourceDraft {
        id: 1,
        kind: SourceKind::DecodedText,
        name: source_name.to_string(),
        encoding: Some("UTF-8".to_string()),
        revision: "1".to_string(),
        sha256,
        byte_length: Some(bytes.len() as u64),
        utf8_length: Some(text.len() as u64),
        utf16_length: Some(text.encode_utf16().count() as u64),
        editable: false,
        text_content: Some(text.to_string()),
    });
    for node in nodes {
        builder.add_node(node);
    }
    builder.build().map_err(PlainTextError::Canonicalization)
}
