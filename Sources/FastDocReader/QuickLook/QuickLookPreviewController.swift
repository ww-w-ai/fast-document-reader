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

    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Data(contentsOf: url)

        // The one door every other reader of these bytes uses (invariant 29): `read(from:ofType:)`
        // dispatches on `fileURL`'s extension and `ofType` is unused by that override, exactly as
        // `HeadlessPDF` and the test suite's own helper do.
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "public.data")
        doc.makeWindowControllers()

        guard let wc = doc.windowControllers.first as? DocumentWindowController,
              let window = wc.window,
              let content = window.contentView else {
            throw CocoaError(.fileReadUnknown)
        }

        // Lay the document out at the size we are about to be shown at, THEN move the content view
        // across. Sizing afterwards would re-wrap every line a second time (invariant 48's rule:
        // build at the width you will be laid out at, so the first paint is the final one).
        let bounds = view.bounds
        window.setFrame(NSRect(origin: .zero, size: bounds.size), display: false)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        view.addSubview(content)

        document = doc
        windowController = wc
    }
}
