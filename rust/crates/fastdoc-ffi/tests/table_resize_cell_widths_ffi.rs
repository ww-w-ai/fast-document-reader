//! S5B2a-02: drives `fastdoc_table_resize_cell_widths` through the real `extern "C"` symbol, not
//! the pure Rust function it wraps — this is what proves the FFI shape (flat arrays, caller-owned
//! output buffer, the `max_width <= 0.0` sentinel), which `fastdoc-engine`'s own unit tests cannot.

use fastdoc_engine_ffi::{fastdoc_table_resize_cell_widths, FastdocTableResizeCell};

fn cell(col: usize, span: usize, pad: f64, border: f64) -> FastdocTableResizeCell {
    FastdocTableResizeCell {
        starting_column: col,
        column_span: span,
        pad_left: pad,
        pad_right: pad,
        border_left: border,
        border_right: border,
    }
}

#[test]
fn three_equal_columns_split_the_available_width_through_the_c_abi() {
    let proportions = [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0];
    let cells = [cell(0, 1, 4.0, 1.0), cell(1, 1, 4.0, 1.0), cell(2, 1, 4.0, 1.0)];
    let mut out = [0.0_f64; 3];
    let ok = unsafe {
        fastdoc_table_resize_cell_widths(
            proportions.as_ptr(),
            proportions.len(),
            300.0,
            0.0,
            0.0,
            0.0, // no authored cap
            cells.as_ptr(),
            cells.len(),
            out.as_mut_ptr(),
        )
    };
    assert!(ok);
    assert_eq!(out, [90.0, 90.0, 90.0]);
}

#[test]
fn a_table_whose_proportions_do_not_sum_to_one_still_answers() {
    let proportions = [0.5, 0.6]; // sums to 1.1
    let cells = [cell(0, 1, 0.0, 0.0), cell(1, 1, 0.0, 0.0)];
    let mut out = [0.0_f64; 2];
    let ok = unsafe {
        fastdoc_table_resize_cell_widths(
            proportions.as_ptr(),
            proportions.len(),
            200.0,
            0.0,
            0.0,
            0.0,
            cells.as_ptr(),
            cells.len(),
            out.as_mut_ptr(),
        )
    };
    assert!(ok);
    assert!(out[0] > 0.0 && out[1] > 0.0, "{out:?}");
    assert!(out[0] + out[1] <= 200.0 + 0.001, "{out:?}");
}

#[test]
fn a_positive_max_width_caps_the_grid() {
    let proportions = [0.5, 0.5];
    let cells = [cell(0, 1, 0.0, 0.0), cell(1, 1, 0.0, 0.0)];
    let mut out = [0.0_f64; 2];
    let ok = unsafe {
        fastdoc_table_resize_cell_widths(
            proportions.as_ptr(),
            proportions.len(),
            500.0,
            0.0,
            0.0,
            200.0, // authored cap
            cells.as_ptr(),
            cells.len(),
            out.as_mut_ptr(),
        )
    };
    assert!(ok);
    assert_eq!(out, [100.0, 100.0]);
}

#[test]
fn a_merged_cell_spans_more_than_one_column_through_the_c_abi() {
    let proportions = [0.25, 0.25, 0.25, 0.25];
    let cells = [cell(0, 2, 2.0, 0.0), cell(2, 1, 2.0, 0.0), cell(3, 1, 2.0, 0.0)];
    let mut out = [0.0_f64; 3];
    let ok = unsafe {
        fastdoc_table_resize_cell_widths(
            proportions.as_ptr(),
            proportions.len(),
            400.0,
            0.0,
            0.0,
            0.0,
            cells.as_ptr(),
            cells.len(),
            out.as_mut_ptr(),
        )
    };
    assert!(ok);
    assert_eq!(out[0], 196.0);
    assert_eq!(out[1], 96.0);
    assert_eq!(out[2], 96.0);
}

#[test]
fn zero_cells_is_not_a_null_pointer_error() {
    let proportions = [1.0_f64];
    let ok = unsafe {
        fastdoc_table_resize_cell_widths(
            proportions.as_ptr(),
            proportions.len(),
            100.0,
            0.0,
            0.0,
            0.0,
            std::ptr::null(),
            0,
            std::ptr::null_mut(),
        )
    };
    assert!(ok, "an empty cell list is a valid, if useless, call");
}
