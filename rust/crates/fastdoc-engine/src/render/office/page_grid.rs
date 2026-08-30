//! swift: Render/Office/PageGrid.swift
//! swift-range: 1-2

use swiftshim::CGFloat;
use crate::render::office::office_block::{OfficeSectionDeclaration, PaperGeometry};
use crate::render::office::page_pagination::PagePagination;
use crate::render::office::footnote_band_settle::FootnoteBandSettle;

/// WHERE EACH SHEET IS, when the document does not print every page on the same paper.
///
/// `PagePagination.pitch` answers with ONE number — a page is the strip
/// `[leadingBand + k·pitch, …]` — and every consumer of it (printing, the page count, which section
/// a page belongs to, the margin numbers, the anchored-object pass) does arithmetic on that scalar.
/// That is exact while a document prints on one sheet, and every office format defines a page per
/// SECTION. Measured on `2025 행정업무운영 편람`: 14 sections, 5 distinct geometries — front matter
/// 396.9 × 507.4pt, body 396.9 × 555.6, appendix 413.9 × 612.3 — all typeset at the busiest
/// section's height, so every appendix page is given 56.7pt less than it declares.
///
/// This table is the same arithmetic with the scalar replaced by a per-page value: page *k* has its
/// own height and its own top, and the top of page *k*+1 is the bottom of page *k*. A document that
/// declares one geometry produces exactly the strips `pitch` produces, which is what lets the two
/// live side by side while consumers move over one at a time.
///
/// It does NOT carry width. One container has one width (invariant 57), so a section's wider paper
/// is still typeset at the document's column — recording the height is what a single-column reader
/// can honour, and `paper` keeps the declared width so a caller can see what was not honoured.
// swift: Render/Office/PageGrid.swift:3-143
#[derive(Debug, Clone, PartialEq)]
pub struct PageGrid {
    pub pages: Vec<Page>,
}

/// One sheet: which section it belongs to, the paper it is cut from, and where it sits.
// swift: Render/Office/PageGrid.swift:24-49
#[derive(Debug, Clone, PartialEq)]
pub struct Page {
    /// The section this page is typeset on, as an index into the document's own section list.
    pub section: i64,
    /// The paper that section declared. The height is what this grid spaces pages by; the width
    /// is carried unhonoured (see the type comment).
    pub paper: PaperGeometry,
    /// The repeat distance this page occupies — its content height plus the band the reader
    /// reserves for a running header/footer, exactly as `PagePagination.pitch` composes them.
    pub pitch: CGFloat,
    /// Height at the FOOT of this page reserved for notes cited ON it — 0 on every page that
    /// cites none, which is every page of every document until S14 fills this in.
    ///
    /// DELIBERATELY NOT part of `pitch`. A note does not make the sheet taller; it takes room
    /// away from the body of a sheet whose size the document already declared, which is what
    /// Word and HWP both do. Keeping the pitch uniform is what lets every existing consumer —
    /// the page derivation, printing, the margin numbers, the anchored-object pass — stay
    /// exactly as it is, and it is what keeps `PageBandLayoutDelegate`'s derive-from-the-rect
    /// rule idempotent: the page a line sits on still comes from one division that no note can
    /// move. What a note DOES move is the floor the body may reach, which is
    /// `textTop + pitch - band - noteBand` rather than the sheet's own bottom.
    pub note_band: CGFloat,
    /// The top of this page's TEXT, measured from the top of the first page's text.
    pub text_top: CGFloat,
}

impl Page {
    pub fn new(section: i64, paper: PaperGeometry, pitch: CGFloat, text_top: CGFloat) -> Self {
        Page { section, paper, pitch, note_band: 0.0, text_top }
    }
}

impl PageGrid {
    // swift: Render/Office/PageGrid.swift:50-61
    pub fn count(&self) -> usize {
        self.pages.len()
    }

    /// The grid a document with ONE geometry produces — the scalar rule, expressed as a table, so a
    /// consumer that has moved over keeps working for every document that never needed this.
    // swift: Render/Office/PageGrid.swift:54-62
    pub fn uniform(page_count: i64, pitch: CGFloat, section: i64, paper: PaperGeometry) -> PageGrid {
        let n = page_count.max(0);
        let pages = (0..n)
            .map(|k| Page::new(section, paper.clone(), pitch, (k as CGFloat) * pitch))
            .collect();
        PageGrid { pages }
    }

    /// Builds the table from what the reader already knows: how tall a page's band is, which section
    /// each page belongs to, and what paper that section declared.
    ///
    /// `sectionOfPage` is the SAME question `DocumentWindowController.sectionOfPage` answers from
    /// where the section markers landed in the laid-out text — passed in rather than recomputed, so
    /// there is one answer to it. A page whose section is unknown, or whose section declared no
    /// paper of its own, is cut from `documentPaper`: that is what the reader does today, and a page
    /// table must not change the answer for a document that never stated a second geometry.
    ///
    /// `band` is not per-section here even though a section can hide its own header (invariant 83).
    /// The band is measured once from the reader's own rendering of the running heads
    /// (`PageBandGeometry.measure`), and a section that hides them still reserves the same gap —
    /// changing that is a layout change, not a pagination one.
    // swift: Render/Office/PageGrid.swift:63-95
    pub fn build(
        page_count: i64,
        band: CGFloat,
        document_paper: PaperGeometry,
        sections: &[OfficeSectionDeclaration],
        section_of_page: impl Fn(i64) -> Option<i64>,
        note_band_of_page: impl Fn(i64) -> CGFloat,
    ) -> PageGrid {
        let mut pages: Vec<Page> = Vec::new();
        let mut top: CGFloat = 0.0;
        let n = page_count.max(0);
        for index in 0..n {
            let section = section_of_page(index);
            let declared = section.and_then(|s| {
                if s >= 0 && (s as usize) < sections.len() {
                    sections[s as usize].paper.clone()
                } else {
                    None
                }
            });
            let paper = declared.unwrap_or_else(|| document_paper.clone());
            let pitch = PagePagination::pitch(paper.content_height, band);
            let note = FootnoteBandSettle::clamped(note_band_of_page(index), paper.content_height);
            let mut page = Page::new(section.unwrap_or(0), paper, pitch, top);
            page.note_band = note;
            pages.push(page);
            top += pitch;
        }
        PageGrid { pages }
    }

    /// The lowest a page's BODY may reach — its sheet's own content bottom, less whatever this page
    /// reserves for notes. This is the number an overrun check asks for, and the ONLY place a note
    /// band changes an answer: page tops, the pitch and the page a point falls on are all untouched
    /// (see `Page.noteBand`).
    ///
    /// Out of range extends the last page the same way `textTop` does, so a caller walking off the
    /// end gets the strip the next sheet WOULD have rather than nothing.
    // swift: Render/Office/PageGrid.swift:96-109
    pub fn body_bottom(&self, page: i64) -> CGFloat {
        if self.pages.is_empty() {
            return 0.0;
        }
        let index = page.max(0).min(self.pages.len() as i64 - 1) as usize;
        let p = &self.pages[index];
        self.text_top(page) + p.paper.content_height - p.note_band
    }

    /// The top of page `page`'s TEXT, from the top of the first page's text. Out of range extends the
    /// last page's pitch rather than returning nothing: a caller asking past the end is asking where
    /// the next sheet WOULD start, which is how printing walks off the end of a document.
    // swift: Render/Office/PageGrid.swift:106-131
    pub fn text_top(&self, page: i64) -> CGFloat {
        if self.pages.is_empty() {
            return 0.0;
        }
        if page < 0 {
            return 0.0;
        }
        if (page as usize) < self.pages.len() {
            return self.pages[page as usize].text_top;
        }
        let last = &self.pages[self.pages.len() - 1];
        last.text_top + ((page - self.pages.len() as i64 + 1) as CGFloat) * last.pitch
    }

    /// Which page a point in the text falls on — the inverse of `textTop`, and the lookup that
    /// replaces dividing by the pitch.
    // swift: Render/Office/PageGrid.swift:121-136
    pub fn page(&self, text_y: CGFloat) -> i64 {
        if self.pages.is_empty() {
            return 0;
        }
        if text_y < 0.0 {
            return 0;
        }
        // Linear over pages is honest here: this answers per DRAW, over the handful of pages a
        // window shows, and the tables it walks are hundreds of entries at most. A binary search
        // would be the same answer with more places to be wrong about a boundary.
        for (index, page) in self.pages.iter().enumerate() {
            if text_y < page.text_top + page.pitch {
                return index as i64;
            }
        }
        let last = &self.pages[self.pages.len() - 1];
        let overflow = text_y - (last.text_top + last.pitch);
        self.pages.len() as i64 + (overflow / last.pitch.max(1.0)) as i64
    }

    /// True when every page is cut from the same paper — the case the scalar pitch already gets
    /// exactly right, which is what lets a consumer keep the old path until it is ready.
    // swift: Render/Office/PageGrid.swift:133-143
    pub fn is_uniform(&self) -> bool {
        let Some(first) = self.pages.first() else { return true };
        self.pages.iter().all(|p| p.paper == first.paper)
    }
}
