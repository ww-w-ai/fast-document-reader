import XCTest
import AppKit
@testable import FastDocReader

/// A progressively-painted document must end up INDISTINGUISHABLE from one built in a single pass.
/// The reader is shown the front of the file before the rest exists, so the only thing standing
/// between that and a document that quietly stops matching the file is this comparison.
///
/// See `docs/02-planned/markdown-progressive-first-paint.md`.
final class ProgressiveRenderTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-progressive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    /// Big enough to cross the progressive floor, and made of the block kinds whose walk is the
    /// expensive part. The reference link is USED in the first paragraph and DEFINED on the last
    /// line — the case §3 of the design doc exists for: parse a prefix on its own and it silently
    /// becomes plain text.
    private func largeSource() -> String {
        var out = "See [the spec][ref] and https://example.com/bare.\n\n"
        for i in 0..<2400 {
            out += """
            ## Section \(i)

            Paragraph \(i) with `code`, *emphasis* and a path /usr/local/bin/tool\(i).

            - item \(i).a
            - item \(i).b

            | col | value |
            |---|---|
            | \(i) | \(i * 7) |

            ```swift
            let x\(i) = \(i)
            ```

            """
        }
        out += "\n[ref]: https://example.com/spec\n"
        return out
    }

    private func open(_ source: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent("doc.md")
        let data = Data(source.utf8)
        try data.write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    /// The first place the two differ, by VALUE.
    ///
    /// `NSAttributedString.isEqual` cannot answer this: a paragraph style carrying an
    /// `NSTextBlock` compares by object identity, and every render builds fresh table blocks — so
    /// even the same document rendered twice comes out "different". Descriptions with their
    /// pointers stripped compare what the two strings actually SAY.
    private static func firstAttributeDifference(_ a: NSAttributedString, _ b: NSAttributedString)
        -> (at: Int, mine: [String: String], theirs: [String: String])? {
        let pointer = try! NSRegularExpression(pattern: "0x[0-9a-f]+")
        func described(_ d: [NSAttributedString.Key: Any]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: d.map { key, value in
                let text = String(describing: value)
                let stripped = pointer.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: "0x*")
                return (key.rawValue, stripped)
            })
        }
        var i = 0
        while i < min(a.length, b.length) {
            var ra = NSRange(), rb = NSRange()
            let x = described(a.attributes(at: i, longestEffectiveRange: &ra,
                                           in: NSRange(location: i, length: a.length - i)))
            let y = described(b.attributes(at: i, longestEffectiveRange: &rb,
                                           in: NSRange(location: i, length: b.length - i)))
            if x != y { return (i, x, y) }
            i += max(1, min(ra.length, rb.length))
        }
        return nil
    }

    /// Drains the main queue the way an app sitting in its event loop would — the tail is appended
    /// one run-loop turn at a time, so nothing arrives without this.
    private func settle(_ doc: MarkdownDocument, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while doc.isProgressiveRenderPending, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testTheWholeDocumentArrivesAndMatchesASinglePassRender() throws {
        let source = largeSource()
        let (doc, wc) = try open(source)
        let storage = try XCTUnwrap(wc.textStorageRef)

        // The first paint really is a FRONT, not the whole thing — otherwise everything below is
        // asserting nothing (the "is this check actually reached" rule, invariant 30).
        XCTAssertTrue(doc.isProgressiveRenderPending, "a 350 KB document must paint progressively")
        let headLength = storage.length

        settle(doc)
        XCTAssertFalse(doc.isProgressiveRenderPending, "the tail never finished arriving")

        let fresh = MarkdownRenderer.render(source, theme: RenderTheme.current(size: doc.readingSize))
        XCTAssertGreaterThan(storage.length, headLength, "nothing was appended")
        XCTAssertEqual(storage.string, fresh.string, "rendered text")
        XCTAssertEqual(BlockEdit.spans(in: storage), BlockEdit.spans(in: fresh), "block source spans")
    }

    /// The same question one layer down, where it can be asked EXACTLY: chunks concatenated ==
    /// a single-pass render, attributes and all. It cannot be asked of the storage, because
    /// `display` puts things there that no render produces (margin numbers, the reading band).
    func testConcatenatedChunksEqualASinglePassRender() throws {
        let source = largeSource()
        let theme = RenderTheme.current(size: 16)
        let progressive = MarkdownRenderer.renderProgressive(source, theme: theme)
        let assembled = NSMutableAttributedString()
        var chunks = 0
        while !progressive.isFinished {
            assembled.append(progressive.nextChunk(blocks: 37))   // an awkward size on purpose
            chunks += 1
        }
        XCTAssertGreaterThan(chunks, 5, "the walk was not actually sliced")
        let fresh = MarkdownRenderer.render(source, theme: theme)
        XCTAssertEqual(assembled.string, fresh.string, "text")
        // Reported as ONE location rather than as two whole strings: the failure message for a
        // 400 KB document is unreadable, and the first divergence is the whole diagnosis.
        if let (at, mine, theirs) = Self.firstAttributeDifference(assembled, fresh) {
            let around = (fresh.string as NSString)
                .substring(with: NSRange(location: max(0, at - 30), length: min(60, fresh.length - max(0, at - 30))))
            XCTFail("attributes diverge at \(at) near \(around.debugDescription): sliced \(mine) vs whole \(theirs)")
        }
    }

    /// The whole document is parsed before any of it is walked, so a definition at the END binds
    /// text in the FIRST chunk. Parse a prefix on its own and this silently becomes plain text.
    func testALinkDefinedAtTheEndIsAlreadyALinkInTheFirstChunk() throws {
        let progressive = MarkdownRenderer.renderProgressive(largeSource(), theme: RenderTheme.current(size: 16))
        let head = progressive.nextChunk(blocks: 2)
        var found = false
        head.enumerateAttribute(.link, in: NSRange(location: 0, length: head.length)) { v, _, stop in
            if let url = v as? URL, url.absoluteString == "https://example.com/spec" {
                found = true; stop.pointee = true
            }
        }
        XCTAssertTrue(found, "a reference link defined on the last line must resolve in the first chunk")
    }

    /// A short document is built in one pass — splitting it would buy nothing and cost an edit.
    func testASmallDocumentIsNotSplit() throws {
        let (doc, wc) = try open("# Title\n\nJust a paragraph.\n")
        XCTAssertFalse(doc.isProgressiveRenderPending)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let fresh = MarkdownRenderer.render(doc.text, theme: RenderTheme.current(size: doc.readingSize))
        XCTAssertEqual(storage.string, fresh.string)
    }
}
