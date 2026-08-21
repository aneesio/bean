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

    static var appPath: String { Bundle.main.bundlePath }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "unknown (unbundled)" }

    /// Number of running bundled Bean instances (single-instance protection
    /// should keep this at 1; >1 means another bundled copy is also running).
    static var runningInstanceCount: Int {
        guard let id = Bundle.main.bundleIdentifier else { return 1 }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }.count
    }

    /// A warning if Bean is running from a non-stable location, where macOS may
    /// reset Accessibility/login-item state on each rebuild or move.
    static var pathWarning: String? {
        let path = appPath
        let location: String?
        if path.contains("/DerivedData/") { location = "Xcode DerivedData" }
        else if path.contains("/build/") { location = "the build folder" }
        else if path.contains("/Downloads/") { location = "Downloads" }
        else { location = nil }

        guard let location else { return nil }
        return "Bean is running from \(location). For stable permissions and launch-at-login, move Bean.app to /Applications."
    }

    /// Multi-line, copy-pasteable summary (no secrets, no user text).
    var summaryText: String {
        var lines: [String] = ["Bean diagnostics"]
        lines.append("version: \(AppInfo.version) (\(AppInfo.build))")
        lines.append("bundleID: \(Self.bundleID)")
        lines.append("appPath: \(Self.appPath)")
        lines.append("provider: \(settings.provider.rawValue)")
        lines.append("model: \(settings.model)")
        lines.append("accessibility: \(PermissionService.isAccessibilityGranted ? "granted" : "not granted")")
        lines.append("launchAtLogin: \(LoginItemService.statusDescription)")
        lines.append("quickProofreadShortcut: \(settings.shortcut.displayString)")
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
        let activeStyle = store.effectiveProfile(explicit: nil, context: nil).name
        lines.append("styleProfiles: \(store.profiles.count)")
        lines.append("activeStyle: \(activeStyle)")
        lines.append("contextCards: \(store.cards.count) (enabled: \(store.cards.filter { $0.isEnabledByDefault }.count))")
        lines.append("dictionaryTerms: \(store.dictionary.count)")

        // Passive Suggestions (Phase 5) — flags/settings only, no text.
        lines.append("passiveEnabled: \(settings.passiveEnabled ? "yes" : "no")")
        if settings.passiveEnabled {
            if let until = settings.passivePausedUntil, until > Date() {
                lines.append("passivePausedUntil: \(ISO8601DateFormatter().string(from: until))")
            }
            lines.append("passiveDelay: \(String(format: "%.1f", settings.passiveDelay))s")
            lines.append("passiveLengthRange: \(settings.passiveMinLength)-\(settings.passiveMaxLength)")
            var cats: [String] = []
            if settings.passiveInChat { cats.append("chat") }
            if settings.passiveInMailBrowser { cats.append("mail/browser") }
            if settings.passiveInCode { cats.append("code") }
            if settings.passiveInSearch { cats.append("search") }
            lines.append("passiveCategories: \(cats.isEmpty ? "none" : cats.joined(separator: ","))")
        }

        lines.append("inlineHighlightsEnabled: \(settings.inlineHighlightsEnabled ? "yes" : "no")")
        lines.append("webInlineEnabled: \(settings.webInlineEnabled ? "yes" : "no")")
        lines.append("nativeHostBinary: \(Bundle.main.executablePath ?? "unknown")")
        let browserBridge = BrowserBridgeInstaller().inspect()
        lines.append("browserBridgeStatus: \(browserBridge.diagnosticsName)")
        lines.append("browserBridgeExtensionsDetected: \(browserBridge.extensionIDs.count)")
        lines.append("browserBridgeConfiguredBrowsers: \(browserBridge.configuredBrowserNames.count)/\(browserBridge.browserNames.count)")
        lines.append("beanBubbleEnabled: \(settings.bubbleEnabled ? "yes" : "no")")
        lines.append("typingMonitorActive: \(settings.monitorActive ? "yes" : "no")")
        lines.append("lastPauseHandler: \(settings.lastPauseHandler)")
        if !settings.lastSupportReason.isEmpty {
            lines.append("lastReasonCode: \(settings.lastSupportReason)")
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
