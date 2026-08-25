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
    /// The shipping Swift implementation is the reference even in a Rust-enabled build.
    /// Never route this helper through `DocumentTypes.readOffice`: that dispatches to Rust under
    /// `FMD_RUST_ENGINE` and would turn the comparison into Rust against itself.
    private func swiftReference(_ data: Data, extension ext: String) throws -> OfficeReadResult {
        #if DEBUG
        try DocumentEngineTrace.record(
            fileClass: ext == "odt" ? "odt" : "docx", extension: ext, engine: "swift",
            seam: ext == "odt" ? "M-SWIFT-REF-ODT" : "M-SWIFT-REF-DOCX")
        #endif
        let archive = try ZipArchive(data: data)
        return ext == "odt" ? try OdtReader.read(archive) : try DocxReader.read(archive)
    }

    /// Deterministic S1A fixtures make both successful format comparisons mandatory. A refused
    /// document is a failure here and can never inflate the compared-document count.
    func testS1BDeterministicDocxAndOdtBridgeComparisonsAndMutations() throws {
        for item in [("docx", S1BOfficeFixtures.docx), ("odt", S1BOfficeFixtures.odt)] {
            let ext = item.0
            let data = item.1
            let reference = try swiftReference(data, extension: ext)
            let tree = try XCTUnwrap(RustEngine.readOffice(data, extension: ext))
            XCTAssertEqual(tree, reference, "\(ext) full-tree bridge differs")
            XCTAssertEqual(
                RustEngine.extractMarkdown(data, extension: ext),
                OfficeMarkdownSerializer.serialize(reference.blocks, footnotes: reference.footnotes),
                "\(ext) Markdown bridge differs")
            print("S1B_COMPARE {\"extension\":\"\(ext)\",\"api\":\"tree\",\"result\":\"equal\"}")
            print("S1B_COMPARE {\"extension\":\"\(ext)\",\"api\":\"markdown\",\"result\":\"equal\"}")

            #if DEBUG
            let referenceSeam = ext == "odt" ? "M-SWIFT-REF-ODT" : "M-SWIFT-REF-DOCX"
            let referenceRun = "reference-mutated-\(ext)"
            XCTAssertThrowsError(try DocumentEngineTrace.withRun(
                referenceRun, entryPoint: "bridge-reference", faults: [referenceSeam]
            ) { try swiftReference(data, extension: ext) })
            XCTAssertEqual(DocumentEngineTrace.faults(runID: referenceRun), ["F-\(referenceSeam)"])
            print("S1B_MUTATION {\"id\":\"\(referenceSeam)\",\"faultId\":\"F-\(referenceSeam)\","
                  + "\"configuration\":\"rust-enabled\",\"role\":\"killer\","
                  + "\"controlPassed\":true,\"mutatedFailed\":true,"
                  + "\"killerTest\":\"RustEngineBridgeTests/"
                  + "testS1BDeterministicDocxAndOdtBridgeComparisonsAndMutations\"}")

            let treeRun = "tree-mutated-\(ext)"
            XCTAssertNil(DocumentEngineTrace.withRun(
                treeRun, entryPoint: "bridge-tree", faults: ["M-RUST-BRIDGE-TREE"]
            ) { RustEngine.readOffice(data, extension: ext) })
            XCTAssertEqual(DocumentEngineTrace.faults(runID: treeRun), ["F-M-RUST-BRIDGE-TREE"])
            let bridgeRole = ext == "docx" ? "killer" : "corroboration"
            print("S1B_MUTATION {\"id\":\"M-RUST-BRIDGE-TREE\",\"faultId\":\"F-M-RUST-BRIDGE-TREE\","
                  + "\"configuration\":\"rust-enabled\",\"role\":\"\(bridgeRole)\","
                  + "\"controlPassed\":true,\"mutatedFailed\":true,"
                  + "\"killerTest\":\"RustEngineBridgeTests/"
                  + "testS1BDeterministicDocxAndOdtBridgeComparisonsAndMutations\"}")

            let markdownRun = "markdown-mutated-\(ext)"
            XCTAssertNil(DocumentEngineTrace.withRun(
                markdownRun, entryPoint: "bridge-markdown", faults: ["M-RUST-BRIDGE-MARKDOWN"]
            ) { RustEngine.extractMarkdown(data, extension: ext) })
            XCTAssertEqual(DocumentEngineTrace.faults(runID: markdownRun), ["F-M-RUST-BRIDGE-MARKDOWN"])
            print("S1B_MUTATION {\"id\":\"M-RUST-BRIDGE-MARKDOWN\","
                  + "\"faultId\":\"F-M-RUST-BRIDGE-MARKDOWN\","
                  + "\"configuration\":\"rust-enabled\",\"role\":\"\(bridgeRole)\","
                  + "\"controlPassed\":true,\"mutatedFailed\":true,"
                  + "\"killerTest\":\"RustEngineBridgeTests/"
                  + "testS1BDeterministicDocxAndOdtBridgeComparisonsAndMutations\"}")
            #endif
        }
    }

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
                let result = try swiftReference(data, extension: ext)
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
                ours = try swiftReference(data, extension: ext)
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

    // MARK: - S2B-04: `RustCanonicalEnvelope.decode` against hand-built JSON
    //
    // No call into the Rust library — the S2B-04 wire contract is decided and typed on the Swift
    // side before the export exists, so these deliberately do not depend on any Rust symbol; the
    // FFI call itself is Pass C's job.

    /// The S2B-04 acceptance condition, by name: an unknown `ffiVersion` fails the WHOLE decode,
    /// never a partial read of a valid-looking `ok` sitting right beside it. Decoding a normal
    /// envelope correctly (below) does not by itself satisfy this — this is the test that does.
    func testAnEnvelopeFromAnUnknownFfiVersionFailsWholeRatherThanPartially() {
        let json = Data("""
        {"ffiVersion":99,"ok":{"schemaVersion":1,"blocks":[]}}
        """.utf8)
        XCTAssertThrowsError(try RustCanonicalEnvelope.decode(json)) { error in
            XCTAssertEqual(error as? RustCanonicalEnvelopeError, .unknownFfiVersion(99))
        }
    }

    func testAValidOkEnvelopeDecodesToATypedSchemaVersion() throws {
        let json = Data("""
        {"ffiVersion":1,"ok":{"schemaVersion":1,"blocks":["a","b"]}}
        """.utf8)
        let envelope = try RustCanonicalEnvelope.decode(json)
        guard case let .ok(ok) = envelope else {
            return XCTFail("expected .ok, got \(envelope)")
        }
        XCTAssertEqual(ok.schemaVersion, 1)
        let rawObject = try JSONSerialization.jsonObject(with: ok.okObjectBytes) as? [String: Any]
        XCTAssertEqual(rawObject?["blocks"] as? [String], ["a", "b"])
    }

    /// An `error` envelope decodes kind/message/location, and — the part that matters — a `kind`
    /// this build has never seen still decodes rather than throwing, because a future error tag
    /// must never break a host already in the field.
    func testAnErrorEnvelopeDecodesAndPreservesAnUnknownKindVerbatim() throws {
        let json = Data("""
        {"ffiVersion":1,"error":{"kind":"totally_new_kind_v7","message":"boom","location":"reader.rs:12:3"}}
        """.utf8)
        let envelope = try RustCanonicalEnvelope.decode(json)
        guard case let .error(error) = envelope else {
            return XCTFail("expected .error, got \(envelope)")
        }
        XCTAssertEqual(error.kind, "totally_new_kind_v7")
        XCTAssertNil(error.known, "an unrecognised kind must not map to a known case")
        XCTAssertEqual(error.message, "boom")
        XCTAssertEqual(error.location, "reader.rs:12:3")
    }

    /// A known `kind` string does map to its case.
    func testAKnownErrorKindMapsToItsCase() throws {
        let json = Data("""
        {"ffiVersion":1,"error":{"kind":"hwpReadFailed","message":"bad byte","location":"reader.rs:1:1"}}
        """.utf8)
        guard case let .error(error) = try RustCanonicalEnvelope.decode(json) else {
            return XCTFail("expected .error")
        }
        XCTAssertEqual(error.known, .hwpReadFailed)
    }

    /// `ffiVersion` (the envelope) and `schemaVersion` (the tree inside `ok`) are read from
    /// separate fields and must never be confused — the two numbers here are deliberately
    /// different, and each is asserted at its own site.
    func testFfiVersionAndSchemaVersionAreReadFromDistinctFields() throws {
        let json = Data("""
        {"ffiVersion":1,"ok":{"schemaVersion":42,"blocks":[]}}
        """.utf8)
        XCTAssertEqual(RustCanonicalEnvelope.supportedFfiVersion, 1, "the envelope version this build accepts")
        guard case let .ok(ok) = try RustCanonicalEnvelope.decode(json) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(ok.schemaVersion, 42, "the tree version must be read from \"ok\", not confused with ffiVersion")
    }

    /// Neither `ok` nor `error` present — not a shape the contract allows.
    func testAnEnvelopeWithNeitherOkNorErrorFailsToDecode() {
        let json = Data("""
        {"ffiVersion":1}
        """.utf8)
        XCTAssertThrowsError(try RustCanonicalEnvelope.decode(json))
    }

    // MARK: - S5-04/S5-05: the running-header band height, decided in Rust, against the host's own answer

    /// `RustEngineMeasure`'s `makePayload` → `measure` round trip, checked from Swift alone: does
    /// the FLATTEN of `OfficeTextBuilder`'s own output lose anything TextKit would have measured
    /// differently? This is adapter-mapping fidelity, not cross-process agreement — no FFI call, no
    /// Rust decision, both numbers computed in THIS process by THIS file. The live, two-way C-ABI
    /// call that actually asks Rust for the band height is
    /// `testTheCrossProcessCallAgreesWithTheHostsOwnBandHeightForARealHeader` below, which was the
    /// gap an intent audit found this file's old test names claimed to close and did not.
    ///
    /// Tolerance: 0.5pt. Both heights come from the identical TextKit ritual
    /// (`NSTextStorage` → `NSLayoutManager` → unbounded `NSTextContainer`, no padding) run twice —
    /// once directly on `OfficeTextBuilder`'s output, once on that output flattened and rebuilt —
    /// so the only source of drift is floating-point rounding through two separate attributed
    /// strings, not a different interpretation. A tolerance wide enough to hide a whole extra
    /// line (this theme's line height, ~20pt) would defeat the point; 0.5pt cannot.
    private func adapterMappingHeights(for blocks: [OfficeBlock], theme: RenderTheme, columnWidth: CGFloat) -> (swift: CGFloat, rust: CGFloat) {
        let swiftHeight = PageBandGeometry.builtHeight(
            of: blocks, theme: theme, columnWidth: columnWidth, documentDefaultFontSize: theme.baseFontSize,
            pageContentWidth: nil)
        let attr = OfficeTextBuilder.build(
            blocks, theme: theme, columnWidth: columnWidth, documentDefaultFontSize: theme.baseFontSize,
            pageContentWidth: nil)
        let (payload, keepAlive) = RustEngineMeasure.makePayload(from: attr)
        let rustHeight = withExtendedLifetime(keepAlive) { RustEngineMeasure.measure(payload, widthPoints: columnWidth) }
        return (swiftHeight, rustHeight)
    }

    func testTheAdapterMappingReproducesTheHostsOwnBandHeightForARealHeader() {
        let theme = RenderTheme.current(size: 14)
        let blocks: [OfficeBlock] = [.paragraph(spans: [Span(text: "Quarterly Report — Finance Division")])]
        let (swiftHeight, rustHeight) = adapterMappingHeights(for: blocks, theme: theme, columnWidth: 400)

        XCTAssertGreaterThan(swiftHeight, 0, "a real header must not measure zero")
        XCTAssertEqual(swiftHeight, rustHeight, accuracy: 0.5,
                        "the flattened-and-rebuilt payload must answer the same question TextKit already answered")
    }

    /// A second, taller header (three paragraphs, one carrying an image) must move BOTH sides —
    /// the guard against a tolerance wide enough to let a constant pass.
    func testATallerHeaderMovesBothTheHostsAnswerAndTheAdapterMappingsAnswerTheSameDirection() {
        let theme = RenderTheme.current(size: 14)
        let shortBlocks: [OfficeBlock] = [.paragraph(spans: [Span(text: "Q3 Report")])]
        let tallBlocks: [OfficeBlock] = [
            .paragraph(spans: [Span(text: "Quarterly Report — Consolidated Results for the Fiscal Year")]),
            .paragraph(spans: [Span(text: "Prepared by the Finance division, subject to audit")]),
            .image(id: "logo", size: CGSize(width: 64, height: 40), alignment: .left),
        ]

        let short = adapterMappingHeights(for: shortBlocks, theme: theme, columnWidth: 400)
        let tall = adapterMappingHeights(for: tallBlocks, theme: theme, columnWidth: 400)

        XCTAssertGreaterThan(tall.swift, short.swift, "the host's own answer must grow for the taller header")
        XCTAssertGreaterThan(tall.rust, short.rust, "the adapter mapping's answer must grow in the SAME direction")
        XCTAssertEqual(tall.swift, tall.rust, accuracy: 0.5, "agreement must hold at the taller size too, not just the short one")
    }

    // MARK: - The live cross-process call: `fastdoc_office_header_band_height`, actually invoked

    /// `docs/fixtures/office` and `testdocs/` are both gitignored (repo convention — see
    /// `.gitignore`'s own comments on those two lines, which name a SYMLINK as how a worktree
    /// reaches `testdocs/`; this worktree now has one, `ln -s <repo>/testdocs testdocs`), so a
    /// fresh checkout has neither; other fixture-backed tests in this target
    /// (`CellInteriorSeparatorTests.fixture`) already skip rather than fail for exactly that
    /// reason. This machine has both corpora, and every path this file passes here carries a real
    /// Word `w:headerReference` (`unzip -p … word/document.xml`), confirmed before writing this
    /// test — not invented. `repoRootRelativePath` is rooted at the repo, e.g.
    /// `"docs/fixtures/office/paged-visual/prosepages.docx"` or
    /// `"testdocs/everything/GnBS_IM_20260401.docx"`.
    private static func fixture(_ repoRootRelativePath: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(repoRootRelativePath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw XCTSkip("\(repoRootRelativePath) is gitignored and absent in this checkout")
        }
        return data
    }

    /// The host's own band height for a real document — `PageBandGeometry.bandHeight` run over the
    /// SAME `OfficeReadResult` the Swift reader produces for the SAME bytes, with the SAME theme the
    /// engine builds for itself (`RenderTheme::current(result.default_body_font_size)`,
    /// `fastdoc-ffi/src/lib.rs`'s `fastdoc_office_header_band_height`) — so the two calls are asked
    /// the identical question about the identical document.
    private func hostBandHeight(for reference: OfficeReadResult, columnWidth: CGFloat, footer: Bool) -> CGFloat {
        let theme = RenderTheme.current(size: reference.defaultBodyFontSize)
        return PageBandGeometry.bandHeight(
            headers: footer ? [] : reference.headers, footers: footer ? reference.footers : [],
            theme: theme, columnWidth: columnWidth,
            documentDefaultFontSize: reference.defaultBodyFontSize, pageContentWidth: nil)
    }

    /// The gap the intent audit named directly: no test in this file called into Rust across the C
    /// ABI for the band-height decision. This one does — twice over, in fact, since
    /// `fastdoc_office_header_band_height` crosses the boundary once for the document bytes (Rust
    /// reads and normalizes them) and once back into THIS process per paragraph (through
    /// `RustEngineMeasure`'s installed callback).
    ///
    /// One test, not two, and the order inside it matters: `RustEngineMeasure.install()` and the
    /// engine's font provider are both process-global one-shots (`fastdoc-ffi/src/lib.rs`'s own
    /// `text_measurer_missing_then_a_reentrant_callback_keeps_the_outer_panic_location` test states
    /// the same constraint for exactly this reason — "the measurer is a process-global `OnceLock`
    /// shared by every test in this binary, so the absence check has to run before the install
    /// below, in the same test"). Splitting the "not installed yet" assertion into its own test
    /// method was tried first and is WRONG here: XCTest does not run this file's methods in
    /// declaration order (observed empirically — alphabetical), so a second method that calls
    /// `install()` can run first and the "not installed" method then observes an already-installed
    /// process and fails for the wrong reason. Sequence, in order: (1) call the export with NO
    /// measurer installed — refused; (2) install fonts (`RustEngineFonts`, needed by the docx
    /// reader's own layout decisions) and the measurer (`RustEngineMeasure`); (3) call the SAME
    /// export again for a short real header and compare against the host's own
    /// `PageBandGeometry.bandHeight` for the SAME bytes; (4) repeat for a taller real header and
    /// check both sides moved the same direction — the live-call counterpart of
    /// `testATallerHeaderMovesBothTheHostsAnswerAndTheAdapterMappingsAnswerTheSameDirection` above,
    /// with two real documents standing in for "short"/"tall" instead of hand-built blocks.
    /// `prosepages.docx`'s header is one short line; `GnBS_IM_20260401.docx`'s (from `testdocs/`,
    /// `docx-test-corpus.md`'s standing real-document collection) is a single long line
    /// ("INVESTMENT MEMORANDUM | 주식회사 지앤바이오솔루션 … STRICTLY CONFIDENTIAL") that WRAPS at
    /// this test's 400pt column — genuinely taller, not merely longer, which is what "taller"
    /// has to mean for this check (only layout can tell a wrap from a single line, the same
    /// reasoning `built_height`'s own comment gives for measuring rather than estimating). Every
    /// other real header on this machine with `docs/fixtures/office`'s corpus checked first was
    /// either the SAME height as `prosepages.docx`'s (`bus-headings.docx`, `tablepage.docx`) or
    /// empty (덕소 5B구역's three blank header paragraphs) — confirmed by direct measurement
    /// before this pair was chosen, not assumed.
    func testTheCrossProcessCallAgreesWithTheHostsOwnBandHeightAndMovesTallerWithATallerRealHeader() throws {
        let columnWidth: CGFloat = 400
        let shortData = try Self.fixture("docs/fixtures/office/paged-visual/prosepages.docx")
        let tallData = try Self.fixture("testdocs/everything/GnBS_IM_20260401.docx")

        let beforeInstall = RustEngineMeasure.headerBandHeight(shortData, extension: "docx", columnWidth: columnWidth, footer: false)
        XCTAssertNil(beforeInstall, "with no measurer installed the engine cannot answer a height question")
        XCTAssertEqual(RustEngineMeasure.lastErrorKind(), "hostTextMeasurerMissing")

        RustEngineFonts.install()
        RustEngineMeasure.install()

        let shortReference = try swiftReference(shortData, extension: "docx")
        let tallReference = try swiftReference(tallData, extension: "docx")
        XCTAssertFalse(shortReference.headers.isEmpty, "prosepages.docx must declare a running header for this test to mean anything")
        XCTAssertFalse(tallReference.headers.isEmpty, "GnBS_IM_20260401.docx must declare a running header for this test to mean anything")

        let shortHost = hostBandHeight(for: shortReference, columnWidth: columnWidth, footer: false)
        let tallHost = hostBandHeight(for: tallReference, columnWidth: columnWidth, footer: false)
        XCTAssertGreaterThan(shortHost, 0, "a real header must not measure zero")

        let shortEngine = try XCTUnwrap(
            RustEngineMeasure.headerBandHeight(shortData, extension: "docx", columnWidth: columnWidth, footer: false),
            "the engine must answer once a measurer is installed")
        let tallEngine = try XCTUnwrap(
            RustEngineMeasure.headerBandHeight(tallData, extension: "docx", columnWidth: columnWidth, footer: false))

        XCTAssertEqual(shortHost, shortEngine, accuracy: 0.5,
                        "the engine's own decision must agree with this reader's own band height, across the FFI, for a real document")
        XCTAssertGreaterThan(tallHost, shortHost, "the host's own answer must grow for the taller real header")
        XCTAssertGreaterThan(tallEngine, shortEngine, "the engine's cross-process answer must grow in the SAME direction")
        XCTAssertEqual(tallHost, tallEngine, accuracy: 0.5, "agreement must hold at the taller real document too")
    }

    // MARK: - S5-01: the adapter maps a payload only — it decides nothing about the document itself

    /// `RustEngineMeasure.swift`'s own module doc states the rule this test enforces mechanically:
    /// "if the host has to decide anything, the port is wrong." A branch on a document format, a
    /// block kind, or a file extension would be exactly that — a second, divergent interpretation of
    /// the document living in the adapter instead of the engine. `swiftshim/src/text_measure.rs`'s
    /// `the_port_has_exactly_one_primitive_and_it_is_justified` is the Rust-side twin of this check.
    ///
    /// Proven to actually catch something, not just to pass: this test was run once with a deliberate
    /// `if ext == "hwp" { … }` inserted into `RustEngineMeasure.swift` and failed on that token before
    /// the line was removed (reported in this pass's return, not left behind as a second test).
    func testTheAdapterFileContainsNoDocumentFormatOrBlockKindBranching() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FastDocReader/Render/Office/RustEngineMeasure.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let forbidden = [
            "\"docx\"", "\"docm\"", "\"dotx\"", "\"dotm\"", "\"odt\"", "\"hwp\"", "\"hwpx\"",
            "DocxReader", "OdtReader", "HwpReader", "OfficeBlock",
            "case .paragraph", "case .heading", "case .table(", "case .image(",
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token),
                            "RustEngineMeasure.swift must not branch on \(token) — it maps an already-flattened payload only")
        }
    }
}
#endif
