import XCTest
import AppKit
@testable import FastDocReader

/// Why a run of sheets welds into ONE.
///
/// `pageSheets` is `printSheets` with every boundary layout did not OPEN joined to its predecessor
/// (`PagePagination.joiningUnopenedBoundaries`), so a long table — whose lines cannot be shifted —
/// can weld dozens of sheets into a single enormous one. Reported on
/// `2025_행정업무운영편람_최종.hwp`: everything after sheet 492 is one sheet, the margin number stops
/// changing, and Go to Page cannot reach past it.
///
/// This probe prints the four numbers that separate the candidate causes: how much welding there
/// is and where, how many boundaries opened, how many oversized pieces were registered (the record
/// that lets a line inside a table be shifted at all), and how many settle rounds ran.
final class WeldedSheetProbeTests: XCTestCase {

    func testWeldedSheets() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_WELD_PROBE"] else {
            throw XCTSkip("set FMD_WELD_PROBE=<document>")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let env = ProcessInfo.processInfo.environment
        let w = CGFloat(Double(env["FMD_WELD_W"] ?? "") ?? 1098)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: w, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)

        let printed = wc.printSheets
        let joined = wc.pageSheets
        let d = wc.pageBandDelegate
        print("PROBE window        \(w)")
        print("PROBE printSheets   \(printed.count)")
        print("PROBE pageSheets    \(joined.count)   (welded away: \(printed.count - joined.count))")
        print("PROBE opened        \(d.openedBoundaries.count) of \(max(0, printed.count - 1)) boundaries")
        print("PROBE oversized     \(d.oversizedPieces.count) pieces")
        print("PROBE pushedTables  \(d.pushedTables.count)")
        print("PROBE splitTables   \(doc.pageOptions.splitTables)")
        print("PROBE settleCap    \(wc.maxPagedTableSettles)")

        // The tallest joined sheets — a normal one is exactly the paper, a welded one is a multiple.
        let paper = d.pageContentHeight + d.band
        let tall = joined.enumerated()
            .map { (i: $0.offset, h: $0.element.height) }
            .filter { $0.h > paper * 1.5 }
            .sorted { $0.h > $1.h }
        print("PROBE paper pitch   \(String(format: "%.1f", paper))")
        print("PROBE welded sheets \(tall.count)")
        for t in tall.prefix(8) {
            print(String(format: "PROBE   sheet %4d  height %10.1f  = %.1f pages",
                         t.i + 1, t.h, t.h / paper))
        }
        // The first boundary that did NOT open, which is where the first weld begins.
        let firstUnopened = (0..<max(0, printed.count - 1)).first { !d.openedBoundaries.contains($0) }
        print("PROBE first unopened boundary: \(firstUnopened.map(String.init) ?? "none")")

        // Was the ROUND BUDGET the binding constraint? Keep asking the settle past the cap the app
        // ships and watch whether the weld shrinks. If it does, the tail welds only because the
        // document ran out of rounds before its last tables were registered.
        guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer else { return }
        var extra = 0
        while extra < 60 {
            lm.ensureLayout(for: tc)
            if !wc.settlePagedTables() { break }
            extra += 1
        }
        lm.ensureLayout(for: tc)
        print("PROBE extra rounds  \(extra) beyond the shipped cap")
        print("PROBE after: pageSheets \(wc.pageSheets.count) of printSheets \(wc.printSheets.count)")
        print("PROBE after: opened \(d.openedBoundaries.count)  oversized \(d.oversizedPieces.count)")

        // Does the oversized record REACH the welded tail at all? The weld starts at boundary
        // `firstUnopened`, so find the character at the top of that sheet and ask whether any
        // registered piece contains it.
        let len = wc.textView.textStorage?.length ?? 0
        let pieces = d.oversizedPieces.sorted { $0.key < $1.key }
        print("PROBE storage length \(len)")
        print("PROBE last 4 pieces  \(pieces.suffix(4).map { "\($0.key)..\($0.value)" }.joined(separator: " "))")
        if let b = firstUnopened {
            let sheetTop = d.leadingBand + CGFloat(b + 1) * (d.pageContentHeight + d.band)
            let idx = lm.characterIndex(for: NSPoint(x: 4, y: sheetTop + 2),
                                                in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
            let covered = d.oversizedPieces.contains { idx >= $0.key && idx < $0.value }
            print("PROBE weld starts at char \(idx) of \(len) — inside an oversized piece: \(covered)")
            let after = pieces.filter { $0.value > idx }.count
            print("PROBE pieces reaching past that char: \(after)")
            if let st = wc.textView.textStorage, idx < st.length {
                let ps = st.attribute(.paragraphStyle, at: idx, effectiveRange: nil) as? NSParagraphStyle
                let inTable = ps?.textBlocks.first is NSTextTableBlock
                let near = NSRange(location: max(0, idx - 40), length: min(120, st.length - max(0, idx - 40)))
                print("PROBE char \(idx) inside a table: \(inTable)")
                print("PROBE text around it: |\((st.string as NSString).substring(with: near).replacingOccurrences(of: "\n", with: "\u{23CE}"))|")
                let below = pieces.last { $0.value <= idx }
                let above = pieces.first { $0.key > idx }
                print("PROBE nearest piece ending before: \(below.map { "\($0.key)..\($0.value)" } ?? "none")")
                print("PROBE nearest piece starting after: \(above.map { "\($0.key)..\($0.value)" } ?? "none")")
            }
            // Every unopened boundary, and whether its page-top character is covered.
            let unopened = (0..<max(0, printed.count - 1)).filter { !d.openedBoundaries.contains($0) }
            print("PROBE unopened boundaries: \(unopened.count) -> \(unopened.prefix(25).map(String.init).joined(separator: ","))")

            // Does a TABLE actually straddle each unopened boundary? That is the only thing the
            // weld exists to protect (a page rule drawn through a table's rows). Anything else it
            // welds is a boundary layout simply had no line to move at.
            struct L { var top: CGFloat; var bottom: CGFloat; var table: ObjectIdentifier? }
            var lines: [L] = []
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, gr, _ in
                let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                guard let st = wc.textView.textStorage, cr.location < st.length else { return }
                let ps = st.attribute(.paragraphStyle, at: cr.location, effectiveRange: nil) as? NSParagraphStyle
                let blk = ps?.textBlocks.first as? NSTextTableBlock
                lines.append(L(top: rect.minY, bottom: rect.maxY,
                               table: blk.map { ObjectIdentifier($0.table) }))
            }
            lines.sort { $0.top < $1.top }
            let pitch2 = d.pageContentHeight + d.band
            var straddled = 0, clean = 0
            for b in unopened {
                let y = d.leadingBand + CGFloat(b + 1) * pitch2
                let before = lines.last { $0.top < y - 0.5 }
                let after = lines.first { $0.top >= y - 0.5 }
                let crossing = lines.contains { $0.top < y - 0.5 && $0.bottom > y + 0.5 }
                let sameTable = before?.table != nil && before?.table == after?.table
                if crossing || sameTable { straddled += 1 } else { clean += 1 }
            }
            print("PROBE unopened WITH a table straddling: \(straddled)")
            print("PROBE unopened with NOTHING straddling: \(clean)")

            // For each STILL-welded boundary: is the character at that page's top inside a piece
            // the reader registered as oversized? That record is what lets a line inside a table be
            // shifted at all (`PageBandLayoutDelegate` line 334), so a boundary that is welded AND
            // uncovered is one invariant 61's policy never reached.
            // Is the record simply INCOMPLETE? `openedBoundaries` is wiped on every settle round and
            // refilled only for lines the layout manager actually re-lays; a tail laid out before the
            // last reset therefore has real bands that nothing recorded.
            let beforeCount = d.openedBoundaries.count
            d.resetOpenedBoundaries()
            lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: len), actualCharacterRange: nil)
            lm.ensureLayout(for: tc)
            print("PROBE opened after a FORCED full relayout: \(d.openedBoundaries.count) (was \(beforeCount))")
            print("PROBE pageSheets after that: \(wc.pageSheets.count) of \(wc.printSheets.count)")
            let un2 = (0..<max(0, wc.printSheets.count - 1)).filter { !d.openedBoundaries.contains($0) }
            print("PROBE unopened AFTER forced: \(un2.count) -> \(un2.prefix(25).map(String.init).joined(separator: ","))")

            let stillWelded = unopened.filter { d.tableStraddledBoundaries?.contains($0) ?? true }
            print("PROBE still welded: \(stillWelded.count) -> \(stillWelded.map(String.init).joined(separator: ","))")
            for b in stillWelded {
                let y = d.leadingBand + CGFloat(b + 1) * pitch2
                let c = lm.characterIndex(for: NSPoint(x: 4, y: y + 2), in: tc,
                                          fractionOfDistanceBetweenInsertionPoints: nil)
                let covered = d.oversizedPieces.contains { c >= $0.key && c < $0.value }
                let pushed = d.pushedTables.keys.contains { $0 <= c }
                print("PROBE   boundary \(b): char \(c) oversized=\(covered) anyPushedBefore=\(pushed)")
            }
        }
    }
}
