import Foundation
import XCTest
@testable import Bean

final class InlineIssueMappingTests: XCTestCase {
    private func issue(_ original: String, _ suggestion: String, at range: NSRange) -> TextIssue {
        TextIssue(range: range, original: original, suggestion: suggestion, explanation: nil,
                  type: .spelling, confidence: 1, source: .local)
    }

    func testRepeatedMisspellingsKeepTheirExactIndividualOffsets() {
        let value = "teh first and teh second"
        let first = issue("teh", "the", at: NSRange(location: 0, length: 3))
        let second = issue("teh", "the", at: NSRange(location: 14, length: 3))
        XCTAssertEqual(InlineIssueMapping.resolvedRange(for: first, in: value), first.range)
        XCTAssertEqual(InlineIssueMapping.resolvedRange(for: second, in: value), second.range)
        XCTAssertEqual(InlineIssueMapping.expectedValue(afterApplying: second, to: value),
                       "teh first and the second")
    }

    func testUnusableRangeNeedsAUniqueOriginalBeforeRelocation() {
        let unknown = issue("teh", "the", at: NSRange(location: NSNotFound, length: 3))
        XCTAssertNil(InlineIssueMapping.resolvedRange(for: unknown, in: "teh and teh"))
        XCTAssertEqual(InlineIssueMapping.resolvedRange(for: unknown, in: "one teh"),
                       NSRange(location: 4, length: 3))
    }

    func testConfirmedEditShiftsRepeatedIssuesUsingUTF16AndKeepsReadingOrder() {
        let value = "👩🏽‍💻 wierd then teh and teh"
        let text = value as NSString
        let applied = issue("wierd", "weirdly", at: text.range(of: "wierd"))
        let firstRange = text.range(of: "teh")
        let secondRange = text.range(of: "teh", options: .backwards)
        let first = issue("teh", "the", at: firstRange)
        let second = issue("teh", "the", at: secondRange)
        let after = "👩🏽‍💻 weirdly then teh and teh"
        let remaining = InlineIssueMapping.issuesAfterApplying(applied, to: [applied, first, second],
                                                             valueBefore: value, valueAfter: after)
        XCTAssertEqual(remaining.map(\.id), [first.id, second.id])
        XCTAssertEqual(remaining.map(\.range.location), [firstRange.location + 2, secondRange.location + 2])
        XCTAssertEqual(InlineIssueMapping.expectedValue(afterApplying: remaining[1], to: after),
                       "👩🏽‍💻 weirdly then teh and the")
    }

    func testOverlapAndUnexpectedFieldChangesInvalidateDependentSuggestions() {
        let value = "a teh draft"
        let applied = issue("teh", "the", at: NSRange(location: 2, length: 3))
        let overlap = issue("teh draft", "the writing", at: NSRange(location: 2, length: 9))
        XCTAssertTrue(InlineIssueMapping.issuesAfterApplying(applied, to: [applied, overlap],
                                                           valueBefore: value, valueAfter: "a the draft").isEmpty)
        let next = issue("draft", "message", at: NSRange(location: 6, length: 5))
        XCTAssertTrue(InlineIssueMapping.issuesAfterApplying(applied, to: [next],
                                                           valueBefore: value, valueAfter: "a the newer draft").isEmpty)
    }

    func testNativeFixNeverSplitsUnicodeOrChangesLineBoundaries() {
        let emoji = issue("👩🏽‍💻", "developer", at: NSRange(location: 0, length: 1))
        XCTAssertNil(InlineIssueMapping.expectedValue(afterApplying: emoji, to: "👩🏽‍💻 draft"))
        let multiline = issue("teh", "the\n", at: NSRange(location: 0, length: 3))
        XCTAssertNil(InlineIssueMapping.resolvedRange(for: multiline, in: "teh draft"))
        XCTAssertNil(InlineIssueMapping.expectedValue(afterApplying: multiline, to: "teh draft"))
    }

    func testCaretAndSelectionSurviveCorrectionsBeforeWhereTheUserWasWriting() {
        let edited = NSRange(location: 3, length: 5)
        XCTAssertEqual(InlineIssueMapping.selectionAfterReplacing(edited, replacementLength: 7,
                                                                selection: NSRange(location: 18, length: 0),
                                                                originalLength: 20),
                       NSRange(location: 20, length: 0))
        XCTAssertEqual(InlineIssueMapping.selectionAfterReplacing(edited, replacementLength: 7,
                                                                selection: NSRange(location: 1, length: 18),
                                                                originalLength: 20),
                       NSRange(location: 1, length: 20))
        XCTAssertEqual(InlineIssueMapping.selectionAfterReplacing(edited, replacementLength: 7,
                                                                selection: NSRange(location: 5, length: 0),
                                                                originalLength: 20),
                       NSRange(location: 10, length: 0))
        XCTAssertEqual(InlineIssueMapping.selectionAfterReplacing(edited, replacementLength: 7,
                                                                selection: NSRange(location: 1, length: 0),
                                                                originalLength: 20),
                       NSRange(location: 1, length: 0))
    }

    func testInvalidSelectionCannotBeRestoredOutsideTheField() {
        XCTAssertNil(InlineIssueMapping.selectionAfterReplacing(NSRange(location: 3, length: 5),
                                                               replacementLength: 7,
                                                               selection: NSRange(location: 18, length: 4),
                                                               originalLength: 20))
    }
}
