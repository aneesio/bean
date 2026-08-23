import AppKit

// Builds a SAFE, operational diagnostics summary for troubleshooting.
//
// PRIVACY: this contains only non-sensitive operational state. It NEVER includes
// the API key, selected text, corrected text, clipboard contents, or prompts.
@MainActor
struct Diagnostics {
    let settings: AppSettings
    let store: UserContentStore
    let history: OperationHistoryStore
    let usageLedger: UsageLedgerStore
    let setupStatus: SetupStatusStore

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "unknown (unbundled)" }
    static var appLocationAssessment: AppLocationAssessment {
        AppLocationAssessment(appURL: Bundle.main.bundleURL)
    }

    /// Number of running bundled Bean instances (single-instance protection
    /// should keep this at 1; >1 means another bundled copy is also running).
    static var runningInstanceCount: Int {
        guard let id = Bundle.main.bundleIdentifier else { return 1 }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }.count
    }

    /// A warning if Bean is running from a non-stable location, where macOS may
    /// reset Accessibility/login-item state on each rebuild or move.
    static var pathWarning: String? {
        appLocationAssessment.warningMessage
    }

    /// Multi-line, copy-pasteable summary (no secrets, no user text).
    var summaryText: String {
        var lines: [String] = ["Bean diagnostics"]
        lines.append("version: \(AppInfo.version) (\(AppInfo.build))")
        lines.append("bundleID: \(Self.bundleID)")
        lines.append("appBundle: \(Bundle.main.bundleURL.lastPathComponent)")
        lines.append("appLocation: \(Self.appLocationAssessment.kind.rawValue)")
        lines.append("provider: \(settings.provider.rawValue)")
        // The model field accepts custom text. Preserve the canonical shipped
        // identifier because it is useful support metadata, but never copy an
        // arbitrary user-entered value into a diagnostics/support report.
        let diagnosticModel = settings.model == settings.provider.defaultModel
            ? settings.model
            : "custom"
        lines.append("model: \(diagnosticModel)")
        lines.append("accessibility: \(PermissionService.isAccessibilityGranted ? "granted" : "not granted")")
        lines.append("launchAtLogin: \(LoginItemService.statusDescription)")
        lines.append("writingShortcut: \(settings.shortcut.displayString)")
        lines.append("writingShortcutAction: \(settings.primaryShortcutAction.rawValue)")
        lines.append("beanMenuShortcut: \(settings.beanMenuShortcut.displayString)")
        lines.append("onboardingComplete: \(settings.onboardingComplete ? "yes" : "no")")
        lines.append("providerConnectionVerified: \(settings.isProviderConnectionVerified ? "yes" : "no")")
        lines.append("crossAppReplacementVerified: \(history.hasConfirmedExternalReplacement ? "yes" : "no")")
        lines.append("diagnosticsEnabled: \(settings.diagnosticsEnabled ? "yes" : "no")")
        let usage = usageLedger.summary(days: 30)
        lines.append("usage30dTokens: \(usage.inputTokens)+\(usage.outputTokens)")
        lines.append("usage30dCalls: \(usage.operationCount) (automatic: \(usage.automaticOperationCount))")
        lines.append("automaticDailyLimit: \(settings.dailyAutomaticCallLimit)")

        // Content-free counts only — never the actual profiles/cards/terms.
        let activeProfile = store.effectiveProfile(explicit: nil, context: nil)
        let activeStyle = StyleProfile.builtIns().first(where: { $0.id == activeProfile.id })
            .map { "builtIn:\($0.name)" } ?? "custom"
        lines.append("styleProfiles: \(store.profiles.count)")
        lines.append("activeStyle: \(activeStyle)")
        lines.append("writingContextItems: \(store.cards.count) (enabled: \(store.cards.filter { $0.isEnabledByDefault }.count))")
        lines.append("dictionaryTerms: \(store.dictionary.count)")

        // Current product names only. These are flags and numeric limits, never
        // the text behind a suggestion or any saved personalization detail.
        lines.append("liveSuggestionsEnabled: \(settings.inlineHighlightsEnabled ? "yes" : "no")")
        let deeperAISuggestionsEnabled = settings.inlineHighlightsEnabled
            && !settings.inlineLocalOnly
            && settings.inlineIncludeLLM
        lines.append("deeperAISuggestionsEnabled: \(deeperAISuggestionsEnabled ? "yes" : "no")")

        lines.append("browserAIEnabled: \(settings.webInlineEnabled ? "yes" : "no")")
        let browserBridge = BrowserBridgeInstaller().inspect()
        lines.append("browserBridgeStatus: \(browserBridge.diagnosticsName)")
        lines.append("browserBridgeExtensionsDetected: \(browserBridge.extensionIDs.count)")
        lines.append("browserBridgeConfiguredBrowsers: \(browserBridge.configuredBrowserNames.count)/\(browserBridge.browserNames.count)")
        lines.append("beanBubbleEnabled: \(settings.bubbleEnabled ? "yes" : "no")")
        lines.append("typingMonitorActive: \(settings.monitorActive ? "yes" : "no")")
        let lastPauseHandler = OperationalMetadataSanitizer.required(
            settings.lastPauseHandler,
            fallback: "none",
            maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        lines.append("lastPauseHandler: \(lastPauseHandler)")
        if let lastReasonCode = OperationalMetadataSanitizer.optional(
            settings.lastSupportReason,
            maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
        ) {
            lines.append("lastReasonCode: \(lastReasonCode)")
        }

        let instances = Self.runningInstanceCount
        lines.append("runningInstances: \(instances)")
        if instances > 1 {
            lines.append("warning: more than one bundled Bean is running — quit the extras to avoid shortcut conflicts.")
        }
        if let warning = Self.pathWarning {
            lines.append("pathWarning: \(warning)")
        }
        if let report = setupStatus.latestFieldInspection {
            lines.append("")
            lines.append("Latest metadata-only field check")
            lines.append(contentsOf: report.diagnosticsLines)
        }
        if !history.recentDiagnosticsLines.isEmpty {
            lines.append("")
            lines.append("Recent content-free operations (newest first)")
            lines.append(contentsOf: history.recentDiagnosticsLines)
        }
        return lines.joined(separator: "\n")
    }

    /// The log-stream command users can run to watch Bean's operational logs.
    static let logStreamCommand = #"log stream --predicate 'subsystem == "com.bean.app"' --info"#
}

private extension BrowserBridgeStatus {
    var diagnosticsName: String {
        switch state {
        case .extensionNotFound: return "extensionNotFound"
        case .readyToInstall: return "readyToInstall"
        case .installed: return "installed"
        case .needsRepair: return "needsRepair"
        case .unavailable: return "browserUnavailable"
        }
    }
}
