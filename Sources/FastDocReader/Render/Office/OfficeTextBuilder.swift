import AppKit

/// What a "fill to margin" paragraph (see `OfficeTextBuilder.fillMarginTabInfo`) needs to rebuild
/// its trailing tab at any width: the OTHER (non-margin) tab stops, preserved verbatim in their
/// own authored positions, plus the margin tab's own alignment/leader — never its `position`,
/// which is supplied fresh every time by `OfficeTextBuilder.fillMarginTabStops` (that's the whole
/// point of carrying this instead of just keeping the original `TabStop`). Carried as
/// `MDAttr.fillMarginTab`'s attribute value, so it rides along in the text storage from build
/// time through every later reflow.
struct FillMarginTabInfo: Hashable {
    var marginAlignment: TabAlignment
    var marginLeader: TabLeader
    var otherTabs: [TabStop]
}

/// What an office graphic was AUTHORED as, carried as `MDAttr.officeGraphic`'s value so it rides in
/// the text storage from build time through every later reflow — the same trick `FillMarginTabInfo`
/// uses for a fill-to-margin tab, and for the same reason: the size a graphic should occupy is a
/// FUNCTION of the current reading column (`OfficeTextBuilder.graphicSize`), not a number to freeze
/// at whatever width the window happened to have when the document was built.
///
/// Without this, widening the window re-wrapped the text and re-solved every table to the new width
/// while the pictures stayed exactly as large as they were built — the document visibly came apart.
/// `placeholderLabel` is non-nil only for the chart/SmartArt frame, whose pixels are DRAWN at a
/// size (invariant 31) and so must be redrawn rather than merely re-bounded.
struct OfficeGraphicInfo: Hashable {
    var authored: CGSize
    var placeholderLabel: String?
    /// The DENOMINATOR this graphic's scale is measured against, in points: the source page's body
    /// width for a graphic in the text flow, or the source TABLE's own width for one inside a cell
    /// (see `TableFormat.sourceWidth` for why those differ). `nil` = unknown → no scaling, the
    /// authored size verbatim. Carried per graphic rather than looked up at reflow time so the
    /// reflow cannot pick a different basis than the build did.
    var basisWidth: CGFloat?
    /// The width this graphic is clamped to when it would otherwise overflow — its cell's content
    /// width inside a table, the reading column outside one. Recomputed at reflow (a cell's width
    /// changes with the window), so only the KIND of clamp is implied here, not a frozen number.
    var isInsideCell: Bool = false
}

/// Turns a format-neutral `[OfficeBlock]` into styled `NSAttributedString`, the same way
/// `MarkdownRenderer` turns a parsed markdown tree into one and `PlainTextRenderer` turns raw text
/// into one. Every TOP-LEVEL block is exactly one navigation stop: it gets its own `MDAttr.blockId`
/// over its full rendered range (content + its one trailing separator), so gutter click / block
/// edit work here for free once a later sprint wires this into the document — see invariant 1's
/// sibling rule for images: a reserved layout size must never depend on whether pixels are loaded.
enum OfficeTextBuilder {
    /// `columnWidth` is the text column's width in points at build time (what `presizeKnownMedia`
    /// calls `maxWidth` for markdown) — defaulted huge so callers that don't care about wrapping
    /// (every test but the scaling one) get the declared size back untouched. A real caller
    /// (`MarkdownDocument.render(into:)`) always passes the reader's actual column width: office
    /// image sizing is decided HERE, once, at build time — never at load time (see `appendImage`).
    ///
    /// `documentDefaultFontSize` is the SOURCE document's own default body run size, in points
    /// (docx `w:docDefaults/w:rPrDefault/w:rPr/w:sz`, HALF-points, converted by the reader; the
    /// OOXML default when a document states none at all is 11pt — the same default this parameter
    /// itself defaults to, so a caller that hasn't wired a reader-supplied value through yet still
    /// gets the standard behaviour). This is the OTHER half of the font-size model, alongside
    /// `Span.fontSize`: the document, as authored, is 100% — `theme.baseFontSize` (the reading
    /// document's own `readingSize`) is multiplied on top of it, as the RATIO
    /// `theme.baseFontSize / documentDefaultFontSize`. A run that names an explicit size (a 22
    /// half-point body run, a 32 half-point heading — `Span.fontSize` 11pt/16pt) is scaled by that
    /// ratio; a run that names none keeps whatever the surrounding block's OWN base font already is
    /// (`theme.headingFont(level:)`/`theme.bodyFont`), which is already sized off `theme.baseFontSize`
    /// with no further scaling. Two things this preserves, deliberately, the way Word itself does:
    /// a document's own internal relationships survive the user's reading-size setting (a heading
    /// stays proportionally larger than body text, an emphasised 14pt line stays larger than an
    /// 11pt paragraph, AT ANY reading size) — and the reading-size setting still governs how big
    /// the document looks overall, which is the entire point of that setting and must never be
    /// silently overridden by what the document happened to be authored at.
    /// `pageContentWidth` is the SOURCE document's own page body width in points, and it drives the
    /// SEPARATE scale for absolute-extent GRAPHICS — images and the chart/SmartArt placeholder —
    /// which is deliberately NOT `fontSizeScale`. A picture's authored size is a fraction of the PAGE
    /// it was drawn on, so the reader reproduces that fraction: the graphic scale is
    /// `readingColumn ÷ pageContentWidth`, which makes a graphic occupy the same share of the reading
    /// column that it occupied of the source page. A picture INSIDE A TABLE CELL divides by the
    /// table's own `TableFormat.sourceWidth` instead, because tables are stretched to fill the column
    /// (invariant 39) and a page-scaled picture would sit small inside a cell that grew around it.
    /// `nil` = the reader could not determine a page width → scale 1, authored sizes verbatim. Two
    /// consequences, both deliberate: a graphic grows and shrinks with the WINDOW at the document's
    /// own proportion, and it is UNTOUCHED by the reading-size setting — ⌘+/⌘− resizes text, never the
    /// pictures. Scaling graphics by `fontSizeScale` instead was tried and rejected twice: at 1.0 it
    /// left photographs tiny beside 1.6×-enlarged text (the document's own font↔image proportion
    /// broken), and riding the font scale made ⌘+ inflate photographs. Column-fitting still applies
    /// on top (`fittedOfficeSize`), so a scaled graphic can never overflow its column — or its cell —
    /// and because a page-proportional scale maps the page onto the column, a full-page-width image
    /// lands just inside it rather than being clamped.
    /// `comments` (P6b) is `officeComments` from `MarkdownDocument` — used ONLY to resolve each
    /// `Span.commentIds` entry to that comment's DISPLAY number (`OfficeComment.number`), via
    /// `commentNumbers` below, so `MDAttr.commentMark` carries the number a reader recognizes
    /// ("Comment 3") rather than the source's opaque id string. Threaded into headings/paragraphs/
    /// list items (where a comment's anchor overwhelmingly lands); table-cell content does not
    /// receive it — cells build through a separate, already-deep call chain
    /// (`appendTable`→`cellContent`) and a comment anchored inside a table cell is rare enough that
    /// widening that chain wasn't worth the added surface for this sprint.
    /// Indices (into `blocks`) of the tables big enough that building their grid is what makes a
    /// document freeze on open — the ONE place this line is drawn, so the render path and every test
    /// judge the same tables. `rows >= 50 AND rows × maxColumns >= 500`, measured over 1,280
    /// documents / 11,207 tables: it fires on 0.68% of tables and 1.4% of documents while removing
    /// 30.9% of all grid cells, and on ZERO of the reference manual's 388 tables. Both halves are
    /// load-bearing — row count alone catches a 103×2 prose table that costs nothing.
    /// See `docs/giant-table-deferral-design.md`.
    static func giantTableIndices(_ blocks: [OfficeBlock]) -> Set<Int> {
        var out: Set<Int> = []
        for (i, b) in blocks.enumerated() {
            guard case let .table(rows, _, _, _) = b else { continue }
            let r = rows.count
            guard r >= 50 else { continue }
            let cols = rows.map { $0.reduce(0) { $0 + $1.colSpan } }.max() ?? 0
            if r * cols >= 500 { out.insert(i) }
        }
        return out
    }

    /// The stand-in a deferred table leaves behind. Deliberately language-neutral — this app has no
    /// localisation table, and a word here would ship one language to all 23 stores. It is on screen
    /// for about a second, and only for a reader who scrolled ~121 screens down within that second.
    static let deferredTableStandIn = "⋯"

    /// `deferringTables` — indices whose `.table` is replaced by a one-paragraph stand-in carrying
    /// `MDAttr.deferredTable`, so `MarkdownDocument` can paint now and splice the grid in after
    /// (invariant 49's freeze, see `docs/giant-table-deferral-design.md`). EMPTY is the default and
    /// the identity: nothing about any other document changes, byte for byte (invariant 37).
    static func build(_ blocks: [OfficeBlock], theme: RenderTheme,
                      columnWidth: CGFloat = .greatestFiniteMagnitude,
                      documentDefaultFontSize: CGFloat = 11,
                      pageContentWidth: CGFloat? = nil,
                      pageMarginRight: CGFloat? = nil,
                      tableWidth: CGFloat? = nil,
                      lineGridPitch: CGFloat? = nil,
                      comments: [OfficeComment] = [],
                      deferringTables: Set<Int> = [],
                      sectionStartBlocks: [Int] = []) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var blockSeq = 0
        // Ordered-list numbering state, keyed by nesting level. Lives for the whole build() call
        // (not per-block) because the restart rule below needs to see across blocks.
        var orderedCounters: [Int: Int] = [:]
        let fontSizeScale = documentDefaultFontSize > 0 ? theme.baseFontSize / documentDefaultFontSize : 1
        // A graphic in the text flow is measured against the source PAGE; one inside a table is
        // measured against that TABLE (see `pageContentWidth`'s doc above and `appendTable`).
        let pageBasis: CGFloat? = (pageContentWidth ?? 0) > 0 ? pageContentWidth : nil
        // THE paged predicate, in one place, exactly as `DocumentWindowController.pagedWidth` states
        // it: a declared page body width is what makes a document paged, and every rule below that
        // says "the document wins" is gated on this and nothing else.
        let paged = pageBasis != nil
        // How far a picture may run past the body before it is shrunk after all (`bleedAllowance`).
        let bleed = bleedAllowance(paged: paged, pageMarginRight: pageMarginRight)
        func scale(basis: CGFloat?) -> CGFloat {
            guard let basis, basis > 0, columnWidth.isFinite, columnWidth > 0 else { return 1 }
            return columnWidth / basis
        }
        // id → display number, built once per build() call (comments list is small; a dictionary
        // avoids an O(n) scan per span).
        var commentNumbers: [String: Int] = [:]
        for c in comments { commentNumbers[c.id] = c.number }

        // Block index → the section that starts there, so the marker is one dictionary lookup per
        // block rather than a search per section.
        var sectionOfBlock: [Int: Int] = [:]
        for (section, first) in sectionStartBlocks.enumerated() { sectionOfBlock[first] = section }

        func tagBlock(from start: Int, index: Int) {
            let r = NSRange(location: start, length: result.length - start)
            guard r.length > 0 else { return }
            result.addAttribute(MDAttr.blockId, value: blockSeq, range: r)
            blockSeq += 1
            // The section marker goes on the block that STARTS a section, over its whole range —
            // one attribute run per section, which is what a page lookup binary-searches. A section
            // whose first block builds to nothing carries no marker, exactly like `blockId`: an
            // empty run cannot be found by a character, so claiming one would be a lie about where
            // the section begins.
            if let section = sectionOfBlock[index] {
                result.addAttribute(MDAttr.sectionIndex, value: section, range: r)
            }
        }

        for (index, block) in blocks.enumerated() {
            let start = result.length
            // P2's `w:contextualSpacing` adjacency rule (spec area 5): suppress THIS paragraph's
            // spacing-before when the PREVIOUS block is the same style (its `ParagraphFormat` is
            // EQUAL — the vocabulary carries no style id, so equal resolved format is the proxy),
            // and symmetric for spacing-after against the NEXT block. Only ever narrows a format
            // (zeroes spacing that was otherwise set) — a block with no format at all (`nil`, every
            // non-paragraph-shaped case) is untouched, and a paragraph whose OWN contextualSpacing
            // is `false`/unset never has this rule applied regardless of its neighbours.
            let format = contextualSpacingAdjustedFormat(for: block, at: index, in: blocks)
            switch block {
            case let .heading(level, spans, rtl, alignment, tabStops, _):
                let headingBase = headingBaseFont(level: level, theme: theme, paged: paged)
                result.append(spansAttributedString(spans, baseFont: headingBase,
                                                     baseColor: theme.textColor, theme: theme,
                                                     fontSizeScale: fontSizeScale, paged: paged,
                                                     commentNumbers: commentNumbers))
                // Tagged BEFORE the trailing newline is appended, so a substring of this range is
                // exactly the heading's text — precisely what the outline sidebar reads
                // (`OutlinePanel.reload` trims and shows it verbatim).
                result.addAttribute(MDAttr.heading, value: level,
                                     range: NSRange(location: start, length: result.length - start))
                result.append(NSAttributedString(string: "\n"))
                let headingRange = NSRange(location: start, length: result.length - start)
                result.addAttribute(.paragraphStyle,
                                    value: headingParagraphStyle(level: level, spans: spans, theme: theme,
                                                                  rtl: rtl,
                                                                  alignment: alignment, tabStops: tabStops,
                                                                  format: format, fontSizeScale: fontSizeScale,
                                                                  paged: paged, lineGridPitch: lineGridPitch,
                                                                  columnWidth: columnWidth),
                                    range: headingRange)
                if let info = OfficeTextBuilder.fillMarginTabInfo(from: tabStops) {
                    result.addAttribute(MDAttr.fillMarginTab, value: info, range: headingRange)
                }

            case let .paragraph(spans, rtl, alignment, tabStops, _):
                result.append(spansAttributedString(spans, baseFont: theme.bodyFont,
                                                     baseColor: theme.textColor, theme: theme,
                                                     fontSizeScale: fontSizeScale, paged: paged,
                                                     commentNumbers: commentNumbers))
                result.append(NSAttributedString(string: "\n"))
                let paragraphRange = NSRange(location: start, length: result.length - start)
                result.addAttribute(.paragraphStyle,
                                    value: bodyParagraphStyle(theme: theme, rtl: rtl, alignment: alignment,
                                                               tabStops: tabStops, format: format,
                                                               fontSizeScale: fontSizeScale,
                                                               paged: paged, lineGridPitch: lineGridPitch,
                                                               columnWidth: columnWidth),
                                    range: paragraphRange)
                if let info = OfficeTextBuilder.fillMarginTabInfo(from: tabStops) {
                    result.addAttribute(MDAttr.fillMarginTab, value: info, range: paragraphRange)
                }
                markTabLeaders(tabStops, in: paragraphRange, on: result)

            case let .listItem(level, ordered, spans, marker, rtl, alignment, tabStops, _):
                appendListItem(level: level, ordered: ordered, spans: spans, marker: marker, rtl: rtl,
                               alignment: alignment, tabStops: tabStops, into: result,
                               theme: theme, orderedCounters: &orderedCounters, fontSizeScale: fontSizeScale,
                               paged: paged, lineGridPitch: lineGridPitch, format: format,
                               commentNumbers: commentNumbers)

            case .table where deferringTables.contains(index):
                // Holds this table's PLACE (and, via `tagBlock` below, its block id) so the splice
                // that follows is a local replacement rather than a re-render. Styled as an ordinary
                // body paragraph: it must not reserve the grid's eventual height, because the whole
                // point is that this document is short until the grid arrives.
                let standIn = NSMutableAttributedString(string: Self.deferredTableStandIn + "\n")
                standIn.addAttributes([.font: theme.bodyFont, .foregroundColor: theme.secondaryColor,
                                       .paragraphStyle: bodyParagraphStyle(theme: theme, format: format,
                                                                           fontSizeScale: fontSizeScale,
                                                                           paged: paged, lineGridPitch: lineGridPitch,
                                                                           columnWidth: columnWidth),
                                       MDAttr.deferredTable: index],
                                      range: NSRange(location: 0, length: standIn.length))
                result.append(standIn)

            case let .table(rows, headerRows, columnWidths, tableFormat):
                appendTable(rows, headerRows: headerRows, columnWidths: columnWidths, tableFormat: tableFormat,
                            into: result, theme: theme, fontSizeScale: fontSizeScale, columnWidth: columnWidth,
                            // A cell picture is measured against the table's own source width when the
                            // format stated one, else it falls back to the page — never left unscaled.
                            graphicBasis: tableFormat.sourceWidth ?? pageBasis,
                            paged: paged, lineGridPitch: lineGridPitch,
                            tableWidth: tableWidth)

            case let .image(id, size, alignment):
                appendImage(id: id, size: size, columnWidth: columnWidth, basis: pageBasis,
                            scale: scale(basis: pageBasis), alignment: alignment, insideCell: false,
                            bleed: bleed, into: result)

            case let .unsupportedGraphic(label, size, alignment):
                appendUnsupportedGraphic(label: label, size: size, columnWidth: columnWidth, basis: pageBasis,
                                         scale: scale(basis: pageBasis), alignment: alignment, insideCell: false,
                                         bleed: bleed, into: result)

            case let .formula(latex):
                appendFormula(latex: latex, into: result)
            }
            // P2b — a heading/paragraph/list-item's own resolved shading/border (`format` is `nil`
            // for every other case, so this is a no-op there): tagged over the block's FULL rendered
            // range (content + its one trailing separator, same range `tagBlock` below tags), read
            // by `drawMDDecorations` at draw time — see `MDAttr.paraShading`'s own doc for why this
            // is build-time-only (nothing here recomputes geometry; the layout manager just paints a
            // rect over glyphs already laid out).
            if let format {
                let range = NSRange(location: start, length: result.length - start)
                if let shading = format.shading { result.addAttribute(MDAttr.paraShading, value: shading, range: range) }
                // Presence is "either field resolved" — a source can legally set only `w:pBdr`'s
                // `@w:sz` (width) with `@w:color="auto"` (theme decides), or vice versa; the SAME
                // per-field fallback `TableBlockBuilder` already applies to `Cell.borderColor`/
                // `.borderWidth` (`Palette.tableBorder` / `1`pt) is mirrored here so a partially
                // resolved border still draws something rather than silently vanishing.
                if format.borderColor != nil || format.borderWidth != nil {
                    let color = format.borderColor ?? Palette.tableBorder
                    let width = format.borderWidth ?? 1
                    result.addAttribute(MDAttr.paraBorderColor, value: color, range: range)
                    result.addAttribute(MDAttr.paraBorderWidth, value: NSNumber(value: Double(width)), range: range)
                    // WHICH edges — empty means the reader said nothing per-edge, which is the
                    // whole box this drew before the set existed (every ODT paragraph, invariant 37).
                    let edges = format.borderEdges.isEmpty ? RectEdge.all : format.borderEdges
                    result.addAttribute(MDAttr.paraBorderEdges, value: NSNumber(value: edges.rawValue), range: range)
                }
            }
            tagBlock(from: start, index: index)
        }
        unifyParagraphTerminators(in: result)
        return result
    }

    /// Give every paragraph's terminating `"\n"` the attributes of the paragraph it ENDS.
    ///
    /// **A separator with no font is not a neutral character — AppKit gives it Helvetica 12pt**, the
    /// app's own default, so a font the document never mentions sits inside the document. Measured on
    /// a real 9pt Korean report: each of the bare `NSAttributedString(string: "\n")` appends above
    /// produced a `Helvetica@12` run. Laid-out height and page count are IDENTICAL either way
    /// (verified against a `--pdf` render before and after, and by measuring the document's used
    /// height with this pass removed) — this is hygiene and one fewer attribute run per paragraph,
    /// not a spacing change.
    ///
    /// This is invariant 51 at the TOP level. `TableBlockBuilder` unified the newline that ends a
    /// cell and `cellContent` the ones between a cell's own paragraphs; the document's own paragraph
    /// separators were the third case and were never covered. Same function, same ALLOW-list, so a
    /// separator next to an attachment/link/underline still falls back to exactly what it had.
    private static func unifyParagraphTerminators(in result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let ns = result.string as NSString
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: result.length), options: .byParagraphs) {
            _, _, enclosing, _ in
            if enclosing.length > 0 { paragraphs.append(enclosing) }
        }
        for range in paragraphs { unifyTerminator(of: range, in: result, string: ns) }
    }

    /// The `format` carried by a heading/paragraph/list-item block — `nil` for every other case
    /// (table/image/unsupportedGraphic/formula), which carries no `ParagraphFormat` at all.
    private static func paragraphFormat(of block: OfficeBlock) -> ParagraphFormat? {
        switch block {
        case let .heading(_, _, _, _, _, format): return format
        case let .paragraph(_, _, _, _, format): return format
        case let .listItem(_, _, _, _, _, _, _, format): return format
        case .table, .image, .unsupportedGraphic, .formula: return nil
        }
    }

    /// `block`'s own resolved `ParagraphFormat`, with `spacingBefore`/`spacingAfter` zeroed when
    /// P2's `w:contextualSpacing` adjacency rule applies — see `build`'s call site doc. `nil` in,
    /// `nil` out (a block with no `ParagraphFormat` never gets one invented).
    private static func contextualSpacingAdjustedFormat(
        for block: OfficeBlock, at index: Int, in blocks: [OfficeBlock]
    ) -> ParagraphFormat? {
        guard let resolved = paragraphFormat(of: block), resolved.contextualSpacing else {
            return paragraphFormat(of: block)
        }
        // Both neighbour comparisons are against `resolved` — the UNMUTATED format — so zeroing
        // `spacingBefore` for the "previous block matches" check can never change what the
        // "next block matches" check compares against (and vice versa).
        var adjusted = resolved
        if index > 0, paragraphFormat(of: blocks[index - 1]) == resolved {
            adjusted.spacingBefore = 0
        }
        if index + 1 < blocks.count, paragraphFormat(of: blocks[index + 1]) == resolved {
            adjusted.spacingAfter = 0
        }
        return adjusted
    }

    // MARK: Spans → attributed runs

    /// Renders one block's spans against that block's base font/color. A `code` span overrides
    /// BOTH with the theme's inline-code styling and tags `MDAttr.inlineCode` — bold/italic/
    /// underline still layer on top of it (an office run can be monospaced AND bold at once,
    /// unlike a markdown code span, which never carries emphasis).
    ///
    /// NOT private: a later sprint's RTF reader re-themes spans it parsed itself rather than
    /// receiving as `OfficeBlock`, and needs this exact styling logic rather than a duplicate.
    ///
    /// `fontSizeScale` is `theme.baseFontSize / documentDefaultFontSize` (see `build`'s doc comment
    /// for the model) — defaulted to `1` so every pre-sprint call site (this file's own cell/list
    /// helpers used to, and `OfficeTextBuilderTests`' direct calls still do, pass none) keeps
    /// meaning "don't rescale", i.e. `Span.fontSize` is already in the units the caller wants.
    /// `commentNumbers` (P6b) maps a comment's source id (`Span.commentIds` entries) to its DISPLAY
    /// number — see `build`'s doc. Defaults to empty so every pre-P6b call site (every test, and
    /// the table-cell chain — see `build`'s doc for why cells don't thread this) keeps compiling
    /// and behaving exactly as before: a span with no matching number gets no `MDAttr.commentMark`.
    /// `paged` (see `build`'s own `pageContentWidth`) governs ONE thing here: whether an authored
    /// point size is rounded to a whole point — see the `span.fontSize` branch below.
    static func spansAttributedString(_ spans: [Span], baseFont: NSFont, baseColor: NSColor,
                                      theme: RenderTheme, fontSizeScale: CGFloat = 1,
                                      paged: Bool = false,
                                      commentNumbers: [String: Int] = [:]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            var font = baseFont
            var color = baseColor
            var attrs: [NSAttributedString.Key: Any] = [:]
            // `caps` is a DISPLAY-only transform (see `Span.caps`'s doc) — computed on a local copy
            // of the run's text, never on `span` itself, so nothing downstream (undo, re-render,
            // the source model) ever sees an uppercased string that wasn't authored.
            let displayText = span.caps ? span.text.uppercased() : span.text
            if span.code {
                font = theme.codeFont
                color = theme.inlineCodeColor
                attrs[MDAttr.inlineCode] = true
            } else if let name = span.fontName, let named = NSFont(name: name, size: font.pointSize) {
                // Family override — never applied to a `code` span (see `Span.fontName`'s doc).
                font = named
            }
            // `resolvedFontDescriptor` (see its own doc) is `nil` for the overwhelming majority of
            // spans — the font just assigned above already covers every character, so this is a
            // no-op and the span renders byte-identically to before this field existed (invariant
            // 37). Where it is set, `NSFont(descriptor:size:)` — the SAME reconstruction idiom the
            // authored-size step just below and `fontAdding` already use for the theme's own private
            // system-UI faces — rebuilds the EXACT font `FontSubstitutionResolver` found at READ
            // time, so this performs ZERO coverage tests and ZERO CoreText calls on every ⌘+ press:
            // the decision was already made once, when the document was opened, and it cannot go
            // stale because its inputs (this document's own text and fonts) cannot change.
            //
            // `FontSubstitutionResolver.declaredFont` already unions the span's OWN bold/italic (and
            // the block's base weight — semibold for a heading) into the probe it hands CoreText, so
            // a resolved descriptor already IS the correctly-weighted/traited substitute — it must
            // not be re-traited here. Re-adding traits via `withSymbolicTraits` onto an already-
            // resolved PRIVATE system-UI substitute descriptor is not reliable: measured, re-adding
            // `.bold` on an already-`-SemiBold` Korean substitute produced a DIFFERENT face
            // (`.AppleKoreanFont-Bold`, not `-SemiBold`), and re-adding `[.bold, .italic]` on a
            // `-Regular` one silently no-opped. `hasResolvedSubstitute` gates the trait step below so
            // the untouched (`resolvedFontDescriptor == nil`) path — still the overwhelming majority
            // of spans — keeps applying bold/italic exactly as it always has.
            let hasResolvedSubstitute = span.resolvedFontDescriptor != nil
            if let resolvedDescriptor = span.resolvedFontDescriptor,
               let substituted = NSFont(descriptor: resolvedDescriptor, size: font.pointSize) {
                font = substituted
            }
            // An authored size REPLACES the block's base size before bold/italic/super-sub touch
            // it, so those still layer on top of the right starting point (traits preserve family,
            // not size; scaling preserves family, not traits — order doesn't matter between the
            // two, but both must happen before either reads `font.pointSize` for anything else).
            //
            // The `.rounded()` is the NON-paged half of the model and belongs there: a run's size
            // has been multiplied by `fontSizeScale` (reading size ÷ the document's own default),
            // which turns the document's own tidy numbers into arbitrary fractions, and rounding
            // those back to whole points is what keeps a re-typeset document's sizes coalescing into
            // a small set of attribute runs. PAGED has neither the cause nor the licence: the scale
            // is exactly 1 there (`MarkdownDocument.render` builds the theme at the document's own
            // default body size), so the only thing rounding can do is DESTROY a size the author
            // stated. Word's `w:sz` is in HALF-points, so 10.5pt is an ordinary authored size, not an
            // exotic one — measured on one real report, 106 of its 617 runs declare a fractional
            // size, and every one of them was being drawn a half point too large or too small.
            if let authoredSize = span.fontSize {
                let scaled = authoredSize * fontSizeScale
                font = NSFont(descriptor: font.fontDescriptor,
                              size: max(1, paged ? scaled : scaled.rounded())) ?? font
            }
            if !hasResolvedSubstitute {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if span.bold { traits.insert(.bold) }
                if span.italic { traits.insert(.italic) }
                if !traits.isEmpty { font = fontAdding(traits, to: font) }
            }
            // Super/subscript shrink the font AND shift the baseline — `.superscript` alone isn't
            // interpreted by TextKit's own drawing, so it wouldn't actually render raised/lowered
            // here; a smaller font at an offset baseline is what makes it look right on screen.
            // `superscript`/`subscripted` are mutually exclusive in every real document, but if a
            // parser ever set both, superscript wins (checked first) rather than the two offsets
            // cancelling into something illegible.
            if span.superscript {
                let raised = font.pointSize * 0.35
                font = fontScaled(font, by: 0.7)
                attrs[.baselineOffset] = raised
            } else if span.subscripted {
                let lowered = -font.pointSize * 0.15
                font = fontScaled(font, by: 0.7)
                attrs[.baselineOffset] = lowered
            }
            // Authored colour is resolved against the theme, never applied raw — see
            // `resolvedTextColor`'s doc for the ordinary-ink-vs-marked-colour decision. Skipped for
            // a `code` span for the same reason `fontName` is: the inline-code look is one
            // consistent accent across the whole app, not something an individual run overrides.
            if let authoredColor = span.textColor, !span.code {
                color = resolvedTextColor(authoredColor, theme: theme)
            }
            // `smallCaps` (unlike `caps`) never touches `displayText` — it asks the FONT itself to
            // draw lowercase letters as small capitals, via the classic Apple `kLowerCaseType`/
            // `kLowerCaseSmallCapsSelector` font feature (present on macOS system fonts; a font
            // lacking the feature silently renders its ordinary lowercase glyphs instead — no
            // crash, just no small-caps look, the same graceful-degradation posture `fontName`'s
            // missing-family fallback already takes). Applied LAST, after every other font
            // transform above (code/family/size/bold-italic/super-sub), so the feature rides
            // whatever font those already produced rather than being clobbered by one of them.
            // Word's own precedence has `caps` win when both are set — `caps` already uppercased
            // `displayText` above, so this only visibly matters when `smallCaps` is set alone, but
            // it is harmless to also request the feature on an already-uppercased run (small-caps
            // has no effect on characters that are already capital).
            if span.smallCaps {
                let smallCapsAttrs: [[NSFontDescriptor.FeatureKey: Int]] = [[
                    .typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector,
                ]]
                let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: smallCapsAttrs])
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            attrs[.font] = font
            attrs[.foregroundColor] = color
            // Always drawn exactly as authored — see `Span.highlightColor`'s doc for why a
            // highlight, unlike text colour, is never reinterpreted against the theme.
            if let highlight = span.highlightColor { attrs[.backgroundColor] = highlight }
            if span.underline { attrs[.underlineStyle] = nsUnderlineStyle(for: span.underlineStyle).rawValue }
            if span.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Same colour/underline treatment `MarkdownRenderer.inlineFragment`'s `Markdown.Link`
            // case uses — a link must look and behave identically whether it arrived via markdown
            // or an office hyperlink, not grow a second visual style.
            // A PAGED document that stated a colour on the link keeps it — invariant 57, applied to
            // the one attribute the link branch below always overwrote. A printed manual that sets
            // its cross-references in black is not asking for the reader's blue.
            //
            // Only when the document SAID something, and this is the whole reason the rule is not
            // simply "the document always wins": Word's own blue-and-underlined hyperlink comes from
            // the `Hyperlink` CHARACTER style (`w:rPr/w:rStyle`), which this reader does not resolve
            // (see `DocxReader.resolvedRFonts`' note — measured at 0.23% of runs, deferred because it
            // moves size and font as well as colour). So an ordinary Word hyperlink arrives here with
            // NO authored colour at all, and handing it the body colour would make every link in
            // every document indistinguishable from the text around it — further from Word, not
            // closer. The theme's link colour stands in for the style we cannot yet read.
            //
            // The UNDERLINE is left forced for a different reason: `Span.underline` is a Bool with no
            // "unstated" value, so "the document turned underline off" and "the document said
            // nothing" arrive identically, and the three-state distinction invariant 47 needed for
            // borders does not exist here. Guessing wrong would silently drop the click affordance.
            let linkKeepsAuthoredColour = paged && span.textColor != nil && !span.code
            if let link = span.link {
                if link.hasPrefix("#") {
                    // An in-document anchor (docx `w:anchor`, odt same-document `xlink:href`) —
                    // NEVER a `.link` URL built from the raw fragment. `MarkdownRenderer`'s own TOC
                    // links use the identical placeholder-URL-plus-`MDAttr.anchor` pair (see its
                    // `Markdown.Link` case) precisely so the click handler's `MDAttr.anchor` check
                    // catches this BEFORE it can ever reach the generic URL branch that treats a
                    // bare `#fragment` as a relative file path — that misread (clicking a
                    // cross-reference tries to open a file named after the bookmark) is the defect
                    // this exists to prevent, not a style nicety.
                    if !linkKeepsAuthoredColour { attrs[.foregroundColor] = theme.linkColor }
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[MDAttr.anchor] = String(link.dropFirst())
                    attrs[.link] = URL(string: "fmdanchor:jump")!
                } else if let url = URL(string: link) {
                    if !linkKeepsAuthoredColour { attrs[.foregroundColor] = theme.linkColor }
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.link] = url
                }
            }
            if !span.bookmarks.isEmpty {
                attrs[MDAttr.bookmarkTarget] = span.bookmarks
            }
            // P6b: a span whose ids resolve to a known comment gets the DISPLAY number(s) tagged —
            // an id with no match (comments capture failed to find it, or a stale/dangling id) is
            // silently skipped rather than surfacing a "Comment ?" the reader can't act on.
            if !span.commentIds.isEmpty {
                let numbers = span.commentIds.compactMap { commentNumbers[$0] }
                if !numbers.isEmpty { attrs[MDAttr.commentMark] = numbers }
            }
            // header-footer-design.md §5 (build step 5): mark a PAGE/NUMPAGES run so a header/footer
            // draw pass can substitute the live value — see `MDAttr.pageNumberField`'s own doc for
            // why this never touches `displayText`/the span model itself (the cached text still
            // renders verbatim everywhere else, including `--extract`, which never reaches this
            // function at all — invariant 40's blocks→serializer path is entirely separate).
            if let field = span.pageNumberField {
                attrs[MDAttr.pageNumberField] = field
            }
            // An explicitly-marked run (docx `w:rPr/w:rtl`) gets TextKit's own run-level embedding
            // override — the same mechanism a Unicode RLE/PDF control character would produce, just
            // stated declaratively instead of via invisible characters in the string. This is
            // independent of the paragraph's base direction (`OfficeBlock`'s `rtl`): a Latin phrase
            // embedded in an RTL paragraph never sets this, and a Hebrew phrase embedded in an LTR
            // one does — TextKit's bidi algorithm already reorders the two correctly around each
            // other once told which is which.
            if span.rtl {
                attrs[.writingDirection] = [NSWritingDirection.rightToLeft.rawValue
                                             | NSWritingDirectionFormatType.embedding.rawValue]
            }
            out.append(NSAttributedString(string: displayText, attributes: attrs))
        }
        return out
    }

    /// Maps `UnderlineStyle` (already-collapsed from docx `w:u/@w:val` — see that enum's doc) to
    /// the nearest `NSUnderlineStyle` AppKit actually draws. `.dashed`/`.dotted` have exact pattern
    /// equivalents; `.wavy` does not — `NSUnderlineStyle` has no wave pattern at all, so `.thick` is
    /// used as the nearest "this is not an ordinary underline" visual distinction AppKit offers
    /// (a plain `.single` would silently lose the fact the source asked for something unusual).
    private static func nsUnderlineStyle(for style: UnderlineStyle) -> NSUnderlineStyle {
        switch style {
        case .single: return .single
        case .double: return .double
        case .dotted: return .patternDot
        case .dashed: return .patternDash
        case .wavy: return .thick
        }
    }

    /// Decides whether an authored run colour survives into the current reading theme, or steps
    /// aside for the theme's own text colour. The judgement call the app makes: a NEAR-NEUTRAL
    /// authored colour (low saturation — almost always literal black, occasionally literal white)
    /// reads as "ORDINARY" — the author never meant to mark this text, they typed body copy under
    /// whatever their template's default run colour happened to be. Honouring that literally under
    /// the dark theme is exactly how ordinary text goes invisible (black-on-near-black); stepping
    /// aside for `theme.textColor` makes an authored-black run behave IDENTICALLY to a run that
    /// authored no colour at all, which is the only self-consistent reading of "ordinary" text.
    /// A genuinely COLOURFUL authored run (a red warning, a brand blue) has enough saturation to
    /// read as a DELIBERATE mark, and is drawn exactly as authored in both themes — losing that
    /// distinction would lose the meaning the colour exists to carry (a warning that silently
    /// becomes normal-coloured text is a warning nobody can see).
    ///
    /// `0.12` is a low bar deliberately: it only has to separate "grey/black/white" from "has a
    /// hue at all", not fine-tune how vivid a colour must be to count as a mark.
    static func resolvedTextColor(_ authored: NSColor, theme: RenderTheme) -> NSColor {
        guard let rgb = authored.usingColorSpace(.deviceRGB) else { return theme.textColor }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return saturation < 0.12 ? theme.textColor : authored
    }

    /// Adds symbolic traits while keeping the SAME family, so vertical metrics (ascent/descent)
    /// don't shift — an unrelated bold face would jitter the baseline under a fixed line height
    /// (same reasoning as `MarkdownRenderer.fontAdding`, duplicated here: that one is private to
    /// its file).
    private static func fontAdding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    /// Same family, scaled point size — used for super/subscript, which shrink the glyph as well
    /// as shifting its baseline.
    private static func fontScaled(_ font: NSFont, by factor: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * factor).rounded()) ?? font
    }

    // MARK: Paragraph styles

    /// `rtl` sets `baseWritingDirection` ONLY when true — an LTR block (`rtl == false`, every
    /// existing call site before this sprint) leaves it at `NSMutableParagraphStyle()`'s own default
    /// (`.natural`), so a pre-sprint document's paragraph style is byte-identical to before.
    /// `alignment`, when supplied, ALWAYS wins over `rtl`'s implicit edge (see `OfficeBlock`'s doc
    /// on the two) — `nil` (every pre-sprint call site) leaves `.natural` exactly as `rtl` alone
    /// left it before this parameter existed. `tabStops` (points) are appended to whatever default
    /// tab stops `NSMutableParagraphStyle()` already carries; empty (every pre-sprint call site)
    /// changes nothing. Each authored stop's OWN alignment (P2b) is carried into the built
    /// `NSTextTab` — see `officeTextTab`'s doc for exactly how.
    /// `columnWidth` (same meaning as `build`'s own parameter) supplies the placeholder width for
    /// a fill-margin tab (see `fillMarginTabInfo`/`fillMarginTabStops`) — it is otherwise unused
    /// here, since every other tab stop renders exactly as it always has.
    private static func bodyParagraphStyle(theme: RenderTheme, rtl: Bool = false,
                                            alignment: NSTextAlignment? = nil,
                                            tabStops: [TabStop] = [],
                                            format: ParagraphFormat? = nil,
                                            fontSizeScale: CGFloat = 1,
                                            paged: Bool = false,
                                            lineGridPitch: CGFloat? = nil,
                                            columnWidth: CGFloat = .greatestFiniteMagnitude) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * theme.lineHeightRatio).rounded()
        // The `base × lineHeightRatio` line height is a comfortable FLOOR, not a fixed cap. Pinning
        // `maximumLineHeight` to it clips any paragraph whose own font is TALLER than the floor —
        // and a large BODY paragraph is exactly that (an HWP title is a 32pt body paragraph, not a
        // `.heading`, so it hits this style and its glyphs overlapped at ~23pt). Cleared to 0 (no
        // cap), TextKit uses the natural line height once it EXCEEDS the floor, so a tall line grows.
        // Normal body (font ≤ base) is byte-identical: 16pt text's natural height is below the floor,
        // so the `minimumLineHeight` floor still governs. Explicit `.multiple`/`.exact`/`.atLeast`
        // line rules from the document (applyParagraphFormat, below) override this per their own contract.
        // PAGED: the app supplies NO rhythm of its own. A paragraph the document said nothing about
        // gets the font's natural line height and no trailing gap — which is what Word draws for the
        // same paragraph — instead of the reader's 1.45x line and 0.9x gap. Those two ratios are the
        // editorial rhythm this app applies to its OWN markdown, and carrying them onto a page we are
        // reproducing is exactly the "우리 자체 판단" the owner asked to be removed: "예전에는 자체
        // 비율로 보여지는거라 우리가 맘대로 줄간격 등을 조정했지만 이제는 아니야".
        // `applyParagraphFormat` below still applies every line rule and gap the document DID state.
        // PAGED + the section declares a LINE GRID: that pitch is the floor instead of "natural".
        // Word snaps a paragraph that states no spacing of its own onto the grid, and skipping it is
        // why a row Word draws at 18.48pt came out at 13.33pt here — the font's natural height, five
        // points short. `applyParagraphFormat` still overrides this for any paragraph that DID state
        // a rule, so the grid is a floor and never a cap. No grid → 0, i.e. exactly today.
        p.minimumLineHeight = paged ? (lineGridPitch ?? 0) : lh
        p.maximumLineHeight = 0
        p.paragraphSpacing = paged ? 0 : theme.baseFontSize * theme.paragraphSpacingRatio
        if rtl { p.baseWritingDirection = .rightToLeft }
        if let alignment { p.alignment = alignment }
        if !tabStops.isEmpty { p.tabStops = resolvedTabStops(tabStops, columnWidth: columnWidth, paged: paged) }
        // Body only: a `.multiple` line rule never renders below the readability floor (see
        // `OfficeStyle.bodyMinLineHeightRatio`). Headings pass none — they are effectively single-line
        // and carry their own comfortable `headingLineHeightRatio`.
        //
        // PAGED: both floors are switched OFF. Their entire justification (RenderTheme.swift:138-156)
        // is that a dense document rendering tighter than this reader's OWN markdown body "reads as a
        // defect" — a reader-first judgement that holds while office text is being re-typeset at the
        // READER's 16pt size, and stops holding the moment the reader is deliberately reproducing the
        // author's page. Measured on a typical Korean report at a 10pt document default they cost
        // +1pt on every line and +2pt on every paragraph gap, and because `cellContent` routes every
        // table cell through this same style they are paid again on every row of every table — half
        // of the "표가 너무 큼" the owner reported. The no-page-width fallback keeps them, because
        // there the old window-filling model (and its justification) is still what is running.
        let officeStyle = OfficeStyle(theme: theme)
        applyParagraphFormat(format, fontSizeScale: fontSizeScale,
                             minLineHeight: paged ? 0 : theme.baseFontSize * officeStyle.bodyMinLineHeightRatio,
                             minParagraphSpacing: paged ? 0 : theme.baseFontSize * officeStyle.bodyMinParagraphSpacingRatio,
                             to: p)
        return p.copy() as! NSParagraphStyle
    }

    /// The font a heading's spans START from. `RenderTheme.headingFont(level:)` is
    /// `.systemFont(weight: .semibold)`, so every office heading used to be drawn SEMIBOLD whatever
    /// its runs said — a weight the document never asked for, and one that on a Korean face is also
    /// WIDER, so a heading wrapped where the document's own weight would not have.
    ///
    /// PAGED drops the weight and keeps the size, letting `Span.bold` decide — which is only safe
    /// because `DocxReader` now resolves bold through the `w:basedOn` style chain
    /// (`resolvedBold`/`toggleState`). Before that it read only the run's DIRECT `w:rPr`, and a Word
    /// heading takes its bold from its STYLE: measured on two real reports, 39 of 39 and 38 of 38
    /// headings carried no run-bold at all while their `heading 1/2/3` styles declared `<w:b/>`, so
    /// this same change would have un-bolded every one of them. ODT and HWP already carried a
    /// resolved weight.
    ///
    /// The size is taken from the theme's own heading font rather than recomputed, so this stays
    /// correct if the app's heading ladder changes or is removed — it only ever REMOVES the weight.
    ///
    /// One honest limit: a span that needed font SUBSTITUTION carries a descriptor
    /// `FontSubstitutionResolver` resolved at READ time against `blockWeight: .semibold`, and
    /// `spansAttributedString` uses such a descriptor verbatim (re-traiting a resolved private
    /// system-UI descriptor is measured-unreliable — see its own comment). So a substituted heading
    /// run still draws semibold. That is the majority-inert case, not the common one: a
    /// `resolvedFontDescriptor` is nil for the overwhelming majority of spans.
    private static func headingBaseFont(level: Int, theme: RenderTheme, paged: Bool) -> NSFont {
        let themed = theme.headingFont(level: level)
        guard paged else { return themed }
        // PAGED: no ladder and no weight of our own. The owner's rule, verbatim — "그냥 우리 자체
        // 판단을 버리고, 파싱하는 정보 그대로 다 보여지게 하자 (정의되지 않은 값들만 디폴트를 뭘로
        // 지정할지만 옵션)" — leaves exactly one decision here, WHICH default an unstated heading
        // size takes, and the honest answer is the document's own default body size. That is also
        // what Word draws: measured on the file this came from, its `heading 1` style declares 12pt
        // while `heading 3/4/5` declare no size at all, so Word renders those at the document
        // default — where the ladder drew them at 12 x 1.875 = 22.5 and 12 x 1.25 = 15. That gap is
        // the "폰트가 과도하게 큼" reported after comparing us against Word and Pages.
        //
        // A heading whose runs DO state a size is unaffected: `spansAttributedString` replaces this
        // base with the authored size either way.
        return .systemFont(ofSize: theme.baseFontSize)
    }

    /// The size a heading's own RUNS state, in points, already through `fontSizeScale` — `nil` when
    /// none of them state one, which is the case `RenderTheme.headingSize(level:)` exists for. The
    /// LARGEST is taken: this feeds a line-height FLOOR, and a floor derived from the smallest run
    /// of a mixed-size heading would sit under its tallest glyphs.
    private static func headingOwnSize(_ spans: [Span], fontSizeScale: CGFloat) -> CGFloat? {
        guard let largest = spans.compactMap({ $0.fontSize }).max() else { return nil }
        return largest * fontSizeScale
    }

    /// The line-height FLOOR is derived from the heading's OWN spans, and this function takes them
    /// rather than a precomputed basis ON PURPOSE. It was a `lineHeightBasis: CGFloat?` parameter
    /// first, and that shape lost the rule twice in one afternoon: a caller that reshapes this call
    /// (and both callers were reshaped) writes `nil` for it without anything failing to compile, and
    /// the floor silently falls back to the ladder. Passing the spans makes the rule impossible to
    /// drop by editing a call site — the decision lives here, with the arithmetic it feeds.
    private static func headingParagraphStyle(level: Int, spans: [Span] = [], theme: RenderTheme,
                                               rtl: Bool = false,
                                               alignment: NSTextAlignment? = nil,
                                               tabStops: [TabStop] = [],
                                               format: ParagraphFormat? = nil,
                                               fontSizeScale: CGFloat = 1,
                                               paged: Bool = false,
                                               lineGridPitch: CGFloat? = nil,
                                               columnWidth: CGFloat = .greatestFiniteMagnitude) -> NSParagraphStyle {
        let b = theme.baseFontSize
        let style = OfficeStyle(theme: theme)
        let p = NSMutableParagraphStyle()
        // The floor is a ratio of the heading's OWN size wherever the document stated one (paged) —
        // not of `theme.headingSize(level:)`, which is the app's ladder over the document's default
        // body size and has nothing to do with what this heading was authored at. Concretely, an
        // 11pt-default report whose H1 runs declare 19pt got a floor of 11 × 1.875 × 1.25 = 26pt
        // under a 19pt line: a heading held apart from its own text by 7pt of invented leading.
        // Where the runs state NOTHING the ladder is still the only size there is, so the basis
        // falls back to it — and so does every NON-paged call, byte-identically to before this.
        // Paged: the floor follows the heading's own stated size, and where it states none it follows
        // the size the heading is ACTUALLY drawn at — the document's default body size, since the
        // ladder is gone (see `headingBaseFont`). Unpaged keeps the ladder, unchanged.
        let basis = paged
            ? (headingOwnSize(spans, fontSizeScale: fontSizeScale) ?? theme.baseFontSize)
            : theme.headingSize(level: level)
        let lh = (basis * theme.headingLineHeightRatio).rounded()
        p.minimumLineHeight = lh
        // Cleared for the SAME reason the body path was (see `bodyParagraphStyle`, and the comment
        // there naming a 32pt HWP title whose glyphs overlapped at ~23pt): a cap derived from the
        // app's own heading scale CLIPS a heading the document made larger than that scale. The
        // heading path was missed when body was fixed, and the paged model made it bite: the cap now
        // shrinks with the document's own base (11pt → H1 cap 26) while the run's size is taken
        // verbatim, so an ordinary 22–28pt Word/HWP title is cut. A floor still governs anything
        // shorter, and an explicit line rule from the document still overrides both.
        p.maximumLineHeight = 0
        // Paged: no invented space around a heading either. `applyParagraphFormat` below still
        // applies whatever the document's own `spacingBefore`/`spacingAfter` resolved to, so a
        // document that asked for room gets exactly the room it asked for — and one that asked for
        // none gets none, instead of the app's 1.9x/0.4x editorial rhythm on top.
        p.paragraphSpacing = paged ? 0 : b * theme.headingSpacingAfterRatio
        p.paragraphSpacingBefore = paged ? 0 : style.headingSpacingBefore(level: level)
        if rtl { p.baseWritingDirection = .rightToLeft }
        if let alignment { p.alignment = alignment }
        if !tabStops.isEmpty { p.tabStops = resolvedTabStops(tabStops, columnWidth: columnWidth, paged: paged) }
        applyParagraphFormat(format, fontSizeScale: fontSizeScale, to: p)
        return p.copy() as! NSParagraphStyle
    }

    /// Turns a paragraph's authored `tabStops` into `NSTextTab`s for build time ONLY — an ordinary
    /// paragraph (no fill-margin tab, `fillMarginTabInfo` returns nil) maps every stop straight
    /// through via `officeTextTab`, byte-identical to before this attribute existed. A fill-margin
    /// paragraph instead gets `fillMarginTabStops` at a PLACEHOLDER width: the real `columnWidth`
    /// minus `fillMarginTrailingInset` when the caller supplied one (every real render call —
    /// `MarkdownDocument.render(into:)` always does), or the tab's own authored `position`
    /// otherwise (every test/cell-content call site that builds with the default sentinel column,
    /// where "no reflow will ever correct this" makes the original position the honest answer).
    /// Either way this is only ever a STARTING point — `DocumentWindowController.updateTextInset`
    /// re-anchors it to the actual reading column on first layout and every reflow after.
    private static func resolvedTabStops(_ tabStops: [TabStop], columnWidth: CGFloat,
                                          paged: Bool = false) -> [NSTextTab] {
        // PAGED: the authored position is kept, full stop. This whole mechanism exists to correct a
        // MISMATCH between the source page's width and this reader's window-sized column (see
        // `MDAttr.fillMarginTab`), and a paged document has no mismatch — the column IS the page
        // body, so the position the author wrote is already the position it should be drawn at.
        // Rebuilding it anyway does pure damage twice over: a TOC page number lands
        // `fillMarginTrailingInset` (12pt) left of where the author put it and stays there for good
        // (`DocumentWindowController.updateTextInset` skips `reanchorFillMarginTabs` when paged), and
        // a right tab the author placed MID-column — at 200pt in a 451pt page, an ordinary two-column
        // header — is yanked out to 439pt, because `fillMarginTabInfo` picks the RIGHTMOST right tab
        // with no proximity test at all and this branch then discards its position outright.
        guard !paged else { return tabStops.map(officeTextTab) }
        guard let info = fillMarginTabInfo(from: tabStops) else { return tabStops.map(officeTextTab) }
        let hasRealColumn = columnWidth < .greatestFiniteMagnitude
        let width: CGFloat
        if hasRealColumn {
            width = max(0, columnWidth - fillMarginTrailingInset)
        } else {
            width = tabStops.max(by: { $0.position < $1.position })?.position ?? 0
        }
        return fillMarginTabStops(info, width: width)
    }

    /// Trailing gap (points) between a fill-margin tab (a TOC page number, say) and the reading
    /// column's own right edge — small enough the number still reads flush-right, not crowded
    /// against the very edge. Shared with `DocumentWindowController.updateTextInset`, which
    /// re-anchors this tab to the CURRENT column on every reflow (see `MDAttr.fillMarginTab`).
    // Must clear the text container's default lineFragmentPadding (5pt) plus the right-tab rounding
    // slack, or a right-aligned tab placed a hair OUTSIDE the wrap boundary pushes its number onto a
    // second line — the "number on an extra line" regression. The wrap threshold was MEASURED at ~9pt
    // (8pt wraps, 10pt holds, `lineFragmentPadding` 5); 12pt sits comfortably above it while reading
    // flush-right — the page number lands ~16pt in from the edge, not the 28pt a larger safety margin
    // once cost. Larger is safe but visibly not flush; smaller risks the wrap.
    static let fillMarginTrailingInset: CGFloat = 12

    /// The rightmost tab in `tabStops`, when it is right- or decimal-aligned, marks the paragraph
    /// as "fill to margin": a right tab exists to push text — a TOC page number, a right-aligned
    /// header — out to the paragraph's own trailing edge, and that edge was authored against the
    /// SOURCE document's page margin, not this reader's window-width reading column (see
    /// `MDAttr.fillMarginTab`'s doc for the width mismatch this exists to correct). A LEFT- or
    /// CENTER-aligned rightmost tab is an ordinary tab stop and is left alone (returns `nil`) —
    /// this only ever narrows behaviour onto paragraphs that authored a real trailing right/
    /// decimal tab; every other paragraph (the overwhelming common case, and every markdown/
    /// plain-text block, which carries no tab-stop vocabulary at all) is unaffected.
    static func fillMarginTabInfo(from tabStops: [TabStop]) -> FillMarginTabInfo? {
        guard let (i, rightmost) = tabStops.enumerated().max(by: { $0.element.position < $1.element.position })
        else { return nil }
        guard rightmost.alignment == .right || rightmost.alignment == .decimal else { return nil }
        var others = tabStops
        others.remove(at: i)
        return FillMarginTabInfo(marginAlignment: rightmost.alignment, marginLeader: rightmost.leader,
                                  otherTabs: others)
    }

    /// Rebuilds tab stops so the fill-margin tab sits at `width` — an absolute point, already the
    /// caller's chosen right edge (minus whatever inset it wants) — while every OTHER authored tab
    /// stop keeps its own original position. This is the ONE place that turns `FillMarginTabInfo`
    /// back into real `NSTextTab`s, called both at build time (`resolvedTabStops`, a placeholder
    /// width) and on every later reflow (`DocumentWindowController.reanchorFillMarginTabs`, the
    /// reading column's CURRENT width) — so a TOC's page numbers track the window instead of
    /// staying pinned to the document's own page margin.
    static func fillMarginTabStops(_ info: FillMarginTabInfo, width: CGFloat) -> [NSTextTab] {
        let margin = TabStop(position: width, alignment: info.marginAlignment, leader: info.marginLeader)
        return (info.otherTabs + [margin]).map(officeTextTab)
    }

    /// Builds ONE `NSTextTab` from an authored `TabStop` — `.left`/`.center`/`.right` map straight
    /// onto `NSTextAlignment`'s own cases (Apple's modern, non-deprecated `NSTextTab` initializer
    /// is ALREADY alignment-based, so this is a direct translation, not an emulation). `.decimal`
    /// has no `NSTextAlignment` case at all (the deprecated `NSTextTab(type:location:)`/
    /// `.decimalTabStopType` initializer is the only API that names one, and this codebase avoids
    /// deprecated AppKit surface) — the documented, still-current replacement (the header comment
    /// on `NSTextTab`'s alignment initializer) is `.right` alignment plus a column terminator
    /// character set: text runs up TO the tab stop right-aligned, then a further terminator
    /// (the decimal point) ends that column, which is what actually makes a `12.5` and a `100.25`
    /// line their decimal points up under this stop — the same visible effect `.decimal` names.
    /// `leader` is READ but never turned into a drawing instruction here — see `TabLeader`'s own
    /// doc for why (no native AppKit primitive, and a faithful fill is a deferred rendering cost).
    /// Marks every TAB character in `range` with the leader the document asked a tab to fill with —
    /// the `······` between a contents entry and its page number. Drawn by `drawMDDecorations`;
    /// `NSTextTab` carries no leader of its own, so this attribute is the only way the information
    /// survives to draw time.
    ///
    /// ONE leader per paragraph, taken from the LAST stop that declares one: which stop a given tab
    /// actually lands on is a layout answer, not a build-time one, and a contents line has exactly
    /// one leader tab — the trailing right-aligned stop that carries the page number. A paragraph
    /// whose stops declare no leader is untouched, which is every markdown, plain-text and ODT
    /// paragraph and most docx ones (invariant 37).
    private static func markTabLeaders(_ tabStops: [TabStop], in range: NSRange,
                                       on result: NSMutableAttributedString) {
        guard let leader = tabStops.last(where: { $0.leader != .none })?.leader,
              let character = leaderCharacter(leader) else { return }
        let text = result.string as NSString
        var index = range.location
        while index < range.upperBound {
            let found = text.range(of: "\t", options: [], range: NSRange(location: index, length: range.upperBound - index))
            guard found.location != NSNotFound else { break }
            result.addAttribute(MDAttr.tabLeader, value: character, range: found)
            index = found.upperBound
        }
    }

    /// The character a `TabLeader` fills with. `.none` has none, which is why this is optional.
    static func leaderCharacter(_ leader: TabLeader) -> String? {
        switch leader {
        case .none: return nil
        case .dot: return "."
        case .hyphen: return "-"
        case .underscore: return "_"
        }
    }

    private static func officeTextTab(_ stop: TabStop) -> NSTextTab {
        switch stop.alignment {
        case .left: return NSTextTab(textAlignment: .left, location: stop.position, options: [:])
        case .center: return NSTextTab(textAlignment: .center, location: stop.position, options: [:])
        case .right: return NSTextTab(textAlignment: .right, location: stop.position, options: [:])
        case .decimal:
            return NSTextTab(textAlignment: .right, location: stop.position,
                             options: [.columnTerminators: CharacterSet(charactersIn: ".")])
        }
    }

    /// Applies the P2 cascade's resolved `ParagraphFormat` on top of whatever theme-token defaults
    /// the caller already set on `p` — per-field, only when the source specified that field (`nil`
    /// leaves the token value exactly as it was, which is what makes a paragraph with an entirely
    /// unspecified cascade render byte-identical to the pre-P2 token path). Order matters: this
    /// runs AFTER the caller's own token defaults, since `lineRule="atLeast"` must explicitly clear
    /// the `maximumLineHeight` cap those defaults set (a plain unset would leave the old cap active,
    /// silently reintroducing the very clipping `atLeast` exists to prevent).
    ///
    /// `fontSizeScale` is `theme.baseFontSize / documentDefaultFontSize` (see `build`'s doc) — every
    /// POINT value the source declared is scaled by it, exactly like `Span.fontSize`, so a
    /// document's own spacing/indent stays proportional at any reading-size setting.
    /// `lineHeightMultiple` is NOT scaled — `LineHeight.multiple` is already a unitless ratio
    /// (`w:lineRule="auto"`'s `line/240`), not a point value.
    private static func applyParagraphFormat(_ format: ParagraphFormat?, fontSizeScale: CGFloat,
                                              minLineHeight: CGFloat = 0, minParagraphSpacing: CGFloat = 0,
                                              to p: NSMutableParagraphStyle) {
        guard let format else { return }
        if let before = format.spacingBefore { p.paragraphSpacingBefore = before * fontSizeScale }
        if let after = format.spacingAfter {
            // A POSITIVE author gap never drops below the readability floor (see
            // `OfficeStyle.bodyMinParagraphSpacingRatio`); an EXACTLY-zero gap (a deliberate
            // "no space", incl. `contextualSpacing`'s zeroing) stays zero, the floor not applied.
            let scaled = after * fontSizeScale
            p.paragraphSpacing = scaled > 0 ? max(scaled, minParagraphSpacing) : scaled
        }
        if let lineHeight = format.lineHeight {
            switch lineHeight {
            case .multiple(let ratio):
                p.lineHeightMultiple = ratio
                // Clear the caller's token min/max the SAME way `.atLeast` does below: the token
                // default set `minimumLineHeight == maximumLineHeight == lh` (a FIXED line height),
                // and a live `maximumLineHeight` cap clamps `naturalHeight * ratio` back down to
                // `lh` — silently squeezing a document that asked for e.g. `w:line="260"` (1.083×)
                // into the app's own tighter fixed rhythm. That was the "줄간격이 너무 타이트" bug:
                // the multiple was set but never allowed to take effect. A multiple is a ratio of the
                // line's own natural height, so it governs upward freely — the maximum is cleared so
                // a document that asks for MORE than the floor gets exactly that. The minimum is the
                // readability FLOOR (`OfficeStyle.bodyMinLineHeightRatio`, 0 for callers that pass
                // none): a near-single rule measured against the substituted body font renders far
                // tighter than the same reader's markdown body, so office body never drops below it.
                p.minimumLineHeight = minLineHeight
                p.maximumLineHeight = 0
            case .exact(let pt):
                let v = pt * fontSizeScale
                p.minimumLineHeight = v
                p.maximumLineHeight = v
            case .atLeast(let pt):
                p.minimumLineHeight = pt * fontSizeScale
                p.maximumLineHeight = 0 // a floor, not a cap — clears the token's own maximum.
            }
        }
        if format.indentStart != nil || format.indentEnd != nil || format.firstLineIndent != nil
            || format.hangingIndent != nil {
            // `NSParagraphStyle.headIndent`/`firstLineHeadIndent` per the spec's own mapping (area
            // 5): unspecified components read as 0, so a level that sets ONLY `spacingBefore`
            // (say) never reaches this block at all, and a level that sets exactly one indent
            // component still combines correctly with the other three at their neutral value.
            let start = (format.indentStart ?? 0) * fontSizeScale
            let firstLine = (format.firstLineIndent ?? 0) * fontSizeScale
            let hanging = (format.hangingIndent ?? 0) * fontSizeScale
            p.headIndent = start
            p.firstLineHeadIndent = start + firstLine - hanging
            if let end = format.indentEnd {
                // AppKit's own convention (already used by the markdown code-card header/footer,
                // `MarkdownRenderer.swift`'s `tailIndent = -CodeCardMetrics.textInset`): a positive
                // `tailIndent` measures from the LEFT margin, so the OOXML "distance from the right
                // edge" must be negated to land in the same place.
                p.tailIndent = -(end * fontSizeScale)
            }
        }
    }

    // MARK: Lists

    /// Bullet glyph per depth so nested levels read distinctly: • → ◦ → ▪ (then repeat) — same
    /// progression `MarkdownRenderer.bullet(_:)` uses.
    private static func bulletGlyph(_ level: Int) -> String {
        switch level % 3 {
        case 0:  return "•"
        case 1:  return "◦"
        default: return "▪"
        }
    }

    /// Hanging-indent paragraph style: marker at `markerX`, a tab pushes text to `textX`, and
    /// wrapped lines align at `textX` — so the item's first line and every wrap share one edge.
    /// `extraTabStops` (points, from `OfficeBlock.listItem.tabStops`) are AUTHORED stops beyond the
    /// marker's own — appended after the marker tab, never in place of it, so `1.\t<text>` still
    /// reaches the item's hanging indent first (this is the sprint brief's own required case: a
    /// custom tab stop must coexist with, not break, list indentation).
    private static func listParagraphStyle(markerX: CGFloat, textX: CGFloat, theme: RenderTheme,
                                            rtl: Bool = false, alignment: NSTextAlignment? = nil,
                                            extraTabStops: [TabStop] = [],
                                            format: ParagraphFormat? = nil,
                                            paged: Bool = false,
                                            lineGridPitch: CGFloat? = nil,
                                            fontSizeScale: CGFloat = 1) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * theme.lineHeightRatio).rounded()
        // Paged: the app's line rhythm and inter-item gap are BOTH withheld, exactly as in
        // `bodyParagraphStyle` — a list item is a paragraph and gets the same treatment. What the
        // document itself states still arrives through `applyParagraphFormat` below.
        p.minimumLineHeight = paged ? (lineGridPitch ?? 0) : lh
        // Cleared for the same reason as body and heading: pinning the maximum to the app's own
        // rhythm clips a list item whose run the document made larger than the document default
        // (a 14pt callout in an 11pt document is capped at 16 against a ~17pt natural line). A
        // floor, not a cap.
        p.maximumLineHeight = 0
        p.paragraphSpacing = paged ? 0 : theme.baseFontSize * theme.tightSpacingRatio
        p.firstLineHeadIndent = markerX
        p.headIndent = textX
        // NOT routed through `resolvedTabStops`: a list item's authored stops have ALWAYS been mapped
        // straight through here, never re-anchored to the column, so there is no fill-margin
        // correction to switch off for paged (item 7 is a body/heading question only). Sending them
        // through it "for symmetry" would newly apply that correction to every NON-paged list item,
        // which is a change to the model that must stay byte-identical.
        p.tabStops = [NSTextTab(textAlignment: .left, location: textX)] + extraTabStops.map(officeTextTab)
        p.defaultTabInterval = textX
        // The marker/hang-indent geometry (`markerX`/`textX`) is left exactly as it is for an LTR
        // item — mirroring it for RTL (marker on the right, indent growing leftward) is real work
        // this sprint's brief scoped out (base direction only); `baseWritingDirection` alone is
        // enough for TextKit to draw the text right-to-left, just still left-indented.
        if rtl { p.baseWritingDirection = .rightToLeft }
        if let alignment { p.alignment = alignment }
        // Applied LAST, same as the body/heading paths — a list item's own direct `w:pPr` spacing/
        // line-height/indent (P2's cascade) wins over the marker/hang-indent geometry above when
        // the source specified it; an unspecified cascade (the overwhelming common case — Word's
        // numbering, not a paragraph's own `w:ind`, usually carries a list's indentation) leaves
        // `markerX`/`textX` exactly as before this sprint.
        applyParagraphFormat(format, fontSizeScale: fontSizeScale, to: p)
        return p.copy() as! NSParagraphStyle
    }

    /// Renders one list item and updates the per-level numbering state.
    ///
    /// Restart rule (the only stateful part of this file, and only when `marker` is `nil` — see
    /// below): any item at `level` clears the counters of every level DEEPER than it —
    /// a shallower-or-equal item breaks a deeper level's run, so that level restarts at 1 the next
    /// time it appears. A deeper level intervening does NOT clear a shallower level's own counter,
    /// so `1. / a. / b. / 2.` keeps counting `1, 2` at the outer level across the nested run. An
    /// UNORDERED item also clears its OWN level's counter, so a bullet breaks an ordered run at
    /// that same level too.
    ///
    /// `marker`, when supplied, is rendered VERBATIM and `orderedCounters` is left untouched —
    /// see `OfficeBlock.listItem`'s doc comment for why only the reader can compute real numbering
    /// text (continuation across paragraphs, `w:startOverride`, multi-level `%1.%2` formats). This
    /// builder's own counters are a fallback for when the source couldn't supply that text, not a
    /// second, competing numbering scheme — the two never mix for a single item.
    private static func appendListItem(level: Int, ordered: Bool, spans: [Span], marker suppliedMarker: String?,
                                       rtl: Bool = false, alignment: NSTextAlignment? = nil,
                                       tabStops: [TabStop] = [], into result: NSMutableAttributedString,
                                       theme: RenderTheme, orderedCounters: inout [Int: Int],
                                       fontSizeScale: CGFloat = 1, paged: Bool = false,
                                       lineGridPitch: CGFloat? = nil,
                                       format: ParagraphFormat? = nil,
                                       commentNumbers: [String: Int] = [:]) {
        let marker: String
        if let suppliedMarker {
            marker = suppliedMarker + "\t"
        } else {
            // Snapshot the keys first — removing while iterating `.keys` directly mutates the same
            // storage the view is walking.
            for deeper in orderedCounters.keys.filter({ $0 > level }) {
                orderedCounters.removeValue(forKey: deeper)
            }
            if ordered {
                let n = (orderedCounters[level] ?? 0) + 1
                orderedCounters[level] = n
                marker = "\(n).\t"
            } else {
                orderedCounters.removeValue(forKey: level)
                marker = bulletGlyph(level) + "\t"
            }
        }

        let hang = theme.baseFontSize * theme.listHangRatio
        let markerX = CGFloat(level) * hang
        let textX = CGFloat(level + 1) * hang
        let start = result.length
        // The item's text is rendered FIRST (into a local — the appended order is unchanged) so the
        // marker can be drawn to match it. PAGED takes the marker's SIZE and COLOUR from the item's
        // own first resolved span: a bullet beside a 14pt item was drawn at the document's default
        // 11pt, and a marker beside coloured text stayed the theme's ink. Deliberately size+colour
        // only — the FAMILY stays `theme.bodyFont`'s, so an item that opens with a monospaced `code`
        // run does not get a monospaced bullet, and a marker never inherits bold/italic/underline
        // from the word that happens to follow it. Read off the RENDERED run rather than off
        // `Span.fontSize` so it is the one cascade in `spansAttributedString` deciding this, not a
        // second copy of it here. Non-paged is unchanged: theme body font, theme ink.
        let body = spansAttributedString(spans, baseFont: theme.bodyFont, baseColor: theme.textColor,
                                          theme: theme, fontSizeScale: fontSizeScale, paged: paged,
                                          commentNumbers: commentNumbers)
        var markerFont = theme.bodyFont
        var markerColor = theme.textColor
        if paged, body.length > 0 {
            let first = body.attributes(at: 0, effectiveRange: nil)
            if let f = first[.font] as? NSFont,
               let sized = NSFont(descriptor: theme.bodyFont.fontDescriptor, size: f.pointSize) {
                markerFont = sized
            }
            if let c = first[.foregroundColor] as? NSColor { markerColor = c }
        }
        result.append(NSAttributedString(string: marker,
            attributes: [.font: markerFont, .foregroundColor: markerColor]))
        result.append(body)
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle,
                            value: listParagraphStyle(markerX: markerX, textX: textX, theme: theme, rtl: rtl,
                                                       alignment: alignment, extraTabStops: tabStops,
                                                       format: format, paged: paged,
                                                       lineGridPitch: lineGridPitch, fontSizeScale: fontSizeScale),
                            range: NSRange(location: start, length: result.length - start))
    }

    // MARK: Tables

    /// Real bordered grid via the shared `TableBlockBuilder` (also used by `MarkdownRenderer`'s
    /// GFM tables) — an office table now looks and behaves exactly like a markdown one, not a
    /// tab-stop approximation. `headerRows: 0` shades no row, because the source didn't say any
    /// row was a header (see `OfficeBlock.table`; guessing "row one" would misrepresent a
    /// headerless table). A cell shorter than the widest row leaves its trailing columns empty
    /// rather than collapsing the row.
    private static func appendTable(_ rows: [[Cell]], headerRows: Int, columnWidths: [CGFloat] = [],
                                    tableFormat: TableFormat = TableFormat(),
                                    into result: NSMutableAttributedString,
                                    theme: RenderTheme, fontSizeScale: CGFloat = 1,
                                    columnWidth: CGFloat = .greatestFiniteMagnitude,
                                    graphicBasis: CGFloat? = nil,
                                    paged: Bool = false,
                                    lineGridPitch: CGFloat? = nil,
                                    tableWidth: CGFloat? = nil) {
        guard rows.contains(where: { !$0.isEmpty }) else {
            result.append(NSAttributedString(string: "\n"))
            return
        }
        // PAGED: a header row's runs decide their own weight. `headerRows` comes from docx
        // `w:tblHeader` (`DocxReader` reads it as `headerRows`), and ECMA-376 §17.4.49 defines that
        // as "repeat this row at the top of each page" — a PAGINATION instruction, not emphasis.
        // Bolding on it states something the document did not, and on a Korean face the bold form is
        // also WIDER, so the header row's cells wrap at different points than the body rows under
        // them — the column reads as misaligned for a reason nothing in the document explains. Where
        // a header really is emphasised the runs say so (`Span.bold`) and it stays bold either way.
        // Non-paged keeps the app's own convention, which is the model that branch is still running.
        //
        // This changes the WEIGHT only. The header row's SHADING is a different decision made in a
        // different place — `TableBlockBuilder` gives a header cell `Palette.tableHeaderBg`, and only
        // as a last resort, after the cell's own, the table's, and the table style's shading — and it
        // is deliberately left exactly as it is here.
        let headerFont = paged ? theme.bodyFont : fontAdding(.bold, to: theme.bodyFont)
        // Each cell's absolute content width at the reading column, resolved by `TableBlockBuilder`'s
        // own placement + edge geometry (single source of truth for column math) so a cell IMAGE can
        // be clamped to its column at BUILD time — mirroring the top-level `.image` path, which
        // already clamps to `columnWidth`. Padding/border are resolved here EXACTLY as
        // `TableBlockBuilder.build`'s per-placement loop does (cell-direct > table-default >
        // style > floor/1 for non-paged; cell-edge > table-edge > `defaultCellPadding` fallback for
        // paged, via the SAME `TableBlockBuilder.resolvedPagedPadding` `build` itself calls — two
        // independent copies of this cascade is exactly the drift invariant 47 warns about), then
        // handed to the helper so the width math stays in one place. `AnchorSpan.padding` only ever
        // needs an APPROXIMATE horizontal figure (this feeds a build-time image clamp, not the real
        // grid — see its own doc: "a slightly generous estimate is harmless"), so a paged cell's
        // asymmetric left/right edges are averaged into the one number that shape wants.
        let spanGrid: [[TableBlockBuilder.AnchorSpan]] = rows.map { anchors in
            anchors.map { cell in
                let padding: CGFloat
                if paged {
                    let resolved = TableBlockBuilder.resolvedPagedPadding(cell: cell.edgePadding,
                                                                          table: tableFormat.defaultPadding)
                    padding = (resolved.left + resolved.right) / 2
                } else {
                    padding = max(cell.padding ?? TableBlockBuilder.defaultCellPadding,
                                  TableBlockBuilder.defaultCellPadding)
                }
                let borderWidth = cell.borderWidth ?? tableFormat.defaultBorderWidth
                    ?? cell.styleBorderWidth ?? 1
                return TableBlockBuilder.AnchorSpan(rowSpan: cell.rowSpan, colSpan: cell.colSpan,
                                                    padding: padding, borderWidth: borderWidth)
            }
        }
        // The width the table is really laid out at (the reading column minus the text container's
        // own padding), so cell content widths and the built grid agree with the final layout from
        // the FIRST paint — see `TableBlockBuilder.build`'s `width`. For a PAGED document, clamped
        // DOWN to the table's own authored width (`TableFormat.sourceWidth`) when it declared one
        // narrower than the column — Job 2: a table drawn at 68% of the page body must not become
        // 100% of it just because the reader fills the column. Never clamped UP: a table wider than
        // the column, or a non-paged one, still fills it exactly as before this existed. `maxWidth`
        // is ALSO handed to `TableBlockBuilder.build` below so a LATER reflow re-derives the same
        // clamp against the full column rather than re-stretching the table back out to it.
        let requestedWidth = tableWidth ?? columnWidth
        let maxWidth: CGFloat? = paged ? tableFormat.sourceWidth : nil
        let solvedWidth = GridTextTable.clampedWidth(requestedWidth, maxWidth: maxWidth)
        let cellContentWidths = TableBlockBuilder.anchorContentWidths(spans: spanGrid,
                                                                      columnWidths: columnWidths,
                                                                      width: solvedWidth)
        let cellRows: [[TableBlockBuilder.CellContent]] = rows.enumerated().map { r, anchors in
            let isHeader = r < headerRows
            return anchors.enumerated().map { i, cell in
                let content = cellContent(cell.blocks, baseFont: isHeader ? headerFont : theme.bodyFont,
                                          theme: theme, fontSizeScale: fontSizeScale,
                                          imageColumnWidth: cellContentWidths[r][i],
                                          graphicBasis: graphicBasis, paged: paged,
                                          lineGridPitch: lineGridPitch, tableWidth: solvedWidth)
                return TableBlockBuilder.CellContent(content: content, rowSpan: cell.rowSpan, columnSpan: cell.colSpan,
                                                      backgroundColor: cell.backgroundColor,
                                                      backgroundImage: cell.backgroundImage,
                                                      borderColor: cell.borderColor, borderWidth: cell.borderWidth,
                                                      width: cell.width, verticalAlignment: cell.verticalAlignment,
                                                      padding: cell.padding, styleShading: cell.styleShading,
                                                      styleBorderColor: cell.styleBorderColor,
                                                      styleBorderWidth: cell.styleBorderWidth,
                                                      edgeBorders: cell.edgeBorders, edgePadding: cell.edgePadding)
            }
        }
        result.append(TableBlockBuilder.build(rows: cellRows, headerRows: headerRows, theme: theme,
                                              columnWidths: columnWidths,
                                              tableBorderColor: tableFormat.defaultBorderColor,
                                              tableBorderWidth: tableFormat.defaultBorderWidth,
                                              tableShading: tableFormat.defaultShading,
                                              tableEdges: tableFormat.edgeBorders,
                                              tablePadding: tableFormat.defaultPadding,
                                              tableBackgroundImage: tableFormat.backgroundImage,
                                              paged: paged, maxWidth: maxWidth,
                                              width: solvedWidth))
        result.append(NSAttributedString(string: "\n"))
    }

    /// Renders one cell's blocks. Deliberately NOT `build(_:theme:columnWidth:)` reused wholesale:
    /// that function ends every block with its own trailing `"\n"` PLUS a block-level paragraph
    /// style (heading/body line-height, paragraph spacing) sized for the full text column — inside
    /// a cell that fights `TableBlockBuilder`'s own paragraph style (`cellLH`, applied to the whole
    /// cell content afterwards) and would draw a spurious blank line under a single-paragraph cell.
    /// So the SEPARATOR is minimal here (a plain `"\n"` between blocks, none after the last) and no
    /// block gets its own `.paragraphStyle` — everything folds into the outer cell paragraph style.
    /// The single-block, single-paragraph case (the compatibility initialiser's shape) therefore
    /// renders BYTE-IDENTICAL to the pre-sprint `spansAttributedString(cell.spans, …)` call this
    /// replaces: no separator is ever emitted around a lone block.
    ///
    /// `.table` is handled by flattening rather than recursing into `appendTable`/
    /// `TableBlockBuilder` — a cell must never contain a REAL nested `NSTextTable` grid (the
    /// project's standing "nested tables flatten to text" decision, applied identically by both
    /// readers at parse time; this is the renderer's own backstop in case a `.table` block ever
    /// reaches a cell some other way).
    /// `imageColumnWidth` is the cell's resolved content width (from `appendTable`'s
    /// `TableBlockBuilder.anchorContentWidths`); a cell `.image`/`.unsupportedGraphic` wider than it
    /// is shrunk aspect-preserving via `fittedOfficeSize`, exactly as a top-level image clamps to the
    /// reading column. `.greatestFiniteMagnitude` (the default) = "no column known" = no clamp, so
    /// callers/tests that never pass it behave as before. Clamped at BUILD time only (invariant 1).
    private static func cellContent(_ blocks: [OfficeBlock], baseFont: NSFont, theme: RenderTheme,
                                    fontSizeScale: CGFloat = 1,
                                    imageColumnWidth: CGFloat = .greatestFiniteMagnitude,
                                    graphicBasis: CGFloat? = nil,
                                    paged: Bool = false,
                                    lineGridPitch: CGFloat? = nil,
                                    tableWidth: CGFloat = .greatestFiniteMagnitude) -> NSAttributedString {
        // A cell picture's scale is the TABLE's on-screen width over the table's source width — not
        // the cell's over the cell's. They are the same ratio (every column keeps its proportion when
        // the table is stretched), and using the table's avoids needing each cell's source width.
        let cellGraphicScale: CGFloat = {
            guard let graphicBasis, graphicBasis > 0, tableWidth.isFinite, tableWidth > 0 else { return 1 }
            return tableWidth / graphicBasis
        }()
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            switch block {
            // `rtl`/`alignment`/`tabStops` are dropped here (`_`), not lost: a cell's own paragraph
            // style comes from `TableBlockBuilder`'s shared `cellLH` treatment, not from
            // `bodyParagraphStyle`/`headingParagraphStyle`/`listParagraphStyle` above, so there is
            // nowhere in a cell to apply a per-block paragraph override without reaching into that
            // shared builder (out of this sprint's file scope). A cell's RUN-level styling
            // (`Span.rtl`, `Span.textColor`, …) still applies, unaffected — it's carried entirely
            // inside `spansAttributedString`.
            case let .heading(level, spans, rtl, alignment, tabStops, format):
                let headingBase = headingBaseFont(level: level, theme: theme, paged: paged)
                let str = NSMutableAttributedString(attributedString:
                    spansAttributedString(spans, baseFont: headingBase,
                                          baseColor: theme.textColor, theme: theme,
                                          fontSizeScale: fontSizeScale, paged: paged))
                str.addAttribute(.paragraphStyle,
                    value: headingParagraphStyle(level: level, spans: spans, theme: theme, rtl: rtl,
                                                 alignment: alignment, tabStops: tabStops, format: format,
                                                 fontSizeScale: fontSizeScale, paged: paged,
                                                 lineGridPitch: lineGridPitch),
                    range: NSRange(location: 0, length: str.length))
                result.append(str)
            case let .paragraph(spans, rtl, alignment, tabStops, format):
                let str = NSMutableAttributedString(attributedString:
                    spansAttributedString(spans, baseFont: baseFont, baseColor: theme.textColor,
                                          theme: theme, fontSizeScale: fontSizeScale, paged: paged))
                str.addAttribute(.paragraphStyle,
                    value: bodyParagraphStyle(theme: theme, rtl: rtl, alignment: alignment,
                                              tabStops: tabStops, format: format, fontSizeScale: fontSizeScale,
                                              paged: paged, lineGridPitch: lineGridPitch),
                    range: NSRange(location: 0, length: str.length))
                result.append(str)
            case let .listItem(level, ordered, spans, marker, _, _, _, _):
                // Cell-local numbering state — a list embedded in one cell doesn't continue a
                // count begun in a sibling cell or at top level.
                var counters: [Int: Int] = [:]
                appendListItem(level: level, ordered: ordered, spans: spans, marker: marker, into: result,
                                theme: theme, orderedCounters: &counters, fontSizeScale: fontSizeScale,
                                paged: paged, lineGridPitch: lineGridPitch)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .table(nestedRows, _, _, _):
                result.append(flattenTableToText(nestedRows, baseFont: baseFont, theme: theme))
            case let .image(id, size, alignment):
                // A CELL picture is clamped whether paged or not — see `fittedOfficeSize`'s doc for
                // why the bleed decision stops at the cell edge (invariant 39's fixed grid).
                appendImage(id: id, size: size, columnWidth: imageColumnWidth, basis: graphicBasis,
                            scale: cellGraphicScale, alignment: alignment, insideCell: true,
                            bleed: 0, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .unsupportedGraphic(label, size, alignment):
                appendUnsupportedGraphic(label: label, size: size, columnWidth: imageColumnWidth, basis: graphicBasis,
                                         scale: cellGraphicScale, alignment: alignment, insideCell: true,
                                         bleed: 0, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .formula(latex):
                appendFormula(latex: latex, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            }
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
        }
        // A block's paragraph style was applied to its spans but NOT to the "\n" separators appended
        // between blocks — and TextKit reads a paragraph's spacing/line-height from its TERMINATOR.
        // Unify each paragraph's style across its terminating newline (using the style at its start),
        // then TRIM the cell's own edges: the first paragraph's leading gap and the last paragraph's
        // trailing gap would pad the cell's inner top/bottom (a single-paragraph data cell would grow
        // by a whole paragraph gap) — that breathing is the cell's own vertical padding's job.
        //
        // The SECOND half of that same unification is `unifyTerminator` below: paragraph style alone
        // left the separator carrying the cell's base font and no colour while the text either side
        // carried its own resolved font and an `NSColor`, so it stayed a run of its own. Same pass,
        // same "attributes of the paragraph's own start" rule, one more step — see `unifyTerminator`.
        let ns = result.string as NSString
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: result.length), options: .byParagraphs) {
            _, _, enclosing, _ in
            if enclosing.length > 0 { paragraphs.append(enclosing) }
        }
        for (i, range) in paragraphs.enumerated() {
            guard let base = result.attribute(.paragraphStyle, at: range.location,
                                              effectiveRange: nil) as? NSParagraphStyle else { continue }
            let m = base.mutableCopy() as! NSMutableParagraphStyle
            if i == 0 { m.paragraphSpacingBefore = 0 }
            if i == paragraphs.count - 1 { m.paragraphSpacing = 0 }
            result.addAttribute(.paragraphStyle, value: m.copy() as! NSParagraphStyle, range: range)
            unifyTerminator(of: range, in: result, string: ns)
        }
        return result
    }

    /// Finishes the paragraph pass above: gives a paragraph's terminating `"\n"` the rest of the
    /// attributes its OWN first character carries, so the two collapse into ONE attribute run.
    ///
    /// This is invariant 51 one layer up. `TableBlockBuilder` merged the newline that ends a whole
    /// CELL; what it explicitly left behind — and named — is the separator `cellContent` joins
    /// between two blocks of a MULTI-PARAGRAPH cell. That separator was appended carrying the cell's
    /// base font and nothing else, while the text either side of it carries its own resolved font
    /// (a declared family, a substitute) and an `NSColor`, so every interior separator cost a second
    /// run. Measured through `OfficeTextBuilder.build` at a 700pt column: 2,176 of them on the
    /// 600-page reference manual and 271 on the report — and an attribute run is what installing a
    /// string into a live text view is priced by (~50 µs each, invariant 51).
    ///
    /// Three rules, each carried over from invariant 51 because each was earned there:
    ///
    /// **The separator belongs to the paragraph it TERMINATES, not to the one that follows.** It
    /// cannot merge with both when the two blocks are genuinely differently styled, and this side is
    /// forced rather than chosen: the loop above already stamps the PRECEDING paragraph's style on
    /// this character, so taking the following block's font would leave the separator matching
    /// NEITHER neighbour — one run saved becomes one run kept, and it would describe a paragraph that
    /// does not exist. Measured by mutation: reading the following paragraph instead prints
    /// `"\n둘째 문단"` as a run, a separator visibly attached to the wrong side. What that mutation
    /// does NOT do is move the laid-out geometry, and neither does anything else put here — for
    /// invariant 51's three reasons, unchanged: TextKit resolves a paragraph's metrics at its START,
    /// a trailing newline contributes no glyph of its own, and AppKit builds an attachment glyph only
    /// for U+FFFC. So the side is chosen for the RUN COUNT and for describing the document honestly,
    /// not to protect a pixel.
    ///
    /// **The attributes come from the paragraph's OWN START, never from the character before it.**
    /// That character belongs to the PREVIOUS block, and in invariant 51's case to the previous
    /// CELL, where copying it took the neighbour's `NSTextTableBlock` with it. The risk is milder
    /// inside one cell — the same cell, the same table block — but the discipline is what keeps this
    /// pass local to one paragraph. The consequence is honest and measured: a paragraph whose start
    /// and end differ (`**bold** then plain`) merges with neither and stays exactly as many runs as
    /// it was, no better and no worse.
    ///
    /// **Inheritance is an ALLOW-list** — `TableBlockBuilder.inheritableTerminatorAttributes`, the
    /// same one and deliberately not a second copy: it is the same question about the same character
    /// (invariant 36's one-place rule), and a divergent second list is how the two halves of this
    /// would drift apart. Everything that DRAWS or is CLICKED (`.attachment`, `.backgroundColor`,
    /// `.underlineStyle`/`.strikethroughStyle`, `.link`) is absent, so a paragraph ending in a
    /// picture, a highlight or a hyperlink falls back to exactly the separator it always had. A
    /// paragraph with no content of its own (an empty block between two others) has no attributes to
    /// inherit and keeps the bare separator, for invariant 51's empty-cell reason.
    private static func unifyTerminator(of paragraph: NSRange, in result: NSMutableAttributedString,
                                        string ns: NSString) {
        // A terminator only exists where the paragraph's enclosing range ends in one; the LAST block
        // of a cell has none (`cellContent` never appends a trailing separator), and a paragraph that
        // is nothing BUT its terminator has no content of its own to inherit from.
        guard paragraph.length > 1 else { return }
        let terminator = NSRange(location: paragraph.location + paragraph.length - 1, length: 1)
        guard ns.character(at: terminator.location) == 10 else { return }
        let start = result.attributes(at: paragraph.location, effectiveRange: nil)
        guard start.keys.allSatisfy({ TableBlockBuilder.inheritableTerminatorAttributes.contains($0) }) else { return }
        result.setAttributes(start, range: terminator)
    }

    /// Flattens a nested table's cells into one run of text — a tab between cells, a newline after
    /// each non-empty row — so a reader glancing at the flattened text can still tell where one
    /// cell ended and the next began, even though the grid itself is gone. Mirrors the readers' own
    /// `flattenNestedTable` (applied when a `<w:tbl>`/`<table:table>` is found while COLLECTING a
    /// cell's spans, before a `Cell` even exists); this is the renderer-side twin for the case
    /// where a `.table` block reaches `cellContent` directly instead.
    private static func flattenTableToText(_ rows: [[Cell]], baseFont: NSFont, theme: RenderTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for row in rows {
            var rowHasContent = false
            for cell in row {
                let text = cellContent(cell.blocks, baseFont: baseFont, theme: theme)
                guard text.length > 0 else { continue }
                if rowHasContent { result.append(NSAttributedString(string: "\t", attributes: [.font: baseFont])) }
                result.append(text)
                rowHasContent = true
            }
            if rowHasContent { result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont])) }
        }
        return result
    }

    // MARK: Images

    /// Word DRAWS an image at its declared size regardless of the asset's own pixel dimensions (a
    /// 300px PNG placed at 225pt is ordinary), so — unlike a markdown image, whose true size is
    /// unknown until the bytes arrive — the declared size here is already authoritative. The only
    /// adjustment left is column-fitting: shrink proportionally if it's wider than the page. Doing
    /// that HERE, from the declared size alone, means `MarkdownDocument.reconcileMedia` never has
    /// to recompute a fit from real pixels for an office image — which matters, because
    /// recomputing on load is exactly the scroll-bar-jitter invariant 1 exists to prevent (an
    /// office image's pixel dimensions can legitimately disagree with its declared size).
    private static func fittedOfficeSize(_ declared: CGSize, columnWidth: CGFloat) -> CGSize {
        guard declared.width > columnWidth, declared.width > 0 else { return declared }
        let scale = columnWidth / declared.width
        return CGSize(width: columnWidth.rounded(), height: (declared.height * scale).rounded())
    }

    /// How far past the reading column a PAGED document's picture may run before it is shrunk after
    /// all — the owner's "이 앱은 뷰어니 보이게 하는 게 더 중요하다" decision, bounded by what is
    /// actually DRAWABLE rather than by what would be nice.
    ///
    /// Word and HWP let a figure bleed off the body into the page MARGINS, and the geometry to do
    /// that now exists: `DocumentWindowController.settleReadingColumn`'s paged branch sets the text
    /// container to the BODY width, the container's left inset to the document's own LEFT margin, and
    /// the text view's FRAME to `left + body + right` — the author's whole sheet. A line fragment
    /// starts at the container's left edge, so an oversize attachment overruns to the RIGHT only, and
    /// the space it has to overrun into is exactly one number: the document's own RIGHT margin. Past
    /// that it is off the sheet and off the view's bounds, and a view clips its own drawing to its
    /// bounds — so it would be CUT, not bled. A clipped picture is strictly worse than a shrunk one
    /// (the reader loses the right of the figure and nothing on screen says why), which is why the
    /// allowance is the real margin and never a guess at it.
    ///
    /// `nil` — no margin supplied — means NO bleed, i.e. exactly the clamp-to-column behaviour that
    /// preceded this. That is the honest default: without the margin there is no width this can be
    /// proven safe at, and inventing one trades a shrunk picture for a possibly-clipped one.
    ///
    /// **RETURNS 0 TODAY, DELIBERATELY — the premise above is FALSE and was measured to be.** The
    /// paragraph above assumes an attachment wider than the text container paints on into the
    /// frame's spare width and is stopped only by the view's bounds. It is not: **AppKit clips an
    /// attachment to the TEXT CONTAINER**, and the frame is never the limit. Measured by drawing a
    /// real `NSTextView` in exactly `settleReadingColumn`'s paged geometry (inset = left margin,
    /// `containerSize` = body, frame = `left + body + right`), painting a solid attachment through
    /// `cacheDisplay`, and scanning the bitmap for the rightmost painted pixel — container 451.3,
    /// inset 32, frame 515.3:
    ///
    ///     authored  container   rightmost painted   unclipped would be
    ///      411.3      451.3          447.3               448.3    ← fits, whole
    ///      451.3      451.3          482.3               488.3
    ///      481.3      451.3          482.3               518.3
    ///      551.3      451.3          482.3               588.3
    ///      651.3      451.3          482.3               688.3
    ///      551.3      551.3          582.3               588.3    ← CONTROL, whole
    ///      651.3      651.3          682.3               688.3    ← CONTROL, whole
    ///
    /// The painted extent tracks the CONTAINER and nothing else: pinned at 482.3 for every oversize
    /// width, while the two controls — same pictures, container widened to match — paint whole. So
    /// letting the authored width exceed the column does not bleed the picture, it CROPS it: the
    /// reader loses the right of the figure with nothing on screen to explain it, which is strictly
    /// worse than the shrink it would replace. The gate is here, and not a revert, because the
    /// mechanism and the `pageMarginRight` thread are both correct and the finding must not have to
    /// be re-derived.
    ///
    /// What actually unlocks it: `DocumentWindowController.settleReadingColumn`'s paged branch has to
    /// give the container the whole SHEET (`left + body + right`, `textContainerInset.width` 0) and
    /// pull body text back to the body column with paragraph indents instead of with the container.
    /// Then this returns `right` and the numbers above say it will be drawn. That composes with every
    /// indent `applyParagraphFormat` already sets and with `TableBlockBuilder`'s column solve, so it
    /// wants measuring rather than assuming.
    ///
    /// Measured before any of it, on 41 real documents (4 docx + 37 HWP): not ONE picture is authored
    /// wider than its own page body — the widest observed is exactly the body width. The feature has
    /// no subject in this corpus, which is also why gating it costs nothing today.
    private static func bleedAllowance(paged: Bool, pageMarginRight: CGFloat?) -> CGFloat {
        guard paged, let right = pageMarginRight, right > 0 else { return 0 }
        _ = right          // see above: re-enable by returning `right` once the container is the sheet
        return 0
    }

    /// THE size an office graphic occupies, in one place: authored size × page-proportional scale,
    /// then column-fitted. Called at build time here, and again by
    /// `DocumentWindowController.resizeOfficeGraphics` on every reflow — one function so a picture
    /// cannot drift from what a rebuild at the same width would have produced. (Two copies of this
    /// arithmetic is precisely how a resized document ends up disagreeing with a reopened one.)
    /// `bleed` widens the clamp by that many points — see `bleedAllowance`. `0`, the default, is every
    /// non-paged build, every cell picture, every paged document whose reader found no right margin,
    /// and `DocumentWindowController.resizeOfficeGraphics`, which is skipped outright for a paged
    /// document and so can never reach the widened arm.
    static func graphicSize(authored: CGSize, graphicScale: CGFloat, columnWidth: CGFloat,
                            bleed: CGFloat = 0) -> CGSize {
        let scaled = CGSize(width: authored.width * graphicScale, height: authored.height * graphicScale)
        let limit = bleed > 0 && columnWidth.isFinite ? columnWidth + bleed : columnWidth
        // Clamped to `limit`, but never SCALED UP to it: `fittedOfficeSize` only ever shrinks, so a
        // picture narrower than the column keeps its authored width exactly as before.
        return fittedOfficeSize(scaled, columnWidth: limit)
    }

    /// The chart/SmartArt frame's pixels. Extracted so a reflow can REDRAW it at the new size —
    /// invariant 31 means this case is sized by `.bounds` with an image that is never nil, so
    /// stretching the old bitmap would blur its label instead of re-laying it out.
    static func placeholderImage(label: String, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            drawPlaceholderCard(label: label, in: rect)
            return true
        }
    }

    /// The card's actual pixels, drawn into whatever rect it is given. Split out of
    /// `placeholderImage` so the OTHER discovery of "this reader cannot draw this graphic" —
    /// `SizedAttachmentCell.undrawableLabel`, where the bytes turned out to be a format no
    /// installed decoder reads — draws the identical card LIVE at its current cell frame instead
    /// of baking a bitmap that a later resize would scale. One routine, so the two cannot drift.
    ///
    /// The label is fitted rather than allowed to run off the card: the font shrinks toward the
    /// card's width and, if even the floor size cannot hold the sentence, only the label's FIRST
    /// WORD is drawn — which is the format's name ("WMF"), the part worth keeping in a frame too
    /// small for a sentence. A one-word label (`[Chart]`, every caller before this) is measured,
    /// found to fit, and drawn exactly where it always was.
    static func drawPlaceholderCard(label: String, in rect: NSRect) {
        Palette.codeCardBg.setFill()
        rect.fill()
        Palette.codeCardBorder.setStroke()
        NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let available = rect.width - placeholderCardTextInset
        guard available > 0 else { return }
        var fontSize = max(9, min(14, rect.height * 0.18))
        var text = "[\(label)]" as NSString
        func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Palette.secondary]
        }
        var width = text.size(withAttributes: attributes(fontSize)).width
        if width > available {
            // Scale the size by exactly the overshoot (text width is very nearly linear in point
            // size), floored so it never becomes unreadable — one step, no search loop.
            fontSize = max(placeholderCardMinFontSize, fontSize * available / width)
            width = text.size(withAttributes: attributes(fontSize)).width
        }
        if width > available, let firstWord = label.split(separator: " ").first, firstWord.count < label.count {
            text = "[\(firstWord)]" as NSString
            width = text.size(withAttributes: attributes(fontSize)).width
        }
        let attrs = attributes(fontSize)
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                              y: (rect.height - textSize.height) / 2), withAttributes: attrs)
    }

    /// Breathing room kept clear either side of a placeholder card's label.
    static let placeholderCardTextInset: CGFloat = 8
    /// Below this the label stops being readable, so a narrower card loses words instead of size.
    static let placeholderCardMinFontSize: CGFloat = 7

    /// Reserves the (column-fitted) declared size via `SizedAttachmentCell`, image left `nil` —
    /// pixels arrive lazily via `MarkdownDocument.reconcileMedia`. This is invariant 1 of this
    /// codebase: the reserved layout size must NEVER depend on whether an image is loaded, or the
    /// scroll bar swings when it loads/purges.
    private static func appendImage(id: String, size: CGSize, columnWidth: CGFloat, basis: CGFloat?,
                                    scale: CGFloat, alignment: NSTextAlignment?, insideCell: Bool,
                                    bleed: CGFloat = 0,
                                    into result: NSMutableAttributedString) {
        // `scale` (= the on-screen width of what this picture was measured against ÷ that thing's
        // SOURCE width — page for a picture in the flow, table for one in a cell), NOT `fontSizeScale`:
        // the authored size is a fraction of that container, and reproducing the fraction is what keeps
        // the document's own font↔image proportion at any window size — while leaving ⌘+/⌘− (a TEXT
        // setting) unable to inflate a photograph. Scale first, THEN fit, so a scaled image still never
        // exceeds its column or its cell.
        let fitted = graphicSize(authored: size, graphicScale: scale, columnWidth: columnWidth, bleed: bleed)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: fitted)
        att.attachmentCell = SizedAttachmentCell(reservedSize: fitted)
        let ph = NSMutableAttributedString(attachment: att)
        let whole = NSRange(location: 0, length: ph.length)
        ph.addAttribute(MDAttr.image, value: id, range: whole)
        // The AUTHORED size and its basis ride along so a reflow can re-derive this picture's size at
        // the new width (see `MDAttr.officeGraphic`) — a rebuild is not required to resize a window.
        ph.addAttribute(MDAttr.officeGraphic,
                        value: OfficeGraphicInfo(authored: size, placeholderLabel: nil,
                                                 basisWidth: basis, isInsideCell: insideCell),
                        range: whole)
        applyGraphicAlignment(alignment, to: ph)
        result.append(ph)
        result.append(NSAttributedString(string: "\n"))
    }

    /// The containing paragraph's alignment, applied to the one-character attachment paragraph. A
    /// centred picture is the norm in a report and used to render hard left, because this case
    /// carried no paragraph style at all. `nil` (the document said nothing) adds NO paragraph style,
    /// so a document that never aligns anything is byte-identical to before this existed.
    private static func applyGraphicAlignment(_ alignment: NSTextAlignment?, to ph: NSMutableAttributedString) {
        guard let alignment else { return }
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        ph.addAttribute(.paragraphStyle, value: p.copy() as! NSParagraphStyle,
                        range: NSRange(location: 0, length: ph.length))
    }

    /// A chart/SmartArt this reader could not resolve to any picture at all — reserves the SAME
    /// declared+column-fitted area `appendImage` would, drawn as a bordered, labelled frame
    /// SYNTHESIZED RIGHT HERE rather than left for `MarkdownDocument.reconcileMedia` to fill in
    /// later. Deliberately NOT built through `SizedAttachmentCell` the way `appendImage`'s
    /// reserved-but-unloaded state is (measured: `NSTextAttachment` drops a custom
    /// `attachmentCell` the moment `.image` is set — AppKit switches to its own bounds-based
    /// image layout at that point, the SAME mechanism `reconcileMedia`'s "pixels already loaded,
    /// just repaint" branch relies on) — so sizing here comes from `.bounds` alone, set once,
    /// alongside an `.image` that is never nil to begin with. Invariant 1 (reserved size must
    /// never depend on whether pixels are loaded) holds trivially: there is no "not yet loaded"
    /// state for this case at all, so nothing here can ever revise `.bounds` after the fact.
    /// `label` renders verbatim — the caller (`DocxReader`) already turned it into a word a reader
    /// understands ("Chart", "Diagram"), never an XML element name.
    private static func appendUnsupportedGraphic(label: String, size: CGSize, columnWidth: CGFloat, basis: CGFloat?,
                                                  scale: CGFloat, alignment: NSTextAlignment?, insideCell: Bool,
                                                  bleed: CGFloat = 0,
                                                  into result: NSMutableAttributedString) {
        // Same proportional scaling as `appendImage` — a chart/SmartArt placeholder stands in for the
        // space the real graphic would occupy, so it must hold that same share of its container.
        let fitted = graphicSize(authored: size, graphicScale: scale, columnWidth: columnWidth, bleed: bleed)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: fitted)
        att.image = placeholderImage(label: label, size: fitted)
        let ph = NSMutableAttributedString(attachment: att)
        // The authored size + label ride along so a reflow can re-derive this frame at the new
        // width (see `MDAttr.officeGraphic`) instead of leaving it frozen at the build width.
        ph.addAttribute(MDAttr.officeGraphic,
                        value: OfficeGraphicInfo(authored: size, placeholderLabel: label,
                                                 basisWidth: basis, isInsideCell: insideCell),
                        range: NSRange(location: 0, length: ph.length))
        applyGraphicAlignment(alignment, to: ph)
        result.append(ph)
        result.append(NSAttributedString(string: "\n"))
    }

    // MARK: Formulas

    /// Reserves a placeholder exactly the way `MarkdownRenderer.appendWebBlock` does for a markdown
    /// `$$…$$` — same `MDAttr.math` attribute, same `SizedAttachmentCell`-owned guessed size (260×60).
    /// `MarkdownDocument`'s pre-render/pre-size passes key off `enumerateWebBlocks`
    /// (`storage.enumerateAttribute(MDAttr.math, …)`), not this document's `kind`, so an office
    /// formula is picked up by the SAME up-front measure pass a markdown one is — nothing here (or
    /// in `MarkdownDocument`) had to be taught that office documents exist. The guessed size is only
    /// a placeholder; the up-front pass replaces it with the exact cached-PDF size before layout
    /// (invariant 1: reserved size must never depend on whether pixels are loaded).
    private static func appendFormula(latex: String, into result: NSMutableAttributedString) {
        let size = NSSize(width: 260, height: 60)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: size)
        att.attachmentCell = SizedAttachmentCell(reservedSize: size)
        let ph = NSMutableAttributedString(attachment: att)
        ph.addAttribute(MDAttr.math, value: latex, range: NSRange(location: 0, length: ph.length))
        result.append(ph)
        result.append(NSAttributedString(string: "\n"))
    }
}
