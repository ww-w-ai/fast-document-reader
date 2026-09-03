import XCTest
import AppKit
@testable import FastDocReader

/// Turning margin numbers off must take the page-number desk with them, in the same turn.
///
/// `applyMarginNumbers` set only `textView.marginNumbers`; the desk was attached and detached by
/// `syncPageNumberDesk`, reached solely from `applyPagedViewState`. So the View menu's tick and the
/// window disagreed until some unrelated reflow — a resize, a zoom, a page-option toggle — happened
/// to run, which is exactly the kind of "it fixes itself if you touch something else" the reader
/// must not ship.
final class MarginNumberDeskSyncTests: XCTestCase {

    private func pagedWindow() throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("desk-\(UUID().uuidString).docx")
        let body = (1...120).map { i in
            OfficeBlock.paragraph(spans: [Span(text: "Paragraph number \(i) of the body text.")])
        }
        doc.setOfficeContent(
            blocks: body, archive: nil, defaultBodyFontSize: 11,
            pageContentWidth: 400, pageMarginLeft: 50, pageMarginRight: 50,
            pageContentHeight: 500, pageMarginTop: 60, pageMarginBottom: 40,
            pageHeaderDistance: 20, pageFooterDistance: 20,
            headers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "Running header")])])],
            footers: [OfficeHeaderFooter(appliesTo: .defaultPages,
                                         blocks: [.paragraph(spans: [Span(text: "Running footer")])])])
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        return (doc, wc)
    }

    func testTheDeskFollowsTheToggleWithoutAnyOtherReflow() throws {
        let was = MarginNumberStore.isOn
        defer { MarginNumberStore.isOn = was }
        let (_, wc) = try pagedWindow()
        try XCTSkipUnless(wc.isPaged, "needs a paged document for the desk to exist at all")

        MarginNumberStore.isOn = true
        wc.applyMarginNumbers()
        XCTAssertNotNil(wc.pageNumberDesk?.superview, "the desk did not attach when numbers went on")

        MarginNumberStore.isOn = false
        wc.applyMarginNumbers()
        XCTAssertNil(wc.pageNumberDesk?.superview, "the desk stayed on screen after numbers went off")
    }
}
