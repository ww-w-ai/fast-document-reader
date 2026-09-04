import AppKit

/// Replays a `MarkdownWire` back into the `NSAttributedString` the reader lays out.
///
/// The engine builds the typography; this puts it into AppKit's objects. It is deliberately dumb —
/// no decisions, no defaults, no "fix it up if it looks wrong". Every value here came from the
/// renderer, and a difference between what this produces and what `MarkdownRenderer` produces is a
/// bug in one of the two halves, not something to paper over on arrival.
enum MarkdownWireMaterializer {

    enum Failure: Error, CustomStringConvertible {
        case unsupportedVersion(UInt32)
        case raggedColumns(String)
        case indexOutOfRange(String)

        var description: String {
            switch self {
            case .unsupportedVersion(let v):
                return "markdown wire version \(v); this build replays \(MarkdownWire.supportedVersion)"
            case .raggedColumns(let why): return "markdown wire columns disagree: \(why)"
            case .indexOutOfRange(let why): return "markdown wire index out of range: \(why)"
            }
        }
    }

    static func attributedString(_ wire: MarkdownWire, theme: RenderTheme) throws -> NSAttributedString {
        guard wire.v == MarkdownWire.supportedVersion else {
            throw Failure.unsupportedVersion(wire.v)
        }
        let layers = wire.layerLocation.count
        guard wire.layerLength.count == layers else {
            throw Failure.raggedColumns("\(layers) locations against \(wire.layerLength.count) lengths")
        }
        for (name, column) in [("font", wire.layerFont), ("color", wire.layerColor),
                               ("paragraph", wire.layerParagraph), ("attachment", wire.layerAttachment),
                               ("underline", wire.layerUnderline), ("link", wire.layerLink)]
        where !column.isEmpty && column.count != layers {
            throw Failure.raggedColumns("\(name) column has \(column.count) of \(layers)")
        }

        let string = NSMutableAttributedString(string: wire.text)
        let total = string.length

        // Built ONCE, before any layer is replayed: AppKit decides a grid by object identity, so
        // every cell of one table must be handed the same instance (see `MarkdownWire`'s doc).
        let tables = wire.tables.map { spec -> NSTextTable in
            // A table that carries its grid is rebuilt as the GRID table, or `resizeTables` — which
            // keys on the subclass and its proportions — would skip it on every reflow.
            let table: NSTextTable
            if let proportions = spec.columnProportions, !proportions.isEmpty {
                let grid = GridTextTable()
                grid.columnProportions = proportions.map { CGFloat($0) }
                grid.outerMarginLeft = CGFloat(spec.outerMarginLeft ?? 0)
                grid.outerMarginRight = CGFloat(spec.outerMarginRight ?? 0)
                grid.maxWidth = spec.maxWidth.map { CGFloat($0) }
                table = grid
            } else {
                table = NSTextTable()
            }
            table.numberOfColumns = max(1, Int(spec.columns))
            table.collapsesBorders = spec.collapsesBorders
            table.hidesEmptyCells = spec.hidesEmptyCells
            return table
        }
        let fonts = wire.fonts.map { font($0, theme: theme) }
        let colors = wire.colors.map { color($0, theme: theme) }
        let styles = try wire.paragraphStyles.map { try paragraphStyle($0, tables: tables, colors: colors) }

        // Extras arrive sorted by layer, so one walk over them keeps pace with the layer loop
        // rather than costing a dictionary of arrays.
        var extraCursor = 0

        string.beginEditing()

        for layer in 0..<layers {
            let location = Int(wire.layerLocation[layer])
            let length = Int(wire.layerLength[layer])
            guard location >= 0, length >= 0, location + length <= total else {
                throw Failure.indexOutOfRange("layer \(layer) covers \(location)..<\(location + length) of \(total)")
            }
            let range = NSRange(location: location, length: length)

            if let index = pooled(wire.layerFont, layer) {
                string.addAttribute(.font, value: try element(fonts, index, "font"), range: range)
            }
            if let index = pooled(wire.layerColor, layer) {
                string.addAttribute(.foregroundColor, value: try element(colors, index, "colour"), range: range)
            }
            if let index = pooled(wire.layerParagraph, layer) {
                string.addAttribute(.paragraphStyle, value: try element(styles, index, "paragraph style"), range: range)
            }
            if let index = pooled(wire.layerAttachment, layer) {
                let spec = try element(wire.attachments, index, "attachment")
                string.addAttribute(.attachment, value: attachment(spec), range: range)
            }
            if layer < wire.layerUnderline.count, wire.layerUnderline[layer] != 0 {
                string.addAttribute(.underlineStyle, value: NSNumber(value: wire.layerUnderline[layer]), range: range)
            }
            if let index = pooled(wire.layerLink, layer) {
                // An `NSURL`, not a `String`: that is what `MarkdownRenderer` stores and what the
                // click handler reads back. A string here looks identical in a log and fails the
                // `as? URL` at the other end.
                let target = try element(wire.linkTargets, index, "link target")
                string.addAttribute(.link, value: URL(string: target) ?? target, range: range)
            }

            while extraCursor < wire.extras.count, Int(wire.extras[extraCursor].layer) == layer {
                let extra = wire.extras[extraCursor]
                string.addAttribute(NSAttributedString.Key(extra.key), value: value(extra.value), range: range)
                extraCursor += 1
            }
        }
        string.endEditing()

        // Substitution is the HOST's, deliberately, exactly as it is on the office path (see
        // `HwpReader.read_before_host_font_substitution`): the engine names the font the document
        // asked for, and AppKit decides which face actually draws a script that font does not
        // cover. Skipping it is how Korean prose came back in `.AppleSystemUIFont` where this
        // reader draws it in `.AppleSDGothicNeoI-Regular`.
        FontSubstitutionResolver.applySubstitutions(to: string)
        return string
    }

    /// `-1` means "this layer sets no such attribute"; an absent column means no layer does.
    private static func pooled(_ column: [Int32], _ layer: Int) -> Int? {
        guard layer < column.count, column[layer] >= 0 else { return nil }
        return Int(column[layer])
    }

    private static func element<T>(_ pool: [T], _ index: Int, _ what: String) throws -> T {
        guard index < pool.count else {
            throw Failure.indexOutOfRange("\(what) \(index) of \(pool.count)")
        }
        return pool[index]
    }

    /// Rebuilt from the theme by ROLE, which is the whole point of the role travelling — see
    /// `MarkdownWire.Font`. `raw` is the escape hatch for a font the theme does not explain; the
    /// engine has never produced one for markdown, and if it starts to, this is where it shows up.
    private static func font(_ spec: MarkdownWire.Font, theme: RenderTheme) -> NSFont {
        let base: NSFont
        switch spec.role {
        case "body": base = theme.bodyFont
        case "heading": base = theme.headingFont(level: Int(spec.level))
        case "code": base = theme.codeFont
        // `MarkdownRenderer.swift:773` — a table header asks for a system semibold directly.
        case "tableHeader": base = NSFont.systemFont(ofSize: theme.baseFontSize, weight: .semibold)
        default: base = NSFont(name: spec.name, size: CGFloat(spec.size))
                        ?? NSFont.systemFont(ofSize: CGFloat(spec.size))
        }
        guard spec.traits != 0 else { return base }
        // The same two lines `MarkdownRenderer.fontAdding` runs, for the same reason: composing
        // "same family, bolder" ourselves picks different faces than macOS does.
        let wanted = NSFontDescriptor.SymbolicTraits(rawValue: spec.traits)
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(wanted))
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// Rebuilt from the palette by ROLE so the colour stays a light/dark dynamic — see
    /// `MarkdownWire.Color`. `raw` falls back to the components the engine resolved, which is a
    /// fixed colour in both appearances and is why the roles exist.
    private static func color(_ spec: MarkdownWire.Color, theme: RenderTheme) -> NSColor {
        switch spec.role {
        case "text": return theme.textColor
        case "secondary": return theme.secondaryColor
        case "link": return theme.linkColor
        case "inlineCode": return theme.inlineCodeColor
        // The highlighter's own palette — AppKit's named system colours, which are dynamic.
        case "systemRed": return .systemRed
        case "systemOrange": return .systemOrange
        case "systemGreen": return .systemGreen
        case "systemPink": return .systemPink
        case "systemTeal": return .systemTeal
        case "secondaryLabel": return .secondaryLabelColor
        default:
            let (r, g, b, a) = (CGFloat(spec.r), CGFloat(spec.g), CGFloat(spec.b), CGFloat(spec.a))
            // The names are `NSColorSpaceName`'s own serde spelling; anything else is treated as
            // sRGB rather than refused, because a colour is not worth failing a document over.
            return spec.space == "deviceRGB"
                ? NSColor(deviceRed: r, green: g, blue: b, alpha: a)
                : NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }

    private static func paragraphStyle(_ spec: MarkdownWire.ParagraphStyle, tables: [NSTextTable],
                                       colors: [NSColor]) throws -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = NSTextAlignment(rawValue: Int(spec.alignment)) ?? .natural
        style.lineSpacing = CGFloat(spec.lineSpacing)
        style.paragraphSpacing = CGFloat(spec.paragraphSpacing)
        style.paragraphSpacingBefore = CGFloat(spec.paragraphSpacingBefore)
        style.firstLineHeadIndent = CGFloat(spec.firstLineHeadIndent)
        style.headIndent = CGFloat(spec.headIndent)
        style.tailIndent = CGFloat(spec.tailIndent)
        style.defaultTabInterval = CGFloat(spec.defaultTabInterval)
        style.lineHeightMultiple = CGFloat(spec.lineHeightMultiple)
        style.minimumLineHeight = CGFloat(spec.minimumLineHeight)
        style.maximumLineHeight = CGFloat(spec.maximumLineHeight)
        style.lineBreakMode = NSLineBreakMode(rawValue: UInt(spec.lineBreakMode)) ?? .byWordWrapping
        style.baseWritingDirection = NSWritingDirection(rawValue: Int(spec.baseWritingDirection)) ?? .natural
        style.lineBreakStrategy = NSParagraphStyle.LineBreakStrategy(rawValue: UInt(spec.lineBreakStrategy))
        // Assigned ONLY when the wire names stops. `NSMutableParagraphStyle` starts with AppKit's
        // twelve default stops at 28pt, and assigning an empty array wipes them — which is a
        // different paragraph from the one the renderer built, not the same one described briefly.
        // Markdown sets stops for list markers and never clears them, so "none named" means
        // "AppKit's defaults", not "no tab stops".
        if !spec.tabStops.isEmpty {
            style.tabStops = spec.tabStops.compactMap { pair in
                guard pair.count == 2, let alignment = NSTextAlignment(rawValue: Int(pair[0])) else { return nil }
                return NSTextTab(textAlignment: alignment, location: CGFloat(pair[1]))
            }
        }
        style.textBlocks = try spec.textBlocks.map { try tableBlock($0, tables: tables, colors: colors) }
        return style
    }

    /// The cell exactly as the builder left it: the same subclass the host's own builder makes
    /// (its `drawBackground` is where a page band's cut through a cell is drawn), its width, its
    /// padding and rules per edge, and its tint. The edge codes are AppKit's own `NSRectEdge`.
    private static func tableBlock(_ spec: MarkdownWire.TableBlock, tables: [NSTextTable],
                                   colors: [NSColor]) throws -> NSTextTableBlock {
        let table = try element(tables, Int(spec.table), "table")
        let cell = GridTextTableBlock(table: table,
                                      startingRow: Int(spec.row), rowSpan: Int(spec.rowSpan),
                                      startingColumn: Int(spec.column), columnSpan: Int(spec.columnSpan))
        let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]
        if let width = spec.contentWidth {
            cell.setContentWidth(CGFloat(width), type: .absoluteValueType)
        }
        if let padding = spec.padding, padding.count == edges.count {
            for (edge, value) in zip(edges, padding) {
                cell.setWidth(CGFloat(value), type: .absoluteValueType, for: .padding, edge: edge)
            }
        }
        if let border = spec.border, border.count == edges.count {
            for (edge, value) in zip(edges, border) where value > 0 {
                cell.setWidth(CGFloat(value), type: .absoluteValueType, for: .border, edge: edge)
            }
        }
        for pair in spec.borderColors ?? [] where pair.count == 2 {
            guard let edge = NSRectEdge(rawValue: UInt(max(0, pair[0]))) else { continue }
            cell.setBorderColor(try element(colors, Int(pair[1]), "color"), for: edge)
        }
        if let background = spec.background {
            cell.backgroundColor = try element(colors, Int(background), "color")
        }
        return cell
    }

    /// The box only. Which picture goes in it is carried by this layer's `mdImage`/`mdMermaid`/
    /// `mdMath` extra and filled in by the document's own lazy media pass (invariant 1), and the
    /// size lives on the CELL rather than on `attachment.image` (invariant 31).
    private static func attachment(_ spec: MarkdownWire.Attachment) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = SizedAttachmentCell(
            reservedSize: NSSize(width: CGFloat(spec.width), height: CGFloat(spec.height)))
        return attachment
    }

    /// `MDAttr` values are read back by consumers that expect the exact types `MarkdownRenderer`
    /// stored — an `NSNumber` where a level is read as `Int`, an `NSValue` where a source range is
    /// read as `NSRange`. Handing back a `String` for a number would compile and then fail at the
    /// first `as? Int` in the window controller.
    private static func value(_ value: MarkdownWire.Extra.Value) -> Any {
        switch value {
        case .text(let s): return s
        case .int(let i): return NSNumber(value: i)
        case .bool(let b): return NSNumber(value: b)
        case .double(let d): return NSNumber(value: d)
        case .range(let location, let length):
            return NSValue(range: NSRange(location: location, length: length))
        }
    }
}
