import AppKit
import ImageIO

final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

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

    /// The SOURCE document's own default body run size, in points — see
    /// `OfficeTextBuilder.build`'s `documentDefaultFontSize` doc for the font-size model this
    /// feeds. Set from `DocumentTypes.officeDefaultBodyFontSize`, both on first `read(from:)` and on
    /// `reloadDocument` (see `ReloadOutcome.office`), so the two behave identically. `11` (the
    /// fallback both readers themselves return) when the document declares no default of its own.
    private(set) var officeDefaultBodyFontSize: CGFloat = 11

    /// The SOURCE document's own page BODY width in points (paper − margins), or nil when the reader
    /// could not determine it — see `OfficeReadResult.pageContentWidth`. Set alongside `officeBlocks`
    /// on every read/reload. `render(into:)` divides the reading column by it to get the GRAPHIC scale
    /// it hands `OfficeTextBuilder.build` (`graphicScale`), so an image occupies the same share of the
    /// column that it occupied of the source page. It does NOT change the column itself — the column
    /// always fills the window (pinning it to the page width was tried and rejected, see
    /// `DocumentWindowController.updateTextInset`). nil for every non-office kind, and nil here means
    /// graphics keep their authored point size exactly as before this existed.
    private(set) var officePageContentWidth: CGFloat?

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
                pageContentWidth: result.pageContentWidth)
            return
        }
        let archive = try ZipArchive(data: data)
        let result = try DocumentTypes.readOffice(archive, extension: ext)
        setOfficeContent(
            blocks: result.blocks, comments: result.comments, archive: archive,
            images: result.images,
            defaultBodyFontSize: DocumentTypes.officeDefaultBodyFontSize(archive, extension: ext),
            pageContentWidth: result.pageContentWidth)
    }

    /// The office-document seam `read(from:)` and `reloadDocument` both go through: the parser's
    /// output plus the archive it came from, which `reconcileMedia` needs to resolve an `.image`
    /// block's id to bytes. Not `private` — `OfficeDocumentTests` drives image loading against
    /// synthetic blocks/archives it builds itself, independent of whatever `DocxReader` parses (that
    /// parser's own correctness is `DocxReaderTests`' job, not this file's).
    func setOfficeContent(
        blocks: [OfficeBlock], comments: [OfficeComment] = [], archive: ZipArchive?,
        images: [String: Data] = [:], defaultBodyFontSize: CGFloat = 11,
        pageContentWidth: CGFloat? = nil
    ) {
        self.officeBlocks = blocks
        self.officeComments = comments
        self.officeArchive = archive
        self.officeImageBytes = images
        self.officeDefaultBodyFontSize = defaultBodyFontSize
        self.officePageContentWidth = pageContentWidth
        self.text = ""
        self.file = TextFile(text: "", encoding: .utf8, hasBOM: false)
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
        case office(blocks: [OfficeBlock], comments: [OfficeComment], archive: ZipArchive?, images: [String: Data], defaultBodyFontSize: CGFloat, pageContentWidth: CGFloat?)
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
                    pageContentWidth: result.pageContentWidth)
            }
            let archive = try ZipArchive(data: data)
            let result = try DocumentTypes.readOffice(archive, extension: ext)
            let defaultBodyFontSize = DocumentTypes.officeDefaultBodyFontSize(archive, extension: ext)
            return .office(
                blocks: result.blocks, comments: result.comments, archive: archive,
                images: result.images, defaultBodyFontSize: defaultBodyFontSize,
                pageContentWidth: result.pageContentWidth)
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
            case .office(let blocks, let comments, let archive, let images, let defaultBodyFontSize, let pageContentWidth):
                // Re-parse the archive, same as the initial read — never through the text-decode
                // path (invariant: an office document's bytes are never handed to
                // `TextEncodingDetector`). `defaultBodyFontSize` is carried through too, so a
                // reload renders identically to the first open of the same file (see invariant 29's
                // "reload must behave the same as first open" lesson).
                setOfficeContent(blocks: blocks, comments: comments, archive: archive, images: images, defaultBodyFontSize: defaultBodyFontSize, pageContentWidth: pageContentWidth)
            case .text(let reread):
                // The undo stack holds source OFFSETS into the text we're replacing. Re-reading the
                // file can move every one of them (the file may have changed behind us), so an undo
                // applied afterwards would overwrite the wrong span. Drop the history rather than
                // corrupt the file. Compared as TEXT, not bytes: re-encoding is not a change the
                // user made.
                if reread.text != self.text { undoManager?.removeAllActions() }
                self.file = reread
                self.text = reread.text
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
        let updated = ns.replacingCharacters(in: r, with: replacement)
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
        if spliceRender(into: wc, editedSource: r, replacementLength: newSpan.length) {
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
    /// against a definition elsewhere in the file, so such documents take the full path.
    ///
    /// Returns false when it cannot do the job, and the caller re-renders everything. Refusing is
    /// always correct here; guessing is not.
    private func spliceRender(into wc: DocumentWindowController, editedSource r: NSRange,
                              replacementLength: Int) -> Bool {
        guard let storage = wc.textStorageRef, storage.length > 0 else { return false }
        // An office document has no source text to splice a substring out of — `text` is "" for
        // these (see `read(from:ofType:)`) — and it never reaches here anyway, since every path
        // that calls `applySourceEdit` is gated shut for `.office`. Refuse rather than assume.
        guard kind != .office else { return false }
        if kind == .markdown && hasCrossBlockReferences { return false }

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

        let theme = RenderTheme.current(size: FontSizeStore.size)
        let fragmentSource = ns.substring(with: NSRange(location: oldStart, length: newLength))
        let fragment = NSMutableAttributedString(attributedString:
            kind == .plainText ? PlainTextRenderer.render(fragmentSource, theme: theme)
                               : MarkdownRenderer.render(fragmentSource, theme: theme))
        // A fragment is rendered from position zero, so its source offsets and block ids are local.
        // Lift both into the document's coordinates before it goes in.
        rebase(fragment, sourceOffset: oldStart, idBase: blockIdBase)
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

    private func rebase(_ fragment: NSMutableAttributedString, sourceOffset: Int, idBase: Int) {
        let whole = NSRange(location: 0, length: fragment.length)
        fragment.enumerateAttribute(MDAttr.srcRange, in: whole) { value, range, _ in
            guard let s = (value as? NSValue)?.rangeValue else { return }
            fragment.addAttribute(MDAttr.srcRange,
                                  value: NSValue(range: NSRange(location: s.location + sourceOffset, length: s.length)),
                                  range: range)
        }
        fragment.enumerateAttribute(MDAttr.blockId, in: whole) { value, range, _ in
            guard let id = value as? Int else { return }
            fragment.addAttribute(MDAttr.blockId, value: idBase + id, range: range)
        }
    }

    /// True when the document has link/footnote definitions, which a single block can refer to from
    /// anywhere — the one case where a block does NOT render the same on its own.
    private var hasCrossBlockReferences: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.contains("]:")
        }
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

    @objc func increaseReaderFontSize(_ sender: Any?) { FontSizeStore.increase(); reRenderPreservingCaret() }
    @objc func decreaseReaderFontSize(_ sender: Any?) { FontSizeStore.decrease(); reRenderPreservingCaret() }
    @objc func resetReaderFontSize(_ sender: Any?) { FontSizeStore.reset(); reRenderPreservingCaret() }

    /// A queued font-size rebuild, kept so a burst of presses collapses into one (see below).
    private var pendingFontRerender: DispatchWorkItem?

    /// ⌘+/⌘− rebuilds and re-lays out the WHOLE document — measured end to end at 0.36 s on a
    /// 38-table Word report and 0.8 s on a 62-table HWP. Pressing the key three times quickly used
    /// to cost three of those, one after another, and the reader sat through all three even though
    /// only the LAST size is ever seen. So the rebuild is debounced: each press cancels the queued
    /// one and re-queues, and because `FontSizeStore` was already updated synchronously, the single
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
        // Dirty from the start: there IS content and it exists nowhere but memory, so closing must
        // ask rather than discard it silently.
        if !skeleton.isEmpty { updateChangeCount(.changeDone) }
    }

    /// The line ending this file uses, so an inserted line matches the ones around it. A file made
    /// on Windows stays CRLF — mixing the two inside one file is the kind of thing that shows up
    /// later as a stray character in someone else's tool.
    var lineEnding: String { text.contains("\r\n") ? "\r\n" : "\n" }

    private func render(into wc: DocumentWindowController) {
        // FontSizeStore is the SINGLE owner of font size — never read UserDefaults directly.
        let theme = RenderTheme.current(size: FontSizeStore.size)
        // Refresh the reading column NOW that `wc.document` is wired (`makeWindowControllers` runs
        // `addWindowController` BEFORE this `render`): the controller's own `init` already ran
        // `updateTextInset` once, but that was before `document` was set, so an office document's
        // `officePageContentWidth` was unreachable and the pass baked the wide window-filling
        // fallback. Re-run it here so the office `columnWidth` read below is the FINAL pinned+centred
        // page column, not the stale pre-document width — office image sizes are frozen at build time
        // and never re-derived (invariant 1/11), so they MUST be built against the real column.
        // Geometry ONLY (`settleReadingColumn`, not the full `updateTextInset`): the storage still
        // holds the outgoing document that the string built below is about to replace.
        wc.settleReadingColumn()
        let attr: NSAttributedString
        switch kind {
        case .plainText: attr = PlainTextRenderer.render(text, theme: theme)
        case .markdown: attr = MarkdownRenderer.render(text, theme: theme)
        // Rebuilt from blocks every render, not cached: a font-size change (⌘+/⌘−) or ⌘R must
        // reflow office text exactly like markdown does — a finished string would freeze the
        // document at whatever size it was first opened at.
        // TWO independent scales, and keeping them independent is the whole point:
        //   • TEXT (and the absolute spacing/indent/tab stops that belong with it) rides the reader's
        //     own size — `theme` above, i.e. `FontSizeStore.size ÷ officeDefaultBodyFontSize` inside
        //     the builder (invariant 37). So ⌘+/⌘− works on an office document exactly as it does on
        //     markdown, which is the entire point of that setting.
        //   • GRAPHICS (images, chart/SmartArt placeholders) ride `graphicScale` = the reading column
        //     ÷ the SOURCE page's body width. A picture was authored as a fraction of its page, so
        //     reproducing that fraction of the column keeps the document's own font↔image proportion
        //     and makes pictures grow/shrink with the WINDOW — never with the font setting.
        // Both were briefly fused (the page fitted to the column by faking the base font size); that
        // made ⌘+/⌘− dead on office documents and tied photograph size to a text preference.
        // The column read here is real — `wc.settleReadingColumn()` above ran with `document` wired —
        // and it MUST be, because graphic sizes freeze at build time and are never re-derived
        // (invariant 1/11). A document whose reader could not determine a page width gets scale 1,
        // i.e. authored sizes verbatim, the pre-existing behaviour. Identical for docx/odt/HWP: one
        // `OfficeBlock` vocabulary, one builder, no per-format branch.
        case .office:
            let colW = wc.textView.textContainer?.size.width ?? 800
            // The width tables are ACTUALLY laid out at: the reading column minus the text
            // container's own padding on each side, which is exactly what
            // `DocumentWindowController.resizeTableColumns` re-solves them to. Handing it to the
            // builder makes the first paint the final one — otherwise every table is built at a
            // placeholder width and visibly resized a moment later (the "table shrinks then grows"
            // flicker), and the resize pass then has real work to do on every single render.
            let pad = wc.textView.textContainer?.lineFragmentPadding ?? 5
            attr = OfficeTextBuilder.build(officeBlocks, theme: theme,
                                           columnWidth: colW,
                                           documentDefaultFontSize: officeDefaultBodyFontSize,
                                           pageContentWidth: officePageContentWidth,
                                           tableWidth: max(1, colW - 2 * pad),
                                           comments: officeComments)
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
            wc.precomputeLayout()
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
        let scale = FontSizeStore.size / FontSizeStore.defaultSize
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
                    guard let px = MarkdownDocument.imagePixelSize(url) else { return }
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
    func reconcileMedia(in wc: DocumentWindowController) {
        guard let storage = wc.textStorageRef else { return }
        let keep = wc.visibleCharRange(margin: 1.5)   // ±1.5 screens stay loaded
        guard keep.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
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
        func loadOfficePixels(_ image: NSImage?, _ r: NSRange) {
            guard gen == self.renderGeneration, r.location < storage.length, let att = attach(r) else { return }
            att.image = image ?? MarkdownDocument.brokenImage()
            wc.redrawGlyphs(r)
            wc.refreshAfterImageFill()
        }

        // Collect first (don't mutate storage while enumerating its attributes).
        var purge: [NSRange] = [], imgLoad: [(String, NSRange)] = [], mmLoad: [(WebBlock, NSRange)] = []
        var officeLoad: [(String, NSRange)] = []
        storage.enumerateAttribute(MDAttr.image, in: whole) { v, r, _ in
            guard let src = v as? String, !src.isEmpty, let att = attach(r) else { return }
            if onScreen(r) {
                guard att.image == nil else { return }
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
                loadOfficePixels(NSImage(data: data), r)
                continue
            }
            // Keyed by document path + archive entry id, NOT id alone: every `.docx` names its media
            // "word/media/image1.png", "image2.png", … — the SAME id means a DIFFERENT picture in a
            // different file, so an id-only key would serve one document's image inside another.
            let cacheKey = "\(fileURL?.path ?? "")|\(id)" as NSString
            if let c = MarkdownDocument.officeImageCache.object(forKey: cacheKey) {
                loadOfficePixels(c, r)
            } else {
                MarkdownDocument.loadOfficeImage(archive: officeArchive, id: id) { [weak wc] img in
                    if let img { MarkdownDocument.officeImageCache.setObject(img, forKey: cacheKey) }
                    if wc != nil { loadOfficePixels(img, r) }
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
    /// cheap, so a local image's exact height can be reserved before its pixels load.
    private static func imagePixelSize(_ url: URL) -> NSSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        return NSSize(width: w, height: h)
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

    private static func loadOfficeImage(archive: ZipArchive?, id: String, completion: @escaping (NSImage?) -> Void) {
        // A linked image never reaches this function — `reconcileMedia` routes
        // `officeExternalLinkPrefix` ids into the ordinary markdown image pipeline instead (see
        // there) — so an id arriving here that still starts with it would be a caller bug; treated
        // the same as any other unresolvable id (degrade to `nil`, never crash) rather than
        // asserting, since a rendering path is the wrong place to enforce that invariant.
        guard let archive, !id.hasPrefix("docx-unresolvable:"), !id.hasPrefix(officeExternalLinkPrefix) else {
            completion(nil); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = (try? archive.data(for: id)).flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { completion(img) }
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
