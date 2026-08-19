import XCTest
import AppKit
@testable import FastDocReader

/// DOES A REAL COLUMN RUN EVER BEGIN PARTWAY DOWN A SHEET?
///
/// Invariant 100 recorded, as a known limit, that a run starting mid-page was laid out from that
/// page's TOP — which both drew the run over the single-column text above it and gave every later
/// sheet the first sheet's leftover height. `ColumnGeometry.placements` now carries two column
/// heights and starts the run where the run starts. This probe is the instrument that says how much
/// that is worth, and it is re-runnable rather than a number someone has to trust.
///
/// `FMD_COLUMN_START_PROBE=<dir>[:<dir>…]` — colon-separated directories walked for office
/// documents, the same shape `FMD_RENDER_CORPUS` uses. PRIVACY: counts only. No document text, no
/// filename and no path is ever printed.
final class ColumnRunStartProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PageViewOptionsStore.current = PageViewOptions(outline: true)
    }

    override func tearDown() {
        PageViewOptionsStore.reset()
        super.tearDown()
    }

    func testWhereRealColumnRunsBegin() throws {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_COLUMN_START_PROBE"] else {
            throw XCTSkip("set FMD_COLUMN_START_PROBE=<dir>[:<dir>] to walk a corpus for column runs")
        }
        let fm = FileManager.default
        var files: [URL] = []
        for dir in dirs.split(separator: ":").map(String.init) {
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: dir),
                                           includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk
            where DocumentTypes.officeExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
        }
        print("PROBE candidate documents=\(files.count)")
        try XCTSkipIf(files.isEmpty, "no office documents under the given directories")

        var docsWithRuns = 0, runs = 0, midPageRuns = 0
        var midPageLines = 0, totalLines = 0
        var read = 0, failed = 0
        for url in files {
            autoreleasepool {
                guard let data = try? Data(contentsOf: url) else { failed += 1; return }
                let doc = MarkdownDocument()
                doc.fileURL = url
                do { try doc.read(from: data, ofType: "public.data") } catch { failed += 1; return }
                read += 1
                NSWindow.removeFrame(usingName: "FastMDReaderDoc")
                doc.makeWindowControllers()
                guard let wc = doc.windowControllers.first as? DocumentWindowController else { return }
                defer { doc.windowControllers.forEach { doc.removeWindowController($0) } }
                wc.textView.postsFrameChangedNotifications = false
                wc.textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
                wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
                wc.window?.contentView?.layoutSubtreeIfNeeded()
                wc.updateTextInset()

                let declared = wc.columnRunRanges()
                guard !declared.isEmpty else { return }
                guard let lm = wc.textView.layoutManager, let tc = wc.textView.textContainer else { return }
                let delegate = wc.pageBandDelegate
                let pitch = PagePagination.pitch(pageContentHeight: delegate.pageContentHeight,
                                                 band: delegate.band)
                guard pitch > 0 else { return }
                lm.ensureLayout(for: tc)
                var sawRun = false
                for run in declared {
                    let columns = ColumnGeometry.columns(inWidth: delegate.columnBodyWidth,
                                                         layout: run.layout)
                    guard columns.count > 1 else { continue }
                    let glyphs = lm.glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
                    var firstTop: CGFloat?
                    var lines = 0
                    lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                        if firstTop == nil { firstTop = rect.minY }
                        lines += 1
                    }
                    guard let top = firstTop else { continue }
                    sawRun = true
                    runs += 1
                    totalLines += lines
                    let page = PageBandLayoutDelegate.page(of: top, leadingBand: delegate.leadingBand,
                                                           pitch: pitch)
                    let pageTop = page * pitch + delegate.leadingBand
                    // One point of slack: a run that begins at a page top lands there to within a
                    // line's own rounding, the same order every other rule here tolerates.
                    if top - pageTop > 1 { midPageRuns += 1; midPageLines += lines }
                }
                if sawRun { docsWithRuns += 1 }
            }
        }
        print("PROBE read=\(read) failed=\(failed) docsWithColumnRuns=\(docsWithRuns)")
        print("PROBE runs=\(runs) midPageRuns=\(midPageRuns) " +
              "(\(runs == 0 ? 0 : midPageRuns * 100 / runs)%)")
        print("PROBE lines under a run=\(totalLines) of which in a mid-page run=\(midPageLines)")
        XCTAssertGreaterThan(read, 0, "nothing was read — this probe measured nothing")
    }
}
