//! S2A2 Pass C, unit S2A2-07's feature-fixture half.
//!
//! `office_reader_reachability.rs` proves each reader is REACHED, with the four minimal fixtures
//! `Tests/Baseline/fixtures.json`'s `sources` array already carries. It proves nothing about
//! vocabulary: a synthetic docx/odt with one paragraph, and `blank2010.hwp`/`hwpx-01-saved.hwpx`,
//! declare none of a multi-column layout, a table, a diagonal, a form control, or a picture fill.
//!
//! This file drives NINE real, licensed HWP/HWPX documents — registered in the same manifest's new
//! `featureFixtures` array, each with full provenance (id/class/kind/origin/immutableRevision/
//! license/licenseFile/redistribution/expectedSha256, plus `family`/`why`) — through
//! `HwpReader::read_before_host_font_substitution` and asserts a TYPED, feature-specific anchor on
//! the resulting `OfficeReadResult`: a `Span.column_layout` whose `count` is actually `> 1`, a
//! `Cell.diagonal`, a `Span.form_control`, a nested `OfficeBlock::Table` inside a cell, a
//! `Cell.background_image` (a picture fill), pre-decoded bytes in `OfficeReadResult.images`, and —
//! the one true refusal boundary — `office_export::assert_exportable` returning
//! `Err(NotExportable::CellBackgroundImage)` for a document whose only unexportable content is that
//! picture fill. "It parsed without error" is never accepted as an anchor here: every assertion
//! first pins the expected COUNT (`assert!(... >= N)` or `assert_eq!`) before it inspects contents,
//! so a walk that silently found nothing fails loudly rather than passing vacuously.
//!
//! DOCX and ODT carry no real-document corpus in this repository (`Tests/Baseline/fixtures.json`'s
//! `sources` entries for both are project-authored one-paragraph literals) — every family below is
//! therefore explicitly UNCOVERED for those two formats, not silently narrowed. Reviewer comments
//! ("annotations") are uncovered for every format this crate reads today: `HwpReader::read`
//! (`mapping.rs`, around its `OfficeReadResult { blocks, comments: Vec::new(), .. }` construction)
//! hardcodes `comments` to `[]` — HWP comment support is architecture, not corpus, work — and DOCX/
//! ODT have no corpus to prove it with either. See the coverage table in this file's final test.
//!
//! HWP/HWPX go through `HwpReader::read_before_host_font_substitution`, never `::read` — `::read`
//! resolves fonts against a host `FontProvider` only the macOS app installs, and panics in a Rust
//! test (`office_reader_reachability.rs`'s doc comment on `assert_reachable`).

use fastdoc_engine::render::office::hwp_reader::HwpReader;
use fastdoc_engine::render::office::office_block::{Cell, OfficeBlock, OfficeReadResult};
use fastdoc_engine::render::office::office_export::{assert_exportable, NotExportable};
use swiftshim::Data;

/// `Vendor/rhwp-src/samples/<relative>`, resolved from `CARGO_MANIFEST_DIR` (this crate is
/// `rust/crates/fastdoc-engine`; the vendor tree is three levels up, at `rust/../Vendor`) — never
/// an absolute author path, matching `office_reader_reachability.rs`'s `rhwp_saved_fixture`.
fn sample(relative: &str) -> Vec<u8> {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("Vendor/rhwp-src/samples")
        .join(relative);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing required feature fixture {} ({e}); run: git submodule update --init -- Vendor/rhwp-src",
            path.display()
        )
    })
}

fn read(relative: &str) -> OfficeReadResult {
    let bytes = sample(relative);
    let data = Data::fromBytes(bytes);
    HwpReader::read_before_host_font_substitution(&data)
        .unwrap_or_else(|e| panic!("{relative}: HwpReader::read_before_host_font_substitution failed: {e:?}"))
}

/// The `expectedSha256` a `featureFixtures` id carries in `Tests/Baseline/fixtures.json`, read at
/// test time — `office_reader_reachability.rs`'s `manifest_expected_sha256` does the same for
/// `sources`, for the same reason: a copied literal goes stale silently, the manifest does not.
fn manifest_feature_sha256(fixture_id: &str) -> String {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("Tests/Baseline/fixtures.json");
    let bytes = std::fs::read(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture manifest {} ({e})", path.display()));
    let manifest: serde_json::Value = serde_json::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("fixture manifest {} is not valid JSON ({e})", path.display()));
    let entries = manifest["featureFixtures"]
        .as_array()
        .unwrap_or_else(|| panic!("fixture manifest has no `featureFixtures` array"));
    let entry = entries
        .iter()
        .find(|s| s["id"].as_str() == Some(fixture_id))
        .unwrap_or_else(|| panic!("fixture manifest declares no featureFixtures entry with id {fixture_id:?}"));
    for key in [
        "id", "class", "kind", "origin", "immutableRevision", "license", "licenseFile",
        "redistribution", "expectedSha256",
    ] {
        assert!(
            entry.get(key).is_some(),
            "featureFixtures[{fixture_id:?}] is missing required provenance field {key:?}"
        );
    }
    entry["expectedSha256"]
        .as_str()
        .unwrap_or_else(|| panic!("featureFixtures[{fixture_id:?}] has no `expectedSha256`"))
        .to_string()
}

fn assert_matches_manifest(fixture_id: &str, relative_path: &str) {
    let bytes = sample(relative_path);
    let sha = {
        use sha2::{Digest, Sha256};
        format!("{:x}", Sha256::digest(&bytes))
    };
    assert_eq!(
        sha,
        manifest_feature_sha256(fixture_id),
        "{relative_path}: on-disk bytes diverge from featureFixtures[{fixture_id:?}]'s expectedSha256"
    );
}

// -------------------------------------------------------------------------------------------
// Walk helpers — recurse into table cells (including nested tables), since a column layout, a
// form control, a diagonal or a picture fill can all occur inside a cell, not just at top level.
// -------------------------------------------------------------------------------------------

/// Every `Span.column_layout` in the document, in encounter order.
fn column_layouts(result: &OfficeReadResult) -> Vec<i64> {
    let mut out = Vec::new();
    walk(&result.blocks, &mut |block| {
        if let OfficeBlock::Heading { spans, .. }
        | OfficeBlock::Paragraph { spans, .. }
        | OfficeBlock::ListItem { spans, .. } = block
        {
            for s in spans {
                if let Some(cl) = &s.column_layout {
                    out.push(cl.count);
                }
            }
        }
    });
    out
}

/// Every `Span.form_control` in the document.
fn form_control_count(result: &OfficeReadResult) -> usize {
    let mut n = 0usize;
    walk(&result.blocks, &mut |block| {
        if let OfficeBlock::Heading { spans, .. }
        | OfficeBlock::Paragraph { spans, .. }
        | OfficeBlock::ListItem { spans, .. } = block
        {
            n += spans.iter().filter(|s| s.form_control.is_some()).count();
        }
    });
    n
}

/// Every cell (including nested-table cells) that carries a diagonal.
fn diagonal_count(result: &OfficeReadResult) -> usize {
    let mut n = 0usize;
    walk_cells(&result.blocks, &mut |cell| {
        if cell.diagonal.is_some() {
            n += 1;
        }
    });
    n
}

/// Every cell (including nested-table cells) that carries a picture fill.
fn cell_background_image_count(result: &OfficeReadResult) -> usize {
    let mut n = 0usize;
    walk_cells(&result.blocks, &mut |cell| {
        if cell.background_image.is_some() {
            n += 1;
        }
    });
    n
}

/// True if some table cell's OWN blocks contain a nested `OfficeBlock::Table` — a real nested
/// grid, not a table merely sitting alongside another one at the top level.
fn has_nested_table(result: &OfficeReadResult) -> bool {
    let mut found = false;
    walk_cells(&result.blocks, &mut |cell| {
        if cell.blocks.iter().any(|b| matches!(b, OfficeBlock::Table { .. })) {
            found = true;
        }
    });
    found
}

fn walk(blocks: &[OfficeBlock], f: &mut impl FnMut(&OfficeBlock)) {
    for block in blocks {
        f(block);
        if let OfficeBlock::Table { rows, .. } = block {
            for row in rows {
                for cell in row {
                    walk(&cell.blocks, f);
                }
            }
        }
    }
}

fn walk_cells(blocks: &[OfficeBlock], f: &mut impl FnMut(&Cell)) {
    for block in blocks {
        if let OfficeBlock::Table { rows, .. } = block {
            for row in rows {
                for cell in row {
                    f(cell);
                    walk_cells(&cell.blocks, f);
                }
            }
        }
    }
}

// -------------------------------------------------------------------------------------------
// multi-column authority — SO-SUEOP.hwp / .hwpx
// -------------------------------------------------------------------------------------------

#[test]
fn hwp_multi_column_authority_declares_more_than_one_column() {
    assert_matches_manifest("feature-multi-column-hwp", "SO-SUEOP.hwp");
    let result = read("SO-SUEOP.hwp");
    let layouts = column_layouts(&result);
    assert!(
        layouts.len() >= 2,
        "SO-SUEOP.hwp: expected at least 2 column_layout declarations, found {}",
        layouts.len()
    );
    assert!(
        layouts.iter().any(|&c| c > 1),
        "SO-SUEOP.hwp: no column_layout declares more than 1 column — anchor not reached; declarations were {layouts:?}"
    );
}

#[test]
fn hwpx_multi_column_authority_declares_more_than_one_column() {
    assert_matches_manifest("feature-multi-column-hwpx", "SO-SUEOP.hwpx");
    let result = read("SO-SUEOP.hwpx");
    let layouts = column_layouts(&result);
    assert!(
        layouts.len() >= 2,
        "SO-SUEOP.hwpx: expected at least 2 column_layout declarations, found {}",
        layouts.len()
    );
    assert!(
        layouts.iter().any(|&c| c > 1),
        "SO-SUEOP.hwpx: no column_layout declares more than 1 column — anchor not reached; declarations were {layouts:?}"
    );
}

// -------------------------------------------------------------------------------------------
// diagonals — 대각선샘플.hwp / .hwpx (rhwp's own diagonal-line sample)
// -------------------------------------------------------------------------------------------

#[test]
fn hwp_cell_diagonal_arrives() {
    assert_matches_manifest("feature-diagonal-hwp", "대각선샘플.hwp");
    let result = read("대각선샘플.hwp");
    let n = diagonal_count(&result);
    assert_eq!(n, 9, "대각선샘플.hwp: expected exactly 9 cells with a diagonal, found {n}");
}

#[test]
fn hwpx_cell_diagonal_arrives() {
    assert_matches_manifest("feature-diagonal-hwpx", "대각선샘플.hwpx");
    let result = read("대각선샘플.hwpx");
    let n = diagonal_count(&result);
    assert_eq!(n, 9, "대각선샘플.hwpx: expected exactly 9 cells with a diagonal, found {n}");
}

// -------------------------------------------------------------------------------------------
// form controls — form-02.hwp / hwpx/form-02.hwpx
// -------------------------------------------------------------------------------------------

#[test]
fn hwp_form_control_arrives() {
    assert_matches_manifest("feature-form-control-hwp", "form-02.hwp");
    let result = read("form-02.hwp");
    let n = form_control_count(&result);
    assert_eq!(n, 5, "form-02.hwp: expected exactly 5 spans with a form_control, found {n}");
}

#[test]
fn hwpx_form_control_arrives() {
    assert_matches_manifest("feature-form-control-hwpx", "hwpx/form-02.hwpx");
    let result = read("hwpx/form-02.hwpx");
    let n = form_control_count(&result);
    assert_eq!(n, 5, "hwpx/form-02.hwpx: expected exactly 5 spans with a form_control, found {n}");
}

// -------------------------------------------------------------------------------------------
// nested/rich tables + resources (images) — tac-img-02.hwp / .hwpx
// -------------------------------------------------------------------------------------------

#[test]
fn hwp_nested_table_and_resources_arrive() {
    assert_matches_manifest("feature-nested-table-hwp", "tac-img-02.hwp");
    let result = read("tac-img-02.hwp");
    assert!(has_nested_table(&result), "tac-img-02.hwp: expected a table cell whose own blocks contain a nested table, found none");
    let cell_fills = cell_background_image_count(&result);
    assert!(cell_fills >= 1, "tac-img-02.hwp: expected at least 1 cell with a picture fill, found {cell_fills}");
    assert!(
        !result.images.is_empty(),
        "tac-img-02.hwp: expected OfficeReadResult.images to pre-decode at least 1 embedded picture, found none"
    );
    let inline_images = {
        let mut n = 0usize;
        walk(&result.blocks, &mut |b| {
            if matches!(b, OfficeBlock::Image { .. }) {
                n += 1;
            }
        });
        n
    };
    assert!(inline_images >= 1, "tac-img-02.hwp: expected at least 1 inline OfficeBlock::Image, found {inline_images}");
}

#[test]
fn hwpx_nested_table_and_resources_arrive() {
    assert_matches_manifest("feature-nested-table-hwpx", "tac-img-02.hwpx");
    let result = read("tac-img-02.hwpx");
    assert!(has_nested_table(&result), "tac-img-02.hwpx: expected a table cell whose own blocks contain a nested table, found none");
    let cell_fills = cell_background_image_count(&result);
    assert!(cell_fills >= 1, "tac-img-02.hwpx: expected at least 1 cell with a picture fill, found {cell_fills}");
    assert!(
        !result.images.is_empty(),
        "tac-img-02.hwpx: expected OfficeReadResult.images to pre-decode at least 1 embedded picture, found none"
    );
}

// -------------------------------------------------------------------------------------------
// picture-fill refusal (export boundary) — issue2083_hide_fill_page.hwpx
// -------------------------------------------------------------------------------------------

#[test]
fn hwpx_picture_fill_is_refused_at_the_export_boundary() {
    assert_matches_manifest("feature-picture-fill-refusal-hwpx", "issue2083_hide_fill_page.hwpx");
    let result = read("issue2083_hide_fill_page.hwpx");
    // Pin the anchor is actually present before asking whether it is refused — a document with
    // zero picture fills would trivially fail to export for an unrelated reason.
    let cell_fills = cell_background_image_count(&result);
    assert!(cell_fills >= 1, "issue2083_hide_fill_page.hwpx: expected at least 1 cell with a picture fill, found {cell_fills}");
    let verdict = assert_exportable(&result);
    assert_eq!(
        verdict,
        Err(NotExportable::CellBackgroundImage),
        "issue2083_hide_fill_page.hwpx: expected assert_exportable to refuse specifically for a cell picture fill, got {verdict:?}"
    );
}

// -------------------------------------------------------------------------------------------
// Coverage table (family x format). This test asserts nothing new — it exists so the coverage
// claim lives next to the code that proves it, not only in a return-value summary that decays.
// -------------------------------------------------------------------------------------------

#[test]
fn coverage_table_is_documented_here_not_only_in_the_return_value() {
    // | family                                  | markdown | plain-text | docx        | odt         | hwp                           | hwpx                                |
    // |------------------------------------------|----------|------------|-------------|-------------|--------------------------------|---------------------------------------|
    // | multi-column authority                    | n/a      | n/a        | NOT COVERED | NOT COVERED | feature-multi-column-hwp      | feature-multi-column-hwpx            |
    // | nested/rich tables                        | n/a      | n/a        | NOT COVERED | NOT COVERED | feature-nested-table-hwp      | feature-nested-table-hwpx            |
    // | picture-fill refusal (export boundary)    | n/a      | n/a        | NOT COVERED | NOT COVERED | NOT COVERED (see why, below)  | feature-picture-fill-refusal-hwpx    |
    // | form controls                              | n/a      | n/a        | NOT COVERED | NOT COVERED | feature-form-control-hwp      | feature-form-control-hwpx            |
    // | diagonals                                  | n/a      | n/a        | NOT COVERED | NOT COVERED | feature-diagonal-hwp          | feature-diagonal-hwpx                |
    // | annotations (reviewer comments)            | n/a      | n/a        | NOT COVERED | NOT COVERED | NOT COVERED (architectural)   | NOT COVERED (architectural)          |
    // | resources (images)                         | n/a      | n/a        | NOT COVERED | NOT COVERED | feature-nested-table-hwp      | feature-nested-table-hwpx            |
    //
    // DOCX/ODT: this repository ships no real-document corpus for either format (`Tests/Baseline/
    // fixtures.json`'s `sources` entries for `docx`/`odt` are project-authored one-paragraph
    // literals — see `office_reader_reachability.rs`'s `docx_zip_bytes`/`odt_zip_bytes`). Every
    // family above is therefore uncovered for both, not silently narrowed.
    //
    // Annotations: `HwpReader::read` (`mapping.rs`) hardcodes `OfficeReadResult.comments` to `[]`
    // for every HWP/HWPX document — reviewer-comment support does not exist in this reader yet, so
    // no fixture, however well chosen, can prove it. `field-01-memo.hwp`, the only named candidate
    // for this family, was opened and measured 0 comments, confirming the hardcode rather than
    // contradicting it.
    //
    // Picture-fill refusal on HWP: every real HWP document found in the corpus that carries a
    // picture fill (`tac-img-02.hwp`, both `2025 행정업무운영편람(최종)` files, `exam_kor.hwp`) also
    // carries a master page or an anchored object, both of which `office_export::assert_exportable`
    // checks BEFORE it reaches a cell's picture fill — so the top-level call returns
    // `Err(MasterPages)`/`Err(AnchoredObjects)` for those files, never `Err(CellBackgroundImage)`.
    // The underlying DATA fact (`Cell.background_image` present) IS proven for HWP, by
    // `hwp_nested_table_and_resources_arrive` above; only the export boundary's specific refusal
    // reason is uncovered for HWP.
}
