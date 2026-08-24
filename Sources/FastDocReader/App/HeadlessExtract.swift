import Foundation

/// The `--extract` headless path: `FastDocReader --extract <file>` prints the document as Markdown
/// to stdout and exits, WITHOUT ever starting `NSApplication` (so no window, no Dock icon). Its whole
/// reason to exist: an AI agent reading a `.docx`/`.odt` directly spends a lot of tokens parsing the
/// zip+XML, while this reuses the app's OWN office reader (the same bytes the reader renders) and
/// hands back clean Markdown. `.md`/`.txt` pass through verbatim (already cheap) so one command
/// works on anything the app opens.
///
/// Exit codes: 0 success · 1 read/parse failure · 2 usage error. Errors go to stderr, never stdout,
/// so a caller can trust stdout to be only the document.
enum HeadlessExtract {

    static func run(_ args: [String]) -> Int32 {
        guard args.count == 1, let path = args.first, !path.hasPrefix("-") else {
            err("usage: FastDocReader --extract <file>\n" +
                "  Prints the document as Markdown to stdout.\n" +
                "  Supported: .docx .docm .dotx .dotm .odt .hwp .hwpx (converted) · .md .txt (verbatim).")
            return 2
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let ext = url.pathExtension.lowercased()

        guard DocumentTypes.opensInApp(ext) else {
            err("unsupported file type \".\(ext)\": FastDoc reads .docx/.docm/.dotx/.dotm, " +
                ".odt, .hwp/.hwpx, and plain text/Markdown. Legacy binary .doc and .rtf are not supported.")
            return 1
        }

        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            // A sandboxed build is denied a path handed in on the command line, and the denial
            // reads as an ordinary file error — so say what actually has to happen (FolderAccess).
            err(FolderAccess.annotatingHeadlessDenial(
                "cannot read \(url.lastPathComponent): \(error.localizedDescription)"))
            return 1
        }

        switch DocumentTypes.kind(forExtension: ext) {
        case .markdown, .plainText:
            // Already text — emit verbatim, decoded in whatever encoding the file actually is
            // (invariant 18's detector), so a CP949/UTF-16 file isn't turned into a wall of "?".
            out(TextEncodingDetector.decode(data).text)
            return 0

        case .office:
            do {
                // HWP/HWPX take raw `Data` (not a `ZipArchive` — a `.hwp` is CFB binary), so branch to
                // `HwpReader.read` before `ZipArchive(data:)`, then feed the SAME serializer the zip
                // office path uses (invariant 40 — one block vocabulary → Markdown). Only the reader
                // differs; the serializer is shared.
                #if FMD_RUST_ENGINE
                // The ported engine answers BOTH families here, HWP included, and nothing catches
                // it if it cannot. Its own dispatch branches on the extension before opening an
                // archive, for the same reason this code used to: a `.hwp` is CFB binary and would
                // fail as a zip. Letting HWP keep falling back to `HwpReader` would have left the
                // larger half of this corpus untested while the totals still read as green.
                guard let result = RustEngine.readOffice(data, extension: ext) else {
                    throw NSError(domain: "ai.ww-w.fast-md-reader", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "The document engine could not read this \(ext.uppercased()) file.",
                    ])
                }
                #else
                let result = try DocumentTypes.isHwp(ext)
                    ? HwpReader.read(data)
                    : DocumentTypes.readOffice(try ZipArchive(data: data), extension: ext)
                #endif
                let body = OfficeMarkdownSerializer.serialize(result.blocks, footnotes: result.footnotes)
                out(header(for: url.lastPathComponent, body: body) + body)
                return 0
            } catch {
                err("cannot extract \(url.lastPathComponent): \(error.localizedDescription)")
                return 1
            }
        }
    }

    /// A short HTML-comment legend at the very top (invisible to a Markdown renderer, visible to an
    /// agent reading the raw text) — the "note at the front" the owner asked for. The `<raw>` line is
    /// added only when the body actually used the marker.
    private static func header(for filename: String, body: String) -> String {
        var note = "<!-- Extracted from \(filename) by FastDoc. Best-effort Markdown. -->\n"
        if body.contains(OfficeMarkdownSerializer.rawOpen) {
            note += "<!-- \(OfficeMarkdownSerializer.rawOpen)…\(OfficeMarkdownSerializer.rawClose)" +
                    " marks content whose original structure (e.g. merged-cell tables) could not be " +
                    "safely mapped; treat the text inside as literal. -->\n"
        }
        return note + "\n"
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
