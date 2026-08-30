import Foundation
import CoreGraphics

/// What page furniture a PAGED document shows: the sheet outline, the running header, the running
/// footer, and whether a table may be broken across a page (`paged-view-options-design.md`).
///
/// **The outline is the MASTER** — see `underOutlineRule`. The other three are about a page, so with
/// no page drawn there is nothing for them to be about; the View menu greys them out and
/// a document's own `pageOptions` reports them off.
///
/// **PER DOCUMENT, seeded from the last choice.** This was global — one `UserDefaults` value every
/// window read — on the reasoning that a reader who wants continuous flow wants it for every
/// document, not one at a time. Half of that holds and is kept: the choice still survives a
/// relaunch and a newly opened document still starts at it (`PageViewOptionsStore.startingOptions`).
/// The other half did not. With several documents open, turning the outline off re-applied the band
/// to EVERY paged window, so a setting changed for the report being read disturbed twelve documents
/// nobody had touched — and re-applying a band is not free, it invalidates that document's whole
/// layout. `FontSizeStore` records the identical mistake and the identical repair for the font size;
/// this is that repair, applied to the second reading preference that had it. (The comments panel
/// was per window from the start — it shows one document's own content.)
///
/// **The defaults are all three ON.** The owner's request framed the outline as the thing that
/// REPLACES the page-break line — *"페이지 외곽 모양(그럼 선이 필요 없어짐)"* — so shipping it off would
/// hide the feature behind a menu nobody has a reason to open. It is one click to turn off.
struct PageViewOptions: Equatable {
    /// Each sheet is drawn as a page: its own paper, its own edge, the desk showing between them.
    var outline: Bool
    /// The running header and footer are the PAGE's — they live in its own two margins — so they are
    /// not separate choices at all: with a page drawn they are drawn, and with the outline off there
    /// is no page and the reader sees content in one continuous flow. The owner's rule, after the two
    /// menu items had existed for a while: *"메뉴에서 Header, Footer 는 옵션에서 제거해 (아웃라인
    /// 보이면 같이 보이는거고, 아니면 함께 안 보이는 것임). 아웃라인을 제거하면 콘텐츠만 쭉 보이기
    /// 때문"*. Derived rather than stored, so no state can disagree with the outline.
    var header: Bool { outline }
    var footer: Bool { outline }

    /// The 바탕쪽 — the template a Korean document repeats behind every page: its running title, the
    /// tab down the outer edge, the artwork and the PAGE NUMBER (invariant 78).
    ///
    /// A stored sub-choice UNDER the outline rather than a derived one, unlike the header and footer
    /// above: those are the same two bands the outline itself draws, while this is a whole layer of
    /// the document's own furniture — the owner asked for it where the other page choices live
    /// (*"머리말 꼬리말 바탕쪽 등을 보고 안 보고 옵션화… 거기에 포함시켜"*). Still governed by the
    /// outline: with no page drawn there is no sheet for it to be on.
    var masterPage: Bool = true

    /// What to do with a table that will not finish on the page it starts on: BREAK it at a row
    /// boundary and carry the rest onto the next page (what Word does by default), or keep it whole
    /// and move the whole thing down.
    ///
    /// **This choice never applies to a table taller than the page**, which has no whole page to be
    /// moved to and is always broken — the owner's rule: *"표가 한장이 넘을때가 있거든. 이런 경우는
    /// 무조건 쪼개야 해"*.
    ///
    /// ON by default, because it is what the DOCUMENT does. Measured on `2025 행정업무운영 편람`
    /// against rhwp's own render: keeping tables whole leaves the bottom of a page empty and carries
    /// the table down — 166pt of blank paper on one measured page, where HWP starts the table there
    /// and continues it overleaf — and across the file that is **11 pages** of the gap to rhwp's page
    /// count (526 whole against 515 broken). This reader exists to reproduce a page, and a page the
    /// document fills is not ours to leave half empty.
    ///
    /// The earlier default was OFF, for a reason that has not gone away but is narrower than it
    /// looked: breaking is only ever done where no vertically merged cell crosses the boundary, and a
    /// Korean report form is merged almost everywhere. That rule still holds — it is a guard inside
    /// the breaking itself, so turning this on cannot break a merged form; those tables are still
    /// carried whole because the boundary refuses them. What changes is the ordinary table, which HWP
    /// breaks and this reader was moving. One click either way, and the choice is remembered.
    ///
    /// Defaulted in the memberwise init to `false` on purpose, and deliberately NOT changed with the
    /// preference: every existing caller that names only the three furniture toggles means "the shape
    /// before tables could be broken", and those call sites are describing a state, not choosing one.
    var splitTables: Bool = false

    static let `default` = PageViewOptions(outline: true, masterPage: true, splitTables: true)

    /// With the outline off a paged document reserves NO band at all
    /// (`PageBandLayoutDelegate.isActive`), which is the code path this reader had before any of the
    /// paged work existed — so "off" is not a new mode to maintain, it is the old one.
    var separatesPages: Bool { outline }

    /// THE OUTLINE IS THE MASTER SWITCH. A running header and footer live in a page's own margins and
    /// a table is only broken at a page boundary, so with no page drawn there is nothing for any of
    /// the three to be about — the owner's rule: *"Page Outline을 보기/해제하면 Header, Footer는 따라서
    /// 함께 보기/해제되는거야… 아웃라인이 없으면 나눌것도 없지."*
    ///
    /// Applied as a DERIVED value rather than by clearing the stored keys, so turning the outline back
    /// on restores exactly what the reader had chosen. A document's own `pageOptions` is the only
    /// caller — every consumer therefore gets the rule without knowing it exists.
    var underOutlineRule: PageViewOptions {
        guard !outline else { return self }
        return PageViewOptions(outline: false, masterPage: false, splitTables: false)
    }
}

/// The stored preference, in the shape of `FontSizeStore`: one key, read on demand, never cached in
/// a way that could disagree with what a window is actually showing.
enum PageViewOptionsStore {
    private static let outlineKey = "pageOutlineVisible"
    private static let splitTablesKey = "pageSplitTables"
    private static let masterPageKey = "pageMasterPageVisible"

    /// `UserDefaults.bool(forKey:)` returns `false` for a key that was never written, which would make
    /// every default OFF — the opposite of what is wanted. Each flag is therefore read through
    /// What the reader actually shows — the stored choices with the OUTLINE's rule applied. Every
    /// consumer reads this one, so the dependency exists in a single place rather than in each of them.
    /// What a NEWLY opened document starts with — the last choice the reader made, or the defaults
    /// on a machine where nobody has changed them.
    ///
    /// Read ONCE, when a document is created, to seed `MarkdownDocument.pageOptions`; never read
    /// again while that document is open. The distinction is the whole design, and it is the same
    /// one `FontSizeStore.startingSize` records — for the same reason, arrived at twice. A single
    /// shared value that every window reads means a toggle in one window changes what another
    /// window shows, and this file used to do exactly that ON PURPOSE, walking every open paged
    /// window to re-apply the band. That is defensible for a setting nobody would want to differ
    /// between documents, and wrong as soon as a reader wants the outline off for the one report
    /// they are measuring and on everywhere else. Seeding keeps "remembered next time" true without
    /// letting one window reach into another.
    ///
    /// Deliberately NOT called `current`: the old name invited exactly the read-it-everywhere use
    /// that made a toggle global, and `MarkdownDocument.pageOptions` is the only thing a render,
    /// a band or a menu may consult now.
    static var startingOptions: PageViewOptions {
        get { intent.underOutlineRule }
        set {
            let d = UserDefaults.standard
            d.set(newValue.outline, forKey: outlineKey)
            d.set(newValue.masterPage, forKey: masterPageKey)
            d.set(newValue.splitTables, forKey: splitTablesKey)
        }
    }

    /// What the reader CHOSE, before the outline's rule is applied — what the menu ticks, so turning
    /// the outline off and on again restores the header/footer/split choices instead of resetting them.
    ///
    /// `UserDefaults.bool(forKey:)` returns `false` for a key that was never written, which would make
    /// every default OFF — the opposite of what is wanted. Each flag is therefore read through
    /// `object(forKey:)` so "never set" and "set to false" stay distinguishable.
    static var intent: PageViewOptions {
        let d = UserDefaults.standard
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) as? Bool ?? fallback
        }
        return PageViewOptions(outline: flag(outlineKey, PageViewOptions.default.outline),
                               masterPage: flag(masterPageKey, PageViewOptions.default.masterPage),
                               splitTables: flag(splitTablesKey, PageViewOptions.default.splitTables))
    }

    /// Test seam — puts the three keys back to "never written" so a case starts from the real
    /// defaults rather than from whatever an earlier case chose.
    static func reset() {
        let d = UserDefaults.standard
        [outlineKey, masterPageKey, splitTablesKey].forEach { d.removeObject(forKey: $0) }
    }
}
