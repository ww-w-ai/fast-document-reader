import CoreGraphics
import Foundation

/// What's genuinely global about the reader's font size: the default, the 10...36 clamp, and the
/// one-point step. The size itself is NOT here any more — it belongs to each document (see
/// `MarkdownDocument.readingSize`), because it's a fact about what a reader is currently looking
/// at, not a fact about the app, and two open documents can be looking at different sizes at once.
///
/// This type used to hold a single mutable, `UserDefaults`-backed `size` that every open document's
/// render READ FROM on every render — THAT was the bug: pressing ⌘+ in one window changed the ONE
/// shared value, so any OTHER window (even one nobody had touched) silently drew at the new size the
/// next time anything made it re-render, and windows visibly disagreed. Reproduced before the fix:
/// two documents open, one ⌘+ press, the stored value went 16 → 17 and exactly ONE of the two
/// re-rendered.
///
/// `startingSize` is what survives, and the distinction is the whole design: it is READ ONCE, when a
/// document is created, to seed that document's own `readingSize` — and never read again. Changing
/// one document's size updates this seed for the NEXT document opened, and cannot reach any document
/// already open, because nothing open is looking at it any more. That keeps the reader's remembered
/// size across launches (which the README and the App Store description both promise) without
/// reintroducing the shared-mutable-state bug that promise was previously implemented with.
enum FontSizeStore {
    private static let key = "baseFontSize"
    static let defaultSize: CGFloat = 16
    static let step: CGFloat = 1
    static func clamped(_ v: CGFloat) -> CGFloat { min(36, max(10, v)) }
    static func increased(from v: CGFloat) -> CGFloat { clamped(v + step) }
    static func decreased(from v: CGFloat) -> CGFloat { clamped(v - step) }

    /// The size a NEWLY created document starts at — the last size the reader chose, or the default
    /// on a machine that has never been zoomed. Deliberately NOT called `size`: the old name invited
    /// exactly the "read it during render" use that caused the bug, and `MarkdownDocument.readingSize`
    /// is the only thing a render may ever consult.
    static var startingSize: CGFloat {
        get { clamped(CGFloat(UserDefaults.standard.object(forKey: key) as? Double ?? Double(defaultSize))) }
        set { UserDefaults.standard.set(Double(clamped(newValue)), forKey: key) }
    }
}
