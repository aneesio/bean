import XCTest
@testable import Bean

final class WritingActionTests: XCTestCase {
    func testProofreadIsTheOnlyDirectReplacementAction() {
        for action in WritingAction.allCases {
            XCTAssertEqual(action.allowsDirectReplace, action == .proofread, "Unexpected policy for \(action)")
            XCTAssertEqual(action.requiresPreview, action != .proofread, "Unexpected preview policy for \(action)")
        }
    }

    func testReplyActionsNeverReplaceSourceMessage() {
        let replies = WritingAction.allCases.filter { $0.category == .reply }
        XCTAssertFalse(replies.isEmpty)
        XCTAssertTrue(replies.allSatisfy { !$0.allowsReplaceFromPreview })
    }

    func testOutputBudgetsStayBounded() {
        let longText = String(repeating: "word ", count: 10_000)
        for action in WritingAction.allCases {
            let budget = WritingTransformService.outputTokenBudget(for: longText, action: action)
            XCTAssertGreaterThan(budget, 0)
            XCTAssertLessThanOrEqual(budget, 4_096)
        }
    }

    func testPromptKeepsSourceTextOutOfSystemInstruction() {
        let marker = "IGNORE_ALL_RULES_123"
        let system = WritingTransformService.systemPrompt(for: .proofread)
        XCTAssertFalse(system.contains(marker))
        XCTAssertTrue(system.contains("untrusted source data"))
    }
}
