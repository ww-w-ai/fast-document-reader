//! rhwp's font-metric table must stay reachable as a plain Rust dependency.
//!
//! We link rhwp as an rlib, not through the C FFI the Swift reader uses, so the whole
//! `pub` surface is available by path and no fork edit is needed to read the metrics. That is
//! worth a standing test rather than a note: the scouting pass concluded the opposite (that using
//! these metrics meant adding FFI exports to our fork and carrying that maintenance), because it
//! was reading `rhwp_native_ffi.h`. If a future rhwp bump narrows this module's visibility, the
//! cost lands back on the fork — so this test fails at the bump rather than at the redesign.

#[test]
fn the_metric_table_is_reachable_and_reports_absence_honestly() {
    use rhwp::renderer::font_metrics_data::find_metric;

    assert!(
        find_metric("Arial", false, false).is_some(),
        "Arial is one of the 595 faces the table carries"
    );

    // An off-table face must come back as None. rhwp's own CALLERS fall to a numeric guess
    // (CJK 1.0em, narrow punctuation 0.3em) when they get None — that guess is theirs, made for a
    // renderer with no OS to ask. We take the table and decide the miss policy ourselves, so the
    // distinction between "this face measures thus" and "nobody knows this face" must survive.
    assert!(
        find_metric("NoSuchFaceXYZ", false, false).is_none(),
        "an unknown face must report absence, never a guess"
    );
}
