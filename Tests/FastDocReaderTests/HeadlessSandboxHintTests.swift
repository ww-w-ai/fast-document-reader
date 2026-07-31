import XCTest
@testable import FastDocReader

/// The sandbox note the headless flags add to a file failure. The failure itself is indistinguishable
/// from "no such file" — the sandbox denies before anything can be asked — so the message is the only
/// place the caller learns that a grant, not a different path, is what they need.
///
/// What no test here can see: whether the grant is actually RESTORED for a headless run (that is
/// `main.swift` calling `FolderAccess.restoreGrants()` before either flag branches, and a test cannot
/// enter `main.swift`). It is verified by running a SANDBOX=1 build against a granted folder —
/// invariant 29's seam, checked by hand.
final class HeadlessSandboxHintTests: XCTestCase {

    func testAnUnsandboxedBuildAddsNothing() {
        XCTAssertNil(FolderAccess.headlessDenialHint(sandboxed: false))
        XCTAssertEqual(FolderAccess.annotatingHeadlessDenial("cannot read a.docx: nope", sandboxed: false),
                       "cannot read a.docx: nope")
    }

    func testASandboxedBuildNamesTheGrantAndKeepsTheOriginalReason() {
        let hint = FolderAccess.headlessDenialHint(sandboxed: true)
        XCTAssertNotNil(hint)
        // The hint tells the caller to use a menu item; if that item is ever renamed, the message
        // must follow it rather than name something the File menu no longer has.
        XCTAssertTrue(hint?.contains(FolderAccess.grantMenuTitle) == true,
                      "the hint must name the menu item that actually makes the grant")

        let annotated = FolderAccess.annotatingHeadlessDenial("cannot read a.docx: nope", sandboxed: true)
        XCTAssertTrue(annotated.hasPrefix("cannot read a.docx: nope"),
                      "the system's own reason must survive — the hint is added, never substituted")
        XCTAssertTrue(annotated.contains(FolderAccess.grantMenuTitle))
    }
}
