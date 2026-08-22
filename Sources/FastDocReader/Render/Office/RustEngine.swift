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
    static func extractMarkdown(_ data: Data, extension ext: String) -> String? {
        let result: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw in
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
