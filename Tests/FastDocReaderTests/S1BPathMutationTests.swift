import XCTest
@testable import FastDocReader

#if DEBUG
/// S1B path evidence. Every mutation test runs a real control first, then injects one exact fault at
/// the dispatch seam and requires that fault to be observed. These tests are intentionally serial:
/// scoped run IDs provide attribution, while serial execution keeps AppKit document construction
/// deterministic.
final class S1BPathMutationTests: XCTestCase {
    private var configuration: String {
        #if FMD_RUST_ENGINE
        return "rust-enabled"
        #else
        return "default"
        #endif
    }
    override func setUp() {
        super.setUp()
        DocumentEngineTrace.reset()
    }

    /// The seam a HWP GUI open/reload actually runs through in THIS configuration. Naming the
    /// swift seam unconditionally made these tests assert the state S7 exists to end — the GUI read
    /// HWP with `HwpReader` while `--extract` read the same bytes with the engine. Deriving it from
    /// `configuration` keeps the test measuring "the dispatch seam fires and a fault at it is fatal"
    /// rather than pinning which reader wins, which is the behaviour contract's job
    /// (`Tests/Baseline/behavior.json`), not this file's.
    private var hwpOpenSeam: String {
        configuration == "rust-enabled" ? "M-HWP-RUST-OPEN" : "M-HWP-SWIFT-OPEN"
    }
    private var hwpReloadSeam: String {
        configuration == "rust-enabled" ? "M-HWP-RUST-RELOAD" : "M-HWP-SWIFT-RELOAD"
    }
    private var hwpEngine: String { configuration == "rust-enabled" ? "rust" : "swift" }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/rhwp-src/saved/\(name)")
    }

    private func assertFault(_ runID: String, _ seam: String) {
        XCTAssertEqual(DocumentEngineTrace.faults(runID: runID), ["F-\(seam)"])
        XCTAssertEqual(DocumentEngineTrace.snapshot(runID: runID).map(\.seam), [seam])
        let defaultKillers: Set<String> = [
            "M-HWP-SWIFT-OPEN", "M-HWP-SWIFT-RELOAD", "M-HWP-SWIFT-EXTRACT",
            "M-PLAIN-NAV-REJECTION", "M-OFFICE-SAVE-REJECTION",
        ]
        let rustKillers: Set<String> = [
            "M-HWP-RUST-EXTRACT", "M-HWP-RUST-OPEN", "M-HWP-RUST-RELOAD",
            "M-PLAIN-NAV-REJECTION", "M-OFFICE-SAVE-REJECTION",
        ]
        let designated = configuration == "default" && defaultKillers.contains(seam)
            || configuration == "rust-enabled" && rustKillers.contains(seam)
        let role = designated && !runID.contains("hwpx") ? "killer" : "corroboration"
        let killerTests = [
            "M-HWP-SWIFT-OPEN": "S1BPathMutationTests/testHwpSwiftOpenControlThenMutation",
            "M-HWP-SWIFT-RELOAD": "S1BPathMutationTests/testHwpSwiftReloadControlThenMutation",
            "M-HWP-RUST-OPEN": "S1BPathMutationTests/testHwpSwiftOpenControlThenMutation",
            "M-HWP-RUST-RELOAD": "S1BPathMutationTests/testHwpSwiftReloadControlThenMutation",
            "M-HWP-SWIFT-EXTRACT": "S1BPathMutationTests/testHwpExtractControlThenConfigurationMutation",
            "M-HWP-RUST-EXTRACT": "S1BPathMutationTests/testHwpExtractControlThenConfigurationMutation",
            "M-PLAIN-NAV-REJECTION": "S1BPathMutationTests/testPlainTextNavigationRejectionControlThenMutation",
            "M-OFFICE-SAVE-REJECTION": "S1BPathMutationTests/testOfficeSaveRejectionControlThenMutationLeavesSourceUntouched",
        ]
        let killerTest = killerTests[seam] ?? "missing"
        print("S1B_MUTATION {\"id\":\"\(seam)\",\"faultId\":\"F-\(seam)\","
              + "\"configuration\":\"\(configuration)\",\"role\":\"\(role)\","
              + "\"controlPassed\":true,\"mutatedFailed\":true,"
              + "\"killerTest\":\"\(killerTest)\"}")
    }

    func testHwpSwiftOpenControlThenMutation() throws {
        for name in ["blank2010.hwp", "hwpx-01-saved.hwpx"] {
            let url = fixture(name)
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension
            let control = "open-control-\(ext)"
            let document = MarkdownDocument()
            document.fileURL = url
            try DocumentEngineTrace.withRun(control, entryPoint: "gui-open") {
                try document.read(from: data, ofType: "public.data")
            }
            XCTAssertEqual(DocumentEngineTrace.snapshot(runID: control).map(\.engine), [hwpEngine])

            let mutated = "open-mutated-\(ext)"
            let killed = MarkdownDocument()
            killed.fileURL = url
            XCTAssertThrowsError(try DocumentEngineTrace.withRun(
                mutated, entryPoint: "gui-open", faults: [hwpOpenSeam]
            ) {
                try killed.read(from: data, ofType: "public.data")
            })
            assertFault(mutated, hwpOpenSeam)
        }
    }

    func testHwpSwiftReloadControlThenMutation() throws {
        for name in ["blank2010.hwp", "hwpx-01-saved.hwpx"] {
            let url = fixture(name)
            let ext = url.pathExtension
            let control = "reload-control-\(ext)"
            _ = DocumentEngineTrace.withRun(control, entryPoint: "gui-reload") {
                MarkdownDocument.reloadOutcome(url: url, kind: .office, extension: ext)
            }
            XCTAssertEqual(DocumentEngineTrace.snapshot(runID: control).map(\.engine), [hwpEngine])

            let mutated = "reload-mutated-\(ext)"
            let outcome = DocumentEngineTrace.withRun(
                mutated, entryPoint: "gui-reload", faults: [hwpReloadSeam]
            ) {
                MarkdownDocument.reloadOutcome(url: url, kind: .office, extension: ext)
            }
            guard case .failure = outcome else { return XCTFail("reload mutation survived") }
            assertFault(mutated, hwpReloadSeam)
        }
    }

    func testHwpExtractControlThenConfigurationMutation() throws {
        for name in ["blank2010.hwp", "hwpx-01-saved.hwpx"] {
            let url = fixture(name)
            let ext = url.pathExtension
            #if FMD_RUST_ENGINE
            let seam = "M-HWP-RUST-EXTRACT"
            let expectedEngine = "rust"
            #else
            let seam = "M-HWP-SWIFT-EXTRACT"
            let expectedEngine = "swift"
            #endif
            let control = "extract-control-\(ext)"
            XCTAssertEqual(DocumentEngineTrace.withRun(control, entryPoint: "extract") {
                HeadlessExtract.run([url.path])
            }, 0)
            XCTAssertEqual(DocumentEngineTrace.snapshot(runID: control).map(\.engine), [expectedEngine])

            let mutated = "extract-mutated-\(ext)"
            XCTAssertEqual(DocumentEngineTrace.withRun(
                mutated, entryPoint: "extract", faults: [seam]
            ) { HeadlessExtract.run([url.path]) }, 1)
            assertFault(mutated, seam)
        }
    }

    func testPlainTextNavigationRejectionControlThenMutation() {
        let storage = NSTextStorage(string: "# raw text is not a rendered heading\n")
        let controlPanel = OutlinePanel(frame: .zero)
        DocumentEngineTrace.withRun("plain-nav-control", entryPoint: "derived-navigation") {
            controlPanel.reload(from: storage)
        }
        XCTAssertTrue(controlPanel.entries.isEmpty)

        let mutatedPanel = OutlinePanel(frame: .zero)
        DocumentEngineTrace.withRun(
            "plain-nav-mutated", entryPoint: "derived-navigation",
            faults: ["M-PLAIN-NAV-REJECTION"]
        ) { mutatedPanel.reload(from: storage) }
        XCTAssertFalse(mutatedPanel.entries.isEmpty, "plain-text navigation mutation survived")
        assertFault("plain-nav-mutated", "M-PLAIN-NAV-REJECTION")
    }

    func testOfficeSaveRejectionControlThenMutationLeavesSourceUntouched() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1b-read-only-\(UUID().uuidString).docx")
        let original = S1BOfficeFixtures.docx
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        document.fileURL = url

        XCTAssertThrowsError(try DocumentEngineTrace.withRun(
            "office-save-control", entryPoint: "edit-save"
        ) { try document.data(ofType: "public.data") })
        XCTAssertEqual(try Data(contentsOf: url), original)

        let produced = try DocumentEngineTrace.withRun(
            "office-save-mutated", entryPoint: "edit-save",
            faults: ["M-OFFICE-SAVE-REJECTION"]
        ) { try document.data(ofType: "public.data") }
        XCTAssertEqual(produced, Data(), "save rejection mutation did not alter the boundary")
        XCTAssertEqual(try Data(contentsOf: url), original, "mutation touched source bytes")
        assertFault("office-save-mutated", "M-OFFICE-SAVE-REJECTION")
    }

    func testHwpPDFSurfaceCarriesParserTraceAndProducesPDF() throws {
        let input = fixture("blank2010.hwp")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1b-hwp-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = DocumentEngineTrace.withRun("hwp-pdf", entryPoint: "pdf") {
            HeadlessPDF.run([input.path, "-o", output.path, "-f"])
        }
        XCTAssertEqual(result, 0)
        XCTAssertTrue(try Data(contentsOf: output).starts(with: Array("%PDF".utf8)))
        let events = DocumentEngineTrace.snapshot(runID: "hwp-pdf")
        XCTAssertEqual(events.map(\.entryPoint), ["pdf"])
        XCTAssertEqual(events.map(\.seam), [hwpOpenSeam])
    }

    @MainActor
    func testHwpQuickLookSurfaceCarriesParserTraceAndInstallsContent() async throws {
        let controller = QuickLookPreviewController()
        _ = controller.view
        DocumentEngineTrace.beginRun("hwp-quick-look", entryPoint: "quick-look")
        defer { DocumentEngineTrace.endRun() }
        try await controller.preparePreviewOfFile(at: fixture("blank2010.hwp"))
        XCTAssertFalse(controller.view.subviews.isEmpty, "Quick Look installed no content")
        let events = DocumentEngineTrace.snapshot(runID: "hwp-quick-look")
        XCTAssertEqual(events.map(\.entryPoint), ["quick-look"])
        XCTAssertEqual(events.map(\.seam), [hwpOpenSeam])
    }
}
#endif
