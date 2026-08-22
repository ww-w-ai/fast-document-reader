#if FMD_RUST_ENGINE
import AppKit

// The parts of the engine's envelope that Swift cannot synthesise: AppKit's own value types, and
// the three enums that carry a payload. Everything else is synthesised beside its type — see the
// decoding section at the end of `OfficeBlock.swift`.

/// A colour on the wire: the four sRGB components, which is exactly what the reader's own
/// `NSColor(rgb:alpha:)` extension is built out of, so nothing is lost or guessed.
///
/// A struct rather than a conformance on `NSColor` itself, because `NSColor` is a non-final ObjC
/// class and `init(from:)` can only be satisfied by a `required` initialiser inside the class's own
/// definition — an extension cannot add one.
/// A size on the wire. `CGSize`'s own `Codable` reads an ARRAY — `[w, h]` — and the engine writes
/// the two named fields, which is the shape a host would expect and the one every other geometry
/// value here uses. Converting in this one place is cheaper than teaching the engine CoreGraphics'
/// private spelling.
struct WireSize: Decodable {
    let width: CGFloat, height: CGFloat
    var size: CGSize { CGSize(width: width, height: height) }
}

struct WireColor: Decodable {
    /// Which initialiser the reader chose. Carried rather than assumed: `OdtReader` builds device
    /// RGB and the other readers build sRGB, and the same three components in the two spaces are
    /// different colours on screen.
    enum Space: String, Decodable { case sRGB, deviceRGB }

    let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    let space: Space

    var color: NSColor {
        switch space {
        case .sRGB: return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case .deviceRGB: return NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
        }
    }
}

/// A struct, so unlike `NSColor` it can simply conform — but its memberwise initialiser is not
/// available to an extension, so the four edges are named here.
extension NSEdgeInsets: Decodable {
    private enum K: String, CodingKey { case top, left, bottom, right }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init(top: try c.decode(CGFloat.self, forKey: .top),
                  left: try c.decode(CGFloat.self, forKey: .left),
                  bottom: try c.decode(CGFloat.self, forKey: .bottom),
                  right: try c.decode(CGFloat.self, forKey: .right))
    }
}

extension NSTextAlignment: Decodable {
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        switch name {
        case "left": self = .left
        case "center": self = .center
        case "right": self = .right
        case "justified": self = .justified
        case "natural": self = .natural
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown text alignment \"\(name)\"")
        }
    }
}

/// A single-key object, which is how the engine writes an enum case that carries something:
/// `{"multiple": 1.2}`. Reading the key first and the payload after keeps the three payload enums
/// below down to their actual cases.
private struct OneKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private func singleKey(_ decoder: Decoder) throws -> (KeyedDecodingContainer<OneKey>, OneKey) {
    let c = try decoder.container(keyedBy: OneKey.self)
    guard let key = c.allKeys.first, c.allKeys.count == 1 else {
        throw DecodingError.dataCorruptedError(
            in: try decoder.singleValueContainer(),
            debugDescription: "expected exactly one case name, found \(c.allKeys.map(\.stringValue))")
    }
    return (c, key)
}

extension LineHeight: Decodable {
    public init(from decoder: Decoder) throws {
        let (c, key) = try singleKey(decoder)
        let value = try c.decode(CGFloat.self, forKey: key)
        switch key.stringValue {
        case "multiple": self = .multiple(value)
        case "exact": self = .exact(value)
        case "atLeast": self = .atLeast(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c, debugDescription: "unknown line height")
        }
    }
}

extension BorderDecl: Decodable {
    public init(from decoder: Decoder) throws {
        // `suppressed` carries nothing, so the engine writes it as a bare name rather than an
        // object — the same shape any no-payload case takes.
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard name == "suppressed" else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unknown border declaration \"\(name)\"")
            }
            self = .suppressed
            return
        }
        let (c, key) = try singleKey(decoder)
        guard key.stringValue == "drawn" else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c, debugDescription: "unknown border declaration")
        }
        self = .drawn(try c.decode(BorderSide.self, forKey: key))
    }
}

extension OfficeBlock: Decodable {
    private enum Payload {
        // One nested type per case, so each case's fields are named ONCE and the compiler checks
        // them — a hand-written `init(from:)` per case would name every field a second time.
        struct Heading: Decodable {
            var level: Int; var spans: [Span]; var rtl: Bool
            var alignment: NSTextAlignment?; var tabStops: [TabStop]; var format: ParagraphFormat
        }
        struct Paragraph: Decodable {
            var spans: [Span]; var rtl: Bool
            var alignment: NSTextAlignment?; var tabStops: [TabStop]; var format: ParagraphFormat
        }
        struct ListItem: Decodable {
            var level: Int; var ordered: Bool; var spans: [Span]; var marker: String?
            var rtl: Bool; var alignment: NSTextAlignment?; var tabStops: [TabStop]
            var format: ParagraphFormat; var numbering: ListNumbering?
        }
        struct Table: Decodable {
            var rows: [[Cell]]; var headerRows: Int; var columnWidths: [CGFloat]; var format: TableFormat
        }
        struct Image: Decodable { var id: String; var size: WireSize; var alignment: NSTextAlignment? }
        struct UnsupportedGraphic: Decodable { var label: String; var size: WireSize; var alignment: NSTextAlignment? }
        struct Formula: Decodable { var latex: String }
    }

    public init(from decoder: Decoder) throws {
        let (c, key) = try singleKey(decoder)
        switch key.stringValue {
        case "heading":
            let p = try c.decode(Payload.Heading.self, forKey: key)
            self = .heading(level: p.level, spans: p.spans, rtl: p.rtl,
                            alignment: p.alignment, tabStops: p.tabStops, format: p.format)
        case "paragraph":
            let p = try c.decode(Payload.Paragraph.self, forKey: key)
            self = .paragraph(spans: p.spans, rtl: p.rtl, alignment: p.alignment,
                              tabStops: p.tabStops, format: p.format)
        case "listItem":
            let p = try c.decode(Payload.ListItem.self, forKey: key)
            self = .listItem(level: p.level, ordered: p.ordered, spans: p.spans, marker: p.marker,
                             rtl: p.rtl, alignment: p.alignment, tabStops: p.tabStops,
                             format: p.format, numbering: p.numbering)
        case "table":
            let p = try c.decode(Payload.Table.self, forKey: key)
            self = .table(rows: p.rows, headerRows: p.headerRows,
                          columnWidths: p.columnWidths, format: p.format)
        case "image":
            let p = try c.decode(Payload.Image.self, forKey: key)
            self = .image(id: p.id, size: p.size.size, alignment: p.alignment)
        case "unsupportedGraphic":
            let p = try c.decode(Payload.UnsupportedGraphic.self, forKey: key)
            self = .unsupportedGraphic(label: p.label, size: p.size.size, alignment: p.alignment)
        case "formula":
            let p = try c.decode(Payload.Formula.self, forKey: key)
            self = .formula(latex: p.latex)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c, debugDescription: "unknown block \"\(key.stringValue)\"")
        }
    }
}
#endif
