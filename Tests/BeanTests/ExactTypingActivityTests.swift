import XCTest
@testable import Bean

final class ExactTypingActivityTests: XCTestCase {
    func testNormalizationChangeTriggersFreshCheckWithUnchangedVisualText() {
        var tracker = TypingPauseActivityTracker()
        XCTAssertEqual(tracker.observe(.init(processIdentifier: 1, fieldIdentity: 1,
            value: "café", acceptsTextInput: true)), .focusChanged)
        XCTAssertEqual(tracker.observe(.init(processIdentifier: 1, fieldIdentity: 1,
            value: "cafe\u{301}", acceptsTextInput: true)), .textChanged)
        XCTAssertEqual(tracker.observe(.init(processIdentifier: 1, fieldIdentity: 1,
            value: "cafe\u{301}", acceptsTextInput: true)), .unchanged)
    }
}
