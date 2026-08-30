//! One copy of each paragraph format on the wire, instead of one per paragraph.
//!
//! The third and largest application of the repair `picture_pool` made for pictures and
//! `edge_border_pool` made for per-edge borders. Measured on the same 2,562-page government
//! manual: `format` appears **10,864 times for 1,635 distinct values**, 1,655,374 bytes. That is
//! TWICE the occurrence count of `edge_borders` (5,494) for slightly fewer bytes — and invariant
//! 129 established that the host's bill is the nested container Foundation opens per occurrence,
//! not the bytes inside it. Interning by bytes alone would have ranked this second; interning by
//! what the host pays ranks it first.
//!
//! Two halves, and only one of them needs a pool:
//!
//! - A format that says NOTHING leaves the wire entirely (`ParagraphFormat::is_default` on the
//!   field). Before this, a paragraph declaring no spacing, no indent and no shading still wrote
//!   `"format":{"contextual_spacing":false}` — a container per block for no information.
//! - A format that says something is filed here and replaced by its slot.
//!
//! The design is deliberately the neighbour's, not a new one: an explicit walk (so "did you miss a
//! site" is a gate, not a hope), an index rather than a hash, both directions in one file, and a
//! pool that `from_json` drains so a round-tripped result equals the one the reader produced.
//!
//! Unlike `edge_borders`, `format` is NOT optional in the vocabulary — every paragraph has one, and
//! its default renders byte-identically to a block with no format at all. So the interned state is
//! "format is the default AND a slot is set", and `put` restores the real value over that default.

use super::office_block::{
    Cell, OfficeBlock, OfficeMasterObjectContent, OfficeReadResult, ParagraphFormat,
};

/// The pool being built, and the map from a format to the slot it already occupies.
#[derive(Default)]
pub struct Interner {
    pool: Vec<ParagraphFormat>,
    /// Keyed by the format's own JSON, for the reason its neighbour gives: a total, order-stable
    /// description of a struct of small optionals, cheaper to write than a hand-rolled `Hash` that
    /// would have to be kept in step with the type by hand.
    seen: std::collections::HashMap<String, u32>,
    interned: usize,
}

impl Interner {
    pub fn new() -> Self {
        Self::default()
    }

    fn take(&mut self, format: &mut ParagraphFormat, slot: &mut Option<u32>) {
        // A default format is already absent from the wire — pooling it would trade a missing key
        // for a present one, which is the wrong direction.
        if format.is_default() {
            return;
        }
        let Ok(key) = serde_json::to_string(format) else {
            // Unserialisable here means unserialisable in the payload too, so leaving it inline is
            // the honest move: the wire keeps the shape it always had for this one format.
            return;
        };
        let next = self.pool.len() as u32;
        let index = *self.seen.entry(key).or_insert(next);
        if index == next {
            self.pool.push(*format);
        }
        *format = ParagraphFormat::default();
        *slot = Some(index);
        self.interned += 1;
    }

    pub fn blocks(&mut self, blocks: &mut [OfficeBlock]) {
        for block in blocks {
            match block {
                OfficeBlock::Heading { format, format_ref, .. }
                | OfficeBlock::Paragraph { format, format_ref, .. }
                | OfficeBlock::ListItem { format, format_ref, .. } => self.take(format, format_ref),
                OfficeBlock::Table { rows, .. } => {
                    for row in rows {
                        for cell in row {
                            self.cell(cell);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    fn cell(&mut self, cell: &mut Cell) {
        self.blocks(&mut cell.blocks);
    }

    /// A master-page object's text box holds ordinary blocks, so it holds paragraph formats too.
    /// Measured: leaving this walk out left 409 formats inline on the manual — small next to the
    /// 10,455 that were pooled, but "the walk reaches every site" is the property that makes the
    /// gate meaningful, and a partial walk cannot be told from a complete one by its output.
    pub fn master_content(&mut self, content: &mut OfficeMasterObjectContent) {
        if let OfficeMasterObjectContent::Text(blocks) = content {
            self.blocks(blocks);
        }
    }

    /// `(interned occurrences, distinct formats)` and the table itself.
    pub fn finish(self) -> (usize, usize, Vec<ParagraphFormat>) {
        (self.interned, self.pool.len(), self.pool)
    }
}

/// Move every paragraph's non-default format into `result.paragraph_format_pool`, leaving the slot
/// behind. Returns `(interned, distinct)` — the pair that says whether a document had anything to
/// gain, and the pair a gate can assert on.
pub fn intern(result: &mut OfficeReadResult) -> (usize, usize) {
    let mut interner = Interner::new();
    walk_result(result, &mut interner);
    let (interned, distinct, pool) = interner.finish();
    result.paragraph_format_pool = pool;
    (interned, distinct)
}

/// Put the formats back where a reader would have left them — the inverse of `intern`, so a host or
/// a test that decodes the wire sees exactly the result the reader produced.
pub fn expand(result: &mut OfficeReadResult) -> usize {
    // Drained, not copied: after expanding, the pool is empty again and the result is exactly the
    // one the reader produced, which is what makes the round-trip check meaningful.
    let pool = std::mem::take(&mut result.paragraph_format_pool);
    let mut restored = 0usize;
    put_blocks(&mut result.blocks, &pool, &mut restored);
    for page in &mut result.master_pages {
        for object in &mut page.objects {
            put_master_content(&mut object.content, &pool, &mut restored);
        }
    }
    for anchored in &mut result.anchored_objects {
        put_master_content(&mut anchored.object.content, &pool, &mut restored);
    }
    for header in &mut result.headers {
        put_blocks(&mut header.blocks, &pool, &mut restored);
    }
    for footer in &mut result.footers {
        put_blocks(&mut footer.blocks, &pool, &mut restored);
    }
    for footnote in &mut result.footnotes {
        put_blocks(&mut footnote.blocks, &pool, &mut restored);
    }
    restored
}

fn walk_result(result: &mut OfficeReadResult, interner: &mut Interner) {
    interner.blocks(&mut result.blocks);
    for page in &mut result.master_pages {
        for object in &mut page.objects {
            interner.master_content(&mut object.content);
        }
    }
    for anchored in &mut result.anchored_objects {
        interner.master_content(&mut anchored.object.content);
    }
    for header in &mut result.headers {
        interner.blocks(&mut header.blocks);
    }
    for footer in &mut result.footers {
        interner.blocks(&mut footer.blocks);
    }
    for footnote in &mut result.footnotes {
        interner.blocks(&mut footnote.blocks);
    }
}

fn put(format: &mut ParagraphFormat, slot: &mut Option<u32>, pool: &[ParagraphFormat],
       restored: &mut usize) {
    let Some(index) = slot.take() else { return };
    match pool.get(index as usize) {
        Some(value) => {
            *format = *value;
            *restored += 1;
        }
        // The slot outlived its table. Leaving the default in place is the state this vocabulary
        // already means "the document said nothing" by — but silently is not, so say it once.
        None => eprintln!("fastdoc: pooled paragraph format {index} is not in the table"),
    }
}

fn put_master_content(content: &mut OfficeMasterObjectContent, pool: &[ParagraphFormat],
                      restored: &mut usize) {
    if let OfficeMasterObjectContent::Text(blocks) = content {
        put_blocks(blocks, pool, restored);
    }
}

fn put_blocks(blocks: &mut [OfficeBlock], pool: &[ParagraphFormat], restored: &mut usize) {
    for block in blocks {
        match block {
            OfficeBlock::Heading { format, format_ref, .. }
            | OfficeBlock::Paragraph { format, format_ref, .. }
            | OfficeBlock::ListItem { format, format_ref, .. } => {
                put(format, format_ref, pool, restored);
            }
            OfficeBlock::Table { rows, .. } => {
                for row in rows {
                    for cell in row {
                        put_blocks(&mut cell.blocks, pool, restored);
                    }
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::office::office_block::{Cell, OfficeBlock, TableFormat};

    fn spaced(before: f64) -> ParagraphFormat {
        ParagraphFormat { spacing_before: Some(before), ..ParagraphFormat::default() }
    }

    fn paragraph(format: ParagraphFormat) -> OfficeBlock {
        OfficeBlock::Paragraph {
            spans: vec![],
            rtl: false,
            alignment: None,
            tab_stops: vec![],
            format,
            format_ref: None,
        }
    }

    /// The claim the whole module rests on: many uses of a handful of formats become a handful of
    /// entries, and every use points at the RIGHT one.
    #[test]
    fn repeated_formats_become_one_entry_each() {
        let mut result = OfficeReadResult {
            blocks: vec![paragraph(spaced(6.0)), paragraph(spaced(12.0)), paragraph(spaced(6.0)),
                         paragraph(spaced(6.0)), paragraph(spaced(12.0))],
            ..Default::default()
        };
        let before = result.clone();

        let (interned, distinct) = intern(&mut result);
        assert_eq!((interned, distinct), (5, 2));
        assert_eq!(result.paragraph_format_pool, vec![spaced(6.0), spaced(12.0)]);

        let restored = expand(&mut result);
        assert_eq!(restored, 5);
        assert!(result.paragraph_format_pool.is_empty());
        assert_eq!(result, before);
    }

    /// A format that says nothing is left alone — it is already absent from the wire, and giving it
    /// a slot would add a key rather than remove one.
    #[test]
    fn a_format_that_says_nothing_is_not_pooled() {
        let mut result = OfficeReadResult {
            blocks: vec![paragraph(ParagraphFormat::default()); 4],
            ..Default::default()
        };
        assert_eq!(intern(&mut result), (0, 0));
        assert!(result.paragraph_format_pool.is_empty());
    }

    /// The walk reaches a paragraph nested inside a table cell. This is the site an interner that
    /// only looked at top-level blocks would miss, and on the measured manual it is the MAJORITY:
    /// 6,649 of the 10,864 occurrences are inside cells.
    #[test]
    fn a_paragraph_inside_a_cell_is_reached() {
        let cell = Cell { blocks: vec![paragraph(spaced(6.0))], ..Cell::default() };
        let mut result = OfficeReadResult {
            blocks: vec![OfficeBlock::Table {
                rows: vec![vec![cell]],
                header_rows: 0,
                column_widths: vec![],
                format: TableFormat::default(),
            }],
            ..Default::default()
        };
        let before = result.clone();
        assert_eq!(intern(&mut result), (1, 1));
        assert_eq!(expand(&mut result), 1);
        assert_eq!(result, before);
    }

    /// A slot with no entry behind it leaves the paragraph saying nothing rather than crashing —
    /// the same "broken envelope degrades to the vocabulary's own null state" contract its
    /// neighbour keeps.
    #[test]
    fn a_slot_with_no_entry_leaves_the_default() {
        let mut result = OfficeReadResult {
            blocks: vec![OfficeBlock::Paragraph {
                spans: vec![], rtl: false, alignment: None, tab_stops: vec![],
                format: ParagraphFormat::default(), format_ref: Some(7),
            }],
            ..Default::default()
        };
        assert_eq!(expand(&mut result), 0);
        let OfficeBlock::Paragraph { format, format_ref, .. } = &result.blocks[0] else {
            panic!("the block changed shape")
        };
        assert!(format.is_default());
        assert_eq!(*format_ref, None);
    }
}
