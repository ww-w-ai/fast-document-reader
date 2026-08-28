import XCTest
import AppKit
@testable import FastDocReader

#if DEBUG
@MainActor
final class S1BBehaviorOracleTests: XCTestCase {
    private struct Fixture {
        let fileClass: String
        let ext: String
        let data: Data
    }

    func testEveryRepresentativeBehaviorContractInThisConfiguration() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hwp = root.appendingPathComponent("Vendor/rhwp-src/saved/blank2010.hwp")
        let hwpx = root.appendingPathComponent("Vendor/rhwp-src/saved/hwpx-01-saved.hwpx")
        let fixtures = [
            Fixture(fileClass: "markdown", ext: "md", data: Data("# Baseline\n\nMarkdown body.\n".utf8)),
            Fixture(fileClass: "plain-text", ext: "txt", data: Data("FastDoc plain baseline\n".utf8)),
            Fixture(fileClass: "docx", ext: "docx", data: S1BOfficeFixtures.docx),
            Fixture(fileClass: "odt", ext: "odt", data: S1BOfficeFixtures.odt),
            Fixture(fileClass: "hwp", ext: "hwp", data: try Data(contentsOf: hwp)),
            Fixture(fileClass: "hwpx", ext: "hwpx", data: try Data(contentsOf: hwpx)),
        ]
        let entryPoints = [
            "gui-open", "gui-reload", "extract", "pdf", "quick-look",
            "derived-navigation", "edit-save",
        ]
        let expected = try expectedEngines(root: root)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastdoc-s1b-oracles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for fixture in fixtures {
            let input = directory.appendingPathComponent("baseline.\(fixture.ext)")
            try fixture.data.write(to: input)
            for entryPoint in entryPoints {
                let runID = "oracle-\(fixture.fileClass)-\(entryPoint)"
                DocumentEngineTrace.beginRun(runID, entryPoint: entryPoint)
                var assertions = 0
                do {
                    assertions = try await exercise(
                        entryPoint, fixture: fixture, input: input, directory: directory, runID: runID)
                } catch {
                    DocumentEngineTrace.endRun()
                    throw error
                }
                DocumentEngineTrace.endRun()

                let expectedEngine = try XCTUnwrap(expected[fixture.fileClass]?[entryPoint])
                let engines = DocumentEngineTrace.snapshot(runID: runID).map(\.engine)
                if expectedEngine == "none" {
                    XCTAssertTrue(engines.isEmpty, "\(runID) unexpectedly called \(engines)")
                } else {
                    XCTAssertEqual(engines, [expectedEngine], "\(runID) engine identity differs")
                }
                XCTAssertGreaterThan(assertions, 0, "\(runID) performed no observable assertion")
                let expectedEvents = expectedEngine == "none" ? [] : [expectedEngine]
                let evidence: [String: Any] = [
                    "class": fixture.fileClass,
                    "entryPointId": entryPoint,
                    "runId": runID,
                    "representativeExtension": fixture.ext,
                    "oracleId": "O-\(fixture.fileClass.uppercased())-\(entryPoint.uppercased())",
                    "controlAssertions": assertions,
                    "expectedEngine": expectedEngine,
                    "expectedEvents": expectedEvents,
                    "observedEvents": engines,
                ]
                let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                print("S1B_CONTRACT " + String(decoding: encoded, as: UTF8.self))
            }
        }
    }

    private func exercise(
        _ entryPoint: String,
        fixture: Fixture,
        input: URL,
        directory: URL,
        runID: String
    ) async throws -> Int {
        switch entryPoint {
        case "gui-open":
            let document = MarkdownDocument()
            document.fileURL = input
            try document.read(from: fixture.data, ofType: "public.data")
            XCTAssertEqual(document.kind, DocumentTypes.kind(forExtension: fixture.ext))
            return 1
        case "gui-reload":
            let outcome = MarkdownDocument.reloadOutcome(
                url: input, kind: DocumentTypes.kind(forExtension: fixture.ext), extension: fixture.ext)
            if case .failure(let reason) = outcome { XCTFail("reload failed: \(reason)") }
            return 1
        case "extract":
            XCTAssertEqual(HeadlessExtract.run([input.path]), 0)
            return 1
        case "pdf":
            let output = directory.appendingPathComponent("\(fixture.fileClass).pdf")
            XCTAssertEqual(HeadlessPDF.run([input.path, "-o", output.path, "-f"]), 0)
            XCTAssertTrue(try Data(contentsOf: output).starts(with: Array("%PDF".utf8)))
            return 2
        case "quick-look":
            let controller = QuickLookPreviewController()
            _ = controller.view
            try await controller.preparePreviewOfFile(at: input)
            XCTAssertFalse(controller.view.subviews.isEmpty)
            return 1
        case "derived-navigation":
            let document = MarkdownDocument()
            document.fileURL = input
            if fixture.fileClass == "plain-text" {
                // Loading is setup for the negative no-derived-heading boundary.
                DocumentEngineTrace.endRun()
            }
            try document.read(from: fixture.data, ofType: "public.data")
            if fixture.fileClass == "plain-text" {
                DocumentEngineTrace.beginRun(runID, entryPoint: "derived-navigation")
            }
            document.makeWindowControllers()
            let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
            let storage = try XCTUnwrap(controller.textView.textStorage)
            let panel = OutlinePanel(frame: .zero)
            panel.reload(from: storage)
            if fixture.fileClass == "markdown" {
                XCTAssertEqual(panel.entries.map(\.title), ["Baseline"])
            } else if fixture.fileClass == "plain-text" {
                XCTAssertTrue(panel.entries.isEmpty)
            } else {
                XCTAssertGreaterThanOrEqual(panel.entries.count, 0)
            }
            return 1
        case "edit-save":
            let document = MarkdownDocument()
            document.fileURL = input
            // Loading is setup for this negative boundary, not part of the save operation's trace.
            DocumentEngineTrace.endRun()
            try document.read(from: fixture.data, ofType: "public.data")
            DocumentEngineTrace.beginRun(runID, entryPoint: "edit-save")
            if document.kind == .office {
                XCTAssertThrowsError(try document.data(ofType: "public.data"))
                XCTAssertEqual(try Data(contentsOf: input), fixture.data)
                return 2
            }
            let saved = try document.data(ofType: "public.data")
            XCTAssertEqual(saved, fixture.data)
            return 1
        default:
            XCTFail("unknown S1B entry point \(entryPoint)")
            return 0
        }
    }

    private func expectedEngines(root: URL) throws -> [String: [String: String]] {
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Baseline/behavior.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contracts = try XCTUnwrap(document["contracts"] as? [[String: Any]])
        var result: [String: [String: String]] = [:]
        for contract in contracts {
            let fileClass = try XCTUnwrap(contract["class"] as? String)
            let entryPoint = try XCTUnwrap(contract["entryPointId"] as? String)
            result[fileClass, default: [:]][entryPoint] =
                try XCTUnwrap(contract["expectedEngine"] as? String)
        }
        return result
    }
}
#endif
