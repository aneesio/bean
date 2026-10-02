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

    func testAccessibilityStepExplainsUserTriggeredDirectReplacement() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Accept a suggestion, or run Proofread to replace the current text in one action."))
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

    func testPermissionRecoveryPreservesSetupAndReadyReviewUsesExistingResetFlow() throws {
        let suite = "bean.onboarding-recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.onboardingComplete = true
        settings.onboardingStepRawValue = OnboardingStep.ready.rawValue
        var permissionRecoveryCount = 0
        let actions = SettingsActions(checkPermissions: {}, resetOnboarding: {
            settings.onboardingComplete = false
            settings.onboardingStepRawValue = OnboardingStep.welcome.rawValue
        }, openReadme: {}, openTesting: {}, fullReset: {
            FullResetResult(completedAreas: [], failures: [], skippedAreas: [], terminationRequested: false)
        }, applyShortcut: { _, _ in nil })

        actions.reviewSetupOrRecoverAccessibility(accessibilityGranted: false) { permissionRecoveryCount += 1 }
        XCTAssertEqual(permissionRecoveryCount, 1)
        XCTAssertTrue(settings.onboardingComplete, "Recovering one permission must not restart completed setup")
        XCTAssertEqual(settings.onboardingStepRawValue, OnboardingStep.ready.rawValue)

        actions.reviewSetupOrRecoverAccessibility(accessibilityGranted: true) { permissionRecoveryCount += 1 }
        XCTAssertEqual(permissionRecoveryCount, 1, "Review Setup does not open macOS permission recovery")
        XCTAssertFalse(settings.onboardingComplete)
        XCTAssertEqual(settings.onboardingStepRawValue, OnboardingStep.welcome.rawValue)
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
