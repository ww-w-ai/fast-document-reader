import XCTest
@testable import FastDocReader

/// S18 — a form control is something to READ.
///
/// Measured over the 637-sample corpus (`examples/scan_forms.rs`): 12 documents (1.9%) embed a form
/// control, and between them they hold 406 — **365 checkboxes (90%)**, 17 radio buttons, 11 buttons,
/// 8 edit fields, 5 combo boxes. The document count is small and misleading: a document that has any
/// tends to BE a form, where the controls are the content. `samples/form-02.hwp` rendered as a
/// completely blank page before this existed, because every control arrives on a zero-width anchor
/// span with no text of its own.
final class FormControlTests: XCTestCase {

    // MARK: what a control looks like on the page

    /// 90% of the corpus's controls. A ticked box has to read as ticked with no legend beside it.
    func testACheckBoxShowsWhetherItIsTicked() {
        let unticked = OfficeFormControl(kind: .checkBox, caption: "동의")
        let ticked = OfficeFormControl(kind: .checkBox, caption: "동의", value: 1)
        XCTAssertEqual(unticked.displayText, "☐ 동의")
        XCTAssertEqual(ticked.displayText, "☒ 동의")
        XCTAssertFalse(unticked.isTicked)
        XCTAssertTrue(ticked.isTicked)
    }

    func testARadioButtonShowsWhetherItIsChosen() {
        XCTAssertEqual(OfficeFormControl(kind: .radioButton, caption: "남").displayText, "○ 남")
        XCTAssertEqual(OfficeFormControl(kind: .radioButton, caption: "남", value: 1).displayText, "◉ 남")
    }

    /// A control with no label is still a control — the box must appear, or a form loses the very
    /// thing the reader is looking for.
    func testAnUnlabelledBoxStillAppears() {
        XCTAssertEqual(OfficeFormControl(kind: .checkBox).displayText, "☐")
        XCTAssertEqual(OfficeFormControl(kind: .checkBox, value: 1).displayText, "☒")
    }

    func testAButtonIsItsFace() {
        XCTAssertEqual(OfficeFormControl(kind: .pushButton, caption: "명령 단추").displayText,
                       "[ 명령 단추 ]")
    }

    /// An empty field is a RULE, not nothing: a blank form still has to show where the answers go,
    /// which is the whole point of printing one.
    func testAnEmptyFieldIsStillDrawn() {
        XCTAssertEqual(OfficeFormControl(kind: .edit).displayText, "[________]")
        XCTAssertEqual(OfficeFormControl(kind: .edit, text: "홍길동").displayText, "[ 홍길동 ]")
    }

    func testAComboShowsWhatItHolds() {
        XCTAssertEqual(OfficeFormControl(kind: .comboBox, caption: "지역", text: "서울").displayText,
                       "[ 서울 ▾ ]")
        XCTAssertEqual(OfficeFormControl(kind: .comboBox, caption: "지역").displayText,
                       "[ 지역 ▾ ]", "with nothing chosen, the label stands in")
    }

    /// A control kind this reader has no shape for must not vanish — an unknown control is still
    /// something the document put there.
    func testAnUnknownControlKeepsWhateverLabelItHas() {
        XCTAssertEqual(OfficeFormControl.Kind(exported: "spinButton"), .unknown)
        XCTAssertEqual(OfficeFormControl(kind: .unknown, caption: "무언가").displayText, "[ 무언가 ]")
        XCTAssertEqual(OfficeFormControl(kind: .unknown).displayText, "",
                       "but an unknown control with nothing to say adds nothing")
    }

    // MARK: the decode, from the JSON the exporter really sends

    /// The shape read off `samples/form-02.hwp`.
    func testAFormControlSurvivesTheDecoderAndBecomesText() throws {
        let json = """
        {"v":1,"blocks":[{"t":"para","spans":[\
        {"text":"","form":{"formType":"checkBox","name":"CheckBox","caption":"선택 상자",\
        "widthHwpUnit":7087,"heightHwpUnit":1984,"foreColor":"000000","backColor":"F0F0F0",\
        "value":1,"enabled":true}}]}]}
        """
        guard case let .paragraph(spans, _, _, _, _)? = try HwpReader.mapJSON(json).blocks.first else {
            return XCTFail("expected one paragraph")
        }
        guard let control = spans.compactMap(\.formControl).first else {
            return XCTFail("the control did not reach the reader")
        }
        XCTAssertEqual(control.kind, .checkBox)
        XCTAssertTrue(control.isTicked)
        // The control arrives on a ZERO-WIDTH anchor span. Without giving it text the document
        // renders blank, which is what a corpus form sample did.
        XCTAssertEqual(spans.map(\.text).joined(), "☒ 선택 상자")
    }

    /// A run that already has text keeps it — the control's glyphs stand in for NOTHING, never over
    /// something the document actually wrote.
    func testAControlNeverOverwritesTextTheDocumentWrote() throws {
        let json = """
        {"v":1,"blocks":[{"t":"para","spans":[\
        {"text":"이미 있는 글자","form":{"formType":"checkBox","name":"c","caption":"라벨",\
        "widthHwpUnit":1,"heightHwpUnit":1,"foreColor":"000000","backColor":"FFFFFF","enabled":true}}]}]}
        """
        guard case let .paragraph(spans, _, _, _, _)? = try HwpReader.mapJSON(json).blocks.first else {
            return XCTFail("expected one paragraph")
        }
        XCTAssertEqual(spans.map(\.text).joined(), "이미 있는 글자")
        XCTAssertNotNil(spans.first?.formControl, "and the control is still carried")
    }

    /// `enabled` is carried rather than acted on: a greyed-out control is part of the form and must
    /// still be visible.
    func testADisabledControlIsStillShown() {
        let c = OfficeFormControl(kind: .checkBox, caption: "잠김", value: 1, enabled: false)
        XCTAssertEqual(c.displayText, "☒ 잠김")
        XCTAssertFalse(c.enabled)
    }
}
