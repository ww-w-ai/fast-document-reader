import XCTest
import CFastdocEngine
@testable import FastDocReader

/// P3 — what the HOST pays to take delivery of a document, separated from what the ENGINE pays to
/// read it.
///
/// Until now the Swift side of `RustEngine.readOffice` was known only by subtraction: the whole
/// call minus the engine's own `--extract` time, which came out "about 400 ms" and carried every
/// error in both measurements. That number is the entire case for P4 (a flat binary wire, or
/// pulling only the range on screen), so it cannot stay an estimate — a wire format is a large,
/// hard-to-reverse change to make on a subtraction.
///
/// This probe times the two halves separately on ONE real document:
///
///   1. `fastdoc_read_office_json` — parse, map, project, serialize. All of it inside Rust.
///   2. `RustEngine.decodeOffice` — `JSONDecoder` over the payload, plus the vector-painting pass
///      that turns declared paths into PDFs and folds them into the image map.
///
/// and prints a third number the first two do not contain: `JSONSerialization` over the SAME bytes.
/// That is the floor for parsing this payload at all in this process — the part no amount of
/// decoder tuning removes. The gap between it and `decodeOffice` is what `Decodable` costs on top,
/// and the two lead to different repairs. Only one of them is an argument for a new wire format.
///
/// Deliberately measurement-only, and asserts nothing about time (invariant 113 — a wall clock is
/// not a gate on this machine). It asserts only that it measured something: a null payload or a
/// failed decode fails the probe rather than reporting a fast zero (invariant 30).
///
///     FMD_TRANSPORT_COST_FILE=<document> swift test --filter OfficeTransportCostTests
final class OfficeTransportCostTests: XCTestCase {
    func testWhereTheTimeGoesBetweenTheEngineAndTheHost() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_TRANSPORT_COST_FILE"] else {
            throw XCTSkip("set FMD_TRANSPORT_COST_FILE to a .docx/.odt/.hwp/.hwpx")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        RustEngineFonts.install()

        let engineStart = Date()
        let json: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ext.withCString { fastdoc_read_office_json(base, raw.count, $0) }
        }
        let engineMs = Date().timeIntervalSince(engineStart) * 1000
        let payload = try XCTUnwrap(json, "the engine refused \(url.lastPathComponent)")
        defer { fastdoc_string_free(payload) }
        let payloadBytes = strlen(payload)

        let decodeStart = Date()
        let result = RustEngine.decodeOffice(payload)
        let decodeMs = Date().timeIntervalSince(decodeStart) * 1000
        let decoded = try XCTUnwrap(result, "the payload did not decode")

        // The floor: parsing the same bytes with no vocabulary to build. `bytesNoCopy` so the
        // measurement is the parse and not a copy of a payload this size.
        let bytes = Data(bytesNoCopy: payload, count: payloadBytes, deallocator: .none)
        let rawStart = Date()
        _ = try JSONSerialization.jsonObject(with: bytes)
        let rawMs = Date().timeIntervalSince(rawStart) * 1000

        // The vocabulary alone, with the SAME decoder settings the host uses and without the
        // vector-painting pass — so the two halves of `decodeOffice` can be told apart. Painting a
        // declared path into a PDF is AppKit work no wire format removes; building 3,000-odd blocks
        // out of `Decodable` is exactly what a wire format WOULD change, and P4 has to know which
        // of the two it is buying.
        let vocabDecoder = JSONDecoder()
        vocabDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let vocabStart = Date()
        let bare = try vocabDecoder.decode(OfficeReadResult.self, from: bytes)
        let vocabMs = Date().timeIntervalSince(vocabStart) * 1000

        print(String(
            format: """
            TRANSPORT %@
              payload        %d bytes
              engine (FFI)   %.1f ms   parse + map + project + serialize, all inside Rust
              decode (host)  %.1f ms   JSONDecoder + the vector-painting pass
              raw parse      %.1f ms   JSONSerialization over the same bytes — the floor
                vocabulary   %.1f ms   Decodable alone, no vector pass
                vectors      %.1f ms   %d graphics painted into PDFs
              blocks %d  images %d
            """,
            url.lastPathComponent, payloadBytes, engineMs, decodeMs, rawMs,
            vocabMs, decodeMs - vocabMs, bare.vectorGraphics.count,
            decoded.blocks.count, decoded.images.count))
    }
}
