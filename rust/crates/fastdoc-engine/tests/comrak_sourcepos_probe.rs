//! Throwaway measurement probe (S3, pass A gate) — NOT the producer's test suite. Prints comrak's
//! raw `Sourcepos` for a Korean+emoji+tab fixture so pass A can measure, rather than assume,
//! whether `LineColumn::column` counts UTF-8 bytes or Unicode characters, and how a literal tab
//! character affects it. Run with `cargo test --test comrak_sourcepos_probe -- --nocapture`.

use comrak::nodes::NodeValue;
use comrak::{parse_document, Arena, Options};

#[test]
fn probe_column_unit_and_tab_handling() {
    let arena = Arena::new();
    let options = Options::default();
    // Line 1: heading with Korean text and an emoji.
    // Line 2: blank.
    // Line 3: paragraph with a literal TAB in the middle, between Korean and ASCII (Text node, not indented code).
    let text = "# 안녕 🎉 world\n\n안녕\tabc\n";
    let root = parse_document(&arena, text, &options);

    for node in root.descendants() {
        let ast = node.data.borrow();
        println!("{:?} sourcepos={}", &ast.value, ast.sourcepos);
    }

    // Byte layout, so this test documents ground truth alongside the printed probe:
    // line 1 = "# 안녕 🎉 world\n"
    //   '#'=1B '  '=1B '안'=3B '녕'=3B ' '=1B '🎉'=4B ' '=1B "world"=5B '\n'
    // line 3 = "\t안녕abc\n"
    //   '\t'=1B '안'=3B '녕'=3B "abc"=3B '\n'
    let heading = root
        .descendants()
        .find(|n| matches!(n.data.borrow().value, NodeValue::Heading(_)))
        .unwrap();
    let heading_sp = heading.data.borrow().sourcepos;
    println!("HEADING sourcepos = {heading_sp}");

    let paragraph_line3 = root
        .descendants()
        .find(|n| {
            matches!(n.data.borrow().value, NodeValue::Paragraph)
                && n.data.borrow().sourcepos.start.line == 3
        })
        .unwrap();
    let para_sp = paragraph_line3.data.borrow().sourcepos;
    println!("LINE3 PARAGRAPH sourcepos = {para_sp}");
}

#[test]
fn probe_end_column_points_to_first_or_last_byte_of_final_multibyte_char() {
    let arena = Arena::new();
    let options = Options::default();
    // Heading ends in an emoji (4 bytes): "# hi 🎉" — line bytes: '#'=1 ' '=1 h=1 i=1 ' '=1 🎉=4 = 9 total.
    // If end.column points to the FIRST byte of the final char: 6 (0-based byte 5, 1-based col 6).
    // If end.column points to the LAST byte of the final char: 9 (0-based byte 8, 1-based col 9).
    let text = "# hi 🎉\n";
    let root = parse_document(&arena, text, &options);
    let heading = root
        .descendants()
        .find(|n| matches!(n.data.borrow().value, NodeValue::Heading(_)))
        .unwrap();
    println!("EMOJI-END HEADING sourcepos = {}", heading.data.borrow().sourcepos);
}
