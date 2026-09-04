//! swift: Render/Office/OdtReader.swift

use swiftshim::{CGFloat, CGSize, NSColor, NSTextAlignment, Ref};
use crate::render::office::office_block::{
    OfficeBlock, Span, Cell, EdgeBorders, BorderSide, BorderDecl, BorderLineStyle, EdgePadding,
    CellVAlign, TabStop, TabAlignment, TabLeader, ParagraphFormat, LineHeight, UnderlineStyle,
    OfficeReadResult, OfficeHeaderFooter, HeaderFooterApplicability, OfficeComment, PageNumberField,
    TableFormat,
};
use crate::render::office::zip_archive::ZipArchive;
use crate::render::office::odf_script_type::OdfScriptType;
// swift: Render/Office/OdtReader.swift — cross-file dependency, out of the phase-A manifest
// (rust/PORT-MANIFEST.txt has no entry for Script/ScriptRunSplitter.swift). Referenced by name;
// see `appendMerging`'s `todo!()` below and this file's `notes` in the worker's return.
use crate::render::office::script::script_run_splitter::{ScriptRunSplitter, Piece};

/// `.odt` bytes → `[OfficeBlock]`. An ODT is a ZIP holding `content.xml` (the body, required) and
/// optionally `styles.xml` — this reader consults BOTH for `text:list-style` (bullet vs number per
/// level) and text-formatting styles, because LibreOffice sometimes defines a list style used by the
/// body in `styles.xml` rather than `content.xml`'s own `office:automatic-styles`. Sibling of
/// `DocxReader`, deliberately shaped the same way (same XML-tree approach, same error type, same
/// span-reassembly, same unresolvable-image convention) so two office readers don't diverge for no
/// reason — but the underlying markup is different enough that nothing is shared code, only shape.
// swift: OdtReader
// Swift `enum OdtReader: OfficeDocumentReader { ... }` is a pure namespace (no cases) — mirrored as
// an uninhabited Rust enum used only as an `impl` target. `OfficeDocumentReader` is
// `App/DocumentTypes.swift:10`, host-layer and out of the phase-A engine-layer manifest; the
// conformance itself is therefore not transliterated, only the members it requires.
pub enum OdtReader {}

// swift: OdtReader.ReadError
/// Swift: `OdtReader.ReadError` (nested `enum ReadError: Swift.Error, Equatable, LocalizedError`).
/// Named `OdtReadError` at module scope — Rust has no nested-type-inside-enum-namespace shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OdtReadError {
    /// `content.xml` is missing from the archive. Returning an empty document here would look
    /// like a genuinely blank file — the worst failure mode for a reader — so this throws.
    MissingContentXML,
    /// A required XML part did not parse (malformed XML). Named by its archive path so the
    /// error is actionable.
    MalformedXML(String),
}

impl OdtReadError {
    pub fn error_description(&self) -> Option<String> {
        match self {
            OdtReadError::MissingContentXML => {
                Some("This .odt file has no content.xml — it may be corrupt.".to_string())
            }
            OdtReadError::MalformedXML(part) => {
                Some(format!("\"{}\" could not be parsed as XML.", part))
            }
        }
    }
}

impl OdtReader {
    /// This reader emits `.image` blocks — PARSING only. Resolving an emitted id to actual pixels
    /// (reading the archive entry, drawing a placeholder for an unresolvable one) is a later
    /// sprint's job, exactly as in `DocxReader`.
    // swift: OdtReader.read
    pub fn read(archive: &ZipArchive) -> Result<OfficeReadResult, OdtReadError> {
        if !archive.contains("content.xml") {
            return Err(OdtReadError::MissingContentXML);
        }
        let content_root = match archive.data_for("content.xml").ok().and_then(|d| Self::build_tree(&d).ok()) {
            Some(root) => root,
            None => return Err(OdtReadError::MalformedXML("content.xml".to_string())),
        };
        // `styles.xml` is optional and, when present, is a SECOND place list/text styles can live
        // — a document-level style declared once and reused is exactly what a writer would do, so
        // both parts are searched and merged (content.xml wins on a name collision, since it is
        // the part the body actually renders under).
        let mut style_roots: Vec<Ref<XMLNode>> = vec![content_root.clone()];
        if archive.contains("styles.xml") {
            if let Ok(data) = archive.data_for("styles.xml") {
                if let Ok(styles_root) = Self::build_tree(&data) {
                    style_roots.push(styles_root);
                }
            }
        }
        let mut list_styles: std::collections::HashMap<String, std::collections::HashMap<i32, bool>> =
            std::collections::HashMap::new();
        let mut font_faces: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        let mut text_style_decls: std::collections::HashMap<String, TextStyleDecl> = std::collections::HashMap::new();
        let mut paragraph_style_decls: std::collections::HashMap<String, ParagraphStyleDecl> = std::collections::HashMap::new();
        let mut table_cell_style_decls: std::collections::HashMap<String, TableCellStyleDecl> = std::collections::HashMap::new();
        let mut table_column_style_decls: std::collections::HashMap<String, TableColumnStyleDecl> = std::collections::HashMap::new();
        for root in style_roots.iter().rev() {
            // `merge(...) { existing, _ in existing }` — existing key wins, i.e. earlier-processed
            // (content.xml, since we walk `.reversed()`) beats later (styles.xml). `HashMap::entry`
            // with `.or_insert` reproduces the same "first writer wins" semantics.
            for (k, v) in Self::parse_list_styles(root) {
                list_styles.entry(k).or_insert(v);
            }
            for (k, v) in Self::parse_font_face_decls(root) {
                font_faces.entry(k).or_insert(v);
            }
            for (k, v) in Self::parse_text_style_decls(root, &font_faces) {
                text_style_decls.entry(k).or_insert(v);
            }
            for (k, v) in Self::parse_paragraph_style_decls(root) {
                paragraph_style_decls.entry(k).or_insert(v);
            }
            for (k, v) in Self::parse_table_cell_style_decls(root) {
                table_cell_style_decls.entry(k).or_insert(v);
            }
            for (k, v) in Self::parse_table_column_style_decls(root) {
                table_column_style_decls.entry(k).or_insert(v);
            }
        }
        // Resolve every style NAME once, up front, into its final (inheritance-flattened) value —
        // every call site below keeps reading a plain `[String: TextStyle]`/`[String:
        // ResolvedParagraphStyle]`/`[String: TableCellStyle]` exactly as before this sprint, so
        // `style:parent-style-name` chains (see `resolveTextStyle`/`resolveParagraphStyle`/
        // `resolveTableCellStyle`, each cycle-guarded) are invisible to every consumer past this
        // point — resolving once here, rather than at every lookup, is also what keeps a malformed
        // document's cycle guard from doing repeated work for the same name.
        let text_styles: std::collections::HashMap<String, TextStyle> = text_style_decls
            .keys()
            .map(|k| (k.clone(), Self::resolve_text_style(k, &text_style_decls)))
            .collect();
        let paragraph_styles: std::collections::HashMap<String, ResolvedParagraphStyle> = paragraph_style_decls
            .keys()
            .map(|k| (k.clone(), Self::resolve_paragraph_style(k, &paragraph_style_decls)))
            .collect();
        let table_cell_styles: std::collections::HashMap<String, TableCellStyle> = table_cell_style_decls
            .keys()
            .map(|k| (k.clone(), Self::resolve_table_cell_style(k, &table_cell_style_decls)))
            .collect();
        let table_column_styles: std::collections::HashMap<String, TableColumnStyle> = table_column_style_decls
            .keys()
            .map(|k| (k.clone(), Self::resolve_table_column_style(k, &table_column_style_decls)))
            .collect();
        let styles = ParsedStyles {
            list_styles,
            text_styles,
            paragraph_styles,
            table_cell_styles,
            table_column_styles,
        };
        let body = match XMLNode::first_descendant(&content_root, "office:text") {
            Some(b) => b,
            None => return Ok(OfficeReadResult { blocks: vec![], ..Default::default() }),
        };
        // ODF footnotes AND endnotes are the SAME element (`text:note`, told apart only by
        // `text:note-class`), sitting INLINE at the citation point with the note's own marker
        // (`text:note-citation`) and full body (`text:note-body`) as children of that one element —
        // unlike docx, which keeps the body in a wholly separate part. `NoteCollector` is filled in
        // by `collectSpans`'s `text:note` case DURING the one real body walk (not a separate
        // up-front pass): when that walk meets a `text:note`, it emits the marker inline and records
        // `(marker, body)` on the collector rather than recursing into the body — that recursion
        // skip is the detachment that keeps the note's text from being spliced into the citing
        // sentence. Once the body walk finishes, the collector holds every note in citation order,
        // ready to be rendered — once, here, at the document's end.
        let notes = NoteCollector::new();
        let body_blocks = Self::parse_body(&body, &styles, archive, &notes, 0);
        let note_blocks = Self::build_note_blocks(&notes.entries.borrow(), &styles, archive);
        let master_page = Self::typeset_master_page(&body, &style_roots);
        let page = Self::page_geometry(&style_roots, master_page.as_ref());
        // header-footer-design.md step 2/4 — read ONLY, nothing renders these yet.
        let header_footer = Self::master_page_header_footers(master_page.as_ref(), &styles, archive);
        let mut comments = notes.comments.borrow().clone();
        comments.sort_by_key(|c| c.number);
        let mut blocks = body_blocks;
        blocks.extend(note_blocks);
        Ok(OfficeReadResult {
            blocks,
            comments,
            // The document's own default body run size, answered by the SAME parse that produced
            // these blocks. It used to be reachable only through a separate entry point that opened
            // the archive again for this one number -- so a host asking for both paid two full
            // parses, and its scalar return had nowhere to say "could not read", which made the
            // caller's fallback and a document that genuinely declares 11 indistinguishable. HWP has
            // always answered it off its own parse (`OfficeReadResult.default_body_font_size`); this
            // is the zip half catching up.
            default_body_font_size: Self::document_default_body_font_size(archive),
            page_content_width: page.as_ref().map(|p| p.content),
            page_margin_left: page.as_ref().map(|p| p.left),
            page_margin_right: page.as_ref().map(|p| p.right),
            page_content_height: page.as_ref().and_then(|p| p.height),
            page_margin_top: page.as_ref().and_then(|p| p.top),
            page_margin_bottom: page.as_ref().and_then(|p| p.bottom),
            headers: header_footer.0,
            footers: header_footer.1,
            ..Default::default()
        })
    }

    /// The master page this document is TYPESET on — the one the most body paragraphs sit under,
    /// not simply the first `style:master-page` the file declares.
    ///
    /// ODF has no `w:sectPr`/HWP section to count: a page style changes when a paragraph applies a
    /// style carrying `style:master-page-name`, and every following paragraph stays on that master
    /// page until another one switches it. Walking the body and counting paragraphs per master page
    /// is therefore the exact ODF equivalent of `DocxReader.typesetSectionProperties`' "most content
    /// wins", and it exists for the same measured reason (invariant 73/79): taking the wrong one
    /// typesets the whole document on a title page's or a landscape appendix's paper.
    ///
    /// The FIRST declared master page is the default — a paragraph that names none inherits whatever
    /// is in effect, and nothing is in effect before the first switch. An EMPTY
    /// `style:master-page-name` is a page break that keeps the current page style, so it is ignored
    /// here rather than treated as a switch. Ties go to the earlier-declared master page, matching
    /// the docx rule's tie-break.
    ///
    /// A single-master-page document — the overwhelming majority — has exactly one candidate, so
    /// this returns precisely what `children.first` returned before it existed.
    // swift: OdtReader.typesetMasterPage
    fn typeset_master_page(body: &Ref<XMLNode>, style_roots: &[Ref<XMLNode>]) -> Option<Ref<XMLNode>> {
        let master_styles = style_roots.iter().find_map(|r| XMLNode::child(r, "office:master-styles"))?;
        let master_pages: Vec<Ref<XMLNode>> = XMLNode::children(&master_styles)
            .into_iter()
            .filter(|c| XMLNode::name(c) == "style:master-page")
            .collect();
        let first = master_pages.first()?.clone();
        if master_pages.len() <= 1 {
            return Some(first);
        }

        // A style declares its master page directly or inherits it through `style:parent-style-name`
        // — an automatic style (`P1`) almost always carries the geometry-free half and points at the
        // named style that holds the switch. Resolved with the same cycle guard the other style
        // resolvers here use: a malformed document must not spin.
        let mut declared: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        let mut parents: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for root in style_roots {
            for style_node in XMLNode::all_descendants(root, "style:style") {
                let Some(name) = XMLNode::attributes(&style_node).get("style:name").cloned() else { continue };
                if let Some(parent) = XMLNode::attributes(&style_node).get("style:parent-style-name") {
                    parents.entry(name.clone()).or_insert_with(|| parent.clone());
                }
                let Some(master) = XMLNode::attributes(&style_node).get("style:master-page-name").cloned() else { continue };
                if master.is_empty() || declared.contains_key(&name) { continue; }
                declared.insert(name, master);
            }
        }
        // swift: OdtReader.masterPageName
        fn master_page_name(
            name: &str, declared: &std::collections::HashMap<String, String>,
            parents: &std::collections::HashMap<String, String>,
        ) -> Option<String> {
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            let mut current: Option<String> = Some(name.to_string());
            while let Some(key) = current.clone() {
                if !seen.insert(key.clone()) { break; }
                if let Some(master) = declared.get(&key) { return Some(master.clone()); }
                current = parents.get(&key).cloned();
            }
            None
        }

        let mut counts: std::collections::HashMap<String, i32> = std::collections::HashMap::new();
        let mut current = XMLNode::attributes(&first).get("style:name").cloned().unwrap_or_default();
        fn walk(
            node: &Ref<XMLNode>, current: &mut String, counts: &mut std::collections::HashMap<String, i32>,
            declared: &std::collections::HashMap<String, String>,
            parents: &std::collections::HashMap<String, String>,
        ) {
            for child in XMLNode::children(node) {
                // Counted whether or not it names a style: a paragraph with no `text:style-name` is
                // the ORDINARY case, and skipping those counted only the switch points — one
                // appendix paragraph then outvoted a whole body of plain ones.
                let name = XMLNode::name(&child);
                let is_body_content = name == "text:p" || name == "text:h" || name == "table:table";
                let attrs = XMLNode::attributes(&child);
                let style_name = attrs.get("text:style-name").or_else(|| attrs.get("table:style-name"));
                if is_body_content {
                    if let Some(style_name) = style_name {
                        if let Some(master) = master_page_name(style_name, declared, parents) {
                            *current = master;
                        }
                    }
                }
                if is_body_content {
                    *counts.entry(current.clone()).or_insert(0) += 1;
                }
                // Recurse regardless: a `text:section`, list or frame holds paragraphs that carry
                // their own style, and a switch declared inside one is still a switch.
                walk(&child, current, counts, declared, parents);
            }
        }
        walk(body, &mut current, &mut counts, &declared, &parents);

        let mut best = first.clone();
        let mut best_count = *counts.get(&XMLNode::attributes(&first).get("style:name").cloned().unwrap_or_default()).unwrap_or(&0);
        for page in master_pages.iter().skip(1) {
            let name = XMLNode::attributes(page).get("style:name").cloned().unwrap_or_default();
            let count = *counts.get(&name).unwrap_or(&0);
            if count > best_count {
                best = page.clone();
                best_count = count;
            }
        }
        Some(best)
    }

    /// The page layout's geometry in points: the printable column and the margins either side of it,
    /// PLUS the vertical twin of that same pair — the printable row span and the margins above/below
    /// it (`OfficeReadResult.pageContentHeight`), read through the same `parseLength` (cm/mm/in/pt→pt)
    /// as everything else here rather than a second unit parser. The margins were always read here in
    /// order to be SUBTRACTED; they are kept now because a paged view reproduces the PAPER
    /// (`left + content + right`, `top + height + bottom`), not just the column — see
    /// `OfficeReadResult.pageMarginLeft`.
    ///
    /// Height/top/bottom are a SEPARATE guard from width/left/right: a page layout that declares
    /// `fo:page-width` but not `fo:page-height` (or whose vertical geometry computes to ≤0) must not
    /// lose its WIDTH, so a bad/missing height clamps only these three fields to nil.
    ///
    /// `masterPage` is the one the body is actually typeset on (`typesetMasterPage`); its
    /// `style:page-layout-name` names the layout to read. When that name resolves to nothing — no
    /// master page, no such layout, or a layout declaring no usable paper — this falls back to the
    /// old scan of every layout in declaration order, so a document whose master page is unhelpful is
    /// no worse off than before this lookup existed.
    // swift: OdtReader.pageGeometry
    fn page_geometry(style_roots: &[Ref<XMLNode>], master_page: Option<&Ref<XMLNode>>) -> Option<PageGeometry> {
        if let Some(master_page) = master_page {
            if let Some(layout_name) = XMLNode::attributes(master_page).get("style:page-layout-name") {
                if let Some(layout) = style_roots.iter()
                    .flat_map(|r| XMLNode::all_descendants(r, "style:page-layout"))
                    .find(|l| XMLNode::attributes(l).get("style:name") == Some(layout_name))
                {
                    if let Some(geometry) = Self::page_geometry_scanning(std::slice::from_ref(&layout)) {
                        return Some(geometry);
                    }
                }
            }
        }
        Self::page_geometry_scanning(style_roots)
    }

    /// The first usable paper declared anywhere under `roots`, in declaration order.
    // swift: OdtReader.pageGeometry
    fn page_geometry_scanning(roots: &[Ref<XMLNode>]) -> Option<PageGeometry> {
        for root in roots {
            // EVERY page-layout-properties under this root, not just the first: a real writer emits
            // page layouts that carry no paper at all — LibreOffice writes a bare
            // `<style:page-layout-properties style:layout-grid-standard-mode="true"/>` ahead of the
            // real one — and stopping at the first match found that decoy, gave up on the whole root
            // and left an A4 document with no page geometry, i.e. not paged (invariant 57). Take the
            // first that actually DECLARES a usable paper width.
            for props in XMLNode::all_descendants(root, "style:page-layout-properties") {
                let attrs = XMLNode::attributes(&props);
                let Some(width) = attrs.get("fo:page-width").and_then(|s| Self::parse_length(s)) else { continue };
                let left = attrs.get("fo:margin-left").and_then(|s| Self::parse_length(s)).unwrap_or(0.0);
                let right = attrs.get("fo:margin-right").and_then(|s| Self::parse_length(s)).unwrap_or(0.0);
                let content = width - left - right;
                if content <= 0.0 { continue; }
                let mut height: Option<CGFloat> = None;
                let mut top: Option<CGFloat> = None;
                let mut bottom: Option<CGFloat> = None;
                if let Some(page_height) = attrs.get("fo:page-height").and_then(|s| Self::parse_length(s)) {
                    let t = attrs.get("fo:margin-top").and_then(|s| Self::parse_length(s)).unwrap_or(0.0);
                    let b = attrs.get("fo:margin-bottom").and_then(|s| Self::parse_length(s)).unwrap_or(0.0);
                    let content_height = page_height - t - b;
                    if content_height > 0.0 {
                        height = Some(content_height);
                        top = Some(t.max(0.0));
                        bottom = Some(b.max(0.0));
                    }
                }
                return Some(PageGeometry { content, left: left.max(0.0), right: right.max(0.0), height, top, bottom });
            }
        }
        None
    }

    // MARK: Headers/footers — office:master-styles/style:master-page (header-footer-design.md §4)

    /// `office:master-styles/style:master-page`'s `style:header`/`style:footer` (+ `-first`/`-left`
    /// variants), each fed through the SAME `parseBody` the document's own `office:text` uses — zero
    /// new block-parsing code (header-footer-design.md §2c's docx precedent, restated for ODF: a
    /// `text:p`/`table:table` under `style:header` is parsed exactly like one under `office:text`).
    ///
    /// TRAP, real and measured (both `docs/fixtures/office/bus-headings.odt` and `tago-tables.odt`
    /// declare it, byte-identical between the two — treat them as one data point): a page layout's
    /// `style:page-layout` carries its OWN `style:header-style`/`style:footer-style` — a DIFFERENT,
    /// geometry-only element (`fo:min-height`/margins) that is nearly always present and always
    /// empty of content. A grep for "header-style" false-positives on it; this function only ever
    /// looks inside `style:master-page` (never `style:page-layout`), where the CONTENT-bearing
    /// `style:header`/`style:footer` elements actually live.
    ///
    /// The running header/footer read is the one belonging to the master page the body is actually
    /// TYPESET on (`typesetMasterPage`), not simply the first `style:master-page` declared — the same
    /// "most content wins" selection `pageGeometry` uses, so a document's paper and its running
    /// header can never come from two different page styles. A document whose master page could not
    /// be resolved has no header/footer to read.
    ///
    /// Still only ONE master page: a page style is chosen for the whole document, not per switch,
    /// because this reader lays the body out as one continuous column (invariant 57) and has nowhere
    /// to put a second paper. That is the same scope the HWP reader had before invariant 78 gave it
    /// per-page section selection.
    // swift: OdtReader.masterPageHeaderFooters
    fn master_page_header_footers(
        master_page: Option<&Ref<XMLNode>>, styles: &ParsedStyles, archive: &ZipArchive,
    ) -> (Vec<OfficeHeaderFooter>, Vec<OfficeHeaderFooter>) {
        if let Some(master_page) = master_page {
            let mut headers: Vec<OfficeHeaderFooter> = Vec::new();
            let mut footers: Vec<OfficeHeaderFooter> = Vec::new();
            // swift: OdtReader.append
            fn append(
                master_page: &Ref<XMLNode>, tag: &str, applies_to: HeaderFooterApplicability,
                list: &mut Vec<OfficeHeaderFooter>, styles: &ParsedStyles, archive: &ZipArchive,
            ) {
                let Some(node) = XMLNode::child(master_page, tag) else { return };
                let blocks = OdtReader::parse_body(&node, styles, archive, &NoteCollector::new(), 0);
                list.push(OfficeHeaderFooter { applies_to, blocks, section: None });
            }
            append(master_page, "style:header", HeaderFooterApplicability::DefaultPages, &mut headers, styles, archive);
            append(master_page, "style:header-first", HeaderFooterApplicability::FirstPage, &mut headers, styles, archive);
            append(master_page, "style:header-left", HeaderFooterApplicability::EvenPages, &mut headers, styles, archive);
            append(master_page, "style:footer", HeaderFooterApplicability::DefaultPages, &mut footers, styles, archive);
            append(master_page, "style:footer-first", HeaderFooterApplicability::FirstPage, &mut footers, styles, archive);
            append(master_page, "style:footer-left", HeaderFooterApplicability::EvenPages, &mut footers, styles, archive);
            return (headers, footers);
        }
        (Vec::new(), Vec::new())
    }

    /// The document's own default BODY paragraph size, in points — ODF states this in
    /// `style:default-style` (the family-wide fallback every paragraph without its own explicit
    /// size ultimately falls back to, family `"paragraph"`)'s `style:text-properties/fo:font-size`.
    /// A SEPARATE entry point from `read()` rather than a second return value: `read()`'s signature
    /// (`[OfficeBlock]`) is a call-site contract `DocumentTypes.readOffice`/`MarkdownDocument` depend
    /// on. Reached ONLY through `DocumentTypes.officeDefaultBodyFontSize`, never called directly by
    /// `MarkdownDocument` — see `DocumentTypes.officeReaderType`'s doc for why. `11` — the same
    /// default `OfficeTextBuilder.build` itself falls back to — is returned when the document
    /// declares no `style:default-style` at all, or one with no font size.
    // swift: OdtReader.documentDefaultBodyFontSize
    pub fn document_default_body_font_size(archive: &ZipArchive) -> CGFloat {
        if !archive.contains("content.xml") {
            return 11.0;
        }
        let Some(content_data) = archive.data_for("content.xml").ok() else { return 11.0 };
        let Some(content_root) = Self::build_tree(&content_data).ok() else { return 11.0 };
        let mut roots = vec![content_root];
        if archive.contains("styles.xml") {
            if let Ok(data) = archive.data_for("styles.xml") {
                if let Ok(styles_root) = Self::build_tree(&data) {
                    roots.push(styles_root);
                }
            }
        }
        // `styles.xml` is where Writer actually puts `style:default-style` in real documents — search
        // it FIRST (unlike every other style table in this file, which lets content.xml win on a
        // name collision: `style:default-style` isn't a named style two parts could disagree about,
        // there is only ever one, so "first part that declares one" is the only meaningful order).
        for root in roots.iter().rev() {
            if let Some(size) = Self::parse_default_paragraph_font_size(root) {
                return size;
            }
        }
        11.0
    }

    // MARK: Footnotes / endnotes — text:note (told apart by text:note-class, but rendered identically)

    /// Every `#text` descendant of `node`, concatenated in document order, with `text:tab`/
    /// `text:line-break` turned into `\t`/`\n` — used ONLY for a comment's own `dc:creator`/
    /// `dc:date`/`text:p` content (P6a — `OfficeComment` carries no `Span`s, unlike a document
    /// paragraph, so there is nothing to preserve formatting FOR here, unlike `collectSpans`'s own
    /// walk). Not `collectSpans` itself: that produces styled `Span`s and threads bookmarks/
    /// comment-range state neither of which a comment's own text needs.
    // swift: OdtReader.plainText
    fn plain_text(node: &Ref<XMLNode>) -> String {
        let mut text = String::new();
        fn walk(node: &Ref<XMLNode>, text: &mut String) {
            for child in XMLNode::children(node) {
                match XMLNode::name(&child).as_str() {
                    "#text" => text.push_str(&XMLNode::text(&child)),
                    "text:tab" => text.push('\t'),
                    "text:line-break" => text.push('\n'),
                    _ => walk(&child, text),
                }
            }
        }
        walk(node, &mut text);
        text
    }

    /// `text:note-citation`'s own character-data children ARE the marker Word/LibreOffice actually
    /// displays ("1", "i", …, whatever the note's numbering style produced) — read verbatim, never
    /// recomputed, so this reader never has to know footnote vs. endnote numbering schemes (unlike
    /// docx's `w:footnoteReference`, which carries no number of its own — see `DocxReader`). Missing
    /// entirely (malformed) yields an empty string, which the caller (`collectSpans`'s `text:note`
    /// case) falls back to `NoteCollector.fallbackCounter` for, rather than showing a blank marker.
    // swift: OdtReader.noteCitationText
    fn note_citation_text(note: &Ref<XMLNode>) -> String {
        let Some(citation) = XMLNode::child(note, "text:note-citation") else { return String::new() };
        XMLNode::children(&citation).into_iter()
            .filter(|c| XMLNode::name(c) == "#text")
            .map(|c| XMLNode::text(&c))
            .collect::<Vec<_>>()
            .join("")
    }

    /// Turns each note's body into ordinary blocks — reusing `parseBody` itself, since
    /// `text:note-body`'s children (`text:p`/`text:h`/`text:list`/`table:table`) are exactly the
    /// shape `office:text`'s own children are — appended in citation order at the document's end,
    /// each prefixed with the SAME marker span rendered at the citation point, so a reader can match
    /// one back to the other. See `DocxReader.collectNoteBlocks`/`prependingMarker` for the mirrored
    /// docx-side logic (kept format-specific rather than shared, per the roadmap's own call: the
    /// EXTRACTION differs per format, only the output shape is one-to-one).
    // swift: OdtReader.buildNoteBlocks
    fn build_note_blocks(
        note_entries: &[(String, Ref<XMLNode>)], styles: &ParsedStyles, archive: &ZipArchive,
    ) -> Vec<OfficeBlock> {
        note_entries.iter().flat_map(|entry| {
            // A footnote/endnote body cannot itself contain another `text:note` in any real
            // document (ODF disallows it), so a note-body-local `NoteCollector` here only ever
            // guards against a malformed file recursing forever — it is discarded, never merged
            // back into the outer one.
            let mut blocks = Self::parse_body(&entry.1, styles, archive, &NoteCollector::new(), 0);
            let marker = Span { text: entry.0.clone().into(), superscript: true, ..Default::default() };
            if let Some(first) = blocks.first().cloned() {
                if let Some(marked_first) = Self::prepending_marker(marker.clone(), &first) {
                    blocks[0] = marked_first;
                } else {
                    // Empty note body, or one that opens with a table/image — neither has a `[Span]` to
                    // splice into, so the marker becomes its own small leading paragraph instead of
                    // being silently dropped.
                    blocks.insert(0, OfficeBlock::Paragraph { spans: vec![marker], rtl: false, alignment: None, tab_stops: vec![], format: ParagraphFormat::default(), format_ref: None });
                }
            } else {
                blocks.insert(0, OfficeBlock::Paragraph { spans: vec![marker], rtl: false, alignment: None, tab_stops: vec![], format: ParagraphFormat::default(), format_ref: None });
            }
            blocks
        }).collect()
    }

    /// Word stores a literal `w:tab` inside the note body itself, between the auto-numbered mark
    /// and the text (its own footnote-paragraph template fakes a hanging indent that way) — so a
    /// docx note body's OWN first span already starts with `"\t"`, read verbatim like any other
    /// tab in the document. ODF has no such element (its hanging indent is a paragraph-style
    /// property, not a character), and since the marker prepended here is OUR OWN construct, not
    /// something the file gave us, the number would otherwise run straight into the first word —
    /// `"1The first note body text."` reads as a typo, and a reader comparing the two formats'
    /// output would see them disagree over one document for no reason a user could point to. A
    /// synthetic tab span, plain (not superscript, not part of the marker itself), closes that gap
    /// and matches what docx already shows.
    // swift: OdtReader.prependingMarker
    fn note_marker_separator() -> Span {
        Span { text: "\t".to_string().into(), ..Default::default() }
    }

    /// `nil` for `.table`/`.image` — there is no `[Span]` inside either to prepend into.
    // swift: OdtReader.prependingMarker
    fn prepending_marker(marker: Span, block: &OfficeBlock) -> Option<OfficeBlock> {
        match block {
            OfficeBlock::Paragraph { spans, rtl, alignment, tab_stops, format, .. } => {
                let mut new_spans = vec![marker, Self::note_marker_separator()];
                new_spans.extend(spans.clone());
                Some(OfficeBlock::Paragraph {
                    spans: new_spans, rtl: rtl.clone(), alignment: alignment.clone(),
                    tab_stops: tab_stops.clone(), format: format.clone(), format_ref: None,
                })
            }
            OfficeBlock::Heading { level, spans, rtl, alignment, tab_stops, format, .. } => {
                let mut new_spans = vec![marker, Self::note_marker_separator()];
                new_spans.extend(spans.clone());
                Some(OfficeBlock::Heading {
                    level: *level, spans: new_spans, rtl: rtl.clone(), alignment: alignment.clone(),
                    tab_stops: tab_stops.clone(), format: format.clone(), format_ref: None,
                })
            }
            OfficeBlock::ListItem { level, ordered, spans, marker: item_marker, rtl, alignment, tab_stops, format, .. } => {
                let mut new_spans = vec![marker, Self::note_marker_separator()];
                new_spans.extend(spans.clone());
                // The Swift original (Render/Office/OdtReader.swift:435-437) binds `numbering` with `_` and omits
                // it on reconstruction, so it falls to `OfficeBlock.listItem`'s own default
                // (`numbering: ListNumbering? = nil`, OfficeBlock.swift:817) — silently dropping the
                // item's numbering here. Reproduced deliberately, not fixed: `numbering`'s own doc
                // comment calls it a "vocabulary-only addition, trailing and defaulted so no
                // existing caller changes meaning" — this IS an existing caller that would have
                // needed updating and was not, so this looks like a latent Swift defect rather than
                // a design choice. The port must match the program that exists, not the one that
                // should; diverging here would make every corpus-comparison diff at this site
                // ambiguous between "port bug" and "we improved on Swift". Do not "fix" this back to
                // preserving `numbering` without also fixing OdtReader.swift and DocxReader.swift.
                Some(OfficeBlock::ListItem {
                    level: *level, ordered: *ordered, spans: new_spans, marker: item_marker.clone(),
                    rtl: rtl.clone(), alignment: alignment.clone(), tab_stops: tab_stops.clone(),
                    format: format.clone(), numbering: None,
                    format_ref: None,
                })
            }
            OfficeBlock::Table { .. } | OfficeBlock::Image { .. } | OfficeBlock::UnsupportedGraphic { .. }
            | OfficeBlock::Formula { .. } => None,
        }
    }
}

// MARK: Every style family this reader resolves, bundled for one-parameter threading

/// Everything `parseBody`/`parseList`/`collectCellBlocks` need from `content.xml` +
/// `styles.xml`'s style tables, already merged AND inheritance-resolved (see `read()`) — bundled
/// into one value so adding this sprint's two NEW families (table-cell, table-column) didn't mean
/// growing every recursive helper's parameter list by two more names apiece. `listStyles`/
/// `textStyles`/`paragraphStyles` existed before this sprint as separate parameters; nothing about
/// their OWN shape changed, only that they now travel together.
// swift: OdtReader.ParsedStyles
struct ParsedStyles {
    list_styles: std::collections::HashMap<String, std::collections::HashMap<i32, bool>>,
    text_styles: std::collections::HashMap<String, TextStyle>,
    paragraph_styles: std::collections::HashMap<String, ResolvedParagraphStyle>,
    table_cell_styles: std::collections::HashMap<String, TableCellStyle>,
    table_column_styles: std::collections::HashMap<String, TableColumnStyle>,
}

// MARK: Text (span) styles — automatic-styles → bold/italic/underline/color/highlight/size/family

/// The family a style states for each of ODF's three script types, already resolved through
/// `office:font-face-decls` and `normalizedFontFamily`. `nil` in a slot means the style chain
/// declared no family for that script type — never a stand-in name, and never the family from a
/// NEIGHBOURING slot.
///
/// Falling back across slots (asian → latin when only latin is declared) was considered and
/// rejected, and the reason is the whole point of this work: that fallback IS the defect being
/// removed, drawing Hangul in the face the document chose for its English words. ODF defines the
/// three properties independently — §20.277-§20.279 are the same sentence three times with the
/// script type swapped — and states no precedence between them, so an undeclared slot is
/// undeclared, and `nil` means what it has always meant everywhere else in this reader: the
/// theme's own body font (invariant 37).
// swift: OdtReader.SlotFonts
#[derive(Debug, Clone, Default, PartialEq)]
struct SlotFonts {
    latin: Option<String>,
    asian: Option<String>,
    complex: Option<String>,
}

impl SlotFonts {
    /// True when no character in any script can pick a different family from any other — the
    /// common case by far, since a document that means one typeface points all three slots at
    /// it. `collectSpans` uses this to skip the per-scalar walk entirely, which is what makes
    /// "the document declared one family, or none" cost exactly what it cost before per-slot
    /// resolution existed rather than merely producing the same answer more slowly.
    // swift: OdtReader.SlotFonts.family
    fn is_uniform(&self) -> bool {
        self.latin == self.asian && self.asian == self.complex
    }

    // swift: OdtReader.SlotFonts.family
    fn family(&self, script_type: OdfScriptType) -> Option<String> {
        match script_type {
            OdfScriptType::Latin => self.latin.clone(),
            OdfScriptType::Asian => self.asian.clone(),
            OdfScriptType::Complex => self.complex.clone(),
        }
    }
}

// swift: OdtReader.TextStyle
#[derive(Debug, Clone, Default, PartialEq)]
struct TextStyle {
    bold: bool,
    italic: bool,
    underline: bool,
    strikethrough: bool,
    superscript: bool,
    subscripted: bool,
    /// `Span.textColor`/`Span.highlightColor`/`Span.fontSize`/`Span.fontName` — see those fields'
    /// own doc comments in `OfficeBlock.swift` for exactly how `OfficeTextBuilder` treats each
    /// once it reaches a `Span`. `nil` means the style (after inheritance) never said — never a
    /// literal black/zero/system-default value, same "absent stays unspecified" rule every other
    /// property in this file already follows.
    text_color: Option<NSColor>,
    highlight_color: Option<NSColor>,
    font_size: Option<CGFloat>,
    /// The three families, one per ODF script type. A `Span` still carries ONE `fontName` —
    /// `collectSpans` cuts a run into pieces where the resolved family changes and gives each
    /// piece its own, so nothing downstream of this reader learns that slots exist.
    fonts: SlotFonts,
    /// P4 — `Span.underlineStyle`/`.caps`/`.smallCaps`'s ODF sources (`style:text-underline-
    /// style`+`style:text-underline-type`, `fo:text-transform`, `fo:font-variant`). `underlineStyle`
    /// defaults `.single`, matching `Span`'s own default (meaningful only when `underline` above
    /// is `true`).
    underline_style: UnderlineStyle,
    caps: bool,
    small_caps: bool,
}

/// The RAW, per-style, NOT-YET-INHERITED declaration a single `style:style` element (family
/// `"text"`) makes — every field is an `Optional` (unlike `TextStyle`'s own `Bool`s, which default
/// `false`) precisely so `resolveTextStyle` can tell "this style says OFF" apart from "this style
/// says nothing, ask the parent" while walking `parent` — see `resolveTextStyle`'s doc comment.
// swift: OdtReader.TextStyleDecl
#[derive(Debug, Clone, Default)]
struct TextStyleDecl {
    bold: Option<bool>,
    italic: Option<bool>,
    underline: Option<bool>,
    strikethrough: Option<bool>,
    superscript: Option<bool>,
    subscripted: Option<bool>,
    text_color: Option<NSColor>,
    highlight_color: Option<NSColor>,
    font_size: Option<CGFloat>,
    /// Three INDEPENDENT optionals, not one `SlotFonts` — a style may declare the complex family
    /// and nothing else (both `List` and `Index` in this repo's own fixtures do exactly that),
    /// and the two it stayed silent about have to keep inheriting from the parent. One combined
    /// value with one "was it declared" flag would answer for all three at once and silently drop
    /// the parent's other two families.
    font_name: Option<String>,
    font_name_asian: Option<String>,
    font_name_complex: Option<String>,
    underline_style: Option<UnderlineStyle>,
    caps: Option<bool>,
    small_caps: Option<bool>,
    /// `style:parent-style-name` — the style this one is based on, resolved by `resolveTextStyle`.
    parent: Option<String>,
}

impl OdtReader {
    /// Only `style:family="text"` styles are read — ODF reuses `style:style` for paragraph, table,
    /// table-cell, graphic and text styles alike, all distinguished by `style:family`; picking up
    /// the wrong family would collide names (a paragraph style and a text style can share a name).
    /// A style with no `style:text-properties` at all, or one that declares none of the
    /// properties this reader understands, is simply absent from the map — `collectSpans` reads
    /// that as "no formatting", never a crash. `fontFaces` (already merged from both parts by the
    /// time this runs — see `read()`) resolves `style:font-name`'s indirection through
    /// `office:font-face-decls`; `fo:font-family` (rarer, but legal directly on `style:text-
    /// properties`) is read as a literal name with no such indirection.
    // swift: OdtReader.parseTextStyleDecls
    fn parse_text_style_decls(
        root: &Ref<XMLNode>, font_faces: &std::collections::HashMap<String, String>,
    ) -> std::collections::HashMap<String, TextStyleDecl> {
        let mut map: std::collections::HashMap<String, TextStyleDecl> = std::collections::HashMap::new();
        for style_node in XMLNode::all_descendants(root, "style:style") {
            let attrs = XMLNode::attributes(&style_node);
            if attrs.get("style:family").map(String::as_str) != Some("text") { continue; }
            let Some(name) = attrs.get("style:name").cloned() else { continue };
            let mut decl = TextStyleDecl::default();
            decl.parent = attrs.get("style:parent-style-name").cloned();
            if let Some(props) = XMLNode::child(&style_node, "style:text-properties") {
                let props_attrs = XMLNode::attributes(&props);
                if let Some(weight) = props_attrs.get("fo:font-weight") { decl.bold = Some(weight == "bold"); }
                if let Some(style) = props_attrs.get("fo:font-style") { decl.italic = Some(style == "italic"); }
                if let Some(underline) = props_attrs.get("style:text-underline-style") { decl.underline = Some(underline != "none"); }
                if let Some(strike) = props_attrs.get("style:text-line-through-style") { decl.strikethrough = Some(strike != "none"); }
                // `style:text-position` is `"<super|sub> <percentage>"` (e.g. `"super 58%"`) — only
                // the leading keyword decides which axis; the percentage is a font-scale hint this
                // viewer doesn't reproduce (same "skip presentation fidelity" call as everywhere else).
                if let Some(position) = props_attrs.get("style:text-position") {
                    decl.superscript = Some(position.starts_with("super"));
                    decl.subscripted = Some(position.starts_with("sub"));
                }
                if let Some(color) = props_attrs.get("fo:color") { decl.text_color = Self::parse_odf_color(color); }
                if let Some(bg) = props_attrs.get("fo:background-color") { decl.highlight_color = Self::parse_odf_color(bg); }
                // `fo:font-size` is almost always an absolute length ("12pt") in a real document —
                // `parseLength` handles that. A PERCENTAGE ("150%", relative to the parent style's own
                // size) is a real, legal ODF value this reader does NOT resolve: `parseLength` has no
                // "%" suffix in its table and `Double("150%")` itself fails to parse, so it naturally
                // returns `nil` — read as "no size specified" rather than a wrong literal number. That
                // is a deliberate skip, not an oversight (see this sprint's own report).
                if let Some(size) = props_attrs.get("fo:font-size") { decl.font_size = Self::parse_length(size); }
                // swift: OdtReader.resolveSlot
                // ODF states the family THREE times, once per script type (§20.277-§20.279 are the
                // same sentence with latin / asian / complex swapped), and each of the three has an
                // indirect form naming a `style:font-face` and a direct form holding the family
                // literally. Note the naming asymmetry that defeats any `name + "-asian"` string
                // building: the western direct form is `fo:`-prefixed and the western indirect form
                // is `style:`-prefixed, while every asian/complex twin is `style:`-prefixed. There is
                // no mechanical transform, so the pairs are a literal table.
                //
                // All six routes end at `normalizedFontFamily`, the ONE place that turns an XSL
                // `font-family` value into something `NSFont(name:)` can be handed — see its own
                // doc. `style:font-name*` names a `style:font-face`; when that face exists its
                // `svg:font-family` is used EVEN IF EMPTY (an emptily-declared face states no
                // typeface, which must read as "this style says nothing about the family" so the
                // parent's real one still inherits), and only a reference to a face that was never
                // declared at all falls back to the reference name itself.
                //
                // Indirect BEATS direct per slot, which is the spec's own stated preference
                // (§20.189: "Instead of this attribute, the style:font-name attribute should be
                // used") — and it beats it even when it resolves to nothing, because the two are two
                // spellings of one declaration rather than a preference list, and LibreOffice writes
                // both onto the same element meaning the same thing. Falling through to the direct
                // twin when the indirect one names an empty face was considered and rejected: it
                // would change what the LATIN slot already resolves to today, which is a separate
                // question from adding the other two.
                fn resolve_slot(
                    props_attrs: &std::collections::HashMap<String, String>, indirect: &str, direct: &str,
                    font_faces: &std::collections::HashMap<String, String>,
                ) -> Option<String> {
                    if let Some(face_name) = props_attrs.get(indirect) {
                        return OdtReader::normalized_font_family(font_faces.get(face_name).unwrap_or(face_name));
                    }
                    if let Some(family) = props_attrs.get(direct) {
                        return OdtReader::normalized_font_family(family);
                    }
                    None
                }
                decl.font_name = resolve_slot(&props_attrs, "style:font-name", "fo:font-family", font_faces);
                decl.font_name_asian = resolve_slot(&props_attrs, "style:font-name-asian", "style:font-family-asian", font_faces);
                decl.font_name_complex = resolve_slot(&props_attrs, "style:font-name-complex", "style:font-family-complex", font_faces);
                // P4 — `style:text-underline-type="double"` wins over `style:text-underline-style`
                // (ODF lets both be stated together); read together so a double underline is never
                // reported as merely a dotted/dashed/wavy `.single`. Absent style with a present type
                // (rare, malformed) still resolves via the `default: .single` fallthrough.
                if props_attrs.get("style:text-underline-style").is_some()
                    || props_attrs.get("style:text-underline-type").is_some() {
                    if props_attrs.get("style:text-underline-type").map(String::as_str) == Some("double") {
                        decl.underline_style = Some(UnderlineStyle::Double);
                    } else {
                        decl.underline_style = Some(match props_attrs.get("style:text-underline-style").map(String::as_str) {
                            Some("dotted") => UnderlineStyle::Dotted,
                            Some(v) if v.starts_with("dash") || v == "long-dash" => UnderlineStyle::Dashed,
                            Some(v) if v.starts_with("wave") => UnderlineStyle::Wavy,
                            _ => UnderlineStyle::Single,
                        });
                    }
                }
                // P4 — only `"uppercase"` maps to `Span.caps`; `capitalize`/`lowercase`/`none` have no
                // equivalent field, so a document declaring one of those explicitly turns caps OFF
                // (an explicit, non-uppercase value beats an ancestor's `uppercase`), same "explicit
                // beats inherited" posture every other toggle in this cascade already has.
                if let Some(transform) = props_attrs.get("fo:text-transform") {
                    decl.caps = Some(transform == "uppercase");
                }
                if let Some(variant) = props_attrs.get("fo:font-variant") {
                    decl.small_caps = Some(variant == "small-caps");
                }
            }
            map.insert(name, decl);
        }
        map
    }

    /// `office:font-face-decls > style:font-face` — the indirection `style:font-name` points through:
    /// a `style:text-properties/@style:font-name` is a REFERENCE (`style:font-face/@style:name`), not
    /// the literal family name itself, which lives on that SAME element's `svg:font-family`. Searched
    /// the same "anywhere below root" way every other style table in this file is, since a font-face
    /// declaration can live in either part exactly like a style can.
    ///
    /// The family is stored VERBATIM, quoting and all, including an empty one — normalization
    /// happens at the single point that consumes it (`parseTextStyleDecls` →
    /// `normalizedFontFamily`). Dropping empty declarations here instead was the obvious shape and
    /// is wrong: it makes a face that was DECLARED with no family indistinguishable from one that
    /// was never declared, and those resolve differently — the first states no typeface (inherit),
    /// the second falls back to the reference name.
    // swift: OdtReader.parseFontFaceDecls
    fn parse_font_face_decls(root: &Ref<XMLNode>) -> std::collections::HashMap<String, String> {
        let mut map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for face in XMLNode::all_descendants(root, "style:font-face") {
            let attrs = XMLNode::attributes(&face);
            let (Some(name), Some(family)) = (attrs.get("style:name").cloned(), attrs.get("svg:font-family").cloned()) else { continue };
            map.insert(name, family);
        }
        map
    }

    /// One XSL `font-family` value (ODF `svg:font-family` / `fo:font-family`) → the single family
    /// name to record on a `Span`, or `nil` when it names no typeface at all.
    ///
    /// Two things make the raw attribute unusable as a font name. It is a LIST of alternatives in
    /// preference order, and its members are CSS-quoted whenever the name is not a bare identifier
    /// — LibreOffice writes `svg:font-family="&apos;Noto Sans CJK KR&apos;"`, which unescapes to a
    /// value carrying literal apostrophes. `NSFont(name:)` wants a family name, not a CSS token:
    /// measured on this machine, `NSFont(name: "'Noto Sans CJK KR'", size: 12)` is `nil` while the
    /// unquoted spelling resolves, so before this every quoted family in every ODT silently
    /// resolved to nothing and the document's chosen typeface was never drawn. All four `.odt`
    /// fixtures in `docs/fixtures/office` quote this way, so this is the common case, not an edge.
    ///
    /// The split is quote-AWARE rather than a plain `split(separator: ",")`: a comma inside a
    /// quoted member belongs to the name. That case is vanishingly rare in real font names, but
    /// tracking the quote state is what lets the SAME scan strip the quotes, so handling it costs
    /// nothing extra and removes the question. A quote character is structural and never part of a
    /// family name, so an UNBALANCED one (malformed, but it happens) still yields the bare name
    /// rather than a name with a stray quote in it — which is the whole failure this function
    /// exists to end. An apostrophe inside a double-quoted member is ordinary text, and vice versa.
    ///
    /// Only the FIRST member that names something is kept: a `Span` records one family, and the
    /// remaining alternatives are fallbacks for a font that isn't installed — a question
    /// `FontSubstitutionResolver` already answers against what this machine actually has, using
    /// coverage rather than the author's guess. A leading member that names nothing (`", Arial"`)
    /// is skipped rather than being read as "no family", because an empty member carries no
    /// intent while `Arial` plainly does.
    // swift: OdtReader.normalizedFontFamily
    fn normalized_font_family(raw: &str) -> Option<String> {
        let mut members: Vec<String> = Vec::new();
        let mut current = String::new();
        let mut quote: Option<char> = None;
        for character in raw.chars() {
            if let Some(open) = quote {
                if character == open { quote = None; } else { current.push(character); }
            } else if character == '\'' || character == '"' {
                quote = Some(character);
            } else if character == ',' {
                members.push(current.clone());
                current.clear();
            } else {
                current.push(character);
            }
        }
        members.push(current);
        for member in members {
            let trimmed = member.trim();
            if !trimmed.is_empty() { return Some(trimmed.to_string()); }
        }
        None
    }

    /// Resolves one text style's `style:parent-style-name` chain into a final `TextStyle` — the
    /// NEAREST declaration of each field wins (the style itself, else its parent, else its
    /// grandparent, …), exactly the way `DocxReader.resolvedOutlineLevel` walks `w:basedOn`. A name
    /// already visited during THIS walk means a cycle in a malformed document (`A` based on `B` based
    /// on `A`) — the walk stops there rather than looping forever, same guard, same reasoning. A field
    /// never declared anywhere in the chain keeps `TextStyle`'s own default (`false`/`nil`).
    // swift: OdtReader.resolveTextStyle
    fn resolve_text_style(
        style_name: &str, decls: &std::collections::HashMap<String, TextStyleDecl>,
    ) -> TextStyle {
        let mut result = TextStyle::default();
        // Three independent font flags, one per script type — the nearest-wins walk runs PER SLOT,
        // so a child that declares only the complex family still inherits the parent's latin and
        // asian ones. A single `font` flag would stop the walk for all three the moment any one of
        // them was declared, which is the shape this repo's own fixtures break immediately: their
        // `List` and `Index` styles declare the complex family and nothing else.
        let mut have = HaveTextFlags::default();
        let mut current_name: Option<String> = Some(style_name.to_string());
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        while let Some(name) = current_name.clone() {
            if visited.contains(&name) { break; }
            visited.insert(name.clone());
            let Some(decl) = decls.get(&name) else { break };
            if !have.bold { if let Some(v) = decl.bold { result.bold = v; have.bold = true; } }
            if !have.italic { if let Some(v) = decl.italic { result.italic = v; have.italic = true; } }
            if !have.underline { if let Some(v) = decl.underline { result.underline = v; have.underline = true; } }
            if !have.strike { if let Some(v) = decl.strikethrough { result.strikethrough = v; have.strike = true; } }
            if !have.sup { if let Some(v) = decl.superscript { result.superscript = v; have.sup = true; } }
            if !have.sub { if let Some(v) = decl.subscripted { result.subscripted = v; have.sub = true; } }
            if !have.color { if let Some(v) = decl.text_color.clone() { result.text_color = Some(v); have.color = true; } }
            if !have.highlight { if let Some(v) = decl.highlight_color.clone() { result.highlight_color = Some(v); have.highlight = true; } }
            if !have.size { if let Some(v) = decl.font_size { result.font_size = Some(v); have.size = true; } }
            if !have.font { if let Some(v) = decl.font_name.clone() { result.fonts.latin = Some(v); have.font = true; } }
            if !have.font_asian { if let Some(v) = decl.font_name_asian.clone() { result.fonts.asian = Some(v); have.font_asian = true; } }
            if !have.font_complex { if let Some(v) = decl.font_name_complex.clone() { result.fonts.complex = Some(v); have.font_complex = true; } }
            if !have.underline_style { if let Some(v) = decl.underline_style { result.underline_style = v; have.underline_style = true; } }
            if !have.caps { if let Some(v) = decl.caps { result.caps = v; have.caps = true; } }
            if !have.small_caps { if let Some(v) = decl.small_caps { result.small_caps = v; have.small_caps = true; } }
            current_name = decl.parent.clone();
        }
        result
    }
}

/// Swift: the tuple-typed local `var have = (bold: false, italic: false, ...)` inside
/// `resolveTextStyle` — given a name here since Rust has no anonymous-tuple-with-named-fields
/// literal syntax as convenient to mutate through `&mut` field access.
// swift: OdtReader.resolveTextStyle
#[derive(Default)]
struct HaveTextFlags {
    bold: bool, italic: bool, underline: bool, strike: bool, sup: bool, sub: bool,
    color: bool, highlight: bool, size: bool,
    font: bool, font_asian: bool, font_complex: bool,
    underline_style: bool, caps: bool, small_caps: bool,
}

impl OdtReader {
    // MARK: List styles — style name → (0-based level → ordered?)

    /// ODF numbers list levels 1-based (`text:level="1"` is the outermost) — converted to the
    /// 0-based nesting depth `OfficeBlock.listItem.level` already uses, so `isOrdered` never has to
    /// re-derive the offset. A level with neither a number nor a bullet child (an image-marker
    /// level, rare but legal) is simply absent, which `isOrdered` reads as unresolvable → bullet.
    // swift: OdtReader.parseListStyles
    fn parse_list_styles(root: &Ref<XMLNode>) -> std::collections::HashMap<String, std::collections::HashMap<i32, bool>> {
        let mut map: std::collections::HashMap<String, std::collections::HashMap<i32, bool>> = std::collections::HashMap::new();
        for list_style in XMLNode::all_descendants(root, "text:list-style") {
            let attrs = XMLNode::attributes(&list_style);
            let Some(name) = attrs.get("style:name").cloned() else { continue };
            let mut levels: std::collections::HashMap<i32, bool> = std::collections::HashMap::new();
            for level_style in XMLNode::children(&list_style) {
                let level_attrs = XMLNode::attributes(&level_style);
                let Some(level) = level_attrs.get("text:level").and_then(|s| s.parse::<i32>().ok()) else { continue };
                match XMLNode::name(&level_style).as_str() {
                    "text:list-level-style-number" => { levels.insert(level - 1, true); }
                    "text:list-level-style-bullet" => { levels.insert(level - 1, false); }
                    _ => continue,
                }
            }
            map.insert(name, levels);
        }
        map
    }

    /// Unresolvable input — no style name on the list at all, a style name absent from the table,
    /// or a level the style doesn't declare — defaults to unordered (a bullet), never ordered: an
    /// unstyled list is a faithful reading, a fabricated "1. 2. 3." is not (same reasoning as
    /// `DocxReader.isOrdered`).
    // swift: OdtReader.isOrdered
    fn is_ordered(
        style_name: Option<&str>, level: i32,
        list_styles: &std::collections::HashMap<String, std::collections::HashMap<i32, bool>>,
    ) -> bool {
        let Some(style_name) = style_name else { return false };
        list_styles.get(style_name).and_then(|m| m.get(&level)).copied().unwrap_or(false)
    }

    // This reader never supplies `OfficeBlock.listItem`'s `marker` — every `.listItem(...)` built
    // below leaves it at its default `nil`, an explicit decision, not an oversight: teaching an
    // ODF list style's number-format element (`text:list-level-style-number`'s own `style:num-
    // format`/`style:num-prefix`/`style:num-suffix`, ODF's rough equivalent of docx's `w:lvlText`)
    // the same restart/override semantics `DocxReader` now implements is out of this sprint's
    // scope. `OfficeTextBuilder`'s own counter-based fallback (unchanged) is what ODF lists still
    // render through, exactly as before this sprint.
}

// MARK: Paragraph styles — outline level, writing direction, alignment, tab stops

// swift: OdtReader.ResolvedParagraphStyle
#[derive(Debug, Clone, Default)]
struct ResolvedParagraphStyle {
    outline_level: Option<i32>,
    /// The paragraph style's own run weight/posture — the BASE every span in the paragraph starts
    /// from, which a text-family style on an individual run then overrides. See
    /// `ParagraphStyleDecl.bold`.
    bold: Option<bool>,
    italic: Option<bool>,
    rtl: bool,
    alignment: Option<NSTextAlignment>,
    /// Each `style:tab-stop`'s `style:position` plus its `style:type` (alignment: left/center/
    /// right/char→decimal) and leader (`style:leader-text`/`style:leader-style`) — parity with
    /// `DocxReader.parseTabStops`, so an ODF TOC's right-aligned page number or a dotted leader
    /// renders the same as its docx twin (they were previously flattened to a plain left tab).
    tab_stops: Vec<TabStop>,
    /// P4 — spacing/indent/line-height/shading/border, cascaded the SAME nearest-wins way as
    /// every other field here. Built up field-by-field in `resolveParagraphStyle` (each of
    /// `ParagraphFormat`'s own `Optional` fields already IS the "unset" sentinel this cascade
    /// needs, so no separate `have.*` flags are needed for these — unlike the `Bool`-defaulting
    /// fields above).
    format: ParagraphFormat,
}

/// The RAW, not-yet-inherited declaration of one `style:style` element, family `"paragraph"`.
/// `alignmentRaw` stays the FILE's literal `fo:text-align` string (`"start"`/`"end"`/`"left"`/…)
/// through resolution — `start`/`end` can only become a real `NSTextAlignment` once the CHAIN's
/// resolved `rtl` is known (see `resolveParagraphStyle`), so converting eagerly per-declaration
/// would risk resolving against the wrong (this style's OWN, not yet inherited) writing mode.
// swift: OdtReader.ParagraphStyleDecl
#[derive(Debug, Clone, Default)]
struct ParagraphStyleDecl {
    /// `fo:font-weight`/`fo:font-style` off this paragraph style's own
    /// `style:text-properties`. Three-state like every other field here: `nil` = this level
    /// said nothing (keep climbing), `false` = it explicitly said normal.
    bold: Option<bool>,
    italic: Option<bool>,
    outline_level: Option<i32>,
    rtl: Option<bool>,
    alignment_raw: Option<String>,
    tab_stops: Vec<TabStop>,
    parent: Option<String>,
    /// P4 — `fo:margin-top`/`-bottom`/`-left`/`-right`, `fo:text-indent` (normalized into
    /// EITHER `firstLineIndent` OR `hangingIndent`, never both — see the parse site), `fo:line-
    /// height`/`style:line-height-at-least`, `fo:background-color` (paragraph SHADING — a
    /// DIFFERENT element than `style:text-properties`'s own `fo:background-color`, which
    /// `TextStyleDecl.highlightColor` reads as run highlight, never this), and `fo:border`.
    spacing_before: Option<CGFloat>,
    spacing_after: Option<CGFloat>,
    indent_start: Option<CGFloat>,
    indent_end: Option<CGFloat>,
    first_line_indent: Option<CGFloat>,
    hanging_indent: Option<CGFloat>,
    line_height: Option<LineHeight>,
    shading: Option<NSColor>,
    border_color: Option<NSColor>,
    border_width: Option<CGFloat>,
    /// ODF `style:paragraph-properties/@style:contextual-spacing` (ODF 1.3 §20.353) — the docx
    /// `w:contextualSpacing` equivalent: when true, drop the space BETWEEN adjacent paragraphs of
    /// the same style. `Bool?`, not `Bool`, for the same per-property cascade reason docx's is
    /// (`DocxReader.ParaProps.contextualSpacing`): a style that never mentions it must climb the
    /// parent chain, which a plain `false` would silently stop.
    contextual_spacing: Option<bool>,
}

impl OdtReader {
    /// A `text:p` isn't the only way ODF marks a heading — Writer also lets a PARAGRAPH STYLE itself
    /// declare `style:default-outline-level` (an attribute directly on `style:style`, family
    /// `"paragraph"`), so a paragraph styled that way is a heading even though its element name is
    /// the plain `text:p` an ordinary paragraph uses. Only `style:family="paragraph"` styles are
    /// read, mirroring `parseTextStyleDecls`'s own family filter — `style:style` is reused across
    /// several families, and a text/graphic style can share a name with a paragraph style.
    ///
    /// `style:writing-mode` (docx's `w:bidi` equivalent) — only the literal value `"rl-tb"`
    /// (right-to-left, top-to-bottom, the value Writer's own toggle produces) reads as RTL; every
    /// other value (`lr-tb`, `tb-rl`, `page`, …) reads as an EXPLICIT "not RTL" (`false`, not
    /// unspecified — see `resolveParagraphStyle`'s `have.rtl` guard, which is why this is `Bool?` and
    /// not folded into "absent = false").
    ///
    /// `fo:text-align`/`style:tab-stops` are this sprint's own additions — read straight off
    /// `style:paragraph-properties`, the same element `style:writing-mode` already lives on.
    // swift: OdtReader.parseParagraphStyleDecls
    fn parse_paragraph_style_decls(root: &Ref<XMLNode>) -> std::collections::HashMap<String, ParagraphStyleDecl> {
        let mut map: std::collections::HashMap<String, ParagraphStyleDecl> = std::collections::HashMap::new();
        for style_node in XMLNode::all_descendants(root, "style:style") {
            let attrs = XMLNode::attributes(&style_node);
            if attrs.get("style:family").map(String::as_str) != Some("paragraph") { continue; }
            let Some(name) = attrs.get("style:name").cloned() else { continue };
            let mut decl = ParagraphStyleDecl::default();
            decl.parent = attrs.get("style:parent-style-name").cloned();
            if let Some(level) = attrs.get("style:default-outline-level").and_then(|s| s.parse::<i32>().ok()) {
                decl.outline_level = Some(level);
            }
            // A PARAGRAPH-family style may carry run properties too, and for a heading that is where
            // its weight almost always lives — `Heading_20_1` declares `fo:font-weight="bold"` on its
            // own `style:text-properties`, not on any text-family style. Reading only the text family
            // (`parseTextStyleDecls`, which filters `style:family == "text"`) therefore reported every
            // such heading as not bold. Measured on this repo's own fixtures: 32 heading characters
            // across notes.odt / embed.odt / giant-table.odt render a weight lighter than LibreOffice
            // draws them. Exactly the gap `DocxReader.resolvedBold` closes on the other side.
            if let Some(text_props) = XMLNode::child(&style_node, "style:text-properties") {
                let text_props_attrs = XMLNode::attributes(&text_props);
                if let Some(weight) = text_props_attrs.get("fo:font-weight") { decl.bold = Some(weight == "bold"); }
                if let Some(posture) = text_props_attrs.get("fo:font-style") { decl.italic = Some(posture == "italic"); }
            }
            if let Some(props) = XMLNode::child(&style_node, "style:paragraph-properties") {
                let props_attrs = XMLNode::attributes(&props);
                if let Some(mode) = props_attrs.get("style:writing-mode") { decl.rtl = Some(mode == "rl-tb"); }
                decl.alignment_raw = props_attrs.get("fo:text-align").cloned();
                if let Some(tab_stops_node) = XMLNode::child(&props, "style:tab-stops") {
                    decl.tab_stops = XMLNode::children(&tab_stops_node).into_iter()
                        .filter(|c| XMLNode::name(c) == "style:tab-stop")
                        .filter_map(|stop| {
                            let stop_attrs = XMLNode::attributes(&stop);
                            let pos = stop_attrs.get("style:position").and_then(|s| Self::parse_length(s))?;
                            // ODF `style:type` (default `left`) → the same `TabAlignment` docx maps from
                            // `w:val`; `char` is ODF's decimal-style stop. A right/decimal stop is what a
                            // TOC page number or a right-aligned column rides — dropping it (the old
                            // "position only" behaviour) rendered every such tab left-aligned.
                            let alignment = match stop_attrs.get("style:type").map(String::as_str) {
                                Some("center") => TabAlignment::Center,
                                Some("right") => TabAlignment::Right,
                                Some("char") => TabAlignment::Decimal,
                                _ => TabAlignment::Left,
                            };
                            // ODF states the leader as its fill character (`style:leader-text`) and/or a
                            // style keyword (`style:leader-style="dotted"`); map both onto `TabLeader`.
                            let leader = match stop_attrs.get("style:leader-text").map(String::as_str) {
                                Some(".") => TabLeader::Dot,
                                Some("_") => TabLeader::Underscore,
                                Some("-") | Some("\u{2010}") => TabLeader::Hyphen,
                                _ => if stop_attrs.get("style:leader-style").map(String::as_str) == Some("dotted") { TabLeader::Dot } else { TabLeader::None },
                            };
                            Some(TabStop { position: pos, alignment, leader })
                        })
                        .collect();
                }
                // P4 — spacing/indent/line-height/shading/border, straight off this SAME element.
                decl.spacing_before = props_attrs.get("fo:margin-top").and_then(|s| Self::parse_length(s));
                decl.spacing_after = props_attrs.get("fo:margin-bottom").and_then(|s| Self::parse_length(s));
                decl.indent_start = props_attrs.get("fo:margin-left").and_then(|s| Self::parse_length(s));
                decl.indent_end = props_attrs.get("fo:margin-right").and_then(|s| Self::parse_length(s));
                // ODF's negative `fo:text-indent` IS its own hanging-indent spelling (ODF 1.3
                // §20.271) — a POSITIVE value pushes the first line further in, a NEGATIVE one pulls
                // it back out (a hanging indent), mirrored onto `ParagraphFormat`'s own mutually
                // exclusive `firstLineIndent`/`hangingIndent` pair exactly as docx's `w:ind/
                // @w:firstLine`/`@w:hanging` already are.
                if let Some(value) = props_attrs.get("fo:text-indent").and_then(|s| Self::parse_length(s)) {
                    if value > 0.0 { decl.first_line_indent = Some(value); } else { decl.hanging_indent = Some(-value); }
                }
                // `fo:line-height` is EITHER a percentage (relative to the line's own font size, ODF's
                // `w:lineRule="auto"` equivalent) OR an absolute length (`w:lineRule="exact"`
                // equivalent) — `"normal"` and anything unparseable both mean "unspecified", never a
                // literal `1.0`. `style:line-height-at-least` (`w:lineRule="atLeast"` equivalent) is
                // read only when `fo:line-height` itself is absent — ODF documents state at most one
                // of the two on a given paragraph-properties element.
                if let Some(raw) = props_attrs.get("fo:line-height") {
                    decl.line_height = Self::parse_odf_line_height(raw);
                } else if let Some(value) = props_attrs.get("style:line-height-at-least").and_then(|s| Self::parse_length(s)) {
                    decl.line_height = Some(LineHeight::AtLeast(value));
                }
                // PARAGRAPH shading — `style:paragraph-properties/@fo:background-color` — is a
                // DIFFERENT attribute occurrence than the one `parseTextStyleDecls` reads off
                // `style:text-properties` (that one becomes `Span.highlightColor`, a RUN highlight).
                // Both happen to share the same attribute NAME because ODF reuses `fo:background-
                // color` across several property elements; which one this is is decided entirely by
                // which properties element it was found on, not by anything in this function.
                if let Some(bg) = props_attrs.get("fo:background-color") { decl.shading = Self::parse_odf_color(bg); }
                let border = Self::parse_odf_border(&props);
                decl.border_color = border.0;
                decl.border_width = border.1;
                // `style:contextual-spacing` (ODF's `w:contextualSpacing`): a plain boolean toggle —
                // only the literal `"true"` turns it on; its ABSENCE stays `nil` (cascade climbs), and
                // any other value reads as an explicit `false` (this level said "no", stop climbing).
                if let Some(cs) = props_attrs.get("style:contextual-spacing") { decl.contextual_spacing = Some(cs == "true"); }
            }
            map.insert(name, decl);
        }
        map
    }

    /// `fo:line-height`'s two legal shapes (ODF 1.3 §20.191): a PERCENTAGE, relative to the line's
    /// own font size (`"150%"` → `LineHeight.multiple(1.5)`), or an absolute LENGTH (`"18pt"` →
    /// `LineHeight.exact(18)`). `"normal"` (the explicit "no override" keyword) and anything this
    /// helper cannot parse both return `nil` — unspecified, never a fabricated `1.0`.
    // swift: OdtReader.parseODFLineHeight
    fn parse_odf_line_height(raw: &str) -> Option<LineHeight> {
        if let Some(stripped) = raw.strip_suffix('%') {
            let percent: f64 = stripped.parse().ok()?;
            return Some(LineHeight::Multiple(CGFloat::from(percent / 100.0)));
        }
        let points = Self::parse_length(raw)?;
        Some(LineHeight::Exact(points))
    }

    /// Resolves one paragraph style's `style:parent-style-name` chain — same nearest-declaration-wins,
    /// cycle-guarded walk `resolveTextStyle` uses, just over this family's own four fields. `rtl` is
    /// resolved BEFORE `alignmentRaw` is turned into a real `NSTextAlignment`, because a `"start"`/
    /// `"end"` value can only be read against a writing direction once one is known — `resolveAlignment`
    /// (see below) is what does that conversion, called once here after the walk finishes rather than
    /// per-level during it, so it always sees the CHAIN's final resolved `rtl`, not one ancestor's own.
    // swift: OdtReader.resolveParagraphStyle
    fn resolve_paragraph_style(
        style_name: &str, decls: &std::collections::HashMap<String, ParagraphStyleDecl>,
    ) -> ResolvedParagraphStyle {
        let mut result = ResolvedParagraphStyle::default();
        let mut alignment_raw: Option<String> = None;
        let mut have = HaveParagraphFlags::default();
        let mut current_name: Option<String> = Some(style_name.to_string());
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        while let Some(name) = current_name.clone() {
            if visited.contains(&name) { break; }
            visited.insert(name.clone());
            let Some(decl) = decls.get(&name) else { break };
            if !have.outline { if let Some(v) = decl.outline_level { result.outline_level = Some(v); have.outline = true; } }
            if !have.bold { if let Some(v) = decl.bold { result.bold = Some(v); have.bold = true; } }
            if !have.italic { if let Some(v) = decl.italic { result.italic = Some(v); have.italic = true; } }
            if !have.rtl { if let Some(v) = decl.rtl { result.rtl = v; have.rtl = true; } }
            if !have.align { if let Some(v) = decl.alignment_raw.clone() { alignment_raw = Some(v); have.align = true; } }
            if !have.tabs && !decl.tab_stops.is_empty() { result.tab_stops = decl.tab_stops.clone(); have.tabs = true; }
            if !have.spacing_before { if let Some(v) = decl.spacing_before { result.format.spacing_before = Some(v); have.spacing_before = true; } }
            if !have.spacing_after { if let Some(v) = decl.spacing_after { result.format.spacing_after = Some(v); have.spacing_after = true; } }
            if !have.indent_start { if let Some(v) = decl.indent_start { result.format.indent_start = Some(v); have.indent_start = true; } }
            if !have.indent_end { if let Some(v) = decl.indent_end { result.format.indent_end = Some(v); have.indent_end = true; } }
            if !have.first_line_indent { if let Some(v) = decl.first_line_indent { result.format.first_line_indent = Some(v); have.first_line_indent = true; } }
            if !have.hanging_indent { if let Some(v) = decl.hanging_indent { result.format.hanging_indent = Some(v); have.hanging_indent = true; } }
            if !have.line_height { if let Some(v) = decl.line_height { result.format.line_height = Some(v); have.line_height = true; } }
            if !have.shading { if let Some(v) = decl.shading.clone() { result.format.shading = Some(v); have.shading = true; } }
            if !have.border_color { if let Some(v) = decl.border_color.clone() { result.format.border_color = Some(v); have.border_color = true; } }
            if !have.border_width { if let Some(v) = decl.border_width { result.format.border_width = Some(v); have.border_width = true; } }
            if !have.contextual_spacing { if let Some(v) = decl.contextual_spacing { result.format.contextual_spacing = v; have.contextual_spacing = true; } }
            current_name = decl.parent.clone();
        }
        result.alignment = Self::resolve_alignment(alignment_raw.as_deref(), result.rtl);
        result
    }

    /// `fo:text-align`'s `"start"`/`"end"` are WRITING-DIRECTION-RELATIVE (ODF 1.3 §20.339) — which
    /// edge they mean depends on the paragraph's own base direction, exactly the way CSS's
    /// `text-align: start` does. Resolving them HERE, into a real `NSTextAlignment`, rather than
    /// passing `"start"`/`"end"` through unresolved, is what lets the result WIN over `OfficeBlock`'s
    /// own `rtl`-implies-alignment default (see its doc comment: "an EXPLICIT `alignment` always
    /// wins") — `OfficeTextBuilder` only ever sees a concrete `NSTextAlignment` or `nil`, never a
    /// direction-relative keyword it would have to reinterpret itself. `left`/`right`/`center`/
    /// `justify` are direction-independent and pass through literally; an unrecognised or absent value
    /// returns `nil` (unspecified — same "absent stays unspecified" rule as everywhere else).
    // swift: OdtReader.resolveAlignment
    fn resolve_alignment(raw: Option<&str>, rtl: bool) -> Option<NSTextAlignment> {
        match raw {
            Some("left") => Some(NSTextAlignment::Left),
            Some("right") => Some(NSTextAlignment::Right),
            Some("center") | Some("centre") => Some(NSTextAlignment::Center),
            Some("justify") => Some(NSTextAlignment::Justified),
            Some("start") => Some(if rtl { NSTextAlignment::Right } else { NSTextAlignment::Left }),
            Some("end") => Some(if rtl { NSTextAlignment::Left } else { NSTextAlignment::Right }),
            _ => None,
        }
    }
}

/// Swift: the tuple-typed local `var have = (...)` inside `resolveParagraphStyle`.
// swift: OdtReader.resolveParagraphStyle
#[derive(Default)]
struct HaveParagraphFlags {
    outline: bool, bold: bool, italic: bool, rtl: bool, align: bool, tabs: bool,
    spacing_before: bool, spacing_after: bool, indent_start: bool, indent_end: bool,
    first_line_indent: bool, hanging_indent: bool, line_height: bool, shading: bool,
    border_color: bool, border_width: bool, contextual_spacing: bool,
}

// MARK: Table-cell styles — background, border (S15: previously unparsed family)

// swift: OdtReader.TableCellStyle
#[derive(Debug, Clone, Default, PartialEq)]
struct TableCellStyle {
    background_color: Option<NSColor>,
    border_color: Option<NSColor>,
    border_width: Option<CGFloat>,
    /// The four edges as ODF states them INDIVIDUALLY (`fo:border` for all four, then each
    /// `fo:border-*` overriding its own side) — the three-state model docx already used, which
    /// this reader collapsed into the single colour/width pair above. `none`/`hidden` is a
    /// SUPPRESSION, not silence, for the same reason it is in every other format: silence
    /// inherits the theme's grid, which is the rule the document asked to remove.
    edge_borders: Option<EdgeBorders>,
    vertical_alignment: Option<CellVAlign>,
    padding: Option<CGFloat>,
    /// Per-edge padding for the PAGED model (Job 1) — see `parseTableCellStyleDecls`'s own doc
    /// for how each is resolved from `fo:padding-{side}`/the `fo:padding` shorthand. `padding`
    /// above stays the single-value representative the non-paged model keeps using, unaffected.
    padding_top: Option<CGFloat>,
    padding_left: Option<CGFloat>,
    padding_bottom: Option<CGFloat>,
    padding_right: Option<CGFloat>,
}

// swift: OdtReader.TableCellStyleDecl
#[derive(Debug, Clone, Default)]
struct TableCellStyleDecl {
    background_color: Option<NSColor>,
    border_color: Option<NSColor>,
    border_width: Option<CGFloat>,
    edge_borders: Option<EdgeBorders>,
    vertical_alignment: Option<CellVAlign>,
    padding: Option<CGFloat>,
    padding_top: Option<CGFloat>,
    padding_left: Option<CGFloat>,
    padding_bottom: Option<CGFloat>,
    padding_right: Option<CGFloat>,
    parent: Option<String>,
}

impl OdtReader {
    /// `style:family="table-cell"` — one of the two families `oss-delta-odt.md`'s audit found this
    /// reader never parsed AT ALL before this sprint (the other is `table-column`, just below). Reads
    /// straight onto `Cell.backgroundColor`/`borderColor`/`borderWidth` (`OfficeBlock.swift`'s own
    /// fields, unused by this reader until now) — see `parseODFBorder` for why only ONE side's
    /// color/width survives even though ODF can state all four independently (`Cell`'s own documented
    /// scope: one uniform border, not a four-sided model).
    // swift: OdtReader.parseTableCellStyleDecls
    fn parse_table_cell_style_decls(root: &Ref<XMLNode>) -> std::collections::HashMap<String, TableCellStyleDecl> {
        let mut map: std::collections::HashMap<String, TableCellStyleDecl> = std::collections::HashMap::new();
        for style_node in XMLNode::all_descendants(root, "style:style") {
            let attrs = XMLNode::attributes(&style_node);
            if attrs.get("style:family").map(String::as_str) != Some("table-cell") { continue; }
            let Some(name) = attrs.get("style:name").cloned() else { continue };
            let mut decl = TableCellStyleDecl::default();
            decl.parent = attrs.get("style:parent-style-name").cloned();
            if let Some(props) = XMLNode::child(&style_node, "style:table-cell-properties") {
                let props_attrs = XMLNode::attributes(&props);
                if let Some(bg) = props_attrs.get("fo:background-color") { decl.background_color = Self::parse_odf_color(bg); }
                let border = Self::parse_odf_border(&props);
                decl.border_color = border.0;
                decl.border_width = border.1;
                decl.edge_borders = Self::parse_odf_edge_borders(&props);
                // ODF `style:vertical-align` (top/middle/bottom/automatic) → `CellVAlign`; `middle`
                // is the odt spelling of docx's `center`, `automatic` means "no explicit alignment"
                // and is left nil (TableBlockBuilder's own top default stands).
                decl.vertical_alignment = match props_attrs.get("style:vertical-align").map(String::as_str) {
                    Some("top") => Some(CellVAlign::Top),
                    Some("middle") => Some(CellVAlign::Center),
                    Some("bottom") => Some(CellVAlign::Bottom),
                    _ => None,
                };
                // ODF `fo:padding` is the uniform cell inset; the per-side `fo:padding-left` etc. are a
                // fallback (Cell.padding is one uniform value, so take the first side that names one).
                decl.padding = props_attrs.get("fo:padding").and_then(|s| Self::parse_length(s))
                    .or_else(|| props_attrs.get("fo:padding-left").and_then(|s| Self::parse_length(s)))
                    .or_else(|| props_attrs.get("fo:padding-top").and_then(|s| Self::parse_length(s)));
                // PER-EDGE, for the PAGED model (Job 1): ODF's own shorthand-then-override precedence
                // — a specific `fo:padding-{side}` wins, else the uniform `fo:padding` shorthand
                // applies to that side, else the edge is genuinely undeclared (`nil`, carried through
                // rather than defaulted here — see `Cell.edgePadding`'s own doc for why a genuine
                // zero must stay distinguishable from silence).
                let uniform = props_attrs.get("fo:padding").and_then(|s| Self::parse_length(s));
                decl.padding_top = props_attrs.get("fo:padding-top").and_then(|s| Self::parse_length(s)).or(uniform);
                decl.padding_left = props_attrs.get("fo:padding-left").and_then(|s| Self::parse_length(s)).or(uniform);
                decl.padding_bottom = props_attrs.get("fo:padding-bottom").and_then(|s| Self::parse_length(s)).or(uniform);
                decl.padding_right = props_attrs.get("fo:padding-right").and_then(|s| Self::parse_length(s)).or(uniform);
            }
            map.insert(name, decl);
        }
        map
    }

    /// Same nearest-declaration-wins, cycle-guarded walk as `resolveTextStyle`/`resolveParagraphStyle`
    /// — a table-cell style basing itself on another via `style:parent-style-name` is legal ODF even
    /// though real documents rarely bother, so the mechanism is implemented for real rather than
    /// assumed unreachable.
    // swift: OdtReader.resolveTableCellStyle
    fn resolve_table_cell_style(
        style_name: &str, decls: &std::collections::HashMap<String, TableCellStyleDecl>,
    ) -> TableCellStyle {
        let mut result = TableCellStyle::default();
        let mut have = HaveTableCellFlags::default();
        let mut current_name: Option<String> = Some(style_name.to_string());
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        while let Some(name) = current_name.clone() {
            if visited.contains(&name) { break; }
            visited.insert(name.clone());
            let Some(decl) = decls.get(&name) else { break };
            if !have.bg { if let Some(v) = decl.background_color.clone() { result.background_color = Some(v); have.bg = true; } }
            if !have.border_color { if let Some(v) = decl.border_color.clone() { result.border_color = Some(v); have.border_color = true; } }
            if !have.border_width { if let Some(v) = decl.border_width { result.border_width = Some(v); have.border_width = true; } }
            // The per-edge set is taken WHOLE from the nearest style that states any edge — merging
            // one ancestor's top with another's left would invent a border nobody declared, and ODF's
            // own cascade replaces the border declaration rather than blending it.
            if !have.edges { if let Some(v) = decl.edge_borders.clone() { result.edge_borders = Some(v); have.edges = true; } }
            if !have.valign { if let Some(v) = decl.vertical_alignment { result.vertical_alignment = Some(v); have.valign = true; } }
            if !have.padding { if let Some(v) = decl.padding { result.padding = Some(v); have.padding = true; } }
            if !have.pad_top { if let Some(v) = decl.padding_top { result.padding_top = Some(v); have.pad_top = true; } }
            if !have.pad_left { if let Some(v) = decl.padding_left { result.padding_left = Some(v); have.pad_left = true; } }
            if !have.pad_bottom { if let Some(v) = decl.padding_bottom { result.padding_bottom = Some(v); have.pad_bottom = true; } }
            if !have.pad_right { if let Some(v) = decl.padding_right { result.padding_right = Some(v); have.pad_right = true; } }
            current_name = decl.parent.clone();
        }
        result
    }
}

/// Swift: the tuple-typed local `var have = (...)` inside `resolveTableCellStyle`.
// swift: OdtReader.resolveTableCellStyle
#[derive(Default)]
struct HaveTableCellFlags {
    bg: bool, border_color: bool, border_width: bool, valign: bool, padding: bool,
    pad_top: bool, pad_left: bool, pad_bottom: bool, pad_right: bool, edges: bool,
}

// MARK: Table-column styles — declared width (S15: previously unparsed family AND element)

// swift: OdtReader.TableColumnStyle
#[derive(Debug, Clone, Default, PartialEq)]
struct TableColumnStyle {
    width: Option<CGFloat>,
    /// P4 — `style:rel-column-width` (`"3*"` — a PROPORTION, not a length: ODF 1.3 §20.212). Kept
    /// as the bare number (`3`, not `3.0` points of anything) — `resolvedGridColumnWidths` only
    /// ever needs the RATIO between columns, and `TableBlockBuilder` normalizes any
    /// `OfficeBlock.table.columnWidths` array to a percentage of its own sum, so a proportion unit
    /// and a points unit are interchangeable inputs to that same normalization as long as a given
    /// table doesn't mix the two (real ODT documents state one or the other for every column, never
    /// both within the same table).
    rel_width: Option<CGFloat>,
}

// swift: OdtReader.TableColumnStyleDecl
#[derive(Debug, Clone, Default)]
struct TableColumnStyleDecl {
    width: Option<CGFloat>,
    rel_width: Option<CGFloat>,
    parent: Option<String>,
}

impl OdtReader {
    /// `style:family="table-column"` — `oss-delta-odt.md`'s audit found `table:table-column` itself
    /// (the ELEMENT, not just this style family) referenced nowhere in this file at all before this
    /// sprint; `parseColumnWidths` (below, called from `parseTable`) is the new caller that walks the
    /// element, this function resolves the style it points at.
    // swift: OdtReader.parseTableColumnStyleDecls
    fn parse_table_column_style_decls(root: &Ref<XMLNode>) -> std::collections::HashMap<String, TableColumnStyleDecl> {
        let mut map: std::collections::HashMap<String, TableColumnStyleDecl> = std::collections::HashMap::new();
        for style_node in XMLNode::all_descendants(root, "style:style") {
            let attrs = XMLNode::attributes(&style_node);
            if attrs.get("style:family").map(String::as_str) != Some("table-column") { continue; }
            let Some(name) = attrs.get("style:name").cloned() else { continue };
            let mut decl = TableColumnStyleDecl::default();
            decl.parent = attrs.get("style:parent-style-name").cloned();
            if let Some(props) = XMLNode::child(&style_node, "style:table-column-properties") {
                let props_attrs = XMLNode::attributes(&props);
                if let Some(width) = props_attrs.get("style:column-width") { decl.width = Self::parse_length(width); }
                // `"<number>*"` — the trailing `*` is the datatype's own marker (ODF 1.3 §18.3.31
                // `styleRelativeWidth`), not decoration; a value with no `*` suffix is not this
                // datatype at all and is left unset rather than guessed at.
                if let Some(rel) = props_attrs.get("style:rel-column-width") {
                    if let Some(stripped) = rel.strip_suffix('*') {
                        if let Ok(number) = stripped.parse::<f64>() {
                            decl.rel_width = Some(CGFloat::from(number));
                        }
                    }
                }
            }
            map.insert(name, decl);
        }
        map
    }

    // swift: OdtReader.resolveTableColumnStyle
    fn resolve_table_column_style(
        style_name: &str, decls: &std::collections::HashMap<String, TableColumnStyleDecl>,
    ) -> TableColumnStyle {
        let mut result = TableColumnStyle::default();
        let mut current_name: Option<String> = Some(style_name.to_string());
        let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
        while let Some(name) = current_name.clone() {
            if visited.contains(&name) { break; }
            visited.insert(name.clone());
            let Some(decl) = decls.get(&name) else { break };
            if result.width.is_none() { if let Some(v) = decl.width { result.width = Some(v); } }
            if result.rel_width.is_none() { if let Some(v) = decl.rel_width { result.rel_width = Some(v); } }
            current_name = decl.parent.clone();
        }
        result
    }

    // MARK: Document default body size — style:default-style, family "paragraph"

    /// `style:default-style` (family `"paragraph"`) is ODF's document-wide fallback — every paragraph
    /// this reader never gave its own explicit size ultimately falls back to it. Deliberately its own
    /// small function rather than folded into `parseParagraphStyleDecls`: `style:default-style` is a
    /// SIBLING element of `style:style`, not a `style:style` node itself (no `style:family` attribute,
    /// no name, exactly one per document), so it needs its own, narrower search.
    // swift: OdtReader.parseDefaultParagraphFontSize
    fn parse_default_paragraph_font_size(root: &Ref<XMLNode>) -> Option<CGFloat> {
        let default_style = XMLNode::all_descendants(root, "style:default-style").into_iter()
            .find(|n| XMLNode::attributes(n).get("style:family").map(String::as_str) == Some("paragraph"))?;
        let size_string = XMLNode::child(&default_style, "style:text-properties")
            .and_then(|p| XMLNode::attributes(&p).get("fo:font-size").cloned())?;
        Self::parse_length(&size_string)
    }
}

impl OdtReader {
    // MARK: content.xml — office:text → blocks

    /// Guards `parseBody`'s generic recursion (see the `default` case below) against a hostile
    /// file nesting wrappers arbitrarily deep — a real ODF document never approaches this, so the
    /// cap only ever bites on pathological input, where dropping the excess is the safe outcome.
    // swift: OdtReader.parseBody
    const MAX_BODY_RECURSION_DEPTH: i32 = 64;

    // swift: OdtReader.parseBody
    fn parse_body(
        text: &Ref<XMLNode>, styles: &ParsedStyles, archive: &ZipArchive, notes: &NoteCollector, depth: i32,
    ) -> Vec<OfficeBlock> {
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        for child in XMLNode::children(text) {
            let attrs = XMLNode::attributes(&child);
            match XMLNode::name(&child).as_str() {
                "text:h" => {
                    let raw_level = attrs.get("text:outline-level").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1);
                    let level = raw_level.max(1).min(6);
                    let resolved = Self::resolved_style(attrs.get("text:style-name").map(String::as_str), styles);
                    let resolved2 = resolved.clone();
                    blocks.extend(Self::paragraph_like_blocks(
                        &child,
                        Box::new(move |spans| OfficeBlock::Heading {
                            level: level as i64, spans, rtl: resolved2.rtl, alignment: resolved2.alignment.clone(),
                            tab_stops: resolved2.tab_stops.clone(), format: resolved2.format.clone(), format_ref: None,
                        }),
                        styles, archive, notes,
                    ));
                }
                "text:p" => {
                    // A `text:p` whose OWN paragraph style declares `style:default-outline-level` is a
                    // heading too — Writer produces this shape routinely — resolved on the same 1-based
                    // scale `text:outline-level` already uses, so it's clamped identically.
                    let style_name = attrs.get("text:style-name").map(String::as_str);
                    let resolved = Self::resolved_style(style_name, styles);
                    if let Some(raw_level) = resolved.outline_level {
                        let level = raw_level.max(1).min(6);
                        let resolved2 = resolved.clone();
                        blocks.extend(Self::paragraph_like_blocks(
                            &child,
                            Box::new(move |spans| OfficeBlock::Heading {
                                level: level as i64, spans, rtl: resolved2.rtl, alignment: resolved2.alignment.clone(),
                                tab_stops: resolved2.tab_stops.clone(), format: resolved2.format.clone(), format_ref: None,
                            }),
                            styles, archive, notes,
                        ));
                    } else {
                        let resolved2 = resolved.clone();
                        blocks.extend(Self::paragraph_like_blocks(
                            &child,
                            Box::new(move |spans| OfficeBlock::Paragraph {
                                spans, rtl: resolved2.rtl, alignment: resolved2.alignment.clone(),
                                tab_stops: resolved2.tab_stops.clone(), format: resolved2.format.clone(), format_ref: None,
                            }),
                            styles, archive, notes,
                        ));
                    }
                }
                "text:hidden-paragraph" => {
                    // Verified against OASIS ODF 1.3 schema (element text:hidden-paragraph):
                    // text:condition is REQUIRED, text:is-hidden is OPTIONAL (text:boolean). Content
                    // model is mixed content (same as text:p — spans directly, no wrapped text:p
                    // child). We deliberately do not evaluate text:condition (see below).
                    // ODF's PARAGRAPH-level "show under a condition" field — same content model as
                    // `text:p` (spec: same child elements). `text:is-hidden` is the file's OWN
                    // LAST-COMPUTED display state; this reader never evaluates `text:condition`
                    // itself (that would need the variable/field engine this project doesn't
                    // implement). Hide ONLY on an explicit "true" — an absent or "false" attribute
                    // SHOWS the content, per this project's governing rule that losing the author's
                    // words is the unforgivable failure, an unknown state is not grounds to hide.
                    if attrs.get("text:is-hidden").map(String::as_str) != Some("true") {
                        let resolved = Self::resolved_style(attrs.get("text:style-name").map(String::as_str), styles);
                        blocks.extend(Self::paragraph_like_blocks(
                            &child,
                            Box::new(move |spans| OfficeBlock::Paragraph {
                                spans, rtl: resolved.rtl, alignment: resolved.alignment.clone(),
                                tab_stops: resolved.tab_stops.clone(), format: resolved.format.clone(), format_ref: None,
                            }),
                            styles, archive, notes,
                        ));
                    }
                }
                "text:numbered-paragraph" => {
                    // A single numbered/lettered paragraph carrying its OWN `text:list-id`/
                    // `text:style-name`/`text:list-level` directly, with no enclosing `text:list`/
                    // `text:list-item` pair (legal clause templates, DOCX→ODT converters). Its
                    // `text:style-name` names a LIST style exactly like `text:list`'s own attribute —
                    // reuse `isOrdered` rather than re-deriving the ordered/bullet rule. ODF's
                    // `text:list-level` is 1-based; `OfficeBlock.listItem.level` is 0-based.
                    let style_name = attrs.get("text:style-name").cloned();
                    let raw_level = attrs.get("text:list-level").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1);
                    let level = (raw_level - 1).max(0);
                    let ordered = Self::is_ordered(style_name.as_deref(), level, &styles.list_styles);
                    for item in XMLNode::children(&child).into_iter().filter(|i| XMLNode::name(i) == "text:p") {
                        // The item's OWN `text:p` style-name (paragraph formatting), not the enclosing
                        // `text:numbered-paragraph`'s (which names its LIST style, a different lookup
                        // table entirely).
                        let item_attrs = XMLNode::attributes(&item);
                        let resolved = Self::resolved_style(item_attrs.get("text:style-name").map(String::as_str), styles);
                        blocks.extend(Self::paragraph_like_blocks(
                            &item,
                            Box::new(move |spans| OfficeBlock::ListItem {
                                level: level as i64, ordered, spans, marker: None, rtl: resolved.rtl,
                                alignment: resolved.alignment.clone(), tab_stops: resolved.tab_stops.clone(),
                                format: resolved.format.clone(), numbering: None,
                                format_ref: None,
                            }),
                            styles, archive, notes,
                        ));
                    }
                }
                "text:list" => {
                    blocks.extend(Self::parse_list(&child, 0, None, styles, archive, notes));
                }
                "table:table" => {
                    blocks.push(Self::parse_table(&child, styles, archive, notes));
                }
                "office:annotation" | "text:tracked-changes" | "text:sequence-decls" | "text:variable-decls"
                | "text:user-field-decls" | "office:forms" | "office:scripts" => {
                    // Deliberate exclusions — dropped ON PURPOSE, not by omission (see the permissive
                    // `default` below):
                    //  - `office:annotation`: a comment standing directly under `office:text` rather
                    //    than inline inside a `text:p` — not the shape a real ODF producer writes (an
                    //    annotation is paragraph-content per the OASIS schema), so this is a malformed-
                    //    document guard, not the normal path. Real comments ARE captured — see the
                    //    `office:annotation`/`office:annotation-end` cases in `collectSpans`'s inline
                    //    walk (P6a) — this exclusion only drops the shape that has no enclosing
                    //    paragraph for a comment's spans to anchor into.
                    //  - `text:tracked-changes`: the DELETED-content stash. A deletion is a single,
                    //    empty `<text:change/>` point marker inline (walked as a no-op by
                    //    `collectSpans`'s permissive default), while its actual payload lives in a
                    //    `<text:changed-region>` inside THIS sibling element — never inline between two
                    //    markers. Excluding it is what keeps a tracked deletion from rendering as live
                    //    text; now that the switch below recurses into everything else, this exclusion
                    //    is LOAD-BEARING rather than an accident of a closed switch.
                    //  - `text:sequence-decls` / `text:variable-decls` / `text:user-field-decls`:
                    //    numbering/variable SCHEME declarations, no visible body text of their own.
                    //  - `office:forms` / `office:scripts`: form-control / macro definitions, not
                    //    document prose.
                    continue;
                }
                _ => {
                    // Any other wrapper this switch doesn't specifically name — `text:section`, the
                    // seven index/TOC elements (`text:table-of-content`, `text:illustration-index`,
                    // `text:table-index`, `text:object-index`, `text:user-index`,
                    // `text:alphabetical-index`, `text:bibliography`) and their `*-source`/`*-body`
                    // children, `text:page-sequence`/`text:page`, or a future ODF wrapper this reader
                    // has never seen — is DESCENDED INTO rather than dropped whole, so a document built
                    // entirely from templated sections/TOCs isn't silently emptied. A `*-source`
                    // config child recurses too but contributes nothing (it has no `text:p`/`text:h`/
                    // `text:list`/`table:table` children of its own), which is harmless, not a special
                    // case to guard against.
                    if depth >= Self::MAX_BODY_RECURSION_DEPTH { continue; }
                    blocks.extend(Self::parse_body(&child, styles, archive, notes, depth + 1));
                }
            }
        }
        blocks
    }

    /// One paragraph-style lookup, resolved — the same `ResolvedParagraphStyle` every `text:h`/
    /// `text:p`/`text:hidden-paragraph`/`text:numbered-paragraph`/list-item case above needs, pulled
    /// into one place so each case reads `resolved.rtl`/`resolved.alignment`/`resolved.tabStops`/
    /// `resolved.outlineLevel` instead of four separate dictionary lookups (the shape every one of
    /// those call sites had before this sprint, ONE field at a time). An absent/unresolvable style
    /// name returns the all-`nil`/`false`/empty default, exactly what the four separate lookups
    /// already returned for the same input.
    // swift: OdtReader.resolvedStyle
    fn resolved_style(style_name: Option<&str>, styles: &ParsedStyles) -> ResolvedParagraphStyle {
        let Some(style_name) = style_name else { return ResolvedParagraphStyle::default() };
        styles.paragraph_styles.get(style_name).cloned().unwrap_or_default()
    }

    /// A heading or paragraph normally contributes exactly one text block, but one carrying an
    /// image contributes that text block (if it has any spans) FOLLOWED BY the image block(s), in
    /// source order — mirroring `DocxReader.parseParagraph`. A paragraph that is ONLY a picture
    /// (no spans at all — LibreOffice puts an image-only paragraph with no other text) contributes
    /// no empty text block, so callers never see a phantom `.paragraph(spans: [])` standing in for
    /// a picture.
    // swift: OdtReader.paragraphLikeBlocks
    fn paragraph_like_blocks(
        node: &Ref<XMLNode>, make: Box<dyn Fn(Vec<Span>) -> OfficeBlock>,
        styles: &ParsedStyles, archive: &ZipArchive, notes: &NoteCollector,
    ) -> Vec<OfficeBlock> {
        // The paragraph style's own weight/posture is the BASE every span starts from — a heading's
        // bold lives there, not on a text-family style (see `ParagraphStyleDecl.bold`). A run's own
        // `text:style-name` still overrides it, because `collectSpans` replaces the whole style when
        // it meets one.
        let attrs = XMLNode::attributes(node);
        let para_style = Self::resolved_style(attrs.get("text:style-name").map(String::as_str), styles);
        let mut base = TextStyle::default();
        if let Some(bold) = para_style.bold { base.bold = bold; }
        if let Some(italic) = para_style.italic { base.italic = italic; }
        let spans = Self::collect_spans(node, &base, &styles.text_styles, notes);
        // A figure inherits its paragraph's alignment (see `OfficeBlock.image`'s `alignment`), read
        // back through the SAME `resolvedStyle` lookup the caller used to build `make` — so the
        // picture and the text around it can never disagree about how this paragraph is aligned.
        // Resolved here rather than threaded through all ten call sites, which would be ten chances
        // for one of them to pass something slightly different.
        let paragraph_alignment = Self::resolved_style(attrs.get("text:style-name").map(String::as_str), styles).alignment;
        let images: Vec<OfficeBlock> = Self::collect_images(node, archive).into_iter()
            .map(|b| b.aligning_graphic(paragraph_alignment.clone()))
            .collect();
        let text_boxes = Self::collect_text_box_blocks(node, &styles.text_styles, notes);
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        if !(spans.is_empty() && !(images.is_empty() && text_boxes.is_empty())) {
            blocks.push(make(spans));
        }
        blocks.extend(images);
        blocks.extend(text_boxes);
        blocks
    }

    // MARK: Lists — text:list > text:list-item > text:p, nested by nesting text:list

    /// Walks one list's items. Each item may hold ordinary paragraph content (`text:p`) and/or a
    /// nested list (`text:list`, recursing at `level + 1`) — ODF allows either or both. A nested
    /// list with no `text:style-name` of its own inherits the ENCLOSING list's style name (Writer
    /// commonly leaves it unstated for a plain continuation), rather than falling straight to
    /// unordered, which would wrongly flip a nested bullet under a numbered list to a bullet purely
    /// because the inner element omitted a redundant attribute.
    // swift: OdtReader.parseList
    fn parse_list(
        list: &Ref<XMLNode>, level: i32, inherited_style_name: Option<&str>,
        styles: &ParsedStyles, archive: &ZipArchive, notes: &NoteCollector,
    ) -> Vec<OfficeBlock> {
        let attrs = XMLNode::attributes(list);
        let style_name = attrs.get("text:style-name").cloned().or_else(|| inherited_style_name.map(String::from));
        let ordered = Self::is_ordered(style_name.as_deref(), level, &styles.list_styles);
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        for item in XMLNode::children(list).into_iter().filter(|i| XMLNode::name(i) == "text:list-item") {
            for child in XMLNode::children(&item) {
                match XMLNode::name(&child).as_str() {
                    "text:p" => {
                        // The item's OWN paragraph style-name, not the enclosing LIST's — same
                        // distinction `text:numbered-paragraph` above draws.
                        let child_attrs = XMLNode::attributes(&child);
                        let resolved = Self::resolved_style(child_attrs.get("text:style-name").map(String::as_str), styles);
                        blocks.extend(Self::paragraph_like_blocks(
                            &child,
                            Box::new(move |spans| OfficeBlock::ListItem {
                                level: level as i64, ordered, spans, marker: None, rtl: resolved.rtl,
                                alignment: resolved.alignment.clone(), tab_stops: resolved.tab_stops.clone(),
                                format: resolved.format.clone(), numbering: None,
                                format_ref: None,
                            }),
                            styles, archive, notes,
                        ));
                    }
                    "text:list" => {
                        blocks.extend(Self::parse_list(&child, level + 1, style_name.as_deref(), styles, archive, notes));
                    }
                    _ => continue,
                }
            }
        }
        blocks
    }
}

impl OdtReader {
    // MARK: Tables — table:table > table:table-row > table:table-cell

    /// `table:table-header-rows` is a WRAPPER element around the leading header rows, not a
    /// per-row flag the way docx's `w:tblHeader` is — its absence (this fixture has none) means
    /// `headerRows == 0`, never a guess of 1 (`OfficeBlock.table`'s own contract: an un-styled
    /// table is a faithful rendering, a wrongly-bolded row is not).
    // swift: OdtReader.parseTable
    fn parse_table(table: &Ref<XMLNode>, styles: &ParsedStyles, archive: &ZipArchive, notes: &NoteCollector) -> OfficeBlock {
        let column_widths = Self::parse_column_widths(table, &styles.table_column_styles);
        let column_default_cell_styles = Self::parse_column_default_cell_styles(table, &styles.table_cell_styles);
        let mut rows: Vec<Vec<Cell>> = Vec::new();
        let mut header_rows = 0usize;
        for child in XMLNode::children(table) {
            match XMLNode::name(&child).as_str() {
                "table:table-header-rows" => {
                    let expanded: Vec<Vec<Cell>> = XMLNode::children(&child).into_iter()
                        .filter(|r| XMLNode::name(r) == "table:table-row")
                        .flat_map(|r| Self::expand_row(&r, &column_widths, &column_default_cell_styles, styles, archive, notes))
                        .collect();
                    header_rows += expanded.len();
                    rows.extend(expanded);
                }
                "table:table-row" => {
                    rows.extend(Self::expand_row(&child, &column_widths, &column_default_cell_styles, styles, archive, notes));
                }
                _ => continue,
            }
        }
        OfficeBlock::Table {
            rows, header_rows: header_rows as i64,
            column_widths: Self::resolved_grid_column_widths(table, &styles.table_column_styles),
            format: TableFormat::default(),
        }
    }

    /// P4 — `OfficeBlock.table`'s own `columnWidths: [CGFloat]` (the P3 field docx's `w:tblGrid`
    /// already feeds — see `DocxReader.tableGridColumnWidths`): the table's GRID ratios, fed to
    /// `TableBlockBuilder` to fill the table's width proportionally rather than falling back to its
    /// equal-ish auto layout. Reads EVERY `table:table-column` in source order (repeats expanded, the
    /// same `table:number-columns-repeated` handling `parseColumnWidths` above already does), preferring
    /// a column's `relWidth` (ODF's own preferred, proportion-native form) over its absolute `width`
    /// when a style states both. A malformed/unstyled column anywhere in the grid — same
    /// "never partially apply an untrustworthy grid" posture `tableGridColumnWidths` documents — makes
    /// the WHOLE grid unusable, returned as `[]` (`TableBlockBuilder`'s existing auto layout, unchanged
    /// — this is exactly what a table with no `table:table-column` elements at all already returns).
    // swift: OdtReader.resolvedGridColumnWidths
    fn resolved_grid_column_widths(table: &Ref<XMLNode>, table_column_styles: &std::collections::HashMap<String, TableColumnStyle>) -> Vec<CGFloat> {
        let mut widths: Vec<CGFloat> = Vec::new();
        for child in XMLNode::children(table).into_iter().filter(|c| XMLNode::name(c) == "table:table-column") {
            let attrs = XMLNode::attributes(&child);
            let Some(style_name) = attrs.get("table:style-name") else { return Vec::new() };
            let Some(style) = table_column_styles.get(style_name) else { return Vec::new() };
            let Some(width) = style.rel_width.or(style.width) else { return Vec::new() };
            let repeated = attrs.get("table:number-columns-repeated").and_then(|s| s.parse::<usize>().ok()).unwrap_or(1);
            widths.extend(std::iter::repeat(width).take(repeated));
        }
        widths
    }

    /// `table:table-column` — the ELEMENT `oss-delta-odt.md`'s audit found referenced nowhere in this
    /// file at all — declares one or more (via `table:number-columns-repeated`) columns' worth of
    /// declared width, IN SOURCE ORDER, as DIRECT children of `table:table` (siblings of the
    /// `table:table-row`s, not inside them). Returns one entry PER COLUMN (repeats expanded, mirroring
    /// `expandRow`'s own cell/row repeat expansion), `nil` where a column has no `table:style-name` or
    /// an unresolvable one — so the result's INDEX is a column position, directly usable by
    /// `expandRow`'s own running column counter.
    /// A `table:table-column`'s `table:default-cell-style-name` — ODF's own spelling of "the default
    /// look of cells in this column" (docx has no per-column default; it uses table-level `w:tblBorders`
    /// instead). A cell that declares NO `table:style-name` of its own inherits this column default
    /// (its borders, shading, vertical-alignment, padding) rather than falling straight to the theme
    /// default. Returned one entry PER COLUMN (repeats expanded, same as `parseColumnWidths`), `nil`
    /// where a column names no default, so the INDEX is a column position `expandRow` reads directly.
    // swift: OdtReader.parseColumnDefaultCellStyles
    fn parse_column_default_cell_styles(
        table: &Ref<XMLNode>, table_cell_styles: &std::collections::HashMap<String, TableCellStyle>,
    ) -> Vec<Option<TableCellStyle>> {
        let mut out: Vec<Option<TableCellStyle>> = Vec::new();
        for child in XMLNode::children(table).into_iter().filter(|c| XMLNode::name(c) == "table:table-column") {
            let attrs = XMLNode::attributes(&child);
            let style = attrs.get("table:default-cell-style-name").and_then(|n| table_cell_styles.get(n).cloned());
            let repeated = attrs.get("table:number-columns-repeated").and_then(|s| s.parse::<usize>().ok()).unwrap_or(1);
            out.extend(std::iter::repeat(style).take(repeated));
        }
        out
    }

    // swift: OdtReader.parseColumnWidths
    fn parse_column_widths(
        table: &Ref<XMLNode>, table_column_styles: &std::collections::HashMap<String, TableColumnStyle>,
    ) -> Vec<Option<CGFloat>> {
        let mut widths: Vec<Option<CGFloat>> = Vec::new();
        for child in XMLNode::children(table).into_iter().filter(|c| XMLNode::name(c) == "table:table-column") {
            let attrs = XMLNode::attributes(&child);
            let width = attrs.get("table:style-name").and_then(|n| table_column_styles.get(n)).and_then(|s| s.width);
            let repeated = attrs.get("table:number-columns-repeated").and_then(|s| s.parse::<usize>().ok()).unwrap_or(1);
            widths.extend(std::iter::repeat(width).take(repeated));
        }
        widths
    }

    /// ODF collapses runs of identical adjacent cells/rows into one element carrying a
    /// `table:number-columns-repeated`/`table:number-rows-repeated` count — ignoring it silently
    /// loses columns (a 5-column table where 3 empty trailing cells were collapsed into one would
    /// come back as 3 columns). Both expansions happen here, once, rather than at every caller.
    ///
    /// `table:covered-table-cell` is ODF's OWN merge convention — the opposite of docx's `vMerge`
    /// (research-odt.md §1): the ORIGIN cell of a merge carries `table:number-columns-spanned` /
    /// `table:number-rows-spanned` directly, and EVERY covered position (horizontal or vertical)
    /// gets an explicit `<table:covered-table-cell/>` placeholder in that row's own XML — there is
    /// no cross-row bookkeeping to do, each row already states its own covered positions. Dropping
    /// those placeholders (contributing zero `Cell`s) is therefore correct on its own: what's left
    /// is exactly `OfficeBlock.table`'s anchor-only shape, spans/repeats notwithstanding.
    ///
    /// `columnWidths` (this sprint's own addition) is read positionally — a running `columnIndex`
    /// starts at 0 for the row and advances past EVERY column a cell (or a dropped covered-cell)
    /// occupies, so an anchor's OWN width comes from `columnWidths[columnIndex]` at the moment it's
    /// reached, before the index advances past it. A `table:covered-table-cell` still advances the
    /// index by its own (possibly repeated) column count even though it contributes no `Cell` —
    /// skipping that would misalign every width to its right.
    // swift: OdtReader.expandRow
    fn expand_row(
        row: &Ref<XMLNode>, column_widths: &[Option<CGFloat>], column_default_cell_styles: &[Option<TableCellStyle>],
        styles: &ParsedStyles, archive: &ZipArchive, notes: &NoteCollector,
    ) -> Vec<Vec<Cell>> {
        let row_attrs = XMLNode::attributes(row);
        let row_repeat = row_attrs.get("table:number-rows-repeated").and_then(|s| s.parse::<usize>().ok()).unwrap_or(1);
        // ODF precedence for a cell with no `table:style-name` of its own: the ROW's own
        // `table:default-cell-style-name`, then the COLUMN's (resolved per-column-index below).
        let row_default_style = row_attrs.get("table:default-cell-style-name").and_then(|n| styles.table_cell_styles.get(n).cloned());
        let mut cells: Vec<Cell> = Vec::new();
        let mut column_index: usize = 0;
        for child in XMLNode::children(row) {
            let attrs = XMLNode::attributes(&child);
            match XMLNode::name(&child).as_str() {
                "table:table-cell" => {
                    let blocks = Self::collect_cell_blocks(&child, styles, archive, notes);
                    let row_span = attrs.get("table:number-rows-spanned").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1);
                    let col_span = attrs.get("table:number-columns-spanned").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1);
                    let col_repeat = attrs.get("table:number-columns-repeated").and_then(|s| s.parse::<usize>().ok()).unwrap_or(1);
                    let own_style = attrs.get("table:style-name").and_then(|n| styles.table_cell_styles.get(n).cloned());
                    // Each REPEAT instance advances the column index by exactly ONE — its own start
                    // column — never by `colSpan`: the ADDITIONAL columns a span covers are accounted
                    // for by the `table:covered-table-cell` element(s) that follow it in THIS row (see
                    // the `case` below), not by this cell's own element. Advancing by `colSpan` here
                    // would double-count those columns once more when the covered-cell(s) are reached,
                    // shifting every width to the right of a horizontal merge by one column too many
                    // (caught by `testColumnWidthAlignsCorrectlyAcrossAColumnSpan`'s own mutation check).
                    for _ in 0..col_repeat {
                        let width = column_widths.get(column_index).copied().flatten();
                        // cell's own style > row default > column default (this column index) — ODF's own
                        // cascade; the theme default in `TableBlockBuilder` remains the final fallback.
                        let column_default = column_default_cell_styles.get(column_index).cloned().flatten();
                        let cell_style = own_style.clone().or_else(|| row_default_style.clone()).or_else(|| column_default.clone());
                        let mut cell = Cell {
                            blocks: blocks.clone(), row_span: row_span as i64, col_span: col_span as i64,
                            background_color: cell_style.as_ref().and_then(|s| s.background_color.clone()),
                            border_color: cell_style.as_ref().and_then(|s| s.border_color.clone()),
                            border_width: cell_style.as_ref().and_then(|s| s.border_width),
                            edge_borders: cell_style.as_ref().and_then(|s| s.edge_borders.clone()),
                            width,
                            vertical_alignment: cell_style.as_ref().and_then(|s| s.vertical_alignment),
                            padding: cell_style.as_ref().and_then(|s| s.padding),
                            ..Default::default()
                        };
                        // PAGED model's per-edge padding (Job 1) — `nil` when the resolved style named
                        // no edge at all, so a cell with no cell-style keeps `edgePadding == nil` exactly
                        // like every other still-unpopulated field here.
                        if let Some(s) = &cell_style {
                            if s.padding_top.is_some() || s.padding_left.is_some() || s.padding_bottom.is_some() || s.padding_right.is_some() {
                                cell.edge_padding = Some(EdgePadding {
                                    top: s.padding_top, left: s.padding_left, bottom: s.padding_bottom, right: s.padding_right,
                                });
                            }
                        }
                        cells.push(cell);
                        column_index += 1;
                    }
                }
                "table:covered-table-cell" => {
                    // Contributes no `Cell` (see the doc comment above) but still occupies its own
                    // column position(s) — whether it is standing in for the REST of a horizontal span
                    // (same row as its anchor) or for a vertical span's continuation (a later row, no
                    // anchor of its own in THIS row at all), it is exactly one more column than the
                    // element itself would otherwise account for — the running index must still move
                    // past it, once per repeat.
                    let repeated = attrs.get("table:number-columns-repeated").and_then(|s| s.parse::<usize>().ok()).unwrap_or(1);
                    column_index += repeated;
                }
                _ => continue,
            }
        }
        std::iter::repeat(cells).take(row_repeat).collect()
    }

    /// A text/heading/list block with no spans at all — used only to filter a cell's OWN
    /// placeholder-empty paragraph (`<text:p/>`, the shape a genuinely blank cell always carries)
    /// out of what it contributes; an image or table block is never "empty" in this sense and
    /// always passes through. Mirrors `DocxReader.isEmptyTextBlock` exactly.
    // swift: OdtReader.isEmptyTextBlock
    fn is_empty_text_block(block: &OfficeBlock) -> bool {
        match block {
            OfficeBlock::Paragraph { spans, .. } | OfficeBlock::Heading { spans, .. } | OfficeBlock::ListItem { spans, .. } => {
                spans.is_empty()
            }
            OfficeBlock::Table { .. } | OfficeBlock::Image { .. } | OfficeBlock::UnsupportedGraphic { .. }
            | OfficeBlock::Formula { .. } => false,
        }
    }

    /// A cell's content, built from the SAME per-block classification `parseBody` gives the
    /// document — a paragraph, a heading, a list item, an image — via `paragraphLikeBlocks`/
    /// `parseList`, rather than a second, cell-only walk that only ever knew how to collect plain
    /// text. This is what closes gap-list rows 6 and 7: before this sprint a cell held nothing but
    /// `[Span]`, so an image or a bulleted/numbered list inside a `<table:table-cell>` had nowhere
    /// to go and was silently skipped.
    ///
    /// ODT has no per-numId counter STATE to decide a scope for (unlike `DocxReader`'s
    /// `ListNumberingState`) — `isOrdered` is a pure function of a list style's name/level, and this
    /// reader never resolves real marker TEXT for an ODF list (`OfficeBlock.listItem.marker` stays
    /// `nil` here exactly as it does in the body, see the note above `isOrdered`); `OfficeTextBuilder`
    /// counts a cell's list items the same way it already counts the body's, so nothing extra is
    /// threaded through here for numbering to "continue" — there is no reader-level counter to share.
    ///
    /// A nested `<table:table>` is a REAL `.table` block inside the cell — read by the same
    /// `parseTable` as a body table (invariant 164). An empty paragraph is filtered with the SAME
    /// `isEmptyTextBlock` check above: a truly empty cell must produce no block at all, never a
    /// phantom `.paragraph(spans: [])` standing in for "nothing here".
    // swift: OdtReader.collectCellBlocks
    fn collect_cell_blocks(cell: &Ref<XMLNode>, styles: &ParsedStyles, archive: &ZipArchive, notes: &NoteCollector) -> Vec<OfficeBlock> {
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        for child in XMLNode::children(cell) {
            let attrs = XMLNode::attributes(&child);
            match XMLNode::name(&child).as_str() {
                "text:h" => {
                    let raw_level = attrs.get("text:outline-level").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1);
                    let level = raw_level.max(1).min(6);
                    let resolved = Self::resolved_style(attrs.get("text:style-name").map(String::as_str), styles);
                    blocks.extend(Self::paragraph_like_blocks(
                        &child,
                        Box::new(move |spans| OfficeBlock::Heading {
                            level: level as i64, spans, rtl: resolved.rtl, alignment: resolved.alignment.clone(),
                            tab_stops: resolved.tab_stops.clone(), format: resolved.format.clone(), format_ref: None,
                        }),
                        styles, archive, notes,
                    ));
                }
                "text:p" => {
                    let style_name = attrs.get("text:style-name").map(String::as_str);
                    let resolved = Self::resolved_style(style_name, styles);
                    if let Some(raw_level) = resolved.outline_level {
                        let level = raw_level.max(1).min(6);
                        let resolved2 = resolved.clone();
                        blocks.extend(Self::paragraph_like_blocks(
                            &child,
                            Box::new(move |spans| OfficeBlock::Heading {
                                level: level as i64, spans, rtl: resolved2.rtl, alignment: resolved2.alignment.clone(),
                                tab_stops: resolved2.tab_stops.clone(), format: resolved2.format.clone(), format_ref: None,
                            }),
                            styles, archive, notes,
                        ));
                    } else {
                        let resolved2 = resolved.clone();
                        blocks.extend(Self::paragraph_like_blocks(
                            &child,
                            Box::new(move |spans| OfficeBlock::Paragraph {
                                spans, rtl: resolved2.rtl, alignment: resolved2.alignment.clone(),
                                tab_stops: resolved2.tab_stops.clone(), format: resolved2.format.clone(), format_ref: None,
                            }),
                            styles, archive, notes,
                        ));
                    }
                }
                "text:list" => {
                    blocks.extend(Self::parse_list(&child, 0, None, styles, archive, notes));
                }
                "table:table" => {
                    blocks.push(Self::parse_table(&child, styles, archive, notes));
                }
                _ => continue,
            }
        }
        blocks.into_iter().filter(|b| !Self::is_empty_text_block(b)).collect()
    }

}

impl OdtReader {
    // MARK: Images — draw:frame > draw:image

    /// `svg:width`/`svg:height` on the FRAME (not the image) is the declared, authoritative drawn
    /// size — same reasoning as amendment D in the roadmap: a raster placed at a given frame size
    /// is displayed there regardless of its pixel dimensions. Every `draw:frame` with a
    /// `draw:image` child anywhere below `node` is collected, not just a direct child, since a
    /// frame can itself be wrapped (e.g. inside `draw:text-box`) — mirrors `DocxReader`'s
    /// `allDescendants("a:blip")` walk for the same reason: an image must never be dropped just
    /// because of an intermediate wrapper this reader doesn't specifically name.
    // swift: OdtReader.collectImages
    fn collect_images(node: &Ref<XMLNode>, archive: &ZipArchive) -> Vec<OfficeBlock> {
        let mut frames: Vec<Ref<XMLNode>> = Vec::new();
        // A hand-rolled walk, not `allDescendants("draw:frame")` — a `text:note` sitting inside this
        // paragraph (the citation) carries its OWN body, parsed and rendered separately by
        // `buildNoteBlocks`; searching blindly into it here would pull an image that belongs to the
        // FOOTNOTE into the citing paragraph's own image list, duplicating it in the wrong place.
        fn walk(node: &Ref<XMLNode>, frames: &mut Vec<Ref<XMLNode>>) {
            for child in XMLNode::children(node) {
                if XMLNode::name(&child) == "text:note" { continue; }
                if XMLNode::name(&child) == "draw:frame" { frames.push(child.clone()); }
                walk(&child, frames);
            }
        }
        walk(node, &mut frames);
        frames.into_iter().filter_map(|frame| {
            let image = XMLNode::child(&frame, "draw:image")?;
            let attrs = XMLNode::attributes(&frame);
            let width = attrs.get("svg:width").and_then(|s| Self::parse_length(s));
            let height = attrs.get("svg:height").and_then(|s| Self::parse_length(s));
            let size = CGSize::new(
                width.unwrap_or(Self::unresolved_frame_size().width),
                height.unwrap_or(Self::unresolved_frame_size().height),
            );
            let href = XMLNode::attributes(&image).get("xlink:href").cloned();
            Some(OfficeBlock::Image { id: Self::resolve_image_id(href.as_deref(), archive).into(), size, alignment: None })
        }).collect()
    }

    /// A `draw:frame` wrapping a `draw:text-box` (and carrying no `draw:image` — that combination
    /// is an ordinary picture, handled by `collectImages`) contributes its own text-box content
    /// instead of nothing. Mirrors `DocxReader.textBoxBlocks`'s scope exactly, per this project's
    /// own rule that the two readers stay parallel rather than diverging for no reason: only the
    /// text box's own `text:p`/`text:h` paragraphs (no nested lists/tables — docx's fallback never
    /// chased those either), with an empty one (LibreOffice leaves a placeholder paragraph in an
    /// otherwise-untyped shape) dropped rather than shown as a phantom blank line.
    // swift: OdtReader.collectTextBoxBlocks
    fn collect_text_box_blocks(
        node: &Ref<XMLNode>, text_styles: &std::collections::HashMap<String, TextStyle>, notes: &NoteCollector,
    ) -> Vec<OfficeBlock> {
        let mut text_boxes: Vec<Ref<XMLNode>> = Vec::new();
        fn walk(node: &Ref<XMLNode>, text_boxes: &mut Vec<Ref<XMLNode>>) {
            for child in XMLNode::children(node) {
                if XMLNode::name(&child) == "text:note" { continue; } // belongs to the footnote, not this paragraph
                if XMLNode::name(&child) == "draw:frame" && XMLNode::child(&child, "draw:image").is_none() {
                    if let Some(text_box) = XMLNode::child(&child, "draw:text-box") {
                        text_boxes.push(text_box);
                        continue; // don't also descend into the text box's own contents from here
                    }
                }
                walk(&child, text_boxes);
            }
        }
        walk(node, &mut text_boxes);
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        for text_box in text_boxes {
            for child in XMLNode::children(&text_box) {
                match XMLNode::name(&child).as_str() {
                    "text:h" => {
                        let attrs = XMLNode::attributes(&child);
                        let raw_level = attrs.get("text:outline-level").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1);
                        let level = raw_level.max(1).min(6);
                        let spans = Self::collect_spans(&child, &TextStyle::default(), text_styles, notes);
                        if spans.is_empty() { continue; }
                        blocks.push(OfficeBlock::Heading { level: level as i64, spans, rtl: false, alignment: None, tab_stops: vec![], format: ParagraphFormat::default(), format_ref: None });
                    }
                    "text:p" => {
                        let spans = Self::collect_spans(&child, &TextStyle::default(), text_styles, notes);
                        if spans.is_empty() { continue; }
                        blocks.push(OfficeBlock::Paragraph { spans, rtl: false, alignment: None, tab_stops: vec![], format: ParagraphFormat::default(), format_ref: None });
                    }
                    _ => continue,
                }
            }
        }
        blocks
    }

    /// A best-defensible non-zero fallback for a frame whose `svg:width`/`svg:height` is missing or
    /// doesn't parse — invariant 1 applies here exactly as it does to `DocxReader`'s VML fallback:
    /// never reserve a zero/collapsed area.
    fn unresolved_frame_size() -> CGSize {
        CGSize::new(72.0, 72.0)
    }

    /// An `xlink:href` resolves to the archive entry path when it names a real entry (the ordinary
    /// case: `"Pictures/…"`, an embedded image) — anything else this reader can't hand pixels for
    /// (no href at all, or a linked/external href that never was extracted into the archive, e.g.
    /// an absolute `file:///…`) resolves to a clearly-marked, non-archive-shaped id. Mirrors
    /// `DocxReader.resolveId`, prefixed `"odt-"` rather than `"docx-"` since the two formats'
    /// unresolvable ids are never compared against each other — only ever matched by prefix within
    /// their own reader's caller.
    // swift: OdtReader.resolveImageId
    fn resolve_image_id(href: Option<&str>, archive: &ZipArchive) -> String {
        let Some(href) = href else { return Self::unresolvable_id("no-href") };
        if !archive.contains(href) { return Self::unresolvable_id(href); }
        href.to_string()
    }

    // swift: OdtReader.unresolvableId
    fn unresolvable_id(reason: &str) -> String {
        format!("odt-unresolvable:{}", reason)
    }

    /// A CSS-like length (`"7.938cm"`, `"1in"`, a bare `"72"`) → points. Longest-suffix-first is
    /// unnecessary here (no unit is a prefix of another), kept in a table for the same
    /// self-evident-order-independence reason as `DocxReader.parseCSSLikeLength`. A bare number
    /// (no unit) is treated as points, ODF's own convention for `style:*-margin`/similar unmarked
    /// lengths elsewhere in the format.
    // swift: OdtReader.parseLength
    fn parse_length(raw: &str) -> Option<CGFloat> {
        let points_per_unit: [(&str, f64); 6] = [
            ("cm", 72.0 / 2.54), ("mm", 72.0 / 25.4), ("in", 72.0), ("pc", 12.0), ("pt", 1.0), ("px", 0.75),
        ];
        for (suffix, factor) in points_per_unit {
            if let Some(stripped) = raw.strip_suffix(suffix) {
                let number: f64 = stripped.parse().ok()?;
                return Some(CGFloat::from(number * factor));
            }
        }
        let number: f64 = raw.parse().ok()?;
        Some(CGFloat::from(number))
    }

    /// ODF's `color` datatype (`fo:color`, `fo:background-color`'s non-`"transparent"` form) is
    /// ALWAYS `"#RRGGBB"` — never a CSS colour name, never `0x`-prefixed, never carrying alpha (ODF
    /// 1.3 §18.3.2). `"transparent"` — `fo:background-color`'s other legal value, meaning "no
    /// highlight" — returns `nil`, exactly like an absent attribute, never black: see `Span
    /// .highlightColor`'s own doc for why "no mark" must never become a literal colour.
    // swift: OdtReader.parseODFColor
    fn parse_odf_color(raw: &str) -> Option<NSColor> {
        if raw == "transparent" || !raw.starts_with('#') || raw.len() != 7 { return None; }
        let value = u32::from_str_radix(&raw[1..], 16).ok()?;
        // swift: `NSColor(deviceRed:...)`, and device RGB is what OdtReader means — the other
        // two readers build sRGB from the same kind of literal. Same components, different colour.
        Some(NSColor::device_rgb(
            CGFloat::from(((value >> 16) & 0xFF) as f64 / 255.0),
            CGFloat::from(((value >> 8) & 0xFF) as f64 / 255.0),
            CGFloat::from((value & 0xFF) as f64 / 255.0),
            1.0,
        ))
    }

    // swift: OdtReader.parseODFEdgeBorders
    /// ODF's border shorthand is `"<width-length> <line-style> <color>"` (e.g. `"0.06pt solid
    /// #000000"`, the same three-token shape CSS borders use) — `fo:border` sets all four sides at
    /// once, `fo:border-top`/`-bottom`/`-left`/`-right` set one side each. `Cell`'s own vocabulary is
    /// ONE uniform colour/width, not a real four-sided model (`OfficeBlock.swift`'s own doc comment on
    /// `Cell.borderColor`/`borderWidth`), so the first side declared wins — `fo:border` is checked
    /// first (the common, symmetric case), then each individual side, so an asymmetric border (only
    /// `fo:border-top` set, no `fo:border` shorthand) still contributes something rather than nothing.
    /// The middle token being `"none"`/`"hidden"` means no border on that side, read the same as the
    /// attribute being absent entirely.
    /// The same shorthand read PER SIDE, keeping what the uniform pair above throws away: which
    /// sides were named, whether a side was switched OFF, and the style token (`solid`/`dashed`/
    /// `dotted`/`double`), which every ODF file states and this reader used to drop — a dotted frame
    /// then rendered as a solid one, the same defect measured in the docx and HWP paths.
    /// `fo:border` seeds all four; a per-side attribute then overrides its own side, which is ODF's
    /// own precedence. Returns nil when the style named no side at all, so an unstyled cell is
    /// unchanged.
    fn parse_odf_edge_borders(props: &Ref<XMLNode>) -> Option<EdgeBorders> {
        // swift: OdtReader.decl
        fn decl(raw: &str) -> Option<BorderDecl> {
            let tokens: Vec<String> = raw.split(' ').map(String::from).collect();
            if tokens.is_empty() { return None; }
            if tokens.iter().any(|t| t == "none" || t == "hidden") { return Some(BorderDecl::Suppressed); }
            let width = tokens.first().and_then(|s| OdtReader::parse_length(s));
            let color = tokens.last().and_then(|s| OdtReader::parse_odf_color(s));
            let width = width?;
            if !(width > 0.0) { return None; }
            let style = match if tokens.len() > 1 { tokens[1].as_str() } else { "solid" } {
                "dotted" => BorderLineStyle::Dotted,
                "dashed" | "dash-dot" | "dash-dot-dot" | "fine-dashed" | "dotted-dashed" => BorderLineStyle::Dashed,
                "double" | "double-thin" | "groove" | "ridge" => BorderLineStyle::Double,
                _ => BorderLineStyle::Solid,
            };
            Some(BorderDecl::Drawn(BorderSide { width, color, style }))
        }
        let attrs = XMLNode::attributes(props);
        let all = attrs.get("fo:border").and_then(|s| decl(s));
        let mut out = EdgeBorders { top: all.clone(), left: all.clone(), bottom: all.clone(), right: all, inside_h: None, inside_v: None };
        if let Some(raw) = attrs.get("fo:border-top") { out.top = decl(raw); }
        if let Some(raw) = attrs.get("fo:border-bottom") { out.bottom = decl(raw); }
        if let Some(raw) = attrs.get("fo:border-left") { out.left = decl(raw); }
        if let Some(raw) = attrs.get("fo:border-right") { out.right = decl(raw); }
        if out.is_empty() { None } else { Some(out) }
    }

    // swift: OdtReader.parseODFBorder
    fn parse_odf_border(props: &Ref<XMLNode>) -> (Option<NSColor>, Option<CGFloat>) {
        let attrs = XMLNode::attributes(props);
        for key in ["fo:border", "fo:border-top", "fo:border-bottom", "fo:border-left", "fo:border-right"] {
            let Some(raw) = attrs.get(key) else { continue };
            let tokens: Vec<&str> = raw.split(' ').collect();
            if tokens.len() >= 2 && (tokens[1] == "none" || tokens[1] == "hidden") { continue; }
            let width = tokens.first().and_then(|s| Self::parse_length(s));
            let color = tokens.last().and_then(|s| Self::parse_odf_color(s));
            if width.is_some() || color.is_some() { return (color, width); }
        }
        (None, None)
    }
}

impl OdtReader {
    // MARK: Spans — text:span/text:a/text:s/text:tab/text:line-break, in document order

    /// Walks `node`'s children strictly in document order (see `XMLNode`/`#text` below — unlike a
    /// plain "attributes + children" tree, character data is threaded in as ordered pseudo-children
    /// so `"before "` / `<text:span>bold</text:span>` / `" after"` reassemble in the right order,
    /// which a tree that only concatenates trailing text per element cannot do). `style` is the
    /// formatting in effect for any bare text reached at this level; a `text:span` resolves ITS
    /// OWN style from `text:style-name` (falling back to the inherited `style` when the name is
    /// absent or unresolvable — text is never dropped for want of a style) and passes that down to
    /// its own children, so nesting narrows rather than resets formatting. `link` is threaded
    /// alongside but separately from `style`, because a hyperlink target comes from `text:a`'s own
    /// `xlink:href` attribute, not from any named style — it narrows the same way (a `text:a` with
    /// no `xlink:href` at all just carries the enclosing link, if any, rather than losing it).
    // swift: OdtReader.collectSpans
    fn collect_spans(
        node: &Ref<XMLNode>, style: &TextStyle, text_styles: &std::collections::HashMap<String, TextStyle>,
        notes: &NoteCollector,
    ) -> Vec<Span> {
        let spans: Ref<Vec<Span>> = swiftshim::new_ref(Vec::new());
        // Same role as `DocxReader.collectSpans`'s `pendingBookmarks`: names collected from
        // `text:bookmark`/`text:bookmark-start` since the last span, attached to the next real
        // content. ODF has no known equivalent of Word's auto-inserted `_GoBack`, so nothing is
        // filtered here.
        let pending_bookmarks: Ref<Vec<String>> = swiftshim::new_ref(Vec::new());
        // Set for exactly the run a `text:page-number`/`text:page-count` field contributes, so the
        // CACHED number ODF stores as that element's text can be swapped for this page's live value
        // at paint time (`PageBandPainter.substitutingPageFields`). Without it an .odt footer reading
        // "- 2 -" showed "- 2 -" on every page, because the file's last-computed 2 is ordinary text.
        let pending_page_number_field: Ref<Option<PageNumberField>> = swiftshim::new_ref(None);

        /// Emits ONE piece of a run: `family` is the family THIS stretch of text resolved to, which
        /// is one of the style's three slots rather than "the style's font", and is the only thing
        /// separating a piece from its neighbours. Everything else — the bookmark handover, the
        /// comment ids, the run-merge equality — is exactly what it was before slots existed.
        // swift: OdtReader.appendPiece
        fn append_piece(
            text: &str, style: &TextStyle, family: Option<&str>, link: Option<&str>,
            spans: &Ref<Vec<Span>>, pending_bookmarks: &Ref<Vec<String>>,
            pending_page_number_field: &Ref<Option<PageNumberField>>, notes: &NoteCollector,
        ) {
            if text.is_empty() { return; }
            let mut bookmarks: Vec<String> = Vec::new();
            if !pending_bookmarks.borrow().is_empty() {
                bookmarks = pending_bookmarks.borrow().clone();
                pending_bookmarks.borrow_mut().clear();
            }
            // Every span emitted while a NAMED `office:annotation` range is open carries that
            // comment's id — see `Span.commentIds` and the `office:annotation`/
            // `office:annotation-end` cases below.
            let comment_ids = notes.active_comment_ids.borrow().clone();
            let field = *pending_page_number_field.borrow();
            *pending_page_number_field.borrow_mut() = None;
            if !bookmarks.is_empty() || !comment_ids.is_empty() || field.is_some() {
                spans.borrow_mut().push(Span {
                    text: text.to_string().into(), bold: style.bold, italic: style.italic, underline: style.underline,
                    underline_style: style.underline_style, caps: style.caps, small_caps: style.small_caps,
                    link: link.map(|s| s.to_string().into()), strikethrough: style.strikethrough, superscript: style.superscript,
                    subscripted: style.subscripted, bookmarks: bookmarks.into_iter().map(Into::into).collect(),
                    comment_ids: comment_ids.into_iter().map(Into::into).collect(), text_color: style.text_color.clone(),
                    highlight_color: style.highlight_color.clone(), font_size: style.font_size,
                    font_name: family.map(|s| s.to_string().into()), page_number_field: field,
                    ..Default::default()
                });
                return;
            }
            // A bookmarked/commented span is never EXTENDED by trailing text either — see the
            // matching guard in `DocxReader.collectSpans`. `textColor`/`highlightColor`/`fontSize`/
            // `fontName`/`underlineStyle`/`caps`/`smallCaps` (P3/P4's own additions) join the same
            // equality check — two runs that only differ in, say, colour must stay two separate
            // `Span`s, or the FIRST run's colour would silently win for the whole merged range (a
            // merge keeps the first span and appends only the second's text).
            //
            // That cross-reference described the docx guard as if it already matched this one, and
            // for a long time it did not: the docx side compared none of those four fields, so the
            // sentence above read as a shared contract while only one of the two readers honoured
            // it. Both sides are aligned now, and each carries its own list rather than a pointer to
            // the other — a comment cannot keep two lists in step, only a test can, so the real
            // guard is a per-reader completeness test over everything that reader's own markup can
            // express (`testEveryRunPropertyADocxCanCarryKeepsAdjacentRunsApart` and
            // `testEveryTextPropertyAnOdtCanCarryKeepsAdjacentRunsApart`).
            //
            // `code` and `rtl` are absent here, unlike in the docx guard, because no ODT-sourced
            // `Span` can differ in them: `code` is a markdown concept with no ODF equivalent, and
            // ODF states direction only on a PARAGRAPH style (`style:writing-mode`), never on a
            // `text:span` — see `Span.rtl`'s own doc. Both are left at their defaults by every
            // construction site in this function, so comparing them would always be true.
            let mut spans_mut = spans.borrow_mut();
            let can_merge = if let Some(last) = spans_mut.last() {
                last.bookmarks.is_empty() && last.comment_ids.is_empty() && last.page_number_field.is_none()
                    && last.bold == style.bold && last.italic == style.italic && last.underline == style.underline
                    && last.strikethrough == style.strikethrough && last.superscript == style.superscript
                    && last.subscripted == style.subscripted && last.link.as_deref() == link
                    && last.text_color == style.text_color && last.highlight_color == style.highlight_color
                    && last.font_size == style.font_size && last.font_name.as_deref() == family
                    && last.underline_style == style.underline_style && last.caps == style.caps
                    && last.small_caps == style.small_caps
            } else { false };
            if can_merge {
                let idx = spans_mut.len() - 1;
                spans_mut[idx].text.push_str(text);
            } else {
                spans_mut.push(Span {
                    text: text.to_string().into(), bold: style.bold, italic: style.italic, underline: style.underline,
                    underline_style: style.underline_style, caps: style.caps, small_caps: style.small_caps,
                    link: link.map(|s| s.to_string().into()), strikethrough: style.strikethrough, superscript: style.superscript,
                    subscripted: style.subscripted, text_color: style.text_color.clone(),
                    highlight_color: style.highlight_color.clone(), font_size: style.font_size,
                    font_name: family.map(|s| s.to_string().into()),
                    ..Default::default()
                });
            }
        }

        /// One run of text as the document wrote it, cut into the fewest pieces that each want one
        /// typeface, and emitted in order.
        ///
        /// The cut is `ScriptRunSplitter`'s, driven by ODF's own §20.358 table 22 — and it breaks
        /// where the resolved FAMILY changes, never where the slot changes, which is what keeps
        /// `제1항` one piece in the overwhelmingly common document that points its latin and asian
        /// slots at the same face.
        // swift: OdtReader.appendMerging
        fn append_merging(
            text: &str, style: &TextStyle, link: Option<&str>, spans: &Ref<Vec<Span>>,
            pending_bookmarks: &Ref<Vec<String>>, pending_page_number_field: &Ref<Option<PageNumberField>>,
            notes: &NoteCollector,
        ) {
            if text.is_empty() { return; }
            // The case invariant 37 rests on, and the one nearly every real document is in: when the
            // three slots name one family — or name none at all — no character can select anything
            // different from any other, so the scalar walk is skipped rather than run to rediscover
            // that. Before/after is then identical by CONSTRUCTION and not merely by measurement,
            // and costs nothing it did not cost before slots existed.
            if style.fonts.is_uniform() {
                append_piece(text, style, style.fonts.latin.as_deref(), link, spans, pending_bookmarks, pending_page_number_field, notes);
                return;
            }
            // swift: OdtReader.appendMerging
            // cross-file dependency, out of the
            // phase-A manifest (see this file's `notes` in the worker's return).
            let pieces: Vec<Piece> = ScriptRunSplitter::split(
                text, |scalar| crate::render::office::odf_script_type::OdfScriptTable::slot(scalar), |t| style.fonts.family(t),
            );
            // A run in which NOTHING classified — a tab, a stretch of spaces, a line of en dashes,
            // all of them table 22 gaps — states no script type at all, and the splitter rightly
            // hands it back carrying no family. Emitting that verbatim would strand a lone theme-font
            // span between two runs of one real family, which is absorption failing at exactly the
            // boundary it exists to protect; the neighbour's family carries across instead, so the
            // space between two Korean words is measured in the face the document asked for and the
            // piece merges away rather than becoming a span of its own. A single piece that resolved
            // to `nil` because its OWN slot is undeclared is a different answer and keeps the `nil` —
            // which is why this re-scans rather than testing `family == nil`, a test that cannot tell
            // the two apart. The re-scan is reached only for a run that produced one family-less
            // piece under a genuinely multi-family style, so it is neither the common path nor a
            // second walk of anything long.
            if pieces.len() == 1 && pieces[0].family.is_none() {
                let neighbour = spans.borrow().last().and_then(|s| s.font_name.clone());
                if let Some(neighbour) = neighbour {
                    if !text.chars().any(|c| crate::render::office::odf_script_type::OdfScriptTable::slot(c).is_some()) {
                        append_piece(text, style, Some(neighbour.as_str()), link, spans, pending_bookmarks, pending_page_number_field, notes);
                        return;
                    }
                }
            }
            for piece in pieces {
                append_piece(piece.text, style, piece.family.as_deref(), link, spans, pending_bookmarks, pending_page_number_field, notes);
            }
        }

        // swift: OdtReader.walk
        fn walk(
            node: &Ref<XMLNode>, style: &TextStyle, link: Option<&str>, spans: &Ref<Vec<Span>>,
            pending_bookmarks: &Ref<Vec<String>>, pending_page_number_field: &Ref<Option<PageNumberField>>,
            text_styles: &std::collections::HashMap<String, TextStyle>, notes: &NoteCollector,
        ) {
            for child in XMLNode::children(node) {
                let attrs = XMLNode::attributes(&child);
                match XMLNode::name(&child).as_str() {
                    "#text" => {
                        append_merging(&XMLNode::text(&child), style, link, spans, pending_bookmarks, pending_page_number_field, notes);
                    }
                    "text:span" => {
                        let child_style = attrs.get("text:style-name").and_then(|n| text_styles.get(n).cloned()).unwrap_or_else(|| style.clone());
                        walk(&child, &child_style, link, spans, pending_bookmarks, pending_page_number_field, text_styles, notes);
                    }
                    "text:a" => {
                        let href = attrs.get("xlink:href").cloned().or_else(|| link.map(String::from));
                        walk(&child, style, href.as_deref(), spans, pending_bookmarks, pending_page_number_field, text_styles, notes);
                    }
                    "text:s" => {
                        let count = attrs.get("text:c").and_then(|s| s.parse::<usize>().ok()).unwrap_or(1);
                        append_merging(&" ".repeat(count), style, link, spans, pending_bookmarks, pending_page_number_field, notes);
                    }
                    "text:tab" => {
                        append_merging("\t", style, link, spans, pending_bookmarks, pending_page_number_field, notes);
                    }
                    "text:line-break" => {
                        append_merging("\n", style, link, spans, pending_bookmarks, pending_page_number_field, notes);
                    }
                    "draw:frame" => {
                        continue; // images are collected separately by `collectImages`
                    }
                    "text:note" => {
                        // The citation's own marker (`text:note-citation`'s literal text — never
                        // recomputed for a well-formed note, see `noteCitationText`) is emitted right
                        // here as a superscript span, exactly where Word/LibreOffice draw it. A note
                        // missing `text:note-citation` entirely (malformed — ODF requires one) falls
                        // back to `notes.fallbackCounter`, a plain sequential count in citation order,
                        // rather than showing a blank marker or crashing.
                        //
                        // `text:note-body` — the note's full text — is deliberately NOT walked from
                        // here: doing so would splice the footnote's own sentence(s) into the middle of
                        // the CITING paragraph, which is precisely the corruption `read()`'s
                        // `buildNoteBlocks` exists to avoid. A note with no `text:note-body` at all
                        // (also malformed) contributes nothing to `notes.entries` — its marker still
                        // shows here, honestly, but there is no body text to fabricate. That body, when
                        // present, is rendered once, detached, at the document's end instead.
                        let citation = OdtReader::note_citation_text(&child);
                        let marker = if citation.is_empty() {
                            let m = format!("{}", *notes.fallback_counter.borrow());
                            *notes.fallback_counter.borrow_mut() += 1;
                            m
                        } else {
                            citation
                        };
                        if let Some(body) = XMLNode::child(&child, "text:note-body") {
                            notes.entries.borrow_mut().push((marker.clone(), body));
                        }
                        let mut marker_style = TextStyle::default();
                        marker_style.superscript = true;
                        append_merging(&marker, &marker_style, link, spans, pending_bookmarks, pending_page_number_field, notes);
                    }
                    "text:hidden-text" => {
                        // Verified against OASIS ODF 1.3 schema (element text:hidden-text):
                        // text:condition and text:string-value are REQUIRED, text:is-hidden is
                        // OPTIONAL (text:boolean) — used as an empty field in practice.
                        // ODF's RUN-level "show under a condition" field. Unlike `text:hidden-paragraph`
                        // (which wraps ordinary content), this is an EMPTY field element — its display
                        // text is CACHED in `text:string-value` (ODF's standard "field caches its last-
                        // computed text as an attribute" convention, ODF 1.3 Part 3 §7.2), not held as
                        // child nodes. `text:is-hidden` is the file's own last-computed state; hide only
                        // on an explicit "true", exactly the same rule as `text:hidden-paragraph`.
                        if attrs.get("text:is-hidden").map(String::as_str) != Some("true") {
                            append_merging(attrs.get("text:string-value").map(String::as_str).unwrap_or(""), style, link, spans, pending_bookmarks, pending_page_number_field, notes);
                        }
                    }
                    "text:conditional-text" => {
                        // Verified against OASIS ODF 1.3 schema (element text:conditional-text):
                        // text:condition, text:string-value-if-true, text:string-value-if-false are
                        // REQUIRED; text:current-value is OPTIONAL (text:boolean) — used as an empty
                        // field in practice.
                        // ODF's "one of two alternative texts, selected by a formula" field — also an
                        // EMPTY element. `text:current-value` records which branch the formula last
                        // evaluated to; this reader trusts that recorded state rather than evaluating
                        // `text:condition` itself. Absent `text:current-value` reads as "false" (ODF's
                        // own default for the attribute), matching `text:string-value-if-false`.
                        let show_true_branch = attrs.get("text:current-value").map(String::as_str) == Some("true");
                        let text = if show_true_branch {
                            attrs.get("text:string-value-if-true").cloned().unwrap_or_default()
                        } else {
                            attrs.get("text:string-value-if-false").cloned().unwrap_or_default()
                        };
                        append_merging(&text, style, link, spans, pending_bookmarks, pending_page_number_field, notes);
                    }
                    "text:page-number" | "text:page-count" => {
                        // ODF 1.3 Part 3 §7.3.4/§7.5.19: both elements CACHE their last-computed value as
                        // their own text content, exactly like `text:hidden-text`'s `string-value`. That
                        // cached text is emitted verbatim — it is what a reader with no pagination would
                        // show, and it keeps the surrounding "- N -" punctuation intact — but the run is
                        // MARKED so the band painter can replace it with this page's real number.
                        //
                        // `text:select-page` ("previous"/"current"/"next") is deliberately not honoured:
                        // this reader's live value is the page the band is being drawn on, and offsetting
                        // it would need a second field kind for a construct no real document here uses.
                        // The cached text still shows the author's own intent for those rare cases.
                        *pending_page_number_field.borrow_mut() = Some(
                            if XMLNode::name(&child) == "text:page-count" { PageNumberField::NumPages } else { PageNumberField::Page }
                        );
                        walk(&child, style, link, spans, pending_bookmarks, pending_page_number_field, text_styles, notes);
                        *pending_page_number_field.borrow_mut() = None; // never leaks onto the text that FOLLOWS the field
                    }
                    "text:bookmark-start" | "text:bookmark" => {
                        // `text:bookmark` (a zero-length, point bookmark — the common case for a
                        // cross-reference target) and `text:bookmark-start` (the open end of a ranged
                        // bookmark) both carry the target name the SAME way: `text:name`. Recorded here,
                        // never rendered as text — see `Span.bookmarks`.
                        if let Some(name) = attrs.get("text:name") { pending_bookmarks.borrow_mut().push(name.clone()); }
                        continue;
                    }
                    "text:bookmark-end" | "text:soft-page-break" => {
                        continue; // markers with no renderable text of their own
                    }
                    // A reviewer comment (P6a — see `OfficeComment`). ODF puts it INLINE, mixed into
                    // the paragraph's own run content: `dc:creator`/`dc:date` (author/timestamp) plus
                    // `text:p` children (the comment's own text). `office:name`, when present, is what
                    // pairs this start with a LATER `office:annotation-end` of the same name, marking a
                    // RANGE — every span in between carries this comment's id (see `appendMerging`
                    // above). An annotation with NO `office:name` is a POINT comment (LibreOffice's
                    // common case for "comment on the cursor, no selection") — it is captured and
                    // listed (still gets a display number), but this reader has no way to know how far
                    // its "range" should extend without a name to match a later end against, so it
                    // deliberately anchors NOTHING rather than guessing (never opened as active).
                    "office:annotation" => {
                        let author = XMLNode::child(&child, "dc:creator").map(|n| OdtReader::plain_text(&n)).filter(|s| !s.is_empty());
                        let date_iso = XMLNode::child(&child, "dc:date").map(|n| OdtReader::plain_text(&n)).filter(|s| !s.is_empty());
                        let text = XMLNode::children(&child).into_iter()
                            .filter(|c| XMLNode::name(c) == "text:p")
                            .map(|c| OdtReader::plain_text(&c))
                            .collect::<Vec<_>>()
                            .join("\n");
                        let name = attrs.get("office:name").cloned();
                        let number = *notes.comment_number_counter.borrow();
                        let id = name.clone().unwrap_or_else(|| format!("odt-comment-{}", number));
                        let comment = OfficeComment {
                            id: id.into(), author: author.map(Into::into), date_iso: date_iso.map(Into::into),
                            text: text.into(), number: number as i64,
                        };
                        *notes.comment_number_counter.borrow_mut() += 1;
                        notes.comments.borrow_mut().push(comment);
                        if let Some(name) = name { notes.active_comment_ids.borrow_mut().push(name); }
                        continue;
                    }
                    "office:annotation-end" => {
                        if let Some(name) = attrs.get("office:name") {
                            notes.active_comment_ids.borrow_mut().retain(|n| n != name);
                        }
                        continue;
                    }
                    _ => {
                        // Anything else this switch doesn't specifically name is descended into rather
                        // than skipped, so text is never lost just because ODF wrapped it in something
                        // unanticipated — same permissive-recursion reasoning as `DocxReader.collectSpans`.
                        walk(&child, style, link, spans, pending_bookmarks, pending_page_number_field, text_styles, notes);
                    }
                }
            }
        }
        walk(node, style, None, &spans, &pending_bookmarks, &pending_page_number_field, text_styles, notes);
        let result = spans.borrow().clone();
        result
    }

    // MARK: Generic XML tree — text threaded in as ordered `"#text"` pseudo-children

    // swift: OdtReader.buildTree
    fn build_tree(data: &swiftshim::Data) -> Result<Ref<XMLNode>, OdtReadError> {
        let delegate = XMLTreeBuilder::new();
        // swift: OdtReader.buildTree
        // `XMLParser`/`XMLParserDelegate` are
        // Foundation, standing in as `swiftshim::XMLParser` (shim addition), which drives bytes
        // through the SAME loop `DocxReader` uses so the two readers cannot disagree about what
        // an entity or a self-closing tag means.
        let parser = swiftshim::XMLParser::new(&data.0);
        let parsed = parser.parse(&delegate);
        let root: Option<Ref<XMLNode>> = if parsed { delegate.root.borrow().clone() } else { None };
        root.ok_or(OdtReadError::MalformedXML("xml".to_string()))
    }
}

/// Swift: `OdtReader.pageGeometry`'s tuple return type `(content: CGFloat, left: CGFloat, right:
/// CGFloat, height: CGFloat?, top: CGFloat?, bottom: CGFloat?)`, named here for `Option<T>`
/// ergonomics — Rust tuples don't carry field labels the way Swift's do.
// swift: OdtReader.typesetMasterPage
struct PageGeometry {
    content: CGFloat,
    left: CGFloat,
    right: CGFloat,
    height: Option<CGFloat>,
    top: Option<CGFloat>,
    bottom: Option<CGFloat>,
}

/// Accumulates `(marker, body)` for every `text:note` the real body walk encounters, in citation
/// order, plus the running counter `collectSpans` falls back to when a note has no
/// `text:note-citation` of its own (malformed — ODF requires one, but this reader never crashes
/// on a broken document). A class, not a struct, because `collectSpans` and its callers thread
/// it through several layers (paragraphs, list items, table cells) purely to mutate one shared
/// list — value semantics would silently fork it at every call boundary.
// swift: OdtReader.NoteCollector
struct NoteCollector {
    fallback_counter: std::cell::RefCell<i32>,
    entries: std::cell::RefCell<Vec<(String, Ref<XMLNode>)>>,
    /// P6a — reviewer comments (`office:annotation`), captured on the SAME class as footnotes
    /// for the same reason: `collectSpans` and its callers already thread `NoteCollector`
    /// through every layer (paragraphs, list items, table cells) purely to mutate shared state,
    /// so comment tracking rides that existing thread rather than adding a second parameter to
    /// every one of those functions. `activeCommentIds` is the RANGE tracker (open between an
    /// `office:annotation` that declares `office:name` and the matching `office:annotation-end`
    /// — see the `office:annotation`/`office:annotation-end` cases in `collectSpans`'s walk);
    /// `comments` accumulates every `OfficeComment` found, `commentNumberCounter` assigns each
    /// its 1-based first-appearance-in-body display number.
    active_comment_ids: std::cell::RefCell<Vec<String>>,
    comments: std::cell::RefCell<Vec<OfficeComment>>,
    comment_number_counter: std::cell::RefCell<i32>,
}

impl NoteCollector {
    fn new() -> Self {
        NoteCollector {
            fallback_counter: std::cell::RefCell::new(1),
            entries: std::cell::RefCell::new(Vec::new()),
            active_comment_ids: std::cell::RefCell::new(Vec::new()),
            comments: std::cell::RefCell::new(Vec::new()),
            comment_number_counter: std::cell::RefCell::new(1),
        }
    }
}


// MARK: Generic XML tree — text threaded in as ordered `"#text"` pseudo-children

/// A minimal DOM, like `DocxReader`'s own, but with one deliberate difference: character data
/// becomes an ordinary child node named `"#text"` instead of accumulating in a separate `text`
/// property on its parent. ODF paragraphs mix bare text and elements constantly
/// (`"before "<text:span>bold</text:span>" after"`), and a parent-level `text` string that simply
/// concatenates everything the parser hands it — regardless of when a child element started or
/// ended — cannot preserve that interleaving. Ordering it as children does, at the cost of a few
/// `"#text"` checks in `OdtReader.collectSpans`.
// swift: XMLNode
pub struct XMLNode {
    name: String,
    attributes: std::collections::HashMap<String, String>,
    children: Vec<Ref<XMLNode>>,
    /// Only meaningful on a `"#text"` node — the character data itself.
    text: String,
}

impl XMLNode {
    fn new(name: String, attributes: std::collections::HashMap<String, String>) -> Ref<XMLNode> {
        swiftshim::new_ref(XMLNode { name, attributes, children: Vec::new(), text: String::new() })
    }

    fn name(node: &Ref<XMLNode>) -> String {
        node.borrow().name.clone()
    }

    fn attributes(node: &Ref<XMLNode>) -> std::collections::HashMap<String, String> {
        node.borrow().attributes.clone()
    }

    fn children(node: &Ref<XMLNode>) -> Vec<Ref<XMLNode>> {
        node.borrow().children.clone()
    }

    fn text(node: &Ref<XMLNode>) -> String {
        node.borrow().text.clone()
    }

    /// First direct child with this name, or nil.
    // swift: XMLNode.child
    fn child(node: &Ref<XMLNode>, name: &str) -> Option<Ref<XMLNode>> {
        node.borrow().children.iter().find(|c| c.borrow().name == name).cloned()
    }

    /// First match anywhere below this node, depth-first in document order.
    // swift: XMLNode.firstDescendant
    fn first_descendant(node: &Ref<XMLNode>, name: &str) -> Option<Ref<XMLNode>> {
        for child in node.borrow().children.clone() {
            if child.borrow().name == name { return Some(child); }
            if let Some(found) = Self::first_descendant(&child, name) { return Some(found); }
        }
        None
    }

    /// EVERY match anywhere below this node, in document order — used where a style table must
    /// find every `text:list-style`/`style:style` regardless of which wrapper element holds it.
    // swift: XMLNode.allDescendants
    fn all_descendants(node: &Ref<XMLNode>, name: &str) -> Vec<Ref<XMLNode>> {
        let mut result: Vec<Ref<XMLNode>> = Vec::new();
        for child in node.borrow().children.clone() {
            if child.borrow().name == name { result.push(child.clone()); }
            result.extend(Self::all_descendants(&child, name));
        }
        result
    }
}

// swift: XMLTreeBuilder
struct XMLTreeBuilder {
    root: std::cell::RefCell<Option<Ref<XMLNode>>>,
    stack: std::cell::RefCell<Vec<Ref<XMLNode>>>,
}

impl XMLTreeBuilder {
    fn new() -> Self {
        XMLTreeBuilder { root: std::cell::RefCell::new(None), stack: std::cell::RefCell::new(Vec::new()) }
    }
}

// swift: XMLNode.allDescendants
// `NSObject, XMLParserDelegate` conformance;
// `XMLParserDelegate` is Foundation, not yet in swiftshim (shim addition).
impl swiftshim::XMLParserDelegate for XMLTreeBuilder {
    fn parser_did_start_element(
        &self, _parser: &swiftshim::XMLParser, element_name: &str, _namespace_uri: Option<&str>,
        _qualified_name: Option<&str>, attribute_dict: std::collections::HashMap<String, String>,
    ) {
        let node = XMLNode::new(element_name.to_string(), attribute_dict);
        if let Some(parent) = self.stack.borrow().last() {
            parent.borrow_mut().children.push(node.clone());
        } else {
            *self.root.borrow_mut() = Some(node.clone());
        }
        self.stack.borrow_mut().push(node);
    }

    /// Character data is appended into the CURRENT top-of-stack element as a `"#text"` pseudo-child
    /// — merged into the last child if it is already one (the parser can call this more than once
    /// for a single run of text), so mixed content keeps its real order without producing a run of
    /// adjacent one-character `"#text"` nodes.
    // swift: XMLTreeBuilder.parser
    fn parser_found_characters(&self, _parser: &swiftshim::XMLParser, string: &str) {
        let stack = self.stack.borrow();
        let Some(parent) = stack.last() else { return };
        let mut parent_mut = parent.borrow_mut();
        let last_is_text = parent_mut.children.last().map(|c| c.borrow().name == "#text").unwrap_or(false);
        if last_is_text {
            let last = parent_mut.children.last().unwrap().clone();
            last.borrow_mut().text.push_str(string);
        } else {
            let text_node = XMLNode::new("#text".to_string(), std::collections::HashMap::new());
            text_node.borrow_mut().text = string.to_string();
            parent_mut.children.push(text_node);
        }
    }

    fn parser_did_end_element(
        &self, _parser: &swiftshim::XMLParser, _element_name: &str, _namespace_uri: Option<&str>,
        _qualified_name: Option<&str>,
    ) {
        self.stack.borrow_mut().pop();
    }
}

// MARK: Coverage bookkeeping — doc-comment/blank-line spans already transliterated as
// `///` prose above their corresponding item, whose `// swift:` range marker started at the
// declaration rather than at the doc comment's own first line. Listed here so every line
// of the original is claimed by SOME range, per rust-port-convention.md §2 ("overlap is fine;
// blank lines and comment blocks count and must be claimed too").
// swift: OdtReader.append
// swift: OdtReader.resolveSlot
// swift: OdtReader.isOrdered
// swift: OdtReader.TableCellStyle
// swift: OdtReader.TableColumnStyle
// swift: OdtReader.parseTableColumnStyleDecls
// swift: OdtReader.parseColumnDefaultCellStyles
// swift: OdtReader.unresolvableId
