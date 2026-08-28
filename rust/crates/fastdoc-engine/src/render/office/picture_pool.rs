//! One copy of each picture on the wire, instead of one per use.
//!
//! Measured on a 2,562-page government manual: the export the host decodes is 27,169,703 bytes, of
//! which 17,193,764 (63%) are picture bytes — written 692 times for **61 distinct pictures**. 610
//! table cells each carry their own base64 copy of one of 44 background images. The canonical tree
//! does not have this problem: it hashes resources into a table and points at them, and 61 is
//! exactly its anonymous-resource count. The duplication is re-introduced on the way OUT, where the
//! projection expands that table inline at every use.
//!
//! So this moves the bytes into `OfficeReadResult.picture_pool` and leaves each `NSImage` holding
//! the key. The pool is its own field rather than the existing `images` map on purpose: that map's
//! key is the exact `.image(id:)` string a BLOCK carries, and a cell's background has no such id,
//! so filing pooled bytes there would make "is this key drawable by id" unanswerable.
//!
//! Both directions live here, next to each other, because a wire that is written in one place and
//! read in another is the shape that drifts (this module's neighbour `RustEngine.decodeOffice`
//! carries the same note one layer up).
//!
//! The walk is explicit rather than a scoped interner hidden inside `NSImage`'s `Serialize`. A
//! hidden one would need no traversal and would be shorter, but it cannot answer "did you miss a
//! site" — and an explicit walk turns that question into a gate: after interning, no picture's
//! bytes may appear twice in the payload (`payload_composition`'s `DEDUP data` line).

use super::office_block::{
    Cell, OfficeBlock, OfficeMasterObjectContent, OfficeReadResult, TableFormat,
};
use swiftshim::{Data, NSImage, SwiftString};

/// The key a pooled picture is filed under: content-addressed, so two cells that declare the same
/// bytes land on the same entry no matter which document part reached them first.
fn pool_key(data: &Data) -> SwiftString {
    let digest = <sha2::Sha256 as sha2::Digest>::digest(&data.0);
    let mut hex = String::with_capacity(7 + 32);
    hex.push_str("poolimg:");
    for byte in &digest[..16] {
        hex.push_str(&format!("{byte:02x}"));
    }
    SwiftString::from(hex)
}

/// The pool being built, handed to whichever walk is filling it.
///
/// Exists because the v4 JSON is assembled in TWO places — `office_export::to_json` from a whole
/// `OfficeReadResult`, and `office_project` field by field out of the canonical tree — and only the
/// second is reached by a real document today. A pooling that lived in one of them would be a
/// pooling that does nothing.
#[derive(Default)]
pub struct Interner {
    pool: std::collections::HashMap<SwiftString, Data>,
    pooled: usize,
}

impl Interner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn take(&mut self, image: &mut NSImage) {
        let Some(data) = image.data.take() else { return };
        let key = pool_key(&data);
        self.pool.entry(key.clone()).or_insert(data);
        image.data_key = Some(key);
        self.pooled += 1;
    }

    pub fn blocks(&mut self, blocks: &mut [OfficeBlock]) {
        let mut visit = |image: &mut NSImage| self.take(image);
        walk_blocks(blocks, &mut visit);
    }

    pub fn master_content(&mut self, content: &mut OfficeMasterObjectContent) {
        let mut visit = |image: &mut NSImage| self.take(image);
        walk_master_content(content, &mut visit);
    }

    /// `(pooled occurrences, distinct pictures)` and the table itself.
    pub fn finish(self) -> (usize, usize, std::collections::HashMap<SwiftString, Data>) {
        (self.pooled, self.pool.len(), self.pool)
    }
}

/// Move every inline picture's bytes into `result.picture_pool` and leave the key behind.
///
/// Returns how many pictures were pooled and how many distinct entries they became — the pair a
/// caller can assert on, and the pair that says whether a document had anything to gain.
pub fn intern(result: &mut OfficeReadResult) -> (usize, usize) {
    let mut pooled = 0usize;
    let mut pool = std::mem::take(&mut result.picture_pool);

    let mut take = |image: &mut NSImage| {
        let Some(data) = image.data.take() else { return };
        let key = pool_key(&data);
        pool.entry(key.clone()).or_insert(data);
        image.data_key = Some(key);
        pooled += 1;
    };

    walk_result(result, &mut take);
    result.picture_pool = pool;
    let distinct = result.picture_pool.len();
    (pooled, distinct)
}

/// Put the bytes back where a reader would have left them. The inverse of `intern`, so a host or a
/// test that decodes the wire sees exactly the result the reader produced.
pub fn expand(result: &mut OfficeReadResult) -> usize {
    // Drained, not copied: after expanding, the pool is empty again and the result is exactly the
    // one the reader produced — which is what the round-trip check compares.
    let pool = std::mem::take(&mut result.picture_pool);
    let mut restored = 0usize;
    let mut put = |image: &mut NSImage| {
        let Some(key) = image.data_key.take() else { return };
        if let Some(data) = pool.get(&key) {
            image.data = Some(data.clone());
            restored += 1;
        } else {
            // The key outlived its bytes. Leaving `data` empty is the honest answer — the picture
            // is declared and undrawable, which is a state this vocabulary already has a meaning
            // for — but silently is not, so say so once.
            eprintln!("fastdoc: pooled picture {} has no bytes in the image map", key.as_str());
        }
    };
    walk_result(result, &mut put);
    restored
}

/// Every place a picture can sit. Four, and the traversal that reaches them.
fn walk_result(result: &mut OfficeReadResult, visit: &mut impl FnMut(&mut NSImage)) {
    walk_blocks(&mut result.blocks, visit);
    for header in &mut result.headers {
        walk_blocks(&mut header.blocks, visit);
    }
    for footer in &mut result.footers {
        walk_blocks(&mut footer.blocks, visit);
    }
    for footnote in &mut result.footnotes {
        walk_blocks(&mut footnote.blocks, visit);
    }
    for page in &mut result.master_pages {
        for object in &mut page.objects {
            walk_master_content(&mut object.content, visit);
        }
    }
    for anchored in &mut result.anchored_objects {
        walk_master_content(&mut anchored.object.content, visit);
    }
}

fn walk_master_content(
    content: &mut OfficeMasterObjectContent,
    visit: &mut impl FnMut(&mut NSImage),
) {
    match content {
        OfficeMasterObjectContent::Image(image) => visit(image),
        OfficeMasterObjectContent::Text(blocks) => walk_blocks(blocks, visit),
        // `Drawing(Data)` and `Vector(..)` carry no `NSImage` and have no key to be filed under.
        // Measured on the same manual, neither reaches the payload's top forty contributors.
        OfficeMasterObjectContent::Drawing(_) | OfficeMasterObjectContent::Vector(_) => {}
    }
}

fn walk_blocks(blocks: &mut [OfficeBlock], visit: &mut impl FnMut(&mut NSImage)) {
    for block in blocks {
        if let OfficeBlock::Table { rows, format, .. } = block {
            walk_table_format(format, visit);
            for row in rows {
                for cell in row {
                    walk_cell(cell, visit);
                }
            }
        }
    }
}

fn walk_table_format(format: &mut TableFormat, visit: &mut impl FnMut(&mut NSImage)) {
    if let Some(image) = format.background_image.as_mut() {
        visit(image);
    }
}

fn walk_cell(cell: &mut Cell, visit: &mut impl FnMut(&mut NSImage)) {
    if let Some(image) = cell.background_image.as_mut() {
        visit(image);
    }
    walk_blocks(&mut cell.blocks, visit);
}
