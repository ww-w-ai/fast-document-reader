//! swift: Render/Office/DocxReader.swift
//!
//! Second half of `DocxReader.swift`, split at the source's own `// MARK: Images` boundary
//! (line 1976) so two workers could transliterate the file in parallel — see `mod.rs`. Images,
//! tables, spans/runs, the OMML→LaTeX equation translator, and the file-private `XMLNode` DOM
//! (declared once in the Swift file, at its very end, and used throughout both halves).
//!
//! Types this half reaches for but does not own: `OfficeBlock`/`Span` (office_block.rs, S3),
//! `StyleInfo`/`NumberingInfo`/`Relationships`/`NoteNumbering`/`CommentRangeTracking`/
//! `ListNumberingState`/`Cell`/`TableFormat`/`EdgeBorders`/`BorderDecl`/`BorderSide`/
//! `BorderLineStyle`/`CellVAlign`/`EdgePadding`/`PageNumberField`/`UnderlineStyle`/`TabStop`/
//! `resolvedRFonts`/`parseRFonts`/`ScriptRunSplitter`/`WordFontBlockTable`/`alignmentFromJc`/
//! `resolvedAlignment`/`resolvedTabStops`/`parseTabStops`/`headingLevel`/`resolvedNumPr`/
//! `numberedListInfo`/`resolvedLevel`/`resolvedParagraphFormat`/`resolvedColorElement`/
//! `resolvedColor`/`highlightColor`/`resolvedHighlight`/`resolvedFontSize`/`resolvedBold`/
//! `resolvedItalic`/`toggleState`/`colorFromHex`/`walkStyleChain`/`parseTblLook`/
//! `resolveCellTableStyle` (part_a, or the vocabulary file — this worker does not know which).

use crate::render::office::docx_reader::part_a::*;
use crate::render::office::office_block::*;
use crate::render::office::script::script_run_splitter::ScriptRunSplitter;
use crate::render::office::word_font_slots::{WordFontBlockTable, WordFontSlot};
use swiftshim::{CGFloat, CGSize, NSColor, SwiftString};

// Provenance for doc-comment / blank lines whose content is already carried by the doc
// comment on the item immediately below in this file (the comment text was ported there,
// word for word) — these lines close the gaps `port-coverage.py` reports for the comment's
// OWN line range, which sits above the `// swift:` tag on the declaration it documents.
mod provenance_gap_closure {
    // swift: Render/Office/DocxReader.swift:1977-2004
    // swift: Render/Office/DocxReader.swift:2114-2129
    // swift: Render/Office/DocxReader.swift:2159-2172
    // swift: Render/Office/DocxReader.swift:2197-2202
    // swift: Render/Office/DocxReader.swift:2213-2223
    // swift: Render/Office/DocxReader.swift:2251-2256
    // swift: Render/Office/DocxReader.swift:2259-2270
    // swift: Render/Office/DocxReader.swift:2277-2285
    // swift: Render/Office/DocxReader.swift:2302-2306
    // swift: Render/Office/DocxReader.swift:2308-2311
    // swift: Render/Office/DocxReader.swift:2313-2320
    // swift: Render/Office/DocxReader.swift:2336-2336
    // swift: Render/Office/DocxReader.swift:2353-2353
    // swift: Render/Office/DocxReader.swift:2365-2372
    // swift: Render/Office/DocxReader.swift:2403-2403
    // swift: Render/Office/DocxReader.swift:2552-2561
    // swift: Render/Office/DocxReader.swift:2569-2577
    // swift: Render/Office/DocxReader.swift:2781-2792
    // swift: Render/Office/DocxReader.swift:2796-2802
    // swift: Render/Office/DocxReader.swift:2806-2829
    // swift: Render/Office/DocxReader.swift:2857-2861
    // swift: Render/Office/DocxReader.swift:2879-2884
    // swift: Render/Office/DocxReader.swift:2893-2900
    // swift: Render/Office/DocxReader.swift:2907-2914
    // swift: Render/Office/DocxReader.swift:2929-2938
    // swift: Render/Office/DocxReader.swift:2944-2968
    // swift: Render/Office/DocxReader.swift:2993-2999
    // swift: Render/Office/DocxReader.swift:3017-3024
    // swift: Render/Office/DocxReader.swift:3038-3057
    // swift: Render/Office/DocxReader.swift:3324-3340
    // swift: Render/Office/DocxReader.swift:3349-3387
    // swift: Render/Office/DocxReader.swift:3414-3414
    // swift: Render/Office/DocxReader.swift:3487-3487
    // swift: Render/Office/DocxReader.swift:3562-3563
    // swift: Render/Office/DocxReader.swift:3569-3570
    // swift: Render/Office/DocxReader.swift:3580-3602
    // swift: Render/Office/DocxReader.swift:3604-3607
    // swift: Render/Office/DocxReader.swift:3611-3615
    // swift: Render/Office/DocxReader.swift:3625-3626
    // swift: Render/Office/DocxReader.swift:3631-3635
    // swift: Render/Office/DocxReader.swift:3663-3663
    // swift: Render/Office/DocxReader.swift:3665-3665
    // swift: Render/Office/DocxReader.swift:3671-3671
    // swift: Render/Office/DocxReader.swift:3677-3677
    // swift: Render/Office/DocxReader.swift:3683-3683
    // swift: Render/Office/DocxReader.swift:3690-3692
    // swift: Render/Office/DocxReader.swift:3703-3706
    // swift: Render/Office/DocxReader.swift:3726-3729
    // swift: Render/Office/DocxReader.swift:3758-3759
    // swift: Render/Office/DocxReader.swift:3770-3770
    // swift: Render/Office/DocxReader.swift:3776-3776
    // swift: Render/Office/DocxReader.swift:3782-3782
    // swift: Render/Office/DocxReader.swift:3788-3790
    // swift: Render/Office/DocxReader.swift:3797-3799
    // swift: Render/Office/DocxReader.swift:3815-3815
    // swift: Render/Office/DocxReader.swift:3828-3828
    // swift: Render/Office/DocxReader.swift:3833-3834
    // swift: Render/Office/DocxReader.swift:3836-3838
    // swift: Render/Office/DocxReader.swift:3842-3844
    // swift: Render/Office/DocxReader.swift:3848-3849
    // swift: Render/Office/DocxReader.swift:3860-3863
    // swift: Render/Office/DocxReader.swift:3868-3868
    // swift: Render/Office/DocxReader.swift:3873-3875
    // swift: Render/Office/DocxReader.swift:3884-3886
    // swift: Render/Office/DocxReader.swift:3895-3899
    // swift: Render/Office/DocxReader.swift:3908-3909
    // swift: Render/Office/DocxReader.swift:3913-3915
    // swift: Render/Office/DocxReader.swift:3926-3928
    // swift: Render/Office/DocxReader.swift:3932-3932
    // swift: Render/Office/DocxReader.swift:3938-3938
}

// ================================================================================================
// MARK: Images — w:drawing (DrawingML) and w:pict (legacy VML)
// swift: Render/Office/DocxReader.swift:1976-1976
// ================================================================================================

impl super::DocxReader {
    /// Descends into `mc:AlternateContent` via `mc:Choice` ONLY, never `mc:Fallback` — the two
    /// are alternative renderings of the SAME content (modern DrawingML vs. legacy VML, for a
    /// reader that doesn't understand the newer one), not two pieces of content. Walking both is
    /// the classic bug here: it turns every picture — or text box — in a document that carries
    /// this construct into two. A standalone `w:pict` (no `mc:AlternateContent` wrapper at all —
    /// common in documents saved by, or round-tripped through, an older Word) is genuine content
    /// and IS collected.
    ///
    /// A `w:drawing`/`w:pict` that resolves to no picture at all is NOT automatically an image —
    /// an AutoShape/text-box group is common (a callout box, a decorative rule) and reserving
    /// image space with a broken-picture placeholder for one would tell the reader a picture
    /// failed to load when there never was one. Such a shape contributes its TEXT instead, if it
    /// has any (`w:txbxContent`); a chart or SmartArt diagram (no picture, no text either) gets
    /// `graphicPlaceholderBlock` instead of nothing at all — but only when `allowGraphicPlaceholder`
    /// says this is the right point in the walk to decide that (see below).
    ///
    /// `allowGraphicPlaceholder` exists because `mc:AlternateContent` needs three-way, not
    /// two-way, resolution — `mc:Choice` handled normally when it renders SOMETHING; failing that,
    /// `mc:Fallback` (Word's own already-rendered VML picture of the very chart/diagram `mc:Choice`
    /// couldn't be drawn from — reachable for the first time by this sprint); only when NEITHER
    /// yields anything does a placeholder get drawn. Recursing into `mc:Choice`/`mc:Fallback` with
    /// `allowGraphicPlaceholder: false` lets this same function do the picture-then-text resolution
    /// for each half without either one jumping ahead to a placeholder on its own — the
    /// `mc:AlternateContent` case below is the ONLY place that decides "neither half gave us
    /// anything, use the placeholder", exactly once per `mc:AlternateContent`, from the CHOICE
    /// half's own declared size (Word always duplicates `wp:extent` onto both halves, but Choice is
    /// the modern, up-to-date wrapper and is preferred for consistency with the "Choice wins" rule
    /// everywhere else in this function).
    // swift: Render/Office/DocxReader.swift:2005-2094
    fn collect_drawing_blocks(
        node: &XMLNode,
        style_info: &StyleInfo,
        numbering: &NumberingInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
        allow_graphic_placeholder: bool,
    ) -> Vec<OfficeBlock> {
        let mut blocks: Vec<OfficeBlock> = Vec::new();

        fn walk(
            node: &XMLNode,
            style_info: &StyleInfo,
            numbering: &NumberingInfo,
            relationships: &Relationships,
            notes: &NoteNumbering,
            comments: &CommentRangeTracking,
            list_state: &swiftshim::Ref<ListNumberingState>,
            allow_graphic_placeholder: bool,
            blocks: &mut Vec<OfficeBlock>,
        ) {
            for child in &node.children {
                match child.name.as_str() {
                    "mc:AlternateContent" => {
                        let Some(choice) = child.child("mc:Choice") else { continue };
                        let choice_blocks = super::DocxReader::collect_drawing_blocks(
                            choice, style_info, numbering, relationships, notes, comments,
                            list_state, false,
                        );
                        if !choice_blocks.is_empty() {
                            blocks.extend(choice_blocks);
                            continue;
                        }
                        // Choice gave us nothing renderable (the chart/diagram case) — reach for the
                        // Fallback Word left for exactly this situation: an older reader's rendering,
                        // most often a `w:pict`/VML picture of the SAME chart/diagram, walked through
                        // the identical "w:pict" case below (so its own picture-vs-text resolution,
                        // and any relationship-id lookup, is reused unchanged, not reimplemented here).
                        let fallback_blocks = match child.child("mc:Fallback") {
                            Some(fallback) => super::DocxReader::collect_drawing_blocks(
                                fallback, style_info, numbering, relationships, notes, comments,
                                list_state, false,
                            ),
                            None => Vec::new(),
                        };
                        if !fallback_blocks.is_empty() {
                            blocks.extend(fallback_blocks);
                        } else if allow_graphic_placeholder {
                            if let Some(drawing) = choice.first_descendant("w:drawing") {
                                if let Some(placeholder) =
                                    super::DocxReader::graphic_placeholder_block(drawing)
                                {
                                    blocks.push(placeholder);
                                }
                            }
                        }
                    }
                    "w:drawing" => {
                        // A picture and a text box are NOT mutually exclusive within one `w:drawing` —
                        // a group can hold a `pic:pic` (say, a background photo) alongside a `wps:wsp`
                        // carrying `w:txbxContent` (a caption on top of it), as separate siblings. Both
                        // are always computed and both survive, picture(s) first then text, in the
                        // drawing's own document order; a placeholder is reached only when NEITHER
                        // produced anything (unchanged from before).
                        let pictures =
                            super::DocxReader::image_blocks_from_drawing(child, relationships);
                        let text = super::DocxReader::text_box_blocks(
                            child, style_info, numbering, relationships, notes, comments,
                            list_state,
                        );
                        if !pictures.is_empty() || !text.is_empty() {
                            blocks.extend(pictures);
                            blocks.extend(text);
                            continue;
                        }
                        if allow_graphic_placeholder {
                            if let Some(placeholder) =
                                super::DocxReader::graphic_placeholder_block(child)
                            {
                                // A chart/diagram with no `mc:AlternateContent` wrapper at all (some
                                // producers emit one without the legacy-fallback ceremony) — there is no
                                // Fallback to try, so this is the placeholder's only chance to appear.
                                blocks.push(placeholder);
                            }
                        }
                    }
                    "w:pict" => {
                        // Same "both survive" rule as `w:drawing` above — a legacy VML picture and a
                        // legacy VML text box are two different child elements of `w:pict` and neither
                        // one's presence should suppress the other.
                        let picture =
                            super::DocxReader::image_block_from_pict(child, relationships);
                        if let Some(picture) = picture {
                            blocks.push(picture);
                        }
                        blocks.extend(super::DocxReader::text_box_blocks(
                            child, style_info, numbering, relationships, notes, comments,
                            list_state,
                        ));
                    }
                    _ => walk(
                        child, style_info, numbering, relationships, notes, comments,
                        list_state, allow_graphic_placeholder, blocks,
                    ),
                }
            }
        }

        walk(
            node, style_info, numbering, relationships, notes, comments, list_state,
            allow_graphic_placeholder, &mut blocks,
        );
        blocks
    }

    /// Detects a `w:drawing` whose content is a chart or SmartArt diagram graphicFrame — DrawingML
    /// this reader has no vector renderer for. Neither has an `a:blip` (a picture) nor a
    /// `w:txbxContent` (typed caption text), so `imageBlocks`/`textBoxBlocks` both return empty and
    /// — absent this — the whole object vanishes with no trace at all (gap-list rows 11/12: every
    /// box, label and connector of a SmartArt diagram, or an entire embedded chart, silently gone).
    ///
    /// Detected by the DrawingML element the chart/diagram part is actually REFERENCED through —
    /// `c:chart` (a chart's `r:id` back to `word/charts/chartN.xml`) or `dgm:relIds` (a SmartArt
    /// diagram's `r:dm`/`r:lo`/`r:qs`/`r:cs` back to `word/diagrams/*.xml`) — never by
    /// `a:graphicData`'s `uri` string, which is a full schema URL this reader would otherwise have
    /// to string-match loosely for no real gain (the two element names are exact and unambiguous).
    /// Returns `nil` for anything else — an AutoShape/connector group with no picture and no typed
    /// text (already covered by `textBoxBlocks`'s own tests) is legitimately EMPTY, not a graphic
    /// this reader failed to render; placeholder-ing it would misreport "something is missing here"
    /// for a callout box the author genuinely left blank.
    // swift: Render/Office/DocxReader.swift:2095-2113
    fn graphic_placeholder_block(drawing: &XMLNode) -> Option<OfficeBlock> {
        let label: &str;
        if drawing.first_descendant("c:chart").is_some() {
            label = "Chart";
        } else if drawing.first_descendant("dgm:relIds").is_some() {
            label = "Diagram";
        } else {
            return None;
        }
        // Same element, same units, same conversion `imageBlocks` reads its own picture sizing
        // from — a chart/diagram graphicFrame carries `wp:extent` on the identical
        // `wp:inline`/`wp:anchor` wrapper a picture would.
        let extent = drawing.first_descendant("wp:extent")?;
        let cx: f64 = extent.attributes.get("cx")?.parse().ok()?;
        let cy: f64 = extent.attributes.get("cy")?.parse().ok()?;
        Some(OfficeBlock::UnsupportedGraphic {
            label: label.into(),
            size: CGSize::new(Self::emu_to_points(cx), Self::emu_to_points(cy)),
            alignment: None,
        })
    }

    /// A shape's caption/callout text lives in `w:txbxContent` (one or more, nested arbitrarily
    /// deep inside `wps:wsp`/`wpg:wgp`) — routed through the SAME body-level dispatch
    /// (`parseBodyChild`) the document body itself uses, rather than only handling its `w:p`
    /// children directly: OOXML permits a `w:tbl` as a direct child of `w:txbxContent` too (a table
    /// typed inside a text box), and `parseBodyChild` already knows how to turn that into a real
    /// `.table` block via `parseTable` — no parallel mini-parser, no special case, and a text box
    /// carrying a list or an `w:sdt`-wrapped paragraph is handled the identical way. Rendered
    /// INLINE, in the text box's own document order — this reader does not attempt the shape's
    /// float/wrap position (invariant 31 measured that path too expensive and deliberately unshipped;
    /// a text box is not an exception to it). An empty paragraph here (Word leaves a placeholder
    /// `<w:p/>` in the text frame of an otherwise-empty AutoShape) is real content in the document
    /// BODY but not here — a shape with nothing typed into it has no text, and must produce no
    /// block; the body's own "empty paragraph = a blank line" reading does not apply to shape
    /// decoration. `isEmptyTextBlock` only ever filters a text/heading/list block with no spans —
    /// a `.table` block from a text box's own `w:tbl` always survives, empty visual rows included,
    /// exactly like an ordinary body table.
    // swift: Render/Office/DocxReader.swift:2130-2148
    fn text_box_blocks(
        node: &XMLNode,
        style_info: &StyleInfo,
        numbering: &NumberingInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
    ) -> Vec<OfficeBlock> {
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        for txbx in node.all_descendants("w:txbxContent") {
            for child in &txbx.children {
                let child_blocks = super::DocxReader::parse_body_child(
                    child, style_info, numbering, relationships, notes, comments, list_state,
                );
                blocks.extend(
                    child_blocks
                        .into_iter()
                        .filter(|b| !super::DocxReader::is_empty_text_block(b)),
                );
            }
        }
        blocks
    }

    /// A text/heading/list block with no spans at all — used only to filter a text box's OWN
    /// placeholder-empty paragraph (see `textBoxBlocks`) out of what it contributes; an image or
    /// table block is never "empty" in this sense and always passes through.
    // swift: Render/Office/DocxReader.swift:2149-2158
    fn is_empty_text_block(block: &OfficeBlock) -> bool {
        match block {
            OfficeBlock::Paragraph { spans, .. } => spans.is_empty(),
            OfficeBlock::Heading { spans, .. } => spans.is_empty(),
            OfficeBlock::ListItem { spans, .. } => spans.is_empty(),
            OfficeBlock::Table { .. }
            | OfficeBlock::Image { .. }
            | OfficeBlock::UnsupportedGraphic { .. }
            | OfficeBlock::Formula { .. } => false,
        }
    }

    /// `wp:extent` (EMU) is present on both an inline (`wp:inline`) and a floating (`wp:anchor`)
    /// drawing, so it's read by name rather than by which wrapper it's under. No `wp:extent` means
    /// this isn't a shape this reader understands sizing for — silently produces no block, same as
    /// a run with no text at all producing no span. An empty result here also means "not a
    /// picture" to the caller, which then looks for text instead — so this must return `[]`, never
    /// an unresolvable placeholder, when there is no `a:blip` anywhere inside.
    ///
    /// A `w:drawing` isn't always ONE picture — Word groups multiple pictures under a single
    /// `w:drawing` (`wpg:wgp`) routinely (e.g. two logos placed side by side), and EVERY `a:blip`
    /// found inside is a real, separate picture that must not be silently merged into one or
    /// dropped (measured on the real government-guide test file: a single `w:drawing` there
    /// groups exactly two `pic:pic` elements, two DISTINCT embedded pictures). A picture inside a
    /// group is positioned and sized in that group's own LOCAL child coordinate space, not EMU —
    /// `groupScale`/`collectGroupedPictures` chain the real transform (every nested group's own
    /// `ext ÷ chExt`) down to each picture rather than approximating with the group's outer box.
    // swift: Render/Office/DocxReader.swift:2173-2196
    fn image_blocks_from_drawing(
        drawing: &XMLNode,
        relationships: &Relationships,
    ) -> Vec<OfficeBlock> {
        let Some(extent) = drawing.first_descendant("wp:extent") else { return Vec::new() };
        let (Some(cx), Some(cy)) = (
            extent.attributes.get("cx").and_then(|v| v.parse::<f64>().ok()),
            extent.attributes.get("cy").and_then(|v| v.parse::<f64>().ok()),
        ) else {
            return Vec::new();
        };
        let whole_drawing_size =
            CGSize::new(Self::emu_to_points(cx), Self::emu_to_points(cy));
        let Some(outer_group) = drawing.first_descendant("wpg:wgp") else {
            // No group — by far the common case, a single inline/floating picture whose own box
            // IS the drawing's `wp:extent`. (Still collects every `a:blip`, not just the first,
            // in case Word ever emits more than one ungrouped — no real file exercises that, but
            // nothing here assumes exactly one.)
            return drawing
                .all_descendants("a:blip")
                .into_iter()
                .map(|blip| OfficeBlock::Image {
                    id: Self::resolve_id(
                        blip.attributes
                            .get("r:embed")
                            .or_else(|| blip.attributes.get("r:link"))
                            .cloned(),
                        relationships,
                    )
                    .into(),
                    size: whole_drawing_size,
                    alignment: None,
                })
                .collect();
        };
        let mut images: Vec<OfficeBlock> = Vec::new();
        let scale = Self::group_scale(outer_group).unwrap_or(AxisScale { x: 1.0, y: 1.0 });
        Self::collect_grouped_pictures(
            outer_group, scale, whole_drawing_size, relationships, &mut images,
        );
        images
    }

    /// The multiplier that converts a value expressed in THIS group's own child-coordinate units
    /// (`wpg:grpSpPr/a:xfrm`'s `chOff`/`chExt`) into the units its OWN `off`/`ext` are expressed
    /// in (its parent's child units, or real EMU at the outermost group) — i.e. one link in the
    /// nested-group transform chain. `nil` when the group carries no usable `a:xfrm` (missing, or
    /// a degenerate `chExt` of 0 on an axis) — the caller then chains through unchanged on that
    /// axis rather than dividing by zero, which is a defensible "no additional scaling known"
    /// reading, not a crash.
    // swift: Render/Office/DocxReader.swift:2203-2212
    fn group_scale(group: &XMLNode) -> Option<AxisScale> {
        let xfrm = group.child("wpg:grpSpPr")?.child("a:xfrm")?;
        let ext = xfrm.child("a:ext")?;
        let ch_ext = xfrm.child("a:chExt")?;
        let ext_cx: f64 = ext.attributes.get("cx")?.parse().ok()?;
        let ext_cy: f64 = ext.attributes.get("cy")?.parse().ok()?;
        let ch_ext_cx: f64 = ch_ext.attributes.get("cx")?.parse().ok()?;
        let ch_ext_cy: f64 = ch_ext.attributes.get("cy")?.parse().ok()?;
        Some(AxisScale {
            x: if ch_ext_cx == 0.0 { 1.0 } else { ext_cx / ch_ext_cx },
            y: if ch_ext_cy == 0.0 { 1.0 } else { ext_cy / ch_ext_cy },
        })
    }

    /// Walks one group's DIRECT children: a nested `wpg:grpSp` multiplies `scale` by its OWN
    /// `groupScale` and recurses (chaining the transform one more level down before it reaches
    /// any picture inside it); a `pic:pic` is sized by its own `pic:spPr/a:xfrm/a:ext` — read as a
    /// PRECISE direct-child path, never a broad descendant search, because `a:blip/a:extLst/a:ext`
    /// is an unrelated extension-marker element that also happens to be named `a:ext` and sits
    /// EARLIER in the same picture (an unqualified search would silently grab attributes with no
    /// `cx`/`cy` and look like "no size" instead of the real one) — converted with the accumulated
    /// `scale`. A picture that (unusually) carries no own `a:xfrm/a:ext` falls back to
    /// `fallbackSize` (the whole drawing's `wp:extent`) rather than a zero. Anything else at this
    /// level (`wps:wsp` — a connecting line, a plain AutoShape with no picture) contributes no
    /// image; its text, if any, is handled separately by `textBoxBlocks`.
    // swift: Render/Office/DocxReader.swift:2224-2250
    fn collect_grouped_pictures(
        group: &XMLNode,
        scale: AxisScale,
        fallback_size: CGSize,
        relationships: &Relationships,
        images: &mut Vec<OfficeBlock>,
    ) {
        for child in &group.children {
            match child.name.as_str() {
                "wpg:grpSp" => {
                    let nested_scale = match Self::group_scale(child) {
                        Some(inner) => AxisScale { x: scale.x * inner.x, y: scale.y * inner.y },
                        None => scale,
                    };
                    Self::collect_grouped_pictures(
                        child, nested_scale, fallback_size, relationships, images,
                    );
                }
                "pic:pic" => {
                    let Some(blip) = child.first_descendant("a:blip") else { continue };
                    let rel_id = blip
                        .attributes
                        .get("r:embed")
                        .or_else(|| blip.attributes.get("r:link"))
                        .cloned();
                    let own_ext = child
                        .child("pic:spPr")
                        .and_then(|n| n.child("a:xfrm"))
                        .and_then(|n| n.child("a:ext"));
                    let size = match own_ext.and_then(|ext| {
                        let cx: f64 = ext.attributes.get("cx")?.parse().ok()?;
                        let cy: f64 = ext.attributes.get("cy")?.parse().ok()?;
                        Some((cx, cy))
                    }) {
                        Some((cx, cy)) => CGSize::new(
                            Self::emu_to_points(cx * scale.x),
                            Self::emu_to_points(cy * scale.y),
                        ),
                        None => fallback_size,
                    };
                    images.push(OfficeBlock::Image {
                        id: Self::resolve_id(rel_id, relationships).into(),
                        size,
                        alignment: None,
                    });
                }
                _ => continue,
            }
        }
    }

    /// A best-defensible non-zero fallback for a VML shape whose `style` is missing or doesn't
    /// parse — invariant 1 (never reserve a zero/collapsed area) applies just as much to a legacy
    /// shape this reader can't size as to a not-yet-loaded markdown image. One inch square is
    /// arbitrary but visible and stable; there is no better signal available in that case.
    // swift: Render/Office/DocxReader.swift:2257-2258
    const UNRESOLVED_VML_SIZE: CGSize = CGSize { width: 72.0, height: 72.0 };

    /// Legacy VML: the image reference is `v:imagedata/@r:id` (note `r:id`, not `r:embed` —
    /// VML predates the DrawingML relationship-attribute convention), and the size lives on the
    /// enclosing shape's CSS-like `style` attribute (`v:shape`/`v:rect`/…) rather than a
    /// dedicated extent element, so it's found by attribute rather than by element name. A single
    /// `w:pict` CAN itself group several `v:imagedata` (mirroring the DrawingML case above), but
    /// that only happens here as the Fallback half of an `mc:AlternateContent` this reader never
    /// descends into (see `collectImages`) — a genuinely standalone multi-picture VML group is not
    /// exercised by either real test file, so only the first `v:imagedata` is read; a document that
    /// hits this would still get one correctly-sized picture, not a crash or a dropped block.
    // swift: Render/Office/DocxReader.swift:2271-2276
    fn image_block_from_pict(pict: &XMLNode, relationships: &Relationships) -> Option<OfficeBlock> {
        let imagedata = pict.first_descendant("v:imagedata")?;
        let style_node = pict.first_descendant_with_attribute("style");
        let size = style_node
            .and_then(|n| n.attributes.get("style"))
            .and_then(|s| Self::parse_vml_style_size(Some(s)))
            .unwrap_or(Self::UNRESOLVED_VML_SIZE);
        Some(OfficeBlock::Image {
            id: Self::resolve_id(imagedata.attributes.get("r:id").cloned(), relationships).into(),
            size,
            alignment: None,
        })
    }

    /// A relationship id resolves to the archive entry path for an embedded image, to
    /// `"docx-unresolvable:…"` for anything this reader genuinely cannot hand pixels for (no id on
    /// the element at all, or an id that doesn't appear in `document.xml.rels` — a malformed/edited
    /// document), or to `"docx-external-link:…"` for a real, external (`r:link`) target — every one
    /// of these still returns a block, never nil, so a picture never silently vanishes from the
    /// block list. `MarkdownDocument`'s image loader treats the first prefix as "always show a
    /// sized placeholder, never attempt an archive lookup" and the second as "try the folder-grant
    /// path a blocked local image already has, using the raw target as the URL to resolve".
    // swift: Render/Office/DocxReader.swift:2286-2300
    fn resolve_id(rel_id: Option<String>, relationships: &Relationships) -> String {
        let Some(rel_id) = rel_id else { return Self::unresolvable_id("no-relationship-id") };
        let Some(rel) = relationships.by_id.get(&rel_id) else {
            return Self::unresolvable_id(&rel_id);
        };
        // A `r:link` (external target, `TargetMode="External"`) is a REAL, resolvable reference —
        // unlike the two cases above, this isn't a malformed document, just one whose pixels live
        // OUTSIDE this archive (under the sandbox, unreadable, and macOS never prompts — see
        // CLAUDE.md invariant 9). Marked with its OWN prefix, never `docx-unresolvable:`, so the
        // viewer can tell "this document points somewhere real, just can't reach it yet" apart
        // from "this reference doesn't resolve to anything at all" — only the former can offer the
        // SAME folder-grant placeholder a blocked markdown sibling image already gets
        // (`FolderAccess`/`needsAccessImage()` in `MarkdownDocument`), reused rather than a second
        // "broken image" convention invented for this one case.
        if rel.external { Self::external_link_id(&rel.target) } else { rel.target.clone() }
    }

    // swift: Render/Office/DocxReader.swift:2301-2301
    fn unresolvable_id(reason: &str) -> String {
        format!("docx-unresolvable:{reason}")
    }

    /// A linked (not embedded) image's id — carries the RAW target exactly as
    /// `word/_rels/document.xml.rels` wrote it (a `file:///…` or `http(s)://…` URL), prefixed so
    /// `MarkdownDocument`'s image loader can route it to the folder-grant placeholder instead of
    /// the generic broken-image icon `docx-unresolvable:` ids fall back to.
    // swift: Render/Office/DocxReader.swift:2307-2307
    fn external_link_id(target: &str) -> String {
        format!("docx-external-link:{target}")
    }

    /// EMU (English Metric Units) is DrawingML's native length unit: 914400 per inch, 12700 per
    /// point (72 pt/inch × 12700 = 914400). Verified against the real test file: `cx="6400800"`
    /// (a 7-inch-wide picture) must yield exactly 504 pt.
    // swift: Render/Office/DocxReader.swift:2312-2312
    fn emu_to_points(emu: f64) -> CGFloat {
        emu / 12700.0
    }

    /// A `v:shape`-family `style` attribute is CSS-like declarations (`"width:7in;height:185.25pt"`),
    /// not real CSS — but `in`/`pt`/`px`/`cm`/`mm` behave like their CSS namesakes. A BARE number
    /// (no unit suffix, e.g. `width:1665`) is treated as points: that's Word's own convention for
    /// most unmarked VML dimensions, though a handful of older shapes instead use it as a drawing
    /// COORDINATE (relative to `coordsize`), which this does not attempt to detect — there is no
    /// reliable signal in the shape alone to tell the two apart, so the point-based reading is used
    /// as the best-defensible value rather than fabricating a zero.
    // swift: Render/Office/DocxReader.swift:2321-2335
    fn parse_vml_style_size(style: Option<&str>) -> Option<CGSize> {
        let style = style?;
        let mut width: Option<CGFloat> = None;
        let mut height: Option<CGFloat> = None;
        for declaration in style.split(';') {
            let mut parts = declaration.splitn(2, ':');
            let (Some(property), Some(value)) = (parts.next(), parts.next()) else { continue };
            let property = property.trim();
            let value = Self::parse_css_like_length(value.trim());
            if property == "width" { width = value; }
            if property == "height" { height = value; }
        }
        match (width, height) {
            (Some(width), Some(height)) => Some(CGSize::new(width, height)),
            _ => None,
        }
    }

    // swift: Render/Office/DocxReader.swift:2337-2351
    fn parse_css_like_length(raw: &str) -> Option<CGFloat> {
        // Longest-suffix-first: "in" isn't a prefix collision here, but this keeps the table
        // self-evidently order-independent if a two-letter unit is ever added.
        let points_per_unit: [(&str, f64); 5] =
            [("in", 72.0), ("pt", 1.0), ("px", 0.75), ("cm", 72.0 / 2.54), ("mm", 72.0 / 25.4)];
        for (suffix, factor) in points_per_unit {
            if let Some(stripped) = raw.strip_suffix(suffix) {
                let number: f64 = stripped.parse().ok()?;
                return Some(number * factor);
            }
        }
        // No unit suffix — see the point-based fallback note on the caller.
        raw.parse().ok()
    }

    // ============================================================================================
    // MARK: word/document.xml — body → blocks
    // swift: Render/Office/DocxReader.swift:2352-2352
    // ============================================================================================

    // swift: Render/Office/DocxReader.swift:2354-2364
    pub(crate) fn parse_body(
        body: &XMLNode,
        style_info: &StyleInfo,
        numbering: &NumberingInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
    ) -> Vec<OfficeBlock> {
        body.children
            .iter()
            .flat_map(|c| {
                Self::parse_body_child(
                    c, style_info, numbering, relationships, notes, comments, list_state,
                )
            })
            .collect()
    }

    /// A body child is normally `w:p` or `w:tbl`. `w:sdt` (a content control / structured document
    /// tag) is UNWRAPPED here, never skipped — Word uses it to wrap a whole paragraph or table (a
    /// "click here to enter text" field, a repeating-section template) inside `w:sdtContent`, and a
    /// reader that treats the wrapper as opaque loses everything the author typed inside it, which
    /// is exactly the class of bug this sprint exists to close. Recurses so a content control
    /// nested inside another one is unwrapped all the way down; `w:sdtPr` (placeholder-text hints,
    /// a lock setting, …) is deliberately never read — the only thing needed from `w:sdt` is its
    /// content. Anything else at this level (the body's own trailing `w:sectPr`) is not a block.
    // swift: Render/Office/DocxReader.swift:2373-2402
    pub(crate) fn parse_body_child(
        child: &XMLNode,
        style_info: &StyleInfo,
        numbering: &NumberingInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
    ) -> Vec<OfficeBlock> {
        match child.name.as_str() {
            "w:p" => Self::parse_paragraph(
                child, style_info, numbering, relationships, notes, comments, list_state,
            ),
            "w:tbl" => vec![Self::parse_table(
                child, style_info, numbering, relationships, notes, comments, list_state,
            )],
            "w:sdt" => {
                let Some(content) = child.child("w:sdtContent") else { return Vec::new() };
                content
                    .children
                    .iter()
                    .flat_map(|c| {
                        Self::parse_body_child(
                            c, style_info, numbering, relationships, notes, comments, list_state,
                        )
                    })
                    .collect()
            }
            _ => Vec::new(),
        }
    }

    /// A paragraph normally contributes exactly one block, but one carrying an image contributes
    /// its text block (if it has any text) FOLLOWED BY that image's block(s), in source order —
    /// never reordering the paragraph's own text to make room for the picture. A paragraph that
    /// carries ONLY a picture (spans empty, the common case: Word puts an image in a paragraph of
    /// its own) contributes no empty text block, so callers never see a phantom `.paragraph(spans: [])`
    /// standing in for a picture.
    // swift: Render/Office/DocxReader.swift:2404-2536
    fn parse_paragraph(
        p: &XMLNode,
        style_info: &StyleInfo,
        numbering: &NumberingInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
    ) -> Vec<OfficeBlock> {
        let p_pr = p.child("w:pPr");
        // Read directly off THIS paragraph's own `w:pPr` — not resolved through the `w:basedOn`
        // style chain `resolvedOutlineLevel` walks for headings. Word's RTL-paragraph toggle writes
        // `w:bidi` onto the paragraph itself when applied from the UI; a style-level default that
        // ALSO needs the basedOn chain to reach it is a real possibility this reader doesn't yet
        // resolve — narrower than "wrong", but worth stating rather than silently assuming.
        let rtl = Self::is_on(p_pr, "w:bidi");
        // `pStyleId` is read here for `alignment`/`tabStops`' style-chain fallback below; `collectSpans`
        // reads its own copy off `p`'s `w:pPr` directly (see its doc) rather than receiving it as a
        // parameter, but it is the SAME value — both read the identical `w:pPr/w:pStyle` off the
        // identical paragraph node.
        let p_style_id_for_alignment = p_pr
            .and_then(|n| n.child("w:pStyle"))
            .and_then(|n| n.attributes.get("w:val"))
            .cloned();
        // An EXPLICIT `w:jc` on this paragraph always wins; failing that, the style chain (S13's
        // `basedOn` walk, reused via `resolvedAlignment`) — never a hardcoded `.left`. This is what
        // must win over `rtl`'s own implicit edge (see `OfficeBlock`'s doc): `OfficeTextBuilder`
        // already gives an explicit `alignment` that precedence, so resolving it correctly here is
        // the whole of this reader's part of that contract.
        let alignment = p_pr
            .and_then(|n| n.child("w:jc"))
            .and_then(|n| n.attributes.get("w:val"))
            .and_then(|v| Self::alignment_from_jc(v))
            .or_else(|| {
                Self::resolved_alignment(p_style_id_for_alignment.clone(), style_info)
            });
        let tab_stops: Vec<TabStop> = {
            let mut stops: Vec<TabStop> = Vec::new();
            if let Some(tabs_node) = p_pr.and_then(|n| n.child("w:tabs")) {
                stops = Self::parse_tab_stops(tabs_node);
            }
            if stops.is_empty() {
                stops = Self::resolved_tab_stops(p_style_id_for_alignment.clone(), style_info)
                    .unwrap_or_default();
            }
            stops
        };
        let spans =
            Self::collect_spans(p, style_info, relationships, notes, comments);
        // The graphics this paragraph produced inherit ITS alignment (a centred figure is the norm in
        // a report and used to render hard left — see `OfficeBlock.image`'s `alignment`). Stamped
        // here rather than inside `collectDrawingBlocks`, which recurses through runs, alternate
        // content and fallbacks and has no business knowing a paragraph-level property.
        let drawing_blocks: Vec<OfficeBlock> = Self::collect_drawing_blocks(
            p, style_info, numbering, relationships, notes, comments, list_state, true,
        )
        .into_iter()
        .map(|b| b.aligning_graphic(alignment))
        .collect();
        // A display equation (`m:oMathPara`) is collected separately from `spans`, not folded into
        // them — `collectSpans` deliberately SKIPS `m:oMathPara` (see its own switch) so its content
        // is never also flattened into plain text there; a bare inline `m:oMath` takes the opposite
        // path (degraded to a `Span` INSIDE `spans` by `collectSpans` itself), matching this
        // sprint's inline-vs-block decision (see `WebBlock`'s doc / `OfficeBlock.formula`'s doc).
        let formula_blocks = Self::collect_formula_blocks(p);
        // Heading wins over list, even when the paragraph ALSO carries `w:numPr` — Word-authored
        // contracts routinely attach a multilevel list to their heading styles so "1. Definitions"
        // / "2.1 Interpretation" number themselves, and `outlineLvl` is the author's explicit
        // "this is a heading at level N"; `numPr` only says how it happens to be numbered. Word's
        // own navigation pane treats such a paragraph as a heading, not a list item, and the
        // heading level already carries the hierarchy a list level would have expressed. Losing
        // this precedence would drop every clause heading in such a document out of the outline
        // sidebar — silently, since parsing still "succeeds". `outlineLvl 9` is still not a
        // heading (see `headingLevel`), so that case correctly falls through to `.listItem` below.
        // A heading's own numbering IS now rendered into its text (reversing an earlier decision
        // recorded at this exact spot: "a heading's own numPr counter is deliberately NOT
        // advanced"). Word attaches a heading's clause numbering to its STYLE — `w:pPr/w:numPr` on
        // the `HeadingN` style definition itself, not repeated per paragraph — which is why
        // "1. 서비스 사용" / "1.1. 서비스 신규 신청" used to render with no leading number at all:
        // the numbering was there, just never looked up past the paragraph's own (usually absent)
        // `w:numPr`. `resolvedNumPr`, below, is what reaches it, walking the SAME `w:basedOn` chain
        // every other per-style property here climbs. The counter `numberedListInfo` advances for
        // a numbered heading is the exact same `listState` a LATER plain `.listItem` at that
        // numId/level continues from — correct, because Word's multilevel counters belong to the
        // numId, not to whether the paragraph carrying them happens to be a heading or an ordinary
        // list item (see `ListNumberingState`'s own doc).
        let p_style_id = p_pr
            .and_then(|n| n.child("w:pStyle"))
            .and_then(|n| n.attributes.get("w:val"))
            .cloned();
        // The P2 cascade (docDefaults → style chain → this paragraph's own direct `w:pPr`) —
        // resolved once per paragraph and reused for whichever of heading/listItem/paragraph this
        // turns out to be, exactly like `alignment`/`tabStops` above.
        let format =
            Self::resolved_paragraph_format(p_pr, p_style_id.clone(), style_info);
        let skip_empty_text = spans.is_empty() && (!drawing_blocks.is_empty() || !formula_blocks.is_empty());
        let text_block: Option<OfficeBlock>;
        if let Some(level) = Self::heading_level(p_pr, p_style_id.clone(), style_info) {
            let mut heading_spans = spans.clone();
            // Prepend the heading's own numbering marker — resolved through `resolvedNumPr`
            // (paragraph's own `w:numPr` first, else the style chain) and formatted by the SAME
            // `numberedListInfo` a plain list item uses, so `1.`/`1.1.`/`가.` count identically
            // either way. Guarded exactly like every other "unspecified → unchanged" cascade in
            // this reader (invariant 37): an empty heading (`skipEmptyText`'s own case) gets no
            // marker span to attach to; a `numId` that doesn't resolve, or resolves to `bullet`/
            // `none`/no `w:lvlText`, yields `nil`/`""` from `numberedListInfo` exactly as it does
            // for a `.listItem`, and produces no marker either — a document with no numbering
            // anywhere renders byte-identical to before this sprint. The marker span COPIES
            // `headingSpans[0]` and only replaces its text, so a numbered heading's "1." renders in
            // that heading's own font/size/weight/colour, never a reader-invented default; its
            // trailing separator is the level's own `w:suff` (space/nothing/tab), never a
            // hardcoded one.
            if !heading_spans.is_empty() {
                if let Some((num_id, ilvl)) =
                    Self::resolved_num_pr(p_pr, p_style_id.clone(), style_info)
                {
                    if let Some(num_id) = num_id {
                        if let Some((_ordered, marker)) = Self::numbered_list_info(
                            Some(num_id.clone()), ilvl, numbering, list_state,
                        ) {
                            if let Some(marker) = marker {
                                if !marker.is_empty() {
                                    let suff = Self::resolved_level(&num_id, ilvl, numbering)
                                        .map(|l| l.suff)
                                        .unwrap_or_else(|| "\t".to_string());
                                    let mut marker_span = heading_spans[0].clone();
                                    marker_span.text = format!("{marker}{suff}").into();
                                    heading_spans.insert(0, marker_span);
                                }
                            }
                        }
                    }
                }
            }
            text_block = if skip_empty_text {
                None
            } else {
                Some(OfficeBlock::Heading {
                    level: level as i64,
                    spans: heading_spans,
                    rtl,
                    alignment,
                    tab_stops: tab_stops.clone(),
                    format: format.clone(),
                })
            };
        } else if let Some(num_pr) = p_pr.and_then(|n| n.child("w:numPr")) {
            let ilvl: i32 = num_pr
                .child("w:ilvl")
                .and_then(|n| n.attributes.get("w:val"))
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let num_id = num_pr
                .child("w:numId")
                .and_then(|n| n.attributes.get("w:val"))
                .cloned();
            // `numberedListInfo` returns `nil` only for Word's `numId="0"` sentinel — "carries
            // `w:numPr` but is explicitly NOT numbered" — which reads as an ordinary paragraph,
            // never a list item.
            if let Some((ordered, marker)) =
                Self::numbered_list_info(num_id.clone(), ilvl, numbering, list_state)
            {
                text_block = if skip_empty_text {
                    None
                } else {
                    Some(OfficeBlock::ListItem {
                        level: ilvl as i64,
                        ordered,
                        spans: spans.clone(),
                        marker: marker.map(SwiftString::from),
                        rtl,
                        alignment,
                        tab_stops: tab_stops.clone(),
                        format: format.clone(),
                        numbering: None,
                    })
                };
            } else {
                text_block = if skip_empty_text {
                    None
                } else {
                    Some(OfficeBlock::Paragraph {
                        spans: spans.clone(),
                        rtl,
                        alignment,
                        tab_stops: tab_stops.clone(),
                        format: format.clone(),
                    })
                };
            }
        } else {
            text_block = if skip_empty_text {
                None
            } else {
                Some(OfficeBlock::Paragraph {
                    spans: spans.clone(),
                    rtl,
                    alignment,
                    tab_stops: tab_stops.clone(),
                    format: format.clone(),
                })
            };
        }
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        if let Some(text_block) = text_block {
            blocks.push(text_block);
        }
        blocks.extend(drawing_blocks);
        blocks.extend(formula_blocks);
        blocks
    }

    /// Finds every `m:oMathPara` (a display equation on its own line) anywhere inside a paragraph
    /// and translates each `m:oMath` it wraps into a `.formula` block — one block per equation, in
    /// document order. Deliberately shallow compared to `collectDrawingBlocks`: real documents put
    /// `m:oMathPara` directly as a `w:p` child, not buried inside `mc:AlternateContent`, but the
    /// generic `default: walk` still descends through anything unanticipated (a tracked-change
    /// wrapper, say) so an equation is never missed just because Word nested it one level deeper
    /// than expected. Does NOT recurse into `m:oMathPara` itself once found — its own children are
    /// exactly the `m:oMath` elements being collected, not further paragraph structure to walk.
    // swift: Render/Office/DocxReader.swift:2537-2551
    fn collect_formula_blocks(node: &XMLNode) -> Vec<OfficeBlock> {
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        fn walk(node: &XMLNode, blocks: &mut Vec<OfficeBlock>) {
            for child in &node.children {
                if child.name == "m:oMathPara" {
                    for o_math in child.children.iter().filter(|c| c.name == "m:oMath") {
                        blocks.push(super::DocxReader::formula_block(o_math));
                    }
                    continue;
                }
                walk(child, blocks);
            }
        }
        walk(node, &mut blocks);
        blocks
    }

    /// One `m:oMath` → one `.formula` block, with the SAME never-nothing fallback ladder every
    /// other content type in this reader uses: real LaTeX shape when the translation produced any
    /// (`OmmlTranslator.latex` already degrades unrecognized sub-constructs to their own text, so
    /// this is usually non-empty even for equations this translator only partially understands);
    /// failing that, the equation's flattened text as an ordinary paragraph; failing THAT — an
    /// `m:oMath` with no `m:t` anywhere in it at all — a literal, honest placeholder rather than a
    /// block that renders as nothing (the brief's explicit requirement: "an equation with no
    /// translatable content at all still produces something visible").
    // swift: Render/Office/DocxReader.swift:2562-2568
    fn formula_block(o_math: &XMLNode) -> OfficeBlock {
        let latex = OmmlTranslator::latex(o_math).trim().to_string();
        if !latex.is_empty() {
            return OfficeBlock::Formula { latex: latex.into() };
        }
        let text = OmmlTranslator::flatten_text(o_math).trim().to_string();
        if !text.is_empty() {
            return OfficeBlock::Paragraph {
                spans: vec![Span { text: text.into(), ..Default::default() }],
                rtl: false,
                alignment: None,
                tab_stops: Vec::new(),
                format: Default::default(),
            };
        }
        OfficeBlock::Paragraph {
            spans: vec![Span { text: "[equation]".into(), ..Default::default() }],
            rtl: false,
            alignment: None,
            tab_stops: Vec::new(),
            format: Default::default(),
        }
    }

    /// A grid position a row's own `<w:tc>` sequence doesn't literally cover — because `w:tcPr`
    /// carries an ANCHOR reference, not a grid coordinate — so this reader must derive each cell's
    /// starting grid column itself: walking a row's `<w:tc>` elements left to right, accumulating
    /// each one's own width (`w:gridSpan`, default 1) as it goes, is exactly that derivation. A
    /// well-formed row's cells always sum to the table's full grid width (a vertically-continuing
    /// cell still carries its own `<w:tc>` occupying its column, per spec), so this cumulative walk
    /// lands on the correct column even when two rows have a different NUMBER of `<w:tc>` (a
    /// horizontal merge changes how many `<w:tc>` a row needs without changing the grid it spans).
    // swift: Render/Office/DocxReader.swift:2578-2756
    fn parse_table(
        tbl: &XMLNode,
        style_info: &StyleInfo,
        numbering: &NumberingInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
    ) -> OfficeBlock {
        let row_nodes: Vec<&XMLNode> = tbl.children.iter().filter(|n| n.name == "w:tr").collect();
        let tbl_pr = tbl.child("w:tblPr");
        // The table's own default cell margin (`w:tblPr/w:tblCellMar`) — the MIDDLE layer a
        // per-cell `w:tcPr/w:tcMar` (read below, per cell) falls back to before `Cell.padding`
        // itself falls back to `nil` (and `TableBlockBuilder`'s pre-existing 7pt default).
        let table_default_margin =
            Self::cell_margin(tbl_pr.and_then(|n| n.child("w:tblCellMar")));
        // The SAME element, per-edge — feeds `TableFormat.defaultPadding` below, the PAGED model's
        // table-wide fallback layer beneath a cell's own `edgePadding`.
        //
        // Resolved through the STYLE CHAIN, not from `w:tblPr` alone, and that is the whole point:
        // Word puts its stock cell margin (`top=0 left=108 bottom=0 right=108`) in the DEFAULT TABLE
        // STYLE, so a table that writes no `w:tblCellMar` of its own — the common case — was reading
        // as "the document said nothing" and falling through to `TableBlockBuilder.defaultCellPadding`
        // (7pt) on all four edges. Measured on one real report: 14pt of vertical padding the document
        // had explicitly set to ZERO, which is the bulk of a 28.3pt row where Word draws 18.5pt.
        //
        // Order is Word's own: the table's direct `w:tblPr` beats its named `w:tblStyle` (walked up
        // `w:basedOn`, cycle-guarded by `walkStyleChain`) beats the default table style. The single
        // -value `tableDefaultMargin` above is deliberately NOT given the same treatment — it feeds
        // only the non-paged model, which invariant 37 requires to stay byte-identical.
        let table_style_id = tbl_pr
            .and_then(|n| n.child("w:tblStyle"))
            .and_then(|n| n.attributes.get("w:val"))
            .cloned();
        let table_default_edge_padding = Self::cell_edge_padding(
            tbl_pr.and_then(|n| n.child("w:tblCellMar")),
        )
        .or_else(|| {
            Self::walk_style_chain(table_style_id.clone(), style_info, |id| {
                style_info.table_cell_margins.get(id).cloned()
            })
        })
        .or_else(|| {
            style_info
                .default_table_style_id
                .as_deref()
                .and_then(|id| style_info.table_cell_margins.get(id).cloned())
        });
        let mut rows: Vec<Vec<Cell>> = Vec::new();
        // Parallel to `rows` — each anchor cell's own starting grid column, so a second pass
        // (below, after the grid's full row/column extent is known) can resolve its table-STYLE
        // shading/border (P5) by POSITION. Kept separate from `Cell` itself rather than folded
        // into it: a covered (merge-continued) position never gets an entry here either, exactly
        // mirroring `rows`' own anchor-only shape.
        let mut positions: Vec<Vec<usize>> = Vec::new();
        // The grid's total column count, discovered as the row walk below encounters `w:tc`/
        // `w:gridSpan` — the same quantity `tableGridColumnWidths` derives independently from
        // `w:tblGrid` when that part exists; this is the fallback for tables that don't declare
        // one (an un-styled table never needs it, so it costs nothing there).
        let mut max_grid_col: usize = 0;
        // Grid column → where in `rows` its currently-open vertical-merge anchor lives, so a
        // `continue` cell several rows down can find the top cell and extend ITS `rowSpan` instead
        // of becoming a cell of its own.
        let mut open_merge: std::collections::HashMap<usize, (usize, usize)> =
            std::collections::HashMap::new();
        for row in &row_nodes {
            let mut row_cells: Vec<Cell> = Vec::new();
            let mut row_positions: Vec<usize> = Vec::new();
            let mut grid_col: usize = 0;
            for tc in row.children.iter().filter(|n| n.name == "w:tc") {
                let tc_pr = tc.child("w:tcPr");
                let col_span: usize = tc_pr
                    .and_then(|n| n.child("w:gridSpan"))
                    .and_then(|n| n.attributes.get("w:val"))
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1);
                let v_merge = tc_pr.and_then(|n| n.child("w:vMerge"));
                // `w:vMerge` present with NO `w:val` — not `val="restart"` — is Word's default for
                // "this cell continues the merge above", the #1 footgun measured on the real corpus
                // (13 of 16 vertical merges omit `w:val` entirely). Reading a bare `<w:vMerge/>` as
                // the start of a fresh merge is the single most common docx-reader bug there is.
                let continues_merge = v_merge.is_some()
                    && v_merge.and_then(|n| n.attributes.get("w:val")).map(|s| s.as_str())
                        != Some("restart");
                if continues_merge {
                    // This cell's own paragraphs are read (`tc.children` below, if ever needed) but
                    // deliberately DISCARDED, never rendered — Word routinely leaves stale leftover
                    // text in a continue cell from before the merge existed, and showing it would
                    // draw a phantom extra line under a merged cell that visually has none. No cell
                    // is emitted for this grid position at all — it is covered, not empty.
                    if let Some(anchor) = open_merge.get(&grid_col).copied() {
                        rows[anchor.0][anchor.1].row_span += 1;
                    }
                    // No open merge at this column (a malformed/edited document) — there is nothing
                    // to extend, and a `continue` cell is never content of its own, so it is simply
                    // dropped rather than fabricated into a normal cell.
                } else {
                    let blocks = Self::collect_cell_blocks(
                        tc, style_info, numbering, relationships, notes, comments, list_state,
                    );
                    let (border_color, border_width) = Self::cell_border(tc_pr);
                    // Own `w:tcMar` wins; a cell that says nothing inherits the table's own default
                    // (already resolved above) rather than falling straight to `nil`.
                    let resolved_margin =
                        Self::cell_margin(tc_pr.and_then(|n| n.child("w:tcMar")))
                            .or(table_default_margin);
                    let mut cell = Cell {
                        blocks,
                        row_span: 1,
                        col_span: col_span as i64,
                        background_color: Self::cell_shading(tc_pr),
                        background_image: None,
                        border_color,
                        border_width,
                        edge_borders: None,
                        width: Self::cell_width(tc_pr),
                        vertical_alignment: Self::cell_valign(tc_pr),
                        padding: resolved_margin,
                        edge_padding: None,
                        diagonal: None,
                        style_shading: None,
                        style_border_color: None,
                        style_border_width: None,
                    };
                    // The same node read per EDGE — this is what the renderer actually uses when the
                    // document states its edges individually (the uniform pair above stays as the
                    // fallback for everything that doesn't).
                    cell.edge_borders =
                        Self::resolve_edge_borders(tc_pr.and_then(|n| n.child("w:tcBorders")));
                    // This CELL's own `w:tcMar`, per edge — deliberately NOT merged with the table's
                    // default here (unlike `resolvedMargin` above): `TableBlockBuilder`'s own PAGED
                    // resolution cascades cell-edge > table-edge > theme fallback itself, so merging
                    // the two here would just hide the table default's own doc-comment-visible layer.
                    cell.edge_padding =
                        Self::cell_edge_padding(tc_pr.and_then(|n| n.child("w:tcMar")));
                    row_cells.push(cell);
                    row_positions.push(grid_col);
                    if v_merge.is_some() {
                        // `val="restart"` — the top of a genuine new vertical-merge chain; later
                        // `continue` cells at this column extend THIS cell's `rowSpan`.
                        open_merge.insert(grid_col, (rows.len(), row_cells.len() - 1));
                    } else {
                        // An ORDINARY cell with no `w:vMerge` element at all is not part of any
                        // merge and can never be extended — it must not become continuable just
                        // because a later (malformed) row has a stray `continue` at this column.
                        // It also ends whatever chain was open here before it.
                        open_merge.remove(&grid_col);
                    }
                }
                grid_col += col_span;
                max_grid_col = max_grid_col.max(grid_col);
            }
            rows.push(row_cells);
            positions.push(row_positions);
        }
        // Defensive clamp: an anchor's `rowSpan` can never claim more rows than the table actually
        // has left below it. This reader's own construction above can't overshoot (it only grows a
        // `rowSpan` once per genuinely-encountered `continue` row, and there can never be more of
        // those than real rows), but a malformed/hand-edited document is exactly the kind of input
        // that must never be trusted to size itself — the same posture as never trusting a ZIP
        // entry's declared size.
        for r in 0..rows.len() {
            for c in 0..rows[r].len() {
                rows[r][c].row_span = rows[r][c].row_span.min((row_nodes.len() - r) as i64);
            }
        }
        // Leading run only — a header row can never follow an ordinary one, and the source is
        // trusted over any guess (an un-marked table defaults to `headerRows: 0`, never 1).
        let mut header_rows: i64 = 0;
        for row in &row_nodes {
            let is_header = row
                .child("w:trPr")
                .map(|n| n.children.iter().any(|c| c.name == "w:tblHeader"))
                .unwrap_or(false);
            if !is_header { break; }
            header_rows += 1;
        }
        let (table_border_color, table_border_width) = Self::table_border(tbl_pr);
        let mut format = TableFormat {
            default_border_color: table_border_color,
            default_border_width: table_border_width,
            default_shading: Self::cell_shading(tbl_pr),
            ..Default::default()
        };
        // The table-wide `w:tblCellMar` default, per edge — the PAGED model's fallback layer beneath
        // a cell's own `edgePadding` (see `Cell.edgePadding`'s own doc for the cascade).
        format.default_padding = table_default_edge_padding;
        // `w:tblBorders` per edge, INCLUDING `w:insideH`/`w:insideV` — the interior rules a cell
        // inherits when it is not on that side of the grid (the position test is the renderer's).
        format.edge_borders = Self::resolve_edge_borders(tbl_pr.and_then(|n| n.child("w:tblBorders")));
        // P5 — table-STYLE shading/border cascade (`w:tblStyle` + `w:tblStylePr` + `w:tblLook`).
        // A table with no named style (every markdown-sourced table, and most plain docx tables)
        // skips this entirely, leaving every cell's `styleShading`/`styleBorderColor`/
        // `styleBorderWidth` at their default `nil` — BYTE-IDENTICAL to before this cascade
        // existed. `rowCount`/`colCount` are the grid's own dimensions (not `rows.count`'s literal
        // anchor tally, which undercounts once any span is wider than 1 — see `positions`' doc).
        let grid_widths = Self::table_grid_column_widths(tbl);
        if let Some(tbl_style_id) = tbl_pr
            .and_then(|n| n.child("w:tblStyle"))
            .and_then(|n| n.attributes.get("w:val"))
        {
            if !rows.is_empty() {
                let col_count = if grid_widths.is_empty() { max_grid_col } else { grid_widths.len() };
                if col_count > 0 {
                    let look = Self::parse_tbl_look(tbl_pr);
                    for r in 0..rows.len() {
                        for c in 0..rows[r].len() {
                            let (shading, style_border_color, style_border_width) =
                                Self::resolve_cell_table_style(
                                    tbl_style_id,
                                    style_info,
                                    &look,
                                    r as i32,
                                    positions[r][c] as i32,
                                    row_nodes.len() as i32,
                                    col_count as i32,
                                    header_rows as i32,
                                );
                            rows[r][c].style_shading = shading;
                            rows[r][c].style_border_color = style_border_color;
                            rows[r][c].style_border_width = style_border_width;
                        }
                    }
                }
            }
        }
        // The table's own width as Word laid it out (`w:tblGrid` is already points here — twips ÷ 20).
        // A picture in a cell is scaled against THIS, not the page: the reader stretches every table
        // to fill the reading column, so a page-scaled picture would sit small in a cell that grew
        // around it (`TableFormat.sourceWidth`). Empty grid → nil → the page basis, as before.
        let grid_total: CGFloat = grid_widths.iter().sum();
        if grid_total > 0.0 { format.source_width = Some(grid_total); }
        OfficeBlock::Table { rows, header_rows, column_widths: grid_widths, format }
    }

    /// `w:tbl/w:tblGrid/w:gridCol/@w:w` — the table's OWN authoritative column widths (ECMA-376
    /// §17.4.48/§17.4.49), in document order, twips converted to points the same way `cellWidth`
    /// converts a per-cell `w:tcW` (÷20). This is what fixes jagged columns: `w:tcW` on individual
    /// cells routinely fails to sum to the table's full width, but `w:tblGrid` is what Word itself
    /// treats as the ground truth for how the columns are proportioned. No `w:tblGrid`, or one with
    /// no `w:gridCol` children at all, returns `[]` — "no grid known" — so `TableBlockBuilder` falls
    /// back to its pre-existing per-cell/auto layout rather than being handed an empty proportion
    /// to normalise against a zero sum.
    // swift: Render/Office/DocxReader.swift:2757-2776
    fn table_grid_column_widths(tbl: &XMLNode) -> Vec<CGFloat> {
        let Some(grid) = tbl.child("w:tblGrid") else { return Vec::new() };
        let cols: Vec<&XMLNode> = grid.children.iter().filter(|n| n.name == "w:gridCol").collect();
        if cols.is_empty() { return Vec::new(); }
        // A malformed/unparseable width anywhere in the grid makes the WHOLE grid unusable —
        // same posture as the count-mismatch case `OfficeBlock.table`'s doc comment describes:
        // never partially apply an untrustworthy grid.
        let mut widths: Vec<CGFloat> = Vec::new();
        for col in cols {
            let Some(w_str) = col.attributes.get("w:w") else { return Vec::new() };
            let Ok(value) = w_str.parse::<f64>() else { return Vec::new() };
            if value <= 0.0 { return Vec::new(); }
            widths.push(value / 20.0);
        }
        widths
    }

    /// A cell's own shading — `w:tcPr/w:shd/@w:fill`, a literal hex colour, or the string
    /// `"auto"`, Word's own "no fill" sentinel (the overwhelmingly common case — most cells carry
    /// an explicit `w:shd` with `fill="auto"` even when the author never touched shading at all,
    /// since Word writes it as part of the cell's resolved formatting). `"auto"` reads as `nil` —
    /// unshaded — exactly like an absent `w:shd` entirely, never as a fabricated colour.
    // swift: Render/Office/DocxReader.swift:2777-2780
    fn cell_shading(tc_pr: Option<&XMLNode>) -> Option<NSColor> {
        let fill = tc_pr.and_then(|n| n.child("w:shd")).and_then(|n| n.attributes.get("w:fill"))?;
        if fill.to_lowercase() == "auto" { return None; }
        Self::color_from_hex(fill)
    }

    /// A cell's border, reduced to the ONE colour/width `Cell` has room for (see its own doc: a
    /// real per-edge model is out of this sprint's scope) — the first of `w:tcBorders`' four edges,
    /// checked top/left/bottom/right, that is actually drawn (`w:val` present and neither `"nil"`
    /// nor `"none"`, OOXML's two ways of saying "no border on this edge"). Real tables overwhelmingly
    /// border all four edges identically, so "the first drawn edge" and "the cell's border" agree in
    /// practice; a cell with genuinely mixed edges loses that distinction, honestly, rather than
    /// this reader inventing a fifth field nothing here would fill in consistently. `w:sz` is in
    /// EIGHTHS of a point (ECMA-376 §17.4.66) — divided by 8, not 2 (that's `w:sz`'s OTHER unit,
    /// half-points, used for run/paragraph mark sizes — the two `w:sz` attributes are unrelated
    /// despite sharing a name). `w:color="auto"` resolves to `nil` (theme decides), same as
    /// `w:fill`'s identical sentinel above.
    // swift: Render/Office/DocxReader.swift:2793-2795
    fn cell_border(tc_pr: Option<&XMLNode>) -> (Option<NSColor>, Option<CGFloat>) {
        Self::resolve_border(tc_pr.and_then(|n| n.child("w:tcBorders")))
    }

    /// The table's OWN default border — `w:tbl/w:tblPr/w:tblBorders` — that every cell inherits
    /// unless its own `w:tcBorders` (`cellBorder`, above) says otherwise; see `TableFormat`'s own
    /// doc for the resolution chain this feeds. Shares `resolveBorder` with `cellBorder` because
    /// `w:tblBorders` and `w:tcBorders` are the SAME edge-element shape (`w:top`/`w:left`/
    /// `w:bottom`/`w:right`, each with `@w:val`/`@w:color`/`@w:sz`), just declared on the table
    /// instead of the cell.
    // swift: Render/Office/DocxReader.swift:2803-2805
    fn table_border(tbl_pr: Option<&XMLNode>) -> (Option<NSColor>, Option<CGFloat>) {
        Self::resolve_border(tbl_pr.and_then(|n| n.child("w:tblBorders")))
    }

    /// Shared by `cellBorder`/`tableBorder` — the ONE colour/width `Cell`/`TableFormat` have room
    /// for (see `Cell.borderColor`'s own doc: a real per-edge model is out of this sprint's scope),
    /// taken from the first of the four edges, checked top/left/bottom/right, that is actually
    /// drawn (`w:val` present and neither `"nil"` nor `"none"`, OOXML's two ways of saying "no
    /// border on this edge"). Real tables overwhelmingly border all four edges identically, so "the
    /// first drawn edge" and "the table's/cell's border" agree in practice. `w:sz` is in EIGHTHS of
    /// a point (ECMA-376 §17.4.66) — divided by 8, not 2 (that's `w:sz`'s OTHER unit, half-points,
    /// used for run/paragraph mark sizes — the two `w:sz` attributes are unrelated despite sharing
    /// a name). `w:color="auto"` resolves to `nil` (theme decides).
    /// The SAME `w:tcBorders`/`w:tblBorders` node read per EDGE, which is how Word actually states
    /// it — a row whose top is a solid blue rule and whose bottom is a dotted hairline is ordinary,
    /// and `resolveBorder` below (kept for the uniform fallback) can only report one of them.
    ///
    /// THREE outcomes per edge, which is why this returns `BorderDecl` and not `BorderSide` (see
    /// `BorderDecl`'s own doc):
    /// - no child element for that edge → `nil`, the document never mentioned it (it inherits);
    /// - `w:val="none"`/`"nil"` → `.suppressed`, explicitly off — nothing drawn, nothing inherited;
    /// - a drawn `w:val` with a `w:sz` → `.drawn`. `w:sz` is EIGHTHS of a point (§17.4.66).
    ///
    /// An all-`.suppressed` result is deliberately NOT erased by the `isEmpty` check below: "every
    /// edge off" must reach the renderer as a declaration, or it renders like silence (= the theme's
    /// own default border, the exact rule the document asked to remove).
    /// `w:insideH`/`w:insideV` are meaningful only on `w:tblBorders`; a cell never declares them.
    // swift: Render/Office/DocxReader.swift:2830-2856
    fn resolve_edge_borders(borders: Option<&XMLNode>) -> Option<EdgeBorders> {
        let borders = borders?;
        fn side(borders: &XMLNode, name: &str) -> Option<BorderDecl> {
            let e = borders.child(name)?;
            let val = e.attributes.get("w:val")?;
            if val == "nil" || val == "none" { return Some(BorderDecl::Suppressed); }
            // A drawn `w:val` carrying NO `w:sz` stays UNSPECIFIED — a deliberate choice, not an
            // oversight: the width is the whole of what this renderer draws with, the element does
            // not state one, and inventing a default here would put a rule of our own choosing on an
            // edge the document only half-described. Letting it inherit is what shipped before this
            // three-state split, and it is kept unchanged.
            let sz: f64 = e.attributes.get("w:sz")?.parse().ok()?;
            let color = e.attributes.get("w:color").and_then(|c| {
                if c.to_lowercase() == "auto" { None } else { super::DocxReader::color_from_hex(c) }
            });
            // A declared-but-zero width still means "drawn" in Word; a hairline is the honest render.
            Some(BorderDecl::Drawn(BorderSide {
                width: (sz / 8.0).max(0.25),
                color,
                style: super::DocxReader::line_style(val),
            }))
        }
        let out = EdgeBorders {
            top: side(borders, "w:top"),
            left: side(borders, "w:left"),
            bottom: side(borders, "w:bottom"),
            right: side(borders, "w:right"),
            inside_h: side(borders, "w:insideH"),
            inside_v: side(borders, "w:insideV"),
        };
        if out.is_empty() { None } else { Some(out) }
    }

    /// `w:val` (ST_Border, §17.18.2 — about two dozen values) → the four styles this reader paints.
    /// Word's own list separates gaps and stroke widths this renderer cannot express at a 0.5pt
    /// rule (`dashSmallGap` vs `dashed`), so the families collapse; the decorative art borders
    /// (`w:val="apples"` and friends) and the bevels resolve to `solid`, which is what they are
    /// nearest to and never to nothing.
    // swift: Render/Office/DocxReader.swift:2862-2869
    // swift note: kept `pub(crate)` — the Swift original is `static func` (internal, not
    // `private`), reachable outside DocxReader's own scope.
    pub(crate) fn line_style(val: &str) -> BorderLineStyle {
        if val.starts_with("dot") && val != "dotted" { return BorderLineStyle::Dashed; } // dotDash, dotDotDash
        match val {
            "dotted" | "dottedHeavy" => BorderLineStyle::Dotted,
            "dashed" | "dashedHeavy" | "dashSmallGap" | "dashDotStroked" | "dotted-dashed" => {
                BorderLineStyle::Dashed
            }
            "double" | "doubleWave" | "triple" | "thinThickSmallGap" | "thickThinSmallGap"
            | "thinThickThinSmallGap" | "thinThickMediumGap" | "thickThinMediumGap"
            | "thinThickThinMediumGap" | "thinThickLargeGap" | "thickThinLargeGap"
            | "thinThickThinLargeGap" => BorderLineStyle::Double,
            _ => BorderLineStyle::Solid,
        }
    }

    // swift: Render/Office/DocxReader.swift:2870-2878
    pub(crate) fn resolve_border(borders: Option<&XMLNode>) -> (Option<NSColor>, Option<CGFloat>) {
        let Some(borders) = borders else { return (None, None) };
        for edge in ["w:top", "w:left", "w:bottom", "w:right"] {
            let Some(e) = borders.child(edge) else { continue };
            let Some(val) = e.attributes.get("w:val") else { continue };
            if val == "nil" || val == "none" { continue; }
            let color = e.attributes.get("w:color").and_then(|c| {
                if c.to_lowercase() == "auto" { None } else { Self::color_from_hex(c) }
            });
            let width = e.attributes.get("w:sz").and_then(|v| v.parse::<f64>().ok()).map(|v| v / 8.0);
            return (color, width);
        }
        (None, None)
    }

    /// A cell's own vertical alignment — `w:tcPr/w:vAlign/@w:val` (`"top"`/`"center"`/`"bottom"`;
    /// any other/absent value, including Word's own `"both"` which this vocabulary has no case
    /// for, reads as `nil` — see `Cell.verticalAlignment`'s own doc for why `nil` already means
    /// Word's own default).
    // swift: Render/Office/DocxReader.swift:2885-2892
    fn cell_valign(tc_pr: Option<&XMLNode>) -> Option<CellVAlign> {
        match tc_pr
            .and_then(|n| n.child("w:vAlign"))
            .and_then(|n| n.attributes.get("w:val"))
            .map(|s| s.as_str())
        {
            Some("top") => Some(CellVAlign::Top),
            Some("center") => Some(CellVAlign::Center),
            Some("bottom") => Some(CellVAlign::Bottom),
            _ => None,
        }
    }

    /// A resolved cell margin — `w:tcMar` (per cell) or `w:tblCellMar` (table default), both the
    /// SAME shape (`w:top`/`w:start`(or `w:left`)/`w:bottom`/`w:end`(or `w:right`), each an
    /// `w:w`-in-twips element) — reduced to the ONE uniform value `Cell.padding` has room for (see
    /// its own doc: the START/left edge, mirroring `ParagraphFormat.indentStart`'s same edge
    /// choice). `nil` when the element itself is absent, or when its start/left edge is, so a
    /// margin element that only sets OTHER edges is honestly read as "nothing here" rather than a
    /// wrong edge's value smuggled in as the uniform one.
    // swift: Render/Office/DocxReader.swift:2901-2906
    fn cell_margin(mar_node: Option<&XMLNode>) -> Option<CGFloat> {
        let mar_node = mar_node?;
        let edge = mar_node.child("w:start").or_else(|| mar_node.child("w:left"))?;
        let w_str = edge.attributes.get("w:w")?;
        let value: f64 = w_str.parse().ok()?;
        if value < 0.0 { return None; }
        Some(value / 20.0)
    }

    /// The SAME `w:tcMar`/`w:tblCellMar` element `cellMargin` reads, but ALL FOUR edges
    /// independently — `Cell.edgePadding`'s PAGED counterpart to that single-value model. `nil` per
    /// edge means the element didn't state THAT edge (mirroring `cellMargin`'s own "start/left is
    /// absent" reading, applied to each side rather than collapsed to one representative). This is
    /// what lets Word's own stock `w:tblCellMar` (`left=start 108, right=end 108, top=0, bottom=0`
    /// twips = 5.4pt sides, EXPLICITLY zero top/bottom) survive as a real zero rather than being
    /// smeared with the left value the way `cellMargin`'s single-value model necessarily does.
    // swift: Render/Office/DocxReader.swift:2915-2928
    pub(crate) fn cell_edge_padding(mar_node: Option<&XMLNode>) -> Option<EdgePadding> {
        let mar_node = mar_node?;
        fn edge(node: Option<&XMLNode>) -> Option<CGFloat> {
            let w_str = node?.attributes.get("w:w")?;
            let value: f64 = w_str.parse().ok()?;
            if value < 0.0 { return None; }
            Some(value / 20.0)
        }
        let top = edge(mar_node.child("w:top"));
        let left = edge(mar_node.child("w:start").or_else(|| mar_node.child("w:left")));
        let bottom = edge(mar_node.child("w:bottom"));
        let right = edge(mar_node.child("w:end").or_else(|| mar_node.child("w:right")));
        if top.is_none() && left.is_none() && bottom.is_none() && right.is_none() { return None; }
        Some(EdgePadding { top, left, bottom, right })
    }

    /// A cell's own declared column width — `w:tcPr/w:tcW`, whose `@w:type` names which of THREE
    /// unit systems `@w:w` is in (ECMA-376 §17.4.90, `ST_TblWidth`): `"dxa"` (twentieths of a
    /// point — the SAME twips `parseTabStops` converts), `"pct"` (fiftieths of a percent of the
    /// table's available width) or `"auto"` (no declared width at all, Word sizes the column
    /// itself). Only `"dxa"` is handled — it is both the common case in practice and the only one
    /// this reader can convert to an ABSOLUTE point value from the cell's own markup alone; `"pct"`
    /// would need the table's own resolved available width (from `w:tblPr/w:tblW` and the page's
    /// margins) to turn a percentage into points, which is real work this sprint's brief scopes
    /// out — skipped here, honestly, rather than guessed at. A `w:tcW` with no `@w:type` at all
    /// defaults to `"dxa"` per the same clause, which is why `nil`/`"dxa"` are treated alike.
    // swift: Render/Office/DocxReader.swift:2939-2943
    fn cell_width(tc_pr: Option<&XMLNode>) -> Option<CGFloat> {
        let tc_w = tc_pr.and_then(|n| n.child("w:tcW"))?;
        let w_str = tc_w.attributes.get("w:w")?;
        let value: f64 = w_str.parse().ok()?;
        match tc_w.attributes.get("w:type").map(|s| s.as_str()) {
            None | Some("dxa") => Some(value / 20.0),
            _ => None,
        }
    }

    /// A cell's content, built from the SAME per-block classification `parseParagraph` gives the
    /// body — a paragraph, a heading, a list item, an image — rather than a second, cell-only walk
    /// that only ever knew how to collect plain text. This is what closes gap-list rows 6 and 7:
    /// before this sprint a cell held nothing but `[Span]`, so an image or a numbered list item
    /// inside a `<w:tc>` had nowhere to go and was silently skipped.
    ///
    /// List numbering inside a cell shares the WHOLE document's `ListNumberingState` (the same
    /// instance `read()` threads through the body) rather than getting its own — a `w:numId`'s
    /// counters belong to the numId, not to whether the paragraph using it happens to sit inside a
    /// table cell, and Word itself continues a list's numbers across an intervening table exactly as
    /// it does across an ordinary paragraph. A numbered item inside a cell therefore continues the
    /// document's numbering, never restarts at 1.
    ///
    /// Three of the same places `collectCellSpans` already knew text could hide — `w:p`, `w:sdt`, a
    /// nested `w:tbl` — but a nested table is still FLATTENED to a single `.paragraph` of spans
    /// (`flattenNestedTable`/`collectCellSpans`, unchanged), never a real nested `.table` block: that
    /// was decided earlier and is enforced again by the renderer, and this sprint's brief is
    /// explicit that it must not change.
    ///
    /// An empty paragraph — Word's own placeholder for a cell the author left blank, or the stray
    /// `<w:p/>` a genuinely empty cell always carries (a `<w:tc>` is never bodiless in real OOXML) —
    /// is filtered out with the SAME `isEmptyTextBlock` check `textBoxBlocks` already uses: a truly
    /// empty cell must produce no block at all, never a phantom `.paragraph(spans: [])` standing in
    /// for "nothing here".
    // swift: Render/Office/DocxReader.swift:2969-2992
    fn collect_cell_blocks(
        tc: &XMLNode,
        style_info: &StyleInfo,
        numbering: &NumberingInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
        list_state: &swiftshim::Ref<ListNumberingState>,
    ) -> Vec<OfficeBlock> {
        let mut blocks: Vec<OfficeBlock> = Vec::new();
        for child in &tc.children {
            match child.name.as_str() {
                "w:p" => blocks.extend(Self::parse_paragraph(
                    child, style_info, numbering, relationships, notes, comments, list_state,
                )),
                "w:tbl" => {
                    let spans = Self::flatten_nested_table(
                        child, style_info, relationships, notes, comments,
                    );
                    if !spans.is_empty() {
                        blocks.push(OfficeBlock::Paragraph {
                            spans, rtl: false, alignment: None, tab_stops: Vec::new(),
                            format: Default::default(),
                        });
                    }
                }
                "w:sdt" => {
                    if let Some(content) = child.child("w:sdtContent") {
                        blocks.extend(Self::collect_cell_blocks(
                            content, style_info, numbering, relationships, notes, comments,
                            list_state,
                        ));
                    }
                }
                _ => continue,
            }
        }
        blocks.into_iter().filter(|b| !Self::is_empty_text_block(b)).collect()
    }

    /// A cell's content as plain spans, no block structure — used ONLY by `flattenNestedTable`,
    /// which deliberately squashes a nested table's grid down to text (`Cell` has no room for a
    /// second, real nested `.table` block). `collectCellBlocks` above is what a table's OWN cells
    /// go through now; this stays exactly as it was for the flatten-only path.
    // swift: Render/Office/DocxReader.swift:3000-3016
    fn collect_cell_spans(
        tc: &XMLNode,
        style_info: &StyleInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
    ) -> Vec<Span> {
        let mut spans: Vec<Span> = Vec::new();
        for child in &tc.children {
            match child.name.as_str() {
                "w:p" => spans.extend(Self::collect_spans(
                    child, style_info, relationships, notes, comments,
                )),
                "w:tbl" => spans.extend(Self::flatten_nested_table(
                    child, style_info, relationships, notes, comments,
                )),
                "w:sdt" => {
                    if let Some(content) = child.child("w:sdtContent") {
                        spans.extend(Self::collect_cell_spans(
                            content, style_info, relationships, notes, comments,
                        ));
                    }
                }
                _ => continue,
            }
        }
        spans
    }

    /// Flattens a nested table's cells into one run of spans — a tab between cells, a newline
    /// after each non-empty row — so a reader glancing at the flattened text can still tell where
    /// one cell ended and the next began, even though the grid itself is gone. Recurses through
    /// `collectCellSpans`, so a table nested inside a nested table (and a content control inside
    /// THAT) also survives — no depth cap is enforced; real documents don't go more than one or
    /// two levels, per the research survey.
    // swift: Render/Office/DocxReader.swift:3025-3037
    fn flatten_nested_table(
        table: &XMLNode,
        style_info: &StyleInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
    ) -> Vec<Span> {
        let mut spans: Vec<Span> = Vec::new();
        for row in table.children.iter().filter(|n| n.name == "w:tr") {
            let mut row_has_content = false;
            for cell in row.children.iter().filter(|n| n.name == "w:tc") {
                let cell_spans =
                    Self::collect_cell_spans(cell, style_info, relationships, notes, comments);
                if cell_spans.is_empty() { continue; }
                if row_has_content { spans.push(Span { text: "\t".into(), ..Default::default() }); }
                spans.extend(cell_spans);
                row_has_content = true;
            }
            if row_has_content { spans.push(Span { text: "\n".into(), ..Default::default() }); }
        }
        spans
    }

    /// Walks a paragraph (or a table cell's paragraph) collecting `w:r` runs into `Span`s,
    /// merging consecutive runs that carry identical formatting into one — Word fragments a
    /// single sentence into several runs constantly (a spell-check pass, a single character
    /// pasted with different provenance), and without merging, that fragmentation would leak
    /// into the rendered text as spurious style boundaries.
    ///
    /// Recursion is deliberately permissive: any wrapper this switch doesn't specifically name
    /// (`w:ins`, `w:smartTag`, `w:customXml`, …) is descended into rather than skipped, so a
    /// run's visible text is never lost just because Word wrapped it in something unanticipated.
    /// Two wrappers get their OWN case rather than falling through to that generic descent:
    /// `w:hyperlink` carries the link target as an ATTRIBUTE (`r:id`/`w:anchor`), which the generic
    /// walk has nowhere to read, so every run underneath it is threaded through with that target;
    /// `w:sdt` (an inline content control) is unwrapped into its `w:sdtContent` only, so its
    /// `w:sdtPr` (placeholder-text hints, lock settings — never renderable content) is never
    /// mistaken for one. Only elements known to carry NO renderable body text of their own are
    /// pruned: paragraph/run properties (formatting only), deleted-content wrappers, empty
    /// markers, and section properties.
    // swift: Render/Office/DocxReader.swift:3058-3313
    fn collect_spans(
        node: &XMLNode,
        style_info: &StyleInfo,
        relationships: &Relationships,
        notes: &NoteNumbering,
        comments: &CommentRangeTracking,
    ) -> Vec<Span> {
        // The paragraph's own style id, read off THIS node's `w:pPr` directly — every caller passes
        // the paragraph (`w:p`) itself as `node` (`parseParagraph`, `collectCellSpans`'s `w:p` case),
        // never a sub-element, so this is the same `w:pPr/w:pStyle` `parseParagraph` itself reads for
        // `headingLevel`/`alignment` — read again here rather than threaded as a separate parameter,
        // since every call site already has `node` in hand and nothing else about that lookup varies.
        let p_style_id: Option<String> = node
            .child("w:pPr")
            .and_then(|n| n.child("w:pStyle"))
            .and_then(|n| n.attributes.get("w:val"))
            .cloned();
        let mut spans: Vec<Span> = Vec::new();
        // Names collected from `w:bookmarkStart` since the last span was emitted, waiting for the
        // next real content to attach to (a bookmark almost always wraps its target rather than
        // standing alone) — see the `w:bookmarkStart` case in `walk` and the doc comment on
        // `Span.bookmarks`. `_GoBack` is filtered here, not recorded and never resolvable: Word
        // inserts it automatically (last-edit-location bookkeeping) into nearly every real
        // document, no hyperlink ever targets it, and recording it would force every span right
        // after one — text a user never asked to navigate to — out of the ordinary run-merging path.
        let mut pending_bookmarks: Vec<String> = Vec::new();
        // A COMPOUND field (`w:fldChar`/`w:instrText`, header-footer-design.md §5) is a state
        // machine spread across SIBLING runs, never nested inside one: `begin` opens it, one or
        // more `w:instrText` runs spell the instruction ("PAGE   \* MERGEFORMAT"), `separate`
        // closes the instruction and opens the cached RESULT text, `end` closes the whole field.
        // Some fields (`STYLEREF` in this reader's own reference document) never reach `separate`
        // at all — no cached result exists to mark, and `.none` after `end` reflects that exactly.
        // `.simple` state deliberately doesn't exist: a `w:fldSimple` is self-contained (its own
        // `w:instr` attribute, no separate/end pair) and is handled inline where it's found, not
        // through this machine.
        #[derive(Clone, PartialEq)]
        enum FieldState {
            None,
            CollectingInstr(String),
            InResult(Option<PageNumberField>),
        }
        let field_state = FieldState::None;

        // `appendMerging` needs `&mut spans`, `&mut pending_bookmarks` and `&Comments` all at
        // once, and `walk` recurses while holding the same borrows — expressed as one recursive
        // closure-shaped helper carrying the mutable state explicitly, since Rust closures cannot
        // borrow themselves.
        struct Ctx<'a> {
            spans: Vec<Span>,
            pending_bookmarks: Vec<String>,
            field_state: FieldState,
            comments: &'a CommentRangeTracking,
        }

        fn append_merging(ctx: &mut Ctx, mut span: Span) {
            if !ctx.pending_bookmarks.is_empty() {
                span.bookmarks.extend(
                    std::mem::take(&mut ctx.pending_bookmarks).into_iter().map(SwiftString::from),
                );
            }
            // Every span emitted while a `w:commentRangeStart…w:commentRangeEnd` range is open
            // carries that comment's id(s) — see `Span.commentIds`. A span can be inside more than
            // one open range at once (overlapping/nested comments), so this APPENDS every currently
            // active id rather than picking one.
            let active_ids = ctx.comments.active_ids_snapshot();
            if !active_ids.is_empty() {
                span.comment_ids.extend(active_ids.into_iter().map(SwiftString::from));
            }
            // A span carrying a page-number field marker is never merged either — same reasoning as
            // bookmarks/commentIds right below: merging would smear the substitutable cached text
            // into the literal characters around it (the dashes framing a page number), losing the
            // exact boundary a later live-substitution pass needs. See `Span.pageNumberField`'s own
            // doc.
            if !(span.bookmarks.is_empty() && span.comment_ids.is_empty() && span.page_number_field.is_none()) {
                ctx.spans.push(span);
                return;
            }
            // A bookmarked/commented span is also never EXTENDED by whatever comes right after it —
            // merging trailing text into it would grow the marker's rendered span past its real
            // target/range, the same boundary-smearing `Span.bookmarks`'/`Span.commentIds`' doc
            // comments warn against, just from the other direction.
            //
            // A merge KEEPS THE FIRST span and appends only the second's TEXT, so this list is not
            // "which fields we bother to compare" — it is "which fields cannot be silently
            // overwritten by the run before them". Anything a run can carry and this check omits is
            // a live data loss: `textColor`/`highlightColor`/`fontSize`/`fontName` were all missing
            // here (while `OdtReader`'s twin already had them, which is how it went unnoticed for so
            // long), so two runs differing only in colour merged and the SECOND run's colour was
            // gone. Per-slot fonts make adjacent runs differ in family constantly
            // (`docs/per-script-font-design.md` §5.1), which would have flattened that feature run
            // by run. Three fields are deliberately absent: `bookmarks`/`commentIds`/`pageNumberField`
            // are handled by the `isEmpty`/`== nil` guards above (never merged at all, in either
            // direction), and `resolvedFontDescriptor` is still `nil` for every span here — it is
            // written by `resolvingFontSubstitution()`, which runs at the dispatch point AFTER this
            // reader has returned (`DocumentTypes.readOffice`), and that pass does its own splitting
            // rather than re-entering this one. Anything ADDED to `Span` that a `w:r` can express
            // belongs in this list; `DocxReaderTests.testEveryRunPropertyADocxCanCarryKeepsAdjacentRunsApart`
            // is the guard that says so out loud.
            let can_merge = if let Some(last) = ctx.spans.last() {
                last.bookmarks.is_empty() && last.comment_ids.is_empty()
                    && last.page_number_field.is_none()
                    && last.bold == span.bold && last.italic == span.italic
                    && last.underline == span.underline && last.underline_style == span.underline_style
                    && last.caps == span.caps && last.small_caps == span.small_caps
                    && last.code == span.code && last.link == span.link
                    && last.strikethrough == span.strikethrough && last.superscript == span.superscript
                    && last.subscripted == span.subscripted && last.rtl == span.rtl
                    && last.text_color == span.text_color && last.highlight_color == span.highlight_color
                    && last.font_size == span.font_size && last.font_name == span.font_name
            } else {
                false
            };
            if can_merge {
                let idx = ctx.spans.len() - 1;
                ctx.spans[idx].text =
                    SwiftString::from(format!("{}{}", ctx.spans[idx].text, span.text));
            } else {
                ctx.spans.push(span);
            }
        }

        fn walk(
            node: &XMLNode,
            link: Option<&str>,
            style_info: &StyleInfo,
            relationships: &Relationships,
            notes: &NoteNumbering,
            p_style_id: Option<&str>,
            ctx: &mut Ctx,
        ) {
            for child in &node.children {
                match child.name.as_str() {
                    // Tracked MOVES are a matched pair: `w:moveFrom` wraps the run(s) at the ORIGINAL
                    // location and `w:moveTo` wraps the SAME run(s), verbatim, at the NEW location —
                    // Word's move-tracking round-trip literally duplicates the moved text into two
                    // places in `document.xml` and relies on the reader to keep only one.
                    // `w:moveFrom` is excluded here, exactly like `w:del` right beside it: it is
                    // content that is no longer at this location. `w:moveTo` is deliberately NOT
                    // listed — it falls through to the permissive `default: walk` below and is kept,
                    // exactly like `w:ins`. Before this fix NEITHER was excluded, so both locations
                    // rendered — a 100%-reproducible text duplication on every tracked move, not a
                    // degraded edge case. The empty boundary markers `w:moveFromRangeStart`/
                    // `w:moveFromRangeEnd` (used when a move's extent doesn't align to paragraph
                    // boundaries) carry no children of their own per spec, so excluding them changes
                    // nothing today — listed anyway so this switch stays the complete, authoritative
                    // record of "moved away" markers rather than relying on them being harmlessly
                    // empty.
                    "w:pPr" | "w:rPr" | "w:del" | "w:moveFrom" | "w:moveFromRangeStart"
                    | "w:moveFromRangeEnd" | "w:bookmarkEnd" | "w:proofErr" | "w:sectPr" => continue,
                    // A bookmark's name is the target an in-document link (`w:anchor`) jumps to — see
                    // `Span.bookmarks`/`hyperlinkTarget` below. `_GoBack` is Word's own auto-inserted
                    // bookmark (nothing in a real document ever links to it) and is deliberately never
                    // recorded — see the doc comment on `pendingBookmarks` above.
                    "w:bookmarkStart" => {
                        if let Some(name) = child.attributes.get("w:name") {
                            if name != "_GoBack" {
                                ctx.pending_bookmarks.push(name.clone());
                            }
                        }
                        continue;
                    }
                    // Opens/closes a comment's RANGE — every span emitted while it's open is marked (see
                    // `appendMerging` above and `CommentRangeTracking`). Ranges can be nested/overlapping
                    // (two reviewers commenting on overlapping text), so this is push/remove, not a
                    // single active id.
                    "w:commentRangeStart" => {
                        if let Some(id) = child.attributes.get("w:id") { ctx.comments.start(id.clone()); }
                        continue;
                    }
                    "w:commentRangeEnd" => {
                        if let Some(id) = child.attributes.get("w:id") { ctx.comments.end(id); }
                        continue;
                    }
                    // The point marker where Word draws the comment balloon/icon — it carries no text of
                    // its own (the range that was just closed already marked the commented spans), so
                    // there is nothing further to attach here.
                    "w:commentReference" => continue,
                    // A display equation — `collectFormulaBlocks` (called separately, once per
                    // paragraph, from `parseParagraph`) already turns this into its OWN `.formula`
                    // block; walking it here too would flatten its `m:t` runs a SECOND time into this
                    // paragraph's ordinary text, duplicating the equation's symbols right next to its
                    // proper rendering.
                    "m:oMathPara" => continue,
                    // A bare, INLINE equation (mixed into a sentence, or standing alone without the
                    // `m:oMathPara` wrapper) — this sprint gives it no web-block placeholder (see
                    // `WebBlock`'s doc: block-only, no inline mechanism), so it degrades to its own
                    // text, IN PLACE, exactly where it sits among the surrounding runs — the sentence
                    // stays intact rather than being broken into separate blocks for one symbol.
                    "m:oMath" => {
                        let text = OmmlTranslator::flatten_text(child);
                        if !text.is_empty() {
                            append_merging(
                                ctx,
                                Span {
                                    text: text.into(),
                                    link: link.map(SwiftString::from),
                                    ..Default::default()
                                },
                            );
                        }
                    }
                    // The OTHER field encoding (header-footer-design.md §5): `w:fldSimple` is
                    // SELF-CONTAINED — its own `w:instr` attribute plus an ordinary `w:r` cached-result
                    // child, no `begin`/`separate`/`end` pair at all. Mark every span this content walk
                    // produces with the SAME field kind, after the fact (the walk that builds them is
                    // the same ordinary recursion every other wrapper gets — `w:r` inside it needs no
                    // special case of its own).
                    "w:fldSimple" => {
                        // Marked through the SAME `fieldState` the compound encoding uses, for the
                        // duration of this element's own walk — NOT by stamping the spans afterwards.
                        // Stamping afterwards silently did nothing: the cached result run carries the
                        // footer's ordinary formatting, so `appendMerging` folded it into the text right
                        // before it ("- " in a `- 9 -` footer), the span count did not grow, and the
                        // range that was about to be stamped was empty. Measured on a real fixture as
                        // "- 9 -" on every page — the file's own stale number, exactly what the live
                        // substitution exists to replace. Setting the state FIRST means the span is born
                        // marked, which also keeps it out of the merge (the guard excludes a marked span).
                        let outer_field_state = ctx.field_state.clone();
                        ctx.field_state = FieldState::InResult(
                            child.attributes.get("w:instr").and_then(|i| super::DocxReader::page_number_field_kind(i)),
                        );
                        walk(child, link, style_info, relationships, notes, p_style_id, ctx);
                        ctx.field_state = outer_field_state;
                        continue;
                    }
                    "w:hyperlink" => {
                        // A hyperlink whose target can't be resolved (no `r:id`/`w:anchor`, or a
                        // relationship id absent from `document.xml.rels`) still keeps its text — only
                        // the link itself is lost, never the content, so `target` falling through to
                        // the OUTER `link` (usually nil) rather than being forced is deliberate.
                        let target = super::DocxReader::hyperlink_target(child, relationships);
                        let next_link = target.as_deref().or(link);
                        walk(child, next_link, style_info, relationships, notes, p_style_id, ctx);
                    }
                    "w:sdt" => {
                        if let Some(content) = child.child("w:sdtContent") {
                            walk(content, link, style_info, relationships, notes, p_style_id, ctx);
                        }
                    }
                    "w:r" => {
                        // A footnote/endnote reference is a MARKER element nested inside the run
                        // (`<w:r><w:rPr>…</w:rPr><w:footnoteReference w:id="1"/></w:r>`), not text —
                        // `buildSpan` below has no `w:t` to read from such a run and would otherwise
                        // silently produce nothing, dropping the citation entirely. Emitted as its OWN
                        // superscript span carrying the pre-computed marker number (`notes`, resolved
                        // once for the whole document in `numberNoteReferences` before this walk ever
                        // ran) — the SAME number the corresponding note body is prefixed with in
                        // `collectNoteBlocks`, so a reader can match one to the other. An id that
                        // resolves to no number (present in `w:footnoteReference` but this document's
                        // body was never walked for numbering — can't happen from `read()`, but this
                        // guards a caller that reuses `collectSpans` some other way) contributes nothing
                        // rather than a bare, meaningless digit.
                        for ref_child in &child.children {
                            match ref_child.name.as_str() {
                                "w:footnoteReference" => {
                                    if let Some(id) = ref_child.attributes.get("w:id") {
                                        if let Some(number) = notes.footnote.get(id) {
                                            append_merging(
                                                ctx,
                                                Span {
                                                    text: number.to_string().into(),
                                                    superscript: true,
                                                    link: link.map(SwiftString::from),
                                                    ..Default::default()
                                                },
                                            );
                                        }
                                    }
                                }
                                "w:endnoteReference" => {
                                    if let Some(id) = ref_child.attributes.get("w:id") {
                                        if let Some(number) = notes.endnote.get(id) {
                                            append_merging(
                                                ctx,
                                                Span {
                                                    text: number.to_string().into(),
                                                    superscript: true,
                                                    link: link.map(SwiftString::from),
                                                    ..Default::default()
                                                },
                                            );
                                        }
                                    }
                                }
                                // The COMPOUND field state machine (see `fieldState`'s own doc above) — each
                                // control element sits alone in its OWN run, a sibling of the run(s) it
                                // brackets, never nested inside the text run it's marking.
                                "w:fldChar" => {
                                    match ref_child.attributes.get("w:fldCharType").map(|s| s.as_str()) {
                                        Some("begin") => {
                                            ctx.field_state = FieldState::CollectingInstr(String::new());
                                        }
                                        Some("separate") => {
                                            // The common case: an instruction was actually collected. A
                                            // `separate` with nothing collected (malformed, or this walk started
                                            // mid-field) opens a result region with no known kind — no marker,
                                            // exactly as if the field weren't recognized at all.
                                            if let FieldState::CollectingInstr(instr) = &ctx.field_state {
                                                ctx.field_state =
                                                    FieldState::InResult(super::DocxReader::page_number_field_kind(instr));
                                            } else {
                                                ctx.field_state = FieldState::InResult(None);
                                            }
                                        }
                                        Some("end") => {
                                            // Closes the field whether or not it ever reached `separate` — the
                                            // `STYLEREF` case in this reader's own reference document goes
                                            // straight from `begin`+`instrText` to `end` with no result at all.
                                            ctx.field_state = FieldState::None;
                                        }
                                        _ => {}
                                    }
                                }
                                "w:instrText" => {
                                    if let FieldState::CollectingInstr(instr) = &ctx.field_state {
                                        let mut updated = instr.clone();
                                        updated.push_str(&ref_child.text);
                                        ctx.field_state = FieldState::CollectingInstr(updated);
                                    }
                                }
                                _ => continue,
                            }
                        }
                        // Only a run sitting BETWEEN `separate` and `end` — the cached RESULT text — is
                        // ever marked; a `begin`/`instrText`/`separate`/`end` run itself has no `w:t` of
                        // its own (`buildSpan` finds nothing to build), so this never mislabels the
                        // control runs themselves.
                        let field_kind: Option<PageNumberField> = match &ctx.field_state {
                            FieldState::InResult(kind) => *kind,
                            _ => None,
                        };
                        for mut span in super::DocxReader::build_spans(
                            child,
                            style_info,
                            p_style_id,
                            ctx.spans.last().and_then(|s| s.font_name.as_ref()).map(|f| f.to_string()),
                        ) {
                            span.link = link.map(SwiftString::from);
                            span.page_number_field = field_kind;
                            append_merging(ctx, span);
                        }
                    }
                    _ => walk(child, link, style_info, relationships, notes, p_style_id, ctx),
                }
            }
        }

        let mut ctx = Ctx {
            spans: std::mem::take(&mut spans),
            pending_bookmarks: std::mem::take(&mut pending_bookmarks),
            field_state,
            comments,
        };
        walk(node, None, style_info, relationships, notes, p_style_id.as_deref(), &mut ctx);
        ctx.spans
    }

    /// Reads a field instruction string (`w:instrText`'s concatenated text, or `w:fldSimple`'s
    /// `w:instr` attribute) down to which page-number field it names, tolerating the switches Word
    /// always appends (`\* MERGEFORMAT`, …) and leading/trailing whitespace. `nil` for every other
    /// field (`STYLEREF`, `DATE`, …) — those keep their cached text with no marker, exactly as
    /// before this existed (header-footer-design.md §7: no live value is planned for `STYLEREF`).
    // swift: Render/Office/DocxReader.swift:3314-3323
    fn page_number_field_kind(instr: &str) -> Option<PageNumberField> {
        let trimmed = instr.trim();
        // The field NAME is the first whitespace-separated token — instructions read like
        // `PAGE   \* MERGEFORMAT` or ` NUMPAGES  \* MERGEFORMAT `.
        let name = trimmed.splitn(2, ' ').next()?;
        match name.to_uppercase().as_str() {
            "PAGE" => Some(PageNumberField::Page),
            "NUMPAGES" => Some(PageNumberField::NumPages),
            _ => None,
        }
    }

    /// `r:id` resolves through the SAME relationship plumbing an embedded image's `r:embed` uses
    /// (`word/_rels/document.xml.rels`) — Word's hyperlink relationships are conventionally
    /// `TargetMode="External"`, so `Relationship.target` is already the raw URL, unmodified. An
    /// internal same-document link (e.g. a cross-reference to a heading) carries no `r:id` at all,
    /// only `w:anchor` naming a bookmark — turned into a `#`-prefixed fragment, the same convention
    /// markdown links already use for in-document anchors.
    ///
    /// PRECEDENCE, `r:id` present alongside `w:anchor`: `r:id` wins, `w:anchor` is ignored — per
    /// ECMA-376 Part 1 §17.16.22 (`CT_Hyperlink`), `id` is "the relationship id of the target of
    /// this hyperlink" and, when present, `anchor` names a location WITHIN that relationship's
    /// target (a bookmark inside the linked document), not a location in the current one. This
    /// reader has no way to jump inside an external target, so honouring `w:anchor` there would be
    /// wrong twice over — it would misread it as an in-document bookmark AND ignore the external
    /// target entirely. Dropping it and following `r:id` alone is the correct reading, not just the
    /// simpler one.
    // swift: Render/Office/DocxReader.swift:3341-3348
    fn hyperlink_target(hyperlink: &XMLNode, relationships: &Relationships) -> Option<String> {
        if let Some(r_id) = hyperlink.attributes.get("r:id") {
            return relationships.by_id.get(r_id).map(|r| r.target.clone());
        }
        if let Some(anchor) = hyperlink.attributes.get("w:anchor") {
            return Some(format!("#{anchor}"));
        }
        None
    }

    /// `w:t` text is concatenated verbatim, including any leading/trailing spaces — `xml:space`
    /// is a hint to XML WRITERS about whether to preserve whitespace-only nodes; a parser already
    /// reports the literal characters present, so there is nothing extra to honour here (and
    /// nothing here trims). `w:br`/`w:tab` are not text but stand for one, so they are turned
    /// into `\n`/`\t` in place, and so do `w:noBreakHyphen`/`w:softHyphen`/`w:ptab` (U+2011, U+00AD,
    /// `\t` — the author's punctuation/whitespace, not formatting; dropping them silently deleted a
    /// real character). `w:sym` is a special-character reference (`w:font`+`w:char`, a
    /// code point in that FONT's own private encoding, e.g. Wingdings) with no `w:t` fallback at
    /// all — this reader has no way to map an arbitrary symbol-font code point to a real Unicode
    /// glyph, but silently emitting nothing would make the author's character disappear entirely
    /// (the one unforgivable failure this sprint exists to close), so it becomes a visible
    /// placeholder (▯) instead — wrong glyph, but honestly marked as "something was here", never
    /// mistaken for empty content. A run producing no text at all (formatting-only, or an empty
    /// bookmark anchor Word occasionally wraps in its own run) yields no span — the caller must
    /// never see a phantom empty one.
    /// A tiny, deliberately incomplete `w:char` → Unicode mapping — the ▯ fallback above stays the
    /// default for everything not listed here, and stays honest: a wrong-looking mark beats a
    /// silently vanished one, but a real glyph beats either when it can be cited with confidence.
    /// This project's licence rule forbids copying a lookup table out of another reader
    /// (LibreOffice/Calligra/pandoc are read-for-understanding only), so every entry here must
    /// trace to a source this project can actually name: Microsoft's own Wingdings-to-Unicode
    /// correspondence, also published by the Unicode Consortium as a vendor "best fit" mapping
    /// (`unicode.org/Public/MAPPINGS/VENDORS/MICSFT/SYMBOL/wingding.txt`), assigns the Private-Use-
    /// Area code point U+F0FC to the Wingdings glyph Word renders as a check mark and U+F0FB to the
    /// one it renders as a ballot X — Word's own "checked"/"crossed-out" marks for a legacy
    /// Wingdings-font checkbox, one of the categories the sprint brief asked for.
    ///
    /// P2R extends the table with the categories the ORIGINAL brief named but that sprint left
    /// unmapped for lack of a citable chart — bullet, box, arrow, telephone and envelope glyphs.
    /// Source: Alan Wood's "Unicode resources" Wingdings character-set page
    /// (`alanwood.net/demos/wingdings.html`), a long-standing, independently-citable font↔Unicode
    /// correspondence reference (not another markdown/office READER's source — see this function's
    /// own licence-rule note above). `w:char` is the Wingdings font's OWN code position + `0xF000`
    /// (Word always encodes a PUA offset); the table's "Hex" column is that same code position
    /// before the offset, e.g. its `0x9F` is this function's `F09F`. Still deliberately incomplete —
    /// only glyphs from the brief's named categories, not an attempt at full Wingdings coverage —
    /// and the ▯ fallback still covers everything else honestly.
    // swift: Render/Office/DocxReader.swift:3388-3413
    fn mapped_symbol_character(font: Option<&str>, char_val: Option<&str>) -> Option<String> {
        let font = font?;
        if font.to_lowercase() != "wingdings" { return None; }
        let char_val = char_val?;
        match char_val.to_uppercase().as_str() {
            "F0FC" => Some("\u{2713}".to_string()), // check mark
            "F0FB" => Some("\u{2717}".to_string()), // ballot X
            "F09F" => Some("\u{2022}".to_string()), // bullet
            "F06E" => Some("\u{25A0}".to_string()), // black square (box)
            "F06F" => Some("\u{25A1}".to_string()), // white square (box)
            "F0EF" => Some("\u{21E6}".to_string()), // leftwards white arrow
            "F0F0" => Some("\u{21E8}".to_string()), // rightwards white arrow
            "F0F1" => Some("\u{21E7}".to_string()), // upwards white arrow
            "F0F2" => Some("\u{21E9}".to_string()), // downwards white arrow
            "F028" => Some("\u{1F57F}".to_string()), // black touchtone telephone
            "F02A" => Some("\u{1F582}".to_string()), // back of envelope
            _ => None,
        }
    }

    /// One `w:r` → the `Span`s it needs, which is USUALLY exactly one.
    ///
    /// It is a list rather than a single span because Word picks a font per CHARACTER, not per run:
    /// the four `w:rFonts` slots are selected by the character's Unicode block
    /// (`WordFontBlockTable`), so one run reading `2026년 보고서 (Report)` can genuinely ask for two
    /// typefaces. `ScriptRunSplitter` cuts it into the fewest pieces that each want one family, and
    /// crucially cuts on the resolved FAMILY and never on the slot — so a document whose slots all
    /// name the same face, which is the common case and every fixture in this repository, comes back
    /// as a single piece identical to what this function returned before it could split at all.
    // swift: Render/Office/DocxReader.swift:3415-3486
    fn build_spans(
        run: &XMLNode,
        style_info: &StyleInfo,
        p_style_id: Option<&str>,
        neighbour_family: Option<String>,
    ) -> Vec<Span> {
        let Some(template) = Self::build_span(run, style_info, p_style_id) else { return Vec::new() };
        let r_pr = run.child("w:rPr");
        let r_fonts = Self::resolved_r_fonts(
            p_style_id.map(|s| s.to_string()),
            style_info,
            &Self::parse_r_fonts(r_pr),
        );
        // Run-level complex-script override, and the ONLY route to the `cs` slot: MS-OI29500
        // §17.3.2.26 — *"If the run has the cs element or the rtl element, then the cs (or cstheme)
        // font is used, REGARDLESS of the Unicode character values of the run's content."* Checked
        // before any per-character work because it makes that work meaningless: one slot, one
        // family, one span, whatever the text says. Neither signal occurs anywhere in this project's
        // (Korean, left-to-right) corpus, which is a fact about the corpus and not about the rule —
        // the app already ships right-to-left support.
        if Self::is_on(r_pr, "w:cs") || Self::is_on(r_pr, "w:rtl") {
            let mut span = template;
            span.font_name = r_fonts
                .family(WordFontSlot::Cs, None, &style_info.theme_fonts)
                .map(SwiftString::from);
            return vec![span];
        }
        let hinted = r_fonts.hints_east_asia();
        let theme = &style_info.theme_fonts;
        let template_text = template.text.to_string();
        let pieces = ScriptRunSplitter::split(
            &template_text,
            |c| WordFontBlockTable::slot(c, hinted),
            |piece| r_fonts.family(piece.slot, piece.script.as_deref(), theme),
        );
        // A run with nothing but script-neutral characters in it — `2026`, `(3)`, a lone tab — has
        // no neighbour to absorb into, so the splitter hands back one piece with no family at all
        // (its documented reading of "nothing classified"). For Word that answer is wrong rather
        // than merely conservative: its table says outright that Basic Latin selects `ascii`, so a
        // document declaring `w:ascii="Georgia"` really does draw `2026` in Georgia. Measured on the
        // four fixtures here, leaving it uncorrected silently dropped three declared families and
        // ADDED spans (bus-headings 755 → 1099), because those runs then differed in family from
        // every neighbour and could no longer merge. Asking the table directly is the whole fix, and
        // it costs one lookup on the only shape that can reach it.
        //
        // **The NEIGHBOUR is asked first, and the table only when there is no neighbour.** That
        // order was measured, not chosen: with the table first, a real bilingual document produced
        // 5,396 spans averaging 2.3 characters each — 2,324 of them a single character — because
        // Word stores a Korean sentence as one `w:r` PER WORD, so every space between two words is
        // its own run, asks the table for `ascii`, is answered with the theme's Latin family, and
        // becomes a span that can never merge with the 맑은 고딕 on either side of it. Absorption
        // exists to prevent exactly this and structurally cannot reach it: it works within one run,
        // and Word put the space in a different one. Carrying the neighbour across collapses those
        // back. `OdtReader` already resolves it this way, and having the two agree is not a tidiness
        // point — the same document saved in the two formats must not fragment differently.
        //
        // What that gives up, stated rather than hidden: a run of pure digits sitting between two
        // Korean runs now takes 맑은 고딕 rather than the `w:ascii` family Word would use for it.
        // Word is more faithful there and we are not. It is the smaller error — those characters
        // have no glyph of their own to lose (a space) or a nearly font-invariant one (a comma, a
        // bracket), while the alternative costs a 5.7x rise in the run count that governs how long
        // every single ⌘+ press takes. A run with NO neighbour to inherit from — the first thing in
        // a paragraph — still asks the table, which is why `w:ascii="Georgia"` still draws a leading
        // `2026` in Georgia.
        if pieces.len() == 1 && pieces[0].family.is_none() {
            if let Some(first) = template_text.chars().next() {
                let none_classified =
                    !template_text.chars().any(|c| WordFontBlockTable::slot(c, hinted).is_some());
                if none_classified {
                    let mut span = template;
                    span.font_name = neighbour_family.map(SwiftString::from).or_else(|| {
                        r_fonts
                            .family(
                                WordFontBlockTable::slot_for_value(first as u32, hinted),
                                None,
                                theme,
                            )
                            .map(SwiftString::from)
                    });
                    return vec![span];
                }
            }
        }
        pieces
            .into_iter()
            .map(|piece| {
                let mut span = template.clone();
                span.text = piece.text.into();
                span.font_name = piece.family.map(SwiftString::from);
                span
            })
            .collect()
    }

    /// The run's text and every property EXCEPT its font family — the shape `buildSpans` clones per
    /// piece. Split out so the per-character font work reads as one concern and the twenty-odd
    /// toggles as another; the font is filled in by the caller, which is the only thing that varies
    /// within one run.
    // swift: Render/Office/DocxReader.swift:3488-3549
    fn build_span(run: &XMLNode, style_info: &StyleInfo, p_style_id: Option<&str>) -> Option<Span> {
        let mut text = String::new();
        for child in &run.children {
            match child.name.as_str() {
                "w:t" => text.push_str(&child.text),
                "w:br" => text.push('\n'),
                "w:tab" => text.push('\t'),
                "w:sym" => text.push_str(
                    &Self::mapped_symbol_character(
                        child.attributes.get("w:font").map(|s| s.as_str()),
                        child.attributes.get("w:char").map(|s| s.as_str()),
                    )
                    .unwrap_or_else(|| "▯".to_string()),
                ),
                // A non-breaking hyphen/soft hyphen IS text (the author's punctuation choice, not
                // formatting), and a positioned tab (`w:ptab`) is whitespace like `w:tab` even though
                // this reader doesn't honour its absolute position — dropping any of the three silently
                // deleted the author's character (see the function doc above).
                "w:noBreakHyphen" => text.push('\u{2011}'),
                "w:softHyphen" => text.push('\u{00AD}'),
                "w:ptab" => text.push('\t'),
                _ => continue,
            }
        }
        if text.is_empty() { return None; }
        let r_pr = run.child("w:rPr");
        // `w:vanish` is Word's own "don't show this in Normal view" toggle on a run — the same
        // principle sprint S4 applied to ODT's hidden-text signals, kept consistent here: hide
        // only on the file's explicit say-so. It's also how Word marks index-entry/TOC-field
        // scaffolding, so honouring it removes clutter the author never intended to be read as
        // body text. Deliberately handles ONLY plain `w:vanish` — `w:specVanish` is a
        // DIFFERENT, style-level toggle ("hidden unless the paragraph mark itself says
        // otherwise") whose exact interaction with paragraph marks this reader cannot verify
        // with confidence from a run alone, so it is left unhandled rather than guessed at.
        if Self::is_on(r_pr, "w:vanish") { return None; }
        let vert_align = r_pr.and_then(|n| n.child("w:vertAlign")).and_then(|n| n.attributes.get("w:val"));
        // Direct run properties WIN over the paragraph's style chain — read straight off THIS run's
        // own `w:rPr` first, and only consult `resolvedColor`/`resolvedHighlight`/`resolvedFontSize`/
        // `resolvedFontName` (the `basedOn`-chain walk, S13's reused mechanism) when this run didn't
        // say. `styleInfo.themeColors` is threaded through `resolvedColorElement` so a THEME colour
        // on a direct run resolves to the identical literal a style-level one would.
        let direct_color = Self::resolved_color_element(
            r_pr.and_then(|n| n.child("w:color")), &style_info.theme_colors,
        );
        let color = direct_color.or_else(|| Self::resolved_color(p_style_id.map(|s| s.to_string()), style_info));
        let direct_highlight = r_pr
            .and_then(|n| n.child("w:highlight"))
            .and_then(|n| n.attributes.get("w:val"))
            .and_then(|v| Self::highlight_color(v));
        let highlight = direct_highlight.or_else(|| Self::resolved_highlight(p_style_id.map(|s| s.to_string()), style_info));
        let direct_font_size: Option<CGFloat> = r_pr
            .and_then(|n| n.child("w:sz"))
            .and_then(|n| n.attributes.get("w:val"))
            .and_then(|v| v.parse::<f64>().ok())
            .map(|v| v / 2.0);
        let font_size = direct_font_size.or_else(|| Self::resolved_font_size(p_style_id.map(|s| s.to_string()), style_info));
        // `fontName` is deliberately left nil here — `buildSpans` resolves the four `w:rFonts` slots
        // per character and writes the family onto each piece it emits.
        // Direct run properties win; where the run says nothing, the paragraph style's own chain
        // decides (see `resolvedBold` — a Word heading's bold is almost always the STYLE's, not the
        // run's). `toggleState` keeps "explicitly off" distinct from "unstated" so a deliberately
        // un-bolded run does not inherit a bold ancestor.
        let bold = Self::toggle_state(r_pr, "w:b")
            .or_else(|| Self::resolved_bold(p_style_id.map(|s| s.to_string()), style_info))
            .unwrap_or(false);
        let italic = Self::toggle_state(r_pr, "w:i")
            .or_else(|| Self::resolved_italic(p_style_id.map(|s| s.to_string()), style_info))
            .unwrap_or(false);
        Some(Span {
            text: text.into(),
            bold,
            italic,
            underline: Self::is_on(r_pr, "w:u"),
            underline_style: Self::underline_style_value(r_pr),
            code: false,
            caps: Self::is_on(r_pr, "w:caps"),
            small_caps: Self::is_on(r_pr, "w:smallCaps"),
            strikethrough: Self::is_on(r_pr, "w:strike"),
            superscript: vert_align.map(|s| s.as_str()) == Some("superscript"),
            subscripted: vert_align.map(|s| s.as_str()) == Some("subscript"),
            rtl: Self::is_on(r_pr, "w:rtl"),
            text_color: color,
            highlight_color: highlight,
            font_size,
            ..Default::default()
        })
    }

    /// Maps `w:rPr/w:u/@w:val` (§17.18.99 `ST_Underline`) to `UnderlineStyle` — see that enum's own
    /// doc for the collapsed mapping. Only meaningful when `isOn(rPr, "w:u")` is `true`; called
    /// unconditionally here anyway (cheap, and `Span.underline` is what actually gates whether
    /// `OfficeTextBuilder` ever reads it), so a non-underlined run still gets a harmless `.single`.
    // swift: Render/Office/DocxReader.swift:3550-3561
    fn underline_style_value(r_pr: Option<&XMLNode>) -> UnderlineStyle {
        let Some(val) = r_pr.and_then(|n| n.child("w:u")).and_then(|n| n.attributes.get("w:val")) else {
            return UnderlineStyle::Single;
        };
        match val.as_str() {
            "double" => UnderlineStyle::Double,
            "dotted" | "dottedHeavy" => UnderlineStyle::Dotted,
            v if v.starts_with("dash") => UnderlineStyle::Dashed,
            v if v.starts_with("wave") || v.starts_with("wavy") => UnderlineStyle::Wavy,
            _ => UnderlineStyle::Single,
        }
    }

    /// A run-property toggle (`w:b`/`w:i`/`w:u`) is ON by its mere presence — UNLESS it carries
    /// `w:val="0"` or `w:val="false"`, which is Word's way of explicitly switching an inherited
    /// toggle back off. Treating `<w:b w:val="0"/>` as bold is a real, documented bug class.
    // swift: Render/Office/DocxReader.swift:3564-3568
    fn is_on(r_pr: Option<&XMLNode>, tag: &str) -> bool {
        let Some(element) = r_pr.and_then(|n| n.child(tag)) else { return false };
        let Some(val) = element.attributes.get("w:val") else { return true };
        val != "0" && val != "false"
    }

    // ============================================================================================
    // MARK: Generic XML tree
    // swift: Render/Office/DocxReader.swift:3571-3571
    // ============================================================================================

    // swift: Render/Office/DocxReader.swift:3572-3579
    pub(crate) fn build_tree(data: &[u8]) -> Result<XMLNode, DocxReaderReadError> {
        let delegate_root = XMLTreeBuilder::parse(data);
        delegate_root.ok_or_else(|| DocxReaderReadError::MalformedXML("xml".to_string()))
    }
}

/// One shared axis-scaling factor for `groupScale`/`collectGroupedPictures` — see their own docs.
// swift: Render/Office/DocxReader.swift:2203-2203
#[derive(Debug, Clone, Copy)]
struct AxisScale {
    x: f64,
    y: f64,
}

/// Translates one `m:oMath` node (OOXML's Office Math Markup Language) into the LaTeX the app's
/// existing formula engine already renders (`WebBlock.Engine.math`, KaTeX). Lives in THIS file
/// (not its own) because it walks `XMLNode`, which is deliberately `private` to this file to avoid
/// colliding with `OdtReader`'s own type of the same name — `OmmlTranslator` is `DocxReader`'s
/// caller-only helper, so file-private access is exactly the right shape, not a workaround.
///
/// Coverage is deliberately partial (the sprint brief is explicit: "do not attempt full OMML
/// coverage"). What IS covered: `m:r`/`m:t` (runs/text), `m:f` (fraction), `m:sSup`/`m:sSub`/
/// `m:sSubSup` (super/subscript), `m:rad` (radical), `m:d` (delimiters), `m:nary` (sum/product/
/// integral), `m:m`/`m:mr` (matrix), `m:func` (function application), `m:limLow`/`m:limUpp`
/// (limits), `m:bar` (over/underline), `m:acc` (accents), `m:groupChr` (over/underbrace),
/// `m:eqArr` (stacked equations).
///
/// The one rule every construct obeys: an element this translator does NOT specifically know how
/// to shape falls back to `flattenText` — its own `m:t` runs, concatenated — rather than producing
/// nothing. That fallback is the `default:` case of `translate(_:)`, not a case anyone has to
/// remember to add for a new/unhandled element, so it also covers constructs never named above
/// (`m:box`, `m:borderBox`, `m:phant`, …) automatically. Losing the author's SHAPE (no fraction
/// bar, no radical sign) is accepted; losing their SYMBOLS is not — see CLAUDE.md's standing rule
/// that content loss is this project's one unforgivable failure, layout loss is not.
// swift: Render/Office/DocxReader.swift:3603-3603
enum OmmlTranslator {}

impl OmmlTranslator {
    /// The LaTeX for one `m:oMath` node — its direct children, translated and concatenated. Empty
    /// only when the equation carries no content at all (an empty `m:oMath`, or one whose only
    /// children are property elements) — the caller (`DocxReader.formulaBlock`) is responsible for
    /// turning THAT into something visible rather than emitting a formula block with nothing in it.
    // swift: Render/Office/DocxReader.swift:3608-3610
    fn latex(o_math: &XMLNode) -> String {
        Self::translate_children(&o_math.children)
    }

    /// Every `m:t` found anywhere below `node`, depth-first, concatenated verbatim. The universal
    /// fallback (see the type doc) and also what `DocxReader.collectSpans` uses for a genuinely
    /// INLINE `m:oMath` (mixed into a sentence) that this sprint deliberately never turns into a
    /// web block at all — no inline placeholder mechanism exists yet (`WebBlock` is block-only).
    // swift: Render/Office/DocxReader.swift:3616-3624
    fn flatten_text(node: &XMLNode) -> String {
        let mut out = String::new();
        fn walk(n: &XMLNode, out: &mut String) {
            if n.name == "m:t" { out.push_str(&n.text); return; }
            for c in &n.children { walk(c, out); }
        }
        walk(node, &mut out);
        out
    }

    // MARK: - Dispatch
    // swift: Render/Office/DocxReader.swift:3627-3627

    // swift: Render/Office/DocxReader.swift:3628-3630
    fn translate_children(nodes: &[XMLNode]) -> String {
        nodes.iter().filter_map(Self::translate).collect::<Vec<_>>().join("")
    }

    /// `nil` for property/formatting elements (`m:*Pr`) — they carry no equation content of their
    /// own and must contribute nothing, not even their (nonexistent) text; every other unrecognized
    /// element falls to `flattenText`, never to `nil`, so a real author symbol is never silently
    /// dropped just because this translator doesn't know its shape.
    // swift: Render/Office/DocxReader.swift:3636-3661
    fn translate(node: &XMLNode) -> Option<String> {
        if node.name.ends_with("Pr") { return None; }
        Some(match node.name.as_str() {
            "m:r" => Self::run(node),
            "m:f" => Self::fraction(node),
            "m:sSup" => Self::superscript(node),
            "m:sSub" => Self::subscript_translate(node),
            "m:sSubSup" => Self::sub_sup(node),
            "m:rad" => Self::radical(node),
            "m:d" => Self::delimiter(node),
            "m:nary" => Self::nary(node),
            "m:m" => Self::matrix(node),
            "m:func" => Self::func_apply(node),
            "m:limLow" => Self::lim_low(node),
            "m:limUpp" => Self::lim_upp(node),
            "m:bar" => Self::bar(node),
            "m:acc" => Self::accent(node),
            "m:groupChr" => Self::group_chr(node),
            "m:eqArr" => Self::eq_arr(node),
            _ => Self::flatten_text(node),
        })
    }

    /// `m:r`'s only content is `m:t` (its `m:rPr`/`w:rPr` are formatting, skipped by the `Pr` rule
    /// above) — `flattenText` finds it regardless of exactly how deep it sits.
    // swift: Render/Office/DocxReader.swift:3662-3662
    fn run(node: &XMLNode) -> String {
        Self::flatten_text(node)
    }

    // MARK: - Structural constructs
    // swift: Render/Office/DocxReader.swift:3664-3664

    // swift: Render/Office/DocxReader.swift:3666-3670
    fn fraction(node: &XMLNode) -> String {
        let num = node.child("m:num").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        let den = node.child("m:den").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        format!("\\frac{{{num}}}{{{den}}}")
    }

    // swift: Render/Office/DocxReader.swift:3672-3676
    fn superscript(node: &XMLNode) -> String {
        let base = Self::element(node, "m:e");
        let sup = Self::element(node, "m:sup");
        format!("{{{base}}}^{{{sup}}}")
    }

    // swift: Render/Office/DocxReader.swift:3678-3682
    fn subscript_translate(node: &XMLNode) -> String {
        let base = Self::element(node, "m:e");
        let sub = Self::element(node, "m:sub");
        format!("{{{base}}}_{{{sub}}}")
    }

    // swift: Render/Office/DocxReader.swift:3684-3689
    fn sub_sup(node: &XMLNode) -> String {
        let base = Self::element(node, "m:e");
        let sub = Self::element(node, "m:sub");
        let sup = Self::element(node, "m:sup");
        format!("{{{base}}}_{{{sub}}}^{{{sup}}}")
    }

    /// A hidden degree (`m:radPr`'s `m:degHide` = "1") is Word's own square-root shorthand — the
    /// SOURCE says there is no degree to show, not that this translator lost one.
    // swift: Render/Office/DocxReader.swift:3693-3702
    fn radical(node: &XMLNode) -> String {
        let radicand = Self::element(node, "m:e");
        let deg_hidden = Self::prop_val(node.child("m:radPr"), "m:degHide").as_deref() == Some("1");
        let deg = node.child("m:deg").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        if deg_hidden || deg.trim().is_empty() {
            return format!("\\sqrt{{{radicand}}}");
        }
        format!("\\sqrt[{deg}]{{{radicand}}}")
    }

    /// One or more `m:e` arguments wrapped in the delimiters the source declared (`m:begChr`/
    /// `m:endChr`, under `m:dPr`) — defaulting to `(`/`)`, Word's own default when a document omits
    /// them entirely (an EMPTY `m:val=""` is a real, different, deliberate choice — "no visible
    /// delimiter" — and is honoured as empty, not silently overridden back to parentheses).
    // swift: Render/Office/DocxReader.swift:3707-3717
    fn delimiter(node: &XMLNode) -> String {
        let d_pr = node.child("m:dPr");
        let beg = Self::prop_val(d_pr, "m:begChr").unwrap_or_else(|| "(".to_string());
        let end = Self::prop_val(d_pr, "m:endChr").unwrap_or_else(|| ")".to_string());
        let args: Vec<String> = node
            .children
            .iter()
            .filter(|c| c.name == "m:e")
            .map(|c| Self::translate_children(&c.children))
            .collect();
        let inner = args.join(", ");
        let left = if beg.is_empty() { ".".to_string() } else { Self::escape_delimiter(&beg) };
        let right = if end.is_empty() { ".".to_string() } else { Self::escape_delimiter(&end) };
        format!("\\left{left} {inner} \\right{right}")
    }

    // swift: Render/Office/DocxReader.swift:3718-3725
    fn escape_delimiter(c: &str) -> String {
        match c {
            "{" => "\\{".to_string(),
            "}" => "\\}".to_string(),
            "|" => "|".to_string(),
            _ => c.to_string(),
        }
    }

    /// The operator glyph (`m:naryPr`'s `m:chr`) maps to a handful of common LaTeX big-operator
    /// commands; anything else keeps the source glyph literally rather than guessing a command name
    /// for it — the SAME "don't invent, degrade honestly" posture the rest of this translator uses.
    // swift: Render/Office/DocxReader.swift:3730-3744
    fn nary(node: &XMLNode) -> String {
        let nary_pr = node.child("m:naryPr");
        let chr = Self::prop_val(nary_pr, "m:chr").unwrap_or_else(|| "\u{2211}".to_string());
        let cmd = Self::nary_command(&chr);
        let sub_hidden = Self::prop_val(nary_pr, "m:subHide").as_deref() == Some("1");
        let sup_hidden = Self::prop_val(nary_pr, "m:supHide").as_deref() == Some("1");
        let sub = node.child("m:sub").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        let sup = node.child("m:sup").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        let operand = Self::element(node, "m:e");
        let mut out = cmd;
        if !sub_hidden && !sub.is_empty() { out.push_str(&format!("_{{{sub}}}")); }
        if !sup_hidden && !sup.is_empty() { out.push_str(&format!("^{{{sup}}}")); }
        format!("{out} {operand}")
    }

    // swift: Render/Office/DocxReader.swift:3745-3757
    fn nary_command(chr: &str) -> String {
        match chr {
            "\u{2211}" => "\\sum".to_string(),   // ∑
            "\u{220F}" => "\\prod".to_string(),   // ∏
            "\u{222B}" => "\\int".to_string(),    // ∫
            "\u{222C}" => "\\iint".to_string(),   // ∬
            "\u{222D}" => "\\iiint".to_string(),  // ∭
            "\u{222E}" => "\\oint".to_string(),   // ∮
            "\u{22C3}" => "\\bigcup".to_string(), // ⋃
            "\u{22C2}" => "\\bigcap".to_string(), // ⋂
            _ => chr.to_string(),
        }
    }

    /// Every `m:mr` row's `m:e` cells, `&`-separated, rows `\\`-separated.
    // swift: Render/Office/DocxReader.swift:3760-3769
    fn matrix(node: &XMLNode) -> String {
        let rows: Vec<String> = node
            .children
            .iter()
            .filter(|c| c.name == "m:mr")
            .map(|row| {
                row.children
                    .iter()
                    .filter(|c| c.name == "m:e")
                    .map(|c| Self::translate_children(&c.children))
                    .collect::<Vec<_>>()
                    .join(" & ")
            })
            .collect();
        format!("\\begin{{matrix}} {} \\end{{matrix}}", rows.join(" \\\\ "))
    }

    /// `m:fName` is itself OMML content (usually a plain run like "sin"), not a bare string
    /// attribute — translated the same way any other sub-expression is.
    // swift: Render/Office/DocxReader.swift:3771-3775
    fn func_apply(node: &XMLNode) -> String {
        let name = node.child("m:fName").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        let arg = Self::element(node, "m:e");
        format!("{name}\\left({arg}\\right)")
    }

    // swift: Render/Office/DocxReader.swift:3777-3781
    fn lim_low(node: &XMLNode) -> String {
        let base = Self::element(node, "m:e");
        let lim = node.child("m:lim").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        if lim.is_empty() { base } else { format!("{base}_{{{lim}}}") }
    }

    // swift: Render/Office/DocxReader.swift:3783-3787
    fn lim_upp(node: &XMLNode) -> String {
        let base = Self::element(node, "m:e");
        let lim = node.child("m:lim").map(|n| Self::translate_children(&n.children)).unwrap_or_default();
        if lim.is_empty() { base } else { format!("{base}^{{{lim}}}") }
    }

    /// `m:barPr`'s `m:pos` (`"bot"` = underline, anything else, including absent, = overline —
    /// Word's own default for a bar with no `m:pos` at all).
    // swift: Render/Office/DocxReader.swift:3791-3796
    fn bar(node: &XMLNode) -> String {
        let pos = Self::prop_val(node.child("m:barPr"), "m:pos");
        let e = Self::element(node, "m:e");
        if pos.as_deref() == Some("bot") { format!("\\underline{{{e}}}") } else { format!("\\overline{{{e}}}") }
    }

    /// The accent glyph (`m:accPr`'s `m:chr`) maps to a handful of common LaTeX accent commands;
    /// an unmapped glyph is kept literally alongside the base rather than dropped, same posture as
    /// `nary`'s unmapped operator.
    // swift: Render/Office/DocxReader.swift:3800-3814
    fn accent(node: &XMLNode) -> String {
        let chr = Self::prop_val(node.child("m:accPr"), "m:chr").unwrap_or_default();
        let e = Self::element(node, "m:e");
        match chr.as_str() {
            "\u{0302}" => format!("\\hat{{{e}}}"),    // combining circumflex
            "\u{20D7}" => format!("\\vec{{{e}}}"),    // combining right arrow above
            "\u{0307}" => format!("\\dot{{{e}}}"),    // combining dot above
            "\u{0303}" => format!("\\tilde{{{e}}}"),  // combining tilde
            "\u{0305}" | "\u{0304}" => format!("\\bar{{{e}}}"), // combining overline / macron
            "" => e,
            _ => format!("{e}{chr}"),
        }
    }

    /// The brace glyph + position (`m:groupChrPr`'s `m:chr`/`m:pos`) maps overbrace/underbrace;
    /// anything else keeps the source glyph, appended, rather than being silently dropped.
    // swift: Render/Office/DocxReader.swift:3816-3827
    fn group_chr(node: &XMLNode) -> String {
        let group_pr = node.child("m:groupChrPr");
        let chr = Self::prop_val(group_pr, "m:chr").unwrap_or_else(|| "\u{23DE}".to_string());
        let pos = Self::prop_val(group_pr, "m:pos").unwrap_or_else(|| "top".to_string());
        let e = Self::element(node, "m:e");
        match (chr.as_str(), pos.as_str()) {
            ("\u{23DE}", "top") | ("\u{FE37}", "top") => format!("\\overbrace{{{e}}}"),
            ("\u{23DF}", "bot") | ("\u{FE38}", "bot") => format!("\\underbrace{{{e}}}"),
            _ => {
                if pos == "bot" { format!("\\underbrace{{{e}}}") } else { format!("\\overbrace{{{e}}}") }
            }
        }
    }

    /// Each `m:e` on its own line — LaTeX's `aligned` environment, `\\`-separated.
    // swift: Render/Office/DocxReader.swift:3829-3832
    fn eq_arr(node: &XMLNode) -> String {
        let rows: Vec<String> = node
            .children
            .iter()
            .filter(|c| c.name == "m:e")
            .map(|c| Self::translate_children(&c.children))
            .collect();
        format!("\\begin{{aligned}} {} \\end{{aligned}}", rows.join(" \\\\ "))
    }

    // MARK: - Small helpers
    // swift: Render/Office/DocxReader.swift:3835-3835

    /// The translated content of `node`'s FIRST child named `tag`, or empty text if absent —
    /// absence is common (`m:sub`/`m:sup`/`m:deg` are all individually optional per the OMML
    /// schema) and must degrade to an empty group, never a crash or a dropped construct.
    // swift: Render/Office/DocxReader.swift:3839-3841
    fn element(node: &XMLNode, tag: &str) -> String {
        node.child(tag).map(|n| Self::translate_children(&n.children)).unwrap_or_default()
    }

    /// `pr?.child(tag)?.attributes["m:val"]` — the one shape every OMML property value takes
    /// (`<m:chr m:val="…"/>`, `<m:begChr m:val="…"/>`, …).
    // swift: Render/Office/DocxReader.swift:3845-3847
    fn prop_val(pr: Option<&XMLNode>, tag: &str) -> Option<String> {
        pr?.child(tag)?.attributes.get("m:val").cloned()
    }
}

/// A minimal DOM: element name (the qualified name, e.g. `"w:p"` — namespace processing is left
/// off, so `XMLParser` hands that back directly instead of splitting prefix from URI), its
/// attributes, its element children in document order, and any character data that landed
/// directly inside it (only leaf elements like `w:t` ever have any).
///
/// A tree — not a flat event stream — because `DocxReader`'s job is inherently structural
/// (a table's rows nest cells which nest paragraphs which nest runs); re-deriving that nesting
/// from `XMLParser`'s start/end callbacks by hand for every element kind would be the same tree,
/// built once per caller instead of once here.
///
/// swift note: the Swift original is `private final class XMLNode` — reference semantics, but a
/// tree built once by `XMLTreeBuilder` and never mutated again by this half of the reader, so
/// phase A gives it a plain owned-tree `struct` (`Vec<XMLNode>` children) rather than
/// `swiftshim::Ref<XMLNode>`; every method that read `self` read-only in Swift stays a `&self`
/// method here. `OdtReader.swift` declares an unrelated type of the same name (also
/// file-private) — this one is `pub(crate)` only within `docx_reader`, never re-exported, so the
/// two never collide.
// swift: Render/Office/DocxReader.swift:3850-3859
#[derive(Clone)]
pub(crate) struct XMLNode {
    pub name: String,
    pub attributes: std::collections::HashMap<String, String>,
    pub children: Vec<XMLNode>,
    pub text: String,
}

impl XMLNode {
    // swift: Render/Office/DocxReader.swift:3864-3867
    pub fn new(name: String, attributes: std::collections::HashMap<String, String>) -> Self {
        Self { name, attributes, children: Vec::new(), text: String::new() }
    }

    /// First direct child with this name, or nil. Every lookup `DocxReader` needs (`w:pPr` on a
    /// paragraph, `w:outlineLvl` on `w:pPr`, …) is for a single expected child, never a list.
    // swift: Render/Office/DocxReader.swift:3869-3872
    pub fn child(&self, name: &str) -> Option<&XMLNode> {
        self.children.iter().find(|c| c.name == name)
    }

    /// First match anywhere below this node (depth-first, document order), for lookups where the
    /// exact nesting varies by producer — `wp:extent`/`a:blip` sit at a different depth inside an
    /// inline vs. a floating (`wp:anchor`) drawing, and pinning that depth would silently miss one
    /// of the two shapes.
    // swift: Render/Office/DocxReader.swift:3876-3883
    pub fn first_descendant(&self, name: &str) -> Option<&XMLNode> {
        for child in &self.children {
            if child.name == name { return Some(child); }
            if let Some(found) = child.first_descendant(name) { return Some(found); }
        }
        None
    }

    /// Same idea, keyed by attribute presence rather than element name — used to find the VML
    /// shape carrying a `style="width:…;height:…"` attribute without knowing whether it's a
    /// `v:shape`, `v:rect`, `v:roundrect`, ….
    // swift: Render/Office/DocxReader.swift:3887-3894
    pub fn first_descendant_with_attribute(&self, attribute: &str) -> Option<&XMLNode> {
        for child in &self.children {
            if child.attributes.contains_key(attribute) { return Some(child); }
            if let Some(found) = child.first_descendant_with_attribute(attribute) { return Some(found); }
        }
        None
    }

    /// EVERY match anywhere below this node, in document order — unlike `firstDescendant`, used
    /// where stopping at the first would silently drop real content (a `w:drawing` grouping
    /// several pictures has one `a:blip` per picture, all of them real).
    // swift: Render/Office/DocxReader.swift:3900-3907
    pub fn all_descendants(&self, name: &str) -> Vec<&XMLNode> {
        let mut result: Vec<&XMLNode> = Vec::new();
        for child in &self.children {
            if child.name == name { result.push(child); }
            result.extend(child.all_descendants(name));
        }
        result
    }
}

/// swift note: `XMLTreeBuilder` was an `NSObject`/`XMLParserDelegate` driving Foundation's
/// `XMLParser` via start/end/characters callbacks and a stack of open `XMLNode`s. Rust has no
/// `XMLParser` — its shape (a SAX driver building the same tree via the same open-element stack)
/// is preserved as a `todo!()` shim over an as-yet-undecided XML crate, deferred to phase B per
/// the contract (§0: "cannot express" → `todo!()`, never a reshaped caller).
// swift: Render/Office/DocxReader.swift:3910-3910
struct XMLTreeBuilder {
    root: Option<XMLNode>,
    stack: Vec<XMLNode>,
}

impl XMLTreeBuilder {
    // swift: Render/Office/DocxReader.swift:3911-3912
    fn new() -> Self {
        Self { root: None, stack: Vec::new() }
    }

    /// swift: `func parser(_:didStartElement:namespaceURI:qualifiedName:attributes:)`
    // swift: Render/Office/DocxReader.swift:3916-3925
    fn did_start_element(&mut self, element_name: &str, attributes: std::collections::HashMap<String, String>) {
        let node = XMLNode::new(element_name.to_string(), attributes);
        self.stack.push(node);
        // swift: parent-append happens on `didEndElement` here (owned-tree shape has no parent
        // pointer to push into directly) — see `did_end_element` below, which is where the child
        // is actually attached; kept as `todo!()` in `parse` below pending the XML-crate decision.
    }

    /// swift: `func parser(_:foundCharacters:)`
    // swift: Render/Office/DocxReader.swift:3929-3931
    fn found_characters(&mut self, string: &str) {
        if let Some(last) = self.stack.last_mut() {
            last.text.push_str(string);
        }
    }

    /// swift: `func parser(_:didEndElement:namespaceURI:qualifiedName:)`
    // swift: Render/Office/DocxReader.swift:3933-3937
    fn did_end_element(&mut self) {
        if let Some(finished) = self.stack.pop() {
            match self.stack.last_mut() {
                Some(parent) => parent.children.push(finished),
                None => self.root = Some(finished),
            }
        }
    }

    /// swift: `buildTree`'s `XMLParser(data:).parse()` driver loop.
    ///
    /// The driving itself lives in `swiftshim::xml_parser::drive`, shared with `OdtReader`, so the
    /// two readers cannot drift apart on what an entity or a self-closing tag means. Only the
    /// adapter is here: this builder is a plain `&mut self` struct rather than an interior-
    /// mutability delegate, which is why it calls `drive` directly instead of going through
    /// `XMLParser::parse`.
    // swift: Render/Office/DocxReader.swift:3572-3578
    fn parse(data: &[u8]) -> Option<XMLNode> {
        let mut builder = XMLTreeBuilder::new();
        let ok = {
            let b = std::cell::RefCell::new(&mut builder);
            swiftshim::xml_parser::drive(
                data,
                &mut |name, attributes| b.borrow_mut().did_start_element(name, attributes),
                &mut |text| b.borrow_mut().found_characters(text),
                &mut |_name| b.borrow_mut().did_end_element(),
            )
        };
        // swift:3577 — `parser.parse()` failing yields nil, and so does a document that parsed but
        // never closed its root. A half-built tree is worse than none: the caller would read it as
        // a complete document that happens to be missing everything after the error.
        if !ok || !builder.stack.is_empty() {
            return None;
        }
        builder.root
    }
}
