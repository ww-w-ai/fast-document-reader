//! The transliteration of `Render/MarkdownRenderer.swift`, actually run.
//!
//! `Scripts/port-coverage.py` read this file at **0/829** while the module was absent: S3 wrote a
//! fresh producer against the canonical tree and deleted the transliteration (`ec0b49b`), which
//! left the format this app is named for as the only manifest entry with no port at all. The
//! module is restored from `3f659a4`, its four `todo!()`s — all of them the `swift-markdown`
//! PACKAGE, never the renderer — are backed by `markdown_package`, and these tests are the first
//! thing that proves the ported renderer produces text rather than merely compiling.
//!
//! This is NOT a parity suite against the Swift build; that comes next and needs both sides
//! running on the same document. These are the shape checks that must hold before parity is even
//! worth measuring.

use fastdoc_engine::render::markdown_renderer::MarkdownRenderer;
use fastdoc_engine::render::render_theme::RenderTheme;
use swiftshim::color_font::{NSFontDescriptor, NSFontDescriptorSymbolicTraits, NSFontWeight};
use swiftshim::font_provider::{self, FaceId, FaceInfo, FontProvider};

/// A font world with exactly one face in it.
///
/// `font_provider::provider()` panics when nothing is installed, and that is deliberate — both
/// "every font exists" and "no font exists" render a plausible document with the wrong typefaces
/// and report nothing. A Rust integration test has no AppKit to install the real one from, and
/// this repo had no stub at all, which is why the ported renderer had never been RUN outside the
/// app despite compiling.
///
/// So this is the smallest world that lets the renderer finish, and it is deliberately blind:
/// every name resolves to the same face and that face covers every scalar, so nothing here can
/// say anything about font CHOICE. These tests assert on text, and the parity suite that compares
/// this renderer against the Swift one has to run inside the app, against the real provider.
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

fn install_font_world() {
    // `install` is a `OnceLock` set: the first test through wins and the rest are no-ops, which is
    // what we want when the harness runs them on several threads.
    let _ = font_provider::install(Box::new(SingleFaceWorld));
}

fn render(markdown: &str) -> String {
    install_font_world();
    let theme = RenderTheme::current(13.0);
    MarkdownRenderer::render(markdown, &theme).string().to_string()
}

#[test]
fn a_heading_and_a_paragraph_reach_the_rendered_string() {
    let out = render("# Title\n\nSome prose here.\n");
    assert!(out.contains("Title"), "heading text is missing from: {out:?}");
    assert!(out.contains("Some prose here."), "paragraph text is missing from: {out:?}");
}

#[test]
fn inline_styles_keep_their_text() {
    let out = render("A **bold** and *italic* and `code` word.\n");
    for word in ["bold", "italic", "code"] {
        assert!(out.contains(word), "{word} is missing from: {out:?}");
    }
}

#[test]
fn a_list_renders_every_item() {
    let out = render("- alpha\n- beta\n- gamma\n");
    for item in ["alpha", "beta", "gamma"] {
        assert!(out.contains(item), "{item} is missing from: {out:?}");
    }
}

#[test]
fn a_fenced_code_block_keeps_its_body() {
    let out = render("```rust\nlet x = 1;\n```\n");
    assert!(out.contains("let x = 1;"), "code body is missing from: {out:?}");
}

#[test]
fn a_table_renders_its_cells() {
    let out = render("| a | b |\n|---|---|\n| 1 | 2 |\n");
    for cell in ["a", "b", "1", "2"] {
        assert!(out.contains(cell), "cell {cell} is missing from: {out:?}");
    }
}

#[test]
fn a_block_quote_keeps_its_prose() {
    let out = render("> quoted line\n");
    assert!(out.contains("quoted line"), "{out:?}");
}

/// The renderer must not lose the bulk of a real document. A novel that renders to a handful of
/// characters is the failure mode a "does it contain this word" test cannot see.
#[test]
fn a_long_document_renders_in_proportion_to_its_source() {
    let mut source = String::new();
    for i in 0..500 {
        source.push_str(&format!("## Section {i}\n\nSome prose for section {i}.\n\n"));
    }
    let out = render(&source);
    assert!(
        out.len() > source.len() / 2,
        "rendered {} characters from {} of markdown — most of the document did not survive",
        out.len(),
        source.len()
    );
}

/// `autolink` is the one pass that was DEAD in the restored transliteration, twice over.
///
/// Its two scanners are `NSDataDetector` and `NSRegularExpression`, and both were `todo!()` in
/// `swiftshim::regex` — so the whole pass panicked the moment it ran, which is why nothing here
/// had ever executed it. Backing them with a real engine exposed a second, quieter defect: the
/// transliteration called `firstMatch` where `MarkdownRenderer.swift:97` and `:110` both call
/// `enumerateMatches`, so even once it ran it would have linked the FIRST url in a document and
/// silently left every other one as plain text. A shape test that renders one link cannot see
/// that; these render several.
fn links_in(markdown: &str) -> Vec<(String, String)> {
    install_font_world();
    let theme = RenderTheme::current(13.0);
    let rendered = MarkdownRenderer::render(markdown, &theme);
    let text = swiftshim::SwiftString::new(rendered.string());
    let mut out = Vec::new();
    let mut at = 0usize;
    while at < rendered.length() {
        // `attribute` hands back the EFFECTIVE range with the value, so the span of one link is
        // read rather than rebuilt by scanning character by character.
        let Some((value, effective)) =
            rendered.attribute(&swiftshim::NSAttributedStringKey::Link, at)
        else {
            at += 1;
            continue;
        };
        let url = match value {
            swiftshim::AttrValue::Text(t) => t.clone(),
            other => format!("{other:?}"),
        };
        out.push((text.substring(effective), url));
        at = effective.maxRange().max(at + 1);
    }
    out
}

#[test]
fn every_bare_url_is_linked_not_merely_the_first() {
    let links = links_in("See https://one.example and https://two.example and https://three.example.\n");
    let urls: Vec<&str> = links.iter().map(|(_, u)| u.as_str()).collect();
    assert_eq!(
        urls,
        vec!["https://one.example", "https://two.example", "https://three.example"],
        "the Swift original enumerates ALL matches; got {links:?}"
    );
}

#[test]
fn a_detected_link_carries_the_detectors_url_not_the_matched_text() {
    // `MarkdownRenderer.swift:98` reads `m.url`, which is where the scheme a bare `www.` host
    // never wrote comes from. Storing the matched TEXT instead ships an unopenable link.
    let links = links_in("Visit www.example.com or mail someone@example.com.\n");
    assert_eq!(
        links,
        vec![
            ("www.example.com".to_string(), "https://www.example.com".to_string()),
            ("someone@example.com".to_string(), "mailto:someone@example.com".to_string()),
        ],
        "got {links:?}"
    );
}

#[test]
fn a_url_inside_code_is_left_alone() {
    // The renderer's own comment: link styling is painted after highlighting, so an autolinked
    // URL in a fence kills the syntax colour right there.
    let links = links_in("`https://in-code.example` and https://in-prose.example\n");
    let urls: Vec<&str> = links.iter().map(|(_, u)| u.as_str()).collect();
    assert_eq!(urls, vec!["https://in-prose.example"], "got {links:?}");
}

#[test]
fn a_markdown_link_is_not_overwritten_by_the_detector() {
    let links = links_in("[label](https://written.example)\n");
    assert_eq!(links.len(), 1, "got {links:?}");
    assert_eq!(links[0].0, "label");
    assert_eq!(links[0].1, "https://written.example");
}

#[test]
fn file_paths_are_linked_at_a_word_boundary_and_shed_trailing_punctuation() {
    let links = links_in("Open ./notes/a.md, then /etc/hosts. Not and/or.\n");
    let texts: Vec<&str> = links.iter().map(|(t, _)| t.as_str()).collect();
    assert_eq!(
        texts,
        vec!["./notes/a.md", "/etc/hosts"],
        "the comma and the full stop belong to the sentence, and `and/or` has no leading \
         boundary; got {links:?}"
    );
    assert!(
        links.iter().all(|(_, u)| u == "fmdpath:file"),
        "a file path is resolved by the link handler, not by its own url; got {links:?}"
    );
}

#[test]
fn a_range_the_detector_reports_is_measured_the_way_the_string_is_indexed() {
    // An NSRange is UTF-16 and the regex engine underneath works in bytes. Korean prose is three
    // bytes to the character, so a byte offset used as an index lands mid-word — or panics.
    let links = links_in("한국어 문장 안의 https://예시.example 링크입니다.\n");
    assert_eq!(links.len(), 1, "got {links:?}");
    assert_eq!(
        links[0].0, "https://예시.example",
        "the highlighted span must be the url itself, not a slice offset by the byte/unit \
         difference of the Korean text before it"
    );
}

/// The Rust half of the markdown Rust↔Swift comparison, deliberately the SAME SHAPE as
/// `Tests/FastDocReaderTests/MarkdownParseCostProbeTests.swift` so the two numbers are about the
/// same work: parse alone (minimum of three, because the first run pays for cold pages), then the
/// whole render including the attributed-string build.
///
/// Set `FMD_MD_PARSE_PROBE` to the same file the Swift probe is given, and run **`--release`** —
/// this repo has already reported a debug figure as if it were real once (1,102 ms against a true
/// 63.7), and the mistake is worth naming rather than repeating.
///
/// This is the office comparison's shape applied to markdown: `--extract` puts the two office
/// readers on one document and reports both; here the ported renderer and the host renderer each
/// get the same novel. Neither number means anything without the other.
#[test]
fn what_the_ported_renderer_costs_on_a_real_document() {
    let Ok(path) = std::env::var("FMD_MD_PARSE_PROBE") else {
        eprintln!("SKIP: set FMD_MD_PARSE_PROBE to an absolute path naming a markdown file");
        return;
    };
    let text = std::fs::read_to_string(&path).expect("FMD_MD_PARSE_PROBE must name a readable file");
    install_font_world();

    fn ms(body: impl FnOnce()) -> f64 {
        let t = std::time::Instant::now();
        body();
        t.elapsed().as_secs_f64() * 1000.0
    }

    let mut parse_samples = Vec::new();
    for _ in 0..3 {
        let mut parsed = None;
        parse_samples.push(ms(|| {
            parsed = Some(fastdoc_engine::render::markdown_package::parse_document_text(&text))
        }));
        assert!(parsed.is_some());
    }
    let theme = RenderTheme::current(13.0);
    let mut built = None;
    let render_ms = ms(|| built = Some(MarkdownRenderer::render(&text, &theme)));
    let built = built.unwrap();

    let name = std::path::Path::new(&path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or(path.clone());
    println!(
        "MDPARSE-RUST file={name} bytes={} chars={} parseMinMs={:.1} renderMs={:.1} builtChars={}",
        text.len(),
        text.chars().count(),
        parse_samples.iter().cloned().fold(f64::INFINITY, f64::min),
        render_ms,
        built.length()
    );
}

/// The ported renderer must not re-index the document once per character it reads.
///
/// This is the gate on the defect the transliteration shipped with: `SwiftString::characterAt`
/// rebuilt the whole UTF-16 index on every call, and `AttributedBuilder::new` calls it once per
/// character, so rendering cost grew with the SQUARE of the document. Measured before the fix:
/// `demo/moby-dick.md` took 20.2 minutes against the host renderer's 479 ms, and `time / chars²`
/// held at ~8e-7 across a 128x size range. After: 120 ms.
///
/// What it asserts is a COUNT, not a duration — how many times a UTF-16 index gets built while a
/// document renders. That number is a property of the code's shape, so it is identical on an idle
/// machine and a loaded one; this repo's own suite already names its wall-clock tests as false-
/// failure repeat offenders. Doubling the document must not double the count: the old code's count
/// tracked the character total, so it fails this outright rather than by a margin.
#[test]
fn rendering_does_not_rebuild_the_utf16_index_per_character() {
    let unit = "# Heading\n\nSome *body* text with a [link](https://example.com) and `code`.\n\n\
                > A quote, and a line with 한글 so the units are not all one code unit.\n\n";
    let small: String = unit.repeat(200);
    let large: String = unit.repeat(400);
    install_font_world();
    let theme = RenderTheme::current(13.0);

    let before_small = swiftshim::nsstring::utf16_index_builds();
    let built_small = MarkdownRenderer::render(&small, &theme);
    let small_builds = swiftshim::nsstring::utf16_index_builds() - before_small;

    let before_large = swiftshim::nsstring::utf16_index_builds();
    let built_large = MarkdownRenderer::render(&large, &theme);
    let large_builds = swiftshim::nsstring::utf16_index_builds() - before_large;

    // The documents really are the sizes this test thinks they are, so a renderer that quietly
    // produced nothing could not pass by building nothing.
    assert!(
        built_small.length() > 10_000 && built_large.length() > built_small.length(),
        "the fixtures did not render: small={} large={}",
        built_small.length(),
        built_large.length()
    );

    // Twice the document, essentially the same number of index builds. The bound is deliberately
    // loose — the claim is "not proportional to length", and the failure it guards against is a
    // count in the hundreds of thousands, not a count of nine instead of eight.
    assert!(
        large_builds <= small_builds + 8,
        "the UTF-16 index is being rebuilt as the document grows: \
         {small_builds} builds for {} chars, {large_builds} for {} chars",
        small.chars().count(),
        large.chars().count()
    );
}
