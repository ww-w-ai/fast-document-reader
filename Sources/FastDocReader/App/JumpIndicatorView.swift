import AppKit

/// The number a reader is typing, echoed back while they type it — "Go to 12 / 443 ⏎".
///
/// A HUD rather than a panel, because the request is one keystroke long: typing a digit IS the
/// command (`ReaderTextView.keyDown`), Return runs it and Escape or a second of silence forgets it.
/// The reader never leaves the page, which is the whole difference from ⌘L's sheet.
///
/// Laid over the scroll view like `PageNumberDeskView`, never inside the text: it has no text
/// storage and no layout manager, so an input echo cannot move the document it is asking about.
final class JumpIndicatorView: NSView {

    /// What to show. Empty hides the view — one property, so the caller never has to keep a string
    /// and a visibility flag in step.
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            isHidden = text.isEmpty
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    /// Pure furniture — never takes a click, so a click through it still reaches the text.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        let label = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white
        ])
        let size = label.size()
        let padding = NSSize(width: 22, height: 12)
        let box = NSRect(x: (bounds.width - size.width - padding.width * 2) / 2,
                         y: bounds.height - size.height - padding.height * 2 - 40,
                         width: size.width + padding.width * 2,
                         height: size.height + padding.height * 2)
        // Dark capsule, so it reads the same over white paper and over the grey desk.
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        label.draw(at: NSPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }
}
