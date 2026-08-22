import AppKit

/// What KIND of face a declared family name asks for, when this machine cannot supply the family
/// itself. Format-neutral on purpose: a `.docx` naming `HY중고딕` and a `.hwp` naming it are the same
/// problem, and all three office readers share one substitution pass.
///
/// **Why a name is evidence at all.** A Korean family name is a compound — a vendor prefix (`HY`,
/// `한양`, `함초롬`, `휴먼`, `KoPub`, `Haansoft`, `HCR`) and a weight suffix (`견`, `태`, `중`, `세`,
/// `Bold`, `Light`, `M`) wrapped around a ROOT that states the kind. 명조 is serif and 고딕 is sans;
/// that is what the words mean, not an inference this reader is making. Matching the root as a
/// SUBSTRING is what lets one short table cover `HY중고딕`, `한양중고딕`, `맑은 고딕` and `함초롬돋움`
/// without any of them being written down.
///
/// **Reach, measured** over 2,267 real documents (2,287,032 unresolvable font slots, 265 distinct
/// unresolved families — `docs/06-research/2026-08-18-font-dump-full.md`): the roots classify **61.5%
/// of the NAMES but 97.6% of the SLOTS**. The residue is display and handwriting faces, and it stays
/// `unclassified` deliberately — `헤드라인` says what a face is FOR, not whether it has serifs, so
/// guessing one would be this app contributing judgment the document never gave.
///
/// The tables below were built by running this classifier against those real 265 names and reading
/// what fell out, never assumed ahead of the data. Two rounds of that produced the two least obvious
/// entries, and both are recorded where they live: the romanised Korean roots, and the vendor-prefix
/// rule that keeps a Latin-SPELLED Korean face from being called a Western one.
enum DeclaredFontKind: Equatable {
    case serif
    case sans
    case mono
    case symbol
    /// A genuinely Western/foreign name: no Hangul, no known root, no Korean vendor prefix.
    case latin
    /// Korean by script or by vendor, with no root this table knows. Not a failure — a face whose
    /// name does not state a kind, which is a different fact from one whose kind we failed to read.
    case unclassified

    /// The family this reader may ask for when a declaration of this kind cannot be resolved, or
    /// `nil` when there is nothing honest to offer and the existing cascade should answer.
    ///
    /// These three are what a fresh macOS actually ships for Korean. **Naming a family here does not
    /// depend on it**: the caller puts every candidate through the same coverage test it uses today,
    /// so a face that is absent — or that cannot draw this document's characters — simply loses.
    ///
    /// **The spelling is not stylistic — `NSFont(name:)` rejects the wrong form and returns nil.**
    /// Apple is not consistent across these three: the Korean sans family is `Apple SD Gothic Neo`
    /// WITH spaces (its PostScript face is `AppleSDGothicNeo-Regular`), while `AppleMyungjo` and
    /// `AppleGothic` take no spaces at all. Getting one wrong does not fail loudly — the candidate
    /// simply never resolves, the chain falls through to the cascade, and the whole feature quietly
    /// does nothing while looking correct. `DeclaredFontKindTests` asserts each one resolves.
    var systemFamily: String? {
        switch self {
        case .serif: return "AppleMyungjo"
        case .sans: return "Apple SD Gothic Neo"
        case .mono: return "Menlo"
        // A symbol font's glyphs are its whole point; substituting a text face for one draws the
        // wrong characters rather than the right characters in the wrong style.
        case .symbol: return nil
        // Latin names are handled by `equivalentFamily(for:)` instead — an equivalence, not a kind.
        case .latin, .unclassified: return nil
        }
    }
}

extension DeclaredFontKind {
    // Order matters: the first table that matches wins, and mono/symbol are checked first because
    // "고정폭 고딕" is a monospace face that also carries a sans root.
    private static let monoRoots = ["고정폭", "타자기", "Mono", "Console", "Consolas", "Courier", "Typewriter"]
    private static let symbolRoots = ["Wingding", "Webding", "Marlett", "Symbol", "Dingbat", "기호"]
    /// The Korean sans roots AND their romanisations — `Haansoft Batang` and `HCR Dotum` name Korean
    /// faces in Latin letters only, so a Hangul-only table misses them.
    private static let sansRoots = ["고딕", "돋움", "굴림", "Gothic", "Dotum", "Gulim", "Sans"]
    /// `Myungjo` and `Gungsuh` are second romanisations, found by running this against the real 265
    /// and seeing them stuck in `.latin` — which is a WRONG fact, not merely a missing one.
    private static let serifRoots = ["명조", "바탕", "궁서", "옛체", "Myeongjo", "Myungjo", "Batang",
                                "Gungseo", "Gungsuh", "Serif", "Ming"]
    /// A name written only in Latin letters is not automatically a Western font. `HYHeadLine-Medium`
    /// and `HYhaeseo` are 한양시스템 faces whose roots (헤드라인 / 해서) are not in the tables above,
    /// and without this check they landed in `.latin` beside `Palatino Linotype` — a Korean face
    /// classified as Western, which would then be offered a Latin equivalent that cannot draw Hangul.
    /// Anchored at the START, because `HY` and `HCI` are short enough to occur inside an unrelated
    /// word by accident.
    private static let koreanVendorPrefixes = ["HY", "HCI"]

    /// Western families this reader can name an EQUIVALENT for — the same typeface shipping under a
    /// different name, not a guess about its style. `Palatino Linotype` is Palatino; that is an
    /// identity, and it is the only reason this table is allowed to exist at all.
    ///
    /// It is deliberately tiny. `Times New Roman` and `Arial` are absent because they RESOLVE on
    /// macOS already (as `TimesNewRomanPSMT` and `ArialMT`), so they never reach this code — verified
    /// with `NSFont(name:)`, not assumed.
    private static let latinEquivalents = [
        "palatino linotype": "Palatino",
        "book antiqua": "Palatino",
    ]

    static func containsHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0xAC00...0xD7A3).contains($0.value) ||   // syllables
            (0x1100...0x11FF).contains($0.value) ||   // jamo
            (0x3130...0x318F).contains($0.value)      // compatibility jamo
        }
    }

    /// The kind a declared family name states, and the substring that decided it. The morpheme is
    /// returned so a probe can report WHY a name classified the way it did — a classification whose
    /// reason cannot be printed is one nobody can check.
    static func classify(_ name: String) -> (kind: DeclaredFontKind, morpheme: String) {
        for m in monoRoots where name.localizedCaseInsensitiveContains(m) { return (.mono, m) }
        for m in symbolRoots where name.localizedCaseInsensitiveContains(m) { return (.symbol, m) }
        for m in sansRoots where name.localizedCaseInsensitiveContains(m) { return (.sans, m) }
        for m in serifRoots where name.localizedCaseInsensitiveContains(m) { return (.serif, m) }
        if containsHangul(name) { return (.unclassified, "none") }
        for p in koreanVendorPrefixes where name.hasPrefix(p) { return (.unclassified, "vendor:\(p)") }
        return (.latin, "no-hangul")
    }

    /// A same-typeface substitute for a Western family, or `nil`. Separate from `classify` because it
    /// answers a different question: not "what kind is this" but "is this face this machine's face
    /// under another name".
    static func equivalentFamily(for name: String) -> String? {
        latinEquivalents[name.lowercased()]
    }

    /// The family to try for a declaration this machine cannot resolve, or `nil` to leave the
    /// existing cascade to answer. The caller must still verify coverage; this only proposes.
    static func fallbackFamily(for name: String) -> String? {
        if let equivalent = equivalentFamily(for: name) { return equivalent }
        return classify(name).kind.systemFamily
    }
}

/// What a DOCUMENT said about one entry in its own font table, in format-neutral terms.
///
/// Every office format keeps such a table and every one of them says more about a face than its name:
/// HWP's `HWPTAG_FACE_NAME` carries a nominated substitute, an embed flag and a ten-byte type-info
/// block; `.docx` and `.odt` have their own equivalents. This type is what the substitution pass reads,
/// so that pass never learns which format it is serving.
struct DeclaredFace: Equatable {
    /// The face the DOCUMENT ITSELF nominates when its first choice is unavailable. Measured on 1,589
    /// real HWP documents: 9,084 faces nominate one and **none of them resolves** on a machine without
    /// Hancom Office (invariant 95). It is tried first anyway, because a substitute the document chose
    /// outranks one this reader inferred, and on a machine that HAS those fonts it fires.
    var nominatedSubstitute: String?
    /// The document carries the face's own bytes. Two documents in 1,589 do.
    var isEmbedded: Bool = false
    /// The ten-byte type-info block HWP's font table carries (PANOSE): byte 0 is family kind — text,
    /// hand-written, decorative, symbol — and byte 1 is serif style. When a document fills this in, the
    /// KIND of a face is something it STATED rather than something this reader inferred from the name,
    /// and the stated answer wins. `nil` means the document said nothing, which is not the same as a
    /// block of zeroes (PANOSE zero means "any", a real declaration).
    var typeInfo: [UInt8]?

    /// What kind the document's own font table states — **deliberately not read, and this is the
    /// finding rather than an omission.**
    ///
    /// The ten-byte block looked like the best evidence in this whole design: a kind the DOCUMENT
    /// declared, outranking anything inferred from a family name. Tracing it into the parser showed
    /// the opposite. **Byte 0 carries two different vocabularies depending on which format the file
    /// was saved in, and nothing in the export says which:**
    ///
    /// - **HWP5** — genuine PANOSE, the file's own FACE_NAME bytes copied verbatim
    ///   (`parser/doc_info.rs:281`). Family kind 2 = Latin Text, 3 = Hand Written, 5 = Symbol.
    /// - **HWPX** — an OWPML `FCAT_*` enum written into the SAME byte
    ///   (`parser/hwpx/header.rs:474`, `info[0] = font_family_type_to_u8`), where 1 = FCAT_MYUNGJO,
    ///   2 = FCAT_GOTHIC, 3 = FCAT_SSERIF, 4 = FCAT_BRUSHSCRIPT, 5 = FCAT_DECORATIVE.
    ///
    /// The two disagree on almost every value that matters: `3` means hand-written under one reading
    /// and SANS-SERIF under the other, `5` means symbol under one and DECORATIVE under the other, and
    /// the two most useful HWPX values — 명조 and 고딕, stated outright — are not PANOSE family kinds
    /// at all. A reader that picks one vocabulary is wrong for every file saved the other way.
    ///
    /// Byte 1 is worse: on HWPX it is rhwp's own `synthesize_serif_type` guess from the font NAME, and
    /// no XML attribute backs it. The same manuscript saved both ways reports 11 from its HWP5 form
    /// and 0 from its HWPX one.
    ///
    /// So this reader honours the declaration it can actually read — the family NAME, whose morphemes
    /// are the document's own words and which `classify` covers for 97.5% of the font slots in a
    /// 2,267-document corpus. The block stays CARRIED on this type so a later sprint can consume it
    /// once the exporter normalises the two vocabularies into one field and says which it used;
    /// reading it before then would be guessing while claiming to quote.
    var declaredKind: DeclaredFontKind? { nil }
}

#if FMD_RUST_ENGINE
/// Declared here, not beside the decoder: Swift synthesises `Decodable` only in the file that
/// declares the type. See `OfficeBlock.swift`'s decoding section for the whole picture.
extension DeclaredFace: Decodable {}
#endif
