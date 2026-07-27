#!/usr/bin/env python3
"""Generate Sources/FastDocReader/Render/Office/Script/ScriptRanges.swift from the UCD.

This is a BUILD-TIME tool, not shipped code: it turns two Unicode Character Database files
into one sorted, gapless range table that the app looks up by binary search. Swift's standard
library exposes no `Script` property at all (58 members of `Unicode.Scalar.Properties`, none of
them script or block), and the routes that could answer it at runtime were each measured and
rejected -- ICU is undocumented on Apple platforms and an unresolved App Store risk, NLTagger
returns language-flavoured composite codes (漢字 -> Jpan) at 63-100x the cost, and the scalar's
own `name` string disagrees with the real Script value on exactly the characters that matter
(U+309B, U+0964, U+064B). So we carry the answer with us.

Usage:
    python3 Scripts/gen-script-ranges.py                    # fetch UCD 17.0.0 over the network
    python3 Scripts/gen-script-ranges.py --version 18.0.0   # fetch a different UCD release
    python3 Scripts/gen-script-ranges.py --ucd ~/ucd        # use already-downloaded files

The version stamped into the generated file is READ OUT OF the data files' own headers, never
passed in -- a stamp that a caller could get wrong is worse than no stamp, because the whole
point of it is to tell a future reader which UCD the table and CoreText's font cascade were
last known to agree on. `--version` only chooses what to download, and is then checked against
what actually arrived.

The Unicode Character Database is licensed under UNICODE LICENSE V3, which requires the
copyright and permission notice to travel with derived data. That notice is emitted into the
generated Swift file's header, ships in full as licenses/UNICODE-LICENSE-V3.txt, and is
recorded in THIRD-PARTY-NOTICES.md. Do not remove any of the three.
"""

import argparse
import os
import re
import sys
import urllib.request

# The class order is a CONTRACT with Swift's `ScriptClass` enum -- the generated table stores
# each range's class as this list's index, so reordering it silently re-labels every scalar in
# the app. `ScriptTableTests.testGeneratedClassNamesMatchTheEnumCaseOrder` compares the emitted
# names against the enum's own cases and fails if the two ever drift apart.
CLASS_ORDER = [
    "latin",
    "hangul",
    "han",
    "kana",
    "eastAsianOther",
    "complex",
    "other",
    "common",
    "inherited",
    "extend",
]

HANGUL = {"Hangul"}
HAN = {"Han"}
KANA = {"Hiragana", "Katakana"}

# EAST_ASIAN_OTHER and COMPLEX are the two curated sets in this file, and they are curated
# because Unicode defines no property for either notion: "complex script" is ODF's and Word's
# shaping/bidi vocabulary, not the UCD's, and there is no Complex_Script property to derive it
# from. They are therefore refinements OF `other`, not independent facts -- every classifier
# shipping today maps `complex`, `eastAsianOther` and `other` to the same slot, so a script
# missing from either set cannot mis-render anything. The day a classifier does distinguish
# them, the right move is to derive the membership (Bidi_Class in {AL,R}, union scripts with an
# Indic_Syllabic_Category, plus an explicit set) rather than to keep patching a list by hand.
EAST_ASIAN_OTHER = {
    "Bopomofo",
    "Yi",
    "Nushu",
    "Tangut",
    "Khitan_Small_Script",
    "Lisu",
    "Miao",
    "Nyiakeng_Puachue_Hmong",
}
COMPLEX = {
    "Arabic", "Hebrew", "Syriac", "Thaana", "Nko", "Samaritan", "Mandaic",
    "Devanagari", "Bengali", "Gurmukhi", "Gujarati", "Oriya", "Tamil", "Telugu",
    "Kannada", "Malayalam", "Sinhala", "Thai", "Lao", "Tibetan", "Myanmar", "Khmer",
    "Adlam", "Hanifi_Rohingya", "Mongolian", "Tifinagh", "Yezidi", "Garay", "Todhri",
    "Tai_Tham", "Tai_Le", "New_Tai_Lue", "Tai_Viet", "Javanese", "Balinese", "Sundanese",
    "Batak", "Buginese", "Rejang", "Lepcha", "Limbu", "Syloti_Nagri", "Kaithi", "Chakma",
    "Sharada", "Takri", "Tirhuta", "Modi", "Grantha", "Ahom", "Newa", "Bhaiksuki",
    "Marchen", "Masaram_Gondi", "Gunjala_Gondi", "Soyombo", "Zanabazar_Square", "Dogra",
    "Makasar", "Wancho", "Chorasmian", "Dives_Akuru", "Vithkuqi", "Old_Uyghur", "Tangsa",
    "Toto", "Cypro_Minoan", "Kawi", "Nag_Mundari", "Sunuwar", "Tulu_Tigalari",
    "Gurung_Khema", "Kirat_Rai", "Ol_Onal", "Beria_Erfe", "Sidetic", "Tai_Yo",
    "Tolong_Siki",
}

MAX_SCALAR = 0x10FFFF
UCD_URL = "https://www.unicode.org/Public/{version}/ucd/{name}"

# Reproduced from https://www.unicode.org/license.txt, the licence the UCD's own header points
# at via https://www.unicode.org/copyright.html. Emitted into the generated file so the notice
# travels with the derived data even if the file is read in isolation.
LICENCE_NOTICE = [
    "Derived from the Unicode Character Database, Copyright (c) 1991-2026 Unicode, Inc.",
    "Distributed under UNICODE LICENSE V3; full text in licenses/UNICODE-LICENSE-V3.txt.",
    "Unicode and the Unicode Logo are registered trademarks of Unicode, Inc.",
]


def classify(script_value):
    """One UCD Script value -> one of CLASS_ORDER."""
    if script_value == "Latin":
        return "latin"
    if script_value == "Common":
        return "common"
    if script_value == "Inherited":
        return "inherited"
    if script_value in HANGUL:
        return "hangul"
    if script_value in HAN:
        return "han"
    if script_value in KANA:
        return "kana"
    if script_value in EAST_ASIAN_OTHER:
        return "eastAsianOther"
    if script_value in COMPLEX:
        return "complex"
    # Everything with a real script identity we do not name individually, PLUS the scalars the
    # UCD leaves unassigned (Script=Unknown, which includes the private use areas). Unassigned
    # is deliberately NOT absorbing: it is not Common, and a format whose own specification
    # says to treat it as neutral -- ODF does, for its Table 22 gaps -- expresses that in its
    # own classifier, which is the whole reason `classify` is injected into the splitter rather
    # than baked into this table.
    return "other"


def fetch(version, name, cache_dir):
    """Read a UCD file from `cache_dir`, downloading it there first if it is not present."""
    path = os.path.join(cache_dir, name)
    if not os.path.exists(path):
        url = UCD_URL.format(version=version, name=name)
        sys.stderr.write("fetching %s\n" % url)
        os.makedirs(cache_dir, exist_ok=True)
        with urllib.request.urlopen(url) as response, open(path, "wb") as out:
            out.write(response.read())
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def stamped_version(text, name):
    """The UCD release a data file declares in its OWN first line (`# Scripts-17.0.0.txt`)."""
    match = re.match(r"#\s*%s-(\d+\.\d+\.\d+)\.txt" % re.escape(name.replace(".txt", "")), text)
    if not match:
        raise SystemExit("%s does not declare its UCD version in its first line" % name)
    return match.group(1)


def parse_ranges(text, wanted_property=None):
    """UCD line format -> [(first, last, value)], sorted. `wanted_property` filters the
    two-field files (DerivedCoreProperties.txt) down to one property."""
    out = []
    for line in text.splitlines():
        line = line.split("#")[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        code_range, value = fields[0], fields[1]
        if wanted_property is not None and value != wanted_property:
            continue
        if ".." in code_range:
            first, last = code_range.split("..")
        else:
            first = last = code_range
        out.append((int(first, 16), int(last, 16), value))
    out.sort()
    return out


def coalesce(ranges):
    """Merge adjacent ranges that carry the same class. The table is keyed by START only, so
    two touching ranges with one class must become one entry or the binary search does extra
    probes for no reason."""
    out = []
    for first, last, value in ranges:
        if out and out[-1][2] == value and out[-1][1] + 1 == first:
            out[-1] = (out[-1][0], last, value)
        else:
            out.append((first, last, value))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="17.0.0",
                        help="UCD release to fetch (ignored when --ucd already holds the files)")
    parser.add_argument("--ucd", default=None,
                        help="directory holding Scripts.txt / DerivedCoreProperties.txt; "
                             "missing files are downloaded into it")
    parser.add_argument("--out", default=None, help="path of the Swift file to write")
    args = parser.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cache_dir = args.ucd or os.path.join(repo, ".ucd-cache")
    out_path = args.out or os.path.join(
        repo, "Sources/FastDocReader/Render/Office/Script/ScriptRanges.swift")

    scripts_text = fetch(args.version, "Scripts.txt", cache_dir)
    derived_text = fetch(args.version, "DerivedCoreProperties.txt", cache_dir)

    # The stamp is what the DATA says, not what the caller asked for, and both files have to
    # agree -- a Scripts.txt from one release overlaid with a Grapheme_Extend set from another
    # would produce a table that is internally inconsistent and stamped with a version that
    # describes neither half of it.
    scripts_version = stamped_version(scripts_text, "Scripts.txt")
    derived_version = stamped_version(derived_text, "DerivedCoreProperties.txt")
    if scripts_version != derived_version:
        raise SystemExit("UCD version mismatch: Scripts.txt %s vs DerivedCoreProperties.txt %s"
                         % (scripts_version, derived_version))
    if args.version not in (scripts_version, "latest"):
        raise SystemExit("asked for UCD %s but the files in %s are %s"
                         % (args.version, cache_dir, scripts_version))

    script_ranges = parse_ranges(scripts_text)
    declared_scripts = {value for _, _, value in script_ranges}

    # A curated name that no longer exists in the UCD is dead weight that silently stops
    # classifying anything -- exactly the kind of quiet drift a rename upstream would cause.
    # Refuse rather than generate a table with an unreachable arm in it.
    for name, curated in (("EAST_ASIAN_OTHER", EAST_ASIAN_OTHER), ("COMPLEX", COMPLEX)):
        unknown = sorted(curated - declared_scripts)
        if unknown:
            raise SystemExit("%s names scripts UCD %s does not define: %s"
                             % (name, scripts_version, ", ".join(unknown)))
    overlap = sorted(EAST_ASIAN_OTHER & COMPLEX)
    if overlap:
        raise SystemExit("EAST_ASIAN_OTHER and COMPLEX both claim: %s" % ", ".join(overlap))

    # Per-scalar class, then the Grapheme_Extend overlay ON TOP. The overlay is the whole
    # reason this table exists in the form it does: 1,443 combining scalars carry a REAL script
    # (U+0483 Cyrillic titlo, U+0591-05BD Hebrew points, U+0610-061A Arabic, U+094D Devanagari
    # virama, U+0E31/U+0E34 Thai), so absorbing only Common and Inherited leaves those free to
    # break a run in the middle of a grapheme cluster. Asking
    # `Unicode.Scalar.Properties.isGraphemeExtend` per scalar at runtime instead was measured at
    # 11.64 ms per 250k scalars -- more than the whole grapheme-cluster iteration it was meant
    # to replace -- so the bit is baked in here and never queried again.
    classes = bytearray([CLASS_ORDER.index("other")]) * (MAX_SCALAR + 1)
    for first, last, value in script_ranges:
        klass = CLASS_ORDER.index(classify(value))
        for scalar in range(first, last + 1):
            classes[scalar] = klass
    extend_index = CLASS_ORDER.index("extend")
    extend_count = 0
    for first, last, _ in parse_ranges(derived_text, wanted_property="Grapheme_Extend"):
        for scalar in range(first, last + 1):
            classes[scalar] = extend_index
            extend_count += 1

    ranges = []
    start = 0
    for scalar in range(1, MAX_SCALAR + 2):
        if scalar > MAX_SCALAR or classes[scalar] != classes[start]:
            ranges.append((start, scalar - 1, CLASS_ORDER[classes[start]]))
            start = scalar
    ranges = coalesce(ranges)

    starts = ",".join(str(first) for first, _, _ in ranges)
    values = ",".join(str(CLASS_ORDER.index(value)) for _, _, value in ranges)
    names = ", ".join('"%s"' % name for name in CLASS_ORDER)
    command = "python3 Scripts/gen-script-ranges.py --version %s" % scripts_version

    lines = []
    lines.append("// GENERATED FILE -- do not edit by hand.")
    lines.append("//")
    lines.append("// Regenerate with:  %s" % command)
    lines.append("// Generator:        Scripts/gen-script-ranges.py")
    lines.append("// Source data:      Unicode Character Database %s" % scripts_version)
    lines.append("//                   Scripts.txt, DerivedCoreProperties.txt (Grapheme_Extend)")
    lines.append("//")
    for notice in LICENCE_NOTICE:
        lines.append("// %s" % notice)
    lines.append("//")
    lines.append("// %d ranges, sorted, gapless, covering U+0000...U+10FFFF. Looked up by binary")
    lines[-1] = lines[-1] % len(ranges)
    lines.append("// search in `UnicodeScript.of(_:)`; the classes are `ScriptClass`'s cases, stored")
    lines.append("// as that enum's raw values. Whichever UCD release this was built from is the one")
    lines.append("// the classifier and the platform's font cascade were last known to agree on.")
    lines.append("")
    lines.append("/// The UCD release `scriptRangeStarts`/`scriptRangeClasses` were generated from.")
    lines.append("let scriptTableUnicodeVersion = \"%s\"" % scripts_version)
    lines.append("")
    lines.append("/// First scalar of each range, ascending. Entry `i` runs to `starts[i + 1] - 1`.")
    lines.append("let scriptRangeStarts: [UInt32] = [%s]" % starts)
    lines.append("")
    lines.append("/// `ScriptClass` raw value for the range starting at the same index.")
    lines.append("let scriptRangeClasses: [UInt8] = [%s]" % values)
    lines.append("")
    lines.append("/// `ScriptClass`'s case names in raw-value order, as this generator wrote them.")
    lines.append("/// Compared against the enum itself by a test, so a reordered CLASS_ORDER cannot")
    lines.append("/// silently re-label every scalar in the table.")
    lines.append("let scriptClassNames: [String] = [%s]" % names)
    lines.append("")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))

    sys.stderr.write("UCD %s: %d script ranges in, %d Grapheme_Extend scalars overlaid\n"
                     % (scripts_version, len(script_ranges), extend_count))
    sys.stderr.write("wrote %s (%d entries, %d bytes)\n"
                     % (out_path, len(ranges), os.path.getsize(out_path)))


if __name__ == "__main__":
    main()
