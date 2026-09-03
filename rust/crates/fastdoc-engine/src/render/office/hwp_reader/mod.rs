//! swift: Render/Office/HwpReader.swift
//!
//! One Swift file, split across two Rust files only because two workers transliterated it in
//! parallel. The seam is the source's own `// MARK: - Codable model` boundary: mapping above it,
//! the rhwp JSON schema below. Nothing was moved between the halves.

pub mod mapping;
pub mod schema;

pub use mapping::*;
pub use schema::*;

// S2A2 Pass C, unit C1 — measurement only, kept out of `mapping.rs`/`schema.rs` (neither worker's
// file) as its own module. See its own doc comment for what it measures and why.
pub mod column_key_parity;
