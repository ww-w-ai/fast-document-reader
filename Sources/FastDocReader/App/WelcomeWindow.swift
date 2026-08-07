import AppKit

/// Whether the first-run guide still wants to appear.
///
/// Global (not per document) and in `UserDefaults`, because the tick has to survive a relaunch —
/// a "don't show this again" that forgets is worse than no tick at all.
enum WelcomeStore {
    static let key = "fmd.showsWelcomeOnLaunch"

    /// `UserDefaults.bool(forKey:)` answers `false` for a key that was never written, which would
    /// hide the guide from the only reader it exists for — the one who has never launched this
    /// before. Absent means SHOW; only an explicit tick writes `false`.
    static var showsOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

/// The first-run guide, in two steps that are walked in order: **what this app is**, then **the one
/// setting worth changing on day one**.
///
/// Two steps rather than one screen with a button, because the default-app claim is the thing a new
/// reader does not know to look for — "설치해도 md 가 그대로 기존 프로그램으로 열림" is what the
/// single-screen version left people with. The tick that suppresses the guide lives on step 2, so
/// closing the window at step 1 does NOT count as having seen it and it comes back next launch.
/// That is the whole enforcement: no trapping, no disabled close box, just a guide that has not
/// finished until the reader has been shown both halves.
final class WelcomeWindowController: NSWindowController {

    /// One instance, so choosing the menu item twice raises the existing window instead of stacking
    /// a second copy of it behind the first.
    private static var shared: WelcomeWindowController?

    /// Internal, with the step readable, so a test can prove the guide OPENS on step 1 and that
    /// leaving there writes nothing — the two halves of "you have to walk both steps" that no
    /// compiler can see.
    enum Step { case whatItIs, defaults }

    private(set) var step: Step = .whatItIs
    private var container: NSView!
    private var picker: DefaultAppPicker!
    private(set) var dontShowAgain: NSButton!

    static func present() {
        if let existing = shared, let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = WelcomeWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 100),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        container = NSView()
        window.contentView = container
        show(.whatItIs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Step 1 content

    private struct Point {
        let heading: String
        let body: String
    }

    /// Written for someone who has just installed this and has no idea why it differs from the
    /// reader they already had. Each point is a thing the app DOES, not an adjective.
    private static let points: [Point] = [
        Point(heading: "It opens what other readers hand off",
              body: "Markdown, Word (.docx), OpenDocument (.odt), Hangul (.hwp, .hwpx), plain text, "
                  + "CSV and source code — in one window, laid out from each document's own styles "
                  + "rather than a look of ours."),
        Point(heading: "Word, ODT and HWP keep their pages",
              body: "Page size, margins, running headers and page numbers come from the file, so "
                  + "what you read is what the author set. ⌘P prints exactly those pages."),
        Point(heading: "Everything is real text",
              body: "⌘F finds words inside table cells, and you can select and copy straight out of "
                  + "a table. Nothing here is a picture of a document."),
        Point(heading: "It stays out of the way",
              body: "No conversion step, no web view, no sign-in. Every keyboard shortcut is under "
                  + "Help ▸ Keyboard Shortcuts."),
    ]

    // MARK: - Assembling a step

    private func show(_ step: Step) {
        self.step = step
        container.subviews.forEach { $0.removeFromSuperview() }
        window?.title = step == .whatItIs
            ? "Welcome to \(AppDelegate.appDisplayName)  —  Step 1 of 2"
            : "Welcome to \(AppDelegate.appDisplayName)  —  Step 2 of 2"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch step {
        case .whatItIs:  fill(stack, forStepOne: ())
        case .defaults:  fill(stack, forStepTwo: ())
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if container.constraints.first(where: { $0.firstAttribute == .width }) == nil {
            container.widthAnchor.constraint(equalToConstant: 560).isActive = true
        }
        container.layoutSubtreeIfNeeded()
        window?.setContentSize(container.fittingSize)
    }

    private func fill(_ stack: NSStackView, forStepOne _: Void) {
        stack.addArrangedSubview(Self.wrappingLabel(
            "A native reader for the documents you actually get — no conversion step, no web view.",
            size: 13, secondary: true))
        for point in Self.points { stack.addArrangedSubview(Self.makePoint(point)) }
        stack.addArrangedSubview(NSBox.horizontalRule())

        let next = NSButton(title: "Continue", target: self, action: #selector(goToDefaults))
        next.bezelStyle = .rounded
        next.keyEquivalent = "\r"
        Self.addButtonRow(leading: nil, trailing: [next], to: stack)
    }

    private func fill(_ stack: NSStackView, forStepTwo _: Void) {
        stack.addArrangedSubview(Self.wrappingLabel(
            "Set \(AppDelegate.appDisplayName) as the default app", size: 15, weight: .semibold))
        stack.addArrangedSubview(Self.wrappingLabel(DefaultAppPicker.explanation,
                                                    size: 12, secondary: true))
        picker = DefaultAppPicker()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.heightAnchor.constraint(equalToConstant: picker.frame.height).isActive = true
        picker.widthAnchor.constraint(equalToConstant: picker.frame.width).isActive = true
        stack.addArrangedSubview(picker)
        stack.addArrangedSubview(NSBox.horizontalRule())

        dontShowAgain = NSButton(checkboxWithTitle: "Don’t show this again", target: nil, action: nil)
        let back = NSButton(title: "Back", target: self, action: #selector(goToWhatItIs))
        back.bezelStyle = .rounded
        let skip = NSButton(title: "Not Now", target: self, action: #selector(finishWithoutClaiming))
        skip.bezelStyle = .rounded
        let apply = NSButton(title: "Set as Default", target: self, action: #selector(applyAndFinish))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        Self.addButtonRow(leading: dontShowAgain, trailing: [back, skip, apply], to: stack)
    }

    // MARK: - Small view builders

    private static func wrappingLabel(_ text: String, size: CGFloat,
                                      weight: NSFont.Weight = .regular,
                                      secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        if secondary { label.textColor = .secondaryLabelColor }
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 500
        return label
    }

    private static func makePoint(_ point: Point) -> NSView {
        let stack = NSStackView(views: [wrappingLabel(point.heading, size: 13, weight: .semibold),
                                        wrappingLabel(point.body, size: 12, secondary: true)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    /// Adds the row and only THEN pins its width to the stack. Constraining before insertion throws
    /// (`no common ancestor`) — which is a crash on every open, not a layout blemish, and is what
    /// `testTheGuideOpensOnTheExplanation` caught.
    private static func addButtonRow(leading: NSView?, trailing: [NSView], to stack: NSStackView) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: ([leading, spacer] + trailing).compactMap { $0 })
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    // MARK: - Actions

    @objc func goToDefaults()  { show(.defaults) }
    @objc func goToWhatItIs()  { show(.whatItIs) }

    @objc private func finishWithoutClaiming() {
        persistChoice()
        window?.close()
    }

    @objc private func applyAndFinish() {
        persistChoice()
        let chosen = picker.chosen
        guard !chosen.isEmpty else { window?.close(); return }   // everything unticked = nothing to do
        let appName = AppDelegate.appDisplayName
        DefaultAppClaim.apply(chosen) { [weak self] failures in
            let outcome = DefaultAppClaim.outcomeMessage(failures: failures, appName: appName)
            let done = NSAlert()
            done.messageText = outcome.title
            done.informativeText = outcome.body
            done.addButton(withTitle: "OK")
            done.runModal()
            self?.window?.close()
        }
    }

    /// The tick is persisted on the way OUT of step 2, whichever way the reader leaves it — a
    /// button or the red close box. Step 1 has no tick, so leaving there writes nothing and the
    /// guide is due again next launch.
    private func persistChoice() {
        guard step == .defaults, let dontShowAgain else { return }
        WelcomeStore.showsOnLaunch = (dontShowAgain.state != .on)
    }
}

extension WelcomeWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        persistChoice()
        WelcomeWindowController.shared = nil
    }
}

private extension NSBox {
    static func horizontalRule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
