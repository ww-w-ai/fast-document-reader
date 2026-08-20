//! swift: every renderer/builder file — `NSAttributedString`/`NSMutableAttributedString` is the
//! text model the whole engine layer assembles into. Call sites key attributes with both the
//! stock `NSAttributedString.Key` cases (`.font`, `.foregroundColor`, `.paragraphStyle`, `.link`,
//! `.strikethroughStyle`, `.underlineStyle`) and this app's own custom keys, `MDAttr.*`
//! (Render/MDAttr.swift, in scope) — so the attribute value type must hold either.

use crate::color_font::{NSColor, NSFont};
use crate::foundation::NSRange;
use crate::paragraph_style::NSParagraphStyle;
use std::collections::HashMap;

/// swift: NSAttributedString.Key — the stock keys the in-scope files add. `MDAttr`'s own custom
/// keys (blockId, heading, image, …) are declared in MDAttr.swift itself, which is in scope and
/// ported alongside this crate rather than duplicated here.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum NSAttributedStringKey {
    Font,
    ForegroundColor,
    ParagraphStyle,
    Link,
    StrikethroughStyle,
    UnderlineStyle,
    /// swift: MDAttr.* and any other app-defined custom attribute key — carried by name so this
    /// shim does not need to enumerate MDAttr's cases.
    Custom(String),
}

/// swift: the attribute-run value union — `NSAttributedString` stores `[NSAttributedString.Key:
/// Any]`; call sites in this codebase put fonts, colors, paragraph styles, ranges, bools, ints,
/// strings and CGFloats in there. Modeled as a closed enum rather than `Any` because Rust has no
/// safe dynamic-typing equivalent worth building for phase A.
#[derive(Debug, Clone, PartialEq)]
pub enum AttrValue {
    Font(NSFont),
    Color(NSColor),
    ParagraphStyle(NSParagraphStyle),
    Range(NSRange),
    Int(i64),
    Double(f64),
    Bool(bool),
    Text(String),
    UnderlineStyle(crate::paragraph_style::NSUnderlineStyle),
}

/// swift: NSAttributedString
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NSAttributedString {
    pub(crate) string: String,
    pub(crate) runs: Vec<(NSRange, HashMap<NSAttributedStringKey, AttrValue>)>,
}

impl NSAttributedString {
    pub fn new(string: impl Into<String>) -> Self {
        Self {
            string: string.into(),
            runs: Vec::new(),
        }
    }

    /// swift: `NSAttributedString(string:attributes:)`. A Swift initializer is a label list, not an
    /// identifier, so there is no Swift name to mirror here — it falls under the convention's
    /// Rust-only-constructor clause and takes a snake_case name like `NSColor::srgb` does.
    pub fn with_attributes(
        string: impl Into<String>,
        attributes: HashMap<NSAttributedStringKey, AttrValue>,
    ) -> Self {
        let string = string.into();
        let whole = NSRange::new(0, string.encode_utf16().count());
        Self {
            string,
            runs: if attributes.is_empty() {
                Vec::new()
            } else {
                vec![(whole, attributes)]
            },
        }
    }

    pub fn string(&self) -> &str {
        &self.string
    }

    /// swift: .length — UTF-16 code unit count, the unit every `NSRange` in this codebase is
    /// measured in. Real UTF-16 accounting is deferred (`swiftshim::SwiftString` per convention
    /// §3); this counts UTF-16 code units of the stored `String` so ranges built against it are
    /// at least self-consistent until phase B.
    pub fn length(&self) -> usize {
        self.string.encode_utf16().count()
    }

    pub fn attribute(
        &self,
        key: &NSAttributedStringKey,
        at: usize,
    ) -> Option<(&AttrValue, NSRange)> {
        for (range, attrs) in &self.runs {
            if range.location <= at && at < range.maxRange() {
                if let Some(v) = attrs.get(key) {
                    return Some((v, *range));
                }
            }
        }
        None
    }

    pub fn attributesAt(&self, at: usize) -> Option<&HashMap<NSAttributedStringKey, AttrValue>> {
        self.runs
            .iter()
            .find(|(range, _)| range.location <= at && at < range.maxRange())
            .map(|(_, attrs)| attrs)
    }

    pub fn enumerateAttribute(
        &self,
        key: &NSAttributedStringKey,
        range: NSRange,
        mut body: impl FnMut(Option<&AttrValue>, NSRange, &mut bool),
    ) {
        let mut stop = false;
        for (run_range, attrs) in &self.runs {
            if stop {
                break;
            }
            if run_range.location < range.maxRange() && run_range.maxRange() > range.location {
                body(attrs.get(key), *run_range, &mut stop);
            }
        }
    }
}

/// swift: NSMutableAttributedString
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NSMutableAttributedString {
    pub(crate) inner: NSAttributedString,
}

impl NSMutableAttributedString {
    /// swift: `NSMutableAttributedString(string:attributes:)` — see the immutable twin above for why
    /// this constructor is snake_case while the crate's methods keep Swift spelling.
    pub fn with_attributes(
        string: impl Into<String>,
        attributes: HashMap<NSAttributedStringKey, AttrValue>,
    ) -> Self {
        Self {
            inner: NSAttributedString::with_attributes(string, attributes),
        }
    }

    pub fn new() -> Self {
        Self {
            inner: NSAttributedString::default(),
        }
    }

    pub fn fromString(string: impl Into<String>) -> Self {
        Self {
            inner: NSAttributedString::new(string),
        }
    }

    /// swift: `NSMutableAttributedString(attributedString:)` — same reasoning as
    /// `with_attributes` above: a Swift initializer label list, not a name to mirror, so
    /// snake_case per convention's Rust-only-constructor clause. Found missing during S12
    /// verification (markdown_renderer.rs:846,898,1344,1513 all call it).
    pub fn from_attributed_string(other: &NSAttributedString) -> Self {
        Self {
            inner: other.clone(),
        }
    }

    pub fn mutableString(&mut self) -> &mut String {
        &mut self.inner.string
    }

    pub fn string(&self) -> &str {
        &self.inner.string
    }

    pub fn length(&self) -> usize {
        self.inner.length()
    }

    pub fn append(&mut self, other: &NSAttributedString) {
        let offset = self.length();
        self.inner.string.push_str(&other.string);
        for (range, attrs) in &other.runs {
            self.inner.runs.push((
                NSRange::new(range.location + offset, range.length),
                attrs.clone(),
            ));
        }
    }

    pub fn addAttribute(&mut self, key: NSAttributedStringKey, value: AttrValue, range: NSRange) {
        self.inner
            .runs
            .push((range, HashMap::from([(key, value)])));
    }

    pub fn addAttributes(
        &mut self,
        attributes: HashMap<NSAttributedStringKey, AttrValue>,
        range: NSRange,
    ) {
        self.inner.runs.push((range, attributes));
    }

    pub fn setAttributes(
        &mut self,
        attributes: HashMap<NSAttributedStringKey, AttrValue>,
        range: NSRange,
    ) {
        self.inner.runs.retain(|(r, _)| *r != range);
        self.inner.runs.push((range, attributes));
    }

    pub fn attribute(
        &self,
        key: &NSAttributedStringKey,
        at: usize,
    ) -> Option<(&AttrValue, NSRange)> {
        self.inner.attribute(key, at)
    }

    /// swift: .replaceCharacters(in:with:) — a string splice plus run-offset recomputation.
    /// Closed as a phase-A hole (team-lead review, 2026-08-21): purely an algorithm over this
    /// shim's own data, `append()` already does the offset half of this work, and nothing here
    /// needed a live TextKit object.
    ///
    /// Attribute inheritance follows Foundation's own rule for this call: the inserted text
    /// takes the attributes of the FIRST character of the replaced range, or (an empty range)
    /// the character immediately before `range.location`, or (location 0) no attributes. Runs
    /// wholly inside the replaced range are dropped; runs straddling either edge are clipped to
    /// their surviving portion; runs entirely at or after `range.maxRange()` shift by the delta
    /// between the new and old lengths.
    pub fn replaceCharacters(&mut self, range: NSRange, with: &str) {
        let units: Vec<u16> = self.inner.string.encode_utf16().collect();
        let new_units: Vec<u16> = with.encode_utf16().collect();
        let delta = new_units.len() as i64 - range.length as i64;

        let inherited = if range.length > 0 {
            self.inner.attributesAt(range.location).cloned()
        } else if range.location > 0 {
            self.inner.attributesAt(range.location - 1).cloned()
        } else {
            None
        };

        let mut spliced = units[..range.location].to_vec();
        spliced.extend_from_slice(&new_units);
        spliced.extend_from_slice(&units[range.maxRange()..]);
        self.inner.string = String::from_utf16_lossy(&spliced);

        let mut runs = Vec::with_capacity(self.inner.runs.len() + 1);
        for (r, attrs) in self.inner.runs.drain(..) {
            if r.maxRange() <= range.location {
                runs.push((r, attrs)); // wholly before — untouched
            } else if r.location >= range.maxRange() {
                let shifted = (r.location as i64 + delta) as usize;
                runs.push((NSRange::new(shifted, r.length), attrs)); // wholly after — shifted
            } else {
                // overlaps the replaced range: keep only the surviving edges.
                if r.location < range.location {
                    runs.push((
                        NSRange::new(r.location, range.location - r.location),
                        attrs.clone(),
                    ));
                }
                if r.maxRange() > range.maxRange() {
                    let tail_len = r.maxRange() - range.maxRange();
                    let tail_start = (range.maxRange() as i64 + delta) as usize;
                    runs.push((NSRange::new(tail_start, tail_len), attrs));
                }
            }
        }
        if !new_units.is_empty() {
            if let Some(attrs) = inherited {
                runs.push((NSRange::new(range.location, new_units.len()), attrs));
            }
        }
        self.inner.runs = runs;
    }

    pub fn beginEditing(&mut self) {}
    pub fn endEditing(&mut self) {}

    pub fn asAttributedString(&self) -> &NSAttributedString {
        &self.inner
    }
}

impl From<NSMutableAttributedString> for NSAttributedString {
    fn from(m: NSMutableAttributedString) -> Self {
        m.inner
    }
}
