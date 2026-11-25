import XCTest
@testable import FastDocReader

/// `PlanJSON` writes what `JSONSerialization` writes, as far as a reader can tell: both parse back to
/// equal objects.
final class PlanJSONTests: XCTestCase {
    private func parsed(_ data: Data?) throws -> NSDictionary? {
        try JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? NSDictionary
    }

    func testThePlanInputParsesBackAsFoundationWritesIt() throws {
        let input: [String: Any] = [
            "planVersion": 1, "contentHeight": 841.89, "splitTables": false, "truncated": true,
            "noteBands": [] as [Any], "lines": [12.5, 0.1 + 0.2, 1e-7, 3.0, -2.25, 123456789.125],
            "lineLocs": [0, 12, 30], "name": "a \"quoted\" \\ tab\t line\n 한글",
            "cell": [1, 2, 3] as [Any], "flag": NSNumber(value: true), "count": NSNumber(value: 7),
            "ratio": NSNumber(value: 0.75), "cg": CGFloat(10.5),
            "blocks": [["key": 501, "kind": "text", "rows": [["height": 20.0, "cells": [] as [[String: Any]]]]]] as [[String: Any]],
        ]
        XCTAssertEqual(try parsed(PlanJSON.data(input)), try parsed(JSONSerialization.data(withJSONObject: input)))
        // Parsed NSNumbers compare a Bool equal to 1, so the literals are checked in the text.
        let text = String(decoding: try XCTUnwrap(PlanJSON.data(input)), as: UTF8.self)
        XCTAssertTrue(text.contains("\"flag\":true") && text.contains("\"splitTables\":false") && text.contains("\"planVersion\":1"))
    }

    func testANonFiniteNumberIsRefused() {
        XCTAssertNil(PlanJSON.data(["x": Double.nan] as [String: Any]))
        XCTAssertNil(PlanJSON.data(["x": Date()] as [String: Any]))
    }
}
