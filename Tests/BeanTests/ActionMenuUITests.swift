import XCTest
@testable import Bean

@MainActor
final class ActionMenuUITests: XCTestCase {
    func testPreviewCommunicatesCapturedScopeAndSourceApp() {
        let selected = PreviewModel(
            actionName: "Make Clearer",
            transformedText: "Clear result",
            originalText: "Original",
            sourceAppName: "Mail",
            captureLabel: "Selected text"
        )
        let wholeField = PreviewModel(
            actionName: "AI Proofread",
            transformedText: "Fixed",
            sourceAppName: "Slack",
            captureLabel: "Whole field"
        )

        XCTAssertEqual(selected.sourceSummary, "Selected text in Mail")
        XCTAssertEqual(wholeField.sourceSummary, "Whole field in Slack")
    }

    func testKeyboardNavigationWrapsThroughVisibleActions() {
        let actions = WritingAction.primaryActions
        XCTAssertEqual(ActionMenuKeyboardNavigation.adjacentAction(
            to: nil, offset: 1, in: actions), actions.first)
        XCTAssertEqual(ActionMenuKeyboardNavigation.adjacentAction(
            to: nil, offset: -1, in: actions), actions.last)
        XCTAssertEqual(ActionMenuKeyboardNavigation.adjacentAction(
            to: actions.last, offset: 1, in: actions), actions.first)
        XCTAssertEqual(ActionMenuKeyboardNavigation.adjacentAction(
            to: actions.first, offset: -1, in: actions), actions.last)
        XCTAssertNil(ActionMenuKeyboardNavigation.adjacentAction(
            to: nil, offset: 1, in: []))
    }

    func testSourceAnchorChoosesItsDisplayBeforePointerFallback() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        ]
        let sourceOnSecondDisplay = CGRect(x: 1_250, y: 300, width: 400, height: 120)

        XCTAssertEqual(ActionMenuController.preferredScreenIndex(
            sourceAnchorRect: sourceOnSecondDisplay,
            pointerLocation: CGPoint(x: 200, y: 200),
            screenFrames: screens
        ), 1)
        XCTAssertEqual(ActionMenuController.preferredScreenIndex(
            sourceAnchorRect: nil,
            pointerLocation: CGPoint(x: 200, y: 200),
            screenFrames: screens
        ), 0)
        XCTAssertNil(ActionMenuController.preferredScreenIndex(
            sourceAnchorRect: sourceOnSecondDisplay,
            pointerLocation: .zero,
            screenFrames: []
        ))
    }

    func testHUDSourceAnchorChoosesItsDisplayBeforePointerFallback() {
        let screens = [
            CGRect(x: -1_000, y: 0, width: 1_000, height: 800),
            CGRect(x: 0, y: 0, width: 1_000, height: 800)
        ]
        let sourceOnLeftDisplay = CGRect(x: -750, y: 240, width: 300, height: 100)

        XCTAssertEqual(StatusHUD.preferredScreenIndex(
            sourceAnchorRect: sourceOnLeftDisplay,
            pointerLocation: CGPoint(x: 300, y: 300),
            screenFrames: screens
        ), 0)
        XCTAssertEqual(StatusHUD.preferredScreenIndex(
            sourceAnchorRect: nil,
            pointerLocation: CGPoint(x: 300, y: 300),
            screenFrames: screens
        ), 1)
        XCTAssertNil(StatusHUD.preferredScreenIndex(
            sourceAnchorRect: sourceOnLeftDisplay,
            pointerLocation: .zero,
            screenFrames: []
        ))
    }

    func testHUDGenerationRejectsStaleDismissalAndAnimationCompletions() {
        var generation = StatusHUDPresentationGeneration()

        let firstPresentation = generation.advance()
        XCTAssertTrue(generation.isCurrent(firstPresentation))

        let secondPresentation = generation.advance()
        XCTAssertFalse(generation.isCurrent(firstPresentation))
        XCTAssertTrue(generation.isCurrent(secondPresentation))

        let dismissalAnimation = generation.advance()
        XCTAssertFalse(generation.isCurrent(secondPresentation))
        XCTAssertTrue(generation.isCurrent(dismissalAnimation))

        let replacementPresentation = generation.advance()
        XCTAssertFalse(generation.isCurrent(dismissalAnimation))
        XCTAssertTrue(generation.isCurrent(replacementPresentation))
    }

    func testStatusMessagesIncludeSourceWithoutChangingUnknownSourceCopy() {
        XCTAssertEqual(StatusHUD.sourceAwareMessage("Selected text fixed", sourceAppName: "Mail"),
                       "Selected text fixed — Mail")
        XCTAssertEqual(StatusHUD.sourceAwareMessage("Result copied", sourceAppName: nil),
                       "Result copied")
        XCTAssertEqual(StatusHUD.sourceAwareMessage("Result copied", sourceAppName: "  "),
                       "Result copied")
    }

    func testReduceMotionRemovesHUDTransitions() {
        XCTAssertEqual(StatusHUD.animationDuration(reduceMotion: true, appearing: true), 0)
        XCTAssertEqual(StatusHUD.animationDuration(reduceMotion: true, appearing: false), 0)
        XCTAssertGreaterThan(StatusHUD.animationDuration(reduceMotion: false, appearing: true), 0)
        XCTAssertGreaterThan(StatusHUD.animationDuration(reduceMotion: false, appearing: false), 0)
    }

    func testActionNoticesRequireExplicitDismissal() {
        let notice = ActionNotice(
            title: "Review Needed",
            message: "Bean needs your decision.",
            kind: .warning,
            primaryAction: .init("Continue", handler: {})
        )
        XCTAssertEqual(notice.dismissalPolicy, .explicitUserAction)
    }

    func testPreviewDefaultsMakeProviderRegenerationExplicit() {
        let model = PreviewModel(
            actionName: "Make Clearer",
            transformedText: "Clear result",
            originalText: "Original"
        )

        XCTAssertEqual(model.retryButtonTitle, "Generate Again · uses AI")
        XCTAssertTrue(model.showsRetryButton)
        XCTAssertTrue(model.showsAIIndicator)
    }

    func testRecoveryCanDescribeReplacementWithoutImplyingGeneration() {
        let model = PreviewModel(
            actionName: "Replacement Recovery",
            transformedText: "Corrected",
            originalText: "Original"
        )

        model.showsAIIndicator = false

        XCTAssertEqual(model.retryButtonTitle, "Retry Replacement")
        XCTAssertFalse(model.showsAIIndicator)
    }

    func testWeakPreviewHandlerInvokesWithLiveModelWithoutRetainingIt() {
        var model: PreviewModel? = PreviewModel(
            actionName: "Proofread",
            transformedText: "Corrected",
            originalText: "Original"
        )
        weak var releasedModel = model
        let expectedID = model.map(ObjectIdentifier.init)
        var handledID: ObjectIdentifier?

        model?.onReplace = model?.weakHandler { handledID = ObjectIdentifier($0) } ?? {}
        model?.onReplace()

        XCTAssertEqual(handledID, expectedID)
        model = nil
        XCTAssertNil(releasedModel, "A stored preview handler must not retain its owning model")
    }

    func testPreviewCancelIsSerializedBehindRunningReplacement() {
        let model = PreviewModel(
            actionName: "Proofread",
            transformedText: "Corrected",
            originalText: "Original"
        )
        var cancellationCount = 0
        model.onCancel = { cancellationCount += 1 }

        model.isRunning = true
        model.cancelIfIdle()
        XCTAssertEqual(
            cancellationCount,
            0,
            "Cancel must not clear replacement state while an async paste can still complete"
        )

        model.isRunning = false
        model.cancelIfIdle()
        XCTAssertEqual(cancellationCount, 1)
    }
}
