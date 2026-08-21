//! swift: `Foundation.XMLParser` + `XMLParserDelegate` — the SAX-style reader `OdtReader` and
//! `DocxReader` both build their trees through.
//!
//! The delegate protocol is real here because the readers' own tree building is real: the callbacks
//! carry element names, attributes and character data, and everything the readers do with them is
//! plain data handling that Rust expresses today. What is NOT here is the parse itself — driving
//! bytes to callbacks is what a real XML crate does, and which one this engine adopts is an open
//! decision (`quick-xml` / `xml-rs` / `roxmltree`; see `docs/plans/rust-phase-b-worklist.md` §1).

use std::collections::HashMap;

/// swift: `XMLParserDelegate` — the three callbacks the in-scope readers implement.
pub trait XMLParserDelegate {
    fn parser_did_start_element(
        &self,
        parser: &XMLParser,
        element_name: &str,
        namespace_uri: Option<&str>,
        qualified_name: Option<&str>,
        attribute_dict: HashMap<String, String>,
    );

    fn parser_found_characters(&self, parser: &XMLParser, string: &str);

    fn parser_did_end_element(
        &self,
        parser: &XMLParser,
        element_name: &str,
        namespace_uri: Option<&str>,
        qualified_name: Option<&str>,
    );
}

/// swift: `XMLParser`
pub struct XMLParser {
    pub shouldProcessNamespaces: bool,
}

impl XMLParser {
    /// swift: `XMLParser(data:)`
    pub fn new(_data: &[u8]) -> Self {
        Self { shouldProcessNamespaces: false }
    }

    /// swift: `XMLParser.parse()` — drives the bytes and calls the delegate.
    pub fn parse<D: XMLParserDelegate>(&self, _delegate: &D) -> bool {
        todo!("XML crate not chosen — see docs/plans/rust-phase-b-worklist.md §1")
    }
}
