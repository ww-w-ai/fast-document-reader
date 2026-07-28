import XCTest
import AppKit
@testable import FastDocReader

/// Decomposes the newline-only attribute runs a real document still pays for, and lays it out.
///
/// Invariant 51 merged a table CELL's terminating newline into the cell's own run. What it left
/// behind, and named in its own last sentence, is `OfficeTextBuilder.cellContent`'s INTERIOR
/// separator — the `"\n"` joined between two blocks of a multi-paragraph cell. This probe is the
/// instrument that tells the three kinds apart, because the total alone cannot: a newline run is an
/// EMPTY-cell terminator (nothing of its own cell precedes it), an INTERIOR separator (more of the
/// same cell follows it), or a CELL terminator (its cell ends there and declined to inherit).
///
///     FMD_SEP_PROBE="/path/a.hwp:/path/b.docx" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter testInteriorSeparatorDecomposition
///
/// Skipped by default — it needs documents this repo does not ship. It reports and asserts nothing
/// about the numbers: what counts as "too many runs" is a judgement made with the measurement in
/// hand. The one thing it DOES assert is that the walk found something, so a silently empty run
/// cannot read as a clean result.
final class InteriorSeparatorProbeTests: XCTestCase {
    /// How a single newline run is classified, and the counts a document produces.
    struct Decomposition {
        var totalRuns = 0
        var newlineRuns = 0
        var cellTerminators = 0
        var interiorSeparators = 0
        var emptyCellTerminators = 0
        var looseNewlines = 0          // a newline run outside any table
        /// Of `interiorSeparators`, the ones terminating an EMPTY paragraph — a block inside a cell
        /// that produced no text of its own. Those can never merge: there is nothing to merge with,
        /// which is invariant 51's empty-cell rule reaching one layer up. Splitting them out is what
        /// tells a residue that is IRREDUCIBLE apart from one that is a missed case.
        var interiorAfterEmptyParagraph = 0
        var laidOutHeight: CGFloat = 0
    }

    /// The classifier, counted per newline CHARACTER rather than per run.
    ///
    /// Counting runs of length exactly 1 was the first version and it UNDER-reports: two adjacent
    /// separators whose attributes happen to be equal coalesce into one run of length 2, which such a
    /// test never sees, so a real cost hides behind its own coalescing. The question this probe exists
    /// to answer is "how many newlines still fail to merge into their content", so the unit is the
    /// newline: a newline is UN-MERGED when the run it sits in holds no non-newline character.
    static func decompose(_ attr: NSAttributedString) -> Decomposition {
        var d = Decomposition()
        let ns = attr.string as NSString
        func block(at i: Int) -> NSTextTableBlock? {
            guard i >= 0, i < attr.length else { return nil }
            let ps = attr.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
            return ps?.textBlocks.first as? NSTextTableBlock
        }
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { a, r, _ in
            d.totalRuns += 1
            var newlines: [Int] = []
            var hasContent = false
            for i in r.location..<(r.location + r.length) {
                if ns.character(at: i) == 10 { newlines.append(i) } else { hasContent = true }
            }
            guard !hasContent else { return }
            for i in newlines {
                d.newlineRuns += 1
                guard let mine = (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else {
                    d.looseNewlines += 1
                    continue
                }
                let prev = block(at: i - 1)
                let next = block(at: i + 1)
                if prev !== mine {
                    d.emptyCellTerminators += 1
                } else if next === mine {
                    d.interiorSeparators += 1
                    if i > 0, ns.character(at: i - 1) == 10 { d.interiorAfterEmptyParagraph += 1 }
                } else {
                    d.cellTerminators += 1
                }
            }
        }
        d.laidOutHeight = Self.laidOutHeight(attr)
        return d
    }

    /// Laid out through a real layout manager at the width the string was built for, in a container
    /// with slack so an overshoot cannot be clipped into looking exact (invariant 50's trap).
    static func laidOutHeight(_ attr: NSAttributedString, width: CGFloat = 700) -> CGFloat {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: width + 200, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        storage.addLayoutManager(lm); lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height
    }

    /// Reads a document through the SAME dispatch the app uses (invariant 29/44) and builds it at the
    /// same 700pt column every measurement in invariant 51 used, so the two are comparable.
    static func build(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        let result: OfficeReadResult = DocumentTypes.isHwp(ext)
            ? try HwpReader.read(try Data(contentsOf: url))
            : try DocumentTypes.readOffice(try ZipArchive(data: Data(contentsOf: url)), extension: ext)
        return OfficeTextBuilder.build(result.blocks, theme: RenderTheme.current(size: 16),
                                       columnWidth: 700,
                                       pageContentWidth: result.pageContentWidth,
                                       tableWidth: 700)
    }

    /// Invariant 48, on a real document: re-solving every table's columns at the width they were
    /// BUILT at must move zero cells. This unit merges a cell's paragraphs into fewer
    /// `.paragraphStyle` runs, and `resizeTables` walks exactly those runs — so a cell could in
    /// principle go MISSING from that walk rather than merely not move, which is why the denominator
    /// is reported and not just the numerator.
    static func cellsMovedByAResizeAtTheBuildWidth(_ attr: NSAttributedString,
                                                   width: CGFloat = 700) -> (moved: Int, cells: Int) {
        let storage = NSTextStorage(attributedString: attr)
        func widths() -> [ObjectIdentifier: CGFloat] {
            var out: [ObjectIdentifier: CGFloat] = [:]
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                guard let b = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
                out[ObjectIdentifier(b)] = b.contentWidth
            }
            return out
        }
        let before = widths()
        TableBlockBuilder.resizeTables(in: storage, toWidth: width)
        let after = widths()
        let moved = before.reduce(into: 0) { n, kv in if after[kv.key] != kv.value { n += 1 } }
        return (moved, before.count)
    }

    func testInteriorSeparatorDecomposition() throws {
        guard let list = ProcessInfo.processInfo.environment["FMD_SEP_PROBE"] else {
            throw XCTSkip("set FMD_SEP_PROBE to a colon-separated list of real office documents")
        }
        var any = false
        for path in list.split(separator: ":").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let attr = try Self.build(url)
            let d = Self.decompose(attr)
            let (moved, cells) = Self.cellsMovedByAResizeAtTheBuildWidth(attr)
            any = true
            XCTAssertEqual(moved, 0,
                           "\(url.lastPathComponent): invariant 48 — re-solving at the width the table "
                           + "was BUILT at must move no cell, and \(moved) of \(cells) moved")
            print("""
            separator decomposition — \(url.lastPathComponent)
              length                 \(attr.length)
              TOTAL attribute runs   \(d.totalRuns)
              UN-MERGED newlines     \(d.newlineRuns)
                cell terminators     \(d.cellTerminators)
                INTERIOR separators  \(d.interiorSeparators)  (of which after an EMPTY paragraph: \(d.interiorAfterEmptyParagraph))
                empty-cell terms     \(d.emptyCellTerminators)
                outside any table    \(d.looseNewlines)
              laid-out height        \(String(format: "%.5f", d.laidOutHeight))
              cells moved by a resize at the build width
                                     \(moved) of \(cells)
            """)
        }
        XCTAssertTrue(any, "FMD_SEP_PROBE named no readable document — an empty walk is not a clean result")
    }

    /// The same decomposition over the office fixtures this repo DOES ship, so the number is
    /// reproducible without the two real reports. Not skipped.
    func testFixtureDecomposition() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/office")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("docs/fixtures/office is gitignored and absent in this checkout")
        }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["docx", "odt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no office fixtures found — an empty walk is not a clean result")
        for url in files {
            let d = Self.decompose(try Self.build(url))
            print("fixture \(url.lastPathComponent): runs \(d.totalRuns) · unmerged newlines \(d.newlineRuns) "
                  + "(cell \(d.cellTerminators) · interior \(d.interiorSeparators) · empty \(d.emptyCellTerminators) "
                  + "· loose \(d.looseNewlines)) · height \(String(format: "%.5f", d.laidOutHeight))")
        }
    }
}
