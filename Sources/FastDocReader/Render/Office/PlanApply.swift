import AppKit

/// The one plan-vs-applied parity check.
///
/// Pagination is the engine's decision and the host applies it line by line
/// (`PageBandLayoutDelegate`). This reads the visible layout back and compares it with the plan that
/// produced it: every line the plan names stands at its target, the sheets the layout fills are the
/// plan's, and a second layout of the same text puts every line where the first did. Used by
/// `PlanParityProbeTests` (`FMD_PLAN_PARITY=<document>[:<document>...]`); nothing in the app calls it.
enum PlanAppliedParity {
    struct Report {
        var skipped: String?
        var targets = 0
        var untargetedLines = 0
        var differing = 0
        var firstDifference: String?
        /// The first few differing lines with what kind each is, for diagnosis.
        var details: [String] = []
        var pagesPlan = 0
        var pagesApplied = 0
        var unstable = 0
        var openedBoundaries = 0
        /// Lines of a table cell in a columned run that AppKit moved down inside the cell's box after
        /// the delegate set them, on the same page (the table re-lays its cell out once the delegate has
        /// answered; S0's reader showed the same moves). Reported, not held as a difference.
        var cellSettled = 0
        var cellSettledMost: CGFloat = 0
        var text: String {
            if let skipped { return "PARITY skipped: \(skipped)" }
            return (details.isEmpty ? "" : details.joined(separator: "\n") + "\n") + "PARITY targets \(targets): differing \(differing) (first: \(firstDifference ?? "none")); untargeted lines \(untargetedLines); pages plan \(pagesPlan) applied \(pagesApplied); unstable after a second layout \(unstable); opened boundaries \(openedBoundaries); column cell lines AppKit settled within their page \(cellSettled) (most \(String(format: "%.2f", Double(cellSettledMost))))"
        }
    }

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

    /// Lays `wc` out for paper exactly as `--pdf` does (`makePrintOperation`: print layout, one plan
    /// generation, trailing band), then reads the layout back against the plan it applied.
    static func run(controller wc: DocumentWindowController) -> Report {
        var report = Report()
        guard wc.pageBandDelegate.paginates, let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer,
              let storage = wc.textView.textStorage, storage.length > 0 else {
            report.skipped = "not paged"
            return report
        }
        _ = wc.makePrintOperation()
        lm.ensureLayout(for: tc)
        guard let plan = wc.lastPlan else {
            report.skipped = "no plan was applied"
            return report
        }
        let delegate = wc.pageBandDelegate
        let first = lines(of: lm, tc, length: storage.length)
        report.targets = delegate.targets.count
        report.pagesPlan = (plan["pageCount"] as? NSNumber)?.intValue ?? -1
        report.pagesApplied = wc.printPageCount
        report.openedBoundaries = delegate.openedBoundaries.count
        let pitch = delegate.pageContentHeight + delegate.band
        func page(_ y: CGFloat) -> Int { Int(PageBandLayoutDelegate.page(of: y, leadingBand: delegate.leadingBand, pitch: pitch)) }
        for (loc, target) in delegate.targets {
            guard let line = first[loc] else {
                report.differing += 1
                report.firstDifference = report.firstDifference ?? "line at \(loc) is not in the layout"
                continue
            }
            // A line in a cell the document centres (or bottom-aligns) is set at its proposed top and
            // then moved inside the cell's box by AppKit, after the delegate has answered (invariant
            // 72): where it ends up inside the box is not a page decision, so only its page is held.
            let style = loc < storage.length ? storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle : nil
            if let cell = style?.textBlocks.first as? NSTextTableBlock, cell.verticalAlignment != .topAlignment {
                if page(line.y) != page(target.y) {
                    report.differing += 1
                    report.firstDifference = report.firstDifference ?? "line at \(loc) is on page \(page(line.y) + 1), the plan said \(page(target.y) + 1)"
                }
                continue
            }
            let expectedX = target.columnX.map { $0 + target.insetX }
            let dy = line.y - target.y
            if style?.textBlocks.first is NSTextTableBlock, target.columnX != nil, dy > 0.6, dy < 6,
               page(line.y) == page(target.y), expectedX.map({ abs(line.x - $0) <= 0.6 }) ?? true {
                report.cellSettled += 1
                report.cellSettledMost = max(report.cellSettledMost, dy)
                continue
            }
            if abs(line.y - target.y) > 0.6 || (expectedX.map { abs(line.x - $0) > 0.6 } ?? false) {
                report.differing += 1
                if report.details.count < 12 {
                    let cell = style?.textBlocks.first as? NSTextTableBlock
                    report.details.append(String(format: "PARITY   line %d: plan y %.2f x %@, applied y %.2f x %.2f, %@, column %@",
                                                 loc, Double(target.y), expectedX.map { String(format: "%.2f", Double($0)) } ?? "-",
                                                 Double(line.y), Double(line.x),
                                                 cell.map { "cell r\($0.startingRow) c\($0.startingColumn) align \($0.verticalAlignment.rawValue)/authored \($0.authoredVerticalAlignment.rawValue)" } ?? "not in a table",
                                                 target.columnX != nil ? "yes" : "no"))
                }
                report.firstDifference = report.firstDifference ?? String(
                    format: "line at %d: plan y %.2f, applied y %.2f", loc, Double(target.y), Double(line.y))
            }
        }
        report.untargetedLines = first.keys.filter { delegate.targets[$0] == nil }.count
        // A second layout of the same text: the answer must not depend on the order lines are asked in.
        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        lm.ensureLayout(for: tc)
        let second = lines(of: lm, tc, length: storage.length)
        for (loc, a) in first {
            guard let b = second[loc], abs(a.y - b.y) <= 0.001, abs(a.x - b.x) <= 0.001 else { report.unstable += 1; continue }
        }
        return report
    }
}
