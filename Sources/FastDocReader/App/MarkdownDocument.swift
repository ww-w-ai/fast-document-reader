import AppKit
import ImageIO

final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

    /// THIS document's own reading font size — belongs here, not to a shared global (see
    /// `FontSizeStore`'s own header comment for the bug this fixes). Seeded ONCE, at creation, from
    /// the last size the reader chose, and never re-read from anywhere afterwards: that single read
    /// is what keeps "remembered next time" true across launches, while the absence of any later
    /// read is what stops one window's ⌘+ from reaching another. ⌘+/⌘−/Actual Size (below) change
    /// only the document that received the menu action, and update the seed for the NEXT document
    /// opened — never for one already open. Not `private(set)`: test setup that legitimately wants a
    /// document to start pre-zoomed (simulating a reader who already changed it before the render
    /// being measured) sets this directly, before the first `render(into:)`.
    var readingSize: CGFloat = FontSizeStore.startingSize

    /// The office reader's output (`.docx` etc — see `Render/Office`). Blocks, not a finished
    /// attributed string: `render(into:)` re-runs `OfficeTextBuilder.build` every time (font-size
    /// change, ⌘R), so a cached string would freeze the document at whatever size it was built at.
    /// Empty for every other kind.
    private(set) var officeBlocks: [OfficeBlock] = []

    /// Every reviewer comment the source document declares (`word/comments.xml`, inline
    /// `office:annotation`) — see `OfficeComment`. Set alongside `officeBlocks` on every read/reload
    /// (see `setOfficeContent`); empty for every non-office kind, and for an office document with no
    /// comments. P6a captures this ONLY — no view reads it yet (the sidebar panel is P6b).
    private(set) var officeComments: [OfficeComment] = []

    /// Running headers/footers the source document declares (header-footer-design.md step 2) — see
    /// `OfficeHeaderFooter`. Threaded through exactly like `officeComments` above (same
    /// `setOfficeContent`/`ReloadOutcome`/`reloadOutcome` seam): set alongside `officeBlocks` on every
    /// read/reload, empty for every non-office kind and for an office document with none. Read-only
    /// capture — no view paints these yet (steps 4/5 of that design).
    private(set) var officeHeaders: [OfficeHeaderFooter] = []
    private(set) var officeFooters: [OfficeHeaderFooter] = []

    /// The SOURCE document's own default body run size, in points — see
    /// `OfficeTextBuilder.build`'s `documentDefaultFontSize` doc for the font-size model this
    /// feeds. Set from `DocumentTypes.officeDefaultBodyFontSize`, both on first `read(from:)` and on
    /// `reloadDocument` (see `ReloadOutcome.office`), so the two behave identically. `11` (the
    /// fallback both readers themselves return) when the document declares no default of its own.
    private(set) var officeDefaultBodyFontSize: CGFloat = 11

    /// The SOURCE document's own page BODY width in points (paper − margins), or nil when the reader
    /// could not determine it — see `OfficeReadResult.pageContentWidth`. Set alongside `officeBlocks`
    /// on every read/reload.
    ///
    /// **Non-nil here is what makes a document PAGED**, which is the single predicate the whole
    /// paged-zoom model branches on (`DocumentWindowController.pagedWidth`): the reading column is
    /// pinned to this width, the theme is built at the document's OWN default size so
    /// `fontSizeScale` is 1, and ⌘+/⌘−/⌘0 magnify the view instead of rebuilding the document.
    /// `render(into:)` still divides the column by it for the GRAPHIC scale — which is now exactly
    /// 1, i.e. a picture at its authored size.
    ///
    /// nil for every non-office kind, AND for an office document whose reader found no page size (a
    /// real, tested state in docx, odt and HWP alike). That case keeps the fill-the-window column
    /// and the reading-font-size model, unchanged. Do NOT substitute `kind == .office` for this
    /// check — they are different sets, and five tests in `OfficeDocumentTests` exist on the
    /// difference.
    private(set) var officePageContentWidth: CGFloat?

    /// The section's line-grid pitch — see `OfficeReadResult.lineGridPitch`. Carried on the document
    /// for the same reason the page width is: `render` rebuilds through `OfficeTextBuilder` on every
    /// zoom/reflow and has to hand it the document's own instruction each time.
    private(set) var officeLineGridPitch: CGFloat?

    /// The page's own left/right margins in points — see `OfficeReadResult.pageMarginLeft`. Together
    /// with `officePageContentWidth` they give the PAPER width, which is what a paged view must
    /// reproduce: Word and Pages show the whole sheet, so laying out only the body magnifies the text
    /// by `paper ÷ body` relative to them at the same window width (1.24×–1.32× on four real A4
    /// documents). `nil` → the view falls back to its own side inset, exactly as before.
    private(set) var officePageMarginLeft: CGFloat?
    private(set) var officePageMarginRight: CGFloat?

    /// The page's own BODY height in points — see `OfficeReadResult.pageContentHeight`. The vertical
    /// twin of `officePageContentWidth`, carried the same way for the same reason: it is the hard
    /// prerequisite for running headers/footers and for showing where a page ends, neither of which
    /// this field wires up on its own. `nil` for every non-office kind and for an office document
    /// whose reader found no page height (unchanged, exactly like a document with no page width).
    private(set) var officePageContentHeight: CGFloat?

    /// The page's own top/bottom margins in points — see `OfficeReadResult.pageMarginTop`/
    /// `pageMarginBottom`, the vertical twins of `officePageMarginLeft`/`officePageMarginRight`.
    private(set) var officePageMarginTop: CGFloat?
    private(set) var officePageMarginBottom: CGFloat?
    /// How far the running header/footer sits from the SHEET's own top/bottom edge — see
    /// `OfficeReadResult.pageHeaderDistance`. `nil` for a format that does not say.
    private(set) var officePageHeaderDistance: CGFloat?
    private(set) var officePageFooterDistance: CGFloat?

    /// Throw away the page model so a Quick Look preview shows CONTENT ONLY — no paper, no side
    /// margins, no running header or footer, the text filling the preview's width the way a
    /// window-fitting document does. The owner's instruction, and the right one for that surface: a
    /// preview is a glance at what is inside a file, and reproducing the author's paper spends most
    /// of a small panel on white space. Tables reflow to the preview's width instead of the page's,
    /// which can look a little rougher than the reader does — accepted deliberately.
    ///
    /// Keep only the head of an office document, so a preview lays out a screenful rather than the
    /// whole file. Measured on a 20 MB HWPX: parsing it costs 1,220 ms and BUILDING it 1,998 ms, so
    /// the typography — not the parser — is what a glance was paying for. The parse cannot be cut
    /// (rhwp and the zip readers hand back a whole document or nothing), this can.
    ///
    /// Budgeted in characters, counted the same way the text is built, so a table full of one-word
    /// cells costs what it actually renders. A table is kept WHOLE or dropped whole — half a grid is
    /// worse than none. When something IS left out, `note` is appended as a last paragraph so the
    /// shortening is visible — a preview that silently ends early reads as a broken document.
    @discardableResult
    func truncateOfficeBlocksForPreview(characterBudget: Int, note: String) -> Bool {
        func length(_ block: OfficeBlock) -> Int {
            switch block {
            case .heading(_, let spans, _, _, _, _), .paragraph(let spans, _, _, _, _):
                return spans.reduce(0) { $0 + $1.text.count }
            case .listItem(_, _, let spans, _, _, _, _, _):
                return spans.reduce(0) { $0 + $1.text.count }
            case .table(let rows, _, _, _):
                return rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + length($1) } } }
            default:
                return 0
            }
        }
        var kept: [OfficeBlock] = []
        var used = 0
        for block in officeBlocks {
            if used >= characterBudget { break }
            kept.append(block)
            used += length(block)
        }
        guard kept.count < officeBlocks.count else { return false }
        kept.append(.paragraph(spans: [Span(text: note, italic: true)]))
        officeBlocks = kept
        return true
    }

    /// Must be called BEFORE `makeWindowControllers()`; afterwards the geometry is already built in.
    /// Nothing else calls this: the reader and `--pdf` reproduce the page (invariants 57 and 59).
    func flattenPagesForPreview() {
        officePageContentWidth = nil
        officePageContentHeight = nil
        officePageMarginLeft = nil
        officePageMarginRight = nil
        officePageMarginTop = nil
        officePageMarginBottom = nil
        officePageHeaderDistance = nil
        officePageFooterDistance = nil
        officeHeaders = []
        officeFooters = []
    }

    /// The archive `officeBlocks` was parsed from, kept so an `.image` block's id (an archive entry
    /// path, e.g. `"word/media/image1.png"`) can be pulled on demand when it scrolls into view — the
    /// same lazy-pixels discipline `reconcileMedia` already gives markdown images, not a second
    /// cache (unzipping a PNG is cheap; a disk cache exists elsewhere only because a WebKit round
    /// trip is not). `nil` for every other kind.
    private(set) var officeArchive: ZipArchive?

    /// Embedded office image bytes PRE-DECODED at read time, keyed by the `.image` block's id (see
    /// `OfficeReadResult.images`). The zip-backed readers (`DocxReader`/`OdtReader`) leave this `[:]`
    /// and resolve pixels lazily from `officeArchive`; HWP has no archive and its image FFI needs the
    /// live parse handle (gone by reconcile time), so `HwpReader.read` fills this and `reconcileMedia`
    /// checks it BEFORE the archive. `[:]` for every non-HWP document — byte-identical behaviour.
    private(set) var officeImageBytes: [String: Data] = [:]

    // C3: bumped on every full render; async mermaid swaps from a previous render carry
    // a stale generation and abort before mutating, so only the latest render wins.
    /// Bumped by every render. `private(set)` (not `private`) so a latency probe can tell "the
    /// rebuild has actually happened" apart from "nothing has started yet" — without it, timing a
    /// debounced re-render measures the debounce and stops before the work begins.
    private(set) var renderGeneration = 0

    /// Indices into `officeBlocks` of the tables this render left out so the document could paint
    /// (`OfficeTextBuilder.giantTableIndices`), cleared once `spliceDeferredTables` has put them all
    /// back. Empty for every markdown/plain-text document and for 98.6% of office ones; `private(set)`
    /// so a test can assert a document deferred nothing without reaching through the render path.
    private(set) var deferredTables: Set<Int> = []

    /// Deferral is a FIRST-PAINT device, and this is what confines it to one.
    ///
    /// Deferring on a RE-RENDER (⌘+/⌘−/⌘R) shipped a hang, and the mechanism is worth keeping
    /// because it is not the obvious one. The re-render takes the reader's anchor against the FULL
    /// document, then replaces the storage with the deferred string — a third the length — so
    /// `restore` clamps that character to the deferred string's LAST one and parks the viewport at
    /// its bottom. The splice then inserts 273,016 characters ABOVE that point, which leaves the
    /// viewport sitting inside a grid nothing has laid out yet. From there it is not scrolling that
    /// costs: DRAWING the visible rect has to fill the layout hole under it, and it advances about
    /// 800 characters per pass at 150–300 ms a pass. Measured end to end at 69,460 and 80,008 ms —
    /// the "infinite loop" a reader reports. With the reader at character 0 the same press costs a
    /// 498 ms worst turn; at character 326,797, 9,038 ms and 181 turns over 100 ms.
    ///
    /// At first paint the anchor IS character 0, so none of that geometry exists, and the measured
    /// prize (3,130 → 628 ms) is a first-paint prize anyway. Deferring on re-render can be revisited
    /// only with an anchor that survives the swap — mapped through `MDAttr.blockId`, which is the one
    /// identity both strings share — and it must be measured with the reader deep in the document,
    /// because at the top every version of this looks perfect.
    private var hasPaintedOnce = false

    // While the up-front measure pass is rendering uncached diagrams, their exact size isn't known
    // yet — reconcileMedia must NOT load them (that would resize under the reader). Cleared once the
    // pass finishes and every diagram has been sized. `prerenderToken` cancels a stale pass when a
    // new render starts.
    private var isPrerendering = false
    private var prerenderToken = 0

    // Same idea for remote images: until their header has been fetched their size is a guess, so
    // reconcileMedia must not fill them mid-pass (the pixels would arrive and resize the layout).
    private var isMeasuringRemote = false
    private var measureToken = 0

    override class var autosavesInPlace: Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    /// Closing the last document is the one moment this app holds a document's worth of memory with
    /// nothing to show for it: `applicationShouldTerminateAfterLastWindowClosed` is false, so it
    /// deliberately stays running with no window at all (invariant 43's menu-bar state). See
    /// `purgeImageCaches` for what is dropped and the measurements behind it.
    ///
    /// Hooked HERE rather than on `NSWindow.willCloseNotification` because the count has to be read
    /// after the document is gone from `NSDocumentController`, and `super.close()` is what removes it
    /// — asking at window-close time would always see this document still registered and never fire.
    ///
    /// Asking the ALLOCATOR to hand pages back as well (`malloc_zone_pressure_relief`) was built,
    /// measured and removed — and it was measured in BOTH orders, which matters, because the first
    /// result invites the wrong conclusion. Called BEFORE the purge it returned 0 MB immediately and
    /// 0 MB again three seconds later, which is correct behaviour rather than a broken API: the
    /// memory was still referenced by the caches above, so there was nothing free to return. Called
    /// AFTER the purge, with 97 MB demonstrably given back on that same close, it still returned
    /// 0 MB. So dropping the references is the entire fix on this OS, and a call that provably
    /// returns nothing in either order is not worth shipping.
    override func close() {
        super.close()
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty { Self.purgeImageCaches() }
        }
    }

    /// Saving is ⌘S, not every edit. Writing on each keystroke-sized change meant rewriting the
    /// whole file for one moved line — and, worse, it left no way back: the file on disk had
    /// already changed before the reader decided they liked it. Edits now live in memory, the
    /// document goes dirty, and AppKit's own "Save / Don't Save / Cancel" sheet handles closing.
    /// Change tracking is left to NSDocument, which watches the undo manager — undo back to the
    /// original state correctly reports the document as clean again.
    override func data(ofType typeName: String) throws -> Data {
        // Office documents have no editable source (invariant: `text` stays "" for them — see
        // `read(from:ofType:)`) — refuse rather than write an empty file over a real one. This is
        // the only writer (`applySourceEdit` never runs for `.office`; see the kind gates in
        // `ReaderTextView` and `DocumentWindowController`), so refusing here closes the door for
        // every path at once.
        guard kind != .office else {
            throw NSError(domain: "ai.ww-w.fast-md-reader", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This document is read-only and can't be saved.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "\(fileURL?.lastPathComponent ?? "This file") is a format fast-md-reader only reads, not edits.",
            ])
        }
        guard let bytes = TextEncodingDetector.encode(text, like: file) else {
            throw NSError(domain: "ai.ww-w.fast-md-reader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This file's text encoding can't represent some of the characters in your edits.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "\(fileURL?.lastPathComponent ?? "The file") is stored in an older encoding. Remove those characters, or convert the file to UTF-8 in another editor, and save again.",
            ])
        }
        return bytes
    }

    /// How this file was stored, kept so a save writes it back the same way (see TextFile). Set on
    /// every read; the default only matters for a document that was never read from disk.
    private(set) var file = TextFile(text: "", encoding: .utf8, hasBOM: false)

    override func read(from data: Data, ofType typeName: String) throws {
        // An office document is a binary ZIP container, not text — `TextEncodingDetector` is a
        // text-encoding detector, and running it over these bytes would be nonsense (best case,
        // garbage; worst case a false "valid encoding" match). Parse the archive instead, and
        // THROW on failure rather than opening an empty window (see `DocxReader.ReadError`) — an
        // empty office document would look like a genuinely blank file, the worst failure mode.
        guard kind == .office else {
            // NOT `String(decoding:as: UTF8.self)`: that never fails, it just substitutes
            // replacement characters, so a Windows-made CP949 or UTF-16 file arrives as a wall of
            // "?" and looks corrupted. The detector reads the bytes for what they are.
            self.file = TextEncodingDetector.decode(data)
            self.text = file.text
            cachedHasCrossBlockReferences = nil
            return
        }
        let ext = fileURL?.pathExtension ?? untitledExtension ?? ""
        // HWP/HWPX are NOT a `ZipArchive`: an `.hwp` is CFB binary (a `.hwpx` is a zip, but rhwp reads
        // both from raw `Data` itself), so they must branch BEFORE `ZipArchive(data:)` — which would
        // throw on `.hwp` — and hand the bytes straight to `HwpReader.read`. No archive exists, so
        // `officeArchive` stays nil; `HwpReader.read` pre-decodes every embedded image into
        // `result.images` (S4 reconcile checks that map before the nil archive). HWP's own default
        // body size (Normal/"바탕글" style char-shape base size) rides the SAME rhwp parse —
        // `result.defaultBodyFontSize` is decoded off the export envelope's `defaultFontSizePt`,
        // docx/odt's `officeDefaultBodyFontSize` analog with no second FFI call — so every HWP scales
        // to its own declared size, falling back to `11` (the theme default the builder tolerates for
        // an unspecified size, invariant 37) only when rhwp emitted null. This branch +
        // `DocumentTypes.hwpExtensions` ARE the HWP dispatch (invariant 29); the zip path below is
        // unchanged for docx/odt.
        if DocumentTypes.isHwp(ext) {
            let result = try HwpReader.read(data)
            setOfficeContent(
                blocks: result.blocks, comments: result.comments, archive: nil,
                images: result.images, defaultBodyFontSize: result.defaultBodyFontSize,
                pageContentWidth: result.pageContentWidth,
                pageMarginLeft: result.pageMarginLeft, pageMarginRight: result.pageMarginRight,
                pageContentHeight: result.pageContentHeight,
                pageMarginTop: result.pageMarginTop, pageMarginBottom: result.pageMarginBottom,
                pageHeaderDistance: result.pageHeaderDistance,
                pageFooterDistance: result.pageFooterDistance,
                headers: result.headers, footers: result.footers,
                lineGridPitch: result.lineGridPitch)
            return
        }
        let archive = try ZipArchive(data: data)
        let result = try DocumentTypes.readOffice(archive, extension: ext)
        setOfficeContent(
            blocks: result.blocks, comments: result.comments, archive: archive,
            images: result.images,
            defaultBodyFontSize: DocumentTypes.officeDefaultBodyFontSize(archive, extension: ext),
            pageContentWidth: result.pageContentWidth,
                pageMarginLeft: result.pageMarginLeft, pageMarginRight: result.pageMarginRight,
                pageContentHeight: result.pageContentHeight,
                pageMarginTop: result.pageMarginTop, pageMarginBottom: result.pageMarginBottom,
                pageHeaderDistance: result.pageHeaderDistance,
                pageFooterDistance: result.pageFooterDistance,
                headers: result.headers, footers: result.footers,
                lineGridPitch: result.lineGridPitch)
    }

    /// The office-document seam `read(from:)` and `reloadDocument` both go through: the parser's
    /// output plus the archive it came from, which `reconcileMedia` needs to resolve an `.image`
    /// block's id to bytes. Not `private` — `OfficeDocumentTests` drives image loading against
    /// synthetic blocks/archives it builds itself, independent of whatever `DocxReader` parses (that
    /// parser's own correctness is `DocxReaderTests`' job, not this file's).
    func setOfficeContent(
        blocks: [OfficeBlock], comments: [OfficeComment] = [], archive: ZipArchive?,
        images: [String: Data] = [:], defaultBodyFontSize: CGFloat = 11,
        pageContentWidth: CGFloat? = nil,
        pageMarginLeft: CGFloat? = nil, pageMarginRight: CGFloat? = nil,
        pageContentHeight: CGFloat? = nil,
        pageMarginTop: CGFloat? = nil, pageMarginBottom: CGFloat? = nil,
        pageHeaderDistance: CGFloat? = nil, pageFooterDistance: CGFloat? = nil,
        headers: [OfficeHeaderFooter] = [], footers: [OfficeHeaderFooter] = [],
        lineGridPitch: CGFloat? = nil
    ) {
        self.officeBlocks = blocks
        self.officeComments = comments
        self.officeArchive = archive
        self.officeImageBytes = images
        self.officeDefaultBodyFontSize = defaultBodyFontSize
        self.officePageContentWidth = pageContentWidth
        self.officePageMarginLeft = pageMarginLeft
        self.officePageMarginRight = pageMarginRight
        self.officePageContentHeight = pageContentHeight
        self.officePageMarginTop = pageMarginTop
        self.officePageMarginBottom = pageMarginBottom
        self.officePageHeaderDistance = pageHeaderDistance
        self.officePageFooterDistance = pageFooterDistance
        self.officeHeaders = headers
        self.officeFooters = footers
        self.officeLineGridPitch = lineGridPitch
        self.text = ""
        self.file = TextFile(text: "", encoding: .utf8, hasBOM: false)
        cachedHasCrossBlockReferences = nil
    }

    override func makeWindowControllers() {
        let wc = DocumentWindowController()
        addWindowController(wc)
        // Deliberately still the OLD name after the FastDocReader rename: this string is a
        // defaults KEY holding the user's saved window frame, not an identifier anyone sees.
        // Renaming it orphans every existing user's remembered window size and position for no
        // gain — the same reasoning that keeps the bundle identifier `ai.ww-w.fast-md-reader`.
        wc.window?.setFrameAutosaveName("FastMDReaderDoc")
        // Record the file in Open Recent. Auto-recording wasn't firing for our open paths, so note
        // it explicitly (idempotent — the controller de-dupes).
        if let url = fileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        render(into: wc)
    }

    // MARK: - Font size (menu actions routed through the responder chain)

    /// What attempting to reload the file found — decided in one place, separate from the NSAlert
    /// `reloadDocument` shows for `.failure`, so the decision itself is testable headlessly (an
    /// `NSAlert.runModal()` is not). Before this existed, `reloadDocument` reached for `try?` at
    /// `Data(contentsOf:)`, `ZipArchive(data:)` AND `DocumentTypes.readOffice` — any one of the three
    /// failing meant the function silently did nothing, which looks identical to a successful no-op
    /// reload and hides a real problem (deleted file, permissions, a corrupted archive) from the user.
    enum ReloadOutcome {
        case office(blocks: [OfficeBlock], comments: [OfficeComment], archive: ZipArchive?, images: [String: Data], defaultBodyFontSize: CGFloat, pageContentWidth: CGFloat?, pageMarginLeft: CGFloat?, pageMarginRight: CGFloat?, pageContentHeight: CGFloat?, pageMarginTop: CGFloat?, pageMarginBottom: CGFloat?, pageHeaderDistance: CGFloat?, pageFooterDistance: CGFloat?, headers: [OfficeHeaderFooter], footers: [OfficeHeaderFooter], lineGridPitch: CGFloat?)
        case text(TextFile)
        case failure(String)
    }

    /// Reads `url` fresh (never the in-memory `text`/`officeBlocks` — this IS the re-read) and
    /// reports what happened. `kind`/`ext` are passed in rather than read from `self` so this stays
    /// a pure function of its arguments: nothing here mutates the document, which is what makes
    /// `MarkdownDocumentReloadTests` able to call it directly and assert `.failure` without ever
    /// constructing a window.
    static func reloadOutcome(url: URL, kind: DocumentKind, extension ext: String) -> ReloadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(error.localizedDescription)
        }
        guard kind == .office else {
            return .text(TextEncodingDetector.decode(data))
        }
        do {
            // HWP branches to `HwpReader.read(Data)` before `ZipArchive` for the same reason as
            // `read(from:)` — a `.hwp` is not a zip. Nil archive, images pre-decoded, and the SAME
            // `result.defaultBodyFontSize`/`pageContentWidth` the first open uses (NOT a hardcoded
            // 11 — that made a ⌘R reload of an HWP whose declared body size ≠ 11 render differently
            // from its first open, the exact regression invariant 29 forbids).
            if DocumentTypes.isHwp(ext) {
                let result = try HwpReader.read(data)
                return .office(
                    blocks: result.blocks, comments: result.comments, archive: nil,
                    images: result.images, defaultBodyFontSize: result.defaultBodyFontSize,
                    pageContentWidth: result.pageContentWidth,
                pageMarginLeft: result.pageMarginLeft, pageMarginRight: result.pageMarginRight,
                pageContentHeight: result.pageContentHeight,
                pageMarginTop: result.pageMarginTop, pageMarginBottom: result.pageMarginBottom,
                pageHeaderDistance: result.pageHeaderDistance,
                pageFooterDistance: result.pageFooterDistance,
                headers: result.headers, footers: result.footers,
                lineGridPitch: result.lineGridPitch)
            }
            let archive = try ZipArchive(data: data)
            let result = try DocumentTypes.readOffice(archive, extension: ext)
            let defaultBodyFontSize = DocumentTypes.officeDefaultBodyFontSize(archive, extension: ext)
            return .office(
                blocks: result.blocks, comments: result.comments, archive: archive,
                images: result.images, defaultBodyFontSize: defaultBodyFontSize,
                pageContentWidth: result.pageContentWidth,
                pageMarginLeft: result.pageMarginLeft, pageMarginRight: result.pageMarginRight,
                pageContentHeight: result.pageContentHeight,
                pageMarginTop: result.pageMarginTop, pageMarginBottom: result.pageMarginBottom,
                pageHeaderDistance: result.pageHeaderDistance,
                pageFooterDistance: result.pageFooterDistance,
                headers: result.headers, footers: result.footers,
                lineGridPitch: result.lineGridPitch)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// ⌘R: re-read the file from disk and re-render, keeping the scroll position. Note this
    /// reloads the DOCUMENT's content — it runs the currently-launched app binary, so it does
    /// not pick up a new app build (that still needs a relaunch).
    @objc func reloadDocument(_ sender: Any?) {
        // Re-reading throws away whatever hasn't been saved, so say so first. Silently discarding
        // edits because someone reached for Reload would be the worst kind of data loss: invisible.
        if isDocumentEdited {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Reload and lose your unsaved changes?"
            a.informativeText = "\(fileURL?.lastPathComponent ?? "This document") has edits that haven't been saved. Reloading reads the file from disk again and discards them."
            a.addButton(withTitle: "Reload")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if let url = fileURL {
            let ext = url.pathExtension.isEmpty ? (untitledExtension ?? "") : url.pathExtension
            switch Self.reloadOutcome(url: url, kind: kind, extension: ext) {
            case .office(let blocks, let comments, let archive, let images, let defaultBodyFontSize, let pageContentWidth, let pageMarginLeft, let pageMarginRight, let pageContentHeight, let pageMarginTop, let pageMarginBottom, let pageHeaderDistance, let pageFooterDistance, let headers, let footers, let lineGridPitch):
                // Re-parse the archive, same as the initial read — never through the text-decode
                // path (invariant: an office document's bytes are never handed to
                // `TextEncodingDetector`). `defaultBodyFontSize` is carried through too, so a
                // reload renders identically to the first open of the same file (see invariant 29's
                // "reload must behave the same as first open" lesson).
                setOfficeContent(blocks: blocks, comments: comments, archive: archive, images: images,
                                 defaultBodyFontSize: defaultBodyFontSize, pageContentWidth: pageContentWidth,
                                 pageMarginLeft: pageMarginLeft, pageMarginRight: pageMarginRight,
                                 pageContentHeight: pageContentHeight,
                                 pageMarginTop: pageMarginTop, pageMarginBottom: pageMarginBottom,
                                 headers: headers, footers: footers,
                                 lineGridPitch: lineGridPitch)
            case .text(let reread):
                // The undo stack holds source OFFSETS into the text we're replacing. Re-reading the
                // file can move every one of them (the file may have changed behind us), so an undo
                // applied afterwards would overwrite the wrong span. Drop the history rather than
                // corrupt the file. Compared as TEXT, not bytes: re-encoding is not a change the
                // user made.
                if reread.text != self.text { undoManager?.removeAllActions() }
                self.file = reread
                self.text = reread.text
                cachedHasCrossBlockReferences = nil
                localImageSizeCache = [:]   // an image beside the file may have changed on disk too
                updateChangeCount(.changeCleared)     // the document now matches the file again
            case .failure(let message):
                // Nothing above this case has touched `self.text`/`self.file`/`officeBlocks` —
                // the document on screen stays exactly what it was. Silently doing nothing (the
                // old `try?` behaviour) looked identical to a successful no-op reload; this says
                // out loud that the file on disk could not be read.
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Couldn't reload \(url.lastPathComponent)"
                a.informativeText = message
                a.addButton(withTitle: "OK")
                a.runModal()
            }
        }
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let anchor = wc.topVisibleCharIndex()
        render(into: wc)
        wc.scrollCharToTop(anchor)
    }

    // MARK: - Block-level source editing (right-click a selection → Edit)

    /// The markdown source substring for a block's source range (UTF-16).
    func sourceSubstring(_ r: NSRange) -> String {
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length else { return "" }
        return ns.substring(with: r)
    }

    /// Replace a source range with edited markdown and update the screen. Nothing is written to
    /// disk — that is ⌘S (see `data(ofType:)`); this marks the document dirty instead.
    ///
    /// Undo runs back through here with the inverse edit, so it re-renders exactly like a typed one,
    /// and redo falls out for free: the undo manager records the inverse this call registers while
    /// it is undoing.
    func applySourceEdit(_ r: NSRange, with replacement: String, actionName: String = "Edit") {
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length else { NSSound.beep(); return }
        // Decided against the text BEFORE this edit — `spliceRender` runs after `self.text` below
        // has already become the NEW text, so this is the only point that still has both "before"
        // (`ns`/`r`) and "after" (`replacement`) in hand at once. See `editTouchesDefinitionLine`.
        let touchesDefinitionLine = kind == .markdown
            && Self.editTouchesDefinitionLine(r, replacement: replacement, in: ns)
        let updated = ns.replacingCharacters(in: r, with: replacement)
        if kind == .markdown {
            updateCrossBlockReferencesCache(before: ns, range: r, replacement: replacement, after: updated)
        }
        let previous = ns.substring(with: r)
        self.text = updated
        self.file.text = updated          // keep the two in step; `file` also carries the encoding
        let undoRange = NSRange(location: r.location, length: (replacement as NSString).length)
        undoManager?.registerUndo(withTarget: self) {
            $0.applySourceEdit(undoRange, with: previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        // Re-rendering the WHOLE document for one changed block is what made long files crawl:
        // measured at 92ms in `display` alone for a 64k-character file, and it grows with the file,
        // so undo/redo of a small edit paid the price of the entire document. Splice the changed
        // blocks in instead, and fall back to the full path only when that can't be trusted.
        let newSpan = NSRange(location: r.location, length: (replacement as NSString).length)
        if spliceRender(into: wc, editedSource: r, replacementLength: newSpan.length,
                        touchesDefinitionLine: touchesDefinitionLine) {
            wc.revealEditedSource(newSpan, highlight: newSpan.length > 0)
            return
        }
        let anchor = wc.topVisibleCharIndex()
        render(into: wc)
        wc.scrollCharToTop(anchor)
        wc.revealEditedSource(newSpan, highlight: newSpan.length > 0)
    }

    // MARK: - Incremental (spliced) re-render

    /// Block ids must stay unique across a splice: two neighbouring blocks that share an id read as
    /// ONE block to the reading cursor and the gutter. A fresh fragment numbers its blocks from
    /// zero, so each splice lifts them clear of every id already on screen.
    private var blockIdBase = 1_000_000

    /// Redraw ONLY the blocks an edit touched.
    ///
    /// Safe because a block renders the same alone as it does in context — verified per block kind
    /// in FragmentRenderTests — with one documented exception: a reference-style link resolves
    /// against a DEFINITION that can live anywhere in the file. A definition renders to NOTHING in
    /// CommonMark (`AttributedBuilder.tagBlock`'s `guard r.length > 0` never fires for one — no
    /// glyphs, no `srcRange`, no footprint), so every one the document currently declares is
    /// PREPENDED to the fragment's source before it renders (`definitionsPrefix`) — a reference
    /// INSIDE the fragment then resolves exactly as it would in a full render, with nothing added
    /// to what's on screen. Prepended, not appended: CommonMark resolves a duplicate label to
    /// whichever definition the parser sees FIRST, and "run the fragment to where the next block
    /// starts" (below) can already carry a definition of its own inside the fragment's tail — a
    /// definition renders to nothing, so it gets no `srcRange` and so no entry in `BlockEdit.spans`,
    /// meaning it never stops the fragment from swallowing it — and that one isn't necessarily the
    /// document's true first for its label. Putting the document's real first-per-label definitions
    /// at the very front of what gets parsed is what keeps that ordering honest regardless of what
    /// the fragment happens to carry along; `rebase` corrects the local offsets a prefix shifts by
    /// exactly its own length, so nothing here disturbs the srcRange story.
    ///
    /// That only covers references the FRAGMENT makes, though — a block elsewhere that references a
    /// definition THIS edit adds, edits or removes would need its own re-render to notice, which a
    /// splice never gives it. `touchesDefinitionLine` (computed by the caller, against the text
    /// before AND after the edit) is what still sends such an edit down the full path — everything
    /// else here now splices.
    ///
    /// Returns false when it cannot do the job, and the caller re-renders everything. Refusing is
    /// always correct here; guessing is not.
    private func spliceRender(into wc: DocumentWindowController, editedSource r: NSRange,
                              replacementLength: Int, touchesDefinitionLine: Bool) -> Bool {
        guard let storage = wc.textStorageRef, storage.length > 0 else { return false }
        // An office document has no source text to splice a substring out of — `text` is "" for
        // these (see `read(from:ofType:)`) — and it never reaches here anyway, since every path
        // that calls `applySourceEdit` is gated shut for `.office`. Refuse rather than assume.
        guard kind != .office else { return false }
        if touchesDefinitionLine { return false }

        let spans = BlockEdit.spans(in: storage)          // spans of the text BEFORE this edit
        guard let first = BlockEdit.indexOfBlock(containing: r.location, in: spans) else { return false }
        // Grow the run until it covers the whole edited range: a delete reaches past its block into
        // the separator and on into the next one, and the fragment must span all of it.
        var last = first
        let editEnd = r.location + r.length
        while last + 1 < spans.count, spans[last].location + spans[last].length < editEnd { last += 1 }
        let oldStart = spans[first].location
        let oldEnd = spans[last].location + spans[last].length
        guard oldStart <= r.location, oldEnd >= editEnd else { return false }   // edit spills outside the blocks

        let delta = replacementLength - r.length
        let ns = text as NSString
        // Run the fragment up to where the NEXT block starts, not just to the last block's text.
        // A block's rendered range includes the separator that follows it (in a text file that is
        // the newline the blank line itself is made of), so a fragment that stopped at the text
        // would splice that separator away.
        // (`spans` are offsets into the text BEFORE the edit; `ns` is the text after, so the old
        // length is recovered from the delta rather than kept around.)
        let oldTextLength = ns.length - delta
        let oldFragmentEnd = last + 1 < spans.count ? spans[last + 1].location : oldTextLength
        let newLength = (oldFragmentEnd - oldStart) + delta
        guard newLength >= 0, oldStart + newLength <= ns.length else { return false }

        // The rendered range these blocks occupy must be one contiguous run to be replaceable.
        guard let rendered = renderedRange(ofSourceSpans: spans[first...last], in: storage) else { return false }

        let theme = RenderTheme.current(size: readingSize)
        let fragmentSource = ns.substring(with: NSRange(location: oldStart, length: newLength))
        // `hasCrossBlockReferences` is the same cheap whole-document existence check every markdown
        // splice already paid before this fix — a document with none of the syntax takes the `nil`
        // arm and pays nothing further, `renderSource` identical to `fragmentSource`.
        let prefix = (kind == .markdown && hasCrossBlockReferences)
            ? Self.definitionsPrefix(documentText: text) : nil
        let renderSource = (prefix ?? "") + fragmentSource
        let fragment = NSMutableAttributedString(attributedString:
            kind == .plainText ? PlainTextRenderer.render(fragmentSource, theme: theme)
                               : MarkdownRenderer.render(renderSource, theme: theme))
        // A fragment is rendered from position zero (plus, for markdown, whatever definitions
        // prefix was glued ahead of it), so its source offsets and block ids are local. Lift both
        // into the document's coordinates before it goes in.
        let prefixLength = (prefix as NSString?)?.length ?? 0
        rebase(fragment, sourceOffset: oldStart, idBase: blockIdBase, localOffsetTrim: prefixLength)
        blockIdBase += 100_000

        let tail = NSRange(location: rendered.location + rendered.length,
                           length: storage.length - (rendered.location + rendered.length))
        storage.beginEditing()
        storage.replaceCharacters(in: rendered, with: fragment)
        // Everything after the splice keeps its rendered text but now sits at a different place in
        // the FILE, so its recorded source offsets move by the same delta the edit made.
        if delta != 0, tail.length > 0 {
            let shifted = NSRange(location: rendered.location + fragment.length,
                                  length: storage.length - (rendered.location + fragment.length))
            storage.enumerateAttribute(MDAttr.srcRange, in: shifted) { value, range, _ in
                guard let s = (value as? NSValue)?.rangeValue else { return }
                storage.addAttribute(MDAttr.srcRange,
                                     value: NSValue(range: NSRange(location: s.location + delta, length: s.length)),
                                     range: range)
            }
        }
        storage.endEditing()

        renderGeneration += 1
        wc.refreshAfterMutation()
        // An edit can add, remove or rename a heading — `## New section` typed into a block, a
        // section moved, a heading deleted — so the table of contents is as much a product of this
        // path as the text is. Only the full re-render used to rebuild it, which is why the sidebar
        // quietly described the document as it was several edits ago.
        wc.reloadOutline()
        wc.reloadCommentPanel()
        // Media inside the new fragment still needs its exact area reserved before it can draw —
        // same rule as a full render (invariant: size first, pixels later).
        DispatchQueue.main.async { [weak self, weak wc] in
            guard let self, let wc else { return }
            self.presizeKnownMedia(in: wc)
            self.reconcileMedia(in: wc)
            self.prerenderAllDiagrams(in: wc)
            self.measureRemoteImages(in: wc)
        }
        return true
    }

    /// The single contiguous rendered range covering a run of source spans, or nil if the run isn't
    /// contiguous on screen (which would make a splice cut into something it shouldn't).
    private func renderedRange(ofSourceSpans wanted: ArraySlice<NSRange>,
                               in storage: NSTextStorage) -> NSRange? {
        let targets = Set(wanted.map { NSRange(location: $0.location, length: $0.length) }.map(NSStringFromRange))
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let s = (v as? NSValue)?.rangeValue, targets.contains(NSStringFromRange(s)) else { return }
            lo = min(lo, r.location); hi = max(hi, r.location + r.length)
        }
        guard lo != Int.max, hi > lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    /// `localOffsetTrim` is the length of a synthetic definitions PREFIX (see `definitionsPrefix`)
    /// that was glued ahead of the fragment's own source before rendering, if any. A definition
    /// renders to nothing (no `srcRange` ever gets tagged for one — see this function's caller's
    /// doc), so every `srcRange` this enumeration actually visits belongs to the fragment's OWN
    /// content and sits at `localOffsetTrim` or later; subtracting it first recovers the offset
    /// relative to the fragment alone, exactly as if no prefix had ever been glued on, before
    /// re-basing onto the true document with `sourceOffset`. Zero when there was no prefix, so this
    /// is a no-op for plain text and for markdown with no cross-block references — the common case.
    private func rebase(_ fragment: NSMutableAttributedString, sourceOffset: Int, idBase: Int,
                        localOffsetTrim: Int = 0) {
        let whole = NSRange(location: 0, length: fragment.length)
        fragment.enumerateAttribute(MDAttr.srcRange, in: whole) { value, range, _ in
            guard let s = (value as? NSValue)?.rangeValue else { return }
            let local = max(0, s.location - localOffsetTrim)
            fragment.addAttribute(MDAttr.srcRange,
                                  value: NSValue(range: NSRange(location: local + sourceOffset, length: s.length)),
                                  range: range)
        }
        fragment.enumerateAttribute(MDAttr.blockId, in: whole) { value, range, _ in
            guard let id = value as? Int else { return }
            fragment.addAttribute(MDAttr.blockId, value: idBase + id, range: range)
        }
    }

    // MARK: - Cross-block references (link/footnote definitions)

    /// Cache for `hasCrossBlockReferences` below — recomputing it is a whole-document line-by-line
    /// scan (measured 29-33 ms on 1.2 MB, 57-58 ms on 2.4 MB), and `spliceRender` asks it on every
    /// successful markdown splice, so it was the largest single cost left in the edit path. `nil`
    /// means "not yet known"; the getter computes it fresh (once) the first time anything asks, and
    /// `updateCrossBlockReferencesCache` keeps it in step after that — see its doc for the
    /// invalidation rule. Reset to `nil` wherever `text` is replaced wholesale rather than through
    /// `applySourceEdit` (`read(from:)`, `setOfficeContent`, `reloadDocument`'s text-reread branch,
    /// `prepareUntitled`) — those are NOT edits this cache's incremental rule was built to track.
    private var cachedHasCrossBlockReferences: Bool?

    /// True when the document has a line that LOOKS LIKE a link reference definition — the coarse,
    /// deliberately loose existence check `spliceRender` uses to decide whether it's worth looking
    /// any closer (see `editTouchesDefinitionLine`, `definitionsPrefix`). A false positive here
    /// (GFM footnote syntax `[^1]: …` matches too — see `isDefinitionLine`'s doc comment; so does a
    /// definition-shaped line sitting inert inside a fenced code block) only ever costs an
    /// unnecessary look from `definitionLineRanges`, which is itself precise — never a wrong render
    /// — so looseness is safe here, which is also why the cache below is allowed to stay
    /// stale-`true`, never stale-`false` (see `updateCrossBlockReferencesCache`).
    private var hasCrossBlockReferences: Bool {
        if let cached = cachedHasCrossBlockReferences { return cached }
        let fresh = Self.containsReferenceDefinitionLine(text)
        cachedHasCrossBlockReferences = fresh
        return fresh
    }

    /// The SAME coarse test `hasCrossBlockReferences` uses, generalised to any string — reused, in
    /// `editTouchesDefinitionLine`, against just the text an edit touches (bounded by the EDIT's
    /// size, never the document's).
    private static func containsReferenceDefinitionLine(_ s: String) -> Bool {
        s.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.contains("]:")
        }
    }

    /// `r`, widened out to the full line(s) it lies within — from the newline immediately before it
    /// (or the start of `s`) to the newline immediately after it (or the end of `s`), NOT including
    /// either boundary newline itself. Bounded by the length of the surrounding line(s), not the
    /// document — what keeps both `editTouchesDefinitionLine` and
    /// `updateCrossBlockReferencesCache` cheap even in a huge file; they share this rather than each
    /// re-deriving it.
    private static func lineSpan(around r: NSRange, in s: NSString) -> NSRange {
        var start = r.location
        while start > 0, s.character(at: start - 1) != 10 { start -= 1 }   // 10 == "\n"
        var end = r.location + r.length
        while end < s.length, s.character(at: end) != 10 { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// True when replacing `r` (in the text BEFORE this edit) with `replacement` can change which
    /// labels the document DEFINES — either an existing definition line inside `r` is edited or
    /// removed, or `replacement` itself types a new one. A definition resolves document-wide by
    /// LABEL, not by position, so a change here can alter how a block far outside `r`'s own blocks
    /// reads on screen — the one case `spliceRender` still can't trust to a splice (everything else
    /// now does — see its doc comment).
    ///
    /// Widens `r` out to the full LINE(S) it lies within (`lineSpan`) and checks THAT — in the old
    /// text as it stood, and in what the same span becomes once `replacement` lands — rather than
    /// checking only `r`'s own substring and `replacement` in isolation. The widened old text is a
    /// strict superset of `r`'s own substring and the widened new text is a strict superset of
    /// `replacement`, so this subsumes a narrower "does r/replacement itself contain a bracket"
    /// check rather than needing it alongside — and it is what closes a real gap that narrower check
    /// has: deleting the blank line before `[ref]: url` merges it into the paragraph above (a real
    /// definition becomes ordinary paragraph text — CommonMark reference definitions cannot
    /// interrupt a paragraph), yet the character actually removed is only that blank line's own
    /// "\n" — no bracket in it, so a check confined to the literal edited characters misses it.
    /// Bounded by the length of the surrounding line(s), never the document, so this still costs
    /// nothing extra for a typical edit even in a document that uses the syntax heavily.
    private static func editTouchesDefinitionLine(_ r: NSRange, replacement: String, in ns: NSString) -> Bool {
        let span = lineSpan(around: r, in: ns)
        let prefix = ns.substring(with: NSRange(location: span.location, length: r.location - span.location))
        let suffixStart = r.location + r.length
        let suffix = ns.substring(with: NSRange(location: suffixStart, length: span.location + span.length - suffixStart))
        if containsReferenceDefinitionLine(prefix + ns.substring(with: r) + suffix) { return true }
        return containsReferenceDefinitionLine(prefix + replacement + suffix)
    }

    /// Keeps `cachedHasCrossBlockReferences` correct across an edit — called from `applySourceEdit`
    /// for every markdown edit, with the same `ns` (text BEFORE the edit) / `r` / `replacement`
    /// `editTouchesDefinitionLine` uses, plus `updated` (text AFTER), so this pays no extra string
    /// work to obtain them.
    ///
    /// THE INVALIDATION RULE, AND WHY IT CANNOT MISS A CASE: a definition-candidate line's status
    /// can only change for lines that lie inside the edited region OR are newly/formerly ADJACENT to
    /// it because a newline was added or removed there — every line further away is untouched
    /// byte-for-byte (same characters, same neighbours), so its candidate status cannot move. So
    /// this widens `r` to its enclosing line boundaries (`lineSpan`, the SAME widening
    /// `editTouchesDefinitionLine` uses and for the identical reason — a naive "does the touched
    /// text itself contain a bracket" rule misses a newline-only edit that merges or splits an
    /// UNTOUCHED bracket line) and asks only whether THAT widened span contains a candidate line,
    /// before the edit and after:
    ///   - after == true  → the document definitely has a candidate somewhere (this span is proof)
    ///     — set the cache to `true` outright, no whole-document scan needed.
    ///   - after == false, before == false → this span contributed nothing to the answer either
    ///     time, so whatever the cache already said is still correct — leave it untouched.
    ///   - after == false, before == true → a candidate that WAS inside this span is gone; the
    ///     document-wide answer may have flipped (if this was the only one) or may not have (if
    ///     another candidate exists elsewhere) — only a full scan can tell, so this is the one case
    ///     that pays for one. Every other edit — the overwhelming common case for prose with no
    ///     reference-style syntax nearby — costs two small, line-bounded scans and nothing more.
    private func updateCrossBlockReferencesCache(before ns: NSString, range r: NSRange, replacement: String, after updated: String) {
        let span = Self.lineSpan(around: r, in: ns)
        let prefix = ns.substring(with: NSRange(location: span.location, length: r.location - span.location))
        let suffixStart = r.location + r.length
        let suffix = ns.substring(with: NSRange(location: suffixStart, length: span.location + span.length - suffixStart))
        let beforeHasCandidate = Self.containsReferenceDefinitionLine(prefix + ns.substring(with: r) + suffix)
        if Self.containsReferenceDefinitionLine(prefix + replacement + suffix) {
            cachedHasCrossBlockReferences = true
        } else if beforeHasCandidate {
            cachedHasCrossBlockReferences = Self.containsReferenceDefinitionLine(updated)
        }
        // else (after == false, before == false): unchanged — leave the cache exactly as it was.
    }

    /// A precise, single-line link-reference-definition match: `[label]: destination`, optionally
    /// followed by a same-line quoted/parenthesised title. Deliberately STRICTER than
    /// `containsReferenceDefinitionLine`'s loose `[`…`]:` test above: that one is only ever used to
    /// decide whether to look closer or fall back to looking at every definition, so a false
    /// positive there is harmless (an unnecessary look, never a wrong render). This one decides
    /// what text gets COPIED into another fragment's rendered source (`definitionsPrefix`), where a
    /// false positive is NOT harmless — it would inject a real block's own text into every other
    /// fragment as if it were an invisible definition. Concretely this is what rules out GFM
    /// footnote syntax (`[^1]: The note.`): it starts with `[` and contains `]:` exactly like a
    /// real definition, but "The note." isn't a valid destination-with-nothing-else-trailing, so
    /// swift-markdown renders it as an ordinary PARAGRAPH, not nothing. Doesn't chase a title onto
    /// a SECOND line (`[foo]: /url` on one line, `"title"` on the next, both valid CommonMark) —
    /// harmless here, because the label+destination line alone already matches and already carries
    /// everything this app's own renderer reads (`link.title` is never used, only
    /// `link.destination`), so the omitted title line changes nothing visible.
    private static let definitionLineRE = try! NSRegularExpression(
        pattern: #"^\[[^\]\n]+\]:\s*(?:<[^<>\n]*>|\S+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?$"#)

    /// True when `line` is SHAPED like a link reference definition on its own — CommonMark also
    /// requires it not be indented 4 or more spaces (that reads as an indented CODE block, or the
    /// lazy continuation of one, never a fresh definition start — the same limit every other block
    /// starter in the spec obeys). Checked against the RAW line, before any trimming: trimming
    /// first and matching on the trimmed result is what let a `    [ref]: url` inside an indented
    /// code block through — its indentation stripped away by that same trim, so the text got
    /// copied into another fragment (`definitionsPrefix`) as a live definition instead of the
    /// visible code it actually is, breaking both "renders to nothing" and every recorded srcRange
    /// downstream of it.
    private static func isDefinitionLine(_ line: String) -> Bool {
        var indent = 0
        for ch in line {
            if ch == " " { indent += 1; if indent >= 4 { return false } }
            else if ch == "\t" { return false }
            else { break }
        }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let ts = t as NSString
        return definitionLineRE.firstMatch(in: t, range: NSRange(location: 0, length: ts.length)) != nil
    }

    /// A CommonMark fence-OPENING line: 0-3 leading spaces, then a run of 3+ backticks or 3+
    /// tildes. Marker and run length are returned so `isClosingFence` can require the SAME
    /// character and AT LEAST that many of it (a longer closing fence is valid CommonMark; a
    /// shorter one, or the other character, is not a close at all — it's still fence content). A
    /// backtick fence's info string may not itself contain a backtick (CommonMark §4.5); a tilde
    /// fence has no such restriction.
    private static func openingFence(_ line: String) -> (marker: Character, minCloseLength: Int)? {
        let chars = Array(line)
        var i = 0, indent = 0
        while i < chars.count, chars[i] == " ", indent < 3 { i += 1; indent += 1 }
        guard i < chars.count, chars[i] == "`" || chars[i] == "~" else { return nil }
        let marker = chars[i]
        var runLength = 0
        while i < chars.count, chars[i] == marker { i += 1; runLength += 1 }
        guard runLength >= 3 else { return nil }
        if marker == "`", chars[i...].contains("`") { return nil }
        return (marker, runLength)
    }

    /// True when `line` closes a fence opened with `marker`/`minCloseLength` — 0-3 leading spaces,
    /// a run of AT LEAST `minCloseLength` of the SAME `marker` character, and nothing after it but
    /// trailing whitespace. An unclosed fence (no line in the rest of the document satisfies this)
    /// runs to the end of the document, per CommonMark — `definitionLineRanges` below relies on
    /// exactly that: the scanning loop simply never finds a close, so every remaining line falls
    /// into the "still fenced" branch and none of them is ever a candidate.
    private static func isClosingFence(_ line: String, marker: Character, minCloseLength: Int) -> Bool {
        let chars = Array(line)
        var i = 0, indent = 0
        while i < chars.count, chars[i] == " ", indent < 3 { i += 1; indent += 1 }
        var runLength = 0
        while i < chars.count, chars[i] == marker { i += 1; runLength += 1 }
        guard runLength >= minCloseLength else { return false }
        return chars[i...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// A generous, line-shape-only test for "this line closes whatever paragraph was open above it,
    /// even with no blank line in between" — an ATX heading, a thematic break (or a setext heading's
    /// own underline, which reads identically for this purpose: either way nothing is open after
    /// it), a list item marker, a block quote marker, or a table-ish row. Deliberately loose: a
    /// false positive here only ever makes the line AFTER it eligible for the definition-shape
    /// check in `definitionLineRanges`, which still has to pass `isDefinitionLine` on its own — it
    /// can never manufacture a definition that isn't itself shaped like one. Without this, a real
    /// definition sitting directly under a heading or a thematic break (both valid CommonMark, both
    /// common) was silently EXCLUDED — and because routing to the full-render fallback doesn't
    /// depend on this precision (only on the coarse `hasCrossBlockReferences`/
    /// `editTouchesDefinitionLine` checks above), that exclusion isn't a safe "do a bit more work
    /// elsewhere" — it's a wrong render: the reference resolves in a full render and silently
    /// doesn't in a splice.
    private static func interruptsParagraph(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("#") { return true }                          // ATX heading
        if t.hasPrefix(">") { return true }                          // block quote
        if t.contains("|") { return true }                           // table-ish row
        let squeezed = t.replacingOccurrences(of: " ", with: "")
        if squeezed.count >= 3, Set(squeezed).count == 1, let c = squeezed.first, "-*_=".contains(c) {
            return true                                               // thematic break / setext underline
        }
        return t.range(of: #"^([-*+]|\d{1,9}[.)])(\s|$)"#, options: .regularExpression) != nil   // list item
    }

    /// Every line of `s` that is BOTH shaped like a link reference definition (`isDefinitionLine`)
    /// AND is something the real CommonMark parser would actually read as one — not a line inside a
    /// fenced or indented code block (verbatim text, never live syntax — indented is handled for
    /// free by `isDefinitionLine` rejecting 4+ leading spaces; fenced is tracked explicitly below),
    /// and not the lazy continuation of an open paragraph (a definition-shaped line directly
    /// following ordinary paragraph text, with nothing between them that would end that paragraph,
    /// is that paragraph's own text — CommonMark reference definitions cannot interrupt a
    /// paragraph). Returned as each accepted line's own whole-line UTF-16 range (its own trailing
    /// newline excluded, matching how a block's `srcRange` is cut elsewhere in this file), so its
    /// exact source text can be pulled out and reused, not just known to exist.
    ///
    /// This is a coarse, line-shape-only scan, not a full block-grammar parse — it tracks just
    /// enough state (fence open/close, and whether the line before "closed" whatever paragraph was
    /// open) to answer those two questions safely. A false EXCLUSION here is a WRONG render, not a
    /// harmless fallback (see `interruptsParagraph`'s doc) — so `interruptsParagraph` is
    /// deliberately generous rather than exhaustive-and-risky.
    private static func definitionLineRanges(in s: String) -> [NSRange] {
        let ns = s as NSString
        var out: [NSRange] = []
        var start = 0
        var precededByBlankOrDefinition = true   // start of document — nothing open above it
        var fence: (marker: Character, minCloseLength: Int)?
        while start <= ns.length {
            var end = start
            while end < ns.length, ns.character(at: end) != 10 { end += 1 }   // up to, not incl., \n
            let lineRange = NSRange(location: start, length: end - start)
            let line = ns.substring(with: lineRange)

            if let open = fence {
                if isClosingFence(line, marker: open.marker, minCloseLength: open.minCloseLength) {
                    fence = nil
                    // The block after a fence is fresh — like text after a blank line, it can
                    // itself open a definition, whether or not this close line has a blank line
                    // after it.
                    precededByBlankOrDefinition = true
                }
                // Every other line here is fence CONTENT: verbatim, never a candidate.
            } else if let opened = openingFence(line) {
                fence = opened
                precededByBlankOrDefinition = false   // a fence marker line is never itself a definition
            } else {
                let isBlank = lineRange.length == 0
                    || line.trimmingCharacters(in: .whitespaces).isEmpty
                let isCandidate = !isBlank && isDefinitionLine(line)
                let accepted = isCandidate && precededByBlankOrDefinition
                if accepted { out.append(lineRange) }
                // The NEXT line is free to define when THIS one didn't leave a paragraph open
                // beneath it — true when this line is blank, was itself just accepted (chaining
                // consecutive definitions with no blank line required between entries), or is one
                // of the other constructs that always closes a paragraph even with no blank line
                // before it (`interruptsParagraph`). A REJECTED candidate, like any other ordinary
                // text, leaves the paragraph open under it.
                precededByBlankOrDefinition = isBlank || accepted
                    || (!isCandidate && interruptsParagraph(line))
            }

            if end >= ns.length { break }
            start = end + 1   // skip the \n
        }
        return out
    }

    /// The definitions text to PREPEND before a fragment's own source so a reference INSIDE it
    /// resolves exactly as it would in a full render — `nil` when `documentText` declares none (the
    /// common case: pure pass-through, no extra parse cost). Prepended, not appended — see
    /// `spliceRender`'s doc for why the position matters for duplicate labels — joined by exactly
    /// one blank line so the first prepended definition can't merge into whatever text follows it,
    /// and ending in that same blank line so the fragment's own first line is never read as its
    /// continuation.
    private static func definitionsPrefix(documentText: String) -> String? {
        let ns = documentText as NSString
        let defs = definitionLineRanges(in: documentText).map { ns.substring(with: $0) }
        guard !defs.isEmpty else { return nil }
        return defs.joined(separator: "\n") + "\n\n"
    }

    // MARK: - Undo / Redo (⌘Z, ⇧⌘Z)

    /// Own selectors rather than the standard `undo:`/`redo:`: the menu bar is built in code, so
    /// nothing wires those up for us, and this app's responder chain already reaches the document
    /// this way (see `reloadDocument:`). SourceEditPanel answers the same two selectors for its own
    /// typing, so one pair of menu items serves both windows.
    @objc func undoSourceEdit(_ sender: Any?) { undoManager?.undo() }
    @objc func redoSourceEdit(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undoSourceEdit(_:)): return undoManager?.canUndo ?? false
        case #selector(redoSourceEdit(_:)): return undoManager?.canRedo ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }

    /// The three live size actions. Each changes THIS document and then records the result as the
    /// seed for the next document opened — writing the seed is the only thing that outlives this
    /// document, and nothing already open ever reads it again (see `readingSize` above).
    ///
    /// A PAGED document takes none of that road: it is shown at its own scale and ZOOMED, so each
    /// action becomes a view transform on the window controller and returns before anything is
    /// rebuilt. That is the whole point — a rebuild deep in a 401,765-character report cost a
    /// 65,853 ms freeze (invariant 56b), and a document that is never rebuilt cannot pay it.
    /// The fork lives here, at the top of the chain, because this is where `officePageContentWidth`
    /// is visible; everything below (`setReadingSize`, the debounce, `render`) stays untouched and
    /// keeps serving markdown, plain text, and office documents with no page width.
    @objc func increaseReaderFontSize(_ sender: Any?) {
        if pagedController?.stepPageZoom(magnifying: true) == true { return }
        setReadingSize(FontSizeStore.increased(from: readingSize))
    }
    @objc func decreaseReaderFontSize(_ sender: Any?) {
        if pagedController?.stepPageZoom(magnifying: false) == true { return }
        setReadingSize(FontSizeStore.decreased(from: readingSize))
    }
    @objc func resetReaderFontSize(_ sender: Any?) {
        if pagedController?.fitPageZoom() == true { return }
        setReadingSize(FontSizeStore.defaultSize)
    }

    /// This document's window controller, but only while the document is paged — so a caller that
    /// asks for it is asking exactly the question "should this be a zoom?".
    private var pagedController: DocumentWindowController? {
        guard let wc = windowControllers.first as? DocumentWindowController, wc.isPaged else { return nil }
        return wc
    }

    /// The pinch gesture's commit point (`ReaderScrollView`): the same single rebuild ⌘+/⌘− costs,
    /// applied to a size the gesture chose rather than to a step.
    func applyReadingSize(_ v: CGFloat) { setReadingSize(FontSizeStore.clamped(v)) }

    private func setReadingSize(_ v: CGFloat) {
        readingSize = v
        FontSizeStore.startingSize = v
        reRenderPreservingCaret()
    }

    /// A queued font-size rebuild, kept so a burst of presses collapses into one (see below).
    private var pendingFontRerender: DispatchWorkItem?

    /// ⌘+/⌘− rebuilds and re-lays out the WHOLE document — measured end to end at 0.36 s on a
    /// 38-table Word report and 0.8 s on a 62-table HWP. Pressing the key three times quickly used
    /// to cost three of those, one after another, and the reader sat through all three even though
    /// only the LAST size is ever seen. So the rebuild is debounced: each press cancels the queued
    /// one and re-queues, and because `readingSize` was already updated synchronously, the single
    /// rebuild that survives renders the FINAL size. 120 ms is short enough to feel immediate and far
    /// shorter than one rebuild, so a burst now costs one rebuild instead of N.
    private func reRenderPreservingCaret() {
        pendingFontRerender?.cancel()
        // LEADING edge: the first press after a pause renders immediately, so the key always does
        // something visible the moment it is pressed. Only presses that arrive while a rebuild is
        // still fresh are collapsed into ONE trailing render at the final size.
        //
        // A plain trailing debounce (what this was) is what made ⌘+ feel BROKEN rather than fast:
        // holding the key re-queued the work on every repeat, so the document sat unchanged until
        // the key was released — the total work went down but the reader saw nothing happen.
        // "In flight" matters as much as "how long ago": several presses can land in ONE run-loop
        // turn (a held key, or a script), and without this each would start its own full rebuild.
        if !fontRerenderInFlight, Date().timeIntervalSince(lastFontRerenderEnded) > Self.fontRerenderIdleGap {
            fontRerenderInFlight = true
            performFontSizeRerender()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFontRerender = nil
            self.fontRerenderInFlight = true
            self.performFontSizeRerender()
        }
        pendingFontRerender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// How long after a font re-render finishes the next press is still treated as part of the same
    /// burst. Below this, presses collapse; above it, the next press renders at once.
    private static let fontRerenderIdleGap: TimeInterval = 0.25
    private var lastFontRerenderEnded = Date.distantPast
    private var fontRerenderInFlight = false

    /// Whether an office re-render is heavy enough to deserve the spinner. Cost here is driven by
    /// TABLES and graphics, not by character count — the 62-table HWP measured at 0.8 s per font
    /// change holds only ~19k characters, well under `runBusy`'s 120k-character heuristic, so the
    /// slowest operation in the app was the one showing no feedback. Early-exits after the eighth.
    private var officeRerenderIsHeavy: Bool {
        guard kind == .office else { return false }
        var structural = 0
        for block in officeBlocks {
            switch block {
            case .table, .image, .unsupportedGraphic: structural += 1
            default: break
            }
            if structural >= 8 { return true }
        }
        return false
    }

    private func performFontSizeRerender() {
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let anchor = wc.readingAnchor()            // cursor if visible, else the middle of the page
        let savedCaret = wc.textView.readingCaret
        // A font-size change re-renders and re-lays out EVERYTHING, media included — the slowest
        // thing the app does on a long document, so it gets the spinner like the other reflows.
        wc.runBusy(heavy: officeRerenderIsHeavy) { [weak self, weak wc] in
            guard let self, let wc else { return }
            self.render(into: wc)                   // resets caret to 0 and re-lays out at the new size
            wc.textView.readingCaret = savedCaret   // restore reading position (clamped internally)
            wc.restore(anchor)                      // and put the page back where the eye was
            // Stamped when the work FINISHES, not when it was requested: what decides whether the
            // next press is "part of this burst" is whether a rebuild just ran, not how long ago the
            // reader last touched the key.
            self.lastFontRerenderEnded = Date()
            self.fontRerenderInFlight = false
        }
    }

    /// The 3-way fork every render/edit decision is made from. Decided by extension, not content
    /// (a `.txt` full of `#` and `*` is a text file whose author wanted those characters on the
    /// page, and guessing otherwise would rewrite what they see) — `untitledExtension` answers the
    /// question for a document that has no file yet.
    var kind: DocumentKind {
        DocumentTypes.kind(forExtension: fileURL?.pathExtension ?? untitledExtension ?? "md")
    }

    /// True for a file this app opens as TEXT rather than markdown or a rendered office document
    /// (.txt, .csv, .log, …). Kept as the boolean callers already use for wording ("line" vs
    /// "block") and the plain-text render fork — `kind` is the one place that actually decides.
    var isPlainText: Bool { kind == .plainText }

    /// What a NEW document is, before it has a file to be judged by. Nil for anything read from
    /// disk, where the path answers the question.
    private var untitledExtension: String?

    override var displayName: String! {
        get { fileURL == nil ? "Untitled.\(untitledExtension ?? "md")" : super.displayName }
        set { super.displayName = newValue }
    }

    /// A brand-new, unsaved document of the chosen kind.
    ///
    /// Markdown starts with a skeleton rather than a blank page: this app edits a block at a time,
    /// and a document with no blocks gives the reader nothing to click, edit, or move — the first
    /// thing they'd meet is the one dead end the app has. Three blocks is enough to show what a
    /// block IS. Plain text starts empty, because there a block is just a line and the first `i`
    /// makes one.
    func prepareUntitled(markdown: Bool) {
        untitledExtension = markdown ? "md" : "txt"
        fileType = markdown ? "net.daringfireball.markdown" : "public.plain-text"
        let skeleton = markdown ? "# Title\n\nWrite here.\n\n## Section\n" : ""
        self.text = skeleton
        self.file = TextFile(text: skeleton, encoding: .utf8, hasBOM: false)
        cachedHasCrossBlockReferences = nil
        // Dirty from the start: there IS content and it exists nowhere but memory, so closing must
        // ask rather than discard it silently.
        if !skeleton.isEmpty { updateChangeCount(.changeDone) }
    }

    /// The line ending this file uses, so an inserted line matches the ones around it. A file made
    /// on Windows stays CRLF — mixing the two inside one file is the kind of thing that shows up
    /// later as a stray character in someone else's tool.
    var lineEnding: String { text.contains("\r\n") ? "\r\n" : "\n" }

    /// Measures this document's running header/footer and wires BOTH halves of the page band — the
    /// reservation (`PageBandLayoutDelegate`) and the painting (`PageBandContent`) — for whatever the
    /// View menu's page options currently say.
    ///
    /// Called from two places that must never disagree: the render above, and
    /// `DocumentWindowController.reapplyPageBand()` when a toggle changes. Factored out for exactly
    /// that reason (invariant 29's single-dispatch discipline) — a toggle that re-derived the band
    /// with its own copy of this arithmetic would drift from the render's the first time either was
    /// touched.
    ///
    /// A hidden header or footer is passed through as NO ENTRIES rather than as a flag, which is what
    /// makes "hidden" mean the same thing to every consumer at once: it is not measured, so the band
    /// shrinks; it is not painted, because the painter has nothing to paint. `separatesPages` is the
    /// one thing the toggles add that entries alone cannot express — with the outline on, the space
    /// between two sheets exists even when nothing is drawn in it.
    ///
    /// `readingColumn` is only a FALLBACK: a paged document builds its band at the page's own body
    /// width (invariant 59d), which is a constant of the file and not of the window.
    /// `forPrinting` forces the PAGED shape on regardless of the View menu: paper HAS pages whether
    /// or not the reader is currently drawing them, so ⌘P and `--pdf` always lay the document out
    /// with its page separation, header and footer — the owner's rule, and the only way a printout
    /// can look like the document. It also drops `RenderTheme.pageDeskGap`, which is desk rather than
    /// paper: leaving it in makes the print grid advance 12pt further than the sheet is tall, so the
    /// strip between two sheets belongs to no page and anything in it is DROPPED FROM THE PRINTOUT.
    /// Measured on a real 147-page report: an overrun of more than the bottom margin (76.52pt here)
    /// fell into that strip and the line vanished, with the next line printing half-cut at the top of
    /// the following page — text that `pdftotext` still finds in the file because it was drawn, just
    /// onto no sheet.
    func applyPageBand(to wc: DocumentWindowController, theme: RenderTheme? = nil,
                       readingColumn: CGFloat? = nil, forPrinting: Bool = false) {
        // The render passes both, because it has already computed them and they must be the SAME
        // values the body was built with. A toggle passes neither and they are re-derived here from
        // the identical expressions — a paged document's theme is pinned to its own default body size
        // (invariant 57), so this is not a guess about what the render did.
        let theme = theme ?? RenderTheme.current(
            size: officePageContentWidth != nil ? officeDefaultBodyFontSize : readingSize)
        let readingColumn = readingColumn ?? wc.textView.textContainer?.size.width ?? 800
        let stored = PageViewOptionsStore.current
        let options = forPrinting ? PageViewOptions(outline: true, splitTables: stored.splitTables) : stored
        let headers = options.header ? officeHeaders : []
        let footers = options.footer ? officeFooters : []
        let bandColumn = officePageContentWidth ?? readingColumn
        let sides = officePageContentHeight != nil
            ? PageBandGeometry.measure(headers: headers, footers: footers,
                                       theme: theme, columnWidth: bandColumn,
                                       documentDefaultFontSize: officeDefaultBodyFontSize,
                                       pageContentWidth: officePageContentWidth,
                                       pageMarginTop: officePageMarginTop,
                                       pageMarginBottom: officePageMarginBottom,
                                       separatesPages: options.separatesPages,
                                       deskGap: forPrinting ? 0 : nil)
            : PageBandGeometry.Sides(header: 0, footer: 0, band: 0)
        wc.configurePageBand(pageContentHeight: officePageContentHeight, band: sides.band,
                             headers: headers, footers: footers, theme: theme,
                             columnWidth: bandColumn, documentDefaultFontSize: officeDefaultBodyFontSize,
                             pageContentWidth: officePageContentWidth,
                             headerHeight: sides.header, footerHeight: sides.footer,
                             separatesPages: options.separatesPages,
                             deskGap: forPrinting ? 0 : nil)
    }

    private func render(into wc: DocumentWindowController) {
        // THIS document is the single owner of the size it renders at — never a shared global.
        //
        // A PAGED document is built at the size it was AUTHORED at, not at the reader's. That makes
        // `fontSizeScale` (= theme.baseFontSize ÷ documentDefaultFontSize) come out as exactly 1
        // through the existing arithmetic, so every absolute point the document states — run sizes,
        // spacing, indents, tab stops — reaches the page verbatim and the line breaks are the
        // author's. Zoom then multiplies the whole page uniformly.
        //
        // Pinning `fontSizeScale` directly instead would be INCOHERENT and is the trap here: a span
        // that declares 10 pt would render at 10 pt while a span that declares nothing kept
        // `theme.bodyFont` at the reader's 16 pt — neighbouring paragraphs differing by 60% for no
        // reason the document gives, which is exactly what invariant 37 exists to prevent. Moving
        // the THEME keeps "declared nothing → theme token" resolving to the document's own default.
        let theme = RenderTheme.current(size: officePageContentWidth != nil ? officeDefaultBodyFontSize : readingSize)
        // Refresh the reading column NOW that `wc.document` is wired (`makeWindowControllers` runs
        // `addWindowController` BEFORE this `render`): the controller's own `init` already ran
        // `updateTextInset` once, but that was before `document` was set, so an office document's
        // `officePageContentWidth` was unreachable and the pass baked the wide window-filling
        // fallback. Re-run it here so the office `columnWidth` read below is the FINAL pinned+centred
        // page column, not the stale pre-document width — office image sizes are frozen at build time
        // and never re-derived (invariant 1/11), so they MUST be built against the real column.
        // ("pinned+centred" was aspirational prose left over from an abandoned attempt for a long
        // time; as of the paged-zoom change it describes what actually happens.)
        // Geometry ONLY (`settleReadingColumn`, not the full `updateTextInset`): the storage still
        // holds the outgoing document that the string built below is about to replace.
        wc.settleReadingColumn()
        let attr: NSAttributedString
        switch kind {
        case .plainText: attr = PlainTextRenderer.render(text, theme: theme)
        case .markdown: attr = MarkdownRenderer.render(text, theme: theme)
        // Rebuilt from blocks every render, not cached: ⌘R (and, for a document with no page width,
        // ⌘+/⌘−) must reflow office text exactly like markdown does — a finished string would
        // freeze the document at whatever size it was first opened at.
        //
        // TWO scales, and which of them varies depends on whether the document declared a page:
        //   • TEXT (with the absolute spacing/indent/tab stops that belong with it) rides `theme`,
        //     i.e. `theme.baseFontSize ÷ officeDefaultBodyFontSize` inside the builder (invariant 37).
        //     NO page width → that is `readingSize ÷ default`, so ⌘+/⌘− reflows like markdown.
        //     PAGED → the theme was built at the document's own default just above, so the ratio is
        //     1 and the text is laid out as authored; the reader's ⌘+ magnifies instead.
        //   • GRAPHICS (images, chart/SmartArt placeholders) ride `graphicScale` = the reading column
        //     ÷ the SOURCE page's body width. A picture was authored as a fraction of its page, so
        //     reproducing that fraction of the column keeps the document's own font↔image proportion.
        //     NO page width → scale 1, authored sizes verbatim. PAGED → the column IS the page body,
        //     so the ratio is again exactly 1 and a picture lands at its authored size, this time
        //     because the page is being reproduced rather than because nothing was known.
        // The two must not be FUSED — that was tried (fitting the page to the column by faking the
        // base font size) and it made ⌘+/⌘− dead on office documents and tied photograph size to a
        // text preference. Under the paged model they are not fused; they independently arrive at 1.
        // The column read here is real — `wc.settleReadingColumn()` above ran with `document` wired —
        // and it MUST be, because graphic sizes freeze at build time and are never re-derived
        // (invariant 1/11). Identical for docx/odt/HWP: one `OfficeBlock` vocabulary, one builder,
        // no per-format branch.
        case .office:
            let colW = wc.textView.textContainer?.size.width ?? 800
            // The width tables are ACTUALLY laid out at: the reading column minus the text
            // container's own padding on each side, which is exactly what
            // `DocumentWindowController.resizeTableColumns` re-solves them to. Handing it to the
            // builder makes the first paint the final one — otherwise every table is built at a
            // placeholder width and visibly resized a moment later (the "table shrinks then grows"
            // flicker), and the resize pass then has real work to do on every single render.
            let pad = wc.textView.textContainer?.lineFragmentPadding ?? 5
            // A handful of documents (1.4%) carry a table so large that BUILDING its grid is the
            // whole opening freeze — 2,351 of 3,329 ms on a 51,816-cell report. Those are left out
            // here and spliced in after the first paint (`spliceDeferredTables`). Empty for 99.3%
            // of tables and for every markdown/plain-text document, and an empty set builds exactly
            // the string this line built before (invariant 37).
            deferredTables = hasPaintedOnce ? [] : OfficeTextBuilder.giantTableIndices(officeBlocks)
            hasPaintedOnce = true
            attr = OfficeTextBuilder.build(officeBlocks, theme: theme,
                                           columnWidth: colW,
                                           documentDefaultFontSize: officeDefaultBodyFontSize,
                                           pageContentWidth: officePageContentWidth,
                                           tableWidth: max(1, colW - 2 * pad),
                                           lineGridPitch: officeLineGridPitch,
                                           comments: officeComments,
                                           deferringTables: deferredTables)
            // Running-header/footer page-boundary reservation AND painting (header-footer-design.md
            // §4/§5, build steps 4/5): wired here, before `wc.display(attr)` below replaces the
            // storage, so the layout manager's delegate reflects THIS render's own numbers before any
            // line of the new document is laid out. Measuring only when this document declared a page
            // HEIGHT at all skips the (harmless but pointless) header/footer build+layout pass on
            // every ⌘+/⌘R of the much more common non-paged office document — `configurePageBand`'s
            // own gate would make it inert anyway, this just avoids doing the measurement for nothing.
            // `PageBandGeometry.measure` (not the older `bandHeight` this replaced) measures the
            // header and footer heights ONCE and hands step 5's painter the SAME two numbers step 4's
            // reservation is built from, rather than measuring them a second time at draw time.
            applyPageBand(to: wc, theme: theme, readingColumn: colW)
        }
        wc.display(attr)
        wc.window?.title = displayName ?? "fast-md-reader"
        renderGeneration += 1
        DispatchQueue.main.async { [weak self, weak wc] in
            guard let self, let wc else { return }
            // Reserve EXACT area up front wherever the size is known cheaply — local images
            // (ImageIO header) and already-cached diagrams (cached PDF size). Then loading only
            // toggles the drawing (pixels), never the geometry, so the scroll bar stays stable.
            self.presizeKnownMedia(in: wc)
            // Lay out the WHOLE document up front (media are just placeholders, so it's cheap): the
            // scrollbar then reflects the full length immediately — the user sees how much content
            // there is without scrolling. Content itself streams in lazily via reconcileMedia.
            // The completion runs only if this walk finished on the string it started on, which is
            // the guarantee the splice below needs: it may not edit under a running walk, and a
            // superseded render must not splice at all.
            let generation = self.renderGeneration
            wc.precomputeLayout { [weak self, weak wc] in
                guard let self, let wc, self.renderGeneration == generation else { return }
                self.spliceDeferredTables(into: wc, generation: generation)
            }
            self.reconcileMedia(in: wc)   // load only what's on screen now
            // Then, in the background, render EVERY uncached diagram to the disk cache so its exact
            // size is known — the scrollbar becomes correct and never resizes again as you scroll
            // (the whole point: uncached docs behave like cached ones). Cached docs skip this.
            self.prerenderAllDiagrams(in: wc)
            // Same for remote images: fetch each header (a few KB, not the image) so its exact size
            // is known before it lands. Docs with no remote images skip this.
            self.measureRemoteImages(in: wc)
        }
    }

    /// Puts each giant table's grid back, one per run-loop turn, after the document has already
    /// painted without them. See `docs/giant-table-deferral-design.md` — the summary of why this
    /// exists and why it is shaped this way:
    ///
    ///  • The freeze it removes is `OfficeTextBuilder.build` + `display`, ONE uninterruptible turn
    ///    (invariant 49). On a 51,816-cell report that is 3,329 ms before anything is on screen;
    ///    without these five grids it is 664 ms. The work is not saved, it is MOVED — 418 ms of
    ///    deferred build plus 1,912 ms of payback here adds up to one full build, within 1%.
    ///  • **Nothing here forces layout, and `precomputeLayout` must never run again afterwards.**
    ///    That is the whole finding: forcing it costs a 211 ms freeze with two slices over 200 ms,
    ///    while leaving TextKit to lay these tables out on its own settles the full document in
    ///    ~7.5 s with a WORST slice of 45 ms and none over 50 — measured twice. Invariant 49 records
    ///    two failed attempts to make this freeze smaller by slicing the walk finer; the answer was
    ///    never a finer slice, it was not walking these tables at all.
    ///  • One table per turn, because building one is 25–862 ms of real main-thread work. Doing all
    ///    five in a turn would be a 1.9 s freeze — trading the freeze we removed for a later one.
    ///
    /// Media and the outline are refreshed once at the end (a splice moves every heading offset
    /// after it), mirroring what `spliceRender` already does for a markdown edit.
    private func spliceDeferredTables(into wc: DocumentWindowController, generation: Int) {
        guard !deferredTables.isEmpty, kind == .office, wc.textStorageRef != nil else { return }
        // The reader's position is recorded ONCE, before the first mutation, and carried forward:
        // every splice above it pushes their line down by its own delta, so restoring the anchor
        // unshifted would silently land them on different text. At open this is character 0 and
        // costs nothing; it matters on ⌘+, which re-renders wherever the reader happens to be.
        var anchor = wc.readingAnchor()

        func spliceNext() {
            guard renderGeneration == generation, let storage = wc.textStorageRef else { return }
            // Found by attribute, never by matching the stand-in's text: the glyph is presentation
            // and could change, the attribute is the contract (`MDAttr.deferredTable`).
            var found: (range: NSRange, index: Int)?
            storage.enumerateAttribute(MDAttr.deferredTable,
                                       in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let index = value as? Int else { return }
                found = (range, index)
                stop.pointee = true
            }
            guard let (standIn, blockIndex) = found, blockIndex < officeBlocks.count else {
                finish()
                return
            }
            let theme = RenderTheme.current(size: readingSize)
            let colW = wc.textView.textContainer?.size.width ?? 800
            let pad = wc.textView.textContainer?.lineFragmentPadding ?? 5
            // Built with `deferringTables` EMPTY, so this one table renders in full — same builder,
            // same widths as the surrounding document, so the first paint of the grid is its final
            // one and `resizeTableColumns` finds nothing to move (invariant 48b).
            let piece = NSMutableAttributedString(attributedString:
                OfficeTextBuilder.build([officeBlocks[blockIndex]], theme: theme,
                                        columnWidth: colW,
                                        documentDefaultFontSize: officeDefaultBodyFontSize,
                                        pageContentWidth: officePageContentWidth,
                                        tableWidth: max(1, colW - 2 * pad),
                                        lineGridPitch: officeLineGridPitch,
                                        comments: officeComments))
            // A one-block build numbers its block from zero. The stand-in already holds the id this
            // table had in the full document, so the grid inherits it — two neighbours sharing an id
            // would merge into one stop for the reading cursor (invariant 19's lesson).
            if let id = storage.attribute(MDAttr.blockId, at: standIn.location, effectiveRange: nil) {
                piece.addAttribute(MDAttr.blockId, value: id,
                                   range: NSRange(location: 0, length: piece.length))
            }
            let delta = piece.length - standIn.length
            storage.beginEditing()
            storage.replaceCharacters(in: standIn, with: piece)
            storage.endEditing()
            if standIn.location + standIn.length <= anchor.char {
                anchor = DocumentWindowController.ReadingAnchor(char: anchor.char + delta,
                                                                offsetFromTop: anchor.offsetFromTop)
            } else if standIn.location < anchor.char {
                // The reader was ON the stand-in itself; the grid that replaced it starts here.
                anchor = DocumentWindowController.ReadingAnchor(char: standIn.location,
                                                                offsetFromTop: anchor.offsetFromTop)
            }
            DispatchQueue.main.async { spliceNext() }
        }

        func finish() {
            guard renderGeneration == generation else { return }
            deferredTables = []
            // Every heading after a splice sits at a different character now, and the outline reads
            // those offsets to jump (invariant 23's rule: anything that changes the text ends here).
            wc.refreshAfterMutation()
            wc.reloadOutline()
            // The pass's own anchor, shifted past each splice above it — at first paint that is
            // character 0 unless the reader scrolled while the grids were arriving.
            let target = anchor
            presizeKnownMedia(in: wc)
            // THE DOCUMENT MUST STILL BE WALKED. Skipping this was the shipped bug (`f813bbf`,
            // reverted): leaving the giants unlaid is fine while the reader sits still — TextKit
            // settles them in ~11 s in slices it chooses — but the moment they SCROLL to one, the
            // arrival forces every unlaid character in between, in ONE call. Measured on the
            // 51,816-cell report: **69,460 and 80,008 ms**, twice, which is the "infinite loop" a
            // reader sees. With this walk the same scroll costs **3.2 and 5.1 ms**.
            //
            // The prototype rejected this walk on its worst slice (211 ms against 45 ms unwalked)
            // and never priced the scroll, which is the whole reason the comparison came out wrong.
            // Re-measured with arrival included, its slices (274–682 ms) are no worse than what the
            // SHIPPING build already produces walking the same document undeferred (1,367 ms), and
            // both are paid in the background after the reader already has the page.
            //
            // The anchor is restored FROM THE COMPLETION, not before the walk — invariant 24's rule,
            // and it bit here exactly as that invariant describes. `restore` clamps its scroll to
            // the text view's CURRENT height, and until the walk has run that height only covers
            // what happens to be laid out, so restoring first put a reader who was 75% down at
            // character 298 — the top of the document. Measured: 98,970 → 298 before this line moved.
            wc.precomputeLayout { [weak wc] in wc?.restore(target) }
            reconcileMedia(in: wc)
        }

        DispatchQueue.main.async { spliceNext() }
    }

    /// The up-front measure pass. On the FIRST open of a diagram-heavy document nothing is cached,
    /// so each diagram's real height is unknown and loading it on scroll would resize the layout
    /// under the reader (the scroll-bar jitter). Here we render every uncached diagram to the disk
    /// cache in the background (bounded concurrency for memory), and once they're ALL sized we
    /// reserve each exact area and lay the document out ONCE. After this, sizes never change, so
    /// scrolling only ever draws pixels — no reflow, no jitter. Second open onward: all cached, so
    /// there's nothing to render and presizeKnownMedia already reserved exact areas.
    func prerenderAllDiagrams(in wc: DocumentWindowController) {
        guard let storage = wc.textStorageRef else { return }
        var codes: [WebBlock] = []
        var seen = Set<WebBlock>()
        storage.enumerateWebBlocks { block, _ in
            guard seen.insert(block).inserted else { return }
            if WebBlockRenderer.cachedSize(block) == nil { codes.append(block) }
        }
        // With NSTextTable, a cell's content — including any diagram/formula/image attachment — lives
        // in the top-level storage as ordinary paragraphs, so the `enumerateWebBlocks` walk above
        // already reaches in-cell web blocks. No separate cell descent is needed.
        guard !codes.isEmpty else { return }   // all cached → already presized to exact areas
        isPrerendering = true
        prerenderToken += 1
        let token = prerenderToken
        let gen = renderGeneration
        Task { @MainActor in
            // A few blocks render at once (each on its OWN WebBlockRenderer so their web views
            // don't collide); a small cap keeps the transient WebKit memory modest.
            let cap = min(3, codes.count)
            var next = 0
            await withTaskGroup(of: Void.self) { group in
                func pump() {
                    guard next < codes.count else { return }
                    let block = codes[next]; next += 1
                    group.addTask { @MainActor in _ = await WebBlockRenderer().prerenderToCache(block) }
                }
                for _ in 0..<cap { pump() }
                while await group.next() != nil {
                    guard token == self.prerenderToken, gen == self.renderGeneration else { break }
                    pump()
                }
            }
            guard token == self.prerenderToken, gen == self.renderGeneration else { return }
            self.isPrerendering = false
            // Every diagram is cached now → reserve each EXACT area, lay the whole doc out once
            // (scroll bar becomes correct), keep the reader's position, then fill visible pixels.
            let anchor = wc.topVisibleCharIndex()
            self.presizeKnownMedia(in: wc)
            wc.precomputeLayout()
            wc.scrollCharToTop(anchor)
            self.reconcileMedia(in: wc)
        }
    }

    // MARK: - Images / diagrams (lazy: only on-screen media hold pixels)

    /// Decoded-image cache keyed by resolved absolute URL string (muya's loadImageMap).
    private static let imageCache = NSCache<NSString, NSImage>()

    /// Decoded-image cache for office documents, keyed by "path|archive entry id" (see the cache
    /// key comment in `reconcileMedia` for why the id alone is not enough). Separate from
    /// `imageCache`: an office id and a markdown src string share no format, so keeping them apart
    /// avoids having to prove they can never collide.
    private static let officeImageCache = NSCache<NSString, NSImage>()

    /// Decoded pixels outlive the document that needed them, and that is what a reader sees as the app
    /// never giving memory back. Both caches are keyed so nothing COLLIDES across documents (the
    /// office one carries the file path, see above) — but neither is scoped to a document's LIFETIME,
    /// so closing a 20 MB report leaves every image it decoded sitting here for a session that will
    /// never ask for them again. Measured 2026-07-31: open that report, close it, and the process
    /// still held 165 MB against 15 MB freshly launched, with `heap` reporting 1,374 live 160 KB
    /// blocks — decoded images — and `leaks` reporting only 14 KB, i.e. nothing was leaked and
    /// everything was still legitimately referenced from right here.
    ///
    /// Purged only when the LAST document closes, never per document: while anything is open these
    /// entries are what makes scrolling back to a picture instant, and `NSCache` already evicts them
    /// under real memory pressure. `NSCache` offers no way to enumerate or drop one document's keys,
    /// which is the other reason the boundary is "nothing open" rather than "this document closed".
    /// Test-visible, in the shape of `textInsetUpdateCount`: `NSCache` exposes no count, so what the
    /// purge DID can only be judged by measuring the process (above). WHEN it fires can be tested,
    /// and that is the half a future edit can break silently — moving the guard, or hooking a
    /// notification that fires before `NSDocumentController` has let go of the document.
    private(set) static var imageCachePurgeCount = 0

    static func purgeImageCaches() {
        imageCache.removeAllObjects()
        officeImageCache.removeAllObjects()
        imageCachePurgeCount += 1
    }

    /// How far a mermaid diagram is allowed to grow past its own natural size when reaching for the
    /// column width. A cap on the target WIDTH (e.g. "floor at half the column") either undershoots
    /// diagrams already close to the column, or — raised enough to fix that — blows a deliberately
    /// tiny two-node diagram up into oversized fonts. Capping the FACTOR instead lets a mid-size
    /// diagram (the common case) reach full column width while a genuinely tiny one stays close to
    /// its own natural size, because its small natural size is itself what limits how far the
    /// multiplier can take it. 2.5x chosen as a middle ground: generous enough to fix the common
    /// 50–100%-of-column band, not so generous that a 3-node graph balloons past legibility.
    static let mermaidEnlargeFactorCap: CGFloat = 2.5

    /// Pure grow-toward-column decision for a mermaid diagram narrower than the column (the shrink
    /// case — `naturalWidth >= colW` — is handled by the caller and never reaches here). No view/
    /// layout state involved, so it is identical whether the attachment's pixels are currently loaded
    /// or purged (invariant 1), and it re-derives the same answer on every call — safe to call fresh
    /// on every resize/reflow (invariant 24) without caching or re-rendering.
    static func mermaidTargetWidth(naturalWidth: CGFloat, colW: CGFloat) -> CGFloat {
        min(colW, naturalWidth * mermaidEnlargeFactorCap)
    }

    /// Column-fit a raw pixel size, honoring an explicit width (HTML/Pandoc/Obsidian) or shrinking
    /// oversized images to the column width. Internal (not private) so tests can drive it directly —
    /// see `MermaidSizingTests` — the same pattern this codebase already uses for pure, view-free
    /// math (`TextNavigator`, `BlockEdit`).
    func fittedSize(_ pixelSize: NSSize, _ storage: NSAttributedString, _ range: NSRange, maxWidth: CGFloat) -> NSSize {
        let colW = maxWidth - 8
        var size = pixelSize
        guard size.width > 0 else { return size }
        var targetW: CGFloat?
        if let pct = (storage.attribute(MDAttr.imageWidthPct, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue {
            targetW = colW * CGFloat(pct)
        } else if let pts = (storage.attribute(MDAttr.imageWidth, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue {
            targetW = min(CGFloat(pts), colW)
        } else if size.width > colW {
            targetW = colW
        } else if storage.attribute(MDAttr.mermaid, at: range.location, effectiveRange: nil) != nil,
                  size.width < colW {
            // A diagram's natural width is a mermaid layout artefact, not a size anyone chose:
            // mermaid's `useMaxWidth: true` only ever SHRINKS a diagram to fit a narrower container,
            // it never grows one to fill a wider one (docs/06-research/mermaid-sizing.md) — so every
            // diagram below the column width, not just those under half of it, needs a grow rule
            // here. It's vector art (WKPDFConfiguration/createPDF, see WebBlockRenderer), so
            // enlarging costs no sharpness.
            //
            // Diagrams ONLY. An image's size IS authored (a 16px icon must stay a 16px icon), and a
            // formula stretched to the column would look absurd.
            targetW = MarkdownDocument.mermaidTargetWidth(naturalWidth: size.width, colW: colW)
        }
        if let targetW {
            let s = targetW / size.width
            size = NSSize(width: targetW.rounded(), height: (size.height * s).rounded())
        }
        // Media grows and shrinks with the reader's text. A formula must: an `x` in a sentence and
        // the same `x` in the equation beside it have to stay the same size, or the maths shrinks
        // away as the prose grows. Pictures follow for a plainer reason — someone enlarging the text
        // is asking to see MORE, and a diagram that stayed put while the words around it doubled
        // would look like a mistake. All three are vector or downscaled, so nothing loses sharpness.
        let scale = readingSize / FontSizeStore.defaultSize
        if scale != 1 {
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        // The column is the hard limit whatever the zoom — text never scrolls sideways here, and
        // media that outgrew the page would be the one thing that did.
        if size.width > colW {
            let s = colW / size.width
            size = NSSize(width: colW, height: size.height * s)
        }
        return NSSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// Reserve the exact column-fitted area for media whose size is known WITHOUT rendering: local
    /// images (ImageIO header), already-cached diagrams (cached PDF size), and remote images whose
    /// header has already been fetched. Runs once after render, before the full layout, so those
    /// never resize on load. Uncached diagrams / unmeasured remote images keep their placeholder.
    private func presizeKnownMedia(in wc: DocumentWindowController) {
        guard let storage = wc.textStorageRef else { return }
        let maxWidth = wc.textView.textContainer?.size.width ?? 800
        let baseDir = fileURL?.deletingLastPathComponent()
        let whole = NSRange(location: 0, length: storage.length)
        var sets: [(NSSize, NSRange)] = []
        // An office image's `MDAttr.image` value is an archive entry id ("word/media/image1.png"),
        // not a URL/path — `resolveImageURL` would misread it as one relative to the document's
        // folder. Skip it: `OfficeTextBuilder` already reserved its exact (column-fitted) size at
        // build time, so there is nothing to presize here (invariant: office sizing happens once,
        // at build time — never re-derived from a path).
        if kind != .office {
            storage.enumerateAttribute(MDAttr.image, in: whole) { v, r, _ in
                guard let src = v as? String, !src.hasPrefix("data:"),
                      let url = self.resolveImageURL(src, baseDir: baseDir) else { return }
                if url.isFileURL {
                    guard let px = self.cachedLocalImagePixelSize(url) else { return }
                    sets.append((px, r))
                } else if let px = MarkdownDocument.remoteSizes[url.absoluteString] {
                    sets.append((px, r))
                }
            }
        }
        storage.enumerateWebBlocks(in: whole) { block, r in
            guard let sz = WebBlockRenderer.cachedSize(block) else { return }
            sets.append((sz, r))
        }
        for (px, r) in sets {
            guard r.location < storage.length,
                  let att = storage.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment,
                  let cell = att.attachmentCell as? SizedAttachmentCell else { continue }
            let fitted = fittedSize(px, storage, r, maxWidth: maxWidth)
            cell.reservedSize = fitted           // the cell owns layout size (survives image==nil)
            att.bounds = NSRect(origin: .zero, size: fitted)
            storage.edited(.editedAttributes, range: r, changeInLength: 0)
        }
        // Cell media now lives in top-level storage (each cell is real paragraphs in an NSTextTable),
        // so the enumerations above already sized every in-cell image/diagram/formula — no descent.
    }

    /// The core of the lazy scheme: on-screen images/diagrams hold their pixels; those far from the
    /// viewport drop them (bounds stay, so no reflow); reload from cache when they come back near.
    /// Text is left alone — it's tiny and non-contiguous layout already purges its off-screen glyphs.
    /// Called after render and on every scroll-settle. All work here is main-thread.
    ///
    /// `loadingEverything` is for PAPER, which has no viewport. The lazy scheme is right for reading
    /// and wrong for printing: measured on a 14.4 MB report carrying 28 pictures, printing it while
    /// only the top of the document had ever been on screen produced a 50-page PDF containing ONE
    /// image — every picture the reader had not scrolled past printed as blank reserved space, with
    /// nothing to say so. That is a silent loss in a file someone sends on, so both print paths ask
    /// for the whole document instead (`DocumentWindowController.makePrintOperation`). Nothing is
    /// purged in that mode either, since every range counts as on-screen.
    func reconcileMedia(in wc: DocumentWindowController, loadingEverything: Bool = false) {
        guard let storage = wc.textStorageRef else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let keep = loadingEverything ? whole : wc.visibleCharRange(margin: 1.5)   // else ±1.5 screens
        guard keep.length > 0 else { return }
        let baseDir = fileURL?.deletingLastPathComponent()
        let maxWidth = wc.textView.textContainer?.size.width ?? 800
        let gen = renderGeneration
        func onScreen(_ r: NSRange) -> Bool { NSIntersectionRange(r, keep).length > 0 }
        func attach(_ r: NSRange) -> NSTextAttachment? {
            storage.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment
        }
        // Load: set the image AND its real fitted bounds (placeholder → actual). Reload gives the
        // same size, so it's stable. Purge: drop the image, keep bounds (no reflow).
        func load(_ image: NSImage?, _ r: NSRange) {
            guard gen == self.renderGeneration, r.location < storage.length,
                  let att = attach(r), let cell = att.attachmentCell as? SizedAttachmentCell else { return }
            let img = image ?? MarkdownDocument.brokenImage()
            let newSize = self.fittedSize(img.size, storage, r, maxWidth: maxWidth)
            let sizeChanged = abs(cell.reservedSize.height - newSize.height) > 0.5 || abs(cell.reservedSize.width - newSize.width) > 0.5
            att.image = img
            if sizeChanged {
                // Reserved size was only a guess (uncached diagram / remote image) — correct it, which
                // DOES reflow. Rare after the up-front measure pass (which pre-sizes every diagram).
                cell.reservedSize = newSize
                att.bounds = NSRect(origin: .zero, size: newSize)
                storage.edited(.editedAttributes, range: r, changeInLength: 0)
                wc.textView.layoutManager?.ensureLayout(forCharacterRange:
                    NSRange(location: r.location, length: storage.length - r.location))
            } else {
                // Reserved size already exact → just paint the pixels. No layout touch → the frame
                // height and scroll bar do not move at all.
                wc.redrawGlyphs(r)
            }
            wc.refreshAfterImageFill()
        }
        func purgeAt(_ r: NSRange) {
            guard r.location < storage.length, let att = attach(r) else { return }
            att.image = nil                 // reserved size (cell) unchanged → space kept, no reflow
            wc.redrawGlyphs(r)              // repaint the now-empty reserved area
        }
        // Office counterpart of `load`: PAINT ONLY. `OfficeTextBuilder` already reserved the exact,
        // column-fitted area at build time from the DECLARED size — an office image's own pixel
        // dimensions are not authoritative (Word draws it at the declared size regardless), so
        // recomputing a fit from the loaded pixels here would be actively wrong, not just redundant.
        // Deliberately never touches `cell.reservedSize`/`att.bounds`/`storage.edited`/`ensureLayout`
        // — that is invariant 1 (scroll-bar stability), and it is why this is its own function
        // rather than a branch inside `load` that someone could accidentally "simplify" back together.
        //
        // When the pixels do NOT arrive, the honest report is a labelled card, and it is left as a
        // LABEL on the cell rather than an image on the attachment (`SizedAttachmentCell
        // .undrawableLabel`, which draws it at the live cell frame). Setting `att.image` here is the
        // tempting one-liner and is the defect this replaces: an attachment built by `appendImage`
        // carries `placeholderLabel == nil`, so `DocumentWindowController.resizeOfficeGraphics` never
        // re-draws it and every window resize scales whatever bitmap was put there — which is how a
        // 22×22 system glyph came to be stretched across a 700×465 frame and read as a corrupt file.
        // `bytes` are the ones the decode was attempted ON, carried in only to NAME the format in
        // that label; nothing here decides anything from them.
        func loadOfficePixels(_ image: NSImage?, _ bytes: Data?, _ r: NSRange) {
            guard gen == self.renderGeneration, r.location < storage.length, let att = attach(r) else { return }
            if let image {
                att.image = image
            } else if let cell = att.attachmentCell as? SizedAttachmentCell {
                cell.undrawableLabel = MarkdownDocument.undrawablePictureLabel(for: bytes)
            } else {
                // No cell to draw through (invariant 31 — one was set once, so pixels had already
                // loaded here at least once and AppKit dropped it). Rare, and the old mute glyph is
                // still better than blank space.
                att.image = MarkdownDocument.brokenImage()
            }
            wc.redrawGlyphs(r)
            wc.refreshAfterImageFill()
        }

        // Collect first (don't mutate storage while enumerating its attributes).
        var purge: [NSRange] = [], imgLoad: [(String, NSRange)] = [], mmLoad: [(WebBlock, NSRange)] = []
        var officeLoad: [(String, NSRange)] = []
        storage.enumerateAttribute(MDAttr.image, in: whole) { v, r, _ in
            guard let src = v as? String, !src.isEmpty, let att = attach(r) else { return }
            if onScreen(r) {
                // `att.image == nil` used to mean "not loaded yet" and nothing else, because a
                // failed load still assigned the broken-image icon and so closed this gate itself.
                // A picture whose format has no decoder now keeps `image == nil` FOREVER and draws
                // a labelled card from its cell instead (`SizedAttachmentCell.undrawableLabel`), so
                // without the second half of this test we would re-read, re-decode and re-fail that
                // picture on every reconcile — which is to say on every scroll — for as long as the
                // document stays open. The document that prompted this work carries eight of them.
                guard att.image == nil,
                      (att.attachmentCell as? SizedAttachmentCell)?.undrawableLabel == nil else { return }
                if kind == .office {
                    // A linked (not embedded) office image's id carries the file's real,
                    // real-world location — a `file:///…`/`http(s)://…` URL, exactly the shape
                    // an ordinary markdown image's `src` already is (`DocxReader.externalLinkId`).
                    // Routed into the SAME markdown pipeline below, rather than `officeLoad`'s
                    // archive-only path, so it reuses the folder-grant placeholder a blocked
                    // sibling markdown image already gets (`FolderAccess`/`needsAccessImage()`)
                    // instead of the generic broken-image icon `officeLoad` falls back to for a
                    // genuinely unresolvable id. Gap-list #8's requirement is exactly this: degrade
                    // VISIBLY, with the existing mechanism, not a second one invented for it.
                    if src.hasPrefix(MarkdownDocument.officeExternalLinkPrefix) {
                        imgLoad.append((String(src.dropFirst(MarkdownDocument.officeExternalLinkPrefix.count)), r))
                    } else {
                        officeLoad.append((src, r))
                    }
                    return
                }
                // Mid-measure, an unmeasured remote image has no exact size yet — filling it now
                // would resize under the reader. The measure pass fills it once it's sized.
                if self.isMeasuringRemote, !src.hasPrefix("data:"),
                   let u = self.resolveImageURL(src, baseDir: baseDir), !u.isFileURL,
                   MarkdownDocument.remoteSizes[u.absoluteString] == nil { return }
                imgLoad.append((src, r))
            }
            else if att.image != nil { purge.append(r) }
        }
        storage.enumerateWebBlocks(in: whole) { block, r in
            guard let att = attach(r) else { return }
            if onScreen(r) {
                guard att.image == nil else { return }
                // During the up-front pass an uncached block has no exact size yet — loading it
                // now would resize the layout under the reader. Wait for the pass to size it; a
                // cached one is already exact, so it's safe to fill.
                if self.isPrerendering && WebBlockRenderer.cachedSize(block) == nil { return }
                mmLoad.append((block, r))
            }
            else if att.image != nil { purge.append(r) }
        }

        for r in purge { purgeAt(r) }
        for (src, r) in imgLoad {
            if src.hasPrefix("data:") {
                load(MarkdownDocument.decodeDataURI(src), r)
            } else if let url = resolveImageURL(src, baseDir: baseDir) {
                if let c = MarkdownDocument.imageCache.object(forKey: url.absoluteString as NSString) {
                    load(c, r)
                } else if FolderAccess.needsGrant(for: url) {
                    // Sandboxed and unreadable: don't attempt the read (it just fails silently, and
                    // macOS won't prompt). Offer the grant instead — clicking the range runs it.
                    storage.addAttribute(MDAttr.needsFolderGrant, value: url.deletingLastPathComponent(), range: r)
                    load(MarkdownDocument.needsAccessImage(), r)
                } else {
                    MarkdownDocument.loadImage(url) { [weak wc] img in
                        if let img { MarkdownDocument.imageCache.setObject(img, forKey: url.absoluteString as NSString) }
                        if wc != nil { load(img, r) }
                    }
                }
            } else { load(nil, r) }
        }
        for (id, r) in officeLoad {
            // Pre-decoded bytes win over the archive: HWP has no archive and hands its embedded image
            // pixels in `officeImageBytes` at read time (the rhwp handle is gone by now). Branch on MAP
            // PRESENCE, not an `hwpimg:` string, so any future pre-decode reader generalizes. The bytes
            // are already in memory, so no NSCache round trip — decode straight to pixels (paint-only
            // via `loadOfficePixels`, invariant 1/2/11 preserved; a nil image degrades to the broken
            // icon there, same as the archive path).
            if let data = officeImageBytes[id] {
                loadOfficePixels(NSImage(data: data), data, r)
                continue
            }
            // Keyed by document path + archive entry id, NOT id alone: every `.docx` names its media
            // "word/media/image1.png", "image2.png", … — the SAME id means a DIFFERENT picture in a
            // different file, so an id-only key would serve one document's image inside another.
            let cacheKey = "\(fileURL?.path ?? "")|\(id)" as NSString
            if let c = MarkdownDocument.officeImageCache.object(forKey: cacheKey) {
                loadOfficePixels(c, nil, r)
            } else if loadingEverything {
                // Printing cannot wait for a callback: the print operation is built and run on this
                // same turn, so an asynchronous decode lands after the PDF has already been written.
                // Measured before this branch existed — a 28-picture report printed with ONE image in
                // it, the single one the opening viewport had already cached. Reading the archive
                // entry and decoding it here costs the same work on this thread instead of another.
                let (img, bytes) = MarkdownDocument.loadOfficeImageSync(archive: officeArchive, id: id)
                if let img { MarkdownDocument.officeImageCache.setObject(img, forKey: cacheKey) }
                loadOfficePixels(img, bytes, r)
            } else {
                MarkdownDocument.loadOfficeImage(archive: officeArchive, id: id) { [weak wc] img, bytes in
                    if let img { MarkdownDocument.officeImageCache.setObject(img, forKey: cacheKey) }
                    if wc != nil { loadOfficePixels(img, bytes, r) }
                }
            }
        }
        if !mmLoad.isEmpty {
            let renderer = WebBlockRenderer()   // cache-first: reloads hit the disk cache, no WebKit
            Task { @MainActor in
                for (block, r) in mmLoad {
                    guard let img = await renderer.renderImage(block) else { continue }
                    load(img, r)
                }
            }
        }
        // A cell's content now lives in top-level storage (NSTextTable), so its images/diagrams are
        // reached by the same `MDAttr.image`/`enumerateWebBlocks` loops above — no cell descent.
    }

    private func resolveImageURL(_ src: String, baseDir: URL?) -> URL? {
        if let u = URL(string: src), let scheme = u.scheme, !scheme.isEmpty { return u }   // http(s)/file
        if src.hasPrefix("~") { return URL(fileURLWithPath: (src as NSString).expandingTildeInPath) }
        if src.hasPrefix("/") { return URL(fileURLWithPath: src) }
        if let baseDir { return baseDir.appendingPathComponent(src).standardizedFileURL }   // relative to the doc
        return nil
    }

    /// Measured sizes of remote images, keyed by absolute URL. Process-wide: the same URL keeps its
    /// size across reloads and documents, so it's measured once.
    static var remoteSizes: [String: NSSize] = [:]

    /// Pixel dimensions of a REMOTE image without downloading it: ask for the first 64 KB only, which
    /// carries the header of every format we care about, and let ImageIO read the dimensions out of
    /// that. Falls back to a full GET if the server ignores Range (some CDNs do).
    private static func remoteImageSize(_ url: URL) async -> NSSize? {
        func size(of data: Data) -> NSSize? {
            let src = CGImageSourceCreateIncremental(nil)
            CGImageSourceUpdateData(src, data as CFData, false)   // false: more bytes may follow
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Double,
                  let h = p[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
            return NSSize(width: w, height: h)
        }
        var head = URLRequest(url: url)
        head.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        if let (data, _) = try? await URLSession.shared.data(for: head), let s = size(of: data) { return s }
        if let (data, _) = try? await URLSession.shared.data(from: url) { return size(of: data) }
        return nil
    }

    /// The remote counterpart of prerenderAllDiagrams: measure every not-yet-known remote image, then
    /// reserve exact areas and lay out ONCE. Without this each image would resize the document as it
    /// arrived — the reflow this whole design exists to avoid. Only headers are fetched, so it costs
    /// a few KB per image, not the image.
    func measureRemoteImages(in wc: DocumentWindowController) {
        // An office document's `MDAttr.image` ids are either an archive entry path (skipped
        // naturally below since it resolves to a local file URL) or, for a linked image, a
        // `docx-external-link:`-prefixed id — `URL(string:)` would misread that leading segment
        // as a URL SCHEME and treat the whole thing as a plausible remote URL, wastefully firing
        // a network request against a scheme nothing serves. Office sizing is decided once, at
        // build time (see `presizeKnownMedia`'s identical office skip) — there is nothing for this
        // remote-measurement pass to usefully do for `.office` documents at all.
        guard kind != .office else { return }
        guard let storage = wc.textStorageRef else { return }
        let baseDir = fileURL?.deletingLastPathComponent()
        var urls: [URL] = []
        var seen = Set<String>()
        func collectRemote(_ s: NSAttributedString) {
            s.enumerateAttribute(MDAttr.image, in: NSRange(location: 0, length: s.length)) { v, _, _ in
                guard let src = v as? String, !src.hasPrefix("data:"),
                      let url = self.resolveImageURL(src, baseDir: baseDir), !url.isFileURL,
                      MarkdownDocument.remoteSizes[url.absoluteString] == nil,
                      seen.insert(url.absoluteString).inserted else { return }
                urls.append(url)
            }
        }
        collectRemote(storage)   // in-cell images are top-level paragraphs now (NSTextTable) → reached here
        guard !urls.isEmpty else { return }   // all measured (or none) → presize already exact
        isMeasuringRemote = true
        measureToken += 1
        let token = measureToken
        let gen = renderGeneration
        Task { @MainActor in
            await withTaskGroup(of: (String, NSSize?).self) { group in
                for url in urls {
                    group.addTask { (url.absoluteString, await MarkdownDocument.remoteImageSize(url)) }
                }
                for await (key, size) in group {
                    if let size { MarkdownDocument.remoteSizes[key] = size }
                }
            }
            guard token == self.measureToken, gen == self.renderGeneration else { return }
            self.isMeasuringRemote = false
            let anchor = wc.topVisibleCharIndex()
            self.presizeKnownMedia(in: wc)
            wc.precomputeLayout()
            wc.scrollCharToTop(anchor)
            self.reconcileMedia(in: wc)
        }
    }

    /// Pixel dimensions of an image WITHOUT decoding it (ImageIO reads only the header) — fast and
    /// cheap, so a local image's exact height can be reserved before its pixels load. Measured at
    /// 0.117 ms/image, which sounds free until you count the callers: `presizeKnownMedia` asks for
    /// EVERY local image in the WHOLE document, and it runs from four async tails — `render(into:)`'s
    /// (every ⌘+ press), `spliceRender`'s (every edit), `prerenderAllDiagrams` and
    /// `measureRemoteImages`. 120 images = 14 ms, 406 = ~48 ms, paid again on each of those passes
    /// for a number that cannot have changed between them. `cachedLocalImagePixelSize` is the
    /// memoised entry point every call site uses instead of calling this directly.
    private static func imagePixelSize(_ url: URL) -> NSSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        return NSSize(width: w, height: h)
    }

    /// Memoised per document instance — see `imagePixelSize` for why. Reset on ⌘R
    /// (`reloadDocument`), which re-reads the file from disk: an image beside it can have changed
    /// size since the last read, so a reload must forget what it thought it knew — the same
    /// discipline `cachedHasCrossBlockReferences` follows.
    private var localImageSizeCache: [URL: NSSize] = [:]

    /// Test-visible count of real header reads (cache MISSES only) — the deterministic knob this
    /// cache is judged by, since wall clock on this machine swings far too much to prove anything:
    /// the document's local-image count on the first pass, and 0 more on every pass after. See
    /// `ImageHeaderCacheTests`.
    private(set) var imageHeaderReadCount = 0

    /// Only SUCCESSFUL reads are cached. A failure (the file is missing, unreadable, or not on disk
    /// yet) is deliberately left unmemoised so a later pass can still find the image if it becomes
    /// readable — pinning a transient failure for the rest of the session would be worse than
    /// re-reading a header that is cheap anyway.
    private func cachedLocalImagePixelSize(_ url: URL) -> NSSize? {
        if let cached = localImageSizeCache[url] { return cached }
        imageHeaderReadCount += 1
        guard let px = Self.imagePixelSize(url) else { return nil }
        localImageSizeCache[url] = px
        return px
    }

    private static func loadImage(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOf: url)
                DispatchQueue.main.async { completion(img) }
            }
        } else {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let img = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { completion(img) }
            }.resume()
        }
    }

    /// Pulls an office image's bytes out of the archive and decodes them, off the main thread:
    /// `ZipArchive.data(for:)` inflates DEFLATE (real work for a large picture) and `NSImage(data:)`
    /// decodes it, neither of which belongs on the thread the reader is drawing on. An
    /// unresolvable id (the sandbox has no path to reach — an external `r:link`, a dangling
    /// relationship) or a missing archive/entry degrades to `nil` (→ the broken-image placeholder in
    /// `loadOfficePixels`) rather than crashing or attempting a filesystem read that would only fail
    /// silently.
    /// `DocxReader.externalLinkId`'s prefix — kept here as the ONE place `reconcileMedia` and this
    /// function both check it, rather than the literal string repeated at each call site.
    static let officeExternalLinkPrefix = "docx-external-link:"

    /// Hands back the BYTES alongside the image: when the decode fails they are the only evidence
    /// of what the picture actually was, and naming that format is the difference between a reader
    /// concluding "this document is corrupt" and "this is a chart in a format my Mac can't draw".
    /// The same read and decode as `loadOfficeImage`, on the CALLING thread. Exists only for printing,
    /// which has no later turn to receive a callback in (see `reconcileMedia(in:loadingEverything:)`);
    /// the guard clause is deliberately identical, so the two cannot disagree about which ids resolve.
    private static func loadOfficeImageSync(archive: ZipArchive?, id: String) -> (NSImage?, Data?) {
        guard let archive, !id.hasPrefix("docx-unresolvable:"), !id.hasPrefix(officeExternalLinkPrefix) else {
            return (nil, nil)
        }
        let bytes = try? archive.data(for: id)
        return (bytes.flatMap { NSImage(data: $0) }, bytes)
    }

    private static func loadOfficeImage(archive: ZipArchive?, id: String,
                                        completion: @escaping (NSImage?, Data?) -> Void) {
        // A linked image never reaches this function — `reconcileMedia` routes
        // `officeExternalLinkPrefix` ids into the ordinary markdown image pipeline instead (see
        // there) — so an id arriving here that still starts with it would be a caller bug; treated
        // the same as any other unresolvable id (degrade to `nil`, never crash) rather than
        // asserting, since a rendering path is the wrong place to enforce that invariant.
        guard let archive, !id.hasPrefix("docx-unresolvable:"), !id.hasPrefix(officeExternalLinkPrefix) else {
            completion(nil, nil); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let bytes = try? archive.data(for: id)
            let img = bytes.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { completion(img, bytes) }
        }
    }

    private static func decodeDataURI(_ src: String) -> NSImage? {
        guard let comma = src.firstIndex(of: ","),
              let data = Data(base64Encoded: String(src[src.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    /// Placeholder for an image the sandbox blocks: it says what to do, because a plain broken icon
    /// would read as "this app can't show images" when one click fixes it. Click → folder grant.
    static func needsAccessImage() -> NSImage {
        let text = "Click to allow images in this folder" as NSString
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let pad: CGFloat = 10, iconW: CGFloat = 18
        let textSize = text.size(withAttributes: attrs)
        let size = NSSize(width: (textSize.width + iconW + pad * 3).rounded(), height: 34)
        let img = NSImage(size: size)
        img.lockFocus()
        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                              xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.setFill(); bg.fill()
        NSColor.tertiaryLabelColor.setStroke(); bg.stroke()
        if let icon = NSImage(systemSymbolName: "lock", accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: pad, y: (size.height - 14) / 2, width: 12, height: 14))
        }
        text.draw(at: NSPoint(x: pad + iconW, y: (size.height - textSize.height) / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    /// What to write on the card when an office picture could not be turned into pixels.
    ///
    /// **The decision is never made here.** Whether a picture can be drawn is settled by ACTUALLY
    /// ATTEMPTING the decode (`NSImage(data:)`, i.e. asking ImageIO's registry of installed
    /// decoders) and only reaching this function when that attempt came back nil. These magic
    /// bytes exist to put a NAME on that failure, nothing else — a wrong guess here costs one
    /// wrong word on a card, never a picture that would have drawn. The practical consequence is
    /// the one worth stating: **the day macOS ships a WMF decoder, `NSImage(data:)` starts
    /// succeeding and the chart simply appears** — there is no allow-list to notice it, and this
    /// list may then name a format nothing ever hands it, which is harmless.
    ///
    /// Measured on the rhwp sample corpus (340 HWP files, 1,825 embedded pictures through the real
    /// reader): 95 undecodable, all of them WMF (93) or PCX (2); BMP, PNG, JPEG, GIF and TIFF all
    /// decode natively. EMF, SVG and an OLE container are named because they are the neighbouring
    /// shapes the same authoring tools produce, not because they were seen failing.
    static func undrawablePictureLabel(for bytes: Data?) -> String {
        guard let bytes, !bytes.isEmpty else { return "Image missing" }
        guard let name = pictureFormatName(bytes) else { return "Image — no decoder" }
        return "\(name) image — no decoder"
    }

    /// The format a picture's leading bytes claim to be, or `nil` when they claim nothing this
    /// reader recognises. Naming only — see `undrawablePictureLabel`.
    static func pictureFormatName(_ bytes: Data) -> String? {
        func starts(_ magic: [UInt8]) -> Bool {
            guard bytes.count >= magic.count else { return false }
            for (i, b) in magic.enumerated() where bytes[bytes.startIndex + i] != b { return false }
            return true
        }
        // Windows Metafile in both shapes Office writes: the "placeable" header Word prefers, and
        // the bare METAFILEPICT one (a chart pasted as a picture, the whole of this corpus's gap).
        if starts([0xD7, 0xCD, 0xC6, 0x9A]) || starts([0x01, 0x00, 0x09, 0x00]) { return "WMF" }
        // Enhanced Metafile: EMR_HEADER, confirmed by the " EMF" signature at offset 40 — that
        // second check matters because the record type alone is four very common bytes.
        if starts([0x01, 0x00, 0x00, 0x00]), bytes.count >= 44 {
            let sig = bytes.subdata(in: bytes.index(bytes.startIndex, offsetBy: 40)
                                       ..< bytes.index(bytes.startIndex, offsetBy: 44))
            if sig == Data([0x20, 0x45, 0x4D, 0x46]) { return "EMF" }
        }
        // PCX: manufacturer 0x0A, then a version in 0…5 and an encoding of 0 or 1.
        if starts([0x0A]), bytes.count >= 3 {
            let version = bytes[bytes.index(bytes.startIndex, offsetBy: 1)]
            let encoding = bytes[bytes.index(bytes.startIndex, offsetBy: 2)]
            if version <= 5, encoding <= 1 { return "PCX" }
        }
        if starts(Array("<svg".utf8)) || starts(Array("<?xml".utf8)) { return "SVG" }
        // A compound-file container: an OLE object stored where a picture was expected.
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return "Embedded object" }
        return nil
    }

    /// A broken/missing-image placeholder so a failed load isn't just blank space.
    private static func brokenImage() -> NSImage {
        let img = NSImage(systemSymbolName: "photo", accessibilityDescription: "missing image")
            ?? NSImage(size: NSSize(width: 22, height: 22))
        img.size = NSSize(width: 22, height: 22)
        return img
    }

    /// Swap each mermaid placeholder for a rendered PDF image. Runs async so text opens
    /// instantly with placeholders and diagrams stream in. A no-mermaid document does no
    /// work here and never touches WebKit.
}
