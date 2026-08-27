#if FMD_RUST_ENGINE
import AppKit
import CFastdocEngine
import Foundation

/// The host's answer to S5's measurement port: "how tall is this text at this width" —
/// `swiftshim::text_measure`'s `TextMeasurer`, installed the same way `RustEngineFonts` installs
/// the font world (S2B's precedent, S5's plan says to copy its shape exactly).
///
/// This file maps ONLY. Every attribute the callback reads was already resolved by the engine's
/// own `OfficeTextBuilder` (paragraph style, tab stops, indents, line height; a run's font or an
/// attachment's already-fitted box) — deciding any of that again here would be a second,
/// divergent interpretation of the same document, which is exactly what S5's design forbids
/// ("if the host has to decide anything, the port is wrong"). What is left is mechanical: build
/// the SAME `NSAttributedString` shape `PageBandGeometry.builtHeight` already builds today
/// (`Sources/FastDocReader/Render/Office/PageBandGeometry.swift:146-164`), lay it out in a
/// container of the given width with unbounded height and no padding, and report the used
/// height — the identical TextKit ritual, run against a payload the engine flattened rather than
/// against `OfficeTextBuilder`'s own live output.
enum RustEngineMeasure {
    /// Installs the callback. Idempotent by the engine's own one-shot rule
    /// (`fastdoc_install_text_measurer` refuses a second installation rather than swapping).
    static func install() {
        _ = installedOnce
    }

    private static let installedOnce: Bool = {
        var callbacks = FastdocTextMeasureCallbacks()
        callbacks.measure = { payloadPtr, widthPoints in
            guard let payloadPtr else { return 0 }
            return RustEngineMeasure.measure(payloadPtr.pointee, widthPoints: widthPoints)
        }
        return fastdoc_install_text_measurer(callbacks)
    }()

    /// `NSTextAlignment`'s wire code — must stay the mirror image of `alignment_code` in
    /// `crates/swiftshim/src/text_measure.rs` (left=0, right=1, center=2, justified=3,
    /// natural=4). Kept as a table rather than `NSTextAlignment(rawValue:)` because AppKit's own
    /// raw values do not happen to match the engine's wire order.
    private static func alignment(fromWireCode code: UInt8) -> NSTextAlignment {
        switch code {
        case 0: return .left
        case 1: return .right
        case 2: return .center
        case 3: return .justified
        default: return .natural
        }
    }

    /// One call's worth of mapping + layout — pulled out of the C callback closure so it is a
    /// plain, testable Swift function (`RustEngineBridgeTests` calls this directly with a
    /// hand-built payload, without going through the FFI boundary at all).
    static func measure(_ payload: FastdocTextMeasurePayload, widthPoints: CGFloat) -> CGFloat {
        let result = NSMutableAttributedString()
        let paragraphs = payload.paragraph_count > 0
            ? UnsafeBufferPointer(start: payload.paragraphs, count: payload.paragraph_count) : nil
        let runs = payload.run_count > 0
            ? UnsafeBufferPointer(start: payload.runs, count: payload.run_count) : nil

        for (index, paragraph) in (paragraphs ?? UnsafeBufferPointer<FastdocTextMeasureParagraph>(start: nil, count: 0)).enumerated() {
            let start = result.length
            var firstRunFont: NSFont?
            for run in runs ?? UnsafeBufferPointer<FastdocTextMeasureRun>(start: nil, count: 0)
            where run.paragraph_index == index {
                switch run.kind {
                case FastdocTextMeasureRunKindText:
                    let piece = attributedRun(for: run)
                    if firstRunFont == nil, piece.length > 0 {
                        firstRunFont = piece.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    }
                    result.append(piece)
                case FastdocTextMeasureRunKindAttachment:
                    result.append(attributedAttachment(for: run))
                default:
                    continue
                }
            }
            // The terminator is appended BEFORE the paragraph style is applied, and the style
            // covers content + terminator together — the same order `OfficeTextBuilder` itself
            // builds a paragraph in (`result.append("\n"); let paragraphRange = ...; addAttribute`).
            // A paragraph with no runs (a blank line) still gets its style on the lone "\n", which
            // is what makes an EMPTY paragraph's line height agree with the host's own answer too.
            // WITH THE PARAGRAPH'S OWN FONT — specifically its FIRST run's, not its last: the host's
            // own `unifyTerminator` (`OfficeTextBuilder.swift:1690`) copies the attributes AT THE
            // PARAGRAPH'S START (`result.attributes(at: paragraph.location, ...)`), never the last
            // run's. The two agree for the overwhelming majority of paragraphs, where every run
            // shares one font — which is why the earlier `lastRunFont` version measured a real paged
            // header correctly (single font throughout) while still being the wrong rule in general.
            // It surfaced on a footnote whose FIRST run is the citation number at the document's own
            // default size and whose LAST run is the note's smaller body text: `lastRunFont` gave the
            // terminator the body's small size, TextKit's invisible trailing line fragment measured
            // short against it, and the note's reserved band came out 6.3pt shorter than the host's
            // own build for every note in the fixture (`FootnoteHeightsDocumentPathTests`). An
            // unattributed terminator is still wrong for the reason recorded below — it fell to a
            // default face and reported 14.0pt where the host's own build reported 13.0 on a real
            // paged header — so this stays attributed, just to the correct end of the paragraph.
            result.append(NSAttributedString(
                string: "\n", attributes: firstRunFont.map { [.font: $0] } ?? [:]))
            let paragraphRange = NSRange(location: start, length: result.length - start)
            if paragraphRange.length > 0 {
                result.addAttribute(.paragraphStyle, value: paragraphStyle(for: paragraph), range: paragraphRange)
            }
        }

        guard result.length > 0 else { return 0 }

        // The identical ritual `PageBandGeometry.builtHeight` performs on `OfficeTextBuilder`'s
        // own output — same container shape (unbounded height, no padding), same layout manager
        // settings — so the two sides are asking TextKit the same question.
        let storage = NSTextStorage(attributedString: result)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: widthPoints, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    private static func paragraphStyle(for paragraph: FastdocTextMeasureParagraph) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment(fromWireCode: paragraph.alignment)
        style.lineSpacing = paragraph.line_spacing
        style.lineHeightMultiple = paragraph.line_height_multiple
        style.minimumLineHeight = paragraph.minimum_line_height
        style.maximumLineHeight = paragraph.maximum_line_height
        style.paragraphSpacingBefore = paragraph.spacing_before
        style.paragraphSpacing = paragraph.spacing_after
        style.firstLineHeadIndent = paragraph.first_line_head_indent
        style.headIndent = paragraph.head_indent
        style.tailIndent = paragraph.tail_indent
        if paragraph.tab_stop_count > 0, let tabStopsPtr = paragraph.tab_stops {
            let tabStops = UnsafeBufferPointer(start: tabStopsPtr, count: paragraph.tab_stop_count)
            style.tabStops = tabStops.map {
                NSTextTab(textAlignment: alignment(fromWireCode: $0.alignment), location: $0.location, options: [:])
            }
        }
        return style
    }

    private static func attributedRun(for run: FastdocTextMeasureRun) -> NSAttributedString {
        let text = run.text.map { String(cString: $0) } ?? ""
        let faceName = run.font_name.map { String(cString: $0) }
        // `font_name` is the face the ENGINE ALREADY RESOLVED — `text_measure.rs:257` reads
        // `font.fontName()` off the attributed string `office_text_builder` built, and the two
        // trait flags beside it are read from that same font. So when the name resolves, the
        // traits are already IN it and re-applying them is not a no-op: `OfficeTextBuilder`
        // measured `.bold` on an already-resolved `-SemiBold` Korean substitute landing on
        // `.AppleKoreanFont-Bold`, a different face (`OfficeTextBuilder.swift:521-535`), which is
        // exactly why the builder gates its own trait step. Re-traiting here re-earned that defect.
        //
        // It was NOT, however, the 1.0pt this port disagreed by on a real paged header: removing it
        // moved that number by nothing, and the cause turned out to be the bare paragraph
        // terminator below. Kept anyway, because the rule it restores is the builder's own and the
        // face it would change is a substituted one — which the English fixture that exposed the
        // 1.0pt never exercises.
        //
        // The traits still describe the run when the face does NOT resolve on this machine — then
        // the fallback is a plain system font and they are the only description left.
        var font: NSFont
        if let resolved = faceName.flatMap({ NSFont(name: $0, size: run.size) }) {
            font = resolved
        } else {
            font = NSFont.systemFont(ofSize: run.size)
            if run.bold || run.italic {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if run.bold { traits.insert(.bold) }
                if run.italic { traits.insert(.italic) }
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: run.size) ?? font
            }
        }
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    /// `.bounds` alone does NOT govern layout for a plain `NSTextAttachment` with no image and no
    /// custom cell — measured: `NSLayoutManager` collapses it to the default "missing image" glyph
    /// (~1×15pt) regardless of `.bounds`, silently losing whatever height the reserved box was
    /// supposed to hold. `OfficeTextBuilder.appendImage` never hits this because it always sets
    /// `attachmentCell = SizedAttachmentCell(reservedSize:)`, whose `cellSize()` is what TextKit
    /// actually asks for — so the mirror here has to build the SAME cell, not just copy `.bounds`.
    private static func attributedAttachment(for run: FastdocTextMeasureRun) -> NSAttributedString {
        let size = CGSize(width: run.attachment_width, height: run.attachment_height)
        let attachment = NSTextAttachment()
        attachment.bounds = CGRect(origin: .zero, size: size)
        attachment.attachmentCell = SizedAttachmentCell(reservedSize: size)
        return NSAttributedString(attachment: attachment)
    }

    /// swift: the wire code for `alignment` — the inverse of `alignment(fromWireCode:)`, used only
    /// to build a payload FROM an `NSAttributedString` (`makePayload` below). Kept the mirror of
    /// `alignment_code` in `text_measure.rs` for the same reason that function is: AppKit's own
    /// `NSTextAlignment` raw values do not happen to match the engine's wire order.
    private static func wireCode(for alignment: NSTextAlignment) -> UInt8 {
        switch alignment {
        case .left: return 0
        case .right: return 1
        case .center: return 2
        case .justified: return 3
        default: return 4
        }
    }

    /// Flattens an `NSAttributedString` into a `FastdocTextMeasurePayload` the SAME way the
    /// engine's own `ResolvedText::from_attributed_string` does — paragraph-style run ranges
    /// first, then the `Font`/`Attachment` runs inside each — so `measure(_:widthPoints:)` can be
    /// exercised from Swift alone. What it proves is narrower than the cross-process check and
    /// still worth having: that this file's OWN mapping is lossless for content
    /// `OfficeTextBuilder` already built. The live comparison — Rust's decision against the host's,
    /// across the FFI — is `headerBandHeight` below, and the two tests are named apart so neither
    /// is mistaken for the other. Kept `internal`, not `private`, for that one caller.
    static func makePayload(from attr: NSAttributedString) -> (FastdocTextMeasurePayload, AnyObject) {
        let storage = PayloadStorage()
        let whole = NSRange(location: 0, length: attr.length)
        let ns = attr.string as NSString

        // Paragraphs are found by the NEWLINE, exactly as `OfficeTextBuilder.unifyParagraphTerminators`
        // finds them (`enumerateSubstrings(options: .byParagraphs)`) — never by where `.paragraphStyle`
        // happens to change. `unifyParagraphTerminators` deliberately copies the paragraph's own
        // inheritable attributes (`.font` included) onto its terminating "\n", so that character reads
        // as part of the SAME `.paragraphStyle`/`.font` run as the text before it: grouping by
        // attribute equality merged text and terminator into one run and handed the terminator's own
        // "\n" back as literal RUN TEXT — which `measure(_:widthPoints:)` then followed with a SECOND,
        // synthetic "\n" of its own (a genuine extra blank paragraph, wrong in the same direction for
        // every paragraph in a document). Splitting on the newline instead can never make that
        // mistake, because the terminator is never inside a paragraph's captured content range.
        var paragraphRanges: [NSRange] = []
        ns.enumerateSubstrings(in: whole, options: .byParagraphs) { _, _, enclosing, _ in
            if enclosing.length > 0 { paragraphRanges.append(enclosing) }
        }

        for (index, range) in paragraphRanges.enumerated() {
            let style = (attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
                ?? NSParagraphStyle.default
            // The paragraph's CONTENT only — its terminating "\n", when present, is never captured
            // as run text; `measure(_:widthPoints:)` appends exactly one "\n" per paragraph itself.
            var contentRange = range
            if contentRange.length > 0, ns.character(at: contentRange.location + contentRange.length - 1) == 10 {
                contentRange.length -= 1
            }
            let tabStops: [FastdocTextMeasureTabStop] = style.tabStops.map {
                FastdocTextMeasureTabStop(alignment: wireCode(for: $0.alignment), location: $0.location)
            }
            storage.tabStopArrays.append(tabStops)
            let tabStopsPtr = storage.tabStopArrays[storage.tabStopArrays.count - 1].withUnsafeBufferPointer { $0.baseAddress }
            storage.paragraphs.append(FastdocTextMeasureParagraph(
                alignment: wireCode(for: style.alignment),
                line_spacing: style.lineSpacing,
                line_height_multiple: style.lineHeightMultiple,
                minimum_line_height: style.minimumLineHeight,
                maximum_line_height: style.maximumLineHeight,
                spacing_before: style.paragraphSpacingBefore,
                spacing_after: style.paragraphSpacing,
                first_line_head_indent: style.firstLineHeadIndent,
                head_indent: style.headIndent,
                tail_indent: style.tailIndent,
                tab_stops: tabStopsPtr,
                tab_stop_count: tabStops.count))

            guard contentRange.length > 0 else { continue }
            attr.enumerateAttributes(in: contentRange, options: []) { attributes, runRange, _ in
                if let font = attributes[.font] as? NSFont {
                    let faceName = font.fontName.utf8CString
                    let text = (attr.attributedSubstring(from: runRange).string).utf8CString
                    storage.families.append(faceName)
                    storage.texts.append(text)
                    let familyPtr = storage.families[storage.families.count - 1].withUnsafeBufferPointer { $0.baseAddress }
                    let textPtr = storage.texts[storage.texts.count - 1].withUnsafeBufferPointer { $0.baseAddress }
                    let traits = font.fontDescriptor.symbolicTraits
                    storage.runs.append(FastdocTextMeasureRun(
                        paragraph_index: index, kind: FastdocTextMeasureRunKindText,
                        font_name: familyPtr, size: font.pointSize,
                        bold: traits.contains(.bold), italic: traits.contains(.italic),
                        text: textPtr, attachment_width: 0, attachment_height: 0))
                } else if let attachment = attributes[.attachment] as? NSTextAttachment {
                    storage.runs.append(FastdocTextMeasureRun(
                        paragraph_index: index, kind: FastdocTextMeasureRunKindAttachment,
                        font_name: nil, size: 0, bold: false, italic: false, text: nil,
                        attachment_width: attachment.bounds.width, attachment_height: attachment.bounds.height))
                }
            }
        }

        let payload = storage.paragraphs.withUnsafeBufferPointer { paragraphsBuf -> FastdocTextMeasurePayload in
            storage.runs.withUnsafeBufferPointer { runsBuf in
                FastdocTextMeasurePayload(
                    paragraphs: paragraphsBuf.baseAddress, paragraph_count: paragraphsBuf.count,
                    runs: runsBuf.baseAddress, run_count: runsBuf.count)
            }
        }
        return (payload, storage)
    }

    /// Everything `makePayload`'s pointers borrow from — kept alive by the caller
    /// (`withExtendedLifetime`) for exactly the duration of one `measure` call, the same ownership
    /// rule `swiftshim::text_measure`'s module doc states for the Rust-built payload.
    private final class PayloadStorage {
        var families: [ContiguousArray<CChar>] = []
        var texts: [ContiguousArray<CChar>] = []
        var tabStopArrays: [[FastdocTextMeasureTabStop]] = []
        var paragraphs: [FastdocTextMeasureParagraph] = []
        var runs: [FastdocTextMeasureRun] = []
    }

    // MARK: - S5-05: the live cross-process call `RustEngineBridgeTests` needed and did not have.
    //
    // `fastdoc_office_header_band_height` crosses the C ABI TWICE for one answer: once for the
    // document's bytes (Rust reads and normalizes them into headers/footers) and once back into
    // this process for every paragraph's height (through the callback `install()` registers
    // above). Nothing here decides anything about the document — it hands bytes and an extension
    // string to the engine and reads back a number or a reason it could not be produced.

    /// The engine's own decision for a document's running header (or footer) band height, in
    /// points — or `nil` when the engine could not answer (see `lastErrorKind()` for why: no
    /// measurer installed, an unreadable document, or a band the wire format cannot describe).
    /// `fastdoc_office_header_band_height` returns a negative sentinel for every failure case, and
    /// a real height is never negative, so the sentinel can never be mistaken for an answer.
    static func headerBandHeight(_ data: Data, extension ext: String, columnWidth: CGFloat, footer: Bool) -> CGFloat? {
        let raw: Double = data.withUnsafeBytes { buffer -> Double in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return ext.withCString { extensionC in
                fastdoc_office_header_band_height(base, buffer.count, extensionC, Double(columnWidth), footer)
            }
        }
        return raw < 0 ? nil : CGFloat(raw)
    }

    /// The `"kind"` tag out of the engine's last recorded failure (`fastdoc_take_last_error`'s
    /// JSON, `ffi_guard.rs`'s `FfiFailure::to_last_error_json` — the same shape
    /// `RustCanonicalError` decodes elsewhere in this build), read fresh after a call that
    /// returned `nil`. Frees the string it reads, per the library's ownership rule
    /// (`RustEngine.swift`'s `defer` pattern is the precedent).
    static func lastErrorKind() -> String? {
        guard let diagnostic = fastdoc_take_last_error() else { return nil }
        defer { fastdoc_string_free(diagnostic) }
        guard let bytes = String(cString: diagnostic).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return nil
        }
        return object["kind"] as? String
    }
}
#endif
