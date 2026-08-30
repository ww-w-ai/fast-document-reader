//! swift: Render/MDAttr.swift
//! swift-range: 1-6

// swift: Render/MDAttr.swift:3-6
// Centralized custom NSAttributedString attribute keys (C5).
// Producers (renderer) and consumers (window controller, reader view) must all
// reference `MDAttr.*` — never raw string literals — so the producer→consumer
// contract stays greppable and drift-free.
pub struct MDAttr;

impl MDAttr {
    // swift: Render/MDAttr.swift:8-9
    /// Value = the raw code string of a fenced code block (used by the copy-button overlay).
    pub fn code_block() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdCodeBlock".to_string())
    }

    // swift: Render/MDAttr.swift:10-12
    /// Value = the code block's language string ("" if none) — lets the no-wrap overlay
    /// re-highlight with the same rules.
    pub fn code_lang() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdCodeLang".to_string())
    }

    // swift: Render/MDAttr.swift:13-14
    /// Value = the mermaid diagram source (the document layer swaps it for a PDF attachment).
    pub fn mermaid() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdMermaid".to_string())
    }

    // swift: Render/MDAttr.swift:15-17
    /// Value = the TeX source of a display formula. Same deal as `mermaid`, drawn by a different
    /// engine — see `WebBlock`, which is what the document layer actually iterates.
    pub fn math() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdMath".to_string())
    }

    // swift: Render/MDAttr.swift:18-19
    /// Value = the heading level (Int); scanned live to recompute heading jump offsets.
    pub fn heading() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdHeading".to_string())
    }

    // swift: Render/MDAttr.swift:20-24
    /// Value = a per-block sequence Int. Every top-level block (paragraph, list, quote,
    /// code, table, rule) carries one unique id over its whole range, so a gutter click can
    /// recover the exact block range to copy — headings are clearly separated from the
    /// paragraph beneath them (they own distinct ids).
    pub fn block_id() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdBlockId".to_string())
    }

    // swift: Render/MDAttr.swift:25-26
    /// Marks a blockquote's range so the layout manager can draw its left accent bar.
    pub fn block_quote() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdBlockQuote".to_string())
    }

    // swift: Render/MDAttr.swift:27-29
    /// Left inset (points, NSNumber) for a code block nested inside a blockquote, so its card
    /// (and buttons) shift right to align with the quote's prose instead of the page margin.
    pub fn code_inset() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdCodeInset".to_string())
    }

    // swift: Render/MDAttr.swift:30-32
    /// Marks an inline-code span so the layout manager can draw a rounded chip hugging the
    /// glyphs (a plain .backgroundColor fills the whole inflated line height instead).
    pub fn inline_code() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdInlineCode".to_string())
    }

    // swift: Render/MDAttr.swift:33-34
    /// Marks a thematic break (`---`) so the layout manager draws a full-width hairline.
    pub fn rule() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdRule".to_string())
    }

    // swift: Render/MDAttr.swift:35-37
    /// Value = an image source (URL/path). The document layer loads it async and swaps the
    /// placeholder attachment's image in place (like mermaid). MDAttr.image_alt holds the alt.
    pub fn image() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdImage".to_string())
    }

    // swift: Render/MDAttr.swift:38
    pub fn image_alt() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdImageAlt".to_string())
    }

    // swift: Render/MDAttr.swift:39-41
    /// Marks an image the sandbox won't let us read — clicking it asks for the folder (App Store
    /// build only). Value = the folder to grant.
    pub fn needs_folder_grant() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdNeedsFolderGrant".to_string())
    }

    // swift: Render/MDAttr.swift:42-44
    /// Explicit image width (non-standard extensions): points (NSNumber) or a 0–1 fraction of
    /// the column (image_width_pct). Parsed from HTML `<img width>`, Pandoc `{width=}`, Obsidian `|N`.
    pub fn image_width() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdImageWidth".to_string())
    }

    // swift: Render/MDAttr.swift:45
    pub fn image_width_pct() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdImageWidthPct".to_string())
    }

    // swift: Render/MDAttr.swift:46-48
    /// Value = a raw file path string (absolute/~/relative) detected in prose; the link
    /// handler resolves it against the document's directory and opens it.
    pub fn file_path() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdFilePath".to_string())
    }

    // swift: Render/MDAttr.swift:49-51
    /// Reserved for the reading-line highlight contract (kept for symmetry; the reading
    /// line itself is drawn via layout-manager temporary attributes, not stored).
    pub fn reading_line() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdReadingLine".to_string())
    }

    // swift: Render/MDAttr.swift:52-54
    /// Value = NSValue(range:) of this block's span in the ORIGINAL markdown source (line-based,
    /// UTF-16). Lets a rendered selection map back to source markdown for block-level editing.
    pub fn src_range() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdSrcRange".to_string())
    }

    // swift: Render/MDAttr.swift:55-59
    /// Value = the raw fragment (without `#`) of an in-document anchor link (a TOC entry, or an
    /// office cross-reference/bookmark link). The click handler resolves it — first against
    /// `bookmark_target` (exact name), then by GFM heading-slug match — and scrolls there; a target
    /// that resolves to neither does nothing (see `AnchorResolver`).
    pub fn anchor() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdAnchor".to_string())
    }

    // swift: Render/MDAttr.swift:60-66
    /// Value = `[String]`, the bookmark name(s) (docx `w:bookmarkStart/@w:name`, odt
    /// `text:bookmark(-start)/@text:name`) whose target position is the START of this span — the
    /// destination side of an in-document anchor link, recorded by the office readers exactly the
    /// way a markdown heading's own text already doubles as its jump target. `AnchorResolver`
    /// matches an anchor link's raw fragment against these names EXACTLY (bookmark names are
    /// opaque ids like `_Toc123`, never slugified).
    pub fn bookmark_target() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdBookmarkTarget".to_string())
    }

    // swift: Render/MDAttr.swift:67-72
    /// Value = `NSColor`, an office paragraph's own background fill (docx `w:pPr/w:shd/@w:fill`,
    /// odt `fo:background-color`) — drawn as a full-width rect behind the paragraph's line
    /// fragments by `drawMDDecorations`, the same build-time/draw-time split every other block
    /// decoration here uses (see `CodeCardLayoutManager`'s file doc). Never set by markdown or
    /// plain-text documents — see `ParagraphFormat.shading`'s own doc.
    pub fn para_shading() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdParaShading".to_string())
    }

    // swift: Render/MDAttr.swift:73-76
    /// Value = `NSColor`, an office paragraph's own border colour (docx `w:pPr/w:pBdr`, odt
    /// `fo:border`) — paired with `para_border_width` (never one without the other; both are set or
    /// neither, mirroring `ParagraphFormat.borderColor`/`.borderWidth`'s own "both resolved
    /// together" contract). Drawn as a stroked rect the same way `para_shading` is filled.
    pub fn para_border_color() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdParaBorderColor".to_string())
    }

    // swift: Render/MDAttr.swift:78-80
    /// Value = `NSNumber` (CGFloat), the paragraph border's stroke width in points — see
    /// `para_border_color`.
    pub fn para_border_width() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdParaBorderWidth".to_string())
    }

    // swift: Render/MDAttr.swift:81-84
    /// Value = `NSNumber` (`RectEdge.rawValue`), WHICH of the paragraph border's four edges the
    /// document declared — set alongside the two above, never alone. Word's stock Title and Heading
    /// styles rule the bottom only, and drawing all four for them put every heading in a box.
    pub fn para_border_edges() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdParaBorderEdges".to_string())
    }

    // swift: Render/MDAttr.swift:85-90
    /// Value = `String` (a single character), the LEADER a tab should fill its advance with — docx
    /// `w:tabs/w:tab/@w:leader`, the `······` a table of contents runs between a title and its page
    /// number. Set on the TAB CHARACTER itself by `OfficeTextBuilder` and drawn at draw time:
    /// `NSTextTab` has no leader-fill of its own, so the alternative to drawing it ourselves is not
    /// drawing it at all, which is what this reader did until a real contents page was read.
    pub fn tab_leader() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdTabLeader".to_string())
    }

    // swift: Render/MDAttr.swift:91-98
    /// Value = `[Int]`, the DISPLAY number(s) (`OfficeComment.number`) of the reviewer comment(s)
    /// whose range this span falls within — set by `OfficeTextBuilder` from `Span.commentIds`
    /// resolved against the document's `officeComments` (P6a captured the ids; this is P6b's
    /// number-carrying attribute). A build-time-only tag: nothing here draws anything — the
    /// comments panel's highlight + number badge (`drawCommentMarks`) reads it at DRAW time, and
    /// only while the panel is open, so setting this attribute never changes layout (invariant
    /// 1/24) and a comment-free document (or one whose panel is closed) never differs on screen.
    pub fn comment_mark() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdCommentMark".to_string())
    }

    // swift: Render/MDAttr.swift:99-109
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
    pub fn fill_margin_tab() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdFillMarginTab".to_string())
    }

    // swift: Render/MDAttr.swift:111-117
    /// An office graphic's AUTHORED size (an `OfficeGraphicInfo`), attached to the attachment
    /// character by `OfficeTextBuilder`. `DocumentWindowController.resizeOfficeGraphics` re-derives
    /// the picture's on-screen size from it on every reflow — the graphic keeps the share of the
    /// reading column it held of the source page, at ANY window width, instead of staying frozen at
    /// the width the document happened to be built at. Office only; markdown images size themselves
    /// from their own pixels (`fittedSize`) and never carry this.
    pub fn office_graphic() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdOfficeGraphic".to_string())
    }

    // swift: Render/MDAttr.swift:119-126
    /// Value = `Int`, the index into `MarkdownDocument.officeBlocks` of a table whose GRID was left
    /// out of this build so the document could paint, set on the one-paragraph stand-in that holds
    /// its place. `MarkdownDocument.spliceDeferredTables` finds each stand-in by THIS attribute —
    /// never by matching the stand-in's text, which would break the moment the glyph changed — and
    /// replaces it with the real table. Present only while a splice is outstanding: a document with
    /// no qualifying table (99.3% of them) never carries it, and after the pass finishes none
    /// remains. See `docs/giant-table-deferral-design.md`.
    pub fn deferred_table() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdDeferredTable".to_string())
    }

    // swift: Render/MDAttr.swift:128-136
    /// Value = `true`, stamped over a table the DOCUMENT forbids splitting at a page boundary
    /// (HWP `Table.page_break == 나누지 않음`; docx's `w:cantSplit` on every row is the same claim).
    /// Absent means the document did not forbid it, which is every markdown table and most office
    /// ones — so the reader's own policy (invariant 92: break by default) still governs them.
    ///
    /// It has to be an ATTRIBUTE rather than a lookup back into the block model, because the
    /// decision is taken from a COMPLETED layout (`settlePagedTables`), where the only handle on a
    /// table is where its characters are.
    pub fn table_keeps_whole() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdTableKeepsWhole".to_string())
    }

    // swift: Render/MDAttr.swift:138-147
    /// Value = `PageNumberField` (`.page`/`.numPages`) — the attribute-string mirror of
    /// `Span.page_number_field`, stamped by `OfficeTextBuilder.spansAttributedString` on a running
    /// header/footer's PAGE/NUMPAGES run so `PageBandPainter.substitutingPageFields` can find and
    /// replace it with the LIVE per-page value in a freshly-built header/footer string (header-
    /// footer-design.md §5, build step 5) — never touching the shared document storage or the span
    /// model underneath it, the same "compute a display transform on a copy" discipline `caps`
    /// already uses. A span with no page-number field never carries this; ordinary body text (the
    /// document's main storage) never carries it either, because only a header/footer entry's
    /// blocks are ever built through the live-substitution path.
    pub fn page_number_field() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdPageNumberField".to_string())
    }

    // swift: Render/MDAttr.swift:149-156
    /// WHICH SECTION of the source document this run belongs to (an `Int`), set on the first block
    /// of each section and nowhere else — the marker that lets a PAGE be placed in a section.
    ///
    /// The reader lays every section into ONE column (invariant 57), so nothing else in the built
    /// text says where one section ends and the next begins. A 바탕쪽 is declared per section
    /// (invariant 78), so without this the reader would have to pick one template for the whole
    /// document, which puts one chapter's running title on every other chapter's pages.
    pub fn section_index() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdSectionIndex".to_string())
    }

    // swift: Render/MDAttr.swift:158-170
    /// WHICH FOOTNOTE this run is the reference marker for (an `Int`, the note's own number) — set
    /// on the superscript marker in the BODY, never on the note's text.
    ///
    /// A marker is a superscript number and nothing about its glyphs distinguishes it from an
    /// exponent, so without this the reader cannot tell which run cites a note, or which note it
    /// cites. Carried as the note's number rather than an index because that is the only identifier
    /// both sides already share (`OfficeFootnote.number`), and because a document may cite the same
    /// number twice.
    ///
    /// Only FOOTNOTE markers carry it. An endnote's marker deliberately does not: its note stays in
    /// the body flow where it already belongs (`OfficeReadResult.footnotes`), so nothing needs to
    /// find it.
    pub fn footnote_ref() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdFootnoteRef".to_string())
    }

    // swift: Render/MDAttr.swift:171-175
    /// Where the document changes its column layout — an `OfficeColumnLayout`, on the run the
    /// declaration sat at. Read from the LAID-OUT text rather than the block model for the same
    /// reason `footnote_ref` is: the decision it feeds is taken from a finished layout, where the
    /// only handle on a position is a character index.
    pub fn column_layout() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdColumnLayout".to_string())
    }

    // swift: Render/MDAttr.swift:177-182
    /// Set (value `true`) on a block the DOCUMENT vetoes a page number for (HWP's `Control::
    /// PageHide`'s `hidePageNum`) — see `OfficeReadResult.hidePageNumberBlocks`. A page resolved
    /// from where this marker sits in the laid-out text (`DocumentWindowController`'s section-page
    /// arithmetic) is told to substitute its master page's `PAGE` field with an empty string rather
    /// than skip the whole master page — HWP suppresses the NUMBER, not the 바탕쪽's title/artwork.
    pub fn hides_page_number() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdHidesPageNumber".to_string())
    }

    // swift: Render/MDAttr.swift:183-186
    /// The page number this character's page starts counting from — HWP's NewNumber. Carried as an
    /// `Int` (`NSNumber` on the wire, which is `Hashable`, invariant 67). Present only on the block
    /// that declared the restart; every later page counts up from it.
    pub fn page_number_restart() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdPageNumberRestart".to_string())
    }

    // swift: Render/MDAttr.swift:188-191
    /// The anchored objects (an `[Int]` of indices into `OfficeReadResult.anchored_objects`) that
    /// belong to THIS block — the marker that says which page a paper-pinned object is drawn on.
    /// Set on the block the document anchored them at, and nowhere else.
    pub fn anchored_objects() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdAnchoredObjects".to_string())
    }

    // swift: Render/MDAttr.swift:193-199
    /// Set on a block the DOCUMENT breaks a page at (HWP's 쪽 나누기 / 구역 나누기), so layout starts
    /// it on a fresh page instead of letting it run on from the previous one. The value is `true`;
    /// the attribute's PRESENCE is the instruction. Carried as a marker rather than as a shift
    /// applied at build time for the same reason the running band is (invariant 58): the text
    /// storage must stay the document's own text, and a reflow re-asks layout rather than replaying
    /// arithmetic someone baked in.
    pub fn starts_page() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdStartsPage".to_string())
    }

    // swift: Render/MDAttr.swift:201-204
    /// Set on a block the document keeps with the one AFTER it (HWP 다음 문단과 함께). Layout moves
    /// such a block to the next page rather than let a page boundary fall between it and what
    /// follows — which is what stops a heading being stranded at the foot of a page.
    pub fn keep_with_next() -> swiftshim::NSAttributedStringKey {
        swiftshim::NSAttributedStringKey::Custom("mdKeepWithNext".to_string())
    }
}

// Boundary lines (closing braces, blank separators, field/case lines already
// covered in substance by the ranges above) that the coverage script's per-item
// markers did not individually re-state:
// swift: Render/MDAttr.swift:7-7
// swift: Render/MDAttr.swift:38-38
// swift: Render/MDAttr.swift:45-45
// swift: Render/MDAttr.swift:77-77
// swift: Render/MDAttr.swift:80-80
// swift: Render/MDAttr.swift:110-110
// swift: Render/MDAttr.swift:118-118
// swift: Render/MDAttr.swift:127-127
// swift: Render/MDAttr.swift:137-137
// swift: Render/MDAttr.swift:148-148
// swift: Render/MDAttr.swift:157-157
// swift: Render/MDAttr.swift:176-176
// swift: Render/MDAttr.swift:187-187
// swift: Render/MDAttr.swift:192-192
// swift: Render/MDAttr.swift:200-200
// swift: Render/MDAttr.swift:205-205
