import Foundation
import CFastdocEngine

/// S5B2a: the arithmetic behind `TableBlockBuilder.resizeTables`, answered by the Rust engine —
/// HOST TO RUST, the opposite direction from `RustEngine`'s own calls (there the engine reads a
/// document and hands the host an answer; here the host already holds the live `NSTextStorage`
/// and asks the engine to do the subtraction for one table at a time).
///
/// WIRED INTO the production reflow path since S5B2b: `TableBlockBuilder.resizeTables` takes its
/// per-cell widths from here. The host's own formula (`localCellTargetWidth`) stays as the
/// independent reference a test checks this against, and as what `resizeTables` writes when this
/// cannot answer.
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

    /// Every table in one document, asked in ONE call — and built WITHOUT a per-table array on
    /// the way in. Measured on a 323-table, 6,077-cell document, the width-unchanged reflow path
    /// cost 5.2 ms with the host's own formula and 9.55 ms through a per-table crossing; splitting
    /// that gap showed the boundary itself was 0.35 ms of it, the intermediate payload arrays
    /// 1.6 ms and the collection 2.4 ms (`evidence/s5b2b-latency.md`). So the caller appends
    /// straight into the flat buffers the C ABI already wants: `beginTable` opens a table and
    /// every `addCell` after it belongs to that table, exactly as `TableBlockBuilder.resizeTables`
    /// walks them.
    struct BatchRequest {
        private var descriptors: [FastdocTableResizeTableDesc] = []
        private var proportions: [Double] = []
        private var cells: [FastdocTableResizeCell] = []

        /// The number of cells added so far — the size of the answer `solve` returns.
        var cellCount: Int { cells.count }

        mutating func reserve(tableCount: Int, cellCount: Int) {
            descriptors.reserveCapacity(tableCount)
            cells.reserveCapacity(cellCount)
        }

        /// Opens a table. Every `addCell` until the next `beginTable` counts toward this one.
        mutating func beginTable(
            columnProportions: [CGFloat], availableWidth: CGFloat,
            outerMarginLeft: CGFloat, outerMarginRight: CGFloat, maxWidth: CGFloat?
        ) {
            let columnOffset = proportions.count
            for proportion in columnProportions { proportions.append(Double(proportion)) }
            descriptors.append(
                FastdocTableResizeTableDesc(
                    column_offset: columnOffset, column_count: columnProportions.count,
                    available_width: Double(availableWidth),
                    outer_margin_left: Double(outerMarginLeft),
                    outer_margin_right: Double(outerMarginRight),
                    max_width: Double(maxWidth ?? 0),
                    cell_offset: cells.count, cell_count: 0))
        }

        /// Adds one cell to the table `beginTable` last opened. Calling it before any `beginTable`
        /// is a caller bug and is ignored rather than silently attributed to the wrong table.
        mutating func addCell(
            startingColumn: Int, columnSpan: Int, padLeft: CGFloat, padRight: CGFloat,
            borderLeft: CGFloat, borderRight: CGFloat
        ) {
            guard !descriptors.isEmpty else { return }
            cells.append(
                FastdocTableResizeCell(
                    starting_column: startingColumn, column_span: columnSpan,
                    pad_left: Double(padLeft), pad_right: Double(padRight),
                    border_left: Double(borderLeft), border_right: Double(borderRight)))
            descriptors[descriptors.count - 1].cell_count += 1
        }

        /// The target content width for every cell added, in the order they were added. Returns nil
        /// if the engine could not answer any part of the payload — never a partial array. The
        /// answer stays `Double`, the width the C ABI speaks, so answering 6,077 cells does not
        /// allocate a second array to say the same numbers in `CGFloat`.
        func solve() -> [Double]? {
            var out = [Double](repeating: 0, count: cells.count)
            let ok = descriptors.withUnsafeBufferPointer { descriptorsBuf in
                proportions.withUnsafeBufferPointer { propsBuf in
                    cells.withUnsafeBufferPointer { cellsBuf in
                        out.withUnsafeMutableBufferPointer { outBuf in
                            fastdoc_table_resize_cell_widths_batch(
                                descriptorsBuf.baseAddress, descriptorsBuf.count,
                                propsBuf.baseAddress, propsBuf.count,
                                cellsBuf.baseAddress, cellsBuf.count,
                                outBuf.baseAddress)
                        }
                    }
                }
            }
            guard ok else { return nil }
            return out
        }
    }
}
