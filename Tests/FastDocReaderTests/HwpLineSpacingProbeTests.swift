import XCTest
@testable import FastDocReader

/// What a real HWP corpus actually declares for line spacing, default body size and page width —
/// the measurements the paged model's line-rule decision rests on, asked of documents rather than
/// argued from the format's shape.
///
///     FMD_HWP_LINESPACING_SURVEY="/path/to/hwp/files" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter HwpLineSpacingProbeTests
///
/// Skipped by default: it needs documents this repo does not ship. It REPORTS; the judgement of
/// what to do with the numbers is made with them in hand, not baked in as a threshold here.
final class HwpLineSpacingProbeTests: XCTestCase {

    private func corpusFiles() throws -> [URL] {
        guard let dirs = ProcessInfo.processInfo.environment["FMD_HWP_LINESPACING_SURVEY"],
              !dirs.isEmpty else {
            throw XCTSkip("set FMD_HWP_LINESPACING_SURVEY to colon-separated directories of HWP files")
        }
        let fm = FileManager.default
        var files: [URL] = []
        var skipped = 0
        for dir in dirs.split(separator: ":").map(String.init) {
            // Invariant 35: no error handler → the walk stops dead at the first unreadable
            // subdirectory and under-reports its own input silently.
            let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles],
                                  errorHandler: { _, _ in skipped += 1; return true })
            while let u = e?.nextObject() as? URL {
                if ["hwp", "hwpx"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        if skipped > 0 { print("LSPROBE dirsSkipped=\(skipped)") }
        var seen = Set<String>()
        return files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    /// Walks the raw rhwp JSON (paragraphs, table cells included) counting what each paragraph
    /// declares for line spacing, and how its own runs' sizes relate to the document default.
    func testSurveyLineSpacingAcrossCorpus() throws {
        let files = try corpusFiles()
        print("LSPROBE files=\(files.count)")

        var docs = 0, parseFailed = 0
        var docsWithPageWidth = 0, docsNullDefaultSize = 0
        var defaultSizeHistogram: [String: Int] = [:]
        var typeCounts: [String: Int] = [:]
        var percentHistogram: [Int: Int] = [:]
        var paras = 0
        // How far a paragraph's OWN largest run size sits from the document default — the
        // difference between rhwp's `max_fs` basis and this reader's `defaultBodySize` basis.
        var percentParasWithRunSize = 0, percentParasRunSizeDiffers = 0
        var docsAnyPercentNon160 = 0, docsAllPercent160 = 0

        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let json = HwpReader.exportDocumentJSON(data),
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let blocks = obj["blocks"] as? [[String: Any]] else { parseFailed += 1; continue }
            docs += 1

            let defaultPt = (obj["defaultFontSizePt"] as? Double).flatMap { $0 > 0 ? $0 : nil }
            if defaultPt == nil { docsNullDefaultSize += 1 }
            defaultSizeHistogram[defaultPt.map { String(format: "%.1f", $0) } ?? "null", default: 0] += 1
            if let w = obj["pageContentWidth"] as? Double, w > 0 { docsWithPageWidth += 1 }
            let basis = defaultPt ?? 11

            var docHas160 = false, docHasOtherPercent = false

            func walk(_ b: [String: Any]) {
                switch b["t"] as? String {
                case "para":
                    paras += 1
                    guard let lh = b["lineHeight"] as? [String: Any],
                          let type = lh["type"] as? String,
                          let raw = lh["value"] as? Int, raw > 0 else {
                        typeCounts["<none>", default: 0] += 1
                        return
                    }
                    typeCounts[type, default: 0] += 1
                    guard type == "percent", let pct = HwpReader.percentLineHeight(raw) else { return }
                    percentHistogram[Int(pct.rounded()), default: 0] += 1
                    if abs(pct - 160) <= 0.5 { docHas160 = true } else { docHasOtherPercent = true }
                    // The paragraph's own largest declared run size, in points.
                    let sizes = (b["spans"] as? [[String: Any]] ?? [])
                        .compactMap { ($0["size"] as? Int).flatMap { $0 > 0 ? Double($0) / 100 : nil } }
                    if let maxRun = sizes.max() {
                        percentParasWithRunSize += 1
                        if abs(maxRun - basis) > 0.05 { percentParasRunSizeDiffers += 1 }
                    }
                case "table":
                    for row in b["rows"] as? [[[String: Any]]] ?? [] {
                        for cell in row { for inner in cell["blocks"] as? [[String: Any]] ?? [] { walk(inner) } }
                    }
                default: break
                }
            }
            blocks.forEach(walk)
            if docHasOtherPercent { docsAnyPercentNon160 += 1 }
            else if docHas160 { docsAllPercent160 += 1 }
        }

        print("LSPROBE docs=\(docs) parseFailed=\(parseFailed) paras=\(paras)")
        print("LSPROBE docsWithPageWidth=\(docsWithPageWidth) docsNullDefaultSize=\(docsNullDefaultSize)")
        print("LSPROBE defaultSizeHistogram=\(defaultSizeHistogram.sorted { $0.value > $1.value }.prefix(12))")
        print("LSPROBE lineHeightTypes=\(typeCounts.sorted { $0.value > $1.value })")
        print("LSPROBE percentHistogram=\(percentHistogram.sorted { $0.value > $1.value }.prefix(20))")
        print("LSPROBE percentParasWithRunSize=\(percentParasWithRunSize) differsFromDocDefault=\(percentParasRunSizeDiffers)")
        print("LSPROBE docsWithNon160Percent=\(docsAnyPercentNon160) docsOnly160=\(docsAllPercent160)")
    }

    /// How far the paragraph's OWN largest run sits from the document default — the difference
    /// between rhwp's `max_fs` basis and this reader's `defaultBodySize` basis, as a RATIO, plus the
    /// documents whose reported default is implausible as a body size.
    func testSurveyPercentBasisDivergence() throws {
        let files = try corpusFiles()
        var ratioBuckets: [String: Int] = [:]
        var implausibleDefaults: [(String, Double)] = []
        var docs = 0

        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let json = HwpReader.exportDocumentJSON(data),
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let blocks = obj["blocks"] as? [[String: Any]] else { continue }
            docs += 1
            let defaultPt = (obj["defaultFontSizePt"] as? Double).flatMap { $0 > 0 ? $0 : nil }
            let basis = defaultPt ?? 11
            if basis < 5 || basis > 20 { implausibleDefaults.append((url.lastPathComponent, basis)) }

            func walk(_ b: [String: Any]) {
                switch b["t"] as? String {
                case "para":
                    guard let lh = b["lineHeight"] as? [String: Any],
                          lh["type"] as? String == "percent",
                          let raw = lh["value"] as? Int, raw > 0,
                          HwpReader.percentLineHeight(raw) != nil else { return }
                    let sizes = (b["spans"] as? [[String: Any]] ?? [])
                        .compactMap { ($0["size"] as? Int).flatMap { $0 > 0 ? Double($0) / 100 : nil } }
                    guard let maxRun = sizes.max() else { return }
                    let r = maxRun / basis
                    let bucket: String
                    switch r {
                    case ..<0.75: bucket = "<0.75"
                    case ..<0.95: bucket = "0.75-0.95"
                    case ..<1.05: bucket = "~1.0"
                    case ..<1.5: bucket = "1.05-1.5"
                    case ..<3: bucket = "1.5-3"
                    default: bucket = ">=3"
                    }
                    ratioBuckets[bucket, default: 0] += 1
                case "table":
                    for row in b["rows"] as? [[[String: Any]]] ?? [] {
                        for cell in row { for inner in cell["blocks"] as? [[String: Any]] ?? [] { walk(inner) } }
                    }
                default: break
                }
            }
            blocks.forEach(walk)
        }
        print("LSPROBE2 docs=\(docs)")
        print("LSPROBE2 maxRun/docDefault buckets=\(ratioBuckets.sorted { $0.value > $1.value })")
        print("LSPROBE2 implausibleDefaults n=\(implausibleDefaults.count) sample=\(implausibleDefaults.prefix(8))")
    }

    /// How often each paragraph SIZE property is present-and-zero versus absent — the invariant-47
    /// three-state question asked of HWP's spacing/indent fields, which `nonZeroPoints` currently
    /// collapses into one `nil`.
    func testSurveyZeroVersusAbsentParagraphMetrics() throws {
        let files = try corpusFiles()
        var present: [String: Int] = [:], zero: [String: Int] = [:], absent: [String: Int] = [:]
        var paras = 0
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = HwpReader.exportDocumentJSON(data),
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let blocks = obj["blocks"] as? [[String: Any]] else { continue }
            func walk(_ b: [String: Any]) {
                switch b["t"] as? String {
                case "para":
                    paras += 1
                    for key in ["spaceBefore", "spaceAfter", "indentStart", "indentEnd", "indentFirst"] {
                        if let v = b[key] as? Int {
                            present[key, default: 0] += 1
                            if v == 0 { zero[key, default: 0] += 1 }
                        } else { absent[key, default: 0] += 1 }
                    }
                case "table":
                    for row in b["rows"] as? [[[String: Any]]] ?? [] {
                        for cell in row { for inner in cell["blocks"] as? [[String: Any]] ?? [] { walk(inner) } }
                    }
                default: break
                }
            }
            blocks.forEach(walk)
        }
        print("LSPROBE3 paras=\(paras)")
        for key in ["spaceBefore", "spaceAfter", "indentStart", "indentEnd", "indentFirst"] {
            print("LSPROBE3 \(key): present=\(present[key] ?? 0) ofWhichZero=\(zero[key] ?? 0) absent=\(absent[key] ?? 0)")
        }
    }

    /// The LAID-OUT result on real documents, through the real reader and the real builder at the
    /// real paged geometry — the only measurement that can settle whether honouring the percent
    /// changes the page, and by how much. Reports total height and the resolved line-height
    /// distribution so a before/after can be compared by re-running it across the change.
    func testMeasureLaidOutHeightOfRealDocuments() throws {
        let files = try corpusFiles().prefix(24)
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let result = try? HwpReader.read(data) else { continue }
            let base = result.defaultBodyFontSize
            // The paged theme: built at the DOCUMENT's own default body size, so fontSizeScale == 1.
            let theme = RenderTheme(baseFontSize: base)
            guard let page = result.pageContentWidth else { continue }
            let text = OfficeTextBuilder.build(result.blocks, theme: theme, columnWidth: page,
                                               documentDefaultFontSize: base,
                                               pageContentWidth: page, tableWidth: page)
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: page, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let h = layout.usedRect(for: container).height

            var minLineHeights: [String: Int] = [:]
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                guard let p = v as? NSParagraphStyle else { return }
                minLineHeights[String(format: "%.1f", p.minimumLineHeight), default: 0] += 1
            }
            let top = minLineHeights.sorted { $0.value > $1.value }.prefix(4)
            print("LSHEIGHT \(url.lastPathComponent) base=\(base) chars=\(storage.length) height=\(String(format: "%.1f", h)) minLH=\(top)")
        }
    }
}
