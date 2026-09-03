//! swift: Render/WebBlock.swift
//! which engine draws a block, and the code it draws.
//!
//! The Swift file carries no drawing at all: `WebBlockRenderer.swift` does that, and stays with the
//! host (it is WebKit). What is here is vocabulary the renderer needs while BUILDING the document —
//! it places a sized placeholder per block long before any pixels exist, which is what keeps the
//! scroll bar stable while diagrams and formulas fill in lazily.
//!
//! WHAT IS DELIBERATELY NOT HERE: `enumerateWebBlocks` (`WebBlock.swift:31`) and the
//! `Engine.attribute` mapping it walks. `Render/WebBlock.swift` is NOT in `PORT-MANIFEST.txt` —
//! it is one of the files `CROSS-PLATFORM.md` §2 leaves with the host, and only its value half was
//! lifted across when the engine/host line was redrawn by responsibility rather than by file. Every
//! caller of that walk lives in `App/MarkdownDocument.swift`, which is host code, and the walk
//! itself iterates an `NSAttributedString` — a TextKit shape the engine hands over rather than one
//! it keeps. Porting it here would add a function with no caller on this side of the boundary.
//!
//! This paragraph exists because its absence read as an omission: a gap audit flagged
//! `enumerateWebBlocks` as MISSING, correctly observing it is nowhere in the port and that
//! `office_text_builder.rs` names it in a comment as though it existed. Both observations are
//! right; the conclusion was not, and nothing in the code said so. If the engine ever needs to walk
//! its own web blocks, port it then — and keep the property the Swift comment exists to state, that
//! ONE place knows there is more than one engine, so adding a third cannot silently skip a pass.

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
