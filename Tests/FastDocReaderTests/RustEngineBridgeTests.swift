#if FMD_RUST_ENGINE
import XCTest
@testable import FastDocReader

/// Checks the boundary itself, from the app's side: the same document, read by this reader and by
/// the ported engine linked into the same process, has to produce the same Markdown.
///
/// The Rust workspace has its own corpus comparison, but it runs the engine as a Rust library and
/// shells out to the app. This one runs both readers IN ONE PROCESS across the C ABI, which is the
/// only place a whole class of failure can appear: the bytes handed over, the string encoding
/// coming back, the ownership of that string. A pure-Rust test cannot see any of it.
final class RustEngineBridgeTests: XCTestCase {
    /// The extension the bridge is given comes from the filename, and the engine lower-cases it
    /// itself — a `.DOCX` attachment is a real thing, and the readers' dispatch is case-insensitive
    /// on this side too.
    func testTheBridgeReturnsWhatThisReaderReturns() throws {
        guard let dir = ProcessInfo.processInfo.environment["FMD_BRIDGE_CORPUS"] else {
            throw XCTSkip("set FMD_BRIDGE_CORPUS to a directory of .docx/.odt documents")
        }

        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: dir) else {
            return XCTFail("cannot read \(dir)")
        }
        var checked = 0, refusedByBoth = 0
        var differing: [String] = []

        for case let name as String in walk {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["docx", "docm", "dotx", "dotm", "odt"].contains(ext) else { continue }
            // AppleDouble stubs: not documents, and both readers refuse them.
            guard !(name as NSString).lastPathComponent.hasPrefix("._") else { continue }

            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path) else { continue }

            let ours: String?
            do {
                let result = try DocumentTypes.readOffice(try ZipArchive(data: data), extension: ext)
                ours = OfficeMarkdownSerializer.serialize(result.blocks, footnotes: result.footnotes)
            } catch {
                ours = nil
            }
            let theirs = RustEngine.extractMarkdown(data, extension: ext)

            switch (ours, theirs) {
            case (nil, nil): refusedByBoth += 1
            case let (a?, b?) where a == b: checked += 1
            case (_?, nil): differing.append("\(name) — we read it, the engine refused it")
            case (nil, _?): differing.append("\(name) — the engine read it, we refused it")
            default: differing.append("\(name) — both read it, the Markdown differs")
            }
        }

        print("BRIDGE \(checked) identical, \(refusedByBoth) refused by both, \(differing.count) differing")
        XCTAssertTrue(differing.isEmpty, "the engine disagreed with this reader:\n\(differing.joined(separator: "\n"))")
        XCTAssertGreaterThan(checked + refusedByBoth, 0, "FMD_BRIDGE_CORPUS matched no documents")
    }

    /// The engine's whole document, decoded into this app's own vocabulary, against what this
    /// app's reader produces for the same file.
    ///
    /// This is the check the Markdown comparison cannot make. `--extract` walks only the parts of
    /// the vocabulary that turn into text, so a table's borders, a cell's shading, a paragraph's
    /// indents and the page geometry all pass through it untouched and unchecked. `OfficeReadResult`
    /// is `Equatable` over every field, so comparing the two results compares ALL of it.
    ///
    /// Both sides are compared BEFORE font substitution: that step is AppKit's, it runs on the host
    /// for either reader, and including it would be comparing this app against itself.
    func testTheEngineReadsTheSameDocumentThisReaderDoes() throws {
        guard let dir = ProcessInfo.processInfo.environment["FMD_BRIDGE_CORPUS"] else {
            throw XCTSkip("set FMD_BRIDGE_CORPUS to a directory of .docx/.odt documents")
        }
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: dir) else { return XCTFail("cannot read \(dir)") }

        var identical = 0, refusedByBoth = 0, engineDeclined = 0
        var differing: [String] = []

        for case let name as String in walk {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["docx", "docm", "dotx", "dotm", "odt"].contains(ext) else { continue }
            guard !(name as NSString).lastPathComponent.hasPrefix("._") else { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path) else { continue }

            let ours: OfficeReadResult?
            do {
                // The readers directly, NOT `DocumentTypes.readOffice` — that applies font
                // substitution, which is the host's and runs after either reader.
                let archive = try ZipArchive(data: data)
                ours = ext == "odt" ? try OdtReader.read(archive) : try DocxReader.read(archive)
            } catch {
                ours = nil
            }
            let theirs = RustEngine.readOffice(data, extension: ext)

            switch (ours, theirs) {
            case (nil, nil): refusedByBoth += 1
            // The engine declining a document it CAN read — one carrying something the envelope
            // cannot hold — is a designed outcome, not a failure. It is counted, not ignored, so a
            // silent rise in declines cannot pass for success.
            case (_?, nil): engineDeclined += 1
            case (nil, _?): differing.append("\(name) — the engine read it, we refused it")
            case let (a?, b?) where a == b: identical += 1
            default: differing.append("\(name) — both read it, the result differs")
            }
        }

        print("TREE \(identical) identical, \(engineDeclined) declined by the engine, \(refusedByBoth) refused by both, \(differing.count) differing")
        XCTAssertTrue(differing.isEmpty, "the engine disagreed with this reader:\n\(differing.joined(separator: "\n"))")
        XCTAssertGreaterThan(identical, 0, "no document was actually compared")
    }

    /// The library owns every string it returns, so a caller that keeps calling must not grow.
    /// Run under a leak check this is worth little on its own; run in the same suite as the
    /// comparison above, it is what says the `defer`-free path does not exist.
    func testRepeatedCallsDoNotDependOnCallerFreeingAnything() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_BRIDGE_FILE"],
              let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("set FMD_BRIDGE_FILE to one .docx/.odt document")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let first = RustEngine.extractMarkdown(data, extension: ext)
        XCTAssertNotNil(first)
        for _ in 0..<50 {
            XCTAssertEqual(RustEngine.extractMarkdown(data, extension: ext), first)
        }
    }
}
#endif
