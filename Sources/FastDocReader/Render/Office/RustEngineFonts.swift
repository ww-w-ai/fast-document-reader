#if FMD_RUST_ENGINE
import AppKit
import CFastdocEngine

/// The host's answer to the one question the ported engine cannot answer for itself.
///
/// The engine is values all the way down — a colour is four numbers, a rect is four numbers — with
/// one exception. Fonts are not values: whether "함초롬바탕" exists is a property of THIS machine,
/// and what you get when you add `.bold` to a face is a property of AppKit's cascade rather than
/// arithmetic on a family name. `FontSubstitutionResolver.swift` has the measurement: adding
/// `.bold` to an already-`-SemiBold` substitute returned `.AppleKoreanFont-Bold`, a DIFFERENT face,
/// and adding `[.bold, .italic]` to a `-Regular` one silently did nothing.
///
/// So the engine holds an opaque id and hands it back to ask what it means, and this file is what
/// answers. Choosing the HOST to answer (rather than a face set bundled into the engine) is what
/// makes this build reproduce the shipped reader exactly, which is the only reason a comparison
/// against it means anything. The other choice — identical output on every platform, at the cost of
/// moving macOS away from the shipped reader — is a second implementation of the same C surface,
/// not a change to it.
enum RustEngineFonts {

    /// Faces this process has issued ids for. The id IS the index + 1, so 0 stays free to mean
    /// "no such face" across the boundary.
    ///
    /// It only grows. A document resolves a handful of faces and the engine may ask about any of
    /// them at any point in the walk, so an id must stay valid for the life of the process — which
    /// is also why this is not a cache that can evict.
    private static var faces: [NSFontDescriptor] = []
    private static let lock = NSLock()

    private static func issue(_ descriptor: NSFontDescriptor) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        // Same descriptor asked for twice gets the same id, so the engine's own `FaceId` equality
        // keeps meaning "the same face" rather than "asked at the same time".
        if let existing = faces.firstIndex(of: descriptor) { return UInt64(existing + 1) }
        faces.append(descriptor)
        return UInt64(faces.count)
    }

    private static func face(forId id: UInt64) -> NSFontDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        let index = Int(id) - 1
        return faces.indices.contains(index) ? faces[index] : nil
    }

    /// Installs the four answers into the engine. Idempotent by the engine's own one-shot rule.
    static func install() {
        _ = installedOnce
    }

    private static let installedOnce: Bool = {
        var callbacks = FastdocFontProvider()

        // `NSFont(name:size:)` — nil is the signal `FontSubstitutionResolver` branches on, so a
        // missing face must come back as 0 rather than as some fallback the resolver would then
        // never replace. The size is arbitrary: a face's identity does not depend on it.
        callbacks.face_named = { namePtr in
            guard let namePtr, let name = String(validatingUTF8: namePtr) else { return 0 }
            guard let font = NSFont(name: name, size: 12) else { return 0 }
            return issue(font.fontDescriptor)
        }

        // `NSFont(descriptor:size:)`. The engine hands back a base face it was ISSUED plus whatever
        // it layered on; this rebuilds that descriptor and asks AppKit, which is the whole point —
        // composing "same family, bolder" in Rust would pick different faces than macOS on exactly
        // the Korean documents this reader exists for.
        callbacks.resolve = { base, traits, features, featureCount in
            var descriptor: NSFontDescriptor
            if base != 0, let known = face(forId: base) {
                descriptor = known
            } else {
                descriptor = NSFontDescriptor()
            }
            if traits != 0 {
                let symbolic = NSFontDescriptor.SymbolicTraits(rawValue: UInt32(traits))
                descriptor = descriptor.withSymbolicTraits(symbolic)
            }
            if featureCount > 0, let features {
                // Pairs of (key, value), flattened. The key encoding is the engine's own — these
                // are dictionary keys in AppKit, not integers — and small caps is its only user.
                var settings: [[NSFontDescriptor.FeatureKey: Int]] = []
                for pair in 0..<featureCount {
                    let key = features[pair * 2]
                    let value = Int(features[pair * 2 + 1])
                    let featureKey: NSFontDescriptor.FeatureKey
                    switch key {
                    case 1: featureKey = .typeIdentifier
                    case 2: featureKey = .selectorIdentifier
                    // 0 is the engine's `FeatureIdentifier`, which AppKit's `FeatureKey` does not
                    // have — the pair it uses is type + selector, which is what small caps sets.
                    // Dropped rather than guessed at, and no in-scope call site sends it.
                    default: continue
                    }
                    settings.append([featureKey: value])
                }
                if !settings.isEmpty {
                    descriptor = descriptor.addingAttributes([.featureSettings: settings])
                }
            }
            guard let font = NSFont(descriptor: descriptor, size: 12) else { return 0 }
            return issue(font.fontDescriptor)
        }

        // The system always has these, so this never returns 0.
        callbacks.system_face = { weight, monospaced in
            let w = NSFont.Weight(rawValue: weight)
            let font = monospaced
                ? NSFont.monospacedSystemFont(ofSize: 12, weight: w)
                : NSFont.systemFont(ofSize: 12, weight: w)
            return issue(font.fontDescriptor)
        }

        // What an issued face actually is. `familyName` is nil for the private system-UI cascades,
        // and that nil is information the engine reads — hence `has_family` rather than an empty
        // string, which would read as a family called "".
        callbacks.describe = { faceId, namePtr, nameCap, familyPtr, familyCap, hasFamilyPtr, traitsPtr in
            guard let known = face(forId: faceId), let font = NSFont(descriptor: known, size: 12) else {
                hasFamilyPtr?.pointee = false
                traitsPtr?.pointee = 0
                namePtr?.pointee = 0
                return
            }
            write(font.fontName, into: namePtr, capacity: nameCap)
            if let family = font.familyName {
                write(family, into: familyPtr, capacity: familyCap)
                hasFamilyPtr?.pointee = true
            } else {
                hasFamilyPtr?.pointee = false
            }
            traitsPtr?.pointee = font.fontDescriptor.symbolicTraits.rawValue
        }

        // `CTFontGetGlyphsForCharacters` — can this face draw this scalar? Tested on `glyphs[0]`
        // rather than the call's own return value: a non-BMP scalar is two UTF-16 units and
        // CoreText reports the trailing half as unmapped even when the pair resolved. That reading
        // is the shipped resolver's own, and getting it wrong substitutes a face for every emoji.
        callbacks.covers = { faceId, scalar in
            guard let known = face(forId: faceId),
                  let font = NSFont(descriptor: known, size: 12),
                  let unicode = Unicode.Scalar(scalar) else { return true }
            var units = Array(String(Character(unicode)).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count)
            return glyphs[0] != 0
        }

        // `CTFontCreateForString` over a string holding exactly this character — what the system
        // ITSELF would substitute. Returning 0 means "nothing to offer", which the engine reads as
        // "keep the declared face" rather than picking one of its own.
        callbacks.substitute = { declaredId, scalar in
            guard let known = face(forId: declaredId),
                  let declared = NSFont(descriptor: known, size: 12),
                  let unicode = Unicode.Scalar(scalar) else { return 0 }
            let text = String(Character(unicode)) as CFString
            let substituted = CTFontCreateForString(declared as CTFont, text,
                                                   CFRange(location: 0, length: CFStringGetLength(text)))
            return issue((substituted as NSFont).fontDescriptor)
        }

        return fastdoc_install_font_provider(callbacks)
    }()

    /// NUL-terminated, truncated rather than reallocated. A PostScript name longer than the
    /// engine's buffer is a bug on this side, not a face.
    private static func write(_ string: String, into buffer: UnsafeMutablePointer<CChar>?, capacity: Int) {
        guard let buffer, capacity > 0 else { return }
        let bytes = Array(string.utf8.prefix(capacity - 1))
        for (offset, byte) in bytes.enumerated() { buffer[offset] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
    }
}
#endif
