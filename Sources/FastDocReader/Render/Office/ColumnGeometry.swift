import AppKit

/// What a document declares when it says "from here on, N columns", and where those columns sit.
///
/// The declaration arrives at a PARAGRAPH, not on the section: HWP puts a `ColumnDef` control in the
/// text, so one document can switch layout partway and switch back. Measured over the 637-sample
/// corpus (`examples/scan_columns.rs`, counts only): **64 documents (10.0%) declare more than one
/// column somewhere**, across 149 declarations — 125 of two columns, 20 of three, and single
/// documents at four, five and nine. That is three times as common as a footnote, and the paragraphs
/// living under such a declaration are 22,204 of 558,452 (3.98%).
///
/// This type and `ColumnGeometry` are the ARITHMETIC only. Nothing here lays anything out or draws
/// anything — which line belongs to which column is the engine's page plan, and moving it there is
/// `PageBandLayoutDelegate` applying that plan.
struct OfficeColumnLayout: Hashable {
    /// How many columns the text flows through. `1` is the ordinary single column and is carried
    /// rather than dropped: a document that RETURNS to one column says so with a declaration, and
    /// throwing it away would leave the previous one in force for the rest of the document.
    var count: Int
    /// The gap between two columns, in points, as the document measures it. Needed whether or not
    /// the columns are equal — an equal split is `(width − spacing × (count − 1)) ÷ count`.
    var spacing: CGFloat = 0
    /// Per-column widths and the gap after each, for a document that did NOT ask for equal columns
    /// — 57 of the 149 declarations (38%). Empty means equal.
    ///
    /// The UNIT is whatever `proportional` says, which is the format's own two-mindedness rather
    /// than ours: HWP 5 binary states shares that sum to 32,768 while HWPX states absolute lengths.
    var widths: [CGFloat] = []
    var gaps: [CGFloat] = []
    /// Whether `widths`/`gaps` are shares of the whole (`true`) or points (`false`).
    var proportional: Bool = false
    /// The rule drawn between columns — `0` is no rule, which is what 93 of the 149 declarations
    /// say. The other 56 (38%) do draw one.
    var separatorType: Int = 0
    var separatorWidthPt: CGFloat = 0
    var separatorColor: NSColor? = nil

    /// Whether this declaration actually splits the text. A `count` of one is a declaration to
    /// STOP, and every consumer wants to tell the two apart without repeating the comparison.
    var splitsText: Bool { count > 1 }
    /// Whether a rule is drawn between the columns.
    var drawsSeparator: Bool { separatorType != 0 && splitsText }
}

/// Where each column sits inside a body width.
enum ColumnGeometry {
    /// One column's horizontal extent, in the same coordinates the body text is laid out in.
    struct Column: Equatable {
        var x: CGFloat
        var width: CGFloat
    }

    /// The columns a declaration produces inside `bodyWidth`.
    ///
    /// Returns ONE column spanning the whole width for any declaration that does not split the text
    /// — a single column, a nonsensical count, or a width nothing can fit in. Callers therefore
    /// never branch on "is this document multi-column"; they lay out into whatever comes back, and a
    /// document that declares nothing gets exactly the geometry it has always had.
    static func columns(inWidth bodyWidth: CGFloat, layout: OfficeColumnLayout) -> [Column] {
        let whole = [Column(x: 0, width: bodyWidth)]
        guard bodyWidth > 0, layout.count > 1 else { return whole }

        // The document listed its own widths — honour them, in whichever unit it used.
        if !layout.widths.isEmpty, layout.widths.count >= layout.count {
            if let explicit = explicitColumns(inWidth: bodyWidth, layout: layout) { return explicit }
        }

        let gaps = layout.spacing * CGFloat(layout.count - 1)
        let each = (bodyWidth - gaps) / CGFloat(layout.count)
        // A spacing wider than the page would give every column a negative width and put the text
        // outside the paper. The declaration is then unusable and the single column is the honest
        // answer: too wide is a document that will not fit, not a document to be drawn inside out.
        guard each > 0 else { return whole }
        return (0..<layout.count).map {
            Column(x: CGFloat($0) * (each + layout.spacing), width: each)
        }
    }

    /// Columns from the per-column widths a document listed, or `nil` when they do not describe a
    /// usable layout and the equal split should stand.
    private static func explicitColumns(inWidth bodyWidth: CGFloat,
                                        layout: OfficeColumnLayout) -> [Column]? {
        let widths = Array(layout.widths.prefix(layout.count))
        // A gap list may be shorter than the column list, and the last column's gap is meaningless
        // — pad rather than index past the end.
        let gaps = (0..<layout.count).map { $0 < layout.gaps.count ? layout.gaps[$0] : 0 }

        var scale: CGFloat = 1
        if layout.proportional {
            // Shares, summing to the format's own 32,768 — but taken from the actual total rather
            // than that constant, so a document whose numbers are slightly off still lands inside
            // the page instead of overflowing it by the size of its own rounding error.
            let total = widths.reduce(0, +) + gaps.reduce(0, +)
            guard total > 0 else { return nil }
            scale = bodyWidth / total
        }

        var out: [Column] = []
        var x: CGFloat = 0
        for i in 0..<layout.count {
            let w = widths[i] * scale
            guard w > 0 else { return nil }
            out.append(Column(x: x, width: w))
            x += w + gaps[i] * scale
        }
        // Absolute widths can simply be wrong for this page — a document written for wider paper, or
        // a reader zoomed past what it declared. Falling back to the equal split keeps the text on
        // the sheet, which matters more than honouring a number that does not fit.
        guard x - (gaps.last ?? 0) * scale <= bodyWidth + 0.5 else { return nil }
        return out
    }
}

// port-exclude: part of the envelope decoder, only sitting here because Swift synthesises
// `Decodable` in the file that declares the type. Same reason as `OfficeBlock`'s block.
/// Declared here, not beside the decoder: Swift synthesises `Decodable` only in the file that
/// declares the type. See `OfficeBlock.swift`'s decoding section for the whole picture.
extension OfficeColumnLayout: Decodable {
    enum CodingKeys: String, CodingKey {
        case count, spacing, widths, gaps, proportional
        case separatorType, separatorWidthPt, separatorColor
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decode(Int.self, forKey: .count)
        spacing = try c.decode(CGFloat.self, forKey: .spacing)
        widths = try c.decode([CGFloat].self, forKey: .widths)
        gaps = try c.decode([CGFloat].self, forKey: .gaps)
        proportional = try c.decode(Bool.self, forKey: .proportional)
        separatorType = try c.decode(Int.self, forKey: .separatorType)
        separatorWidthPt = try c.decode(CGFloat.self, forKey: .separatorWidthPt)
        separatorColor = try c.decodeIfPresent(WireColor.self, forKey: .separatorColor)?.color
    }
}
// port-exclude-end
