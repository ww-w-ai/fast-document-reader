import XCTest
import AppKit
import CFastdocEngine
@testable import FastDocReader

/// S3 of `docs/plans/pagination-to-engine.md`: the measurement port's second primitive, the line
/// boxes behind a height. The same payload shapes the C# host's `TextMeasurerPort` tests use
/// (`PagingTests`, "S3 measure_lines"), so the two hosts are asked the same question.
final class RustEngineMeasureLinesTests: XCTestCase {
    private func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size) }

    private func payload(_ paragraphs: [(String, CGFloat, NSParagraphStyle)]) -> (FastdocTextMeasurePayload, AnyObject) {
        let attr = NSMutableAttributedString()
        for (text, size, style) in paragraphs {
            let start = attr.length
            attr.append(NSAttributedString(string: text + "\n", attributes: [.font: font(size)]))
            attr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: attr.length - start))
        }
        return RustEngineMeasure.makePayload(from: attr)
    }

    private func lines(_ built: (FastdocTextMeasurePayload, AnyObject), width: CGFloat) -> [RustEngineMeasure.LineBox] {
        withExtendedLifetime(built.1) { RustEngineMeasure.measureLines(built.0, widthPoints: width) }
    }

    private func height(_ built: (FastdocTextMeasurePayload, AnyObject), width: CGFloat) -> CGFloat {
        withExtendedLifetime(built.1) { RustEngineMeasure.measure(built.0, widthPoints: width) }
    }

    func testLinesAreTheLayoutBehindTheHeightParagraphByParagraph() {
        let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda"
        let built = payload([(text, 12, NSParagraphStyle.default), ("short", 12, NSParagraphStyle.default)])
        let narrow = lines(built, width: 90)
        XCTAssertGreaterThan(narrow.filter { $0.paragraph == 0 }.count, 1, "the long paragraph wraps")
        XCTAssertEqual(narrow.filter { $0.paragraph == 1 }.count, 1)
        // Tops climb and boxes touch. The used height `measure` reports ends no sooner than the last
        // line: TextKit's used rect also holds the empty line after the final terminator.
        for pair in zip(narrow, narrow.dropFirst()) {
            XCTAssertEqual(pair.0.top + pair.0.height, pair.1.top, accuracy: 0.001)
        }
        XCTAssertLessThanOrEqual(narrow.last!.top + narrow.last!.height, height(built, width: 90))
        // A line ends where its paragraph's text does, never counting the terminator.
        XCTAssertEqual(narrow.filter { $0.paragraph == 0 }.last!.charEnd, (text as NSString).length)
        XCTAssertEqual(narrow.last!.charEnd, 5)
        XCTAssertTrue(narrow.allSatisfy { $0.baseline > 0 && $0.baseline < $0.height })
    }

    func testTheParagraphStyleTheEngineResolvedGovernsTheBox() {
        let spaced = NSMutableParagraphStyle()
        spaced.minimumLineHeight = 30
        spaced.maximumLineHeight = 30
        let built = payload([("one line", 12, spaced)])
        XCTAssertEqual(lines(built, width: 300).map(\.height), [30])
    }

    func testAnEmptyParagraphStillStandsOneLine() {
        let built = payload([("", 12, NSParagraphStyle.default), ("x", 12, NSParagraphStyle.default)])
        let all = lines(built, width: 300)
        XCTAssertEqual(all.map(\.paragraph), [0, 1])
        XCTAssertEqual(all[0].charEnd, 0)
    }

    func testTheReadingOfALiveLayoutIsTheSameBoxTheMeasurementPassMakes() {
        // The shadow reads fragments TextKit already laid out; the port builds and lays out its own.
        // Both go through `observedLineBox`, so one layout must read the same either way.
        let storage = NSTextStorage(string: "alpha beta gamma delta epsilon zeta eta theta iota\n", attributes: [.font: font(12)])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 80, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var observed: [RustEngineMeasure.LineBox] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, glyphRange, _ in
            observed.append(RustEngineMeasure.observedLineBox(
                layout: layout, rect: rect, glyphRange: glyphRange, paragraph: 0, paragraphStart: 0, contentLength: storage.length - 1))
        }
        let built = payload([("alpha beta gamma delta epsilon zeta eta theta iota", 12, NSParagraphStyle.default)])
        let viaPort = lines(built, width: 80)
        XCTAssertEqual(observed.count, viaPort.count)
        XCTAssertEqual(observed.map(\.height), viaPort.map(\.height))
        XCTAssertEqual(observed.map(\.charEnd), viaPort.map(\.charEnd))
    }
}
