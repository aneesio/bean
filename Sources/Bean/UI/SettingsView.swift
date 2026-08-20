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
    let actions: SettingsActions

    @State private var selection: Category? = .general
    @State private var loginEnabled: Bool = LoginItemService.isEnabled
    @State private var loginError: String?
    @State private var proofreadError: String?
    @State private var beanMenuError: String?

    enum Category: String, CaseIterable, Identifiable {
        case general = "General"
        case provider = "AI Provider"
        case shortcuts = "Shortcuts"
        case style = "Actions & Style"
        case context = "Context"
        case passive = "Passive Suggestions"
        case inline = "Inline Highlights"
        case privacy = "Privacy & Diagnostics"
        case troubleshooting = "Troubleshooting"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .provider: return "cpu"
            case .shortcuts: return "command"
            case .style: return "wand.and.stars"
            case .context: return "doc.text"
            case .passive: return "bubble.left.and.text.bubble.right"
            case .inline: return "highlighter"
            case .privacy: return "lock.shield"
            case .troubleshooting: return "wrench.and.screwdriver"
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
    }

    @ViewBuilder
    private func sidebarRow(_ category: Category) -> some View {
        HStack {
            Label(category.rawValue, systemImage: category.symbol)
            Spacer()
            switch category {
            case .provider where !settings.hasAPIKey:
                StatusPill(text: "Set up", kind: .warning, showsIcon: false)
            case .general where !PermissionService.isAccessibilityGranted:
                StatusPill(text: "!", kind: .warning, showsIcon: false)
            case .inline:
                StatusPill(text: "Beta", kind: .experimental, showsIcon: false)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var detailSections: some View {
        switch selection ?? .general {
        case .general:
            if !settings.isSetupComplete { Section { setupWarning } }
            Section("General") { generalSection }
            Section("Bean Bubble") { bubbleSection }
            Section("Permissions") { PermissionsSection(compact: true) }
        case .provider:
            Section("AI Provider") {
                ProviderSetupSection(settings: settings, compact: true)
                timeoutRow
            }
            Section("Usage & Cost") { usageCostSection }
        case .shortcuts:
            Section("Shortcuts") { shortcutSection }
        case .style:
            Section("Style Profiles") { StyleProfilesSection(store: store) }
            Section("App Defaults") { AppDefaultsSection(store: store) }
        case .context:
            Section("Context Cards") { ContextCardsSection(store: store) }
            Section("Personal Dictionary") { DictionarySection(store: store) }
        case .passive:
            Section("Passive Suggestions") { passiveSection }
        case .inline:
            Section("Inline Highlights (experimental)") { inlineSection }
            Section("Browser Extension (Beta)") { browserExtensionSection }
        case .privacy:
            Section("Privacy") { privacySection }
            Section("Data") { DataSection(store: store) }
        case .troubleshooting:
            Section("Troubleshooting") { troubleshootingSection }
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
        Group {
            LabeledContent("Automatic provider checks") {
                StatusPill(text: settings.automaticAIChecksEnabled ? "On" : "Off",
                           kind: settings.automaticAIChecksEnabled ? .warning : .success,
                           showsIcon: false)
            }
            Text("Passive Suggestions, provider-backed Inline Highlights, and Web Inline Support can call the API after typing pauses. Manual shortcuts and the Bean Bubble call it only when you choose an action.")
                .font(.caption).foregroundColor(.secondary)
            Button("Disable automatic AI checks") { settings.disableAutomaticAIChecks() }
                .disabled(!settings.automaticAIChecksEnabled)
            Text("This keeps explicit actions available and leaves native inline checking in local-only mode. For lower per-token cost, OpenAI's gpt-4.1-nano is Bean's default OpenAI model; switching providers requires an OpenAI API key.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        Group {
            shortcutRow(
                title: "Quick Proofread",
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
                Toggle("Show when a text field is focused", isOn: $settings.bubbleOnFocus)
                Toggle("Show when text is selected", isOn: $settings.bubbleOnSelection)
                Toggle("Open menu on hover (otherwise click)", isOn: $settings.bubbleOpenOnHover)
                HStack {
                    Text("Delay before showing")
                    Slider(value: $settings.bubbleDelay, in: 0.3...2.0, step: 0.1)
                    Text(String(format: "%.1fs", settings.bubbleDelay)).monospacedDigit().frame(width: 40)
                }
                Toggle("Show in chat apps", isOn: $settings.bubbleInChat)
                Toggle("Show in mail / browser text fields", isOn: $settings.bubbleInMailBrowser)
                Toggle("Show in code editors", isOn: $settings.bubbleInCode)
                Toggle("Show in search / address fields", isOn: $settings.bubbleInSearch)
            }
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
                Toggle("Enable in mail / browser text fields", isOn: $settings.passiveInMailBrowser)
                Toggle("Enable in code editors", isOn: $settings.passiveInCode)
                Toggle("Enable in search / address fields", isOn: $settings.passiveInSearch)
                Toggle("Only call AI when an offline check finds a likely issue", isOn: $settings.passiveOnlyWhenLikely)
                Toggle("Require preview before apply", isOn: $settings.passiveRequirePreview)
            }
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
                Text("Code editors, search/address bars, and secure fields are always excluded.")
                    .font(.caption2).foregroundColor(.secondary)
                Stepper("Max issues shown: \(settings.inlineMaxIssues)", value: $settings.inlineMaxIssues, in: 1...8)
                Toggle("Use local checks only (no token cost)", isOn: $settings.inlineLocalOnly)
                Toggle("Include LLM issue suggestions", isOn: $settings.inlineIncludeLLM)
                    .disabled(settings.inlineLocalOnly)
                Toggle("Show explanation in correction card", isOn: $settings.inlineShowExplanation)
                Toggle("Fall back to Passive Suggestions when highlights unavailable", isOn: $settings.inlineFallbackPassive)
            }
        }
    }

    // MARK: - Browser Extension

    @State private var copiedInstall = false

    private var browserExtensionSection: some View {
        Group {
            HStack {
                Toggle("Enable Web Inline Support", isOn: $settings.webInlineEnabled)
                Spacer()
                StatusPill(text: "Beta", kind: .experimental, showsIcon: false)
            }
            Text("Native Inline Highlights work where macOS exposes reliable text positions. Web apps (Gmail, Slack web, Notion, Jira) need the Bean browser extension. Unsupported editors fall back to Passive Suggestions or the Bean Bubble.")
                .font(.caption).foregroundColor(.secondary)

            Text("When enabled, browser text is sent to Bean locally through Chrome Native Messaging so Bean can generate suggestions using your configured AI provider. Bean does not store this text.")
                .font(.caption2).foregroundColor(.secondary)

            HStack {
                Button("Reveal Extension Folder") { revealExtensionFolder() }
                Button("Setup Guide") { actions.openReadme() }
            }
            Button(copiedInstall ? "Install command copied ✓" : "Copy Native Host Install Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("./scripts/install_native_messaging_host.sh <extension-id>", forType: .string)
                copiedInstall = true
            }
            Text("Setup: load BrowserExtension/ unpacked in Chrome (Developer mode), copy its extension ID, then run the install command above with that ID. Test the connection from the extension's Options.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private func revealExtensionFolder() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
           FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            actions.openReadme()
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Group {
            Label("Bean only sends text when you trigger it.", systemImage: "hand.raised")
            Label("Bean does not store your text.", systemImage: "nosign")
            Label("API keys are stored in macOS Keychain.", systemImage: "key")
            Toggle("Diagnostics logging (no text)", isOn: $settings.diagnosticsEnabled)
            Text("Diagnostics record operational metrics only — lengths and result codes. Never your text, prompts, or clipboard.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Troubleshooting

    @State private var copiedDiagnostics = false

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
        let text = Diagnostics(settings: settings, store: store).summaryText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedDiagnostics = true
    }
}
