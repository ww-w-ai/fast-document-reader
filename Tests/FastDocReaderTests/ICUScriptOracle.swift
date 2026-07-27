import Darwin
import Foundation

/// ICU's answer to "what script is this scalar", reached by `dlsym` — TEST CODE ONLY.
///
/// This exists so the generated `ScriptRanges.swift` is checked against an authority that had no
/// hand in generating it. It is deliberately built the most inert way available: no `-licucore`
/// linker flag, no C target, no module map, no `Package.swift` change of any kind. Nothing about it
/// can leak into the app target by a future edit, because there is nothing to inherit — the whole
/// dependency is two `dlsym` calls inside a test bundle.
///
/// That inertness is the point rather than a convenience. Linking `libicucore` genuinely works on
/// this platform (Apple builds ICU with `U_DISABLE_RENAMING`, so the symbols are exported
/// unversioned from the dyld shared cache, and the character-property data is embedded in the
/// library rather than read from `/usr/share/icu`), and it is the fastest route to the property by
/// a factor of two. It is still not shippable: Apple has never documented the ICU C API on its
/// platforms, deliberately withholds `uscript.h`, and App Store acceptance of a binary linking it is
/// unresolved. An unresolved store question is not worth 1 ms per document read.
///
/// Everything here is asked for by NAME, never by number. ICU's `UScriptCode` integers are not
/// stable across ICU releases — new scripts are inserted — and Apple bumps ICU with the OS, so a
/// test that compared raw integers would rot into a false failure on some future macOS.
final class ICUScriptOracle {
    /// `UCHAR_SCRIPT` from the SDK's own `unicode/uchar.h`. The numeric PROPERTY selectors are
    /// stable (unlike the property VALUES this returns); only the values are looked up by name.
    private static let ucharScript: Int32 = 0x100A
    /// `U_LONG_PROPERTY_NAME`, the second case of `UPropertyNameChoice` — the long form is the one
    /// that matches the UCD's own `Scripts.txt` spellings ("Hangul", "Old_Uyghur").
    private static let longPropertyName: Int32 = 1

    private typealias GetIntPropertyValue = @convention(c) (Int32, Int32) -> Int32
    private typealias GetPropertyValueName = @convention(c) (Int32, Int32, Int32) -> UnsafePointer<CChar>?
    private typealias GetUnicodeVersion = @convention(c) (UnsafeMutablePointer<UInt8>) -> Void

    private let getIntPropertyValue: GetIntPropertyValue
    private let getPropertyValueName: GetPropertyValueName
    private let getUnicodeVersion: GetUnicodeVersion?
    /// ICU's numeric script code changes per scalar; the NAME behind it does not. There are ~180
    /// distinct codes against 1.1M scalars, and `u_getPropertyValueName` returns a C string that
    /// would otherwise be bridged to a Swift `String` on every one of them.
    private var namesByCode: [Int32: String] = [:]

    init?() {
        // RTLD_DEFAULT — libicucore is already in the process (Foundation links it), so the ordinary
        // case needs no dlopen at all. The explicit open is the fallback for a host that somehow has
        // not pulled it in yet, and a `nil` from both is reported by the caller as a missing oracle
        // rather than swallowed as a pass.
        let anyLoaded = UnsafeMutableRawPointer(bitPattern: -2)
        var handle = anyLoaded
        if dlsym(handle, "u_getIntPropertyValue") == nil {
            handle = dlopen("/usr/lib/libicucore.dylib", RTLD_LAZY)
        }
        guard let handle,
              let property = dlsym(handle, "u_getIntPropertyValue"),
              let name = dlsym(handle, "u_getPropertyValueName") else { return nil }
        getIntPropertyValue = unsafeBitCast(property, to: GetIntPropertyValue.self)
        getPropertyValueName = unsafeBitCast(name, to: GetPropertyValueName.self)
        getUnicodeVersion = dlsym(handle, "u_getUnicodeVersion").map {
            unsafeBitCast($0, to: GetUnicodeVersion.self)
        }
    }

    /// ICU's long Script property-value name for this scalar, e.g. `"Hangul"`, `"Common"`,
    /// `"Unknown"` — the same spellings the UCD's `Scripts.txt` uses.
    func scriptName(of scalar: UInt32) -> String {
        let code = getIntPropertyValue(Int32(bitPattern: scalar), Self.ucharScript)
        if let cached = namesByCode[code] { return cached }
        let name = getPropertyValueName(Self.ucharScript, code, Self.longPropertyName)
            .map { String(cString: $0) } ?? "?\(code)"
        namesByCode[code] = name
        return name
    }

    /// The Unicode release ICU's own data was built from, for diagnosing a disagreement: if this
    /// does not match `UnicodeScript.unicodeVersion`, the two are describing different Unicodes and
    /// the differences are a version skew rather than a generation bug.
    var unicodeVersion: String {
        guard let getUnicodeVersion else { return "unknown" }
        var version = [UInt8](repeating: 0, count: 4)
        version.withUnsafeMutableBufferPointer { getUnicodeVersion($0.baseAddress!) }
        return version.map(String.init).joined(separator: ".")
    }
}
