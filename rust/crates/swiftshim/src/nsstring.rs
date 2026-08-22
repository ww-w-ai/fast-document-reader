//! swift: convention §3 — `String` UTF-16 indexing and `NSString` both become
//! `swiftshim::SwiftString`. The reader casts `source as NSString` specifically to get UTF-16
//! random access cheaply (MarkdownRenderer.swift:172-179 explains why); this shim keeps that
//! shape (a UTF-16 code-unit-indexed string with `.length`, `substring`, and path helpers)
//! without deciding, yet, how Rust should represent it — see `SwiftString` for the same
//! reasoning spelled out once instead of on every call site.
//!
//! Stored as a UTF-8 `String` (the natural Rust representation) with UTF-16 code-unit indices
//! computed on demand for the handful of methods Cocoa's `NSString`/`NSRange` contract actually
//! needs (`length`, `substring`, `characterAt`, `getLineStart`). `Deref<Target = str>` is
//! implemented so every ordinary Rust string method (`is_empty`, `chars`, `starts_with`,
//! `ends_with`, `strip_prefix`, `trim`, `to_uppercase`, …) resolves through autoderef exactly as
//! it would on a plain `String` — those are Rust-native operations the transliterated engine
//! calls on this type where the original Swift code used `String`'s own value semantics, not an
//! `NSString` cast, so per convention §3 they need no Apple name to mirror.

use crate::foundation::NSRange;

/// swift: `NSString` — and, per convention §3, also Swift's own `String` wherever the call site
/// indexes it by UTF-16 offset (`.utf16`, `NSRange`-based substring). UTF-16 code-unit offsets
/// are computed from the stored UTF-8 text on demand so `length`/`substring(with:)` match
/// Cocoa's counting exactly instead of Rust's UTF-8 byte counting, which is the whole reason the
/// app pays for this cast (MarkdownRenderer.swift 172-179).
#[derive(Debug, Clone, Default, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize, serde::Deserialize)]
/// `transparent` so text crosses a boundary AS text. Without it every string in a document is
/// wrapped in an object naming this struct's private field — an implementation detail no host
/// should have to know, let alone match.
#[serde(transparent)]
pub struct SwiftString {
    s: String,
}

impl SwiftString {
    pub fn new(s: &str) -> Self {
        Self { s: s.to_string() }
    }

    /// swift: `.utf16` — this string's UTF-16 code units, computed from the stored UTF-8 text.
    /// Every method below that takes or returns a UTF-16 offset goes through this.
    fn units(&self) -> Vec<u16> {
        self.s.encode_utf16().collect()
    }

    pub fn length(&self) -> usize {
        self.s.encode_utf16().count()
    }

    pub fn substring(&self, range: NSRange) -> String {
        let units = self.units();
        String::from_utf16_lossy(&units[range.location..range.maxRange()])
    }

    pub fn characterAt(&self, index: usize) -> u16 {
        self.units()[index]
    }

    /// swift: a plain string reference — this crate's Rust-only escape hatch onto `&str` (there
    /// is no Apple member to mirror; `NSString` has no `as_str`-shaped accessor of its own).
    pub fn as_str(&self) -> &str {
        &self.s
    }

    /// swift: `+=` / `.append(_:)` on the `String` this type stands in for (convention §3) —
    /// Rust-only, since Swift spells this operator syntax, not a named member.
    pub fn push_str(&mut self, other: &str) {
        self.s.push_str(other);
    }

    /// swift: .deletingLastPathComponent
    pub fn deletingLastPathComponent(&self) -> SwiftString {
        let trimmed = self.s.trim_end_matches('/');
        match trimmed.rfind('/') {
            Some(i) => SwiftString::new(&trimmed[..i]),
            None => SwiftString::new(""),
        }
    }

    /// swift: .lastPathComponent
    pub fn lastPathComponent(&self) -> SwiftString {
        let trimmed = self.s.trim_end_matches('/');
        match trimmed.rfind('/') {
            Some(i) => SwiftString::new(&trimmed[i + 1..]),
            None => SwiftString::new(trimmed),
        }
    }

    /// swift: NSString.getLineStart(_:end:contentsEnd:for:) — a named method, so it keeps Swift
    /// spelling. `end` is where the NEXT line begins; `contentsEnd` stops before this line's
    /// terminator, which is what lets a reader render a file byte-for-byte including its last
    /// newline. UTF-16 line scanning is not a CoreText/AppKit-bound call, so given a real body
    /// rather than deferred. Terminator recognition matches this port's own line-boundary
    /// convention elsewhere (CodeHighlighter's comment/line scan checks only LF), with CR and
    /// CRLF also folded to one boundary so a Windows-authored text file (PlainTextRenderer's own
    /// target) doesn't render its carriage returns as empty lines of their own.
    pub fn getLineStart(
        &self,
        start: Option<&mut usize>,
        end: &mut usize,
        contents_end: &mut usize,
        for_range: NSRange,
    ) {
        let units = self.units();
        let n = units.len();
        // Scan backward from the range's start to the beginning of its line.
        let mut s = for_range.location.min(n);
        while s > 0 && units[s - 1] != 10 && units[s - 1] != 13 {
            s -= 1;
        }
        if let Some(out) = start {
            *out = s;
        }
        // Scan forward from the range's end to this line's terminator.
        let mut c = for_range.maxRange().min(n);
        while c < n && units[c] != 10 && units[c] != 13 {
            c += 1;
        }
        *contents_end = c;
        let mut e = c;
        if e < n {
            if units[e] == 13 {
                e += 1;
                if e < n && units[e] == 10 {
                    e += 1;
                }
            } else {
                e += 1; // LF
            }
        }
        *end = e;
    }

    /// swift: `.range(of:options:range:)` — a plain (not regex) substring search restricted to
    /// `range`, returned as Cocoa spells "not found": `NSRange(location: NSNotFound, length: 0)`
    /// rather than `Option`, matching the in-scope call site's own `.location == NSNotFound` test.
    pub fn range_of(&self, needle: &str, range: NSRange) -> NSRange {
        let units = self.units();
        let lo = range.location.min(units.len());
        let hi = range.maxRange().min(units.len());
        let hay = String::from_utf16_lossy(&units[lo..hi]);
        match hay.find(needle) {
            // `hay.find` is a UTF-8 byte offset; re-measure everything before the match in UTF-16
            // so the returned range stays in Cocoa's own counting.
            Some(byte_offset) => {
                let prefix_units = hay[..byte_offset].encode_utf16().count();
                let match_units = needle.encode_utf16().count();
                NSRange::new(lo + prefix_units, match_units)
            }
            None => NSRange::notFound(),
        }
    }

    /// swift: `String.enumerateSubstrings(in:options: .byLines) { substring, substringRange,
    /// enclosingRange, stop in ... }` — the `.byLines` option is baked into the name (per
    /// convention §3's "Rust-only constructor" reasoning extended to specialised wrappers: the
    /// general four-argument, option-set-driven enumerator has no other caller in scope, so it is
    /// not built). `range` and each yielded line range are UTF-16 (`NSRange`) throughout, matching
    /// every other range in this shim.
    pub fn enumerate_substrings_by_lines(
        &self,
        range: NSRange,
        mut body: impl FnMut(NSRange, &mut bool),
    ) {
        let units = self.units();
        let limit = range.maxRange().min(units.len());
        let mut pos = range.location.min(limit);
        let mut stop = false;
        while pos < limit && !stop {
            let mut line_end = pos;
            while line_end < limit && units[line_end] != 10 && units[line_end] != 13 {
                line_end += 1;
            }
            let mut next = line_end;
            if next < limit {
                if units[next] == 13 {
                    next += 1;
                    if next < limit && units[next] == 10 {
                        next += 1;
                    }
                } else {
                    next += 1; // LF
                }
            }
            body(NSRange::new(pos, line_end - pos), &mut stop);
            if next <= pos {
                break; // guard against a zero-width step
            }
            pos = next;
        }
    }
}

/// swift: `NSString`'s value semantics — every plain Rust `str`/`String` method the engine calls
/// on a `SwiftString` (where the original Swift code held a `String`, not an `NSString` cast)
/// resolves here via autoderef: `is_empty`, `chars`, `starts_with`, `ends_with`, `strip_prefix`,
/// `trim`, `to_uppercase`, and `Option<SwiftString>::as_deref()`.
impl std::ops::Deref for SwiftString {
    type Target = str;
    fn deref(&self) -> &str {
        &self.s
    }
}

impl std::fmt::Display for SwiftString {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.s)
    }
}

impl AsRef<str> for SwiftString {
    fn as_ref(&self) -> &str {
        &self.s
    }
}

impl From<&str> for SwiftString {
    fn from(s: &str) -> Self {
        SwiftString::new(s)
    }
}

impl From<String> for SwiftString {
    fn from(s: String) -> Self {
        Self { s }
    }
}

impl From<SwiftString> for String {
    fn from(s: SwiftString) -> Self {
        s.s
    }
}

/// swift: `NSString` — the Swift engine names this type directly at 27 call sites, so the name has
/// to resolve, not merely be described. It is the same UTF-16-indexed string SwiftString provides.
pub type NSString = SwiftString;
