import XCTest
import AppKit
@testable import FastDocReader

/// Whether a 바탕쪽 text object's words actually FIT the box the document gave it.
///
/// `MasterPagePainter.draw` builds a master text object through `OfficeTextBuilder` and then draws
/// it with `NSAttributedString.draw(in:)`, which CLIPS. So a box whose text is laid out taller than
/// the document intended loses its last line silently — no warning, no ellipsis, just a word that
/// is not there. Measured on the 2025 행정업무운영편람's section tab: the document stacks 공/문/서
/// down a 23.7×87.7pt strip and the reference renderer fits all three at a 36pt pitch, while this
/// reader fits two.
///
/// `FMD_MASTER_FIT_PROBE=<file>` — a real office file with a master page. Skipped by default.
final class MasterTextFitProbeTests: XCTestCase {
    func testEveryMasterTextObjectFitsItsOwnBox() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_MASTER_FIT_PROBE"] else {
            throw XCTSkip("set FMD_MASTER_FIT_PROBE=<office file with a master page> to run this")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let parsed: OfficeReadResult = DocumentTypes.isHwp(url.pathExtension)
            ? try HwpReader.read(data)
            : try DocumentTypes.readOffice(try ZipArchive(data: data), extension: url.pathExtension)
        let theme = RenderTheme(baseFontSize: 13)
        var overflowing = 0, total = 0
        for (p, page) in parsed.masterPages.enumerated() {
            for (j, object) in page.objects.enumerated() {
                guard case .text(let blocks) = object.content else { continue }
                let built = OfficeTextBuilder.build(blocks, theme: theme,
                                                    columnWidth: object.frame.width,
                                                    documentDefaultFontSize: parsed.defaultBodyFontSize,
                                                    pageContentWidth: parsed.pageContentWidth)
                guard built.length > 0 else { continue }
                total += 1
                let measured = built.boundingRect(
                    with: NSSize(width: object.frame.width, height: .greatestFiniteMagnitude),
                    options: NSString.DrawingOptions([.usesLineFragmentOrigin, .usesFontLeading])).height
                let text = built.string.replacingOccurrences(of: "\n", with: "/")
                if measured > object.frame.height + 0.5 {
                    overflowing += 1
                    print(String(format: "PROBE OVERFLOW page %d obj %d box %.1fx%.1f needs %.1f  %@",
                                 p, j, object.frame.width, object.frame.height, measured,
                                 text as NSString))
                }
            }
        }
        print("PROBE master text objects: \(total), overflowing their box: \(overflowing)")
    }
}
