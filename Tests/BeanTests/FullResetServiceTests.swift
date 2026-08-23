import XCTest
@testable import Bean

final class FullResetServiceTests: XCTestCase {
    private struct TestError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    func testSuccessfulResetUsesSafeOrderPreservesUnrelatedCredentialsAndQuits() {
        var events: [String] = []
        var credentials = [
            ProviderKind.openai.keychainAccount: "openai-secret",
            ProviderKind.anthropic.keychainAccount: "anthropic-secret",
            "unrelated.account": "keep-me"
        ]

        let service = FullResetService(effects: FullResetEffects(
            deleteProviderKey: { provider in
                events.append("key.\(provider.rawValue)")
                credentials.removeValue(forKey: provider.keychainAccount)
            },
            forgetProviderCredentialCache: { events.append("forget-cache") },
            resetUserContent: { events.append("user-content") },
            disableLoginItem: { events.append("login-item") },
            removeBrowserBridge: {
                events.append("browser-bridge")
                return BrowserBridgeRemovalResult(
                    removedBrowserNames: ["Chrome"], failedBrowserNames: [],
                    manualApprovalCleared: true
                )
            },
            resetAccounting: {
                events.append("accounting")
                return .complete
            },
            clearPreferences: { events.append("preferences") },
            terminateApplication: { events.append("terminate") }
        ))

        let result = service.perform()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.completedAreas, [
            .providerKeys, .userContent, .loginItem, .browserBridge,
            .accounting, .preferences
        ])
        XCTAssertEqual(events, [
            "key.openai", "key.anthropic", "forget-cache", "user-content",
            "login-item", "browser-bridge", "accounting", "preferences", "terminate"
        ])
        XCTAssertNil(credentials[ProviderKind.openai.keychainAccount])
        XCTAssertNil(credentials[ProviderKind.anthropic.keychainAccount])
        XCTAssertEqual(credentials["unrelated.account"], "keep-me")
    }

    @MainActor
    func testExternalFailureIsReportedAndProtectedFinalStoresAreNotCleared() {
        var events: [String] = []
        let service = FullResetService(effects: FullResetEffects(
            deleteProviderKey: { provider in
                events.append("key.\(provider.rawValue)")
                if provider == .anthropic { throw TestError(message: "denied") }
            },
            forgetProviderCredentialCache: { events.append("forget-cache") },
            resetUserContent: { events.append("user-content") },
            disableLoginItem: { events.append("login-item") },
            removeBrowserBridge: {
                events.append("browser-bridge")
                return BrowserBridgeRemovalResult(
                    removedBrowserNames: ["Chrome"], failedBrowserNames: ["Edge"],
                    manualApprovalCleared: false
                )
            },
            resetAccounting: {
                events.append("accounting")
                return .complete
            },
            clearPreferences: { events.append("preferences") },
            terminateApplication: { events.append("terminate") }
        ))

        let result = service.perform()

        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.terminationRequested)
        XCTAssertEqual(result.skippedAreas, [.accounting, .preferences])
        XCTAssertEqual(result.failures.map(\.area), [.providerKeys, .browserBridge])
        XCTAssertTrue(result.failures[0].message.contains("Already cleared"))
        XCTAssertTrue(result.failures[0].message.contains("OpenAI"))
        XCTAssertTrue(result.failures[0].message.contains("Anthropic Claude"))
        XCTAssertTrue(result.failures[1].message.contains("Edge"))
        XCTAssertTrue(result.failures[1].message.contains("Already removed"))
        XCTAssertTrue(result.failures[1].message.contains("Chrome"))
        XCTAssertTrue(result.failures[1].message.contains("manual extension approval"))
        XCTAssertFalse(events.contains("accounting"))
        XCTAssertFalse(events.contains("preferences"))
        XCTAssertFalse(events.contains("terminate"))
        XCTAssertTrue(events.contains("forget-cache"),
                      "deleted Keychain values must never remain usable from process memory")
    }

    @MainActor
    func testPartialPersonalizationEraseIsNeverDescribedAsAllOrNothing() {
        let service = FullResetService(effects: FullResetEffects(
            deleteProviderKey: { _ in },
            forgetProviderCredentialCache: {},
            resetUserContent: { throw UserContentStoreError.unableToErase },
            disableLoginItem: {},
            removeBrowserBridge: {
                BrowserBridgeRemovalResult(
                    removedBrowserNames: [], failedBrowserNames: [],
                    manualApprovalCleared: true
                )
            },
            resetAccounting: { .complete },
            clearPreferences: {},
            terminateApplication: {}
        ))

        let result = service.perform()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failures.map(\.area), [.userContent])
        XCTAssertTrue(result.failures[0].message.contains(
            "Some Bean-owned personalization files may already have been removed"
        ))
        XCTAssertFalse(result.failures[0].message.contains("unchanged"))
        XCTAssertEqual(result.skippedAreas, [.accounting, .preferences])
    }

    @MainActor
    func testAccountingFailureSkipsPreferencesAndDoesNotQuit() {
        var preferencesCalled = false
        var terminated = false
        let service = FullResetService(effects: FullResetEffects(
            deleteProviderKey: { _ in },
            forgetProviderCredentialCache: {},
            resetUserContent: {},
            disableLoginItem: {},
            removeBrowserBridge: {
                BrowserBridgeRemovalResult(
                    removedBrowserNames: [], failedBrowserNames: [],
                    manualApprovalCleared: true
                )
            },
            resetAccounting: { throw TestError(message: "disk unavailable") },
            clearPreferences: { preferencesCalled = true },
            terminateApplication: { terminated = true }
        ))

        let result = service.perform()

        XCTAssertEqual(result.failures.map(\.area), [.accounting])
        XCTAssertEqual(result.skippedAreas, [.preferences])
        XCTAssertFalse(preferencesCalled)
        XCTAssertFalse(terminated)
    }

    @MainActor
    func testPartialBrowserCleanupNamesClearedApprovalWithoutCompletingArea() {
        let service = FullResetService(effects: FullResetEffects(
            deleteProviderKey: { _ in },
            forgetProviderCredentialCache: {},
            resetUserContent: {},
            disableLoginItem: {},
            removeBrowserBridge: {
                BrowserBridgeRemovalResult(
                    removedBrowserNames: ["Chrome"], failedBrowserNames: ["Edge"],
                    manualApprovalCleared: true
                )
            },
            resetAccounting: { .complete },
            clearPreferences: {},
            terminateApplication: {}
        ))

        let result = service.perform()

        XCTAssertFalse(result.completedAreas.contains(.browserBridge))
        let failure = result.failures.first { $0.area == .browserBridge }
        XCTAssertTrue(failure?.message.contains("Already removed Bean's connection for Chrome") == true)
        XCTAssertTrue(failure?.message.contains("Couldn't remove the Bean connection for Edge") == true)
        XCTAssertTrue(failure?.message.contains("saved manual extension approval is now clear") == true)
    }

    func testFullAccountingResetClearsPrivateCapAndRejectsLateSettlement() throws {
        let suiteName = "FullResetAccounting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullResetAccounting-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            directoryURL: directory
        )
        let metadata = AutomaticCallMetadata(
            source: .webInline, appName: "must-not-persist.example",
            appBundleIdentifier: nil, appCategory: "browser",
            action: "detectIssues", inputMode: "textarea", inputLength: 20,
            provider: "test", model: "test"
        )
        guard case .reserved(let reservation) = store.reserve(
            dailyLimit: 5, leaseDuration: 60, metadata: metadata
        ) else {
            return XCTFail("Expected a reservation")
        }
        XCTAssertTrue(reservation.beginProviderAttempt())
        XCTAssertEqual(store.automaticCallsToday(), 1)

        defaults.set(Data("visible-usage".utf8), forKey: "usage")
        defaults.set(Data("visible-history".utf8), forKey: "history")
        XCTAssertTrue(store.resetAllAccounting().succeeded)
        XCTAssertNil(defaults.object(forKey: "usage"))
        XCTAssertNil(defaults.object(forKey: "history"))
        XCTAssertEqual(store.automaticCallsToday(), 0,
                       "full reset, unlike visible Clear, intentionally resets the private cap")

        XCTAssertFalse(reservation.complete(
            usage: LLMUsage(inputTokens: 10, outputTokens: 2, isEstimated: false),
            outputLength: 12, safetyResult: "passed", outcome: "completed"
        ))
        XCTAssertNil(defaults.object(forKey: "usage"))
        XCTAssertNil(defaults.object(forKey: "history"))
    }

    @MainActor
    func testPartialAccountingResetNamesAlreadyRemovedPrivateStateAndVisibleFailures() {
        var preferencesCalled = false
        let service = FullResetService(effects: FullResetEffects(
            deleteProviderKey: { _ in },
            forgetProviderCredentialCache: {},
            resetUserContent: {},
            disableLoginItem: {},
            removeBrowserBridge: {
                BrowserBridgeRemovalResult(
                    removedBrowserNames: [], failedBrowserNames: [],
                    manualApprovalCleared: true
                )
            },
            resetAccounting: {
                AutomaticCallBudgetStore.ResetResult(
                    privateStateRemoved: true,
                    visibleUsageRemoved: false,
                    visibleHistoryRemoved: true
                )
            },
            clearPreferences: { preferencesCalled = true },
            terminateApplication: {}
        ))

        let result = service.perform()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failures.map(\.area), [.accounting])
        let message = result.failures[0].message
        XCTAssertTrue(message.contains("Already removed Bean's private automatic-call state"))
        XCTAssertTrue(message.contains("Couldn't remove visible usage totals"))
        XCTAssertTrue(message.contains("Already removed visible operation history"))
        XCTAssertEqual(result.skippedAreas, [.preferences])
        XCTAssertFalse(preferencesCalled)
    }

    func testSupportReportIsReviewableAndNeverClaimsItWasSent() {
        let date = Date(timeIntervalSince1970: 0)
        let report = SupportReportBuilder(generatedAt: date)
            .makeReport(diagnostics: "Bean diagnostics\nversion: 1.6.0 (8)")

        XCTAssertTrue(report.contains("Review every line before sharing"))
        XCTAssertTrue(report.contains("not saved or uploaded"))
        XCTAssertTrue(report.contains("Bean diagnostics"))
        XCTAssertTrue(report.contains("[Describe the problem using synthetic text only.]"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("report sent"))
    }

    func testSupportRepairCardsAreActionableWithoutTreatingOptionalBrowserAsBroken() {
        let absentBrowser = BrowserBridgeStatus(
            state: .extensionNotFound, extensionIDs: [], detectedExtensionBrowserNames: [],
            browserNames: ["Chrome"],
            configuredBrowserNames: [], detail: "Add the extension."
        )
        let healthyOptional = SupportCenter.repairCards(
            accessibilityGranted: true, appLocationWarning: nil,
            runningInstanceCount: 1, browserStatus: absentBrowser,
            browserAIEnabled: false
        )
        XCTAssertTrue(healthyOptional.isEmpty)

        let cards = SupportCenter.repairCards(
            accessibilityGranted: false,
            appLocationWarning: "Bean is running from Downloads.",
            runningInstanceCount: 2, browserStatus: absentBrowser,
            browserAIEnabled: true
        )
        XCTAssertEqual(cards.map(\.id), ["accessibility", "app-location", "instances", "browser"])
        XCTAssertEqual(cards.first?.action, .guidedSetup)
        XCTAssertEqual(cards.last?.action, .browserSettings)

        let unavailableBrowser = BrowserBridgeStatus(
            state: .unavailable, extensionIDs: [], detectedExtensionBrowserNames: [],
            browserNames: [],
            configuredBrowserNames: [], detail: "Open a supported browser once."
        )
        XCTAssertTrue(SupportCenter.repairCards(
            accessibilityGranted: true, appLocationWarning: nil,
            runningInstanceCount: 1, browserStatus: unavailableBrowser,
            browserAIEnabled: false
        ).isEmpty)
        XCTAssertEqual(SupportCenter.repairCards(
            accessibilityGranted: true, appLocationWarning: nil,
            runningInstanceCount: 1, browserStatus: unavailableBrowser,
            browserAIEnabled: true
        ).map(\.id), ["browser"])
    }

    func testPublicLinksStayOnTheCanonicalRepository() {
        for url in [
            BeanPublicLinks.repository, BeanPublicLinks.issues,
            BeanPublicLinks.newBug, BeanPublicLinks.privacy,
            BeanPublicLinks.license, BeanPublicLinks.changelog,
            BeanPublicLinks.support
        ] {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "github.com")
            XCTAssertTrue(url.path.hasPrefix("/aneesio/bean"))
        }
    }

    func testPreferencesResetRemovesOnlyBeansExactDomain() throws {
        let beanDomain = "BeanPreferencesReset.\(UUID().uuidString)"
        let unrelatedDomain = "UnrelatedPreferences.\(UUID().uuidString)"
        let beanDefaults = try XCTUnwrap(UserDefaults(suiteName: beanDomain))
        let unrelatedDefaults = try XCTUnwrap(UserDefaults(suiteName: unrelatedDomain))
        defer {
            beanDefaults.removePersistentDomain(forName: beanDomain)
            unrelatedDefaults.removePersistentDomain(forName: unrelatedDomain)
        }
        beanDefaults.set("remove", forKey: "bean-setting")
        unrelatedDefaults.set("keep", forKey: "other-setting")
        beanDefaults.synchronize()
        unrelatedDefaults.synchronize()

        try BeanPreferencesResetter(defaults: beanDefaults, domainName: beanDomain).clear()

        XCTAssertTrue((beanDefaults.persistentDomain(forName: beanDomain) ?? [:]).isEmpty)
        XCTAssertEqual(unrelatedDefaults.string(forKey: "other-setting"), "keep")
    }

    func testLiveFullResetDeletesKeychainItemsWithoutReadingSecrets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/Core/FullResetService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("KeychainService.delete(account: provider.keychainAccount)"))
        XCTAssertFalse(source.contains("settings.apiKey(for:"))
        XCTAssertFalse(source.contains("settings.setAPIKey("))
    }
}
