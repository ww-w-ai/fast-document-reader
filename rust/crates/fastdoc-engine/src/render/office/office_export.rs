//! The document, as it crosses to a host — and the check that says nothing was lost on the way.
//!
//! Five places in the vocabulary hold something that cannot be written down: an AppKit font
//! descriptor, decoded picture bytes, a pre-rendered vector drawing. They are `#[serde(skip)]`, and
//! a skip on its own is the quietest kind of data loss — the document still arrives, still renders,
//! just without the thing that was dropped, and nothing says so.
//!
//! So the skips are paired with `assert_exportable`. Every one of them is empty for the readers
//! this boundary carries — the zip readers leave pictures in the archive for the host to resolve,
//! and font resolution happens on the host AFTER the read — so the check costs nothing today and
//! turns "silently degraded" into "refused, by name" the day it stops being true.

use super::office_block::{Cell, OfficeBlock, OfficeReadResult};

/// The envelope a host decodes. `v` is first and is checked first.
///
/// A version was put here before anything needed one, per `docs/CROSS-PLATFORM.md` §2: adding it
/// later is itself the breaking change, because by then something is already reading a document
/// that has no version to check. The engine and the host ship separately — the engine is a
/// prebuilt library — so "they are always built together" is not a promise this project can make.
#[derive(serde::Serialize, serde::Deserialize)]
pub struct OfficeDocumentEnvelope {
    pub v: u32,
    #[serde(flatten)]
    pub result: OfficeReadResult,
}

/// The version this build writes. Bump when the shape changes in a way a host must notice.
pub const SCHEMA_VERSION: u32 = 2;

/// What a read result carried that this boundary cannot.
#[derive(Debug, PartialEq)]
pub enum NotExportable {
    /// A span already has a resolved substitute face. Font resolution belongs to the host and runs
    /// after the read, so a reader producing one means that order changed.
    ResolvedFontDescriptor,
    /// A table or cell carries decoded picture pixels.
    BackgroundImage,
    /// Master pages (바탕쪽) or paragraph-anchored objects: pictures and pre-rendered drawings.
    PaperObjects,
}

impl NotExportable {
    pub fn description(&self) -> &'static str {
        match self {
            Self::ResolvedFontDescriptor => "a span carries a resolved font descriptor, which cannot cross to a host",
            Self::BackgroundImage => "a table or cell carries decoded picture pixels",
            Self::PaperObjects => "the document carries master-page or anchored objects",
        }
    }
}

/// Refuses a result holding anything the envelope would drop.
///
/// Deliberately a hard check rather than a lossy export: a host that renders a document with its
/// pictures missing looks like a rendering bug for as long as it takes someone to find this file.
pub fn assert_exportable(result: &OfficeReadResult) -> Result<(), NotExportable> {
    if !result.master_pages.is_empty() || !result.anchored_objects.is_empty() {
        return Err(NotExportable::PaperObjects);
    }
    check_blocks(&result.blocks)?;
    for footnote in &result.footnotes {
        check_blocks(&footnote.blocks)?;
    }
    Ok(())
}

fn check_blocks(blocks: &[OfficeBlock]) -> Result<(), NotExportable> {
    for block in blocks {
        match block {
            OfficeBlock::Heading { spans, .. }
            | OfficeBlock::Paragraph { spans, .. }
            | OfficeBlock::ListItem { spans, .. } => {
                if spans.iter().any(|s| s.resolved_font_descriptor.is_some()) {
                    return Err(NotExportable::ResolvedFontDescriptor);
                }
            }
            OfficeBlock::Table { rows, format, .. } => {
                if format.background_image.is_some() {
                    return Err(NotExportable::BackgroundImage);
                }
                for row in rows {
                    for cell in row {
                        check_cell(cell)?;
                    }
                }
            }
            OfficeBlock::Image { .. }
            | OfficeBlock::UnsupportedGraphic { .. }
            | OfficeBlock::Formula { .. } => {}
        }
    }
    Ok(())
}

fn check_cell(cell: &Cell) -> Result<(), NotExportable> {
    if cell.background_image.is_some() {
        return Err(NotExportable::BackgroundImage);
    }
    check_blocks(&cell.blocks)
}

/// The document as JSON, or what stopped it.
pub fn to_json(result: &OfficeReadResult) -> Result<String, NotExportable> {
    assert_exportable(result)?;
    let envelope = OfficeDocumentEnvelope { v: SCHEMA_VERSION, result: result.clone() };
    // Serialisation itself cannot fail for this shape — every field is a plain value, there is no
    // map with non-string keys and no custom impl that can error.
    Ok(serde_json::to_string(&envelope).unwrap_or_default())
}
