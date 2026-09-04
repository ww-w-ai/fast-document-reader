import XCTest
import CFastdocEngine
import AppKit
@testable import FastDocReader

/// The engine's markdown render against this app's own, attribute by attribute.
///
/// `markdown_wire_projection.rs` proves the wire is well formed and `markdown_wire_ffi.rs` proves
/// a caller can reach it. Neither says the string that comes back is the string the reader would
/// have built — and that is the only question that decides whether the engine can replace
/// `MarkdownRenderer`. So this compares the two FINISHED strings: the text, and then every
/// attribute at every position.
///
/// Deliberately NOT `isEqual:` on the strings, and not `isEqual:` on a paragraph style either:
/// `NSTextBlock` compares by identity, so two structurally identical tables are never equal and a
/// blunt comparison would fail on every document with a table while saying nothing about why.
/// Comparing field by field is what turns a failure into a sentence.
final class MarkdownEngineParityTests: XCTestCase {

    private static let sources: [(String, String)] = [
        ("headings and emphasis", """
        # Title

        Some **bold**, some *italic*, and some `inline code`.

        ## Second level

        A paragraph that runs on a little so it has more than one run in it.
        """),
        ("lists", """
        - first
        - second
          - nested
        1. one
        2. two
        """),
        ("a table", """
        | Column | Another | Third |
        |---|---:|:---:|
        | a | b | c |
        | d | e | f |
        """),
        ("code and rules", """
        ---

        ```swift
        let x = 1
        print(x)
        ```

        ---
        """),
        ("links and quotes", """
        > A quotation with a [link](https://ww-w.ai) inside it.

        See also [the docs](https://example.com/docs#anchor) and <https://example.com>.
        """),
        // A link whose whole text is inline code, inside a table cell — how `demo/README.md`
        // writes every one of its rows, and the shape that first showed the engine dropping the
        // link attribute.
        ("a code link in a table", """
        | Document | What to look at |
        |---|---|
        | [`code-blocks.md`](code-blocks.md) | Every language |
        """),
        ("mixed scripts", """
        # 제목 — mixed 스크립트

        한국어 문단과 English text가 섞인 문단입니다. **굵게** 그리고 *기울임*.
        """),
    ]

    func testTheEngineBuildsTheSameStringThisAppWouldHave() throws {
        for (name, source) in Self.sources {
            let theme = RenderTheme.current(size: 16)
            let host = MarkdownRenderer.render(source, theme: theme)
            guard let engine = RustMarkdownEngine.render(source, theme: theme) else {
                XCTFail("\(name): the engine returned nil — \(RustMarkdownEngine.lastFailure ?? "no reason recorded")")
                continue
            }
            XCTAssertEqual(engine.string, host.string, "\(name): the text itself differs")
            guard engine.string == host.string else { continue }
            for difference in Self.differences(engine: engine, host: host) {
                XCTFail("\(name): \(difference)")
            }
        }
    }

    /// The size the caller asks for has to reach the glyphs, not just the wire — a theme that was
    /// read but not used would pass every shape assertion above at one size and fail the reader at
    /// every other one.
    func testTheEngineHonoursTheReadingSize() throws {
        let source = "# Heading\n\nBody text.\n"
        for size in [12, 16, 24] as [CGFloat] {
            let theme = RenderTheme.current(size: size)
            let host = MarkdownRenderer.render(source, theme: theme)
            guard let engine = RustMarkdownEngine.render(source, theme: theme) else {
                XCTFail("the engine returned nil at \(size)pt")
                continue
            }
            let hostBody = try XCTUnwrap(host.attribute(.font, at: host.length - 2, effectiveRange: nil) as? NSFont)
            let engineBody = try XCTUnwrap(engine.attribute(.font, at: engine.length - 2, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(engineBody.pointSize, hostBody.pointSize, accuracy: 0.01,
                           "body size at \(size)pt")
        }
    }

    /// Two tables must stay TWO tables.
    ///
    /// The mirror of the check below, and the one that was missing: every markdown table declares
    /// the identical thing — n columns, borders collapsed — so a wire that pools tables by what
    /// they declare merges every table in a document into one grid, and AppKit then lays them out
    /// as a single table. Measured before the fix: a document of 60 tables produced 1.
    func testEveryTableInADocumentStaysItsOwnTable() throws {
        let theme = RenderTheme.current(size: 16)
        let source = (1...5).map { n in
            "## Section \(n)\n\n| A | B |\n|---|---|\n| \(n) | \(n * 2) |\n"
        }.joined(separator: "\n")
        guard let engine = RustMarkdownEngine.render(source, theme: theme) else {
            return XCTFail("the engine returned nil — \(RustMarkdownEngine.lastFailure ?? "no reason")")
        }
        let host = MarkdownRenderer.render(source, theme: theme)
        XCTAssertEqual(Self.tableCount(engine), 5, "five markdown tables are five NSTextTables")
        XCTAssertEqual(Self.tableCount(engine), Self.tableCount(host),
                       "and the engine must agree with this app's own renderer")
    }

    /// How many distinct `NSTextTable` objects a string's cells point at.
    static func tableCount(_ string: NSAttributedString) -> Int {
        var tables = Set<ObjectIdentifier>()
        string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            for block in ((value as? NSParagraphStyle)?.textBlocks ?? []) {
                guard let cell = block as? NSTextTableBlock else { continue }
                tables.insert(ObjectIdentifier(cell.table))
            }
        }
        return tables.count
    }

    /// A table's cells must all point at ONE `NSTextTable`. This is the one property the wire can
    /// get right in every field and still lay out wrongly, because AppKit reads it as identity.
    func testEveryCellOfOneTablePointsAtOneTable() throws {
        let theme = RenderTheme.current(size: 16)
        let source = Self.sources.first { $0.0 == "a table" }!.1
        guard let engine = RustMarkdownEngine.render(source, theme: theme) else {
            return XCTFail("the engine returned nil — \(RustMarkdownEngine.lastFailure ?? "no reason")")
        }
        var tables: [ObjectIdentifier: Int] = [:]
        engine.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: engine.length)) { value, _, _ in
            for block in ((value as? NSParagraphStyle)?.textBlocks ?? []) {
                guard let cell = block as? NSTextTableBlock else { continue }
                tables[ObjectIdentifier(cell.table), default: 0] += 1
            }
        }
        XCTAssertEqual(tables.count, 1, "one markdown table must produce one NSTextTable, got \(tables.count)")
        XCTAssertGreaterThanOrEqual(tables.values.first ?? 0, 9,
                                    "a 3x3 table has at least nine cells pointing at it")
    }

    /// The repository, from this file's own path — the same three steps every other test that
    /// reads a shipped sample takes.
    fileprivate func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - comparison

    /// Every way the two strings' attributes differ, as sentences. Empty means identical.
    /// The cell the engine sends is the cell the host's own builder makes: the same grid table
    /// with the same column shares, the same subclass, the same width, padding, rules and tint.
    /// For as long as the wire carried only a cell's position, every markdown table drew with no
    /// rules and no padding and was skipped by every reflow (invariant 162).
    func testATableCellCrossesTheWireWithItsGridPaddingRulesAndTint() throws {
        let source = "| Document | What to look at |\n|---|---|\n| one | two |\n| three | four |\n"
        let theme = RenderTheme.current(size: 16)
        let host = MarkdownRenderer.render(source, theme: theme)
        let engine = try XCTUnwrap(RustMarkdownEngine.render(source, theme: theme),
                                   RustMarkdownEngine.lastFailure ?? "the engine returned nil")
        let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]
        for text in ["Document", "one", "four"] {
            let h = try XCTUnwrap(Self.cell(in: host, at: text), "host \(text)")
            let e = try XCTUnwrap(Self.cell(in: engine, at: text), "engine \(text)")
            XCTAssertTrue(e is GridTextTableBlock, "\(text): the engine's cell is the host's own subclass")
            let hg = try XCTUnwrap(h.table as? GridTextTable, "\(text): the host grid")
            let eg = try XCTUnwrap(e.table as? GridTextTable, "\(text): the engine's table is the grid table")
            XCTAssertEqual(eg.columnProportions, hg.columnProportions, "\(text): column shares")
            XCTAssertEqual(e.contentWidth, h.contentWidth, accuracy: 0.01, "\(text): width")
            for edge in edges {
                XCTAssertEqual(e.width(for: .padding, edge: edge), h.width(for: .padding, edge: edge), accuracy: 0.01, "\(text): padding")
                XCTAssertEqual(e.width(for: .border, edge: edge), h.width(for: .border, edge: edge), accuracy: 0.01, "\(text): rule")
                XCTAssertEqual(e.borderColor(for: edge) != nil, h.borderColor(for: edge) != nil, "\(text): rule colour")
            }
            XCTAssertEqual(e.backgroundColor != nil, h.backgroundColor != nil, "\(text): tint")
        }
        // The comparison is of two FULL cells, not two empties.
        let header = try XCTUnwrap(Self.cell(in: engine, at: "Document"))
        XCTAssertNotNil(header.backgroundColor, "the header row is tinted")
        XCTAssertGreaterThan(header.width(for: .padding, edge: .minX), 0, "the cell has padding")
        XCTAssertGreaterThan(header.width(for: .border, edge: .minY) + header.width(for: .border, edge: .maxY), 0, "the grid has rules")
    }

    private static func cell(in s: NSAttributedString, at text: String) -> NSTextTableBlock? {
        let r = (s.string as NSString).range(of: text)
        guard r.location != NSNotFound else { return nil }
        return (s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.last as? NSTextTableBlock
    }

    fileprivate static func differences(engine: NSAttributedString, host: NSAttributedString) -> [String] {
        var found: [String] = []
        let whole = NSRange(location: 0, length: host.length)
        // Table identity is per-string, so the comparison is between the SHAPES of the two
        // groupings: cell N of the host's table and cell N of the engine's must agree on which
        // table-slot they belong to, without either side's pointers meaning anything to the other.
        var hostTables: [ObjectIdentifier: Int] = [:]
        var engineTables: [ObjectIdentifier: Int] = [:]

        host.enumerateAttributes(in: whole, options: []) { hostAttrs, range, _ in
            let engineAttrs = engine.attributes(at: range.location, effectiveRange: nil)
            let keys = Set(hostAttrs.keys).union(engineAttrs.keys)
            for key in keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let at = "at \(range.location)..<\(range.location + range.length) [\(key.rawValue)]"
                switch (hostAttrs[key], engineAttrs[key]) {
                case (nil, .some(let e)): found.append("\(at): the engine added \(e)")
                case (.some(let h), nil): found.append("\(at): the engine dropped \(h)")
                case (.some(let h), .some(let e)):
                    if key == .paragraphStyle,
                       let hp = h as? NSParagraphStyle, let ep = e as? NSParagraphStyle {
                        found += paragraphDifferences(hp, ep, at: at,
                                                      hostTables: &hostTables, engineTables: &engineTables)
                    } else if key == .attachment,
                              let ha = h as? NSTextAttachment, let ea = e as? NSTextAttachment {
                        let hs = (ha.attachmentCell as? SizedAttachmentCell)?.reservedSize ?? .zero
                        let es = (ea.attachmentCell as? SizedAttachmentCell)?.reservedSize ?? .zero
                        if hs != es { found.append("\(at): reserved \(es) against \(hs)") }
                    } else if let ho = h as? NSObject, let eo = e as? NSObject, !ho.isEqual(eo) {
                        found.append("\(at): \(e) against \(h)")
                    }
                case (nil, nil): break
                }
            }
        }
        return found
    }

    fileprivate static func paragraphDifferences(
        _ host: NSParagraphStyle, _ engine: NSParagraphStyle, at: String,
        hostTables: inout [ObjectIdentifier: Int], engineTables: inout [ObjectIdentifier: Int]
    ) -> [String] {
        var found: [String] = []
        func compare(_ name: String, _ h: CGFloat, _ e: CGFloat) {
            if abs(h - e) > 0.001 { found.append("\(at) \(name): \(e) against \(h)") }
        }
        compare("lineSpacing", host.lineSpacing, engine.lineSpacing)
        compare("paragraphSpacing", host.paragraphSpacing, engine.paragraphSpacing)
        compare("paragraphSpacingBefore", host.paragraphSpacingBefore, engine.paragraphSpacingBefore)
        compare("firstLineHeadIndent", host.firstLineHeadIndent, engine.firstLineHeadIndent)
        compare("headIndent", host.headIndent, engine.headIndent)
        compare("tailIndent", host.tailIndent, engine.tailIndent)
        compare("defaultTabInterval", host.defaultTabInterval, engine.defaultTabInterval)
        compare("lineHeightMultiple", host.lineHeightMultiple, engine.lineHeightMultiple)
        compare("minimumLineHeight", host.minimumLineHeight, engine.minimumLineHeight)
        compare("maximumLineHeight", host.maximumLineHeight, engine.maximumLineHeight)
        if host.alignment != engine.alignment {
            found.append("\(at) alignment: \(engine.alignment.rawValue) against \(host.alignment.rawValue)")
        }
        if host.lineBreakMode != engine.lineBreakMode {
            found.append("\(at) lineBreakMode: \(engine.lineBreakMode.rawValue) against \(host.lineBreakMode.rawValue)")
        }
        if host.baseWritingDirection != engine.baseWritingDirection {
            found.append("\(at) baseWritingDirection differs")
        }
        if host.lineBreakStrategy != engine.lineBreakStrategy {
            found.append("\(at) lineBreakStrategy: \(engine.lineBreakStrategy.rawValue) against \(host.lineBreakStrategy.rawValue)")
        }
        let hostStops = host.tabStops.map { ($0.alignment.rawValue, $0.location) }
        let engineStops = engine.tabStops.map { ($0.alignment.rawValue, $0.location) }
        if hostStops.count != engineStops.count
            || zip(hostStops, engineStops).contains(where: { $0.0 != $1.0 || abs($0.1 - $1.1) > 0.001 }) {
            found.append("\(at) tabStops: \(engineStops) against \(hostStops)")
        }
        if host.textBlocks.count != engine.textBlocks.count {
            found.append("\(at) textBlocks: \(engine.textBlocks.count) against \(host.textBlocks.count)")
            return found
        }
        for (h, e) in zip(host.textBlocks, engine.textBlocks) {
            guard let hc = h as? NSTextTableBlock, let ec = e as? NSTextTableBlock else {
                found.append("\(at): a text block that is not a table cell")
                continue
            }
            if hc.startingRow != ec.startingRow || hc.rowSpan != ec.rowSpan
                || hc.startingColumn != ec.startingColumn || hc.columnSpan != ec.columnSpan {
                found.append("\(at) cell: r\(ec.startingRow)+\(ec.rowSpan) c\(ec.startingColumn)+\(ec.columnSpan)"
                             + " against r\(hc.startingRow)+\(hc.rowSpan) c\(hc.startingColumn)+\(hc.columnSpan)")
            }
            // Neither side's pointers mean anything to the other, so each table is given the
            // slot number it was first seen at. Two cells agree iff both sides put them in the
            // same slot — which is exactly "these cells are one grid" without comparing pointers.
            let hostSlot = hostTables[ObjectIdentifier(hc.table), default: hostTables.count]
            let engineSlot = engineTables[ObjectIdentifier(ec.table), default: engineTables.count]
            hostTables[ObjectIdentifier(hc.table)] = hostSlot
            engineTables[ObjectIdentifier(ec.table)] = engineSlot
            if hostSlot != engineSlot {
                found.append("\(at): this cell is in table slot \(engineSlot), the host puts it in \(hostSlot)")
            }
            if hc.table.numberOfColumns != ec.table.numberOfColumns {
                found.append("\(at) columns: \(ec.table.numberOfColumns) against \(hc.table.numberOfColumns)")
            }
            if hc.table.collapsesBorders != ec.table.collapsesBorders {
                found.append("\(at) collapsesBorders differs")
            }
        }
        return found
    }
}


extension MarkdownEngineParityTests {

    /// The same comparison, against the four documents this app actually ships — including
    /// Moby-Dick, which is 1.2 million characters and the only sample here with enough prose to
    /// exercise the pools at scale.
    func testTheEngineMatchesOnEveryDocumentThisAppShips() throws {
        let theme = RenderTheme.current(size: 16)
        for name in ["code-blocks.md", "images.md", "math.md", "moby-dick.md", "README.md"] {
            let url = repoRoot().appendingPathComponent("demo").appendingPathComponent(name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("\(name) is missing from demo/")
                continue
            }
            let host = MarkdownRenderer.render(source, theme: theme)
            guard let engine = RustMarkdownEngine.render(source, theme: theme) else {
                XCTFail("\(name): the engine returned nil — \(RustMarkdownEngine.lastFailure ?? "no reason recorded")")
                continue
            }
            if engine.string != host.string {
                // Named, never dumped: a 1.2-million-character document printed in full is a
                // failure report nobody reads. The first differing index and its neighbourhood is
                // what actually locates the bug.
                let h = host.string as NSString, e = engine.string as NSString
                var i = 0
                while i < min(h.length, e.length), h.character(at: i) == e.character(at: i) { i += 1 }
                let window = { (s: NSString) in
                    s.substring(with: NSRange(location: i, length: min(40, s.length - i)))
                }
                XCTFail("\(name): text differs at \(i) of host \(h.length) / engine \(e.length)"
                        + "\n  host  : \(window(h).debugDescription)"
                        + "\n  engine: \(window(e).debugDescription)")
                continue
            }
            let differences = Self.differences(engine: engine, host: host)
            // Named rather than dumped: one real document can differ in thousands of places, and a
            // failure report that scrolls past the screen is one nobody reads.
            XCTAssertEqual(differences.count, 0,
                           "\(name): \(differences.count) attribute differences, first: \(differences.first ?? "")")
        }
    }

    /// Nothing may fall through to `raw`.
    ///
    /// `raw` is the wire's escape hatch — a font or colour the theme cannot name, sent as a
    /// resolved face or as fixed components. It is not an error in itself, and that is exactly why
    /// it needs a gate: a `raw` colour renders the same in both appearances (losing dark mode) and
    /// a `raw` font is rebuilt from a name that, for a system face, does not round-trip. Both look
    /// right in a screenshot and are wrong in a way only this check sees.
    func testNothingFallsThroughToTheRawEscapeHatch() throws {
        for name in ["code-blocks.md", "images.md", "math.md", "moby-dick.md", "README.md"] {
            let url = repoRoot().appendingPathComponent("demo").appendingPathComponent(name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let wire = try XCTUnwrap(Self.wire(for: source, size: 16), "\(name) produced no wire")
            XCTAssertEqual(wire.fonts.filter { $0.role == "raw" }.map(\.name), [],
                           "\(name): a font the theme cannot name")
            XCTAssertEqual(wire.colors.filter { $0.role == "raw" }.count, 0,
                           "\(name): a colour the theme cannot name")
            XCTAssertFalse(wire.fonts.isEmpty, "\(name): a rendered document names fonts")
        }
    }

    /// The wire itself, decoded — the parity tests compare finished strings, and this is the one
    /// check that needs to see what crossed.
    static func wire(for source: String, size: CGFloat) -> MarkdownWire? {
        RustEngineFonts.install()
        let bytes = Array(source.utf8)
        let envelope: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBufferPointer {
            fastdoc_render_markdown($0.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 0x1)!,
                                    $0.count, Double(size))
        }
        guard let envelope else { return nil }
        defer { fastdoc_string_free(envelope) }
        struct Envelope: Decodable { var ok: MarkdownWire? }
        return (try? JSONDecoder().decode(Envelope.self, from: Data(bytes: envelope, count: strlen(envelope))))?.ok
    }
}


extension MarkdownEngineParityTests {

    /// A document built PIECE BY PIECE must equal the same document built at once.
    ///
    /// This is the property front-first paint is entirely built on: the reader sees the head
    /// first and the rest arrives afterwards, and nobody may be able to tell afterwards which
    /// document they are looking at. It is also the property a stateless chunk export would break
    /// invisibly — every piece would look right on its own and the joins would be wrong.
    func testAProgressiveRenderJoinsUpToTheWholeDocument() throws {
        let theme = RenderTheme.current(size: 16)
        for name in ["code-blocks.md", "math.md", "README.md"] {
            let url = repoRoot().appendingPathComponent("demo").appendingPathComponent(name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("\(name) is missing from demo/")
                continue
            }
            let whole = try XCTUnwrap(RustMarkdownEngine.render(source, theme: theme),
                                      "\(name): \(RustMarkdownEngine.lastFailure ?? "no reason")")
            let render = try XCTUnwrap(RustMarkdownEngine.renderProgressive(source, theme: theme),
                                       "\(name): the engine would not start a progressive render")
            let joined = NSMutableAttributedString()
            var pieces = 0
            while !render.isFinished {
                joined.append(render.nextChunk(blocks: 3))
                pieces += 1
                // Bounded: a handle that never advances is a hang, and a hanging test takes its
                // own cleanup down with it.
                guard pieces < 500 else { return XCTFail("\(name): the render never finished") }
            }
            XCTAssertGreaterThan(pieces, 1, "\(name) is long enough to arrive in more than one piece")
            XCTAssertEqual(joined.string, whole.string, "\(name): the pieces do not join up")
            guard joined.string == whole.string else { continue }
            let differences = Self.differences(engine: joined, host: whole)
            XCTAssertEqual(differences.count, 0,
                           "\(name): \(differences.count) attribute differences between the "
                           + "progressive and whole renders, first: \(differences.first ?? "")")
        }
    }

    /// No two blocks may share an id across pieces — two neighbours that do read as ONE stop for
    /// the reading cursor (invariant 19), which is what a handle that forgot its builder between
    /// pieces would produce.
    func testBlockIdsStayDistinctAcrossPieces() throws {
        let theme = RenderTheme.current(size: 16)
        let source = (1...12).map { "## Section \($0)\n\nParagraph \($0).\n" }.joined(separator: "\n")
        let render = try XCTUnwrap(RustMarkdownEngine.renderProgressive(source, theme: theme))
        let joined = NSMutableAttributedString()
        var pieces = 0
        while !render.isFinished {
            joined.append(render.nextChunk(blocks: 2))
            pieces += 1
            guard pieces < 500 else { return XCTFail("the render never finished") }
        }
        var ids: [Int] = []
        var ranges = 0
        joined.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: joined.length)) { value, _, _ in
            guard let id = value as? Int else { return }
            ranges += 1
            if ids.last != id { ids.append(id) }
        }
        XCTAssertGreaterThan(ranges, 2, "the document carries block ids at all")
        XCTAssertEqual(Set(ids).count, ids.count, "no id may be handed out twice: \(ids)")
    }
}
