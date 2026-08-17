import XCTest
import AppKit
@testable import FastDocReader

/// Which of a char shape's sixteen decorations real Korean documents actually use — the measurement
/// that decides which of them are worth rendering and which are format capacity nobody exercises.
///
///     FMD_HWP_CHAR_DECOR="/path/to/hwp/files:/another/dir" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter HwpCharDecorProbeTests
///
/// Skipped by default: it needs documents this repo does not ship. Counted per CHAR SHAPE rather
/// than per span, because that is the unit the document declares and the unit the table carries;
/// a document-level count is reported beside it, since one shape used by one word and one used by
/// every paragraph look identical from the table alone.
final class HwpCharDecorProbeTests: XCTestCase {

    private func corpusFiles() throws -> [URL] {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_HWP_CHAR_DECOR"], !dirs.isEmpty else {
            throw XCTSkip("set FMD_HWP_CHAR_DECOR to colon-separated directories of HWP files")
        }
        let fm = FileManager.default
        var files: [URL] = []
        var skipped = 0
        for dir in dirs.split(separator: ":").map(String.init) {
            let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles],
                                  errorHandler: { _, _ in skipped += 1; return true })
            while let u = e?.nextObject() as? URL {
                if ["hwp", "hwpx"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        if skipped > 0 { print("DECORPROBE dirsSkipped=\(skipped)") }
        var seen = Set<String>()
        return files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    func testWhichDecorationsRealDocumentsUse() throws {
        let files = try corpusFiles()
        var parsed = 0, unreadable = 0, shapes = 0, docsWithTable = 0
        var shapeCount: [String: Int] = [:]
        var docCount: [String: Int] = [:]
        // A per-script array can differ BETWEEN scripts, and a reader that carries one value per
        // span can only honour it when it does not. How often that is true decides whether the
        // simple shape is honest or a quiet lie.
        var present: [String: Int] = [:], uniform: [String: Int] = [:]
        func countUniformity(_ name: String, _ v: [Int]?) {
            guard let v, !v.isEmpty else { return }
            present[name, default: 0] += 1
            if v.allSatisfy({ $0 == v[0] }) { uniform[name, default: 0] += 1 }
        }

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let export = try? HwpReader.fontSlotExport(json) else { unreadable += 1; continue }
            parsed += 1
            if !export.charShapeDecor.isEmpty { docsWithTable += 1 }
            var here = Set<String>()
            for d in export.charShapeDecor {
                shapes += 1
                func hit(_ name: String, _ on: Bool) {
                    guard on else { return }
                    shapeCount[name, default: 0] += 1
                    here.insert(name)
                }
                hit("underlineShape", (d.underlineShape ?? 0) != 0)
                hit("underlineColor", d.underlineColor != nil)
                hit("strikeShape", (d.strikeShape ?? 0) != 0)
                hit("strikeColor", d.strikeColor != nil)
                hit("shadeColor", d.shadeColor != nil)
                hit("outline", (d.outlineType ?? 0) != 0)
                hit("shadow", (d.shadowType ?? 0) != 0)
                hit("emboss", d.emboss == true)
                hit("engrave", d.engrave == true)
                hit("emphasisDot", (d.emphasisDot ?? 0) != 0)
                hit("kerning", d.kerning == true)
                hit("ratios(장평)", d.ratios != nil)
                hit("spacings(자간)", d.spacings != nil)
                hit("relativeSizes", d.relativeSizes != nil)
                hit("charOffsets", d.charOffsets != nil)
                countUniformity("spacings", d.spacings)
                countUniformity("ratios", d.ratios)
                countUniformity("relativeSizes", d.relativeSizes)
                countUniformity("charOffsets", d.charOffsets)
            }
            for n in here { docCount[n, default: 0] += 1 }
        }

        print("DECORPROBE files=\(files.count) parsed=\(parsed) unreadable=\(unreadable) charShapes=\(shapes) docsWithTable=\(docsWithTable)")
        print("""
        DECORPROBE uniform spacings=\(uniform["spacings"] ?? 0)/\(present["spacings"] ?? 0) \
        ratios=\(uniform["ratios"] ?? 0)/\(present["ratios"] ?? 0) \
        relativeSizes=\(uniform["relativeSizes"] ?? 0)/\(present["relativeSizes"] ?? 0) \
        charOffsets=\(uniform["charOffsets"] ?? 0)/\(present["charOffsets"] ?? 0)
        """)
        for (name, n) in shapeCount.sorted(by: { $0.value > $1.value }) {
            let pct = shapes > 0 ? Double(n) / Double(shapes) * 100 : 0
            print(String(format: "DECORPROBE %@ shapes=%d (%.2f%%) docs=%d", name, n, pct, docCount[name] ?? 0))
        }

        XCTAssertGreaterThan(parsed, 0, "no document could be read — the probe measured nothing")
        // The decode itself: a renamed key leaves every row all-nil and every count above a
        // confident zero.
        XCTAssertGreaterThan(docsWithTable, 0, "no document carried a decoration table — the export broke")
    }
}
