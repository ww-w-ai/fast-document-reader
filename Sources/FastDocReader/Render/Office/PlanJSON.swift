import Foundation

/// The plan input written as JSON without bridging it to Foundation.
///
/// `JSONSerialization` bridges every nested Swift dictionary and array to an Objective-C object
/// before writing it; on the 편람's input (3,207 blocks) that was 43 ms of the plan call. This writes
/// the same values: a `Bool` as `true`/`false`, an integer as an integer, a floating value as the
/// shortest decimal that reads back as the same `Double`, strings escaped per RFC 8259. Key order is
/// not kept (the engine reads an object, not a sequence). `PlanJSONTests` holds it equal to
/// `JSONSerialization` on what both parse back to.
enum PlanJSON {
    /// `nil` for a value JSON cannot hold (a non-finite number or an unsupported type), as
    /// `JSONSerialization` refuses those too.
    static func data(_ value: Any) -> Data? {
        var out: [UInt8] = []
        out.reserveCapacity(1 << 16)
        guard write(value, into: &out) else { return nil }
        return Data(out)
    }

    private static func write(_ value: Any, into out: inout [UInt8]) -> Bool {
        // Native scalars by their exact type: `as? Double` would also accept an NSNumber holding a Bool.
        let type = Swift.type(of: value)
        if type == Double.self { return number(value as! Double, into: &out) }
        if type == Int.self { out.append(contentsOf: String(value as! Int).utf8); return true }
        if type == Bool.self { out.append(contentsOf: ((value as! Bool) ? "true" : "false").utf8); return true }
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { out.append(contentsOf: (n.boolValue ? "true" : "false").utf8); return true }
            if CFNumberIsFloatType(n) { return number(n.doubleValue, into: &out) }
            out.append(contentsOf: n.stringValue.utf8); return true
        case let s as String: string(s, into: &out); return true
        case let a as [Double]:
            out.append(UInt8(ascii: "["))
            for (n, d) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                guard number(d, into: &out) else { return false }
            }
            out.append(UInt8(ascii: "]")); return true
        case let a as [Int]:
            out.append(UInt8(ascii: "["))
            for (n, i) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                out.append(contentsOf: String(i).utf8)
            }
            out.append(UInt8(ascii: "]")); return true
        case let a as [[String: Any]]:
            out.append(UInt8(ascii: "["))
            for (n, v) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                guard write(v, into: &out) else { return false }
            }
            out.append(UInt8(ascii: "]")); return true
        case let o as [String: Any]:
            out.append(UInt8(ascii: "{"))
            var first = true
            for (k, v) in o {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                string(k, into: &out)
                out.append(UInt8(ascii: ":"))
                guard write(v, into: &out) else { return false }
            }
            out.append(UInt8(ascii: "}")); return true
        case let a as [Any]:
            out.append(UInt8(ascii: "["))
            for (n, v) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                guard write(v, into: &out) else { return false }
            }
            out.append(UInt8(ascii: "]")); return true
        case is NSNull: out.append(contentsOf: "null".utf8); return true
        default: return false
        }
    }

    private static func number(_ d: Double, into out: inout [UInt8]) -> Bool {
        guard d.isFinite else { return false }
        if d == d.rounded(.towardZero), abs(d) < 1e15 { out.append(contentsOf: String(Int64(d)).utf8) }
        else { out.append(contentsOf: "\(d)".utf8) }
        return true
    }

    private static func string(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: "\\\"".utf8)
            case UInt8(ascii: "\\"): out.append(contentsOf: "\\\\".utf8)
            case 0..<0x20: out.append(contentsOf: String(format: "\\u%04x", byte).utf8)
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
