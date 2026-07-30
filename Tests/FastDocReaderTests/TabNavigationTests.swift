import XCTest
import AppKit
@testable import FastDocReader

/// Reaching a specific tab: ⌘1…⌘8 by number, ⌘9 for the last, ⌥⌘←/→ for the neighbours.
///
/// ⌃⇥ / ⌃⇧⇥ already cycled — AppKit binds those to the tab group itself — but there was no way to
/// reach a specific document, which is what a reader with six open wants.
///
/// The tab GROUP is AppKit's and cannot be assembled headlessly (`NSWindow.tabGroup` is nil until the
/// window server actually tabs two windows together), so what is asserted here is the decision layer:
/// which index a menu item resolves to, and when the item is offered at all. The jump itself is one
/// assignment to `tabGroup.selectedWindow`.
final class TabNavigationTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    /// ⌘1…⌘8 are 0-based positions in the TAB BAR's own order.
    func testANumberedItemResolvesToThatTabPosition() throws {
        let (_, wc) = try openMarkdown()
        XCTAssertEqual(wc.tabIndex(for: item(tag: 1)), 0)
        XCTAssertEqual(wc.tabIndex(for: item(tag: 2)), 1)
        XCTAssertEqual(wc.tabIndex(for: item(tag: 8)), 7)
    }

    /// **⌘9 is the LAST tab, not the ninth.** Every browser does this, and it is what makes the key
    /// worth having: a reader with four documents open pressing ⌘9 wants the fourth, not nothing.
    func testTheNinthItemMeansTheLastTabNotTheNinthOne() throws {
        let (_, wc) = try openMarkdown()
        // Headless there is exactly one window in the group, so "last" is it.
        XCTAssertEqual(wc.tabbedWindows.count, 1)
        XCTAssertEqual(wc.tabIndex(for: item(tag: 9)), 0,
                       "with one tab open, the last tab is the first one — never index 8")
    }

    /// Anything that is not one of the nine items is not ours, and must not be interpreted as tab 0.
    func testSomethingElseEntirelyResolvesToNothing() throws {
        let (_, wc) = try openMarkdown()
        XCTAssertNil(wc.tabIndex(for: item(tag: 0)))
        XCTAssertNil(wc.tabIndex(for: item(tag: 10)))
        XCTAssertNil(wc.tabIndex(for: nil))
        XCTAssertNil(wc.tabIndex(for: "not a menu item"))
    }

    /// A lone window has nothing to jump to, so the whole submenu greys out rather than offering
    /// nine keys that do nothing. (A tabbed window's own item stays enabled — `validateMenuItem`
    /// gates on the tab COUNT, which is 1 for an untabbed window.)
    func testTheNumberedItemsAreOfferedOnlyWhenThereAreTabs() throws {
        let (_, wc) = try openMarkdown()
        for tag in [1, 2, 9] {
            XCTAssertFalse(wc.validateMenuItem(item(tag: tag)),
                           "⌘\(tag) must be greyed out while only one document is open")
        }
    }

    /// Asking for a tab that isn't there must do nothing at all — never clamp to the nearest one,
    /// which would make ⌘7 with three tabs open silently behave as ⌘3.
    func testAskingForATabThatIsNotOpenDoesNothing() throws {
        let (_, wc) = try openMarkdown()
        let before = wc.window
        wc.goToTab(item(tag: 5))
        XCTAssertEqual(wc.window, before, "no window change, no crash")
    }

    /// An untabbed window still reports itself as its own only tab, so every caller here has one
    /// consistent list to count and index rather than an empty one to special-case.
    func testAnUntabbedWindowIsItsOwnOnlyTab() throws {
        let (_, wc) = try openMarkdown()
        XCTAssertEqual(wc.tabbedWindows.count, 1)
        XCTAssertEqual(wc.tabbedWindows.first, wc.window)
    }

    // MARK: - Fixture

    private func item(tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "Tab \(tag)",
                              action: #selector(DocumentWindowController.goToTab(_:)),
                              keyEquivalent: "\(tag)")
        item.tag = tag
        return item
    }

    private func openMarkdown() throws -> (MarkdownDocument, DocumentWindowController) {
        let source = "# Heading\n\nSome prose.\n"
        let url = temp.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        return (doc, wc)
    }
}
