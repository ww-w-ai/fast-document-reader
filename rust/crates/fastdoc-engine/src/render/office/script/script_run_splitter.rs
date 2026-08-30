//! swift: Render/Office/Script/ScriptRunSplitter.swift
//! swift-range: 1-49
//!
//! Cuts one run of text into the fewest pieces that each want a different typeface, so a reader can
//! draw every character in the family the DOCUMENT chose for that character's writing system.
//!
//! Every office format declares several font slots per run — Word 4 (`w:ascii`/`w:hAnsi`/`w:eastAsia`/
//! `w:cs`), ODF 3, HWP 7 — and picks between them per character. This reader used to collapse each
//! run to the single family the document named for LATIN text, so a Korean paragraph's Hangul was
//! drawn in the face chosen for its English words, or the reverse; whichever way round it landed, one
//! of the two was wrong. This splitter is the shared half of the fix. The per-format halves — which
//! slots exist, how they cascade, and which slot a given character selects — stay in each reader,
//! because the three formats genuinely disagree and merging them would silently mis-render one.
//!
//! ## Pieces break where the resolved FAMILY changes, never where the slot changes
//!
//! This is the load-bearing choice, and it is what makes invariant 37 — "a document that declared
//! nothing renders byte-identically" — hold structurally rather than by argument:
//!
//! - A document that points several slots at the same face, which is the common case, yields exactly
//!   ONE piece: the original run, unchanged, no coverage test needed to believe it.
//! - A document that declares no family at all yields one piece whose family is `nil`. Unchanged.
//! - Fragmentation is therefore paid only where the document genuinely asked for two typefaces.
//!
//! Breaking on the slot INDEX instead would split `제1항`, `2026년` and `(3)` at every alternation
//! even when both slots name the same family — a digit is not neutral to Word, its own block table
//! sends ASCII to the Latin slot — and run count is ~93% of the build stage. Per-character
//! alternation has already been measured on this codebase at build 625 ms → 5.8 s and display
//! 1.5 s → 34 s. Do not re-derive that.
//!
//! ## Absorption belongs to the classifier, not to this type
//!
//! `classify` returning `nil` means "this scalar joins the run in progress and can never start a new
//! one". It is the classifier's call rather than a rule baked in here because the three formats
//! disagree about what is neutral: Word's block table slots ASCII digits and punctuation to a real
//! slot, while ODF names 22 unmapped gap ranges whose treatment it leaves to the consumer. What they
//! cannot disagree about is the floor — `ScriptClass.isAbsorbing` — since a mark that extends a
//! grapheme cluster must never begin a piece, or a boundary lands inside a cluster.
//!
//! ## Scalars, not characters
//!
//! Iterating `String.unicodeScalars` was measured at 2.78 ms per 250k against 7.61 ms for `Character`
//! iteration, with byte-identical output on a 250k corpus and on 13 hand-built trap cases (combining
//! marks, a Cyrillic titlo on a Latin base, VS16, a regional-indicator pair, a ZWJ family, an astral
//! pair, a skin-tone modifier, a danda, Arabic mixed with Latin, a kana voiced mark, a Thai vowel
//! above, Hebrew points). Grapheme segmentation buys nothing that absorption does not already give,
//! because every scalar that can extend a cluster is Common, Inherited or Grapheme_Extend and none of
//! those may start a piece. Piece boundaries are `String.Index` values taken straight from that walk,
//! so a boundary cannot land inside a surrogate pair by construction — this pass deliberately does
//! NOT inherit `FontSubstitutionResolver.resolveOne`'s hand-written lead/trail-surrogate guard, which
//! exists only because that function walks a raw `[UniChar]` buffer.

// swift: ScriptRunSplitter
pub struct ScriptRunSplitter;

// swift: ScriptRunSplitter.Piece
/// One stretch of the input that wants one typeface.
///
/// `text` is a `Substring`, so slicing costs nothing and the pieces of an unsplit run share the
/// original storage; a caller building a new `Span` from one says `String(piece.text)` at that
/// point. `family` is the name the document resolved for this stretch, or `nil` for "the document
/// said nothing here" — which is not a failure but the ordinary case, and means the same thing it
/// has always meant: draw it in the theme's own body font.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Piece<'a> {
    pub text: &'a str,
    pub family: Option<String>,
}

impl ScriptRunSplitter {
    /// Splits `text` into pieces that each resolve to one family.
    ///
    /// - Parameters:
    ///   - text: the run's text. An empty string yields no pieces.
    ///   - classify: which font slot this scalar selects, or `nil` to absorb it into the run in
    ///     progress. Called once per scalar.
    ///   - family: the family name that slot resolves to in THIS document, or `nil` if the document
    ///     named none. Must be a pure function of its slot — the result is memoised for as long as
    ///     consecutive scalars keep choosing the same slot, which on real text is nearly always, and
    ///     which is what keeps a per-scalar dictionary lookup out of the loop. `Slot: Equatable` buys
    ///     exactly that memo and nothing else.
    ///
    /// - Returns: pieces in order. No piece is ever empty, and concatenating their `text` reproduces
    ///   `text` exactly — both asserted in `ScriptRunSplitterTests`, on every case it has.
    // swift: ScriptRunSplitter.split
    pub fn split<'a, Slot, ClassifyFn, FamilyFn>(
        text: &'a str,
        mut classify: ClassifyFn,
        mut family: FamilyFn,
    ) -> Vec<Piece<'a>>
    where
        Slot: PartialEq + Clone,
        ClassifyFn: FnMut(char) -> Option<Slot>,
        FamilyFn: FnMut(Slot) -> Option<String>,
    {
        // swift: ScriptRunSplitter.split
        let mut pieces: Vec<Piece<'a>> = Vec::new();
        // Byte offsets into `text`, standing in for Swift's `String.Index` — a boundary is always
        // taken at a scalar (char) boundary, so it can never land inside a multi-byte encoding.
        let mut piece_start: usize = 0;

        // `resolved` is the family of the piece being built. `is_resolved` is separate from it being
        // non-nil because "we have not decided this piece's family yet" has to be distinguishable
        // from "we decided, and the answer is no family" — until the first deciding scalar arrives,
        // scalars accumulate into a piece whose family is still undecided, which is how a run that
        // opens with a space or an opening bracket hands that punctuation to the first real piece
        // instead of stranding it in one of its own.
        //
        // **A scalar whose slot resolves to NO FAMILY decides nothing and breaks nothing.** This is
        // the correction three independent reviews arrived at from three different directions, all
        // measuring the same defect: `nil` was being compared as though it were a family name, so a
        // slot the document never declared read as "a different typeface" and reintroduced, through
        // the back door, exactly the break-on-the-SLOT behaviour this splitter exists to avoid
        // (`docs/per-script-font-design.md` §1). Measured through the real dispatch, before this
        // line: an .odt whose style declares only the western slot turned a 167-character Korean
        // paragraph from 2 spans into 50 — 제1항 became 제 / 1 / 항, character by character, because
        // the undeclared East-Asian slot kept "disagreeing" with the declared Latin one; a .docx
        // whose runs carry `w:asciiTheme="minorEastAsia"` (2,422 of them in one real corpus file)
        // split every sentence in two and left the Latin half with no family at all, 1,189 spans
        // becoming 2,186.
        //
        // Treating it as absorbing is not merely cheaper, it is what the document MEANS: a slot it
        // never declared carries no opinion about this text, so the text belongs to whatever family
        // its neighbours established. That also makes the invariant-37 guarantee stronger than it
        // was — a document declaring exactly ONE slot now yields exactly one piece, i.e. byte for
        // byte what it rendered before per-slot fonts existed, and the proof is structural rather
        // than a fixture that happens to agree.
        let mut resolved: Option<String> = None;
        let mut is_resolved = false;
        let mut memo_slot: Option<Slot> = None;
        let mut memo_family: Option<String> = None;

        for (index, ch) in text.char_indices() {
            if let Some(slot) = classify(ch) {
                let candidate: Option<String>;
                if let Some(m) = &memo_slot {
                    if *m == slot {
                        candidate = memo_family.clone();
                    } else {
                        let c = family(slot.clone());
                        memo_slot = Some(slot);
                        memo_family = c.clone();
                        candidate = c;
                    }
                } else {
                    let c = family(slot.clone());
                    memo_slot = Some(slot);
                    memo_family = c.clone();
                    candidate = c;
                }
                if let Some(candidate) = candidate {
                    if !is_resolved {
                        resolved = Some(candidate);
                        is_resolved = true;
                    } else if Some(&candidate) != resolved.as_ref() {
                        pieces.push(Piece { text: &text[piece_start..index], family: resolved.clone() });
                        piece_start = index;
                        resolved = Some(candidate);
                    }
                }
            }
        }

        // The tail, including the case where nothing classified at all: a run of pure punctuation is
        // one piece with no family, not zero pieces and not a dropped tail.
        if piece_start < text.len() {
            pieces.push(Piece { text: &text[piece_start..text.len()], family: resolved });
        }
        pieces
    }
}
