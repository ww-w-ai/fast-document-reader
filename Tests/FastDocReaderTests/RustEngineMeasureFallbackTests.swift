import XCTest
import AppKit
import CFastdocEngine
@testable import FastDocReader

/// S5C1B-02: a face this machine cannot resolve still measures BOLD.
///
/// The port stopped re-applying bold/italic on top of a face the engine already resolved, because
/// the name it sends IS that resolved face (`text_measure.rs:257` reads `font.fontName()` off the
/// built string). The traits are still the only description left when that name does not resolve
/// here — a document naming a font this machine does not have — and dropping the trait step on
/// THAT path would silently measure regular text where the document said bold.
final class RustEngineMeasureFallbackTests: XCTestCase {
    /// The discriminator is a WRAP, not a height comparison at one width: the same text at the same
    /// size in bold and regular usually reports the SAME line height, so "the bold answer is taller"
    /// passes even when the trait step does nothing. Bold glyphs are WIDER, so a width that fits the
    /// regular face on one line and forces the bold one onto two makes the answer differ by a whole
    /// line — which no no-op can produce.
    /// The other half: a face that DOES resolve must be measured AS IT IS.
    ///
    /// The engine sends the face it already resolved, so its weight is in the name. Re-applying the
    /// bold trait on top of it does not confirm that weight — it asks for a different one:
    /// `AppleSDGothicNeo-SemiBold` re-traited resolves to `AppleSDGothicNeo-Bold`, which is
    /// precisely why `OfficeTextBuilder` gates its own trait step (`OfficeTextBuilder.swift:521-535`).
    /// Without this test, restoring the unconditional re-trait changed nothing any check could see:
    /// every fixture in this repository names a face whose re-traiting lands back on itself.
    func testAResolvedFaceIsMeasuredAsItIsRatherThanReTraited() throws {
        let semibold = "AppleSDGothicNeo-SemiBold"
        guard let asSent = NSFont(name: semibold, size: 12),
              let reTraited = NSFont(descriptor: asSent.fontDescriptor.withSymbolicTraits(.bold), size: 12),
              reTraited.fontName != asSent.fontName else {
            throw XCTSkip("\(semibold) is absent here, or re-traiting it lands on itself — nothing to tell apart")
        }
        // Latin text in a KOREAN face on purpose: this machine's headless font substitution maps
        // Hangul in both weights onto the same substitute, so Korean text measures 295.128pt in
        // SemiBold and in Bold alike and could not tell the two apart. The face's own Latin glyphs
        // do differ — 371.868 against 386.976 — so the weight is observable through them.
        let text = "A running header set in the semibold face this document actually named"

        func height(width: CGFloat, font: String) -> CGFloat {
            var name = font.utf8CString
            var body = text.utf8CString
            return name.withUnsafeMutableBufferPointer { namePtr in
                body.withUnsafeMutableBufferPointer { bodyPtr in
                    var run = FastdocTextMeasureRun(
                        paragraph_index: 0, kind: FastdocTextMeasureRunKindText,
                        font_name: namePtr.baseAddress, size: 12, bold: true, italic: false,
                        text: bodyPtr.baseAddress, attachment_width: 0, attachment_height: 0)
                    var paragraph = FastdocTextMeasureParagraph(
                        alignment: 0, line_spacing: 0, line_height_multiple: 0,
                        minimum_line_height: 0, maximum_line_height: 0,
                        spacing_before: 0, spacing_after: 0,
                        first_line_head_indent: 0, head_indent: 0, tail_indent: 0,
                        tab_stops: nil, tab_stop_count: 0)
                    return withUnsafePointer(to: &paragraph) { paragraphPtr in
                        withUnsafePointer(to: &run) { runPtr in
                            RustEngineMeasure.measure(
                                FastdocTextMeasurePayload(paragraphs: paragraphPtr, paragraph_count: 1,
                                                          runs: runPtr, run_count: 1),
                                widthPoints: width)
                        }
                    }
                }
            }
        }

        // A width where the SemiBold face still fits one line and the Bold one — wider glyphs — does
        // not. Found by measuring the two faces directly, so the test does not hardcode a number
        // that a font revision could invalidate.
        let semiWidth = ceil(NSAttributedString(string: text, attributes: [.font: asSent]).size().width)
        let boldWidth = ceil(NSAttributedString(string: text, attributes: [.font: reTraited]).size().width)
        guard boldWidth > semiWidth + 2 else {
            throw XCTSkip("the two faces measure the same width here, so no width can tell them apart")
        }
        let width = semiWidth + 1

        let oneLine = height(width: 4000, font: semibold)
        let atWidth = height(width: width, font: semibold)
        XCTAssertEqual(atWidth, oneLine, accuracy: 0.5,
                       "the face the engine sent fits this width on one line; a measurement that re-traits it to a wider face would wrap")
    }

    func testAnUnresolvableFaceStillMeasuresBoldWiderThanRegular() throws {
        // UUID-suffixed so it cannot collide with a font someone has installed.
        let missing = "FastDocNoSuchFace-\(UUID().uuidString)"
        let text = "Running header of a document whose font this machine does not have installed"

        func height(bold: Bool, width: CGFloat) -> CGFloat {
            var name = missing.utf8CString
            var body = text.utf8CString
            return name.withUnsafeMutableBufferPointer { namePtr in
                body.withUnsafeMutableBufferPointer { bodyPtr in
                    var run = FastdocTextMeasureRun(
                        paragraph_index: 0, kind: FastdocTextMeasureRunKindText,
                        font_name: namePtr.baseAddress, size: 12, bold: bold, italic: false,
                        text: bodyPtr.baseAddress,
                        attachment_width: 0, attachment_height: 0)
                    var paragraph = FastdocTextMeasureParagraph(
                        alignment: 0, line_spacing: 0, line_height_multiple: 0,
                        minimum_line_height: 0, maximum_line_height: 0,
                        spacing_before: 0, spacing_after: 0,
                        first_line_head_indent: 0, head_indent: 0, tail_indent: 0,
                        tab_stops: nil, tab_stop_count: 0)
                    return withUnsafePointer(to: &paragraph) { paragraphPtr in
                        withUnsafePointer(to: &run) { runPtr in
                            let payload = FastdocTextMeasurePayload(
                                paragraphs: paragraphPtr, paragraph_count: 1,
                                runs: runPtr, run_count: 1)
                            return RustEngineMeasure.measure(payload, widthPoints: width)
                        }
                    }
                }
            }
        }

        // Find a width where the regular face fits on one line — with margin, not sitting on the
        // wrap boundary, so a font-hinting revision cannot flip it.
        let single = height(bold: false, width: 4000)
        var oneLineWidth: CGFloat = 4000
        while oneLineWidth > 60, height(bold: false, width: oneLineWidth - 20) <= single + 0.5 {
            oneLineWidth -= 20
        }
        XCTAssertGreaterThan(oneLineWidth, 60, "a one-line width must exist for this text")

        let regular = height(bold: false, width: oneLineWidth)
        let boldHeight = height(bold: true, width: oneLineWidth)
        XCTAssertEqual(regular, single, accuracy: 0.5,
                       "the regular face must still be on one line at the chosen width")
        XCTAssertGreaterThan(boldHeight, regular + 0.5,
                             "bold glyphs are wider: at a width the regular face fits, the bold one must wrap — if the trait step no-ops, both measure the same font and this cannot happen")
    }
}
