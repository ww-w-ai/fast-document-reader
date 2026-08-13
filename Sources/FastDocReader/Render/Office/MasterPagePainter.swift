import AppKit

/// Everything drawing a document's 바탕쪽 needs, gathered the same way `PageBandContent` gathers a
/// running header's — one struct built by the window controller per render, so the draw pass itself
/// looks nothing up.
struct MasterPageContent {
    var pages: [OfficeMasterPage]
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
    static func applicablePage(_ pages: [OfficeMasterPage], pageIndex: Int) -> OfficeMasterPage? {
        let isEvenPageNumber = (pageIndex + 1) % 2 == 0
        if isEvenPageNumber, let even = pages.first(where: { $0.appliesTo == .evenPages }) {
            return even
        }
        return pages.first { $0.appliesTo == .defaultPages } ?? pages.first
    }

    /// Draw every visible sheet's template. `sheets` are in the text view's own flipped coordinates
    /// (`DocumentWindowController.printSheets`), which run the same way a master object's own
    /// coordinates do — down from the paper's top-left — so placing one is an addition and nothing
    /// else. `totalPages` is only needed for a `NUMPAGES` field.
    static func draw(_ content: MasterPageContent, sheets: [CGRect], totalPages: Int,
                     visibleRect: NSRect) {
        guard !content.pages.isEmpty, !sheets.isEmpty else { return }
        for (index, sheet) in sheets.enumerated() where sheet.intersects(visibleRect) {
            guard let page = applicablePage(content.pages, pageIndex: index) else { continue }
            for object in page.objects {
                let rect = NSRect(x: sheet.minX + object.frame.minX, y: sheet.minY + object.frame.minY,
                                  width: object.frame.width, height: object.frame.height)
                guard rect.intersects(visibleRect) else { continue }
                switch object.content {
                case .image(let image):
                    // `respectFlipped` because this view IS flipped and an image drawn without it
                    // arrives upside down — the one place that matters in this file, since the
                    // artwork here is a whole page of it.
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                               respectFlipped: true, hints: nil)
                case .drawing(let pdf):
                    guard let image = NSImage(data: pdf) else { continue }
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                               respectFlipped: true, hints: nil)
                case .text(let blocks):
                    // Built through the SAME `OfficeTextBuilder` the body and every band use
                    // (invariant 29), then given this page's live number by the SAME substitution a
                    // running header's page field goes through — the box holds an ordinary
                    // `MDAttr.pageNumberField` span, so there is no second field mechanism here.
                    let built = OfficeTextBuilder.build(blocks, theme: content.theme,
                                                        columnWidth: rect.width,
                                                        documentDefaultFontSize: content.documentDefaultFontSize,
                                                        pageContentWidth: content.pageContentWidth)
                    guard built.length > 0 else { continue }
                    PageBandPainter.substitutingPageFields(built, page: index + 1,
                                                           totalPages: totalPages).draw(in: rect)
                }
            }
        }
    }
}
