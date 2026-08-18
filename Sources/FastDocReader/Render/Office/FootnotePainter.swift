import AppKit

/// Draws the notes cited on a page into the room that page reserved for them.
///
/// NOT a second `PageBandPainter`, and the difference is where the ink goes. A running head lives
/// in the gap BETWEEN two sheets — space the reader inserted, which no body text can ever occupy.
/// A footnote lives INSIDE its own sheet, at the bottom of the very column the body is set in, and
/// the only reason there is room for it is that `PageBandLayoutDelegate.textBottom(ofPage:)` refused
/// to let the body reach that far (invariant 98). So this paints against the body's own column and
/// its own coordinates, and it must agree with that rule exactly: draw one point lower than the
/// reservation and a note sits under the last line of text.
///
/// Draw-time only, like every other decoration in this reader — nothing here touches layout, and
/// the reservation it draws into was settled before any of this ran.
enum FootnotePainter {

    /// How much of the reserved band is the separator's own: the rule, and clear air on each side of
    /// it. The document's own `FootnoteShape` declares all three (line type, width, the two margins)
    /// and none of that is decoded yet — S14's remaining rows — so this is the reader's own minimum
    /// and is deliberately small: it must not make the band taller than the settle reserved, because
    /// the settle is what kept the body out.
    static let defaultSeparatorAllowance: CGFloat = 8

    /// How much room the rule and its two margins need on a page whose section declared them — and
    /// the reader's own minimum for one that declared nothing.
    ///
    /// The band and the paint MUST take this from the same function. They are two halves of one
    /// number: the settle reserves it and this file draws into it, so a difference of a point puts
    /// a note over the last line of body text.
    static func separatorAllowance(_ separator: OfficeFootnoteSeparator?) -> CGFloat {
        guard let separator, separator.isDeclared else { return defaultSeparatorAllowance }
        let rule = separator.lineType == 0 ? 0 : max(separator.lineWidthPt, 0.5)
        return separator.marginTopPt + rule + separator.marginBottomPt
    }

    static func draw(notes: [OfficeFootnote], pages: [Int: [Int]], noteBands: [Int: CGFloat],
                     separatorForPage: (Int) -> OfficeFootnoteSeparator?,
                     delegate: PageBandLayoutDelegate, theme: RenderTheme, columnWidth: CGFloat,
                     documentDefaultFontSize: CGFloat, pageContentWidth: CGFloat?,
                     visibleRect: NSRect, origin: NSPoint) {
        guard !notes.isEmpty, !noteBands.isEmpty, columnWidth.isFinite, columnWidth > 0 else { return }
        let byNumber = Dictionary(notes.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        for (page, band) in noteBands where band > 0 {
            guard let numbers = pages[page], !numbers.isEmpty else { continue }
            // The reservation's own top edge, in the same translated coordinates the layout rule
            // works in — `textBottom` is measured from the first line's top, so the leading band
            // has to be added back to land on screen.
            let top = origin.y + delegate.leadingBand + delegate.textBottom(ofPage: CGFloat(page))
            let strip = NSRect(x: origin.x, y: top, width: columnWidth, height: band)
            // A page whose notes are nowhere near the window costs one intersection test.
            guard strip.intersects(visibleRect) else { continue }
            let sep = separatorForPage(page)
            let allowance = separatorAllowance(sep)
            drawSeparator(atTop: top, x: origin.x, columnWidth: columnWidth, theme: theme,
                          separator: sep, allowance: allowance)
            var y = top + allowance
            let spacing = sep?.noteSpacingPt ?? 0
            for (index, number) in numbers.enumerated() {
                if index > 0 { y += spacing }
                guard let note = byNumber[number] else { continue }
                let attr = OfficeTextBuilder.build(note.blocks, theme: theme, columnWidth: columnWidth,
                                                   documentDefaultFontSize: documentDefaultFontSize,
                                                   pageContentWidth: pageContentWidth)
                guard attr.length > 0 else { continue }
                let height = attr.boundingRect(with: NSSize(width: columnWidth,
                                                            height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin]).height
                attr.draw(with: NSRect(x: origin.x, y: y, width: columnWidth, height: height),
                          options: [.usesLineFragmentOrigin])
                y += height
            }
        }
    }

    /// The rule above the notes. A short one, from the column's left edge — which is what HWP draws
    /// by default and what the corpus overwhelmingly declares (`separator_line_type` 1, a plain
    /// solid line, on 1,392 of 1,622 declarations).
    private static func drawSeparator(atTop top: CGFloat, x: CGFloat, columnWidth: CGFloat,
                                      theme: RenderTheme, separator: OfficeFootnoteSeparator?,
                                      allowance: CGFloat) {
        // A section that declared a line type of 0 declared NO line — draw nothing rather than the
        // reader's default, which would put a rule on a page the document deliberately left open.
        if let separator, separator.isDeclared, separator.lineType == 0 { return }
        // Sat on the document's own top margin when it stated one; otherwise centred in the
        // reader's minimum allowance, which is where the eye expects it.
        let offset = (separator?.isDeclared ?? false) ? (separator?.marginTopPt ?? 0) : allowance / 2
        let y = (top + offset).rounded() + 0.5
        // The format's "full width" length is a sentinel far outside any real page, so anything at
        // or beyond the column means the whole column. Nothing declared falls back to the third of
        // the column HWP itself draws by default.
        let declared = separator?.lengthPt
        let length = declared.map { $0 <= 0 || $0 >= columnWidth ? columnWidth : $0 }
            ?? columnWidth / 3
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + min(length, columnWidth), y: y))
        path.lineWidth = max(separator?.lineWidthPt ?? 0, 0.5)
        (separator?.color ?? theme.secondaryColor.withAlphaComponent(0.55)).setStroke()
        path.stroke()
    }
}
