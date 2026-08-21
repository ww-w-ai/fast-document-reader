//! swift: Render/WebBlock.swift — which engine draws a block, and the code it draws.
//!
//! The Swift file carries no drawing at all: `WebBlockRenderer.swift` does that, and stays with the
//! host (it is WebKit). What is here is vocabulary the renderer needs while BUILDING the document —
//! it places a sized placeholder per block long before any pixels exist, which is what keeps the
//! scroll bar stable while diagrams and formulas fill in lazily.

/// swift: `WebBlock.Engine`
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Engine {
    Mermaid,
    Math,
}

impl Engine {
    /// Part of the cache key, so the two engines can never collide and a bump invalidates only its
    /// own PDFs. Mermaid's stays "10": nothing about its capture has changed, and bumping would
    /// throw away every cached diagram for no reason.
    pub fn cacheVersion(self) -> &'static str {
        match self {
            Engine::Mermaid => "10",
            Engine::Math => "katex-0.17.0-2",
        }
    }
}

/// swift: `struct WebBlock`
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WebBlock {
    pub engine: Engine,
    pub code: String,
}
