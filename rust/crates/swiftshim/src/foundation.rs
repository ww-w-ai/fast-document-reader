//! swift: Sources/FastDocReader/Render/**/*.swift (Foundation odds — Data/URL/FileManager/
//! NSRange/NSNumber/NSValue/NSObject, and the `throws` stand-in `EngineError`).
//!
//! These are the minimal Foundation surface the in-scope files touch outside strings and
//! collections proper. Behaviour is real where it is data-only (`NSRange`); everything that
//! reads the filesystem or parses bytes is `todo!()`.

use crate::geometry::CGRect;

/// swift: NSRange
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NSRange {
    pub location: usize,
    pub length: usize,
}

/// swift: NSNotFound — Swift's `NSNotFound` is `Int.max` on 64-bit; `usize::MAX` mirrors that
/// role as the location a range uses to mean "no match".
pub const NS_NOT_FOUND: usize = usize::MAX;

impl NSRange {
    pub fn new(location: usize, length: usize) -> Self {
        Self { location, length }
    }
    pub fn notFound() -> Self {
        Self {
            location: NS_NOT_FOUND,
            length: 0,
        }
    }
    pub fn maxRange(&self) -> usize {
        self.location + self.length
    }
}

/// swift: NSNumber — call sites construct it from a `Double` and read `.rawValue`-shaped ints
/// back out (e.g. an edge-set `OptionSet.rawValue`); phase B decides whether this collapses.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NSNumber {
    value: f64,
}

impl NSNumber {
    pub fn fromDouble(value: f64) -> Self {
        Self { value }
    }
    pub fn intValue(&self) -> i64 {
        self.value as i64
    }
    pub fn doubleValue(&self) -> f64 {
        self.value
    }
}

/// swift: NSValue — the in-scope files only box an `NSRange` in one (`NSValue(range:)`), read
/// back with `.rangeValue`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum NSValue {
    Range(NSRange),
    Rect(CGRect),
}

impl NSValue {
    pub fn fromRange(range: NSRange) -> Self {
        NSValue::Range(range)
    }
    pub fn rangeValue(&self) -> NSRange {
        match self {
            NSValue::Range(r) => *r,
            _ => panic!("NSValue is not a range"),
        }
    }
    pub fn rectValue(&self) -> CGRect {
        match self {
            NSValue::Rect(r) => *r,
            _ => panic!("NSValue is not a rect"),
        }
    }
}

/// swift: NSObject — the in-scope files reference it only as a base/marker type for attachment
/// cells and similar; no member of it is called directly here.
#[derive(Debug, Clone, Default)]
pub struct NSObject;

/// swift: Data
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Data(pub Vec<u8>);

impl Data {
    pub fn new() -> Self {
        Data(Vec::new())
    }
    /// swift: Data() — the no-argument initializer; `empty()` is the name S4's call sites use.
    pub fn empty() -> Self {
        Data(Vec::new())
    }
    pub fn fromBytes(bytes: Vec<u8>) -> Self {
        Data(bytes)
    }
    pub fn base64Encoded(_b64: &str) -> Option<Self> {
        todo!("swift: Data(base64Encoded:) — phase B")
    }
    /// swift: `Data(contentsOf:)` — file URLs only, which is every call site in scope.
    pub fn contentsOf(url: &URL) -> Result<Self, EngineError> {
        std::fs::read(url.path())
            .map(Data)
            .map_err(|e| EngineError::Message(e.to_string()))
    }

    /// swift: .count — a `Collection`'s element count. `len()` is kept alongside for S4's call
    /// sites; both read the same field.
    pub fn count(&self) -> usize {
        self.0.len()
    }
    pub fn len(&self) -> usize {
        self.0.len()
    }
    /// swift: .isEmpty
    pub fn isEmpty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    /// swift: .startIndex — always 0 for a `Data` this shim constructs whole (it never models a
    /// sliced sub-range with a nonzero base, unlike real `Data.SubSequence`).
    pub fn startIndex(&self) -> usize {
        0
    }
    /// swift: .subdata(in:) — ZipArchive.swift's own byte-range reads (invariant-relevant: this
    /// is where a docx's central-directory / local-header slices come from).
    pub fn subdata(&self, range: NSRange) -> Data {
        Data(self.0[range.location..range.maxRange()].to_vec())
    }
    /// swift: subscript(_ i: Int) -> UInt8 — Data's byte-indexed subscript; named rather than
    /// implemented via `Index` because ZipArchive.swift reads it as a plain call, not `data[i]`.
    pub fn byte_at(&self, index: usize) -> u8 {
        self.0[index]
    }
    /// Rust-only: no Swift member this mirrors — Data has no owning "hand me the buffer" call,
    /// callers just keep using `Data` itself. Exists because S4's Rust port needs a `Vec<u8>` at
    /// some point and re-deriving this conversion per call site would be exactly the kind of
    /// per-caller reshaping convention §4 exists to avoid.
    pub fn into_vec(self) -> Vec<u8> {
        self.0
    }
}

impl std::ops::Index<usize> for Data {
    type Output = u8;
    fn index(&self, i: usize) -> &u8 {
        &self.0[i]
    }
}

/// swift: URL
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct URL {
    pub string: String,
}

impl URL {
    pub fn fromString(s: &str) -> Option<Self> {
        Some(URL {
            string: s.to_string(),
        })
    }
    /// swift: `URL(fileURLWithPath:)`
    ///
    /// The path is stored as given, NOT as a `file://` string. `string` is read back by
    /// `OfficeTextBuilder` as the href it writes into a link attribute, and percent-encoding a
    /// local path there would put `%20` in front of the user instead of a space.
    pub fn fileURL(path: &str) -> Self {
        URL { string: path.to_string() }
    }

    /// swift: `URL.path` — the filesystem path, with a `file://` prefix tolerated on the way in
    /// because `fromString` accepts any string and some call sites hand it a real URL.
    pub fn path(&self) -> &str {
        self.string.strip_prefix("file://").unwrap_or(&self.string)
    }
}

/// swift: FileManager — the in-scope files call it only for read-existing/enumerate style
/// checks; the live filesystem is a phase B concern.
#[derive(Debug, Clone, Default)]
pub struct FileManager;

impl FileManager {
    pub fn defaultManager() -> Self {
        FileManager
    }
    pub fn fileExists(&self, path: &str) -> bool {
        std::path::Path::new(path).exists()
    }
}

/// swift: `throws` / `try` — every `throws` function becomes `-> Result<T, EngineError>` and
/// every `try` becomes `?` (convention §3). This enum stands in for whatever concrete Swift
/// `Error` a given call site threw; phase B may split it into per-domain error types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    Message(String),
}
impl EngineError {
    /// The human-readable half, for callers whose own error type has nowhere to put the cause.
    pub fn message(&self) -> String {
        match self {
            EngineError::Message(m) => m.clone(),
        }
    }
}


impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Message(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for EngineError {}

/// swift: `NSNotFound` — Swift compares a not-found range's `location` against this sentinel, so it
/// must be a value the port can name, not a comment. `Int.max` on 64-bit; `usize::MAX` mirrors it
/// against the `usize` location `NSRange` carries here.
pub const NSNotFound: usize = usize::MAX;
