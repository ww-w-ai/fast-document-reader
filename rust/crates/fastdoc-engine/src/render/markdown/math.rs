//! Step 1 of `s3.md`'s fixed three-layer order: math spans are found in the RAW SOURCE, before
//! comrak ever parses it (invariant 12 — `_`/`^` are markdown syntax and a lone `=` line under a
//! matrix reads as a setext heading, shredding the formula across nodes). This is a port of the
//! shipping Swift scan, `MarkdownRenderer.swift:450-483` (`scanMathSpans`) — same two shapes (a
//! `$$`-fenced block, possibly multi-line; a `$$ ... $$` one-liner), same rule that an
//! unterminated `$$` fence stays plain text. The shipping renderer recognizes NO OTHER math
//! delimiter — there is no inline single-`$` case anywhere in `MarkdownRenderer.swift` — so this
//! producer does not invent one either; `Formula.display` is always `true` for a node this scan
//! produces, since every shape it recognizes is `$$`-delimited (display math in TeX's own
//! convention).
//!
//! What changed from the shipping design, and why: the first draft of this module masked matched
//! spans before parsing. `s3.md`'s Design rejects that — masking would have to preserve byte
//! length AND line structure exactly, or every `source_spans` this pass computes (S3-11) shifts.
//! The shipping renderer does not mask either (`MarkdownRenderer.swift:488-503`,
//! `mathSpan(containing:)`): it parses the whole, unmodified source and, at VISIT time, discards
//! any node whose range lies inside a pre-scanned span, substituting the original tex. `mod.rs`'s
//! `Ctx::math_hit` is that substitution rule for this producer: a scanned span is claimed by the
//! FIRST parsed node entirely inside it (block or inline — `blocks::map_block` and
//! `inline::Builder::walk` both check it before doing anything else), and every later node inside
//! the same span is dropped silently, never descended into — mirroring
//! `emittedMath.insert(span.range.location).inserted`.

use comrak::nodes::Sourcepos;

use super::source_position::LineIndex;

/// One `$$...$$` region found in the raw source: its own UTF-8 byte bounds (exclusive end) and
/// the original TeX, exactly as written — never re-escaped, never re-flowed.
#[derive(Debug, Clone)]
pub(super) struct MathSpan {
    utf8_start: usize,
    utf8_end: usize,
    pub(super) tex: String,
}

/// A per-line walk over the raw text, before any markdown parsing — the literal shape of
/// `scanMathSpans`. Two forms claim a span, checked in this order per line:
///   1. A trimmed line that is exactly `$$` opens a fence; the next trimmed-`$$` line closes it,
///      and everything between (trimmed of surrounding whitespace) is the tex. An opening `$$`
///      with no closing line before EOF stays plain text (never added) — matches `if i + 1 <
///      lineStarts.count`.
///   2. A trimmed line that both starts AND ends with `$$` and has more than 4 characters is a
///      one-liner (`$$ x = 1 $$`); its own inner text (both `$$` stripped) is the tex, UNLESS
///      that inner text itself contains another `$$` (two formulas on one line are left to the
///      text path rather than merged into one bogus render).
///
/// A span whose extracted tex is empty (whitespace only) is dropped, matching
/// `out.filter { !$0.tex.isEmpty }`.
pub(super) fn scan_math_spans(text: &str) -> Vec<MathSpan> {
    let mut lines: Vec<(usize, usize)> = Vec::new();
    let mut line_start = 0usize;
    for (i, b) in text.bytes().enumerate() {
        if b == b'\n' {
            lines.push((line_start, i));
            line_start = i + 1;
        }
    }
    lines.push((line_start, text.len()));

    let mut out = Vec::new();
    let mut open_line: Option<usize> = None;
    for i in 0..lines.len() {
        let (ls, le) = lines[i];
        let trimmed = text[ls..le].trim();
        if let Some(open) = open_line {
            if trimmed != "$$" {
                continue;
            }
            let from = lines[open].0;
            let tex_start = lines[open + 1].0;
            let tex = text[tex_start..ls.max(tex_start)].trim().to_string();
            if !tex.is_empty() {
                out.push(MathSpan { utf8_start: from, utf8_end: le, tex });
            }
            open_line = None;
            continue;
        }
        if trimmed == "$$" {
            if i + 1 < lines.len() {
                open_line = Some(i);
            }
            continue;
        }
        if trimmed.starts_with("$$") && trimmed.ends_with("$$") && trimmed.chars().count() > 4 {
            // ASCII-only prefix/suffix stripped by byte count — safe, `$$` is always 2 bytes.
            let inner = &trimmed[2..trimmed.len() - 2];
            if !inner.contains("$$") {
                let tex = inner.trim().to_string();
                if !tex.is_empty() {
                    out.push(MathSpan { utf8_start: ls, utf8_end: le, tex });
                }
            }
        }
    }
    out
}

/// Whether `sourcepos` lies ENTIRELY inside a scanned span — containment, not overlap, matching
/// `mathSpan(containing:)`'s own contract. Spans are few per document, so a linear scan is not
/// the binary search the shipping renderer uses for its own performance reasons (repeated once
/// per re-render there); this producer runs once per `produce()` call.
pub(super) fn containing(spans: &[MathSpan], line_index: &LineIndex, sourcepos: Sourcepos) -> Option<usize> {
    let (start, end) = line_index.byte_bounds(sourcepos);
    spans.iter().position(|s| start >= s.utf8_start && end <= s.utf8_end)
}
