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

/// How many times a `SwiftString` has built its UTF-16 index, process-wide.
///
/// This is the observable the cost gate reads, and it is a COUNT rather than a clock on purpose:
/// the defect it guards against (rebuilding the index per character read) shows up as a number
/// proportional to the document's length, which no machine load can fake in either direction.
/// A wall-clock budget for the same thing is a known false-failure generator on this repo's own
/// suite. See `SwiftString::units`.
static UTF16_INDEX_BUILDS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Reads the counter above. Test-facing, but not `#[cfg(test)]`: the gate that uses it lives in an
/// integration test in another crate, which compiles against this crate's ordinary build.
pub fn utf16_index_builds() -> u64 {
    UTF16_INDEX_BUILDS.load(std::sync::atomic::Ordering::Relaxed)
}

/// swift: `NSString` — and, per convention §3, also Swift's own `String` wherever the call site
/// indexes it by UTF-16 offset (`.utf16`, `NSRange`-based substring). UTF-16 code-unit offsets
/// are computed from the stored UTF-8 text on demand so `length`/`substring(with:)` match
/// Cocoa's counting exactly instead of Rust's UTF-8 byte counting, which is the whole reason the
/// app pays for this cast (MarkdownRenderer.swift 172-179).
#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
/// `transparent` so text crosses a boundary AS text. Without it every string in a document is
/// wrapped in an object naming this struct's private field — an implementation detail no host
/// should have to know, let alone match.
#[serde(transparent)]
pub struct SwiftString {
    s: String,
    /// The UTF-16 units of `s`, built the first time something actually indexes this string.
    ///
    /// **Random access is the whole reason this type exists** — the module note above quotes
    /// `MarkdownRenderer.swift:172-179` saying the reader casts to `NSString` "to get UTF-16
    /// random access cheaply". Rebuilding the units on every read gives the opposite: reading a
    /// document character by character is O(n) per character. Measured on the transliterated
    /// renderer, `AttributedBuilder::new`'s newline scan was 15,363 of 15,376 profile samples,
    /// and `demo/moby-dick.md` rendered in 20.2 MINUTES against the host's 479 ms.
    ///
    /// Lazy rather than eager because `SwiftString` is a field of 62 wire and schema types that
    /// never index anything; materialising UTF-16 for all of them would roughly double the
    /// engine's string memory, which is what P2 and P4 just spent themselves reducing.
    ///
    /// It cannot go stale: `s` is immutable except through `push_str`, which drops it.
    #[serde(skip)]
    units: std::sync::OnceLock<Vec<u16>>,
}

/// Only `s` is identity — `units` is derived from it, so two strings with the same text are the
/// same string whether or not either has been indexed yet. Hand-written because `OnceLock` has no
/// `PartialEq`/`Ord`/`Hash` of its own, and deriving through it would make "has been indexed"
/// observable.
impl PartialEq for SwiftString {
    fn eq(&self, other: &Self) -> bool {
        self.s == other.s
    }
}
impl Eq for SwiftString {}
impl PartialOrd for SwiftString {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for SwiftString {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.s.cmp(&other.s)
    }
}
impl std::hash::Hash for SwiftString {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.s.hash(state);
    }
}

/// A clone starts un-indexed rather than copying the index: the copy usually goes somewhere that
/// never indexes it, and rebuilding costs one pass only for the copies that do.
impl Clone for SwiftString {
    fn clone(&self) -> Self {
        Self::new(&self.s)
    }
}

impl SwiftString {
    pub fn new(s: &str) -> Self {
        Self {
            s: s.to_string(),
            units: std::sync::OnceLock::new(),
        }
    }

    /// swift: `.utf16` — this string's UTF-16 code units, computed from the stored UTF-8 text.
    /// Every method below that takes or returns a UTF-16 offset goes through this.
    ///
    /// Built once per string; see `units` for why that matters and why it is lazy.
    fn units(&self) -> &[u16] {
        self.units.get_or_init(|| {
            UTF16_INDEX_BUILDS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.s.encode_utf16().collect()
        })
    }

    /// Counted rather than read off the index on purpose: `length` is asked of strings that are
    /// never indexed, and answering it must not make all 62 of those hold a UTF-16 copy for good.
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
        // The only place `s` changes, so the only place the index can go stale. Dropping it here
        // is what lets every reader above treat `units()` as always current.
        self.units.take();
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
        Self {
            s,
            units: std::sync::OnceLock::new(),
        }
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
