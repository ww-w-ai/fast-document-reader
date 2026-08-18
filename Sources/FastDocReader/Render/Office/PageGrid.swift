import Foundation
import CoreGraphics

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
struct PageGrid: Equatable {

    /// One sheet: which section it belongs to, the paper it is cut from, and where it sits.
    struct Page: Equatable {
        /// The section this page is typeset on, as an index into the document's own section list.
        var section: Int
        /// The paper that section declared. The height is what this grid spaces pages by; the width
        /// is carried unhonoured (see the type comment).
        var paper: PaperGeometry
        /// The repeat distance this page occupies — its content height plus the band the reader
        /// reserves for a running header/footer, exactly as `PagePagination.pitch` composes them.
        var pitch: CGFloat
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
        var noteBand: CGFloat = 0
        /// The top of this page's TEXT, measured from the top of the first page's text.
        var textTop: CGFloat
    }

    var pages: [Page]

    var count: Int { pages.count }

    /// The grid a document with ONE geometry produces — the scalar rule, expressed as a table, so a
    /// consumer that has moved over keeps working for every document that never needed this.
    static func uniform(pageCount: Int, pitch: CGFloat, section: Int = 0,
                        paper: PaperGeometry) -> PageGrid {
        PageGrid(pages: (0..<max(0, pageCount)).map {
            Page(section: section, paper: paper, pitch: pitch, textTop: CGFloat($0) * pitch)
        })
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
    static func build(pageCount: Int, band: CGFloat, documentPaper: PaperGeometry,
                      sections: [OfficeSectionDeclaration],
                      sectionOfPage: (Int) -> Int?,
                      noteBandOfPage: (Int) -> CGFloat = { _ in 0 }) -> PageGrid {
        var pages: [Page] = []
        var top: CGFloat = 0
        for index in 0..<max(0, pageCount) {
            let section = sectionOfPage(index)
            let declared = section.flatMap { sections.indices.contains($0) ? sections[$0].paper : nil }
            let paper = declared ?? documentPaper
            let pitch = PagePagination.pitch(pageContentHeight: paper.contentHeight, band: band)
            let note = FootnoteBandSettle.clamped(noteBandOfPage(index),
                                                  pageContentHeight: paper.contentHeight)
            pages.append(Page(section: section ?? 0, paper: paper, pitch: pitch,
                              noteBand: note, textTop: top))
            top += pitch
        }
        return PageGrid(pages: pages)
    }

    /// The lowest a page's BODY may reach — its sheet's own content bottom, less whatever this page
    /// reserves for notes. This is the number an overrun check asks for, and the ONLY place a note
    /// band changes an answer: page tops, the pitch and the page a point falls on are all untouched
    /// (see `Page.noteBand`).
    ///
    /// Out of range extends the last page the same way `textTop` does, so a caller walking off the
    /// end gets the strip the next sheet WOULD have rather than nothing.
    func bodyBottom(ofPage page: Int) -> CGFloat {
        guard !pages.isEmpty else { return 0 }
        let index = min(max(0, page), pages.count - 1)
        let p = pages[index]
        return textTop(ofPage: page) + p.paper.contentHeight - p.noteBand
    }

    /// The top of page `page`'s TEXT, from the top of the first page's text. Out of range extends the
    /// last page's pitch rather than returning nothing: a caller asking past the end is asking where
    /// the next sheet WOULD start, which is how printing walks off the end of a document.
    func textTop(ofPage page: Int) -> CGFloat {
        guard !pages.isEmpty else { return 0 }
        if page < 0 { return 0 }
        if page < pages.count { return pages[page].textTop }
        let last = pages[pages.count - 1]
        return last.textTop + CGFloat(page - pages.count + 1) * last.pitch
    }

    /// Which page a point in the text falls on — the inverse of `textTop`, and the lookup that
    /// replaces dividing by the pitch.
    func page(containing textY: CGFloat) -> Int {
        guard !pages.isEmpty else { return 0 }
        if textY < 0 { return 0 }
        // Linear over pages is honest here: this answers per DRAW, over the handful of pages a
        // window shows, and the tables it walks are hundreds of entries at most. A binary search
        // would be the same answer with more places to be wrong about a boundary.
        for (index, page) in pages.enumerated() where textY < page.textTop + page.pitch {
            return index
        }
        let last = pages[pages.count - 1]
        let overflow = textY - (last.textTop + last.pitch)
        return pages.count + Int(overflow / max(1, last.pitch))
    }

    /// True when every page is cut from the same paper — the case the scalar pitch already gets
    /// exactly right, which is what lets a consumer keep the old path until it is ready.
    var isUniform: Bool {
        guard let first = pages.first else { return true }
        return pages.allSatisfy { $0.paper == first.paper }
    }
}
