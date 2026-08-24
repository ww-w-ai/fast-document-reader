#if FMD_RUST_ENGINE
import Foundation
import CFastdocEngine

/// The ported Rust engine, as this app calls it.
///
/// Compiled ONLY into a build that asked for it (`FMD_RUST_ENGINE=1`, see `Package.swift`). The
/// shipped app does not contain this file's code, which is what lets the two readers coexist while
/// the ported one is still being checked against the one that ships.
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
    static let schemaVersion = 1

    /// The document, read by the engine, in this app's own vocabulary.
    ///
    /// Returns nil when the engine could not read it, when it read something it cannot hand over
    /// intact, or when the envelope is a version this build does not know. Every one of those means
    /// the same thing to the caller: use this app's own reader.
    ///
    /// Font substitution is deliberately NOT applied here. It is AppKit's, it belongs to the host,
    /// and `DocumentTypes.readOffice` already applies it once for every reader — so this returns
    /// exactly what a reader returns, at exactly the point a reader returns it.
    static func readOffice(_ data: Data, extension ext: String) -> OfficeReadResult? {
        RustEngineFonts.install()
        let json: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { extensionC in
                fastdoc_read_office_json(base, raw.count, extensionC)
            }
        }
        guard let json else { return nil }
        defer { fastdoc_string_free(json) }

        let bytes = Data(bytesNoCopy: json, count: strlen(json), deallocator: .none)
        let decoder = JSONDecoder()
        // The engine names fields the way Rust does. This is what saves every type in the
        // vocabulary from repeating its own field names a second time just to be decoded.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let envelope = try decoder.decode(Envelope.self, from: bytes)
            guard envelope.v == schemaVersion else { return nil }
            return envelope.result
        } catch {
            // The host cannot RECOVER from a decode failure — there is no second reader behind this
            // one any more — but it must not hide one either. A silent nil here reads exactly like
            // "the engine could not parse the document", and the two have completely different
            // causes: one is a document the engine cannot read, the other is a field the two sides
            // spell differently. Saying which is the difference between a five-minute fix and an
            // afternoon. This is stderr rather than a thrown error because the callers all take an
            // Optional, and widening them to `throws` is a change this diagnostic does not need.
            FileHandle.standardError.write(Data("fastdoc: engine JSON did not decode: \(error)\n".utf8))
            return nil
        }
    }

    private struct Envelope: Decodable {
        let v: Int
        let result: OfficeReadResult
        init(from decoder: Decoder) throws {
            // The version and the document share one object — the engine flattens the result into
            // the envelope so a host reads one thing, not a wrapper around a thing.
            v = try decoder.container(keyedBy: VersionKey.self).decode(Int.self, forKey: .v)
            result = try OfficeReadResult(from: decoder)
        }
        private enum VersionKey: String, CodingKey { case v }
    }

    /// The document's own default body run size in points — the other half of the typography's
    /// font-size model, which a zip-backed read result does not carry.
    ///
    /// Returns nil only when the engine could not be asked at all; the engine itself answers 11 for
    /// a document that declares nothing, which is what this reader's own fallback answered.
    static func officeDefaultBodyFontSize(_ data: Data, extension ext: String) -> CGFloat? {
        RustEngineFonts.install()
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw -> CGFloat? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { CGFloat(fastdoc_office_default_body_font_size(base, raw.count, $0)) }
        }
    }

    static func extractMarkdown(_ data: Data, extension ext: String) -> String? {
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
#endif
