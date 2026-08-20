//! swift: Render/Office/OdfScriptType.swift
//! swift-range: 1-8
//!
//! The three script types ODF names, and the normative code-point table that decides which one a
//! character belongs to.
//!
//! A `<style:text-properties>` states the family three times over — `style:font-name` /
//! `style:font-name-asian` / `style:font-name-complex`, each with a `fo:`/`style:font-family*`
//! direct twin — and every one of those attributes is defined as "evaluated for any [UNICODE]
//! character whose script type is latin / asian / complex" (ODF 1.3 Part 3 §20.277-§20.279). This
//! type is that script type, and `OdfScriptTable` is the mapping.

// swift: Render/Office/OdfScriptType.swift:9-14
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum OdfScriptType {
    Latin,
    Asian,
    Complex,
}

impl OdfScriptType {
    /// All cases, mirroring Swift's `CaseIterable` conformance.
    // swift: Render/Office/OdfScriptType.swift:9
    pub const ALL: [OdfScriptType; 3] = [OdfScriptType::Latin, OdfScriptType::Asian, OdfScriptType::Complex];
}

// swift: Render/Office/OdfScriptType.swift:15-66
/// ODF 1.3 Part 3 §20.358 table 22, transcribed verbatim, plus the ruling this reader makes about
/// the code points the table deliberately leaves out.
///
/// ## The table is normative, and it names no language
///
/// This corrects an assumption carried on this project for a while — that ODF left the per-character
/// choice to the consumer. It does not. §20.358, verbatim:
///
/// > The mapping of Unicode code points to script types is defined by table 22. Consumers should
/// > apply this mapping. For Unicode code points for which no mapping is defined, the mapping is
/// > implementation-dependent.
///
/// The ranges below are that table, in the spec's own order within each script type, and they are
/// byte-identical in ODF 1.2 Part 1 and ODF 1.3 Part 3 (both downloaded and compared rather than
/// remembered). Being a code-point table rather than a language rule is what makes it usable here at
/// all: nothing in this file names a human language, a locale or a country.
///
/// ## The 22 gaps are the design decision, not an edge case
///
/// The table maps 92,879 code points and leaves 22 ranges unmapped — and they are not obscure ones.
/// `U+0020` SPACE is unmapped. So is `U+00A0`, the whole of General Punctuation `U+2000..U+2C5F`
/// (curly quotes, en dash, bullet), the private use areas, and everything from `U+FFF0` up, which is
/// where the emoji live. `OdfScriptTable::slot(for:)` returns `None` for all of them, which
/// `ScriptRunSplitter` reads as "absorb into the run in progress, never start a new one" — the WEAK
/// class in the vocabulary LibreOffice uses, and LibreOffice is the producer of every `.odt` fixture
/// this repo has. Without that ruling a single space between two Korean words would end one run and
/// begin another, and the fragmentation this whole design is built to avoid would arrive through the
/// most common character in the document.
///
/// ## What is deliberately NOT weak: ASCII digits and punctuation
///
/// Table 22 maps `U+0021..U+009F` to **latin**, so a digit and a full stop select the latin slot and
/// really can end a run of Hangul. Treating them as weak instead — which is what LibreOffice does,
/// since ICU calls them `COMMON` and LibreOffice sends `COMMON` to its WEAK class — was considered
/// and rejected: the spec maps them explicitly, "should apply this mapping" is about the mapped
/// ranges, and the consumer's freedom it grants is scoped to the ranges where no mapping is defined.
/// The cost of following the spec here is bounded by the design's load-bearing rule that a piece
/// breaks where the resolved FAMILY changes and not where the slot changes: `제1항` fragments only in
/// a document that genuinely asked for two different typefaces, and is one untouched piece in every
/// document that points both slots at one face.
///
/// ## Two floors win over the table: cluster-extending marks, and control characters
///
/// A combining mark that Table 22 maps — `U+0300..U+036F` falls inside the latin range, `U+064B`
/// inside the complex one — must still never START a piece, or a boundary lands inside a grapheme
/// cluster. `slot(for:)` therefore consults `ScriptClass` first and absorbs anything the UCD marks
/// `Grapheme_Extend` or `Script=Inherited`, whatever range it sits in. That is the shared floor
/// `UnicodeScript` documents, and the table cannot answer it: the table is about which typeface a
/// character wants and says nothing about where a cluster may be cut. The second floor is the
/// control characters, for the reason given at `slot(for:)` itself — they are not drawn, so they
/// cannot want a typeface, and letting one end a run costs a boundary that buys nothing.
pub struct OdfScriptTable;

impl OdfScriptTable {
    /// One row of table 22, as the spec writes it: an inclusive range and the script type it maps to.
    // swift: Render/Office/OdfScriptType.swift:67-73
    #[derive(Clone, Copy)]

    /// Table 22 itself — every range the spec lists, sorted by `first` so the lookup can binary
    /// search. Kept as the spec's 28 separate ranges rather than merged into the 26 they collapse to
    /// (`U+2C60..U+2C7F` and `U+2C80..U+2CE3` are adjacent and both latin; `U+2E80..U+31BF` and
    /// `U+31C0..U+31EF` are adjacent and both asian): a row here should be findable, verbatim, in the
    /// published table, and two fewer probes in a five-probe search buys nothing worth losing that
    /// against. `OdtFontSlotTests` re-derives the mapped total (92,879) and the gap count (22)
    /// from this array, so a mistyped bound fails rather than silently re-labelling a script.
    // swift: Render/Office/OdfScriptType.swift:74-111
    fn rows() -> &'static [Row] {
        use OdfScriptType::*;
        &[
            Row { first: 0x0003, last: 0x001F, r#type: Latin },
            Row { first: 0x0021, last: 0x009F, r#type: Latin },
            Row { first: 0x00A1, last: 0x04FF, r#type: Latin },
            Row { first: 0x0530, last: 0x058F, r#type: Latin },
            Row { first: 0x0590, last: 0x074F, r#type: Complex },
            Row { first: 0x0780, last: 0x07BF, r#type: Complex },
            Row { first: 0x0900, last: 0x109F, r#type: Complex },
            Row { first: 0x10A0, last: 0x10FF, r#type: Latin },
            Row { first: 0x1100, last: 0x11FF, r#type: Asian },
            Row { first: 0x1200, last: 0x137F, r#type: Complex },
            Row { first: 0x13A0, last: 0x16FF, r#type: Latin },
            Row { first: 0x1780, last: 0x18AF, r#type: Complex },
            Row { first: 0x1E00, last: 0x1FFF, r#type: Latin },
            Row { first: 0x2C60, last: 0x2C7F, r#type: Latin },
            Row { first: 0x2C80, last: 0x2CE3, r#type: Latin },
            Row { first: 0x2E80, last: 0x31BF, r#type: Asian },
            Row { first: 0x31C0, last: 0x31EF, r#type: Asian },
            Row { first: 0x3200, last: 0x4DBF, r#type: Asian },
            Row { first: 0x4E00, last: 0xA4CF, r#type: Asian },
            Row { first: 0xA720, last: 0xA7FF, r#type: Latin },
            Row { first: 0xAC00, last: 0xD7AF, r#type: Asian },
            Row { first: 0xF900, last: 0xFAFF, r#type: Asian },
            Row { first: 0xFB50, last: 0xFDFF, r#type: Complex },
            Row { first: 0xFE30, last: 0xFE4F, r#type: Asian },
            Row { first: 0xFE70, last: 0xFEFF, r#type: Complex },
            Row { first: 0xFF00, last: 0xFFEF, r#type: Asian },
            Row { first: 0x20000, last: 0x2A6DF, r#type: Asian },
            Row { first: 0x2F800, last: 0x2FA1F, r#type: Asian },
        ]
    }

    /// Which of the three slots this scalar selects, or `None` for "absorb me" — either because table
    /// 22 declares no mapping for it, or because it is a mark that may not begin a grapheme cluster.
    ///
    /// `#[inline(always)]` for the same reason `UnicodeScript::of` is: the caller is a per-scalar walk
    /// over a whole document, and on real text the ASCII branch is nearly all of it.
    // swift: Render/Office/OdfScriptType.swift:112-147
    #[inline(always)]
    pub fn slot(scalar: char) -> Option<OdfScriptType> {
        let value = scalar as u32;
        // The control characters — general category `Cc`, which is `U+0000..U+001F`, `U+007F` and
        // `U+0080..U+009F`, a membership Unicode fixed permanently and will not extend. Table 22
        // maps most of them to latin (`U+0003..U+001F` is a row of its own, and `U+0021..U+009F`
        // swallows `U+007F..U+009F`) because those rows are written as "the rest of ASCII", not
        // because a control wants a typeface. Nothing here is drawn: a tab's width comes from the
        // paragraph's own tab stops and a line break's from the line. Letting one select a slot puts
        // a boundary in the middle of a sentence that no reader can see and nothing in the document
        // asked for — measured on a `text:tab` between two Korean words under a two-family style, 3
        // spans where 1 is right, with the tab recorded as wanting the Latin face.
        //
        // This is the ONE ruling that departs from the published table rather than filling a gap it
        // left, and it is recorded here rather than left quiet. It changes nothing that is drawn; it
        // only stops an undrawable character from ending a run.
        if value <= 0x1F || (value >= 0x7F && value <= 0x9F) {
            return None;
        }
        // The rest of ASCII, answered without touching either table: table 22 gives `U+0021..U+007E`
        // to latin and leaves `U+0020` SPACE unmapped, and no scalar below `U+0080` is
        // `Grapheme_Extend` or `Script=Inherited`, so the cluster floor cannot change an answer here
        // — which is what lets the branch be one comparison instead of a 128-entry table like
        // `UnicodeScript`'s.
        if value < 0x80 {
            return if value == 0x20 { None } else { Some(OdfScriptType::Latin) };
        }
        // The cluster floor, ahead of the table on purpose — see this type's own doc.
        // Cross-file dependency: Render/Office/Script/UnicodeScript.swift is not one of this
        // sprint's five files. Referenced by its phase-A path pending that file's own port.
        match crate::render::office::script::unicode_script::UnicodeScript::of(scalar) {
            crate::render::office::script::unicode_script::ScriptClass::Extend
            | crate::render::office::script::unicode_script::ScriptClass::Inherited => return None,
            _ => {}
        }
        Self::mapped_type(value)
    }

    /// "Last row whose `first` is <= value", then the `last` bound checked — the table is sorted and
    /// non-overlapping (asserted in tests) but NOT gapless, so unlike `UnicodeScript::search` this one
    /// genuinely has a "no mapping" answer to return, which is the whole point of §20.358's second
    /// sentence.
    // swift: Render/Office/OdfScriptType.swift:148-163
    fn mapped_type(value: u32) -> Option<OdfScriptType> {
        let rows = Self::rows();
        let mut low: usize = 0;
        let mut high: usize = rows.len() - 1;
        if rows[low].first > value {
            return None;
        }
        while low < high {
            let mid = (low + high + 1) >> 1;
            if rows[mid].first <= value {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        let row = rows[low];
        if value <= row.last { Some(row.r#type) } else { None }
    }

    /// The table itself, for the tests that re-derive its published totals from it. Exposed rather
    /// than duplicated in the test file: a second transcription would agree with the first only until
    /// someone edited one of them.
    // swift: Render/Office/OdfScriptType.swift:164-170
    pub fn published_ranges() -> Vec<(u32, u32, OdfScriptType)> {
        Self::rows().iter().map(|r| (r.first, r.last, r.r#type)).collect()
    }
}

struct Row {
    first: u32,
    last: u32,
    r#type: OdfScriptType,
}

struct Row {
    first: u32,
    last: u32,
    r#type: OdfScriptType,
}
