#if FMD_RUST_ENGINE
import Foundation
import CFastdocEngine

/// S5B2a: the arithmetic behind `TableBlockBuilder.resizeTables`, answered by the Rust engine —
/// HOST TO RUST, the opposite direction from `RustEngine`'s own calls (there the engine reads a
/// document and hands the host an answer; here the host already holds the live `NSTextStorage`
/// and asks the engine to do the subtraction for one table at a time).
///
/// NOT wired into the production reflow path. `TableBlockBuilder.resizeTables` still computes and
/// writes its own answer — this type exists only so a test can compare the two, catching a wrong
/// payload shape now, before S5B2b removes the Rust side's `todo!()` and makes the two paths one.
enum RustEngineTableResize {
    /// One cell's own geometry — `TableBlockBuilder.resizeTables`'s four `block.width(for:edge:)`
    /// reads plus the span that picks its slice of the shared grid.
    struct Cell {
        var startingColumn: Int
        var columnSpan: Int
        var padLeft: CGFloat
        var padRight: CGFloat
        var borderLeft: CGFloat
        var borderRight: CGFloat
    }

    /// Asks the engine for each `cells[i]`'s target content width, in the same order they were
    /// given. Returns nil if the engine could not answer (a bad payload, named by
    /// `fastdoc_take_last_error`) — never a partial or best-effort array.
    static func targetWidths(
        columnProportions: [CGFloat], availableWidth: CGFloat,
        outerMarginLeft: CGFloat, outerMarginRight: CGFloat, maxWidth: CGFloat?,
        cells: [Cell]
    ) -> [CGFloat]? {
        // `UnsafePointer<CGFloat>` and `UnsafePointer<Double>` are distinct pointer types to Swift
        // even where `CGFloat` and `Double` are the same width — the raw C ABI wants `Double`.
        let props: [Double] = columnProportions.map { Double($0) }
        let ffiCells = cells.map {
            FastdocTableResizeCell(
                starting_column: $0.startingColumn, column_span: $0.columnSpan,
                pad_left: Double($0.padLeft), pad_right: Double($0.padRight),
                border_left: Double($0.borderLeft), border_right: Double($0.borderRight))
        }
        var out = [Double](repeating: 0, count: cells.count)
        let ok = props.withUnsafeBufferPointer { propsBuf in
            ffiCells.withUnsafeBufferPointer { cellsBuf in
                out.withUnsafeMutableBufferPointer { outBuf in
                    fastdoc_table_resize_cell_widths(
                        propsBuf.baseAddress, propsBuf.count,
                        Double(availableWidth), Double(outerMarginLeft), Double(outerMarginRight),
                        Double(maxWidth ?? 0),
                        cellsBuf.baseAddress, cellsBuf.count,
                        outBuf.baseAddress)
                }
            }
        }
        guard ok else { return nil }
        return out.map { CGFloat($0) }
    }
}
#endif
