import AppKit

/// A single formatted run of text — the smallest unit `OfficeTextBuilder` styles. Traits are
/// independent flags, not mutually exclusive: a run can be bold AND italic AND underlined AND
/// `code` at once (an office format's run properties are independent axes, unlike markdown where
/// `` `code` `` can't nest inside `**bold**`) — `code` only changes which FONT/COLOR the run
/// renders with (see `OfficeTextBuilder`), it doesn't suppress the others.
struct Span: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    /// The underline's STYLE (docx `w:rPr/w:u/@w:val`, §17.18.99 `ST_Underline`) — meaningful only
    /// when `underline` is `true`; a non-underlined span still carries whatever default this field
    /// has, but `OfficeTextBuilder` never reads it in that case. Defaults to `.single`, which is
    /// both `ST_Underline`'s own most common value AND what every span rendered before this field
    /// existed (unconditionally `NSUnderlineStyle.single`). `underline` itself stays the on/off
    /// toggle it always was — see `DocxReader.isOn` — this field only refines what an ON underline
    /// LOOKS like.
    var underlineStyle: UnderlineStyle = .single
    var code: Bool = false
    /// docx `w:rPr/w:caps` (§17.3.2.5) — renders the run's text UPPERCASE at build time, without
    /// changing the underlying source model (`OfficeTextBuilder` uppercases only the DISPLAYED
    /// string). Wins over `smallCaps` when both are set (matches Word's own precedence — `w:caps`
    /// is the stronger of the two transforms).
    var caps: Bool = false
    /// docx `w:rPr/w:smallCaps` (§17.3.2.33) — renders lowercase letters as small capitals via an
    /// AppKit font feature, WITHOUT uppercasing the source text (unlike `caps` above) — the glyphs
    /// change, the characters don't.
    var smallCaps: Bool = false
    /// The link target, if this run is (or is inside) a hyperlink — `nil` for ordinary text. A
    /// later sprint's docx/odt parser resolves relationship ids / `text:a` hrefs down to this
    /// string; this sprint only carries the field through to rendering.
    var link: String? = nil
    var strikethrough: Bool = false
    var superscript: Bool = false
    /// Named `subscripted`, not `subscript` — that spelling is a Swift keyword and would need
    /// backticks at every call site (`` `subscript` ``). `superscript`/`subscripted` reads a little
    /// unevenly next to each other, but stays typeable everywhere without ceremony.
    var subscripted: Bool = false
    /// Whether THIS run is explicitly marked right-to-left (docx `w:rPr/w:rtl`, a toggle read the
    /// same on/off way as `bold`/`italic` — see `DocxReader.isOn`: present-and-unset-`w:val` is ON,
    /// `w:val="0"`/`"false"` is explicitly OFF). This is a RUN-level override for text embedded
    /// inside a paragraph of the opposite direction (a Latin phrase inside an Arabic sentence, or
    /// the reverse) — it does not, by itself, decide where the paragraph begins; that is
    /// `OfficeBlock`'s own `rtl` (see there for why direction is a paragraph property, not a font
    /// one). ODF's run-level markup (`text:span`) carries no equivalent signal — only a PARAGRAPH
    /// style's `style:writing-mode` — so an ODT-sourced `Span` never sets this; it stays `false`.
    var rtl: Bool = false
    /// Bookmark name(s) (docx `w:bookmarkStart`, odt `text:bookmark`/`text:bookmark-start`) whose
    /// target position is the START of this span — empty for ordinary text. `OfficeTextBuilder`
    /// turns a non-empty value into `MDAttr.bookmarkTarget` so an in-document anchor link elsewhere
    /// in the document can jump here by exact name. A span carrying a bookmark is never merged into
    /// its neighbour (see both readers' `appendMerging`) — merging would smear the marker's exact
    /// position across text that predates the bookmark.
    var bookmarks: [String] = []
    /// The id(s) of the reviewer COMMENT(s) whose commented RANGE this span falls within (docx
    /// `w:commentRangeStart`/`w:commentRangeEnd` @w:id, odt `office:annotation`/
    /// `office:annotation-end` @office:name) — empty for ordinary text, matching `OfficeComment.id`.
    /// A span can carry more than one id when two comments' ranges overlap — always APPENDED, never
    /// replaced. A span carrying a comment id is never merged into its neighbour (see both readers'
    /// `appendMerging`), the same reasoning as `bookmarks` above: merging would smear the range's
    /// exact extent across text that predates or postdates it. This sprint (P6a) only CAPTURES this
    /// — no view draws a highlight or a sidebar from it yet (P6b).
    var commentIds: [String] = []
    /// The run's authored text colour, already resolved to a literal RGB — `nil` means the source
    /// didn't specify one (or, for a THEME colour reference such as docx `w:color/@themeColor`,
    /// that a reader hasn't resolved it to a literal value yet; resolving those references against
    /// the document's theme part is later work, but this field is exactly where that resolved
    /// colour goes once it exists — nothing about this vocabulary or `OfficeTextBuilder` needs to
    /// change to receive it). `nil` is NOT "black" — `OfficeTextBuilder` decides what an unset (or,
    /// per its own judgement call, a near-neutral authored) colour renders as; see its
    /// `resolvedTextColor`.
    var textColor: NSColor? = nil
    /// The run's highlighter/background colour (docx `w:highlight`/`w:shd`, odt
    /// `style:text-background-color`) — `nil` for no highlight. Unlike `textColor`, a highlight is
    /// never reinterpreted against the reading theme: painting a background behind text is already
    /// an unambiguous, deliberate mark (there's no "ordinary black highlight" the way there's
    /// "ordinary black body text"), so it is always drawn exactly as authored.
    var highlightColor: NSColor? = nil
    /// The run's authored font size, in POINTS — a reader converts from its own source unit before
    /// constructing this (docx `w:sz`/`w:szCs` are HALF-points; ODT `fo:font-size` is already
    /// points). `nil` means the source didn't specify a size for this run — see
    /// `OfficeTextBuilder.build`'s `documentDefaultFontSize` parameter for exactly how a non-nil
    /// value becomes a rendered size (the model is Word's own: authored size scaled by the ratio
    /// between the user's chosen reading size and the document's own default body size, so a
    /// heading stays proportionally larger than body text at ANY reading size, and the reading-size
    /// setting still governs how big the whole document looks).
    var fontSize: CGFloat? = nil
    /// The run's authored font FAMILY name (docx `w:rFonts/@w:ascii`, odt `style:font-name`) —
    /// `nil` means "the theme's own body/heading/code font", exactly as before this field existed.
    /// Never applied to a `code` span: `OfficeTextBuilder`'s inline-code styling is a single,
    /// consistent monospaced look across the whole app (see `Palette`'s "one deliberate spot of
    /// color" reasoning) — letting an authored family override it would make some code spans
    /// inconsistent with others for no reason a reader would understand.
    var fontName: String? = nil
    /// The SUBSTITUTE font's `NSFontDescriptor`, resolved ONCE at read time by
    /// `FontSubstitutionResolver` and never touched again.
    ///
    /// `nil` is the overwhelmingly common case and means **"this span's declared font draws the
    /// SAMPLE character the document's census picked for that font"** — not, as this doc claimed
    /// until the survey-and-apply design replaced the per-span one, that it covers every character
    /// in the span. The difference is real and a reader should know it: a Times New Roman paragraph
    /// whose census answers with a Latin letter comes back `nil` even though a stray Ⅴ or a
    /// Wingdings bullet inside it has no glyph there, and AppKit substitutes that one character at
    /// draw time exactly as it always did. That is the deliberate trade — see
    /// `docs/font-substitution-cost-design.md` §6 — bought because asking per span cost 2,209
    /// CoreText calls on the reference document where asking per declared font costs 22.
    ///
    /// `OfficeTextBuilder` constructs a `nil` span's font completely UNCHANGED, which is the
    /// byte-identical path invariant 37 depends on. Non-`nil` carries the descriptor of the font
    /// `CTFontCreateForString` itself chose for that sample — never a family of this app's own
    /// picking — and is stamped across the span's WHOLE text: the resolver no longer splits a span
    /// at all, because splitting on coverage was measured to create the very fragmentation this
    /// field exists to remove (reference document: 17,910 spans against 9,328 without it).
    ///
    /// A DESCRIPTOR, deliberately NOT a PostScript name string (this field's first shape, changed
    /// after measuring why it silently did nothing): the theme's body/heading fonts are `.systemFont`,
    /// Apple's PRIVATE system-UI face (`NSFont.fontName == ".AppleSystemUIFont"`), and CoreText's
    /// cascade for it substitutes OTHER private, dot-prefixed faces (`".AppleSDGothicNeoI-Regular"`,
    /// measured) — `NSFont(name:size:)` cannot construct those (CoreText logs a warning and returns
    /// `nil`), so a name-based field left this swap silently inert while the installed-run count
    /// stayed exactly where it started. `NSFont(descriptor:size:)` — the SAME reconstruction idiom
    /// `OfficeTextBuilder`'s own size-scaling and `fontAdding` already use elsewhere in this file for
    /// these very private system faces — rebuilds it correctly (verified: a descriptor captured from
    /// `CTFontCreateForString`'s result reconstructs at any size and still covers the text it was
    /// resolved for). A `fontName`-override span's substitute is a normal public font and reconstructs
    /// either way; the descriptor form costs nothing there and fixes the private-face case everywhere.
    ///
    /// A span whose declared font covers SOME but not all of its characters is split by the resolver
    /// into multiple `Span`s at read time (one per maximal same-substitute run), each carrying its
    /// own value here — this field is never "some characters use it, others don't" within one span.
    var resolvedFontDescriptor: NSFontDescriptor? = nil
}

/// An underline's drawn style — docx `w:rPr/w:u/@w:val` (§17.18.99 `ST_Underline`), collapsed from
/// that enumeration's ~20 named values down to the handful AppKit can actually distinguish.
/// `DocxReader` maps `double`→`.double`; `dotted`/`dottedHeavy`→`.dotted`; every `dash*` variant
/// (`dash`/`dashLong`/`dashedHeavy`/…)→`.dashed`; every `wave*` variant (`wave`/`wavyHeavy`/
/// `wavyDouble`)→`.wavy`; anything else, including `single` itself and an absent/unrecognized
/// `@w:val`, →`.single`. Only consulted when `Span.underline` is `true` — see that field's doc.
enum UnderlineStyle: Equatable {
    case single, double, dotted, dashed, wavy
}

/// One cell of a table row. Only ANCHOR cells — the top-left corner of a merge — appear in
/// `OfficeBlock.table`'s `rows`; a grid position covered by another cell's `rowSpan`/`colSpan` is
/// simply absent, not present-and-empty. `TableBlockBuilder` derives which columns those covered
/// positions land in at render time, the same way `NSTextTableBlock` itself only needs to be told
/// about anchors. All-1 spans (this sprint's parsers emit nothing else yet) reproduce a plain
/// rectangular grid exactly — one `Cell` per visible position, nothing skipped.
struct Cell: Equatable {
    /// A cell's content is the SAME format-neutral block vocabulary as the top of a document —
    /// a paragraph, heading, list item, image, or (flattened, never a real nested grid — see
    /// `OfficeTextBuilder`'s cell renderer) another table — not a bare run of spans. That is what
    /// gives an image or a list item inside a cell somewhere to go at all: before this sprint
    /// `Cell` could only ever hold formatted text, so both `.image` and `.listItem` collection had
    /// to be skipped the moment the cell walk found them (gap-list rows 6 and 7). Rendering
    /// recurses through `OfficeTextBuilder`'s existing per-block machinery rather than growing a
    /// second, cell-only set of cases.
    var blocks: [OfficeBlock]
    var rowSpan: Int = 1
    var colSpan: Int = 1
    /// The cell's own shading (docx `w:tcPr/w:shd/@w:fill`, odt `style:background-color` on the
    /// cell's style) — `nil` means unshaded, which `TableBlockBuilder` still shades with
    /// `Palette.tableHeaderBg` for a header row exactly as it did before this field existed (an
    /// explicit `backgroundColor` on a HEADER cell overrides that theme shading; on a body cell it
    /// is the only shading there is).
    var backgroundColor: NSColor? = nil
    /// The cell's own border colour/width (docx `w:tcPr/w:tcBorders`, odt cell-style borders) —
    /// either or both may be `nil`, in which case `TableBlockBuilder`'s existing theme default
    /// (`Palette.tableBorder` at 1pt) is used for that one, exactly as before this field existed.
    /// A real per-edge border model (top/bottom/left/right independently) is out of this sprint's
    /// scope — both readers' input formats can express far more than this vocabulary carries yet,
    /// and one uniform colour/width already covers the measured "borders" need without inventing
    /// four fields no parser fills in this sprint.
    var borderColor: NSColor? = nil
    var borderWidth: CGFloat? = nil
    /// The cell's own FOUR edges when the document declared them individually (docx `w:tcBorders`).
    /// Takes precedence over `borderColor`/`borderWidth`, which stay as the uniform model every other
    /// format and markdown still use. `nil` = this cell said nothing per-edge → unchanged behaviour.
    var edgeBorders: EdgeBorders? = nil
    /// The cell's own declared column width in POINTS (docx `w:tcPr/w:tcW`, converted from twips;
    /// odt column widths) — `nil` leaves `TableBlockBuilder`'s existing auto layout (equal-ish,
    /// content-driven column sizing via the table's own `percentageValueType`) untouched, exactly
    /// as before this field existed. Set on the grid's anchor cells; a merged cell's covered
    /// positions have no `Cell` of their own to carry a width at all (see `OfficeBlock.table`'s doc
    /// comment on anchor-only rows).
    var width: CGFloat? = nil
    /// The cell's own vertical alignment (docx `w:tcPr/w:vAlign/@w:val` — `top`/`center`/`bottom`;
    /// ODT, P4, carries no equivalent yet) — `nil` means the source didn't say, which is also
    /// Word's own default (`top`), so `TableBlockBuilder` leaves `NSTextTableBlock`'s already-`.top`
    /// vertical alignment untouched rather than setting it explicitly. `CellVAlign` is a closed
    /// three-case vocabulary rather than reusing `NSTextBlock.VerticalAlignment` directly so the
    /// reader stays free of AppKit's own `.baseline` case, which no source format expresses.
    var verticalAlignment: CellVAlign? = nil
    /// The cell's own resolved cell margin/padding, in POINTS, ALREADY resolved by the reader
    /// against the table's default before reaching this struct (docx: per-cell `w:tcPr/w:tcMar` →
    /// table-wide `w:tblPr/w:tblCellMar` → `nil`; odt `fo:padding`/its per-side fallbacks) — `nil`
    /// means neither the cell nor its table said anything, and `TableBlockBuilder` keeps its own
    /// pre-existing 7pt default exactly as before this field existed. A uniform value, mirroring
    /// `borderColor`/`borderWidth`'s same simplification: this reader takes the START/left edge as
    /// representative (the same edge `ParagraphFormat.indentStart` reads for indentation).
    ///
    /// Consulted ONLY by the non-paged (window-filling) rendering model — a PAGED document uses
    /// `edgePadding` below instead, where four independent edges genuinely matter (Word's own stock
    /// `w:tblCellMar` default is `top=bottom=0, left=right=5.4pt`, and smearing that 5.4pt onto top
    /// and bottom is exactly the "표가 너무 큼" defect this field's sibling exists to fix).
    var padding: CGFloat? = nil
    /// The cell's own FOUR edges of padding/inset, independently — docx `w:tcPr/w:tcMar` (this
    /// cell's own declaration ONLY; the table's `w:tblPr/w:tblCellMar` default lives on
    /// `TableFormat.defaultPadding`, and the two are combined per edge by `TableBlockBuilder`,
    /// mirroring `EdgeBorders`' cell-then-table cascade), odt `fo:padding-{top,left,bottom,right}`
    /// (falling back to the uniform `fo:padding` shorthand per edge). `nil` per edge means THAT
    /// edge wasn't declared, carried through undiminished — a genuinely-zero edge must stay
    /// distinguishable from an edge nobody mentioned, invariant 47's discipline reused here for
    /// padding instead of borders. Consulted ONLY by the PAGED table-geometry model
    /// (`TableBlockBuilder.build`'s own per-edge resolution); the non-paged model keeps using the
    /// single `padding` value above, unaffected — this field did not exist before it, so a
    /// non-paged document renders byte-identical whether or not its reader populates this.
    var edgePadding: EdgePadding? = nil

    /// The cell's shading RESOLVED from the table's named STYLE (docx `w:tbl/w:tblPr/w:tblStyle`
    /// cascaded through that style's `w:tblStylePr` conditional blocks for this cell's grid
    /// position — P5) — `nil` means the table either has no named style, or that style has no
    /// shading applicable to this position. A LOWER-priority layer than `backgroundColor`
    /// (this cell's own direct `w:tcPr/w:shd`) and the table's own DIRECT default
    /// (`TableFormat.defaultShading`): `TableBlockBuilder` only falls to this when both of those
    /// are `nil`, and falls further still to the header theme colour when this is `nil` too.
    var styleShading: NSColor? = nil
    /// The cell's border colour/width RESOLVED from the table's named STYLE, mirroring
    /// `styleShading`'s doc — same lower-priority layer, same position-conditional resolution.
    var styleBorderColor: NSColor? = nil
    var styleBorderWidth: CGFloat? = nil

    /// Back-compat convenience for the many construction sites (both readers' plain-text cells,
    /// most existing tests) that only ever need a cell of formatted text — wraps the spans in a
    /// single `.paragraph`, which `OfficeTextBuilder` renders BYTE-IDENTICAL to the pre-sprint
    /// direct-spans path: no block-level separator is added around a lone paragraph, so a
    /// plain-text cell looks exactly as it did before `Cell` could hold anything else.
    init(spans: [Span], rowSpan: Int = 1, colSpan: Int = 1) {
        self.blocks = [.paragraph(spans: spans)]
        self.rowSpan = rowSpan
        self.colSpan = colSpan
    }

    init(blocks: [OfficeBlock], rowSpan: Int = 1, colSpan: Int = 1,
         backgroundColor: NSColor? = nil, borderColor: NSColor? = nil, borderWidth: CGFloat? = nil,
         width: CGFloat? = nil, verticalAlignment: CellVAlign? = nil, padding: CGFloat? = nil) {
        self.blocks = blocks
        self.rowSpan = rowSpan
        self.colSpan = colSpan
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.width = width
        self.verticalAlignment = verticalAlignment
        self.padding = padding
    }
}

/// A cell's vertical alignment — docx `w:tcPr/w:vAlign/@w:val`. See `Cell.verticalAlignment`'s own
/// doc comment for why this is a closed three-case vocabulary rather than AppKit's own
/// `NSTextBlock.VerticalAlignment`.
enum CellVAlign: Equatable {
    case top, center, bottom
}

/// A table's OWN default border/shading — docx `w:tbl/w:tblPr/w:tblBorders` and
/// `w:tbl/w:tblPr/w:shd/@w:fill` — that every cell in the table inherits unless it declares its
/// own (see `Cell.borderColor`/`.backgroundColor`). Mirrors `Cell`'s own uniform-border
/// simplification: `w:tblBorders` can express four edges (plus `insideH`/`insideV`) independently,
/// and this reader takes the first drawn edge, same as `Cell`'s own border reading. `nil` in any
/// field means the table didn't declare one — `TableBlockBuilder` falls through past it to its
/// existing theme default (`Palette.tableBorder`/1pt/header shading), exactly as before this
/// struct existed. A table with no `w:tblPr` at all (every markdown table; any docx table that
/// declares neither) constructs the all-`nil` default, which renders BYTE-IDENTICAL to before.
/// One DRAWN edge of a border, exactly as the document declared it: a width in points and an
/// optional colour (`nil` = the theme decides, OOXML's `w:color="auto"`). This type describes ONLY
/// an edge that is drawn — "the document turned this edge off" and "the document never mentioned
/// this edge" are two further states, and they are carried by `BorderDecl`/`EdgeBorders` below, not
/// by this struct's presence or absence.
struct BorderSide: Equatable {
    var width: CGFloat
    var color: NSColor?
}

/// What a document said about ONE edge — the three states the renderer has to tell apart:
///
/// - `.drawn(side)` — a real border, at that width/colour.
/// - `.suppressed` — the document explicitly turned this edge OFF (`w:val="none"`/`"nil"`). Nothing
///   is drawn there and nothing is inherited or substituted in its place.
/// - `nil` (the edge's `BorderDecl?` in `EdgeBorders` below) — the document never mentioned it. A
///   cell's unmentioned edge inherits the table's; if the TABLE drew a box and still never named
///   this edge, nothing is drawn, and if the table drew no box at all the edge falls back to the
///   ordinary cell > table > style > theme cascade — see `TableBlockBuilder`'s per-placement
///   resolution. The distinction from `.suppressed` is what keeps one cell's lone "off" from
///   stripping its own other three edges of that cascade.
///
/// One enum rather than a side plus a parallel "was this declared" mask: two sources of truth for
/// the same fact can disagree, and a disagreement here surfaces as a stray or missing rule on screen.
enum BorderDecl: Equatable {
    case drawn(BorderSide)
    case suppressed
}

/// A cell's four edges — and, when this describes a TABLE, the two interior directions Word states
/// separately (`w:insideH`/`w:insideV`), which apply to the edges between cells rather than around
/// the table.
///
/// Why per-edge at all: real reports declare edges INDIVIDUALLY — a measured example gives one row
/// "top = solid 1pt blue, bottom = dotted 0.5pt" and the next "top and bottom both dotted 0.5pt".
/// Collapsing that to one width per cell (what this vocabulary did before) made each row's whole box
/// take a different weight and colour, which is exactly the ragged look a reader notices. It also
/// perturbed the content width, since that subtracts the border twice.
struct EdgeBorders: Equatable {
    var top: BorderDecl?
    var left: BorderDecl?
    var bottom: BorderDecl?
    var right: BorderDecl?
    /// Table-level only: the horizontal/vertical edges BETWEEN cells.
    var insideH: BorderDecl?
    var insideV: BorderDecl?

    /// True only when the document said NOTHING about any of the six edges. A set of edges that are
    /// all `.suppressed` is NOT empty — "every border is off" is a declaration, and a reader that
    /// erased it here would hand the renderer the same input as silence, which is what makes the
    /// renderer fall back to its own default rule (exactly the border the document turned off).
    var isEmpty: Bool {
        top == nil && left == nil && bottom == nil && right == nil && insideH == nil && insideV == nil
    }

    /// True when at least one edge is a real rule. This is what separates "the document drew a box
    /// here and left some edges out of the description" from "the document only ever turned edges
    /// OFF" — only the first is missing anything worth standing in for. Suppression-only and silence
    /// both answer `false`, deliberately: neither started a box.
    var drawsAnyEdge: Bool {
        [top, left, bottom, right, insideH, insideV].contains {
            if case .drawn = $0 { return true } else { return false }
        }
    }
}

/// A cell's (or a table's own default) four edges of PADDING/INSET, in POINTS, independently —
/// `Cell.edgePadding`'s and `TableFormat.defaultPadding`'s shared shape. Only two states per edge
/// (unlike `BorderDecl`'s three): a declared value, which may legitimately be `0`, or `nil` meaning
/// the edge wasn't declared at all — there is no "explicitly turned off" equivalent for padding the
/// way `.suppressed` exists for a border, so a plain optional says everything this needs to. `nil`
/// is carried through undiminished rather than defaulted here so a genuinely-zero edge (Word's own
/// stock `w:tblCellMar` is `top=bottom=0, left=right=5.4pt`) stays distinguishable from an edge
/// nobody mentioned — the same discipline `EdgeBorders`/`BorderDecl` apply to borders, reused here
/// for padding. Consulted ONLY by the PAGED table-geometry model; see `Cell.edgePadding`'s own doc
/// for why the non-paged (window-filling) model keeps its separate, single-value `Cell.padding`.
struct EdgePadding: Equatable {
    var top: CGFloat?
    var left: CGFloat?
    var bottom: CGFloat?
    var right: CGFloat?
}

extension OfficeBlock {
    /// Returns this block with the CONTAINING paragraph's alignment applied, if it is a graphic and
    /// doesn't already carry one of its own. Shared by every reader so "a figure inherits its
    /// paragraph's alignment" is stated once instead of re-derived per format — a graphic's own
    /// explicit alignment (should a format ever supply one) always wins, and a non-graphic block is
    /// returned untouched.
    func aligningGraphic(to alignment: NSTextAlignment?) -> OfficeBlock {
        guard let alignment else { return self }
        switch self {
        case let .image(id, size, own):
            return .image(id: id, size: size, alignment: own ?? alignment)
        case let .unsupportedGraphic(label, size, own):
            return .unsupportedGraphic(label: label, size: size, alignment: own ?? alignment)
        default:
            return self
        }
    }
}

struct TableFormat: Equatable {
    var defaultBorderColor: NSColor? = nil
    var defaultBorderWidth: CGFloat? = nil
    var defaultShading: NSColor? = nil
    /// The table's own total width in POINTS as the SOURCE document laid it out (docx `w:tblGrid`
    /// twips summed, HWP's HWPUNIT column widths summed, ODF `style:column-width` summed) — `nil`
    /// when the format states only proportions (ODF `style:rel-column-width`) or nothing at all.
    ///
    /// Used for TWO things, one original and one added by the paged-geometry work. Originally: a
    /// picture inside a cell is sized against THIS width, not the page width. The NON-paged model
    /// stretches every table to fill the reading column (invariant 39), so a table that was half the
    /// page wide in the source becomes twice as wide relative to its content there — a picture scaled
    /// against the page would then sit small in a cell that grew around it. Scaling against the
    /// table's own width keeps the picture's share of its cell exactly as authored, at any window
    /// size. Each reader converts to points itself, so this field has ONE unit whatever the format
    /// stored (a mixed-unit field is how a "source width" quietly becomes twips here and points
    /// there). Second, for a PAGED document: the table itself is laid out at this width (clamped to
    /// the reading column, never wider) rather than stretched to fill it — `TableBlockBuilder`'s own
    /// `GridTextTable.maxWidth`. `nil` (every markdown table, and any office table whose grid total
    /// wasn't readable) leaves a paged table exactly as before this second use — filling the column.
    var sourceWidth: CGFloat? = nil
    /// The table's own declared edges, INCLUDING the interior ones (`w:tblBorders`' `w:insideH`/
    /// `w:insideV`). A cell inherits the outer edge when it sits on that side of the table and the
    /// interior edge when it does not — the position test lives in `TableBlockBuilder`, which is the
    /// only place that knows where a cell sits in the grid.
    var edgeBorders: EdgeBorders? = nil
    /// The table's own default cell margin/padding per edge (docx `w:tblPr/w:tblCellMar`; ODT has no
    /// table-wide equivalent — `fo:padding` lives on the cell's own STYLE only, so an ODT-sourced
    /// `TableFormat` never populates this) — the layer beneath a cell's own `Cell.edgePadding`,
    /// mirroring `edgeBorders`' cell-then-table cascade. `nil` per edge (including a wholly-`nil`
    /// `defaultPadding`) means the table said nothing about that edge either, and the PAGED
    /// resolution falls through to `TableBlockBuilder.defaultCellPadding`. Consulted ONLY by the
    /// PAGED model — see `Cell.edgePadding`'s own doc.
    var defaultPadding: EdgePadding? = nil
}

/// A paragraph's line-spacing mode — docx `w:pPr/w:spacing/@w:lineRule` (`auto`/`exact`/`atLeast`)
/// and ODF's equivalent `style:line-height-at-least`/`fo:line-height` distinction, carried as one
/// closed vocabulary rather than a raw (rule, value) pair so a later sprint's builder can switch
/// over it exhaustively. Reserved for P2 (the reader that populates it, and
/// `OfficeTextBuilder`'s translation to `NSParagraphStyle` line-height, are next sprint's job) —
/// this sprint only carries the vocabulary, nothing constructs a non-nil value yet.
enum LineHeight: Equatable {
    /// docx `w:lineRule="auto"` — a RATIO of the line's own font size, not an absolute value;
    /// `1.0` means single spacing (the same as no line-height set at all), `2.0` double, etc.
    case multiple(CGFloat)
    /// docx `w:lineRule="exact"` — an EXACT height in POINTS, overriding the line's natural size
    /// (a tall glyph or embedded object can be clipped if the exact value is smaller than it needs).
    case exact(CGFloat)
    /// docx `w:lineRule="atLeast"` — a MINIMUM height in POINTS; the line grows past this value
    /// when its own content needs more room, but never shrinks below it.
    case atLeast(CGFloat)
}

/// A tab stop's ALIGNMENT — docx `w:tabs/w:tab/@w:val` (`start`/`left` → `.left`, `center` →
/// `.center`, `end`/`right` → `.right`, `decimal` → `.decimal`; `bar`/`clear` never reach this
/// vocabulary at all — see the reader's own `w:tab` parse for why). Text before the stop is
/// positioned relative to `position` according to this case, exactly the way Word itself lays a
/// tab column out — `.left` pushes text to start AT `position` (the paragraph's pre-P2b behaviour,
/// and every markdown/office call site that never authored a real alignment), `.right` ends text
/// AT `position`, `.center` centers it ON `position`, and `.decimal` aligns the decimal point (or,
/// for non-numeric text, the whole run) ON `position`.
enum TabAlignment: Equatable {
    case left, center, right, decimal
}

/// A tab stop's LEADER (fill) character — docx `w:tabs/w:tab/@w:leader` (`dot` → `.dot`, `hyphen` →
/// `.hyphen`, `underscore` → `.underscore`; absent or any other value → `.none`). Carried through
/// the vocabulary but NOT drawn this sprint — AppKit's `NSTextTab` has no native leader-fill
/// primitive, and a faithful dotted/dashed fill between the preceding text and the tab stop is a
/// real (measured-later) rendering cost this sprint doesn't take on. A tab with a leader still
/// renders as an ordinary aligned tab, just without the fill; `OfficeTextBuilder`'s `NSTextTab`
/// construction reads `position`/`alignment` only, and comments why `leader` is inert.
enum TabLeader: Equatable {
    case none, dot, hyphen, underscore
}

/// One authored tab stop — docx `w:tabs/w:tab` (`@w:pos` in twips → `position` in points, `@w:val`
/// → `alignment`, `@w:leader` → `leader`), odt `style:tab-stop` (`style:position` → `position`;
/// this sprint migrates the VOCABULARY only for ODT — see `OdtReader`'s own doc on why it doesn't
/// yet read ODF's `style:type`/`style:leader-text` into `alignment`/`leader`, so an ODT-sourced
/// stop is always `.left`/`.none`, identical to how it rendered before this type existed).
///
/// `init(position:)` is the ergonomic, position-only constructor every pre-P2b call site (tests,
/// `OdtReader`, markdown-adjacent code that never touches this vocabulary) becomes with a single
/// added token — `alignment`/`leader` default to `.left`/`.none`, which is EXACTLY what a bare
/// `CGFloat` position meant before this type existed, so a call site that only ever cared about
/// position renders byte-identical after the one-token change.
struct TabStop: Equatable {
    var position: CGFloat
    var alignment: TabAlignment
    var leader: TabLeader

    init(position: CGFloat, alignment: TabAlignment = .left, leader: TabLeader = .none) {
        self.position = position
        self.alignment = alignment
        self.leader = leader
    }
}

/// A paragraph's block-level formatting — spacing, indentation, shading and border — read from the
/// source but not yet applied anywhere. Every field defaults to `nil`/`false`, meaning "the source
/// didn't say → `OfficeTextBuilder` keeps using its own token/theme default, exactly as before this
/// struct existed." This sprint (P1) only adds the vocabulary and a default-constructed instance to
/// every block that can carry one; NEITHER reader (`DocxReader`/`OdtReader`) constructs a non-default
/// value yet, NOR does `OfficeTextBuilder` read any of these fields into layout — both are P2's job.
/// A default `ParagraphFormat()` therefore renders BYTE-IDENTICAL to a block with no `format` at all.
struct ParagraphFormat: Equatable {
    /// Space before/after the paragraph, in POINTS (docx `w:pPr/w:spacing/@w:before`/`@w:after` are
    /// TWIPS — a reader converts twips→points before constructing this; ODT `fo:margin-top`/
    /// `fo:margin-bottom` are already points). `nil` leaves the builder's own theme spacing in place.
    var spacingBefore: CGFloat? = nil
    var spacingAfter: CGFloat? = nil
    /// The paragraph's line-spacing mode — see `LineHeight` above. `nil` leaves whatever line
    /// height the builder already computes (typically driven by font size) untouched.
    var lineHeight: LineHeight? = nil
    /// Indentation from the text block's start/end edge (docx `w:pPr/w:ind/@w:start`(or `@w:left`)/
    /// `@w:end`(or `@w:right`), converted twips→points; odt `fo:margin-left`/`fo:margin-right`), and
    /// first-line/hanging indent (`w:ind/@w:firstLine`/`@w:hanging`; odt `fo:text-indent` — a
    /// negative value there is ODF's own hanging-indent spelling, so a reader normalizes it into
    /// EITHER `firstLineIndent` OR `hangingIndent`, never both at once, mirroring docx's own
    /// mutually-exclusive pair). All four in POINTS. Named after the SOURCE spec's own attributes
    /// deliberately — mapping `start`/`end` (which flip with `rtl`) onto `NSParagraphStyle`'s
    /// physical `firstLineHeadIndent`/`headIndent` is P2's job, not this struct's.
    var indentStart: CGFloat? = nil
    var indentEnd: CGFloat? = nil
    var firstLineIndent: CGFloat? = nil
    var hangingIndent: CGFloat? = nil
    /// docx `w:pPr/w:contextualSpacing` (a toggle, read the same on/off way as `Span.rtl` — see
    /// `DocxReader.isOn`) / odt paragraph-style `style:contextual-spacing` — when `true`, suppresses
    /// `spacingBefore`/`spacingAfter` between two consecutive paragraphs of the SAME style (list
    /// items are the common case: no gap wanted between "1." and "2.", but one wanted before the
    /// list and after it). Applying that adjacency rule is P2's job; this field only carries the bit.
    var contextualSpacing: Bool = false
    /// The paragraph's own background fill (docx `w:pPr/w:shd/@w:fill`, odt paragraph-style
    /// `fo:background-color`) — `nil` means unshaded, exactly as every paragraph renders today.
    /// Mirrors `Cell.backgroundColor`'s naming/semantics one level up, for the same reason: a
    /// paragraph can carry its own fill independent of any table it might sit inside.
    var shading: NSColor? = nil
    /// The paragraph's border box (docx `w:pPr/w:pBdr`, odt paragraph-style `fo:border`) — one
    /// uniform colour/width, mirroring `Cell.borderColor`/`Cell.borderWidth`'s existing model and
    /// its documented reasoning: a real per-edge border (top/bottom/left/right independently) is
    /// out of scope for the same reason it is on `Cell` — both source formats can express far more
    /// than this vocabulary carries, and one uniform colour/width already covers the measured need.
    var borderColor: NSColor? = nil
    var borderWidth: CGFloat? = nil
}

/// The format-neutral block vocabulary between a document-format parser (docx/odt/… — later
/// sprints) and `OfficeTextBuilder`, which turns these into typography. Deliberately knows
/// nothing about Word, ODF or XML: a parser's only job is to produce this vocabulary, and
/// `OfficeTextBuilder`'s only job is to consume it, so the two are built and tested apart.
enum OfficeBlock: Equatable {
    /// Every case below that holds spans also carries `rtl`, defaulted `false` so every existing
    /// caller (hundreds, mostly tests) that never mentions it keeps meaning "not explicitly marked
    /// right-to-left" — the same reading an absent source attribute gets.
    ///
    /// This is a PARAGRAPH property, not a font one: docx's `w:pPr/w:bidi` and ODT's paragraph-style
    /// `style:writing-mode="rl-tb"` both mark the whole block, deciding where it BEGINS, which side
    /// neutral characters (digits, punctuation, brackets) resolve toward at its edges, and — when
    /// `alignment` below is `nil` — which edge the block starts flush against. TextKit's own
    /// bidirectional algorithm already reorders mixed-direction RUNS correctly within a line once
    /// it knows the paragraph's base direction; what it cannot recover on its own is THAT base
    /// direction when the source doesn't say, which is exactly what carrying this bit through from
    /// the reader restores (see `OfficeTextBuilder`, which turns it into
    /// `NSParagraphStyle.baseWritingDirection`). An EXPLICIT `alignment` always wins over this
    /// default — `.natural` alignment already resolves to the right edge once the base direction is
    /// `.rightToLeft`, so `rtl` alone is only ever a fallback for when the source has no explicit
    /// alignment of its own to say instead.
    ///
    /// `alignment` (docx `w:pPr/w:jc`, odt `fo:text-align`) is `nil` when the source didn't say —
    /// meaning "let `rtl`/the theme's own default decide", never a hardcoded `.left`. `tabStops`
    /// (docx `w:pPr/w:tabs`, odt `style:tab-stop`) are the paragraph's OWN authored stops, in
    /// POINTS, in addition to whatever tab machinery the block already has for other reasons — a
    /// `listItem`'s marker tab (see below) is never replaced by these, only added to.
    /// `format` (trailing, defaulted — see `ParagraphFormat` above) is this sprint's (P1)
    /// vocabulary-only addition: every existing caller that never mentions it keeps meaning "no
    /// paragraph formatting beyond what the builder already applies," identical to before this
    /// field existed. Populating it from a real document (the reader) and consuming it in layout
    /// (`OfficeTextBuilder`) are both P2's job — this sprint changes no rendered output.
    case heading(level: Int, spans: [Span], rtl: Bool = false, alignment: NSTextAlignment? = nil, tabStops: [TabStop] = [], format: ParagraphFormat = ParagraphFormat())
    case paragraph(spans: [Span], rtl: Bool = false, alignment: NSTextAlignment? = nil, tabStops: [TabStop] = [], format: ParagraphFormat = ParagraphFormat())
    /// `level` is a 0-based nesting depth. `ordered` selects "1. 2. 3." numbering — per level,
    /// restarting when a SHALLOWER level intervenes but continuing across a deeper nested run —
    /// vs a bullet. See `OfficeTextBuilder` for the exact restart rule.
    ///
    /// `marker` is the pre-computed display text for THIS item (e.g. `"1.2.3"`, `"iv."`, `"c)"`),
    /// or `nil`. Only a format that can actually resolve real numbering — a numId that names a
    /// concrete numbering definition, WITH an `w:lvlText` to substitute into — can honestly know
    /// this text, and only the READER (`DocxReader`) has that information: a numbering definition
    /// lives in a side part of the source file (`word/numbering.xml`), continues its counters
    /// across intervening body paragraphs, and can be overridden per-list (`w:startOverride`,
    /// `w:lvlOverride`) — none of which `OfficeTextBuilder` can see from one block in isolation.
    /// `nil` means "the source's numbering couldn't be resolved to real text" (no numbering part,
    /// an unresolvable numId, a level with no `w:lvlText`, ODF's list styles carrying no such
    /// field at all) — the field is OPTIONAL rather than mandatory precisely so that case keeps
    /// working: `OfficeTextBuilder` falls back to counting the item itself from `level`+`ordered`
    /// alone, EXACTLY as it always has (never inventing a number the source didn't give a way to
    /// compute — same principle as `image`'s reserved-but-unloaded size, applied to text instead
    /// of pixels). `ordered`/`level` still drive indentation and the bullet glyph even when
    /// `marker` is supplied — only the marker TEXT bypasses the builder's own counters.
    ///
    /// `alignment`/`tabStops` mean exactly what they mean on `.paragraph`/`.heading` above. A
    /// custom tab stop never displaces the marker's own hanging-indent tab — `OfficeTextBuilder`
    /// APPENDS these after it, so `1.\t<text>` still lands the text at the item's hanging indent
    /// first and any authored stops beyond that still work inside the item's own text.
    /// `format` means exactly what it means on `.paragraph`/`.heading` above — this sprint's
    /// vocabulary-only addition, trailing and defaulted so no existing caller changes meaning.
    case listItem(level: Int, ordered: Bool, spans: [Span], marker: String? = nil, rtl: Bool = false,
                  alignment: NSTextAlignment? = nil, tabStops: [TabStop] = [], format: ParagraphFormat = ParagraphFormat())
    /// Rows of ANCHOR cells only (`rows[row]` lists the cells that START in that row, left to
    /// right — a row's `count` is therefore the number of anchors in it, NOT the column count once
    /// any span is wider than 1; a parser reading `w:gridSpan`/`table:number-columns-spanned` must
    /// size the grid from the source's own column authority (`w:tblGrid` / repeated cells), not
    /// from `rows[row].count`). `headerRows` is the count of LEADING rows that are a genuine
    /// header, and the SOURCE format must say so explicitly — docx marks it with `w:tblHeader`, a
    /// markdown table always has exactly one. It is not a guess `OfficeTextBuilder` makes: pass 0
    /// when the format can't tell you. DEFAULT TO 0 WHEN UNKNOWN, never 1 — an un-styled table is a
    /// faithful rendering of the source; a wrongly-bolded row is a lie about it (real contracts
    /// commonly have zero header rows — guessing "row one" bolds ordinary text).
    /// `columnWidths` is the table's own grid column widths in POINTS, in left-to-right grid
    /// order (docx `w:tbl/w:tblGrid/w:gridCol/@w:w`, twips converted the same way `cellWidth`
    /// converts a per-cell `w:tcW`; odt column widths, P4) — the AUTHORITATIVE proportions Word
    /// itself fills the table's width with, which is why they win over a per-cell `Cell.width`
    /// (that field is a fallback for when no grid was readable at all, see its own doc comment).
    /// Empty means "no grid known" — every markdown table (GFM has no such concept) and any docx
    /// table whose `w:tblGrid` couldn't be read — and `TableBlockBuilder` falls back to its
    /// pre-this-field per-cell/auto layout exactly as before this field existed. When non-empty
    /// its count is expected to equal the table's own derived column count; a caller that can't
    /// establish that (a malformed grid) should pass `[]` rather than a mismatched array — a
    /// mismatch is treated as "unusable" and ignored, never partially applied.
    /// `format` (trailing, defaulted — see `TableFormat` above) is this sprint's (P3b) table-level
    /// default border/shading, inherited by any cell that doesn't declare its own. A
    /// default-constructed `TableFormat()` — every markdown table, and every existing call site that
    /// never mentions this parameter — renders BYTE-IDENTICAL to before this field existed.
    case table(rows: [[Cell]], headerRows: Int, columnWidths: [CGFloat] = [], format: TableFormat = TableFormat())
    /// `id` is an opaque key a later sprint resolves to pixels (a docx relationship id, an odt
    /// href, a markdown source path, …) — this sprint only reserves the LAYOUT area, exactly like
    /// a not-yet-loaded markdown image (invariant 1: reserved size must never depend on whether
    /// pixels are loaded).
    /// `alignment` is the CONTAINING paragraph's own horizontal alignment (docx `w:jc`, ODF
    /// `fo:text-align`, resolved through the same style cascade the paragraph itself uses). A picture
    /// in a report is centred far more often than not, and it used to render hard against the left
    /// margin no matter what the document said, because this case carried no alignment at all and the
    /// builder gave the attachment no paragraph style. `nil` = the document said nothing → the
    /// reader's default (leading), byte-identical to before this existed.
    case image(id: String, size: CGSize, alignment: NSTextAlignment? = nil)
    /// A chart or SmartArt diagram: DrawingML content this reader has no vector renderer for and
    /// for which no already-rendered `mc:Fallback` picture could be recovered either (see
    /// `DocxReader.graphicPlaceholderBlock`). Deliberately its OWN case rather than reusing
    /// `.image` with a synthetic id: an `.image` id names something `MarkdownDocument`'s async
    /// loader is expected to go find pixels FOR (an archive entry, a folder-grant path, or — when
    /// that lookup fails — the SAME generic "broken image" icon a corrupt picture reference gets).
    /// This case is different in kind, not just in degree: there was never any picture to look up
    /// in the first place, so showing the broken-image icon would misreport a decoding failure
    /// that didn't happen. `label` is the pre-formatted, reader-facing word to draw in the frame
    /// ("Chart", "Diagram" — never an XML element name); `size` is the drawing's own declared area
    /// (`wp:extent`, EMU-converted exactly like `.image`'s size), reserved up front and never
    /// revised — there is no later pixel arrival to protect invariant 1 against here, since unlike
    /// `.image` this case's rendering is synthesized once, fully, at build time.
    case unsupportedGraphic(label: String, size: CGSize, alignment: NSTextAlignment? = nil)
    /// A Word/OOXML equation (`m:oMathPara` — a display equation on its own line), translated to
    /// the LaTeX the app's existing formula engine already renders (`OmmlTranslator`). Rides the
    /// SAME web-block pipeline a markdown `$$…$$` does — `OfficeTextBuilder` reserves a placeholder
    /// tagged with the identical `MDAttr.math` attribute `MarkdownRenderer.appendWebBlock` uses —
    /// so `MarkdownDocument`'s pre-render/pre-size passes (which enumerate `MDAttr.math` wherever it
    /// appears, not by document kind) pick it up automatically; invariant 1/2's scroll stability is
    /// inherited, not re-earned. Only a genuinely STANDALONE display equation becomes this case — a
    /// bare inline `m:oMath` mixed into a sentence has no web-block equivalent this sprint (no
    /// inline placeholder mechanism exists in `WebBlock`), so `DocxReader` degrades it to plain text
    /// INSIDE the surrounding paragraph's spans instead of ever reaching here. `latex` is never
    /// empty: an equation with no translatable content at all is degraded, before construction, to
    /// a visible text block by the reader — this case never carries "nothing to render".
    case formula(latex: String)
}

/// One reviewer comment (docx `word/comments.xml` `w:comment`, odt inline `office:annotation`) —
/// content and identity ONLY; where it anchors is on the `Span`s that carry its `id` in their own
/// `commentIds` (see that field's doc), not here. `id` is the source's own key (docx `@w:id`, odt
/// `@office:name` or a reader-synthesized id when the source gave none — see each reader) — opaque,
/// only used to match back to `Span.commentIds`. `author`/`dateISO` are `nil` when the source didn't
/// say (a comment with no name-tagged reviewer, or a producer that omits the timestamp); `dateISO`
/// is carried VERBATIM as the source wrote it (docx `@w:date` is already ISO-8601; odt `dc:date` the
/// same), never reformatted — this project has no comment-panel UI yet (P6b) to decide a display
/// format for. `number` is the comment's 1-based DISPLAY order — by first appearance of its anchor
/// in the body when it has one, or (for a comment the body never anchors at all) continuing that
/// same sequence in the source's own file order — so a reader can show "Comment 1", "Comment 2", …
/// the way a native office app's review pane would, even for an unanchored comment.
struct OfficeComment: Equatable {
    var id: String
    var author: String?
    var dateISO: String?
    var text: String
    var number: Int
}

/// What `OfficeDocumentReader.read` and `DocumentTypes.readOffice` return — the block vocabulary an
/// office document's BODY becomes, plus every reviewer comment the source declares (P6a; see
/// `OfficeComment`). Bundled into one result, rather than two independent return values, so the
/// single dispatch `DocumentTypes.readOffice` (invariant 29) and both readers' `read` stay ONE
/// call, not two that could silently drift out of sync (a comments-only second call would be
/// exactly the kind of second, divergent path invariant 29 exists to prevent). `comments` defaults
/// to `[]` so every pre-P6a construction site (tests building a bare `[OfficeBlock]` result) keeps
/// compiling and means exactly what it always meant: no comments captured.
struct OfficeReadResult: Equatable {
    var blocks: [OfficeBlock]
    var comments: [OfficeComment] = []
    /// Pre-decoded embedded image bytes, keyed by the EXACT `.image(id:)` string the blocks carry
    /// (e.g. `"hwpimg:3"`). Empty for the zip-backed readers (`DocxReader`/`OdtReader`), which resolve
    /// an image's pixels lazily from the archive at reconcile time. HWP has NO archive (it is CFB
    /// binary) and the rhwp image FFI needs the LIVE parse handle, which is gone by reconcile — so
    /// `HwpReader.read` pre-decodes every embedded image here at read time and `MarkdownDocument`
    /// checks this map before the archive. Defaults to `[:]` so every existing construction site
    /// (both zip readers, all tests) keeps compiling and means exactly what it always meant: nothing
    /// pre-decoded, resolve from the archive.
    var images: [String: Data] = [:]
    /// The document's own default BODY run size in points — the other half of `OfficeTextBuilder`'s
    /// font-size model (`documentDefaultFontSize`), used to scale every absolute size to the reader's
    /// base. For HWP this is the Normal("바탕글") style's char-shape base size, decoded from the rhwp
    /// envelope's `defaultFontSizePt` (or `11` when rhwp emitted null — the document declared none).
    /// ONLY `HwpReader` populates this: the zip readers (`DocxReader`/`OdtReader`) surface the same
    /// value through `DocumentTypes.officeDefaultBodyFontSize(archive:)` instead and leave this at
    /// its `11` default, because HWP has no `ZipArchive` to run that shared path against and rhwp
    /// already carries the value in the parse it just did — no second FFI call (invariant 29's HWP
    /// branch owns this the same way docx/odt own theirs through the reader lookup).
    var defaultBodyFontSize: CGFloat = 11
    /// The document's own page BODY width in points — the printable column between the left and right
    /// page margins (paper width − left margin − right margin), honouring page orientation. It is the
    /// DENOMINATOR of the graphic scale and nothing else: `MarkdownDocument.render(into:)` divides the
    /// reading column by it and hands the ratio to `OfficeTextBuilder.build(graphicScale:)`, so a
    /// picture — authored as a fraction of THIS body width — keeps that same fraction of the column at
    /// any window size, while remaining immune to the reading-size setting.
    ///
    /// It is ALSO, now, what makes a document PAGED: non-nil pins the reading column to this width and
    /// switches ⌘+/⌘− from re-typesetting to magnifying (see `MarkdownDocument.officePageContentWidth`).
    /// `nil` = the reader could not determine it (no section/page-layout, or an out-of-range value) →
    /// graphic scale 1, the old window-filling column, and authored point sizes verbatim, so a document
    /// that declares nothing is byte-identical to before this field existed. Each reader
    /// sources it from its own format: HWP from rhwp's `PageDef` (landscape swaps width/height), docx
    /// from the body `w:sectPr`'s `w:pgSz`/`w:pgMar` (twips), odt from `styles.xml`'s
    /// `style:page-layout-properties` (`fo:page-width`/`fo:margin-*`).
    var pageContentWidth: CGFloat? = nil

    /// The page's own LEFT and RIGHT margins in points — the white space either side of
    /// `pageContentWidth`, so `left + pageContentWidth + right` is the PAPER width.
    ///
    /// Carried because a paged view has to reproduce the PAPER, not just the body. Word and Pages show
    /// the whole sheet, so at the same window width a reader that lays out only the body magnifies it
    /// by `paper ÷ body` relative to them — measured on four real A4 documents as **1.24× – 1.32×**,
    /// which is most of "우리가 폰트가 과도하게 큰데?". The margins were already being computed by every
    /// reader in order to SUBTRACT them; they were simply thrown away afterwards.
    ///
    /// Kept as two independent values rather than one symmetric inset because a document may set them
    /// differently (a bound report with a wide gutter), and the difference is visible: the text sits
    /// off-centre on the sheet exactly as the author placed it. `nil` for either = the reader did not
    /// find one, and the view falls back to its own margin, unchanged.
    var pageMarginLeft: CGFloat? = nil
    var pageMarginRight: CGFloat? = nil

    /// The section's LINE GRID pitch in points — Word's `w:sectPr/w:docGrid` with
    /// `@w:type="lines"`/`"linesAndChars"`, whose `@w:linePitch` is in twips.
    ///
    /// This is how a Korean or Japanese Word document states "every line sits on an N-point grid",
    /// and it is applied to text that declares no line spacing of its own — which, in the document
    /// this was found on, is nearly all of it. Word snaps to 18.00pt there; TextKit, given the same
    /// runs and no instruction, produces the font's natural 13.0pt. Measured on that file's tables:
    /// a row Word draws at 18.48pt came out at 13.33pt once the cell-padding error above it was
    /// fixed — five points SHORT, not over. Reading the grid is what closes it.
    ///
    /// `nil` for ODT, HWP, markdown and every docx without a `w:docGrid`, which keeps all of them
    /// byte-identical (invariant 37): the paged branch falls back to the natural line height it uses
    /// today. It is a FLOOR, never a ceiling — a paragraph that states its own larger spacing keeps
    /// it, exactly as Word does.
    var lineGridPitch: CGFloat? = nil
}
