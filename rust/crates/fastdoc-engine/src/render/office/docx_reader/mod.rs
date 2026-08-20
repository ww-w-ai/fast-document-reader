//! swift: Render/Office/DocxReader.swift
//!
//! One Swift file, split across two Rust files only because two workers transliterated it in
//! parallel. The seam is the source's own `// MARK: Images` boundary, so no declaration and no
//! declaration's doc comment is cut in half. Nothing was moved between the halves.

pub mod part_a;
pub mod part_b;

pub use part_a::*;
pub use part_b::*;
