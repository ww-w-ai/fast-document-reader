//! swift: every reader/builder that names `NSParagraphStyle`/`NSMutableParagraphStyle`/
//! `NSTextAlignment`/`NSTextTab`/`NSUnderlineStyle`/`NSWritingDirection`.
//!
//! Fields mirror exactly the properties the in-scope files set: `.alignment`, `.lineSpacing`,
//! `.paragraphSpacing`, `.paragraphSpacingBefore`, `.firstLineHeadIndent`, `.headIndent`,
//! `.tailIndent`, `.tabStops`, `.lineHeightMultiple`, `.minimumLineHeight`,
//! `.maximumLineHeight`, `.baseWritingDirection`, `.lineBreakMode`, `.defaultTabInterval`.

use crate::geometry::CGFloat;

/// swift: NSTextAlignment
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
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
#[derive(Debug, Clone, PartialEq)]
pub struct NSParagraphStyle {
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
