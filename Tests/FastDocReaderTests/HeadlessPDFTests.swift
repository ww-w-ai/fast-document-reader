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

    // MARK: - The PDF is printed into our own temp dir and MOVED to the destination

    /// The sandbox defect in one assertion, in the one form an UNSANDBOXED suite can see it: a
    /// destination folder that cannot be written to must still produce a real PDF and fail only at
    /// the placing step. Printing straight to `jobSavingURL = destination` — which is what the
    /// shipped 1.2 build did — cannot reach `.couldNotPlace` at all, because the print subsystem
    /// fails first and the answer is `.printFailed`.
    ///
    /// It does NOT prove the sandbox property itself (the suite runs unsandboxed, so
    /// `FolderAccess.isNeeded` is false); that one is verified against a signed App Store build.
    ///
    /// **Mutation-checked, and the failure is a HANG, not a red X** — putting `destination` back in
    /// `jobSavingURL` makes this test never return, because the failed print raises AppKit's own
    /// modal error alert and an `xctest` process has no one to dismiss it. That is the field
    /// symptom (`No NSAlertAction found for modalResponse: 0`, then nothing) reproduced without a
    /// sandbox, so a run of this test that sits forever means the staging step is gone, not that
    /// the machine is busy.
    func testAPDFIsStagedInTempAndOnlyTheMoveCanFailOnAnUnwritableDestination() throws {
        let input = try writeMarkdownFixture()
        let locked = temp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }

        let wc = try openHeadless(input)
        let before = try stagedPDFsInTemp()
        XCTAssertThrowsError(try HeadlessPDF.writePDF(from: wc, to: locked.appendingPathComponent("x.pdf"),
                                                      force: false)) { error in
            XCTAssertEqual(self.failureKind(error), "couldNotPlace",
                           "the PDF must have been produced — only putting it in place may fail")
        }
        XCTAssertEqual(try stagedPDFsInTemp(), before,
                       "the staging file must be removed whether the move succeeded or not")
    }

    /// The success half of the same contract: nothing is left behind in the temp directory.
    func testASuccessfulRunLeavesNoStagingFileBehind() throws {
        let input = try writeMarkdownFixture()
        let wc = try openHeadless(input)
        let before = try stagedPDFsInTemp()

        let data = try HeadlessPDF.writePDF(from: wc, to: temp.appendingPathComponent("out.pdf"),
                                            force: false)
        XCTAssertTrue(data.starts(with: Array("%PDF".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("out.pdf").path))
        XCTAssertEqual(try stagedPDFsInTemp(), before)
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

    /// The same three steps `HeadlessPDF.run` takes before it prints, so a test measures the state a
    /// real headless run is in rather than a hand-built one.
    private func openHeadless(_ url: URL) throws -> DocumentWindowController {
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.data")
        NSWindow.removeFrame(usingName: "FastMDReaderDoc")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 820, height: 640), display: false)
        HeadlessPDF.waitForRenderToSettle(doc: doc, wc: wc)
        if let tc = wc.textView.textContainer { wc.textView.layoutManager?.ensureLayout(for: tc) }
        wc.applyTrailingFooterBand()
        return wc
    }

    private func stagedPDFsInTemp() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("fastdoc-pdf-") }.count
    }

    private func failureKind(_ error: Error) -> String {
        switch error as? HeadlessPDF.PDFWriteFailure {
        case .stagingUnavailable: return "stagingUnavailable"
        case .printFailed: return "printFailed"
        case .notAPDF: return "notAPDF"
        case .couldNotPlace: return "couldNotPlace"
        case nil: return "other(\(error))"
        }
    }

    private func writeMarkdownFixture(_ name: String = "sample.md") throws -> URL {
        let url = temp.appendingPathComponent(name)
        let body = (1...80).map { "Paragraph number \($0) of the body text." }.joined(separator: "\n\n")
        try Data(body.utf8).write(to: url)
        return url
    }
}
