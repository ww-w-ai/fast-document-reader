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
    fileprivate(set) static var lastFailure: String?

    /// Begin a progressive render on the engine, or `nil` if it could not start one.
    ///
    /// The handle is what makes this different from calling `render` repeatedly: it keeps the
    /// engine's builder alive between pieces, which is what lets block ids keep counting up across
    /// them and each piece's source offsets continue where the last stopped. A stateless "render
    /// blocks N..M" call would restart both every time, and two neighbouring blocks sharing an id
    /// read as ONE stop for the reading cursor (invariant 19).
    static func renderProgressive(_ source: String, theme: RenderTheme) -> ProgressiveMarkdownRendering? {
        RustEngineFonts.install()
        let bytes = Array(source.utf8)
        let handle: OpaquePointer? = bytes.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 0x1)!
            return fastdoc_markdown_progressive_open(base, buffer.count, Double(theme.baseFontSize))
        }
        guard let handle else {
            recordEngineFailure()
            return nil
        }
        return EngineProgressiveRender(handle: handle, theme: theme, blocks: countTopLevelBlocks(source))
    }

    /// The engine's progressive render, or this app's own if the engine could not start one.
    static func renderProgressiveOrHost(_ source: String, theme: RenderTheme) -> ProgressiveMarkdownRendering {
        renderProgressive(source, theme: theme)
            ?? MarkdownRenderer.renderProgressive(source, theme: theme)
    }

    /// How many top-level blocks the document has, which the caller needs BEFORE the first piece
    /// to size its turns. The engine knows it, but reporting it would mean a fifth export for a
    /// number this app can also get by parsing — and it already has a parser, used for exactly
    /// this in `MarkdownRenderer.parseForProbe`.
    private static func countTopLevelBlocks(_ source: String) -> Int {
        MarkdownRenderer.parseForProbe(source)
    }

    /// Record whatever the engine put in its thread-local error slot. `fastdoc_take_last_error`
    /// CONSUMES it, so exactly one caller may ask — this is that caller for the handle exports,
    /// which report failure by returning NULL rather than by handing back an error envelope.
    private static func recordEngineFailure() {
        guard let diagnostic = fastdoc_take_last_error() else {
            lastFailure = "the engine refused the document and recorded no reason"
            return
        }
        defer { fastdoc_string_free(diagnostic) }
        lastFailure = String(cString: diagnostic)
    }

    /// The engine's progressive render, as the document layer sees it.
    ///
    /// Owns the handle: `deinit` closes it exactly once. That is why this is a class and why the
    /// close lives here rather than in a `defer` at a call site — a reload replaces the object,
    /// and replacing it is what closes the old one, so a handle can be neither stranded nor
    /// double-freed.
    private final class EngineProgressiveRender: ProgressiveMarkdownRendering {
        private let handle: OpaquePointer
        private let theme: RenderTheme
        private var handedOut = 0
        private var visited = 0
        private let blocks: Int

        init(handle: OpaquePointer, theme: RenderTheme, blocks: Int) {
            self.handle = handle
            self.theme = theme
            self.blocks = blocks
        }

        deinit {
            fastdoc_markdown_progressive_close(handle)
        }

        var isFinished: Bool {
            fastdoc_markdown_progressive_is_finished(handle) == 1
        }

        var remainingBlocks: Int { max(0, blocks - visited) }
        var chunksHandedOut: Int { handedOut }

        func nextChunk(blocks: Int) -> NSAttributedString {
            handedOut += 1
            visited += max(1, blocks)
            guard let envelope = fastdoc_markdown_progressive_next(handle, max(1, blocks)) else {
                return NSAttributedString()
            }
            defer { fastdoc_string_free(envelope) }
            do {
                let wire = try decode(Data(bytes: envelope, count: strlen(envelope)))
                let piece = try MarkdownWireMaterializer.attributedString(wire, theme: theme)
                return piece
            } catch {
                // A piece that cannot be read is empty rather than wrong. The document keeps the
                // text it already has and the loop still terminates, because `isFinished` is the
                // ENGINE's answer and the engine advanced whether or not the wire decoded.
                lastFailure = "\(error)"
                return NSAttributedString()
            }
        }
    }

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

    fileprivate enum EnvelopeFailure: Error, CustomStringConvertible {
        case engine(String)
        var description: String { if case .engine(let text) = self { return text }; return "" }
    }

    /// `{"ffiVersion":1,"ok":<wire>}` or `{"ffiVersion":1,"error":{…}}` — the same envelope every
    /// other export uses, so a caller that parses one recognises the other.
    fileprivate static func decode(_ data: Data) throws -> MarkdownWire {
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
