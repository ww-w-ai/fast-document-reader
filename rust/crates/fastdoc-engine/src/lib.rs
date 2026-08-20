//! The document engine: parse, then lay out, then hand a finished box tree across the FFI.
//!
//! Every module here is a line-for-line transliteration of one Swift file, carrying provenance
//! comments that `Scripts/port-coverage.py` reads. See docs/plans/rust-port-convention.md.

pub mod render;
