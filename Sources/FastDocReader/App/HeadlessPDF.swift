import AppKit

/// The `--pdf` headless path: `FastDocReader --pdf <file> [-o <out.pdf>] [-f]` prints the document
/// to a PDF file and exits. It is deliberately NOT a second pagination engine — it builds a real
/// off-screen `DocumentWindowController`, lets it lay the document out exactly as the interactive
/// reader would, and hands the SAME `makePrintOperation()` that ⌘P runs to an `NSPrintOperation`
/// with `jobDisposition = .save` (the mechanism `PrintPaginationTests.printToPDF` already proves
/// headless), so the page rectangles, paper size and page count are whatever the reader itself
/// would report (invariant 59: the reader's own pages ARE the paper).
///
/// Unlike `--extract`, this needs AppKit's real layout/font/print stack, so it cannot run before
/// `NSApplication` exists — `main.swift` creates `NSApplication.shared` with
/// `setActivationPolicy(.prohibited)` (no Dock icon, no menu bar) and deliberately never installs
/// `AppDelegate` (which would present the Open panel — invariant 43) or calls `app.run()`; the
/// print operation runs synchronously on the calling thread, same as the test does.
///
/// Exit codes mirror `HeadlessExtract`: 0 success · 1 read/parse/print/output failure · 2 usage
/// error. Errors go to stderr; stdout carries only the result (output path, page count, paper size,
/// file size) so a script can trust it.
enum HeadlessPDF {

    static func run(_ args: [String]) -> Int32 {
        guard let parsed = parseArgs(args) else {
            err(usage)
            return 2
        }

        let inputURL = URL(fileURLWithPath: (parsed.input as NSString).expandingTildeInPath)
        let ext = inputURL.pathExtension.lowercased()
        guard DocumentTypes.opensInApp(ext) else {
            err("unsupported file type \".\(ext)\": FastDoc Reader reads .docx/.docm/.dotx/.dotm, " +
                ".odt, .hwp/.hwpx, and plain text/Markdown. Legacy binary .doc and .rtf are not supported.")
            return 1
        }

        let outputURL = parsed.output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? defaultOutputURL(for: inputURL)

        if !parsed.force, FileManager.default.fileExists(atPath: outputURL.path) {
            err("\(outputURL.path) already exists. Pass -f/--force to overwrite it.")
            return 1
        }

        let data: Data
        do { data = try Data(contentsOf: inputURL) }
        catch {
            // Sandboxed, a command-line path carries no access and the denial looks like an
            // ordinary file error — FolderAccess says what would actually fix it.
            err(FolderAccess.annotatingHeadlessDenial(
                "cannot read \(inputURL.lastPathComponent): \(error.localizedDescription)"))
            return 1
        }

        // Same door invariant 29 requires for every other reader of these bytes: `MarkdownDocument`'s
        // own `read(from:ofType:)`, which dispatches on `fileURL`'s extension — `ofType` itself is
        // unused by that override, so any placeholder UTI string is fine (the test suite's own
        // `openOffice` helper does the same).
        let doc = MarkdownDocument()
        doc.fileURL = inputURL
        do { try doc.read(from: data, ofType: "public.data") }
        catch { err("cannot parse \(inputURL.lastPathComponent): \(error.localizedDescription)"); return 1 }

        doc.makeWindowControllers()
        guard let wc = doc.windowControllers.first as? DocumentWindowController else {
            err("internal error: no window controller for \(inputURL.lastPathComponent)")
            return 1
        }
        // A sensible off-screen frame — the app's own default window size — never ordered on
        // screen. For a PAGED document this doesn't matter (width is pinned to the document's own
        // page body, invariant 57); for markdown/plain text it is the column the reader would wrap
        // at.
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)

        waitForRenderToSettle(doc: doc, wc: wc)

        guard let container = wc.textView.textContainer else {
            err("internal error: no text container for \(inputURL.lastPathComponent)")
            return 1
        }
        // The exact two calls `printDocument(_:)` makes right before building the print operation —
        // laying out the very last glyph (asking for it mid-walk is invariant 49's freeze) and
        // reserving the trailing footer band — so a headless print settles into the identical state
        // an interactive ⌘P would.
        wc.textView.layoutManager?.ensureLayout(for: container)
        wc.applyTrailingFooterBand()

        let op = wc.makePrintOperation()
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = outputURL

        guard op.run() else {
            // Reading the input can succeed while WRITING the output is denied — a granted folder
            // covers what is inside it, and `-o` can point anywhere else.
            err(FolderAccess.annotatingHeadlessDenial(
                "printing \(inputURL.lastPathComponent) to PDF failed (could not write \(outputURL.path))"))
            return 1
        }

        guard let pdfData = try? Data(contentsOf: outputURL),
              let provider = CGDataProvider(data: pdfData as CFData),
              let pdf = CGPDFDocument(provider) else {
            err("the PDF was written but could not be read back")
            return 1
        }
        let pageCount = pdf.numberOfPages
        let box = pdf.page(at: 1)?.getBoxRect(.mediaBox) ?? .zero

        out(outputURL.path)
        out("pages: \(pageCount)")
        out("paper: \(pointString(box.width)) x \(pointString(box.height)) pt")
        out("size: \(pdfData.count) bytes")
        return 0
    }

    // MARK: - Settling the async render pipeline

    /// `MarkdownDocument.render(into:)` finishes its synchronous half and then schedules the rest —
    /// the layout-completion walk, deferred giant-table splicing (invariant 55), uncached-diagram
    /// prerendering and remote-image measuring (invariant 2) — on `DispatchQueue.main`. A headless
    /// run never calls `NSApplication.run()`, so nothing drains that queue unless the run loop
    /// itself is spun; this does exactly that. NONE of it is new pagination logic — it is the SAME
    /// completion pipeline `render(into:)` already schedules for the interactive reader, pumped by
    /// hand instead of by an app sitting in its event loop.
    ///
    /// "Settled" is read off observable state rather than guessed at with a fixed sleep: no giant
    /// table still waiting to be spliced back in (`deferredTables`), no render superseding this one
    /// (`renderGeneration`), and the laid-out height no longer moving (a late diagram/remote-image
    /// size correction reflows it) — held for a few consecutive quiet polls before returning, capped
    /// by `timeout` so a dead network host can't hang the CLI forever. Internal (not `private`) so
    /// `HeadlessPDFTests` can settle its own reference `DocumentWindowController` the identical way
    /// before reading `printPageCount` off it.
    static func waitForRenderToSettle(doc: MarkdownDocument, wc: DocumentWindowController,
                                      timeout: TimeInterval = 20) {
        func layoutFully() {
            guard let tc = wc.textView.textContainer else { return }
            wc.textView.layoutManager?.ensureLayout(for: tc)
        }
        layoutFully()
        let deadline = Date().addingTimeInterval(timeout)
        var lastHeight: CGFloat = -1
        var lastGeneration = -1
        var quietPolls = 0
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            layoutFully()
            let height = wc.textView.frame.height
            let generation = doc.renderGeneration
            let quiet = doc.deferredTables.isEmpty && height == lastHeight && generation == lastGeneration
            lastHeight = height
            lastGeneration = generation
            quietPolls = quiet ? quietPolls + 1 : 0
            if quietPolls >= 3 { return }
        }
    }

    // MARK: - Argument parsing

    private struct Parsed { let input: String; let output: String?; let force: Bool }

    private static func parseArgs(_ args: [String]) -> Parsed? {
        var input: String?
        var output: String?
        var force = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-o", "--output":
                i += 1
                guard i < args.count else { return nil }
                output = args[i]
            case "-f", "--force":
                force = true
            default:
                guard !a.hasPrefix("-"), input == nil else { return nil }
                input = a
            }
            i += 1
        }
        guard let input else { return nil }
        return Parsed(input: input, output: output, force: force)
    }

    /// `-o` not given: the input's own basename, next to it, with a `.pdf` extension — never merging
    /// several inputs (out of scope for this flag, invariant of its own usage line below).
    private static func defaultOutputURL(for input: URL) -> URL {
        input.deletingPathExtension().appendingPathExtension("pdf")
    }

    private static func pointString(_ v: CGFloat) -> String {
        String(format: "%.1f", v)
    }

    private static let usage =
        "usage: FastDocReader --pdf <file> [-o <out.pdf>] [-f]\n" +
        "  Prints the document to a PDF file — the same pages the reader shows and ⌘P prints.\n" +
        "  -o, --output <path>   write to this path (default: <file's own name>.pdf, next to it)\n" +
        "  -f, --force            overwrite the output file if it already exists\n" +
        "  Supported: .docx .docm .dotx .dotm .odt .hwp .hwpx · .md .txt and this app's other plain-text kinds.\n" +
        "  One document per run — merging several files into one PDF is not supported."

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
