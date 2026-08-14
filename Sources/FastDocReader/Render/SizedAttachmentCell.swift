import AppKit

/// A text-attachment cell that OWNS its layout size (`reservedSize`) independently of whether an
/// image is currently loaded. The default NSTextAttachmentCell derives its size from the image, so
/// an image==nil attachment collapses to ~zero height — which made the reserved placeholder space
/// vanish and the document's total height (and scroll bar) swing as diagrams lazily loaded/unloaded.
///
/// Here the size is fixed at pre-measure time and never changes when the image toggles, so lazy
/// loading/purging pixels does NOT touch layout: the frame height (and scroll bar) stay rock stable.
/// The cell just draws the attachment's image when one is present, nothing when it isn't.
final class SizedAttachmentCell: NSTextAttachmentCell {
    var reservedSize: NSSize

    /// Set when this picture's pixels were REACHED FOR and could not be produced — either the
    /// bytes name a format no installed decoder reads (a Word/HWP chart pasted as WMF is the
    /// common one), or there were no bytes to read at all. `nil` means "nothing has failed":
    /// an attachment that is merely not-yet-loaded, or purged off-screen, keeps drawing nothing,
    /// which is what invariant 1's reserved-but-empty space is supposed to look like.
    ///
    /// It is a LABEL, not an image, on purpose. The card is drawn HERE, at `cellFrame`, on every
    /// paint — so a window resize (which re-solves `reservedSize` through
    /// `DocumentWindowController.resizeOfficeGraphics`, invariant 46) redraws it crisply at the
    /// new size instead of scaling a bitmap that was baked at some earlier width. Baking it into
    /// `attachment.image` is what stretched a 22×22 system glyph across a 700×465 frame and made
    /// an intact document read as a corrupt one; it would equally blur a labelled card.
    /// Keeping the pixels out of `.image` is also what keeps THIS cell alive to draw them —
    /// invariant 31: AppKit drops a custom `attachmentCell` the moment `.image` is set.
    var undrawableLabel: String?

    /// The picture's own pixels, held HERE rather than on `attachment.image`.
    ///
    /// This is invariant 31 applied to the thing the invariant is actually about: setting
    /// `attachment.image` makes AppKit drop this cell and lay the attachment out its own way, from
    /// the image's NATURAL size — so an office picture whose declared box has a different aspect
    /// than its pixels (36 of 124 in one real manual, one of them by 2.7×) silently stopped using
    /// the reserved box the document asked for the moment its pixels arrived. What a reader saw was
    /// a picture drawn at one size and a click/selection area at another.
    ///
    /// Kept on the cell, the reserved size governs both, always, whether pixels are loaded or not.
    var pixels: NSImage?

    init(reservedSize: NSSize) {
        self.reservedSize = reservedSize
        super.init()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize { reservedSize }
    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(origin: .zero, size: reservedSize)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let image = pixels ?? attachment?.image {
            // `respectFlipped` — the text view is FLIPPED, and the four-argument `draw(in:…)` does
            // not consult that, so every picture drawn by this cell arrived upside down. It was
            // invisible while AppKit still drew the attachment itself from `.image`; the moment the
            // pixels moved onto the cell (invariant 80) this became the app's own draw call, and a
            // whole-page cover reads as an obvious mirror while a photograph reads as merely wrong.
            // The one flag `MasterPagePainter` already passes for the same reason.
            image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1.0,
                       respectFlipped: true, hints: nil)
        } else if let undrawableLabel {
            // The SAME card `OfficeTextBuilder` bakes for a chart it has no picture for at all —
            // one drawing routine, so "a graphic this reader cannot draw" looks like itself
            // wherever the discovery happened to be made.
            OfficeTextBuilder.drawPlaceholderCard(label: undrawableLabel, in: cellFrame)
        }
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
