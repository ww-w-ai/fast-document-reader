//! The document, as it crosses to a host — and the check that says nothing was lost on the way.
//!
//! The one value that cannot cross is an AppKit font descriptor. Images cross as encoded bytes and
//! drawings cross as vector commands for the host painter; neither is silently skipped.
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
pub const SCHEMA_VERSION: u32 = 4;

/// What a read result carried that this boundary cannot.
#[derive(Debug, PartialEq)]
pub enum NotExportable {
    /// A span already has a resolved substitute face. Font resolution belongs to the host and runs
    /// after the read, so a reader producing one means that order changed.
    ResolvedFontDescriptor,
}

impl NotExportable {
    pub fn description(&self) -> &'static str {
        match self {
            Self::ResolvedFontDescriptor => {
                "a span carries a resolved font descriptor, which cannot cross to a host"
            }
        }
    }
}

/// Refuses a result holding anything the envelope would drop.
///
/// Deliberately a hard check rather than a lossy export: a host that renders a document with its
/// pictures missing looks like a rendering bug for as long as it takes someone to find this file.
pub fn assert_exportable(result: &OfficeReadResult) -> Result<(), NotExportable> {
    check_blocks(&result.blocks)?;
    for header in &result.headers {
        check_blocks(&header.blocks)?;
    }
    for footer in &result.footers {
        check_blocks(&footer.blocks)?;
    }
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
            OfficeBlock::Table { rows, .. } => {
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
    check_blocks(&cell.blocks)
}

/// The document as JSON, or what stopped it.
pub fn to_json(result: &OfficeReadResult) -> Result<String, NotExportable> {
    assert_exportable(result)?;
    let envelope = OfficeDocumentEnvelope {
        v: SCHEMA_VERSION,
        result: result.clone(),
    };
    // Serialisation itself cannot fail for this shape — every field is a plain value, there is no
    // map with non-string keys and no custom impl that can error.
    Ok(serde_json::to_string(&envelope).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::office_block::{
        HeaderFooterApplicability, OfficeAnchoredObject, OfficeHeaderFooter, OfficeMasterObject,
        OfficeMasterObjectContent, OfficeMasterPage, ParagraphFormat, Span, TableFormat,
    };
    use swiftshim::{CGRect, CGSize, NSColor, NSFontDescriptor, NSImage};

    fn plain_paragraph(spans: Vec<Span>) -> OfficeBlock {
        OfficeBlock::Paragraph {
            spans,
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format: ParagraphFormat::default(),
        }
    }

    fn resolved_span() -> Span {
        Span {
            resolved_font_descriptor: Some(NSFontDescriptor::default()),
            ..Span::default()
        }
    }

    fn dummy_image() -> NSImage {
        NSImage::withSize(CGSize::new(1.0, 1.0))
    }

    #[test]
    fn accepts_an_empty_result() {
        assert_eq!(assert_exportable(&OfficeReadResult::default()), Ok(()));
    }

    #[test]
    fn refuses_a_resolved_font_descriptor_in_the_body() {
        let result = OfficeReadResult {
            blocks: vec![plain_paragraph(vec![resolved_span()])],
            ..OfficeReadResult::default()
        };
        assert_eq!(
            assert_exportable(&result),
            Err(NotExportable::ResolvedFontDescriptor)
        );
    }

    #[test]
    fn refuses_a_resolved_font_descriptor_in_a_header() {
        let result = OfficeReadResult {
            headers: vec![OfficeHeaderFooter {
                applies_to: HeaderFooterApplicability::DefaultPages,
                blocks: vec![plain_paragraph(vec![resolved_span()])],
                section: None,
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(
            assert_exportable(&result),
            Err(NotExportable::ResolvedFontDescriptor)
        );
    }

    #[test]
    fn refuses_a_resolved_font_descriptor_in_a_footer() {
        let result = OfficeReadResult {
            footers: vec![OfficeHeaderFooter {
                applies_to: HeaderFooterApplicability::DefaultPages,
                blocks: vec![plain_paragraph(vec![resolved_span()])],
                section: None,
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(
            assert_exportable(&result),
            Err(NotExportable::ResolvedFontDescriptor)
        );
    }

    /// S6-3: a master page serializes honestly like an anchored object already does (S6-2, just
    /// below) — `OfficeMasterPage`/`OfficeMasterObject`/`OfficeMasterObjectContent` all already
    /// derive `Serialize`/`Deserialize`, so this boundary was refusing something it could carry.
    #[test]
    fn does_not_refuse_non_empty_master_pages() {
        let result = OfficeReadResult {
            master_pages: vec![OfficeMasterPage {
                section: 0,
                applies_to: HeaderFooterApplicability::DefaultPages,
                objects: vec![],
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(assert_exportable(&result), Ok(()));
    }

    /// S6-2: an anchored object serializes honestly into the envelope like everything else here
    /// (`OfficeAnchoredObject`/`OfficeMasterObject`/`OfficeMasterObjectContent` all already derive
    /// `Serialize`/`Deserialize` — this boundary was refusing something it could already carry).
    /// The Swift decode side already reads it too (`OfficeEnvelopeDecoding.swift`,
    /// `ReaderTextView.swift`'s `officeAnchoredObjects`), which is the native HWP reader's own
    /// path, not this export's — this test only proves the ENGINE's export half no longer refuses.
    #[test]
    fn does_not_refuse_non_empty_anchored_objects() {
        let result = OfficeReadResult {
            anchored_objects: vec![OfficeAnchoredObject {
                block_index: 0,
                object: OfficeMasterObject {
                    frame: CGRect::new(0.0, 0.0, 1.0, 1.0),
                    content: OfficeMasterObjectContent::Image(dummy_image()),
                },
                paragraph_anchor: None,
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(assert_exportable(&result), Ok(()));
    }

    /// S6-4: a table's real picture fill serializes honestly into the envelope like an anchored
    /// object's image already did since S6-2 (`NSImage` derives `Serialize`) — this boundary was
    /// refusing AND silently skipping (`#[serde(skip)]`) something it could already carry. Both
    /// halves check the fix: `assert_exportable` accepts, and the encoded bytes are actually
    /// present in the JSON — proving this is not a refusal lifted while the data still vanishes.
    #[test]
    fn does_not_refuse_a_table_background_image_and_serializes_it() {
        let format = TableFormat {
            background_image: Some(dummy_image()),
            ..TableFormat::default()
        };
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Table {
                rows: vec![],
                header_rows: 0,
                column_widths: vec![],
                format,
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(assert_exportable(&result), Ok(()));
        let json = to_json(&result).unwrap();
        assert!(
            json.contains("\"background_image\""),
            "the table's real picture must appear in the envelope, not vanish silently"
        );
    }

    #[test]
    fn does_not_refuse_a_cell_background_image_and_serializes_it() {
        let cell = Cell {
            background_image: Some(dummy_image()),
            ..Cell::default()
        };
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Table {
                rows: vec![vec![cell]],
                header_rows: 0,
                column_widths: vec![],
                format: TableFormat::default(),
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(assert_exportable(&result), Ok(()));
        let json = to_json(&result).unwrap();
        assert!(json.contains("\"background_image\""));
    }

    #[test]
    fn does_not_refuse_a_background_image_in_a_nested_table_cell() {
        let inner_cell = Cell {
            background_image: Some(dummy_image()),
            ..Cell::default()
        };
        let inner_table = OfficeBlock::Table {
            rows: vec![vec![inner_cell]],
            header_rows: 0,
            column_widths: vec![],
            format: TableFormat::default(),
        };
        let outer_cell = Cell {
            blocks: vec![inner_table],
            ..Cell::default()
        };
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Table {
                rows: vec![vec![outer_cell]],
                header_rows: 0,
                column_widths: vec![],
                format: TableFormat::default(),
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(assert_exportable(&result), Ok(()));
    }

    /// A gradient-only fill (no real picture) exports its DECLARATION, never a rasterized bitmap —
    /// see `office_block::OfficeGradient`'s own doc for why the two fields are never both set.
    #[test]
    fn a_gradient_declaration_serializes_without_a_background_image() {
        let format = TableFormat {
            background_gradient: Some(super::super::office_block::OfficeGradient {
                stops: vec![
                    NSColor::srgb(1.0, 0.0, 0.0, 1.0),
                    NSColor::srgb(0.0, 0.0, 1.0, 1.0),
                ],
                angle_degrees: Some(45.0),
            }),
            ..TableFormat::default()
        };
        let result = OfficeReadResult {
            blocks: vec![OfficeBlock::Table {
                rows: vec![],
                header_rows: 0,
                column_widths: vec![],
                format,
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(assert_exportable(&result), Ok(()));
        let json = to_json(&result).unwrap();
        assert!(json.contains("\"background_gradient\""));
        assert!(
            !json.contains("\"background_image\":{"),
            "no real image was declared — a synthesized bitmap must never appear in its place"
        );
    }

    #[test]
    fn passes_ordinary_footnotes_with_no_resolved_descriptor() {
        let result = OfficeReadResult {
            footnotes: vec![super::super::office_block::OfficeFootnote {
                number: 1,
                blocks: vec![plain_paragraph(vec![Span::default()])],
                section: None,
            }],
            ..OfficeReadResult::default()
        };
        assert_eq!(assert_exportable(&result), Ok(()));
    }
}
