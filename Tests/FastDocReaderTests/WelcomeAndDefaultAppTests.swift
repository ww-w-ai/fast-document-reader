import XCTest
import AppKit
@testable import FastDocReader

/// The first-run guide and the grouped default-app claim.
///
/// Two seams here that no compiler can see, both invariant 29's shape: a preference that works
/// while nothing ever reads it, and a menu item that does not exist. Both are asserted directly.
final class WelcomeAndDefaultAppTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // `NSApp` is an implicitly-unwrapped global that stays nil until something asks for the
        // shared application — reading it first would trap, and which test runs first is alphabetical
        // rather than chosen.
        _ = NSApplication.shared
        WelcomeStore.reset()
    }

    override func tearDown() {
        WelcomeStore.reset()
        super.tearDown()
    }

    // MARK: - The guide's own preference

    /// The trap this store exists to avoid: `UserDefaults.bool(forKey:)` answers `false` for a key
    /// nobody has written, which would hide the guide from the only reader it is for.
    func testTheGuideIsDueWhenThePreferenceWasNeverWritten() {
        XCTAssertNil(UserDefaults.standard.object(forKey: WelcomeStore.key),
                     "precondition: the key must be absent for this test to mean anything")
        XCTAssertTrue(WelcomeStore.showsOnLaunch)
    }

    func testTickingDontShowAgainSticks() {
        WelcomeStore.showsOnLaunch = false
        XCTAssertFalse(WelcomeStore.showsOnLaunch)
        // And a reader who unticks it later gets it back — the tick is a preference, not a burn.
        WelcomeStore.showsOnLaunch = true
        XCTAssertTrue(WelcomeStore.showsOnLaunch)
    }

    // MARK: - The menu seam

    /// A guide nobody can reopen is a guide that is gone. Builds the real menu bar and looks for
    /// the item, restoring whatever the suite had before.
    func testTheHelpMenuOffersTheGuideAndItIsWired() throws {
        let savedMain = NSApp.mainMenu
        let savedHelp = NSApp.helpMenu
        defer { NSApp.mainMenu = savedMain; NSApp.helpMenu = savedHelp }

        let delegate = AppDelegate()
        delegate.buildMenu()

        let help = try XCTUnwrap(NSApp.helpMenu)
        let item = try XCTUnwrap(help.items.first { $0.title.hasPrefix("Welcome to ") },
                                 "the Help menu must offer the first-run guide")
        XCTAssertEqual(item.action, #selector(AppDelegate.showWelcomeWindow(_:)))
        XCTAssertTrue(item.target === delegate)
    }

    /// The other half of the same seam: the App menu's own entry point to the claim panel, which
    /// the guide's button routes to through the responder chain.
    func testTheAppMenuStillOffersTheDefaultAppPanel() {
        let savedMain = NSApp.mainMenu
        let savedHelp = NSApp.helpMenu
        defer { NSApp.mainMenu = savedMain; NSApp.helpMenu = savedHelp }

        let delegate = AppDelegate()
        delegate.buildMenu()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let item = appMenu?.items.first { $0.title == "Set as Default App…" }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.action, #selector(AppDelegate.offerToBecomeDefault(_:)))
    }

    // MARK: - The grouped claim

    /// Four ticks, not nine. The count is asserted because the whole point of the grouping was that
    /// a column of per-extension checkboxes is a form rather than a choice.
    func testTheClaimPanelOffersOneTickPerFamily() {
        XCTAssertEqual(DefaultAppClaim.groups.count, 4)
        XCTAssertEqual(DefaultAppClaim.groups.filter { $0.onByDefault }.map(\.name),
                       ["Markdown  (.md, .markdown)"],
                       "only Markdown is pre-ticked; everything else is opt-in")
    }

    /// Offering to claim a kind this app would then refuse to open is the `Info.plist` fault of
    /// invariant 69 reached from a third direction — here the promise is made in a dialog rather
    /// than in a plist, and it is just as wrong.
    func testEveryClaimableExtensionIsOneTheAppActuallyOpens() {
        for group in DefaultAppClaim.groups {
            for member in group.members {
                XCTAssertTrue(DocumentTypes.opensInApp(member.ext),
                              "\(group.name) offers .\(member.ext), which this app does not open")
            }
        }
    }

    /// Names in a dialog must name the truth: every extension in a group's label is a member of it.
    func testAGroupsLabelListsExactlyItsMembers() {
        for group in DefaultAppClaim.groups {
            let labelled = Set(group.name
                .components(separatedBy: CharacterSet(charactersIn: "(), "))
                .filter { $0.hasPrefix(".") }
                .map { String($0.dropFirst()) })
            let claimed = Set(group.members.map(\.ext))
            // `.markdown` rides on `.md`'s single system type, so the label may name more than the
            // member list — never fewer, and never anything the app does not open.
            XCTAssertTrue(claimed.isSubset(of: labelled),
                          "\(group.name) claims \(claimed.subtracting(labelled)) without saying so")
            for ext in labelled {
                XCTAssertTrue(DocumentTypes.opensInApp(ext), "\(group.name) names .\(ext) but it is not opened")
            }
        }
    }

    // MARK: - Partial ownership

    private var wordFamily: DefaultAppClaim.Group {
        DefaultAppClaim.groups.first { $0.members.contains { $0.ext == "docx" } }!
    }

    func testAFamilyIsClaimedOnlyWhenEveryMemberIs() {
        XCTAssertEqual(DefaultAppClaim.state(of: wordFamily) { _, _ in true }, .claimed)
    }

    func testAFamilyNobodyOwnsIsUnclaimed() {
        XCTAssertEqual(DefaultAppClaim.state(of: wordFamily) { _, _ in false }, .unclaimed)
    }

    /// The case the grouping had to keep reachable: a reader who set `.docx` by hand months ago and
    /// has never heard of `.dotm`. A plain already/not-already flag would show that family as done
    /// and disable the tick, leaving no way to finish it.
    func testAPartlyOwnedFamilyIsNeitherClaimedNorUnclaimed() {
        let state = DefaultAppClaim.state(of: wordFamily) { ext, _ in ext == "docx" }
        XCTAssertEqual(state, .partial)
    }
}

// MARK: - The two-step walk

extension WelcomeAndDefaultAppTests {

    func testTheGuideOpensOnTheExplanation() {
        let guide = WelcomeWindowController()
        defer { guide.window?.close() }
        XCTAssertEqual(guide.step, .whatItIs)
    }

    /// The enforcement, stated as a test: the tick lives on step 2, so a reader who closes the
    /// window at step 1 has not been shown the thing the guide exists for and gets it again next
    /// launch. Without this, "무조건 거치게" is a comment rather than a behaviour.
    func testLeavingAtStepOneDoesNotCountAsHavingSeenIt() {
        let guide = WelcomeWindowController()
        guide.window?.close()
        XCTAssertNil(UserDefaults.standard.object(forKey: WelcomeStore.key),
                     "step 1 must write no preference at all")
        XCTAssertTrue(WelcomeStore.showsOnLaunch)
    }

    func testReachingStepTwoAndTickingRecordsIt() {
        let guide = WelcomeWindowController()
        guide.goToDefaults()
        XCTAssertEqual(guide.step, .defaults)
        guide.dontShowAgain.state = .on
        guide.window?.close()
        XCTAssertFalse(WelcomeStore.showsOnLaunch)
    }

    /// Reaching step 2 and NOT ticking is an answer too — it must leave the guide due again rather
    /// than silently suppressing it because the reader got that far.
    func testReachingStepTwoWithoutTickingLeavesTheGuideDue() {
        let guide = WelcomeWindowController()
        guide.goToDefaults()
        guide.window?.close()
        XCTAssertTrue(WelcomeStore.showsOnLaunch)
    }
}

// MARK: - The cost of claiming

extension WelcomeAndDefaultAppTests {

    /// macOS 14 confirms each claim with its OWN dialog, per TYPE, and they stack — so the member
    /// count IS the number of system prompts a reader who ticks everything has to answer. Carrying
    /// `.docm`/`.dotx`/`.dotm`/`.tsv`/`.log` made that twelve; they were dropped from the claim (the
    /// app still OPENS them) and it is seven. Pinned because the regression is invisible in code
    /// review: adding one plausible-looking member adds a dialog nobody sees until they ship.
    func testClaimingEverythingCostsSevenSystemDialogs() {
        let types = DefaultAppClaim.groups.reduce(0) { $0 + $1.members.count }
        XCTAssertEqual(types, 7)
    }

    /// The extensions deliberately opened-but-not-claimed. Asserted from both sides so neither
    /// half can drift: the app must still open them, and the claim must still leave them alone.
    func testTheOpenedButUnclaimedKindsStayThatWay() {
        let claimed = Set(DefaultAppClaim.groups.flatMap { $0.members.map(\.ext) })
        for ext in ["docm", "dotx", "dotm", "tsv", "log"] {
            XCTAssertTrue(DocumentTypes.opensInApp(ext), ".\(ext) must still open in the app")
            XCTAssertFalse(claimed.contains(ext), ".\(ext) must not cost a system dialog")
        }
    }
}

/// The dead end a reader hits when Launch Services answers a stale "yes" after a claim: the panel
/// shows every family "already set", the button then has nothing to claim, and the app reports
/// success while the Finder goes on opening the file somewhere else. Pressing it again has to
/// re-ask the question, so an already-ours family must still reach `apply`.
final class StaleAlreadySetTests: XCTestCase {

    func testAFamilyThatReadsAsAlreadyOursIsStillClaimedWhenTicked() {
        let picker = DefaultAppPicker(isDefault: { _, _ in true })
        XCTAssertEqual(picker.chosen.count, DefaultAppClaim.groups.count,
                       "every ticked family must reach apply, including the ones shown 'already set'")
    }

    func testNothingTickedStillClaimsNothing() {
        let picker = DefaultAppPicker(isDefault: { _, _ in false })
        for case let box as NSButton in picker.subviews { box.state = .off }
        XCTAssertTrue(picker.chosen.isEmpty)
    }

    func testAClaimIsGivenARealWindowToAppearIn() {
        // A zero budget is the pre-fix shape: one immediate read, which Launch Services can answer
        // with whatever was default a moment earlier.
        XCTAssertGreaterThanOrEqual(
            Double(DefaultAppClaim.settleAttempts) * DefaultAppClaim.settleInterval, 1.0,
            "a claim must be re-read for at least a second before it counts as refused")
    }
}
