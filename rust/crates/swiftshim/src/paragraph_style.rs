//! swift: every reader/builder that names `NSParagraphStyle`/`NSMutableParagraphStyle`/
//! `NSTextAlignment`/`NSTextTab`/`NSUnderlineStyle`/`NSWritingDirection`.
//!
//! Fields mirror exactly the properties the in-scope files set: `.alignment`, `.lineSpacing`,
//! `.paragraphSpacing`, `.paragraphSpacingBefore`, `.firstLineHeadIndent`, `.headIndent`,
//! `.tailIndent`, `.tabStops`, `.lineHeightMultiple`, `.minimumLineHeight`,
//! `.maximumLineHeight`, `.baseWritingDirection`, `.lineBreakMode`, `.defaultTabInterval`.

use crate::geometry::CGFloat;

/// swift: NSTextAlignment
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NSTextAlignment {
    #[default]
    Left,
    Right,
    Center,
    Justified,
    Natural,
}

/// swift: NSLineBreakMode — read alongside `.lineBreakMode` on paragraph style call sites.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NSLineBreakMode {
    #[default]
    ByWordWrapping,
    ByCharWrapping,
    ByClipping,
    ByTruncatingHead,
    ByTruncatingTail,
    ByTruncatingMiddle,
}

/// swift: NSWritingDirection
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NSWritingDirection {
    #[default]
    Natural,
    LeftToRight,
    RightToLeft,
}

/// swift: NSWritingDirectionFormatType — paired with `NSWritingDirection` where the reader needs
/// the embedding/override distinction, not just the base direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NSWritingDirectionFormatType {
    Embedding,
    Override,
}

/// swift: NSUnderlineStyle — an OptionSet (`.single`, `.thick`, `.double`, `.patternDot`, …);
/// call sites in this codebase union style with pattern, so it is bit flags rather than an enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NSUnderlineStyle(pub u32);

impl NSUnderlineStyle {
    pub const NONE: NSUnderlineStyle = NSUnderlineStyle(0);
    pub const single: NSUnderlineStyle = NSUnderlineStyle(0x01);
    pub const thick: NSUnderlineStyle = NSUnderlineStyle(0x02);
    pub const double: NSUnderlineStyle = NSUnderlineStyle(0x09);
    pub const patternDot: NSUnderlineStyle = NSUnderlineStyle(0x100);
    pub const patternDash: NSUnderlineStyle = NSUnderlineStyle(0x200);

    pub fn union(self, other: NSUnderlineStyle) -> NSUnderlineStyle {
        NSUnderlineStyle(self.0 | other.0)
    }

    /// swift: `OptionSet.rawValue` — every `OptionSet` has one; the in-scope call site reads it
    /// back out to store as a plain integer attribute value.
    pub fn rawValue(&self) -> u32 {
        self.0
    }
}

/// swift: NSTextTab.OptionKey — the `options:` dictionary `NSTextTab(textAlignment:location:
/// options:)` takes; the in-scope call sites always pass `[:]`, so this exists only so the
/// signature type-checks.
pub type NSTextTabOptions = std::collections::HashMap<String, f64>;

/// swift: NSTextTab
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NSTextTab {
    pub alignment: NSTextAlignment,
    pub location: CGFloat,
}

impl NSTextTab {
    pub fn new(alignment: NSTextAlignment, location: CGFloat, _options: NSTextTabOptions) -> Self {
        Self { alignment, location }
    }
}

/// swift: NSParagraphStyle — the read-only view; `NSMutableParagraphStyle` is the type call
/// sites actually build (`.default().mutableCopy()`), so this mirrors the same fields.
/// swift: `NSLineBreakStrategy` — the option set a paragraph carries to say how a line may be
/// broken. The reader sets exactly one of its members (`hangulWordPriority`), which is what makes
/// Korean text break at word boundaries rather than mid-word; everything else is carried so a
/// document that states a strategy is not silently flattened to none.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NSLineBreakStrategy(pub u32);

impl NSLineBreakStrategy {
    pub const none: NSLineBreakStrategy = NSLineBreakStrategy(0);
    pub const pushOut: NSLineBreakStrategy = NSLineBreakStrategy(1 << 0);
    pub const hangulWordPriority: NSLineBreakStrategy = NSLineBreakStrategy(1 << 1);
    pub const standard: NSLineBreakStrategy = NSLineBreakStrategy(0xFFFF);

    /// swift: `OptionSet.insert(_:)`
    pub fn insert(&mut self, other: NSLineBreakStrategy) {
        self.0 |= other.0;
    }

    /// swift: `OptionSet.remove(_:)`
    pub fn remove(&mut self, other: NSLineBreakStrategy) {
        self.0 &= !other.0;
    }

    /// swift: `OptionSet.contains(_:)`
    pub fn contains(&self, other: NSLineBreakStrategy) -> bool {
        self.0 & other.0 == other.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct NSParagraphStyle {
    pub lineBreakStrategy: NSLineBreakStrategy,
    pub alignment: NSTextAlignment,
    pub lineSpacing: CGFloat,
    pub paragraphSpacing: CGFloat,
    pub paragraphSpacingBefore: CGFloat,
    pub firstLineHeadIndent: CGFloat,
    pub headIndent: CGFloat,
    pub tailIndent: CGFloat,
    pub tabStops: Vec<NSTextTab>,
    pub defaultTabInterval: CGFloat,
    pub lineHeightMultiple: CGFloat,
    pub minimumLineHeight: CGFloat,
    pub maximumLineHeight: CGFloat,
    pub baseWritingDirection: NSWritingDirection,
    pub lineBreakMode: NSLineBreakMode,
}

impl Default for NSParagraphStyle {
    fn default() -> Self {
        Self {
            alignment: NSTextAlignment::default(),
            lineBreakStrategy: NSLineBreakStrategy::default(),
            lineSpacing: 0.0,
            paragraphSpacing: 0.0,
            paragraphSpacingBefore: 0.0,
            firstLineHeadIndent: 0.0,
            headIndent: 0.0,
            tailIndent: 0.0,
            tabStops: Vec::new(),
            defaultTabInterval: 0.0,
            lineHeightMultiple: 0.0,
            minimumLineHeight: 0.0,
            maximumLineHeight: 0.0,
            baseWritingDirection: NSWritingDirection::default(),
            lineBreakMode: NSLineBreakMode::default(),
        }
    }
}

/// swift: NSMutableParagraphStyle
pub type NSMutableParagraphStyle = NSParagraphStyle;
