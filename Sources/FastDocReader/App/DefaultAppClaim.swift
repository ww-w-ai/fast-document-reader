import AppKit
import UniformTypeIdentifiers

/// Making this app what the Finder opens a kind of file with.
///
/// One owner, because there are two doors into it — the App menu's panel and step 2 of the
/// first-run guide — and a second copy of the family list or of the read-back check is how the two
/// would come to disagree about what was claimed.
///
/// Offered, never taken. An app that makes itself the default handler on its own — at first launch
/// or otherwise — is hijacking a system-wide setting the user did not touch, which the App Store
/// rejects and users rightly resent. Everything here runs only when asked, and says exactly which
/// kinds of file it will claim before doing anything.
enum DefaultAppClaim {

    /// One tick per FAMILY, not per extension. A reader who wants Word documents opening here wants
    /// all of them, and a column of nine checkboxes is a form to fill in rather than a choice to
    /// make. Each group is claimed whole; its members are the distinct system types that family
    /// spans — `.md` and `.markdown` are ONE type, so a single member covers both.
    struct Group {
        let name: String
        let onByDefault: Bool
        /// `(declared id, extension)`. The id is only a fallback — `resolvedType` prefers whatever
        /// the extension really resolves to on THIS machine.
        let members: [(id: String, ext: String)]
    }

    static let groups: [Group] = [
        Group(name: "Markdown  (.md, .markdown)", onByDefault: true,
              members: [("net.daringfireball.markdown", "md")]),
        // `.docm`, `.dotx` and `.dotm` are OPENED by this app but deliberately not CLAIMED.
        // macOS 14 confirms each claim with its own dialog, per TYPE, and they stack — carrying
        // the three Word variants took this one tick from two system dialogs to five, and all four
        // families from six to twelve. The whole reason the list was grouped was that ticking
        // things one by one is a chore; trading nine checkboxes for a dozen dialogs is not a fix.
        // A reader who wants a `.dotm` bound here can do it per file with ⌘I in the Finder.
        Group(name: "Word and OpenDocument  (.docx, .odt)", onByDefault: false,
              members: [("org.openxmlformats.wordprocessingml.document", "docx"),
                        ("org.oasis-open.opendocument.text", "odt")]),
        Group(name: "Hangul  (.hwp, .hwpx)", onByDefault: false,
              members: [("com.hancom.hwp", "hwp"),
                        ("com.hancom.hwpx", "hwpx")]),
        // Same trade as the Word family: `.tsv` and `.log` are opened but not claimed. `.tsv` is
        // rare enough that a dialog for it is pure cost, and `.log` is `com.apple.log` — taking
        // the type Console owns is intrusive for a kind of file most people never double-click.
        Group(name: "Plain text and data  (.txt, .csv)", onByDefault: false,
              members: [("public.plain-text", "txt"),
                        ("public.comma-separated-values-text", "csv")]),
    ]

    /// How much of a family this app already owns. The middle case is the one worth having: a
    /// reader who set `.docx` by hand months ago and never heard of `.dotm` must be able to finish
    /// the job, which a plain already/not-already flag would have disabled.
    enum State { case claimed, partial, unclaimed }

    /// `isDefault` is injected so the decision is testable without touching this machine's real
    /// Launch Services database.
    static func state(of group: Group,
                      isDefault: (String, String) -> Bool = DefaultAppClaim.isDefault) -> State {
        let mine = group.members.filter { isDefault($0.ext, $0.id) }.count
        if mine == group.members.count { return .claimed }
        return mine == 0 ? .unclaimed : .partial
    }

    /// The type a file of this kind ACTUALLY gets on THIS machine, which is not always the
    /// identifier we declare. HWP is why this exists: `.hwp` is Hancom's type, so a Mac with their
    /// suite installed reports `com.haansoft.hancomofficeviewer.mac.hwp` while one without it falls
    /// to the `com.hancom.hwp` this app declares itself — and claiming the hardcoded one would make
    /// this app the default for a type no file on that machine is, which looks like nothing
    /// happening. `.docx` never showed the fault because its identifier is the same everywhere.
    /// The declared id is the fallback for the case the extension resolves to nothing at all.
    static func resolvedType(ext: String, id: String) -> UTType? {
        UTType(filenameExtension: ext) ?? UTType(id)
    }

    /// Whether this app is already what macOS opens the given kind with. Asked of the type the
    /// extension really resolves to, which is also what gets claimed — the two must agree or a
    /// claim that took would still read back as "not set".
    static func isDefault(ext: String, id: String) -> Bool {
        guard let type = resolvedType(ext: ext, id: id),
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        if current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return true }
        // Launch Services stores an IDENTIFIER, not a path, and resolves it back to whichever
        // registered copy of that identifier it prefers. A Mac that still knows an OLDER copy of
        // this app — one kept in the Trash, a download never removed, a second install — answers
        // with THAT path, and a path-only comparison then reads a claim macOS actually accepted as
        // a refusal. Measured here: approving the system dialog bound the identifier to a
        // different copy of this app, after which every attempt reported failure however often it
        // was pressed. Same identifier means the system does consider this app the handler.
        return Bundle(url: current)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Claims each family, then hands back the names of the ones macOS refused — SORTED, because a
    /// bare `Set` iterates in a per-process hash-randomised order and the same refusal would list
    /// its families differently on each run (invariant 50's lesson, from a second direction).
    /// How long a claim is given to appear in Launch Services before it counts as refused: eight
    /// looks a quarter-second apart, so two seconds. Long enough for the commit that lags the
    /// completion handler, short enough that a genuine refusal still answers while the reader is
    /// looking at the dialog they just dismissed.
    static let settleAttempts = 8
    static let settleInterval: TimeInterval = 0.25

    static func apply(_ families: [Group], completion: @escaping ([String]) -> Void) {
        let appURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        // The completion handlers come back on whatever queue AppKit chooses, so the tally is
        // guarded — several landing at once would otherwise corrupt the set.
        let lock = NSLock()
        var failures: Set<String> = []
        func note(_ name: String) { lock.lock(); failures.insert(name); lock.unlock() }
        let waiting = DispatchGroup()
        // Reported by FAMILY, because that is the unit the reader ticked. One refused member names
        // the whole family — a Hangul group half set and silent would read as done.
        for family in families {
            for member in family.members {
                guard let type = resolvedType(ext: member.ext, id: member.id) else {
                    note(family.name); continue
                }
                // Already ours: asking again would put the system's own confirmation dialog up
                // for a change that is not a change. The families arriving here include the ones
                // shown ticked-and-disabled, so this is what keeps that from costing a dialog.
                if isDefault(ext: member.ext, id: member.id) { continue }
                waiting.enter()
                // Report SUCCESS only after reading the association back. macOS can answer noErr
                // and change nothing when another installed app owns the type — measured on .hwp
                // against Hancom's suite — so trusting the return value would tell the user it
                // worked while the Finder still opens the file elsewhere.
                //
                // And read it back MORE THAN ONCE. Launch Services commits the change AFTER the
                // completion handler runs, so a single immediate read can still answer with
                // whatever was default a moment earlier. Measured on the shipped build: the app
                // announced "Done. Those files now open in FastDoc." while the Finder went on
                // opening markdown in Xcode — the reader is then told the setting took, sees that
                // it did not, and has no way to tell the two apart.
                func settle(_ attempt: Int) {
                    if isDefault(ext: member.ext, id: member.id) { waiting.leave(); return }
                    guard attempt < settleAttempts else { note(family.name); waiting.leave(); return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + settleInterval) {
                        settle(attempt + 1)
                    }
                }
                // The FIRST read waits too. Asked the instant the completion handler runs, Launch
                // Services can answer with the change it has accepted but not yet committed — which
                // is how the shipped build came to announce "Done. Those files now open in FastDoc."
                // over a machine whose Finder went on opening markdown in Xcode. Letting the first
                // look land after the same quarter-second as the retries costs nothing and makes a
                // success claim mean the association was still ours a moment later.
                func begin() {
                    DispatchQueue.global().asyncAfter(deadline: .now() + settleInterval) { settle(0) }
                }
                if #available(macOS 14.0, *) {
                    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { _ in begin() }
                } else {
                    _ = LSSetDefaultRoleHandlerForContentType(
                        type.identifier as CFString, .all, bundleID as CFString)
                    begin()
                }
            }
        }
        waiting.notify(queue: .main) { completion(failures.sorted()) }
    }

    /// The outcome sentence both doors show. Reported either way: a settings change with no visible
    /// result leaves the reader unsure whether it took, and macOS can refuse one (a managed Mac).
    static func outcomeMessage(failures: [String], appName: String) -> (title: String, body: String) {
        failures.isEmpty
            ? ("Done", "Those files now open in \(appName).")
            : ("Partly done",
               "macOS declined to change:\n\n\(failures.map { "•  " + $0 }.joined(separator: "\n"))"
               + "\n\nYou can set these per file with ⌘I in the Finder.")
    }
}

/// The tick list itself, shared by the App menu's alert and step 2 of the first-run guide so the
/// two cannot offer different families or disagree about which are already set.
///
/// Frame-based rather than constraint-based because one of its two homes is an `NSAlert`
/// accessory view, which is sized from `frame` and never lays out its accessory itself.
final class DefaultAppPicker: NSView {

    static let explanation =
        "Double-clicking a ticked kind of file in the Finder will open it here. "
        + "To undo this later, select a file in the Finder, press ⌘I, and pick another app "
        + "under “Open with”."

    private static let rowHeight: CGFloat = 26
    /// The alert sizes its accessory from this; the first-run guide passes its own content width so
    /// the list fills the window instead of leaving a ragged empty column beside it.
    static let alertWidth: CGFloat = 420

    private var boxes: [(button: NSButton, group: DefaultAppClaim.Group)] = []

    /// Families the reader has ticked and that are not already fully ours.
    var chosen: [DefaultAppClaim.Group] { boxes.filter { $0.button.state == .on }.map(\.group) }

    init(width: CGFloat = DefaultAppPicker.alertWidth,
         isDefault: @escaping (String, String) -> Bool = DefaultAppClaim.isDefault) {
        super.init(frame: NSRect(x: 0, y: 0, width: width,
                                 height: Self.rowHeight * CGFloat(DefaultAppClaim.groups.count)))
        for (i, group) in DefaultAppClaim.groups.enumerated() {
            let state = DefaultAppClaim.state(of: group, isDefault: isDefault)
            let suffix: String
            switch state {
            case .claimed:   suffix = "  — already set"
            case .partial:   suffix = "  — partly set"
            case .unclaimed: suffix = ""
            }
            let button = NSButton(checkboxWithTitle: group.name + suffix, target: nil, action: nil)
            // A family this app ALREADY owns is shown ticked and disabled: unticking could not undo
            // it (macOS has no "no default app" — some other app has to claim it), and a control
            // that looks like it undoes something but doesn't is worse than no control.
            button.state = (state != .unclaimed || group.onByDefault) ? .on : .off
            button.isEnabled = (state != .claimed)
            // Top-down reading order in a bottom-up coordinate system.
            button.frame = NSRect(x: 0,
                                  y: CGFloat(DefaultAppClaim.groups.count - 1 - i) * Self.rowHeight,
                                  width: width, height: Self.rowHeight - 4)
            addSubview(button)
            // EVERY family goes in the list, the already-ours ones included. They arrive at
            // `apply` ticked and are skipped there without a system dialog, and that is the point:
            // when this reads "already set" WRONGLY — Launch Services answers a stale yes for a
            // while after a claim — leaving the family out would make the button claim nothing at
            // all and still report success, which is the dead end a reader hits by pressing it
            // again. Keeping it in means the second press re-asks the question.
            boxes.append((button, group))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
