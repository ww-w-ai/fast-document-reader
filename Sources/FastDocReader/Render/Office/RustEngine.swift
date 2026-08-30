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
    /// What the engine's envelope is, and what this build knows how to read.
    ///
    /// Checked before anything else. The engine ships as a prebuilt library, so a stale one is a
    /// real state to be in — and a version mismatch has to read as "use the other reader", not as
    /// a document that decoded most of the way.
    static let schemaVersion = 5

    /// How many times the engine has PARSED a document's bytes in this process.
    ///
    /// P1: the app read every office document twice — once through `readOffice` for its content,
    /// once through `RustOfficeDocumentHandle` for the queries — and no test could see it, because
    /// both reads produce identical answers. Two reads and one read are indistinguishable by their
    /// results, exactly as invariant 103 says asking and using are; a count is what makes the
    /// second read observable at all.
    ///
    /// Incremented by the two entry points that cause a parse (`fastdoc_read_office_json` and
    /// `fastdoc_office_open`) and by nothing else — `fastdoc_office_content_json` borrows a parse
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
        let json: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { extensionC in
                fastdoc_read_office_json(base, raw.count, extensionC)
            }
        }
        guard let json else {
            recordOfficeReadFailure()
            return nil
        }
        defer { fastdoc_string_free(json) }
        return decodeOffice(json)
    }

    /// The engine's JSON turned into this app's vocabulary — the half of `readOffice` that has
    /// nothing to do with reading.
    ///
    /// Split out so the export a handle serves (`fastdoc_office_content_json`) crosses the SAME
    /// decoder, version check and vector-painting pass. Two decoders for one wire format is the
    /// shape that drifts (this file's own `unifyTerminator` lesson, one layer up).
    static func decodeOffice(_ json: UnsafeMutablePointer<CChar>) -> OfficeReadResult? {
        let bytes = Data(bytesNoCopy: json, count: strlen(json), deallocator: .none)
        let decoder = JSONDecoder()
        // The engine names fields the way Rust does. This is what saves every type in the
        // vocabulary from repeating its own field names a second time just to be decoded.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let envelope = try decoder.decode(Envelope.self, from: bytes)
            guard envelope.v == schemaVersion else { return nil }
            var result = envelope.result
            for (id, graphic) in result.vectorGraphics {
                guard let pdf = HwpShapeRenderer.pdf(paths: graphic.paths, size: graphic.size) else {
                    FileHandle.standardError.write(
                        Data("fastdoc: host could not paint vector \(id) at \(graphic.size)\n".utf8)
                    )
                    return nil
                }
                result.images[id] = pdf
            }
            result.vectorGraphics.removeAll(keepingCapacity: false)
            return result
        } catch {
            // The host cannot RECOVER from a decode failure — there is no second reader behind this
            // one any more — but it must not hide one either. A silent nil here reads exactly like
            // "the engine could not parse the document", and the two have completely different
            // causes: one is a document the engine cannot read, the other is a field the two sides
            // spell differently. Saying which is the difference between a five-minute fix and an
            // afternoon. It goes into the same slot every other failure here uses, so the caller
            // that received the `nil` says it once in its own sentence — it used to write itself to
            // stderr on the way past, which is the habit `OfficeReadFailure` exists to end.
            let text = "the engine's JSON did not decode: \(error)"
            lastOfficeReadFailure = OfficeReadFailure(kind: "envelopeDecodeFailed",
                                                      message: text, raw: text)
            return nil
        }
    }

    private struct Envelope: Decodable {
        let v: Int
        let result: OfficeReadResult
        init(from decoder: Decoder) throws {
            // The version and the document share one object — the engine flattens the result into
            // the envelope so a host reads one thing, not a wrapper around a thing.
            let container = try decoder.container(keyedBy: VersionKey.self)
            v = try container.decode(Int.self, forKey: .v)
            // The picture pool is read BEFORE the body, so every `WireImage` the body contains can
            // resolve its key as it decodes (`PictureBytes`). Order costs nothing here: JSONDecoder
            // parses the whole document first and materializes on demand, so asking for one key
            // early is a lookup, not a second pass.
            let pool = try container.decodeIfPresent([String: Data].self, forKey: .picturePool) ?? [:]
            // The edge-border table rides in on the same rule, for the same reason (P4b).
            let edges = try container.decodeIfPresent([EdgeBorders].self, forKey: .edgeBorderPool) ?? []
            // The paragraph-format table rides in on the same rule, for the same reason, and turned
            // out to carry twice the occurrences the borders did.
            let formats = try container.decodeIfPresent([ParagraphFormat].self,
                                                        forKey: .paragraphFormatPool) ?? []
            result = try PictureBytes.withPool(pool) {
                try EdgeBorderTable.withPool(edges) {
                    try ParagraphFormatTable.withPool(formats) { try OfficeReadResult(from: decoder) }
                }
            }
        }
        private enum VersionKey: String, CodingKey {
            case v, picturePool, edgeBorderPool, paragraphFormatPool
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
