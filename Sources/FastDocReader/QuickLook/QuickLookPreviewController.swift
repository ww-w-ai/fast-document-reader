import AppKit
import QuickLookUI

/// The Finder's space-bar preview, drawn by THIS reader rather than by whatever else happens to be
/// installed. Its whole claim is that the preview and the opened document are the same thing, so it
/// deliberately builds the document the SAME way `--pdf` does — `MarkdownDocument.read` →
/// `makeWindowControllers()` → the controller's own content view — instead of rendering a second,
/// simpler way that would drift from the reader (invariant 29's lesson, and the reason a
/// "preview-only renderer" was rejected in `docs/02-planned/quick-look-extension-design.md`).
///
/// It ships inside `FastDocReader.app/Contents/PlugIns/QuickLookPreview.appex`, whose executable is a
/// COPY of the app's own binary: `main.swift` sees that it is running inside an `.appex` and hands
/// control to `NSExtensionMain`, so this class is reachable without splitting the package into
/// modules (see that design note for what that would have cost).
///
/// HWP is the case that matters most: on a Mac without Hangul installed, a `.hwp` has no preview at
/// all today.
final class QuickLookPreviewController: NSViewController, QLPreviewingController {

    /// Held for the extension's lifetime: the view we install belongs to this window controller, and
    /// the document owns the text storage behind it. Dropping either would leave an empty preview.
    private var document: MarkdownDocument?
    private var windowController: DocumentWindowController?

    override func loadView() {
        // Quick Look resizes this to the panel it decides on; the size here only matters as the
        // frame the document first lays out in.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 640))
    }

    /// How much SOURCE a preview renders. The reader lays a document out in full so its scrollbar is
    /// honest from the first frame (invariant 49) — right for reading, wrong for a glance, and the
    /// difference is not small: on a real 523 KB / 292,868-character Markdown file the whole document
    /// cost **3,022 ms** to build before anything could be seen.
    ///
    /// The bound is measured, not guessed. Same file, same run, cut to each length:
    /// **1,000 → 79 ms · 10,000 → 170 · 20,000 → 168 · 40,000 → 288 · 80,000 → 814**. So 79 ms is the
    /// floor (building a window controller at all), 20,000 characters costs the same as 10,000, and
    /// the price starts climbing after that. A screenful is roughly two thousand characters, so this
    /// is still about ten screens of scrolling before the note at the end.
    static let previewSourceLimit = 20_000

    /// An OFFICE document is cut shorter than a text one, on the owner's instruction ("앞에 5장 정도만
    /// 보여주고 뒤에 더 있다고"). Kept in CHARACTERS rather than pages because "a page" is not a
    /// constant a budget can be written in: measured through `--pdf` on this repo's own fixtures, a
    /// table-heavy `.docx` holds **233 characters per page** while Korean prose runs well over a
    /// thousand — a five-page rule would cut one document at 1,200 characters and another at 9,000.
    /// This is roughly five pages of ordinary prose and rather more of a form.
    static let previewOfficeCharacterBudget = 8_000

    /// The head of a Markdown/plain-text document, cut where a reader would not notice, plus an
    /// honest note that it IS a head. Pure, so the cutting rules are testable without a window.
    ///
    /// Two rules earn their place: cut back to a blank line so a paragraph is not sliced mid-sentence,
    /// and close a code fence the cut landed inside — otherwise every remaining line renders as code,
    /// which looks like a corrupt document rather than a shortened one.
    static func previewSource(_ text: String, limit: Int = previewSourceLimit) -> String {
        guard text.count > limit else { return text }
        var head = String(text.prefix(limit))
        if let blank = head.range(of: "\n\n", options: .backwards) {
            head = String(head[..<blank.lowerBound])
        }
        if head.components(separatedBy: "```").count % 2 == 0 { head += "\n```" }
        return head + "\n\n---\n\n*" + shortenedNote + "*\n"
    }

    /// Said once, in both halves (text is cut by source, an office document by blocks), so a
    /// shortened preview never differs in how it admits to being shortened.
    static let shortenedNote = "[ ... more in the full document ]"

    func preparePreviewOfFile(at url: URL) async throws {
        var data = try Data(contentsOf: url)

        // Only text kinds can be cut by their own bytes; an office document's structure lives in a
        // zip/binary container, so it is handed over whole (its cost is measured separately).
        switch DocumentTypes.kind(forExtension: url.pathExtension.lowercased()) {
        case .markdown, .plainText:
            let decoded = TextEncodingDetector.decode(data)
            let head = Self.previewSource(decoded.text)
            if head.count != decoded.text.count { data = Data(head.utf8) }
        case .office:
            break   // its bytes are a container; it is cut after reading, below
        }

        // The one door every other reader of these bytes uses (invariant 29): `read(from:ofType:)`
        // dispatches on `fileURL`'s extension and `ofType` is unused by that override, exactly as
        // `HeadlessPDF` and the test suite's own helper do.
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "public.data")
        // Content only: a preview panel is small, and reproducing the author's paper would spend most
        // of it on margins. Must precede makeWindowControllers().
        doc.flattenPagesForPreview()
        doc.truncateOfficeBlocksForPreview(characterBudget: Self.previewOfficeCharacterBudget,
                                           note: Self.shortenedNote)
        doc.makeWindowControllers()

        guard let wc = doc.windowControllers.first as? DocumentWindowController,
              let window = wc.window,
              let content = window.contentView else {
            throw CocoaError(.fileReadUnknown)
        }

        // A preview is a glance, not a read — there is no place to keep, so the reading-line band
        // would read as a highlight the document does not have.
        wc.textView.showsReadingCursor = false

        // Lay the document out at the size we are about to be shown at, THEN move the content view
        // across. Sizing afterwards would re-wrap every line a second time (invariant 48's rule:
        // build at the width you will be laid out at, so the first paint is the final one).
        let bounds = view.bounds
        window.setFrame(NSRect(origin: .zero, size: bounds.size), display: false)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        view.addSubview(content)
        // Last, so it sits above the document: which app drew this preview, answerable at a glance.
        // That the document was CUT is said in the content itself (`shortenedNote`), not here — a
        // mark pinned over the panel stays put while the reader scrolls and reads as chrome.
        PreviewBadgeView.install(PreviewBadgeView.title, in: view)

        document = doc
        windowController = wc
    }
}
