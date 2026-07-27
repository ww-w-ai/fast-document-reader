import XCTest
@testable import FastDocReader

/// ODF's own script-type mapping (§20.358 table 22) as a pure function, plus the fixture-level
/// before/after measurement for the three-slot reader change.
///
/// The READER half — six attributes, per-slot inheritance, where a run is cut — lives beside the rest
/// of the ODT reader's cases in `OdtReaderTests`, which already owns the in-memory `.odt` builder.
final class OdtFontSlotTests: XCTestCase {
    // MARK: Table 22 itself, checked against the totals the published table has

    /// The rows must be sorted and non-overlapping, because the lookup binary searches them, and a
    /// mistyped bound that made two rows overlap would silently re-label whichever one lost.
    func testTable22RowsAreSortedAndNonOverlapping() {
        let rows = OdfScriptTable.publishedRanges
        for row in rows { XCTAssertLessThanOrEqual(row.first, row.last, "a row must not run backwards") }
        for index in 1..<rows.count {
            XCTAssertGreaterThan(rows[index].first, rows[index - 1].last,
                                 "row \(index) overlaps or precedes the one before it")
        }
    }

    /// The two numbers the published table can be checked against without transcribing it twice:
    /// 92,879 mapped code points across the three script types, and 22 unmapped gap ranges over the
    /// whole of Unicode. Both are DERIVED from the shipped rows rather than asserted alongside them,
    /// so a mistyped bound moves one of these totals and fails here.
    func testTable22MapsThePublishedTotalsAndLeavesThePublishedNumberOfGaps() {
        let rows = OdfScriptTable.publishedRanges
        let mapped = rows.reduce(0) { $0 + Int($1.last - $1.first) + 1 }
        XCTAssertEqual(mapped, 92_879, "ODF 1.3 Part 3 table 22 maps 92,879 code points")

        var gaps = 0
        var next: UInt32 = 0
        for row in rows {
            if row.first > next { gaps += 1 }
            next = row.last + 1
        }
        if next <= 0x10FFFF { gaps += 1 }
        XCTAssertEqual(gaps, 22, "table 22 leaves 22 ranges unmapped, which §20.358 declares "
                       + "implementation-dependent and this reader treats as weak")
    }

    /// One character from each of the three script types, taken from ranges the spec lists
    /// separately, so a row dropped in transcription shows up here rather than as a mis-drawn
    /// document. No language is named: these are code points, which is the whole reason table 22 is
    /// usable under this project's constraint.
    func testTable22SpotChecksAcrossAllThreeScriptTypes() {
        let latin: [Unicode.Scalar] = ["A", "0", "\u{00E9}", "\u{0416}", "\u{10A0}", "\u{13A0}", "\u{1E00}", "\u{A720}"]
        for scalar in latin { XCTAssertEqual(OdfScriptTable.slot(for: scalar), .latin, "U+\(hex(scalar))") }

        let asian: [Unicode.Scalar] = ["\u{AC00}", "\u{4E00}", "\u{3131}", "\u{1100}", "\u{3042}", "\u{F900}",
                                       "\u{FF21}", "\u{20000}"]
        for scalar in asian { XCTAssertEqual(OdfScriptTable.slot(for: scalar), .asian, "U+\(hex(scalar))") }

        let complex: [Unicode.Scalar] = ["\u{0E01}", "\u{0627}", "\u{05D0}", "\u{0905}", "\u{1200}", "\u{1780}",
                                         "\u{FB50}", "\u{FE70}"]
        for scalar in complex { XCTAssertEqual(OdfScriptTable.slot(for: scalar), .complex, "U+\(hex(scalar))") }
    }

    /// The gaps, which are the design decision rather than an edge case. Every one of these is a
    /// character a real document is full of, and each must absorb into the run it sits in instead of
    /// starting one of its own.
    func testTable22GapsAreWeakAndSelectNoSlot() {
        let weak: [Unicode.Scalar] = [" ", "\u{00A0}", "\u{2018}", "\u{201C}", "\u{2013}", "\u{2022}",
                                      "\u{E000}", "\u{1F600}", "\u{2A700}"]
        for scalar in weak {
            XCTAssertNil(OdfScriptTable.slot(for: scalar),
                         "U+\(hex(scalar)) is unmapped by table 22 and must be weak")
        }
    }

    /// The one place the cluster floor overrules the table. Each of these marks sits INSIDE a mapped
    /// range — the combining acute in latin, the Arabic fathatan in complex, the kana voiced mark in
    /// asian — so the table alone would let one of them begin a piece, which would cut a grapheme
    /// cluster in half whenever the base's own slot resolved to a different family.
    func testMarksThatExtendAClusterNeverStartAPieceEvenWhereTable22MapsThem() {
        for scalar: Unicode.Scalar in ["\u{0301}", "\u{064B}", "\u{3099}", "\u{0483}", "\u{094D}", "\u{0E31}"] {
            XCTAssertNotNil(OdfScriptTable.publishedRanges.first { scalar.value >= $0.first && scalar.value <= $0.last },
                            "U+\(hex(scalar)) must sit inside a mapped range, or this case proves nothing")
            XCTAssertNil(OdfScriptTable.slot(for: scalar),
                         "U+\(hex(scalar)) extends a cluster and must never start a piece")
        }
    }

    /// The other floor, and the one ruling that departs from the published table rather than filling
    /// a gap it left: a control character absorbs. Table 22 maps every one of these to latin —
    /// asserted here, so this case cannot quietly become a no-op if the table is ever re-transcribed
    /// — and the reader overrules it, because nothing in `Cc` is drawn and a tab whose width comes
    /// from the paragraph's tab stops has no business ending a run of Hangul.
    func testControlCharactersAbsorbEvenThoughTable22MapsThemToLatin() {
        for scalar: Unicode.Scalar in ["\u{0009}", "\u{000A}", "\u{000D}", "\u{001F}", "\u{007F}", "\u{0085}"] {
            XCTAssertEqual(OdfScriptTable.publishedRanges.first { scalar.value >= $0.first && scalar.value <= $0.last }?.type,
                           .latin, "U+\(hex(scalar)) must be mapped to latin by the table, or this case proves nothing")
            XCTAssertNil(OdfScriptTable.slot(for: scalar), "U+\(hex(scalar)) is a control and must absorb")
        }
    }

    private func hex(_ scalar: Unicode.Scalar) -> String { String(scalar.value, radix: 16, uppercase: true) }

    // MARK: The fixtures, measured before and after — invariant 37

    /// Every `.odt` this repo ships, read through the REAL dispatch (invariant 29), reduced to the
    /// only thing three-slot resolution can change: how many spans came out and which family each
    /// one asked for.
    ///
    /// These numbers were measured on both sides of the change and are IDENTICAL, which is the point:
    /// in every span-level style in all four files the latin and asian slots resolve to the same
    /// family and the only differing slot holds the empty string, so correct three-slot support
    /// cannot alter them. That makes this a no-regression guard and NOT evidence the feature works —
    /// the cases that demonstrate it working are the synthetic ones in `OdtReaderTests`, because no
    /// fixture here can. (The one real three-way declaration in the repo is a `style:family="paragraph"`
    /// style, and paragraph styles feed no span font at all; see the reader's own note.)
    ///
    /// Skipped rather than failed when the fixtures are absent: `docs/` is gitignored, so a fresh
    /// clone has none of them.
    func testTheFourOdtFixturesResolveExactlyTheFamiliesTheyDidBeforeSlotsExisted() throws {
        let expected: [String: (spans: Int, characters: Int, families: [String: Int])] = [
            "bus-headings": (755, 6670, ["<none>": 754, "휴먼엑스포": 1]),
            "tago-tables": (901, 8248, ["<none>": 900, "휴먼엑스포": 1]),
            "notes": (14, 200, ["<none>": 14]),
            "embed": (12, 114, ["<none>": 12]),
        ]
        var measured = 0
        for (name, want) in expected.sorted(by: { $0.key < $1.key }) {
            let url = repoRoot().appendingPathComponent("docs/fixtures/office/\(name).odt")
            guard let data = try? Data(contentsOf: url) else { continue }
            measured += 1
            let result = try DocumentTypes.readOffice(try ZipArchive(data: data), extension: "odt")
            let spans = everySpan(in: result.blocks)
            var families: [String: Int] = [:]
            for span in spans { families[span.fontName ?? "<none>", default: 0] += 1 }
            XCTAssertEqual(spans.count, want.spans, "\(name): span count")
            XCTAssertEqual(spans.reduce(0) { $0 + $1.text.count }, want.characters, "\(name): character count")
            XCTAssertEqual(families, want.families, "\(name): resolved-family histogram")
        }
        try XCTSkipIf(measured == 0, "docs/fixtures/office is gitignored and absent from this checkout")
        XCTAssertEqual(measured, expected.count, "every fixture present must be measured, not some of them")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every span the document holds, tables included — a table's cells are where a real report keeps
    /// most of its text, so a walk that skipped them would measure the least interesting half.
    private func everySpan(in blocks: [OfficeBlock]) -> [Span] {
        var out: [Span] = []
        for block in blocks {
            switch block {
            case .paragraph(let spans, _, _, _, _): out += spans
            case .heading(_, let spans, _, _, _, _): out += spans
            case .listItem(_, _, let spans, _, _, _, _, _): out += spans
            case .table(let rows, _, _, _):
                for row in rows { for cell in row { out += everySpan(in: cell.blocks) } }
            default: break
            }
        }
        return out
    }
}
