//! swift: Render/CodeHighlighter.swift
//! swift-range: 1-2

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

// swift: Render/CodeHighlighter.swift:3-11
/// Native, dependency-free tokenizer for a curated language set. This keeps the "no JavaScriptCore
/// for code-only documents" guarantee (spec §2, §10.1). Unknown languages fall back to plain
/// monospace. tree-sitter is a v2 upgrade.
///
/// ONE left-to-right pass, not a stack of regex passes painting over each other. That ordering is
/// what decides correctness: a scanner that has already consumed `"http://a.com"` as a string can't
/// then mistake its `//` for a comment, and a `#` inside a shell string stays a string. Overlapping
/// regex passes get both of those wrong, and every language added multiplies the collisions.
pub struct CodeHighlighter;

// swift: Render/CodeHighlighter.swift:12-21
/// swift: `NSString.enumerateSubstrings(in:options:[.byLines],using:)` — `swiftshim::SwiftString`
/// carries the primitive that method would be built from (`getLineStart(_:end:contentsEnd:for:)`)
/// but not the by-lines walk itself, so it is done locally with that primitive rather than
/// widening the shim for this one call site (`diff_highlight`'s line-at-a-time colouring).
fn enumerate_substrings_by_lines(
    ns: &swiftshim::SwiftString,
    in_range: swiftshim::NSRange,
    mut body: impl FnMut(swiftshim::NSRange, &mut bool),
) {
    let mut stop = false;
    let mut loc = in_range.location;
    let end = in_range.maxRange();
    while loc < end && !stop {
        let mut line_end = 0usize;
        let mut contents_end = 0usize;
        ns.getLineStart(None, &mut line_end, &mut contents_end, swiftshim::NSRange::new(loc, 0));
        let range = swiftshim::NSRange::new(loc, contents_end.saturating_sub(loc));
        body(range, &mut stop);
        loc = if line_end > loc { line_end } else { loc + 1 };
    }
}

struct Palette {
    keyword: swiftshim::NSColor,
    r#type: swiftshim::NSColor,
    string: swiftshim::NSColor,
    number: swiftshim::NSColor,
    comment: swiftshim::NSColor,
    added: swiftshim::NSColor,
    removed: swiftshim::NSColor,
}

impl Default for Palette {
    fn default() -> Self {
        // swift: Render/CodeHighlighter.swift:13-19
        Self {
            keyword: swiftshim::system_colors::systemPink(),
            r#type: swiftshim::system_colors::systemTeal(),
            string: swiftshim::system_colors::systemRed(),
            number: swiftshim::system_colors::systemOrange(),
            comment: swiftshim::system_colors::secondaryLabelColor(),
            added: swiftshim::system_colors::systemGreen(),
            removed: swiftshim::system_colors::systemRed(),
        }
    }
}

// swift: Render/CodeHighlighter.swift:22-36
/// A language is just its comment markers, its string delimiters and its keywords — enough for
/// reading, which is all this app does.
#[derive(Clone)]
struct Lang {
    kw: HashSet<String>,
    /// line-comment starters
    line: Vec<String>,
    /// block-comment delimiters
    block: Vec<(String, String)>,
    /// string delimiters (single char each)
    quotes: String,
    /// multi-char string fences ("""…""")
    raw: Vec<(String, String)>,
    /// Colour Capitalised words as types. True only where that convention actually holds, so
    /// Python's `None` or a shell's `PATH` don't get painted as types.
    caps: bool,
    /// Diffs are coloured by line, not by token — see `diffHighlight`.
    line_shaped: bool,
}

impl Default for Lang {
    fn default() -> Self {
        Self {
            kw: HashSet::new(),
            line: vec!["//".to_string()],
            block: vec![("/*".to_string(), "*/".to_string())],
            quotes: "\"'".to_string(),
            raw: Vec::new(),
            caps: false,
            line_shaped: false,
        }
    }
}

fn kw(words: &[&str]) -> HashSet<String> {
    words.iter().map(|w| w.to_string()).collect()
}

impl CodeHighlighter {
    // MARK: - Languages
    // swift: Render/CodeHighlighter.swift:37-39

    // swift: Render/CodeHighlighter.swift:39-41
    fn c_like(keywords: &[&str], caps: bool, line: Vec<String>) -> Lang {
        Lang {
            kw: kw(keywords),
            line,
            block: vec![("/*".to_string(), "*/".to_string())],
            quotes: "\"'`".to_string(),
            caps,
            ..Default::default()
        }
    }

    // swift: Render/CodeHighlighter.swift:42-45
    fn hash_like(keywords: &[&str], quotes: &str, raw: Vec<(String, String)>) -> Lang {
        Lang {
            kw: kw(keywords),
            line: vec!["#".to_string()],
            block: Vec::new(),
            quotes: quotes.to_string(),
            raw,
            ..Default::default()
        }
    }

    fn c_like_default(keywords: &[&str]) -> Lang {
        Self::c_like(keywords, true, vec!["//".to_string()])
    }

    fn hash_like_default(keywords: &[&str]) -> Lang {
        Self::hash_like(keywords, "\"'", Vec::new())
    }

    // swift: Render/CodeHighlighter.swift:46-90
    fn langs() -> &'static HashMap<String, Lang> {
        static LANGS: OnceLock<HashMap<String, Lang>> = OnceLock::new();
        LANGS.get_or_init(|| {
            let mut m: HashMap<String, Lang> = HashMap::new();
            m.insert(
                "swift".to_string(),
                Self::c_like_default(&[
                    "let", "var", "func", "if", "else", "for", "while", "return", "struct",
                    "class", "enum", "protocol", "extension", "import", "guard", "in", "self",
                    "init", "case", "switch", "defer", "throws", "try", "await", "async", "some",
                    "any", "true", "false", "nil",
                ]),
            );
            m.insert(
                "js".to_string(),
                Self::c_like(
                    &[
                        "const", "let", "var", "function", "if", "else", "for", "while", "return",
                        "class", "new", "import", "export", "from", "default", "await", "async",
                        "try", "catch", "throw", "typeof", "switch", "case", "break", "continue",
                        "true", "false", "null", "undefined", "this",
                    ],
                    false,
                    vec!["//".to_string()],
                ),
            );
            m.insert(
                "ts".to_string(),
                Self::c_like_default(&[
                    "const", "let", "var", "function", "if", "else", "for", "while", "return",
                    "class", "new", "import", "export", "from", "default", "await", "async", "try",
                    "catch", "throw", "interface", "type", "enum", "implements", "extends",
                    "public", "private", "readonly", "switch", "case", "true", "false", "null",
                    "undefined", "this",
                ]),
            );
            m.insert(
                "go".to_string(),
                Self::c_like_default(&[
                    "func", "package", "import", "var", "const", "type", "struct", "interface",
                    "if", "else", "for", "range", "return", "go", "defer", "chan", "select",
                    "switch", "case", "map", "make", "new", "nil", "true", "false",
                ]),
            );
            m.insert(
                "rust".to_string(),
                Self::c_like_default(&[
                    "fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "pub", "use",
                    "mod", "if", "else", "for", "while", "loop", "match", "return", "self", "Self",
                    "async", "await", "move", "ref", "where", "true", "false",
                ]),
            );
            m.insert(
                "java".to_string(),
                Self::c_like_default(&[
                    "class", "interface", "enum", "public", "private", "protected", "static",
                    "final", "void", "new", "if", "else", "for", "while", "return", "import",
                    "package", "extends", "implements", "try", "catch", "throw", "throws",
                    "switch", "case", "this", "true", "false", "null",
                ]),
            );
            m.insert(
                "kotlin".to_string(),
                Self::c_like_default(&[
                    "fun", "val", "var", "class", "object", "interface", "if", "else", "for",
                    "while", "return", "when", "import", "package", "data", "sealed", "suspend",
                    "override", "private", "public", "true", "false", "null", "this",
                ]),
            );
            m.insert(
                "c".to_string(),
                Self::c_like(
                    &[
                        "int", "char", "float", "double", "void", "long", "short", "unsigned",
                        "signed", "struct", "union", "enum", "typedef", "static", "const", "if",
                        "else", "for", "while", "return", "switch", "case", "break", "continue",
                        "sizeof", "include", "define", "NULL",
                    ],
                    false,
                    vec!["//".to_string()],
                ),
            );
            m.insert(
                "cpp".to_string(),
                Self::c_like_default(&[
                    "int", "char", "float", "double", "void", "bool", "auto", "class", "struct",
                    "enum", "namespace", "template", "typename", "public", "private", "protected",
                    "virtual", "const", "static", "if", "else", "for", "while", "return", "switch",
                    "case", "new", "delete", "try", "catch", "throw", "nullptr", "true", "false",
                ]),
            );
            m.insert(
                "csharp".to_string(),
                Self::c_like_default(&[
                    "using", "namespace", "class", "struct", "interface", "enum", "public",
                    "private", "protected", "internal", "static", "readonly", "var", "void", "if",
                    "else", "for", "foreach", "in", "while", "return", "switch", "case", "new",
                    "try", "catch", "throw", "async", "await", "true", "false", "null", "this",
                ]),
            );
            m.insert(
                "scala".to_string(),
                Self::c_like_default(&[
                    "def", "val", "var", "class", "object", "trait", "case", "match", "if", "else",
                    "for", "while", "return", "import", "package", "extends", "with", "implicit",
                    "lazy", "new", "true", "false", "null", "this",
                ]),
            );
            m.insert(
                "dart".to_string(),
                Self::c_like_default(&[
                    "class", "void", "var", "final", "const", "if", "else", "for", "while",
                    "return", "import", "export", "new", "async", "await", "try", "catch", "throw",
                    "extends", "implements", "true", "false", "null", "this",
                ]),
            );
            m.insert(
                "php".to_string(),
                Self::c_like(
                    &[
                        "function", "class", "interface", "trait", "public", "private",
                        "protected", "static", "if", "else", "elseif", "foreach", "for", "while",
                        "return", "echo", "require", "include", "namespace", "use", "new", "try",
                        "catch", "throw", "true", "false", "null", "this",
                    ],
                    false,
                    vec!["//".to_string(), "#".to_string()],
                ),
            );
            m.insert(
                "objc".to_string(),
                Self::c_like_default(&[
                    "interface", "implementation", "property", "import", "include", "if", "else",
                    "for", "while", "return", "void", "id", "self", "nil", "YES", "NO",
                    "nonatomic", "strong", "weak",
                ]),
            );
            m.insert(
                "json".to_string(),
                Lang {
                    kw: kw(&["true", "false", "null"]),
                    line: Vec::new(),
                    block: Vec::new(),
                    quotes: "\"".to_string(),
                    ..Default::default()
                },
            );

            m.insert(
                "python".to_string(),
                Self::hash_like(
                    &[
                        "def", "class", "if", "elif", "else", "for", "while", "return", "import",
                        "from", "as", "with", "in", "not", "and", "or", "try", "except", "finally",
                        "raise", "lambda", "yield", "async", "await", "pass", "break", "continue",
                        "global", "True", "False", "None", "self",
                    ],
                    "\"'",
                    vec![
                        ("\"\"\"".to_string(), "\"\"\"".to_string()),
                        ("'''".to_string(), "'''".to_string()),
                    ],
                ),
            );
            m.insert(
                "bash".to_string(),
                Self::hash_like(
                    &[
                        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                        "case", "esac", "function", "return", "echo", "export", "local", "source",
                        "exit", "cd", "set",
                    ],
                    "\"'`",
                    Vec::new(),
                ),
            );
            m.insert(
                "ruby".to_string(),
                Self::hash_like_default(&[
                    "def", "class", "module", "if", "elsif", "else", "end", "for", "while", "do",
                    "return", "require", "include", "attr_accessor", "yield", "begin", "rescue",
                    "ensure", "raise", "true", "false", "nil", "self", "puts",
                ]),
            );
            m.insert(
                "perl".to_string(),
                Self::hash_like_default(&[
                    "sub", "my", "our", "local", "if", "elsif", "else", "unless", "for", "foreach",
                    "while", "return", "use", "package", "require", "last", "next", "undef",
                ]),
            );
            m.insert(
                "r".to_string(),
                Self::hash_like(
                    &[
                        "function", "if", "else", "for", "while", "repeat", "return", "library",
                        "require", "TRUE", "FALSE", "NULL", "NA", "Inf", "in", "next", "break",
                    ],
                    "\"'`",
                    Vec::new(),
                ),
            );
            m.insert(
                "elixir".to_string(),
                Self::hash_like_default(&[
                    "def", "defmodule", "defp", "do", "end", "if", "else", "cond", "case", "fn",
                    "when", "import", "alias", "require", "use", "true", "false", "nil",
                ]),
            );
            m.insert(
                "yaml".to_string(),
                Self::hash_like_default(&[
                    "true", "false", "null", "yes", "no", "on", "off",
                ]),
            );
            m.insert("toml".to_string(), Self::hash_like_default(&["true", "false"]));
            m.insert(
                "dockerfile".to_string(),
                Self::hash_like_default(&[
                    "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT",
                    "VOLUME", "USER", "WORKDIR", "ARG", "HEALTHCHECK", "SHELL", "AS",
                ]),
            );
            m.insert(
                "makefile".to_string(),
                Self::hash_like_default(&[
                    "include", "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "define",
                    "endef", "export", ".PHONY",
                ]),
            );
            m.insert(
                "powershell".to_string(),
                Lang {
                    kw: kw(&[
                        "function", "param", "if", "else", "elseif", "foreach", "for", "while",
                        "return", "try", "catch", "finally", "throw", "switch", "begin", "process",
                        "end", "true", "false", "null",
                    ]),
                    line: vec!["#".to_string()],
                    block: vec![("<#".to_string(), "#>".to_string())],
                    quotes: "\"'".to_string(),
                    ..Default::default()
                },
            );
            m.insert(
                "ini".to_string(),
                Lang {
                    kw: kw(&["true", "false"]),
                    line: vec![";".to_string(), "#".to_string()],
                    block: Vec::new(),
                    quotes: "\"'".to_string(),
                    ..Default::default()
                },
            );

            m.insert(
                "sql".to_string(),
                Lang {
                    kw: kw(&[
                        "select", "from", "where", "insert", "into", "values", "update", "set",
                        "delete", "create", "table", "alter", "drop", "index", "join", "left",
                        "right", "inner", "outer", "on", "group", "order", "by", "having", "limit",
                        "offset", "as", "and", "or", "not", "null", "distinct", "union", "primary",
                        "key", "foreign", "references", "default", "case", "when", "then", "end",
                    ]),
                    line: vec!["--".to_string()],
                    block: vec![("/*".to_string(), "*/".to_string())],
                    quotes: "\"'`".to_string(),
                    ..Default::default()
                },
            );
            m.insert(
                "lua".to_string(),
                Lang {
                    kw: kw(&[
                        "function", "local", "if", "then", "else", "elseif", "end", "for",
                        "while", "do", "repeat", "until", "return", "break", "nil", "true",
                        "false", "and", "or", "not", "in",
                    ]),
                    line: vec!["--".to_string()],
                    block: vec![("--[[".to_string(), "]]".to_string())],
                    quotes: "\"'".to_string(),
                    ..Default::default()
                },
            );
            m.insert(
                "haskell".to_string(),
                Lang {
                    kw: kw(&[
                        "module", "import", "where", "let", "in", "if", "then", "else", "case",
                        "of", "data", "type", "newtype", "class", "instance", "deriving", "do",
                        "True", "False",
                    ]),
                    line: vec!["--".to_string()],
                    block: vec![("{-".to_string(), "-}".to_string())],
                    quotes: "\"'".to_string(),
                    caps: true,
                    ..Default::default()
                },
            );

            m.insert(
                "html".to_string(),
                Lang {
                    kw: HashSet::new(),
                    line: Vec::new(),
                    block: vec![("<!--".to_string(), "-->".to_string())],
                    quotes: "\"'".to_string(),
                    ..Default::default()
                },
            );
            m.insert(
                "xml".to_string(),
                Lang {
                    kw: HashSet::new(),
                    line: Vec::new(),
                    block: vec![("<!--".to_string(), "-->".to_string())],
                    quotes: "\"'".to_string(),
                    ..Default::default()
                },
            );
            m.insert(
                "css".to_string(),
                Lang {
                    kw: kw(&["important", "media", "import", "keyframes", "supports", "from", "to"]),
                    line: Vec::new(),
                    block: vec![("/*".to_string(), "*/".to_string())],
                    quotes: "\"'".to_string(),
                    ..Default::default()
                },
            );
            m.insert(
                "diff".to_string(),
                Lang {
                    kw: HashSet::new(),
                    line: Vec::new(),
                    block: Vec::new(),
                    quotes: "".to_string(),
                    line_shaped: true,
                    ..Default::default()
                },
            );
            m
        })
    }

    // swift: Render/CodeHighlighter.swift:91-110
    /// Aliases as people actually write them in a fence, mapped onto the table above.
    fn aliases() -> &'static HashMap<String, String> {
        static ALIASES: OnceLock<HashMap<String, String>> = OnceLock::new();
        ALIASES.get_or_init(|| {
            let pairs: &[(&str, &str)] = &[
                ("javascript", "js"),
                ("jsx", "js"),
                ("mjs", "js"),
                ("cjs", "js"),
                ("node", "js"),
                ("typescript", "ts"),
                ("tsx", "ts"),
                ("py", "python"),
                ("python3", "python"),
                ("sh", "bash"),
                ("shell", "bash"),
                ("zsh", "bash"),
                ("console", "bash"),
                ("terminal", "bash"),
                ("golang", "go"),
                ("rs", "rust"),
                ("kt", "kotlin"),
                ("rb", "ruby"),
                ("c++", "cpp"),
                ("cc", "cpp"),
                ("hpp", "cpp"),
                ("cxx", "cpp"),
                ("c#", "csharp"),
                ("cs", "csharp"),
                ("objective-c", "objc"),
                ("objectivec", "objc"),
                ("yml", "yaml"),
                ("docker", "dockerfile"),
                ("make", "makefile"),
                ("ps1", "powershell"),
                ("pwsh", "powershell"),
                ("postgres", "sql"),
                ("postgresql", "sql"),
                ("mysql", "sql"),
                ("sqlite", "sql"),
                ("psql", "sql"),
                ("cfg", "ini"),
                ("conf", "ini"),
                ("editorconfig", "ini"),
                ("htm", "html"),
                ("svg", "xml"),
                ("plist", "xml"),
                ("scss", "css"),
                ("less", "css"),
                ("patch", "diff"),
                ("hs", "haskell"),
                ("ex", "elixir"),
                ("exs", "elixir"),
                ("pl", "perl"),
                ("json5", "json"),
                ("jsonc", "json"),
            ];
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        })
    }

    // swift: Render/CodeHighlighter.swift:111-115
    fn lang(raw: Option<&str>) -> Option<Lang> {
        let l = raw?.to_lowercase();
        let key = Self::aliases().get(&l).cloned().unwrap_or(l);
        Self::langs().get(&key).cloned()
    }

    // MARK: - Tokenizer
    // swift: Render/CodeHighlighter.swift:118-118

    // swift: Render/CodeHighlighter.swift:118-119
    fn identifier_extras() -> &'static HashSet<u16> {
        static EXTRAS: OnceLock<HashSet<u16>> = OnceLock::new();
        EXTRAS.get_or_init(|| HashSet::from([95u16, 36u16])) // _ $
    }

    // swift: Render/CodeHighlighter.swift:120-200
    pub fn highlight(
        code: &str,
        language: Option<&str>,
        theme: &crate::render::render_theme::RenderTheme,
    ) -> swiftshim::NSAttributedString {
        let base: HashMap<swiftshim::NSAttributedStringKey, swiftshim::AttrValue> = HashMap::from([
            (
                swiftshim::NSAttributedStringKey::Font,
                swiftshim::AttrValue::Font(theme.code_font()),
            ),
            (
                swiftshim::NSAttributedStringKey::ForegroundColor,
                swiftshim::AttrValue::Color(theme.text_color()),
            ),
        ]);
        let mut result = swiftshim::NSMutableAttributedString::with_attributes(code, base);
        let lang = match Self::lang(language) {
            Some(l) => l,
            None => return result.asAttributedString().clone(), // plain fallback
        };
        let p = Palette::default();
        let ns = swiftshim::SwiftString::new(code);
        let n = ns.length();

        // swift: Render/CodeHighlighter.swift:128-131
        let paint = |result: &mut swiftshim::NSMutableAttributedString, from: usize, to: usize, c: swiftshim::NSColor| {
            if to <= from {
                return;
            }
            result.addAttribute(
                swiftshim::NSAttributedStringKey::ForegroundColor,
                swiftshim::AttrValue::Color(c),
                swiftshim::NSRange::new(from, to - from),
            );
        };
        // swift: Render/CodeHighlighter.swift:132-137
        let matches = |token: &str, k: usize| -> bool {
            let t = swiftshim::SwiftString::new(token);
            if t.length() == 0 || k + t.length() > n {
                return false;
            }
            for j in 0..t.length() {
                if ns.characterAt(k + j) != t.characterAt(j) {
                    return false;
                }
            }
            true
        };
        // swift: Render/CodeHighlighter.swift:138
        fn is_digit(c: u16) -> bool {
            (48..=57).contains(&c)
        }
        // swift: Render/CodeHighlighter.swift:139-141
        let is_word_start = |c: u16| -> bool {
            (65..=90).contains(&c)
                || (97..=122).contains(&c)
                || Self::identifier_extras().contains(&c)
                || c > 127
        };
        // swift: Render/CodeHighlighter.swift:142
        let is_word = |c: u16| -> bool { is_word_start(c) || is_digit(c) };

        // swift: Render/CodeHighlighter.swift:144
        if lang.line_shaped {
            return Self::diff_highlight(result, &ns, &p).asAttributedString().clone();
        }

        // swift: Render/CodeHighlighter.swift:146-198
        let mut i = 0usize;
        while i < n {
            let c = ns.characterAt(i);

            if lang.line.iter().any(|tok| matches(tok, i)) {
                let mut j = i;
                while j < n && ns.characterAt(j) != 10 {
                    j += 1;
                }
                paint(&mut result, i, j, p.comment);
                i = j;
                continue;
            }
            if let Some(b) = lang.block.iter().find(|b| matches(&b.0, i)) {
                let mut j = i + swiftshim::SwiftString::new(&b.0).length();
                while j < n && !matches(&b.1, j) {
                    j += 1;
                }
                j = n.min(j + swiftshim::SwiftString::new(&b.1).length());
                paint(&mut result, i, j, p.comment);
                i = j;
                continue;
            }
            if let Some(r) = lang.raw.iter().find(|r| matches(&r.0, i)) {
                let mut j = i + swiftshim::SwiftString::new(&r.0).length();
                while j < n && !matches(&r.1, j) {
                    j += 1;
                }
                j = n.min(j + swiftshim::SwiftString::new(&r.1).length());
                paint(&mut result, i, j, p.string);
                i = j;
                continue;
            }
            if lang.quotes.encode_utf16().any(|u| u == c) {
                // Stop a runaway at the line end (except for backticks, which legitimately span
                // lines) so one stray quote can't paint the rest of the block red.
                let multiline = c == 96;
                let mut j = i + 1;
                while j < n {
                    let d = ns.characterAt(j);
                    if d == 92 {
                        j += 2;
                        continue;
                    } // escape
                    if d == c {
                        j += 1;
                        break;
                    }
                    if d == 10 && !multiline {
                        break;
                    }
                    j += 1;
                }
                paint(&mut result, i, j.min(n), p.string);
                i = j.min(n);
                continue;
            }
            if is_digit(c) {
                let mut j = i;
                while j < n && (is_word(ns.characterAt(j)) || ns.characterAt(j) == 46) {
                    j += 1;
                }
                paint(&mut result, i, j, p.number);
                i = j;
                continue;
            }
            if is_word_start(c) {
                let mut j = i;
                while j < n && is_word(ns.characterAt(j)) {
                    j += 1;
                }
                let word = ns.substring(swiftshim::NSRange::new(i, j - i));
                if lang.kw.contains(&word) {
                    paint(&mut result, i, j, p.keyword);
                } else if lang.caps {
                    if let Some(f) = word.chars().next() {
                        if f.is_uppercase() {
                            paint(&mut result, i, j, p.r#type);
                        }
                    }
                }
                i = j;
                continue;
            }
            i += 1;
        }
        result.asAttributedString().clone()
    }

    // swift: Render/CodeHighlighter.swift:201-220
    /// Diffs are line-shaped, not token-shaped: what matters is which side a line is on.
    fn diff_highlight(
        mut result: swiftshim::NSMutableAttributedString,
        ns: &swiftshim::SwiftString,
        p: &Palette,
    ) -> swiftshim::NSMutableAttributedString {
        enumerate_substrings_by_lines(
            ns,
            swiftshim::NSRange::new(0, ns.length()),
            |range, _stop| {
                if range.length == 0 {
                    return;
                }
                let head = ns.characterAt(range.location);
                let substring = ns.substring(range);
                let color: Option<swiftshim::NSColor> = match head {
                    43 => Some(if substring.starts_with("+++") { p.comment } else { p.added }), // +
                    45 => Some(if substring.starts_with("---") { p.comment } else { p.removed }), // -
                    64 => Some(p.keyword), // @@ hunk
                    _ => None,
                };
                if let Some(color) = color {
                    result.addAttribute(
                        swiftshim::NSAttributedStringKey::ForegroundColor,
                        swiftshim::AttrValue::Color(color),
                        range,
                    );
                }
            },
        );
        result
    }
}
