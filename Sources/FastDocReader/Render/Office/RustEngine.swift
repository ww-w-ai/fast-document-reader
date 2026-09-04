import Foundation
import CFastdocEngine

/// The ported Rust engine, as this app calls it.
///
/// This is the reader every build links (S9). The Swift readers beside it are no longer a second
/// shipped path — they are the REFERENCE the tests check this one against, which is the one job
/// they keep.
///
/// Ownership follows the same rule the HWP parser's FFI already established: every string the
/// library returns is freed by the library, so each call here pairs its pointer with a `defer`.
enum RustEngine {
    /// The engine's Markdown extraction for a document, or nil if it could not read it.
    ///
    /// This is the FIRST thing the app asks the Rust side, deliberately: it is the one path already
    /// checked byte-for-byte against this reader across 551 real documents, so a wrong answer here
    /// means the LINK is wrong — the bytes, the encoding, the ownership — and not the engine. A
    /// boundary whose first traffic has an unknown right answer cannot tell those apart.
    /// The `EnvelopeV1`/`ffiVersion` this build understands — `fastdoc_office_tree_json`'s own
    /// doc: "`ffiVersion` versions this envelope; `ok`'s `schemaVersion` … versions the tree — the
    /// two never mean the same thing". Checked defensively: a mismatch reads as "use the other
    /// reader" rather than a document that decoded most of the way.
    static let treeFfiVersion = 1

    /// How many times the engine has PARSED a document's bytes in this process.
    ///
    /// P1: the app read every office document twice — once through `readOffice` for its content,
    /// once through `RustOfficeDocumentHandle` for the queries — and no test could see it, because
    /// both reads produce identical answers. Two reads and one read are indistinguishable by their
    /// results, exactly as invariant 103 says asking and using are; a count is what makes the
    /// second read observable at all.
    ///
    /// Incremented by the two entry points that cause a parse (`fastdoc_read_office_tree` and
    /// `fastdoc_office_open`) and by nothing else — `fastdoc_office_tree_json` borrows a parse
    /// that already happened, which is the whole point of it.
    private(set) static var documentReads = 0

    /// Test seam: `documentReads` is a process-wide total, so a test measures a DELTA across the
    /// work it is judging rather than an absolute that every earlier test has already moved.
    static func countingDocumentReads<T>(_ body: () throws -> T) rethrows -> (value: T, reads: Int) {
        let before = documentReads
        let value = try body()
        return (value, documentReads - before)
    }

    static func noteDocumentRead() { documentReads += 1 }

    /// The document, read by the engine, in this app's own vocabulary.
    ///
    /// Returns nil when the engine could not read it, when it read something it cannot hand over
    /// intact, or when the envelope is a version this build does not know. Every one of those means
    /// the same thing to the caller: use this app's own reader.
    ///
    /// Font substitution is deliberately NOT applied here. It is AppKit's, it belongs to the host,
    /// and `DocumentTypes.readOffice` already applies it once for every reader — so this returns
    /// exactly what a reader returns, at exactly the point a reader returns it.
    /// The engine's own account of the last office read that returned nothing — kept as a VALUE,
    /// for the caller to put in the ONE line it prints.
    ///
    /// It used to be written straight to stderr from down here, the instant a read failed, as
    /// `fastdoc: {"kind":"invalidArchive","location":null,"message":…}`. That is how `--extract`
    /// came to answer a corrupt file with a line of engine JSON above its own sentence, while
    /// `--pdf` — whose host-side zip open fails first and never reaches the engine — answered with
    /// one sentence. Whoever reads stderr is a person or an agent; internals reach them only
    /// because a caller decided to say them, never because a reader printed on the way past.
    struct OfficeReadFailure {
        /// The wire tag (`invalidArchive`, `hwpReadFailed`, …), when the diagnostic was JSON.
        let kind: String?
        /// The engine's human sentence, when it had one.
        let message: String?
        /// Exactly what the engine recorded, for a caller that wants everything.
        let raw: String

        /// One line, for a caller that has to print something. Prefers the engine's own sentence —
        /// which for a bad archive is the archive reader's own words — and falls back to the raw
        /// diagnostic rather than to a sentence nobody measured.
        var sentence: String { message ?? raw }
    }

    /// The last failure, replaced on every failed read and never cleared on success — a caller
    /// reads it only on the `nil` it just received, so a stale value cannot be reported as fresh.
    private(set) static var lastOfficeReadFailure: OfficeReadFailure?

    /// Take the engine's recorded diagnostic (`fastdoc_take_last_error` CONSUMES it, so exactly one
    /// caller may ask) and record it. Decoding is best-effort: an engine that recorded something
    /// this build cannot parse still gets its text through, in `raw`.
    static func recordOfficeReadFailure() {
        guard let diagnostic = fastdoc_take_last_error() else {
            lastOfficeReadFailure = nil
            return
        }
        defer { fastdoc_string_free(diagnostic) }
        let raw = String(cString: diagnostic)
        let decoded = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        lastOfficeReadFailure = OfficeReadFailure(kind: decoded?["kind"] as? String,
                                                  message: decoded?["message"] as? String,
                                                  raw: raw)
    }

    /// U4: records a diagnostic that did NOT come from `fastdoc_take_last_error` — either the tree
    /// envelope's own `error` object (`fastdoc_office_tree_json`'s own doc: "the envelope IS the
    /// diagnostic channel", so this export never touches that slot) or a decode/adapter failure on
    /// the HOST side (`RenderTreeOfficeAdapter` could not honestly build this document's tree). The
    /// setter stays here — `lastOfficeReadFailure` is `private(set)`, and Swift's `private` is
    /// file-scoped, so only this file may write it — but the caller is the tree path, in
    /// `RenderTreeOfficeAdapter.swift`.
    static func recordOfficeTreeFailure(kind: String?, message: String, raw: String? = nil) {
        lastOfficeReadFailure = OfficeReadFailure(kind: kind, message: message, raw: raw ?? message)
    }

    static func readOffice(_ data: Data, extension ext: String) -> OfficeReadResult? {
        #if DEBUG
        if DocumentEngineTrace.currentEntryPoint == "bridge-tree" {
            do {
                try DocumentEngineTrace.record(
                    fileClass: ext == "odt" ? "odt" : "docx", extension: ext,
                    engine: "rust", seam: "M-RUST-BRIDGE-TREE")
            } catch { return nil }
        }
        #endif
        RustEngineFonts.install()
        noteDocumentRead()
        // `EnvelopeV1` is the only contract a host reads (decision 2 of the cutover plan).
        let json: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { extensionC in
                fastdoc_read_office_tree(base, raw.count, extensionC)
            }
        }
        guard let json else {
            recordOfficeReadFailure()
            return nil
        }
        defer { fastdoc_string_free(json) }
        return decodeOfficeTree(json)
    }

    /// U4: `EnvelopeV1` turned into this app's vocabulary through `RenderTreeOfficeAdapter` — the
    /// tree twin of `decodeOffice` below, crossed by BOTH doors that read one
    /// (`readOffice` above, `RustOfficeDocumentHandle.officeContent`), so a version check and a
    /// decode failure are handled once, not twice.
    ///
    /// Invariant 115's fallback is unchanged by the cutover: a failure at ANY stage here — the FFI
    /// call itself, the envelope's own `error`, or the adapter's own refusal — returns `nil` exactly
    /// as a schema-v5 decode failure always has, and the caller falls back exactly as before (there
    /// is no second Swift-native reader in production any more — see this app's own "Architecture
    /// authority" — so "falls back" means "the read fails and the caller reports it", not a second
    /// engine).
    static func decodeOfficeTree(_ json: UnsafeMutablePointer<CChar>) -> OfficeReadResult? {
        let bytes = Data(bytesNoCopy: json, count: strlen(json), deallocator: .none)
        let envelope: WireTreeEnvelope
        do {
            envelope = try JSONDecoder().decode(WireTreeEnvelope.self, from: bytes)
        } catch {
            let text = "the tree envelope did not decode: \(error)"
            recordOfficeTreeFailure(kind: "envelopeDecodeFailed", message: text)
            return nil
        }
        guard envelope.ffiVersion == treeFfiVersion else { return nil }
        if let failure = envelope.error {
            // `fastdoc_office_tree_json`'s own doc: "the envelope IS the diagnostic channel" — this
            // is a genuine per-document refusal the engine reported, not a host-side decode bug, so
            // it is recorded with the engine's own kind/message. `raw` is the WHOLE envelope's own
            // JSON text (matching `recordOfficeReadFailure`'s contract that `raw` is a JSON blob a
            // log can keep, and `sentence` — `message` here — is the one prose line a caller
            // prints; `EngineDiagnosticSurfaceTests` is what pins this apart).
            let rawText = String(data: bytes, encoding: .utf8) ?? failure.message
            recordOfficeTreeFailure(kind: failure.kind, message: failure.message, raw: rawText)
            return nil
        }
        guard let tree = envelope.ok else { return nil }
        do {
            return try RenderTreeOfficeAdapter.project(tree)
        } catch let error as RenderTreeAdapterError {
            recordOfficeTreeFailure(kind: "treeAdapterFailed", message: error.detail)
            return nil
        } catch {
            recordOfficeTreeFailure(kind: "treeAdapterFailed", message: "\(error)")
            return nil
        }
    }

    static func extractMarkdown(_ data: Data, extension ext: String) -> String? {
        #if DEBUG
        if DocumentEngineTrace.currentEntryPoint == "bridge-markdown" {
            do {
                try DocumentEngineTrace.record(
                    fileClass: ext == "odt" ? "odt" : "docx", extension: ext,
                    engine: "rust", seam: "M-RUST-BRIDGE-MARKDOWN")
            } catch { return nil }
        }
        #endif
        RustEngineFonts.install()
        let result: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { extensionC in
                fastdoc_extract_markdown(base, raw.count, extensionC)
            }
        }
        guard let result else { return nil }
        defer { fastdoc_string_free(result) }
        return String(cString: result)
    }
}
