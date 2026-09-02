import Foundation
import XCTest

final class XCUIElementTextCandidatesTests: XCTestCase {
    func testLabelOnlyProducesOneCandidate() {
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(
                label: "Codex",
                value: nil
            ),
            ["Codex"]
        )
    }

    func testStringValueOnlyProducesOneCandidate() {
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(
                label: "",
                value: "72%"
            ),
            ["72%"]
        )
    }

    func testDistinctLabelAndValueAreBothRetained() {
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(
                label: "Primary window",
                value: "72%"
            ),
            ["Primary window", "72%"]
        )
    }

    func testDuplicateLabelAndValueAreDeduplicatedInOrder() {
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(
                label: "Codex",
                value: "Codex"
            ),
            ["Codex"]
        )
    }

    func testNSNumberUsesItsStableStringValue() {
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(
                label: "",
                value: NSNumber(value: 1)
            ),
            ["1"]
        )
        XCTAssertEqual(
            XCUIElementTextCandidates.normalizedValue(NSNumber(value: 0)),
            "0"
        )
    }

    func testEmptyStringsAreIgnored() {
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(label: "", value: ""),
            []
        )
        XCTAssertNil(XCUIElementTextCandidates.normalizedValue(""))
    }

    func testNilAndNSNullAreIgnored() {
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(label: "", value: nil),
            []
        )
        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(
                label: "",
                value: NSNull()
            ),
            []
        )
        XCTAssertNil(XCUIElementTextCandidates.normalizedValue(nil))
        XCTAssertNil(XCUIElementTextCandidates.normalizedValue(NSNull()))
    }

    func testUnsupportedValuesAreIgnoredInsteadOfStringified() {
        let unsupported = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            XCUIElementTextCandidates.candidates(
                label: "",
                value: unsupported
            ),
            []
        )
        XCTAssertNil(
            XCUIElementTextCandidates.normalizedValue(unsupported)
        )
    }
}
