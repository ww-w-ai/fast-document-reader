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
    /// The space a document itself puts between one page's last body line and the next page's
    /// first: its bottom margin plus the next page's top margin. Both are the PAPER margins — a
    /// running header lives inside the top one and a footer inside the bottom one, in all three
    /// formats — so this single number is exactly the band, already carrying the header and footer
    /// areas the document allowed for.
    ///
    /// This replaced a fixed 12pt "gap between pages" the reader invented, which is the mistake
    /// invariant 57 is about: the document had stated the answer and the app was filling in its own.
    /// On a real .odt the two agree to within a point (declared 85.10pt against the old measured
    /// 84.15pt), which is why the invented value looked plausible for as long as it did.
    ///
    /// Nil margins mean the document never said, and the band falls back to what this reader must
    /// draw — see `bandHeight`.
    static func declaredBand(marginTop: CGFloat?, marginBottom: CGFloat?) -> CGFloat {
        max(0, (marginTop ?? 0)) + max(0, (marginBottom ?? 0))
    }

    /// The document's own inter-page space (`declaredBand`) — but never less than the header and
    /// footer this reader actually draws, or they would land on top of the body text. Exactly `0`
    /// when both measure empty — a document
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
                           documentDefaultFontSize: CGFloat, pageContentWidth: CGFloat?,
                           pageMarginTop: CGFloat? = nil, pageMarginBottom: CGFloat? = nil) -> CGFloat {
        measure(headers: headers, footers: footers, theme: theme, columnWidth: columnWidth,
                documentDefaultFontSize: documentDefaultFontSize, pageContentWidth: pageContentWidth,
                pageMarginTop: pageMarginTop, pageMarginBottom: pageMarginBottom).band
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

    /// `separatesPages` — the reader is drawing each sheet as its own page
    /// (`PageViewOptions.outline`), so the space BETWEEN two sheets has to exist even when there is
    /// no header or footer to put in it. Without this a document with page furniture switched off but
    /// the outline on would draw its sheets edge to edge with no desk between them, which is not a
    /// stack of pages. Defaults to `false`, which is exactly the rule this function had before the
    /// toggles existed: no header and no footer means no band at all.
    static func measure(headers: [OfficeHeaderFooter], footers: [OfficeHeaderFooter],
                        theme: RenderTheme, columnWidth: CGFloat,
                        documentDefaultFontSize: CGFloat, pageContentWidth: CGFloat?,
                        pageMarginTop: CGFloat? = nil, pageMarginBottom: CGFloat? = nil,
                        separatesPages: Bool = false, deskGap: CGFloat? = nil) -> Sides {
        let h = measuredHeight(of: headers, theme: theme, columnWidth: columnWidth,
                               documentDefaultFontSize: documentDefaultFontSize,
                               pageContentWidth: pageContentWidth)
        let f = measuredHeight(of: footers, theme: theme, columnWidth: columnWidth,
                               documentDefaultFontSize: documentDefaultFontSize,
                               pageContentWidth: pageContentWidth)
        guard h > 0 || f > 0 || separatesPages else { return Sides(header: h, footer: f, band: 0) }
        // The document's own two margins when it stated them, and what this reader must draw when
        // that is taller — the max, not a sum, because the header and footer are drawn INSIDE those
        // margins rather than added to them. A document that never stated a margin falls back to the
        // drawn height alone, which is the honest minimum and what the two sides need.
        // …plus, when the reader is drawing SHEETS, the desk you can see between two of them. Two
        // stacked pieces of paper touch, so this is the one number in the band no document declares
        // and the reader has to (see `RenderTheme.pageDeskGap`, which explains why that is not
        // invariant 57(e)'s invented constant returning). It is NOT printed: `PagePagination` takes
        // it back off, so the paper is exactly the document's own sheet.
        let band = max(declaredBand(marginTop: pageMarginTop, marginBottom: pageMarginBottom), h + f)
            + (deskGap ?? (separatesPages ? RenderTheme.pageDeskGap : 0))
        return Sides(header: h, footer: f, band: band)
    }

    /// One side (headers OR footers) of `bandHeight`, isolated so the additive structure
    /// (`headerOnly + footerOnly - gap == both`) is independently testable without re-deriving font
    /// metrics in the test itself.
    private static func measuredHeight(of entries: [OfficeHeaderFooter], theme: RenderTheme,
                                        columnWidth: CGFloat, documentDefaultFontSize: CGFloat,
                                        pageContentWidth: CGFloat?) -> CGFloat {
        guard columnWidth.isFinite, columnWidth > 0 else { return 0 }
        // The TALLEST of them, not the first. Once a document's entries come from several sections
        // (a page takes its own section's — invariant 78), any of them can be the one painted on a
        // given page, and a band measured against a shorter one would let a taller one overlap the
        // body text. Reduces to exactly the old number for the overwhelmingly common document whose
        // entries are one section's.
        var tallest: CGFloat = 0
        for entry in entries where !entry.blocks.isEmpty {
            tallest = max(tallest, builtHeight(of: entry.blocks, theme: theme, columnWidth: columnWidth,
                                               documentDefaultFontSize: documentDefaultFontSize,
                                               pageContentWidth: pageContentWidth))
        }
        return tallest
    }

    /// How much a page must keep clear at its foot for the notes cited on it: the separator's own
    /// allowance, the notes themselves, and the document's spacing BETWEEN them.
    ///
    /// Pure arithmetic over already-measured heights, so the fixpoint (invariant 98) can be driven
    /// and tested without laying anything out. A page citing no note reserves nothing — not a
    /// minimum, not a separator: the rule must reduce to today's layout for the 615 of 637 corpus
    /// documents that never cite a footnote at all.
    static func footnoteBandHeight(noteHeights: [CGFloat], separatorAllowance: CGFloat,
                                   noteSpacing: CGFloat) -> CGFloat {
        let drawn = noteHeights.filter { $0 > 0 }
        guard !drawn.isEmpty else { return 0 }
        let between = noteSpacing * CGFloat(drawn.count - 1)
        return max(0, separatorAllowance) + drawn.reduce(0, +) + max(0, between)
    }

    /// How tall this run of blocks is once BUILT and laid out at `columnWidth` — the one place that
    /// answers it, for a running head and for a footnote alike.
    ///
    /// Measured through a throwaway TextKit stack rather than estimated from font sizes, because
    /// that is the only thing that agrees with what the reader will actually draw: a two-line header
    /// and a header that wraps to two lines are the same height, and no arithmetic over the spans
    /// can tell them apart. Blocks that build to nothing measure `0` (`drawsSomething`) — 28% of the
    /// real documents that declare a header declare an EMPTY one, and reserving space for those
    /// would put a gap on every page of a quarter of the corpus.
    static func builtHeight(of blocks: [OfficeBlock], theme: RenderTheme, columnWidth: CGFloat,
                            documentDefaultFontSize: CGFloat, pageContentWidth: CGFloat?) -> CGFloat {
        guard !blocks.isEmpty, columnWidth.isFinite, columnWidth > 0 else { return 0 }
        let attr = OfficeTextBuilder.build(blocks, theme: theme,
                                           columnWidth: columnWidth,
                                           documentDefaultFontSize: documentDefaultFontSize,
                                           pageContentWidth: pageContentWidth)
        guard attr.length > 0, drawsSomething(blocks, built: attr) else { return 0 }
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
    // port-exclude: reconciles the ENGINE's footnote-height reply against this render's own
    // note list. `page_band_geometry.rs` says the same from its side — `footnote_heights`
    // produces the answer this consumes, and there is no Swift-side twin of that loop to port.

    /// S5D-2's seam: reconciles the engine's own footnote-height answer with the notes this
    /// document is ACTUALLY going to draw. Present in BOTH builds, no `#if` guard — the branch
    /// judgment itself (not just the arithmetic either side of it) is what a unit test needs to
    /// watch, and a pure function is what makes that observable without constructing a window
    /// controller.
    ///
    /// `hostNumbers` is this render's own footnote list (`officeFootnotes.map(\.number)`) — the
    /// numbers that will actually be drawn, from THIS parse. `engine` is the engine's own reply, or
    /// `nil` when it could not answer at all. Two independent reads of the same bytes are not
    /// assumed to agree on ORDER, only on the numbers a document actually declared — so a number
    /// this render holds that the engine's reply does not name rejects the WHOLE map, never just
    /// that one entry (invariant 98's corrupt half: a map short one note reserves its page short by
    /// exactly that note's height). A number the engine names that this render does not hold is
    /// simply ignored — nothing draws it, so nothing needs its height.
    static func resolveNoteHeights(hostNumbers: [Int], engine: [Int: CGFloat]?) -> [Int: CGFloat]? {
        guard let engine else { return nil }
        var out: [Int: CGFloat] = [:]
        out.reserveCapacity(hostNumbers.count)
        for number in hostNumbers {
            guard let height = engine[number] else { return nil }
            out[number] = height
        }
        return out
    }
    // port-exclude-end

    /// Does this ONE entry have anything for the reader to put in a band — the question every gate
    /// that used to ask `blocks.isEmpty` should be asking instead. Built through the same
    /// `OfficeTextBuilder` as everything else, so a format whose header parses into blocks that build
    /// to nothing is judged on what it BUILDS rather than on what it parsed.
    static func entryDraws(_ entry: OfficeHeaderFooter?, theme: RenderTheme, columnWidth: CGFloat,
                           documentDefaultFontSize: CGFloat, pageContentWidth: CGFloat?) -> Bool {
        guard let entry, !entry.blocks.isEmpty, columnWidth.isFinite, columnWidth > 0 else { return false }
        let built = OfficeTextBuilder.build(entry.blocks, theme: theme, columnWidth: columnWidth,
                                            documentDefaultFontSize: documentDefaultFontSize,
                                            pageContentWidth: pageContentWidth)
        return drawsSomething(entry.blocks, built: built)
    }

    /// Is there anything in this entry for the reader to PUT in the band it is about to reserve?
    ///
    /// "The entry has blocks" is not that question, and the difference is common rather than exotic:
    /// **26 of the 94 real HWP/HWPX documents that declare a header or footer at all — 28% — declare
    /// one made of nothing but empty paragraphs.** Such an entry measured a full line height, so the
    /// reader opened a band on every page and drew nothing in it. That is invariant 47's three-state
    /// lesson one level deeper than `w:titlePg`'s blank entry (which arrives with NO blocks and was
    /// already handled): present, present-but-empty, and absent are three different answers.
    ///
    /// A picture-only header must still reserve, so the text test is for any NON-WHITESPACE character
    /// — an attachment is `U+FFFC`, which is not whitespace — and a paragraph that draws only a RULE
    /// or a shaded band carries no glyph at all, so the blocks are asked directly for those. Anything
    /// that is not a paragraph (a table, an image, a formula) is content by construction.
    static func drawsSomething(_ blocks: [OfficeBlock], built: NSAttributedString) -> Bool {
        if built.string.contains(where: { !$0.isWhitespace }) { return true }
        return blocks.contains { block in
            switch block {
            case .paragraph(_, _, _, _, let format), .heading(_, _, _, _, _, let format):
                return format.shading != nil || !format.borderEdges.isEmpty
            default:
                return true
            }
        }
    }
}
