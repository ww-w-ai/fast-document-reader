import AppKit

/// Centralized custom NSAttributedString attribute keys (C5).
/// Producers (renderer) and consumers (window controller, reader view) must all
/// reference `MDAttr.*` — never raw string literals — so the producer→consumer
/// contract stays greppable and drift-free.
enum MDAttr {
    /// Value = the raw code string of a fenced code block (used by the copy-button overlay).
    static let codeBlock = NSAttributedString.Key("mdCodeBlock")
    /// Value = the code block's language string ("" if none) — lets the no-wrap overlay
    /// re-highlight with the same rules.
    static let codeLang = NSAttributedString.Key("mdCodeLang")
    /// Value = the mermaid diagram source (the document layer swaps it for a PDF attachment).
    static let mermaid = NSAttributedString.Key("mdMermaid")
    /// Value = the TeX source of a display formula. Same deal as `mermaid`, drawn by a different
    /// engine — see `WebBlock`, which is what the document layer actually iterates.
    static let math = NSAttributedString.Key("mdMath")
    /// Value = the heading level (Int); scanned live to recompute heading jump offsets.
    static let heading = NSAttributedString.Key("mdHeading")
    /// Value = a per-block sequence Int. Every top-level block (paragraph, list, quote,
    /// code, table, rule) carries one unique id over its whole range, so a gutter click can
    /// recover the exact block range to copy — headings are clearly separated from the
    /// paragraph beneath them (they own distinct ids).
    static let blockId = NSAttributedString.Key("mdBlockId")
    /// Marks a blockquote's range so the layout manager can draw its left accent bar.
    static let blockQuote = NSAttributedString.Key("mdBlockQuote")
    /// Left inset (points, NSNumber) for a code block nested inside a blockquote, so its card
    /// (and buttons) shift right to align with the quote's prose instead of the page margin.
    static let codeInset = NSAttributedString.Key("mdCodeInset")
    /// Marks an inline-code span so the layout manager can draw a rounded chip hugging the
    /// glyphs (a plain .backgroundColor fills the whole inflated line height instead).
    static let inlineCode = NSAttributedString.Key("mdInlineCode")
    /// Marks a thematic break (`---`) so the layout manager draws a full-width hairline.
    static let rule = NSAttributedString.Key("mdRule")
    /// Value = an image source (URL/path). The document layer loads it async and swaps the
    /// placeholder attachment's image in place (like mermaid). MDAttr.imageAlt holds the alt.
    static let image = NSAttributedString.Key("mdImage")
    static let imageAlt = NSAttributedString.Key("mdImageAlt")
    /// Marks an image the sandbox won't let us read — clicking it asks for the folder (App Store
    /// build only). Value = the folder to grant.
    static let needsFolderGrant = NSAttributedString.Key("mdNeedsFolderGrant")
    /// Explicit image width (non-standard extensions): points (NSNumber) or a 0–1 fraction of
    /// the column (imageWidthPct). Parsed from HTML `<img width>`, Pandoc `{width=}`, Obsidian `|N`.
    static let imageWidth = NSAttributedString.Key("mdImageWidth")
    static let imageWidthPct = NSAttributedString.Key("mdImageWidthPct")
    /// Value = a raw file path string (absolute/~/relative) detected in prose; the link
    /// handler resolves it against the document's directory and opens it.
    static let filePath = NSAttributedString.Key("mdFilePath")
    /// Reserved for the reading-line highlight contract (kept for symmetry; the reading
    /// line itself is drawn via layout-manager temporary attributes, not stored).
    static let readingLine = NSAttributedString.Key("mdReadingLine")
    /// Value = NSValue(range:) of this block's span in the ORIGINAL markdown source (line-based,
    /// UTF-16). Lets a rendered selection map back to source markdown for block-level editing.
    static let srcRange = NSAttributedString.Key("mdSrcRange")
    /// Value = the raw fragment (without `#`) of an in-document anchor link (a TOC entry, or an
    /// office cross-reference/bookmark link). The click handler resolves it — first against
    /// `bookmarkTarget` (exact name), then by GFM heading-slug match — and scrolls there; a target
    /// that resolves to neither does nothing (see `AnchorResolver`).
    static let anchor = NSAttributedString.Key("mdAnchor")
    /// Value = `[String]`, the bookmark name(s) (docx `w:bookmarkStart/@w:name`, odt
    /// `text:bookmark(-start)/@text:name`) whose target position is the START of this span — the
    /// destination side of an in-document anchor link, recorded by the office readers exactly the
    /// way a markdown heading's own text already doubles as its jump target. `AnchorResolver`
    /// matches an anchor link's raw fragment against these names EXACTLY (bookmark names are
    /// opaque ids like `_Toc123`, never slugified).
    static let bookmarkTarget = NSAttributedString.Key("mdBookmarkTarget")
    /// Value = `NSColor`, an office paragraph's own background fill (docx `w:pPr/w:shd/@w:fill`,
    /// odt `fo:background-color`) — drawn as a full-width rect behind the paragraph's line
    /// fragments by `drawMDDecorations`, the same build-time/draw-time split every other block
    /// decoration here uses (see `CodeCardLayoutManager`'s file doc). Never set by markdown or
    /// plain-text documents — see `ParagraphFormat.shading`'s own doc.
    static let paraShading = NSAttributedString.Key("mdParaShading")
    /// Value = `NSColor`, an office paragraph's own border colour (docx `w:pPr/w:pBdr`, odt
    /// `fo:border`) — paired with `paraBorderWidth` (never one without the other; both are set or
    /// neither, mirroring `ParagraphFormat.borderColor`/`.borderWidth`'s own "both resolved
    /// together" contract). Drawn as a stroked rect the same way `paraShading` is filled.
    static let paraBorderColor = NSAttributedString.Key("mdParaBorderColor")
    /// Value = `NSNumber` (CGFloat), the paragraph border's stroke width in points — see
    /// `paraBorderColor`.
    static let paraBorderWidth = NSAttributedString.Key("mdParaBorderWidth")
    /// Value = `NSNumber` (`RectEdge.rawValue`), WHICH of the paragraph border's four edges the
    /// document declared — set alongside the two above, never alone. Word's stock Title and Heading
    /// styles rule the bottom only, and drawing all four for them put every heading in a box.
    static let paraBorderEdges = NSAttributedString.Key("mdParaBorderEdges")
    /// Value = `String` (a single character), the LEADER a tab should fill its advance with — docx
    /// `w:tabs/w:tab/@w:leader`, the `······` a table of contents runs between a title and its page
    /// number. Set on the TAB CHARACTER itself by `OfficeTextBuilder` and drawn at draw time:
    /// `NSTextTab` has no leader-fill of its own, so the alternative to drawing it ourselves is not
    /// drawing it at all, which is what this reader did until a real contents page was read.
    static let tabLeader = NSAttributedString.Key("mdTabLeader")
    /// Value = `[Int]`, the DISPLAY number(s) (`OfficeComment.number`) of the reviewer comment(s)
    /// whose range this span falls within — set by `OfficeTextBuilder` from `Span.commentIds`
    /// resolved against the document's `officeComments` (P6a captured the ids; this is P6b's
    /// number-carrying attribute). A build-time-only tag: nothing here draws anything — the
    /// comments panel's highlight + number badge (`drawCommentMarks`) reads it at DRAW time, and
    /// only while the panel is open, so setting this attribute never changes layout (invariant
    /// 1/24) and a comment-free document (or one whose panel is closed) never differs on screen.
    static let commentMark = NSAttributedString.Key("mdCommentMark")
    /// Value = `FillMarginTabInfo` (`OfficeTextBuilder`) — set on an office paragraph/heading
    /// whose authored tab stops end in a right- or decimal-aligned "fill to margin" tab (the
    /// dominant real case: a Word Table of Contents entry's page number, authored against the
    /// SOURCE document's own page right margin). That margin has nothing to do with this reader's
    /// window-width reading column, so `DocumentWindowController.updateTextInset` re-anchors the
    /// tab to the CURRENT column on every reflow using this attribute — the same "fill the
    /// window" treatment the office tables already get, extended to a plain right-aligned tab
    /// stop, which otherwise has no idea the column even changed. A paragraph whose rightmost tab
    /// is left/center-aligned (an ordinary tab) never gets this attribute, and neither does any
    /// markdown/plain-text block (they have no tab-stop vocabulary at all).
    static let fillMarginTab = NSAttributedString.Key("mdFillMarginTab")

    /// An office graphic's AUTHORED size (an `OfficeGraphicInfo`), attached to the attachment
    /// character by `OfficeTextBuilder`. `DocumentWindowController.resizeOfficeGraphics` re-derives
    /// the picture's on-screen size from it on every reflow — the graphic keeps the share of the
    /// reading column it held of the source page, at ANY window width, instead of staying frozen at
    /// the width the document happened to be built at. Office only; markdown images size themselves
    /// from their own pixels (`fittedSize`) and never carry this.
    static let officeGraphic = NSAttributedString.Key("mdOfficeGraphic")

    /// Value = `Int`, the index into `MarkdownDocument.officeBlocks` of a table whose GRID was left
    /// out of this build so the document could paint, set on the one-paragraph stand-in that holds
    /// its place. `MarkdownDocument.spliceDeferredTables` finds each stand-in by THIS attribute —
    /// never by matching the stand-in's text, which would break the moment the glyph changed — and
    /// replaces it with the real table. Present only while a splice is outstanding: a document with
    /// no qualifying table (99.3% of them) never carries it, and after the pass finishes none
    /// remains. See `docs/giant-table-deferral-design.md`.
    static let deferredTable = NSAttributedString.Key("mdDeferredTable")

    /// Value = `PageNumberField` (`.page`/`.numPages`) — the attribute-string mirror of
    /// `Span.pageNumberField`, stamped by `OfficeTextBuilder.spansAttributedString` on a running
    /// header/footer's PAGE/NUMPAGES run so `PageBandPainter.substitutingPageFields` can find and
    /// replace it with the LIVE per-page value in a freshly-built header/footer string (header-
    /// footer-design.md §5, build step 5) — never touching the shared document storage or the span
    /// model underneath it, the same "compute a display transform on a copy" discipline `caps`
    /// already uses. A span with no page-number field never carries this; ordinary body text (the
    /// document's main storage) never carries it either, because only a header/footer entry's
    /// blocks are ever built through the live-substitution path.
    static let pageNumberField = NSAttributedString.Key("mdPageNumberField")

    /// WHICH SECTION of the source document this run belongs to (an `Int`), set on the first block
    /// of each section and nowhere else — the marker that lets a PAGE be placed in a section.
    ///
    /// The reader lays every section into ONE column (invariant 57), so nothing else in the built
    /// text says where one section ends and the next begins. A 바탕쪽 is declared per section
    /// (invariant 78), so without this the reader would have to pick one template for the whole
    /// document, which puts one chapter's running title on every other chapter's pages.
    static let sectionIndex = NSAttributedString.Key("mdSectionIndex")

    /// The anchored objects (an `[Int]` of indices into `OfficeReadResult.anchoredObjects`) that
    /// belong to THIS block — the marker that says which page a paper-pinned object is drawn on.
    /// Set on the block the document anchored them at, and nowhere else.
    static let anchoredObjects = NSAttributedString.Key("mdAnchoredObjects")
}
