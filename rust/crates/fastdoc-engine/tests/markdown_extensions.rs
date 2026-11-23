//! The markdown the reader draws beyond CommonMark+GFM: raw inline HTML, quotes that hold blocks,
//! alerts, footnotes, description lists, `==highlight==`, front matter, table alignment, list
//! numbering and the HTML blocks that used to vanish.
//!
//! Each test renders through the production path (`MarkdownRenderer::render`, comrak behind
//! `markdown_package`) and asserts the EVIDENCE attribute a host replays — invariant 41's rule that
//! a feature can ship dead and only the render path proves otherwise. A final test projects the
//! whole fixture onto the wire and fails on any attribute the wire has no column for.

use fastdoc_engine::render::md_attr::MDAttr;
use fastdoc_engine::render::markdown_renderer::MarkdownRenderer;
use fastdoc_engine::render::markdown_wire::{self, MarkdownWire};
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::color_font::{NSFontDescriptor, NSFontDescriptorSymbolicTraits, NSFontWeight};
use swiftshim::font_provider::{self, FaceId, FaceInfo, FontProvider};
use swiftshim::{AttrValue, NSAttributedString, NSAttributedStringKey as Key};

struct SingleFaceWorld;

impl FontProvider for SingleFaceWorld {
    fn face_named(&self, _name: &str) -> Option<FaceId> { Some(FaceId(1)) }
    fn resolve(&self, _descriptor: &NSFontDescriptor) -> Option<FaceId> { Some(FaceId(1)) }
    fn system_face(&self, _weight: NSFontWeight, _monospaced: bool) -> FaceId { FaceId(1) }
    fn describe(&self, _face: FaceId) -> FaceInfo {
        FaceInfo {
            name: "TestFace-Regular".to_string(),
            family: Some("TestFace".to_string()),
            traits: NSFontDescriptorSymbolicTraits::default(),
        }
    }
    fn covers(&self, _face: FaceId, _scalar: u32) -> bool { true }
    fn substitute(&self, _declared: FaceId, _scalar: u32) -> Option<FaceId> { None }
}

const BASE: f64 = 16.0;

fn render(markdown: &str) -> NSAttributedString {
    let _ = font_provider::install(Box::new(SingleFaceWorld));
    MarkdownRenderer::render(markdown, &RenderTheme::current(BASE))
}

fn wire_for(markdown: &str) -> MarkdownWire {
    let _ = font_provider::install(Box::new(SingleFaceWorld));
    let theme = RenderTheme::current(BASE);
    markdown_wire::project(&MarkdownRenderer::render(markdown, &theme), &theme)
}

/// The value of `key` at `at` AFTER every layer has been replayed: the string is a call log, so the
/// LAST layer covering a character that sets the key wins (the host replays in order).
fn effective(r: &NSAttributedString, key: &Key, at: usize) -> Option<AttrValue> {
    r.runs()
        .iter()
        .rev()
        .find(|(range, attrs)| range.location <= at && at < range.maxRange() && attrs.contains_key(key))
        .and_then(|(_, attrs)| attrs.get(key).cloned())
}

/// The attribute `key` on the first occurrence of `needle` (ASCII, so byte and UTF-16 offsets agree).
fn attr_at(r: &NSAttributedString, key: &Key, needle: &str) -> Option<AttrValue> {
    let byte = r.string().find(needle).unwrap_or_else(|| panic!("{needle:?} not in {:?}", r.string()));
    let at = r.string()[..byte].encode_utf16().count();
    effective(r, key, at)
}

fn is_single_line(v: &Option<AttrValue>) -> bool {
    matches!(v, Some(AttrValue::UnderlineStyle(_)))
}

fn font_size_at(r: &NSAttributedString, needle: &str) -> f64 {
    match attr_at(r, &Key::Font, needle) {
        Some(AttrValue::Font(f)) => f.pointSize(),
        other => panic!("no font at {needle:?}: {other:?}"),
    }
}

fn baseline_at(r: &NSAttributedString, needle: &str) -> f64 {
    match attr_at(r, &Key::BaselineOffset, needle) {
        Some(AttrValue::Double(d)) => d,
        _ => 0.0,
    }
}

fn paragraph_at(r: &NSAttributedString, needle: &str) -> swiftshim::NSParagraphStyle {
    match attr_at(r, &Key::ParagraphStyle, needle) {
        Some(AttrValue::ParagraphStyle(p)) => p,
        other => panic!("no paragraph style at {needle:?}: {other:?} in {:?}", r.string()),
    }
}

// 1 — inline HTML -----------------------------------------------------------------------------

#[test]
fn inline_html_tags_become_styles_and_never_show_as_text() {
    let r = render(
        "a <u>under</u> <mark>hi</mark> H<sub>2</sub>O x<sup>3</sup> <kbd>Ctrl</kbd> <s>old</s> \
         <del>gone</del> <b>bold</b> <i>it</i> <span class=\"x\">plain</span> <ins>added</ins>\n",
    );
    let text = r.string();
    assert!(!text.contains('<') && !text.contains('>'), "a tag shown as text: {text:?}");
    assert!(text.contains("plain"), "an unknown tag must keep its inner text");
    assert!(is_single_line(&attr_at(&r, &Key::UnderlineStyle, "under")));
    assert!(is_single_line(&attr_at(&r, &Key::UnderlineStyle, "added")));
    assert!(matches!(attr_at(&r, &Key::BackgroundColor, "hi"), Some(AttrValue::Color(_))));
    assert!(is_single_line(&attr_at(&r, &Key::StrikethroughStyle, "old")));
    assert!(is_single_line(&attr_at(&r, &Key::StrikethroughStyle, "gone")));
    assert!(matches!(attr_at(&r, &MDAttr::inline_code(), "Ctrl"), Some(AttrValue::Bool(true))));
    assert!(baseline_at(&r, "2") < 0.0, "subscript sits below the baseline");
    assert!(baseline_at(&r, "3") > 0.0, "superscript sits above the baseline");
    assert!(font_size_at(&r, "3") < BASE * 0.8, "script text is smaller");
    assert_eq!(baseline_at(&r, "plain"), 0.0);
    // The text between two tags is not touched by either.
    assert!(attr_at(&r, &Key::UnderlineStyle, "plain").is_none());
}

#[test]
fn html_br_is_a_line_break_that_keeps_a_table_cell_one_paragraph() {
    let r = render("| a<br>b | c<br/>d |\n|---|---|\n| 1 | 2 |\n");
    assert!(r.string().contains("a\u{2028}b"), "{:?}", r.string());
    assert!(r.string().contains("c\u{2028}d"), "{:?}", r.string());
    assert!(!r.string().contains("<br"));
    let p = render("one<br>two\n");
    assert!(p.string().starts_with("one\u{2028}two"), "{:?}", p.string());
}

#[test]
fn an_unclosed_tag_styles_to_the_end_of_its_paragraph() {
    let r = render("<u>never closed\n\nnext\n");
    assert!(is_single_line(&attr_at(&r, &Key::UnderlineStyle, "closed")));
    assert!(attr_at(&r, &Key::UnderlineStyle, "next").is_none());
}

// 2 — blocks inside a quote -------------------------------------------------------------------

#[test]
fn a_table_in_a_quote_keeps_its_cells() {
    let r = render("> | a | b |\n> |---|---|\n> | 1 | 2 |\n");
    assert!(!paragraph_at(&r, "1").textBlocks.is_empty(), "the cell lost its table block");
    assert!(attr_at(&r, &MDAttr::block_quote(), "1").is_some());
}

#[test]
fn a_list_in_a_quote_keeps_its_hanging_indent_and_gains_the_quote_indent() {
    let plain = render("- one\n- two\n");
    let quoted = render("> - one\n> - two\n");
    let (p, q) = (paragraph_at(&plain, "one"), paragraph_at(&quoted, "one"));
    assert!(!q.tabStops.is_empty(), "the list's tab stop was overwritten");
    assert!(q.headIndent > p.headIndent, "the quote indent must be added: {} vs {}", q.headIndent, p.headIndent);
    assert!(((q.firstLineHeadIndent - p.firstLineHeadIndent) - (q.headIndent - p.headIndent)).abs() < 1e-6);
}

#[test]
fn code_in_a_quote_keeps_its_card_and_is_pushed_in() {
    let r = render("> ```\n> let x = 1\n> ```\n");
    assert!(attr_at(&r, &MDAttr::code_block(), "let x").is_some());
    assert!(matches!(attr_at(&r, &MDAttr::code_inset(), "let x"), Some(AttrValue::Double(d)) if d > 0.0));
}

#[test]
fn nested_quotes_indent_cumulatively() {
    let one = paragraph_at(&render("> a\n"), "a").headIndent;
    let two = paragraph_at(&render("> > a\n"), "a").headIndent;
    assert!(two > one);
}

// 3 — extensions ------------------------------------------------------------------------------

#[test]
fn alerts_carry_a_title_a_kind_and_the_quote_bar() {
    for (marker, title, kind) in [
        ("NOTE", "Note", "note"),
        ("TIP", "Tip", "tip"),
        ("IMPORTANT", "Important", "important"),
        ("WARNING", "Warning", "warning"),
        ("CAUTION", "Caution", "caution"),
    ] {
        let r = render(&format!("> [!{marker}]\n> body text\n"));
        assert!(r.string().starts_with(&format!("{title}\n")), "{:?}", r.string());
        assert!(!r.string().contains("[!"));
        match attr_at(&r, &MDAttr::alert(), "body") {
            Some(AttrValue::Text(v)) => assert!(v.starts_with(&format!("{kind}:")), "{marker}: {v}"),
            other => panic!("{marker}: {other:?}"),
        }
        let two = render(&format!("> [!{marker}]\n> one\n\n> [!{marker}]\n> two\n"));
        assert_ne!(
            attr_at(&two, &MDAttr::alert(), "one"),
            attr_at(&two, &MDAttr::alert(), "two"),
            "adjacent alerts need separate bars"
        );
        assert!(attr_at(&r, &MDAttr::block_quote(), title).is_some(), "{marker}: no bar");
    }
}

#[test]
fn front_matter_is_hidden() {
    let r = render("---\ntitle: secret\ntags: [a]\n---\n\nbody\n");
    assert!(!r.string().contains("secret") && !r.string().contains("title"), "{:?}", r.string());
    assert!(r.string().contains("body"));
}

#[test]
fn a_document_that_merely_opens_with_a_rule_is_not_front_matter() {
    let r = render("---\n\n```swift\nlet x = 1\n```\n\n---\n");
    assert!(r.string().contains("let x = 1"), "{:?}", r.string());
    let two_rules = render("---\nSome prose between two rules.\n---\n");
    assert!(two_rules.string().contains("Some prose"), "{:?}", two_rules.string());
}

#[test]
fn footnotes_link_a_superscript_reference_to_a_notes_section() {
    let r = render("Claim[^a] and again[^a], plus[^b].\n\n[^a]: First note.\n[^b]: Second note.\n");
    let text = r.string().to_string();
    assert!(!text.contains("[^"), "{text:?}");
    assert!(text.contains("First note.") && text.contains("Second note."));
    // The reference: a superscript digit that jumps to its note, and the first one is the way back.
    let at = text.find("Claim").unwrap() + "Claim".len();
    assert_eq!(effective(&r, &MDAttr::anchor(), at), Some(AttrValue::Text("fn:a".into())), "{text:?}");
    assert_eq!(
        effective(&r, &MDAttr::bookmark_target(), at),
        Some(AttrValue::Text("fnref:a".into())), "{:?}", r.runs().iter().filter(|(g, _)| g.location <= at && at < g.maxRange()).collect::<Vec<_>>()
    );
    assert!(baseline_at(&r, "1") > 0.0);
    // The note: numbered, a bookmark target, and an arrow back.
    let u16 = |byte: usize| text[..byte].encode_utf16().count();
    let note = u16(text.find("1.\tFirst").expect("numbered note"));
    assert_eq!(
        effective(&r, &MDAttr::bookmark_target(), note),
        Some(AttrValue::Text("fn:a".into()))
    );
    let arrow = u16(text.find('\u{21A9}').expect("back arrow"));
    assert_eq!(effective(&r, &MDAttr::anchor(), arrow), Some(AttrValue::Text("fnref:a".into())));
    // The section opens with a rule, once.
    assert_eq!(r.runs().iter().filter(|(_, a)| a.contains_key(&MDAttr::rule())).count(), 1);
    assert!(text.find("2.\tSecond").unwrap() > text.find("1.\tFirst").unwrap());
}

#[test]
fn inline_footnotes_are_rendered() {
    let r = render("Text^[an inline note] here.\n");
    assert!(r.string().contains("an inline note"), "{:?}", r.string());
    assert!(!r.string().contains("^["));
}

#[test]
fn description_lists_show_the_term_and_hang_its_details() {
    let r = render("Apple\n: A red fruit\n: Also a company\n\nPear\n: Green\n");
    let t = r.string();
    for word in ["Apple", "A red fruit", "Also a company", "Pear", "Green"] {
        assert!(t.contains(word), "{word}: {t:?}");
    }
    // A second `: details` under the same term arrives as an item with no term of its own.
    assert!(!t.contains("\n\n"), "no blank paragraph between a term and its details: {t:?}");
    assert!(paragraph_at(&r, "A red fruit").headIndent > paragraph_at(&r, "Apple").headIndent);
}

#[test]
fn highlight_insert_superscript_spoiler_and_wikilinks() {
    let r = render("x^2^ ==hot== ++new++ ||secret|| [[Page|Shown]] [[Bare]]\n");
    let t = r.string();
    for marker in ["^", "==", "++", "||", "[["] {
        assert!(!t.contains(marker), "{marker} shown: {t:?}");
    }
    assert!(baseline_at(&r, "2") > 0.0);
    assert!(matches!(attr_at(&r, &Key::BackgroundColor, "hot"), Some(AttrValue::Color(_))));
    assert!(is_single_line(&attr_at(&r, &Key::UnderlineStyle, "new")));
    assert!(matches!(attr_at(&r, &Key::BackgroundColor, "secret"), Some(AttrValue::Color(_))));
    assert!(t.contains("Shown") && t.contains("Bare") && !t.contains("Page"));
}

#[test]
fn excluded_extensions_keep_their_commonmark_meaning() {
    // `extension.underline` would underline `__x__`; `extension.subscript` would swallow `~x~`.
    let r = render("__bold__ and ~struck~ and >greentext\n");
    assert!(attr_at(&r, &Key::UnderlineStyle, "bold").is_none(), "__x__ must stay strong");
    assert!(is_single_line(&attr_at(&r, &Key::StrikethroughStyle, "struck")));
    assert!(r.string().contains(">greentext"));
}

#[test]
fn multiline_block_quotes_render_as_a_quote() {
    let r = render(">>>\nfirst\n\nsecond\n>>>\n");
    assert!(!r.string().contains(">>>"), "{:?}", r.string());
    assert!(attr_at(&r, &MDAttr::block_quote(), "first").is_some());
    assert!(attr_at(&r, &MDAttr::block_quote(), "second").is_some());
}

#[test]
fn cjk_friendly_emphasis_closes_after_punctuation() {
    let r = render("**「안녕」**입니다\n");
    assert!(!r.string().contains("**"), "{:?}", r.string());
}

#[test]
fn relaxed_task_lists_and_tasks_in_tables() {
    let r = render("- [x]  done with two spaces\n- [ ]\tundone with a tab\n");
    assert!(r.string().contains("\u{2611}\t"), "{:?}", r.string());
    assert!(r.string().contains("\u{2610}\t"), "{:?}", r.string());
    let t = render("| task |\n|---|\n| [x] |\n");
    assert!(t.string().contains("\u{2611}"), "{:?}", t.string());
    assert!(!t.string().contains("[x]"), "{:?}", t.string());
}

#[test]
fn heading_attributes_are_hidden_and_the_id_is_a_jump_target() {
    let r = render("## Title {#my-id}\n\ntext\n");
    assert!(r.string().starts_with("Title\n"), "{:?}", r.string());
    assert_eq!(
        attr_at(&r, &MDAttr::bookmark_target(), "Title"),
        Some(AttrValue::Text("my-id".into()))
    );
}

// 4–5 — tables and lists ----------------------------------------------------------------------

#[test]
fn table_column_alignment_is_honoured() {
    let r = render("| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n");
    use swiftshim::NSTextAlignment as A;
    assert_eq!(paragraph_at(&r, "2").alignment, A::Center);
    assert_eq!(paragraph_at(&r, "3").alignment, A::Right);
    assert_ne!(paragraph_at(&r, "1").alignment, A::Center);
    assert!(!paragraph_at(&r, "2").textBlocks.is_empty(), "alignment must not cost the cell its block");
    // On the wire it is AppKit's own raw value: right = 1, center = 2 (macOS, not the iOS numbering).
    let wire = wire_for("| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n");
    let mut seen: Vec<i32> = wire.paragraph_styles.iter().map(|p| p.alignment).collect();
    seen.sort();
    seen.dedup();
    assert!(seen.contains(&1) && seen.contains(&2), "{seen:?}");
}

#[test]
fn an_ordered_list_starts_at_its_own_number() {
    let r = render("3. three\n4. four\n");
    assert!(r.string().starts_with("3.\tthree\n4.\tfour"), "{:?}", r.string());
    let nested = render("- a\n\n  7. deep\n  8. deeper\n");
    assert!(nested.string().contains("7.\tdeep") && nested.string().contains("8.\tdeeper"), "{:?}", nested.string());
}

// 6 — HTML blocks -----------------------------------------------------------------------------

#[test]
fn html_blocks_show_their_text_instead_of_vanishing() {
    let r = render("<details>\n<summary>The title</summary>\n\nHidden body.\n\n</details>\n");
    let t = r.string();
    assert!(t.contains("The title") && t.contains("Hidden body."), "{t:?}");
    assert!(!t.contains('<'), "{t:?}");
    assert!(t.find("The title").unwrap() < t.find("Hidden body.").unwrap());

    let d = render("<div>one<br>two</div>\n");
    assert!(d.string().contains("one\u{2028}two"), "{:?}", d.string());

    let c = render("<!-- a comment -->\n\ntext\n");
    assert!(!c.string().contains("comment") && c.string().contains("text"), "{:?}", c.string());

    let table = render("<table>\n<tr><td>cell A</td><td>cell B</td></tr>\n</table>\n");
    assert!(table.string().contains("cell A") && table.string().contains("cell B"), "{:?}", table.string());
}

#[test]
fn a_block_image_is_still_an_image() {
    let r = render("<img src=\"a.png\" alt=\"x\">\n");
    assert!(r.runs().iter().any(|(_, a)| a.contains_key(&MDAttr::image())));
}

// 7 — blocks inside a list item ---------------------------------------------------------------

#[test]
fn blocks_inside_a_list_item_sit_under_its_text() {
    let r = render(
        "- item\n\n  ```\n  code line\n  ```\n\n  > quoted\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n",
    );
    let hang = BASE * 1.7;
    assert!(attr_at(&r, &MDAttr::code_block(), "code line").is_some());
    assert!(matches!(attr_at(&r, &MDAttr::code_inset(), "code line"), Some(AttrValue::Double(d)) if d >= hang - 0.01));
    assert!(paragraph_at(&r, "quoted").headIndent >= hang, "quote not under the item text");
    assert!(
        matches!(attr_at(&r, &MDAttr::quote_inset(), "quoted"), Some(AttrValue::Double(d)) if (d - hang).abs() < 0.01),
        "the quote bar must start under the item text"
    );
    assert!(!paragraph_at(&r, "1").textBlocks.is_empty(), "table lost its cells");
}

// the wire ------------------------------------------------------------------------------------

const KITCHEN_SINK: &str = "---\ntitle: x\n---\n\n# Head {#h}\n\n\
a <u>u</u> <mark>m</mark> H<sub>2</sub>O <sup>s</sup> <kbd>k</kbd> <s>s</s> <b>b</b> <i>i</i><br>next\n\n\
x^2^ ==hot== ++new++ ||sp|| [[W]] note[^1]\n\n> [!TIP]\n> tip body\n\n> - q\n>\n> | a | b |\n> |:-|-:|\n> | 1 | 2 |\n\n\
Term\n: Detail\n\n3. three\n\n<details>\n<summary>S</summary>\n\nB\n\n</details>\n\n[^1]: The note.\n";

/// Every (key, value) pair `markdown_wire::project` has a column for. A pair outside this list is
/// what makes the projection print "has no column for" and drop an attribute.
fn carried(key: &Key, value: &AttrValue) -> bool {
    matches!(
        (key, value),
        (Key::Font, AttrValue::Font(_))
            | (Key::ForegroundColor, AttrValue::Color(_))
            | (Key::ParagraphStyle, AttrValue::ParagraphStyle(_))
            | (Key::Attachment, AttrValue::Attachment(_))
            | (Key::UnderlineStyle, AttrValue::UnderlineStyle(_))
            | (Key::StrikethroughStyle, AttrValue::UnderlineStyle(_))
            | (Key::BackgroundColor, AttrValue::Color(_))
            | (Key::BaselineOffset, AttrValue::Double(_))
            | (Key::Link, AttrValue::Text(_))
    ) || matches!(key, Key::Custom(_))
}

#[test]
fn every_attribute_the_fixture_produces_has_a_wire_column() {
    let r = render(KITCHEN_SINK);
    let mut orphans = Vec::new();
    for (_, attrs) in r.runs() {
        for (k, v) in attrs {
            if !carried(k, v) {
                orphans.push(format!("{k:?} / {v:?}"));
            }
        }
    }
    assert!(orphans.is_empty(), "{orphans:?}");
    let wire = wire_for(KITCHEN_SINK);
    assert!(wire.layer_baseline.iter().any(|b| *b > 0.0) && wire.layer_baseline.iter().any(|b| *b < 0.0));
    assert!(wire.layer_background.iter().any(|c| *c >= 0));
    let json = serde_json::to_string(&wire).unwrap();
    let back: MarkdownWire = serde_json::from_str(&json).unwrap();
    assert_eq!(back, wire);
}

#[test]
fn script_text_keeps_its_role_so_the_host_can_rebuild_it() {
    let wire = wire_for("a<sup>b</sup>\n");
    let script = wire.fonts.iter().find(|f| f.size < BASE * 0.8).expect("a script-size font");
    assert_eq!(script.role, "body", "a script font must name its role, not travel as a raw face: {script:?}");
}

#[test]
fn a_document_without_them_pays_nothing_for_the_new_columns() {
    let json = serde_json::to_string(&wire_for("plain *text* and `code`\n")).unwrap();
    assert!(!json.contains("layer_background") && !json.contains("layer_baseline"), "{json}");
}
