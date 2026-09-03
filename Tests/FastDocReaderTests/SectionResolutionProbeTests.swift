import XCTest
import AppKit
@testable import FastDocReader

/// WHICH SECTION each page resolves to — the one answer that decides which 바탕쪽 template is
/// painted and which running header applies. A page that resolves to `nil` falls back to the FIRST
/// template in the document, which is how a cover's furniture ends up on a body page.
///
/// `FMD_SECTION_PROBE=<document>`
final class SectionResolutionProbeTests: XCTestCase {
    func testSectionResolution() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_SECTION_PROBE"] else {
            throw XCTSkip("set FMD_SECTION_PROBE=<document>")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)

        print("PROBE sectionStartBlocks from engine: \(doc.officeSectionStartBlocks)")
        print("PROBE headers=\(doc.officeHeaders.count) footers=\(doc.officeFooters.count) masterPages=\(doc.officeMasterPages.count)")
        for (i, h) in doc.officeHeaders.enumerated() {
            print("PROBE   header[\(i)] section=\(String(describing: h.section)) appliesTo=\(h.appliesTo)")
        }
        for (i, f) in doc.officeFooters.enumerated() {
            print("PROBE   footer[\(i)] section=\(String(describing: f.section)) appliesTo=\(f.appliesTo)")
        }
        for (i, m) in doc.officeMasterPages.enumerated() {
            print("PROBE   master[\(i)] section=\(m.section) appliesTo=\(m.appliesTo) objects=\(m.objects.count)")
        }
        var runs: [(Int, Int)] = []
        if let storage = wc.textView.textStorage {
            storage.enumerateAttribute(MDAttr.sectionIndex,
                                       in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if let s = v as? Int { runs.append((r.location, s)) }
            }
            print("PROBE storage length \(storage.length), sectionIndex runs: \(runs.count) -> \(runs.prefix(20))")
        }
        let d = wc.pageBandDelegate
        print("PROBE band active=\(d.isActive) pageContentHeight=\(d.pageContentHeight) band=\(d.band) leadingBand=\(d.leadingBand)")
        let resolved = (0..<24).map { wc.sectionOfPage($0).map(String.init) ?? "nil" }
        print("PROBE sectionOfPage(0..23) = \(resolved.joined(separator: ","))")
        // Does a running header/footer actually reach each page? This is the question the screen
        // answers by drawing : an entry whose section is unknown applies EVERYWHERE.
        let hdrs = doc.officeHeaders, ftrs = doc.officeFooters
        var applied: [String] = []
        for p in 0..<24 {
            let s = wc.sectionOfPage(p)
            let h = PageBandPainter.applicableEntry(hdrs, pageIndex: p, section: s,
                                                   hiddenSections: [])
            let f = PageBandPainter.applicableEntry(ftrs, pageIndex: p, section: s,
                                                   hiddenSections: [])
            applied.append("\(p):\(h == nil ? "-" : "H")\(f == nil ? "-" : "F")")
        }
        print("PROBE header/footer applied per page: \(applied.joined(separator: " "))")
        let tail = (505..<509).map { p -> String in
            let s = wc.sectionOfPage(p)
            let f = PageBandPainter.applicableEntry(ftrs, pageIndex: p, section: s,
                                                   hiddenSections: [])
            return "\(p):sec=\(s.map(String.init) ?? "nil"),\(f == nil ? "-" : "F")"
        }
        print("PROBE tail pages: \(tail.joined(separator: " "))")
    }
}
