import AppKit

// U4: the Swift-side mirror of `EnvelopeV1` (`rust/crates/fastdoc-engine/src/render/render_tree/
// wire.rs`) — decodes the SAME tree `fastdoc_office_tree_json` hands back, field for field. Names
// stay 1:1 with the Rust wire struct they decode (see each type's comment for its `wire::` twin),
// so a diff against `wire.rs` is a diff against this file, not a guess.
//
// Deliberately narrower than `wire.rs`: fields the office adapter (`RenderTreeOfficeAdapter.swift`)
// never reads are left off these structs. `Decodable`'s keyed containers ignore JSON keys nobody
// asked for, so omitting `sources`, `producer`, `Node.sourceSpans`/`edit`, and every markdown-only
// node payload costs nothing and keeps this file the size of what U4 actually consumes.
//
// Three wire types are byte-for-byte what the existing schema-v5 decoder already reads
// (`OfficeEnvelopeDecoding.swift`), so this file reuses them rather than declaring twins:
// `WireColor` (`wire::Color`), `WireSize` (`wire::Size`), `WireGradient` (`wire::Gradient`), and
// `DeclaredFace` (`OfficeBlock.swift`/`DeclaredFontKind.swift`) — the last is literally the same
// Rust type on both wires (`office_adapter`'s own `declared_faces` field comment).

typealias WireNodeId = UInt64

/// The self-describing envelope `fastdoc_office_tree_json`/`fastdoc_read_office_tree` return:
/// `{"ffiVersion":1,"ok":<tree>}` or `{"ffiVersion":1,"error":{...}}` — never a bare NULL for a
/// document-level failure (see that function's own doc in `fastdoc_engine_ffi.h`).
struct WireTreeEnvelope: Decodable {
    let ffiVersion: Int
    let ok: WireTree?
    let error: WireTreeError?
}

struct WireTreeError: Decodable {
    let kind: String
    let message: String
    let location: String?
}

/// `wire::EnvelopeV1`, narrowed to the fields the office adapter reads.
struct WireTree: Decodable {
    let schemaVersion: Int
    let document: WireDocument
    let nodes: [WireNode]
    let resources: [WireResource]
    let annotations: WireAnnotations
}

/// `wire::Document`.
struct WireDocument: Decodable {
    let rootNodeId: WireNodeId
    let declaredFaces: [String: DeclaredFace]
    let defaultBodyFontSize: Double
    let declaredSectionCount: UInt32
    let documentPaper: WirePaper?
    let lineGridPoints: Double?

    private enum CodingKeys: String, CodingKey {
        case rootNodeId, declaredFaces, defaultBodyFontSize, declaredSectionCount, documentPaper, lineGridPoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootNodeId = try c.decode(WireNodeId.self, forKey: .rootNodeId)
        // `declared_faces`'s VALUE type is `declared_font_kind::DeclaredFace`
        // (`wire.rs`'s own field comment: "the SAME type … reused"), a struct from a DIFFERENT
        // Rust module that carries NO `#[serde(rename_all = "camelCase")]` of its own — so unlike
        // every other field in this tree, its keys cross the wire as Rust's literal snake_case
        // (`is_embedded`, `nominated_substitute`, `type_info`), not camelCase. `WireDeclaredFace`
        // names them explicitly rather than leaning on a decoder-wide `.convertFromSnakeCase`,
        // which would also (wrongly) rewrite every camelCase key elsewhere in this same document.
        let raw = try c.decodeIfPresent([String: WireDeclaredFace].self, forKey: .declaredFaces) ?? [:]
        declaredFaces = raw.mapValues(\.face)
        defaultBodyFontSize = try c.decode(Double.self, forKey: .defaultBodyFontSize)
        declaredSectionCount = try c.decode(UInt32.self, forKey: .declaredSectionCount)
        documentPaper = try c.decodeIfPresent(WirePaper.self, forKey: .documentPaper)
        lineGridPoints = try c.decodeIfPresent(Double.self, forKey: .lineGridPoints)
    }
}

/// `declared_font_kind::DeclaredFace`'s own snake_case wire shape (see `WireDocument.init(from:)`'s
/// doc) — decoded here and converted to the app's own `DeclaredFace` (`OfficeBlock.swift`), which
/// both this door and the schema-v5 door hand to `FontSubstitutionResolver` identically.
private struct WireDeclaredFace: Decodable {
    let nominatedSubstitute: String?
    let isEmbedded: Bool
    let typeInfo: [UInt8]?

    private enum CodingKeys: String, CodingKey {
        case nominatedSubstitute = "nominated_substitute"
        case isEmbedded = "is_embedded"
        case typeInfo = "type_info"
    }

    var face: DeclaredFace {
        var out = DeclaredFace()
        out.nominatedSubstitute = nominatedSubstitute
        out.isEmbedded = isEmbedded
        out.typeInfo = typeInfo
        return out
    }
}

/// `wire::Paper`.
struct WirePaper: Decodable {
    let widthPoints: Double
    let heightPoints: Double
    let margins: WireInsets
    let headerDistancePoints: Double?
    let footerDistancePoints: Double?
}

/// `wire::Insets`.
struct WireInsets: Decodable {
    let top: Double
    let right: Double
    let bottom: Double
    let left: Double
}

/// `wire::OptionalInsets`.
struct WireOptionalInsets: Decodable {
    let top: Double?
    let right: Double?
    let bottom: Double?
    let left: Double?
}

/// `wire::PageNumbering`.
struct WirePageNumbering: Decodable {
    let start: Int64?
    let hidden: Bool
}

/// `wire::FootnoteSeparator`.
struct WireFootnoteSeparator: Decodable {
    let lineType: Int64
    let lineWidthPoints: Double
    let color: WireColor?
    let lengthPoints: Double?
    let marginTopPoints: Double
    let marginBottomPoints: Double
    let noteSpacingPoints: Double
}

/// `wire::PageBorder`.
struct WirePageBorder: Decodable {
    let borders: WireBorderSet?
    let background: WireColor?
    let spacing: WireInsets
    let measuredFromPaper: Bool
}

/// `wire::UniformBorder`.
struct WireUniformBorder: Decodable {
    let color: WireColor?
    let widthPoints: Double?
}

/// `wire::DrawnBorder`.
struct WireDrawnBorder: Decodable {
    let widthPoints: Double
    let color: WireColor?
    let style: WireBorderLineStyle
}

/// `wire::BorderLineStyle` — a bare-string enum on the wire.
enum WireBorderLineStyle: String, Decodable {
    case solid, dashed, dotted, double
}

/// `wire::BorderDeclaration` — `#[serde(tag = "kind", content = "value")]`: `{"kind":"suppressed"}`
/// or `{"kind":"drawn","value":{...}}`.
enum WireBorderDeclaration: Decodable {
    case suppressed
    case drawn(WireDrawnBorder)

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "suppressed": self = .suppressed
        case "drawn": self = .drawn(try c.decode(WireDrawnBorder.self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown border declaration \"\(other)\"")
        }
    }
}

/// `wire::BorderSet`.
struct WireBorderSet: Decodable {
    let top: WireBorderDeclaration?
    let right: WireBorderDeclaration?
    let bottom: WireBorderDeclaration?
    let left: WireBorderDeclaration?
    let insideHorizontal: WireBorderDeclaration?
    let insideVertical: WireBorderDeclaration?
}

/// `wire::CellDiagonal` (the TREE's own type — not `OfficeBlock.swift`'s app-level `CellDiagonal`,
/// which this decodes INTO).
struct WireCellDiagonalRT: Decodable {
    let direction: WireCellDiagonalDirection
    let side: WireDrawnBorder
}

enum WireCellDiagonalDirection: String, Decodable {
    case slash, backslash, both
}

/// `wire::TableStyle`.
struct WireTableStyle: Decodable {
    let defaultUniformBorder: WireUniformBorder?
    let defaultShading: WireColor?
    let edgeBorders: WireBorderSet?
    let defaultPadding: WireOptionalInsets?
    let sourceWidthPoints: Double?
    let repeatHeaderRows: Bool?
    let pageBreakPolicy: WireTablePageBreakPolicy?
    let outerMargin: WireOptionalInsets?
    let backgroundResourceId: UInt64?
    let backgroundGradient: WireGradient?
}

enum WireTablePageBreakPolicy: String, Decodable {
    case never, atRowBoundary, anywhere
}

/// `wire::Alignment` — `Natural` is the wire's own spelling of "not stated" (`wire.rs`'s own
/// `Default` impl doc), never a guessed `.left`.
enum WireAlignment: String, Decodable {
    case natural, left, center, right, justified
}

/// `wire::VerticalAlignment` (a table cell's, not a run's).
enum WireCellVerticalAlignment: String, Decodable {
    case top, middle, bottom
}

/// `wire::Direction`.
enum WireDirection: String, Decodable {
    case natural, leftToRight, rightToLeft
}

/// `wire::LineHeight`.
struct WireLineHeight: Decodable {
    let value: Double
    let mode: WireLineHeightMode
}

enum WireLineHeightMode: String, Decodable {
    case multiple, exact, atLeast
}

enum WireLineBreakGranularity: String, Decodable {
    case word, hyphen, character
}

/// `wire::ParagraphStyle`.
struct WireParagraphStyle: Decodable {
    let alignment: WireAlignment?
    let direction: WireDirection?
    let firstLineIndent: Double?
    let headIndent: Double?
    let tailIndent: Double?
    let spacingBefore: Double?
    let spacingAfter: Double?
    let lineHeight: WireLineHeight?
    let borders: WireBorderSet?
    let shading: WireColor?
    let listTextDistance: Double?
    let hangingIndent: Double?
    let contextualSpacing: Bool
    let eastAsianLineBreak: WireLineBreakGranularity?
    let latinLineBreak: WireLineBreakGranularity?
    let autoSpaceEastAsianLatin: Bool?
    let autoSpaceEastAsianNumber: Bool?
    let lineHeightFromFontMetrics: Bool?
    let lineSpacingBelow: Bool?
    let pageBreakBefore: Bool?
    let keepWithNext: Bool?
}

/// `wire::ParagraphPagination`.
struct WireParagraphPagination: Decodable {
    let keepWithNext: Bool
    let pageBreakBefore: Bool
    let hidesPageNumber: Bool
    let pageNumberRestart: Int64?
}

/// `wire::TabAlignment`/`wire::TabLeader`/`wire::TabStop`.
enum WireTabAlignment: String, Decodable { case left, center, right, decimal }
enum WireTabLeader: String, Decodable { case none, dot, hyphen, underscore }
struct WireTabStop: Decodable {
    let positionPoints: Double
    let alignment: WireTabAlignment
    let leader: WireTabLeader
}

/// `wire::Heading`.
struct WireHeading: Decodable {
    let level: Int64
    let style: WireParagraphStyle
    let tabStops: [WireTabStop]
    let pagination: WireParagraphPagination
}

/// `wire::Paragraph`.
struct WireParagraph: Decodable {
    let style: WireParagraphStyle
    let tabStops: [WireTabStop]
    let pagination: WireParagraphPagination
}

/// `wire::ListNumberingGlyphs`.
enum WireListNumberingGlyphs: String, Decodable {
    case decimal, circledDecimal, romanUpper, romanLower, latinUpper, latinLower
    case hangulSyllable, hangulNumber, hanjaNumber
}

/// `wire::Numbering`.
struct WireNumbering: Decodable {
    let glyphs: WireListNumberingGlyphs
    let startNumber: Int64?
}

/// `wire::ListItem`.
struct WireListItem: Decodable {
    let level: UInt32
    let ordered: Bool
    let marker: String?
    let numbering: WireNumbering?
    let style: WireParagraphStyle
    let tabStops: [WireTabStop]
    let pagination: WireParagraphPagination
}

/// `wire::UnderlineStyle`/`wire::VerticalPosition`/`wire::FormControlKind`/`wire::PageNumberField`.
enum WireUnderlineStyle: String, Decodable { case single, double, dotted, dashed, wavy }
enum WireVerticalPosition: String, Decodable { case normal, superscript, subscript_ = "subscript" }
enum WireFormControlKind: String, Decodable {
    case checkBox, radioButton, pushButton, comboBox, edit, listBox, scrollBar, unknown
}
enum WirePageNumberFieldRT: String, Decodable { case page, numPages }

/// `wire::CharacterStyle`.
struct WireCharacterStyle: Decodable {
    let bold: Bool
    let italic: Bool
    let strike: Bool
    let inlineCode: Bool
    let caps: Bool
    let smallCaps: Bool
    let underline: WireUnderlineStyle?
    let verticalPosition: WireVerticalPosition
    let letterSpacingPercent: Double?
    let widthScalePercent: Double?
    let baselineOffsetPercent: Double?
    let underlineColor: WireColor?
    let strikethroughColor: WireColor?
    let declaredFontName: String?
    let fontSizePoints: Double?
    let foreground: WireColor?
    let background: WireColor?
}

/// `wire::InlineFormControl`.
struct WireInlineFormControl: Decodable {
    let kind: WireFormControlKind
    let caption: String
    let text: String
    let value: Int64
    let enabled: Bool
}

/// `wire::ColumnFlowType`/`wire::ColumnFlowDirection`/`wire::ColumnSeparatorStyle`.
enum WireColumnFlowType: String, Decodable { case normal, distribute, parallel }
enum WireColumnFlowDirection: String, Decodable { case leftToRight, rightToLeft }
enum WireColumnSeparatorStyle: String, Decodable {
    case none, solid, dash, dot, dashDot, dashDotDot, longDash, circle
}

/// `wire::ColumnSeparator`.
struct WireColumnSeparator: Decodable {
    let style: WireColumnSeparatorStyle
    let sourceWidthCode: UInt8
    let widthPoints: Double
    let sourceColorRef: UInt32
    let color: WireColor
}

/// `wire::ColumnFlowDeclaration`.
struct WireColumnFlowDeclaration: Decodable {
    let count: UInt32
    let spacingPoints: Double
    let widths: [Double]
    let gaps: [Double]
    let flowType: WireColumnFlowType
    let direction: WireColumnFlowDirection
    let sourceSameWidth: Bool
    let sourceProportionalWidths: Bool
    let sourceRawAttributes: UInt16
    let separator: WireColumnSeparator
}

/// `wire::TextRun`.
struct WireTextRun: Decodable {
    let text: String
    let style: WireCharacterStyle
    let direction: WireDirection?
    let link: String?
    let bookmarkIds: [WireNodeId]
    let commentIds: [WireNodeId]
    let footnoteReferenceNumber: Int64?
    let formControl: WireInlineFormControl?
    let pageNumberField: WirePageNumberFieldRT?
    let columnFlow: WireColumnFlowDeclaration?
}

/// `wire::Table`.
struct WireTable: Decodable {
    let alignment: WireAlignment
    let headerRows: UInt32
    let sourceColumnWidths: [Double]
    let style: WireTableStyle
}

/// `wire::TableCell`.
struct WireTableCell: Decodable {
    let column: UInt32
    let rowSpan: UInt32
    let columnSpan: UInt32
    let directShading: WireColor?
    let directUniformBorder: WireUniformBorder?
    let directEdgeBorders: WireBorderSet?
    let declaredWidthPoints: Double?
    let verticalAlignment: WireCellVerticalAlignment?
    let uniformPaddingPoints: Double?
    let edgePadding: WireOptionalInsets?
    let declaredHeight: Double?
    let minimumRowHeight: Double?
    let diagonal: WireCellDiagonalRT?
    let styleShading: WireColor?
    let styleUniformBorder: WireUniformBorder?
    let backgroundResourceId: UInt64?
    let backgroundGradient: WireGradient?
}

/// `wire::Image` (a node payload — distinct from the app's `NSImage`/existing `WireImage`, which
/// decodes schema-v5's ALREADY-RESOLVED picture bytes; this is the tree's own declaration).
struct WireImageNode: Decodable {
    let resourceId: UInt64?
    let intrinsicSize: WireSize
    let alignment: WireAlignment
    let sourceKey: String?
}

/// `wire::PathCommand`.
struct WirePathCommandRT: Decodable {
    let command: String
    let values: [Double]
}

/// `wire::VectorPath`.
struct WireVectorPath: Decodable {
    let commands: [WirePathCommandRT]
    let stroke: WireDrawnBorder?
    let fill: WireColor?
    let arrowStart: Bool
    let arrowEnd: Bool
}

/// `wire::Vector`.
struct WireVectorNode: Decodable {
    let paths: [WireVectorPath]
    let intrinsicSize: WireSize
    let alignment: WireAlignment
    let sourceKey: String?
}

/// `wire::Formula`.
struct WireFormula: Decodable {
    let source: String
}

/// `wire::Unsupported`.
struct WireUnsupported: Decodable {
    let reason: String
    let intrinsicSize: WireSize
    let alignment: WireAlignment
}

/// `wire::HeaderFooterApplicability`.
enum WireHeaderFooterApplicability: String, Decodable {
    case defaultPages, firstPage, evenPages, oddPages
}

/// `wire::HeaderFooter` (the `Header`/`Footer` node payload).
struct WireHeaderFooterNode: Decodable {
    let appliesTo: WireHeaderFooterApplicability
    let section: Int64?
}

/// `wire::Footnote`.
struct WireFootnoteNode: Decodable {
    let number: UInt64
}

/// `wire::ParagraphAnchorAlign`/`wire::ParagraphAnchor`.
enum WireParagraphAnchorAlign: String, Decodable { case top, center, bottom }
struct WireParagraphAnchorRT: Decodable {
    let align: WireParagraphAnchorAlign
    let offset: Double
}

/// `wire::AnchoredObject`.
struct WireAnchoredObjectNode: Decodable {
    let x: Double
    let width: Double
    let height: Double
    let y: Double?
    let paragraphAnchor: WireParagraphAnchorRT?
    let anchoredToId: WireNodeId
    let contentId: WireNodeId
}

/// `wire::MasterPage`.
struct WireMasterPageNode: Decodable {
    let appliesTo: WireHeaderFooterApplicability
    let objectIds: [WireNodeId]
}

/// `wire::MasterPageObject`.
struct WireMasterPageObjectNode: Decodable {
    let x: Double
    let width: Double
    let height: Double
    let y: Double
    let contentId: WireNodeId
}

/// `wire::Section`.
struct WireSection: Decodable {
    let paper: WirePaper?
    let paperIsDeclared: Bool
    let lineGridIsDeclared: Bool
    let pageNumbering: WirePageNumbering
    let lineGridPoints: Double?
    let footnoteSeparator: WireFootnoteSeparator?
    let pageBorder: WirePageBorder?
    let hidesHeader: Bool
    let hidesFooter: Bool
    let hidesMasterPage: Bool
    let isVertical: Bool
}

/// `wire::Resource`.
struct WireResource: Decodable {
    let id: WireNodeId
    let bytesBase64: String?
    let sourceKey: String?
}

/// `wire::Bookmark`.
struct WireBookmark: Decodable {
    let id: WireNodeId
    let name: String
}

/// `wire::Comment`.
struct WireCommentRT: Decodable {
    let id: WireNodeId
    let sourceId: String
    let author: String
    let text: String
    let dateIso: String?
    let number: Int64
}

/// `wire::Annotations`.
struct WireAnnotations: Decodable {
    let comments: [WireCommentRT]
    let bookmarks: [WireBookmark]
}

/// `wire::NodePayload` — `#[serde(tag = "type", content = "data")]`, `#[serde(flatten)]`ed onto
/// `Node` (`wire.rs`'s own `node_payloads!` macro). Payload kinds this office adapter never
/// produces from an office document (`lineBreak`/`codeBlock`/`blockQuote`/`thematicBreak`/
/// `rawHtml`/`diagram`/`taskListItem`/`formControl` — the markdown-only vocabulary, plus a
/// standalone `formControl` NODE, which the office readers never emit; a form control always
/// arrives inline on a `TextRun`) decode to `.other` rather than a dedicated case: no reader ever
/// constructs an `OfficeBlock` from any of them, so the tree never carries one to project back.
enum WireNodePayload {
    case document
    case section(WireSection)
    case flow
    case heading(WireHeading)
    case paragraph(WireParagraph)
    case textRun(WireTextRun)
    case list
    case listItem(WireListItem)
    case table(WireTable)
    case tableRow
    case tableCell(WireTableCell)
    case image(WireImageNode)
    case vector(WireVectorNode)
    case formula(WireFormula)
    case footnote(WireFootnoteNode)
    case header(WireHeaderFooterNode)
    case footer(WireHeaderFooterNode)
    case unsupported(WireUnsupported)
    case anchoredObject(WireAnchoredObjectNode)
    case masterPage(WireMasterPageNode)
    case masterPageObject(WireMasterPageObjectNode)
    case other(String)
}

/// `wire::Node`, narrowed to what the office adapter walks — `sourceSpans`/`edit` are read by
/// nobody on this path and are left undecoded (an unread JSON key costs nothing).
struct WireNode: Decodable {
    let id: WireNodeId
    let children: [WireNodeId]
    let payload: WireNodePayload

    private enum CodingKeys: String, CodingKey { case id, children, type, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(WireNodeId.self, forKey: .id)
        children = try c.decodeIfPresent([WireNodeId].self, forKey: .children) ?? []
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "document": payload = .document
        case "section": payload = .section(try c.decode(WireSection.self, forKey: .data))
        case "flow": payload = .flow
        case "heading": payload = .heading(try c.decode(WireHeading.self, forKey: .data))
        case "paragraph": payload = .paragraph(try c.decode(WireParagraph.self, forKey: .data))
        case "textRun": payload = .textRun(try c.decode(WireTextRun.self, forKey: .data))
        case "list": payload = .list
        case "listItem": payload = .listItem(try c.decode(WireListItem.self, forKey: .data))
        case "table": payload = .table(try c.decode(WireTable.self, forKey: .data))
        case "tableRow": payload = .tableRow
        case "tableCell": payload = .tableCell(try c.decode(WireTableCell.self, forKey: .data))
        case "image": payload = .image(try c.decode(WireImageNode.self, forKey: .data))
        case "vector": payload = .vector(try c.decode(WireVectorNode.self, forKey: .data))
        case "formula": payload = .formula(try c.decode(WireFormula.self, forKey: .data))
        case "footnote": payload = .footnote(try c.decode(WireFootnoteNode.self, forKey: .data))
        case "header": payload = .header(try c.decode(WireHeaderFooterNode.self, forKey: .data))
        case "footer": payload = .footer(try c.decode(WireHeaderFooterNode.self, forKey: .data))
        case "unsupported": payload = .unsupported(try c.decode(WireUnsupported.self, forKey: .data))
        case "anchoredObject":
            payload = .anchoredObject(try c.decode(WireAnchoredObjectNode.self, forKey: .data))
        case "masterPage": payload = .masterPage(try c.decode(WireMasterPageNode.self, forKey: .data))
        case "masterPageObject":
            payload = .masterPageObject(try c.decode(WireMasterPageObjectNode.self, forKey: .data))
        default: payload = .other(tag)
        }
    }
}
