//! Converts comrak's 1-based line/column `Sourcepos` positions into the wire schema's
//! `RangeSegment::Text` (absolute UTF-8 AND UTF-16 offsets into the whole source).
//!
//! Measured, not assumed (S3 pass A's gate — `tests/comrak_sourcepos_probe.rs`,
//! `tests/markdown_block_producer.rs::source_span_conversion`):
//!   - comrak's `LineColumn::column` is a 1-based UTF-8 BYTE offset within its own line (this is
//!     comrak's own DEFAULT — `parse.sourcepos_chars`, which would switch it to a Unicode
//!     character count, is never set here). A conversion that assumed characters would be wrong
//!     the moment a document contains Korean text or an emoji.
//!   - `Sourcepos.end` is INCLUSIVE: `end.column` is the byte position of the LAST byte of the
//!     last character in the span, not the first byte of that character. Probed with a heading
//!     ending in a 4-byte emoji (`"# hi 🎉"`, 9 bytes on the line): `end.column == 9`, the index of
//!     the emoji's own last byte — never a char boundary on its own, so `utf8_end` is computed as
//!     `line_start + end.column` (one PAST the last byte), not `line_start + end.column - 1`.
//!   - A literal tab occupies exactly ONE byte in the column count, in both leading and mid-line
//!     position — there is no tab-stop expansion reflected in the reported column, even though
//!     comrak internally treats a tab as up to 4 columns for BLOCK-STRUCTURE decisions (list/quote
//!     indentation, whether text is indented enough to become a code block). Probed with a
//!     mid-line tab between Korean and ASCII text (`"안녕\tabc"`, 10 bytes): the following text's
//!     sourcepos advanced by exactly 1 byte for the tab, not 4.
//!
//! | measured | comrak 0.54.0 default |
//! |---|---|
//! | column unit | 1-based UTF-8 byte offset (not Unicode character count) |
//! | tab handling | counted as exactly 1 byte; no tab-stop expansion in the reported column |
//! | `end` semantics | inclusive — points at the last byte of the span's last character |

use comrak::nodes::Sourcepos;

use crate::render::render_tree::RangeSegment;

/// A line-start byte/UTF-16 offset table, built ONCE per document in a single linear pass. Every
/// later conversion resolves a `LineColumn` against this table and then counts UTF-16 code units
/// only from that LINE's own start — never from the document's start — so the cost of any one
/// span is bounded by its own line's length, not the whole document (no O(n^2) re-scan).
pub(super) struct LineIndex {
    line_byte_starts: Vec<usize>,
    line_utf16_starts: Vec<u64>,
}

impl LineIndex {
    pub(super) fn build(text: &str) -> Self {
        let mut line_byte_starts = vec![0usize];
        let mut line_utf16_starts = vec![0u64];
        let mut byte_pos = 0usize;
        let mut utf16_pos = 0u64;
        for ch in text.chars() {
            byte_pos += ch.len_utf8();
            utf16_pos += ch.len_utf16() as u64;
            if ch == '\n' {
                line_byte_starts.push(byte_pos);
                line_utf16_starts.push(utf16_pos);
            }
        }
        Self { line_byte_starts, line_utf16_starts }
    }

    /// The absolute UTF-8/UTF-16 offset pair for a 1-based `(line, column)` pair, where `column`
    /// is comrak's own convention: the byte immediately at that position is INCLUDED (used for
    /// both a span's inclusive start and, by the caller, one past its inclusive end).
    fn offsets(&self, text: &str, line: usize, column: usize) -> (u64, u64) {
        let line_byte_start = self.line_byte_starts[line - 1];
        let line_utf16_start = self.line_utf16_starts[line - 1];
        let byte_offset = line_byte_start + column;
        let utf16_within_line = text[line_byte_start..byte_offset].encode_utf16().count() as u64;
        (byte_offset as u64, line_utf16_start + utf16_within_line)
    }

    /// The UTF-8 byte range `[start, end)` a comrak `Sourcepos` covers, with no UTF-16
    /// conversion — `math::containing`'s containment check (is this node entirely inside a
    /// scanned math span?) needs only this, and paying for a UTF-16 count it never uses would be
    /// waste. Same start/end arithmetic as `segment` below: `column` is one-past-N-bytes into its
    /// line (see this module's doc comment), so the inclusive start needs `column - 1` and the
    /// inclusive end needs `column` unchanged — exclusive end.
    pub(super) fn byte_bounds(&self, sourcepos: Sourcepos) -> (usize, usize) {
        let start = self.line_byte_starts[sourcepos.start.line - 1] + sourcepos.start.column - 1;
        let end = self.line_byte_starts[sourcepos.end.line - 1] + sourcepos.end.column;
        (start, end)
    }

    /// One `RangeSegment::Text` covering a comrak block's whole `Sourcepos`, exclusive end.
    pub(super) fn segment(&self, text: &str, sourcepos: Sourcepos) -> RangeSegment {
        // `offsets` treats `column` as "one past this many bytes into the line" (see above), so
        // the inclusive start needs `column - 1` and the inclusive end needs `column` unchanged —
        // that is exactly the exclusive end the wire schema wants.
        let (utf8_start, utf16_start) =
            self.offsets(text, sourcepos.start.line, sourcepos.start.column - 1);
        let (utf8_end, utf16_end) = self.offsets(text, sourcepos.end.line, sourcepos.end.column);
        RangeSegment::Text { utf8_start, utf8_end, utf16_start, utf16_end }
    }
}
