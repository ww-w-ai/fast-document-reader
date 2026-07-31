import Foundation
import CoreGraphics

/// What page furniture a PAGED document shows: the sheet outline, the running header, the running
/// footer — three independent toggles in the View menu (`paged-view-options-design.md`).
///
/// **A GLOBAL preference, not per window.** The design left this open; it is settled here because a
/// reader who wants continuous flow wants it for every document they open, not one at a time, and
/// because the choice has to survive a relaunch to be worth making. (The comments panel is per window
/// for the opposite reason — it shows one document's own content, not a way of reading.)
///
/// **The defaults are all three ON.** The owner's request framed the outline as the thing that
/// REPLACES the page-break line — *"페이지 외곽 모양(그럼 선이 필요 없어짐)"* — so shipping it off would
/// hide the feature behind a menu nobody has a reason to open. It is one click to turn off.
struct PageViewOptions: Equatable {
    /// Each sheet is drawn as a page: its own paper, its own edge, the desk showing between them.
    var outline: Bool
    /// The running header is drawn in the top margin. Off ALSO stops it being measured, so the band
    /// shrinks and the space it occupied goes away — this is a layout switch, not a visibility flag.
    var header: Bool
    /// The running footer, same rule.
    var footer: Bool

    /// What to do with a table that will not finish on the page it starts on: BREAK it at a row
    /// boundary and carry the rest onto the next page (what Word does by default), or keep it whole
    /// and move the whole thing down.
    ///
    /// **This choice never applies to a table taller than the page**, which has no whole page to be
    /// moved to and is always broken — the owner's rule: *"표가 한장이 넘을때가 있거든. 이런 경우는
    /// 무조건 쪼개야 해"*.
    ///
    /// Off by default. Breaking is only ever done where no vertically merged cell crosses the
    /// boundary, and a Korean report form is merged almost everywhere, so on the documents this reader
    /// is used for "keep it whole" is the choice that reliably produces a clean page. One click either
    /// way.
    /// Defaulted in the memberwise init on purpose: every existing caller that names the three
    /// furniture toggles means "the shape before tables could be broken", which is exactly `false`.
    var splitTables: Bool = false

    static let `default` = PageViewOptions(outline: true, header: true, footer: true, splitTables: false)

    /// With all three off a paged document reserves NO band at all
    /// (`PageBandLayoutDelegate.isActive`), which is the code path this reader had before any of the
    /// paged work existed — so "everything off" is not a new mode to maintain, it is the old one.
    var separatesPages: Bool { outline }

    /// The page-break hairline is drawn only when the band exists but the SHEET does not. With the
    /// outline on, a real paper edge says "the page ends here" better than a rule across the column
    /// does; with everything off there is no band to mark at all.
    var drawsDivider: Bool { !outline && (header || footer) }
}

/// The stored preference, in the shape of `FontSizeStore`: one key, read on demand, never cached in
/// a way that could disagree with what a window is actually showing.
enum PageViewOptionsStore {
    private static let outlineKey = "pageOutlineVisible"
    private static let headerKey = "pageHeaderVisible"
    private static let footerKey = "pageFooterVisible"
    private static let splitTablesKey = "pageSplitTables"

    /// `UserDefaults.bool(forKey:)` returns `false` for a key that was never written, which would make
    /// every default OFF — the opposite of what is wanted. Each flag is therefore read through
    /// `object(forKey:)` so "never set" and "set to false" stay distinguishable.
    static var current: PageViewOptions {
        get {
            let d = UserDefaults.standard
            func flag(_ key: String, _ fallback: Bool) -> Bool {
                d.object(forKey: key) as? Bool ?? fallback
            }
            return PageViewOptions(outline: flag(outlineKey, PageViewOptions.default.outline),
                                   header: flag(headerKey, PageViewOptions.default.header),
                                   footer: flag(footerKey, PageViewOptions.default.footer),
                                   splitTables: flag(splitTablesKey, PageViewOptions.default.splitTables))
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.outline, forKey: outlineKey)
            d.set(newValue.header, forKey: headerKey)
            d.set(newValue.footer, forKey: footerKey)
            d.set(newValue.splitTables, forKey: splitTablesKey)
        }
    }

    /// Test seam — puts the three keys back to "never written" so a case starts from the real
    /// defaults rather than from whatever an earlier case chose.
    static func reset() {
        let d = UserDefaults.standard
        [outlineKey, headerKey, footerKey, splitTablesKey].forEach { d.removeObject(forKey: $0) }
    }
}
