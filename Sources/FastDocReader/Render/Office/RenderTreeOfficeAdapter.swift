import AppKit
import CFastdocEngine

// U4: `EnvelopeV1` -> `OfficeReadResult`. This file builds the app's own `OfficeReadResult`/
// `OfficeBlock` values directly from the wire tree instead of decoding JSON — so it needs no
// picture/edge-border/paragraph-format POOLING (that exists only to shrink JSON text) and no
// `formatRef`/`edgeBordersRef` indirection (`OfficeBlock`'s cases carry a resolved
// `ParagraphFormat`/`EdgeBorders?` directly, never a pool slot).

/// What this adapter could not honestly build from the tree — a missing node, a dangling
/// reference, or a field the tree has no honest way to supply. One case rather than several
/// because nothing downstream branches on which: every reason means "fall back exactly as a
/// decode failure would" (invariant 115's own rule — see `RustOfficeDocumentHandle.officeContent`'s
/// doc).
struct RenderTreeAdapterError: Error {
    let detail: String
}

enum RenderTreeOfficeAdapter {
    /// The document, built from its `WireTree` alone.
    static func project(_ tree: WireTree) throws -> OfficeReadResult {
        var byId: [WireNodeId: WireNode] = [:]
        byId.reserveCapacity(tree.nodes.count)
        for node in tree.nodes { byId[node.id] = node }
        var resources: [WireNodeId: WireResource] = [:]
        for resource in tree.resources { resources[resource.id] = resource }
        let bookmarkNames = Dictionary(uniqueKeysWithValues: tree.annotations.bookmarks.map { ($0.id, $0.name) })
        let commentSourceIds = Dictionary(
            uniqueKeysWithValues: tree.annotations.comments.map { ($0.id, $0.sourceId) })

        let proj = Projector(byId: byId, resources: resources,
                             bookmarkNames: bookmarkNames, commentSourceIds: commentSourceIds)

        let root = try proj.get(tree.document.rootNodeId)
        guard !root.children.isEmpty else {
            throw RenderTreeAdapterError(detail: "document has no section children")
        }
        let isMultiSection = root.children.count > 1
        let declaredSectionCount = Int(tree.document.declaredSectionCount)
        if isMultiSection && declaredSectionCount != root.children.count {
            throw RenderTreeAdapterError(detail:
                "declaredSectionCount \(declaredSectionCount) disagrees with \(root.children.count) section nodes")
        }

        var blocks: [OfficeBlock] = []
        var headers: [OfficeHeaderFooter] = []
        var footers: [OfficeHeaderFooter] = []
        var footnotes: [OfficeFootnote] = []
        var anchoredObjects: [OfficeAnchoredObject] = []
        var masterPages: [OfficeMasterPage] = []
        var wireSections: [WireSection] = []
        var sectionStartBlocks: [Int] = []

        for (sectionIndex, sectionId) in root.children.enumerated() {
            let sectionNode = try proj.get(sectionId)
            guard case let .section(section) = sectionNode.payload else {
                throw RenderTreeAdapterError(detail: "document child was not a section")
            }
            wireSections.append(section)

            var flowId: WireNodeId?
            var pendingAnchored: [WireAnchoredObjectNode] = []
            for childId in sectionNode.children {
                let child = try proj.get(childId)
                switch child.payload {
                case .flow: flowId = childId
                case .header(let hf): headers.append(try proj.headerFooter(child, hf))
                case .footer(let hf): footers.append(try proj.headerFooter(child, hf))
                case .footnote(let note): footnotes.append(try proj.footnote(child, note))
                case .anchoredObject(let ao): pendingAnchored.append(ao)
                case .masterPage(let mp): masterPages.append(try proj.masterPage(mp, sectionIndex))
                default:
                    throw RenderTreeAdapterError(detail: "unexpected section child payload")
                }
            }
            guard let flowId else {
                throw RenderTreeAdapterError(detail: "section has no flow child")
            }
            let flowChildren = try proj.get(flowId).children

            sectionStartBlocks.append(blocks.count)
            blocks.append(contentsOf: try proj.mapBlocks(flowChildren, baseIndex: blocks.count))

            for ao in pendingAnchored {
                anchoredObjects.append(try proj.anchoredObject(ao))
            }
        }

        let defaultBodyFontSize = CGFloat(tree.document.defaultBodyFontSize)

        var pageContentWidth: CGFloat?, pageMarginLeft: CGFloat?, pageMarginRight: CGFloat?
        var pageContentHeight: CGFloat?, pageMarginTop: CGFloat?, pageMarginBottom: CGFloat?
        var pageHeaderDistance: CGFloat?, pageFooterDistance: CGFloat?
        if let paper = tree.document.documentPaper {
            pageContentWidth = CGFloat(paper.widthPoints - paper.margins.left - paper.margins.right)
            pageMarginLeft = CGFloat(paper.margins.left)
            pageMarginRight = CGFloat(paper.margins.right)
            pageContentHeight = CGFloat(paper.heightPoints - paper.margins.top - paper.margins.bottom)
            pageMarginTop = CGFloat(paper.margins.top)
            pageMarginBottom = CGFloat(paper.margins.bottom)
            pageHeaderDistance = paper.headerDistancePoints.map { CGFloat($0) }
            pageFooterDistance = paper.footerDistancePoints.map { CGFloat($0) }
        }

        // 1-indexed by this array's own order after sorting by wire id — both readers already
        // assign comment numbers this way (`annotations.comments`'s own doc).
        let comments: [OfficeComment] = tree.annotations.comments
            .sorted { $0.id < $1.id }
            .enumerated()
            .map { i, c in
                OfficeComment(id: c.sourceId, author: c.author.isEmpty ? nil : c.author,
                              dateISO: c.dateIso, text: c.text, number: i + 1)
            }

        let sections: [OfficeSectionDeclaration]
        let finalSectionStartBlocks: [Int]
        if declaredSectionCount == 0 {
            sections = []
            finalSectionStartBlocks = []
        } else {
            sections = wireSections.map(Self.sectionDeclaration)
            finalSectionStartBlocks = sectionStartBlocks
        }

        var result = OfficeReadResult(blocks: blocks)
        result.comments = comments
        result.images = proj.images
        result.vectorGraphics = proj.vectorGraphics
        result.defaultBodyFontSize = defaultBodyFontSize
        result.declaredFaces = tree.document.declaredFaces
        result.pageContentWidth = pageContentWidth
        result.pageMarginLeft = pageMarginLeft
        result.pageMarginRight = pageMarginRight
        result.pageContentHeight = pageContentHeight
        result.pageMarginTop = pageMarginTop
        result.pageMarginBottom = pageMarginBottom
        result.pageHeaderDistance = pageHeaderDistance
        result.pageFooterDistance = pageFooterDistance
        result.headers = headers
        result.footers = footers
        result.footnotes = footnotes
        result.masterPages = masterPages
        result.sections = sections
        result.anchoredObjects = anchoredObjects
        result.sectionStartBlocks = finalSectionStartBlocks
        result.keepWithNextBlocks = proj.keepWithNext.sorted()
        result.pageBreakBlocks = proj.pageBreak.sorted()
        result.hidePageNumberBlocks = proj.hidePageNumber.sorted()
        result.pageNumberRestartBlocks = proj.restart
        result.lineGridPitch = tree.document.lineGridPoints.map { CGFloat($0) }
        return paintVectors(result)
    }

    /// A vector graphic is host-painted to PDF once, folded into `images`, and the now-redundant
    /// `vectorGraphics` map is cleared. Returns the untouched result on a paint failure — the
    /// caller (`officeContent`/`readOffice`) treats a `nil` return from THIS function as failure
    /// for the WHOLE document rather than a partially-painted one — see those two call sites.
    private static func paintVectors(_ result: OfficeReadResult) -> OfficeReadResult {
        var result = result
        for (id, graphic) in result.vectorGraphics {
            guard let pdf = HwpShapeRenderer.pdf(paths: graphic.paths, size: graphic.size) else {
                FileHandle.standardError.write(
                    Data("fastdoc: host could not paint vector \(id) at \(graphic.size)\n".utf8))
                continue
            }
            result.images[id] = pdf
        }
        result.vectorGraphics.removeAll(keepingCapacity: false)
        return result
    }

    /// `paper`/`lineGridPitch` are read back only when the section itself declared them
    /// (`paperIsDeclared`/`lineGridIsDeclared`), never the document-level fallback the adapter
    /// fills the wire section with — see `wire::Section`'s own doc, invariant 73.
    private static func sectionDeclaration(_ s: WireSection) -> OfficeSectionDeclaration {
        var decl = OfficeSectionDeclaration()
        decl.footnoteSeparator = s.footnoteSeparator.map(footnoteSeparator)
        decl.pageBorder = s.pageBorder.map(pageBorder)
        decl.paper = s.paperIsDeclared ? s.paper.map(paperGeometry) : nil
        decl.hidesHeader = s.hidesHeader
        decl.hidesFooter = s.hidesFooter
        decl.hidesMasterPage = s.hidesMasterPage
        decl.pageNumberStart = s.pageNumbering.start.map(Int.init)
        decl.lineGridPitch = s.lineGridIsDeclared ? s.lineGridPoints.map { CGFloat($0) } : nil
        decl.isVertical = s.isVertical
        return decl
    }

    private static func paperGeometry(_ p: WirePaper) -> PaperGeometry {
        PaperGeometry(contentWidth: CGFloat(p.widthPoints - p.margins.left - p.margins.right),
                      contentHeight: CGFloat(p.heightPoints - p.margins.top - p.margins.bottom),
                      marginLeft: CGFloat(p.margins.left), marginTop: CGFloat(p.margins.top),
                      marginRight: CGFloat(p.margins.right), marginBottom: CGFloat(p.margins.bottom))
    }

    private static func footnoteSeparator(_ fs: WireFootnoteSeparator) -> OfficeFootnoteSeparator {
        var out = OfficeFootnoteSeparator()
        out.lineType = Int(fs.lineType)
        out.lineWidthPt = CGFloat(fs.lineWidthPoints)
        out.color = fs.color?.color
        out.lengthPt = fs.lengthPoints.map { CGFloat($0) }
        out.marginTopPt = CGFloat(fs.marginTopPoints)
        out.marginBottomPt = CGFloat(fs.marginBottomPoints)
        out.noteSpacingPt = CGFloat(fs.noteSpacingPoints)
        return out
    }

    private static func pageBorder(_ pb: WirePageBorder) -> OfficePageBorder {
        OfficePageBorder(
            borders: pb.borders.map(edgeBorders), background: pb.background?.color,
            spacing: NSEdgeInsets(top: CGFloat(pb.spacing.top), left: CGFloat(pb.spacing.left),
                                  bottom: CGFloat(pb.spacing.bottom), right: CGFloat(pb.spacing.right)),
            measuredFromPaper: pb.measuredFromPaper)
    }

    private static func borderDecl(_ d: WireBorderDeclaration) -> BorderDecl {
        switch d {
        case .suppressed: return .suppressed
        case .drawn(let side):
            return .drawn(BorderSide(width: CGFloat(side.widthPoints), color: side.color?.color,
                                     style: borderLineStyle(side.style)))
        }
    }

    private static func borderLineStyle(_ s: WireBorderLineStyle) -> BorderLineStyle {
        switch s {
        case .solid: return .solid
        case .dashed: return .dashed
        case .dotted: return .dotted
        case .double: return .double
        }
    }

    fileprivate static func edgeBorders(_ eb: WireBorderSet) -> EdgeBorders {
        EdgeBorders(top: eb.top.map(borderDecl), left: eb.left.map(borderDecl),
                    bottom: eb.bottom.map(borderDecl), right: eb.right.map(borderDecl),
                    insideH: eb.insideHorizontal.map(borderDecl), insideV: eb.insideVertical.map(borderDecl))
    }

    fileprivate static func edgePadding(_ oi: WireOptionalInsets) -> EdgePadding {
        EdgePadding(top: oi.top.map { CGFloat($0) }, left: oi.left.map { CGFloat($0) },
                    bottom: oi.bottom.map { CGFloat($0) }, right: oi.right.map { CGFloat($0) })
    }

    fileprivate static func gradient(_ g: WireGradient) -> OfficeGradient {
        g.gradient
    }

    /// An image/graphic's own alignment; `.natural` is "not stated" and reconstructs `nil`,
    /// never a guessed `.left` (see `WireAlignment`'s own doc).
    fileprivate static func alignmentBack(_ a: WireAlignment) -> NSTextAlignment? {
        switch a {
        case .natural: return nil
        case .left: return .left
        case .right: return .right
        case .center: return .center
        case .justified: return .justified
        }
    }

    /// A PARAGRAPH's alignment field, which (unlike the graphic-facing `alignmentBack` above) is
    /// ALREADY `Optional` on `ParagraphStyle.alignment` (`wire::ParagraphStyle`), so `.natural` is
    /// never reached here at all — see `paragraphFormatBack`.
    private static func paragraphAlignmentBack(_ a: WireAlignment) -> NSTextAlignment {
        switch a {
        case .natural: return .natural
        case .left: return .left
        case .right: return .right
        case .center: return .center
        case .justified: return .justified
        }
    }

    fileprivate static func underlineStyleBack(_ s: WireUnderlineStyle) -> UnderlineStyle {
        switch s {
        case .single: return .single
        case .double: return .double
        case .dotted: return .dotted
        case .dashed: return .dashed
        case .wavy: return .wavy
        }
    }

    fileprivate static func formControlKindBack(_ k: WireFormControlKind) -> OfficeFormControl.Kind {
        switch k {
        case .checkBox: return .checkBox
        case .radioButton: return .radioButton
        case .pushButton: return .pushButton
        case .comboBox: return .comboBox
        case .edit: return .edit
        case .listBox: return .listBox
        case .scrollBar: return .scrollBar
        case .unknown: return .unknown
        }
    }

    fileprivate static func pageNumberFieldBack(_ f: WirePageNumberFieldRT) -> PageNumberField {
        switch f {
        case .page: return .page
        case .numPages: return .numPages
        }
    }

    private static func headerFooterApplicability(_ v: WireHeaderFooterApplicability) -> HeaderFooterApplicability {
        switch v {
        case .defaultPages: return .defaultPages
        case .firstPage: return .firstPage
        case .evenPages: return .evenPages
        case .oddPages: return .oddPages
        }
    }

    private static func paragraphAnchorAlign(_ a: WireParagraphAnchorAlign) -> ParagraphAnchor.Align {
        switch a {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    fileprivate static func columnLayoutBack(_ flow: WireColumnFlowDeclaration) -> OfficeColumnLayout {
        var layout = OfficeColumnLayout(count: Int(flow.count))
        layout.spacing = CGFloat(flow.spacingPoints)
        layout.widths = flow.widths.map { CGFloat($0) }
        layout.gaps = flow.gaps.map { CGFloat($0) }
        layout.proportional = flow.sourceProportionalWidths
        layout.separatorType = Int(flow.separator.sourceWidthCode)
        layout.separatorWidthPt = CGFloat(flow.separator.widthPoints)
        layout.separatorColor = flow.separator.style == .none ? nil : flow.separator.color.color
        return layout
    }

    private static func lineBreakGranularityBack(_ v: WireLineBreakGranularity) -> LineBreakGranularity {
        switch v {
        case .word: return .word
        case .hyphen: return .hyphen
        case .character: return .character
        }
    }

    private static func lineHeightBack(_ lh: WireLineHeight) -> LineHeight {
        switch lh.mode {
        case .multiple: return .multiple(CGFloat(lh.value))
        case .exact: return .exact(CGFloat(lh.value))
        case .atLeast: return .atLeast(CGFloat(lh.value))
        }
    }

    /// One uniform colour/width across whichever edges the wire `BorderSet` names, taking the
    /// FIRST drawn edge's colour/width as representative.
    private static func paragraphBorderBack(_ bs: WireBorderSet?) -> (RectEdge, NSColor?, CGFloat?) {
        guard let bs else { return ([], nil, nil) }
        var edges: RectEdge = []
        var color: NSColor?
        var width: CGFloat?
        func take(_ decl: WireBorderDeclaration?, _ edge: RectEdge) {
            if case .drawn(let d) = decl {
                edges.insert(edge)
                if color == nil && width == nil {
                    color = d.color?.color
                    width = CGFloat(d.widthPoints)
                }
            }
        }
        take(bs.top, .top)
        take(bs.left, .left)
        take(bs.bottom, .bottom)
        take(bs.right, .right)
        return (edges, color, width)
    }

    /// Returns the `(ParagraphFormat, alignment, rtl)` triple `.heading`/`.paragraph`/`.listItem`
    /// each carry as three separate parameters.
    fileprivate static func paragraphFormatBack(
        _ style: WireParagraphStyle
    ) -> (ParagraphFormat, NSTextAlignment?, Bool) {
        let alignment = style.alignment.map(paragraphAlignmentBack)
        let rtl = style.direction == .rightToLeft
        let (borderEdges, borderColor, borderWidth) = paragraphBorderBack(style.borders)
        var format = ParagraphFormat()
        format.listTextDistance = style.listTextDistance.map { CGFloat($0) }
        format.spacingBefore = style.spacingBefore.map { CGFloat($0) }
        format.spacingAfter = style.spacingAfter.map { CGFloat($0) }
        format.lineHeight = style.lineHeight.map(lineHeightBack)
        format.indentStart = style.headIndent.map { CGFloat($0) }
        format.indentEnd = style.tailIndent.map { CGFloat($0) }
        format.firstLineIndent = style.firstLineIndent.map { CGFloat($0) }
        format.hangingIndent = style.hangingIndent.map { CGFloat($0) }
        format.contextualSpacing = style.contextualSpacing
        format.shading = style.shading?.color
        format.borderColor = borderColor
        format.borderWidth = borderWidth
        format.borderEdges = borderEdges
        format.eastAsianLineBreak = style.eastAsianLineBreak.map(lineBreakGranularityBack)
        format.latinLineBreak = style.latinLineBreak.map(lineBreakGranularityBack)
        format.autoSpaceEastAsianLatin = style.autoSpaceEastAsianLatin
        format.autoSpaceEastAsianNumber = style.autoSpaceEastAsianNumber
        format.lineHeightFromFontMetrics = style.lineHeightFromFontMetrics
        format.lineSpacingBelow = style.lineSpacingBelow
        format.pageBreakBefore = style.pageBreakBefore
        format.keepWithNext = style.keepWithNext
        return (format, alignment, rtl)
    }

    fileprivate static func tabStopsBack(_ stops: [WireTabStop]) -> [TabStop] {
        stops.map {
            TabStop(position: CGFloat($0.positionPoints), alignment: tabAlignmentBack($0.alignment),
                   leader: tabLeaderBack($0.leader))
        }
    }

    private static func tabAlignmentBack(_ v: WireTabAlignment) -> TabAlignment {
        switch v {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .decimal: return .decimal
        }
    }

    private static func tabLeaderBack(_ v: WireTabLeader) -> TabLeader {
        switch v {
        case .none: return .none
        case .dot: return .dot
        case .hyphen: return .hyphen
        case .underscore: return .underscore
        }
    }

    private static func cellVAlignBack(_ v: WireCellVerticalAlignment) -> CellVAlign {
        switch v {
        case .top: return .top
        case .middle: return .center
        case .bottom: return .bottom
        }
    }

    fileprivate static func pageBreakPolicyBack(_ v: WireTablePageBreakPolicy) -> TablePageBreakPolicy {
        switch v {
        case .never: return .never
        case .atRowBoundary: return .atRowBoundary
        case .anywhere: return .anywhere
        }
    }

    private static func cellDiagonalBack(_ d: WireCellDiagonalRT) -> CellDiagonal {
        let direction: CellDiagonal.Direction
        switch d.direction {
        case .slash: direction = .slash
        case .backslash: direction = .backslash
        case .both: direction = .both
        }
        return CellDiagonal(direction: direction, side: BorderSide(
            width: CGFloat(d.side.widthPoints), color: d.side.color?.color,
            style: borderLineStyle(d.side.style)))
    }

    /// The background fill (`background_image`/`background_gradient`) is left unset here — it is
    /// patched on by `Projector.mapTable`, which alone holds the resource lookup a fill needs.
    fileprivate static func cellBack(_ tc: WireTableCell, blocks: [OfficeBlock]) -> Cell {
        var cell = Cell(blocks: blocks, rowSpan: Int(tc.rowSpan), colSpan: Int(tc.columnSpan))
        cell.declaredHeight = tc.declaredHeight.map { CGFloat($0) }
        cell.minimumRowHeight = tc.minimumRowHeight.map { CGFloat($0) }
        cell.backgroundColor = tc.directShading?.color
        cell.borderColor = tc.directUniformBorder?.color?.color
        cell.borderWidth = tc.directUniformBorder?.widthPoints.map { CGFloat($0) }
        cell.edgeBorders = tc.directEdgeBorders.map(edgeBorders)
        cell.width = tc.declaredWidthPoints.map { CGFloat($0) }
        cell.verticalAlignment = tc.verticalAlignment.map(cellVAlignBack)
        cell.padding = tc.uniformPaddingPoints.map { CGFloat($0) }
        cell.edgePadding = tc.edgePadding.map(edgePadding)
        cell.diagonal = tc.diagonal.map(cellDiagonalBack)
        cell.styleShading = tc.styleShading?.color
        cell.styleBorderColor = tc.styleUniformBorder?.color?.color
        cell.styleBorderWidth = tc.styleUniformBorder?.widthPoints.map { CGFloat($0) }
        return cell
    }

    private static func pathCommandBack(_ cmd: WirePathCommandRT) -> HwpShapeRenderer.Path.Command {
        switch (cmd.command, cmd.values) {
        case ("moveTo", let v) where v.count == 2: return .move(CGPoint(x: v[0], y: v[1]))
        case ("lineTo", let v) where v.count == 2: return .line(CGPoint(x: v[0], y: v[1]))
        case ("curveTo", let v) where v.count == 6:
            return .curve(CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]), CGPoint(x: v[4], y: v[5]))
        default: return .close
        }
    }

    fileprivate static func vectorPathBack(_ p: WireVectorPath) -> HwpShapeRenderer.Path {
        HwpShapeRenderer.Path(
            commands: p.commands.map(pathCommandBack),
            stroke: p.stroke.map { BorderSide(width: CGFloat($0.widthPoints), color: $0.color?.color,
                                              style: borderLineStyle($0.style)) },
            fill: p.fill?.color, arrowStart: p.arrowStart, arrowEnd: p.arrowEnd)
    }

    fileprivate static func glyphsBack(_ v: WireListNumberingGlyphs) -> ListNumbering.Glyphs {
        switch v {
        case .decimal: return .decimal
        case .circledDecimal: return .circledDecimal
        case .romanUpper: return .romanUpper
        case .romanLower: return .romanLower
        case .latinUpper: return .latinUpper
        case .latinLower: return .latinLower
        case .hangulSyllable: return .hangulSyllable
        case .hangulNumber: return .hangulNumber
        case .hanjaNumber: return .hanjaNumber
        }
    }
}

/// Holds the running, per-document build state for one document's projection.
private final class Projector {
    let byId: [WireNodeId: WireNode]
    let resources: [WireNodeId: WireResource]
    var images: [String: Data] = [:]
    var vectorGraphics: [String: HwpShapeRenderer.VectorGraphic] = [:]
    var keepWithNext: Set<Int> = []
    var pageBreak: Set<Int> = []
    var hidePageNumber: Set<Int> = []
    var restart: [OfficePageNumberRestart] = []
    /// Node id -> its position in the reconstructed `blocks`, recorded as each top-level flow
    /// block is mapped — S6-2's reverse of `office_adapter::Ctx.block_node_id`, read back by
    /// `anchoredObject` to resolve `anchoredToId`.
    var nodeIndex: [WireNodeId: Int] = [:]
    let bookmarkNames: [WireNodeId: String]
    let commentSourceIds: [WireNodeId: String]

    init(byId: [WireNodeId: WireNode], resources: [WireNodeId: WireResource],
         bookmarkNames: [WireNodeId: String], commentSourceIds: [WireNodeId: String]) {
        self.byId = byId
        self.resources = resources
        self.bookmarkNames = bookmarkNames
        self.commentSourceIds = commentSourceIds
    }

    func get(_ id: WireNodeId) throws -> WireNode {
        guard let node = byId[id] else {
            throw RenderTreeAdapterError(detail: "dangling node id \(id)")
        }
        return node
    }

    func resolveBookmarkName(_ id: WireNodeId) throws -> String {
        guard let name = bookmarkNames[id] else {
            throw RenderTreeAdapterError(detail:
                "textRun.bookmarkIds named bookmark \(id), which annotations.bookmarks does not contain")
        }
        return name
    }

    func resolveCommentSourceId(_ id: WireNodeId) throws -> String {
        guard let sourceId = commentSourceIds[id] else {
            throw RenderTreeAdapterError(detail:
                "textRun.commentIds named comment \(id), which annotations.comments does not contain")
        }
        return sourceId
    }

    func headerFooter(_ node: WireNode, _ hf: WireHeaderFooterNode) throws -> OfficeHeaderFooter {
        guard let flowId = node.children.first else {
            throw RenderTreeAdapterError(detail: "header/footer has no flow")
        }
        let blocks = try mapBlocks(try get(flowId).children, baseIndex: 0)
        var out = OfficeHeaderFooter(appliesTo: applicability(hf.appliesTo), blocks: blocks)
        out.section = hf.section.map(Int.init)
        return out
    }

    func footnote(_ node: WireNode, _ note: WireFootnoteNode) throws -> OfficeFootnote {
        guard let flowId = node.children.first else {
            throw RenderTreeAdapterError(detail: "footnote has no flow")
        }
        let blocks = try mapBlocks(try get(flowId).children, baseIndex: 0)
        return OfficeFootnote(number: Int(note.number), blocks: blocks, section: nil)
    }

    private func applicability(_ v: WireHeaderFooterApplicability) -> HeaderFooterApplicability {
        switch v {
        case .defaultPages: return .defaultPages
        case .firstPage: return .firstPage
        case .evenPages: return .evenPages
        case .oddPages: return .oddPages
        }
    }

    // MARK: - Anchored / master content

    func anchoredObject(_ ao: WireAnchoredObjectNode) throws -> OfficeAnchoredObject {
        guard let blockIndex = nodeIndex[ao.anchoredToId] else {
            throw RenderTreeAdapterError(detail:
                "anchoredObject.anchoredToId \(ao.anchoredToId) names no block in this document's own flow")
        }
        let y = ao.y ?? 0
        let paragraphAnchor = ao.paragraphAnchor.map {
            ParagraphAnchor(align: Self.paragraphAnchorAlign($0.align), offset: CGFloat($0.offset))
        }
        let content = try anchoredContent(ao.contentId)
        let object = OfficeMasterObject(
            frame: CGRect(x: ao.x, y: y, width: ao.width, height: ao.height), content: content)
        return OfficeAnchoredObject(blockIndex: blockIndex, object: object, paragraphAnchor: paragraphAnchor)
    }

    private static func paragraphAnchorAlign(_ a: WireParagraphAnchorAlign) -> ParagraphAnchor.Align {
        switch a {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    /// A resource this use needs PIXELS from, never a by-reference key. Reaching one with no
    /// bytes is a real defect (P2a's own doc), not a document fact, so this throws rather than
    /// drawing a blank.
    private func resourceBytes(_ resource: WireResource) throws -> Data {
        guard let base64 = resource.bytesBase64, let data = Data(base64Encoded: base64) else {
            throw RenderTreeAdapterError(detail:
                "resource \(resource.id) carries no bytes, and this use needs pixels rather than a reference")
        }
        return data
    }

    private func backgroundResource(_ resourceId: WireNodeId) throws -> NSImage {
        guard let resource = resources[resourceId] else {
            throw RenderTreeAdapterError(detail: "background fill referenced missing resource \(resourceId)")
        }
        let bytes = try resourceBytes(resource)
        guard let image = NSImage(data: bytes) else {
            throw RenderTreeAdapterError(detail: "background fill bytes did not decode as an image")
        }
        return image
    }

    /// An existing `Image`/`Vector`/`Flow` node, read back into `OfficeMasterObject.Content`. No
    /// `sourceKey` is required here (unlike an ordinary in-flow picture): an anchored/master
    /// object's pixels never had a document-declared string id to round-trip, only decoded
    /// bytes/paths.
    func anchoredContent(_ contentId: WireNodeId) throws -> OfficeMasterObject.Content {
        let node = try get(contentId)
        switch node.payload {
        case .image(let img):
            guard let resourceId = img.resourceId else {
                throw RenderTreeAdapterError(detail: "anchored image carries no resource id")
            }
            guard let resource = resources[resourceId] else {
                throw RenderTreeAdapterError(detail: "anchored image referenced missing resource \(resourceId)")
            }
            let bytes = try resourceBytes(resource)
            guard let image = NSImage(data: bytes) else {
                throw RenderTreeAdapterError(detail: "anchored image bytes did not decode as an image")
            }
            return .image(image)
        case .vector(let v):
            let graphic = HwpShapeRenderer.VectorGraphic(
                paths: v.paths.map(RenderTreeOfficeAdapter.vectorPathBack),
                size: CGSize(width: v.intrinsicSize.width, height: v.intrinsicSize.height))
            return .vector(graphic)
        case .flow:
            let blocks = try mapBlocks(node.children, baseIndex: 0)
            return .text(blocks)
        default:
            throw RenderTreeAdapterError(detail: "anchoredObject.contentId named an unexpected node payload")
        }
    }

    func masterPage(_ mp: WireMasterPageNode, _ sectionIndex: Int) throws -> OfficeMasterPage {
        let objects = try mp.objectIds.map(masterObject)
        return OfficeMasterPage(section: sectionIndex, appliesTo: applicability(mp.appliesTo), objects: objects)
    }

    private func masterObject(_ objectId: WireNodeId) throws -> OfficeMasterObject {
        let node = try get(objectId)
        guard case let .masterPageObject(obj) = node.payload else {
            throw RenderTreeAdapterError(detail: "masterPage.objectIds named an unexpected node payload")
        }
        let content = try anchoredContent(obj.contentId)
        return OfficeMasterObject(frame: CGRect(x: obj.x, y: obj.y, width: obj.width, height: obj.height),
                                  content: content)
    }

    // MARK: - Flow -> [OfficeBlock]

    /// Walks a run of sibling node ids into `OfficeBlock`s, unwrapping the wire tree's synthetic
    /// `list` wrapper back into flat `listItem` blocks (office formats never nest items under a
    /// container block). `baseIndex` is this slice's own offset into the reconstructed flat
    /// `blocks` array, matching `office_adapter::map_blocks`'s re-keying so
    /// `keepWithNext`/`pageBreak`/… land on the same indices.
    func mapBlocks(_ ids: [WireNodeId], baseIndex: Int) throws -> [OfficeBlock] {
        var out: [OfficeBlock] = []
        out.reserveCapacity(ids.count)
        var i = baseIndex
        for id in ids {
            let node = try get(id)
            switch node.payload {
            case .list:
                for itemId in node.children {
                    let itemNode = try get(itemId)
                    guard case let .listItem(li) = itemNode.payload else {
                        throw RenderTreeAdapterError(detail: "list child was not a listItem")
                    }
                    out.append(try mapListItem(itemNode.children, li, index: i))
                    nodeIndex[itemId] = i
                    i += 1
                }
            default:
                out.append(try mapSingleBlock(node, index: i))
                nodeIndex[id] = i
                i += 1
            }
        }
        return out
    }

    private func recordPagination(_ index: Int, _ p: WireParagraphPagination) {
        if p.keepWithNext { keepWithNext.insert(index) }
        if p.pageBreakBefore { pageBreak.insert(index) }
        if p.hidesPageNumber { hidePageNumber.insert(index) }
        if let n = p.pageNumberRestart {
            restart.append(OfficePageNumberRestart(block: index, number: Int(n)))
        }
    }

    private func mapSpans(_ ids: [WireNodeId]) throws -> [Span] {
        var out: [Span] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            let node = try get(id)
            guard case let .textRun(run) = node.payload else {
                throw RenderTreeAdapterError(detail: "expected a text run")
            }
            out.append(try convertRun(run))
        }
        return out
    }

    private func convertRun(_ run: WireTextRun) throws -> Span {
        let columnLayout = run.columnFlow.map(RenderTreeOfficeAdapter.columnLayoutBack)
        let commentIds = try run.commentIds.map(resolveCommentSourceId)
        let bookmarks = try run.bookmarkIds.map(resolveBookmarkName)
        let underline = run.style.underline != nil
        let underlineStyle = run.style.underline.map(RenderTreeOfficeAdapter.underlineStyleBack) ?? .single
        var superscript = false, subscripted = false
        switch run.style.verticalPosition {
        case .superscript: superscript = true
        case .subscript_: subscripted = true
        case .normal: break
        }
        var span = Span(text: run.text)
        span.bold = run.style.bold
        span.italic = run.style.italic
        span.underline = underline
        span.underlineStyle = underlineStyle
        span.code = run.style.inlineCode
        span.caps = run.style.caps
        span.smallCaps = run.style.smallCaps
        span.link = run.link
        span.strikethrough = run.style.strike
        span.superscript = superscript
        span.footnoteRef = run.footnoteReferenceNumber.map(Int.init)
        span.formControl = run.formControl.map {
            OfficeFormControl(kind: RenderTreeOfficeAdapter.formControlKindBack($0.kind), caption: $0.caption,
                              text: $0.text, value: Int($0.value), enabled: $0.enabled)
        }
        span.columnLayout = columnLayout
        span.subscripted = subscripted
        span.rtl = run.direction == .rightToLeft
        span.bookmarks = bookmarks
        span.commentIds = commentIds
        span.textColor = run.style.foreground?.color
        span.highlightColor = run.style.background?.color
        span.letterSpacingPercent = run.style.letterSpacingPercent.map { CGFloat($0) }
        span.widthScalePercent = run.style.widthScalePercent.map { CGFloat($0) }
        span.baselineOffsetPercent = run.style.baselineOffsetPercent.map { CGFloat($0) }
        span.underlineColor = run.style.underlineColor?.color
        span.strikethroughColor = run.style.strikethroughColor?.color
        span.fontSize = run.style.fontSizePoints.map { CGFloat($0) }
        span.fontName = run.style.declaredFontName
        span.pageNumberField = run.pageNumberField.map(RenderTreeOfficeAdapter.pageNumberFieldBack)
        return span
    }

    private func mapListItem(_ spanIds: [WireNodeId], _ li: WireListItem, index: Int) throws -> OfficeBlock {
        recordPagination(index, li.pagination)
        let spans = try mapSpans(spanIds)
        let numbering = li.numbering.map { n in
            ListNumbering(glyphs: RenderTreeOfficeAdapter.glyphsBack(n.glyphs),
                          startNumber: n.startNumber.map(Int.init))
        }
        let (format, alignment, rtl) = RenderTreeOfficeAdapter.paragraphFormatBack(li.style)
        return .listItem(level: Int(li.level) - 1, ordered: li.ordered, spans: spans,
                         marker: li.marker, rtl: rtl, alignment: alignment,
                         tabStops: RenderTreeOfficeAdapter.tabStopsBack(li.tabStops),
                         format: format, numbering: numbering)
    }

    private func mapSingleBlock(_ node: WireNode, index: Int) throws -> OfficeBlock {
        switch node.payload {
        case .heading(let h):
            recordPagination(index, h.pagination)
            let spans = try mapSpans(node.children)
            let (format, alignment, rtl) = RenderTreeOfficeAdapter.paragraphFormatBack(h.style)
            return .heading(level: Int(h.level), spans: spans, rtl: rtl, alignment: alignment,
                            tabStops: RenderTreeOfficeAdapter.tabStopsBack(h.tabStops), format: format)
        case .paragraph(let p):
            recordPagination(index, p.pagination)
            let spans = try mapSpans(node.children)
            let (format, alignment, rtl) = RenderTreeOfficeAdapter.paragraphFormatBack(p.style)
            return .paragraph(spans: spans, rtl: rtl, alignment: alignment,
                              tabStops: RenderTreeOfficeAdapter.tabStopsBack(p.tabStops), format: format)
        case .table(let t):
            return try mapTable(node, t)
        case .image(let img):
            return try mapImage(img)
        case .vector(let v):
            return try mapVector(v)
        case .formula(let f):
            return .formula(latex: f.source)
        case .unsupported(let u):
            return .unsupportedGraphic(
                label: u.reason,
                size: CGSize(width: u.intrinsicSize.width, height: u.intrinsicSize.height),
                alignment: RenderTreeOfficeAdapter.alignmentBack(u.alignment))
        default:
            throw RenderTreeAdapterError(detail: "unexpected flow child")
        }
    }

    /// `resourceId == nil` is `wire::Image`'s own positive statement that the document declared
    /// this picture and no bytes back it (P2a); the block still carries `sourceKey` as its
    /// `.image(id:)`, matching invariant 1's reserved-but-unloaded contract. A resource carried BY
    /// REFERENCE (bytes absent, `sourceKey` present) is the same shape: `images` gets no entry,
    /// and whoever draws the block asks the still-open document.
    private func mapImage(_ img: WireImageNode) throws -> OfficeBlock {
        let alignment = RenderTreeOfficeAdapter.alignmentBack(img.alignment)
        let size = CGSize(width: img.intrinsicSize.width, height: img.intrinsicSize.height)
        guard let resourceId = img.resourceId else {
            guard let key = img.sourceKey else {
                throw RenderTreeAdapterError(detail: "image.sourceKey")
            }
            return .image(id: key, size: size, alignment: alignment)
        }
        guard let resource = resources[resourceId] else {
            throw RenderTreeAdapterError(detail: "image referenced missing resource \(resourceId)")
        }
        guard let key = resource.sourceKey else {
            throw RenderTreeAdapterError(detail: "resource.sourceKey")
        }
        if resource.bytesBase64 != nil {
            images[key] = try resourceBytes(resource)
        }
        return .image(id: key, size: size, alignment: alignment)
    }

    private func mapVector(_ v: WireVectorNode) throws -> OfficeBlock {
        guard let key = v.sourceKey else {
            throw RenderTreeAdapterError(detail: "vector.sourceKey")
        }
        let size = CGSize(width: v.intrinsicSize.width, height: v.intrinsicSize.height)
        let graphic = HwpShapeRenderer.VectorGraphic(paths: v.paths.map(RenderTreeOfficeAdapter.vectorPathBack),
                                                     size: size)
        vectorGraphics[key] = graphic
        return .image(id: key, size: size, alignment: RenderTreeOfficeAdapter.alignmentBack(v.alignment))
    }

    /// Cells are sorted by their own `column` within a row — the tree does not promise document
    /// order.
    private func mapTable(_ node: WireNode, _ t: WireTable) throws -> OfficeBlock {
        var rows: [[Cell]] = []
        rows.reserveCapacity(node.children.count)
        for rowId in node.children {
            let rowNode = try get(rowId)
            guard case .tableRow = rowNode.payload else {
                throw RenderTreeAdapterError(detail: "table child was not a row")
            }
            let cellIdsSorted = rowNode.children.sorted { a, b in
                let ca = try? get(a), cb = try? get(b)
                let colA: UInt32 = { if case let .tableCell(c) = ca?.payload { return c.column }; return 0 }()
                let colB: UInt32 = { if case let .tableCell(c) = cb?.payload { return c.column }; return 0 }()
                return colA < colB
            }
            var rowOut: [Cell] = []
            rowOut.reserveCapacity(cellIdsSorted.count)
            for cellId in cellIdsSorted {
                let cellNode = try get(cellId)
                guard case let .tableCell(tc) = cellNode.payload else {
                    throw RenderTreeAdapterError(detail: "row child was not a cell")
                }
                let blocks = try mapBlocks(cellNode.children, baseIndex: 0)
                var cell = RenderTreeOfficeAdapter.cellBack(tc, blocks: blocks)
                cell.backgroundImage = try tc.backgroundResourceId.map(backgroundResource)
                cell.backgroundGradient = tc.backgroundGradient.map(RenderTreeOfficeAdapter.gradient)
                rowOut.append(cell)
            }
            rows.append(rowOut)
        }

        let backgroundImage = try t.style.backgroundResourceId.map(backgroundResource)
        let backgroundGradient = t.style.backgroundGradient.map(RenderTreeOfficeAdapter.gradient)
        var format = TableFormat()
        format.defaultBorderColor = t.style.defaultUniformBorder?.color?.color
        format.defaultBorderWidth = t.style.defaultUniformBorder?.widthPoints.map { CGFloat($0) }
        format.defaultShading = t.style.defaultShading?.color
        format.backgroundImage = backgroundImage
        format.backgroundGradient = backgroundGradient
        format.sourceWidth = t.style.sourceWidthPoints.map { CGFloat($0) }
        format.edgeBorders = t.style.edgeBorders.map(RenderTreeOfficeAdapter.edgeBorders)
        format.defaultPadding = t.style.defaultPadding.map(RenderTreeOfficeAdapter.edgePadding)
        format.repeatHeaderRows = t.style.repeatHeaderRows
        format.pageBreakPolicy = t.style.pageBreakPolicy.map(RenderTreeOfficeAdapter.pageBreakPolicyBack)
        format.outerMargin = t.style.outerMargin.map(RenderTreeOfficeAdapter.edgePadding)

        return .table(rows: rows, headerRows: Int(t.headerRows),
                     columnWidths: t.sourceColumnWidths.map { CGFloat($0) }, format: format)
    }
}
