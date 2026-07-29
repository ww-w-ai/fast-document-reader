import AppKit

/// Measures the vertical space a document's running header + footer actually occupy when built by
/// THIS reader's own `OfficeTextBuilder` — never the document's declared header/footer OFFSET.
/// header-footer-design.md §4 is explicit about why: "the space has to fit the header as this
/// reader renders it, and if our rendering is taller the header lands on top of the body text." So
/// the band is measured, not read from the file, and it needs no new parsing.
///
/// Consumed by `PageBandLayoutDelegate`, which reserves this much space between one page's text and
/// the next's (header-footer-design.md build step 4 — geometry only; painting the header/footer
/// into the space this reserves is step 5, not yet built).
enum PageBandGeometry {
    /// The gap between one page's footer and the next page's header. No `RenderTheme` token exists
    /// for "space between pages" (its ratios are all body-text rhythm — line height, paragraph
    /// spacing, indent), so this is a small fixed placeholder pending step 5's visual pass, not a
    /// value derived from the document itself.
    static let gap: CGFloat = 12

    /// `headerHeight + footerHeight + gap`, or exactly `0` when both measure empty — a document
    /// with no running header or footer must reserve nothing at all (see
    /// `PageBandLayoutDelegate.isActive`, which gates on this being `> 0`, and header-footer-
    /// design.md's own "a document with no header and no footer has band 0 and MUST behave exactly
    /// as it does today").
    ///
    /// Only the entry that applies to every ordinary page (`.defaultPages`) is measured;
    /// `.firstPage`/`.evenPages` are deferred past v1 (header-footer-design.md §7 — even/odd
    /// headers and a first-page cover are both "after v1"), so measuring the one that actually
    /// repeats on most pages is the honest number for now, not an oversight.
    ///
    /// Builds through the SAME `OfficeTextBuilder` the document's own body uses — never a second,
    /// divergent rendering path (invariant 29's discipline) — laid out once in an ISOLATED stack
    /// (its own storage/layout manager/container), so measuring never touches or invalidates the
    /// real text view.
    static func bandHeight(headers: [OfficeHeaderFooter], footers: [OfficeHeaderFooter],
                           theme: RenderTheme, columnWidth: CGFloat,
                           documentDefaultFontSize: CGFloat, pageContentWidth: CGFloat?) -> CGFloat {
        let h = measuredHeight(of: headers, theme: theme, columnWidth: columnWidth,
                               documentDefaultFontSize: documentDefaultFontSize,
                               pageContentWidth: pageContentWidth)
        let f = measuredHeight(of: footers, theme: theme, columnWidth: columnWidth,
                               documentDefaultFontSize: documentDefaultFontSize,
                               pageContentWidth: pageContentWidth)
        guard h > 0 || f > 0 else { return 0 }
        return h + f + gap
    }

    /// The header height, the footer height, AND the combined band — measured together so a caller
    /// building the PAINTING context (`PageBandPainter`, build step 5) doesn't measure header+footer
    /// twice: once for `bandHeight` (how much space to RESERVE) and again for how tall each side is
    /// (where to PAINT it). `band` here is the same number `bandHeight(...)` returns for identical
    /// inputs — `PageBandReservationTests` proves that identity — but this is an ADDITIVE surface:
    /// `bandHeight` itself is untouched (same private `measuredHeight` calls, same tests judge it
    /// directly), so nothing already shipped is at risk of a change here.
    struct Sides: Equatable {
        var header: CGFloat
        var footer: CGFloat
        var band: CGFloat
    }

    static func measure(headers: [OfficeHeaderFooter], footers: [OfficeHeaderFooter],
                        theme: RenderTheme, columnWidth: CGFloat,
                        documentDefaultFontSize: CGFloat, pageContentWidth: CGFloat?) -> Sides {
        let h = measuredHeight(of: headers, theme: theme, columnWidth: columnWidth,
                               documentDefaultFontSize: documentDefaultFontSize,
                               pageContentWidth: pageContentWidth)
        let f = measuredHeight(of: footers, theme: theme, columnWidth: columnWidth,
                               documentDefaultFontSize: documentDefaultFontSize,
                               pageContentWidth: pageContentWidth)
        let band = (h > 0 || f > 0) ? h + f + gap : 0
        return Sides(header: h, footer: f, band: band)
    }

    /// One side (headers OR footers) of `bandHeight`, isolated so the additive structure
    /// (`headerOnly + footerOnly - gap == both`) is independently testable without re-deriving font
    /// metrics in the test itself.
    private static func measuredHeight(of entries: [OfficeHeaderFooter], theme: RenderTheme,
                                        columnWidth: CGFloat, documentDefaultFontSize: CGFloat,
                                        pageContentWidth: CGFloat?) -> CGFloat {
        guard columnWidth.isFinite, columnWidth > 0 else { return 0 }
        guard let entry = entries.first(where: { $0.appliesTo == .defaultPages }) ?? entries.first,
              !entry.blocks.isEmpty else { return 0 }
        let attr = OfficeTextBuilder.build(entry.blocks, theme: theme,
                                           columnWidth: columnWidth,
                                           documentDefaultFontSize: documentDefaultFontSize,
                                           pageContentWidth: pageContentWidth)
        guard attr.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }
}
