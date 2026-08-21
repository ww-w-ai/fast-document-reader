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
#[derive(Clone, Default)]
pub struct NSLayoutManager {
    /// swift: `.delegate as? PageBandLayoutDelegate` — the reader's page-band gap detection reads
    /// its layout manager's delegate back through this downcast. Modeled as a trait object rather
    /// than `Any` + a downcast, so the accessor below is concrete (no turbofish/inference needed
    /// at the call site) and the crate boundary is respected: `fastdoc-engine` depends on
    /// `swiftshim`, not the reverse, so `PageBandDelegate` is declared here and the engine's real
    /// delegate type implements it there.
    page_band_delegate: Option<std::rc::Rc<dyn PageBandDelegate>>,
}

impl std::fmt::Debug for NSLayoutManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NSLayoutManager")
            .field("page_band_delegate", &self.page_band_delegate.is_some())
            .finish()
    }
}

impl NSLayoutManager {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn addTextContainer(&mut self, _container: &NSTextContainer) {
        todo!("swift: NSLayoutManager.addTextContainer(_:) — phase B (host-resident)")
    }

    /// swift: `.allowsNonContiguousLayout = _` — TextKit's incremental-layout opt-in; needs a
    /// live layout manager to have any effect, so `todo!()` like the rest of this file.
    pub fn set_allows_non_contiguous_layout(&self, _allows: bool) {
        todo!("swift: NSLayoutManager.allowsNonContiguousLayout — phase B (host-resident)")
    }

    /// swift: `.ensureLayout(for:)` — forces TextKit to lay out a container; needs a live layout
    /// pass.
    pub fn ensure_layout(&self, _container: &NSTextContainer) {
        todo!("swift: NSLayoutManager.ensureLayout(for:) — phase B (host-resident)")
    }

    /// swift: `.usedRect(for:)` — the laid-out size of a container; needs a live layout pass.
    pub fn used_rect(&self, _container: &NSTextContainer) -> crate::geometry::CGRect {
        todo!("swift: NSLayoutManager.usedRect(for:) — phase B (host-resident)")
    }

    /// swift: `.delegate = _` — sets the delegate any later `page_band_delegate()` read returns.
    pub fn set_page_band_delegate(&mut self, delegate: std::rc::Rc<dyn PageBandDelegate>) {
        self.page_band_delegate = Some(delegate);
    }

    /// swift: `.delegate as? PageBandLayoutDelegate` — see the field doc above.
    pub fn page_band_delegate(&self) -> Option<std::rc::Rc<dyn PageBandDelegate>> {
        self.page_band_delegate.clone()
    }
}

/// swift: `PageBandLayoutDelegate` (Render/Office/PageBandLayoutDelegate.swift, in scope) — the
/// one member `GridTextTableBlock.swift`'s gap-crossing math reads off it. Declared here (not in
/// `fastdoc-engine`) purely so `NSLayoutManager` can hold a reference to it without a reverse
/// dependency; the engine's real delegate type implements this trait.
pub trait PageBandDelegate {
    fn opened_bands(&self) -> Vec<OpenedBand>;
}

/// swift: the `(top, height)` shape `PageBandLayoutDelegate.openedBands` yields per band.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OpenedBand {
    pub top: crate::geometry::CGFloat,
    pub height: crate::geometry::CGFloat,
}

/// swift: NSTextStorage
#[derive(Debug, Clone, Default)]
pub struct NSTextStorage {
    pub attributedString: NSAttributedString,
}

impl NSTextStorage {
    pub fn withAttributedString(attributedString: &NSAttributedString) -> Self {
        Self {
            attributedString: attributedString.clone(),
        }
    }
    pub fn addLayoutManager(&mut self, _layout_manager: &NSLayoutManager) {
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

    /// swift: `.widthTracksTextView = _` — needs a live text view to have any effect.
    pub fn set_width_tracks_text_view(&self, _tracks: bool) {
        todo!("swift: NSTextContainer.widthTracksTextView — phase B (host-resident)")
    }

    /// swift: `.lineFragmentPadding = _` — needs a live layout pass to have any effect.
    pub fn set_line_fragment_padding(&self, _padding: crate::geometry::CGFloat) {
        todo!("swift: NSTextContainer.lineFragmentPadding — phase B (host-resident)")
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
