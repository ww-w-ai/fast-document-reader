import AppKit

/// The finished markdown string as the engine sends it, and the shape the replay reads.
///
/// This is the host half of `render/markdown_wire.rs`; the two are mirrors and a field added to
/// one is a field added to the other (`contract-surface-sync`). Three of its decisions are not
/// obvious from the shape alone:
///
///  * **The layers are a call LOG, not a run list.** `layerLocation`/`layerLength` are the ranges
///    `addAttribute` was called with, in call order, and they OVERLAP — a paragraph style laid
///    across a whole block, then a font over one word inside it. They are replayed in order, later
///    calls winning, exactly the way the renderer wrote them. A reader who assumes they tile
///    (AppKit's own `runs` do) builds a broken document; that assumption cost one failing test.
///  * **Everything repeated is pooled.** One real document names 3 fonts, 3 colours and 8
///    paragraph styles across 47,000 layers, so the pools are what keep the wire from being mostly
///    duplicate JSON. `-1` in a layer column means "this layer does not set that attribute".
///  * **A table is an IDENTITY, not a value.** AppKit lays a grid out by which `NSTextTable`
///    object its cells point at, so the `tables` pool is built ONCE into real objects and every
///    cell of one grid is handed the same instance. Rebuilding a table per cell produces a
///    document that looks like a table and lays out as a column of one-cell grids.
///
/// The element types are NESTED because the office wire next door already owns the bare `Wire…`
/// names for its own, differently-shaped structs (`OfficeEnvelopeDecoding`).
struct MarkdownWire: Decodable {
    var v: UInt32
    var text: String
    var fonts: [Font] = []
    var colors: [Color] = []
    var paragraphStyles: [ParagraphStyle] = []
    var tables: [Table] = []
    var attachments: [Attachment] = []
    var layerLocation: [UInt32]
    var layerLength: [UInt32]
    var layerFont: [Int32] = []
    var layerColor: [Int32] = []
    var layerParagraph: [Int32] = []
    var layerAttachment: [Int32] = []
    var layerUnderline: [Int32] = []
    var layerLink: [Int32] = []
    var linkTargets: [String] = []
    var extras: [Extra] = []

    /// The version this build of the host knows how to replay. The engine stamps its own into `v`;
    /// a mismatch means the two halves were built from different sources, which is a build-system
    /// failure rather than a document one and must be loud.
    static let supportedVersion: UInt32 = 2

    private enum CodingKeys: String, CodingKey {
        case v, text, fonts, colors
        case paragraphStyles = "paragraph_styles"
        case tables, attachments
        case layerLocation = "layer_location"
        case layerLength = "layer_length"
        case layerFont = "layer_font"
        case layerColor = "layer_color"
        case layerParagraph = "layer_paragraph"
        case layerAttachment = "layer_attachment"
        case layerUnderline = "layer_underline"
        case layerLink = "layer_link"
        case linkTargets = "link_targets"
        case extras
    }

    /// Written out rather than synthesized, because the engine OMITS an empty pool or column
    /// (serde's `skip_serializing_if`) and Swift's synthesized `Decodable` reads a missing key as
    /// an ERROR — it does not fall back to the property's default value. Left synthesized, a
    /// document with no table (which is most of them) was refused at `tab_stops`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(UInt32.self, forKey: .v)
        text = try c.decode(String.self, forKey: .text)
        fonts = try c.decodeIfPresent([Font].self, forKey: .fonts) ?? []
        colors = try c.decodeIfPresent([Color].self, forKey: .colors) ?? []
        paragraphStyles = try c.decodeIfPresent([ParagraphStyle].self, forKey: .paragraphStyles) ?? []
        tables = try c.decodeIfPresent([Table].self, forKey: .tables) ?? []
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        layerLocation = try c.decode([UInt32].self, forKey: .layerLocation)
        layerLength = try c.decode([UInt32].self, forKey: .layerLength)
        layerFont = try c.decodeIfPresent([Int32].self, forKey: .layerFont) ?? []
        layerColor = try c.decodeIfPresent([Int32].self, forKey: .layerColor) ?? []
        layerParagraph = try c.decodeIfPresent([Int32].self, forKey: .layerParagraph) ?? []
        layerAttachment = try c.decodeIfPresent([Int32].self, forKey: .layerAttachment) ?? []
        layerUnderline = try c.decodeIfPresent([Int32].self, forKey: .layerUnderline) ?? []
        layerLink = try c.decodeIfPresent([Int32].self, forKey: .layerLink) ?? []
        linkTargets = try c.decodeIfPresent([String].self, forKey: .linkTargets) ?? []
        extras = try c.decodeIfPresent([Extra].self, forKey: .extras) ?? []
    }

    /// A font as the renderer MEANT it — the theme role plus the traits laid on top — because a
    /// system font's descriptor does not round-trip: `NSFont.systemFont(ofSize:weight:)` is the
    /// private `.AppleSystemUIFontDemi` cascade, and rebuilding it from its own descriptor yields
    /// the concrete `.SFNS-Semibold`, a different face with different metrics and no cascade.
    /// Rebuilding from the ROLE calls the same AppKit function the renderer called.
    struct Font: Decodable {
        /// `body` · `heading` · `code` · `raw`.
        var role: String
        /// Heading level; `0` for the other roles.
        var level: Int32 = 0
        /// `NSFontDescriptorSymbolicTraits`' raw bits — bold is `1 << 1`, italic `1 << 0`.
        var traits: UInt32
        /// The face the engine resolved. Authoritative only for `raw`.
        var name: String
        var size: Double

        private enum CodingKeys: String, CodingKey { case role, level, traits, name, size }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            level = try c.decodeIfPresent(Int32.self, forKey: .level) ?? 0
            traits = try c.decode(UInt32.self, forKey: .traits)
            name = try c.decode(String.self, forKey: .name)
            size = try c.decode(Double.self, forKey: .size)
        }
    }

    /// A colour as the renderer MEANT it, for the same reason `Font` carries a role: every colour
    /// markdown uses is a light/dark dynamic from the palette, and the engine has no appearance to
    /// resolve one against, so it keeps the light half. Components alone would pin the whole
    /// document to light mode.
    struct Color: Decodable {
        /// `text` · `secondary` · `link` · `inlineCode` · `raw`.
        var role: String
        /// The components the engine resolved. Authoritative only for `raw`.
        var r: Double, g: Double, b: Double, a: Double
        /// `deviceRGB` and `sRGB` are different colours on screen, so which initialiser made this
        /// one crosses with it rather than being guessed on arrival.
        var space: String
    }

    struct Table: Decodable {
        var columns: Int32
        var collapsesBorders: Bool
        var hidesEmptyCells: Bool
        /// The grid a `GridTextTable` is rebuilt from — absent on a wire that carried none.
        var columnProportions: [Double]?
        var outerMarginLeft: Double?
        var outerMarginRight: Double?
        var maxWidth: Double?

        private enum CodingKeys: String, CodingKey {
            case columns
            case collapsesBorders = "collapses_borders"
            case hidesEmptyCells = "hides_empty_cells"
            case columnProportions = "column_proportions"
            case outerMarginLeft = "outer_margin_left"
            case outerMarginRight = "outer_margin_right"
            case maxWidth = "max_width"
        }
    }

    struct TableBlock: Decodable {
        var table: UInt32
        var row: Int32, rowSpan: Int32, column: Int32, columnSpan: Int32
        /// The cell's box: `minX, minY, maxX, maxY` widths, per-edge rule colours as
        /// `[edge, colourIndex]` pairs, and the background — all indices into the colour pool.
        var contentWidth: Double?
        var padding: [Double]?
        var border: [Double]?
        var borderColors: [[Int64]]?
        var background: UInt32?

        private enum CodingKeys: String, CodingKey {
            case table, row, column, padding, border, background
            case rowSpan = "row_span"
            case columnSpan = "column_span"
            case contentWidth = "content_width"
            case borderColors = "border_colors"
        }
    }

    struct ParagraphStyle: Decodable {
        var alignment: Int32
        var lineSpacing: Double
        var paragraphSpacing: Double
        var paragraphSpacingBefore: Double
        var firstLineHeadIndent: Double
        var headIndent: Double
        var tailIndent: Double
        var defaultTabInterval: Double
        var lineHeightMultiple: Double
        var minimumLineHeight: Double
        var maximumLineHeight: Double
        var lineBreakMode: Int32
        var baseWritingDirection: Int32
        var lineBreakStrategy: UInt32
        /// `(alignment, location)` pairs — markdown sets these for list markers.
        var tabStops: [[Double]] = []
        var textBlocks: [TableBlock] = []

        private enum CodingKeys: String, CodingKey {
            case alignment
            case lineSpacing = "line_spacing"
            case paragraphSpacing = "paragraph_spacing"
            case paragraphSpacingBefore = "paragraph_spacing_before"
            case firstLineHeadIndent = "first_line_head_indent"
            case headIndent = "head_indent"
            case tailIndent = "tail_indent"
            case defaultTabInterval = "default_tab_interval"
            case lineHeightMultiple = "line_height_multiple"
            case minimumLineHeight = "minimum_line_height"
            case maximumLineHeight = "maximum_line_height"
            case lineBreakMode = "line_break_mode"
            case baseWritingDirection = "base_writing_direction"
            case lineBreakStrategy = "line_break_strategy"
            case tabStops = "tab_stops"
            case textBlocks = "text_blocks"
        }

        /// Same reason as `MarkdownWire.init(from:)`: both of these are omitted when empty, which
        /// is every paragraph outside a table and every paragraph outside a list.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            alignment = try c.decode(Int32.self, forKey: .alignment)
            lineSpacing = try c.decode(Double.self, forKey: .lineSpacing)
            paragraphSpacing = try c.decode(Double.self, forKey: .paragraphSpacing)
            paragraphSpacingBefore = try c.decode(Double.self, forKey: .paragraphSpacingBefore)
            firstLineHeadIndent = try c.decode(Double.self, forKey: .firstLineHeadIndent)
            headIndent = try c.decode(Double.self, forKey: .headIndent)
            tailIndent = try c.decode(Double.self, forKey: .tailIndent)
            defaultTabInterval = try c.decode(Double.self, forKey: .defaultTabInterval)
            lineHeightMultiple = try c.decode(Double.self, forKey: .lineHeightMultiple)
            minimumLineHeight = try c.decode(Double.self, forKey: .minimumLineHeight)
            maximumLineHeight = try c.decode(Double.self, forKey: .maximumLineHeight)
            lineBreakMode = try c.decode(Int32.self, forKey: .lineBreakMode)
            baseWritingDirection = try c.decode(Int32.self, forKey: .baseWritingDirection)
            lineBreakStrategy = try c.decode(UInt32.self, forKey: .lineBreakStrategy)
            tabStops = try c.decodeIfPresent([[Double]].self, forKey: .tabStops) ?? []
            textBlocks = try c.decodeIfPresent([TableBlock].self, forKey: .textBlocks) ?? []
        }
    }

    /// An attachment reserves a box; the pixels arrive later from the host's own lazy media pass
    /// (invariant 1), keyed off the `mdImage`/`mdMermaid`/`mdMath` extra on the same layer.
    struct Attachment: Decodable {
        var width: Double
        var height: Double
    }

    /// One custom (`MDAttr`) attribute on one layer. Sparse enough to travel as a list rather than
    /// as twelve more columns that would be empty almost everywhere.
    struct Extra: Decodable {
        var layer: UInt32
        var key: String
        var value: Value

        /// Tagged `{"k":…,"v":…}`, matching `WireExtraValue`'s serde representation.
        enum Value {
            case text(String)
            case int(Int64)
            case bool(Bool)
            case double(Double)
            /// `mdSrcRange` — a UTF-16 range back into the markdown source.
            case range(Int, Int)
        }

        private enum CodingKeys: String, CodingKey { case layer, key, k, v }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            layer = try c.decode(UInt32.self, forKey: .layer)
            key = try c.decode(String.self, forKey: .key)
            switch try c.decode(String.self, forKey: .k) {
            case "s": value = .text(try c.decode(String.self, forKey: .v))
            case "i": value = .int(try c.decode(Int64.self, forKey: .v))
            case "b": value = .bool(try c.decode(Bool.self, forKey: .v))
            case "d": value = .double(try c.decode(Double.self, forKey: .v))
            case "r":
                let pair = try c.decode([Int].self, forKey: .v)
                guard pair.count == 2 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                        debugDescription: "a range value is (location, length), got \(pair.count) numbers"))
                }
                value = .range(pair[0], pair[1])
            case let other:
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                    debugDescription: "unknown extra-value tag \"\(other)\" for key \(key)"))
            }
        }
    }
}
