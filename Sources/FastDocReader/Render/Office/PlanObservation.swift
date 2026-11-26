import AppKit

/// S6b2-0a of `docs/plans/pagination-to-engine.md`: the natural-layout observation.
///
/// A second layout manager on the SAME text storage lays the document out with nobody deciding a
/// page: no band shifts, no pushes, no pulls, no column map. Vertical shifts never change line
/// breaks (a column's width is fixed when the text is built), so one such layout serves every plan
/// call whatever the page-view toggles say. The visible layout manager is never touched.
///
/// This type only owns the layout manager and its walk; `PlanInputBuilder` reads its line fragments.
final class PlanObservation {
    let layout = NSLayoutManager()
    let container: NSTextContainer
    let recorder: PlanObservationDelegate
    private weak var storage: NSTextStorage?

    /// The chunk the walk advances by: the same bound `precomputeLayout` uses (invariant 49).
    static let walkChunk = 20_000

    /// Configured from the visible container, so a line breaks where it does there: the same width,
    /// the same fragment padding.
    ///
    /// `applying` swaps the recording delegate for an apply delegate (the parity probe): the same
    /// layout manager configuration, with lines put at the plan's targets.
    init(storage: NSTextStorage, like visible: NSTextContainer, applying: NSLayoutManagerDelegate? = nil) {
        self.storage = storage
        recorder = PlanObservationDelegate(storage: storage)
        layout.allowsNonContiguousLayout = false
        layout.delegate = applying ?? recorder
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

    /// The same observation taken in steps, so a caller can spread it over main-thread turns
    /// (invariant 207): lay the text out from the start, then read its line fragments from the start.
    /// Each step is bounded by a character or glyph count; the caller decides how many fit a turn.
    final class Walk {
        /// The observer while the walk holds it; `discard` drops it with its glyph and fragment store.
        private var held: PlanObservation?
        private var observer: PlanObservation { held! }
        /// Characters laid out so far, and glyphs whose line fragments have been read.
        private(set) var laidTo = 0
        private(set) var collectedTo = 0
        private(set) var fragments: [PlanInputBuilder.Fragment] = []
        private(set) var isLaidOut = false
        private(set) var isCollected = false

        init(storage: NSTextStorage, like visible: NSTextContainer) {
            held = PlanObservation(storage: storage, like: visible)
        }

        /// Lays out up to `characters` more characters; the last step lays the container's end too,
        /// as `walk()` does.
        func lay(characters: Int) {
            guard !isLaidOut, held != nil, let storage = observer.storage else { return }
            let end = min(storage.length, laidTo + max(1, characters))
            if end > laidTo {
                observer.layout.ensureLayout(forCharacterRange: NSRange(location: laidTo, length: end - laidTo))
            }
            laidTo = end
            if end >= storage.length {
                observer.layout.ensureLayout(for: observer.container)
                isLaidOut = true
            }
        }

        /// Reads the line fragments of about `glyphs` more glyphs, ending at a fragment boundary so
        /// no fragment is read twice. Only after the text is laid out.
        func collect(glyphs: Int) {
            guard isLaidOut, !isCollected, held != nil, let storage = observer.storage else { return }
            let layout = observer.layout
            let total = layout.numberOfGlyphs
            var end = min(total, collectedTo + max(1, glyphs))
            if end < total {
                var fragment = NSRange()
                _ = layout.lineFragmentRect(forGlyphAt: end, effectiveRange: &fragment, withoutAdditionalLayout: true)
                end = fragment.location > collectedTo ? fragment.location : max(end, NSMaxRange(fragment))
            }
            if end > collectedTo {
                fragments += PlanInputBuilder.collect(layout, observer.container, storage: storage,
                                                      glyphs: NSRange(location: collectedTo, length: end - collectedTo))
            }
            collectedTo = end
            if end >= total { isCollected = true }
        }

        /// The finished observation; the observer is removed from the text.
        func finish() -> PlanInputBuilder.Observation {
            let proposed = held?.recorder.proposedTableLineTops ?? [:]
            discard()
            let taken = fragments
            fragments = []
            return PlanInputBuilder.Observation(fragments: taken, groups: PlanInputBuilder.group(taken),
                                                proposedTableLineTops: proposed)
        }

        /// Removes the observer from the text and lets it go, once: a walk that is finished or given
        /// up holds nothing laid out (invariant 65).
        func discard() {
            held?.remove()
            held = nil
        }
    }
}

private var authoredAlignmentKey: UInt8 = 0

extension NSTextTableBlock {
    /// Remembers the vertical alignment the document asked for, before anything changes it. The
    /// reader top-aligns the cells of a table it breaks across pages and leaves the block changed;
    /// the plan is told the alignment the document declared.
    func rememberAuthoredAlignment() {
        guard objc_getAssociatedObject(self, &authoredAlignmentKey) == nil else { return }
        objc_setAssociatedObject(self, &authoredAlignmentKey, NSNumber(value: verticalAlignment.rawValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Puts back the alignment the document asked for, when `rememberAuthoredAlignment` saw one.
    func restoreAuthoredAlignment() {
        guard let saved = objc_getAssociatedObject(self, &authoredAlignmentKey) as? NSNumber,
              let value = NSTextBlock.VerticalAlignment(rawValue: saved.intValue) else { return }
        if verticalAlignment != value { verticalAlignment = value }
    }

    /// The alignment the document asked for: what `rememberAuthoredAlignment` saw, else the current one.
    var authoredVerticalAlignment: NSTextBlock.VerticalAlignment {
        guard let saved = objc_getAssociatedObject(self, &authoredAlignmentKey) as? NSNumber,
              let value = NSTextBlock.VerticalAlignment(rawValue: saved.intValue) else { return verticalAlignment }
        return value
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
