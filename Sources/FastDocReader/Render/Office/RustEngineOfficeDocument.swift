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

    /// S5C3-04: `MasterPagePainter.applicablePage` plus the section veto (`:73`), ported to Rust
    /// (`master_page_selection`) and answered batched over every VISIBLE page `draw(_:sheets:…)`
    /// assembles — one crossing per draw pass, matching every other query on this page. `nil` —
    /// no handle, or a bad payload (`RustEngineMeasure.lastErrorKind()` names which) — is
    /// `MasterPagePainter.draw`'s own signal to fall back to `applicablePage` for the whole batch,
    /// the same failure direction S5C-1 established for every query above.
    ///
    /// A `nil` ENTRY inside the returned array is a real answer, not a failure: it is the engine's
    /// own "-1, no template applies" (no candidates for the page's section, or the section is
    /// vetoed) — `applicablePage`'s own `nil` return, not a gap for the host to fill in.
    func masterTemplateSelection(
        templates: [OfficeMasterPage], vetoedSections: Set<Int>,
        pages: [(pageIndex: Int, section: Int?)]
    ) -> [Int?]? {
        guard !pages.isEmpty else { return [] }
        let ffiTemplates = templates.map {
            FastdocMasterTemplateDesc(section: Int64($0.section), applies_to: $0.appliesTo.wireTag)
        }
        let ffiVetoed = vetoedSections.map(Int64.init)
        let ffiPages = pages.map {
            FastdocMasterPageQuery(page_index: Int64($0.pageIndex), has_section: $0.section != nil,
                                   section: Int64($0.section ?? 0))
        }
        var out = [Int64](repeating: -1, count: pages.count)
        let answered = ffiTemplates.withUnsafeBufferPointer { templatesBuf in
            ffiVetoed.withUnsafeBufferPointer { vetoedBuf in
                ffiPages.withUnsafeBufferPointer { pagesBuf in
                    out.withUnsafeMutableBufferPointer { outBuf in
                        fastdoc_office_master_selection(
                            templatesBuf.baseAddress, templatesBuf.count,
                            vetoedBuf.baseAddress, vetoedBuf.count,
                            pagesBuf.baseAddress, pagesBuf.count,
                            outBuf.baseAddress, outBuf.count)
                    }
                }
            }
        }
        guard answered else { return nil }
        answeredQueries += 1
        return out.map { $0 >= 0 ? Int($0) : nil }
    }
    /// S5D1-03: `FootnoteBandSettle.step` plus the proposal arithmetic that feeds it
    /// (`PageBandGeometry.footnoteBandHeight`/`FootnotePainter.separatorAllowance`), answered by
    /// the engine for ONE settle round (`s5d1.md`'s "the ANSWERS move, the host still supplies the
    /// heights" row). `nil` — no handle, or a bad payload (`RustEngineMeasure.lastErrorKind()`
    /// names which) — is `settleFootnoteBands`'s own signal to fall back to the host's own
    /// `FootnoteBandSettle.step` for the whole round, the same failure direction S5C-1 established
    /// for every query on this page.
    ///
    /// `pages` is this round's proposal inputs, one entry per page this round is proposing a band
    /// for — `(pageIndex, noteHeights, separator)`, the separator already RESOLVED
    /// (`footnoteSeparator(forPage:)`) rather than asked of the engine — `s5d1.md`: "The engine
    /// must never be asked to resolve it." `history` is every earlier round's proposal, oldest
    /// first, exactly as `footnoteBandHistory` already holds it. `pageContentHeight`/`cap` mirror
    /// `FootnoteBandSettle.clamped`/`step`'s own scalars.
    func footnoteBandSettle(
        pages: [(pageIndex: Int, noteHeights: [CGFloat], separator: OfficeFootnoteSeparator?)],
        history: [[Int: CGFloat]], pageContentHeight: CGFloat, cap: Int
    ) -> FootnoteBandSettle.Outcome? {
        var flatHeights: [Double] = []
        var ffiPages: [FastdocFootnotePageDesc] = []
        ffiPages.reserveCapacity(pages.count)
        for page in pages {
            let offset = flatHeights.count
            flatHeights.append(contentsOf: page.noteHeights.map(Double.init))
            let sep = page.separator
            ffiPages.append(FastdocFootnotePageDesc(
                page_index: Int64(page.pageIndex), note_offset: offset, note_count: page.noteHeights.count,
                has_separator: sep != nil, separator_is_declared: sep?.isDeclared ?? false,
                separator_line_type: Int64(sep?.lineType ?? 0), separator_line_width_pt: Double(sep?.lineWidthPt ?? 0),
                separator_margin_top_pt: Double(sep?.marginTopPt ?? 0), separator_margin_bottom_pt: Double(sep?.marginBottomPt ?? 0),
                separator_note_spacing_pt: Double(sep?.noteSpacingPt ?? 0)))
        }
        var flatHistoryEntries: [FastdocNoteBandEntry] = []
        var ffiRounds: [FastdocFootnoteHistoryRoundDesc] = []
        ffiRounds.reserveCapacity(history.count)
        for round in history {
            let offset = flatHistoryEntries.count
            flatHistoryEntries.append(contentsOf: round.map {
                FastdocNoteBandEntry(page: Int64($0.key), value: Double($0.value))
            })
            ffiRounds.append(FastdocFootnoteHistoryRoundDesc(
                entry_offset: offset, entry_count: flatHistoryEntries.count - offset))
        }
        // A safe upper bound (the FFI doc's own statement): the settle registers at most one
        // band per page proposed this round.
        let capacity = max(pages.count, 1)
        var outBands = [FastdocNoteBandEntry](repeating: FastdocNoteBandEntry(page: 0, value: 0), count: capacity)
        var outCount = 0
        var outOutcome: Int32 = -1
        var outStopReason: Int32 = -1
        let answered = ffiPages.withUnsafeBufferPointer { pagesBuf in
            flatHeights.withUnsafeBufferPointer { heightsBuf in
                ffiRounds.withUnsafeBufferPointer { roundsBuf in
                    flatHistoryEntries.withUnsafeBufferPointer { entriesBuf in
                        outBands.withUnsafeMutableBufferPointer { outBuf -> Bool in
                            withUnsafeMutablePointer(to: &outCount) { outCountPtr in
                                withUnsafeMutablePointer(to: &outOutcome) { outOutcomePtr in
                                    withUnsafeMutablePointer(to: &outStopReason) { outStopReasonPtr in
                                        fastdoc_office_footnote_band_settle(
                                            pagesBuf.baseAddress, pagesBuf.count,
                                            heightsBuf.baseAddress, heightsBuf.count,
                                            roundsBuf.baseAddress, roundsBuf.count,
                                            entriesBuf.baseAddress, entriesBuf.count,
                                            Double(pageContentHeight), Int64(cap),
                                            outBuf.baseAddress, outBuf.count, outCountPtr,
                                            outOutcomePtr, outStopReasonPtr)
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
        var bands: [Int: CGFloat] = [:]
        for i in 0..<outCount {
            bands[Int(outBands[i].page)] = CGFloat(outBands[i].value)
        }
        if outOutcome == 0 { return .retry(bands) }
        let reason: FootnoteBandSettle.StopReason
        switch outStopReason {
        case 1: reason = .cycle
        case 2: reason = .cap
        default: reason = .still
        }
        return .stop(bands, reason)
    }

}

private extension HeaderFooterApplicability {
    /// The wire tag `fastdoc_office_master_selection`'s own comment defines: `0` = `.defaultPages`,
    /// `1` = `.firstPage`, `2` = `.evenPages` — the same three-way vocabulary a master page shares
    /// with a running header/footer.
    var wireTag: Int32 {
        switch self {
        case .defaultPages: return 0
        case .firstPage: return 1
        case .evenPages: return 2
        }
    }
}
#endif
