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

private struct WirePoint: Decodable {
    let x: CGFloat, y: CGFloat
    var point: CGPoint { CGPoint(x: x, y: y) }
}

private struct WireRect: Decodable {
    let origin: WirePoint, size: WireSize
    var rect: CGRect { CGRect(origin: origin.point, size: size.size) }
}

struct WireImage: Decodable {
    let size: WireSize
    let data: Data?
    /// Where the bytes are, when the wire did not repeat them here.
    ///
    /// A real document reuses one picture in many places — 610 cells of one government manual share
    /// 44 background images — so the engine writes each picture's bytes ONCE into the envelope's
    /// `picturePool` and leaves this key at every use (`office/picture_pool.rs`). Resolving it needs
    /// the pool, which arrives in the same envelope; `PictureBytes.pool` is how it gets here without
    /// this type having to be handed a context at every one of its call sites.
    let dataKey: String?

    var image: NSImage? {
        if let data, let decoded = NSImage(data: data) { return decoded }
        if let dataKey, let pooled = PictureBytes.pool[dataKey] {
            // One `NSImage` per DISTINCT picture, not per use: 610 cells that share a background
            // used to decode the same bitmap 610 times, which is work the pooling can retire along
            // with the bytes.
            if let cached = PictureBytes.cache.object(forKey: dataKey as NSString) { return cached }
            guard let decoded = NSImage(data: pooled) else { return nil }
            PictureBytes.cache.setObject(decoded, forKey: dataKey as NSString)
            return decoded
        }
        return nil
    }
}

/// The envelope's picture pool, in scope for exactly as long as one decode.
///
/// A task-local rather than a parameter because `WireImage` is decoded from a dozen places through
/// `Decodable`, which has nowhere to carry a context — and rather than a post-pass over the decoded
/// document because one of those places (`OfficeMasterObject.Content.image`) holds a real `NSImage`
/// and throws when there are no bytes, so by the time a post-pass ran the decode would already have
/// failed. Bound in `RustEngine.decodeOffice`, empty everywhere else.
enum PictureBytes {
    @TaskLocal static var pool: [String: Data] = [:]
    /// Scoped to one decode alongside the pool — a key is content-addressed, so an entry is only
    /// ever the same picture, but keeping it past the decode would hold every document's bitmaps
    /// alive for the life of the process.
    @TaskLocal static var cache: NSCache<NSString, NSImage> = NSCache()

    /// Bind both for one decode. The only way in — so a decode either has a pool and a fresh cache
    /// or has neither, and never one document's bitmaps under another's keys.
    static func withPool<T>(_ pool: [String: Data], _ body: () throws -> T) rethrows -> T {
        try $pool.withValue(pool) { try $cache.withValue(NSCache<NSString, NSImage>(), operation: body) }
    }
}

/// A gradient fill DECLARATION on the wire — `office_block::OfficeGradient`'s own JSON, never a
/// rasterized bitmap (that stays `WireImage`, decoded separately into `backgroundImage`).
struct WireGradient: Decodable {
    let stops: [WireColor]
    let angleDegrees: CGFloat?
    var gradient: OfficeGradient {
        OfficeGradient(stops: stops.map { $0.color }, angleDegrees: angleDegrees)
    }
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

extension HwpShapeRenderer.Path.Command: Decodable {
    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self), name == "Close" {
            self = .close
            return
        }
        let (c, key) = try singleKey(decoder)
        switch key.stringValue {
        case "Move": self = .move(try c.decode(WirePoint.self, forKey: key).point)
        case "Line": self = .line(try c.decode(WirePoint.self, forKey: key).point)
        case "Curve":
            let points = try c.decode([WirePoint].self, forKey: key)
            guard points.count == 3 else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                       debugDescription: "curve needs three points")
            }
            self = .curve(points[0].point, points[1].point, points[2].point)
        default:
            throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                   debugDescription: "unknown path command")
        }
    }
}

extension HwpShapeRenderer.Path: Decodable {
    private enum CodingKeys: String, CodingKey { case commands, stroke, fill, arrowStart, arrowEnd }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commands = try c.decode([Command].self, forKey: .commands)
        stroke = try c.decodeIfPresent(BorderSide.self, forKey: .stroke)
        fill = try c.decodeIfPresent(WireColor.self, forKey: .fill)?.color
        arrowStart = try c.decode(Bool.self, forKey: .arrowStart)
        arrowEnd = try c.decode(Bool.self, forKey: .arrowEnd)
    }
}

extension HwpShapeRenderer.VectorGraphic: Decodable {
    private enum CodingKeys: String, CodingKey { case paths, size }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paths = try c.decode([HwpShapeRenderer.Path].self, forKey: .paths)
        size = try c.decode(WireSize.self, forKey: .size).size
    }
}

extension OfficeMasterObject.Content: Decodable {
    init(from decoder: Decoder) throws {
        let (c, key) = try singleKey(decoder)
        switch key.stringValue {
        case "Image":
            let wire = try c.decode(WireImage.self, forKey: key)
            if let image = wire.image {
                self = .image(image)
            } else if wire.dataKey != nil {
                // The wire named a pooled picture and the pool does not hold it. Before pictures
                // were pooled this could only mean "an image with no bytes at all", and throwing
                // took the WHOLE document down with it — the failure P2c and P2d spent themselves
                // removing for every other kind of picture. So reserve the declared box and draw
                // nothing in it, which is what the reader already does for a picture a document
                // names but has no bytes for (invariant 1's rule, `appendImage`).
                self = .image(NSImage(size: wire.size.size))
            } else {
                // No key and no bytes: the wire itself is malformed, not the pool incomplete.
                throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                       debugDescription: "host image has no bytes")
            }
        case "Drawing": self = .drawing(try c.decode(Data.self, forKey: key))
        case "Vector": self = .vector(try c.decode(HwpShapeRenderer.VectorGraphic.self, forKey: key))
        case "Text": self = .text(try c.decode([OfficeBlock].self, forKey: key))
        default:
            throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                   debugDescription: "unknown master object content")
        }
    }
}

extension OfficeMasterObject: Decodable {
    private enum CodingKeys: String, CodingKey { case frame, content }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(WireRect.self, forKey: .frame).rect
        content = try c.decode(Content.self, forKey: .content)
    }
}

extension ParagraphAnchor.Align: Decodable {
    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "top": self = .top
        case "center": self = .center
        case "bottom": self = .bottom
        default: throw DecodingError.dataCorruptedError(
            in: try decoder.singleValueContainer(), debugDescription: "unknown paragraph anchor")
        }
    }
}

extension ParagraphAnchor: Decodable {
    private enum CodingKeys: String, CodingKey { case align, offset }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        align = try c.decode(Align.self, forKey: .align)
        offset = try c.decode(CGFloat.self, forKey: .offset)
    }
}

extension OfficeAnchoredObject: Decodable {
    private enum CodingKeys: String, CodingKey { case blockIndex, object, paragraphAnchor }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockIndex = try c.decode(Int.self, forKey: .blockIndex)
        object = try c.decode(OfficeMasterObject.self, forKey: .object)
        paragraphAnchor = try c.decodeIfPresent(ParagraphAnchor.self, forKey: .paragraphAnchor)
    }
}

extension OfficeMasterPage: Decodable {
    private enum CodingKeys: String, CodingKey { case section, appliesTo, objects }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        section = try c.decode(Int.self, forKey: .section)
        appliesTo = try c.decode(HeaderFooterApplicability.self, forKey: .appliesTo)
        objects = try c.decode([OfficeMasterObject].self, forKey: .objects)
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
