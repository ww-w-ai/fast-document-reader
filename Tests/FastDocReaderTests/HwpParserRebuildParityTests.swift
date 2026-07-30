import XCTest
import AppKit
@testable import FastDocReader

/// The instrument that makes a REBUILD of the vendored rhwp parser verifiable on its own.
///
/// Adding data to rhwp's JSON means replacing `Vendor/RhwpNative.xcframework` — a prebuilt binary this
/// repo cannot diff, cannot review, and (invariant 45) SwiftPM will happily NOT relink. So the first
/// step of the per-slot font work (`docs/per-script-font-design.md` §6) is deliberately additive:
/// the new fields appear, the existing `font` field and every run boundary stay exactly as they were,
/// and the rendered output must therefore be BIT-IDENTICAL afterwards. This test is what "bit-
/// identical" means in practice — it dumps every span of a real document, through the REAL
/// `HwpReader.read` path (FFI → JSON → `OfficeBlock` → `resolvingFontSubstitution`), in a stable
/// textual form that can be diffed across the two binaries.
///
/// It dumps the SPANS rather than the rendered `NSAttributedString` on purpose: the span vocabulary
/// is exactly the parser's output surface, so a difference here is attributable to the parser, while
/// a difference in an attributed string could equally be a theme or a builder change. Everything the
/// builder later reads off a span is included, including the substitute font resolved at read time —
/// which is the field a changed font NAME would move first.
final class HwpParserRebuildParityTests: XCTestCase {

    /// `FMD_HWP_SPAN_DUMP` = one or more document paths, colon-separated (a `.hwp` AND a `.hwpx`, so
    /// both of rhwp's front ends are proven — they converge on the same `CharShape.font_ids` table,
    /// but only running both shows it). `FMD_HWP_SPAN_DUMP_OUT` = a directory to write one dump file
    /// per document into; without it the dump is summarised but not kept, which is enough to spot a
    /// changed checksum and not enough to see WHAT changed.
    func testSpanDumpForRealDocuments() throws {
        guard let list = ProcessInfo.processInfo.environment["FMD_HWP_SPAN_DUMP"], !list.isEmpty else {
            throw XCTSkip("set FMD_HWP_SPAN_DUMP to colon-separated .hwp/.hwpx paths to run this")
        }
        let outDir = ProcessInfo.processInfo.environment["FMD_HWP_SPAN_DUMP_OUT"]
        for path in list.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let result = try HwpReader.read(data)
            let dump = Self.dump(result)
            if let outDir {
                let name = url.deletingPathExtension().lastPathComponent
                    + "." + url.pathExtension + ".spans.txt"
                try dump.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name),
                               atomically: true, encoding: .utf8)
            }
            let lines = dump.split(separator: "\n", omittingEmptySubsequences: false).count
            print("SPANDUMP \(url.lastPathComponent): \(lines) lines, \(dump.count) chars")
        }
    }

    /// How often a real HWP actually declares DIFFERENT families in its seven slots — the question
    /// step 2 of `docs/per-script-font-design.md` lives or dies on, asked of a corpus rather than
    /// assumed from the format's shape. `FMD_HWP_SLOT_SURVEY` = a colon-separated list of
    /// directories; every `.hwp`/`.hwpx` under them is parsed and its `charShapes` table summarised.
    ///
    /// It reports rather than asserts, on purpose. The design's own splitting rule breaks a run
    /// where the RESOLVED FAMILY changes, never where the slot index does, so a document whose seven
    /// slots all name one face produces exactly the spans it produces today — meaning the honest
    /// output of this probe is a proportion, not a pass/fail. A corpus with no per-slot variation at
    /// all would say the HWP half of the feature is a no-op on real files, which is worth knowing
    /// BEFORE building the classifier, not after.
    func testHowOftenAnHwpDeclaresDifferentFontsPerSlot() throws {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_HWP_SLOT_SURVEY"], !dirs.isEmpty else {
            throw XCTSkip("set FMD_HWP_SLOT_SURVEY to colon-separated directories of HWP files")
        }
        let fm = FileManager.default
        var files: [URL] = []
        var skipped = 0
        for dir in dirs.split(separator: ":").map(String.init) {
            // An explicit error handler, or the walk stops dead at the first unreadable directory
            // and under-reports its own input with no indication (invariant 35).
            let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles], errorHandler: { _, _ in skipped += 1; return true })
            while let u = e?.nextObject() as? URL {
                if ["hwp", "hwpx"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        var parsed = 0, unreadable = 0, withVariation = 0
        var variedRows = 0, totalRows = 0
        var examples: [String] = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { unreadable += 1; continue }
            parsed += 1
            totalRows += export.charShapes.count
            let varied = export.charShapes.filter { row in
                Set(row.filter { !$0.isEmpty }).count > 1
            }
            variedRows += varied.count
            if let first = varied.first {
                withVariation += 1
                if examples.count < 8 { examples.append("\(url.lastPathComponent): \(first)") }
            }
        }
        print("""
              SLOTSURVEY files=\(files.count) parsed=\(parsed) unreadable=\(unreadable) \
              dirsSkipped=\(skipped) documentsWithPerSlotVariation=\(withVariation) \
              charShapeRows=\(totalRows) rowsWithVariation=\(variedRows)
              """)
        for e in examples { print("  \(e)") }
    }

    // MARK: the dump itself

    /// One line per span, prefixed by the block path that reached it, plus the document-level fields
    /// the reader also consumes. Deliberately exhaustive over `Span`'s 20 stored properties: a dump
    /// that omitted a field would prove parity only for the fields it happened to include, which is
    /// the "a green assertion whose subject is unreachable proves nothing" failure of invariant 30.
    static func dump(_ result: OfficeReadResult) -> String {
        var out = ""
        out += "defaultBodyFontSize=\(fmt(result.defaultBodyFontSize))\n"
        out += "pageContentWidth=\(fmt(result.pageContentWidth))\n"
        out += "images=\(result.images.keys.sorted().map { "\($0):\(result.images[$0]!.count)" }.joined(separator: ","))\n"
        out += "comments=\(result.comments.count)\n"
        for (i, block) in result.blocks.enumerated() { walk(block, path: "\(i)", into: &out) }
        return out
    }

    private static func walk(_ block: OfficeBlock, path: String, into out: inout String) {
        switch block {
        case .paragraph(let spans, let rtl, let align, let tabs, let format):
            out += "\(path) para rtl=\(rtl) align=\(fmt(align)) tabs=\(tabs.count) fmt=\(fmt(format))\n"
            emit(spans, path: path, into: &out)
        case .heading(let level, let spans, let rtl, let align, let tabs, let format):
            out += "\(path) head level=\(level) rtl=\(rtl) align=\(fmt(align)) tabs=\(tabs.count) fmt=\(fmt(format))\n"
            emit(spans, path: path, into: &out)
        case .listItem(let level, let ordered, let spans, let marker, let rtl, let align, let tabs, let format):
            out += "\(path) list level=\(level) ordered=\(ordered) marker=\(marker ?? "-") rtl=\(rtl) align=\(fmt(align)) tabs=\(tabs.count) fmt=\(fmt(format))\n"
            emit(spans, path: path, into: &out)
        case .table(let rows, let headerRows, let columnWidths, let format):
            out += "\(path) table rows=\(rows.count) header=\(headerRows)"
            out += " cols=\(columnWidths.map { fmt($0) }.joined(separator: "|")) fmt=\(String(describing: format))\n"
            for (r, row) in rows.enumerated() {
                for (c, cell) in row.enumerated() {
                    out += "\(path).\(r).\(c) cell span=\(cell.rowSpan)x\(cell.colSpan) w=\(fmt(cell.width)) valign=\(String(describing: cell.verticalAlignment))\n"
                    for (b, inner) in cell.blocks.enumerated() {
                        walk(inner, path: "\(path).\(r).\(c).\(b)", into: &out)
                    }
                }
            }
        default:
            // Images, formulas, rules and unsupported graphics carry no spans; their identity is
            // still dumped so a changed id/size shows up as a diff line.
            out += "\(path) other \(String(describing: block))\n"
        }
    }

    private static func emit(_ spans: [Span], path: String, into out: inout String) {
        for (i, s) in spans.enumerated() {
            out += "\(path)#\(i)"
            out += " text=\(s.text.debugDescription)"
            out += " b=\(s.bold) i=\(s.italic) u=\(s.underline)/\(s.underlineStyle)"
            out += " code=\(s.code) caps=\(s.caps) small=\(s.smallCaps)"
            out += " strike=\(s.strikethrough) sup=\(s.superscript) sub=\(s.subscripted) rtl=\(s.rtl)"
            out += " link=\(s.link ?? "-")"
            out += " bm=\(s.bookmarks.joined(separator: "|"))"
            out += " cid=\(s.commentIds.joined(separator: "|"))"
            out += " color=\(fmt(s.textColor)) hl=\(fmt(s.highlightColor))"
            out += " size=\(fmt(s.fontSize)) font=\(s.fontName ?? "-")"
            out += " subst=\(fmt(s.resolvedFontDescriptor))"
            out += "\n"
        }
    }

    // MARK: stable formatting (no pointers, no locale, no hash order)

    private static func fmt(_ v: CGFloat?) -> String {
        guard let v else { return "-" }
        return String(format: "%.4f", Double(v))
    }

    private static func fmt(_ v: NSTextAlignment?) -> String {
        guard let v else { return "-" }
        return String(describing: v)
    }

    private static func fmt(_ c: NSColor?) -> String {
        guard let c, let s = c.usingColorSpace(.sRGB) else { return "-" }
        return String(format: "%.4f/%.4f/%.4f/%.4f",
                      s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }

    /// A descriptor's attributes are a dictionary, so they are SORTED before printing — an unsorted
    /// dump would diff against itself run to run, which is invariant 50's hash-order lesson in a
    /// smaller place.
    private static func fmt(_ d: NSFontDescriptor?) -> String {
        guard let d else { return "-" }
        return d.fontAttributes
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
    }

    private static func fmt(_ f: ParagraphFormat) -> String {
        String(describing: f)
    }
}
