import Foundation
import CoreGraphics

/// Turns the format-neutral office block vocabulary (`OfficeBlock`, the SAME thing the reader
/// renders — invariant 29's `OfficeReadResult.blocks`) into GitHub-flavoured Markdown, for the
/// headless `--extract` path. Pure and view-free: `[OfficeBlock] -> String`, so it is fully unit
/// testable without AppKit layout.
///
/// Policy (conservative + honest, agreed with the owner):
///   - Map to real Markdown ONLY when it is unambiguous — headings, paragraphs, lists, simple
///     rectangular tables, inline bold/italic/strike/code/links, standalone formulas.
///   - When a construct can't be safely mapped (a merged-cell table, block content inside a cell),
///     do NOT fabricate a structure that would read as correct — dump the region's plain TEXT inside
///     a `<raw>…</raw>` marker instead. The CLI wrapper appends a one-line legend explaining `<raw>`
///     at the top of the document (the "footnote-style note" the owner asked for).
///   - Escaping is deliberately minimal (an AI consumer tolerates messy text far better than a
///     mangled table): only what would corrupt a structure WE emit — the `|` inside a pipe-table
///     cell, and newlines folded to spaces inside a span.
enum OfficeMarkdownSerializer {

    /// The marker the CLI legend refers to. Callers check `output.contains(rawOpen)` to decide
    /// whether to include the `<raw>` explanation in the header note.
    static let rawOpen = "<raw>"
    static let rawClose = "</raw>"

    static func serialize(_ blocks: [OfficeBlock]) -> String {
        var pieces: [(text: String, isList: Bool)] = []
        for block in blocks {
            let rendered = render(block)
            guard !rendered.text.isEmpty else { continue }
            pieces.append(rendered)
        }
        var out = ""
        for (i, p) in pieces.enumerated() {
            if i > 0 {
                // Consecutive list items stay in one list (single newline); everything else is
                // separated by a blank line so paragraphs/headings/tables don't run together.
                out += (p.isList && pieces[i - 1].isList) ? "\n" : "\n\n"
            }
            out += p.text
        }
        return out
    }

    // MARK: - Blocks

    private static func render(_ block: OfficeBlock) -> (text: String, isList: Bool) {
        switch block {
        case let .heading(level, spans, _, _, _, _):
            let hashes = String(repeating: "#", count: min(max(level, 1), 6))
            return ("\(hashes) \(inline(spans, inCell: false))", false)

        case let .paragraph(spans, _, _, _, _):
            return (inline(spans, inCell: false), false)

        case let .listItem(level, ordered, spans, marker, _, _, _, _):
            let indent = String(repeating: "  ", count: max(level, 0))
            let mark: String
            if ordered {
                // Preserve the document's OWN resolved label (e.g. "1.", "a.", "1.1.2", a legal
                // clause number) literally rather than letting Markdown auto-number — a real number
                // the reader shows must survive extraction.
                if let m = marker, !m.trimmingCharacters(in: .whitespaces).isEmpty {
                    mark = m.hasSuffix(" ") ? m : m + " "
                } else {
                    mark = "1. "
                }
            } else {
                mark = "- "
            }
            return (indent + mark + inline(spans, inCell: false), true)

        case let .table(rows, headerRows, _, _):
            return (renderTable(rows, headerRows: headerRows), false)

        case let .image(id, _, _):
            return ("![image](\(id))", false)

        case let .unsupportedGraphic(label, _, _):
            // The reader shows an honest placeholder for a chart/SmartArt with no picture fallback;
            // extraction mirrors that rather than inventing text that was never there.
            return ("*[\(label)]*", false)

        case let .formula(latex):
            return ("$$\n\(latex)\n$$", false)
        }
    }

    // MARK: - Tables

    private static func renderTable(_ rows: [[Cell]], headerRows: Int) -> String {
        guard !rows.isEmpty else { return "" }
        _ = headerRows
        if isSimpleGrid(rows) {
            return pipeTable(rows)
        }
        return rawTable(rows)
    }

    /// A grid a GFM pipe table can hold: rectangular, no merged cells, and every cell's content is
    /// plain paragraph text (no nested table, list, image, or formula inside a cell).
    private static func isSimpleGrid(_ rows: [[Cell]]) -> Bool {
        let widths = Set(rows.map { $0.count })
        guard widths.count == 1, let width = widths.first, width > 0 else { return false }
        for row in rows {
            for cell in row {
                if cell.rowSpan != 1 || cell.colSpan != 1 { return false }
                for b in cell.blocks {
                    if case .paragraph = b { continue }
                    return false
                }
            }
        }
        return true
    }

    private static func pipeTable(_ rows: [[Cell]]) -> String {
        let width = rows[0].count
        func rowLine(_ row: [Cell]) -> String {
            "| " + row.map { cellInline($0) }.joined(separator: " | ") + " |"
        }
        // GFM requires a header row + a delimiter line. The office model may report `headerRows == 0`
        // (an un-styled table — see `OfficeBlock.table`'s doc), but a pipe table has no "no header"
        // form, so row 0 becomes the header and every other row is body. No cell is dropped.
        var lines = [rowLine(rows[0]),
                     "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"]
        for row in rows.dropFirst() { lines.append(rowLine(row)) }
        return lines.joined(separator: "\n")
    }

    private static func rawTable(_ rows: [[Cell]]) -> String {
        var lines = [rawOpen, "[table — merged cells or block content; structure not mapped, cells below are literal]"]
        for row in rows {
            lines.append(row.map { plainCell($0) }.joined(separator: " | "))
        }
        lines.append(rawClose)
        return lines.joined(separator: "\n")
    }

    private static func cellInline(_ cell: Cell) -> String {
        var parts: [String] = []
        for b in cell.blocks {
            if case let .paragraph(spans, _, _, _, _) = b {
                let s = inline(spans, inCell: true)
                if !s.isEmpty { parts.append(s) }
            }
        }
        return parts.joined(separator: " ")
    }

    private static func plainCell(_ cell: Cell) -> String {
        cell.blocks.map { plainBlock($0) }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Inline spans

    private static func inline(_ spans: [Span], inCell: Bool) -> String {
        coalesced(spans).map { span($0, inCell: inCell) }.joined()
    }

    /// Undoes `FontSubstitutionResolver`'s read-time span splitting before any Markdown delimiter is
    /// emitted. That resolver cuts one logical run into several `Span`s purely so `OfficeTextBuilder`
    /// can assign each piece its own on-screen substitute FONT (invariant 37/§`docs/font-substitution
    /// -cost-design.md`) — a rendering concern this serializer has no notion of and must not leak
    /// through: `span(_:inCell:)` wraps EVERY `Span` in its own delimiters, so two adjacent pieces of
    /// one bold run that the resolver split (e.g. one Korean substitute for `‘18`, another for `년`)
    /// would otherwise close and reopen `**…**` between them, corrupting the Markdown an AI receives
    /// (`**'18****년**`) and the code/link fencing the same way. Two adjacent spans are merged back
    /// into one when they are equal in EVERY field this serializer or a future one could read except
    /// `text` and `resolvedFontDescriptor` — which is exactly the shape the resolver's split leaves
    /// behind, since it only ever divides one source `Span` into contiguous pieces with everything
    /// but those two fields copied verbatim.
    private static func coalesced(_ spans: [Span]) -> [Span] {
        guard spans.count > 1 else { return spans }
        var out: [Span] = []
        out.reserveCapacity(spans.count)
        for s in spans {
            if let last = out.last, sameMarkdownIdentity(last, s) {
                out[out.count - 1].text += s.text
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// `a` and `b` came from ONE span before font-substitution resolution split it iff clearing the
    /// two fields that split is allowed to change (`text`, `resolvedFontDescriptor`) makes them
    /// equal.
    private static func sameMarkdownIdentity(_ a: Span, _ b: Span) -> Bool {
        var x = a; x.text = ""; x.resolvedFontDescriptor = nil
        var y = b; y.text = ""; y.resolvedFontDescriptor = nil
        return x == y
    }

    private static func span(_ s: Span, inCell: Bool) -> String {
        guard !s.text.isEmpty else { return "" }
        if s.code {
            // Inline code is verbatim — no other Markdown applies inside it. Bump the fence past any
            // backticks the code itself contains so it can't close early.
            let ticks = String(repeating: "`", count: longestBacktickRun(s.text) + 1)
            let pad = (s.text.first == "`" || s.text.last == "`") ? " " : ""
            return ticks + pad + s.text + pad + ticks
        }
        var t = escapeText(s.text, inCell: inCell)
        if s.strikethrough { t = "~~\(t)~~" }
        if s.bold && s.italic { t = "***\(t)***" }
        else if s.bold { t = "**\(t)**" }
        else if s.italic { t = "*\(t)*" }
        if let link = s.link, !link.trimmingCharacters(in: .whitespaces).isEmpty {
            t = "[\(t)](\(link))"
        }
        return t
    }

    /// Minimal, per policy: fold hard newlines to spaces (a span is inline, not a block), and inside
    /// a pipe-table cell escape `|` so a literal bar can't split the column. Prose keeps its literal
    /// `*`/`#`/`_` — an AI reader tolerates that far better than an over-escaped wall of backslashes.
    private static func escapeText(_ text: String, inCell: Bool) -> String {
        var t = text.replacingOccurrences(of: "\n", with: " ")
        if inCell { t = t.replacingOccurrences(of: "|", with: "\\|") }
        return t
    }

    private static func longestBacktickRun(_ s: String) -> Int {
        var longest = 0, cur = 0
        for ch in s {
            if ch == "`" { cur += 1; longest = max(longest, cur) } else { cur = 0 }
        }
        return longest
    }

    // MARK: - Plain-text extraction (for <raw> dumps)

    private static func plainBlock(_ block: OfficeBlock) -> String {
        switch block {
        case let .heading(_, spans, _, _, _, _): return spans.map(\.text).joined()
        case let .paragraph(spans, _, _, _, _): return spans.map(\.text).joined()
        case let .listItem(_, _, spans, _, _, _, _, _): return spans.map(\.text).joined()
        case let .table(rows, _, _, _):
            return rows.map { $0.map { plainCell($0) }.joined(separator: " | ") }.joined(separator: "\n")
        case let .image(id, _, _): return "[image \(id)]"
        case let .unsupportedGraphic(label, _, _): return "[\(label)]"
        case let .formula(latex): return latex
        }
    }
}
