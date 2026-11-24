import AppKit

/// S6b2-0c of `docs/plans/pagination-to-engine.md`: the apply pass, as a probe.
///
/// `PageBandLayoutDelegate` decides pages by arithmetic on the rect the typesetter proposes. The apply
/// delegate decides nothing: a line whose first character has a plan target is put at that target
/// (a pure lookup by character location, so a second layout of the same text gives the same answer),
/// and every other line is left to the typesetter. There is no page arithmetic, no band, no push, no
/// pull and no settle loop; the plan is the whole decision.
///
/// Nothing in the app creates this: `PlanApplyProbe` lays the document out once more on a layout
/// manager of its own, beside the visible one, and reads every line back (`PagePlanShadowProbeTests`,
/// `FMD_PLAN_APPLY=1`). Wiring it into the screen, ⌘P and `--pdf` is S6b2.
final class PlanApplyDelegate: NSObject, NSLayoutManagerDelegate {
    /// Where one line goes: the page-grid `y` of its top and, for a line in a columned run, the
    /// left edge of its column plus how far a table cell stood from the run's own left edge in the
    /// natural layout (`insetX`). The proposed rect cannot say: a table line's `x` is only final once
    /// the table has laid its cell out, after this delegate has answered.
    struct Target {
        var y: CGFloat
        var columnX: CGFloat?
        var insetX: CGFloat
    }

    private weak var storage: NSTextStorage?
    var targets: [Int: Target] = [:]
    /// Each line the delegate moved, by character location: the `y` it was set to, and what kind of
    /// line it is. Read back after the walk to see whether TextKit left it there.
    private(set) var placed: [Int: (y: CGFloat, kind: Kind)] = [:]
    /// How often the typesetter asked about each line: more than once means a re-layout reached it.
    private(set) var visits: [Int: Int] = [:]
    private(set) var proposedX: [Int: CGFloat] = [:]

    enum Kind: String { case text, column, table }

    init(storage: NSTextStorage) {
        self.storage = storage
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, !targets.isEmpty else { return false }
        let location = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
        visits[location, default: 0] += 1
        guard let target = targets[location] else { return false }
        let rect = lineFragmentRect.pointee
        var inTable = false
        if let storage, location >= 0, location < storage.length,
           let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle {
            inTable = style.textBlocks.contains { $0 is NSTextTableBlock }
        }
        let x = target.columnX.map { $0 + target.insetX } ?? rect.minX
        proposedX[location] = rect.minX
        placed[location] = (target.y, target.columnX != nil ? .column : (inTable ? .table : .text))
        let dx = x - rect.minX, dy = target.y - rect.minY
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return false }
        lineFragmentRect.pointee.origin.x = x
        lineFragmentRect.pointee.origin.y = target.y
        lineFragmentUsedRect.pointee.origin.x += dx
        lineFragmentUsedRect.pointee.origin.y += dy
        return true
    }
}

/// The apply pass run beside the visible layout, and what it is compared with.
enum PlanApplyProbe {
    struct Line {
        var y: CGFloat
        var x: CGFloat
    }

    /// Every line fragment of a layout by the character location of its first character.
    static func lines(of lm: NSLayoutManager, _ tc: NSTextContainer, length: Int) -> [Int: Line] {
        var out: [Int: Line] = [:]
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, glyphRange, _ in
            let at = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
            guard at >= 0, at < length else { return }
            out[at] = Line(y: rect.minY, x: rect.minX)
        }
        return out
    }

    /// How many sheets the layout fills, by the formula `printPageCount` uses: from the last line.
    static func pageCount(of lm: NSLayoutManager, leading: CGFloat, pageContentHeight: CGFloat, band: CGFloat) -> Int {
        let last = lm.numberOfGlyphs - 1
        let bottom = last >= 0 ? lm.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY : 0
        return PageBandPainter.totalPages(documentHeight: max(0, bottom - leading),
                                          pitch: PagePagination.pitch(pageContentHeight: pageContentHeight, band: band))
    }

    /// The plan's targets as the delegate wants them. The plan names a page and a top on the PRINT
    /// grid; the host turns that into its `y`, adding `deskGap` per page where the screen has one.
    static func targets(plan: [String: Any], leading: CGFloat, pitch: CGFloat, deskGap: CGFloat,
                        columnRuns: [(range: NSRange, layout: OfficeColumnLayout)], bodyWidth: CGFloat,
                        insetX: [Int: CGFloat], naturalTop: [Int: CGFloat]) -> [Int: PlanApplyDelegate.Target] {
        var columns: [[ColumnGeometry.Column]] = []
        for run in columnRuns { columns.append(ColumnGeometry.columns(inWidth: bodyWidth, layout: run.layout)) }
        var out: [Int: PlanApplyDelegate.Target] = [:]
        for target in (plan["targets"] as? [[String: Any]]) ?? [] {
            guard let loc = (target["loc"] as? NSNumber)?.intValue, let page = (target["page"] as? NSNumber)?.intValue,
                  let top = (target["top"] as? NSNumber)?.doubleValue else { continue }
            let y = leading + CGFloat(page) * (pitch + deskGap) + CGFloat(top)
            var columnX: CGFloat?
            if let column = (target["column"] as? NSNumber)?.intValue,
               let run = columnRuns.firstIndex(where: { NSLocationInRange(loc, $0.range) }), column < columns[run].count {
                columnX = columns[run][column].x
            }
            out[loc] = PlanApplyDelegate.Target(y: y, columnX: columnX, insetX: insetX[loc] ?? 0)
        }
        // A line of a columned run the plan names no target for sits on the natural line of one it
        // does (a fragment of a table row that is no cell's paragraph): it goes where that sibling
        // goes, by the distance the two stand apart in the natural stack.
        var byTop: [Int: [Int]] = [:]
        for (loc, top) in naturalTop where out[loc]?.columnX != nil { byTop[Int((top * 20).rounded()), default: []].append(loc) }
        for (loc, top) in naturalTop where out[loc] == nil {
            let key = Int((top * 20).rounded())
            // Several cells of one row can stand on the natural line and be dealt to different columns
            // (a tall one is carried on, a short one is not): the nearest in the text is its own.
            let sibling = (key - 2...key + 2).flatMap { byTop[$0] ?? [] }
                .filter { abs((naturalTop[$0] ?? .infinity) - top) <= 0.1 }
                .min { abs($0 - loc) < abs($1 - loc) }
            guard let sibling, let target = out[sibling] else { continue }
            out[loc] = PlanApplyDelegate.Target(y: target.y + (top - (naturalTop[sibling] ?? top)), columnX: target.columnX, insetX: 0)
        }
        return out
    }

    /// Lays the document out on a layout manager the apply delegate drives, reads every line back
    /// and compares it with what TextKit's reader printed (`reader`), what the plan said (`plan`),
    /// and a second layout of the same text. One report line per axis.
    static func run(wc: DocumentWindowController, plan: [String: Any], reader: [Int: Line], readerPages: Int,
                    leading: CGFloat, pageContentHeight: CGFloat, band: CGFloat,
                    columnRuns: [(range: NSRange, layout: OfficeColumnLayout)], bodyWidth: CGFloat,
                    insetX: [Int: CGFloat], naturalTop: [Int: CGFloat]) -> [String] {
        guard let storage = wc.textView.textStorage, let tc = wc.textView.textContainer else { return ["APPLY skipped: no storage"] }
        let pitch = pageContentHeight + band
        let delegate = PlanApplyDelegate(storage: storage)
        delegate.targets = targets(plan: plan, leading: leading, pitch: pitch, deskGap: 0, columnRuns: columnRuns,
                                   bodyWidth: bodyWidth, insetX: insetX, naturalTop: naturalTop)
        let applied = PlanObservation(storage: storage, like: tc, applying: delegate)
        defer { applied.remove() }
        applied.walk()
        let first = lines(of: applied.layout, applied.container, length: storage.length)
        let countApplied = pageCount(of: applied.layout, leading: leading, pageContentHeight: pageContentHeight, band: band)
        // A second layout of the same text: if TextKit moved a line after it was placed, or the
        // answer depended on the order the lines were asked in, the two layouts would differ.
        let placedFirst = delegate.placed
        let visitsFirst = delegate.visits
        applied.layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        applied.walk()
        let second = lines(of: applied.layout, applied.container, length: storage.length)

        func local(_ y: CGFloat) -> (page: Int, top: CGFloat) {
            let p = Int(PageBandLayoutDelegate.page(of: y, leadingBand: leading, pitch: pitch))
            return (p, y - leading - CGFloat(p) * pitch)
        }
        var different = 0, pageDiff = 0, topDiff = 0, xDiff = 0, missing = 0, extra = 0, loose = 0
        var maxDelta: CGFloat = 0
        var firstDifference: String?
        for (loc, r) in reader {
            guard let a = first[loc] else { missing += 1; continue }
            let (rp, rt) = local(r.y), (ap, at) = local(a.y)
            let delta = abs(rt - at)
            let bad: Bool
            if rp != ap { pageDiff += 1; bad = true }
            else if delta > 0.6 { topDiff += 1; maxDelta = max(maxDelta, delta); bad = true }
            else if abs(r.x - a.x) > 0.6 { xDiff += 1; bad = true }
            else { bad = false }
            if delta > 0.01, rp == ap { loose += 1 }
            if bad {
                different += 1
                if firstDifference == nil {
                    firstDifference = "line at \(loc): TextKit p\(rp + 1) top \(String(format: "%.2f", Double(rt))) x \(String(format: "%.2f", Double(r.x))); applied p\(ap + 1) top \(String(format: "%.2f", Double(at))) x \(String(format: "%.2f", Double(a.x)))"
                }
                if ProcessInfo.processInfo.environment["FMD_PLAN_APPLY_LIST"] == "1" {
                    let near = first.filter { $0.key != loc && abs($0.value.y - a.y) < 0.2 }.sorted { $0.key < $1.key }.prefix(6)
                        .map { "\($0.key)\(delegate.targets[$0.key] == nil ? "-" : "+")@\(String(format: "%.2f", Double($0.value.y)))x\(String(format: "%.1f", Double($0.value.x)))" }.joined(separator: " ")
                    print("APPLY   near \(loc) (\(String(format: "%.2f", Double(a.y)))): \(near)")
                    print("APPLY   differs at \(loc): TextKit p\(rp + 1) top \(String(format: "%.2f", Double(rt))) x \(String(format: "%.2f", Double(r.x))); applied p\(ap + 1) top \(String(format: "%.2f", Double(at))) x \(String(format: "%.2f", Double(a.x))); blockId \(storage.attribute(MDAttr.blockId, at: loc, effectiveRange: nil) as? Int ?? -1) blocks \((storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.count ?? -1) text \(String((storage.string as NSString).substring(with: NSRange(location: loc, length: min(10, storage.length - loc))).filter { !$0.isNewline })) kind \(placedFirst[loc]?.kind.rawValue ?? "-") proposedX \(delegate.proposedX[loc].map { String(format: "%.2f", Double($0)) } ?? "-") columnX \(delegate.targets[loc]?.columnX.map { String(format: "%.2f", Double($0)) } ?? "-")")
                }
            }
        }
        for loc in first.keys where reader[loc] == nil { extra += 1 }
        // The plan against the applied layout, for the lines the plan placed by themselves.
        var planTexts = 0, planMoved = 0
        var byKind: [String: (placed: Int, moved: Int, big: Int, most: CGFloat)] = [:]
        for (loc, place) in placedFirst {
            guard let a = first[loc] else { continue }
            planTexts += 1
            let move = abs(a.y - place.y)
            let moved = move > 0.01
            if moved { planMoved += 1 }
            var entry = byKind[place.kind.rawValue] ?? (0, 0, 0, 0)
            entry.placed += 1
            if moved { entry.moved += 1 }
            if move > 0.6 {
                entry.big += 1
                if ProcessInfo.processInfo.environment["FMD_PLAN_APPLY_LIST"] == "1" {
                    print("APPLY   moved at \(loc) (\(place.kind.rawValue)): set y \(String(format: "%.2f", Double(place.y))) final y \(String(format: "%.2f", Double(a.y))) TextKit y \(reader[loc].map { String(format: "%.2f", Double($0.y)) } ?? "-") blockId \(storage.attribute(MDAttr.blockId, at: loc, effectiveRange: nil) as? Int ?? -1)")
                }
            }
            entry.most = max(entry.most, move)
            byKind[place.kind.rawValue] = entry
        }
        var unstable = 0
        for (loc, a) in first {
            guard let b = second[loc] else { unstable += 1; continue }
            if abs(a.y - b.y) > 0.001 || abs(a.x - b.x) > 0.001 { unstable += 1 }
        }
        let untargeted = first.keys.filter { delegate.targets[$0] == nil }.count
        let revisited = visitsFirst.values.filter { $0 > 1 }.count
        let planPages = (plan["pageCount"] as? NSNumber)?.intValue ?? -1
        return [
            "APPLY lines: \(reader.count) in TextKit, \(first.count) applied (missing \(missing), extra \(extra)); differing: \(different) (page \(pageDiff), top \(topDiff), x \(xDiff)); max top delta \(String(format: "%.3f", Double(maxDelta))); within-page deltas over 0.01: \(loose); first: \(firstDifference ?? "none")",
            "APPLY pages: applied \(countApplied), plan \(planPages), TextKit \(readerPages)",
            "APPLY placed: \(delegate.targets.count) targets, \(placedFirst.count) lines set; untargeted lines \(untargeted); set lines TextKit moved afterwards: \(planMoved) of \(planTexts) (\(byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.moved)/\($0.value.placed), over 0.6: \($0.value.big), most \(String(format: "%.3f", Double($0.value.most)))" }.joined(separator: ", ")))",
            "APPLY stability: lines differing between two layouts of the same text: \(unstable); lines the typesetter asked about again during the first walk: \(revisited)",
        ]
    }
}
