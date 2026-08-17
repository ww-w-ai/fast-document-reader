import XCTest
import AppKit
@testable import FastDocReader

/// What one table CELL actually costs in the built string, split into the part we could take back and
/// the part `NSTextTable` charges whatever we do.
///
/// **The question this exists to settle.** Measured with the whole-reader probe on a generated
/// markdown document of 300 tables (15,000 cells, 370k characters) against a twin holding the SAME
/// text with the table syntax flattened away: memory after full layout **689 MB against 142 MB**, full
/// layout **6,356 ms against 1,775 ms**, and drawing a screenful **10.3 ms against 9.2 ms**. So the
/// table machinery costs ~36 KB and ~0.3 ms per cell, and almost none of it is DRAWING. That fixes the
/// size of the prize; it does not say whether the prize is reachable without replacing the engine.
///
/// Invariant 42 is the reason that distinction decides the next move rather than a preference: twice
/// now, "the native API is slow / does not align" turned out to be OUR INPUT, and the custom engine
/// built in between measured worse and was deleted. Invariant 51 is the same lesson paying out — the
/// single biggest win in this reader was a cell's terminating newline carrying the cell's own
/// attributes instead of a fresh default one, worth −48% attribute runs and −71% `display`, with no
/// engine change at all.
///
/// So this probe reports three numbers per cell and one ratio:
///
///  - **runs/cell** — the axis invariant 51 moved, and the axis three separate costs follow.
///  - **paragraph styles/cell** — one per cell is unavoidable (a style is how a cell's block reaches
///    the text), more than one is ours.
///  - **table blocks/cell** — must be exactly 1.0; anything above it means a cell built more than one
///    `NSTextTableBlock`, which nothing in the vocabulary asks for.
///  - **distinct styles IGNORING their blocks** — the split that answers the question. Every cell needs
///    its own style OBJECT because the style is what carries that cell's block, but if all 15,000 of
///    them are otherwise the same VALUE, the per-cell weight is `NSTextTableBlock`'s own and only a
///    different engine can take it back. If instead they differ in dozens of ways nothing in the
///    document asked for, that difference is ours to remove and invariant 51 says what that is worth.
///
///     FMD_TABLE_COST_PROBE="/path/to/doc.hwp" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter testTableCellCost
///
/// Skipped by default: it needs a document this repo does not ship. It reports and asserts only the
/// one thing that is a defect at any size (a cell with more than one block).
final class TableCellCostProbeTests: XCTestCase {
    private func f(_ v: Double) -> String { String(format: "%.2f", v) }

    func testTableCellCost() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_TABLE_COST_PROBE"] else {
            throw XCTSkip("set FMD_TABLE_COST_PROBE to an absolute path naming a real document")
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let uti: String = {
            switch ext {
            case "odt": return "org.oasis-open.opendocument.text"
            case "hwp", "hwpx": return "com.hancom.hwp"
            case "md", "markdown": return "net.daringfireball.markdown"
            case "txt": return "public.plain-text"
            default: return "org.openxmlformats.wordprocessingml.document"
            }
        }()

        // The same door a double-click uses, for the same reason the whole-reader probe gives: a
        // builder can be entirely correct and UNREACHED by the app (invariant 29).
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: uti)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 900), display: false)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let storage = try XCTUnwrap(wc.textStorageRef)
        let whole = NSRange(location: 0, length: storage.length)
        guard storage.length > 0 else { throw XCTSkip("the document built to nothing") }

        var runs = 0, runsInTables = 0
        var styleIdentities = Set<ObjectIdentifier>()
        var blockIdentities = Set<ObjectIdentifier>()
        var tableIdentities = Set<ObjectIdentifier>()
        var charsInTables = 0
        // Distinct paragraph-style VALUES once the blocks are taken out — compared with
        // `NSParagraphStyle`'s own equality rather than a hand-written field list, so a field added
        // later is compared without anyone remembering this probe exists. Linear over the
        // representatives, which stay in the dozens on every document measured.
        var blocklessRepresentatives: [NSParagraphStyle] = []
        var blocklessInTables = 0

        let dumpLimit = Int(ProcessInfo.processInfo.environment["FMD_TABLE_COST_DUMP"] ?? "0") ?? 0
        var dumped = 0
        storage.enumerateAttributes(in: whole, options: []) { attrs, range, _ in
            runs += 1
            if dumped < dumpLimit, attrs[.paragraphStyle].map({ ($0 as? NSParagraphStyle)?.textBlocks.isEmpty == false }) == true {
                let text = (storage.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
                let font = (attrs[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)pt" } ?? "no-font"
                print("DUMP {\(range.location),\(range.length)} \"\(text.prefix(24))\" font=\(font)")
                dumped += 1
            }
            guard let style = attrs[.paragraphStyle] as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock else { return }
            runsInTables += 1
            charsInTables += range.length
            styleIdentities.insert(ObjectIdentifier(style))
            blockIdentities.insert(ObjectIdentifier(block))
            tableIdentities.insert(ObjectIdentifier(block.table))
            XCTAssertEqual(style.textBlocks.count, 1,
                           "a cell carries exactly one text block — \(style.textBlocks.count) at "
                           + "character \(range.location) means the builder nested what it should not")

            let bare = style.mutableCopy() as! NSMutableParagraphStyle
            bare.textBlocks = []
            if !blocklessRepresentatives.contains(where: { $0.isEqual(bare) }) {
                blocklessRepresentatives.append(bare.copy() as! NSParagraphStyle)
            }
            blocklessInTables += 1
        }

        // How many font runs are made ONLY of characters with no script of their own (spaces,
        // digits, punctuation). A run like that could have joined either neighbour, so it is the
        // share a script-aware pass could take back — see invariant 93's residual.
        var neutralRuns = 0, fontRuns = 0
        storage.enumerateAttribute(.font, in: whole, options: []) { _, range, _ in
            fontRuns += 1
            let piece = (storage.string as NSString).substring(with: range)
            if !piece.isEmpty, piece.unicodeScalars.allSatisfy({ UnicodeScript.of($0).isAbsorbing }) {
                neutralRuns += 1
            }
        }
        print("NEUTRAL fontRuns=\(fontRuns) neutralOnlyRuns=\(neutralRuns) "
              + "share=\(fontRuns > 0 ? Int(Double(neutralRuns) / Double(fontRuns) * 100) : 0)%")

        // WHICH attribute is doing the cutting: runs counted per key, so the one with the most is
        // the one a fix has to change. `enumerateAttributes` above reports a new run when ANY value
        // differs, and a key set that looks identical can still be cut by one key's VALUE.
        var perKey: [String: Int] = [:]
        for key in [MDAttr.srcRange, MDAttr.blockId, NSAttributedString.Key.font,
                    NSAttributedString.Key.foregroundColor, NSAttributedString.Key.paragraphStyle,
                    MDAttr.codeBlock, MDAttr.officeGraphic] {
            var n = 0
            storage.enumerateAttribute(key, in: whole, options: []) { _, _, _ in n += 1 }
            perKey[key.rawValue] = n
        }
        for (k, v) in perKey.sorted(by: { $0.value > $1.value }) { print("KEYRUNS \(k) = \(v)") }

        let cells = Double(blockIdentities.count)
        let per: (Int) -> String = { n in cells > 0 ? self.f(Double(n) / cells) : "n/a" }
        print("""
        TABLECOST file=\(url.lastPathComponent) chars=\(storage.length) charsInTables=\(charsInTables)
        TABLECOST tables=\(tableIdentities.count) cells=\(blockIdentities.count)
        TABLECOST runs=\(runs) runsInTables=\(runsInTables) runsPerCell=\(per(runsInTables))
        TABLECOST paragraphStyleObjects=\(styleIdentities.count) stylesPerCell=\(per(styleIdentities.count))
        TABLECOST tableBlockObjects=\(blockIdentities.count) blocksPerCell=\(per(blockIdentities.count))
        TABLECOST distinctStyleValuesIgnoringBlocks=\(blocklessRepresentatives.count) \
        of \(blocklessInTables) in-table runs
        """)

        // The one thing that is wrong at any magnitude. Everything else above is a judgement the
        // reader makes with the numbers in hand, which is why this probe asserts nothing about them.
        XCTAssertLessThanOrEqual(blockIdentities.count, styleIdentities.count,
                                 "every cell's block must reach the text through at least one style")
    }
}
