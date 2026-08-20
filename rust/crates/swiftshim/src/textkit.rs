//! swift: Render/TableBlockBuilder.swift and Render/GridTextTableBlock.swift.
//!
//! Per convention §4, these six symbols are received here NOT because the reader draws with
//! them (drawing is host-resident, excluded from phase A — see rust/PORT-MANIFEST.txt), but
//! because table geometry ASKS them for cell width via `NSTextTable.rectForBlock(layoutManager:
//! atIndex:effectiveRange:)`. They exist so that call shape compiles; a live layout pass is a
//! phase B / host-integration concern.

use crate::attributed_string::{AttrValue, NSAttributedString, NSAttributedStringKey};
use crate::foundation::NSRange;
use crate::geometry::{CGPoint, CGSize};

/// swift: NSLayoutManager
#[derive(Debug, Clone, Default)]
pub struct NSLayoutManager;

impl NSLayoutManager {
    pub fn new() -> Self {
        Self
    }
    pub fn addTextContainer(&mut self, _container: NSTextContainer) {
        todo!("swift: NSLayoutManager.addTextContainer(_:) — phase B (host-resident)")
    }
}

/// swift: NSTextStorage
#[derive(Debug, Clone, Default)]
pub struct NSTextStorage {
    pub attributedString: NSAttributedString,
}

impl NSTextStorage {
    pub fn withAttributedString(attributedString: NSAttributedString) -> Self {
        Self { attributedString }
    }
    pub fn addLayoutManager(&mut self, _layout_manager: NSLayoutManager) {
        todo!("swift: NSTextStorage.addLayoutManager(_:) — phase B (host-resident)")
    }

    /// swift: .length — `NSTextStorage` is an `NSMutableAttributedString` subclass, so this
    /// (like `enumerateAttribute` below) just forwards to the attributed string it wraps.
    pub fn length(&self) -> usize {
        self.attributedString.length()
    }

    /// swift: .enumerateAttribute(.paragraphStyle, in:options:using:) — the shape
    /// TableBlockBuilder.swift's row-height pass walks to find each paragraph's own style run.
    pub fn enumerateAttribute(
        &self,
        key: &NSAttributedStringKey,
        range: NSRange,
        body: impl FnMut(Option<&AttrValue>, NSRange, &mut bool),
    ) {
        self.attributedString.enumerateAttribute(key, range, body);
    }
}

/// swift: NSTextContainer
#[derive(Debug, Clone)]
pub struct NSTextContainer {
    pub size: CGSize,
}

impl NSTextContainer {
    pub fn new(size: CGSize) -> Self {
        Self { size }
    }
}

/// swift: NSView — referenced only as the ancestor type table geometry code type-checks
/// against; the reader's actual view hierarchy is host-resident (AppKit, excluded from phase A).
/// Carries the one downcast GridTextTableBlock.swift performs (`controlView as? NSTextView`) —
/// Rust has no `as?` dynamic cast for a plain struct, so the shim provides the one shape the
/// in-scope code actually asks for instead of a general type-erasure mechanism nothing needs.
#[derive(Debug, Clone, Default)]
pub struct NSView {
    asTextView: Option<Box<NSTextView>>,
}

impl NSView {
    /// swift: `controlView as? NSTextView` (GridTextTableBlock.swift:28)
    pub fn asTextView(&self) -> Option<&NSTextView> {
        self.asTextView.as_deref()
    }
}

/// swift: NSScrollView
#[derive(Debug, Clone, Default)]
pub struct NSScrollView {
    pub base: NSView,
}

/// swift: NSTextView
#[derive(Debug, Clone, Default)]
pub struct NSTextView {
    pub base: NSView,
    pub textContainer: Option<NSTextContainer>,
    /// swift: .textContainerOrigin — the view/container coordinate-system offset
    /// GridTextTableBlock.swift:24-28 explains at length (28pt in this reader).
    pub textContainerOrigin: CGPoint,
}
