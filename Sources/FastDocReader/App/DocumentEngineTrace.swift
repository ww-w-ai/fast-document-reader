#if DEBUG
import Foundation

/// Test-only observation and fault-injection boundary for document-engine dispatch.
/// Release builds contain neither this type nor its stable fault identifiers.
enum DocumentEngineTrace {
    struct Event: Equatable, Codable {
        let runID: String
        let entryPoint: String
        let fileClass: String
        let fileExtension: String
        let engine: String
        let seam: String
    }

    struct Fault: Error, Equatable {
        let id: String
    }

    private struct Scope {
        let runID: String
        let entryPoint: String
        let faults: Set<String>
    }

    private static let lock = NSLock()
    private static var events: [Event] = []
    private static var triggeredFaults: [String: [String]] = [:]
    private static let scopeKey = "ai.ww-w.fast-doc-reader.engine-trace-scope"

    static func withRun<T>(
        _ runID: String,
        entryPoint: String,
        faults: Set<String> = [],
        _ operation: () throws -> T
    ) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[scopeKey]
        dictionary[scopeKey] = ScopeBox(Scope(runID: runID, entryPoint: entryPoint, faults: faults))
        defer {
            if let previous { dictionary[scopeKey] = previous }
            else { dictionary.removeObject(forKey: scopeKey) }
        }
        return try operation()
    }

    /// Async test harnesses whose implementation is main-thread synchronous may bracket a call.
    /// Mutation tests remain serial and always pair this with `endRun()` in `defer`.
    static func beginRun(_ runID: String, entryPoint: String, faults: Set<String> = []) {
        Thread.current.threadDictionary[scopeKey] = ScopeBox(
            Scope(runID: runID, entryPoint: entryPoint, faults: faults))
    }

    static func endRun() {
        Thread.current.threadDictionary.removeObject(forKey: scopeKey)
    }

    static func record(
        fileClass: String,
        extension ext: String,
        engine: String,
        seam: String
    ) throws {
        guard let scope = (Thread.current.threadDictionary[scopeKey] as? ScopeBox)?.scope else {
            return
        }
        let event = Event(
            runID: scope.runID,
            entryPoint: scope.entryPoint,
            fileClass: fileClass,
            fileExtension: ext.lowercased(),
            engine: engine,
            seam: seam
        )
        let faultID = "F-\(seam)"
        lock.lock()
        events.append(event)
        if scope.faults.contains(seam) {
            triggeredFaults[scope.runID, default: []].append(faultID)
        }
        lock.unlock()
        if scope.faults.contains(seam) { throw Fault(id: faultID) }
    }

    /// Records a seam whose intentional mutation changes a return value instead of throwing.
    static func mutationActive(
        fileClass: String,
        extension ext: String,
        engine: String,
        seam: String
    ) -> Bool {
        guard let scope = (Thread.current.threadDictionary[scopeKey] as? ScopeBox)?.scope,
              scope.faults.contains(seam) else {
            return false
        }
        do {
            try record(fileClass: fileClass, extension: ext, engine: engine, seam: seam)
            return false
        } catch {
            return true
        }
    }

    static func snapshot(runID: String) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.runID == runID }
    }

    static func faults(runID: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return triggeredFaults[runID, default: []]
    }

    static var currentEntryPoint: String? {
        (Thread.current.threadDictionary[scopeKey] as? ScopeBox)?.scope.entryPoint
    }

    static func reset() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        triggeredFaults.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private final class ScopeBox: NSObject {
        let scope: Scope
        init(_ scope: Scope) { self.scope = scope }
    }
}
#endif
