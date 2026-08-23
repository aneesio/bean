import SwiftUI
import AppKit

// Actions the Settings window delegates back to the app (window/permission
// flows it can't perform itself).
struct SettingsActions {
    var checkPermissions: () -> Void
    var resetOnboarding: () -> Void
    var openReadme: () -> Void
    var openTesting: () -> Void
    var fullReset: () -> FullResetResult
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
    let automaticCallBudget: AutomaticCallBudgetStore
    @ObservedObject var setupStatus: SetupStatusStore
    @ObservedObject var navigation: SettingsNavigation
    let actions: SettingsActions

    @State private var loginEnabled: Bool = LoginItemService.isEnabled
    @State private var loginError: String?
    @State private var proofreadError: String?
    @State private var beanMenuError: String?
    @State private var showsPersonalization = false
    @State private var personalizationArea: PersonalizationArea = .styles
    @State private var automaticSpentToday: Int?
    @State private var accountingClearMessage: String?
    @State private var accountingClearFailed = false
    @State private var supportBrowserStatus: BrowserBridgeStatus?
    @State private var supportReport = ""
    @State private var showsSupportReport = false
    @State private var showsAccountingClearConfirmation = false
    @State private var showsFullResetConfirmation = false
    @State private var fullResetResult: FullResetResult?
    @State private var legalDocumentError: String?
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var permissionStatus = AccessibilityPermissionModel()

    enum Category: String, CaseIterable, Identifiable {
        case general = "General"
        case writing = "Writing"
        case provider = "AI & Usage"
        case browser = "Browser"
        case privacy = "Privacy & Help"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .writing: return "text.badge.checkmark"
            case .provider: return "sparkles"
            case .browser: return "globe"
            case .privacy: return "lock.shield"
            }
        }
    }

    enum PersonalizationArea: String, CaseIterable, Identifiable {
        case styles = "Styles"
        case appDefaults = "App Defaults"
        case writingContext = "Writing Context"
        case dictionary = "Dictionary"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(Category.allCases) { category in
                    Button {
                        navigation.selection = category
                    } label: {
                        sidebarRow(category)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        category == navigation.selection ? .isSelected : []
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(210)
        } detail: {
            Form { detailSections }
                .formStyle(.grouped)
                .controlSize(.large)
                .navigationTitle(navigation.selection.rawValue)
        }
        .frame(minWidth: 900, minHeight: 660)
        .tint(BeanDesign.accent)
        .onAppear {
            automaticSpentToday = automaticCallBudget.automaticCallsToday()
            history.refresh()
            usageLedger.refresh()
            permissionStatus.refresh()
            refreshSupportStatus()
            normalizeSimplifiedWritingSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionStatus.refresh()
            automaticSpentToday = automaticCallBudget.automaticCallsToday()
            history.refresh()
            usageLedger.refresh()
            refreshSupportStatus()
        }
        .onChange(of: hasVerifiedAIConfiguration) { verified in
            if !verified { disableDeeperAISuggestions() }
        }
        .sheet(isPresented: $showsSupportReport) {
            SupportReportPreview(
                report: supportReport,
                onCopy: { copySupportReport() },
                onOpenIssue: { openBugReport() }
            )
        }
        .alert("Reset Bean completely?", isPresented: $showsFullResetConfirmation) {
            Button("Reset Bean and Quit", role: .destructive) { performFullReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bean will remove provider keys, writing personalization, usage and operation history, private automatic-call state, preferences, onboarding progress, launch-at-login registration, native-host manifests, and manual extension approvals. On success Bean quits; reopen it to start from Welcome. macOS Accessibility permission and the browser extension's own settings/blocklist must be removed separately.")
        }
        .alert("Clear usage and operation history?", isPresented: $showsAccountingClearConfirmation) {
            Button("Clear History", role: .destructive) { clearVisibleAccounting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes Bean's visible usage totals and content-free operation history. Today's private automatic-call count remains so the safety limit cannot be reset by clearing history.")
        }
    }

    @ViewBuilder
    private func sidebarRow(_ category: Category) -> some View {
        HStack {
            Label(category.rawValue, systemImage: category.symbol)
            Spacer()
            if category == .general && !isAccessibilityReady {
                StatusPill(text: "Access", kind: .warning, showsIcon: false)
            }
        }
        .frame(minHeight: BeanDesign.comfortableTargetSize)
        .padding(.horizontal, BeanDesign.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: BeanDesign.Radius.sm, style: .continuous)
                .fill(
                    category == navigation.selection
                        ? BeanDesign.accent.opacity(0.18)
                        : Color.clear
                )
        )
        .foregroundColor(
            category == navigation.selection ? BeanDesign.accent : .primary
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category.rawValue)
        .accessibilityHint(
            category == .general && !isAccessibilityReady
                ? "Accessibility permission is required"
                : ""
        )
    }

    @ViewBuilder
    private var detailSections: some View {
        switch navigation.selection {
        case .general:
            Section("Bean") { simpleStatusSection }
            Section("General") { generalSection }
            Section("Shortcuts") { shortcutSection }
            Section("Updates") { updateSection }
            Section {
                DisclosureGroup("Advanced") { generalAdvancedSection }
            }
        case .writing:
            Section("Writing Assistance") { writingAssistanceSection }
            Section { personalizationSection }
        case .provider:
            Section("Optional AI Provider") {
                ProviderSetupSection(settings: settings, usageLedger: usageLedger, compact: true)
            }
            Section("Usage") {
                usageSummarySection
                DisclosureGroup("Cost controls and detailed usage") {
                    timeoutRow
                    usageCostSection
                }
            }
        case .browser:
            Section("Bean for the Web") { browserExtensionSection }
        case .privacy:
            Section("Privacy") { privacySection }
            Section {
                DisclosureGroup("Your data") { DataSection(store: store) }
            }
            Section("Help") { simpleSupportSection }
            Section("Reset Bean") { fullResetSection }
        }
    }

    private var simpleStatusSection: some View {
        Group {
            HStack(spacing: 12) {
                IconBadge(symbol: isAccessibilityReady ? "checkmark.seal.fill" : "lock.shield",
                          tint: isAccessibilityReady ? BeanDesign.success : BeanDesign.warning, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isAccessibilityReady ? "Accessibility is ready" : "Allow access to use Bean in other apps")
                        .font(.headline)
                    Text(isAccessibilityReady
                         ? (hasVerifiedAIConfiguration
                            ? "Free local help is ready. AI is connected for deliberate actions."
                            : "Local writing help is available; AI is optional.")
                         : "The guided setup can take you directly to the required macOS permission.")
                        .font(.caption).foregroundColor(BeanDesign.secondaryText)
                }
                Spacer()
                Button(isAccessibilityReady ? "Review Setup" : "Continue Setup") {
                    actions.resetOnboarding()
                }
                .accessibilityHint("Opens Bean's three-step setup guide")
            }
            HStack(spacing: 14) {
                compactCheck("Accessibility", permissionStatus.granted)
                Label(hasVerifiedAIConfiguration ? "AI connected" : "AI optional",
                      systemImage: hasVerifiedAIConfiguration ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
                    .foregroundColor(hasVerifiedAIConfiguration ? BeanDesign.success : BeanDesign.secondaryText)
            }
        }
    }

    private func compactCheck(_ title: String, _ ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundColor(ready ? BeanDesign.success : BeanDesign.secondaryText)
    }

    private var writingAssistanceSection: some View {
        Group {
            Toggle("Live suggestions", isOn: liveSuggestionsBinding)
                .accessibilityHint("Runs local checks and underlines issues in supported fields")
            Text("Underlines obvious issues while you type in supported fields. Runs locally on your Mac with no token cost.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)

            Divider()

            Toggle("Deeper AI suggestions", isOn: deeperAISuggestionsBinding)
                .disabled(!canEnableDeeperAI && !deeperAISuggestionsEnabled)
                .accessibilityHint("Uses your connected AI provider after you type")
            Text("Optional. Adds provider suggestions to Live suggestions after you type. Uses API tokens and never replaces text until you approve it.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            if !canEnableDeeperAI {
                HStack(spacing: BeanDesign.Spacing.sm) {
                    Label("Connect and verify AI first", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(BeanDesign.secondaryText)
                    Button("Set Up AI") { navigation.selection = .provider }
                        .accessibilityHint("Opens AI and Usage settings")
                }
            }

            Divider()

            Toggle("Bean button", isOn: $settings.bubbleEnabled)
                .accessibilityHint("Shows a writing-actions button beside eligible editable fields")
            Text("Shows a small shortcut beside supported editable fields. It stays hidden in secure, read-only, and unsupported fields.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)

            DisclosureGroup("Advanced") { writingAdvancedOptions }
        }
    }

    private var personalizationSection: some View {
        DisclosureGroup(isExpanded: $showsPersonalization) {
            VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
                Picker("Personalization area", selection: $personalizationArea) {
                    ForEach(PersonalizationArea.allCases) { area in
                        Text(area.rawValue).tag(area)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Personalization category")

                personalizationContent
            }
            .padding(.top, BeanDesign.Spacing.sm)
        } label: {
            HStack {
                Label("Personalize Bean", systemImage: "slider.horizontal.3")
                Spacer()
                Text("Styles, context, and dictionary")
                    .font(.caption)
                    .foregroundColor(BeanDesign.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var personalizationContent: some View {
        switch personalizationArea {
        case .styles:
            StyleProfilesSection(store: store)
        case .appDefaults:
            AppDefaultsSection(store: store)
        case .writingContext:
            WritingContextSection(store: store)
        case .dictionary:
            DictionarySection(store: store)
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
            Text("Quick Fix and Live suggestions are free. Optional AI activity appears below.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
        }
    }

    private var isAccessibilityReady: Bool { permissionStatus.granted }

    /// Verification metadata is stored in UserDefaults. Reading it never
    /// touches Keychain, so merely opening Settings cannot trigger a password
    /// prompt. The AI page loads the credential only after the user chooses it.
    private var hasVerifiedAIConfiguration: Bool {
        settings.isProviderConnectionVerified
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
                    .font(.caption).foregroundColor(BeanDesign.secondaryText)
            } else {
                Text("No field has been inspected yet.")
                    .foregroundColor(BeanDesign.secondaryText)
            }
            Text("Focus a field in another app, then choose Bean → Help → Check Current Field from the menu bar. Bean records metadata only and does not read the field's text for this check.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
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
                Text(assessment.userFacingReason)
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.secondaryText)
            }
        }
    }

    private var recentOperationsSection: some View {
        Group {
            if history.records.isEmpty {
                Text("No operations recorded yet.").foregroundColor(BeanDesign.secondaryText)
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
                            .font(.caption).foregroundColor(BeanDesign.secondaryText)
                    }
                }
            }
            Button("Clear usage and operation history", role: .destructive) {
                showsAccountingClearConfirmation = true
            }
            Text("This clears both visible accounting views together. Today's automatic-call count still protects the safety limit.")
                .font(BeanDesign.Typography.smallCaption())
                .foregroundColor(BeanDesign.secondaryText)
            accountingClearFeedback
            Text("This bounded history contains operational metadata only—never text, prompts, responses, clipboard contents, or field labels.")
                .font(BeanDesign.Typography.smallCaption()).foregroundColor(BeanDesign.secondaryText)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Group {
            Toggle("Launch Bean at login", isOn: $loginEnabled)
                .onChange(of: loginEnabled) { newValue in setLogin(newValue) }
                .accessibilityHint("Starts Bean automatically when you sign in to this Mac")
            if let loginError {
                Text(loginError).font(.caption).foregroundColor(BeanDesign.danger)
            } else if !LoginItemService.isAvailable {
                Text("Launch at login is available when Bean runs from the built app.")
                    .font(.caption).foregroundColor(BeanDesign.secondaryText)
            }
        }
    }

    private var generalAdvancedSection: some View {
        Group {
            Toggle(
                "Use the whole focused field when no text is selected",
                isOn: $settings.fixFocusedFieldWhenNoSelection
            )
            .accessibilityHint("When off, Quick Fix requires selected text")
            Text("Turn this off if Quick Fix should require an explicit text selection.")
                .font(.caption)
                .foregroundColor(BeanDesign.secondaryText)
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
                    .font(.caption).foregroundColor(BeanDesign.secondaryText)
            case .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking GitHub Releases…").foregroundColor(BeanDesign.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Checking GitHub Releases")
            case .upToDate(let release):
                updateResult(release, available: false)
            case .updateAvailable(let release):
                updateResult(release, available: true)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(BeanDesign.warning)
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
            .font(BeanDesign.Typography.smallCaption()).foregroundColor(BeanDesign.secondaryText)
    }

    private var timeoutRow: some View {
        HStack {
            Text("Request timeout")
            Slider(value: $settings.timeoutSeconds, in: 5...120, step: 5)
                .accessibilityLabel("AI request timeout")
                .accessibilityValue("\(Int(settings.timeoutSeconds)) seconds")
                .accessibilityHint("Adjusts how long Bean waits for an AI provider")
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
            ForEach([OperationSource.manual, .nativeInline, .webInline], id: \.rawValue) { source in
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
                    .font(.caption).foregroundColor(BeanDesign.secondaryText)
            }
            if month.unpricedOperationCount > 0 {
                Label("Cost excludes \(month.unpricedOperationCount) calls using custom or unpriced model IDs.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(BeanDesign.secondaryText)
            }
            if month.totalTokens >= settings.monthlyTokenWarningThreshold {
                Label("Your 30-day token total has reached the warning threshold.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(BeanDesign.warning)
            }

            Divider()
            LabeledContent("Automatic provider checks") {
                StatusPill(text: settings.automaticAIChecksEnabled ? "On" : "Off",
                           kind: settings.automaticAIChecksEnabled ? .warning : .success,
                           showsIcon: false)
            }
            Text("Deeper AI suggestions and browser AI can call your provider. The daily limit covers all browser AI—including Fix Paragraph—because webpages cannot prove a trusted click. Explicit AI actions in the Bean Mac app remain uncapped. Quick Fix and Live suggestions stay local.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            Stepper("Daily automatic-call limit: \(settings.dailyAutomaticCallLimit)",
                    value: $settings.dailyAutomaticCallLimit, in: 1...200)
                .accessibilityHint("Limits automatic checks and all browser AI, but not explicit AI actions in the Bean Mac app")
            Stepper("30-day warning: \(settings.monthlyTokenWarningThreshold.formatted()) tokens",
                    value: $settings.monthlyTokenWarningThreshold,
                    in: 25_000...5_000_000, step: 25_000)
                .accessibilityHint("Sets the token usage warning threshold")
            if let automaticSpentToday {
                let automaticUsed = max(today.automaticOperationCount, automaticSpentToday)
                Text("Automatic calls today: \(automaticUsed) of \(settings.dailyAutomaticCallLimit). The limit does not disable explicit AI actions in the Bean Mac app or local Quick Fix.")
                    .font(.caption).foregroundColor(BeanDesign.secondaryText)
            } else {
                Label("Bean couldn't verify automatic-call accounting. Automatic provider checks pause safely until accounting is available; local Quick Fix still works.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.warning)
                Button("Check Accounting Again") { refreshAccountingStatus() }
                    .accessibilityHint("Retries Bean's private automatic-call safety check")
                Text("If the warning remains after reopening Bean, Full Reset in Privacy & Help is the data-erasing last resort. If reset reports a failure, preview a Support Report instead of repeating it.")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.secondaryText)
            }
            Button("Disable automatic AI checks") { settings.disableAutomaticAIChecks() }
                .disabled(!settings.automaticAIChecksEnabled)
            Text("Quick Fix is free and offline. At the pricing snapshot, OpenAI gpt-5-nano is $0.05/M input and $0.40/M output tokens; Claude Haiku 4.5 is $1/M input and $5/M output. Switching providers requires that provider's API key.")
                .font(BeanDesign.Typography.smallCaption()).foregroundColor(BeanDesign.secondaryText)
            Text("Estimated USD cost uses public list prices captured \(UsageCostEstimator.pricingSnapshot); actual billing, caching, tiers, taxes, and future price changes may differ.")
                .font(BeanDesign.Typography.smallCaption()).foregroundColor(BeanDesign.secondaryText)
            Button("Clear usage and operation history", role: .destructive) {
                showsAccountingClearConfirmation = true
            }
            Text("Clearing removes the visible content-free counters and operation metadata. It does not reset today's automatic-call limit, remove API keys, or change preferences.")
                .font(BeanDesign.Typography.smallCaption()).foregroundColor(BeanDesign.secondaryText)
            accountingClearFeedback
        }
    }

    @ViewBuilder
    private var accountingClearFeedback: some View {
        if let accountingClearMessage {
            Label(accountingClearMessage,
                  systemImage: accountingClearFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(BeanDesign.Typography.smallCaption())
                .foregroundColor(accountingClearFailed ? BeanDesign.danger : BeanDesign.success)
                .accessibilityLabel(accountingClearMessage)
        }
    }

    private func clearVisibleAccounting() {
        guard let result = automaticCallBudget.clearVisibleAccounting() else {
            accountingClearFailed = true
            accountingClearMessage = "Bean couldn't verify that both accounting stores were cleared. Try again; automatic AI remains safely capped."
            return
        }
        usageLedger.refresh()
        history.refresh()
        automaticSpentToday = result.automaticCallsToday
        accountingClearFailed = false
        if result.automaticCallsToday == 0 {
            accountingClearMessage = "Usage and operation history cleared."
        } else if result.automaticCallsToday == 1 {
            accountingClearMessage = "Usage and operation history cleared. Today's 1 automatic call still counts toward the safety limit."
        } else {
            accountingClearMessage = "Usage and operation history cleared. Today's \(result.automaticCallsToday) automatic calls still count toward the safety limit."
        }
    }

    private func refreshAccountingStatus() {
        automaticSpentToday = automaticCallBudget.automaticCallsToday()
        usageLedger.refresh()
        history.refresh()
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Writing shortcut runs", selection: $settings.primaryShortcutAction) {
                    ForEach(PrimaryShortcutAction.allCases) { action in
                        Text("\(action.displayName) · \(action.detail)").tag(action)
                    }
                }
                .pickerStyle(.menu)
                Text(settings.primaryShortcutAction == .quickFix
                     ? "Corrects obvious typos and spacing privately on your Mac."
                     : "Runs thorough proofreading with your connected AI provider. Full-field changes are previewed before replacement.")
                    .font(.caption)
                    .foregroundColor(BeanDesign.secondaryText)
            }
            Divider()
            shortcutRow(
                title: "Writing Shortcut",
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
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
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
                .accessibilityLabel("Record shortcut for \(title)")
                Button("Reset to Default") { error.wrappedValue = actions.applyShortcut(slot, resetTo) }
                    .accessibilityHint("Restores the default shortcut for \(title)")
            }
            if let message = error.wrappedValue {
                Text(message).font(.caption).foregroundColor(BeanDesign.danger)
            }
        }
    }

    // MARK: - Writing assistance

    private var liveSuggestionsBinding: Binding<Bool> {
        Binding(
            get: { settings.inlineHighlightsEnabled },
            set: { enabled in
                settings.inlineHighlightsEnabled = enabled
                if enabled {
                    if !deeperAISuggestionsEnabled {
                        settings.inlineLocalOnly = true
                        settings.inlineIncludeLLM = false
                    }
                } else {
                    disableDeeperAISuggestions()
                }
            }
        )
    }

    private var deeperAISuggestionsBinding: Binding<Bool> {
        Binding(
            get: { deeperAISuggestionsEnabled },
            set: { enabled in
                if enabled {
                    guard canEnableDeeperAI else { return }
                    settings.inlineHighlightsEnabled = true
                    settings.inlineLocalOnly = false
                    settings.inlineIncludeLLM = true
                } else {
                    disableDeeperAISuggestions()
                }
            }
        )
    }

    private var deeperAISuggestionsEnabled: Bool {
        settings.inlineHighlightsEnabled
            && !settings.inlineLocalOnly
            && settings.inlineIncludeLLM
    }

    private var canEnableDeeperAI: Bool {
        settings.hasAPIKey && hasVerifiedAIConfiguration
    }

    private func disableDeeperAISuggestions() {
        settings.inlineIncludeLLM = false
        settings.inlineLocalOnly = true
    }

    private func normalizeSimplifiedWritingSettings() {
        if !settings.inlineHighlightsEnabled || !canEnableDeeperAI {
            disableDeeperAISuggestions()
        } else if !settings.inlineIncludeLLM {
            settings.inlineLocalOnly = true
        }
    }

    private var writingAdvancedOptions: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.sm) {
            Text("Live suggestions")
                .font(.subheadline.weight(.semibold))
            Stepper(
                "Maximum issues shown: \(settings.inlineMaxIssues)",
                value: $settings.inlineMaxIssues,
                in: 1...8
            )
            .accessibilityHint("Sets the maximum simultaneous Live suggestion underlines")
            Toggle("Show explanations", isOn: $settings.inlineShowExplanation)
            Text("Code editors, search fields, secure fields, and fields Bean cannot verify remain excluded.")
                .font(BeanDesign.Typography.smallCaption())
                .foregroundColor(BeanDesign.secondaryText)

            monitorStatusRow

            Divider()

            Text("Bean button")
                .font(.subheadline.weight(.semibold))
            if settings.bubbleEnabled {
                bubbleOptions
            } else {
                Text("Turn on Bean button above to customize when and where it appears.")
                    .font(.caption)
                    .foregroundColor(BeanDesign.secondaryText)
            }
        }
        .padding(.top, BeanDesign.Spacing.xs)
    }

    private var bubbleOptions: some View {
        Group {
            Toggle("Show when a text field is focused", isOn: $settings.bubbleOnFocus)
            Toggle("Show when text is selected", isOn: $settings.bubbleOnSelection)
            Toggle("Open automatically on hover", isOn: $settings.bubbleOpenOnHover)
            HStack {
                Text("Delay before showing")
                Slider(value: $settings.bubbleDelay, in: 0.3...2.0, step: 0.1)
                    .accessibilityLabel("Bean button delay")
                    .accessibilityValue(String(format: "%.1f seconds", settings.bubbleDelay))
                    .accessibilityHint("Adjusts how long Bean waits before showing the button")
                Text(String(format: "%.1fs", settings.bubbleDelay)).monospacedDigit().frame(width: 40)
            }
            Toggle("Allow in chat apps", isOn: $settings.bubbleInChat)
            Toggle("Allow in mail and browser fields", isOn: $settings.bubbleInMailBrowser)
            Toggle("Allow in code editors", isOn: $settings.bubbleInCode)
            Toggle("Allow in search fields", isOn: $settings.bubbleInSearch)
            Text("These preferences only narrow eligible fields. Bean still hides the button anywhere it cannot verify safe editing.")
                .font(BeanDesign.Typography.smallCaption())
                .foregroundColor(BeanDesign.secondaryText)
        }
    }

    private var monitorStatusRow: some View {
        HStack {
            Label(
                "Writing monitor",
                systemImage: settings.monitorActive ? "dot.radiowaves.left.and.right" : "pause.circle"
            )
            .font(.caption)
            .foregroundColor(settings.monitorActive ? BeanDesign.success : BeanDesign.secondaryText)
            .accessibilityValue(settings.monitorActive ? "Active" : "Inactive")
            if settings.diagnosticsEnabled, settings.lastPauseHandler != "none" {
                Spacer()
                Text("last: \(settings.lastPauseHandler)")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.secondaryText)
            }
        }
    }

    private var browserExtensionSection: some View {
        BrowserExtensionSetupSection(settings: settings)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Group {
            Label("Provider-backed manual actions send text only when you trigger them.", systemImage: "hand.raised")
            Label("Deeper AI suggestions may send the current writing block after you type.", systemImage: "clock.arrow.circlepath")
            Label("Bean does not retain text you proofread, rewrite, or draft.", systemImage: "nosign")
            Label("Personalization is stored in Bean's private local data file. Provider-backed actions may also send a bounded view of the active style, examples, enabled Writing Context, and matching dictionary terms.", systemImage: "internaldrive")
            Label("Quick Fix and local checks never send text or personalization to an AI provider.", systemImage: "checkmark.shield")
            Label("API keys are stored in macOS Keychain.", systemImage: "key")
            Toggle("Extra diagnostics logging (no text)", isOn: $settings.diagnosticsEnabled)
            Text("Bean always keeps bounded local usage and content-free operation history. Always-on content-free events in Apple's unified log use fixed operation names, coarse app categories, and outcome or reason codes. This toggle adds structured provider/model, length, feature-state, and timing metrics.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            Text("Diagnostics and support reports may include app and bundle names, provider/model, feature states, counts, lengths, timing, and result codes—never processed text, prompts, API keys, or clipboard contents.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            HStack {
                Button("Open Privacy Policy") { openBundledDocument("PRIVACY") }
                Button("Open License") { openBundledDocument("LICENSE") }
            }
            if let legalDocumentError {
                Label(legalDocumentError, systemImage: "exclamationmark.triangle.fill")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.danger)
            }
        }
    }

    private func openBundledDocument(_ name: String) {
        let bundled = Bundle.main.url(forResource: name, withExtension: "md")
        let fallback: URL?
        switch name {
        case "PRIVACY": fallback = BeanPublicLinks.privacy
        case "LICENSE": fallback = BeanPublicLinks.license
        default: fallback = nil
        }
        guard let destination = bundled ?? fallback,
              NSWorkspace.shared.open(destination) else {
            legalDocumentError = "Bean couldn't open the \(name == "LICENSE" ? "license" : "privacy policy"). Try the canonical GitHub link from About."
            return
        }
        legalDocumentError = nil
    }

    // MARK: - Troubleshooting

    @State private var copiedDiagnostics = false
    @State private var diagnosticsCopyError: String?

    private var simpleSupportSection: some View {
        Group {
            if supportBrowserStatus == nil {
                HStack(spacing: BeanDesign.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Checking Bean setup…")
                        .font(.caption).foregroundColor(BeanDesign.secondaryText)
                }
            } else if supportRepairCards.isEmpty {
                HStack(alignment: .top, spacing: BeanDesign.Spacing.sm) {
                    IconBadge(symbol: "checkmark.circle.fill", tint: BeanDesign.success, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac-side setup checks passed").font(.callout.weight(.semibold))
                        Text("For live browser status, open Bean's extension and choose Check again. If something still feels wrong, preview a support report before sharing it.")
                            .font(.caption).foregroundColor(BeanDesign.secondaryText)
                    }
                }
                .padding(.vertical, BeanDesign.Spacing.xs)
            } else {
                ForEach(supportRepairCards) { card in supportRepairCard(card) }
            }

            HStack {
                Button("Preview Support Report") { previewSupportReport() }
                    .accessibilityHint("Shows exactly what Bean can copy for a GitHub bug report")
                Button(copiedDiagnostics ? "Diagnostics Copied ✓" : "Copy Diagnostics Summary") {
                    copyDiagnostics()
                }
                .accessibilityHint("Copies content-free technical diagnostics without opening or sending a report")
            }
            if let diagnosticsCopyError {
                Label(diagnosticsCopyError, systemImage: "exclamationmark.triangle.fill")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.danger)
            }
            Text("Support reports stay on this Mac until you explicitly copy them. Bean never submits a report or uploads diagnostics for you.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            DisclosureGroup("Advanced diagnostics") {
                if let warning = Diagnostics.pathWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(BeanDesign.warning).font(.callout)
                }
                Button("Reveal Bean in Finder") { revealInFinder() }
                Button("Open Console Logs") { openConsole() }
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

    private var supportRepairCards: [SupportRepairCard] {
        guard let supportBrowserStatus else { return [] }
        return SupportCenter.repairCards(
            accessibilityGranted: permissionStatus.granted,
            appLocationWarning: Diagnostics.pathWarning,
            runningInstanceCount: Diagnostics.runningInstanceCount,
            browserStatus: supportBrowserStatus,
            browserAIEnabled: settings.webInlineEnabled
        )
    }

    @ViewBuilder
    private func supportRepairCard(_ card: SupportRepairCard) -> some View {
        HStack(alignment: .top, spacing: BeanDesign.Spacing.sm) {
            IconBadge(symbol: card.symbol, tint: BeanDesign.warning, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.callout.weight(.semibold))
                Text(card.detail).font(.caption).foregroundColor(BeanDesign.secondaryText)
                if let actionTitle = card.actionTitle {
                    Button(actionTitle) { performRepairAction(card.action) }
                }
            }
            Spacer()
        }
        .padding(BeanDesign.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: 10).fill(BeanDesign.warmBackground))
        .accessibilityElement(children: .contain)
    }

    private func performRepairAction(_ action: SupportRepairAction) {
        switch action {
        case .guidedSetup:
            actions.resetOnboarding()
        case .browserSettings:
            navigation.selection = .browser
        case .revealApplication:
            revealInFinder()
        case .none:
            break
        }
    }

    private func refreshSupportStatus() {
        supportBrowserStatus = BrowserBridgeInstaller().inspect()
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
        let copied = NSPasteboard.general.setString(text, forType: .string)
        copiedDiagnostics = copied
        diagnosticsCopyError = copied
            ? nil
            : "Couldn't copy diagnostics. Nothing was sent; try again or use the support report preview."
    }

    private func previewSupportReport() {
        let diagnostics = Diagnostics(
            settings: settings, store: store, history: history,
            usageLedger: usageLedger, setupStatus: setupStatus
        ).summaryText
        supportReport = SupportReportBuilder().makeReport(diagnostics: diagnostics)
        showsSupportReport = true
    }

    private func copySupportReport() -> String? {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(supportReport, forType: .string) else {
            return "Couldn't copy the report. Nothing was sent; select the preview text and copy it manually."
        }
        return nil
    }

    private func openBugReport() -> String? {
        guard NSWorkspace.shared.open(BeanPublicLinks.newBug) else {
            return "Couldn't open GitHub. Nothing was uploaded; you can still copy the preview."
        }
        return nil
    }

    private var fullResetSection: some View {
        Group {
            Text("Full Reset removes Bean's provider keys, personalization files and generated backups, usage and operation history, private automatic-call state, preferences, onboarding progress, login item, native-host manifests, and manual extension approvals.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            Text("\(FullResetService.accessibilityRemovalInstructions) Bean also cannot remove the browser extension or erase its local settings and blocked-sites list; clear or remove the extension in your browser if desired.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            Text("Full Reset also cannot selectively erase earlier Apple unified-log entries; macOS controls their retention.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            Text("After a successful reset, Bean quits. Reopen it to start from the Welcome screen.")
                .font(.caption).foregroundColor(BeanDesign.secondaryText)
            Button("Full Reset Bean…", role: .destructive) {
                showsFullResetConfirmation = true
            }
            .accessibilityHint("Shows a confirmation before removing Bean data and quitting")
            fullResetFeedback
        }
    }

    @ViewBuilder
    private var fullResetFeedback: some View {
        if let result = fullResetResult {
            if result.succeeded {
                Label("Reset complete. Bean is quitting; reopen it to begin setup again.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundColor(BeanDesign.success)
            } else {
                Label("Reset incomplete. Bean did not quit.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold)).foregroundColor(BeanDesign.danger)
                if !result.completedAreas.isEmpty {
                    Text("Already removed: \(result.completedAreas.map(\.rawValue).joined(separator: ", ")). These changes were not rolled back.")
                        .font(BeanDesign.Typography.smallCaption())
                        .foregroundColor(BeanDesign.secondaryText)
                }
                ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                    Text("\(failure.area.rawValue): \(failure.message)")
                        .font(BeanDesign.Typography.smallCaption())
                        .foregroundColor(BeanDesign.danger)
                }
                if !result.skippedAreas.isEmpty {
                    Text("Not attempted: \(result.skippedAreas.map(\.rawValue).joined(separator: ", ")). Fix the items above, then retry.")
                        .font(BeanDesign.Typography.smallCaption())
                        .foregroundColor(BeanDesign.secondaryText)
                }
            }
        }
    }

    private func performFullReset() {
        fullResetResult = actions.fullReset()
        if fullResetResult?.succeeded == false {
            loginEnabled = LoginItemService.isEnabled
            refreshSupportStatus()
        }
    }
}

private struct SupportReportPreview: View {
    let report: String
    let onCopy: () -> String?
    let onOpenIssue: () -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var copyError: String?
    @State private var issueError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Support Report Preview")
                        .font(BeanDesign.Typography.title())
                    Text(copied
                         ? "Report copied after your review. Bean has not saved or sent it."
                         : "Review every line. Bean has not copied, saved, or sent this report.")
                        .font(.caption).foregroundColor(BeanDesign.secondaryText)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BeanDesign.Spacing.md)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(BeanDesign.warmBackground))

            HStack {
                Button(copied ? "Report Copied ✓" : "Copy Support Report") {
                    copyError = onCopy()
                    copied = copyError == nil
                }
                .buttonStyle(.borderedProminent)
                Button("Open GitHub Bug Form") { issueError = onOpenIssue() }
                Spacer()
                Text("Opening GitHub does not upload this preview.")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.secondaryText)
            }
            if let copyError {
                Label(copyError, systemImage: "exclamationmark.triangle.fill")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.danger)
            }
            if let issueError {
                Label(issueError, systemImage: "exclamationmark.triangle.fill")
                    .font(BeanDesign.Typography.smallCaption())
                    .foregroundColor(BeanDesign.danger)
            }
        }
        .padding(BeanDesign.Spacing.lg)
        .frame(width: 720, height: 620)
        .tint(BeanDesign.accent)
    }
}

/// A presenter-owned route keeps Settings navigation addressable even after
/// the window already exists. Entry points such as “Set Up AI” can therefore
/// open the exact destination they promise instead of dropping users on the
/// last/default page.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsView.Category

    init(selection: SettingsView.Category = .general) {
        self.selection = selection
    }
}
