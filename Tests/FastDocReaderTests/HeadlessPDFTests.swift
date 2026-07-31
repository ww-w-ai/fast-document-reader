import XCTest
import AppKit
@testable import FastDocReader

/// `FastDocReader --pdf <file>`: exercises the real CLI entry point (`HeadlessPDF.run`), not the
/// print mechanism in isolation — `PrintPaginationTests` already proves `makePrintOperation()`
/// itself; this proves the HEADLESS WRAPPER around it (invariant 29's lesson: a mechanism's own
/// unit tests don't prove a caller actually reaches it).
final class HeadlessPDFTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-headless-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Page count matches the reader's own pagination

    /// THE headline property: the PDF `--pdf` produces has exactly as many pages as the reader
    /// itself reports for the same file (`DocumentWindowController.printPageCount`, the same number
    /// `PrintPaginationTests` proves ⌘P prints) — opened as its own, separate reference window so
    /// this is a real cross-check, not the CLI comparing itself to its own work.
    func testPagedFixturePDFPageCountMatchesTheReadersOwnPagination() throws {
        let url = repoRoot().appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("docs/fixtures/office/bus-headings.docx is not in this checkout (docs/ is local-only)")
        }

        let refDoc = MarkdownDocument()
        refDoc.fileURL = url
        try refDoc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        refDoc.makeWindowControllers()
        let refWC = try XCTUnwrap(refDoc.windowControllers.first as? DocumentWindowController)
        refWC.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: refDoc, wc: refWC)
        if let tc = refWC.textView.textContainer { refWC.textView.layoutManager?.ensureLayout(for: tc) }
        refWC.applyTrailingFooterBand()
        XCTAssertTrue(refWC.isPaged, "precondition: the fixture must be a paged document")
        let expectedPages = refWC.printPageCount
        XCTAssertGreaterThan(expectedPages, 1, "precondition: the fixture must actually paginate")

        let outURL = temp.appendingPathComponent("bus-headings.pdf")
        let exitCode = HeadlessPDF.run([url.path, "-o", outURL.path])
        XCTAssertEqual(exitCode, 0, "the CLI must succeed on a real fixture")

        let data = try Data(contentsOf: outURL)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(pdf.numberOfPages, expectedPages,
                       "the exported PDF must have exactly as many pages as the reader itself reports")
    }

    // MARK: - Refuse to overwrite

    func testRefusesToOverwriteAnExistingOutputFileWithoutForce() throws {
        let input = try writeMarkdownFixture()
        let outURL = temp.appendingPathComponent("sample.pdf")
        try Data("not a pdf".utf8).write(to: outURL)

        let exitCode = HeadlessPDF.run([input.path, "-o", outURL.path])
        XCTAssertNotEqual(exitCode, 0, "must refuse to clobber an existing file without -f")
        let untouched = try Data(contentsOf: outURL)
        XCTAssertEqual(String(decoding: untouched, as: UTF8.self), "not a pdf",
                       "the existing file must be left exactly as it was")

        let forced = HeadlessPDF.run([input.path, "-o", outURL.path, "-f"])
        XCTAssertEqual(forced, 0, "-f/--force must allow the overwrite")
        let overwritten = try Data(contentsOf: outURL)
        XCTAssertTrue(overwritten.starts(with: Array("%PDF".utf8)),
                     "the file must now be a real PDF")
    }

    // MARK: - Default output path

    /// No `-o`: the output lands beside the input, same basename, `.pdf` in place of the original
    /// extension.
    func testDefaultOutputPathIsTheInputBasenameWithPdfExtensionNextToIt() throws {
        let input = try writeMarkdownFixture("report.md")
        let expectedOut = temp.appendingPathComponent("report.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOut.path))

        let exitCode = HeadlessPDF.run([input.path])
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedOut.path),
                     "with no -o, the PDF must be written next to the input with a .pdf extension")
    }

    // MARK: - Fixtures

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func writeMarkdownFixture(_ name: String = "sample.md") throws -> URL {
        let url = temp.appendingPathComponent(name)
        let body = (1...80).map { "Paragraph number \($0) of the body text." }.joined(separator: "\n\n")
        try Data(body.utf8).write(to: url)
        return url
    }
}
