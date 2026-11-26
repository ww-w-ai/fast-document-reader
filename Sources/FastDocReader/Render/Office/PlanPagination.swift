import AppKit
import CFastdocEngine

/// The host's door to the engine's page plan (`fastdoc_office_page_plan_json`).
///
/// Pagination is the engine's decision. A host observes its text once in a layout nobody paginated
/// (`PlanObservation`), builds the input from it (`PlanInputBuilder`), asks here, and applies the
/// answer line by line (`PageBandLayoutDelegate`). Nothing in this file decides a page.
enum PlanPagination {
    /// The engine's answer for `input`, or `nil` when it answered no plan (an unsupported plan
    /// version or a payload it refused).
    static func ask(_ input: [String: Any]) -> [String: Any]? {
        PlanJSON.data(input).flatMap(ask(json:))
    }

    /// The engine's answer for an input already encoded (`PlanJSON.data`).
    static func ask(json: Data) -> [String: Any]? {
        guard let reply = envelope(json: json),
              let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return nil }
        return object["ok"] as? [String: Any]
    }

    /// The engine's reply envelope for one plan request, as the FFI wrote it (`ok` or `error`).
    static func envelope(json: Data) -> Data? {
        var bytes = [UInt8](json)
        bytes.append(0)
        let out: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                fastdoc_office_page_plan_json(nil, $0)
            }
        }
        guard let out else { return nil }
        defer { fastdoc_string_free(out) }
        return String(cString: out).data(using: .utf8)
    }

    /// The character ranges of the tables the plan flows line by line (`flowedTables`, by block id),
    /// read from the observation they were planned from.
    static func flowedRanges(plan: [String: Any], observation: PlanInputBuilder.Observation,
                             storageLength: Int) -> [NSRange] {
        let keys = Set(((plan["flowedTables"] as? [NSNumber]) ?? []).map(\.intValue))
        guard !keys.isEmpty else { return [] }
        var out: [NSRange] = []
        for (index, group) in observation.groups.enumerated() where keys.contains(group.id) {
            let start = observation.fragments[group.range.lowerBound].location
            let end = index + 1 < observation.groups.count
                ? observation.fragments[observation.groups[index + 1].range.lowerBound].location
                : storageLength
            if end > start { out.append(NSRange(location: start, length: end - start)) }
        }
        return out
    }
}
