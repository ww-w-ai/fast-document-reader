import Foundation
import UniformTypeIdentifiers
import CoreGraphics

/// The shape a REFERENCE office reader has: `DocxReader` and `OdtReader` both conform.
///
/// Nothing in the app calls one. The engine reads every office document (`readOffice` below), and
/// these readers are the oracle its answers are checked against — which is the one job they keep
/// (S9). This protocol stays in the app target because it names that contract, not because the app
/// reaches through it; `RustEngineBridgeTests` fails the build's own suite if a production source
/// file ever names one of the readers again.
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
    /// Unlisted Markdown aliases open as plain text through the general fallback.
    static let markdownExtensions = ["md", "markdown"]

    /// Extensions included in automatic claims and internal link handling. Explicit opens
    /// also accept other filenames through the public.data fallback.
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
    /// macros are never executed, just never even looked at. They are zip-backed, like `.docx`.
    static let officeExtensions = ["docx", "docm", "dotx", "dotm", "odt"] + hwpExtensions

    /// Hangul Word Processor, read-only through the engine's own HWP path (rhwp). Kept SEPARATE from
    /// `zipBackedOfficeExtensions` because HWP does NOT take a `ZipArchive`: an `.hwpx` is a
    /// zip but an `.hwp` is CFB binary, and rhwp parses BOTH from raw `Data` itself — so HWP must
    /// branch BEFORE `ZipArchive(data:)` (see `MarkdownDocument.read(from:)` and `HeadlessExtract`).
    /// These are folded into `officeExtensions` above so `kind`, `opensInApp` and the open panel all
    /// treat them as office documents (`.office` kind → Viewer/read-only, invariant 22); the branch in
    /// `read(from:)` plus THIS list are the single dispatch for HWP (invariant 29 — no second switch).
    static let hwpExtensions = ["hwp", "hwpx"]

    /// True for `.hwp`/`.hwpx` — the one predicate every read path checks to route to the raw-`Data`
    /// HWP branch instead of the zip pipeline. Kept here so the string list lives in ONE place.
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

    /// The office extensions that arrive as a ZIP ARCHIVE, and are therefore the ones `readOffice`
    /// below is willing to be handed.
    ///
    /// This used to be a switch returning the Swift reader that owned each extension. It answers a
    /// smaller question now, because the app no longer picks a reader at all: the engine reads every
    /// office document and takes the extension itself, so what is left to decide is only whether the
    /// extension is one this app claims — which is a different failure, with a different message,
    /// than "the engine could not read it".
    ///
    /// hwp/hwpx are DELIBERATELY absent: an `.hwpx` is a zip but an `.hwp` is CFB binary, and both
    /// are parsed from raw `Data`, so HWP branches BEFORE `ZipArchive(data:)` (see `isHwp`) and can
    /// never reach here. Their absence means `readOffice` throws if one ever wrongly did — a safety
    /// net, not the path.
    private static let zipBackedOfficeExtensions: Set<String> = ["docx", "docm", "dotx", "dotm", "odt"]

    /// Where a caller that will keep asking this document questions receives the handle its read
    /// already opened.
    ///
    /// P1: reading a document and opening a handle to it are the SAME parse, and the app was
    /// paying for both — `read(from:)` called the export, then `setOfficeContent` opened a handle
    /// on the same bytes, 565 ms thrown away on a 10.7 MB HWP. Passing one of these says "I am the
    /// caller that will ask again, hand me what you opened."
    ///
    /// `nil` — the default, and every existing caller — is the one-question caller: the tests, the
    /// reference comparisons, `--extract`, `--pdf`. Those take the export path unchanged, so
    /// nothing about a headless read moves, including which process-global ports get installed.
    final class OfficeHandleBox {
        var handle: RustOfficeDocumentHandle?
        init() {}
    }

    static func readOffice(
        _ archive: ZipArchive, extension ext: String, keepingHandleIn box: OfficeHandleBox? = nil
    ) throws -> OfficeReadResult {
        // A REGISTRATION check, not a dispatch: the engine reads every office format and takes the
        // extension itself. What this still answers is whether the extension is one this app claims
        // at all, which is a different failure with a different message than "the engine could not
        // read it" — and `zipBackedOfficeExtensions` is where that list lives.
        guard zipBackedOfficeExtensions.contains(ext.lowercased()) else {
            throw NSError(domain: "ai.ww-w.fast-md-reader", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\".\(ext)\" is registered as an office format but has no reader.",
            ])
        }
        // The engine reads the document, and NOTHING catches it if it cannot.
        //
        // It used to fall through to the Swift reader, which made the app robust and the port
        // unmeasurable: an engine that failed on every document would have looked exactly like one
        // that worked, and the Swift readers are not going to exist on Windows or Android to catch
        // anything there. The engine has to stand on its own here for standing on its own elsewhere
        // to mean something.
        //
        // The Swift readers are still in the tree and still under test — as the REFERENCE the
        // engine is checked against, which is the one job they keep.
        //
        // Font substitution stays below, applied once to whatever produced the blocks: it is
        // AppKit's, it is the host's, and it is what keeps invariant 29's single funnel single.
        #if DEBUG
        try DocumentEngineTrace.record(
            fileClass: ext.lowercased() == "odt" ? "odt" : "docx",
            extension: ext, engine: "rust", seam: "M-ZIP-RUST-DISPATCH")
        #endif
        let ported: OfficeReadResult?
        if let box {
            // One parse, two consumers: the handle IS the read, and the content borrows it.
            let opened = RustOfficeDocumentHandle(data: archive.sourceBytes, extension: ext)
            box.handle = opened
            ported = opened?.officeContent(bytes: archive.sourceBytes)
        } else {
            ported = RustEngine.readOffice(archive.sourceBytes, extension: ext)
        }
        guard let ported else {
            throw NSError(domain: "ai.ww-w.fast-md-reader", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The document engine could not read this \(ext.uppercased()) file.",
            ])
        }
        return ported.resolvingFontSubstitution()
    }


    /// Content types for the Open panel's filter.
    static var openPanelTypes: [UTType] {
        var types: [UTType] = [.data]
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
