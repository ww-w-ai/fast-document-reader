//! swift: every renderer/builder file — `NSAttributedString`/`NSMutableAttributedString` is the
//! text model the whole engine layer assembles into. Call sites key attributes with both the
//! stock `NSAttributedString.Key` cases (`.font`, `.foregroundColor`, `.paragraphStyle`, `.link`,
//! `.strikethroughStyle`, `.underlineStyle`) and this app's own custom keys, `MDAttr.*`
//! (Render/MDAttr.swift, in scope) — so the attribute value type must hold either.

use crate::color_font::{NSColor, NSFont};
use crate::drawing_misc::NSTextAttachment;
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
    /// swift: `.attachment` — the stock key `NSAttributedString(attachment:)` files an
    /// `NSTextAttachment` under.
    Attachment,
    /// swift: MDAttr.* and any other app-defined custom attribute key — carried by name so this
    /// shim does not need to enumerate MDAttr's cases.
    Custom(String),
}

/// swift: the attribute-run value union — `NSAttributedString` stores `[NSAttributedString.Key:
/// Any]`; call sites in this codebase put fonts, colors, paragraph styles, ranges, bools, ints,
/// strings and CGFloats in there. Modeled as a closed enum rather than `Any` because Rust has no
/// safe dynamic-typing equivalent worth building for phase A — except `Any` below, which exists
/// for exactly the values this crate genuinely cannot enumerate: app-defined attribute payload
/// types declared in `fastdoc-engine` (e.g. `FillMarginTabInfo`), which this crate cannot name
/// without a reverse dependency on the engine it is shimmed for.
#[derive(Debug, Clone)]
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
    Attachment(NSTextAttachment),
    /// swift: an app-defined attribute payload type this crate cannot name — see the enum doc
    /// above. Equality is by pointer identity (`Arc::ptr_eq`); two independently-built payloads
    /// that happen to hold equal data are NOT considered equal runs, which only matters where
    /// this crate compares `AttrValue`s for run-merging, and merging is conservative either way
    /// (an unnecessary split is a missed micro-optimisation, never a correctness bug).
    Any(std::sync::Arc<dyn std::any::Any + Send + Sync>),
}

impl PartialEq for AttrValue {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (AttrValue::Font(a), AttrValue::Font(b)) => a == b,
            (AttrValue::Color(a), AttrValue::Color(b)) => a == b,
            (AttrValue::ParagraphStyle(a), AttrValue::ParagraphStyle(b)) => a == b,
            (AttrValue::Range(a), AttrValue::Range(b)) => a == b,
            (AttrValue::Int(a), AttrValue::Int(b)) => a == b,
            (AttrValue::Double(a), AttrValue::Double(b)) => a == b,
            (AttrValue::Bool(a), AttrValue::Bool(b)) => a == b,
            (AttrValue::Text(a), AttrValue::Text(b)) => a == b,
            (AttrValue::UnderlineStyle(a), AttrValue::UnderlineStyle(b)) => a == b,
            (AttrValue::Attachment(a), AttrValue::Attachment(b)) => a == b,
            (AttrValue::Any(a), AttrValue::Any(b)) => std::sync::Arc::ptr_eq(a, b),
            _ => false,
        }
    }
}

/// swift: NSAttributedString
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NSAttributedString {
    pub(crate) string: String,
    /// UTF-16 code-unit count of `string`, kept in step with every mutation.
    ///
    /// Not an optimisation of a cheap call — `length()` is O(1) in Foundation and callers use it
    /// like a field. Deriving it from the string on each call makes `append` walk everything it
    /// has already appended, which is quadratic in the finished document: the ported
    /// `MarkdownRenderer` took 20.2 MINUTES on `demo/moby-dick.md` against the host's 479 ms,
    /// and `time / chars²` held at ~8e-7 across a 128x size range.
    ///
    /// The invariant is `utf16_len == string.encode_utf16().count()`, and it is enforced by
    /// construction: the field is private to this file, every mutation path here updates it, and
    /// the one door that hands out a `&mut String` (`mutableString`) returns a guard that
    /// recomputes on drop. A plain cached count next to a freely mutable string would drift.
    pub(crate) utf16_len: usize,
    pub(crate) runs: Vec<(NSRange, HashMap<NSAttributedStringKey, AttrValue>)>,
}

impl NSAttributedString {
    pub fn new(string: impl Into<String>) -> Self {
        let string = string.into();
        let utf16_len = string.encode_utf16().count();
        Self {
            string,
            utf16_len,
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
        let utf16_len = string.encode_utf16().count();
        let whole = NSRange::new(0, utf16_len);
        Self {
            string,
            utf16_len,
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
    ///
    /// O(1), and it has to be — see `utf16_len`.
    pub fn length(&self) -> usize {
        self.utf16_len
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

    /// The attribute runs themselves, in order.
    ///
    /// `attributesAt` answers one index by scanning, which is fine for the handful of lookups the
    /// renderer does and quadratic for anything that wants every run — a census, or the wire that
    /// carries a finished string to the host. Those want the runs, so this hands them over rather
    /// than making them ask a million times.
    pub fn runs(&self) -> &[(NSRange, HashMap<NSAttributedStringKey, AttrValue>)] {
        &self.runs
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

    /// swift: `.attributedSubstring(from:)` — a real slice: text and runs both clipped to `range`
    /// and re-based to start at 0, exactly like `NSMutableAttributedString.replaceCharacters`'s
    /// own run-clipping above.
    pub fn attributed_substring(&self, range: NSRange) -> NSAttributedString {
        let units: Vec<u16> = self.string.encode_utf16().collect();
        let lo = range.location.min(units.len());
        let hi = range.maxRange().min(units.len());
        // `from_utf16_lossy` maps each unpaired surrogate to one replacement character, itself one
        // UTF-16 unit, so the slice's unit count survives the conversion and is the new length.
        let string = String::from_utf16_lossy(&units[lo..hi]);
        let utf16_len = hi - lo;

        let mut runs = Vec::new();
        for (r, attrs) in &self.runs {
            let start = r.location.max(lo);
            let end = r.maxRange().min(hi);
            if start < end {
                runs.push((NSRange::new(start - lo, end - start), attrs.clone()));
            }
        }
        NSAttributedString {
            string,
            utf16_len,
            runs,
        }
    }

    /// swift: `NSString(string).character(at:)` via `as NSString` — a UTF-16 code-unit read,
    /// following convention §3's own reasoning for why `SwiftString` exists (see nsstring.rs):
    /// this is the same accounting Cocoa's `NSAttributedString.string` cast to `NSString` gives.
    pub fn characterAt(&self, index: usize) -> u16 {
        self.string.encode_utf16().nth(index).unwrap_or(0)
    }
}

/// The `&mut String` `mutableString()` hands out, with the length invariant restored on drop.
///
/// Deliberately not `Clone` or storable: it exists for the duration of one statement, which is how
/// every call site in the port uses `.mutableString` — as a value to push onto or read through,
/// never as something held across other work.
pub struct MutableStringGuard<'a> {
    owner: &'a mut NSAttributedString,
}

impl std::ops::Deref for MutableStringGuard<'_> {
    type Target = String;
    fn deref(&self) -> &String {
        &self.owner.string
    }
}

impl std::ops::DerefMut for MutableStringGuard<'_> {
    fn deref_mut(&mut self) -> &mut String {
        &mut self.owner.string
    }
}

impl Drop for MutableStringGuard<'_> {
    fn drop(&mut self) {
        self.owner.utf16_len = self.owner.string.encode_utf16().count();
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
    /// snake_case per convention's Rust-only-constructor clause. Its callers are in
    /// `render/office/office_text_builder.rs`.
    pub fn from_attributed_string(other: &NSAttributedString) -> Self {
        Self {
            inner: other.clone(),
        }
    }

    /// swift: `.mutableString` — the backing store, handed out for direct mutation.
    ///
    /// Returns a guard rather than a bare `&mut String` so `utf16_len` cannot drift: whatever the
    /// caller does to the string, the count is recomputed when the guard drops. Callers written
    /// against the Swift original (`cell_str.mutableString().push('\n')`) are unchanged, because
    /// the guard derefs to `String` in both directions.
    pub fn mutableString(&mut self) -> MutableStringGuard<'_> {
        MutableStringGuard { owner: &mut self.inner }
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
        self.inner.utf16_len += other.utf16_len;
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

    /// Replace ONE attribute's value wherever `range` already carries it, leaving every other
    /// layer alone. Not an AppKit method — it exists because this shim stores layers rather than
    /// a coalesced run list, and neither of the two AppKit calls does the right thing here:
    ///
    ///  * `addAttribute` appends a SECOND layer for the same key and range, and `attribute()`
    ///    resolves the FIRST match, so the new value is shadowed by the one it was replacing.
    ///  * `setAttributes` retires every layer at exactly that range and pushes one dictionary in
    ///    their place — which silently drops any OTHER layer that shares the range. Measured: a
    ///    markdown table cell holding `[`code`](url)` has the inline-code attributes and the
    ///    link attributes on the identical range, and grafting the table block through
    ///    `setAttributes` deleted the link and its underline from the finished document.
    ///
    /// If no layer at `range` carries the key, one is appended, which is what `addAttribute`
    /// would have done for a key that was not there.
    pub fn replace_attribute_value(
        &mut self,
        key: NSAttributedStringKey,
        value: AttrValue,
        range: NSRange,
    ) {
        let mut replaced = false;
        for (r, attrs) in self.inner.runs.iter_mut() {
            if *r == range && attrs.contains_key(&key) {
                attrs.insert(key.clone(), value.clone());
                replaced = true;
            }
        }
        if !replaced {
            self.inner.runs.push((range, HashMap::from([(key, value)])));
        }
    }


    pub fn attribute(
        &self,
        key: &NSAttributedStringKey,
        at: usize,
    ) -> Option<(&AttrValue, NSRange)> {
        self.inner.attribute(key, at)
    }

    /// swift: `.enumerateAttribute(_:in:options:using:)` — forwards to the immutable
    /// implementation; a mutable attributed string wraps one.
    pub fn enumerateAttribute(
        &self,
        key: &NSAttributedStringKey,
        range: NSRange,
        body: impl FnMut(Option<&AttrValue>, NSRange, &mut bool),
    ) {
        self.inner.enumerateAttribute(key, range, body);
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
        self.inner.utf16_len = spliced.len();

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

    /// swift: `NSMutableAttributedString(attributedString:)` under the name S10's call sites use
    /// — same operation as `from_attributed_string` above (kept for its own existing callers);
    /// two Rust-only constructor names for one Swift initializer, per convention §3's "a label
    /// list is not an identifier to mirror" reasoning, which does not pick a single spelling.
    pub fn from_immutable(other: &NSAttributedString) -> Self {
        Self::from_attributed_string(other)
    }

    /// swift: `NSMutableAttributedString(attachment:)` — files the attachment under `.attachment`
    /// on the one `U+FFFC` OBJECT REPLACEMENT CHARACTER Cocoa inserts for it.
    pub fn from_attachment(attachment: &NSTextAttachment) -> Self {
        Self::with_attributes(
            "\u{FFFC}",
            HashMap::from([(
                NSAttributedStringKey::Attachment,
                AttrValue::Attachment(attachment.clone()),
            )]),
        )
    }

    /// swift: `NSMutableAttributedString(attachment:)` — same initializer as `from_attachment`
    /// above, under the name the office text builder's call sites use.
    pub fn with_attachment(attachment: NSTextAttachment) -> Self {
        Self::from_attachment(&attachment)
    }

    /// swift: `NSString(string).character(at:)` via `as NSString` — see
    /// `NSAttributedString.characterAt` above; forwards to it since a mutable attributed string
    /// wraps one.
    pub fn characterAt(&self, index: usize) -> u16 {
        self.inner.characterAt(index)
    }

    /// swift: `.deleteCharacters(in:)` — implemented in terms of `replaceCharacters` above
    /// (delete is replace-with-empty), so it inherits the same real run-clipping logic rather
    /// than re-deriving it.
    pub fn delete_characters(&mut self, range: NSRange) {
        self.replaceCharacters(range, "");
    }

    /// swift: `NSMutableString.replaceOccurrences(of:with:options:range:)` — replaces each
    /// occurrence with its OWN `replaceCharacters` call, not one splice over the whole range:
    /// an earlier version spliced the whole `[range.location, range.maxRange())` span in one
    /// shot, which put every character between two matches under a single inherited-attribute
    /// run — flattening any styling between matches to whatever the range's first character
    /// carried (code-highlighted tokens between two `"\n"`s, say, would all lose their color to
    /// the first token's). Foundation mutates the backing string in place per match, touching
    /// only the matched span each time, so runs elsewhere in the range are untouched; this does
    /// the same. Returns the number of replacements made, matching Foundation's own return value.
    pub fn mutable_string_replace_occurrences(
        &mut self,
        target: &str,
        replacement: &str,
        range: NSRange,
    ) -> usize {
        if target.is_empty() {
            return 0;
        }
        let target_len = target.encode_utf16().count();
        let replacement_len = replacement.encode_utf16().count();
        let delta = replacement_len as i64 - target_len as i64;

        let mut count = 0usize;
        let mut cursor = range.location;
        let mut end = range.maxRange();
        while cursor < end {
            let haystack = crate::nsstring::SwiftString::new(&self.inner.string);
            let found = haystack.range_of(target, NSRange::new(cursor, end - cursor));
            if found.location == crate::foundation::NS_NOT_FOUND {
                break;
            }
            self.replaceCharacters(found, replacement);
            count += 1;
            cursor = found.location + replacement_len;
            end = (end as i64 + delta) as usize;
        }
        count
    }

    /// swift: `.attributedSubstring(from:)` — forwards to the immutable implementation.
    pub fn attributed_substring(&self, range: NSRange) -> NSAttributedString {
        self.inner.attributed_substring(range)
    }

    /// swift: `.enumerateAttribute(.paragraphStyle, in: NSRange(location: at, length: 1), ...)`
    /// followed by reading its `.paragraphStyle` cast back out — the convenience shape
    /// `OfficeTextBuilder.swift`'s own paragraph-style lookups use, collapsed to the one read it
    /// actually needs.
    pub fn paragraph_style_at(&self, at: usize) -> Option<NSParagraphStyle> {
        match self.inner.attribute(&NSAttributedStringKey::ParagraphStyle, at)? {
            (AttrValue::ParagraphStyle(style), _) => Some(style.clone()),
            _ => None,
        }
    }

    /// swift: `.addAttribute(.paragraphStyle, value: _, range: _)` — the paragraph-style-specific
    /// convenience the in-scope call sites use instead of the general `addAttribute` above.
    pub fn add_paragraph_style(&mut self, style: NSParagraphStyle, range: NSRange) {
        self.addAttribute(NSAttributedStringKey::ParagraphStyle, AttrValue::ParagraphStyle(style), range);
    }

    /// swift: `.addAttribute(.font, value: _, range: _)`
    pub fn add_attribute_font(&mut self, font: &NSFont, range: NSRange) {
        self.addAttribute(NSAttributedStringKey::Font, AttrValue::Font(font.clone()), range);
    }

    /// swift: `.addAttribute(.foregroundColor, value: _, range: _)`
    pub fn add_attribute_color(&mut self, color: &NSColor, range: NSRange) {
        self.addAttribute(NSAttributedStringKey::ForegroundColor, AttrValue::Color(*color), range);
    }

    /// swift: `.addAttribute(_:value:range:)` for an app-defined `MDAttr.*` key whose value type
    /// this crate cannot name (see `AttrValue::Any`'s doc) — `FillMarginTabInfo` is the one
    /// in-scope caller, but the method stays generic rather than naming that engine type, which
    /// would need a reverse dependency this crate does not have.
    pub fn add_attribute_fill_margin<T: std::any::Any + Send + Sync>(
        &mut self,
        key: NSAttributedStringKey,
        value: T,
        range: NSRange,
    ) {
        self.addAttribute(key, AttrValue::Any(std::sync::Arc::new(value)), range);
    }

    /// swift: `NSAttributedString(attributedString) as NSString` — hands back the run text as a
    /// UTF-16-indexed string for the same reason `SwiftString` exists (convention §3).
    pub fn as_ns_string(&self) -> crate::nsstring::SwiftString {
        crate::nsstring::SwiftString::new(&self.inner.string)
    }

    /// swift: `NSAttributedString(attributedString)` (immutable copy) — consumes this value
    /// rather than borrowing, since every in-scope call site returns it as the final result.
    pub fn into_immutable(self) -> NSAttributedString {
        self.inner
    }
}

impl From<NSMutableAttributedString> for NSAttributedString {
    fn from(m: NSMutableAttributedString) -> Self {
        m.inner
    }
}

/// swift: `NSMutableAttributedString : NSAttributedString` — Rust has no class inheritance;
/// `Deref` expresses the same "is-a" relation `NSTextTableBlock : NSTextBlock` uses in
/// `text_table.rs`, so a `&NSMutableAttributedString` coerces to `&NSAttributedString` at a call
/// site expecting the immutable type, exactly as Swift's subclassing let it stand in there.
/// Inherent methods of the same name on `NSMutableAttributedString` (`string`, `length`,
/// `attribute`, `enumerateAttribute`) still win method resolution, so this changes nothing about
/// how those already behave — it only reaches call sites that were not method calls at all.
impl std::ops::Deref for NSMutableAttributedString {
    type Target = NSAttributedString;
    fn deref(&self) -> &NSAttributedString {
        &self.inner
    }
}

/// swift: `Set(dict.keys).isSubset(of: allowList)` — the run-terminator-attribute-inheritance
/// allow-list check `OfficeTextBuilder.swift` runs on the attribute map an `attributesAt(_:)`
/// lookup returns. An extension trait (not an inherent method) because the receiver is a bare
/// `Option<&HashMap<...>>`, a std type this crate does not own; `None` counts as "no keys",
/// which is vacuously a subset of anything.
pub trait AttrKeysExt {
    fn keys_are_subset_of(&self, allowed: &[NSAttributedStringKey]) -> bool;
}

impl AttrKeysExt for Option<&HashMap<NSAttributedStringKey, AttrValue>> {
    fn keys_are_subset_of(&self, allowed: &[NSAttributedStringKey]) -> bool {
        match self {
            Some(map) => map.keys().all(|k| allowed.contains(k)),
            None => true,
        }
    }
}
