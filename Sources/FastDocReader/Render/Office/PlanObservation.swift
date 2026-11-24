import AppKit

/// S6b2-0a of `docs/plans/pagination-to-engine.md`: the natural-layout observation.
///
/// A second layout manager on the SAME text storage lays the document out with nobody deciding a
/// page: no band shifts, no pushes, no pulls, no column map. Vertical shifts never change line
/// breaks (a column's width is fixed when the text is built), so one such layout serves every plan
/// call whatever the page-view toggles say. The visible layout manager is never touched.
///
/// This type only owns the layout manager and its walk; `PagePlanShadow` reads line fragments off it
/// exactly as it reads them off the visible one, so both observations take the same measurements.
final class PlanObservation {
    let layout = NSLayoutManager()
    let container: NSTextContainer
    let recorder: PlanObservationDelegate
    private weak var storage: NSTextStorage?

    /// The chunk the walk advances by: the same bound `precomputeLayout` uses (invariant 49).
    static let walkChunk = 20_000

    /// Configured from the visible container, so a line breaks where it does there: the same width,
    /// the same fragment padding.
    init(storage: NSTextStorage, like visible: NSTextContainer) {
        self.storage = storage
        recorder = PlanObservationDelegate(storage: storage)
        layout.allowsNonContiguousLayout = false
        layout.delegate = recorder
        container = NSTextContainer(size: visible.size)
        container.widthTracksTextView = false
        container.lineFragmentPadding = visible.lineFragmentPadding
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    /// Lays the whole text out, one bounded chunk at a time. Returns the number of steps taken.
    @discardableResult
    func walk() -> Int {
        guard let storage else { return 0 }
        var at = 0, steps = 0
        while at < storage.length {
            let length = min(Self.walkChunk, storage.length - at)
            layout.ensureLayout(forCharacterRange: NSRange(location: at, length: length))
            at += length
            steps += 1
        }
        layout.ensureLayout(for: container)
        return steps
    }

    /// Drops the layout manager and with it its glyph and fragment store (invariant 65).
    func remove() {
        storage?.removeLayoutManager(layout)
    }
}

/// Records where the typesetter first proposed each table line, and changes nothing: the proposed top
/// is what a table's first-line inset is measured across (invariant 72), before the cell's vertical
/// alignment moves the line inside its box.
final class PlanObservationDelegate: NSObject, NSLayoutManagerDelegate {
    private weak var storage: NSTextStorage?
    private(set) var proposedTableLineTops: [Int: CGFloat] = [:]

    init(storage: NSTextStorage) {
        self.storage = storage
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage else { return false }
        let location = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
        guard location >= 0, location < storage.length,
              let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
              style.textBlocks.contains(where: { $0 is NSTextTableBlock }) else { return false }
        proposedTableLineTops[location] = lineFragmentRect.pointee.minY
        return false
    }
}
