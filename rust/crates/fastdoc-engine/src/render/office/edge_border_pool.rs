//! One copy of each per-edge border declaration on the wire, instead of one per cell.
//!
//! The same repair `picture_pool` makes for pictures, applied to the field that is next-largest
//! after them. Measured on the same 2,562-page government manual: the export the host decodes
//! carries `edge_borders` **5,494 times for 274 distinct declarations**, 1,827,829 bytes. A table
//! silences or draws the same four edges over and over; the document has a handful of looks and
//! thousands of cells wearing them.
//!
//! What made this worth doing rather than estimating is that the COST was measured, not the bytes:
//! deleting the field from a real payload and decoding it through the shipping path took the host
//! from **585.0 ms to 445.5 ms** (invariant 129). The bytes were never the point — Foundation's
//! `Decodable` opens a nested container per occurrence, and 5,494 of those is the bill.
//!
//! The design is deliberately the neighbour's, not a new one: an explicit walk (so "did you miss a
//! site" is a gate, not a hope), an index rather than a hash (these are small structs, and a
//! content hash would cost more than the value it keys), both directions in one file, and a pool
//! that `from_json` drains so a round-tripped result equals the one the reader produced.

use super::office_block::{Cell, EdgeBorders, OfficeBlock, OfficeReadResult, TableFormat};

/// The pool being built, and the map from a declaration to the slot it already occupies.
#[derive(Default)]
pub struct Interner {
    pool: Vec<EdgeBorders>,
    /// Keyed by the declaration's own JSON, which is a total, order-stable description of a struct
    /// whose fields are four small enums — cheaper to write than a hand-rolled `Hash` that would
    /// have to be kept in step with the type by hand.
    seen: std::collections::HashMap<String, u32>,
    interned: usize,
}

impl Interner {
    pub fn new() -> Self {
        Self::default()
    }

    fn take(&mut self, borders: &mut Option<EdgeBorders>, slot: &mut Option<u32>) {
        let Some(value) = borders.take() else { return };
        let Ok(key) = serde_json::to_string(&value) else {
            // Unserialisable here means unserialisable in the payload too, so putting it back is
            // the honest move: the wire keeps the shape it always had for this one declaration.
            *borders = Some(value);
            return;
        };
        let next = self.pool.len() as u32;
        let index = *self.seen.entry(key).or_insert(next);
        if index == next {
            self.pool.push(value);
        }
        *slot = Some(index);
        self.interned += 1;
    }

    pub fn blocks(&mut self, blocks: &mut [OfficeBlock]) {
        for block in blocks {
            if let OfficeBlock::Table { rows, format, .. } = block {
                self.table_format(format);
                for row in rows {
                    for cell in row {
                        self.cell(cell);
                    }
                }
            }
        }
    }

    fn table_format(&mut self, format: &mut TableFormat) {
        let (borders, slot) = (&mut format.edge_borders, &mut format.edge_borders_ref);
        self.take(borders, slot);
    }

    fn cell(&mut self, cell: &mut Cell) {
        let (borders, slot) = (&mut cell.edge_borders, &mut cell.edge_borders_ref);
        self.take(borders, slot);
        self.blocks(&mut cell.blocks);
    }

    /// `(interned occurrences, distinct declarations)` and the table itself.
    pub fn finish(self) -> (usize, usize, Vec<EdgeBorders>) {
        (self.interned, self.pool.len(), self.pool)
    }
}

/// Move every cell's and table's per-edge declaration into `result.edge_border_pool`, leaving the
/// slot behind. Returns `(interned, distinct)` — the pair that says whether a document had anything
/// to gain, and the pair a gate can assert on.
pub fn intern(result: &mut OfficeReadResult) -> (usize, usize) {
    let mut interner = Interner::new();
    walk_result(result, &mut interner);
    let (interned, distinct, pool) = interner.finish();
    result.edge_border_pool = pool;
    (interned, distinct)
}

/// Put the declarations back where a reader would have left them — the inverse of `intern`, so a
/// host or a test that decodes the wire sees exactly the result the reader produced.
pub fn expand(result: &mut OfficeReadResult) -> usize {
    // Drained, not copied: after expanding, the pool is empty again and the result is exactly the
    // one the reader produced, which is what makes the round-trip check meaningful.
    let pool = std::mem::take(&mut result.edge_border_pool);
    let mut restored = 0usize;
    put_blocks(&mut result.blocks, &pool, &mut restored);
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

fn put(borders: &mut Option<EdgeBorders>, slot: &mut Option<u32>, pool: &[EdgeBorders],
       restored: &mut usize) {
    let Some(index) = slot.take() else { return };
    match pool.get(index as usize) {
        Some(value) => {
            *borders = Some(value.clone());
            *restored += 1;
        }
        // The slot outlived its table. Leaving the edges unset is the state this vocabulary already
        // means "the document said nothing per-edge" by — but silently is not, so say it once.
        None => eprintln!("fastdoc: pooled edge borders {index} are not in the table"),
    }
}

fn put_blocks(blocks: &mut [OfficeBlock], pool: &[EdgeBorders], restored: &mut usize) {
    for block in blocks {
        if let OfficeBlock::Table { rows, format, .. } = block {
            put(&mut format.edge_borders, &mut format.edge_borders_ref, pool, restored);
            for row in rows {
                for cell in row {
                    put(&mut cell.edge_borders, &mut cell.edge_borders_ref, pool, restored);
                    put_blocks(&mut cell.blocks, pool, restored);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::office::office_block::{BorderDecl, EdgeBorders, OfficeBlock, TableFormat};

    fn silenced() -> EdgeBorders {
        EdgeBorders {
            top: Some(BorderDecl::Suppressed),
            left: Some(BorderDecl::Suppressed),
            bottom: Some(BorderDecl::Suppressed),
            right: Some(BorderDecl::Suppressed),
            ..Default::default()
        }
    }

    fn open() -> EdgeBorders {
        EdgeBorders {
            top: Some(BorderDecl::Suppressed),
            ..Default::default()
        }
    }

    fn table_of(cells: Vec<EdgeBorders>) -> OfficeBlock {
        let row: Vec<Cell> = cells
            .into_iter()
            .map(|borders| Cell {
                edge_borders: Some(borders),
                ..Cell::default()
            })
            .collect();
        OfficeBlock::Table {
            rows: vec![row],
            header_rows: 0,
            column_widths: vec![],
            format: TableFormat::default(),
        }
    }

    /// The claim the whole module rests on: many uses of a handful of declarations become a handful
    /// of entries, and every use points at the RIGHT one.
    #[test]
    fn repeated_declarations_become_one_entry_each() {
        let mut result = OfficeReadResult {
            blocks: vec![table_of(vec![silenced(), open(), silenced(), silenced(), open()])],
            ..Default::default()
        };
        let (interned, distinct) = intern(&mut result);
        assert_eq!((interned, distinct), (5, 2));
        assert_eq!(result.edge_border_pool.len(), 2);

        // Every cell now carries a slot and no declaration of its own.
        let OfficeBlock::Table { rows, .. } = &result.blocks[0] else { panic!("a table") };
        let slots: Vec<Option<u32>> = rows[0].iter().map(|c| c.edge_borders_ref).collect();
        assert_eq!(slots, vec![Some(0), Some(1), Some(0), Some(0), Some(1)]);
        assert!(rows[0].iter().all(|c| c.edge_borders.is_none()));
    }

    /// `expand` must put back exactly what `intern` took, or the wire is lossy in a way no test
    /// that only counts bytes would see.
    #[test]
    fn expanding_restores_the_result_that_was_interned() {
        let before = OfficeReadResult {
            blocks: vec![table_of(vec![silenced(), open(), silenced()])],
            ..Default::default()
        };
        let mut after = before.clone();
        intern(&mut after);
        assert_ne!(after, before, "interning must actually change the wire shape");
        let restored = expand(&mut after);
        assert_eq!(restored, 3);
        assert_eq!(after, before);
        assert!(after.edge_border_pool.is_empty(), "the pool is drained, not copied");
    }

    /// A document with nothing to gain must not grow a field. The projection oracle compares this
    /// assembler against the exporter's output, and a pool written as `[]` by one and omitted by
    /// the other is a disagreement even when both mean "nothing was pooled".
    #[test]
    fn a_document_with_no_edge_declarations_gets_no_pool() {
        let mut result = OfficeReadResult {
            blocks: vec![table_of(vec![])],
            ..Default::default()
        };
        assert_eq!(intern(&mut result), (0, 0));
        assert!(result.edge_border_pool.is_empty());
        assert!(serde_json::to_string(&result).unwrap().find("edge_border_pool").is_none());
    }
}
