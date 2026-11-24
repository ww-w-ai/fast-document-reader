import XCTest
import AppKit
@testable import FastDocReader

/// S6b2-0a of `docs/plans/pagination-to-engine.md`: the natural observation is a second layout
/// manager on the same storage that nobody paginates. These pin the three things the plan relies on:
/// it lays the text out as an unpaginated layout would while the visible one is shifted, it records
/// only table lines' proposed tops, and it leaves the storage as it found it.
final class PlanObservationTests: XCTestCase {

    private func paragraphs(_ count: Int) -> NSAttributedString {
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk. "
        let out = NSMutableAttributedString()
        for _ in 0..<count {
            out.append(NSAttributedString(
                string: String(repeating: sentence, count: 3) + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: NSParagraphStyle.default]))
        }
        return out
    }

    private func stack(_ text: NSAttributedString, delegate: NSLayoutManagerDelegate?)
        -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.delegate = delegate
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.setAttributedString(text)
        return (storage, layout, container)
    }

    private func lineRects(_ layout: NSLayoutManager, _ container: NSTextContainer) -> [NSRect] {
        layout.ensureLayout(for: container)
        var rects: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }

    /// Mutation target: the `lineFragmentPadding` copy in `PlanObservation.init` — an observer
    /// configured differently from the visible container wraps the text elsewhere.
    func testTheObserverLaysOutAsIfNobodyPaginatedWhileTheVisibleLayoutIsShifted() {
        let text = paragraphs(40)
        let (plainStorage, plainLayout, plainContainer) = stack(text, delegate: nil)
        defer { withExtendedLifetime(plainStorage) {} }
        let plain = lineRects(plainLayout, plainContainer)
        let lineHeight = plain[1].minY - plain[0].minY
        let band = PageBandLayoutDelegate(pageContentHeight: (lineHeight * 12).rounded(), band: 40)
        let (storage, visibleLayout, visibleContainer) = stack(text, delegate: band)
        let paged = lineRects(visibleLayout, visibleContainer)
        XCTAssertGreaterThan(band.shiftCount, 2, "precondition: the visible layout is paginated")
        XCTAssertGreaterThan(paged.last!.minY, plain.last!.minY)

        let observation = PlanObservation(storage: storage, like: visibleContainer)
        observation.walk()
        // Configured from the visible container: a line breaks where it does there.
        XCTAssertEqual(observation.container.size, visibleContainer.size)
        XCTAssertEqual(observation.container.lineFragmentPadding, visibleContainer.lineFragmentPadding)
        let observed = lineRects(observation.layout, observation.container)
        XCTAssertEqual(observed.count, plain.count, "the observer wraps the text where the visible layout does")
        for (i, rect) in observed.enumerated() where i < plain.count {
            XCTAssertEqual(rect.minY, plain[i].minY, accuracy: 0.01, "line \(i) was moved in the observation")
        }
        // The visible layout is untouched by the second one.
        XCTAssertEqual(lineRects(visibleLayout, visibleContainer).last!.minY, paged.last!.minY, accuracy: 0.01)

        let before = storage.layoutManagers.count
        observation.remove()
        XCTAssertEqual(storage.layoutManagers.count, before - 1, "the observer's store is dropped with it")
    }

    /// Mutation target: the `style.textBlocks.contains` guard — without it every paragraph is
    /// recorded; replacing it with `true` makes the first assertion fail.
    func testOnlyTableLinesHaveAProposedTopRecorded() {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        cell.setWidth(2, type: .absoluteValueType, for: .padding)
        let inCell = NSMutableParagraphStyle()
        inCell.textBlocks = [cell]
        let text = NSMutableAttributedString(string: "Before the table.\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: NSParagraphStyle.default])
        let cellStart = text.length
        text.append(NSAttributedString(string: "Inside the cell.\n",
                                       attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: inCell]))
        text.append(NSAttributedString(string: "After the table.\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: NSParagraphStyle.default]))
        let (storage, layout, container) = stack(text, delegate: nil)
        defer { withExtendedLifetime(layout) {} }

        let observation = PlanObservation(storage: storage, like: container)
        observation.walk()
        _ = lineRects(observation.layout, observation.container)
        let recorded = observation.recorder.proposedTableLineTops
        observation.remove()
        XCTAssertEqual(Set(recorded.keys), [cellStart], "only the cell's line is recorded, at its first character")
    }

    /// Mutation target: the `min(Self.walkChunk, ...)` bound — one unbounded step makes this fail; a walk that stops early leaves lines
    /// unplaced for the engine's input.
    func testTheWalkAdvancesInBoundedChunksAndLaysOutEverything() {
        let text = paragraphs(300)
        XCTAssertGreaterThan(text.length, PlanObservation.walkChunk * 2)
        let (storage, _, container) = stack(NSAttributedString(string: ""), delegate: nil)
        storage.setAttributedString(text)
        let observation = PlanObservation(storage: storage, like: container)
        let steps = observation.walk()
        XCTAssertEqual(steps, (text.length + PlanObservation.walkChunk - 1) / PlanObservation.walkChunk)
        XCTAssertEqual(observation.layout.firstUnlaidCharacterIndex(), storage.length)
        observation.remove()
    }

    /// The reader top-aligns the cells of a table it breaks and leaves the block changed; the plan is
    /// told what the document asked for.
    func testTheAuthoredAlignmentOutlivesTheReadersTopAligning() {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        cell.verticalAlignment = .middleAlignment
        XCTAssertEqual(cell.authoredVerticalAlignment, .middleAlignment, "a block nobody touched answers for itself")
        cell.rememberAuthoredAlignment()
        cell.verticalAlignment = .topAlignment
        cell.rememberAuthoredAlignment()
        XCTAssertEqual(cell.authoredVerticalAlignment, .middleAlignment, "the first call is the one that counts")
        XCTAssertEqual(cell.verticalAlignment, .topAlignment)
    }
}
