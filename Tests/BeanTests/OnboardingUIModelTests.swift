import XCTest
@testable import Bean

@MainActor
final class OnboardingUIModelTests: XCTestCase {
    func testOnboardingHasExactlyThreeOrderedSteps() {
        XCTAssertEqual(
            OnboardingStep.allCases.map(\.rawValue),
            [
                OnboardingStep.welcome.rawValue,
                OnboardingStep.accessibility.rawValue,
                OnboardingStep.ready.rawValue
            ]
        )
    }

    func testAccessibilityStepPromisesApprovalBeforeReplacement() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Bean never replaces text until you approve it."))
        XCTAssertFalse(source.contains("Bean only acts when you ask it to."))
    }

    func testOnboardingMinimumIsAppliedToWindowContent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/WindowPresenter.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "window.contentMinSize = NSSize(width: 600, height: 620)"
        ))
        XCTAssertFalse(source.contains(
            "window.minSize = NSSize(width: 600, height: 620)"
        ), "A titled window's frame minimum is smaller than this required content area")
    }

    func testPermissionRefreshUsesInjectedChecker() {
        var granted = false
        let model = AccessibilityPermissionModel(check: { granted })

        XCTAssertFalse(model.granted)
        granted = true
        model.refresh()

        XCTAssertTrue(model.granted)
    }

    func testBriefPermissionPollingStopsAfterGrant() async throws {
        var checks = 0
        let model = AccessibilityPermissionModel(
            check: {
                checks += 1
                return checks >= 2
            },
            pollIntervalNanoseconds: 1_000_000,
            maximumPollCount: 10
        )

        XCTAssertFalse(model.granted)
        model.beginBriefPolling()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(model.granted)
        model.stopPolling()
    }
}
