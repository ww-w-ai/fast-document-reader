import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The two menus this object is the delegate of. Held so `menuNeedsUpdate` can tell them apart by
    // IDENTITY rather than by title: its Open Recent branch begins with `removeAllItems()`, and one
    // menu arriving at the wrong branch would empty the View menu instead of retitling it. An
    // unrecognised menu does nothing, which is the safe direction to fail in.
    // (`NSMenu.delegate` is not a strong reference, so holding the menu here is not a cycle.)
    private var recentMenu: NSMenu?
    private var viewMenu: NSMenu?

    /// The three View-menu items whose MEANING depends on the document, with the wording for each
    /// model. A paged document (one that declared a page body width — docx/odt/HWP) is shown at its
    /// own scale and ZOOMED, so ⌘0 returns it to the zoom it OPENED at
    /// (`DocumentWindowController.defaultPageZoom`, 120% — the band Word, Pages and Hancom's viewer
    /// occupy) and brings the window back with it. It does not return to 100%, which is what made the
    /// shipped title "Actual Size" a lie — and "Zoom to Fit" was the second wording to overpromise,
    /// since the reset is a fixed zoom rather than a fit. Everything else — markdown, plain text, an
    /// office document whose reader found no page width — still changes a reading font size.
    ///
    /// Titles only. The selectors and key equivalents are identical either way, deliberately:
    /// `MarkdownDocument` already forks on paged-ness at the top of the responder chain, so the menu
    /// has nothing to route and only has to stop describing the wrong one of the two.
    private var sizeMenuItems: [(item: NSMenuItem, fontTitle: String, zoomTitle: String)] = []

    // MUST stay false. After its last document closes, the app returns to a windowless menu-bar
    // state — a normal, intended resting state, not a reason to quit. This matters more now that
    // launch presents the Open panel (invariant 43): returning true here would let DISMISSING that
    // panel (it counts as the "last window") trip last-window-closed → quit. With false, closing the
    // last document — or cancelling the launch panel — returns to the menu-bar state; quitting is ⌘Q only.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Opt out of state restoration entirely: no previously-open documents are reopened on launch,
    // so the app always starts clean (closing / quitting never leaves old tabs behind).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // A regular macOS app MUST present an interactive window on launch — App Store review rejects
        // a launch that shows only the menu bar (2.1 App Completeness: "No interactive window
        // displayed upon launch"). A reader has no "new document" concept, so — like shipping App
        // Store markdown readers — launched with NO document we pop the Open panel; cancelling returns
        // to the menu-bar-only state (fine, and what those apps do). Deferred one run-loop turn so a
        // file passed AT launch opens its own window first and suppresses the panel.
        DispatchQueue.main.async { [weak self] in
            guard NSDocumentController.shared.documents.isEmpty,
                  !NSApp.windows.contains(where: { $0.isVisible }) else { return }
            self?.openDocumentPanel(nil)
        }
    }

    // No untitled ("new blank") documents — this is a read-only viewer, there is nothing to create.
    // The launch Open panel above (not this hook) is what satisfies "show a window on launch".
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // A SwiftPM executable has no MainMenu.nib, so build the menu bar in code. Without it,
    // standard shortcuts (⌘Q/⌘O/⌘W/⌘C/⌘F/⌘±) and the native Window/tabs menu don't work.
    private func buildMenu() {
        // The user-facing name comes from the bundle (so a dev build reads "Fast Document Reader
        // (Dev)"), NOT a hardcoded literal — the literal here was the pre-rename "fast-md-reader",
        // showing the retired name in the very first menu item.
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Fast Document Reader"
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        // Custom About action so the panel can show the exact BUILD (git commit + date) this bundle was
        // made from — the marketing version alone can't tell a dev rebuild from the release.
        let about = appMenu.addItem(withTitle: "About \(appName)", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        // Offered, never taken. An app that makes itself the default handler on its own — at first
        // launch or otherwise — is hijacking a system-wide setting the user didn't touch, which the
        // App Store rejects and users rightly resent. This does it only when asked, and says
        // exactly which kinds of file it will claim before doing anything.
        let defaults = appMenu.addItem(withTitle: "Set as Default App…",
                                       action: #selector(offerToBecomeDefault(_:)), keyEquivalent: "")
        defaults.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        // Open… — do NOT use NSDocumentController.openDocument(_:) (its built-in panel path crashes
        // immediately in this code-menu / ad-hoc-signed SwiftPM app). Present our OWN NSOpenPanel and
        // route the result through openDocument(withContentsOf:) — the exact path Open Recent uses,
        // which is known-good.
        let newItem = fileMenu.addItem(withTitle: "New File…", action: #selector(newFileDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(openDocumentPanel(_:)), keyEquivalent: "o")
        openItem.target = self
        // Open Recent — AppKit's automatic population does NOT attach to a code-built menu (no
        // MainMenu.nib), so it stayed empty. Populate it ourselves from recentDocumentURLs via a
        // menu delegate that rebuilds on every open (menuNeedsUpdate).
        let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        self.recentMenu = recentMenu
        let close = fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        // Edits live in memory until this. Closing with unsaved changes gets AppKit's own
        // Save / Don't Save / Cancel sheet, because the document now reports itself as dirty.
        fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        // Sandboxed build only: the App Store sandbox blocks a document's own sibling images until
        // the user grants the folder. Clicking a blocked image does the same thing; this is the
        // discoverable route when none is on screen.
        if FolderAccess.isNeeded {
            fileMenu.addItem(withTitle: FolderAccess.grantMenuTitle,
                             action: #selector(DocumentWindowController.grantFolderAccess(_:)), keyEquivalent: "")
        }
        fileMenu.addItem(withTitle: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")

        // Edit menu (copy / select-all / find)
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: #selector(MarkdownDocument.undoSourceEdit(_:)),
                         keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(MarkdownDocument.redoSourceEdit(_:)),
                                    keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        // Cut / Paste exist for the source-edit popup's text view (a real editable field). Without
        // Paste in the menu, ⌘V never reached that popup at all — a code-built menu gets NO automatic
        // Edit items, so each must be added by hand, and only Copy was. They route to the first
        // responder: in the reader that is the read-only view, which rejects every mutation
        // (`shouldChangeTextIn` → false), so both are inert there and only work in the popup.
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = 1 // NSFindPanelAction.showFindPanel → shows the find bar (usesFindBar)

        // View menu (size — a font size, or a page zoom; see `sizeMenuItems`)
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        let increase = viewMenu.addItem(withTitle: "Increase Font Size", action: Selector(("increaseReaderFontSize:")), keyEquivalent: "+")
        let decrease = viewMenu.addItem(withTitle: "Decrease Font Size", action: Selector(("decreaseReaderFontSize:")), keyEquivalent: "-")
        let actual = viewMenu.addItem(withTitle: "Actual Size", action: Selector(("resetReaderFontSize:")), keyEquivalent: "0")
        // Same three items, two vocabularies — retitled in `menuNeedsUpdate` from the key document.
        sizeMenuItems = [(increase, "Increase Font Size", "Zoom In"),
                         (decrease, "Decrease Font Size", "Zoom Out"),
                         (actual, "Actual Size", "Default Zoom")]
        viewMenu.delegate = self
        self.viewMenu = viewMenu
        viewMenu.addItem(.separator())
        // Table of contents — markdown with headings only; the window controller validates it, so
        // it greys out for a .txt or a document that has no headings rather than opening empty.
        let toc = viewMenu.addItem(withTitle: "Table of Contents",
                                   action: Selector(("toggleTableOfContents:")), keyEquivalent: "t")
        toc.keyEquivalentModifierMask = []   // a bare letter, like the block keys E/I/D/U/J
        // P6b: comments panel — greyed out (`validateMenuItem`) for any document that has none.
        let comments = viewMenu.addItem(withTitle: "Comments",
                                        action: Selector(("toggleComments:")), keyEquivalent: "c")
        comments.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        // Page furniture for a PAGED document (docx/odt/hwp with a declared page) — three independent
        // toggles, checked rather than retitled so all three states read at a glance. Greyed out
        // (`DocumentWindowController.validateMenuItem`) for markdown, plain text, and any office
        // document whose reader found no page width: those have no paper to show or hide. Global, not
        // per window — see `PageViewOptions`.
        let pageOutline = viewMenu.addItem(withTitle: "Page Outline",
                                           action: Selector(("togglePageOutline:")), keyEquivalent: "p")
        pageOutline.keyEquivalentModifierMask = [.command, .option]   // ⌘P is Print
        viewMenu.addItem(withTitle: "Header", action: Selector(("togglePageHeader:")), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Footer", action: Selector(("togglePageFooter:")), keyEquivalent: "")
        // What happens to a table that will not finish on its page: break it where it stands, or carry
        // it whole to the next one. A table TALLER than the page is always broken whatever this says —
        // there is no whole page to carry it to (invariant 64).
        viewMenu.addItem(withTitle: "Split Tables Across Pages",
                         action: Selector(("toggleSplitTables:")), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Reload", action: Selector(("reloadDocument:")), keyEquivalent: "r")

        // Window menu (minimize, zoom, native tabs)
        let windowItem = NSMenuItem(); mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        // Tab navigation. ⌃⇥ / ⌃⇧⇥ already work — AppKit binds them to the tab group itself — but
        // they are the SYSTEM's cycle order and there is no way to reach a specific tab with them.
        // `NSWindow.selectNextTab(_:)`/`selectPreviousTab(_:)` are AppKit's own responder actions, so
        // these two items need no code of ours; only the numbered jumps do.
        let nextTab = windowMenu.addItem(withTitle: "Show Next Tab",
                                         action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\u{2192}")
        nextTab.keyEquivalentModifierMask = [.command, .option]
        let prevTab = windowMenu.addItem(withTitle: "Show Previous Tab",
                                         action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\u{2190}")
        prevTab.keyEquivalentModifierMask = [.command, .option]
        // ⌘1…⌘9. In a code-built menu a key equivalent only exists if a menu item carries it, so
        // these are real items rather than key handling in the text view — which also makes them
        // discoverable and lets `validateMenuItem` grey out a tab that isn't open. Kept in a submenu
        // so nine entries don't bury Minimize and Zoom. ⌘9 is the LAST tab, not the ninth, which is
        // what every browser does and what a reader with four tabs open expects.
        let goToItem = windowMenu.addItem(withTitle: "Go to Tab", action: nil, keyEquivalent: "")
        let goToMenu = NSMenu(title: "Go to Tab")
        for n in 1...9 {
            let item = goToMenu.addItem(withTitle: n == 9 ? "Last Tab" : "Tab \(n)",
                                        action: Selector(("goToTab:")), keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = n
        }
        goToItem.submenu = goToMenu
        NSApp.windowsMenu = windowMenu

        // Help menu — Keyboard Shortcuts guide (also opens with the "?" key in the reader).
        let helpItem = NSMenuItem(); mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help"); helpItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: Selector(("showShortcutGuide:")), keyEquivalent: "?")
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    /// The window controller a nil-targeted View-menu action will actually reach. The chain starts at
    /// the KEY window, so that is what the menu must describe; `mainWindow` covers the moment a sheet
    /// or the find bar holds key while the document behind it is still the one being read.
    ///
    /// The ordered-windows fallback is not belt and braces — it is the only arm that answers while the
    /// app is INACTIVE, where `keyWindow` and `mainWindow` are BOTH nil. Measured, not assumed: with
    /// only the first two arms, a running app holding one paged document reported no controller at
    /// all and titled itself "Increase Font Size" — the exact wrong answer this exists to remove.
    /// A menu can be read while the app is inactive (Accessibility does it), so the answer has to
    /// hold there too.
    ///
    /// Nil — no document window at all — reads as "not paged", which leaves the shipped font wording
    /// in place.
    private var keyDocumentController: DocumentWindowController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let controller = window?.windowController as? DocumentWindowController { return controller }
        }
        return NSApp.orderedWindows.lazy
            .compactMap { $0.windowController as? DocumentWindowController }
            .first
    }

    // MARK: - New file

    /// ⌘N. Asks which kind first, because the answer changes what the document IS here — markdown
    /// is parsed into blocks, plain text is kept line for line — and picking wrong means starting
    /// over. The choice is two buttons rather than a save panel with a type popup: the file has no
    /// home yet, and asking where to put something before knowing what it is gets the order wrong.
    @objc func newFileDocument(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New file"
        alert.informativeText = """
            Markdown is rendered — headings, lists, tables — and starts with a small outline to \
            edit. Plain text is shown exactly as typed, one block per line.

            It is saved when you press ⌘S; until then it lives only here.
            """
        alert.addButton(withTitle: "Markdown  (Untitled.md)")
        alert.addButton(withTitle: "Plain Text  (Untitled.txt)")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        let doc = MarkdownDocument()
        doc.prepareUntitled(markdown: choice == .alertFirstButtonReturn)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }

    // MARK: - Become the default app for text files (user-initiated only)

    /// The kinds this offer covers, and whether one is ticked to begin with. Only types macOS
    /// actually has a registered identity for — .conf/.env/.rst and friends resolve to a throwaway
    /// identity that no association can be pinned to, so promising them here would be a promise the
    /// system can't keep.
    ///
    /// Markdown starts ticked because that is what this app is for. The text kinds start clear:
    /// they are a capability, not the reason someone installed a Markdown reader, and quietly
    /// taking over every .csv on someone's Mac is not a favour.
    private static let claimable: [(name: String, id: String, onByDefault: Bool)] = [
        ("Markdown  (.md, .markdown)", "net.daringfireball.markdown", true),
        ("Word document  (.docx)", "org.openxmlformats.wordprocessingml.document", false),
        ("OpenDocument text  (.odt)", "org.oasis-open.opendocument.text", false),
        ("Plain text  (.txt)", "public.plain-text", false),
        ("Comma-separated values  (.csv)", "public.comma-separated-values-text", false),
        ("Tab-separated values  (.tsv)", "public.tab-separated-values-text", false),
        ("Log files  (.log)", "com.apple.log", false),
    ]

    /// The standard About panel, but with the build's git provenance in the version line. Marketing
    /// version (`CFBundleShortVersionString`) and build number (`CFBundleVersion`) are the
    /// same across a release and every local rebuild, so they can't answer "is the installed app the
    /// build I just made?". `FMDBuildInfo` — stamped by `make-app.sh` with the git short hash, a
    /// `-dirty` flag for uncommitted changes, and the build date — can. Absent (e.g. a raw `swift run`),
    /// the panel just falls back to the standard version line.
    @objc func showAboutPanel(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let build = Bundle.main.object(forInfoDictionaryKey: "FMDBuildInfo") as? String, !build.isEmpty {
            // Put the build stamp on its OWN line below the version, not in the version line's
            // parentheses: `.version = ""` drops the auto "(build number)", and the git hash · date
            // rides in `.credits`, which the panel lays out as a separate line under the version.
            options[.version] = ""
            options[.credits] = NSAttributedString(
                string: build,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc func offerToBecomeDefault(_ sender: Any?) {
        // A checkbox per kind, so the choice is the user's rather than a take-it-or-leave-it lump.
        // A kind this app ALREADY handles is shown ticked and disabled: unticking couldn't undo it
        // (macOS has no "no default app" — some other app has to claim it), and a control that
        // looks like it undoes something but doesn't is worse than no control.
        let rowHeight: CGFloat = 24
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340,
                                       height: rowHeight * CGFloat(Self.claimable.count)))
        var boxes: [(NSButton, String)] = []
        for (i, kind) in Self.claimable.enumerated() {
            let already = isDefaultApp(for: kind.id)
            let button = NSButton(checkboxWithTitle: already ? kind.name + "  — already set" : kind.name,
                                  target: nil, action: nil)
            button.state = (already || kind.onByDefault) ? .on : .off
            button.isEnabled = !already
            // Top-down reading order in a bottom-up coordinate system.
            button.frame = NSRect(x: 0, y: CGFloat(Self.claimable.count - 1 - i) * rowHeight,
                                  width: 340, height: rowHeight - 4)
            box.addSubview(button)
            if !already { boxes.append((button, kind.id)) }
        }

        let alert = NSAlert()
        alert.messageText = "Set fast-md-reader as the default app"
        alert.informativeText = "Double-clicking a ticked kind of file in the Finder will open it here. "
            + "To undo this later, select a file in the Finder, press ⌘I, and pick another app under “Open with”."
        alert.accessoryView = box
        alert.addButton(withTitle: "Set as Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let chosen = boxes.filter { $0.0.state == .on }.map { $0.1 }
        guard !chosen.isEmpty else { return }        // everything unticked = nothing to do
        applyDefaults(for: chosen)
    }

    /// Whether this app is already what macOS opens the given kind with.
    private func isDefaultApp(for identifier: String) -> Bool {
        guard let type = UTType(identifier),
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func applyDefaults(for identifiers: [String]) {
        let appURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        // The completion handlers come back on whatever queue AppKit chooses, so the tally is
        // guarded — several of them landing at once would otherwise corrupt the array.
        let lock = NSLock()
        var failures: [String] = []
        func note(_ name: String) { lock.lock(); failures.append(name); lock.unlock() }
        let group = DispatchGroup()
        for identifier in identifiers {
            let name = Self.claimable.first { $0.id == identifier }?.name ?? identifier
            guard let type = UTType(identifier) else { note(name); continue }
            group.enter()
            if #available(macOS 14.0, *) {
                NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                    if error != nil { note(name) }
                    group.leave()
                }
            } else {
                let status = LSSetDefaultRoleHandlerForContentType(
                    identifier as CFString, .all, bundleID as CFString)
                if status != noErr { note(name) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Report the outcome either way. A settings change with no visible result leaves the
            // user unsure whether it took — and macOS can refuse one (a managed Mac, say).
            let done = NSAlert()
            done.messageText = failures.isEmpty ? "Done" : "Partly done"
            done.informativeText = failures.isEmpty
                ? "Those files now open in fast-md-reader."
                : "macOS declined to change:\n\n\(failures.map { "•  " + $0 }.joined(separator: "\n"))\n\nYou can set these per file with ⌘I in the Finder."
            done.addButton(withTitle: "OK")
            done.runModal()
        }
    }

    // MARK: - Open… (own panel → known-good open path)

    @objc func openDocumentPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Markdown (rendered) + plain text (verbatim) — see DocumentTypes, the single list.
        panel.allowedContentTypes = DocumentTypes.openPanelTypes
        panel.allowsOtherFileTypes = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
    }

    // MARK: - Open Recent (manual population)

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The View menu: retitle the three size items for the document the keys will actually reach.
        // Done here rather than in a `validateMenuItem` because those items are nil-targeted — their
        // validation goes to whichever responder implements the selector (the document), not to this
        // object, so this file could never see it. Kept idempotent and free of side effects: this
        // pass runs whenever AppKit decides it needs the menu's current shape, which is more often
        // than "the user clicked View" (an Accessibility read of the menu triggers it too).
        if menu === viewMenu {
            let paged = keyDocumentController?.isPaged == true
            for entry in sizeMenuItems { entry.item.title = paged ? entry.zoomTitle : entry.fontTitle }
            return
        }
        // Rebuild the Open Recent submenu each time it opens: recent files first, then Clear Menu.
        // Invariant 7: `recentDocumentURLs` is read ONLY from here, so the branch above must return
        // before reaching it — the View menu opening is not a reason to spend a security-scoped
        // extension from the sandbox's limited pool.
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentDocument(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    }
}
