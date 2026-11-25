import CFastdocEngine
import Foundation

/// S5C1-01: a document the engine has already read, opened once through `fastdoc_office_open` and
/// closed exactly once through `fastdoc_office_close` — the cost of reading the bytes (2.4s measured
/// on a 10.2MB HWP in debug) is paid only at `init`, so every later query on this instance borrows the document instead of re-reading
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
    /// document — the SAME `read_office` failure every engine read reports, retrievable through `RustEngineMeasure.lastErrorKind()` immediately after this
    /// initializer returns `nil`.
    init?(data: Data, extension ext: String) {
        // The two process-global ports every query through this handle depends on, installed by
        // the side that OPENS the handle rather than left to call order. Both are idempotent.
        //
        // Measured, not assumed: with neither installed, opening a real `.hwp` succeeds and the
        // first band query PANICS inside the engine (`swiftshim/src/font_provider.rs:133`), which
        // `guard_scalar` turns into a refusal — so the reader silently answers from its own
        // arithmetic and the engine is never actually asked anything. That is the state the app
        // shipped in for HWP: `DocumentTypes` branches to `HwpReader` (`DocumentTypes.swift:121`)
        // BEFORE `RustEngine.readOffice`, which is the only place that installed the font world,
        // and nothing in `Sources/` installed the measurer at all. HWP is also the only format
        // whose footnotes reach `OfficeReadResult.footnotes`, so it is exactly the format the
        // footnote queries need.
        RustEngineFonts.install()
        RustEngineMeasure.install()
        let opened: OpaquePointer? = data.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { extensionC in
                fastdoc_office_open(base, buffer.count, extensionC)
            }
        }
        guard let opened else { return nil }
        RustEngine.noteDocumentRead()
        self.handle = opened
    }

    /// This document's content, in the app's own vocabulary, from the read this handle ALREADY
    /// paid for.
    ///
    /// P1: before this existed, `MarkdownDocument.read(from:)` asked `RustEngine.readOffice` for
    /// the content (a full read) and then opened a handle for the queries (the SAME full read
    /// again). Measured on `2025_행정업무운영편람_최종.hwp`: 565 ms thrown away per open, which is
    /// 47% of what the entire pre-cutover build spent producing that document's `--extract`.
    ///
    /// `data` must be the bytes this handle was opened from. The engine needs them only to record
    /// the source's own sha256 and length; nothing is re-parsed. Passing different bytes would
    /// therefore not answer a different document, it would mislabel this one — which is why the
    /// only caller is the one that just opened the handle from those same bytes.
    func officeContent(bytes data: Data) -> OfficeReadResult? {
        answeredQueries += 1
        // `fastdoc_office_tree_json` borrows the SAME parse this handle already paid for, so
        // P1's single-read guarantee holds.
        let json: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return fastdoc_office_tree_json(handle, base, raw.count)
        }
        guard let json else {
            // The same rule the other reader follows: record it, do not print it. Whoever asked for
            // this content decides what a person sees (`RustEngine.lastOfficeReadFailure`).
            RustEngine.recordOfficeReadFailure()
            return nil
        }
        defer { fastdoc_string_free(json) }
        return RustEngine.decodeOfficeTree(json)
    }

    /// One embedded picture's bytes, fetched from the parse this handle still holds.
    ///
    /// P2c: an `.hwp` has no archive, so the reader used to receive every picture's pixels inside
    /// the read's own payload — 109 of them on the 편람, 54 MB of the 78 MB it shipped, decoded
    /// whether or not any of them was ever on screen. This is the docx/odt shape for a format that
    /// could not have it before: the picture is fetched when something is about to draw it.
    ///
    /// `id` is the id the block itself carries, crop and all (`"hwpimg:3!crop=..."`), and the bytes
    /// come back already cropped — the engine resolves the id through the same code its read used,
    /// so a picture taken from here and one taken from a read are the same bytes.
    ///
    /// `nil` for a picture this document does not have, for a document that keeps no parse
    /// (docx/odt — their pictures come from the archive the host holds), and for one the document
    /// declared without bytes. All three mean the same thing to a caller: ask elsewhere.
    func picture(id: String) -> Data? {
        answeredQueries += 1
        guard let base64 = id.withCString({ fastdoc_office_image_base64(handle, $0) }) else {
            return nil
        }
        defer { fastdoc_string_free(base64) }
        return Data(base64Encoded: String(cString: base64))
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

    /// S5D-2: every footnote's own height, `[number: height]`, from a document this handle already
    /// holds — `PageBandGeometry::built_height`, called once per note and batched into ONE
    /// crossing (never once per note, S5C-3's own batch discipline). `nil` — no handle, or a bad
    /// payload (`RustEngineMeasure.lastErrorKind()` names which) — is `MarkdownDocument`'s own
    /// signal to fall back to its own `PageBandGeometry.builtHeight` loop, the same failure
    /// direction S5C-1 established for every query on this page.
    ///
    /// `count` sizes the reply buffer — the caller already knows how many footnotes its OWN parse
    /// holds (`officeFootnotes.count`), which may differ from how many this handle's parse holds
    /// (two independent reads of the same bytes, `s5d2.md`'s own risk section); the reply is keyed
    /// by NUMBER either way, so `PageBandGeometry.resolveNoteHeights` is what reconciles the two,
    /// not this call.
    func footnoteHeights(count: Int, columnWidth: CGFloat, pageContentWidth: CGFloat?,
                         documentDefaultFontSize: CGFloat) -> [Int: CGFloat]? {
        let capacity = max(count, 1)
        var out = [FastdocFootnoteHeightDesc](repeating: FastdocFootnoteHeightDesc(number: 0, height: 0),
                                              count: capacity)
        let filled = out.withUnsafeMutableBufferPointer { buf in
            fastdoc_office_footnote_heights(
                handle, Double(columnWidth), Double(pageContentWidth ?? 0), pageContentWidth != nil,
                Double(documentDefaultFontSize), buf.baseAddress, buf.count)
        }
        guard filled >= 0 else { return nil }
        answeredQueries += 1
        var result: [Int: CGFloat] = [:]
        result.reserveCapacity(Int(filled))
        for i in 0..<Int(filled) {
            result[Int(out[i].number)] = CGFloat(out[i].height)
        }
        return result
    }

}
