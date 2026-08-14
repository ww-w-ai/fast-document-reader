import AppKit
import UniformTypeIdentifiers

/// Centres the document view HORIZONTALLY when it is narrower than the viewport — a paged document
/// pins its column to the page's own body width, so at anything below "fit" there is spare window
/// on both sides and the page belongs in the middle of it (paged-zoom design §2c).
///
/// Deliberately NOT `DiagramZoomWindow.CenteringClipView`, which centres BOTH axes: that is right for
/// a diagram (a small picture floats in the middle of its window) and wrong for a document (a short
/// markdown file would drift to the vertical centre instead of starting at the top). Same idea, one
/// axis, because the two callers want different things — not a duplicate to be "unified" later.
final class PageCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        // The PAPER's width when the document has one, and only the view's frame otherwise.
        //
        // Reading the frame alone was the bug the owner reported twice ("문서의 width 가 창보다 작으면
        // 센터 정렬되어야지", then "정렬이 가운데가 아니네 — 텍스트 정렬이 아니라 문서의 정렬"): AppKit
        // keeps widening a text view's frame back to its clip view — through `sizeToFit`, and again on
        // a window resize — and a frame that equals the clip can never satisfy `frame < clip`, so the
        // test silently stopped firing and the page hugged the left edge. Measured at 727.2pt of frame
        // around a 595.3pt sheet. The paper is a constant of the DOCUMENT, so asking for it directly
        // cannot go stale that way.
        let contentWidth = (doc as? ReaderTextView)?.pagedPaperWidth ?? doc.frame.width
        guard contentWidth < rect.width else { return rect }
        rect.origin.x = (contentWidth - rect.width) / 2
        return rect
    }
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
                                     NSMenuItemValidation {
    // Explicit TextKit 1 stack (C2): building the view with init(frame:textContainer:)
    // guarantees the classic NSLayoutManager path instead of silently falling back
    // to TextKit 2 compatibility mode when layoutManager is later accessed.
    let textView: ReaderTextView
    private let scrollView = ReaderScrollView()
    private let outline = OutlinePanel(frame: NSRect(x: 0, y: 0, width: OutlinePanel.defaultWidth, height: 400))
    // P6b: the right-side comments panel — an INSPECTOR split item (trailing), distinct from the
    // outline's SIDEBAR item (leading). Both live on the same `splitVC`; `NSSplitViewController`
    // treats "sidebar" and "inspector" as independent kinds; see invariant 26/27's reasoning for
    // why this must be a real split item rather than a hand-built overlay.
    private let commentPanel = CommentPanel(frame: NSRect(x: 0, y: 0, width: CommentPanel.defaultWidth, height: 400))
    // A real NSSplitViewController with a `sidebar` item, not a hand-built NSSplitView. That is
    // what makes the panel LOOK like a Mac sidebar — the inset rounded panel, the system material,
    // the toolbar's ⌥⌘S toggle sitting beside the traffic lights, the divider that tracks it. Every
    // one of those was a thing to imitate by hand and get subtly wrong.
    private let splitVC = NSSplitViewController()
    /// The standard indeterminate spinner, shown over the text while a relayout runs.
    private let spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.style = .spinning
        p.isIndeterminate = true
        p.controlSize = .regular
        p.isDisplayedWhenStopped = false
        p.isHidden = true
        return p
    }()
    private var sidebarItem: NSSplitViewItem!
    private var commentsItem: NSSplitViewItem!

    // MARK: R5 — read-only badge + "Edit in <App>" (office documents only)
    private let officeBadge = NSTextField(labelWithString: "read only")
    private let editButton = NSButton(title: "", target: nil, action: nil)
    private let editMenuButton = NSButton(title: "", target: nil, action: nil)
    private var officeAccessoryHost: NSView!
    /// The table-of-contents titlebar button's host — hidden for a document with no headings, where
    /// the button would do nothing (the toggle just beeps).
    private var sidebarButtonHost: NSView!
    private let externalEditorService = ExternalEditorService()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred   // native tabs
        // Don't let macOS restore previously-open documents on relaunch — every launch starts
        // clean, so closing the window / quitting doesn't leave old docs (tabs) behind next time.
        window.isRestorable = false
        self.init(window: window)
        window.center()

        // Editable so a real blinking insertion point (caret) is shown and arrow-key caret
        // navigation works — you can see where a selection will start, and future editing is a
        // one-line change. Actual mutations are rejected in shouldChangeTextIn (read-only by
        // policy). Substitutions/spell-check are off so nothing tries to change the text.
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true           // ⌘F find bar (free for NSTextView)
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self              // intercept link/path clicks
        textView.displaysLinkToolTips = true
        // Standard NSScrollView + NSTextView sizing: without a non-zero frame and a huge
        // maxSize, a manually-created text view can't grow past its initial frame, so the
        // document is clipped to the visible area and won't scroll.
        let content = window.contentLayoutRect.size
        textView.frame = NSRect(origin: .zero, size: content)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // The clip view is swapped BEFORE `documentView` is set: assigning `contentView`
        // afterwards drops the document view AppKit had already installed on the old clip.
        // For markdown and plain text this class is a no-op (the document view is exactly as wide
        // as the clip), so it is installed unconditionally rather than per document kind.
        scrollView.contentView = PageCenteringClipView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false   // viewer never scrolls sideways; text wraps
        scrollView.drawsBackground = true
        // Paged documents (docx/odt/HWP that declared a page) are ZOOMED rather than re-typeset, so
        // the reader's ⌘+/⌘− becomes a view transform over a column that never moves. Turning this
        // on costs markdown nothing: `magnification` stays 1 unless `setPageZoom` is called, and
        // only a paged document ever calls it. Bounds mirror `DiagramZoomWindow`'s.
        // Opens BOTH the paged ⌘+/⌘− transform and the trackpad pinch. `ReaderScrollView` is what
        // decides what a pinch means per document — a view zoom on paper, a reading-size change in
        // text — because the flag alone cannot tell those apart.
        scrollView.owner = self
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minPageZoom
        scrollView.maxMagnification = Self.maxPageZoom
        // NSClipView repaints only the newly-exposed strip while scrolling, so custom card/quote
        // backgrounds can tear briefly mid-scroll. That's fine: viewportChanged repaints the whole
        // visible area ONCE when scrolling settles.
        // The table of contents sits beside the text as a system sidebar. Collapsed until asked
        // for: a reader opens a document to read it, not to look at a list of its headings.
        let sidebarVC = NSViewController()
        sidebarVC.view = outline
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        let contentVC = NSViewController()
        contentVC.view = scrollView
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        // P6b: the comments panel as a trailing INSPECTOR item, added AFTER content so it sits on
        // the right. Hidden by default (owner's decision, verbatim) — a document with no comments
        // (or one whose panel hasn't been asked for) shows nothing extra.
        let commentsVC = NSViewController()
        commentsVC.view = commentPanel
        commentsItem = NSSplitViewItem(inspectorWithViewController: commentsVC)
        commentsItem.minimumThickness = 220
        commentsItem.maximumThickness = 420
        commentsItem.canCollapse = true
        commentsItem.isCollapsed = true
        splitVC.addSplitViewItem(commentsItem)
        // Old name kept on purpose after the rename — a defaults key for the remembered sidebar
        // width, not a visible identifier. See the matching note on the window frame autosave.
        splitVC.splitView.autosaveName = "FastMDReaderSidebar"
        outline.onSelect = { [weak self] charIndex in self?.goToOutlineEntry(charIndex) }
        commentPanel.onSelect = { [weak self] number in self?.goToComment(number: number) }
        window.contentViewController = splitVC
        // The sidebar button goes in a TITLEBAR ACCESSORY, not a toolbar. Measured, twice: this
        // macOS lays toolbar items out trailing — with the title leading — so a toolbar button ends
        // up on the far right however the identifiers are ordered, and `.flexibleSpace` doesn't
        // move it. A `.leading` accessory is the documented way to put a control immediately right
        // of the traffic lights, which is where every Mac app keeps this one.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = sidebarButtonView()
        window.addTitlebarAccessoryViewController(accessory)
        // R5: the read-only badge + edit-in-app button mirror invariant 26's leading accessory,
        // just on the other side — `.trailing` puts it right of the title, not far-right (a
        // toolbar item would land there regardless of identifier order; see invariant 26).
        let officeAcc = NSTitlebarAccessoryViewController()
        officeAcc.layoutAttribute = .trailing
        officeAcc.view = officeAccessoryView()
        window.addTitlebarAccessoryViewController(officeAcc)
        // NOT fullSizeContentView / titlebarAppearsTransparent. Tried, and wrong: it runs the
        // document up under the title bar so text scrolls through it. The title bar stays solid and
        // opaque, which is what Preview does too — the sidebar is a panel below it, not behind it.
        window.delegate = self                     // windowDidResize → recompute the column
        updateTextInset()

        // C6: text reflow on window resize restrands copy buttons at stale positions.
        // Observe frame changes and re-place them (debounced).
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.frameDidChangeNotification, object: textView)
        // Re-place buttons on scroll so only visible code blocks carry one (perf: we never
        // force layout of off-screen blocks just to position an overlay).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // The text column is recomputed when a resize ENDS, not on every frame of one. Re-wrapping a
    // long document is a full relayout; doing it per frame is what makes a drag feel like it is
    // fighting you. During the drag the column simply keeps its old width and the window moves
    // around it — the same treatment the sidebar animation gets, and for the same reason.
    /// The line at the top of the viewport when a resize began — restored after the reflow.
    private var resizeAnchor = ReadingAnchor(char: 0, offsetFromTop: 0)

    func windowWillStartLiveResize(_ notification: Notification) {
        resizeAnchor = readingAnchor()
        suspendReflow = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // `lastClipWidth` is no longer set here directly — `updateTextInset` (called inside
        // `reflow` below) is the one place that records it now, from whatever width is ACTUALLY
        // current when it runs (see its doc). `suspendReflow` stays true until that call, so no
        // `windowDidResize` can slip through and read a stale value in between.
        //
        // Restore the reading position by CHARACTER, not by scroll offset. A narrower column wraps
        // the same text into more lines, so the document grows taller and the old offset lands
        // somewhere else entirely — further from where you were the longer the document is.
        reflow(keeping: resizeAnchor)
    }

    /// Re-wrap the document and put `anchor` back at the top, with the system spinner over it while
    /// that happens. On a 1MB file the relayout takes long enough to look like the app has stopped
    /// responding, and a spinner is the difference between "working" and "broken".
    ///
    /// The work runs on the NEXT run-loop turn: it blocks the main thread, so a spinner started and
    /// stopped around it in one turn would never paint. And the spinner only appears if the work
    /// outlasts a short delay — on a small document it finishes first and nothing flashes.
    private func reflow(keeping anchor: ReadingAnchor) {
        runBusy { [weak self] in
            guard let self else { return }
            self.suspendReflow = false
            self.updateTextInset()
            // Lay the WHOLE document out before scrolling. Narrowing the column wraps the text into
            // more lines, so the document gets taller — but until that layout exists the text view's
            // height is still the old, shorter one, and scrolling to the anchor gets clamped short
            // of it. That is why the position held when widening and drifted when narrowing, and
            // why opening the sidebar (narrower) drifted while closing it (wider) did not.
            if let lm = self.textView.layoutManager, let tc = self.textView.textContainer {
                lm.ensureLayout(for: tc)
                self.sizeTextViewToFit()
            }
            self.restore(anchor)
            self.placeCopyButtons()
        }
    }

    /// Run work that blocks the main thread, with the spinner over it if it takes long enough to
    /// notice. Every path that re-lays out the whole document goes through here — resize, sidebar,
    /// font size — so none of them can look like a freeze.
    /// `heavy` forces the spinner on regardless of length. The character-count heuristic below is a
    /// proxy for cost that badly misreads OFFICE documents: the 62-table HWP whose re-render was
    /// measured at 0.8 s holds only ~19k characters, so the slowest thing the app does showed no
    /// feedback at all. A caller that knows the work is structurally heavy says so.
    func runBusy(heavy heavyHint: Bool = false, _ work: @escaping () -> Void) {
        // Show it FIRST and force it to draw. A delayed show can never fire: the work blocks the
        // main thread, so the timer only gets its turn after the work is already done and the
        // spinner has been cancelled — which is exactly why no spinner ever appeared.
        //
        // Only for documents big enough for the relayout to be visible; below that the work is a
        // few milliseconds and a spinner would be a flash of noise.
        let heavy = heavyHint || (textView.textStorage?.length ?? 0) > 120_000
        if heavy {
            setBusy(true)
            spinner.display()                     // paint it now, before the main thread is busy
        }
        DispatchQueue.main.async {
            work()
            if heavy { self.setBusy(false) }
        }
    }

    func setBusy(_ busy: Bool) {
        if busy {
            spinner.frame = NSRect(x: (scrollView.bounds.width - 32) / 2,
                                   y: (scrollView.bounds.height - 32) / 2, width: 32, height: 32)
            if spinner.superview == nil { scrollView.addFloatingSubview(spinner, for: .vertical) }
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    func windowDidResize(_ notification: Notification) {
        // Still runs for programmatic resizes (zoom, tiling, entering full screen), which arrive in
        // one step and have no drag to be jerky — but reflow moves the text under the reader there
        // too, so the same anchor applies.
        guard !suspendReflow else { return }
        // `windowDidResize` is not limited to those one-step programmatic cases either — it also
        // fires for a purely VERTICAL drag (only the window's height changes, e.g. a bottom-edge
        // drag) where the reading column is untouched: `updateTextInset` re-wraps text and re-solves
        // table/tab geometry entirely from the column WIDTH, so a height-only event has nothing for
        // it to redo. Gating on the width actually having moved skips that whole-document walk in
        // exactly that case.
        //
        // It also keeps a width-changing resize from doing that walk TWICE: the text view is itself
        // autoresized to the window's width (`autoresizingMask = [.width]`,
        // `postsFrameChangedNotifications = true`), so the very same resize also fires
        // `viewportChanged` via `NSView.frameDidChangeNotification` — synchronously in its own body,
        // not merely its debounced button/media follow-up — which runs the identical width check
        // against the SAME `lastClipWidth`. `updateTextInset` is the one place that value gets
        // written (see its doc), so whichever of the two notification paths runs first does the
        // real work and the other then sees its own width already matched and skips, in either
        // firing order — this is a de-duplication between two independent notification paths for
        // one resize, not a per-frame throttle (`suspendReflow` above already blocks every call
        // during an actual live-resize drag, per-frame or not).
        guard abs(scrollView.contentSize.width - lastClipWidth) > 0.5 else { return }
        resizeGateReflowCount += 1
        let anchor = readingAnchor()
        updateTextInset()
        restore(anchor)
    }

    /// Running-header/footer page-boundary reservation (header-footer-design.md §4, build step 4).
    /// Held here — not just assigned to `layout.delegate` — because `NSLayoutManager.delegate` is
    /// `weak`; installed UNCONDITIONALLY in `init` below and left inert wherever it doesn't apply
    /// (`PageBandLayoutDelegate.isActive`), so no call site has to gate on whether the current
    /// document is paged or has a header/footer at all. `MarkdownDocument.render(into:)` is the one
    /// place that updates its two numbers, every render, via `configurePageBand`.
    let pageBandDelegate = PageBandLayoutDelegate()

    /// Everything `PageBandPainter.draw` (header-footer-design.md build step 5) needs to actually
    /// PAINT the band `pageBandDelegate` reserves — `nil` whenever `band == 0` (no header/footer at
    /// all), so `ReaderTextView.drawBackground(in:)` costs one optional-unwrap for the common
    /// non-paged/no-header case, exactly like `pageBandDelegate.isActive` costs one bool check for
    /// the layout half. See `PageBandContent`'s own doc for why this and `pageBandDelegate` are
    /// always set TOGETHER, from the same `configurePageBand` call.
    private(set) var pageBandContent: PageBandContent?

    /// Wires `pageBandDelegate`'s two numbers AND `pageBandContent` for whatever this document just
    /// became — called from `MarkdownDocument.render(into:)`, before `display(_:)` below replaces the
    /// storage, so the layout manager's delegate reflects THIS render's own numbers before a single
    /// line of the new document is laid out. `pageContentHeight` nil or `band` `0` leaves the
    /// delegate inactive (`PageBandLayoutDelegate.isActive`) AND clears `pageBandContent` — a
    /// document with no header/footer, and every markdown/plain-text document (which never call this
    /// at all), stay exactly as they were before either of these existed. The painting parameters
    /// default to the "nothing to paint" shape so every PRE-step-5 call site (there was exactly one,
    /// and it is now updated, but a future test calling the old two-argument form still compiles and
    /// still means "no header/footer content").
    func configurePageBand(pageContentHeight: CGFloat?, band: CGFloat,
                            headers: [OfficeHeaderFooter] = [], footers: [OfficeHeaderFooter] = [],
                            theme: RenderTheme = .current(size: 11), columnWidth: CGFloat = 0,
                            documentDefaultFontSize: CGFloat = 11, pageContentWidth: CGFloat? = nil,
                            headerHeight: CGFloat = 0, footerHeight: CGFloat = 0,
                            separatesPages: Bool = false, deskGap: CGFloat? = nil) {
        pageBandDelegate.pageContentHeight = pageContentHeight ?? 0
        pageBandDelegate.band = band
        // This render replaces the storage, so where the section markers sit is about to change.
        cachedSectionStarts = nil
        // LEADING (page 0's own header) and TRAILING (the last page's own footer) — the two OUTER
        // edges the between-page reservation cannot reach on its own (header-footer-design.md's own
        // recorded gap). LEADING is gated on page 0's OWN applicable header actually carrying
        // content: an explicit blank `.firstPage` entry (the OOXML "no header on the cover" rule,
        // §2d) must reserve nothing, not merely paint nothing — a document that deliberately blanked
        // its cover should not grow an unexplained gap above it either. TRAILING uses the same
        // `footerHeight > 0` gate the between-page footer bands already use — real per-page "is the
        // LAST page's own entry blank" tracking is the same even/odd-class simplification
        // header-footer-design.md §7 already accepts for the ordinary bands (`headerHeight`/
        // `footerHeight` themselves are already `0` for a non-paged office document — the caller
        // gates `PageBandGeometry.measure` on `officePageContentHeight != nil` before this is ever
        // reached with non-zero values — so this never reserves anything for that far more common
        // case either).
        // "The entry has blocks" was the gate here and it is the wrong question: an entry can be
        // present, carry blocks, and BUILD to nothing — 26 of the 94 real HWP/HWPX documents that
        // declare a header or footer at all declare one made of nothing but empty paragraphs, and the
        // reference report's own `.odt` declares exactly such a first-page header. Every one of them
        // reserved a band above the first line and drew nothing in it. Asked of what it BUILDS, through
        // the one function that owns that judgement.
        let firstPageHeader = PageBandPainter.applicableEntry(headers, pageIndex: 0)
        var leading: CGFloat = PageBandGeometry.entryDraws(
            firstPageHeader, theme: theme, columnWidth: columnWidth,
            documentDefaultFontSize: documentDefaultFontSize,
            pageContentWidth: pageContentWidth) ? headerHeight : 0
        var trailing: CGFloat = footerHeight > 0 ? footerHeight : 0
        // WHEN THE READER IS DRAWING SHEETS, the first and last pages get their FULL margins — the
        // page's own top margin above the first line and its bottom margin below the last, not just
        // as much room as the header and footer happen to need.
        //
        // Without this the outline's first sheet has no top edge at all: the sheet begins one top
        // margin above the first line, which with only a header's worth of leading room is ABOVE the
        // view, so page 1 draws with no top border and a visibly shorter margin than every page after
        // it. Seen immediately on the first real screenshot of the feature. The two `max`es keep the
        // existing rule as the floor, so a document whose header is TALLER than its own margin still
        // gets the room it needs to draw (invariant 57e's own `max`, one level up).
        if separatesPages {
            leading = max(leading, pagedMarginTop ?? 0)
            trailing = max(trailing, pagedMarginBottom ?? 0)
        }
        pageBandDelegate.leadingBand = leading
        pageBandDelegate.trailingBand = trailing
        pageBandDelegate.deskGap = deskGap ?? (separatesPages ? RenderTheme.pageDeskGap : 0)
        applyVerticalInset()   // the leading band only becomes ROOM through the inset — see that function
        // A new render re-decides every boundary, so the previous pass's answers must not survive
        // into it — a stale entry would paint into a band this layout never made.
        pageBandDelegate.resetOpenedBoundaries()
        // The moved-table record goes with them, and for a stronger reason: it is keyed by CHARACTER
        // LOCATION, so carrying it into a different string would move whatever happens to start at
        // that offset. It is also band-dependent — the page outline changes the pitch, so which tables
        // overrun changes with it. `settlePagedTables` rebuilds it from the new layout.
        pageBandDelegate.resetMeasuredPieces()
        pagedTableSettles = 0
        pageBandContent = band > 0
            ? PageBandContent(headers: headers, footers: footers, theme: theme, columnWidth: columnWidth,
                              documentDefaultFontSize: documentDefaultFontSize, pageContentWidth: pageContentWidth,
                              headerHeight: headerHeight, footerHeight: footerHeight,
                              leadingBand: leading, trailingBand: trailing,
                              pageMarginTop: pagedMarginTop, pageMarginBottom: pagedMarginBottom,
                              headerDistance: pagedHeaderDistance, footerDistance: pagedFooterDistance)
            : nil
    }

    /// What `MasterPagePainter.draw` needs — derived from `pageBandContent` rather than plumbed
    /// through `configurePageBand` a second time, because every number it wants (the theme, the
    /// document's default body size, its page width) is already in there and derived once is one
    /// fewer way for the two to disagree.
    ///
    /// `nil` unless the document HAS a master page and the reader is drawing pages at all — the
    /// second condition falls out of `pageBandContent` being nil when `band == 0`, which under the
    /// owner's master-switch rule (`PageViewOptions.underOutlineRule`) is exactly "the page outline
    /// is off, so there is no page for anything to be about".
    var masterPageContent: MasterPageContent? {
        guard PageViewOptionsStore.current.masterPage,
              let pages = mdDocument?.officeMasterPages, !pages.isEmpty,
              let band = pageBandContent else { return nil }
        return MasterPageContent(pages: pages, theme: band.theme,
                                 documentDefaultFontSize: band.documentDefaultFontSize,
                                 pageContentWidth: band.pageContentWidth)
    }

    /// Where each section BEGINS in the laid-out text, as `(character, section)` in document order.
    ///
    /// Read from the markers `OfficeTextBuilder` put on each section's first block
    /// (`MDAttr.sectionIndex`) rather than from the block indices themselves, because a block index
    /// is not a character offset — a block that builds to nothing occupies none. Scanned ONCE per
    /// render (one pass over the storage) and cached: `configurePageBand` clears it, which is the
    /// same "every render, before the storage is replaced" hook the band itself hangs on.
    private var cachedSectionStarts: [(character: Int, section: Int)]?

    private var sectionStarts: [(character: Int, section: Int)] {
        if let cached = cachedSectionStarts { return cached }
        var out: [(character: Int, section: Int)] = []
        if let storage = textView.textStorage, storage.length > 0 {
            storage.enumerateAttribute(MDAttr.sectionIndex,
                                       in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let section = value as? Int { out.append((range.location, section)) }
            }
        }
        cachedSectionStarts = out
        return out
    }

    /// Which section page `page` (0-based) is typeset on, or `nil` when the document never said.
    ///
    /// Answered from the page's FIRST CHARACTER — the glyph the typesetter put at the top of that
    /// page's text — and then the last section that starts at or before it. A page that begins
    /// mid-section carries no marker of its own, which is exactly why the answer is the last one
    /// before it rather than one found on the page.
    func sectionOfPage(_ page: Int) -> Int? {
        let starts = sectionStarts
        guard !starts.isEmpty, let lm = textView.layoutManager, let tc = textView.textContainer,
              pageBandDelegate.isActive else { return nil }
        let pitch = PagePagination.pitch(pageContentHeight: pageBandDelegate.pageContentHeight,
                                         band: pageBandDelegate.band)
        guard pitch > 0 else { return nil }
        // One point INTO the page's text area, in container coordinates — the same arithmetic the
        // band and the sheets use, so all three agree about where a page's text begins.
        let y = pageBandDelegate.leadingBand + CGFloat(page) * pitch + 0.5
        let glyph = lm.glyphIndex(for: NSPoint(x: 1, y: y), in: tc)
        let character = lm.characterIndexForGlyph(at: glyph)
        var answer: Int?
        for start in starts {
            if start.character <= character { answer = start.section } else { break }
        }
        return answer
    }

    /// Reserves the TRAILING footer band — the space below the very LAST line of a paged document,
    /// the other edge of header-footer-design.md's own recorded gap (`PageBandLayoutDelegate.
    /// leadingBand`, wired from `configurePageBand`, fixes the LEADING one). The between-page
    /// mechanism only ever shifts an EXISTING line; there is no line after the very last one to push
    /// down, so this instead widens `NSLayoutManager`'s own "extra line fragment" — normally one line
    /// tall, reserved for cursor placement after a trailing paragraph break. `usedRect(for:)` (and so
    /// `isVerticallyResizable`'s automatic frame-height math) DOES fold that in, confirmed by a
    /// standalone spike before this was built: widening it to `trailingBand` tall grows the view's
    /// frame by exactly that much, nothing is written into the text storage (§4's "nothing inserted"
    /// rule intact — invariant 40's `--extract` guarantee is untouched by construction, structurally
    /// unreachable from the serializer), and it does not fight `textContainerInset` the way a naive
    /// height bump would: that same spike found `textContainerInset.height` pads the top AND bottom
    /// by the SAME amount always, so there is no way to give the two edges different reservations
    /// through it alone — exactly why the leading side above uses a completely different mechanism.
    ///
    /// MUST be called only once the WHOLE document is actually laid out — asking for the last
    /// glyph's position any earlier forces every unlaid character in between to lay out in one call,
    /// exactly the freeze invariant 49 measured and rejected (69–80 SECONDS on a real report).
    /// `precomputeLayout`'s own completion is that guarantee (see its call of this method below) —
    /// including the deferred-giant-table splice's own re-walk (`MarkdownDocument.
    /// spliceDeferredTables.finish()`), which funnels through the exact same function, so a document
    /// with BOTH a footer and a giant table still ends up with the reservation in the right place
    /// once splicing finishes.
    ///
    /// Idempotent and safe to call unconditionally (paged or not, footer or not): it derives its
    /// target purely from the CURRENT last line's own rect, never from a previous call's effect, and
    /// zeroes the reservation whenever there is nothing to reserve — a stale reservation must never
    /// survive from one document to the next on the SAME reused text view/layout manager (`display(_:)`
    /// also clears it up front, before the new document's own walk has had a chance to run at all, so
    /// nothing is ever left showing a PREVIOUS document's footer-sized gap even for one frame).
    func applyTrailingFooterBand() {
        guard pageBandDelegate.isActive else { return }   // markdown/plain-text/non-paged: never reached
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let trailing = pageBandDelegate.trailingBand
        let lastGlyph = lm.numberOfGlyphs - 1
        let baseline: CGFloat = lastGlyph >= 0
            ? lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY
            : 0
        let width = trailing > 0 ? tc.size.width : 0
        let rect = NSRect(x: 0, y: baseline, width: width, height: trailing)
        lm.setExtraLineFragmentRect(rect, usedRect: rect, textContainer: tc)
        sizeTextViewToFit()
    }

    override init(window: NSWindow?) {
        let storage = NSTextStorage()
        let layout = CodeCardLayoutManager()   // draws code blocks as rounded cards
        storage.addLayoutManager(layout)
        // CONTIGUOUS layout. We deliberately precompute the whole document's layout anyway (for a
        // complete scroll bar from the start), so non-contiguous layout's "lay out only the
        // viewport" benefit is already given up. Worse, with non-contiguous layout every attachment
        // edit (a diagram/image loading) drops the layout below it and reverts the total height to
        // an ESTIMATE for a frame — which is exactly the scroll-bar jitter. Contiguous layout keeps
        // the full layout, so an unchanged-size edit re-renders just that glyph and the height (and
        // scroll bar) never move.
        layout.allowsNonContiguousLayout = false
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        // Wrap at an EXPLICIT container width (set in updateTextInset) rather than tracking
        // the text view — tracking left the view too wide, so text overflowed the window.
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        textView = ReaderTextView(frame: .zero, textContainer: container)
        super.init(window: window)
        layout.delegate = pageBandDelegate
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Text fills the window width, with comfortable side margins (per user preference — the
    // readable ~660pt cap felt too narrow). Wrapping at an explicit container width still
    // guarantees the viewer never scrolls sideways.
    private let minSideInset: CGFloat = 32
    private let verticalInset: CGFloat = 28

    /// The app's own padding PLUS the room page 1 needs above its first line.
    ///
    /// A LINE SHIFT CANNOT MAKE ROOM AT THE TOP OF THE VIEW, which is the opposite of what the band
    /// delegate looks like it does. `NSTextView.textContainerOrigin` is derived from where the laid-out
    /// content STARTS: measured on two real documents it is exactly `inset − ⌈usedRect.minY⌉`, so
    /// pushing the first line down by a 138.90pt band moved the origin to −111.00 and the first line
    /// landed back at the inset with the band cancelled. Page 1's own sheet then began 111pt ABOVE the
    /// view's origin — unreachable, because a reader cannot scroll past y=0 and the text view cannot
    /// draw outside its bounds. That is the owner's "1페이지에서 가장 아래로 내려도 위가 안 보임"; every
    /// other page was fine, since their bands sit BETWEEN lines where nothing compensates.
    ///
    /// Printing never saw it (a print rect may reach outside the view — invariant 59a), which is why a
    /// paginated PDF was correct while the screen was not.
    ///
    /// So the room comes from the inset, which AppKit does not cancel. It is symmetric, so the same
    /// amount also appears BELOW the last page — desk, not paper, and the trailing band still supplies
    /// that page's own bottom margin. Zero for markdown, plain text and any document with no band, so
    /// those reduce exactly to `verticalInset`.
    var verticalInsetHeight: CGFloat { verticalInset + pageBandDelegate.leadingBand }

    private func applyVerticalInset() {
        guard abs(textView.textContainerInset.height - verticalInsetHeight) > 0.01 else { return }
        textView.textContainerInset.height = verticalInsetHeight
    }

    /// Set while the sidebar animates: width changes are ignored until it settles (see the toggle).
    private var suspendReflow = false
    private var pageNumberDesk: PageNumberDeskView?

    /// Not private: `MarkdownDocument.render(into:)` calls this right before it reads the reading
    /// column, which it uses BOTH as `OfficeTextBuilder.build`'s `columnWidth` and as the numerator of
    /// that build's `graphicScale` — so an office document's graphics are sized against the SAME column
    /// they will finally be displayed at. The controller's own convenience `init` runs
    /// `updateTextInset()` before `addWindowController` wires `document`, so re-running it once
    /// `document` is wired settles the column before those sizes freeze (invariant 1/11).
    /// The GEOMETRY half of `updateTextInset` — inset, container width, text-view frame — returning
    /// the resulting reading column, and deliberately WITHOUT the two passes that walk the entire
    /// text storage.
    ///
    /// Callers that are about to REPLACE the storage (`MarkdownDocument.render(into:)`, and
    /// `display(_:)` right before `setAttributedString`) need the column settled first, because a
    /// rebuild freezes office graphic sizes against it (invariant 1/11). But at that instant the
    /// storage still holds the OUTGOING document, so re-solving its tab stops and table columns is
    /// work thrown away microseconds later. Measured on a 62-table HWP: 91 ms per full pass, and the
    /// old code paid it THREE times per ⌘+ press (render, display's opening call, display's async
    /// tail) when only the last one — the one that runs against the NEW string — does anything.
    @discardableResult
    func settleReadingColumn() -> CGFloat? {
        let clipWidth = scrollView.contentSize.width
        guard clipWidth > 1, !suspendReflow else { return nil }
        // PAGED: the column is the DOCUMENT's own page body and the window no longer decides it.
        // `lastClipWidth` is still written (below, in the shared path) because both resize gates
        // de-duplicate against it — pinning the COLUMN must not strand the GATE.
        if let page = pagedWidth {
            let widthMoved = abs(clipWidth - lastClipWidth) > 0.5
            lastClipWidth = clipWidth
            textInsetUpdateCount += 1
            // The sheet is the DOCUMENT's: its own left margin positions the text and its own right
            // margin trails it, so `left + body + right` is the author's paper. Reproducing only the
            // BODY was measured as the largest remaining size gap against Word and Pages — they show
            // the whole sheet, so at the same window width a body-only layout magnifies the text by
            // paper ÷ body, which is 1.24×–1.32× on four real A4 documents. A reader that found no
            // margins falls back to the app's own inset, unchanged.
            let leftMargin = pagedMarginLeft ?? minSideInset
            let rightMargin = pagedMarginRight ?? minSideInset
            textView.textContainerInset = NSSize(width: leftMargin, height: verticalInsetHeight)
            textView.textContainer?.containerSize = NSSize(width: page, height: CGFloat.greatestFiniteMagnitude)
            // ZERO, not AppKit's default 5 — the last place the app was quietly narrowing the page.
            // `containerSize.width` is the body width the DOCUMENT declared, and a padding of 5 takes
            // it off BOTH sides, so a 481.90pt column laid out at 471.90. Everything authored against
            // the page's own width then missed by 10pt, and the reference report's table of contents
            // is what showed it: its page-number tab sits at 481.40pt, 0.50pt inside the declared
            // body and 9.50pt OUTSIDE the usable one, so every entry's number wrapped to a second
            // line — and, wrapped, the entry's first line was no longer its LAST, so the style's own
            // `w:jc="both"` justified it and splayed the title across the column. Two symptoms, one
            // cause. The inset already positions the text at the paper's own left margin, so removing
            // the padding does not move the text; it gives the line back the 10pt the document asked
            // for. The table-width sites all read this padding live (`MarkdownDocument.render`,
            // `spliceDeferredTables`, `resizeTableColumns`), so invariant 48b's "built at the width
            // it is laid out at" follows automatically. NON-paged is untouched: it keeps the 5pt,
            // and `OfficeTextBuilder.fillMarginTrailingInset` keeps re-anchoring tabs there.
            textView.textContainer?.lineFragmentPadding = 0
            // The document view is FIXED at the page's width, not stretched to the clip. Both halves
            // matter: measured on this machine, a magnified clip's bounds shrink and an
            // autoresizing text view FOLLOWS them (883 → 441 pt at 2×), which would re-wrap the
            // text on every zoom press — the exact re-typesetting this change exists to remove,
            // arriving through the back door. `PageCenteringClipView` puts the spare width in the
            // margins instead.
            textView.autoresizingMask = []
            // …and `sizeToFit` must respect that too, which needs BOTH of these. With
            // `isHorizontallyResizable == false` AppKit takes "this view's width is its clip view's"
            // literally: every `sizeToFit()` — `applyTrailingFooterBand`'s, and the reading-anchor
            // restore's — silently widened the frame back to the CLIP, so the page stopped being a
            // page. Measured on the reference report: frame 888.2pt against a 595.3pt sheet.
            //
            // Two visible consequences, both reported by the owner the moment sheets were drawn:
            // the sheet was painted at the FRAME's width, so the paper ran the full width of the
            // window with no edges and no desk beside it; and `PageCenteringClipView` compares
            // `doc.frame.width < clip.bounds.width`, which a frame that always equals the clip can
            // never satisfy — so the page hugged the left. It looked right until the first ⌘+,
            // because the opening settle set the frame correctly and the first `sizeToFit` after a
            // zoom undid it ("초기에는 여백이 보이는데, 거기에서 확대/축소하면 사라지고").
            //
            // `true` + the container's `widthTracksTextView = false` (set in `init`) is AppKit's own
            // fixed-width text view: `sizeToFit` then derives the width from the CONTAINER plus its
            // insets, which is exactly the paper. Non-paged keeps `false` and keeps tracking the clip.
            textView.isHorizontallyResizable = true
            var f = textView.frame
            f.size.width = leftMargin + page + rightMargin
            textView.frame = f
            applyPagedViewState()
            // First paged settle: open at `defaultPageZoom`, and bring the window to the page rather
            // than the page to the window.
            //
            // This was first built as fit-to-window, which opened every document 1.5×–2.9× larger than
            // the applications the reader compares us with, and the owner reported the type as
            // oversized. It was then corrected to 1.0 on the belief that "Word and Pages open at
            // 100%". THAT BELIEF WAS WRONG and is the reason this comment is long: measured on this
            // machine, Word opens at 120%, Pages at 125%, and Hancom's HWP Viewer at ~115%, so 1.0
            // made us the smallest of the four and the owner reported THAT. The fix is neither
            // extreme — a fixed multiple of actual size (see `defaultPageZoom`), which keeps the
            // page's authored proportions while landing in the band the three peers occupy.
            //
            // §2a's window-follows-page rule is what keeps the result from looking marooned: the
            // WINDOW comes to the page's size, so the page fills it at the opening zoom and the
            // zoom-follows-window rule below then holds rather than fighting.
            // THE WINDOW IS SIZED ONCE, WHEN THE DOCUMENT OPENS, AND THEN LEFT ALONE.
            //
            // Both of the rules that used to live here are gone, on the owner's instruction after
            // reading a real report: "⌘+/⌘− 할 때는 창의 크기는 변함없도록 하자 — 워드가 그렇게 열리네".
            //   • The window no longer FOLLOWS the zoom (§2a's grow-the-window rule). A press changed
            //     the frame, which reads as the app fighting the reader; Word zooms inside a window
            //     the reader placed and keeps it there. `stepPageZoom` no longer re-fits.
            //   • The zoom no longer follows the WINDOW either. That rule existed to keep the page
            //     filling the reading area exactly, which is incompatible with opening the window
            //     WIDER than the page on purpose — it would eat the side margins on the first resize.
            //     A manual resize now just reveals more desk, which is the design doc's own §2c.
            // What remains is one seed: open at `defaultPageZoom`, and bring the window to the page
            // plus a margin either side.
            if !pageZoomSeeded, scrollView.contentSize.width > 1 {
                pageZoomSeeded = true
                applyMagnification(Self.defaultPageZoom)
                DispatchQueue.main.async { [weak self] in self?.fitWindowToPage() }
            }
            return page
        }
        textView.autoresizingMask = [.width]
        // Stated rather than inherited, for the paged branch's reason above: markdown and plain text
        // WANT the frame to follow the clip, and a document opened after a paged one shares this view.
        textView.isHorizontallyResizable = false
        applyPagedViewState()                // clears the paper, restores the default background
        // The ONE place `lastClipWidth` is written. Every caller — this init/setup path,
        // `reflow(keeping:)`, `display(_:)`, `windowDidResize`, `viewportChanged` — funnels through
        // here, so the value can never disagree with the layout that actually just ran, regardless
        // of which caller triggered it or whether an earlier caller's own bookkeeping went stale
        // waiting for an async turn (concretely: `windowDidEndLiveResize` used to set this directly
        // and could be overtaken by a second resize before `reflow`'s deferred work ran, leaving a
        // width no longer true — see its own comment).
        lastClipWidth = clipWidth
        textInsetUpdateCount += 1
        let column = max(200, clipWidth - 2 * minSideInset)   // fill the window minus margins
        textView.textContainerInset = NSSize(width: minSideInset, height: verticalInsetHeight)
        textView.textContainer?.containerSize = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude)
        // Stated rather than inherited: the paged branch above sets this to 0, and every
        // `?? 5` fallback in the table-width arithmetic assumes this path is the 5pt one. Assigning
        // it here is a no-op against AppKit's default and stops that being a hidden dependency.
        textView.textContainer?.lineFragmentPadding = 5
        var f = textView.frame; f.size.width = clipWidth; textView.frame = f
        return column
    }

    func updateTextInset() {
        // The reading column fills the window (minus side margins) for markdown, plain text, and an
        // office document whose reader could NOT determine a page width. A PAGED document instead
        // pins the column to its own page body and zooms (`settleReadingColumn`, paged-zoom design
        // §2) — the earlier attempt at that pin was rejected as "a narrow column marooned in a wide
        // window", and the thing that fixes it is the zoom, which that attempt did not have.
        //
        // `settleReadingColumn` always runs — it pins the container, keeps `lastClipWidth` current
        // for both resize gates, and seeds the opening zoom.
        guard let column = settleReadingColumn() else { return }
        // PAGED: the three passes are SKIPPED, not deleted. All three are pure functions of the
        // reading column, and a paged column is constant for the life of the document, so each one
        // provably recomputes the value it already holds: `reanchorFillMarginTabs` re-derives the
        // same tab stops, `resizeTableColumns` moves 0 cells (the build used this very width), and
        // `resizeOfficeGraphics` computes `scale = column ÷ basis` = 1, i.e. the authored size the
        // build already applied.
        //
        // Skipping is not just an optimisation here, it is required by §2a: a zoom press RESIZES
        // THE WINDOW, which lands on `windowDidResize` and would otherwise pay a full walk of the
        // storage on every press — 91 ms on a 62-table HWP and far worse on a 51,816-cell report,
        // reintroducing on the window-follow exactly the cost the zoom exists to remove.
        //
        // They are kept, not deleted, because they remain the ENTIRE implementation of the
        // no-page-width fallback (design §7) — an office document whose reader found no page size
        // still re-solves against a window-sized column, exactly as before.
        if isPaged { return }
        reanchorFillMarginTabs(toColumn: column)
        resizeTableColumns(toColumn: column)
        resizeOfficeGraphics(toColumn: column)
    }

    // MARK: - Paged zoom (paged-zoom design §2 / §5 step 1)

    static let minPageZoom: CGFloat = 0.25
    static let maxPageZoom: CGFloat = 8
    /// One press. Matches `DiagramZoomWindow.ZoomScrollView.zoom(by:)` so the two zoom surfaces in
    /// the app step by the same amount.
    static let pageZoomStep: CGFloat = 1.25

    /// The zoom a paged document OPENS at, and the one ⌘0 returns to.
    ///
    /// NOT 1.0, and the reason is measured rather than argued. Every application this reader is
    /// compared against shows a page LARGER than actual size by default, on the same screen:
    /// Word 120%, Pages 125%, and Hancom's HWP Viewer ~115% (its status bar reads "86%" because it
    /// counts in 96-DPI units — 0.86 × 96/72 = 1.147; confirmed independently off its own ruler, where
    /// 1 cm measured 65.4 px on a 2× display against 56.7 px at actual size). Opening at 1.0 therefore
    /// made us the smallest of the four and the owner reported exactly that. 1.2 is Word's own number,
    /// and it sits inside the 1.15–1.25 band the three of them occupy.
    ///
    /// This does NOT re-open the question `c46dcfa` settled: fit-to-window is still wrong (it opened
    /// documents 1.5×–2.9× larger, which is what made the owner call the type oversized). A fixed
    /// multiple of actual size is a different thing — the page keeps its authored proportions and only
    /// its on-screen size changes.
    ///
    /// The number has moved three times, each time on the owner's own reading of the result rather
    /// than on an argument: fit-to-window (too large) → 1.0 (smallest of the four) → 1.2 (Word's own)
    /// → **1.8**, half again as large, which is what the owner asked for after reading a real report
    /// on this display. Word's 120% is measured on Word's default 10–11pt body; a Korean report set in
    /// 10pt with a 481pt column is smaller on screen than that comparison suggests, and the reader is
    /// a reader — it is read, not laid out. So the peer band is the floor here, not the target.
    static let defaultPageZoom: CGFloat = 1.8

    /// How much room to leave on EACH side of the page when the window first opens — the paper sits
    /// on a desk rather than filling the frame edge to edge, which is how Word opens.
    ///
    /// Only ever applied when SIZING THE WINDOW, never to the reading column: the column is the
    /// document's own page body (invariant 57) and `PageCenteringClipView` already centres the page in
    /// whatever spare width exists. So this widens the window; it never re-typesets anything.
    static let pageWindowSideMargin: CGFloat = 40

    /// The page body width this document declared, or nil for every other kind. THE paged predicate:
    /// `kind == .office` is NOT it — an office document whose reader found no page width (a real,
    /// tested state in all three formats) keeps the fill-the-window model, and five existing tests
    /// go red the moment that distinction is lost.
    /// The document this controller is showing — and the ONLY safe way to ask for it.
    ///
    /// `NSWindowController.document` is imported as `unowned(unsafe)`, so once the document has been
    /// released, merely reading it is a use-after-free: the cast takes a `+1` reference and
    /// `objc_retain` walks freed memory. That is not theoretical. It crashes the test suite from the
    /// DRAW path — `ReaderTextView.drawBackground` → `drawPageSheets` → `pageSheets` → `printSheets` →
    /// `pagedDocumentWidth` → here — because a window can outlive its document by a run-loop turn, and
    /// CoreAnimation commits the next draw inside that turn. Two crash reports a day apart show the
    /// identical frame, both reached by a test that pumps the run loop.
    ///
    /// A `weak` mirror, kept in step by overriding the setter, answers `nil` instead. Every read in
    /// this class goes through it; a bare `mdDocument` anywhere is the bug coming
    /// back.
    private weak var weakDocument: MarkdownDocument?

    override var document: AnyObject? {
        didSet { weakDocument = document as? MarkdownDocument }
    }

    var mdDocument: MarkdownDocument? { weakDocument }

    var pagedWidth: CGFloat? {
        guard let doc = mdDocument, let w = doc.officePageContentWidth, w > 0 else { return nil }
        return w
    }

    var isPaged: Bool { pagedWidth != nil }

    /// The page body HEIGHT this document declared, or nil — the vertical twin of `pagedWidth`, from
    /// `MarkdownDocument.officePageContentHeight`. NOT YET consumed by any layout pass: this is the
    /// prerequisite `officePageContentHeight`'s own doc comment describes (running headers/footers,
    /// showing where a page ends), and wiring it into `settleReadingColumn`'s vertical inset is a
    /// separate, measured change — see that function's hardcoded `verticalInset`.
    var pagedHeight: CGFloat? {
        guard let doc = mdDocument, let h = doc.officePageContentHeight, h > 0 else { return nil }
        return h
    }

    /// The page's own top/bottom margins, when its reader found them — the vertical twins of
    /// `pagedMarginLeft`/`pagedMarginRight`. Same non-consumption caveat as `pagedHeight`.
    private var pagedMarginTop: CGFloat? { (mdDocument)?.officePageMarginTop }
    private var pagedMarginBottom: CGFloat? { (mdDocument)?.officePageMarginBottom }
    /// The running header's/footer's own distance from the SHEET edge — see
    /// `OfficeReadResult.pageHeaderDistance`. Nil for a format that does not state it.
    private var pagedHeaderDistance: CGFloat? { (mdDocument)?.officePageHeaderDistance }
    private var pagedFooterDistance: CGFloat? { (mdDocument)?.officePageFooterDistance }

    /// The live magnification. Read-only to the outside; `scrollView` is private on purpose.
    var pageZoom: CGFloat { scrollView.magnification }

    /// Test-visible, in the shape of `textInsetUpdateCount` / `resizeGateReflowCount`: counts how
    /// many times a zoom was actually applied, so a test can assert a press did something without
    /// a stopwatch.
    private(set) var pageZoomChangeCount = 0

    /// Set once the first paged settle has chosen an opening zoom, so a later reflow does not
    /// silently reset the reader's own choice back to fit.
    private var pageZoomSeeded = false

    /// One-shot: the next width change was caused by OUR OWN zoom-driven window resize, so the
    /// zoom-follows-window rule must skip it exactly once. See the settle that consumes it.

    /// The page's own left/right margins, when its reader found them. `nil` → the app's own inset.
    private var pagedMarginLeft: CGFloat? { (mdDocument)?.officePageMarginLeft }
    private var pagedMarginRight: CGFloat? { (mdDocument)?.officePageMarginRight }

    /// The document view's full width in document points — the PAPER: the author's own left margin,
    /// their body column, and their own right margin. This is the number the zoom multiplies and the
    /// one the window is sized against, so at magnification 1.0 the sheet on screen is the sheet Word
    /// and Pages draw at 100%.
    /// Internal rather than private so a test can compute the same number this sizes the window
    /// against — see `testAPagedWindowOpensWiderThanThePageByAMarginEitherSide`.
    var pagedDocumentWidth: CGFloat? {
        pagedWidth.map { (pagedMarginLeft ?? minSideInset) + $0 + (pagedMarginRight ?? minSideInset) }
    }

    private func clampPageZoom(_ z: CGFloat) -> CGFloat {
        min(Self.maxPageZoom, max(Self.minPageZoom, z))
    }

    /// A page magnified past the viewport has to be reachable sideways. Called from both the zoom
    /// and the settle, because the page can outgrow the clip either by zooming IN or by the window
    /// shrinking. The horizontal scroller consumes HEIGHT, never width, so toggling it cannot move
    /// `contentSize.width` and cannot disturb either resize gate.
    private func syncHorizontalScroller() {
        guard let d = pagedDocumentWidth else { scrollView.hasHorizontalScroller = false; return }
        scrollView.hasHorizontalScroller = d * scrollView.magnification > scrollView.contentSize.width + 0.5
    }

    /// Zoom OUT just far enough that the page still fits the reading area — never in, and never
    /// further than it has to.
    ///
    /// Requested for the sidebar: *"목록을 열면 화면 크기가 작아지니 그만큼 문서가 축소되면 좋겠음"*, with
    /// the bound stated straight after — *"무리하게 줄이진 말고, 창이 우측으로 삐져나가지 않도록 축소해서
    /// 맞추라는 뜻"*. So this is shrink-to-fit, one-directional:
    ///   • the page overflows the reading area → scale it down until it fits, side margins kept
    ///   • it already fits → do nothing at all, including when there is room to spare
    ///
    /// The second half is what keeps this from being the "zoom follows the window" rule that was
    /// deliberately removed (see `settleReadingColumn`): a manual resize still just reveals more desk,
    /// and the reader's own zoom choice is never enlarged behind their back. Only a panel taking room
    /// AWAY calls this — the app shrinking the reading area is the app's problem to absorb.
    func shrinkPageZoomToFit() {
        guard isPaged, let d = pagedDocumentWidth, d > 0 else { return }
        let available = scrollView.contentSize.width - 2 * Self.pageWindowSideMargin
        guard available > 1, d * scrollView.magnification > available + 0.5 else { return }
        applyMagnification(clampPageZoom(available / d))
    }

    /// The ONLY thing a zoom is allowed to touch. It must never reach `settleReadingColumn` or
    /// `updateTextInset`: invariant 56b's 65,853 ms freeze is AppKit filling layout holes inside
    /// `NSTextTable`, and magnification creates none — but changing the container width by even a
    /// point re-wraps the document and brings the freeze straight back.
    ///
    /// Returns whether the zoom actually moved, so a press already at the clamp does not go on to
    /// resize the window for nothing.
    @discardableResult
    private func applyMagnification(_ z: CGFloat) -> Bool {
        let target = clampPageZoom(z)
        guard abs(scrollView.magnification - target) > 0.0001 else { return false }
        // The point is in the DOCUMENT view's space — same call, same space, as
        // `DiagramZoomWindow.ZoomScrollView.zoom(by:)`, which is the shipped precedent.
        let visible = scrollView.contentView.documentVisibleRect
        scrollView.setMagnification(target, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        pageZoomChangeCount += 1
        applyPagedViewState()   // a magnification change moves the clip's bounds, which widens the frame
        return true
    }

    /// ⌘+ / ⌘− for a paged document. Returns false when this document is not paged, so the caller
    /// falls through to the reading-font-size model.
    @discardableResult
    func stepPageZoom(magnifying: Bool) -> Bool {
        guard isPaged else { return false }
        // The WINDOW IS NOT TOUCHED — owner's instruction, and Word's behaviour: a zoom press changes
        // how big the page is drawn inside the frame the reader put it in, never the frame itself.
        _ = applyMagnification(scrollView.magnification * (magnifying ? Self.pageZoomStep : 1 / Self.pageZoomStep))
        return true
    }

    /// ⌘0 for a paged document — back to the opening ZOOM, and the window is left exactly where the
    /// reader put it, the same rule ⌘+/⌘− now follow.
    ///
    /// It used to restore the window too, and had to: while the zoom followed the window, resetting
    /// the magnification alone was immediately undone by the re-fit, so the key read as doing nothing.
    /// That rule is gone (see `settleReadingColumn`'s paged branch), so one rule covers all three
    /// keys — the window belongs to the reader, the zoom to these keys.
    @discardableResult
    func fitPageZoom() -> Bool {
        guard isPaged else { return false }
        applyMagnification(Self.defaultPageZoom)
        syncHorizontalScroller()
        return true
    }

    /// Design §2a: while it can, the window tracks the page so the page always fits it exactly; at
    /// the screen's limit it hands over to full screen and further zoom just scrolls the page.
    ///
    /// Guarded on a VISIBLE window: the suite builds controllers with `setFrame` and never orders
    /// them front, and a headless `toggleFullScreen` would be both meaningless and slow. The zoom
    /// itself has already been applied by the time this runs, so a test still observes the whole
    /// behaviour it cares about.
    /// Internal rather than private for the same reason: the opening seed runs on an async turn
    /// and only for a window that was ordered front, so a test has to drive it explicitly.
    func fitWindowToPage() {
        guard let window, window.isVisible, let d = pagedDocumentWidth else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        // The page PLUS a margin either side — the paper sits on a desk, it does not fill the frame.
        let want = d * scrollView.magnification + 2 * Self.pageWindowSideMargin
        let have = scrollView.contentSize.width
        let delta = want - have
        guard abs(delta) > 0.5 else { return }
        let visible = screen.visibleFrame
        let isFullScreen = window.styleMask.contains(.fullScreen)
        let target = window.frame.width + delta
        if target > visible.width {
            if !isFullScreen {
                window.toggleFullScreen(nil)                    // §2a: stop growing, start scrolling
            }
            return
        }
        if isFullScreen {
            window.toggleFullScreen(nil)                        // shrinking back under the limit
            return
        }
        var frame = window.frame
        frame.size.width = max(400, target)
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        window.setFrame(frame, display: true, animate: false)
    }

    /// Office-only (markdown/plain never carry `MDAttr.fillMarginTab`): re-anchors a paragraph's
    /// "fill to margin" tab — a Word Table of Contents entry's page number, most commonly — to
    /// THIS reading column's right edge. The source authored that tab against its own page's
    /// margin, which is unrelated to this reader's window-width column; office TABLES already
    /// track the window this way (`OfficeTextBuilder.appendTable`'s column widths are resolved
    /// against the same column), and this extends the same "fill the window" behaviour to a plain
    /// right-aligned tab stop, which has no size of its own to track anything with. Runs every
    /// time `updateTextInset` does — display, resize, sidebar toggle — so the anchor never lags
    /// the column it targets.
    ///
    /// This mutates ONLY `.paragraphStyle` on already-rendered storage — a display attribute, not
    /// a document edit — so it must never mark the document dirty. It doesn't: dirty tracking here
    /// goes through `MarkdownDocument.applySourceEdit` registering undo actions (see invariant 17
    /// in CLAUDE.md), and this path never touches the undo manager or `applySourceEdit` at all.
    ///
    /// Two passes, not one: collecting `(range, info)` first and applying after avoids mutating
    /// `.paragraphStyle` attributes while `enumerateAttribute` is still walking `.fillMarginTab`
    /// ranges over the same storage.
    private func reanchorFillMarginTabs(toColumn column: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        let width = max(0, column - OfficeTextBuilder.fillMarginTrailingInset)
        var targets: [(NSRange, FillMarginTabInfo)] = []
        storage.enumerateAttribute(MDAttr.fillMarginTab, in: full, options: []) { value, range, _ in
            guard let info = value as? FillMarginTabInfo else { return }
            targets.append((range, info))
        }
        guard !targets.isEmpty else { return }
        for (range, info) in targets {
            guard let base = storage.attribute(.paragraphStyle, at: range.location,
                                                effectiveRange: nil) as? NSParagraphStyle else { continue }
            let p = (base.mutableCopy() as! NSMutableParagraphStyle)
            p.tabStops = OfficeTextBuilder.fillMarginTabStops(info, width: width)
            storage.addAttribute(.paragraphStyle, value: p.copy() as! NSParagraphStyle, range: range)
        }
    }

    /// Re-solves every `NSTextTable` (`GridTextTable`) to THIS reading column's width via
    /// `TableBlockBuilder.resizeTables` — same run cadence as `reanchorFillMarginTabs` above (display,
    /// resize, sidebar toggle, always from `updateTextInset`). A table is built at a placeholder width
    /// (`TableBlockBuilder.initialColumnWidth`); this rewrites each cell block's absolute width from
    /// the stored column proportions for the real column, so it fills and tracks the window. The
    /// change is a display concern only — never the undo manager or `applySourceEdit`, so a read-only
    /// office document doesn't go dirty because its window was resized (office Viewers stay clean).
    private func resizeTableColumns(toColumn column: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        // Re-solve each NSTextTable's cells to ABSOLUTE integer widths for the usable column (container
        // minus a lineFragmentPadding on each side), so columns fill the width and every row's boundary
        // lands on the same integer x. Cheap — it rewrites cell block widths from stored proportions.
        let pad = textView.textContainer?.lineFragmentPadding ?? 5
        TableBlockBuilder.resizeTables(in: storage, toWidth: max(1, column - 2 * pad))
    }

    /// The picture counterpart of `resizeTableColumns`, on the same cadence and for the same reason:
    /// an office graphic holds the share of the reading column that it held of the SOURCE page
    /// (`OfficeTextBuilder.build`'s `graphicScale`), so when the column changes its size must change
    /// with it. Without this, widening the window re-wrapped the text and re-solved every table while
    /// the pictures stayed exactly as large as the width they were built at — the page came apart.
    ///
    /// Sizes are re-derived through `OfficeTextBuilder.graphicSize`, the same function the build uses,
    /// from the AUTHORED size carried in `MDAttr.officeGraphic` — never from the current on-screen
    /// size, which would compound rounding error across a hundred resizes.
    ///
    /// This does NOT weaken invariant 1. That invariant forbids a reserved size that depends on
    /// whether PIXELS are loaded (which makes the scroll bar swing during scrolling); this size is a
    /// pure function of authored size and column, identical whether the image has loaded or not, and
    /// it changes only during a reflow that is re-laying the whole document out anyway. `.image` is
    /// left untouched for real pictures, so a loaded photo is not dropped by a resize; the
    /// chart/SmartArt frame is redrawn because it IS its own pixels (invariant 31).
    private func resizeOfficeGraphics(toColumn column: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0,
              let doc = mdDocument, doc.kind == .office, column > 0 else { return }
        // Collect first — mutating attributes while enumerating them is undefined.
        var work: [(NSRange, NSTextAttachment, OfficeGraphicInfo, CGSize)] = []
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(MDAttr.officeGraphic, in: whole, options: []) { value, range, _ in
            guard let info = value as? OfficeGraphicInfo,
                  let att = storage.attribute(.attachment, at: range.location,
                                              effectiveRange: nil) as? NSTextAttachment else { return }
            // Each graphic carries the width it was measured against (the source page, or the source
            // TABLE for one in a cell), so the reflow divides by exactly what the build divided by —
            // no second decision about the basis, and no lookup that could pick a different one.
            guard let basis = info.basisWidth, basis > 0 else { return }
            // The numerator is the on-screen width of that same container: the reading column, and for
            // a cell graphic the table — which fills the reading column, so it is the column again.
            let scale = column / basis
            // A graphic inside a TABLE CELL is clamped to its cell, never to the ambient reading
            // column — that is what the build does (`appendTable` → `cellContent(imageColumnWidth:)`),
            // and clamping to the full column here would let a cell picture recompute far past its
            // cell and blow the table's fixed column geometry apart (invariant 39). The cell's
            // CURRENT content width is read back from the very block `resizeTableColumns` set one
            // call earlier, so this adds no second copy of the cell-width math.
            let clampWidth: CGFloat = {
                guard let ps = storage.attribute(.paragraphStyle, at: range.location,
                                                 effectiveRange: nil) as? NSParagraphStyle,
                      let block = ps.textBlocks.first as? NSTextTableBlock else { return column }
                let cellWidth = block.contentWidth
                return cellWidth > 1 ? cellWidth : column
            }()
            let target = OfficeTextBuilder.graphicSize(authored: info.authored, graphicScale: scale,
                                                       columnWidth: clampWidth)
            let current = att.bounds.size
            guard abs(target.width - current.width) > 0.5 || abs(target.height - current.height) > 0.5 else { return }
            work.append((range, att, info, target))
        }
        guard !work.isEmpty else { return }
        storage.beginEditing()
        for (range, att, info, target) in work {
            att.bounds = NSRect(origin: .zero, size: target)
            (att.attachmentCell as? SizedAttachmentCell)?.reservedSize = target
            if let label = info.placeholderLabel {
                att.image = OfficeTextBuilder.placeholderImage(label: label, size: target)
            }
            // Invariant 3: a changed attachment is not redrawn (or re-laid-out) by invalidation
            // alone — the storage has to be told its attributes changed.
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }
        storage.endEditing()
    }

    // MARK: - Table of contents (⌥⌘T)

    private var isOutlineVisible = false

    /// Toggle the sidebar. Off for a document with no headings — an empty panel taking a third of
    /// the window teaches the reader that the feature is broken.
    @objc func toggleTableOfContents(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        outline.reload(from: storage)
        guard !outline.entries.isEmpty || isOutlineVisible else { NSSound.beep(); return }
        // Freeze the text column while the sidebar slides. Every animation frame changes the split
        // view's width, and reflowing a long document at 60fps is what made the open/close feel
        // heavy — the text is simply pushed across, then laid out ONCE when the animation lands.
        let anchor = readingAnchor()
        suspendReflow = true
        splitVC.toggleSidebar(sender)
        isOutlineVisible = !sidebarItem.isCollapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            // The panel just took width away from the page — give it back by scaling, not by
            // letting the sheet run off the right edge. Before the reflow, so the column and the
            // sheets are solved once, at the zoom they will actually be read at.
            self.shrinkPageZoomToFit()
            self.reflow(keeping: anchor)          // the line you were reading stays put
            self.reloadOutline()
        }
    }

    /// Rebuild the sidebar's list from the current text. Called from BOTH render paths — a spliced
    /// edit changes headings just as a full re-render does, and only the full one used to say so,
    /// which is why adding a `##` or moving a section left the list stale.
    func reloadOutline() {
        guard let storage = textView.textStorage else { return }
        outline.reload(from: storage)
        // Hide the table-of-contents button entirely for a document with no headings — pressing it
        // there does nothing but beep, so a visible-but-dead control is worse than none. If the panel
        // happened to be open, collapse it too.
        let hasHeadings = !outline.entries.isEmpty
        sidebarButtonHost?.isHidden = !hasHeadings
        // No headings ⇒ no panel, decided by the SPLIT VIEW's actual state rather than by
        // `isOutlineVisible`. That flag only records what the user toggled in THIS window, while the
        // panel can also be open because AppKit restored a sidebar it saved from another window — and
        // gating on the flag then left an empty 180pt panel beside a document with no outline at all
        // (a government form whose section titles live inside table cells, so there is genuinely
        // nothing to list). Re-asserted one run-loop turn later because that restoration can land
        // AFTER this render; both passes are no-ops once it is collapsed.
        if !hasHeadings {
            collapseOutlineIfOpen()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.outline.entries.isEmpty else { return }
                self.collapseOutlineIfOpen()
            }
        }
        if isOutlineVisible { outline.markCurrent(charIndex: textView.selectedRange().location) }
    }

    private func collapseOutlineIfOpen() {
        if !sidebarItem.isCollapsed { sidebarItem.isCollapsed = true }
        isOutlineVisible = false
    }

    /// Clicking a heading in the sidebar moves the READING CURSOR there, not just the scroll
    /// position. The cursor is where every block action starts from, so leaving it behind would
    /// mean the sidebar takes you to a section that `E` or `J` then doesn't act on.
    private func goToOutlineEntry(_ charIndex: Int) {
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        scrollCharToTop(charIndex)
        window?.makeFirstResponder(textView)
    }

    // MARK: - Comments panel (P6b, ⌥⌘C)

    private var isCommentsVisible = false

    /// Toggle the right-side comments panel. Off for a document with no comments — same reasoning
    /// `toggleTableOfContents` gives for an empty outline (a panel taking a fifth of the window that
    /// teaches the reader the feature is broken).
    @objc func toggleComments(_ sender: Any?) {
        guard let doc = mdDocument else { return }
        reloadCommentPanel()
        guard !doc.officeComments.isEmpty || isCommentsVisible else { NSSound.beep(); return }
        // Same freeze-during-slide treatment the outline toggle uses (see its own comment): the
        // text column doesn't change width here — only the trailing inspector does — but reflow is
        // still suspended so a resize-triggered relayout can't race the split animation.
        let anchor = readingAnchor()
        suspendReflow = true
        commentsItem.animator().isCollapsed.toggle()
        isCommentsVisible = !commentsItem.isCollapsed
        textView.commentsVisible = isCommentsVisible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.shrinkPageZoomToFit()   // the inspector takes width too — same rule as the sidebar
            self.reflow(keeping: anchor)
            self.reloadCommentPanel()
        }
    }

    /// Rebuild the panel's list from the current document — called from every place that renders
    /// (both `display(_:)` and the splice-edit path), the same "both render paths" discipline
    /// `reloadOutline()` follows (invariant 23), so the panel never shows a stale list.
    func reloadCommentPanel() {
        guard let doc = mdDocument else { commentPanel.reload(from: []); return }
        commentPanel.reload(from: doc.officeComments)
    }

    /// Clicking a comment row scrolls the body to that comment's first anchored span — found by
    /// scanning `MDAttr.commentMark` for the matching NUMBER, the same attribute the draw pass
    /// reads. A comment the body never anchors (see `OfficeComment.number`'s doc) has no range to
    /// find; nothing happens, same as a dead cross-reference (`AnchorResolver`'s own posture).
    private func goToComment(number: Int) {
        guard let storage = textView.textStorage else { return }
        var found: Int?
        storage.enumerateAttribute(MDAttr.commentMark, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let numbers = value as? [Int], numbers.contains(number) else { return }
            found = range.location
            stop.pointee = true
        }
        guard let charIndex = found else { return }
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        scrollCharToTop(charIndex)
    }

    // MARK: Toolbar (the sidebar button)

    private func sidebarButtonView() -> NSView {
        let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left",
                                             accessibilityDescription: "Table of contents")!,
                              target: self, action: #selector(toggleTableOfContents(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = "Show or hide the table of contents (T)"
        button.translatesAutoresizingMaskIntoConstraints = false
        // Centred by CONSTRAINT, not by a hand-picked frame: the title bar's height isn't ours to
        // predict (it changes with the system and with tabs), and a guessed y sits a pixel or two
        // off — which is precisely what it looked like.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        sidebarButtonHost = host
        return host
    }

    // MARK: R5 — read-only badge + edit-in-app button

    private func officeAccessoryView() -> NSView {
        // "read only" chip. The label sits in a CONTAINER that carries the background/rounding, with
        // the text centred by centerX/centerY constraints — an NSTextField with its own layer
        // background renders its text toward the TOP of a fixed-height box, which is the "위로 쏠림"
        // skew; centring the label inside a plain container puts it dead centre regardless.
        officeBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        officeBadge.textColor = .white
        officeBadge.alignment = .center
        officeBadge.translatesAutoresizingMaskIntoConstraints = false
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.systemRed.cgColor
        chip.layer?.cornerRadius = 8.5              // pill: half the chip height (round style)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(officeBadge)

        // "Edit" button: the target editor's own icon + a short "Edit" (full "Edit in <App>" is the
        // tooltip). Icon + label set in `updateOfficeAccessory`, which knows the current document.
        editButton.bezelStyle = .texturedRounded
        editButton.imagePosition = .imageLeading
        editButton.imageScaling = .scaleProportionallyDown
        editButton.target = self
        editButton.action = #selector(editButtonClicked(_:))
        editButton.translatesAutoresizingMaskIntoConstraints = false

        // The "more editors" button is an ellipsis (…), not a downward chevron.
        editMenuButton.bezelStyle = .texturedRounded
        editMenuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More editors")
        editMenuButton.imagePosition = .imageOnly
        editMenuButton.target = self
        editMenuButton.action = #selector(showEditMenu(_:))
        editMenuButton.translatesAutoresizingMaskIntoConstraints = false

        // Chip hugs the title (leading inset 2, the smallest gap that still clears the title glyphs);
        // the Edit button hugs its short "Edit" label (no wide fixed width now that "Edit in <App>"
        // moved to the tooltip); the whole host width is driven by the content, not a fixed 220 that
        // left a trailing gap.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 28))
        host.isHidden = true   // shown only once `updateOfficeAccessory` sees an office document
        host.addSubview(chip)
        host.addSubview(editButton)
        host.addSubview(editMenuButton)
        editButton.setContentHuggingPriority(.required, for: .horizontal)
        editButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            officeBadge.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
            officeBadge.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
            officeBadge.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            chip.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
            chip.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 17),

            editButton.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 8),
            editButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            editButton.heightAnchor.constraint(equalToConstant: 22),

            editMenuButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 2),
            editMenuButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            editMenuButton.widthAnchor.constraint(equalToConstant: 26),
            editMenuButton.heightAnchor.constraint(equalToConstant: 22),
            editMenuButton.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -6),
        ])
        officeAccessoryHost = host
        return host
    }

    /// The target editor's icon at button size, or a generic pencil when no app is remembered yet.
    private func editButtonIcon(for app: ExternalEditor.AppCandidate?) -> NSImage? {
        let img: NSImage
        if let app { img = NSWorkspace.shared.icon(forFile: app.url.path) }
        else if let pencil = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Edit") { img = pencil }
        else { return nil }
        img.size = NSSize(width: 15, height: 15)
        return img
    }

    /// Called from every render pass (`display(_:)`), same as `reloadOutline()` — the badge/button
    /// must reflect the CURRENT document, not whatever was open when the window was built.
    private func updateOfficeAccessory() {
        guard let doc = mdDocument, doc.kind == .office else {
            officeAccessoryHost.isHidden = true
            return
        }
        officeAccessoryHost.isHidden = false
        let ext = doc.fileURL?.pathExtension.lowercased() ?? ""
        applyEditButton(externalEditorService.rememberedCandidate(forExtension: ext))
    }

    /// Short "Edit" title + the target editor's icon; the full "Edit in <App>" rides in the tooltip.
    private func applyEditButton(_ app: ExternalEditor.AppCandidate?) {
        editButton.title = "Edit"
        editButton.image = editButtonIcon(for: app)
        editButton.toolTip = ExternalEditor.editLabel(for: app)
    }

    /// Body click (S7-6/S7-7): open directly if an app is remembered; otherwise there is nothing to
    /// launch yet, so fall through to the same picker the arrow shows.
    @objc private func editButtonClicked(_ sender: Any?) {
        guard let (doc, ext) = officeDocumentContext() else { return }
        if let app = externalEditorService.rememberedCandidate(forExtension: ext) {
            openExternally(doc, with: app)
        } else {
            presentEditMenu(forExtension: ext, anchor: editButton)
        }
    }

    @objc private func showEditMenu(_ sender: Any?) {
        guard let (_, ext) = officeDocumentContext() else { return }
        presentEditMenu(forExtension: ext, anchor: editMenuButton)
    }

    private func officeDocumentContext() -> (MarkdownDocument, String)? {
        guard let doc = mdDocument, doc.kind == .office,
              let url = doc.fileURL else { return nil }
        return (doc, url.pathExtension.lowercased())
    }

    /// The arrow's menu: every candidate app (S7-3 already excludes us), a checkmark on whichever
    /// one is currently remembered, then `Choose other app…`.
    private func presentEditMenu(forExtension ext: String, anchor: NSView) {
        let remembered = externalEditorService.rememberedCandidate(forExtension: ext)
        let menu = NSMenu()
        for app in externalEditorService.candidates(forExtension: ext) {
            let item = NSMenuItem(title: app.displayName,
                                  action: #selector(chooseCandidateFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            item.state = (app.bundleIdentifier == remembered?.bundleIdentifier) ? .on : .off
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Choose Other App…",
                               action: #selector(chooseOtherApp(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func chooseCandidateFromMenu(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? ExternalEditor.AppCandidate,
              let (doc, ext) = officeDocumentContext() else { return }
        externalEditorService.remember(app, forExtension: ext)
        applyEditButton(app)
        openExternally(doc, with: app)
    }

    /// S7-6: `Choose other app…` — an `NSOpenPanel` restricted to `/Applications`. The user's own
    /// selection grants access to that app regardless of what the sandbox otherwise allows.
    @objc private func chooseOtherApp(_ sender: Any?) {
        guard let (doc, ext) = officeDocumentContext() else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let appURL = panel.url,
              let app = externalEditorService.appCandidate(from: appURL) else { return }
        externalEditorService.remember(app, forExtension: ext)
        applyEditButton(app)
        openExternally(doc, with: app)
    }

    /// S7-8/S7-9: hand the document to the chosen app. The sandbox hand-off itself was NOT
    /// verified here — see the sprint report — so a failure surfaces as an alert rather than
    /// being swallowed.
    private func openExternally(_ doc: MarkdownDocument, with app: ExternalEditor.AppCandidate) {
        guard let url = doc.fileURL else { return }
        externalEditorService.open(url, with: app) { [weak self] error in
            guard let error, let window = self?.window else { return }
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Couldn't open \(app.displayName)"
            a.informativeText = error.localizedDescription
            a.beginSheetModal(for: window)
        }
    }

    /// Grey the menu item out where a table of contents would be empty, rather than opening an empty
    /// panel and leaving the reader to work out why.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTableOfContents(_:)) {
            item.title = isOutlineVisible ? "Hide Table of Contents" : "Table of Contents"
            return canShowTableOfContents
        }
        if item.action == #selector(toggleComments(_:)) {
            item.title = isCommentsVisible ? "Hide Comments" : "Comments"
            return canShowComments
        }
        // ⌘1…⌘9 — greyed out for a tab that isn't open, so ⌘5 with three documents open does
        // nothing visible rather than silently jumping to the third.
        if item.action == #selector(goToTab(_:)) {
            let count = tabbedWindows.count
            guard count > 1 else { return false }          // a lone window has nothing to jump to
            return item.tag == 9 ? true : item.tag <= count
        }
        // The three page options. Enabled only for a document that HAS paper — markdown, plain text
        // and an office document whose reader found no page width have nothing to show or hide, and
        // the gate is `isPaged`, never `kind == .office` (invariant 57). Checked rather than retitled:
        // these are three independent states a reader wants to SEE at a glance, which a "Hide …"
        // title cannot express for three items at once.
        //
        // The OUTLINE is the master (`PageViewOptions.underOutlineRule`): a header and footer live in
        // a page's own margins and a table is only broken at a page boundary, so with the outline off
        // the other three are greyed out rather than left tickable with nothing to act on. Their ticks
        // come from the stored INTENT, so switching the outline back on restores what was chosen.
        if item.action == #selector(toggleMarginNumbers(_:)) {
            item.state = MarginNumberStore.isOn ? .on : .off
            // Retitled per document because the UNIT is the document's, not the reader's: "Line
            // Numbers" on a file with no pages would be a lie the moment it drew page numbers, and
            // two separate toggles could be set to disagree with each other.
            let showsPages = MarginNumberStore.unit(isOn: true, paged: isPaged,
                                                    drawingPages: PageViewOptionsStore.current.outline)
            item.title = showsPages == .pages ? "Page Numbers" : "Line Numbers"
            return true
        }
        // The jump is retitled by the SAME rule, and stays enabled with the numbers switched off —
        // a reader who hid them can still ask to go to page 40.
        if item.action == #selector(goToNumber(_:)) {
            item.title = jumpUnit == .pages ? "Go to Page…" : "Go to Line…"
            return true
        }
        let intent = PageViewOptionsStore.intent
        for (selector, on, needsOutline) in
                [(#selector(togglePageOutline(_:)), intent.outline, false),
                 (#selector(toggleMasterPage(_:)), intent.masterPage, true),
                 (#selector(toggleSplitTables(_:)), intent.splitTables, true)]
        where item.action == selector {
            item.state = on ? .on : .off
            return isPaged && (!needsOutline || intent.outline)
        }
        return true
    }

    /// Enabled only where the panel means something: an office document that actually has
    /// comments. (Once open it stays enabled/toggle-able even if a later reload finds zero — same
    /// posture `guard !doc.officeComments.isEmpty || isCommentsVisible` already takes in the toggle
    /// itself, so the menu and the action never disagree about whether closing is allowed.)
    var canShowComments: Bool {
        guard let doc = mdDocument else { return false }
        return !doc.officeComments.isEmpty || isCommentsVisible
    }

    /// Enabled only where a table of contents means something: markdown, with headings in it.
    var canShowTableOfContents: Bool {
        guard let doc = mdDocument, !doc.isPlainText,
              let storage = textView.textStorage else { return false }
        var any = false
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, _, stop in
            if v != nil { any = true; stop.pointee = true }
        }
        return any
    }

    /// Keep the sidebar's highlight on the section the CURSOR is in — not the one that happens to
    /// be scrolled into view. The cursor is what the reader placed deliberately and what every
    /// block action works from, so the two halves of the window agree about where "here" is.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard isOutlineVisible else { return }
        outline.markCurrent(charIndex: textView.selectedRange().location)
    }

    func display(_ attributed: NSAttributedString) {
        // Once per RENDER, not per reflow: the unit only changes when the document does (a new file,
        // a re-render) or when the reader toggles something — never when a column is re-solved. It
        // was briefly called from `settleReadingColumn`, which is the hot path every resize and every
        // zoom press runs through, and writing a property that repaints from inside a layout settle
        // is how a redraw storm starts on a large document.
        applyMarginNumbers()
        // Geometry only: the storage is replaced on the very next line, so the full pass here would
        // re-solve the outgoing document's tabs and tables for nothing (see `settleReadingColumn`).
        // The async `updateTextInset()` below runs the real one, against the string just installed.
        settleReadingColumn()
        // Clear any TRAILING footer-band reservation the PREVIOUS document may have left behind
        // (`applyTrailingFooterBand`) — `NSLayoutManager.setExtraLineFragmentRect` is layout-manager-
        // level state that a plain `setAttributedString` does NOT reset on its own (confirmed by the
        // same spike `applyTrailingFooterBand` records: calling `ensureLayout` again leaves a
        // manually-set override in place), so a document with no footer opened right after one that
        // HAD one would otherwise inherit a stale blank gap at its own bottom until the new
        // document's own walk got around to correcting it. `precomputeLayout`'s completion re-adds
        // the correct amount moments later for whichever new document actually has one.
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.setExtraLineFragmentRect(.zero, usedRect: .zero, textContainer: tc)
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.recomputeHeadingOffsets()
        reloadOutline()
        reloadCommentPanel()
        updateOfficeAccessory()
        textView.resetCaret()
        window?.makeFirstResponder(textView)
        // Re-apply the column and place buttons after layout has established real sizes.
        DispatchQueue.main.async { [weak self] in
            self?.updateTextInset()
            self?.placeCopyButtons()
        }
    }

    /// The live text storage, so the document layer can swap mermaid placeholders in place.
    var textStorageRef: NSTextStorage? { textView.textStorage }

    /// Redraw just the glyphs for a character range WITHOUT invalidating layout — used when a media
    /// attachment's IMAGE toggles (load/purge) but its reserved size (owned by SizedAttachmentCell)
    /// is unchanged. Touching layout here would resize the frame from a partial usedRect mid-scroll
    /// (the scroll-bar jitter); this only repaints, so the frame/scroll bar never move.
    func redrawGlyphs(_ r: NSRange) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: gr, in: tc)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        textView.setNeedsDisplay(rect)
    }

    // MARK: - Zoom anchor (keep the top visible line stable across a font-size change)

    private var layoutToken = 0

    /// How many run-loop turns the LAST `precomputeLayout` walk used. Wall clock on this machine
    /// swings up to 3× under load (`OfficeRenderLatencyTests`' header records a 2825 ms outlier that
    /// never reproduced), so how finely the walk is sliced is judged by this counter — which is
    /// deterministic — rather than by a stopwatch.
    private(set) var layoutStepCount = 0

    /// A reading position waiting for the document to be FULLY laid out again — set by
    /// `reapplyPageBand`, applied by whichever `precomputeLayout` walk reaches the end.
    ///
    /// Not a completion closure, and that is the point. `precomputeLayout` cancels an in-flight walk
    /// whenever a NEW one starts (`layoutToken`), and a cancelled walk's completion never runs — so a
    /// toggle whose walk was superseded by the render's own opening tail silently lost the reader's
    /// place, landing them at character 0 from 75% down. Measured exactly that way while building
    /// this. Parking the anchor here instead means the LATER, more authoritative walk applies it, so
    /// supersession stops being a lost restore and becomes simply a later one.
    private var pendingAnchor: ReadingAnchor?

    /// Lay out the ENTIRE document up front (media are placeholders, so this is cheap — no images
    /// are rasterized) so the scroll bar reflects the full length immediately: the reader sees how
    /// much content there is without scrolling. Done in small chunks across run-loop turns to keep
    /// the UI responsive; aborts if the document changes.
    /// `then` runs ONLY when the walk reached the end of the document it started on, with its token
    /// intact — i.e. no later render superseded it and nothing edited the storage underneath it. A
    /// caller that splices content in (see `MarkdownDocument.spliceDeferredTables`) needs exactly
    /// that guarantee: it must not mutate a string a walk is still crawling, and it must not fire at
    /// all if the render it belongs to has already been replaced.
    ///
    /// Every completion path below also reserves the TRAILING footer band first
    /// (`applyTrailingFooterBand`) — this IS the "whole document actually laid out" guarantee that
    /// method's own doc requires, and funnelling every caller (the ordinary open/reflow path, AND
    /// `MarkdownDocument.spliceDeferredTables.finish()`'s own second walk) through this one function
    /// is what makes that true regardless of which of them asked.
    func precomputeLayout(then: (() -> Void)? = nil) {
        layoutToken += 1
        let token = layoutToken
        layoutStepCount = 0
        guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        let total = storage.length
        func finishWalk() {
            // The document is now fully laid out, which is the ONLY moment its tables can be measured
            // — so this is where "no table may print in the margin" is decided. If one has to move,
            // the whole walk runs again with that recorded; `settlePagedTables`' own doc explains why
            // it cannot be decided while the first pass is still typesetting.
            if pagedTableSettles < maxPagedTableSettles, settlePagedTables() {
                pagedTableSettles += 1
                precomputeLayout(then: then)
                return
            }
            pagedTableSettles = 0
            applyTrailingFooterBand()
            // Whichever walk gets to the end applies a pending anchor — see `pendingAnchor`.
            if let anchor = pendingAnchor {
                pendingAnchor = nil
                sizeTextViewToFit()
                restore(anchor)
                textView.needsDisplay = true
            }
            then?()
        }
        if total == 0 { finishWalk(); return }
        // MEASURED TWICE, don't re-derive. A flat CHARACTER count looks like the wrong bound here:
        // characters are a cost proxy that misreads office documents (the same proxy failure
        // `runBusy` documents at the top of this file), so a 38-table report of 20k characters is
        // laid out ENTIRELY in one uninterruptible turn while a 1.2 MB markdown file gets sixty.
        // Both obvious repairs were built and measured on real documents, and both were reverted:
        //
        //  1. Slice by TIME (2k characters per pass until a 10 ms budget runs out). On a 62-table
        //     HWP the worst main-thread freeze did not improve (216 ms → 194–238 ms) and the time to
        //     a fully laid-out document roughly doubled (665 ms → 1126–1342 ms).
        //  2. Bound each step by STRUCTURE as well as length — stop after N table-cell paragraphs or
        //     attachments, whichever came first — plus laying the VIEWPORT out before walking from 0
        //     so the visible page is interactive immediately. On a 38-table / 27-image docx (20 576
        //     characters, 610 cell paragraphs), against a baseline of 2 turns / 105–121 ms measured
        //     six times: viewport-first alone 2 turns / 121–148 ms; +structural cap 256 → 3 turns /
        //     155–170 ms; +structural cap 64 → 10 turns / 186–192 ms. Monotone in turn count, every
        //     variant worse, and the worst freeze never improved in any of them.
        //
        // Both failed for the SAME reason, which is the thing worth keeping: the freeze is not this
        // pass. It is the REBUILD (`OfficeTextBuilder.build` + `display`), so slicing layout finer
        // cannot shorten it — it only adds per-turn cost. And time-to-INTERACTIVE, the one thing
        // (2) was meant to buy that (1) had not tested, turns out to be already paid: measured at
        // the instant `precomputeLayout` returns, 451 of the 452 visible characters were ALREADY
        // laid out, before this function ran at all. The reader can see and select the visible page
        // from the start; what this walk buys is the complete SCROLL BAR, not the visible page.
        // `OfficeRenderLatencyTests` is the instrument (its Stage 3b prints both counters) and also
        // pins the character bound, so a third attempt has to measure rather than argue.
        let chunk = 20_000
        func step(_ loc: Int) {
            guard token == self.layoutToken, self.textView.textStorage?.length == total else { return }
            guard loc < total else { finishWalk(); return }
            self.layoutStepCount += 1
            let end = min(loc + chunk, total)
            lm.ensureLayout(forCharacterRange: NSRange(location: loc, length: end - loc))
            if end < total { DispatchQueue.main.async { step(end) } } else { finishWalk() }
        }
        DispatchQueue.main.async { step(0) }
    }

    /// Every table in the CURRENT layout, as `PagePagination.tablesToPush` needs to see it.
    ///
    /// Walked from the line fragments rather than from the text blocks, because what decides this is
    /// where the rows actually LANDED. Contiguous lines sharing one `NSTextTable` are one table: the
    /// cells of a table are contiguous in text order (`TableBlockBuilder` writes them that way), so a
    /// change of table identity is a change of table. `visualTop` is the smallest line top in the run
    /// and NOT the first line's, which a vertically merged cell can push down (see `LaidOutTable`).
    private func laidOutTables() -> [PagePagination.LaidOutTable] {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return [] }
        // Per table, per ROW: where its lines landed, and which rows a page may start on. Kept as
        // running state while the one line-fragment walk goes past, because the walk is the only place
        // where "where did this land" and "which cell is it" are both cheap to know.
        struct Row { var firstChar: Int; var top: CGFloat; var bottom: CGFloat; var firstLineTop: CGFloat }
        var rows: [Int: Row] = [:]              // startingRow → geometry
        var spans: [(start: Int, end: Int)] = []  // every merged cell's row range, half-open
        var out: [PagePagination.LaidOutTable] = []
        var current: ObjectIdentifier?

        func flushRows() {
            guard !out.isEmpty, !rows.isEmpty else { rows = [:]; spans = []; return }
            out[out.count - 1].rows = rows.keys.sorted().map { r in
                let row = rows[r]!
                // Safe unless some cell that STARTED above this row is still open across it.
                let crossed = spans.contains { $0.start < r && $0.end > r }
                // The inset must be measured where it will be USED — against the position the
                // typesetter PROPOSES for that line, not the one a vertically aligned cell ends up
                // drawn at. See `PageBandLayoutDelegate.proposedTableLineTops`.
                let firstLineTop = pageBandDelegate.proposedTableLineTops[row.firstChar] ?? row.firstLineTop
                return PagePagination.LaidOutRow(firstChar: row.firstChar, top: row.top,
                                                 bottom: row.bottom, firstLineTop: firstLineTop,
                                                 canBreakAbove: !crossed)
            }
            rows = [:]; spans = []
        }

        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, glyphRange, _ in
            let cr = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var block: NSTextTableBlock?
            if cr.location >= 0, cr.location < storage.length,
               let style = storage.attribute(.paragraphStyle, at: cr.location,
                                             effectiveRange: nil) as? NSParagraphStyle {
                block = style.textBlocks.first as? NSTextTableBlock
            }
            guard let block else { flushRows(); current = nil; return }
            // A LINE FRAGMENT IS NOT THE CELL. Its own padding and border are drawn OUTSIDE the
            // glyphs, so measuring a row by its lines alone under-reports every row by the amount the
            // cell adds around them — measured on a real report at 3.48pt per cell, which is ~70pt
            // across a twenty-row group and is exactly why a piece the arithmetic said would fit
            // still ended in a margin. Applied to every line rather than only the first and last:
            // an interior line's inset value loses to the `min`/`max` anyway, so this needs no
            // separate "is this the block's first line" bookkeeping to be right.
            let top = rect.minY - block.width(for: .padding, edge: .minY)
                - block.width(for: .border, edge: .minY)
            let bottom = rect.maxY + block.width(for: .padding, edge: .maxY)
                + block.width(for: .border, edge: .maxY)
            let table = ObjectIdentifier(block.table)
            if current != table {
                flushRows()
                current = table
                out.append(PagePagination.LaidOutTable(
                    firstChar: cr.location, visualTop: top, bottom: bottom,
                    firstLineTop: self.pageBandDelegate.proposedTableLineTops[cr.location] ?? rect.minY,
                    lastChar: cr.location + cr.length))
            } else {
                out[out.count - 1].visualTop = min(out[out.count - 1].visualTop, top)
                out[out.count - 1].bottom = max(out[out.count - 1].bottom, bottom)
                out[out.count - 1].lastChar = max(out[out.count - 1].lastChar, cr.location + cr.length)
            }
            if block.rowSpan > 1 {
                spans.append((block.startingRow, block.startingRow + block.rowSpan))
            }
            let r = block.startingRow
            if var existing = rows[r] {
                existing.top = min(existing.top, top)
                existing.bottom = max(existing.bottom, bottom)
                existing.firstChar = min(existing.firstChar, cr.location)
                if cr.location <= existing.firstChar { existing.firstLineTop = rect.minY }
                rows[r] = existing
            } else {
                rows[r] = Row(firstChar: cr.location, top: top, bottom: bottom,
                              firstLineTop: rect.minY)
            }
        }
        flushRows()
        return out
    }

    /// A cell inside a piece that gets BROKEN across pages must sit at the top of its row, whatever
    /// vertical alignment the document asked for.
    ///
    /// Measured on `사업계획서_13-15p_수정안.docx`: the left-hand label `유사 특허 / 분석 정확도` is centred
    /// in its row, and once that row is broken the row spans the page gap — so its middle IS the gap,
    /// and the two label lines were drawn at 786.1…804.7 inside an empty band running 784.5…910.6,
    /// i.e. floating on the desk between two sheets. Word centres such a label within the part of the
    /// row that is on each page; this reader cannot ask AppKit for that, and the top of the row is
    /// the honest approximation — it is where the label's own row begins.
    ///
    /// Applied to the BLOCKS, once the settle knows which pieces will be broken, which is the only
    /// moment that is knowable. Setting it again on a later round costs nothing and changes nothing.
    private func topAlignCellsOf(_ pieces: [Int: Int], in storage: NSTextStorage) {
        guard !pieces.isEmpty else { return }
        for (start, end) in pieces {
            let range = NSRange(location: start, length: max(0, min(end, storage.length) - start))
            guard range.length > 0 else { continue }
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, _, _ in
                guard let style = value as? NSParagraphStyle else { return }
                for block in style.textBlocks where block.verticalAlignment != .topAlignment {
                    block.verticalAlignment = .topAlignment
                }
            }
        }
    }

    /// The first line of every run of THREE OR FEWER lines that a break would strand at the bottom of
    /// a page — the owner's *"1~3줄 애매할 땐 다음 페이지로, 4줄 이상이면 그 자리에서"*. Measured from the
    /// completed layout, because "how many of this piece's lines are on this page" is not a question
    /// the typesetter can be asked while it is placing them.
    ///
    /// Only pieces that are broken WHERE THEY STAND can have such a run: everything else is carried
    /// whole and never crosses a boundary at all. A run that already starts a page is skipped — it is
    /// not stranded, it is the continuation, and marking it would ask for a shift the rule has
    /// already made (the settle would never converge).
    private func orphanRunStarts(in pieces: [Int: Int]) -> Set<Int> {
        guard !pieces.isEmpty, let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage else { return [] }
        let d = pageBandDelegate
        let pitch = d.pageContentHeight + d.band
        guard pitch > 0 else { return [] }
        // Per piece, per page: the lines of that piece which landed on it, in order.
        var runs: [String: [(location: Int, top: CGFloat)]] = [:]
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, glyphRange, _ in
            let cr = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard cr.location < storage.length,
                  let piece = pieces.first(where: { cr.location >= $0.key && cr.location < $0.value })
            else { return }
            let page = Int(((rect.minY - d.leadingBand) / pitch).rounded(.down))
            runs["\(piece.key):\(page)", default: []].append((cr.location, rect.minY))
        }
        var out: Set<Int> = []
        for (key, lines) in runs where lines.count <= 3 {
            guard let page = Int(key.split(separator: ":").last ?? ""), page >= 0,
                  let first = lines.min(by: { $0.location < $1.location }) else { continue }
            // Already at this page's own top: it is the continuation, not a stranded run.
            let pageTop = CGFloat(page) * pitch + d.leadingBand
            guard first.top - pageTop > 0.5 else { continue }
            // And the piece must actually continue past this page, or there is nothing to join it to.
            guard runs["\(key.split(separator: ":").first ?? ""):\(page + 1)"] != nil else { continue }
            out.insert(first.location)
        }
        return out
    }

    /// ONE round of "no table may print in the margin": measure the tables this layout produced, and
    /// if any of them has to move, record it and invalidate so the next layout puts it on the next
    /// page. Returns whether anything changed — i.e. whether the document must be laid out again.
    ///
    /// **Why this needs a completed layout at all.** The rule that moves a table needs the table's
    /// HEIGHT, and at the moment the typesetter asks about its first line nothing has measured it yet.
    /// So the reader lays out, looks at what it got, and re-solves — measure, then place. The cost is
    /// one extra pass through `precomputeLayout`'s own chunked walk, paid only by a document that
    /// actually has a table to move (the reference report: 4 of 16 tables; a full re-layout of it
    /// measured 38ms, and it is chunked, so no single turn grows).
    ///
    /// **Why the whole document is invalidated rather than the tail from the moved table.** Moving a
    /// table changes which page boundaries LAYOUT opened, and `openedBoundaries` is what the painter
    /// and the page outline read. Keeping the earlier half of that record while re-deriving the rest
    /// would leave the two halves describing different layouts; re-deriving all of it is one honest
    /// pass, and the measurement above says it is affordable.
    @discardableResult
    func settlePagedTables() -> Bool {
        guard pageBandDelegate.isActive, let lm = textView.layoutManager,
              let storage = textView.textStorage, storage.length > 0 else { return false }
        let tables = laidOutTables()
        guard !tables.isEmpty else { return false }
        let next = PagePagination.tablesToPush(tables,
                                               pageContentHeight: pageBandDelegate.pageContentHeight,
                                               band: pageBandDelegate.band,
                                               leadingBand: pageBandDelegate.leadingBand,
                                               splitTables: PageViewOptionsStore.current.splitTables,
                                               alreadyPushed: pageBandDelegate.pushedTables)
        let oversized = PagePagination.oversizedPieces(tables,
                                                       pageContentHeight: pageBandDelegate.pageContentHeight,
                                                       alreadyOversized: pageBandDelegate.oversizedPieces)
        let orphans = pageBandDelegate.pullToNextPage
            .union(orphanRunStarts(in: oversized))
        guard next != pageBandDelegate.pushedTables
                || oversized != pageBandDelegate.oversizedPieces
                || orphans != pageBandDelegate.pullToNextPage else { return false }
        pageBandDelegate.pushedTables = next
        pageBandDelegate.oversizedPieces = oversized
        pageBandDelegate.pullToNextPage = orphans
        topAlignCellsOf(oversized, in: storage)
        pageBandDelegate.resetOpenedBoundaries()
        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                            actualCharacterRange: nil)
        return true
    }

    /// The SYNCHRONOUS twin, for a caller that cannot wait for `precomputeLayout`'s chunked walk —
    /// printing, which must not put a table row in a margin just because the asynchronous settle had
    /// not finished yet. Bounded for the same reason the asynchronous one is (see `pagedTableSettles`).
    func settlePagedTablesFully() {
        guard pageBandDelegate.isActive, let lm = textView.layoutManager,
              let tc = textView.textContainer else { return }
        for _ in 0..<maxPagedTableSettles {
            lm.ensureLayout(for: tc)
            if !settlePagedTables() { return }
        }
        lm.ensureLayout(for: tc)
    }

    /// How many times ONE render may re-solve its tables. Each round moves at least one table and a
    /// table is only ever moved once (the rule that moves it declines to move it again once it sits at
    /// a page top), so this terminates on its own — the cap is a backstop against a future change
    /// breaking that, not the mechanism.
    private let maxPagedTableSettles = 8
    private var pagedTableSettles = 0

    /// Visible character range grown by `margin` screenfuls above and below — the region whose
    /// images/diagrams should stay loaded. (Also lays that region out, which smooths scrolling.)
    func visibleCharRange(margin: CGFloat) -> NSRange {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let rect = textView.visibleRect.insetBy(dx: 0, dy: -textView.visibleRect.height * margin)
        let gr = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
    }

    /// What the reader is looking at, as a character plus where on screen it sat. Restoring BOTH is
    /// what makes a reflow invisible: keeping only the character would jump that line to the top of
    /// the window, and keeping only the offset would land on different text once the wrapping
    /// changed.
    struct ReadingAnchor {
        let char: Int
        /// Distance from the top of the viewport to that line, in points.
        let offsetFromTop: CGFloat
    }

    /// The cursor if it is on screen, otherwise whatever sits at the middle of the viewport.
    ///
    /// The cursor wins because it is the one place the reader put deliberately — it is where every
    /// block action happens, and watching it slide away while the window resizes is the thing that
    /// feels wrong. With no cursor in sight the centre of the page is the honest stand-in: anchoring
    /// on the top line lets everything below it drift, which is most of what you are reading.
    func readingAnchor() -> ReadingAnchor {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0, lm.numberOfGlyphs > 0 else {
            return ReadingAnchor(char: 0, offsetFromTop: 0)
        }
        let visible = textView.visibleRect
        let inset = textView.textContainerInset
        func lineTop(_ char: Int) -> CGFloat {
            let glyph = min(lm.glyphIndexForCharacter(at: char), lm.numberOfGlyphs - 1)
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + inset.height
        }
        // Two cases, two meanings. The CURSOR is an exact spot the reader put there, so it anchors
        // on its own line and comes back to the same height. With no cursor in view there is no such
        // spot: take whatever character sits dead centre of the page and put it back dead centre.
        // Centre is the right target because a reflow changes how much fits above and below — hold
        // the middle and the drift is split evenly instead of piling up on one side.
        let caret = min(textView.selectedRange().location, storage.length - 1)
        let caretTop = lineTop(caret)
        if caretTop >= visible.minY, caretTop <= visible.maxY {
            return ReadingAnchor(char: caret, offsetFromTop: caretTop - visible.minY)
        }
        let centrePoint = NSPoint(x: tc.size.width / 2, y: visible.midY - inset.height)
        let centre = min(lm.characterIndexForGlyph(at: lm.glyphIndex(for: centrePoint, in: tc)),
                         storage.length - 1)
        return ReadingAnchor(char: centre, offsetFromTop: visible.height / 2)
    }

    /// Put an anchor back where it was on screen.
    func restore(_ anchor: ReadingAnchor) {
        // Ask for the glyph we WANT before asking how many exist. The old `numberOfGlyphs > 0`
        // pre-guard made this a silent no-op whenever nothing had been laid out yet — the reader
        // stayed wherever `display` left them, which is the top. It only ever passed because the
        // storage swap happened with the clip parked deep in the outgoing document and AppKit laid
        // the incoming one out that far to satisfy the offset; the moment that accident is removed
        // (or the window simply has not drawn yet) every restore returns doing nothing. Measured: a
        // reader 75% down landed at character 282.
        guard let lm = textView.layoutManager, let storage = textView.textStorage,
              storage.length > 0 else { return }
        let char = min(max(0, anchor.char), max(0, storage.length - 1))
        let requested = lm.glyphIndexForCharacter(at: char)
        guard lm.numberOfGlyphs > 0 else { return }
        let glyph = min(requested, lm.numberOfGlyphs - 1)
        let lineTop = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + textView.textContainerInset.height
        var y = lineTop - anchor.offsetFromTop
        // Keep the page's top margin — AND, when this document reserved a leading header band
        // (`PageBandLayoutDelegate.leadingBand`, header-footer-design.md build step 4's outer edge),
        // keep that visible too: `lineTop` for the very first line already sits at
        // `inset.height + leadingBand` (the delegate baked the shift into the line's own rect before
        // this ever reads it), so without adding `leadingBand` here this guard would stop firing the
        // moment a header is reserved, landing the reader just past the band with the header
        // scrolled out of sight instead of at the true top. `leadingBand` is 0 for every document
        // without a leading header — including every markdown/plain-text one — so this reduces
        // identically to the original check there.
        if y <= textView.textContainerInset.height + pageBandDelegate.leadingBand { y = 0 }
        let clip = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, y), maxY)))   // see `scrollCharToTop`
        scrollView.reflectScrolledClipView(clip)
    }

    /// The character index currently at the top of the visible area.
    func topVisibleCharIndex() -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              lm.numberOfGlyphs > 0 else { return 0 }
        let visible = textView.visibleRect
        let pt = NSPoint(x: 4, y: visible.minY - textView.textContainerInset.height + 1)
        let glyph = lm.glyphIndex(for: pt, in: tc)
        return lm.characterIndexForGlyph(at: min(glyph, lm.numberOfGlyphs - 1))
    }

    /// Scroll so the given character sits at the top of the viewport. `lineOffset` pushes it down
    /// by N lines (used when selecting downward so the already-selected line above stays visible).
    func scrollCharToTop(_ charIndex: Int, lineOffset: Int = 0) {
        guard let lm = textView.layoutManager,
              let storage = textView.textStorage, lm.numberOfGlyphs > 0 else { return }
        let idx = min(max(0, charIndex), storage.length)
        let glyph = lm.glyphIndexForCharacter(at: idx)
        var rect = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        rect.origin.y += textView.textContainerInset.height
        var targetY = rect.origin.y - CGFloat(lineOffset) * rect.height
        // The first line is a special case: putting it flush with the top edge scrolls the page's
        // top margin — and, when reserved, its leading header band (see `restore(_:)`'s identical
        // guard, which explains why `leadingBand` belongs in this threshold) — out of sight, so the
        // document looks like it lost its padding. Nothing above it needs the room, so go to the
        // very top instead.
        if targetY <= textView.textContainerInset.height + pageBandDelegate.leadingBand { targetY = 0 }
        let clip = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clip.bounds.height)
        // KEEP the horizontal origin. These two functions mean "scroll VERTICALLY to here"; forcing
        // x to 0 undid `PageCenteringClipView`'s centring, so a paged page snapped to the left edge on
        // every path that ends in a scroll — which is every reflow, i.e. opening AND closing the table
        // of contents ("목차 열 때, 그리고 오히려 닫을 때에도 다시 좌측으로 정렬됨").
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, targetY), maxY)))
        scrollView.reflectScrolledClipView(clip)
        placeCopyButtons()
    }

    /// Called after the document layer mutates the text (e.g. the mermaid swap), which
    /// shifts character offsets. Recompute heading offsets from the live text, clamp the
    /// caret to the new length, and re-place copy buttons.
    func refreshAfterMutation() {
        textView.recomputeHeadingOffsets()
        textView.clampCaretToText()
        placeCopyButtons()
    }

    /// Lightweight refresh for image fills: an attachment's size changed (editedAttributes,
    /// changeInLength 0) so CHARACTER OFFSETS are unchanged — heading offsets don't need
    /// recomputing. Coalesce the button re-placement so N images cost ONE placement, not N
    /// full-document passes (was O(N²) via refreshAfterMutation per image).
    func refreshAfterImageFill() {
        pendingPlace?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.placeCopyButtons() }
        pendingPlace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // MARK: - Code-block overlays (Copy + Wrap toggle + optional no-wrap scroll view)

    private var codeOverlays: [NSView] = []
    private var lastPlacementSig = ""            // skip overlay rebuild when nothing relevant changed
    private var noWrapCodes: Set<String> = []   // code blocks toggled to no-wrap (per session)
    private var pendingPlace: DispatchWorkItem?
    private var lastClipWidth: CGFloat = 0

    /// Test-visible: counts every time `updateTextInset` actually ran its body (as opposed to
    /// early-returning) — from ANY caller. Useful for "did a reflow happen at all", but NOT for
    /// isolating `windowDidResize`'s own gate: a width-changing resize also fires `viewportChanged`
    /// via the text view's own autoresizing (see `windowDidResize`'s comment), which increments
    /// this exact counter too — so a test that wants to prove `windowDidResize`'s gate SPECIFICALLY
    /// isn't over-rejecting must use `resizeGateReflowCount` below instead, or it can pass for the
    /// wrong reason (`WindowResizeGateTests`).
    private(set) var textInsetUpdateCount = 0

    /// Test-visible: counts only calls where `windowDidResize`'s OWN width-changed gate passed —
    /// incremented inside `windowDidResize` itself, before it calls `updateTextInset`, so nothing
    /// `viewportChanged` (or any other caller) does can move this number. This is the counter that
    /// actually answers "did windowDidResize's gate allow a real width change through", the
    /// question `textInsetUpdateCount` alone cannot answer on its own (see its doc).
    private(set) var resizeGateReflowCount = 0

    @objc private func viewportChanged() {
        // The desk numbers are NOT part of the scrolled content, so a scroll moves the sheets out
        // from under them; one repaint over the visible sheets is the whole cost.
        refreshPageNumberDesk()
        // Recompute the centered column only when the width actually changed (a window resize),
        // not on every scroll — avoids reflow churn while scrolling. `updateTextInset` itself is
        // what records the width it solved at (`lastClipWidth` — see its doc), so this check and
        // `windowDidResize`'s share one source of truth for "did the width really move."
        let w = scrollView.contentSize.width
        if abs(w - lastClipWidth) > 0.5 { updateTextInset() }
        pendingPlace?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.placeCopyButtons()
            // Free off-screen images/diagrams and reload near-screen ones (memory bounded to the
            // viewport on long docs).
            (self.mdDocument)?.reconcileMedia(in: self)
            // Scroll has settled: repaint the whole visible area once so any card/quote background
            // torn by copy-on-scroll blitting is drawn clean (mid-scroll tearing is acceptable).
            self.textView.setNeedsDisplay(self.textView.visibleRect)
        }
        pendingPlace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Place the Copy + Wrap buttons (and, for no-wrap blocks, a horizontally-scrollable code
    /// overlay) for every code block currently on screen. Rebuilt on scroll/resize so only
    /// visible blocks cost anything; the no-wrap overlay exists only for toggled blocks, so a
    /// normal document loads with zero extra views.
    private func teardownOverlays() {
        codeOverlays.forEach { $0.removeFromSuperview() }
        codeOverlays.removeAll()
    }

    func placeCopyButtons() {
        guard let storage = textView.textStorage,
              let lm = textView.layoutManager,
              let container = textView.textContainer, storage.length > 0 else {
            teardownOverlays(); lastPlacementSig = ""; return
        }
        let visibleRect = textView.visibleRect
        let visibleGlyphs = lm.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visibleChars.length > 0 else { teardownOverlays(); lastPlacementSig = ""; return }
        let whole = NSRange(location: 0, length: storage.length)
        // Signature of everything that determines overlay layout: visible code blocks (full range
        // + wrap state + vertical position) plus column width and font size. If unchanged since the
        // last placement, existing overlays are still correct — skip the teardown + rebuild. The
        // font size comes from THIS window's own document — a stale/shared key here would mean an
        // overlay placed for one document's size silently surviving a font-size change made through
        // a DIFFERENT window (the exact bug `MarkdownDocument.readingSize` exists to fix).
        let readingSize = (mdDocument)?.readingSize ?? FontSizeStore.defaultSize
        var sig = "\(Int(container.size.width))|\(readingSize)"
        storage.enumerateAttribute(MDAttr.codeBlock, in: visibleChars) { value, visRange, _ in
            guard let code = value as? String else { return }
            var range = visRange
            _ = storage.attribute(MDAttr.codeBlock, at: visRange.location, longestEffectiveRange: &range, in: whole)
            let g = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil).location
            let y = Int(lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY)
            sig += "#\(range.location):\(range.length):\(self.noWrapCodes.contains(code) ? 1 : 0):\(y)"
        }
        if sig == lastPlacementSig { return }
        lastPlacementSig = sig
        teardownOverlays()
        let inset = textView.textContainerInset
        let cardRight = inset.width + container.size.width - CodeCardMetrics.horizontalMargin
        let cardLeft = inset.width + CodeCardMetrics.horizontalMargin

        storage.enumerateAttribute(MDAttr.codeBlock, in: visibleChars) { value, visRange, _ in
            guard let code = value as? String else { return }
            // The enumeration range is CLIPPED to the visible portion; anchoring to it pins the
            // header to the viewport top as you scroll. Recover the block's FULL range so the
            // header sits at the block's real top and scrolls away with it.
            var range = visRange
            _ = storage.attribute(MDAttr.codeBlock, at: visRange.location, longestEffectiveRange: &range, in: whole)
            let lang = (storage.attribute(MDAttr.codeLang, at: range.location, effectiveRange: nil) as? String) ?? ""
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += inset.width; rect.origin.y += inset.height
            let headerY = rect.minY + 2   // the blank header line reserved by the renderer
            // Nested-in-quote code shifts its card (and chrome) right to align with the quote.
            let qInset = CGFloat((storage.attribute(MDAttr.codeInset, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0)
            let blockLeft = cardLeft + qInset

            // The code text starts after the 2-char blank header line.
            if range.length > 2 {
                let codeChars = NSRange(location: range.location + 2, length: range.length - 2)
                let codeGlyphs = lm.glyphRange(forCharacterRange: codeChars, actualCharacterRange: nil)
                var codeRect = lm.boundingRect(forGlyphRange: codeGlyphs, in: container)
                codeRect.origin.x += inset.width; codeRect.origin.y += inset.height

                // No-wrap overlay covers the code area (below the header) with its own scroller.
                if self.noWrapCodes.contains(code) {
                    let frame = NSRect(x: blockLeft, y: codeRect.minY,
                                       width: cardRight - blockLeft, height: codeRect.height)
                    let sv = self.makeNoWrapCodeView(code: code, lang: lang, frame: frame)
                    self.textView.addSubview(sv)
                    self.codeOverlays.append(sv)
                }
            }

            // Header divider — separates the header row (lang label + buttons) from the code,
            // making each block read as a real code card.
            let divider = NSView(frame: NSRect(x: blockLeft, y: headerY + 18,
                                               width: cardRight - blockLeft, height: 1))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Palette.hairline.cgColor
            self.textView.addSubview(divider)
            self.codeOverlays.append(divider)

            // Header strip runs from the card's top edge to the divider; center its chrome in it.
            let cardTopY = headerY - 2 - CodeCardMetrics.verticalPadding
            let bandCenterY = (cardTopY + (headerY + 18)) / 2

            // Language label on the left of the header (e.g. "SWIFT", "PYTHON").
            if !lang.isEmpty {
                let label = self.makeLangLabel(lang)
                label.setFrameOrigin(NSPoint(x: blockLeft + CodeCardMetrics.textInset, y: bandCenterY - label.frame.height / 2))
                self.textView.addSubview(label)
                self.codeOverlays.append(label)
            }

            let copy = self.makeChipButton("Copy", textColor: .secondaryLabelColor,
                bg: NSColor.textColor.withAlphaComponent(0.06), weight: .medium,
                action: #selector(self.copyCode(_:)), code: code, widest: "Copied")
            // Wrap toggle: accent fill + accent text when wrapping is ON; grey text, no fill when OFF.
            let wrapping = !self.noWrapCodes.contains(code)
            let wrap = self.makeChipButton("Wrap",
                textColor: wrapping ? Palette.link : .tertiaryLabelColor,
                bg: wrapping ? Palette.link.withAlphaComponent(0.16) : .clear,
                weight: wrapping ? .semibold : .regular,
                action: #selector(self.toggleWrap(_:)), code: code)
            let btnY = bandCenterY - copy.frame.height / 2
            copy.setFrameOrigin(NSPoint(x: cardRight - copy.frame.width - 6, y: btnY))
            wrap.setFrameOrigin(NSPoint(x: copy.frame.minX - wrap.frame.width - 4, y: btnY))
            self.textView.addSubview(copy)   // buttons on top of any overlay
            self.textView.addSubview(wrap)
            self.codeOverlays.append(copy); self.codeOverlays.append(wrap)
        }
    }

    private func makeButton(_ title: String, action: Selector, code: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 10)
        b.sizeToFit()
        b.identifier = NSUserInterfaceItemIdentifier(code)
        return b
    }

    /// A uniform header chip (Copy / Wrap) — same size and shape so they line up; only the
    /// colors differ (Wrap uses an accent fill when wrapping is on, grey when off).
    /// `widest` is the longest label this chip will ever show. The chip is sized for THAT, so
    /// switching label (Copy → Copied) can't clip the text or shove its neighbour sideways — the
    /// frame is set once here and never touched again.
    private func makeChipButton(_ title: String, textColor: NSColor, bg: NSColor,
                                weight: NSFont.Weight, action: Selector, code: String,
                                widest: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: weight), .foregroundColor: textColor]
        b.attributedTitle = NSAttributedString(string: widest ?? title, attributes: attrs)
        b.sizeToFit()
        var f = b.frame; f.size.width += 14; f.size.height = 17; b.frame = f
        b.attributedTitle = NSAttributedString(string: title, attributes: attrs)   // frame stays
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.backgroundColor = bg.cgColor
        b.identifier = NSUserInterfaceItemIdentifier(code)
        return b
    }

    /// A small uppercase language tag ("SWIFT", "PYTHON") for the code-card header.
    private func makeLangLabel(_ lang: String) -> NSTextField {
        let f = NSTextField(labelWithString: lang.uppercased())
        f.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        f.textColor = .tertiaryLabelColor
        f.sizeToFit()
        return f
    }

    private func makeNoWrapCodeView(code: String, lang: String, frame: NSRect) -> NSScrollView {
        let sv = NSScrollView(frame: frame)
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = Palette.codeCardBg      // opaque, matches the card, hides folded code
        sv.wantsLayer = true
        sv.layer?.cornerRadius = CodeCardMetrics.cornerRadius
        sv.layer?.borderWidth = 1
        sv.layer?.borderColor = Palette.codeCardBorder.cgColor
        let tv = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
        tv.isEditable = false; tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: CodeCardMetrics.textInset, height: 4)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // This window's own document decides its overlay's font size — never a shared global (see
        // `placeCopyButtons`'s cache-signature comment above for why a stale/shared key here would
        // be exactly the bug `MarkdownDocument.readingSize` exists to fix).
        let readingSize = (mdDocument)?.readingSize ?? FontSizeStore.defaultSize
        let overlayTheme = RenderTheme.current(size: readingSize)
        let hl = NSMutableAttributedString(attributedString:
            CodeHighlighter.highlight(code, language: lang.isEmpty ? nil : lang, theme: overlayTheme))
        // Match the wrapped card's line leading so no-wrap lines aren't tighter than wrap mode.
        let codeLH = (overlayTheme.codeFont.pointSize * overlayTheme.codeLineHeightRatio).rounded()
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = codeLH; ps.maximumLineHeight = codeLH
        hl.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: hl.length))
        tv.textStorage?.setAttributedString(hl)
        sv.documentView = tv

        // Force layout of this (visible, user-toggled) block to measure its real extent —
        // deterministic, and only paid for a block on screen.
        if let tc = tv.textContainer, let tlm = tv.layoutManager {
            tlm.ensureLayout(for: tc)
            let usedRect = tlm.usedRect(for: tc)
            // Does the code overflow horizontally? If so a scroller appears along the bottom and
            // would sit ON TOP of the last code line — reserve extra height for it.
            let used = usedRect.width + 2 * CodeCardMetrics.textInset
            let hasHScroll = used > frame.width + 1
            let scrollerPad: CGFloat = hasHScroll ? 16 : 0
            // Fit the overlay to its ACTUAL content (+ top/bottom inset + scroller room) so the
            // last code line is never clipped.
            let contentH = ceil(usedRect.height + 2 * 4 + scrollerPad)
            if contentH > sv.frame.height {
                sv.setFrameSize(NSSize(width: sv.frame.width, height: contentH))
                tv.setFrameSize(NSSize(width: sv.frame.width, height: contentH))
            }
            // Resizing the document view can leave the clip view scrolled off the top line;
            // pin it back to the origin so the first code line is never clipped.
            sv.contentView.scroll(to: .zero)
            sv.reflectScrolledClipView(sv.contentView)
            // Scroll affordance: fade the right edge so it reads as "there's more →".
            if hasHScroll {
                let fade = EdgeFadeView(frame: NSRect(x: sv.frame.width - 26, y: 0, width: 26, height: sv.frame.height))
                fade.autoresizingMask = [.minXMargin, .height]
                sv.addSubview(fade)
            }
        }
        return sv
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        setChipTitle(sender, "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.setChipTitle(sender, "Copy") }
    }

    /// A chip's whole look (10pt, its colour) lives in its attributedTitle. Assigning `.title`
    /// silently throws all of that away and the label snaps to the default 13pt system font —
    /// which is why "Copied" appeared twice the size of "Copy". Re-use the existing attributes.
    private func setChipTitle(_ b: NSButton, _ title: String) {
        let attrs = b.attributedTitle.length > 0
            ? b.attributedTitle.attributes(at: 0, effectiveRange: nil) : [:]
        b.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    @objc private func toggleWrap(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue, let storage = textView.textStorage else { return }
        let noWrap = !noWrapCodes.contains(code)
        if noWrap { noWrapCodes.insert(code) } else { noWrapCodes.remove(code) }
        // Change the underlying code paragraphs' wrapping so the BLOCK HEIGHT actually reflows:
        // wrap = fold long lines (tall); no-wrap = one clipped line per source line (short), with
        // the scroll overlay providing horizontal scrolling on top.
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(MDAttr.codeBlock, in: whole) { v, r, _ in
            guard (v as? String) == code else { return }
            storage.enumerateAttribute(.paragraphStyle, in: r, options: []) { ps, sub, _ in
                guard let ps = ps as? NSParagraphStyle, let mps = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
                // no-wrap: the OVERLAY shows the scrollable code; the underlying copy just needs to
                // keep the block's height. Use truncatingTail (not clipping) so a long line stops at
                // the card's right edge instead of overflowing past the overlay and peeking out.
                mps.lineBreakMode = noWrap ? .byTruncatingTail : .byCharWrapping
                storage.addAttribute(.paragraphStyle, value: mps, range: sub)
            }
        }
        storage.endEditing()
        placeCopyButtons()
    }

    /// Read-only by policy: the view is editable (for a visible caret + future editing) but we
    /// reject every mutation. Flip this to allow editing later.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool { false }

    // MARK: - Link / file-path clicks

    /// Open clicked links: web URLs in the browser, `.md` files as a tab (focusing an already-
    /// open one), other files in their associated app, and folders in Finder.
    func textView(_ tv: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // In-document anchor (a markdown TOC entry, or an office cross-reference/bookmark link) —
        // resolved against bookmark markers first, then heading slugs (`AnchorResolver`). This MUST
        // be checked, and must return, before the raw-URL/file-path branches below: an office
        // bookmark link carries no `.link` scheme AppKit can route on its own (see
        // `OfficeTextBuilder`'s `#`-prefixed-link handling), so falling through here is exactly the
        // defect this branch exists to prevent — a bare `#BookmarkName` misread as a relative file
        // path and handed to `openFile`.
        if let target = tv.textStorage?.attribute(MDAttr.anchor, at: charIndex, effectiveRange: nil) as? String {
            jumpToAnchor(target: target); return true
        }
        // A detected file path (stored raw so it can be resolved against the document's folder).
        if let raw = tv.textStorage?.attribute(MDAttr.filePath, at: charIndex, effectiveRange: nil) as? String {
            openFile(resolvePath(raw)); return true
        }
        let url: URL? = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return false }
        if url.isFileURL {
            openFile(url)
        } else if url.scheme == nil {
            // `[docs](demo/code-blocks.md)` — a relative link, which is how every README on earth
            // points at its neighbours. It is neither a file: URL nor a web one, so handing it to
            // NSWorkspace asks macOS to open "demo/code-blocks.md" as a web address and it fails.
            // Resolve it against the document's own folder, exactly like a bare path in the prose.
            openFile(resolvePath(url.relativePath.removingPercentEncoding ?? url.relativePath))
        } else {
            NSWorkspace.shared.open(url)   // http(s), mailto → the system handler
        }
        return true
    }

    /// Menu counterpart of clicking a blocked image — the same grant, reachable when a document's
    /// images are blocked but none is on screen.
    @objc func grantFolderAccess(_ sender: Any?) {
        grantFolder()
    }

    /// Ask for the folder, then re-read the document: placeholders were sized as placeholders, and
    /// every image can now be measured for real, so a full re-render is both simplest and correct.
    private func grantFolder() {
        guard let doc = (document as? NSDocument)?.fileURL else { return }
        // "files", not "images": reached from the File menu, this grant is also what lets the
        // headless flags read anything in a sandboxed build (see FolderAccess.headlessDenialHint).
        FolderAccess.requestAccess(to: FolderAccess.suggestedFolder(for: doc), in: window,
                                   what: "files") { [weak self] granted in
            guard granted else { return }
            (self?.mdDocument)?.reloadDocument(nil)
        }
    }

    /// Resolve an in-document anchor's raw target and scroll there (top-anchored) — same reveal
    /// path `goToOutlineEntry` uses, so a bookmark/cross-reference jump feels identical to clicking
    /// the sidebar. The matching itself is `AnchorResolver`'s pure decision (bookmark exact match,
    /// then GFM heading-slug match); this function's only job is gathering the two candidate sets
    /// from the live text storage and acting on the result. A target that resolves to nothing does
    /// NOTHING VISIBLE — a link to a deleted bookmark/heading is common in real documents and is
    /// not an error a reader should announce (no beep, no guess).
    private func jumpToAnchor(target: String) {
        guard let storage = textView.textStorage else { return }
        var bookmarks: [String: Int] = [:]
        storage.enumerateAttribute(MDAttr.bookmarkTarget, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let names = v as? [String] else { return }
            for name in names { bookmarks[name] = r.location }
        }
        var headings: [(text: String, position: Int)] = []
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard v != nil else { return }
            headings.append((text: (storage.string as NSString).substring(with: r), position: r.location))
        }
        guard let found = AnchorResolver.resolve(target: target, bookmarks: bookmarks, headings: headings) else { return }
        textView.setSelectedRange(NSRange(location: found, length: 0))
        scrollCharToTop(found)
    }

    /// ⌘-click on a selection: open whatever was highlighted, even without an http prefix.
    /// Tries, in order: an explicit URL scheme → a resolvable file path → a bare web domain.
    /// Right-click → Edit: open the markdown SOURCE of the block(s) the selection touches in a
    /// popup; on save, replace just that source span and re-render (Notion-style block editing).
    func editSelectedSource(atChar: Int? = nil) {
        guard let storage = textView.textStorage, let doc = mdDocument else { return }
        // An office document has no editable source (see `isOfficeDocument`/CLAUDE.md invariant
        // 22) — refuse explicitly rather than rely on the srcRange scan below coming up empty.
        guard doc.kind != .office else { NSSound.beep(); return }
        // Nothing to edit yet — treat Edit on an empty document as writing its first block, rather
        // than beeping at someone who is trying to start.
        guard storage.length > 0 else { addBlockBelow(atChar: nil); return }
        let sel = textView.selectedRange()
        // Use the selection if there is one; otherwise the block under the right-click (or caret).
        let anchor = (atChar ?? sel.location)
        let scan = sel.length > 0 ? sel
                                  : NSRange(location: min(max(0, anchor), storage.length - 1), length: 1)
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: scan) { v, _, _ in
            guard let r = (v as? NSValue)?.rangeValue else { return }
            lo = min(lo, r.location); hi = max(hi, r.location + r.length)
        }
        guard lo != Int.max, hi > lo else { NSSound.beep(); return }
        let srcRange = NSRange(location: lo, length: hi - lo)
        SourceEditPanel.show(title: "Edit block source", markdown: doc.sourceSubstring(srcRange)) { [weak doc] edited in
            doc?.applySourceEdit(srcRange, with: edited)
        }
    }

    // MARK: - Block operations (add / delete / move)
    //
    // All three resolve the block under the pointer to ONE source span pair and hand it to
    // `applySourceEdit` — the single write path — so each is persisted, re-rendered and undoable
    // exactly like a hand edit, and none of them can half-apply.

    /// The block spans of the current document plus the index of the one at `char`.
    private func blockContext(atChar char: Int?) -> (doc: MarkdownDocument, spans: [NSRange], index: Int)? {
        guard let storage = textView.textStorage, let doc = mdDocument,
              storage.length > 0 else { return nil }
        let anchor = min(max(0, char ?? textView.selectedRange().location), storage.length - 1)
        guard let value = storage.attribute(MDAttr.srcRange, at: anchor, effectiveRange: nil) as? NSValue
        else { return nil }
        let spans = BlockEdit.spans(in: storage)
        guard let i = BlockEdit.indexOfBlock(containing: value.rangeValue.location, in: spans) else { return nil }
        return (doc, spans, i)
    }

    /// Right-click → Add Block Below: an empty edit popup; on save the text is inserted after the
    /// clicked block, reusing that document's own separator (blank line in markdown, single
    /// newline in a plain text file).
    func addBlockBelow(atChar char: Int?) {
        guard let doc = mdDocument else { NSSound.beep(); return }
        // An office document has no editable source (see `isOfficeDocument`/CLAUDE.md invariant
        // 22). This guard must come BEFORE the "empty document" branch below: an office document's
        // `text` is always "" and carries no `srcRange`, so `blockContext` is always nil for it —
        // which the branch below would otherwise read as "empty document, start typing" and
        // overwrite `doc.text` (harmlessly empty here, but dirtying the document over content the
        // reader never touched — the real bug this sprint's audit found).
        guard doc.kind != .office else { NSSound.beep(); return }
        // An EMPTY document has no blocks to add below, and without this it had no way in at all:
        // every editing route resolves a block first, so a new tab was a document you could never
        // put anything into. Here the first block simply becomes the document. Tested directly on
        // `doc.text`, NOT on `blockContext == nil` — a nil block context means "no srcRange at this
        // anchor", which is not the same claim as "the document is empty" (see the guard above).
        if doc.text.isEmpty {
            SourceEditPanel.show(title: doc.isPlainText ? "New line" : "New block", markdown: "") { added in
                guard !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let whole = NSRange(location: 0, length: (doc.text as NSString).length)
                doc.applySourceEdit(whole, with: added, actionName: "Add")
            }
            return
        }
        guard let ctx = blockContext(atChar: char) else { NSSound.beep(); return }
        // A text file gets exactly one new line; a markdown file keeps its own paragraph spacing.
        let fixed = ctx.doc.isPlainText ? ctx.doc.lineEnding : nil
        let title = ctx.doc.isPlainText ? "New line" : "New block"
        SourceEditPanel.show(title: title, markdown: "") { [weak self] added in
            guard let self, !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Spans are recomputed at save time: the popup is modeless, so the document may have
            // changed (another edit, a reload) while it was open.
            guard let ctx = self.blockContext(atChar: char),
                  let (r, replacement) = BlockEdit.insertion(after: ctx.index, spans: ctx.spans,
                                                             text: ctx.doc.text as NSString,
                                                             newSource: added,
                                                             fallbackSeparator: fixed ?? "\n\n",
                                                             fixedSeparator: fixed)
            else { NSSound.beep(); return }
            ctx.doc.applySourceEdit(r, with: replacement, actionName: "Add Block")
        }
    }

    /// The run of blocks a delete should take: everything the SELECTION touches, or — with no
    /// selection — just the block under the pointer. Deleting one block at a time when several are
    /// highlighted would ignore what the user plainly indicated.
    private func blockRunToDelete(atChar char: Int?) -> (doc: MarkdownDocument, spans: [NSRange],
                                                         first: Int, last: Int)? {
        guard let ctx = blockContext(atChar: char), let storage = textView.textStorage else { return nil }
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return (ctx.doc, ctx.spans, ctx.index, ctx.index) }
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: sel) { v, _, _ in
            guard let s = (v as? NSValue)?.rangeValue,
                  let i = BlockEdit.indexOfBlock(containing: s.location, in: ctx.spans) else { return }
            lo = min(lo, i); hi = max(hi, i)
        }
        guard lo != Int.max else { return (ctx.doc, ctx.spans, ctx.index, ctx.index) }
        return (ctx.doc, ctx.spans, lo, hi)
    }

    /// Right-click → Delete: confirm first (this rewrites the file on disk), showing what is about
    /// to go so the user can tell they picked the right thing.
    func deleteBlock(atChar char: Int?) {
        guard let run = blockRunToDelete(atChar: char),
              BlockEdit.deletion(from: run.first, through: run.last, spans: run.spans) != nil
        else { NSSound.beep(); return }
        let count = run.last - run.first + 1
        let noun = (run.doc.isPlainText ? "line" : "block") + (count == 1 ? "" : "s")
        let source = run.doc.sourceSubstring(run.spans[run.first])
        let firstLine = source.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? source
        var preview = firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        if count > 1 { preview += "\n… through …\n" + run.doc.sourceSubstring(run.spans[run.last]).prefix(80) }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Delete this \(noun)?" : "Delete these \(count) \(noun)?"
        alert.informativeText = "\(preview)\n\nThis rewrites \(run.doc.fileURL?.lastPathComponent ?? "the file") on disk. You can undo it with ⌘Z."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // The sheet is asynchronous, so re-resolve when the user actually confirms — an undo or a
        // ⌘R reload while it was up would have moved every offset under it.
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let run = self.blockRunToDelete(atChar: char),
                  let r = BlockEdit.deletion(from: run.first, through: run.last, spans: run.spans)
            else { return }
            run.doc.applySourceEdit(r, with: "", actionName: "Delete")
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    /// Put the reading cursor on the block an edit touched, and bring it on screen if it isn't
    /// already. This matters most for undo/redo: the change can be anywhere in the document, and a
    /// reader who presses ⌘Z and sees nothing move can't tell whether it did anything.
    ///
    /// Only scrolls when the block is NOT fully visible — undoing an edit you're looking at should
    /// leave the page exactly where it is.
    func revealEditedSource(_ span: NSRange, highlight: Bool) {
        guard let storage = textView.textStorage, storage.length > 0,
              let lm = textView.layoutManager, let container = textView.textContainer else { return }
        let probe = NSRange(location: span.location, length: max(span.length, 1))
        var lo = Int.max, hi = Int.min
        var fallback: Int?
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let s = (v as? NSValue)?.rangeValue else { return }
            if s.location < probe.location + probe.length, s.location + s.length > probe.location {
                lo = min(lo, r.location); hi = max(hi, r.location + r.length)
            } else if fallback == nil, s.location >= probe.location + probe.length {
                fallback = r.location          // the block that moved up into a deleted one's place
            }
        }
        let target: NSRange
        if lo != Int.max, hi > lo { target = NSRange(location: lo, length: hi - lo) }
        else if let f = fallback { target = NSRange(location: f, length: 0) }
        else { target = NSRange(location: min(span.location, storage.length), length: 0) }

        textView.setSelectedRange(highlight ? target : NSRange(location: target.location, length: 0))
        let glyphs = lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        if !textView.visibleRect.contains(rect) {
            // Leave a little air above it rather than pinning it to the very top edge.
            textView.scrollRangeToVisible(target)
            let clip = scrollView.contentView
            let y = max(0, rect.minY - clip.bounds.height / 4)
            if rect.height < clip.bounds.height {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x,   // keep the centring (see `restore`)
                                        y: min(y, max(0, textView.bounds.height - clip.bounds.height))))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        placeCopyButtons()
    }

    /// Move the block under the reading cursor one step, without entering move mode — the `u`/`j`
    /// keys.
    ///
    /// Selecting ONLY the block that moved is what makes repeated presses work, not just tidier
    /// highlighting. A swap edits two blocks, so the generic post-edit reveal selects both and
    /// leaves the cursor at the start — which for a downward move is the OTHER block, so the next
    /// press picks that one up and swaps the pair straight back. (`u` appeared fine only because
    /// there the moved block happens to end up first.) Landing the cursor on the moved block walks
    /// it as far as you keep pressing.
    func moveBlockUnderCaret(by delta: Int) {
        guard let storage = textView.textStorage, let doc = mdDocument,
              let ctx = blockContext(atChar: textView.selectedRange().location) else { NSSound.beep(); return }
        let spans = BlockEdit.spans(in: storage)
        let first = delta < 0 ? ctx.index - 1 : ctx.index
        guard let (r, replacement) = BlockEdit.swapWithNext(first, spans: spans, text: doc.text as NSString)
        else { NSSound.beep(); return }              // already at the end it's moving toward
        doc.applySourceEdit(r, with: replacement, actionName: "Move")
        selectBlock(at: ctx.index + delta)
    }

    /// Select one block by index and bring it on screen if it isn't already.
    @discardableResult
    func selectBlock(at index: Int) -> Bool {
        guard let storage = textView.textStorage,
              let r = renderedRange(ofBlockAt: index, in: storage) else { return false }
        textView.setSelectedRange(r)
        revealIfOffscreen(r)
        placeCopyButtons()
        return true
    }

    /// The rendered range of the block at `index` — the one place that answers "where on screen is
    /// this block?", so the post-edit reveal and the key moves can't drift apart.
    private func renderedRange(ofBlockAt index: Int, in storage: NSTextStorage,
                               spans precomputed: [NSRange]? = nil) -> NSRange? {
        let spans = precomputed ?? BlockEdit.spans(in: storage)
        guard spans.indices.contains(index) else { return nil }
        let target = spans[index]
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let s = (v as? NSValue)?.rangeValue, s.location == target.location, s.length == target.length
            else { return }
            lo = min(lo, r.location); hi = max(hi, r.location + r.length)
        }
        guard lo != Int.max, hi > lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    /// Scroll a range into view ONLY if it isn't fully visible — moving a block you're looking at
    /// shouldn't shift the page under you.
    private func revealIfOffscreen(_ r: NSRange) {
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        guard !textView.visibleRect.contains(rect) else { return }
        textView.scrollRangeToVisible(r)
    }

    func openSelectionText(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { NSSound.beep(); return }
        if s.contains("://"), let url = URL(string: s) { NSWorkspace.shared.open(url); return }
        let fileURL = resolvePath(s)
        // An explicit path is a path even when it can't be stat'd (sandbox, or simply gone): let
        // openFile ask for the folder or beep, rather than falling through to a bogus https guess.
        if s.hasPrefix("/") || s.hasPrefix("~") || FileManager.default.fileExists(atPath: fileURL.path) {
            openFile(fileURL); return
        }
        // Schemeless web address ("ww-w.ai", "example.com/x") → assume https.
        if s.contains("."), !s.contains(" "), let url = URL(string: "https://\(s)") {
            NSWorkspace.shared.open(url); return
        }
        NSSound.beep()
    }

    /// Resolve a raw path: expand `~`, take absolute paths as-is, resolve relatives against
    /// the current document's directory.
    private func resolvePath(_ raw: String) -> URL {
        if raw.hasPrefix("~") { return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath) }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if let dir = (document as? NSDocument)?.fileURL?.deletingLastPathComponent() {
            return dir.appendingPathComponent(raw).standardizedFileURL
        }
        return URL(fileURLWithPath: raw)
    }

    /// Open a local target (folder, `.md` tab, or associated app).
    ///
    /// Sandboxed, a linked path outside the granted folders is refused by the system, not by us —
    /// macOS puts up its own "doesn't have permission to open X" alert and the click dead-ends. So a
    /// blocked link takes the same route as a blocked image: ask for the folder, then open. Retry
    /// once only (`afterGrant`), since a grant that doesn't cover the target would otherwise loop.
    private func openFile(_ url: URL, afterGrant: Bool = false) {
        if !afterGrant, FolderAccess.needsGrant(for: url) {
            FolderAccess.requestAccess(to: FolderAccess.suggestedFolder(for: url), in: window,
                                       what: "linked files") { [weak self] granted in
                guard granted else { return }               // cancelled: the user already said no
                self?.openFile(url, afterGrant: true)
            }
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = url.pathExtension.lowercased()
        if exists, isDir.boolValue {
            NSWorkspace.shared.open(url)                    // folder → Finder
        } else if DocumentTypes.opensInApp(ext) {
            // Open (or focus) as a tab. NSDocumentController returns the already-open document
            // and fronts its window; tabbingMode = .preferred makes new windows join as tabs.
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } else if exists {
            NSWorkspace.shared.open(url)                    // other file → associated app
        } else {
            NSSound.beep()                                  // dangling path
        }
    }

    // MARK: - Tabs (⌘1…⌘9)

    /// The documents open as tabs in THIS window's tab group, in the order they appear in the tab
    /// bar — which is the order a reader counts them in, and is NOT the order
    /// `NSDocumentController.documents` or `NSApp.windows` reports.
    ///
    /// `tabGroup` is nil for a window that is not tabbed at all (one document open, or the reader
    /// has tabs switched off in System Settings), and then the only tab is this window itself.
    var tabbedWindows: [NSWindow] {
        guard let window else { return [] }
        return window.tabGroup?.windows ?? [window]
    }

    /// Jump to a tab by number. `tag` 1–8 select that tab; **9 is the LAST tab, not the ninth** —
    /// the convention every browser uses, and the one that makes ⌘9 useful to a reader with four
    /// documents open rather than a key that does nothing.
    @objc func goToTab(_ sender: Any?) {
        guard let index = tabIndex(for: sender), let window else { return }
        let windows = tabbedWindows
        guard windows.indices.contains(index) else { return }
        // `selectedWindow` rather than `makeKeyAndOrderFront`: the second brings the window forward
        // without telling the tab group, which on a tabbed window leaves the tab bar highlighting
        // one tab while another is showing.
        window.tabGroup?.selectedWindow = windows[index]
        windows[index].makeKeyAndOrderFront(nil)
    }

    /// The 0-based tab a menu item asks for, or `nil` if it is not one of ours. Pure enough to test
    /// without a window, which is the point: the 9-is-last rule is the part worth pinning.
    func tabIndex(for sender: Any?) -> Int? {
        guard let tag = (sender as? NSMenuItem)?.tag, (1...9).contains(tag) else { return nil }
        return tag == 9 ? max(0, tabbedWindows.count - 1) : tag - 1
    }

    // MARK: - Page view options (View menu: page outline / header / footer)

    @objc func togglePageOutline(_ sender: Any?) { flipPageOption { $0.outline.toggle() } }
    /// Break a table across a page boundary rather than carrying it whole to the next page. Goes
    /// through the SAME `flipPageOption` as the three furniture toggles — it changes how the document
    /// paginates, so it needs the same re-layout, the same reading-position restore and the same
    /// every-open-window sweep, and a second path that re-derived any of that would drift from this
    /// one the first time either was touched (invariant 60f).
    @objc func toggleSplitTables(_ sender: Any?) { flipPageOption { $0.splitTables.toggle() } }
    /// Show or hide the 바탕쪽. Through the same `flipPageOption` as the rest: it draws no differently
    /// from the page furniture beside it and must re-solve and repaint every open window the same way.
    @objc func toggleMasterPage(_ sender: Any?) { flipPageOption { $0.masterPage.toggle() } }

    /// Line (or page) numbers in the left margin. NOT a `flipPageOption`: nothing is re-solved and no
    /// line moves — the numbers are painted into the margin the reading column already sits inside —
    /// so this is the comments panel's shape (invariant 38), a flag plus a repaint, applied to every
    /// open window because the preference is global.
    @objc func toggleMarginNumbers(_ sender: Any?) {
        MarginNumberStore.isOn.toggle()
        for case let wc as DocumentWindowController in
            NSDocumentController.shared.documents.flatMap({ $0.windowControllers }) {
            wc.applyMarginNumbers()
        }
        applyMarginNumbers()
    }

    /// The text view, for the desk overlay's coordinate conversion only — it needs a view to convert
    /// FROM, and `textView` itself is `let` and already internal; this name says why it is being read.
    var textViewForDesk: NSView { textView }

    /// The unit a jump is asked in — the DOCUMENT's own, exactly what the margin draws, and read
    /// independently of whether the numbers are switched on (`MarginNumberStore.jumpUnit`): a reader
    /// who hid the numbers can still ask for page 40.
    var jumpUnit: MarginNumberUnit {
        MarginNumberStore.jumpUnit(paged: isPaged, drawingPages: PageViewOptionsStore.current.outline)
    }

    /// Type a number, press Return, land there. One item rather than two, for the same reason the
    /// numbers themselves are one toggle: the unit belongs to the document, so "Go to Line…" and
    /// "Go to Page…" are the same request retitled, and they can never be set to disagree.
    @objc func goToNumber(_ sender: Any?) {
        let unit = jumpUnit
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = unit == .pages ? "Page number" : "Line number"
        let alert = NSAlert()
        alert.messageText = unit == .pages ? "Go to Page" : "Go to Line"
        alert.informativeText = unit == .pages
            ? "Page 1 to \(max(1, pageSheets.count))."
            : "The number shown in the margin. Out-of-range numbers go to the nearest line."
        alert.addButton(withTitle: "Go")          // the DEFAULT button, so Return alone submits
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Re-read at CONFIRM time, never at open time: the sheet is asynchronous, and a reload or an
        // undo underneath it moves every offset and every sheet (`confirmDeleteBlock`'s discipline).
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces))
            else { return }
            self.goTo(number: number)
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    // MARK: - Type a number, press Return

    /// The digits typed so far. A reader jumps by typing the number they can SEE and pressing Return
    /// — no dialog, because the request is one keystroke long and a sheet would take the page away
    /// from them to ask for it.
    private(set) var jumpBuffer = ""
    private var jumpTimer: Timer?
    private var jumpIndicator: JumpIndicatorView?

    /// Digits are capped at FOUR: a real 490-page report exists in this project's own test set, so
    /// three would make its last pages unreachable by typing.
    private static let maxJumpDigits = 4

    /// The reader typed a digit. Returns false when there is nothing to jump to, so the key falls
    /// through to whatever else wants it rather than being swallowed by a dead feature.
    @discardableResult
    func appendJumpDigit(_ digit: Character) -> Bool {
        guard jumpUnit == .lines || !pageSheets.isEmpty else { return false }
        guard jumpBuffer.count < Self.maxJumpDigits else { return true }
        jumpBuffer.append(digit)
        showJump()
        return true
    }

    /// Return: go, and forget. Returns false when nothing was typed, so Return keeps its old meaning.
    @discardableResult
    func commitJump() -> Bool {
        guard let number = Int(jumpBuffer) else { return false }
        cancelJump()
        goTo(number: number)
        return true
    }

    /// Escape, a second of silence, or a backspace past the first digit.
    func cancelJump() {
        guard !jumpBuffer.isEmpty else { return }
        jumpBuffer = ""
        showJump()
    }

    @discardableResult
    func backspaceJump() -> Bool {
        guard !jumpBuffer.isEmpty else { return false }
        jumpBuffer.removeLast()
        showJump()
        return true
    }

    /// Draw the echo and re-arm the forget timer. One place, so the buffer and what the reader sees
    /// can never disagree.
    private func showJump() {
        jumpTimer?.invalidate()
        jumpTimer = nil
        guard !jumpBuffer.isEmpty else { jumpIndicator?.text = ""; return }
        let indicator = jumpIndicator ?? {
            let v = JumpIndicatorView(frame: scrollView.bounds)
            v.autoresizingMask = [.width, .height]
            jumpIndicator = v
            return v
        }()
        if indicator.superview !== scrollView { scrollView.addSubview(indicator) }
        indicator.frame = scrollView.bounds
        let total = jumpUnit == .pages ? " / \(pageSheets.count)" : ""
        indicator.text = (jumpUnit == .pages ? "Page " : "Line ") + jumpBuffer + total + "  ⏎"
        // Long enough to finish a three-digit number without hurrying, short enough that a stray
        // keystroke does not sit on screen (ax-lecture's own 1.8s, which reads right in use).
        jumpTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelJump() }
        }
    }

    /// Resolve and scroll. Separate from the panel so the whole rule is reachable without a sheet.
    func goTo(number: Int) {
        switch jumpUnit {
        case .pages:
            guard let index = MarginNumberNavigator.sheetIndex(forPage: number,
                                                               sheetCount: pageSheets.count) else { return }
            scrollSheetToTop(index)
        case .lines:
            guard let storage = textView.textStorage,
                  let char = MarginNumberNavigator.characterIndex(forLine: number, in: storage) else { return }
            scrollCharToTop(char)
        }
    }

    /// Put sheet `index` at the top of the viewport. Not `scrollCharToTop`: a page boundary is a
    /// property of the page GRID, not of any character — the first character of a page sits one
    /// leading band below the paper's edge, so jumping by character would cut the top margin (and the
    /// header living in it) off every page.
    func scrollSheetToTop(_ index: Int) {
        let sheets = pageSheets
        guard sheets.indices.contains(index) else { return }
        var y = sheets[index].minY
        // Page 1's own top margin is above its first line with nothing needing the room, so go to the
        // very top rather than scrolling that margin out of sight (`scrollCharToTop`'s same guard).
        if y <= textView.textContainerInset.height { y = 0 }
        let clip = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
        placeCopyButtons()
    }

    /// The ONE place the unit is resolved for this window, so the menu's title, the painter and any
    /// test read the same answer. Called from the toggle and from every render.
    func applyMarginNumbers() {
        textView.marginNumbers = MarginNumberStore.unit(paged: isPaged,
                                                        drawingPages: PageViewOptionsStore.current.outline)
    }

    /// Counts how many times a page option was actually applied — the same shape as
    /// `pageZoomChangeCount`/`textInsetUpdateCount`, so a test can assert a toggle DID something
    /// without a stopwatch and without hand-deriving line positions.
    private(set) var pageOptionChangeCount = 0

    private func flipPageOption(_ change: (inout PageViewOptions) -> Void) {
        guard isPaged else { return }          // no paper, nothing to show or hide
        // The INTENT, never the effective value: with the outline off, `current` reports the other
        // three as false, so reading it here would write those falses back and turning the outline on
        // again would come up bare instead of restoring what the reader had chosen.
        var options = PageViewOptionsStore.intent
        change(&options)
        PageViewOptionsStore.current = options
        // THIS window first, and unconditionally — never through the shared document controller's
        // list. A document that is not registered with `NSDocumentController` (a test builds one
        // directly; so does any future programmatic open) would otherwise find NOTHING to update,
        // including itself, and the toggle would silently do nothing.
        reapplyPageBand()
        // Then every OTHER open paged window: the preference is global (see `PageViewOptions`), so
        // leaving the rest showing the old furniture until they happen to re-render would make the
        // setting look per-window without being it.
        for case let wc as DocumentWindowController in NSDocumentController.shared.documents
            .flatMap({ $0.windowControllers }) where wc !== self && wc.isPaged {
            wc.reapplyPageBand()
        }
    }

    /// Re-solve the page band for the CURRENT view options and lay the document out again.
    ///
    /// **This is a layout change, not a visibility flag, and that is the whole trap.** The comments
    /// panel can set a bool and repaint (invariant 38) because its marks sit on top of glyphs that do
    /// not move. Turning the page furniture off must make the document FLOW CONTINUOUSLY, which means
    /// the band must not be RESERVED — and the reservation is `PageBandLayoutDelegate`, i.e. layout.
    ///
    /// What it must not do is REBUILD (invariant 57): `MarkdownDocument.render` is never reached, so
    /// the string, its tables, and every graphic's frozen size are untouched, and `renderGeneration`
    /// does not move. Only where the lines sit changes.
    ///
    /// The order is invariant 56's, learned the expensive way. The document's height changes by
    /// `band × pageCount` — over 3,000pt on a 19-page A4 report — so:
    ///   1. scroll to the top FIRST. Invalidating layout with the clip parked deep makes the next
    ///      DRAW fill every hole between 0 and the scroll offset in one uninterruptible call; the
    ///      same shape measured 87,638 ms against 937.9 ms after scrolling to zero (invariant 56a).
    ///   2. re-solve the band, then invalidate.
    ///   3. restore the reading position FROM `precomputeLayout`'s completion, never before it —
    ///      restoring first clamps the scroll to a frame height that does not exist yet, which put a
    ///      reader 75% down at character 298 (invariant 55a, invariant 24).
    func reapplyPageBand() {
        applyMarginNumbers()   // the outline decides lines-vs-pages (`MarginNumberStore.unit`)
        guard let doc = mdDocument, let lm = textView.layoutManager,
              let storage = textView.textStorage else { return }
        pageOptionChangeCount += 1
        let anchor = readingAnchor()
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: 0))
        doc.applyPageBand(to: self)
        // The toggle changed what the page IS — desk colour, sheet width, centring, scroller. Applied
        // through the one function every other path uses; doing none of this is what left the desk
        // colour behind after switching the outline off.
        applyPagedViewState()
        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                            actualCharacterRange: nil)
        textView.needsDisplay = true
        pendingAnchor = anchor
        precomputeLayout()
    }

    /// `NSTextView.sizeToFit()` — plus, for a PAGED document, putting the width back.
    ///
    /// **THE ONE WAY THIS VIEW'S WIDTH MAY BE CHANGED.** Every `sizeToFit` in this controller goes
    /// through here, because AppKit's own answer for the width is wrong for a page and it is wrong in
    /// a way that FEEDS BACK. Measured on the reference report after one ⌘+: the frame grew to the
    /// clip's bounds (1297.8pt against a 595.3pt sheet), and the magnification then settled at
    /// `clipFrame ÷ frame` = 0.8876 — a zoom-IN press that zoomed OUT, because the two were solving
    /// for each other. Pinning the width breaks the loop at its only entry point.
    ///
    /// `isHorizontallyResizable = true` (set by `settleReadingColumn`'s paged branch) is the flag that
    /// is SUPPOSED to do this, and it is still set because it is correct — but it was measured not to
    /// hold on its own here, so the width is restored explicitly rather than trusted. A deterministic
    /// assignment beats a flag whose exact interaction with `sizeToFit` we would have to keep
    /// re-deriving.
    private func sizeTextViewToFit() {
        textView.sizeToFit()
        applyPagedViewState()
    }

    /// Test seam: the desk colour beside the page. `scrollView` is private on purpose (invariant 57's
    /// "the zoom is the only thing that touches it"), and this is the one property a test needs to
    /// prove the View-menu toggle re-applies the whole view state rather than part of it.
    var deskBackgroundColorForTesting: NSColor { scrollView.backgroundColor }

    /// THE one place that puts this window into the state a PAGED document needs — and the answer to
    /// why centring kept coming back wrong.
    ///
    /// Five rules describe a paged view: which width is the paper, how wide the scrollable frame is,
    /// what colour the space beside the page is, whether the page is centred, and whether a sideways
    /// scroller is needed. They were applied by FIVE different paths, each handling a different subset
    /// — audited: the reading-column settle did all five, a magnification change did three, `sizeToFit`
    /// did one, and the View-menu page toggle did NONE. So turning the page outline off left the desk
    /// colour behind, turning it on left the paper's white beside the sheet, and every fix landed in one
    /// path while another quietly undid it. That is a structural fault rather than five bugs, and it is
    /// the owner's own diagnosis: *"불필요하게 여러번 그리거나, 그리는 부분이 여러군데인데 일부에서만
    /// 처리하는지"*.
    ///
    /// Safe to call unconditionally: every part below is a no-op for a document with no page, so the
    /// non-paged branch calls it too and markdown gets its defaults back through the SAME function
    /// rather than through a second, divergent one.
    func applyPagedViewState() {
        textView.pagedPaperWidth = pagedDocumentWidth   // nil for markdown, plain text, no-page office
        pinPagedFrameWidth()
        syncDeskBackground()
        syncHorizontalScroller()
        recentrePage()
        syncPageNumberDesk()
    }

    /// The page number written on the DESK beside each sheet. A separate view laid over the scroll
    /// view rather than anything the text view draws, because a paged document's text view is pinned
    /// to the PAPER's width and physically cannot paint outside the sheet — and because furniture
    /// that cannot reach the layout manager cannot move the document (the rule this whole feature
    /// lives under). Present only while there is something to number.
    private func syncPageNumberDesk() {
        let wants = MarginNumberStore.unit(paged: isPaged,
                                           drawingPages: PageViewOptionsStore.current.outline) == .pages
        if wants {
            let desk = pageNumberDesk ?? {
                let v = PageNumberDeskView(frame: scrollView.bounds)
                v.controller = self
                v.autoresizingMask = [.width, .height]
                pageNumberDesk = v
                return v
            }()
            if desk.superview !== scrollView { scrollView.addSubview(desk) }
            desk.frame = scrollView.bounds
            desk.needsDisplay = true
        } else {
            pageNumberDesk?.removeFromSuperview()
        }
    }

    /// Repaint the desk numbers — scrolling and zooming move the sheets under a view that is NOT part
    /// of the scrolled content, so it has to be told. Cheap: one `draw` over the visible sheets.
    func refreshPageNumberDesk() { pageNumberDesk?.needsDisplay = true }

    /// Re-apply the page's horizontal CENTRING after the reading area changed width.
    ///
    /// `PageCenteringClipView.constrainBoundsRect` is AppKit's hook for this, and AppKit calls it when
    /// the bounds ORIGIN is being changed — a scroll, a zoom — but not when the clip's FRAME changes
    /// underneath it. Opening the table of contents does exactly that: the reading area narrows from
    /// 1309pt to 1069pt, the old origin stays, and the page snaps to the left edge. Reported twice
    /// ("헐! 목차 여니 왜 갑자기 또 좌측 정렬임?"). So the constraint is asked for explicitly rather than
    /// waited for.
    private func recentrePage() {
        let clip = scrollView.contentView
        let wanted = clip.constrainBoundsRect(clip.bounds).origin.x
        guard abs(wanted - clip.bounds.origin.x) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: wanted, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Put the text view's width back to the PAPER's, whatever just widened it.
    ///
    /// Called after every `sizeToFit` and after every magnification change — the two paths measured to
    /// widen it. AppKit keeps resizing a text view to its clip view, and a magnification change moves
    /// the clip's BOUNDS, so a zoom press alone took the frame from 595.3pt to 909.0pt on the reference
    /// report. Centring no longer depends on this (`ReaderTextView.pagedPaperWidth` is what
    /// `PageCenteringClipView` reads), but the frame is the SCROLLABLE area: left wrong, a reader can
    /// scroll sideways into empty desk that has no page in it.
    private func pinPagedFrameWidth() {
        guard let paper = pagedDocumentWidth, abs(textView.frame.width - paper) > 0.5 else { return }
        var f = textView.frame
        f.size.width = paper
        textView.frame = f
    }

    /// The desk BESIDE the page is the scroll view's own background, not something the text view can
    /// paint: a sheet narrower than the window leaves bare clip view either side of it, and
    /// `drawPageSheets` cannot reach outside its own bounds. Without this the space beside the paper
    /// stayed the same white as the paper, so a centred page read as no page at all — reported as
    /// "좌우는 문서 끝이 없고 여백도 없어".
    ///
    /// Only while the outline is on, and only for a paged document; everything else keeps AppKit's
    /// default so markdown and plain text are untouched.
    private func syncDeskBackground() {
        let showsDesk = isPaged && PageViewOptionsStore.current.outline
        scrollView.backgroundColor = showsDesk ? Palette.pageDesk : .textBackgroundColor
    }

    /// How much of the band is DESK rather than paper. Read from the LAYOUT that reserved it
    /// (`PageBandLayoutDelegate.deskGap`), never from the preference again — see that property for why
    /// the two are not equivalent.
    private var pageDeskGap: CGFloat { pageBandDelegate.deskGap }

    /// The sheets to DRAW on screen — the same rectangles printing puts on paper, from the same
    /// function, so the page a reader sees and the page that comes out of the printer can never be
    /// two different things. Empty unless the outline is on and the reader actually paginated.
    var pageSheets: [CGRect] {
        guard PageViewOptionsStore.current.outline else { return [] }
        // The PRINTED sheets, joined across any boundary layout could not open, so a page break is
        // never drawn through a table. Derived from `printSheets` rather than computed again: two
        // copies of this arithmetic is exactly how the screen and the paper would come to disagree
        // about where a page is, and the whole promise of the paged view is that they cannot.
        return PagePagination.joiningUnopenedBoundaries(printSheets,
                                                        openedBoundaries: pageBandDelegate.openedBoundaries)
    }

    // MARK: - Print (⌘P)

    private var printRestore: [(NSView, Bool)] = []

    /// The sheets this document prints as, in the text view's own coordinates — EMPTY whenever
    /// AppKit should paginate instead (see the three cases in `makePrintOperation`). Read by
    /// `ReaderTextView.knowsPageRange`/`rectForPage`, which is the only way a view can take
    /// pagination over from AppKit.
    ///
    /// Non-empty only when the reader ITSELF paginated — `pageBandDelegate.isActive`, i.e. the
    /// document declared a page height AND has a running header or footer, so layout actually opened
    /// a gap between pages. A paged document with neither reserves no band (invariant 58's `band ==
    /// 0` path) and its text runs continuously, so cutting it on the page grid would slice a line in
    /// half; that case keeps AppKit's own line-aware pagination and only takes the paper size from
    /// the document.
    var printSheets: [CGRect] {
        guard pageBandDelegate.isActive, let width = pagedDocumentWidth else { return [] }
        let pitch = PagePagination.pitch(pageContentHeight: pageBandDelegate.pageContentHeight,
                                         band: pageBandDelegate.band)
        return PagePagination.sheets(count: printPageCount, width: width,
                                     textOriginY: textView.textContainerOrigin.y,
                                     leadingBand: pageBandDelegate.leadingBand,
                                     pitch: pitch,
                                     topMargin: PagePagination.topMargin(declared: pagedMarginTop,
                                                                          band: pageBandDelegate.band - pageDeskGap),
                                     deskGap: pageDeskGap)
    }

    /// How many pages the reader itself thinks this document has — the SAME number
    /// `PageBandPainter.draw` judges "is this the last page" by, deliberately through the same
    /// function rather than a second copy of the formula: a printout whose page count disagreed with
    /// the painter's would put the trailing footer on the wrong sheet.
    var printPageCount: Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 1 }
        let pitch = PagePagination.pitch(pageContentHeight: pageBandDelegate.pageContentHeight,
                                         band: pageBandDelegate.band)
        // Measured from the LAST LINE, never from `usedRect` minus the trailing band. `usedRect`
        // includes the EXTRA LINE FRAGMENT, and that rect is not ours to rely on: AppKit recomputes
        // it whenever it re-lays the end of the text — putting the caret past the last character
        // (which is exactly what clicking the empty space below the final page does) replaces the
        // band `applyTrailingFooterBand` reserved with its own empty-line height. Measured on a real
        // report: the reservation came back 11.0pt tall and `usedRect` fell 643.85 → 612.35, so the
        // subtraction below then removed a band that was no longer there, the page count dropped by
        // one, and the last sheet — the PAPER behind the final page — stopped being drawn while the
        // text stayed on the desk. The last line's own rect is the same number
        // `applyTrailingFooterBand` derives its reservation from, and nothing outside layout can
        // move it.
        let lastGlyph = lm.numberOfGlyphs - 1
        let contentBottom = lastGlyph >= 0
            ? lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY
            : 0
        let body = max(0, contentBottom - pageBandDelegate.leadingBand)
        return PageBandPainter.totalPages(documentHeight: body, pitch: pitch)
    }

    /// Builds the operation ⌘P runs — factored out of `printDocument` so a test can drive it to a
    /// PDF file and COUNT the pages, which is the only deterministic way to prove pagination without
    /// a print dialog or a screenshot.
    ///
    /// Three cases, and the first rule is shared by all of them: the print settings are a COPY of
    /// `NSPrintInfo.shared`, never the shared object itself. Mutating the shared one leaks a paged
    /// document's A4-with-no-margins into the NEXT document printed, which for a markdown file is a
    /// page with no margins at all.
    ///
    /// 1. **The reader paginated it** (`printSheets` non-empty) — the paper IS the document's own
    ///    sheet and the margins are ZERO, because the document's margins are already inside the laid
    ///    out text: the left/right ones as `textContainerInset` and the top/bottom ones as the band
    ///    between pages (invariant 57e). Adding printer margins on top would inset the page twice.
    ///    Scaling is 1 and both paginations are `.clip`, so nothing AppKit does can resize the view —
    ///    `.fit` would scale the sheet to the printer's imageable width and silently change every
    ///    measurement the paged work exists to preserve.
    /// 2. **Paged, but the reader did not paginate** (no header or footer, so no band) — take the
    ///    paper and the two vertical margins from the document and let `NSTextView`'s own line-aware
    ///    pagination break the text. The horizontal margins stay 0 for case 1's reason.
    /// 3. **Not paged** (markdown, plain text, an office document with no page width) — unchanged
    ///    from before printing knew what a page was.
    ///
    /// The magnification does NOT need undoing here, which was worth measuring rather than assuming:
    /// `scrollView.magnification` is a transform on the CLIP view's bounds, and the text view's own
    /// `bounds`/`frame` are identical at 1.0 and at 1.8 (measured on the reference report, both
    /// 595.3 × 6493.9). Printing the text view therefore prints it at actual size. `PrintPaginationTests`
    /// pins that, so a future zoom implementation that DID move the view's own geometry is caught here
    /// rather than on paper.
    /// Whether the document is currently laid out for PAPER rather than for the window.
    private var printLayoutApplied = false

    /// Lay the document out the way paper needs it, whatever the View menu currently says.
    ///
    /// **A paged document has pages even when the reader has switched the outline off** — the page
    /// breaks are the FILE's, not a viewing preference — so a printout taken while the outline is off
    /// would otherwise come out as one continuous run with no header, no footer and no page margins.
    /// Printing therefore always applies the paged shape (`applyPageBand(forPrinting:)`), which also
    /// drops the desk gap: see that function for the measured text loss it causes on paper.
    ///
    /// Restored by `endPrintLayout` once the job is over. Idempotent — a second call does nothing, so
    /// a caller that prepares and a caller that also prints cannot re-lay the document twice.
    func beginPrintLayout() {
        guard !printLayoutApplied, let doc = mdDocument, doc.officePageContentWidth != nil,
              let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        printLayoutApplied = true
        doc.applyPageBand(to: self, forPrinting: true)
        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                            actualCharacterRange: nil)
        if let tc = textView.textContainer { lm.ensureLayout(for: tc) }
    }

    /// Put the window's own layout back after a print job — the reader must not be left holding the
    /// paper shape when its View menu says otherwise.
    func endPrintLayout() {
        guard printLayoutApplied, let doc = mdDocument,
              let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        printLayoutApplied = false
        let anchor = readingAnchor()
        doc.applyPageBand(to: self)
        applyPagedViewState()
        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                            actualCharacterRange: nil)
        if let tc = textView.textContainer { lm.ensureLayout(for: tc) }
        applyTrailingFooterBand()
        settlePagedTablesFully()
        restore(anchor)
        textView.needsDisplay = true
    }

    func makePrintOperation() -> NSPrintOperation {
        // Paper has pages whether or not the reader is drawing them, so the paged shape goes on
        // FIRST — before the settle, which depends on the band it produces.
        beginPrintLayout()
        // ⌘P can arrive before the asynchronous settle has finished — on a document just opened, or
        // straight after a re-render. Paper cannot show an overrun honestly the way the screen can
        // (`PagePagination.joiningUnopenedBoundaries`), so the tables are settled here first.
        settlePagedTablesFully()
        applyTrailingFooterBand()
        // Paper has no viewport. Pixels are held only for what is near the reader (invariant 1's lazy
        // scheme), so a document printed without ever having been scrolled through prints blank space
        // where its pictures are — measured as ONE image in a 50-page PDF of a report carrying 28.
        // Both print paths come through here, so ⌘P and `--pdf` are fixed by the same call.
        mdDocument?.reconcileMedia(in: self, loadingEverything: true)
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.scalingFactor = 1
        if let first = printSheets.first, let width = pagedDocumentWidth {
            // The SHEET's height, not the pitch: while the page outline is on, the band also carries
            // the desk between two drawn sheets, and desk is not paper. Taken from the sheet itself
            // so the paper can never be a different size from the rectangle `rectForPage` hands back.
            info.paperSize = NSSize(width: width, height: first.height)
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            info.horizontalPagination = .clip
            info.verticalPagination = .clip
        } else if let width = pagedDocumentWidth, let body = pagedHeight {
            let top = pagedMarginTop ?? 0
            let bottom = pagedMarginBottom ?? 0
            info.paperSize = NSSize(width: width, height: top + body + bottom)
            info.topMargin = top; info.bottomMargin = bottom
            info.leftMargin = 0; info.rightMargin = 0
            info.horizontalPagination = .clip
            info.verticalPagination = .automatic
        } else {
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
        }
        // A document starts at the top of the page, always. `NSPrintInfo` centres BOTH ways by
        // default, which nothing here ever turned off — so a file whose text did not fill a sheet
        // printed floating in the middle of it, which reads as a layout accident rather than a
        // document. Set on every branch, not just the unpaged one: a paged document's rects are
        // exactly paper-sized so centring is a no-op for it today, and leaving the flags at AppKit's
        // default would make that a silent dependency on rects never being smaller than the sheet.
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        let op = NSPrintOperation(view: textView, printInfo: info)
        op.jobTitle = (document as? NSDocument)?.fileURL?.lastPathComponent ?? "Document"
        return op
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window = window else { return }
        // Code-block overlays (Copy/Wrap buttons, no-wrap scrollers, dividers) are live subviews;
        // hide them so the printout shows clean code cards, then restore after the panel closes.
        printRestore = codeOverlays.map { ($0, $0.isHidden) }
        codeOverlays.forEach { $0.isHidden = true }
        // The whole document has to be laid out before its last page can be located — asking for the
        // last glyph mid-walk is invariant 49's freeze. `precomputeLayout` normally has this done
        // long before a reader reaches ⌘P; this is the one call that must not depend on that.
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        applyTrailingFooterBand()
        let op = makePrintOperation()
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printRestore.forEach { $0.0.isHidden = $0.1 }
        printRestore = []
        endPrintLayout()   // the window goes back to whatever the View menu asked for
    }

    // MARK: - Shortcut guide (?, Help menu)

    private static var guidePanel: NSPanel?

    @objc func showShortcutGuide(_ sender: Any?) {
        if let p = Self.guidePanel { p.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Keyboard Shortcuts"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 640))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 24, height: 22)
        tv.textStorage?.setAttributedString(Self.guideText())
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        panel.contentView = scroll
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        Self.guidePanel = panel
    }

    private static func guideText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let head = NSFont.boldSystemFont(ofSize: 12)
        let body = NSFont.systemFont(ofSize: 13)
        let key  = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 160)]
        para.defaultTabInterval = 160
        para.lineSpacing = 4
        para.paragraphSpacing = 2
        func section(_ title: String) {
            out.append(NSAttributedString(string: "\n\(title)\n",
                attributes: [.font: head, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        }
        func row(_ k: String, _ desc: String) {
            out.append(NSAttributedString(string: k + "\t",
                attributes: [.font: key, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
            out.append(NSAttributedString(string: desc + "\n",
                attributes: [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
        }
        func note(_ text: String) {
            out.append(NSAttributedString(string: text + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        }
        section("Navigation")
        note("Down the page: fn steps the # outline · ⌘ every heading · ⌥ pages · fn⌘ to the ends")
        row("fn↑ / fn↓", "Previous / next top-level (#) heading")
        row("⌘↑ / ⌘↓", "Previous / next heading (any level)")
        row("⌥↑ / ⌥↓", "Page up / down  (a few lines overlap, so you can find your place)")
        row("fn⌘↑ / fn⌘↓", "Document start / end")
        row("⌘← / ⌘→", "Start / end of the line")
        row("⌥← / ⌥→", "Previous / next sentence")
        row("fn← / fn→", "Previous / next paragraph")
        row("⇧ + any of these", "Same move, selecting what it crosses")
        row("Space / ⇧Space", "Page down / up")
        row("↑ ↓ ← →", "Move the reading cursor one line/char")
        section("File")
        row("⌘O", "Open");  row("⌘W", "Close tab");  row("⌘R", "Reload from disk");  row("⌘P", "Print")
        section("Find & copy")
        row("⌘F", "Find in document");  row("⌘C", "Copy selection");  row("⌘A", "Select all")
        section("Zoom (text)")
        row("⌘+ / ⌘−", "Increase / decrease font size");  row("⌘0", "Actual size")
        section("Window")
        row("⌘M", "Minimize")
        row("⌥⌘← / ⌥⌘→", "Previous / next tab  (⌃⇥ / ⌃⇧⇥ also work)")
        row("⌘1 … ⌘8", "Jump straight to that tab");  row("⌘9", "The last tab")
        section("Page view (Word / ODT / HWP)")
        row("⌥⌘P", "Show each page as a sheet — off, the document runs continuously")
        row("View menu", "Header and Footer can be hidden the same way")
        section("Mouse")
        row("Click link / path", "Open a URL, file, or folder")
        row("⌘-Click selection", "Open the selected text as a link / path / file")
        row("Click left margin", "Copy that whole block (or section, beside a heading)")
        row("Right-click selection", "Copy · Open · Edit… (edit that block's markdown source)")
        row("E · I · D", "Edit · Insert below · Delete — the block at the reading cursor")
        row("Select blocks, then E", "Edit them together — one popup with the merged source")
        row("U · J", "Move that block up · down (⌘Z undoes each step)")
        row("Right-click a block", "The same four, on the block under the pointer")
        row("⌘S", "Save — edits stay in memory until you do")
        row("T", "Table of contents (Markdown with headings) — click a heading to jump")
        row("⌘N", "New file — asks for Markdown or plain text")
        row("Click a diagram / formula / image", "Open it enlarged in a zoomable window")
        row("Wrap / Copy button", "Toggle a code block's wrapping / copy its code")
        section("Diagram window")
        row("Pinch  or  ⌘+ / ⌘−", "Zoom in / out");  row("⌘0", "Fit to window")
        row("Drag", "Move around (pan)");  row("esc", "Close the zoom window")
        section("Help")
        row("?", "Show this guide")
        return out
    }
}

/// A non-interactive right-edge fade (clear → card background) that signals horizontal
/// overflow in a no-wrap code block. Overrides hitTest so it never intercepts scrolling.
final class EdgeFadeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let bg = Palette.codeCardBg
        let gradient = NSGradient(colors: [bg.withAlphaComponent(0), bg])!
        gradient.draw(in: bounds, angle: 0)   // 0° = clear on the left, solid at the right edge
    }
}
