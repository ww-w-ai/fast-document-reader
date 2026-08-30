//! Everything under `Render/` in the Swift tree.

pub mod office;
pub mod render_theme;
pub mod md_attr;
pub mod table_block_builder;
pub mod table_resize_math;
pub mod grid_text_table_block;
pub mod markdown;
// The transliteration of `Render/MarkdownRenderer.swift`, restored from `3f659a4` — the port
// manifest lists that file and `Scripts/port-coverage.py` read it at 0/829 while this module was
// absent. `markdown` above is a DIFFERENT thing: a fresh producer written against the canonical
// tree. Both stay; the manifest is about transliterating the shipped Swift, not about replacing it.
pub mod markdown_renderer;
pub mod markdown_wire;
// The `swift-markdown` package the transliteration is a CLIENT of — not part of the port, which
// is why it is a separate file with no `swift:` claims of its own.
pub mod markdown_package;
pub mod plaintext;
pub mod plain_text_renderer;
pub mod code_highlighter;
pub mod code_card_metrics;
pub mod web_block;
pub mod render_tree;
