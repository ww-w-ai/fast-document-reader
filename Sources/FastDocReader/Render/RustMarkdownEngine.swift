import Foundation
import AppKit
import CFastdocEngine

/// Markdown, rendered by the engine.
///
/// Markdown is the format this app is named for and was the last one the host still built
/// entirely by itself. It is also the one where the engine has the most to win: measured on this
/// machine, 86% of a markdown read is the TYPOGRAPHY build and only 14% is the parse — which is
/// why this crosses a finished attributed string (`MarkdownWire`) rather than the structure tree
/// `fastdoc_read_text_tree` already exported and nothing consumed.
///
/// The `nil` return is a real, expected state, not a defect to be logged and forgotten: the engine
/// ships as a prebuilt library, so a stale one, a wire version this build does not replay, or a
/// document the engine refuses all mean "use `MarkdownRenderer`". The caller falls back; the
/// reader still opens the file.
enum RustMarkdownEngine {

    /// The last failure, replaced on every failed render and never cleared on success — a caller
    /// reads it only on the `nil` it just received, so a stale value cannot be reported as fresh.
    private(set) static var lastFailure: String?

    /// The engine's render, falling back to this app's own renderer if the engine could not
    /// produce one — which is what every call site in the reader uses.
    ///
    /// The fallback is not defensive padding. The engine ships as a PREBUILT library, so "the
    /// installed engine is older than this app" is a real state, and the honest response to it is
    /// to open the document rather than to refuse it. `MarkdownRenderer` stays in the build for
    /// exactly that, and as the reference `MarkdownEngineParityTests` measures against.
    static func renderOrHost(_ source: String, theme: RenderTheme) -> NSAttributedString {
        render(source, theme: theme) ?? MarkdownRenderer.render(source, theme: theme)
    }

    /// Render `source` through the engine, or `nil` if it could not.
    static func render(_ source: String, theme: RenderTheme) -> NSAttributedString? {
        // The engine resolves fonts through THIS process's AppKit (invariant 52's per-script
        // slots are the host's answer, not a table in the engine), so the provider must be
        // installed before a render, exactly as `RustEngine.readOffice` does before a read.
        RustEngineFonts.install()

        let bytes = Array(source.utf8)
        let envelope: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBufferPointer { buffer in
            // An empty document has no base address; the engine's NULL guard would refuse it, and
            // an empty file is a document a reader must be able to open.
            let base = buffer.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 0x1)!
            return fastdoc_render_markdown(base, buffer.count, Double(theme.baseFontSize))
        }
        guard let envelope else {
            lastFailure = "the engine could not build an envelope at all"
            return nil
        }
        defer { fastdoc_string_free(envelope) }

        do {
            let wire = try decode(Data(bytes: envelope, count: strlen(envelope)))
            let string = try MarkdownWireMaterializer.attributedString(wire, theme: theme)
            lastFailure = nil
            return string
        } catch {
            lastFailure = "\(error)"
            return nil
        }
    }

    private enum EnvelopeFailure: Error, CustomStringConvertible {
        case engine(String)
        var description: String { if case .engine(let text) = self { return text }; return "" }
    }

    /// `{"ffiVersion":1,"ok":<wire>}` or `{"ffiVersion":1,"error":{…}}` — the same envelope every
    /// other export uses, so a caller that parses one recognises the other.
    private static func decode(_ data: Data) throws -> MarkdownWire {
        struct Envelope: Decodable {
            struct EngineError: Decodable { var kind: String?; var message: String? }
            var ok: MarkdownWire?
            var error: EngineError?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if let ok = envelope.ok { return ok }
        let failure = envelope.error
        throw EnvelopeFailure.engine(
            "\(failure?.kind ?? "unknown"): \(failure?.message ?? "the engine refused the document")")
    }
}
