#if FMD_RUST_ENGINE
import CFastdocEngine
import Foundation

/// S5C1-01: a document the engine has already read, opened once through `fastdoc_office_open` and
/// closed exactly once through `fastdoc_office_close` — the cost `fastdoc_office_header_band_height`
/// pays on EVERY call (a re-read from bytes; 2.4s measured on a 10.2MB HWP in debug) is paid here
/// only at `init`, so every later query on this instance borrows the document instead of re-reading
/// it.
///
/// One owner, one close: the object that owns a document's lifetime (`MarkdownDocument`) holds this
/// in a stored property and lets ARC close it in `deinit` — never in a `defer` at a call site, which
/// is exactly the shape that would strand or double-close a handle across a reload's
/// close-then-reopen.
final class RustOfficeDocumentHandle {
    private let handle: OpaquePointer

    /// How many queries this handle has ANSWERED. Two implementations that agree numerically are
    /// indistinguishable by their answers, so a test cannot tell "the engine answered" from "the
    /// host's own formula answered" by comparing bands — measured: replacing the handle with `nil`
    /// at the live call site changed no number and passed the whole suite. This counter is what
    /// makes the call itself observable, the same role `TableBlockBuilder.resizeTables`'s returned
    /// write count plays for invariant 48.
    private(set) var answeredQueries = 0

    /// Opens `data` as `extension` through the engine. `nil` when the engine could not read this
    /// document — the SAME `read_office` failure `fastdoc_office_header_band_height` already
    /// reports, retrievable through `RustEngineMeasure.lastErrorKind()` immediately after this
    /// initializer returns `nil`.
    init?(data: Data, extension ext: String) {
        let opened: OpaquePointer? = data.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { extensionC in
                fastdoc_office_open(base, buffer.count, extensionC)
            }
        }
        guard let opened else { return nil }
        self.handle = opened
    }

    deinit {
        fastdoc_office_close(handle)
    }

    /// S5C1-02: the engine's own decision for this document's running header, footer and combined
    /// band, from the document this handle already holds — or `nil` when the engine could not
    /// answer (no measurer installed, or a band carrying something the engine cannot resolve;
    /// `RustEngineMeasure.lastErrorKind()` names which, read immediately after a `nil` return).
    ///
    /// The three page values are passed through exactly as the host has them — `nil` crosses as
    /// "the host never stated one" (a `has_*` flag, not a value folded into a sentinel), never
    /// silently substituted for a value the host actually passed (S5C1's own fact 2). `headersOn`/
    /// `footersOn` mirror `PageViewOptions`: off crosses as NO ENTRIES on the engine side, exactly
    /// as the host's own `applyPageBand` already treats a hidden header/footer.
    /// `separatesPages`/`deskGap` mirror `PageBandGeometry.measure`'s own two page-outline
    /// parameters exactly — dropping either at this boundary would answer a plausible-looking
    /// band that is silently short by `RenderTheme.pageDeskGap` whenever the View menu's outline
    /// is on, or by the wrong amount whenever printing overrides the gap to zero.
    func bandSides(
        columnWidth: CGFloat, pageContentWidth: CGFloat?, pageMarginTop: CGFloat?,
        pageMarginBottom: CGFloat?, headersOn: Bool, footersOn: Bool,
        separatesPages: Bool, deskGap: CGFloat?
    ) -> PageBandGeometry.Sides? {
        var out: [Double] = [0, 0, 0]
        let answered = out.withUnsafeMutableBufferPointer { buffer -> Bool in
            fastdoc_office_band_sides(
                handle, Double(columnWidth),
                Double(pageContentWidth ?? 0), pageContentWidth != nil,
                Double(pageMarginTop ?? 0), pageMarginTop != nil,
                Double(pageMarginBottom ?? 0), pageMarginBottom != nil,
                headersOn, footersOn, separatesPages,
                Double(deskGap ?? 0), deskGap != nil, buffer.baseAddress)
        }
        guard answered else { return nil }
        answeredQueries += 1
        return PageBandGeometry.Sides(header: CGFloat(out[0]), footer: CGFloat(out[1]), band: CGFloat(out[2]))
    }

    /// S5C2-01: every SHEET a paged document prints as — `printSheets`'s own arithmetic, from the
    /// scalars it already resolves (`pitch` and `topMargin` are scalar addition/`max` and stay
    /// host-side; the plan states why). `nil` when the engine could not answer (a bad payload —
    /// `RustEngineMeasure.lastErrorKind()` names which) or `count <= 0`, matching
    /// `PagePagination.sheets`'s own empty-array answer for a non-positive count.
    func sheets(
        count: Int, width: CGFloat, textOriginY: CGFloat, leadingBand: CGFloat,
        pitch: CGFloat, topMargin: CGFloat, deskGap: CGFloat
    ) -> [CGRect]? {
        guard count > 0 else { return [] }
        var raw = [Double](repeating: 0, count: count * 4)
        var outCount = 0
        let answered = raw.withUnsafeMutableBufferPointer { buffer -> Bool in
            withUnsafeMutablePointer(to: &outCount) { countPtr in
                fastdoc_office_sheets(
                    handle, Int64(count), Double(width), Double(textOriginY), Double(leadingBand),
                    Double(pitch), Double(topMargin), Double(deskGap),
                    buffer.baseAddress, buffer.count, countPtr)
            }
        }
        guard answered else { return nil }
        answeredQueries += 1
        var out: [CGRect] = []
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            out.append(CGRect(x: raw[i * 4], y: raw[i * 4 + 1], width: raw[i * 4 + 2], height: raw[i * 4 + 3]))
        }
        return out
    }

    /// S5C2-01: which tables must move whole to the next page and which pieces fit on no page at
    /// all — `settlePagedTables`'s arithmetic half (`tables_to_push`/`oversized_pieces`), from a
    /// completed layout the host already walked (`laidOutTables()`). `nil` when the engine could
    /// not answer — the host falls back to its own `PagePagination` arithmetic at the call site,
    /// the same failure direction S5C-1 established for the band query.
    func tablePlacement(
        tables: [PagePagination.LaidOutTable], pageContentHeight: CGFloat, band: CGFloat,
        leadingBand: CGFloat, splitTables: Bool,
        alreadyPushed: [Int: PagePagination.TableMetrics], noteBands: [Int: CGFloat],
        alreadyOversized: [Int: Int]
    ) -> (pushed: [Int: PagePagination.TableMetrics], oversized: [Int: Int])? {
        var ffiRows: [FastdocLaidOutRow] = []
        ffiRows.reserveCapacity(tables.reduce(0) { $0 + $1.rows.count })
        var ffiTables: [FastdocLaidOutTable] = []
        ffiTables.reserveCapacity(tables.count)
        for t in tables {
            let rowOffset = ffiRows.count
            for r in t.rows {
                ffiRows.append(FastdocLaidOutRow(
                    first_char: Int64(r.firstChar), top: Double(r.top), bottom: Double(r.bottom),
                    first_line_top: Double(r.firstLineTop), can_break_above: r.canBreakAbove))
            }
            ffiTables.append(FastdocLaidOutTable(
                first_char: Int64(t.firstChar), visual_top: Double(t.visualTop),
                bottom: Double(t.bottom), first_line_top: Double(t.firstLineTop),
                last_char: Int64(t.lastChar), row_offset: rowOffset, row_count: t.rows.count,
                keeps_whole: t.keepsWhole))
        }
        let ffiAlreadyPushed = alreadyPushed.map {
            FastdocTableMetricsEntry(key: Int64($0.key), height: Double($0.value.height),
                                     top_inset: Double($0.value.topInset))
        }
        let ffiNoteBands = noteBands.map {
            FastdocNoteBandEntry(page: Int64($0.key), value: Double($0.value))
        }
        let ffiAlreadyOversized = alreadyOversized.map {
            FastdocI64Entry(key: Int64($0.key), value: Int64($0.value))
        }
        // A safe upper bound for BOTH outputs (the FFI doc's own statement): `tablesToPush`/
        // `oversizedPieces` each register at most one entry per unbreakable group, at most one
        // per row, plus the already-carried keys.
        let capacity = max(ffiTables.count + ffiRows.count, 1)
        var outPush = [FastdocTableMetricsEntry](
            repeating: FastdocTableMetricsEntry(key: 0, height: 0, top_inset: 0), count: capacity)
        var outOversized = [FastdocI64Entry](
            repeating: FastdocI64Entry(key: 0, value: 0), count: capacity)
        var outPushCount = 0
        var outOversizedCount = 0

        let answered = ffiTables.withUnsafeBufferPointer { tablesBuf in
            ffiRows.withUnsafeBufferPointer { rowsBuf in
                ffiAlreadyPushed.withUnsafeBufferPointer { pushBuf in
                    ffiNoteBands.withUnsafeBufferPointer { noteBuf in
                        ffiAlreadyOversized.withUnsafeBufferPointer { oversizedBuf in
                            outPush.withUnsafeMutableBufferPointer { outPushBuf in
                                outOversized.withUnsafeMutableBufferPointer { outOversizedBuf -> Bool in
                                    withUnsafeMutablePointer(to: &outPushCount) { outPushCountPtr in
                                        withUnsafeMutablePointer(to: &outOversizedCount) { outOversizedCountPtr in
                                            fastdoc_office_table_placement(
                                                handle,
                                                tablesBuf.baseAddress, tablesBuf.count,
                                                rowsBuf.baseAddress, rowsBuf.count,
                                                Double(pageContentHeight), Double(band), Double(leadingBand),
                                                splitTables,
                                                pushBuf.baseAddress, pushBuf.count,
                                                noteBuf.baseAddress, noteBuf.count,
                                                oversizedBuf.baseAddress, oversizedBuf.count,
                                                outPushBuf.baseAddress, outPushBuf.count, outPushCountPtr,
                                                outOversizedBuf.baseAddress, outOversizedBuf.count,
                                                outOversizedCountPtr)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard answered else { return nil }
        answeredQueries += 1
        var pushed: [Int: PagePagination.TableMetrics] = [:]
        for i in 0..<outPushCount {
            let e = outPush[i]
            pushed[Int(e.key)] = PagePagination.TableMetrics(height: CGFloat(e.height), topInset: CGFloat(e.top_inset))
        }
        var oversized: [Int: Int] = [:]
        for i in 0..<outOversizedCount {
            let e = outOversized[i]
            oversized[Int(e.key)] = Int(e.value)
        }
        return (pushed, oversized)
    }
}
#endif
