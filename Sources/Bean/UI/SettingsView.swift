import SwiftUI
import AppKit

// Actions the Settings window delegates back to the app (window/permission
// flows it can't perform itself).
struct SettingsActions {
    var checkPermissions: () -> Void
    var resetOnboarding: () -> Void
    var openReadme: () -> Void
    var openTesting: () -> Void
    /// Validates + registers a new shortcut for the given slot. Returns an error
    /// message to show, or nil on success.
    var applyShortcut: (ShortcutSlot, GlobalShortcut) -> String?
}

// Bean's Settings window — a native, sidebar-organised preferences experience.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UserContentStore
    @ObservedObject var history: OperationHistoryStore
    @ObservedObject var usageLedger: UsageLedgerStore
    @ObservedObject var setupStatus: SetupStatusStore
    let actions: SettingsActions

    @State private var selection: Category? = .general
    @State private var loginEnabled: Bool = LoginItemService.isEnabled
    @State private var loginError: String?
    @State private var proofreadError: String?
    @State private var beanMenuError: String?
    @StateObject private var updateChecker = UpdateChecker()

    enum Category: String, CaseIterable, Identifiable {
        case general = "General"
        case writing = "Writing"
        case provider = "AI & Usage"
        case personalization = "Personalization"
        case browser = "Browser"
        case privacy = "Privacy & Support"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .writing: return "text.badge.checkmark"
            case .provider: return "sparkles"
            case .personalization: return "slider.horizontal.3"
            case .browser: return "globe"
            case .privacy: return "lock.shield"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Category.allCases) { category in
                    sidebarRow(category).tag(category)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(196)
        } detail: {
            Form { detailSections }
                .formStyle(.grouped)
                .navigationTitle(selection?.rawValue ?? "Settings")
        }
        .frame(width: 760, height: 580)
        .tint(BeanDesign.accent)
        .onAppear {
            history.refresh()
            usageLedger.refresh()
        }
    }

    @ViewBuilder
    private func sidebarRow(_ category: Category) -> some View {
        HStack {
            Label(category.rawValue, systemImage: category.symbol)
            Spacer()
            switch category {
            case .general where !isFullyVerified:
                StatusPill(text: "Action", kind: .warning, showsIcon: false)
            case .provider where !settings.hasAPIKey:
                StatusPill(text: "Set up", kind: .warning, showsIcon: false)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var detailSections: some View {
        switch selection ?? .general {
        case .general:
            Section("Bean") { simpleStatusSection }
            Section("General") { generalSection }
            Section("Shortcuts") { shortcutSection }
            Section("Updates") { updateSection }
        case .writing:
            Section("Writing Assistance") { writingAssistanceSection }
        case .provider:
            Section("AI Provider") {
                ProviderSetupSection(settings: settings, usageLedger: usageLedger, compact: true)
            }
            Section("Usage") {
                usageSummarySection
                DisclosureGroup("Cost controls and detailed usage") {
                    timeoutRow
                    usageCostSection
                }
            }
        case .personalization:
            Section("Style Profiles") { StyleProfilesSection(store: store) }
            Section("App Defaults") { AppDefaultsSection(store: store) }
            Section("Context Cards") { ContextCardsSection(store: store) }
            Section("Personal Dictionary") { DictionarySection(store: store) }
        case .browser:
            Section("Bean for the Web") { browserExtensionSection }
        case .privacy:
            Section("Privacy") { privacySection }
            Section("Data") { DataSection(store: store) }
            Section("Help") { simpleSupportSection }
        }
    }

    private var simpleStatusSection: some View {
        Group {
            HStack(spacing: 12) {
                IconBadge(symbol: isFullyVerified ? "checkmark.seal.fill" : "sparkles",
                          tint: isFullyVerified ? BeanDesign.success : BeanDesign.accent, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFullyVerified ? "Bean is ready" : "Finish setting up Bean")
                        .font(.headline)
                    Text(isFullyVerified
                         ? "Use " + settings.shortcut.displayString + " in any supported text field."
                         : "The guided setup will take you through each required step.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(isFullyVerified ? "Run Setup Again" : "Continue Setup") {
                    actions.resetOnboarding()
                }
            }
            if !isFullyVerified {
                HStack(spacing: 14) {
                    compactCheck("API", settings.isProviderConnectionVerified)
                    compactCheck("Accessibility", PermissionService.isAccessibilityGranted)
                    compactCheck("Replacement", history.hasConfirmedExternalReplacement)
                }
            }
        }
    }

    private func compactCheck(_ title: String, _ ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundColor(ready ? BeanDesign.success : .secondary)
    }

    private var writingAssistanceSection: some View {
        Group {
            Toggle("Show the Bean button near supported text fields", isOn: $settings.bubbleEnabled)
            Text("A small shortcut to Bean's writing actions. It stays hidden in secure and non-editable fields.")
                .font(.caption).foregroundColor(.secondary)
            if settings.bubbleEnabled {
                DisclosureGroup("Bean button options") { bubbleOptions }
            }

            Divider()
            Toggle("Underline issues as I type", isOn: $settings.inlineHighlightsEnabled)
            Text("Highlights supported native fields. Browser highlights are controlled from the Browser section.")
                .font(.caption).foregroundColor(.secondary)
            if settings.inlineHighlightsEnabled {
                DisclosureGroup("Inline highlight options") { inlineOptions }
            }

            Divider()
            Toggle("Suggest improvements after I pause", isOn: $settings.passiveEnabled)
            Text("Optional. This can use paid AI tokens; nothing is changed until you approve it.")
                .font(.caption).foregroundColor(.secondary)
            if settings.passiveEnabled {
                DisclosureGroup("Automatic suggestion options") { passiveOptions }
            }
        }
    }

    private var usageSummarySection: some View {
        let month = usageLedger.summary(days: 30)
        return Group {
            LabeledContent("Last 30 days", value: "\(month.totalTokens.formatted()) tokens · \(month.operationCount) calls")
            LabeledContent("Estimated cost") {
                Text(month.estimatedCostUSD < 1
                     ? String(format: "US$ %.4f", month.estimatedCostUSD)
                     : String(format: "US$ %.2f", month.estimatedCostUSD))
                    .monospacedDigit()
            }
            Text("Local Quick Check is free. Automatic AI checks stay within the daily limit below.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var isFullyVerified: Bool {
        settings.isSetupComplete && settings.isProviderConnectionVerified
            && history.hasConfirmedExternalReplacement
    }

    private var readinessSection: some View {
        return Group {
            setupCheckRow(
                "Installed in Applications",
                ready: Diagnostics.pathWarning == nil,
                detail: Diagnostics.pathWarning == nil ? "/Applications/Bean.app" : "Move Bean to /Applications"
            )
            setupCheckRow(
                "API key saved",
                ready: settings.hasAPIKey,
                detail: settings.hasAPIKey ? settings.provider.displayName : "Add a key in AI & Usage"
            )
            setupCheckRow(
                "Provider connection verified",
                ready: settings.isProviderConnectionVerified,
                detail: settings.isProviderConnectionVerified ? settings.model : "Use Test API key in AI & Usage"
            )
            setupCheckRow(
                "Accessibility",
                ready: PermissionService.isAccessibilityGranted,
                detail: PermissionService.isAccessibilityGranted ? "Allowed" : "Permission required"
            )
            setupCheckRow(
                "Cross-app replacement",
                ready: history.hasConfirmedExternalReplacement,
                detail: history.hasConfirmedExternalReplacement ? "Verified" : "Run the TextEdit verification"
            )
            Button("Open TextEdit verification") {
                try? setupStatus.openTextEditVerificationFile()
            }
            .disabled(!settings.hasAPIKey || !PermissionService.isAccessibilityGranted)
            Text("In TextEdit, click the synthetic sentence and press \(settings.shortcut.displayString). A confirmed replacement completes this check.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func setupCheckRow(_ title: String, ready: Bool, detail: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(detail).foregroundColor(.secondary)
                StatusPill(text: ready ? "Ready" : "Needed",
                           kind: ready ? .success : .warning, showsIcon: false)
            }
        } label: {
            Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ready ? BeanDesign.success : .primary)
        }
    }

    private var fieldInspectionSection: some View {
        Group {
            if let report = setupStatus.latestFieldInspection {
                Text(report.headline).font(.headline)
                LabeledContent("App", value: report.appName)
                LabeledContent("Reference profile", value: report.referenceSurface ?? "generic")
                LabeledContent("Role", value: report.role ?? "Unknown")
                if report.fallbackEvidence == "slackRecentTyping" {
                    LabeledContent("Fallback", value: "Recent Slack composer typing detected")
                }
                capabilityRow("Selected-text action", report.selectedTextAction)
                capabilityRow("Focused-field replacement", report.focusedFieldReplacement)
                capabilityRow("Bean Bubble", report.beanBubble)
                capabilityRow("Inline checking", report.inlineChecking)
                Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("No field has been inspected yet.")
                    .foregroundColor(.secondary)
            }
            Text("Focus a field in another app, then choose Bean → Help → Check Current Field from the menu bar. Bean records metadata only and does not read the field's text for this check.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func capabilityRow(_ title: String, _ assessment: CapabilityAssessment) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                StatusPill(
                    text: assessment.level.displayName,
                    kind: assessment.level == .supported ? .success
                        : assessment.level == .degraded ? .warning : .neutral,
                    showsIcon: false
                )
                Text(assessment.userFacingReason).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var recentOperationsSection: some View {
        Group {
            if history.records.isEmpty {
                Text("No operations recorded yet.").foregroundColor(.secondary)
            } else {
                ForEach(Array(history.records.prefix(8))) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(record.action).font(.callout).fontWeight(.medium)
                            Spacer()
                            StatusPill(
                                text: record.outcome,
                                kind: record.outcome == "replacedConfirmed" ? .success
                                    : record.outcome.contains("fallback") ? .warning : .neutral,
                                showsIcon: false
                            )
                        }
                        Text("\(record.appName ?? record.appCategory) · \(record.source.displayName) · \(record.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Button("Clear operation history", role: .destructive) { history.clear() }
            }
            Text("This bounded history contains operational metadata only—never text, prompts, responses, clipboard contents, or field labels.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Setup warning banner

    private var setupWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !settings.hasAPIKey {
                Label("Add an API key in the Provider section to enable corrections.",
                      systemImage: "key.fill")
                    .foregroundColor(.orange)
            }
            if !PermissionService.isAccessibilityGranted {
                Label("Grant Accessibility permission so Bean can fix text in other apps.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
        .font(.callout)
    }

    // MARK: - General

    private var generalSection: some View {
        Group {
            Toggle("Launch Bean at login", isOn: $loginEnabled)
                .onChange(of: loginEnabled) { newValue in setLogin(newValue) }
            if let loginError {
                Text(loginError).font(.caption).foregroundColor(.red)
            } else if !LoginItemService.isAvailable {
                Text("Launch at login is available when Bean runs from the built app.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Toggle("Fix focused field when no text is selected",
                   isOn: $settings.fixFocusedFieldWhenNoSelection)

            LabeledContent("Version", value: AppInfo.versionDisplay)
        }
    }

    private func setLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            loginError = nil
        } catch {
            // Revert the toggle to the real state and surface the error.
            loginError = "Couldn't update login item: \(error.localizedDescription)"
            loginEnabled = LoginItemService.isEnabled
        }
    }

    // MARK: - Updates

    private var updateSection: some View {
        Group {
            LabeledContent("Installed", value: AppInfo.versionDisplay)

            switch updateChecker.state {
            case .idle:
                Text("Bean checks GitHub only when you click the button. It never downloads or installs an update.")
                    .font(.caption).foregroundColor(.secondary)
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking GitHub Releases…").foregroundColor(.secondary)
                }
            case .upToDate(let release):
                updateResult(release, available: false)
            case .updateAvailable(let release):
                updateResult(release, available: true)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.callout)
            }

            Button(updateChecker.state == .checking ? "Checking…" : "Check for Updates") {
                updateChecker.check()
            }
            .disabled(updateChecker.state == .checking)
        }
    }

    @ViewBuilder
    private func updateResult(_ release: GitHubRelease, available: Bool) -> some View {
        LabeledContent("Latest release") {
            HStack(spacing: 8) {
                Text(release.tagName).monospacedDigit()
                if release.isPrerelease {
                    StatusPill(text: "Prerelease", kind: .experimental, showsIcon: false)
                }
            }
        }
        Label(
            available ? "A newer Bean release is available." : "This Bean version is up to date.",
            systemImage: available ? "arrow.down.circle.fill" : "checkmark.circle.fill"
        )
        .foregroundColor(available ? BeanDesign.accent : BeanDesign.success)
        if let url = release.verifiedPageURL {
            Button("Open Verified GitHub Release") { NSWorkspace.shared.open(url) }
        }
        Text("The release page opens in your browser. Bean does not download or install anything.")
            .font(.caption2).foregroundColor(.secondary)
    }

    private var timeoutRow: some View {
        HStack {
            Text("Request timeout")
            Slider(value: $settings.timeoutSeconds, in: 5...120, step: 5)
            Text("\(Int(settings.timeoutSeconds))s")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var usageCostSection: some View {
        let today = usageLedger.summary(days: 1)
        let month = usageLedger.summary(days: 30)
        return Group {
            LabeledContent("Today") {
                Text("\(today.totalTokens.formatted()) tokens · \(today.operationCount) calls")
                    .monospacedDigit()
            }
            LabeledContent("Last 30 days") {
                Text("\(month.totalTokens.formatted()) tokens · \(month.operationCount) calls")
                    .monospacedDigit()
            }
            LabeledContent("30-day input / output",
                           value: "\(month.inputTokens.formatted()) / \(month.outputTokens.formatted())")
            LabeledContent("Average per call", value: "\(month.averageTokensPerOperation.formatted()) tokens")
            LabeledContent("Estimated provider cost") {
                Text(month.estimatedCostUSD < 1
                     ? String(format: "US$ %.4f", month.estimatedCostUSD)
                     : String(format: "US$ %.2f", month.estimatedCostUSD))
                    .monospacedDigit()
            }
            ForEach([OperationSource.manual, .passive, .nativeInline, .webInline], id: \.rawValue) { source in
                let sourceUsage = usageLedger.summary(days: 30, source: source)
                if sourceUsage.operationCount > 0 {
                    LabeledContent(source.displayName) {
                        Text("\(sourceUsage.totalTokens.formatted()) tokens · \(sourceUsage.operationCount) calls")
                            .monospacedDigit()
                    }
                }
            }
            if month.estimatedOperationCount > 0 {
                Label("\(month.estimatedOperationCount) calls used conservative token estimates because the provider did not report usage.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            if month.unpricedOperationCount > 0 {
                Label("Cost excludes \(month.unpricedOperationCount) calls using custom or unpriced model IDs.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            if month.totalTokens >= settings.monthlyTokenWarningThreshold {
                Label("Your 30-day token total has reached the warning threshold.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }

            Divider()
            LabeledContent("Automatic provider checks") {
                StatusPill(text: settings.automaticAIChecksEnabled ? "On" : "Off",
                           kind: settings.automaticAIChecksEnabled ? .warning : .success,
                           showsIcon: false)
            }
            Text("Passive Suggestions, provider-backed Inline Highlights, and Web Inline Support can call the API after typing pauses. Manual shortcuts and the Bean Bubble call it only when you choose an action.")
                .font(.caption).foregroundColor(.secondary)
            Stepper("Daily automatic-call limit: \(settings.dailyAutomaticCallLimit)",
                    value: $settings.dailyAutomaticCallLimit, in: 1...200)
            Stepper("30-day warning: \(settings.monthlyTokenWarningThreshold.formatted()) tokens",
                    value: $settings.monthlyTokenWarningThreshold,
                    in: 25_000...5_000_000, step: 25_000)
            Text("Automatic calls today: \(today.automaticOperationCount) of \(settings.dailyAutomaticCallLimit). The limit never disables manual AI actions or Local Quick Check.")
                .font(.caption).foregroundColor(.secondary)
            Button("Disable automatic AI checks") { settings.disableAutomaticAIChecks() }
                .disabled(!settings.automaticAIChecksEnabled)
            Text("Local Quick Check is free and offline. At the pricing snapshot, OpenAI gpt-5-nano is $0.05/M input and $0.40/M output tokens; Claude Haiku 4.5 is $1/M input and $5/M output. Switching providers requires that provider's API key.")
                .font(.caption2).foregroundColor(.secondary)
            Text("Estimated USD cost uses public list prices captured \(UsageCostEstimator.pricingSnapshot); actual billing, caching, tiers, taxes, and future price changes may differ.")
                .font(.caption2).foregroundColor(.secondary)
            Button("Clear usage and operation history", role: .destructive) {
                usageLedger.clear()
                history.clear()
            }
            Text("Clearing usage removes only content-free local counters and operation metadata. It does not remove API keys or preferences.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        Group {
            shortcutRow(
                title: "AI Quick Proofread",
                shortcut: settings.shortcut,
                error: $proofreadError,
                slot: .quickProofread,
                resetTo: .default
            )
            Divider()
            shortcutRow(
                title: "Open Bean Menu",
                shortcut: settings.beanMenuShortcut,
                error: $beanMenuError,
                slot: .beanMenu,
                resetTo: .beanMenuDefault
            )
            Text("Tip: ⌘⇧, ⌃⌥, or ⌘⌥ plus a letter work well. The two shortcuts must differ.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func shortcutRow(title: String, shortcut: GlobalShortcut,
                             error: Binding<String?>, slot: ShortcutSlot,
                             resetTo: GlobalShortcut) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: shortcut.displayString)
            HStack {
                ShortcutRecorderButton(
                    onCapture: { captured in error.wrappedValue = actions.applyShortcut(slot, captured) },
                    onCancel: { error.wrappedValue = nil }
                )
                Button("Reset to Default") { error.wrappedValue = actions.applyShortcut(slot, resetTo) }
            }
            if let message = error.wrappedValue {
                Text(message).font(.caption).foregroundColor(.red)
            }
        }
    }

    // MARK: - Bean Bubble

    private var bubbleSection: some View {
        Group {
            HStack {
                Toggle("Show the Bean Bubble", isOn: $settings.bubbleEnabled)
                Spacer()
                StatusPill(text: "Beta", kind: .experimental, showsIcon: false)
            }
            Text("Shows a small Bean icon near supported text fields. Click it to choose an action. Drag the Bean Bubble if it covers your text. Hidden while you type, and not available in secure fields.")
                .font(.caption).foregroundColor(.secondary)

            if settings.bubbleEnabled {
                bubbleOptions
            }
        }
    }

    private var bubbleOptions: some View {
        Group {
            Toggle("Show when a text field is focused", isOn: $settings.bubbleOnFocus)
            Toggle("Show when text is selected", isOn: $settings.bubbleOnSelection)
            Toggle("Open menu on hover", isOn: $settings.bubbleOpenOnHover)
            HStack {
                Text("Delay before showing")
                Slider(value: $settings.bubbleDelay, in: 0.3...2.0, step: 0.1)
                Text(String(format: "%.1fs", settings.bubbleDelay)).monospacedDigit().frame(width: 40)
            }
            Toggle("Show in chat apps", isOn: $settings.bubbleInChat)
            Toggle("Show in mail and browser fields", isOn: $settings.bubbleInMailBrowser)
            Toggle("Show in code editors", isOn: $settings.bubbleInCode)
            Toggle("Show in search fields", isOn: $settings.bubbleInSearch)
        }
    }

    // MARK: - Passive Suggestions

    private var passiveSection: some View {
        Group {
            Toggle("Enable Passive Suggestions", isOn: $settings.passiveEnabled)
            Text("Shows a small suggestion after you pause typing. It can make paid provider calls; keep it off for manual-only usage. It never changes anything until you Apply.")
                .font(.caption).foregroundColor(.secondary)

            monitorStatusRow

            if settings.passiveEnabled {
                passiveOptions
            }
        }
    }

    private var passiveOptions: some View {
        Group {
            if let until = settings.passivePausedUntil, until > Date() {
                HStack {
                    Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundColor(.orange)
                    Button("Resume") { settings.resumePassive() }
                }
            } else {
                Button("Pause for 1 hour") { settings.pausePassive(forHours: 1) }
            }
            HStack {
                Text("Suggestion delay")
                Slider(value: $settings.passiveDelay, in: 0.6...3.0, step: 0.1)
                Text(String(format: "%.1fs", settings.passiveDelay)).monospacedDigit().frame(width: 40)
            }
            Stepper("Minimum length: \(settings.passiveMinLength)", value: $settings.passiveMinLength, in: 5...200, step: 5)
            Stepper("Maximum length: \(settings.passiveMaxLength)", value: $settings.passiveMaxLength, in: 200...8000, step: 200)
            Toggle("Enable in chat apps", isOn: $settings.passiveInChat)
            Toggle("Enable in mail and browser fields", isOn: $settings.passiveInMailBrowser)
            Toggle("Enable in code editors", isOn: $settings.passiveInCode)
            Toggle("Enable in search fields", isOn: $settings.passiveInSearch)
            Toggle("Only call AI when an offline check finds a likely issue", isOn: $settings.passiveOnlyWhenLikely)
            Toggle("Require preview before apply", isOn: $settings.passiveRequirePreview)
        }
    }

    private var monitorStatusRow: some View {
        HStack {
            Image(systemName: settings.monitorActive ? "dot.radiowaves.left.and.right" : "pause.circle")
                .foregroundColor(settings.monitorActive ? .green : .secondary)
            Text("Typing monitor: \(settings.monitorActive ? "Active" : "Inactive")")
                .font(.caption)
            if settings.diagnosticsEnabled, settings.lastPauseHandler != "none" {
                Spacer()
                Text("last: \(settings.lastPauseHandler)").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Inline Highlights

    private var inlineSection: some View {
        Group {
            Toggle("Enable Inline Highlights (experimental)", isOn: $settings.inlineHighlightsEnabled)
            Text("Experimental. Off by default. Underlines small issues in supported native text fields. Click or hover a highlight to review the suggestion beside the text; Apply fixes that issue and moves to the next. Unsupported apps (Slack, Notion, Docs, browsers) fall back to Passive Suggestions when available. Bean analyzes only the focused field and never reads other app content.")
                .font(.caption).foregroundColor(.secondary)

            if settings.inlineHighlightsEnabled {
                inlineOptions
            }
        }
    }

    private var inlineOptions: some View {
        Group {
            Text("Code editors, search fields, and secure fields are always excluded.")
                .font(.caption2).foregroundColor(.secondary)
            Stepper("Maximum issues shown: \(settings.inlineMaxIssues)", value: $settings.inlineMaxIssues, in: 1...8)
            Toggle("Use local checks only (no token cost)", isOn: $settings.inlineLocalOnly)
            Toggle("Include AI suggestions", isOn: $settings.inlineIncludeLLM)
                .disabled(settings.inlineLocalOnly)
            Toggle("Show explanations", isOn: $settings.inlineShowExplanation)
            Toggle("Use pause suggestions when highlights are unavailable", isOn: $settings.inlineFallbackPassive)
        }
    }

    private var browserExtensionSection: some View {
        BrowserExtensionSetupSection(settings: settings)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Group {
            Label("Manual actions send text only when you trigger them.", systemImage: "hand.raised")
            Label("Optional automatic checks may send focused-field text after a typing pause.", systemImage: "clock.arrow.circlepath")
            Label("Bean does not store your text.", systemImage: "nosign")
            Label("API keys are stored in macOS Keychain.", systemImage: "key")
            Toggle("Diagnostics logging (no text)", isOn: $settings.diagnosticsEnabled)
            Text("Diagnostics record operational metrics only — lengths and result codes. Never your text, prompts, or clipboard.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("Open Privacy Policy") { openBundledDocument("PRIVACY") }
                Button("Open License") { openBundledDocument("LICENSE") }
            }
        }
    }

    private func openBundledDocument(_ name: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            actions.openReadme()
        }
    }

    // MARK: - Troubleshooting

    @State private var copiedDiagnostics = false
    @State private var reportError: String?

    private var simpleSupportSection: some View {
        Group {
            Button("Run Guided Setup") { actions.resetOnboarding() }
            Button("Check Accessibility Permission") { actions.checkPermissions() }
            Button("Copy diagnostics and report a problem") { reportIssue() }
            if let reportError {
                Text(reportError).font(.caption).foregroundColor(.red)
            }
            DisclosureGroup("Advanced diagnostics") {
                if let warning = Diagnostics.pathWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange).font(.callout)
                }
                Button("Reveal Bean in Finder") { revealInFinder() }
                Button("Open Console Logs") { openConsole() }
                Button(copiedDiagnostics ? "Diagnostics copied ✓" : "Copy Diagnostics Summary") {
                    copyDiagnostics()
                }
                HStack {
                    Button("Open README") { actions.openReadme() }
                    Button("Open Testing Guide") { actions.openTesting() }
                }
                Divider()
                fieldInspectionSection
                Divider()
                recentOperationsSection
            }
        }
    }

    private var troubleshootingSection: some View {
        Group {
            if let warning = Diagnostics.pathWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.callout)
            }
            Button("Check Permissions") { actions.checkPermissions() }
            Button("Reveal Bean in Finder") { revealInFinder() }
            Button("Open Console (logs)") { openConsole() }
            Button(copiedDiagnostics ? "Diagnostics copied ✓" : "Copy Diagnostics Summary") {
                copyDiagnostics()
            }
            Button("Copy report and open GitHub issue") { reportIssue() }
            if let reportError {
                Text(reportError).font(.caption).foregroundColor(.red)
            }
            HStack {
                Button("Open README") { actions.openReadme() }
                Button("Open Testing Guide") { actions.openTesting() }
            }
            Button("Reset onboarding") { actions.resetOnboarding() }
        }
    }

    private func revealInFinder() {
        if let url = Bundle.main.bundleURL as URL? {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func openConsole() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func copyDiagnostics() {
        let text = Diagnostics(settings: settings, store: store, history: history,
                               usageLedger: usageLedger, setupStatus: setupStatus).summaryText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedDiagnostics = true
    }

    private func reportIssue() {
        copyDiagnostics()
        guard let url = URL(string: "https://github.com/aneesio/bean/issues/new?template=bug.yml"),
              NSWorkspace.shared.open(url) else {
            reportError = "Couldn't open GitHub. The diagnostics summary is still on your clipboard."
            return
        }
        reportError = nil
    }
}
