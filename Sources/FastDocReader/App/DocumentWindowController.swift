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
        guard let doc = documentView, doc.frame.width < rect.width else { return rect }
        rect.origin.x = (doc.frame.width - rect.width) / 2
        return rect
    }
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
                                     NSMenuItemValidation {
    // Explicit TextKit 1 stack (C2): building the view with init(frame:textContainer:)
    // guarantees the classic NSLayoutManager path instead of silently falling back
    // to TextKit 2 compatibility mode when layoutManager is later accessed.
    let textView: ReaderTextView
    private let scrollView = NSScrollView()
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
                self.textView.sizeToFit()
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
                            headerHeight: CGFloat = 0, footerHeight: CGFloat = 0) {
        pageBandDelegate.pageContentHeight = pageContentHeight ?? 0
        pageBandDelegate.band = band
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
        let firstPageHeader = PageBandPainter.applicableEntry(headers, pageIndex: 0)
        let leading: CGFloat = (firstPageHeader != nil && !(firstPageHeader?.blocks.isEmpty ?? true))
            ? headerHeight : 0
        let trailing: CGFloat = footerHeight > 0 ? footerHeight : 0
        pageBandDelegate.leadingBand = leading
        pageBandDelegate.trailingBand = trailing
        // A new render re-decides every boundary, so the previous pass's answers must not survive
        // into it — a stale entry would paint into a band this layout never made.
        pageBandDelegate.resetOpenedBoundaries()
        pageBandContent = band > 0
            ? PageBandContent(headers: headers, footers: footers, theme: theme, columnWidth: columnWidth,
                              documentDefaultFontSize: documentDefaultFontSize, pageContentWidth: pageContentWidth,
                              headerHeight: headerHeight, footerHeight: footerHeight,
                              leadingBand: leading, trailingBand: trailing,
                              pageMarginTop: pagedMarginTop, pageMarginBottom: pagedMarginBottom,
                              headerDistance: pagedHeaderDistance, footerDistance: pagedFooterDistance)
            : nil
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
        textView.sizeToFit()
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

    /// Set while the sidebar animates: width changes are ignored until it settles (see the toggle).
    private var suspendReflow = false

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
            textView.textContainerInset = NSSize(width: leftMargin, height: verticalInset)
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
            var f = textView.frame
            f.size.width = leftMargin + page + rightMargin
            textView.frame = f
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
            syncHorizontalScroller()
            return page
        }
        textView.autoresizingMask = [.width]
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
        textView.textContainerInset = NSSize(width: minSideInset, height: verticalInset)
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
    var pagedWidth: CGFloat? {
        guard let doc = document as? MarkdownDocument, let w = doc.officePageContentWidth, w > 0 else { return nil }
        return w
    }

    var isPaged: Bool { pagedWidth != nil }

    /// The page body HEIGHT this document declared, or nil — the vertical twin of `pagedWidth`, from
    /// `MarkdownDocument.officePageContentHeight`. NOT YET consumed by any layout pass: this is the
    /// prerequisite `officePageContentHeight`'s own doc comment describes (running headers/footers,
    /// showing where a page ends), and wiring it into `settleReadingColumn`'s vertical inset is a
    /// separate, measured change — see that function's hardcoded `verticalInset`.
    var pagedHeight: CGFloat? {
        guard let doc = document as? MarkdownDocument, let h = doc.officePageContentHeight, h > 0 else { return nil }
        return h
    }

    /// The page's own top/bottom margins, when its reader found them — the vertical twins of
    /// `pagedMarginLeft`/`pagedMarginRight`. Same non-consumption caveat as `pagedHeight`.
    private var pagedMarginTop: CGFloat? { (document as? MarkdownDocument)?.officePageMarginTop }
    private var pagedMarginBottom: CGFloat? { (document as? MarkdownDocument)?.officePageMarginBottom }
    /// The running header's/footer's own distance from the SHEET edge — see
    /// `OfficeReadResult.pageHeaderDistance`. Nil for a format that does not state it.
    private var pagedHeaderDistance: CGFloat? { (document as? MarkdownDocument)?.officePageHeaderDistance }
    private var pagedFooterDistance: CGFloat? { (document as? MarkdownDocument)?.officePageFooterDistance }

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
    private var pagedMarginLeft: CGFloat? { (document as? MarkdownDocument)?.officePageMarginLeft }
    private var pagedMarginRight: CGFloat? { (document as? MarkdownDocument)?.officePageMarginRight }

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
        guard let d = pagedDocumentWidth else { return }
        scrollView.hasHorizontalScroller = d * scrollView.magnification > scrollView.contentSize.width + 0.5
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
        syncHorizontalScroller()
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
              let doc = document as? MarkdownDocument, doc.kind == .office, column > 0 else { return }
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
        guard let doc = document as? MarkdownDocument else { return }
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
            self.reflow(keeping: anchor)
            self.reloadCommentPanel()
        }
    }

    /// Rebuild the panel's list from the current document — called from every place that renders
    /// (both `display(_:)` and the splice-edit path), the same "both render paths" discipline
    /// `reloadOutline()` follows (invariant 23), so the panel never shows a stale list.
    func reloadCommentPanel() {
        guard let doc = document as? MarkdownDocument else { commentPanel.reload(from: []); return }
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
        guard let doc = document as? MarkdownDocument, doc.kind == .office else {
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
        guard let doc = document as? MarkdownDocument, doc.kind == .office,
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
        return true
    }

    /// Enabled only where the panel means something: an office document that actually has
    /// comments. (Once open it stays enabled/toggle-able even if a later reload finds zero — same
    /// posture `guard !doc.officeComments.isEmpty || isCommentsVisible` already takes in the toggle
    /// itself, so the menu and the action never disagree about whether closing is allowed.)
    var canShowComments: Bool {
        guard let doc = document as? MarkdownDocument else { return false }
        return !doc.officeComments.isEmpty || isCommentsVisible
    }

    /// Enabled only where a table of contents means something: markdown, with headings in it.
    var canShowTableOfContents: Bool {
        guard let doc = document as? MarkdownDocument, !doc.isPlainText,
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
            applyTrailingFooterBand()
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
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
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
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, targetY), maxY)))
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
            (self.document as? MarkdownDocument)?.reconcileMedia(in: self)
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
        let readingSize = (document as? MarkdownDocument)?.readingSize ?? FontSizeStore.defaultSize
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
        let readingSize = (document as? MarkdownDocument)?.readingSize ?? FontSizeStore.defaultSize
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
        FolderAccess.requestAccess(to: FolderAccess.suggestedFolder(for: doc), in: window) { [weak self] granted in
            guard granted else { return }
            (self?.document as? MarkdownDocument)?.reloadDocument(nil)
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
        guard let storage = textView.textStorage, let doc = document as? MarkdownDocument else { return }
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
        guard let storage = textView.textStorage, let doc = document as? MarkdownDocument,
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
        guard let doc = document as? MarkdownDocument else { NSSound.beep(); return }
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
                clip.scroll(to: NSPoint(x: 0, y: min(y, max(0, textView.bounds.height - clip.bounds.height))))
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
        guard let storage = textView.textStorage, let doc = document as? MarkdownDocument,
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

    // MARK: - Print (⌘P)

    private var printRestore: [(NSView, Bool)] = []

    @objc func printDocument(_ sender: Any?) {
        guard let window = window else { return }
        // Code-block overlays (Copy/Wrap buttons, no-wrap scrollers, dividers) are live subviews;
        // hide them so the printout shows clean code cards, then restore after the panel closes.
        printRestore = codeOverlays.map { ($0, $0.isHidden) }
        codeOverlays.forEach { $0.isHidden = true }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let op = NSPrintOperation(view: textView, printInfo: info)
        op.jobTitle = (document as? NSDocument)?.fileURL?.lastPathComponent ?? "Document"
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printRestore.forEach { $0.0.isHidden = $0.1 }
        printRestore = []
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
        row("⌘M", "Minimize");  row("⌃⇥ / ⌃⇧⇥", "Next / previous tab")
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
