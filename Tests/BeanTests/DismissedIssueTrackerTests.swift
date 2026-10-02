import XCTest
@testable import Bean

final class DismissedIssueTrackerTests: XCTestCase {
    func testUnrelatedPrefixAndSuffixEditsKeepOnlyTheDismissedOccurrence() {
        let original = "Fix teh and teh words."
        let first = issue(in: original, backwards: false)
        var tracker = DismissedIssueTracker()
        tracker.reset(to: original)
        tracker.dismiss(first)
        let updated = "👩🏽‍💻 \(original) Thanks."
        tracker.update(to: updated)
        XCTAssertTrue(tracker.contains(issue(in: updated, backwards: false)))
        XCTAssertFalse(tracker.contains(issue(in: updated, backwards: true)))
    }

    func testTouchingAnOccurrenceMakesItEligibleAgain() {
        var tracker = DismissedIssueTracker()
        tracker.reset(to: "Fix teh word.")
        tracker.dismiss(issue(in: "Fix teh word.", backwards: false))
        tracker.update(to: "Fix the word.")
        tracker.update(to: "Fix teh word.")
        XCTAssertFalse(tracker.contains(issue(in: "Fix teh word.", backwards: false)))
    }

    func testInsertionAtOccurrenceBoundaryMovesItButInsertionInsideInvalidatesIt() {
        var tracker = DismissedIssueTracker()
        tracker.reset(to: "Fix teh word.")
        tracker.dismiss(issue(in: "Fix teh word.", backwards: false))
        tracker.update(to: "Fix new teh word.")
        XCTAssertTrue(tracker.contains(issue(in: "Fix new teh word.", backwards: false)))
        tracker.update(to: "Fix new te-h word.")
        tracker.update(to: "Fix new teh word.")
        XCTAssertFalse(tracker.contains(issue(in: "Fix new teh word.", backwards: false)))
    }

    func testCanonicalUnicodeRepresentationChangeMovesExactUTF16Range() {
        let original = "Café teh word."
        var tracker = DismissedIssueTracker()
        tracker.reset(to: original)
        tracker.dismiss(issue(in: original, backwards: false))
        let updated = "Cafe\u{301} teh word."
        tracker.update(to: updated)
        XCTAssertTrue(tracker.contains(issue(in: updated, backwards: false)))
    }

    func testWordBoundaryTypingInvalidatesDismissalEvenWhenOldSubstringSurvives() {
        for changed in ["Fix xteh word.", "Fix tehh word."] {
            var tracker = DismissedIssueTracker()
            tracker.reset(to: "Fix teh word.")
            tracker.dismiss(issue(in: "Fix teh word.", backwards: false))
            tracker.update(to: changed)
            tracker.update(to: "Fix teh word.")
            XCTAssertFalse(tracker.contains(issue(in: "Fix teh word.", backwards: false)))
        }
    }

    func testAmbiguousCopiedDraftDoesNotSuppressAnUnprovenOccurrence() {
        let original = "Fix teh word."
        var tracker = DismissedIssueTracker()
        tracker.reset(to: original)
        tracker.dismiss(issue(in: original, backwards: false))
        let duplicated = "\(original) \(original)"
        tracker.update(to: duplicated)
        // The unchanged leading occurrence remains identified by its exact
        // prefix; the newly copied occurrence has never been dismissed.
        XCTAssertTrue(tracker.contains(issue(in: duplicated, backwards: false)))
        XCTAssertFalse(tracker.contains(issue(in: duplicated, backwards: true)))
    }

    private func issue(in text: String, backwards: Bool) -> TextIssue {
        let range = (text as NSString).range(of: "teh", options: backwards ? .backwards : [])
        return TextIssue(range: range, original: "teh", suggestion: "the", explanation: nil,
                         type: .spelling, confidence: 1, source: .local)
    }
}
