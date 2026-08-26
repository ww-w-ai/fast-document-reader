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
}
#endif
