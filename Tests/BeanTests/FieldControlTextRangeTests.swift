import Foundation
import XCTest
@testable import Bean

final class FieldControlTextRangeTests: XCTestCase {
    func testVisibleWindowIsUsedRatherThanOffscreenDocumentStart() {
        let value = "Offscreen line.\nVisible line.\nAnother visible line.\n"
        let text = value as NSString
        let start = text.range(of: "Visible").location
        let ranges = TextRangeLocator.fieldControlTextRanges(value: value,
            visibleRange: NSRange(location: start, length: text.length - start))
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertTrue(ranges.allSatisfy { $0.location >= start && NSMaxRange($0) <= text.length })
    }

    func testBeginningAndEndHaveSeparateBoundedBudgets() {
        let value = (0..<150).map { "Synthetic line \($0)." }.joined(separator: "\n")
        let text = value as NSString
        let ranges = TextRangeLocator.fieldControlTextRanges(value: value, visibleRange: nil)
        XCTAssertEqual(ranges.count, 6)
        XCTAssertEqual(ranges.first?.location, 0)
        XCTAssertTrue(ranges.contains { $0.location >= text.length - 512 }, "Beginning lines cannot consume the end sample budget")
    }

    func testWhitespaceAndLongParagraphWorkRemainBounded() {
        XCTAssertEqual(TextRangeLocator.fieldControlTextRanges(value: String(repeating: "\n", count: 100_000), visibleRange: nil), [])
        let long = String(repeating: "draft ", count: 20_000)
        let ranges = TextRangeLocator.fieldControlTextRanges(value: long, visibleRange: nil)
        XCTAssertLessThanOrEqual(ranges.count, 6)
        XCTAssertTrue(ranges.allSatisfy { $0.length <= 512 })
        XCTAssertEqual(NSMaxRange(ranges.last!), (long as NSString).length)
    }

    func testComposedCharactersAreNeverSplitAndInvalidWindowsAreClamped() {
        let value = String(repeating: "👩🏽‍💻", count: 100)
        let text = value as NSString
        for visible in [nil, NSRange(location: 3, length: 20), NSRange(location: Int.max, length: Int.max), NSRange(location: -5, length: -1)] {
            let ranges = TextRangeLocator.fieldControlTextRanges(value: value, visibleRange: visible)
            XCTAssertTrue(ranges.allSatisfy { $0.location >= 0 && NSMaxRange($0) <= text.length })
            XCTAssertTrue(ranges.allSatisfy { text.rangeOfComposedCharacterSequences(for: $0) == $0 })
        }
    }
}
