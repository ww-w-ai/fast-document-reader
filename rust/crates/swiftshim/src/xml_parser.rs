//! swift: `Foundation.XMLParser` + `XMLParserDelegate` — the SAX-style reader `OdtReader` and
//! `DocxReader` both build their trees through.
//!
//! The delegate protocol mirrors Foundation's. The byte driving underneath it is `quick-xml`, a
//! pull parser, so one event out of it becomes one delegate callback and neither reader's
//! transliterated callbacks had to change shape.
//!
//! `drive` is deliberately the ONLY place in this workspace that turns XML bytes into callbacks.
//! `DocxReader`'s tree builder is a plain `&mut self` struct and `OdtReader`'s is an interior-
//! mutability delegate, so they cannot share an adapter — but if they each carried their own
//! driving loop, the two readers would sooner or later disagree about what an entity, a CDATA
//! section or a self-closing tag means, and a document would parse differently depending on which
//! reader opened it. They share this function instead, and only the adapter differs.

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

/// Drives XML bytes and reports each event, exactly as `XMLParser` reports them to a delegate.
///
/// The element name handed out is the QUALIFIED one (`w:p`, not `p`), because both readers run
/// with `shouldProcessNamespaces == false` and match on prefixed names throughout. Namespace
/// resolution here would rename every element the readers look for.
///
/// Returns whether the document parsed to its end, which is what `XMLParser.parse()` returns.
pub fn drive(
    data: &[u8],
    on_start: &mut dyn FnMut(&str, HashMap<String, String>),
    on_characters: &mut dyn FnMut(&str),
    on_end: &mut dyn FnMut(&str),
) -> bool {
    use quick_xml::events::Event;

    let mut reader = quick_xml::Reader::from_reader(data);
    // Foundation reports whitespace-only runs as character data, and Word leans on that: the
    // space between two runs inside `<w:t xml:space="preserve">` IS the document's text. Trimming
    // here would silently join words.
    reader.config_mut().trim_text(false);
    // A document that names an entity we do not know is a document we still want to read as far
    // as it goes, which is also how Foundation behaves — it reports the error and stops, rather
    // than refusing the prefix it already parsed.
    reader.config_mut().check_end_names = false;

    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let name = qualified_name(e.name().as_ref());
                on_start(&name, attributes_of(&e));
            }
            Ok(Event::End(e)) => {
                let name = qualified_name(e.name().as_ref());
                on_end(&name);
            }
            // `<w:b/>` — one event here, two callbacks, because Foundation reports an empty
            // element as a start immediately followed by an end. A reader that only saw the start
            // would leave the element open and adopt every following sibling as its child.
            Ok(Event::Empty(e)) => {
                let name = qualified_name(e.name().as_ref());
                on_start(&name, attributes_of(&e));
                on_end(&name);
            }
            Ok(Event::Text(e)) => match e.unescape() {
                Ok(text) => on_characters(&text),
                Err(_) => return false,
            },
            // CDATA reaches a Foundation delegate through the SAME callback as ordinary text, and
            // its content is literal — unescaping it would corrupt any `&` it deliberately holds.
            Ok(Event::CData(e)) => {
                on_characters(&String::from_utf8_lossy(e.as_ref()));
            }
            Ok(Event::Eof) => return true,
            Ok(_) => {}
            Err(_) => return false,
        }
        buf.clear();
    }
}

fn qualified_name(raw: &[u8]) -> String {
    String::from_utf8_lossy(raw).into_owned()
}

fn attributes_of(e: &quick_xml::events::BytesStart<'_>) -> HashMap<String, String> {
    let mut dict = HashMap::new();
    // Lenient on purpose: a duplicate or unquoted attribute should cost that ONE attribute, not
    // the whole document. Foundation is equally forgiving here, and real `.docx` files in the
    // corpus do carry oddities that a checking parser rejects outright.
    for attribute in e.attributes().with_checks(false).flatten() {
        let key = String::from_utf8_lossy(attribute.key.as_ref()).into_owned();
        let value = match attribute.unescape_value() {
            Ok(v) => v.into_owned(),
            Err(_) => continue,
        };
        dict.insert(key, value);
    }
    dict
}

/// swift: `XMLParser`
pub struct XMLParser {
    pub shouldProcessNamespaces: bool,
    data: Vec<u8>,
}

impl XMLParser {
    /// swift: `XMLParser(data:)`
    pub fn new(data: &[u8]) -> Self {
        Self { shouldProcessNamespaces: false, data: data.to_vec() }
    }

    /// swift: `XMLParser.parse()` — drives the bytes and calls the delegate.
    pub fn parse<D: XMLParserDelegate>(&self, delegate: &D) -> bool {
        drive(
            &self.data,
            &mut |name, attributes| {
                delegate.parser_did_start_element(self, name, None, None, attributes)
            },
            &mut |text| delegate.parser_found_characters(self, text),
            &mut |name| delegate.parser_did_end_element(self, name, None, None),
        )
    }
}
