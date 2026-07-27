import XCTest
@testable import FastDocReader

/// Runs a whole corpus of real office documents through the RENDER path — read → `OfficeTextBuilder`
/// → a laid-out `NSTextStorage` — rather than only through the reader.
///
/// `CorpusProbeTests` (its sibling) scans and PARSES; `--extract` reads and serialises. Neither one
/// ever constructs an `NSTextTableBlock`, so neither can see a defect in `TableBlockBuilder` — and
/// the worst bug of the border-ownership work was exactly that: an unclamped `rowSpan` walk trapped
/// `Index out of range` and killed the app on opening an ordinary `.odt`, while 832 tests stayed
/// green, because `DocxReader` clamps the span at its own source and the docx fixtures were all the
/// suite had. `OdtReader`/`HwpReader` pass the declared span through verbatim (invariant 50), so the
/// crash needed a real HWP/ODT document to surface. This probe is the instrument for that class.
///
///     FMD_RENDER_CORPUS="$HOME/Documents:$HOME/Downloads:$HOME/Desktop" \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter testRenderWholeCorpus
///
/// Skipped by default: it needs documents this repo does not ship. Every path is printed BEFORE it
/// is built, deliberately — a trap aborts the whole xctest process, so the last line printed names
/// the file that caused it. A thrown error is counted and the walk continues; only a trap stops it.
final class CorpusRenderProbeTests: XCTestCase {
    func testRenderWholeCorpus() throws {
        guard let dirList = ProcessInfo.processInfo.environment["FMD_RENDER_CORPUS"] else {
            throw XCTSkip("set FMD_RENDER_CORPUS (colon-separated directories) to render a corpus")
        }
        let roots = dirList.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let theme = RenderTheme.current(size: 16)

        var found = 0, rendered = 0, readThrew = 0, enumerationErrors = 0
        var tables = 0, cellParagraphs = 0
        var failures: [String] = []

        for root in roots {
            // An explicit error handler, for the reason `CorpusProbeTests` records: without one the
            // enumerator stops SILENTLY at the first unreadable subdirectory and the rest of that
            // root is never visited and never reported missing.
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [],
                errorHandler: { _, _ in enumerationErrors += 1; return true }
            ) else { continue }

            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let name = url.lastPathComponent
                    if name == "node_modules" || name == ".build" || name.hasPrefix(".") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard DocumentTypes.isHwp(ext) || ext == "docx" || ext == "docm" || ext == "dotx"
                        || ext == "dotm" || ext == "odt" else { continue }
                // Two kinds of look-alike that carry a document extension and no document: macOS
                // AppleDouble sidecars (`._name.docx`), and Word's own lock/owner stubs (`~$name.docx`,
                // a couple of hundred bytes, no central directory). Counting either as a read failure
                // would put six permanent "failures" in a report whose whole job is to make a real one
                // visible.
                let base = url.lastPathComponent
                guard !base.hasPrefix("._"), !base.hasPrefix("~$") else { continue }
                found += 1

                // Printed BEFORE the build: a trap takes the process down with it, so this line is
                // the only record of which document did it.
                print("render[\(found)] \(url.path)")

                let result: OfficeReadResult
                do {
                    if DocumentTypes.isHwp(ext) {
                        // HWP branches before the zip path — a `.hwp` is CFB/OLE, not an archive
                        // (invariant 44), so `ZipArchive(data:)` would throw on it.
                        result = try HwpReader.read(try Data(contentsOf: url))
                    } else {
                        result = try DocumentTypes.readOffice(try ZipArchive(data: Data(contentsOf: url)),
                                                              extension: ext)
                    }
                } catch {
                    readThrew += 1
                    failures.append("read \(error) — \(url.lastPathComponent)")
                    continue
                }

                // A real reading column, not `.greatestFiniteMagnitude`: the table geometry under
                // test is solved AGAINST this width (invariant 48b), so an unbounded one would
                // exercise a shape no window ever produces.
                let attr = OfficeTextBuilder.build(result.blocks, theme: theme,
                                                   columnWidth: 600,
                                                   pageContentWidth: result.pageContentWidth,
                                                   tableWidth: 600)
                // LAY IT OUT. Building alone leaves the geometry unevaluated; the arithmetic this
                // probe exists to protect only runs when the layout manager asks for it.
                let storage = NSTextStorage(attributedString: attr)
                let lm = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: 600,
                                                             height: CGFloat.greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(lm)
                lm.addTextContainer(container)
                lm.ensureLayout(for: container)
                // And re-solve to a DIFFERENT width, which is the reflow path (`resizeTables`) —
                // build↔resize disagreement is its own defect class (invariant 48c).
                TableBlockBuilder.resizeTables(in: storage, toWidth: 520)
                lm.ensureLayout(for: container)

                var seen = Set<ObjectIdentifier>()
                attr.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attr.length)) { v, _, _ in
                    guard let block = (v as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
                    else { return }
                    cellParagraphs += 1
                    if seen.insert(ObjectIdentifier(block.table)).inserted { tables += 1 }
                }
                rendered += 1
            }
        }

        print("""
        corpus render probe
          found=\(found) rendered=\(rendered) readThrew=\(readThrew) \
        enumerationErrorsSkippedPast=\(enumerationErrors)
          tables=\(tables) cellParagraphs=\(cellParagraphs)
        """)
        for f in failures.prefix(40) { print("  FAIL \(f)") }
        if failures.count > 40 { print("  … \(failures.count - 40) more") }

        // Deliberately NOT asserting `readThrew == 0`: a corpus contains genuinely broken and
        // password-protected files, and this probe's job is to surface a CRASH in the render path,
        // which is a trap and needs no assertion to be noticed. The counts are the report.
        XCTAssertGreaterThan(found, 0, "FMD_RENDER_CORPUS matched no office documents")
    }
}
