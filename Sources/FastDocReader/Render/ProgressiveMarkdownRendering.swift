import AppKit

/// A markdown render handed out front to back, whichever renderer is producing it.
///
/// Front-first paint puts the top of a long document on screen and finishes the rest afterwards
/// (invariant 55(b)). The document layer drives that loop and does not care whether the pieces
/// come from the engine or from this app's own renderer — but it DOES care that the pieces join
/// up, which is what makes this a protocol rather than two call sites: both implementations keep
/// one builder alive across chunks, so block ids keep counting up and each chunk's source offsets
/// continue where the last one stopped (invariant 19).
protocol ProgressiveMarkdownRendering: AnyObject {
    /// Every top-level block has been handed over.
    var isFinished: Bool { get }
    /// Blocks not yet visited — what the caller divides into the turns it is willing to take.
    var remainingBlocks: Int { get }
    /// How many pieces have been handed over, so a probe reports turns instead of guessing.
    var chunksHandedOut: Int { get }
    /// Visit up to `blocks` more top-level blocks and return the text they produced.
    func nextChunk(blocks: Int) -> NSAttributedString
}

extension ProgressiveMarkdownRender: ProgressiveMarkdownRendering {}
