import AppKit

/// Puts every line of a paged document where the PAGE PLAN says it goes, and holds what the painters
/// read about that plan (docs/plans/pagination-to-engine.md, S6b2).
///
/// The engine decides pagination: `fastdoc_office_page_plan_json` takes one natural observation of
/// the text (`PlanObservation`) and answers a page and a top for every line. This class decides
/// nothing. A line whose first character has a plan target is put at that target — a pure lookup by
/// character location, so a second layout of the same text gives the same answer — and every other
/// line is left to the typesetter. There is no page arithmetic, no push, no pull, no settle loop.
///
/// Installed on the real `NSLayoutManager` UNCONDITIONALLY (`DocumentWindowController.init`) and
/// inert wherever it does not apply: with no targets it returns `false` for every line.
final class PageBandLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// Where one line goes: the container `y` of its top and, for a line in a columned run, the left
    /// edge of its column plus how far a table cell stood from the run's own left edge in the natural
    /// layout (`insetX`). The proposed rect cannot say: a table line's `x` is only final once the table
    /// has laid its cell out, after this delegate has answered.
    struct Target {
        var y: CGFloat
        var columnX: CGFloat?
        var insetX: CGFloat
    }

    /// The document's own page BODY height (`MarkdownDocument.officePageContentHeight`). `0` when
    /// unknown / not paged.
    var pageContentHeight: CGFloat
    /// `PageBandGeometry.bandHeight` — footer + gap + next header (+ the desk gap on screen). `0`
    /// disables pagination entirely (see `isActive`): a document with no header/footer reserves
    /// nothing and lays out exactly as it did before pagination existed.
    var band: CGFloat
    /// Extra space reserved BEFORE the very first line of text — the OUTER edge the between-page gaps
    /// cannot reach on their own. `0` when there is no header, or page 0's own applicable header is
    /// deliberately blank (`DocumentWindowController.configurePageBand` decides).
    var leadingBand: CGFloat
    /// The TRAILING twin, other outer edge. Not read by this class; carried here as the natural
    /// single home for all four page-band numbers. `DocumentWindowController.applyTrailingFooterBand`
    /// is what actually reserves it.
    var trailingBand: CGFloat
    /// How much of `band` is the DESK between two drawn sheets rather than the document's own margins
    /// (`RenderTheme.pageDeskGap`, non-zero only while the page outline is on). Held HERE, beside the
    /// band it is part of, because the drawing side has to subtract exactly what the layout side
    /// added: one fact, set once, by whoever reserved the space.
    var deskGap: CGFloat = 0
    /// The width the columns are measured across — the body width this document is laid out in.
    var columnBodyWidth: CGFloat = 0

    init(pageContentHeight: CGFloat = 0, band: CGFloat = 0, leadingBand: CGFloat = 0, trailingBand: CGFloat = 0) {
        self.pageContentHeight = pageContentHeight
        self.band = band
        self.leadingBand = leadingBand
        self.trailingBand = trailingBand
    }

    /// Whether the plan has anything to reserve: a page height and a band (or notes to reserve for).
    var isActive: Bool { pageContentHeight > 0 && (band > 0 || !noteBands.isEmpty) }

    /// Whether this document has SHEETS at all — the weaker half of the gate above, and the one the
    /// footnote path must ask instead: a note's reservation is what makes `isActive` true, so gating
    /// the plan on it is circular and settles on "no".
    var paginates: Bool { pageContentHeight > 0 }

    // MARK: - What the plan says about where lines go

    /// The plan's answer for each line, by the character location of its first character.
    var targets: [Int: Target] = [:]

    /// How many line fragments the plan has actually moved — a test can assert something DID happen
    /// without hand-deriving the expected line positions itself.
    private(set) var shiftCount = 0

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, !targets.isEmpty else { return false }
        let location = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
        guard let target = targets[location] else { return false }
        let rect = lineFragmentRect.pointee
        let x = target.columnX.map { $0 + target.insetX } ?? rect.minX
        let dx = x - rect.minX, dy = target.y - rect.minY
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return false }
        lineFragmentRect.pointee.origin.x = x
        lineFragmentRect.pointee.origin.y = target.y
        lineFragmentUsedRect.pointee.origin.x += dx
        lineFragmentUsedRect.pointee.origin.y += dy
        shiftCount += 1
        return true
    }

    // MARK: - What the painters read

    /// The page boundaries the plan OPENED — page `n` is present when the first line of page `n+1`
    /// sits below an empty band. The painter consults this rather than computing boundaries
    /// arithmetically: a boundary inside a table opens no band, and a painter that trusted the
    /// arithmetic drew the header and the footer straight over the table's own rows.
    private(set) var openedBoundaries: Set<Int> = []

    /// The boundaries a TABLE actually spans — the only ones the weld exists to protect. `nil` means
    /// NOBODY MEASURED (invariant 108's rule — a missing measurement is not an empty one), and the
    /// weld then falls back to its wider behaviour rather than drawing page rules through tables.
    var tableStraddledBoundaries: Set<Int>?

    /// WHERE each opened band actually is: page `n` → the vertical span of the empty gap after it, in
    /// text-container coordinates.
    private(set) var openedBands: [Int: (top: CGFloat, height: CGFloat)] = [:]

    /// The page boundaries a COLUMN placement crosses, which no opened band records: a columned run's
    /// lines are dealt across sheets by the plan, so nothing is shifted down at a boundary.
    var columnOpenedBoundaries: Set<Int> = []

    /// Height reserved at the FOOT of a page for the footnotes cited on it, keyed by page — empty for
    /// every document that cites none. Decided by the plan's footnote fixpoint (invariant 98).
    var noteBands: [Int: CGFloat] = [:]

    /// Takes the painter state of a plan answer, converting the plan's page-local tops to container
    /// coordinates. The plan is on the PRINT grid; the screen adds `deskGap` per page.
    ///
    /// `below` limits the answer to pages the plan will not change (`finalPages` of a plan taken from
    /// the head of the text, for the first paint): what it says about a later page is a guess.
    func adopt(plan: [String: Any], below limit: Int = Int.max) {
        let pitch = pageContentHeight + band - deskGap
        func ints(_ key: String) -> Set<Int> {
            Set(((plan[key] as? [NSNumber]) ?? []).map(\.intValue).filter { $0 < limit })
        }
        openedBoundaries = ints("openedBoundaries")
        columnOpenedBoundaries = ints("columnOpenedBoundaries")
        tableStraddledBoundaries = ints("straddledBoundaries")
        var bands: [Int: (top: CGFloat, height: CGFloat)] = [:]
        for band in (plan["openedBands"] as? [[String: Any]]) ?? [] {
            guard let page = (band["page"] as? NSNumber)?.intValue, page < limit,
                  let top = (band["top"] as? NSNumber)?.doubleValue,
                  let height = (band["height"] as? NSNumber)?.doubleValue else { continue }
            bands[page] = (top: leadingBand + CGFloat(page) * (pitch + deskGap) + CGFloat(top),
                           height: CGFloat(height) + deskGap)
        }
        openedBands = bands
        var notes: [Int: CGFloat] = [:]
        for pair in (plan["noteBands"] as? [[Any]]) ?? [] where pair.count == 2 {
            if let page = (pair[0] as? NSNumber)?.intValue, page < limit,
               let height = (pair[1] as? NSNumber)?.doubleValue, height > 0 {
                notes[page] = CGFloat(height)
            }
        }
        noteBands = notes
    }

    /// Drops everything a plan said: the next layout is the typesetter's own until a plan is adopted.
    /// Called whenever the text, the band or a view option changes, because every one of them makes
    /// the previous answer a statement about a layout that no longer exists.
    func resetPlan() {
        targets = [:]
        openedBoundaries = []
        openedBands = [:]
        tableStraddledBoundaries = nil
        columnOpenedBoundaries = []
        noteBands = [:]
        shiftCount = 0
    }

    /// THE lowest a body line may reach on a given page — its sheet's text bottom, less whatever that
    /// page reserves for notes. One definition for the footnote painter and the plan's own grid.
    func textBottom(ofPage page: CGFloat) -> CGFloat {
        PagePagination.textBottom(ofPage: page, pageContentHeight: pageContentHeight,
                                  band: band, noteBands: noteBands)
    }

    static func page(of y: CGFloat, leadingBand: CGFloat, pitch: CGFloat) -> CGFloat {
        (((y - leadingBand) / pitch) + 1e-6).rounded(.down)
    }

    // MARK: - Targets from a plan

    /// The plan's targets as the delegate wants them. The plan names a page and a top on the PRINT
    /// grid; the host turns that into its `y`, adding `deskGap` per page where the screen has one.
    static func targets(plan: [String: Any], leading: CGFloat, pitch: CGFloat, deskGap: CGFloat,
                        columnRuns: [(range: NSRange, layout: OfficeColumnLayout)], bodyWidth: CGFloat,
                        insetX: [Int: CGFloat], belowPage limit: Int = Int.max) -> [Int: Target] {
        var columns: [[ColumnGeometry.Column]] = []
        for run in columnRuns { columns.append(ColumnGeometry.columns(inWidth: bodyWidth, layout: run.layout)) }
        var out: [Int: Target] = [:]
        for target in (plan["targets"] as? [[String: Any]]) ?? [] {
            guard let loc = (target["loc"] as? NSNumber)?.intValue, let page = (target["page"] as? NSNumber)?.intValue,
                  page < limit, let top = (target["top"] as? NSNumber)?.doubleValue else { continue }
            let y = leading + CGFloat(page) * (pitch + deskGap) + CGFloat(top)
            var columnX: CGFloat?
            if let column = (target["column"] as? NSNumber)?.intValue,
               let run = columnRuns.firstIndex(where: { NSLocationInRange(loc, $0.range) }), column < columns[run].count {
                columnX = columns[run][column].x
            }
            out[loc] = Target(y: y, columnX: columnX, insetX: insetX[loc] ?? 0)
        }
        return out
    }
}
