import AppKit

/// Translucent "⚡️FastDoc" laid over the preview's top-right corner: which app drew this preview.
/// Several previewers can claim the same file type and macOS names none of them, so until this
/// existed the only tell was the reading-line band, which is exactly what the preview now suppresses
/// (invariant 68d), leaving no tell at all.
///
/// This is the ONLY thing pinned over the panel. That a document was cut is said in the CONTENT
/// itself (`shortenedNote`) — a second mark pinned here stayed put while the reader scrolled and read
/// as chrome rather than as the end of the text.
///
/// Plain text, no pill: a filled capsule reads as a control, and at the panel's edge it collided with
/// the scroller and drew clipped. Text alone cannot be clipped into looking broken.
///
/// These are siblings of the document's content view rather than anything the reader draws, so they
/// cannot scroll away, cannot enter the text storage (⌘F would answer them), and do not exist in the
/// reader, on paper, or in `--pdf`. Preview-only, by construction rather than by a flag.
final class PreviewBadgeView: NSView {

    static let title = "⚡️FastDoc"

    /// Inset from the panel's edge. The width clears the vertical scroller (~15pt) so the mark never
    /// sits under it — that overlap is what made the first version look clipped.
    static let margin = NSSize(width: 22, height: 6)

    /// Quiet enough to be furniture, legible enough to answer the question it exists for.
    static let opacity: CGFloat = 0.55

    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = Palette.secondary.withAlphaComponent(Self.opacity)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    /// Sized from the label's own text so renamed or translated wording cannot clip.
    var markSize: NSSize { label.intrinsicContentSize }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    /// Pin to the top-right of `host`, above whatever it already holds. `NSView`'s own autoresizing is
    /// enough here — a fixed size tracking one corner.
    static func install(_ text: String, in host: NSView) {
        let badge = PreviewBadgeView(text: text)
        let size = badge.markSize
        badge.frame = NSRect(x: host.bounds.width - size.width - margin.width,
                             y: host.bounds.height - size.height - margin.height,
                             width: size.width, height: size.height)
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        host.addSubview(badge)
    }
}
