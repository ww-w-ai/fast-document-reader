import AppKit

/// Numbers drawn in the margin beside the text: which line you are on in a text file, which page you
/// are on in a document that has pages. One toggle, because it answers one question — "where am I?" —
/// and the answer's UNIT is a property of the document rather than a second choice for the reader to
/// make (the owner's framing: *"doc, hwp, odt 에서 페이지 번호, 일반 txt, md 등은 라인 번호… 페이지로
/// 나눠보기 옵션이 없을 때에는 라인 번호로 통일"*).
///
/// Deliberately NOT part of `PageViewOptions`: that struct's outline is a master switch over its own
/// three members (`underOutlineRule`), and line numbers must keep working in a document with no pages
/// at all — folding them in would put them under a rule that has nothing to say about them.
enum MarginNumberUnit: Equatable {
    /// The document's own paragraph/line count — every format has this.
    case lines
    /// The page a line sits on. Only ever chosen for a document that HAS pages AND is drawing them:
    /// with the outline off there is no page grid on screen to number against.
    case pages
}

/// The stored preference, in the shape of `PageViewOptionsStore`: one key, read on demand, global
/// rather than per window (a reader who wants to see line numbers wants them for every file, and the
/// choice has to survive a relaunch to be worth making).
enum MarginNumberStore {
    private static let key = "marginNumbersVisible"

    /// OFF by default. Unlike the page outline — which REPLACES a rule the reader was already drawing
    /// — this adds furniture that was never there, and a reader who wants it will look for it.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Test seam — back to "never written", so a case starts from the real default.
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    /// The unit a JUMP uses. Deliberately NOT `unit(...)`: that one answers "what is drawn", and
    /// returns nothing while the toggle is off — but a reader can ask to go to page 40 of a document
    /// whose numbers are hidden, and the unit of that request is still the document's own.
    static func jumpUnit(paged: Bool, drawingPages: Bool) -> MarginNumberUnit {
        unit(isOn: true, paged: paged, drawingPages: drawingPages) ?? .lines
    }

    /// What a given document shows. `nil` = nothing to draw.
    ///
    /// The unit is decided HERE, once, from two facts the caller already has, so the menu, the painter
    /// and any test all read the same answer rather than each re-deriving it.
    static func unit(isOn: Bool = MarginNumberStore.isOn,
                     paged: Bool, drawingPages: Bool) -> MarginNumberUnit? {
        guard isOn else { return nil }
        return (paged && drawingPages) ? .pages : .lines
    }
}

/// Turning a number the reader TYPED into a place in the document. Pure and view-free, so the rule
/// that a jump lands where the number is DRAWN is a unit test rather than something judged by looking.
enum MarginNumberNavigator {

    /// Where line `line` begins, resolved by the SAME rule `ReaderTextView.drawLineNumbers` draws by:
    /// the number is `MDAttr.blockId + 1`, one per block, and a line inside a table carries none.
    ///
    /// Numbers can therefore have GAPS (every table block is missing from the sequence), and a reader
    /// can type one that is out of range. Both are answered by one rule — the first number at or after
    /// the request, or the last one if the request is past the end — so a typed number always lands
    /// somewhere real instead of beeping.
    static func characterIndex(forLine line: Int, in storage: NSAttributedString) -> Int? {
        var firstAtOrAfter: Int?
        var last: Int?
        var seen: Int?
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(MDAttr.blockId, in: whole) { value, range, stop in
            guard let id = value as? Int, id != seen else { return }
            seen = id
            let style = storage.attribute(.paragraphStyle, at: range.location,
                                          effectiveRange: nil) as? NSParagraphStyle
            guard !(style?.textBlocks.first is NSTextTableBlock) else { return }
            last = range.location
            if id + 1 >= line, firstAtOrAfter == nil {
                firstAtOrAfter = range.location
                stop.pointee = true
            }
        }
        return firstAtOrAfter ?? last
    }

    /// Which sheet a typed page number means, clamped into the document's own range. `nil` only when
    /// there are no sheets at all — which is every document the jump would answer in lines instead.
    static func sheetIndex(forPage page: Int, sheetCount: Int) -> Int? {
        guard sheetCount > 0 else { return nil }
        return min(max(1, page), sheetCount) - 1
    }
}
