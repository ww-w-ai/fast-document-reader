//! Stand-ins for the Foundation and AppKit surface the Swift engine layer is written against.
//!
//! Phase A transliterates Swift mechanically, so a missing type must never force the caller to
//! be rewritten — that would mix porting with design. Anything the Swift side names, this crate
//! names too, with the same spelling and the same fields. Behaviour arrives in phase B; until
//! then a method may be `todo!()`. See docs/plans/rust-port-convention.md §4.
//!
//! Every `todo!()` in this crate carries a `swift:` pointer to the file:line where B-phase work
//! resumes; that is deliberate and is not repeated item by item below. Modules are organised by
//! the same clusters convention §4's symbol table uses (values/geometry, color/font/image, text
//! model, paragraph style, tables, TextKit, regex), plus one `nsstring` module for the
//! UTF-16-indexed string convention §3 calls out separately.
#![allow(non_snake_case, non_camel_case_types, non_upper_case_globals)]

use std::cell::RefCell;
use std::rc::Rc;

pub mod attributed_string;
pub mod color_font;
pub mod drawing_misc;
pub mod font_provider;
pub mod foundation;
pub mod geometry;
pub mod nsstring;
pub mod paragraph_style;
pub mod regex;
pub mod text_measure;
pub mod text_table;
pub mod textkit;

/// Swift's reference semantics for `class`. Phase A uses this for EVERY class, without judging
/// whether a given one could have been a value — that judgement belongs to phase B.
pub type Ref<T> = Rc<RefCell<T>>;

pub fn new_ref<T>(value: T) -> Ref<T> {
    Rc::new(RefCell::new(value))
}

// Flat re-export so callers write `swiftshim::NSColor`, matching how the Swift source names
// these types with no module qualification.
pub use attributed_string::{AttrKeysExt, AttrValue, NSAttributedString, NSAttributedStringKey, NSMutableAttributedString};
pub use color_font::{
    system_colors, DynamicColor, NSBitmapImageRep, NSColor, NSFont, NSFontDescriptor,
    NSFontFeatureKey, NSFontDescriptorSymbolicTraits, NSFontWeight, NSGradient, NSImage,
};
pub use drawing_misc::{draw_string_at, size_with_attributes, NSBezierPath, NSCompositingOperation, NSTextAttachment, SizedAttachmentCell};
pub use foundation::{Data, EngineError, FileManager, NSNumber, NSRange, NSValue, NSObject, URL, NSNotFound, NS_NOT_FOUND};
pub use geometry::{
    CGFloat, CGGlyph, CGPoint, CGRect, CGSize, NSEdgeInsets, NSPoint, NSRect, NSRectEdge, NSSize,
};
pub use nsstring::{NSString, SwiftString};
pub use paragraph_style::{
    NSLineBreakMode, NSLineBreakStrategy, NSMutableParagraphStyle, NSParagraphStyle, NSTextAlignment, NSTextTab,
    NSTextTabOptions, NSUnderlineStyle, NSWritingDirection, NSWritingDirectionFormatType,
};
pub use regex::{
    NSDataDetector, NSRegularExpression, NSRegularExpressionOptions, NSTextCheckingResult,
};
pub use text_table::{
    NSTextBlock, NSTextBlockDimension, NSTextBlockLayer, NSTextBlockValueType,
    NSTextBlockVerticalAlignment, NSTextTable, NSTextTableBlock,
};
pub mod xml_parser;
pub use xml_parser::{XMLParser, XMLParserDelegate};
pub use textkit::{NSLayoutManager, NSScrollView, NSTextContainer, NSTextStorage, NSTextView, NSView, OpenedBand, PageBandDelegate};
