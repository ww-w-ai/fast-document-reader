import Foundation
import UniformTypeIdentifiers
import CoreGraphics

/// What `DocumentTypes.officeReaderType(for:)` returns a TYPE conforming to — `DocxReader` and
/// `OdtReader` both conform (see each), so the one switch in this file can hand back a reader for
/// EITHER "parse the archive" (`readOffice`) or "what's this document's own default body size"
/// (`officeDefaultBodyFontSize`) without a second switch that could name a different reader for the
/// same extension (see `officeReaderType`'s own doc for why that divergence is the thing to avoid).
protocol OfficeDocumentReader {
    static func read(_ archive: ZipArchive) throws -> OfficeReadResult
    static func documentDefaultBodyFontSize(_ archive: ZipArchive) -> CGFloat
}

/// The ONE list of file kinds this app opens itself. Three places have to agree — the open panel's
/// filter, the click-a-link handler, and `CFBundleDocumentTypes` in Info.plist — and when they
/// drift the symptom is silent (a file the panel offers opens in TextEdit instead). The first two
/// read this type; Info.plist can't, so any change here must be mirrored there in the same commit.
enum DocumentTypes {
    /// Markdown, rendered.
    /// `.mdown`/`.mkd`/`.mdtext` are deliberately absent: nobody declares those extensions, so macOS
    /// types them as a throwaway `dyn.…` and could never route one here anyway (invariant 69), and
    /// inventing a type of our own to claim three aliases almost nothing writes is not worth the
    /// declaration it would cost.
    static let markdownExtensions = ["md", "markdown"]

    /// Text we display verbatim (see PlainTextRenderer). Deliberately a fixed list rather than
    /// "anything that decodes as UTF-8": offering to open a .swift or .json is a promise this app
    /// doesn't keep — it has no syntax view for them, and the file's real editor is a better answer.
    /// The configuration-file group at the end is what `UTExportedTypeDeclarations` in Info.plist
    /// declares as `ai.ww-w.fast-md-reader.config-text`: nobody else registers those extensions, so
    /// without OUR declaration macOS types them `dyn.…` and refuses to bind the app to them at all
    /// (a `duti -s` fails with -50). Note a file named exactly `.env` has no EXTENSION — it is a
    /// dotfile whose whole name is that — so it stays outside this list's reach; `foo.env` and
    /// `.dev.vars` are what these entries answer.
    /// The serialisation group (`.yaml`/`.yml`/`.json`/`.xml`, alongside `.toml`) is the same promise
    /// as the configuration one: these are files a developer READS all day, and verbatim is what
    /// reading them looks like. Source CODE is still deliberately out — this app has no syntax view
    /// for a `.swift`, and its real editor is the better answer.
    /// The subtitle group is what a transcription tool or a subtitle download hands you; a cue is a
    /// timestamp line and its text, which is exactly what verbatim already shows. `.vtt` alone is
    /// declared by macOS (`org.w3.webvtt`); `.srt`/`.smi`/`.ass`/`.ssa`/`.sub`/`.lrc` are typed
    /// `dyn.…` by every Mac measured, so they need the exported declaration of ours that
    /// `UTExportedTypeDeclarations` carries as `ai.ww-w.fast-md-reader.subtitle-text` — same reason
    /// the configuration group needed one (invariant 69).
    /// The developer and markup groups are typed `dyn.…` by every Mac measured, so they carry two
    /// more exported declarations of ours — `ai.ww-w.fast-md-reader.dev-text` (infrastructure,
    /// schema and request files: `.tf`/`.tfvars`/`.hcl` is HashiCorp's configuration language, which
    /// is what a Terraform file is written in) and `ai.ww-w.fast-md-reader.markup-text` (prose
    /// formats that are not Markdown). The rest lean on a system type, named in Info.plist beside
    /// them: `.sql` is `org.iso.sql`, `.diff`/`.patch` are `public.patch-file`, `.proto` is
    /// `public.protobuf-source`, `.crash`/`.ips` are Apple's own report types.
    ///
    /// Deliberately absent, both measured rather than assumed:
    /// `.gitignore`/`.gitattributes`/`.dockerignore`/`.npmrc`/`.nvmrc`/`.editorconfig` have no
    /// EXTENSION at all — the dot is the start of the NAME — so macOS types them `public.data` and a
    /// filename-extension tag can never reach them; claiming `public.data` to catch them would put
    /// this app in the Open With list of every binary on the disk. And `.plist` conforms to neither
    /// `public.text` nor `public.plain-text` because a property list is as often binary as XML —
    /// opening one verbatim would show mojibake, so it is a promise this app should not make.
    static let plainTextExtensions = ["txt", "text", "csv", "tsv", "log", "crash", "ips",
                                      "conf", "cfg", "ini", "env", "vars", "toml", "cnf",
                                      "yaml", "yml", "json", "xml", "jsonl", "ndjson",
                                      "tf", "tfvars", "hcl", "sls", "properties", "lock",
                                      "graphql", "gql", "proto", "thrift", "avsc",
                                      "xsd", "wsdl", "dtd", "resx", "strings", "po",
                                      "har", "http", "rest", "sql", "diff", "patch",
                                      "mk", "gradle", "cmake", "bzl",
                                      "rst", "adoc", "asciidoc", "org", "tex", "textile", "nfo",
                                      "vtt", "srt", "smi", "ass", "ssa", "sub", "lrc"]

    /// Office formats, read-only (see invariants 22 and CLAUDE.md S4). `.rtf` was surveyed and
    /// dropped (see the roadmap's Revision 2 — AppKit's RTF reader loses structure and images
    /// outright); `.odt` gained a reader in R3, so it belongs here now.
    /// `.docm`/`.dotx`/`.dotm` (Word macro-enabled document/template, and template) share the exact
    /// same `word/document.xml` shape as `.docx` — this app only ever reads XML out of the zip, so
    /// macros are never executed, just never even looked at. They route to `DocxReader` below.
    static let officeExtensions = ["docx", "docm", "dotx", "dotm", "odt"] + hwpExtensions

    /// Hangul Word Processor, read-only via `HwpReader.read(Data)` (rhwp FFI). Kept SEPARATE from the
    /// zip-backed `officeReaderType` switch because HWP does NOT take a `ZipArchive`: an `.hwpx` is a
    /// zip but an `.hwp` is CFB binary, and rhwp parses BOTH from raw `Data` itself — so HWP must
    /// branch BEFORE `ZipArchive(data:)` (see `MarkdownDocument.read(from:)` and `HeadlessExtract`).
    /// These are folded into `officeExtensions` above so `kind`, `opensInApp` and the open panel all
    /// treat them as office documents (`.office` kind → Viewer/read-only, invariant 22); the branch in
    /// `read(from:)` plus THIS list are the single dispatch for HWP (invariant 29 — no second switch).
    static let hwpExtensions = ["hwp", "hwpx"]

    /// True for `.hwp`/`.hwpx` — the one predicate every read path checks to route to `HwpReader.read`
    /// (raw `Data`) instead of the zip pipeline. Kept here so the string list lives in ONE place.
    static func isHwp(_ ext: String) -> Bool { hwpExtensions.contains(ext.lowercased()) }

    static func opensInApp(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return markdownExtensions.contains(e) || plainTextExtensions.contains(e) || officeExtensions.contains(e)
    }

    /// The 3-way fork every render/edit decision is made from — see `DocumentKind`.
    static func kind(forExtension ext: String) -> DocumentKind {
        let e = ext.lowercased()
        if markdownExtensions.contains(e) { return .markdown }
        if officeExtensions.contains(e) { return .office }
        return .plainText
    }

    /// The ONE switch that decides which parser owns which office extension — everything that needs
    /// "which reader for this extension" (`readOffice` below AND `officeDefaultBodyFontSize`) goes
    /// through THIS lookup rather than each keeping its own `case "docx"…` list. A second, divergent
    /// switch is exactly how `.odt` shipped unreachable: it was registered here and in Info.plist
    /// (making the file reachable to the APP), but every read path still said `DocxReader.read`
    /// unconditionally (nothing made the bytes reachable to `OdtReader`). Returns `nil` for an
    /// extension that's in `officeExtensions` but has no case below — a programmer error, not a
    /// malformed file — and both callers below turn that into their own failure mode (throw / 11pt
    /// fallback) rather than silently guessing Word.
    private static func officeReaderType(for ext: String) -> OfficeDocumentReader.Type? {
        switch ext.lowercased() {
        case "docx", "docm", "dotx", "dotm": return DocxReader.self
        case "odt": return OdtReader.self
        // hwp/hwpx are DELIBERATELY absent: HWP takes raw `Data`, not a `ZipArchive`, so it can't
        // conform to `OfficeDocumentReader` and never reaches `readOffice`/`officeDefaultBodyFontSize`
        // — it branches to `HwpReader.read` before `ZipArchive(data:)` (see `isHwp`). Returning nil
        // here means readOffice throws if HWP ever wrongly reached it, a safety net, not the path.
        default: return nil
        }
    }

    static func readOffice(_ archive: ZipArchive, extension ext: String) throws -> OfficeReadResult {
        guard let reader = officeReaderType(for: ext) else {
            throw NSError(domain: "ai.ww-w.fast-md-reader", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\".\(ext)\" is registered as an office format but has no reader.",
            ])
        }
        // `.resolvingFontSubstitution()` is applied HERE, once, for both docx/docm/dotx/dotm AND
        // odt — the single funnel invariant 29 already makes both readers share, so neither
        // `DocxReader` nor `OdtReader` has to call it (or forget to). See
        // `FontSubstitutionResolver`'s file doc for why this belongs at read time.
        return try reader.read(archive).resolvingFontSubstitution()
    }

    /// The other half of `OfficeTextBuilder.build`'s font-size model (see its `documentDefaultFontSize`
    /// doc) — the source document's own default body run size, via the SAME reader lookup `readOffice`
    /// uses, so the two can never name different readers for the same extension. `11` (the fallback
    /// both `DocxReader` and `OdtReader` already return when a document declares no default of its
    /// own) for an extension with no registered reader — this is a lookup for rendering, not a second
    /// place that validates the extension, so it degrades rather than throws.
    static func officeDefaultBodyFontSize(_ archive: ZipArchive, extension ext: String) -> CGFloat {
        officeReaderType(for: ext)?.documentDefaultBodyFontSize(archive) ?? 11
    }

    /// Content types for the Open panel's filter.
    static var openPanelTypes: [UTType] {
        var types: [UTType] = []
        if let pub = UTType("public.markdown") { types.append(pub) }
        if let md = UTType("net.daringfireball.markdown") { types.append(md) }
        types.append(contentsOf: [.plainText, .commaSeparatedText, .tabSeparatedText, .log, .text])
        // Extensions the system may not map to any of the above (.env, .conf) — added explicitly so
        // the panel doesn't grey out a file this app can genuinely open.
        types.append(contentsOf: plainTextExtensions.compactMap {
            UTType(filenameExtension: $0, conformingTo: .plainText)
        })
        // The types the line above cannot reach. Measured with `UTType`, not assumed: macOS hangs
        // each of these off `public.text` and NOT `public.plain-text`, so asking for the extension
        // under `.plainText` hands back a throwaway `dyn.…` that matches no real file — the panel
        // then greys out a document this app opens perfectly well. Name the real types.
        types.append(contentsOf: ["public.yaml", "public.json", "public.xml", "public.toml",
                                  "com.microsoft.ini", "org.w3.webvtt", "public.ndjson",
                                  "com.apple.ips", "com.apple.xcode.strings-text"]
            .compactMap { UTType($0) })
        types.append(contentsOf: officeExtensions.compactMap { UTType(filenameExtension: $0) })
        return types
    }
}

/// What kind of document is open — the fork every render/edit decision is made from.
/// Replaces a bare `isPlainText` boolean, which was really "not markdown": a `.docx` satisfied it,
/// which is exactly what routed office bytes into `PlainTextRenderer` before this existed (see
/// CLAUDE.md invariant list, S4 amendment A).
enum DocumentKind {
    case markdown
    case plainText
    /// Word/ODF/RTF, rendered read-only through `Render/Office`. No `srcRange` is ever emitted for
    /// these (see the S4 audit in the roadmap) — the edit surface is gated shut by kind, not by a
    /// synthetic source range.
    case office
}
