import XCTest
@testable import Bean

final class SettingsStructureTests: XCTestCase {
    @MainActor
    func testSettingsNavigationCanRouteDirectlyToAISetup() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.selection, .general)

        navigation.selection = .provider

        XCTAssertEqual(navigation.selection, .provider)
    }

    func testSettingsHasExactlyFivePrimaryDestinations() {
        XCTAssertEqual(
            SettingsView.Category.allCases.map(\.rawValue),
            ["General", "Writing", "AI & Usage", "Browser", "Privacy & Help"]
        )
    }

    func testWritingPersonalizationOwnsTheFourSecondaryAreas() {
        XCTAssertEqual(
            SettingsView.PersonalizationArea.allCases.map(\.rawValue),
            ["Styles", "App Defaults", "Writing Context", "Dictionary"]
        )
    }

    func testSettingsSidebarUsesBeanSelectionInsteadOfSystemAccent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("List(selection: sidebarSelection)"))
        XCTAssertTrue(source.contains("navigation.selection = category"))
        XCTAssertTrue(source.contains("BeanDesign.accent.opacity(0.18)"))
        XCTAssertTrue(source.contains("category == navigation.selection ? .isSelected : []"))
    }

    func testEveryVisibleAccountingEraseUsesTheCoordinatedClearAPI() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("history.clear()"))
        XCTAssertFalse(source.contains("usageLedger.clear()"))
        XCTAssertEqual(
            source.components(separatedBy: "Button(\"Clear usage and operation history\"").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "clearVisibleAccounting()").count - 1,
            3
        )
    }

    func testSupportPreviewDiagnosticsAndGitHubActionsRemainSeparate() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Button(\"Preview Support Report\")"))
        XCTAssertTrue(source.contains("\"Copy Diagnostics Summary\""))
        XCTAssertTrue(source.contains("Button(\"Open GitHub Bug Form\")"))
        XCTAssertTrue(source.contains("Opening GitHub does not upload this preview."))
        XCTAssertTrue(source.contains("copyError = onCopy()"))
        XCTAssertTrue(source.contains("copied = copyError == nil"))
        XCTAssertTrue(source.contains("issueError = onOpenIssue()"))
        XCTAssertTrue(source.contains("Nothing was sent; select the preview text"))
        XCTAssertTrue(source.contains("Report copied after your review. Bean has not saved or sent it."))

        let openBugBody = try XCTUnwrap(
            source.range(of: "private func openBugReport()")
        )
        let suffix = source[openBugBody.lowerBound...]
        let functionText = suffix.prefix { $0 != "}" }
        XCTAssertFalse(functionText.contains("copyDiagnostics"))
        XCTAssertFalse(functionText.contains("copySupportReport"))
    }

    func testClipboardSuccessCopyNeverIgnoresPasteboardFailure() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "let copied = NSPasteboard.general.setString(text, forType: .string)"
        ))
        XCTAssertTrue(source.contains("copiedDiagnostics = copied"))
        XCTAssertTrue(source.contains(
            "guard NSPasteboard.general.setString(supportReport, forType: .string) else"
        ))
        XCTAssertFalse(source.contains("NSPasteboard.general.setString(supportReport, forType: .string)\n    }"))
    }

    func testFullResetRequiresConfirmationAndNamesManualBoundaries() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".alert(\"Reset Bean completely?\""))
        XCTAssertTrue(source.contains("Button(\"Reset Bean and Quit\", role: .destructive)"))
        XCTAssertTrue(source.contains("Full Reset Bean…"))
        XCTAssertTrue(source.contains("FullResetService.accessibilityRemovalInstructions"))
        XCTAssertTrue(source.contains("Accessibility permission"))
        XCTAssertTrue(source.contains("blocked-sites list"))
        XCTAssertTrue(source.contains("Reset incomplete. Bean did not quit."))
        XCTAssertTrue(source.contains("Already removed:"))
        XCTAssertTrue(source.contains("These changes were not rolled back."))
        XCTAssertTrue(source.contains("cannot selectively erase earlier Apple unified-log entries"))
    }

    func testDestructiveAccountingClearRequiresConfirmation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            ".alert(\"Clear usage and operation history?\", isPresented: $showsAccountingClearConfirmation)"
        ))
        XCTAssertTrue(source.contains("Button(\"Clear History\", role: .destructive)"))
        XCTAssertEqual(
            source.components(separatedBy: "showsAccountingClearConfirmation = true").count - 1,
            2
        )
    }

    func testPrivacyAndReadinessCopyDoesNotOverstateScope() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Accessibility is ready"))
        XCTAssertTrue(source.contains("private var isAccessibilityReady"))
        XCTAssertFalse(source.contains("isReadyForOtherApps"))
        XCTAssertTrue(source.contains("does not retain text you proofread, rewrite, or draft"))
        XCTAssertTrue(source.contains("Provider-backed actions may also send a bounded view"))
        XCTAssertTrue(source.contains("Quick Fix and local checks never send text or personalization"))
        XCTAssertTrue(source.contains("Always-on content-free events in Apple's unified log"))
        XCTAssertTrue(source.contains("structured provider/model, length, feature-state, and timing metrics"))
        XCTAssertTrue(source.contains("Diagnostics and support reports may include app and bundle names"))
        XCTAssertFalse(source.contains("Bean does not store your text."))
    }

    func testBrowserSetupDistinguishesInstalledManifestFromLiveConnection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let browserSetup = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/BrowserExtensionSetupSection.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(browserSetup.contains("Mac connection installed"))
        XCTAssertTrue(browserSetup.contains("Live browser status is checked inside the extension"))
        XCTAssertTrue(browserSetup.contains("choose Check again to verify the live app connection"))
        XCTAssertFalse(browserSetup.contains("return \"Browser connected\""))
        XCTAssertTrue(settings.contains("Mac-side setup checks passed"))
        XCTAssertTrue(settings.contains("For live browser status"))
        XCTAssertFalse(settings.contains("No setup problems detected"))
    }

    func testWritingContextDisclosesProviderBackedScopeAtTheToggle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/StyleDataSettings.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Enabled items can accompany every provider-backed rewrite"))
        XCTAssertTrue(source.contains("Include with provider-backed rewrites"))
        XCTAssertFalse(source.contains("relevant Writing Context"))
    }

    func testLegalDocumentsNeverFallBackToReadme() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )
        let functionStart = try XCTUnwrap(source.range(of: "private func openBundledDocument"))
        let followingMarker = try XCTUnwrap(
            source.range(of: "// MARK: - Troubleshooting", range: functionStart.upperBound..<source.endIndex)
        )
        let functionText = source[functionStart.lowerBound..<followingMarker.lowerBound]

        XCTAssertTrue(functionText.contains("BeanPublicLinks.privacy"))
        XCTAssertTrue(functionText.contains("BeanPublicLinks.license"))
        XCTAssertTrue(functionText.contains("legalDocumentError"))
        XCTAssertFalse(functionText.contains("actions.openReadme"))
    }

    func testAdvancedNativeHostScriptsKeepManifestAndExactApprovalInSync() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let install = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("scripts/install_native_messaging_host.sh"),
            encoding: .utf8
        )
        let uninstall = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("scripts/uninstall_native_messaging_host.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(install.contains(
            "defaults write \"$PREFERENCE_DOMAIN\" \"$APPROVAL_KEY\" -array \"$EXT_ID\""
        ))
        XCTAssertTrue(uninstall.contains(
            "defaults delete \"$PREFERENCE_DOMAIN\" \"$APPROVAL_KEY\""
        ))
        XCTAssertEqual(
            uninstall.components(separatedBy: "defaults delete").count - 1,
            1,
            "uninstall may clear only Bean's exact manual-approval key"
        )
        XCTAssertFalse(install.contains("Enable \"Web Inline Support\""))
        XCTAssertTrue(install.contains("Allow deeper AI checks from the browser"))
        XCTAssertTrue(uninstall.contains("Browser profiles and extension data were not changed"))
    }

    func testAboutUsesCanonicalProjectLinksAndDelegatesManualUpdateCheck() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let about = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/AboutView.swift"),
            encoding: .utf8
        )
        let presenter = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/WindowPresenter.swift"),
            encoding: .utf8
        )

        for link in ["repository", "support", "privacy", "license", "changelog"] {
            XCTAssertTrue(about.contains("BeanPublicLinks.\(link)"))
        }
        XCTAssertTrue(about.contains("community-supported public beta"))
        XCTAssertTrue(about.contains("Button(\"Open Update Check…\")"))
        XCTAssertFalse(about.contains("UpdateChecker("),
                       "About must route to the existing user-triggered Settings check")
        XCTAssertTrue(about.contains("ScrollView"))
        XCTAssertTrue(about.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(about.contains("minWidth: 420"))
        XCTAssertFalse(about.contains(".frame(width: 500)"))
        XCTAssertTrue(presenter.contains("self?.showSettings(section: .general)"))
        XCTAssertTrue(presenter.contains("resizable: true, identifier: \"about\""))
        XCTAssertTrue(presenter.contains(
            "window.contentMinSize = NSSize(width: 420, height: 460)"
        ))
        XCTAssertFalse(presenter.contains(
            "window.minSize = NSSize(width: 420, height: 460)"
        ))
        XCTAssertTrue(presenter.contains("window.setContentSize(NSSize(width: 520, height: 590))"))

        let settings = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("Section(\"Updates\") { updateSection }"),
                      "About's update route must land on a visible control")
    }
}
