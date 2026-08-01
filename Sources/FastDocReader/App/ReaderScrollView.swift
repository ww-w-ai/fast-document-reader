import AppKit

/// The reader's scroll view, whose one job beyond `NSScrollView`'s is to make a TRACKPAD PINCH mean
/// the same thing ⌘+/⌘− means for this document.
///
/// **Why this exists.** `allowsMagnification` was turned on for PAGED documents, which are zoomed
/// rather than re-typeset (invariant 57), with the note that it "costs markdown nothing because
/// magnification stays 1 unless a paged document asks for it". That is true of the ⌘+/⌘− path and
/// false of the gesture: the flag is also what opens the pinch, so on a markdown file a pinch scaled
/// the VIEW — fighting the reflow, the frame pinning and the reading-column arithmetic, all of which
/// assume magnification belongs to paper. The owner found it: *"pan 으로 확대/축소하면 난리 남"*.
///
/// **What it does instead**, per the owner's own specification: a pinch on a text document previews
/// with the cheap thing and commits with the expensive one. While the fingers are down the view is
/// scaled — no rebuild, no reflow, instant — and the moment they lift, the scale is thrown away and
/// the equivalent READING SIZE is applied once, which is the same single rebuild ⌘+ would have cost.
/// *"팬일 때 바로 적용하면 큰 문서에서 딜레이가 심하게 걸릴 수 있으니, 폰트 사이즈만 미리 보여주고
/// 팬을 떼는 순간에 드로잉하도록 하자"*.
///
/// A PAGED document is untouched: there the view transform IS the answer, so the gesture goes
/// straight to `super`.
final class ReaderScrollView: NSScrollView {

    /// Set by the window controller that owns this view. Weak: the controller owns the view.
    weak var owner: DocumentWindowController?

    /// The reading size the gesture started from, and the scale accumulated since — `nil` between
    /// gestures, which is also how a `.changed` arriving without a `.began` is ignored.
    private var pinchBaseSize: CGFloat?

    override func magnify(with event: NSEvent) {
        guard let wc = owner, !wc.isPaged, let doc = wc.mdDocument else {
            super.magnify(with: event)     // paged: the transform is the model
            return
        }
        switch event.phase {
        case .began:
            pinchBaseSize = doc.readingSize
        case .changed:
            guard pinchBaseSize != nil else { return }
            // Preview only. Bounded by the same clamp the committed size uses, so the picture during
            // the gesture cannot promise a size the commit will refuse.
            let next = magnification * (1 + event.magnification)
            magnification = min(maxMagnification, max(minMagnification, next))
        case .ended, .cancelled:
            guard let base = pinchBaseSize else { return }
            pinchBaseSize = nil
            let scale = magnification
            magnification = 1                       // the preview is thrown away, never accumulated
            let target = FontSizeStore.clamped((base * scale).rounded())
            guard abs(target - doc.readingSize) >= 0.5 else { return }
            doc.applyReadingSize(target)            // ONE rebuild, exactly what ⌘+ costs
        default:
            break
        }
    }
}
