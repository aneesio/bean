import XCTest
@testable import Bean

final class WritingActionTests: XCTestCase {
    func testOnlyProofreadingActionsReplaceDirectly() {
        for action in WritingAction.allCases {
            let isProofreading = action == .proofread || action == .localQuickCheck
            XCTAssertEqual(action.allowsDirectReplace, isProofreading, "Unexpected policy for \(action)")
            XCTAssertEqual(action.requiresPreview, !isProofreading, "Unexpected preview policy for \(action)")
        }
    }

    func testLocalQuickCheckDoesNotUseProvider() {
        XCTAssertFalse(WritingAction.localQuickCheck.usesProvider)
        XCTAssertTrue(WritingAction.allCases.filter { $0 != .localQuickCheck }.allSatisfy(\.usesProvider))
        XCTAssertEqual(LocalQuickChecker.corrected("teh  test", dictionary: []), "the test")
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
