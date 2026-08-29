//! swift: markdown/HTML-attribute pattern matching in MarkdownRenderer.swift and
//! OfficeMarkdownSerializer.swift — `NSRegularExpression(pattern:options:)`,
//! `.firstMatch(in:range:)`, `.enumerateMatches(in:range:)`, `.range(at:)`, plus one
//! `NSDataDetector` link scan.
//!
//! Backed by the `regex` crate, the same way `markdown_package` is backed by comrak: the
//! transliteration ports the CALL SITES faithfully, and the Foundation type underneath them is
//! a stand-in built on a pure-Rust library rather than a second hand-written engine.
//!
//! ## Every range here is UTF-16, and that is not incidental
//!
//! `NSAttributedString` is indexed in UTF-16 (`attributed_string.rs` mirrors that exactly), and
//! every range this module hands back is fed straight to `addAttribute`. The `regex` crate works
//! in BYTES. So each call builds one UTF-16-unit → byte-offset table for the subject and converts
//! at both ends. Reporting byte offsets instead is correct for ASCII and silently wrong for a
//! Korean document — the exact class of defect this whole reader keeps paying for.
//!
//! ## Two dialect differences from ICU, handled explicitly
//!
//! 1. **Lookbehind.** ICU has it; the `regex` crate deliberately does not (it would cost the
//!    linear-time guarantee). The one lookbehind in this codebase is a LEADING one
//!    (`(?<=\s|^)…`), so `new` rewrites it into a consuming prefix group and reports the
//!    remainder — see `Compiled::translate`. A lookbehind anywhere else is refused, loudly, at
//!    compile time rather than silently matching something different.
//! 2. **`NSDataDetector`.** There is no Rust equivalent of Apple's data detectors, so
//!    `linkDetector` is a documented approximation; its own doc comment says what it covers and
//!    what it does not.

use crate::foundation::NSRange;

/// swift: NSRegularExpression.Options
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NSRegularExpressionOptions(pub u32);

impl NSRegularExpressionOptions {
    pub const caseInsensitive: NSRegularExpressionOptions = NSRegularExpressionOptions(1);

    fn is_case_insensitive(self) -> bool {
        self.0 & 1 != 0
    }
}

/// UTF-16 unit index → byte offset in the subject, plus the total byte length.
///
/// Built once per call rather than per match: `autolink` runs this over a whole document, and a
/// per-match rebuild is the shape of cost the Swift original's own comment measures and rejects.
struct Utf16Index {
    /// One byte offset per UTF-16 unit; a surrogate PAIR's two units both point at the char start.
    byte_of_unit: Vec<usize>,
    total_bytes: usize,
}

impl Utf16Index {
    fn build(s: &str) -> Self {
        let mut byte_of_unit = Vec::with_capacity(s.len());
        for (byte, ch) in s.char_indices() {
            for _ in 0..ch.len_utf16() {
                byte_of_unit.push(byte);
            }
        }
        Self { byte_of_unit, total_bytes: s.len() }
    }

    fn units(&self) -> usize {
        self.byte_of_unit.len()
    }

    fn byte(&self, unit: usize) -> usize {
        self.byte_of_unit.get(unit).copied().unwrap_or(self.total_bytes)
    }

    /// Byte offset → UTF-16 unit. A match boundary always lands on a char boundary (the regex
    /// crate guarantees it), so the first unit whose byte offset is >= `byte` is the answer.
    fn unit(&self, byte: usize) -> usize {
        match self.byte_of_unit.binary_search(&byte) {
            // A surrogate pair repeats its byte offset; take the FIRST such unit.
            Ok(mut i) => {
                while i > 0 && self.byte_of_unit[i - 1] == byte {
                    i -= 1;
                }
                i
            }
            Err(i) => i,
        }
    }
}

/// swift: NSRegularExpression
#[derive(Debug, Clone)]
pub struct NSRegularExpression {
    pub pattern: String,
    pub options: NSRegularExpressionOptions,
    inner: ::regex::Regex,
    /// How many capture groups this module ADDED in front of the author's own, so `range(at:)`
    /// keeps answering with the author's numbering (1 when a leading lookbehind was rewritten).
    group_offset: usize,
}

impl NSRegularExpression {
    pub fn new(
        pattern: &str,
        options: NSRegularExpressionOptions,
    ) -> Result<Self, crate::foundation::EngineError> {
        let (translated, group_offset) = Self::translate(pattern)?;
        let inner = ::regex::RegexBuilder::new(&translated)
            .case_insensitive(options.is_case_insensitive())
            .build()
            .map_err(|error| {
                crate::foundation::EngineError::Message(format!(
                    "NSRegularExpression: cannot compile {pattern:?}: {error}"
                ))
            })?;
        Ok(Self { pattern: pattern.to_string(), options, inner, group_offset })
    }

    /// Rewrite a LEADING `(?<=A|B)` into a consuming prefix, wrapping the rest in a capture group
    /// this module then reports as the match. `(?<=\s|^)REST` becomes `(?:\s|^)(REST)`, which
    /// matches the same places: the alternatives are single characters or the `^` anchor, so the
    /// only difference is that the prefix is consumed — and nothing in this codebase's patterns
    /// can start inside a match that just ended, because every one of them excludes whitespace.
    ///
    /// A lookbehind anywhere ELSE is an error rather than a silent mismatch.
    fn translate(pattern: &str) -> Result<(String, usize), crate::foundation::EngineError> {
        const OPEN: &str = "(?<=";
        if let Some(rest) = pattern.strip_prefix(OPEN) {
            let end = Self::closing_paren(rest).ok_or_else(|| {
                crate::foundation::EngineError::Message(format!(
                    "NSRegularExpression: unterminated lookbehind in {pattern:?}"
                ))
            })?;
            let inner = &rest[..end];
            let tail = &rest[end + 1..];
            if tail.contains(OPEN) {
                return Err(crate::foundation::EngineError::Message(format!(
                    "NSRegularExpression: only ONE leading lookbehind is supported, {pattern:?} has more"
                )));
            }
            return Ok((format!("(?:{inner})({tail})"), 1));
        }
        if pattern.contains(OPEN) {
            return Err(crate::foundation::EngineError::Message(format!(
                "NSRegularExpression: a lookbehind is only supported at the START of a pattern, \
                 {pattern:?} has one elsewhere"
            )));
        }
        Ok((pattern.to_string(), 0))
    }

    /// Index of the `)` closing the group `s` is the inside of, honouring nesting and `\)`.
    fn closing_paren(s: &str) -> Option<usize> {
        let bytes = s.as_bytes();
        let mut depth = 0usize;
        let mut i = 0usize;
        while i < bytes.len() {
            match bytes[i] {
                b'\\' => i += 1,
                b'(' => depth += 1,
                b')' if depth == 0 => return Some(i),
                b')' => depth -= 1,
                _ => {}
            }
            i += 1;
        }
        None
    }

    pub fn firstMatch(&self, in_string: &str, range: NSRange) -> Option<NSTextCheckingResult> {
        self.enumerated(in_string, range).into_iter().next()
    }

    pub fn matches(&self, in_string: &str, range: NSRange) -> Vec<NSTextCheckingResult> {
        self.enumerated(in_string, range)
    }

    /// swift: NSRegularExpression.enumerateMatches(in:options:range:using:) — the block form. The
    /// callers here never stop early, so the closure takes the match alone and there is no
    /// `stop` out-parameter to mirror.
    pub fn enumerateMatches(
        &self,
        in_string: &str,
        range: NSRange,
        mut body: impl FnMut(&NSTextCheckingResult),
    ) {
        for m in self.enumerated(in_string, range) {
            body(&m);
        }
    }

    pub fn numberOfMatches(&self, in_string: &str, range: NSRange) -> usize {
        self.enumerated(in_string, range).len()
    }

    fn enumerated(&self, in_string: &str, range: NSRange) -> Vec<NSTextCheckingResult> {
        let index = Utf16Index::build(in_string);
        let lo = index.byte(range.location.min(index.units()));
        let hi = index.byte(range.maxRange().min(index.units()));
        if lo > hi {
            return Vec::new();
        }
        // `^` must mean "start of the SEARCHED region", the way an NSRange-scoped ICU scan reads
        // it — so the subject is the slice, and every offset is shifted back by `lo`.
        let subject = &in_string[lo..hi];
        self.inner
            .captures_iter(subject)
            .map(|caps| {
                let whole = caps
                    .get(self.group_offset)
                    .expect("group 0 (or the rewritten prefix's group) always participates");
                let group_ranges = (0..caps.len().saturating_sub(self.group_offset))
                    .map(|g| {
                        caps.get(g + self.group_offset).map(|m| {
                            NSRange::new(
                                index.unit(lo + m.start()),
                                index.unit(lo + m.end()) - index.unit(lo + m.start()),
                            )
                        })
                    })
                    .collect();
                NSTextCheckingResult {
                    range: NSRange::new(
                        index.unit(lo + whole.start()),
                        index.unit(lo + whole.end()) - index.unit(lo + whole.start()),
                    ),
                    group_ranges,
                    url: None,
                }
            })
            .collect()
    }
}

/// swift: NSTextCheckingResult
#[derive(Debug, Clone)]
pub struct NSTextCheckingResult {
    pub range: NSRange,
    group_ranges: Vec<Option<NSRange>>,
    /// swift: NSTextCheckingResult.url — set by `NSDataDetector` only. A plain regular expression
    /// leaves it `None`, exactly as Foundation does.
    url: Option<String>,
}

impl NSTextCheckingResult {
    pub fn range(&self, at: usize) -> NSRange {
        self.group_ranges
            .get(at)
            .and_then(|r| *r)
            .unwrap_or_else(NSRange::notFound)
    }

    pub fn url(&self) -> Option<&str> {
        self.url.as_deref()
    }
}

/// swift: NSDataDetector — a specialised `NSRegularExpression` subclass (link/date detection);
/// the in-scope call site uses it only for links, so it is modeled as its own thin type rather
/// than inheriting `NSRegularExpression`'s fields.
///
/// **This is an approximation of Apple's detector, and the difference is worth stating.** It
/// covers the three forms the reader's own documents actually contain:
///
/// | form | link value |
/// |---|---|
/// | an explicit scheme (`https://…`, `http://`, `ftp://`, `file://`, `mailto:`) | as written |
/// | a `www.`-prefixed host | `https://` prepended, as the detector does |
/// | a bare email address | `mailto:` prepended, as the detector does |
///
/// It deliberately does NOT match a bare `example.com` with no scheme and no `www.`. Apple's
/// detector does, against a TLD list it ships; guessing at that list here would autolink ordinary
/// prose ("i.e", "etc.So") and there is no honest way to carry the list without shipping it.
/// Trailing sentence punctuation is trimmed, which is what the detector does too.
#[derive(Debug, Clone)]
pub struct NSDataDetector {
    inner: ::regex::Regex,
}

impl NSDataDetector {
    pub fn linkDetector() -> Result<Self, crate::foundation::EngineError> {
        const PATTERN: &str = concat!(
            r#"(?:[A-Za-z][A-Za-z0-9+.\-]*://[^\s<>()\[\]{}"]+)"#,
            r#"|(?:mailto:[^\s<>()\[\]{}"]+)"#,
            r#"|(?:www\.[^\s<>()\[\]{}"]+)"#,
            r#"|(?:[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})"#,
        );
        let inner = ::regex::Regex::new(PATTERN).map_err(|error| {
            crate::foundation::EngineError::Message(format!("NSDataDetector: {error}"))
        })?;
        Ok(Self { inner })
    }

    pub fn firstMatch(&self, in_string: &str, range: NSRange) -> Option<NSTextCheckingResult> {
        self.enumerated(in_string, range).into_iter().next()
    }

    pub fn matches(&self, in_string: &str, range: NSRange) -> Vec<NSTextCheckingResult> {
        self.enumerated(in_string, range)
    }

    pub fn enumerateMatches(
        &self,
        in_string: &str,
        range: NSRange,
        mut body: impl FnMut(&NSTextCheckingResult),
    ) {
        for m in self.enumerated(in_string, range) {
            body(&m);
        }
    }

    fn enumerated(&self, in_string: &str, range: NSRange) -> Vec<NSTextCheckingResult> {
        let index = Utf16Index::build(in_string);
        let lo = index.byte(range.location.min(index.units()));
        let hi = index.byte(range.maxRange().min(index.units()));
        if lo > hi {
            return Vec::new();
        }
        let subject = &in_string[lo..hi];
        self.inner
            .find_iter(subject)
            .filter_map(|m| {
                let text = Self::trim_trailing(m.as_str());
                if text.is_empty() {
                    return None;
                }
                let start = index.unit(lo + m.start());
                let end = index.unit(lo + m.start() + text.len());
                Some(NSTextCheckingResult {
                    range: NSRange::new(start, end - start),
                    group_ranges: vec![Some(NSRange::new(start, end - start))],
                    url: Some(Self::url_for(text)),
                })
            })
            .collect()
    }

    /// A URL at the end of a sentence swallows the full stop; so does a parenthesised one swallow
    /// the closing bracket. Apple's detector trims both.
    fn trim_trailing(text: &str) -> &str {
        let mut end = text.len();
        while end > 0 {
            let last = text[..end].chars().next_back().unwrap();
            let unbalanced_close = last == ')'
                && text[..end].matches(')').count() > text[..end].matches('(').count();
            if ".,;:!?'\"".contains(last) || unbalanced_close {
                end -= last.len_utf8();
            } else {
                break;
            }
        }
        &text[..end]
    }

    fn url_for(text: &str) -> String {
        if text.contains("://") || text.starts_with("mailto:") {
            text.to_string()
        } else if text.starts_with("www.") {
            format!("https://{text}")
        } else {
            format!("mailto:{text}")
        }
    }
}
