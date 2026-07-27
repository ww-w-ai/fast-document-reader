import XCTest
import AppKit
@testable import FastDocReader

/// Regression coverage for the reference-definition splicing path (`MarkdownDocument.spliceRender`'s
/// `definitionsPrefix`/`definitionLineRanges`/`isDefinitionLine`) — the machinery that lets an edit
/// splice instead of falling back to a full render even when the document uses `[text][ref]`-style
/// links, by finding the document's real link-reference definitions and gluing them ahead of the
/// edited fragment's own source before it renders. Every case here performs a real edit through the
/// document (never calling the private helpers directly) and inspects what actually lands on
/// screen — matching `SpliceRenderTests`' own standard, because a helper that is "correct" in
/// isolation and wrong once wired into `spliceRender` is exactly the class of bug this file exists
/// to catch (see invariant 29/30 in CLAUDE.md: a unit test on a helper cannot tell you the helper is
/// REACHED correctly).
final class SpliceRenderDefinitionTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-splicedef-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func open(_ source: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    private func assertMatchesFullRender(_ doc: MarkdownDocument, _ wc: DocumentWindowController,
                                         _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let storage = try XCTUnwrap(wc.textStorageRef)
        let theme = RenderTheme.current(size: FontSizeStore.size)
        let fresh = MarkdownRenderer.render(doc.text, theme: theme)
        XCTAssertEqual(storage.string, fresh.string, "\(what): rendered text", file: file, line: line)
        XCTAssertEqual(BlockEdit.spans(in: storage), BlockEdit.spans(in: fresh),
                       "\(what): block source spans", file: file, line: line)
    }

    /// The link's resolved destination, if any, at the first occurrence of `substring` in `storage`.
    private func linkDestination(of substring: String, in storage: NSAttributedString) -> URL? {
        let s = storage.string as NSString
        let r = s.range(of: substring)
        guard r.location != NSNotFound else { return nil }
        return storage.attribute(.link, at: r.location, effectiveRange: nil) as? URL
    }

    // MARK: Blocker 1 / 4a — a definition-shaped line inside a FENCED code block is inert

    func testDefinitionInsideAFencedCodeBlockIsNotInjectedIntoAnotherFragment() throws {
        let source = """
        Intro paragraph here.

        ```text
        sample code

        [fake]: http://phantom.example
        ```

        See [text][fake] in this line.

        Tail.
        """
        let (doc, wc) = try open(source)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let spans = BlockEdit.spans(in: storage)
        let target = try XCTUnwrap(spans.first { doc.sourceSubstring($0).contains("See [text][fake]") })
        doc.applySourceEdit(target, with: "See [text][fake] in this row.", actionName: "Edit")

        try assertMatchesFullRender(doc, wc, "fenced phantom definition")
        let after = try XCTUnwrap(wc.textStorageRef)
        XCTAssertNil(linkDestination(of: "text", in: after),
                     "a definition living inside a fenced code block must not resolve a reference")
        XCTAssertTrue(after.string.contains("[text][fake] in this row."),
                     "the reference must stay LITERAL, exactly like a full render")
    }

    // MARK: Blocker 2 / 4b — a definition-shaped line inside an INDENTED code block is inert

    func testDefinitionInsideAnIndentedCodeBlockIsNotInjectedIntoAnotherFragment() throws {
        let source = "Intro.\n\n    [fake]: http://phantom.example\n\nSee [text][fake] here.\n\nTail.\n"
        let (doc, wc) = try open(source)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let spans = BlockEdit.spans(in: storage)
        // Edit a block nowhere near the pseudo-definition — the failure this pins down injected a
        // whole phantom visible block into the splice regardless of WHICH block was edited.
        let target = try XCTUnwrap(spans.first { doc.sourceSubstring($0).contains("Tail") })
        doc.applySourceEdit(target, with: "Tail edited.", actionName: "Edit")

        try assertMatchesFullRender(doc, wc, "indented phantom definition")
        let after = try XCTUnwrap(wc.textStorageRef)
        XCTAssertNil(linkDestination(of: "text", in: after),
                     "a definition living inside an indented code block must not resolve a reference")
        // No srcRange may run past the end of the (now current) document — the phantom block this
        // bug added recorded one that did, permanently blocking further edits to it.
        let docLength = (doc.text as NSString).length
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let r = (v as? NSValue)?.rangeValue else { return }
            XCTAssertLessThanOrEqual(r.location + r.length, docLength, "a recorded srcRange must not exceed the document")
        }
    }

    // MARK: Blocker 3 — adjacency after a paragraph-interrupting construct with no blank line

    func testDefinitionDirectlyUnderAHeadingWithNoBlankLineStillResolves() throws {
        let source = "## Links\n[ref]: http://example.com\n\nSee [text][ref] here.\n\nTail.\n"
        let (doc, wc) = try open(source)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let spans = BlockEdit.spans(in: storage)
        let target = try XCTUnwrap(spans.first { doc.sourceSubstring($0).contains("See [text][ref]") })
        doc.applySourceEdit(target, with: "See [text][ref] there.", actionName: "Edit")

        try assertMatchesFullRender(doc, wc, "definition under a heading")
        let after = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(linkDestination(of: "text", in: after), URL(string: "http://example.com"),
                       "a definition directly under a heading (no blank line) must still resolve")
    }

    func testDefinitionDirectlyUnderAThematicBreakWithNoBlankLineStillResolves() throws {
        let source = "---\n[ref]: http://example.com\n\nSee [text][ref] here.\n\nTail.\n"
        let (doc, wc) = try open(source)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let spans = BlockEdit.spans(in: storage)
        let target = try XCTUnwrap(spans.first { doc.sourceSubstring($0).contains("See [text][ref]") })
        doc.applySourceEdit(target, with: "See [text][ref] there.", actionName: "Edit")

        try assertMatchesFullRender(doc, wc, "definition under a thematic break")
        let after = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(linkDestination(of: "text", in: after), URL(string: "http://example.com"),
                       "a definition directly under a thematic break (no blank line) must still resolve")
    }

    // MARK: Blocker 5 — duplicate labels: the document's TRUE first definition must win

    func testDuplicateLabelSplicedFragmentKeepsTheFirstDefinitionsURL() throws {
        let source = "[ref]: https://first.example.com\n\nSee [text][ref] here.\n\n[ref]: https://second.example.com\n\nTail paragraph.\n"
        let (doc, wc) = try open(source)
        // Sanity: a full render resolves to the FIRST definition.
        let fresh = MarkdownRenderer.render(doc.text, theme: RenderTheme.current(size: FontSizeStore.size))
        XCTAssertEqual(linkDestination(of: "text", in: fresh), URL(string: "https://first.example.com"))

        let storage = try XCTUnwrap(wc.textStorageRef)
        let spans = BlockEdit.spans(in: storage)
        let target = try XCTUnwrap(spans.first { doc.sourceSubstring($0).contains("See [text][ref]") })
        doc.applySourceEdit(target, with: "See [text][ref] here still.", actionName: "Edit")

        try assertMatchesFullRender(doc, wc, "duplicate label")
        let after = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(linkDestination(of: "text", in: after), URL(string: "https://first.example.com"),
                       "a spliced fragment must resolve a duplicated label to the document's TRUE first definition")
    }

    // MARK: Blocker 6 — a fragment ending inside an UNCLOSED fence must not swallow the prefix

    func testEditingABlockThatEndsInAnUnclosedFenceStillResolvesAnEarlierDefinition() throws {
        let source = "[ref]: https://example.com\n\nSee [text][ref] here.\n\n```\nunclosed code\n"
        let (doc, wc) = try open(source)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let spans = BlockEdit.spans(in: storage)
        let target = try XCTUnwrap(spans.first { doc.sourceSubstring($0).contains("unclosed code") })
        doc.applySourceEdit(target, with: "unclosed code, edited", actionName: "Edit")

        try assertMatchesFullRender(doc, wc, "unclosed fence")
        let after = try XCTUnwrap(wc.textStorageRef)
        // The definition must still be findable and resolve correctly elsewhere on screen — if the
        // fence swallowed the prepended prefix, this reference would read as literal brackets, and
        // no srcRange may extend past the (current) document's own length.
        XCTAssertEqual(linkDestination(of: "text", in: after), URL(string: "https://example.com"))
        let docLength = (doc.text as NSString).length
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let r = (v as? NSValue)?.rangeValue else { return }
            XCTAssertLessThanOrEqual(r.location + r.length, docLength, "a recorded srcRange must not exceed the document")
        }
        // A follow-up edit to the SAME block must still work (the out-of-bounds span this bug left
        // behind permanently blocked exactly this).
        let spans2 = BlockEdit.spans(in: after)
        let target2 = try XCTUnwrap(spans2.first { doc.sourceSubstring($0).contains("unclosed code") })
        let before = doc.text
        doc.applySourceEdit(target2, with: "unclosed code, edited again", actionName: "Edit")
        XCTAssertNotEqual(doc.text, before, "a follow-up edit to the fence block must still apply")
    }
}
