#if FMD_RUST_ENGINE
import Foundation

/// The typed decode target for the new-shape Rust export's wire envelope.
///
/// The envelope is one of exactly two shapes, both carrying `ffiVersion` — the ENVELOPE's own
/// version, checked before anything inside is trusted — separately from `schemaVersion`, which
/// versions the canonical TREE nested inside `ok`. The two numbers were already confused once
/// while this contract was being drafted, so they are kept apart here on purpose: different names,
/// different types, decoded by different code paths. Nothing here calls into the Rust library —
/// this file only knows how to read the bytes such a call would hand back.
///
/// Full typing of the tree itself is S6's job. `RustCanonicalOk` lifts only `schemaVersion` (the
/// one field a caller needs before it can decide whether it can read the rest at all) and keeps the
/// remainder as the tree's own JSON object.
enum RustCanonicalEnvelope: Equatable {
    case ok(RustCanonicalOk)
    case error(RustCanonicalError)
}

/// The successful half of the envelope.
struct RustCanonicalOk: Equatable {
    /// The canonical tree's own version — distinct from the envelope's `ffiVersion` above it.
    let schemaVersion: Int
    /// The `ok` object re-encoded as its own JSON buffer, for whichever later stage decodes the
    /// tree proper. It is semantically equal to what the engine sent, NOT byte-identical: Foundation
    /// cannot hand back a sub-range of the buffer it parsed, and this sprint deliberately does not
    /// add a second JSON scanner to get one. Byte fidelity is asserted where it can be — on the Rust
    /// side, against `ValidatedRenderTree::encode_json()`.
    let okObjectBytes: Data
}

/// The failure half of the envelope.
struct RustCanonicalError: Equatable {
    /// The stable tags this build already knows how to branch on. These MIRROR `FfiErrorKind::tag`
    /// in `rust/crates/fastdoc-ffi/src/ffi_guard.rs`; a Rust test freezes that list so adding a tag
    /// there fails until this one is updated too. Not exhaustive on purpose: the
    /// wire's `kind` string is kept verbatim in `RustCanonicalError.kind` regardless of whether it
    /// matches one of these, so a future tag this build has never seen still decodes cleanly.
    enum KnownKind: String {
        case invalidArgument
        case invalidArchive
        case unsupportedExtension
        case hwpReadFailed
        case readerFailed
        case exportFailed
        case interiorNul
        case panic
        case hostFontProviderMissing
    }

    /// The wire's `kind` string, verbatim — never dropped or rejected for being unrecognised.
    let kind: String
    /// `kind` mapped to a switchable case when this build recognises it, `nil` otherwise.
    var known: KnownKind? { KnownKind(rawValue: kind) }
    let message: String
    let location: String
}

/// Failures the envelope decode itself can raise, before either half is reached.
enum RustCanonicalEnvelopeError: Error, Equatable {
    /// `ffiVersion` named a version this build does not understand. Thrown before `ok`/`error` is
    /// even inspected — an envelope version we cannot interpret is not trusted to mean what we
    /// think even where its `ok` payload happens to parse cleanly.
    case unknownFfiVersion(Int)
    /// The envelope parsed but had neither `ok` nor `error` — not a shape the wire contract allows.
    case malformed(String)
}

extension RustCanonicalEnvelope {
    /// The one `ffiVersion` this build accepts. A mismatch here fails the WHOLE decode; nothing
    /// past this field is ever read for an envelope version this build does not know.
    static let supportedFfiVersion = 1

    private struct Header: Decodable {
        let ffiVersion: Int
    }

    private struct OkHeader: Decodable {
        let schemaVersion: Int
    }

    private struct ErrorPayload: Decodable {
        let kind: String
        let message: String
        let location: String
    }

    private struct Full: Decodable {
        let ffiVersion: Int
        let ok: OkHeader?
        let error: ErrorPayload?
    }

    /// Decodes one caller-owned JSON buffer from the Rust side into a typed envelope.
    ///
    /// `ffiVersion` is checked before `ok`/`error` is looked at, and an unknown version throws
    /// rather than returning a partially-decoded value — the acceptance condition this type exists
    /// to satisfy.
    static func decode(_ json: Data) throws -> RustCanonicalEnvelope {
        let header = try JSONDecoder().decode(Header.self, from: json)
        guard header.ffiVersion == supportedFfiVersion else {
            throw RustCanonicalEnvelopeError.unknownFfiVersion(header.ffiVersion)
        }

        let full = try JSONDecoder().decode(Full.self, from: json)
        if let ok = full.ok {
            return .ok(RustCanonicalOk(schemaVersion: ok.schemaVersion, okObjectBytes: try okObjectBytes(json)))
        }
        if let error = full.error {
            return .error(RustCanonicalError(kind: error.kind, message: error.message, location: error.location))
        }
        throw RustCanonicalEnvelopeError.malformed("envelope has neither \"ok\" nor \"error\"")
    }

    /// Re-encodes just the `ok` object into its own buffer, so a later stage can decode the
    /// canonical tree without this type having interpreted it.
    private static func okObjectBytes(_ json: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let ok = object["ok"]
        else {
            throw RustCanonicalEnvelopeError.malformed("\"ok\" was not a JSON object")
        }
        return try JSONSerialization.data(withJSONObject: ok)
    }
}
#endif
