import AppKit

/// Everything drawing a document's 바탕쪽 needs, gathered the same way `PageBandContent` gathers a
/// running header's — one struct built by the window controller per render, so the draw pass itself
/// looks nothing up.
struct MasterPageContent {
    var pages: [OfficeMasterPage]
    /// Sections that turned their own master page OFF. A veto the document itself declared, so a
    /// cover that says "no 바탕쪽" gets none even though its section declares templates.
    var sectionsHidingMasterPage: Set<Int> = []
    var theme: RenderTheme
    var documentDefaultFontSize: CGFloat
    var pageContentWidth: CGFloat?
}

/// Paints the template a Korean document repeats behind every page — the full-page artwork, the tab
/// down the outer edge, the ruled title line and the page number.
///
/// WHY THIS IS NOT `PageBandPainter`. A running header is a flow laid into a band the reader
/// RESERVED between two pages; a master page is a set of pieces pinned to the SHEET, over the body
/// text as often as beside it. So this needs no band, no reservation and no per-page arithmetic of
/// its own: it takes the sheet rectangles `PagePagination` already computed — the same ones the
/// screen draws and the printer prints (invariant 59) — and puts each object where the paper says.
///
/// It is NOT gated on drawing to screen. The page number a reader sees here IS the document
/// (invariant 77: rhwp's own header and footer bands are empty on a body page and the number comes
/// from the master page), so a printout without it would be missing the document's own furniture.
enum MasterPagePainter {

    /// Which template covers page `pageIndex` (0-based) — the same selection a running header makes,
    /// through the same two-case vocabulary: an `.evenPages` template covers the even PAGE NUMBERS
    /// (page index 1, 3, … — the human's page 2, 4, …), and everything else is covered by the
    /// default one. A document with only an even template leaves the odd pages bare, which is what
    /// it asked for.
    static func applicablePage(_ pages: [OfficeMasterPage], pageIndex: Int,
                               section: Int? = nil) -> OfficeMasterPage? {
        // THE SECTION FIRST. A master page belongs to its own section, and a document that flattens
        // every section into one column still shows each section's own pages — so a page is matched
        // to its section's templates and only then to the parity among them. `nil` (a parser that
        // never said where a section starts) falls back to every template there is, which is the
        // single-answer behaviour this had before per-page selection.
        let candidates = section.map { s in pages.filter { $0.section == s } } ?? pages
        guard !candidates.isEmpty else { return nil }
        let isEvenPageNumber = (pageIndex + 1) % 2 == 0
        if isEvenPageNumber, let even = candidates.first(where: { $0.appliesTo == .evenPages }) {
            return even
        }
        return candidates.first { $0.appliesTo == .defaultPages } ?? candidates.first
    }

    /// Draw every visible sheet's template. `sheets` are in the text view's own flipped coordinates
    /// (`DocumentWindowController.printSheets`), which run the same way a master object's own
    /// coordinates do — down from the paper's top-left — so placing one is an addition and nothing
    /// else. `totalPages` is only needed for a `NUMPAGES` field.
    /// `sectionOfPage` answers which section a given page (0-based) is typeset on — see
    /// `DocumentWindowController.sectionOfPage`, which resolves it from where the section markers
    /// landed in the laid-out text. Returning `nil` for a page means "unknown", and that page falls
    /// back to every template rather than to none.
    static func draw(_ content: MasterPageContent, sheets: [CGRect], totalPages: Int,
                     visibleRect: NSRect, sectionOfPage: (Int) -> Int? = { _ in nil }) {
        guard !content.pages.isEmpty, !sheets.isEmpty else { return }
        for (index, sheet) in sheets.enumerated() where sheet.intersects(visibleRect) {
            let section = sectionOfPage(index)
            // THE SECTION'S OWN VETO, before anything is chosen: a section that hides its master
            // page shows none, however many templates the document declares for it.
            if let section, content.sectionsHidingMasterPage.contains(section) { continue }
            guard let page = applicablePage(content.pages, pageIndex: index,
                                            section: section) else { continue }
            for object in page.objects {
                draw(object, onSheet: sheet, pageIndex: index, totalPages: totalPages,
                     content: content, visibleRect: visibleRect)
            }
        }
    }

    /// ONE object, on ONE sheet — shared by the master page and by an object the document pinned to
    /// the paper at a particular place in the text (`OfficeAnchoredObject`). They differ only in
    /// WHICH pages they appear on; where they go on a page, and how they are drawn, is one rule.
    static func draw(_ object: OfficeMasterObject, onSheet sheet: CGRect, pageIndex: Int,
                     totalPages: Int, content: MasterPageContent, visibleRect: NSRect) {
        let rect = NSRect(x: sheet.minX + object.frame.minX, y: sheet.minY + object.frame.minY,
                          width: object.frame.width, height: object.frame.height)
        guard rect.intersects(visibleRect) else { return }
        // CLIPPED TO ITS OWN SHEET. An object can be taller or wider than the paper it is pinned to
        // — a chapter divider's numeral is 736pt on a 754pt sheet and sits low — and with no clip its
        // ink ran off the paper, across the desk gap and onto the NEXT page, which is where the
        // second running header a reader saw beside it came from. Printing never showed this because
        // each printed page clips to its own sheet by construction; only the screen, which draws
        // every sheet into one continuous view, could. Paper is paper: ink outside it is not the
        // document.
        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        defer { ctx?.restoreGraphicsState() }
        ctx?.cgContext.clip(to: sheet)
        switch object.content {
        case .image(let image):
            // `respectFlipped` because this view IS flipped and an image drawn without it arrives
            // upside down — the one place that matters in this file, since the artwork here is a
            // whole page of it.
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        case .drawing(let pdf):
            guard let image = NSImage(data: pdf) else { return }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        case .text(let blocks):
            // Built through the SAME `OfficeTextBuilder` the body and every band use (invariant 29),
            // then given this page's live number by the SAME substitution a running header's page
            // field goes through — the box holds an ordinary `MDAttr.pageNumberField` span, so there
            // is no second field mechanism here.
            let built = OfficeTextBuilder.build(blocks, theme: content.theme,
                                                columnWidth: rect.width,
                                                documentDefaultFontSize: content.documentDefaultFontSize,
                                                pageContentWidth: content.pageContentWidth)
            guard built.length > 0 else { return }
            PageBandPainter.substitutingPageFields(built, page: pageIndex + 1,
                                                   totalPages: totalPages).draw(in: rect)
        }
    }
}
