import XCTest
import UniformTypeIdentifiers
@testable import FastDocReader

final class OpenAnyFileTests: XCTestCase {
    func testFallbackDeclarationAndPanel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let fallback = try XCTUnwrap(types.first { ($0["LSItemContentTypes"] as? [String]) == ["public.data"] })
        XCTAssertEqual(fallback["LSHandlerRank"] as? String, "None")
        XCTAssertEqual(fallback["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(fallback["NSDocumentClass"] as? String, "FastDocReader.MarkdownDocument")
        XCTAssertTrue(DocumentTypes.openPanelTypes.contains(.data))
    }

    func testNamesAndRoundTrip() throws {
        let bytes = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0xe9])
        for name in ["config", ".env", "file.unknownextension", "main.swift"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try bytes.write(to: url)
            let doc = try MarkdownDocument(contentsOf: url, ofType: "public.data")
            XCTAssertEqual(doc.fileURL, url)
            XCTAssertEqual(doc.kind, .plainText)
            XCTAssertEqual(try doc.data(ofType: "public.data"), bytes, name)
            if case .text(let file) = MarkdownDocument.reloadOutcome(url: url, kind: .plainText, extension: url.pathExtension) {
                XCTAssertEqual(file.text, doc.text)
            } else { XCTFail("reload failed for \(name)") }
        }
        XCTAssertEqual(DocumentTypes.kind(forExtension: "md"), .markdown)
        XCTAssertEqual(DocumentTypes.kind(forExtension: "docx"), .office)
        XCTAssertFalse(DocumentTypes.opensInApp("swift"))
    }

    func testBinaryAndLimits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = MarkdownDocument()
        doc.fileURL = url
        let binary = Data([0, 1, 2, 255])
        try binary.write(to: url)
        try doc.read(from: url, ofType: "public.data")
        XCTAssertEqual(try doc.data(ofType: "public.data"), binary)
        let max = 16 * 1024 * 1024
        try Data(repeating: 65, count: max).write(to: url)
        try doc.read(from: url, ofType: "public.data")
        try Data(repeating: 65, count: max + 1).write(to: url)
        let priorText = doc.text
        XCTAssertThrowsError(try doc.read(from: url, ofType: "public.data"))
        XCTAssertEqual(doc.text, priorText)
        XCTAssertThrowsError(try doc.read(from: Data(repeating: 65, count: max + 1), ofType: "public.data"))
        if case .failure(let message) = MarkdownDocument.reloadOutcome(url: url, kind: .plainText, extension: "") {
            XCTAssertTrue(message.contains("16 MiB"))
        } else { XCTFail("oversized reload must fail") }
    }

    func testFIFOIsRejectedWithoutWaitingForWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = MarkdownDocument()
        doc.fileURL = url
        XCTAssertThrowsError(try doc.read(from: url, ofType: "public.data"))
    }

    func testDirectoryIsRejected() {
        let doc = MarkdownDocument()
        let url = FileManager.default.temporaryDirectory
        doc.fileURL = url
        XCTAssertThrowsError(try doc.read(from: url, ofType: "public.data"))
    }
}
