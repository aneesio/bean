import XCTest
@testable import Bean

final class NativeAssistantStateTests: XCTestCase {
    func testCheckingCleanAndUnavailableStatesCannotBeConfused() {
        var state = NativeAssistantState(phase: .checkingLocal)
        XCTAssertFalse(state.hasSuggestions)
        XCTAssertTrue(state.isBusy)
        state.phase = .complete
        XCTAssertFalse(state.hasSuggestions)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.title.contains("basic grammar"))
        XCTAssertTrue(state.detail.contains("do not mean the text is error-free"))
        state.phase = .unavailable("cannotReadText")
        XCTAssertFalse(state.hasSuggestions)
        XCTAssertTrue(state.detail.contains("does not expose readable text"))
        XCTAssertFalse(state.title.contains("No spelling"))
    }

    func testScopeLabelsAgreeAndReviewCountIsExact() {
        var state = NativeAssistantState(phase: .complete, issueCount: 1, scope: "selected text")
        XCTAssertEqual(state.proofreadLabel, "Proofread selected text")
        XCTAssertEqual(state.rewriteLabel, "Rewrite selected text")
        XCTAssertEqual(state.title, "1 writing suggestion")
        XCTAssertTrue(state.hasSuggestions)
        state.issueCount = 3
        XCTAssertEqual(state.title, "3 writing suggestions")
    }

    func testProviderFailureKeepsBasicCompletionTruthful() {
        var state = NativeAssistantState(phase: .complete)
        state.limitation = "providerFailed"
        XCTAssertTrue(state.title.contains("basic grammar"))
        XCTAssertTrue(state.detail.contains("temporarily unavailable"))
        XCTAssertFalse(state.isBusy)
    }

    func testIncompleteLocalCoverageNeverClaimsAFullCleanCheck() {
        var state = NativeAssistantState(phase: .complete)
        state.localLimitation = "limitReached"
        XCTAssertEqual(state.title, "No suggestions in checked text")
        XCTAssertTrue(state.detail.contains("Checked part"))
        state.localLimitation = "unavailable"
        XCTAssertTrue(state.detail.contains("Full local spelling is unavailable"))
        state.localLimitation = "invalidResponse"
        XCTAssertTrue(state.detail.contains("couldn’t finish"))
    }
}
