//! swift: Render/Office/HwpReader.swift
//! swift-range: 1767-1768
//!
//! One Swift file, split across two Rust files only because two workers transliterated it in
//! parallel. The seam is the source's own `// MARK: - Codable model` boundary: mapping above it,
//! the rhwp JSON schema below. Nothing was moved between the halves.

pub mod mapping;
pub mod schema;

pub use mapping::*;
pub use schema::*;
