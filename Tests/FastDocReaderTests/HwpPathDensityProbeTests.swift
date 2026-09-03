import XCTest
import AppKit
@testable import FastDocReader

/// Compares the preserved Swift HWP reader with the shipping Rust reader at one identical TextKit
/// boundary. `FMD_HWP_PATH_DENSITY=<document>`; skipped by default.
final class HwpPathDensityProbeTests: XCTestCase {
    func testReaderPathDensity() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_HWP_PATH_DENSITY"] else {
            throw XCTSkip("set FMD_HWP_PATH_DENSITY=<document>")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let swift = try HwpReader.read(data)
        let rust = try XCTUnwrap(RustEngine.readOffice(data, extension: url.pathExtension.lowercased()))
            .resolvingFontSubstitution()
        summarize("swift", swift.blocks)
        summarize("rust", rust.blocks)
        measure("swift", swift)
        measure("rust", rust)
        var rustWithoutHeight = rust
        rustWithoutHeight.blocks = stripDeclaredHeights(rust.blocks)
        measure("rust-no-declared-height", rustWithoutHeight)
    }

    private func stripDeclaredHeights(_ blocks: [OfficeBlock]) -> [OfficeBlock] {
        blocks.map { block in
            guard case let .table(rows, headerRows, columnWidths, format) = block else { return block }
            let stripped = rows.map { row in row.map { source in
                var cell = source
                cell.declaredHeight = nil
                cell.blocks = stripDeclaredHeights(cell.blocks)
                return cell
            }}
            return .table(rows: stripped, headerRows: headerRows,
                          columnWidths: columnWidths, format: format)
        }
    }

    private func summarize(_ name: String, _ blocks: [OfficeBlock]) {
        var paragraphs = 0, cells = 0
        var before: CGFloat = 0, after: CGFloat = 0, linePoints: CGFloat = 0
        var exact = 0, least = 0, multiple = 0, unset = 0
        var padding: CGFloat = 0, declaredHeight: CGFloat = 0
        var fonts: [String: Int] = [:], resolved: [String: Int] = [:]
        func spans(_ values: [Span]) {
            for span in values {
                fonts[span.fontName ?? "(nil)", default: 0] += span.text.utf16.count
                let postscript = span.resolvedFontDescriptor?
                    .object(forKey: .name) as? String ?? "(nil)"
                resolved[postscript, default: 0] += span.text.utf16.count
            }
        }
        func format(_ f: ParagraphFormat) {
            paragraphs += 1; before += f.spacingBefore ?? 0; after += f.spacingAfter ?? 0
            switch f.lineHeight {
            case let .exact(v): exact += 1; linePoints += v
            case let .atLeast(v): least += 1; linePoints += v
            case let .multiple(v): multiple += 1; linePoints += v
            case nil: unset += 1
            }
        }
        func walk(_ xs: [OfficeBlock]) {
            for block in xs {
                switch block {
                case let .paragraph(s, _, _, _, f): spans(s); format(f)
                case let .heading(_, s, _, _, _, f): spans(s); format(f)
                case let .listItem(_, _, s, _, _, _, _, f, _): spans(s); format(f)
                case let .table(rows, _, _, _):
                    for row in rows { for cell in row {
                        cells += 1
                        let e = cell.edgePadding
                        padding += (e?.top ?? 0) + (e?.left ?? 0) + (e?.bottom ?? 0) + (e?.right ?? 0)
                        declaredHeight += cell.declaredHeight ?? 0
                        walk(cell.blocks)
                    }}
                default: break
                }
            }
        }
        walk(blocks)
        print(String(format: "HWP_PATH_MODEL %@ paras=%d before=%.0f after=%.0f lineSum=%.0f exact=%d least=%d multiple=%d unset=%d cells=%d padding=%.0f declaredHeight=%.0f",
                     name, paragraphs, before, after, linePoints, exact, least, multiple, unset,
                     cells, padding, declaredHeight))
        print("HWP_PATH_FONTS \(name) declared=" + fonts.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key):\($0.value)" }.joined(separator: ","))
        print("HWP_PATH_FONTS \(name) resolved=" + resolved.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key):\($0.value)" }.joined(separator: ","))
    }

    private func measure(_ name: String, _ result: OfficeReadResult) {
        let width = result.pageContentWidth ?? 400
        let text = OfficeTextBuilder.build(
            result.blocks,
            theme: RenderTheme.current(size: result.defaultBodyFontSize),
            columnWidth: width,
            documentDefaultFontSize: result.defaultBodyFontSize,
            pageContentWidth: width,
            pageMarginRight: result.pageMarginRight,
            tableWidth: width,
            lineGridPitch: result.lineGridPitch,
            pageContentHeight: result.pageContentHeight
        )
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var lines = 0
        var height: CGFloat = 0
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            lines += 1
            height += rect.height
            glyph = range.length > 0 ? NSMaxRange(range) : glyph + 1
        }
        print(String(format: "HWP_PATH_DENSITY %@ blocks=%d chars=%d lines=%d summedHeight=%.0f width=%.2f",
                     name, result.blocks.count, text.length, lines, height, width))
    }
}
