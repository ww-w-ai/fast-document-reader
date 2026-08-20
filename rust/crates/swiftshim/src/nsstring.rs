//! swift: convention §3 — `String` UTF-16 indexing and `NSString` both become
//! `swiftshim::SwiftString`. The reader casts `source as NSString` specifically to get UTF-16
//! random access cheaply (MarkdownRenderer.swift:172-179 explains why); this shim keeps that
//! shape (a UTF-16 code-unit buffer with `.length`, `substring`, and path helpers) without
//! deciding, yet, how Rust should represent it — see `SwiftString` for the same reasoning
//! spelled out once instead of on every call site.

use crate::foundation::NSRange;

/// swift: `NSString` — and, per convention §3, also Swift's own `String` wherever the call site
/// indexes it by UTF-16 offset (`.utf16`, `NSRange`-based substring). Backed by UTF-16 code
/// units so `length`/`substring(with:)` match Cocoa's counting exactly instead of Rust's UTF-8
/// byte counting, which is the whole reason the app pays for this cast (MarkdownRenderer.swift
/// 172-179).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SwiftString {
    units: Vec<u16>,
}

impl SwiftString {
    pub fn new(s: &str) -> Self {
        Self {
            units: s.encode_utf16().collect(),
        }
    }

    pub fn length(&self) -> usize {
        self.units.len()
    }

    pub fn substring(&self, range: NSRange) -> String {
        String::from_utf16_lossy(&self.units[range.location..range.maxRange()])
    }

    pub fn characterAt(&self, index: usize) -> u16 {
        self.units[index]
    }

    /// swift: .deletingLastPathComponent
    pub fn deletingLastPathComponent(&self) -> SwiftString {
        let s = self.to_string();
        let trimmed = s.trim_end_matches('/');
        match trimmed.rfind('/') {
            Some(i) => SwiftString::new(&trimmed[..i]),
            None => SwiftString::new(""),
        }
    }

    /// swift: .lastPathComponent
    pub fn lastPathComponent(&self) -> SwiftString {
        let s = self.to_string();
        let trimmed = s.trim_end_matches('/');
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
        let n = self.units.len();
        // Scan backward from the range's start to the beginning of its line.
        let mut s = for_range.location.min(n);
        while s > 0 && self.units[s - 1] != 10 && self.units[s - 1] != 13 {
            s -= 1;
        }
        if let Some(out) = start {
            *out = s;
        }
        // Scan forward from the range's end to this line's terminator.
        let mut c = for_range.maxRange().min(n);
        while c < n && self.units[c] != 10 && self.units[c] != 13 {
            c += 1;
        }
        *contents_end = c;
        let mut e = c;
        if e < n {
            if self.units[e] == 13 {
                e += 1;
                if e < n && self.units[e] == 10 {
                    e += 1;
                }
            } else {
                e += 1; // LF
            }
        }
        *end = e;
    }
}

impl std::fmt::Display for SwiftString {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", String::from_utf16_lossy(&self.units))
    }
}

impl From<&str> for SwiftString {
    fn from(s: &str) -> Self {
        SwiftString::new(s)
    }
}

impl From<String> for SwiftString {
    fn from(s: String) -> Self {
        SwiftString::new(&s)
    }
}

/// swift: `NSString` — the Swift engine names this type directly at 27 call sites, so the name has
/// to resolve, not merely be described. It is the same UTF-16-indexed string SwiftString provides.
pub type NSString = SwiftString;
