import XCTest
@testable import FastDocReader

/// What the HOST pays to turn one engine payload into this app's vocabulary, measured on a real
/// payload file rather than on a share of a composition table.
///
/// P3 established that the host's cost is the `Decodable` materialisation, not the JSON scan, so a
/// decision about the WIRE (P4b's interning of repeated `format`/`edge_borders` objects) has to be
/// judged by this number and not by bytes removed. Dump a payload with
/// `FMD_PAYLOAD_DUMP=<path>` on the `payload_composition` harness, then point this at it.
///
/// Deliberately drives `RustEngine.decodeOffice` — the shipping path, vector painting included —
/// rather than a second decoder written for the measurement.
final class PayloadDecodeProbeTests: XCTestCase {
    func testHowLongTheHostTakesToDecodeOnePayload() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_PAYLOAD_DECODE"] else {
            throw XCTSkip("set FMD_PAYLOAD_DECODE to an absolute path naming a dumped payload JSON")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var buffer = [CChar](repeating: 0, count: data.count + 1)
        data.withUnsafeBytes { raw in
            _ = memcpy(&buffer, raw.baseAddress!, data.count)
        }

        var best = Double.greatestFiniteMagnitude
        var blocks = -1
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = buffer.withUnsafeMutableBufferPointer { p -> OfficeReadResult? in
                RustEngine.decodeOffice(p.baseAddress!)
            }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            blocks = result?.blocks.count ?? -1
        }

        print(String(format: "PAYLOAD-DECODE %@  %d bytes  %8.1f ms  blocks %d",
                     (path as NSString).lastPathComponent, data.count, best, blocks))
        // A payload that failed to decode returns nil in no time at all, which would read as the
        // fastest arm of whatever comparison this is feeding.
        XCTAssertGreaterThan(blocks, 0, "the payload did not decode — the timing means nothing")
    }
}
