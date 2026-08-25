//! Byte offset -> UTF-8/UTF-16 `RangeSegment` conversion for the plain-text producer.
//!
//! Simpler than the markdown pass's `LineIndex` (`render/markdown/source_position.rs`): a
//! plain-text line's byte span is computed directly by [`super::split_lines`] rather than
//! resolved from an external parser's 1-based line/column pair, so there is no line table to
//! build. What still needs care is the UTF-16 half — the wire schema's `RangeSegment::Text`
//! carries both units (S3-11), and a plain-text file can contain Korean or emoji just as easily
//! as a markdown one. [`Utf16Cursor`] converts a monotonically increasing sequence of byte
//! offsets to UTF-16 offsets in ONE linear pass: `split_lines` already produces line boundaries
//! in increasing byte order, so each conversion only rescans the bytes since the cursor's last
//! position, never the document's start (no O(n^2), same reasoning as the markdown `LineIndex`
//! doc comment).

/// Converts a non-decreasing sequence of byte offsets into UTF-16 offsets, one linear pass over
/// `text`. Every call to [`advance_to`](Self::advance_to) must pass a byte offset `>=` the
/// previous call's (this producer only ever asks for line starts and line-content ends, walked
/// in source order, so that always holds).
pub(super) struct Utf16Cursor<'a> {
    text: &'a str,
    byte: usize,
    utf16: u64,
}

impl<'a> Utf16Cursor<'a> {
    pub(super) fn new(text: &'a str) -> Self {
        Self { text, byte: 0, utf16: 0 }
    }

    /// The UTF-16 offset at `byte_offset`. `byte_offset` must be a UTF-8 char boundary — every
    /// caller in this module gets one from [`super::split_lines`], which only ever cuts at an
    /// ASCII line-terminator byte, and an ASCII byte is never a continuation byte of a
    /// multi-byte UTF-8 sequence, so it is always a char boundary.
    pub(super) fn advance_to(&mut self, byte_offset: usize) -> u64 {
        debug_assert!(byte_offset >= self.byte, "byte offsets must be requested in order");
        self.utf16 += self.text[self.byte..byte_offset].encode_utf16().count() as u64;
        self.byte = byte_offset;
        self.utf16
    }
}
