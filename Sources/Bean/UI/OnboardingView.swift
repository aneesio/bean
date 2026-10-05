import AppKit
import SwiftUI

/// The first-run path is deliberately short. AI and browser support are
/// enhancements, not requirements for Bean's free local writing help.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case accessibility
    case ready
}

struct OnboardingView: View {
    private static let sampleText = "teh quick  brown fox"

    @ObservedObject var settings: AppSettings
    @ObservedObject var usageLedger: UsageLedgerStore

    /// Called only when the user explicitly finishes. Closing early preserves
    /// the current step so setup resumes where the user left it.
    let onClose: () -> Void

    @StateObject private var permission = AccessibilityPermissionModel()
    @State private var tryoutText = Self.sampleText
    @State private var lastCheckedText: String?
    @State private var showsAISetup = false
    @State private var showsBrowserSetup = false
    @State private var appLocationIsWorking = false
    @State private var appLocationError: String?
    @FocusState private var tryoutFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: OnboardingStep {
        OnboardingStep(rawValue: settings.onboardingStepRawValue) ?? .welcome
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BeanDesign.Spacing.xl)
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.4)
            footer
                .padding(.horizontal, BeanDesign.Spacing.xl)
                .padding(.vertical, BeanDesign.Spacing.md)
        }
        .frame(minWidth: 600, idealWidth: 640,
               minHeight: 620, idealHeight: 700)
        .tint(BeanDesign.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        .onAppear {
            normalizePersistedStep()
            permission.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: BeanDesign.Spacing.sm) {
                BeanMark(size: 26)
                Text("Bean").font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            StepDots(count: OnboardingStep.allCases.count, current: step.rawValue)
                .accessibilityLabel("Setup step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
        }
        .padding(.horizontal, BeanDesign.Spacing.xl)
        .padding(.vertical, BeanDesign.Spacing.md)
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .accessibility:
            accessibilityStep
        case .ready:
            readyStep
        }
    }

    private func stepFrame<C: View>(
        _ title: String,
        _ subtitle: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.lg) {
            VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
                Text(title).font(BeanDesign.Typography.title())
                Text(subtitle)
                    .font(BeanDesign.Typography.body())
                    .foregroundColor(.secondary)
            }
            BeanCard { content() }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.lg) {
            VStack(alignment: .center, spacing: BeanDesign.Spacing.md) {
                BeanMark(size: 76)
                Text("Meet Bean").font(BeanDesign.Typography.largeTitle())
                Text("Better writing, right where you type.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BeanDesign.Spacing.md)

            if !Diagnostics.appLocationAssessment.isStable {
                unstableAppLocationCard
            }

            HStack(spacing: BeanDesign.Spacing.md) {
                BenefitCard(
                    symbol: "laptopcomputer",
                    title: "Where you type",
                    subtitle: "Live suggestions in supported text fields."
                )
                BenefitCard(
                    symbol: "lock.shield",
                    title: "Checks stay local",
                    subtitle: "Spelling and basic grammar run on this Mac."
                )
                BenefitCard(
                    symbol: "text.badge.checkmark",
                    title: "Fix in place",
                    subtitle: "Accept a correction, Proofread, or Rewrite."
                )
            }

            Text("Allow Accessibility to enable help in your apps. Set up the browser extension for website suggestions and direct edits. AI rewriting is optional.")
                .font(BeanDesign.Typography.caption())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var unstableAppLocationCard: some View {
        BeanCard {
            HStack(alignment: .top, spacing: BeanDesign.Spacing.md) {
                IconBadge(symbol: "exclamationmark.triangle.fill", tint: BeanDesign.warning, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep Bean reliable")
                        .font(.callout.weight(.semibold))
                    Text(Diagnostics.appLocationAssessment.reason)
                        .font(BeanDesign.Typography.caption())
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: BeanDesign.Spacing.sm) {
                Button(installedCopyExists ? "Open Installed Bean" : "Install in Applications") {
                    resolveAppLocation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appLocationIsWorking)

                if appLocationIsWorking {
                    ProgressView().controlSize(.small)
                    Text(installedCopyExists ? "Opening…" : "Installing…")
                        .font(BeanDesign.Typography.caption())
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: BeanDesign.Spacing.md) {
                Button("Reveal This Copy") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(.link)
                Button("Open Applications") {
                    NSWorkspace.shared.open(
                        AppLocationAssessment.canonicalApplicationURL.deletingLastPathComponent()
                    )
                }
                .buttonStyle(.link)
            }

            if let appLocationError {
                Label(appLocationError, systemImage: "exclamationmark.circle.fill")
                    .font(BeanDesign.Typography.caption())
                    .foregroundColor(BeanDesign.danger)
            }
        }
    }

    private var accessibilityStep: some View {
        stepFrame(
            "Allow Bean where you write",
            "macOS requires Accessibility permission to check and fix text in your apps. Accept a suggestion, or run Proofread to replace the current text in one action."
        ) {
            PermissionsSection(compact: true, permission: permission)

            if !permission.granted {
                Divider().opacity(0.4)
                Label(
                    "You can try the local sample before allowing permission. Live suggestions and direct replacement in your apps require Accessibility.",
                    systemImage: "info.circle"
                )
                .font(BeanDesign.Typography.caption())
                .foregroundColor(.secondary)
            }
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.lg) {
            HStack(spacing: BeanDesign.Spacing.md) {
                IconBadge(
                    symbol: permission.granted ? "checkmark.seal.fill" : "checkmark.circle.fill",
                    tint: permission.granted ? BeanDesign.success : BeanDesign.accent,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.granted ? "Bean is ready in your apps" : "Try Bean while you finish setup")
                        .font(BeanDesign.Typography.title())
                    Text(permission.granted
                         ? "Start typing in a supported field. Click Bean to review suggestions or improve your writing."
                         : "The local sample works below. Allow Accessibility to enable help where you type.")
                        .font(BeanDesign.Typography.caption())
                        .foregroundColor(.secondary)
                }
            }

            tryoutCard

            BeanCard {
                Text("Live suggestions").font(.headline)
                Toggle("Underline issues while I type", isOn: $settings.inlineHighlightsEnabled)
                    .disabled(!permission.granted)
                Text(permission.granted
                     ? "Local checks are on by default. Click the Bean control inside your field to review issues, Proofread, or Rewrite. Underlines appear when precise text placement is available."
                     : "Allow Accessibility to activate live checking and direct replacement in your apps.")
                    .font(BeanDesign.Typography.caption())
                    .foregroundColor(.secondary)
            }

            Text("Shortcuts in your apps")
                .font(.headline)
            BeanCard {
                shortcutRow(settings.primaryShortcutAction.displayName, settings.shortcut.displayString)
                Text(settings.primaryShortcutAction.detail)
                    .font(BeanDesign.Typography.caption())
                    .foregroundColor(.secondary)
                Divider().opacity(0.4)
                shortcutRow("Open Bean menu", settings.beanMenuShortcut.displayString)
            }

            Text("Optional enhancements")
                .font(.headline)
            optionalAISection
            optionalBrowserSection
        }
    }

    private var tryoutCard: some View {
        BeanCard {
            Text("Try a local sample").font(.headline)
            TextEditor(text: $tryoutText)
                .focused($tryoutFocused)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(BeanDesign.subtleBorder)
                )
                .accessibilityLabel("Local proofreading sample")
                .onAppear {
                    DispatchQueue.main.async { tryoutFocused = true }
                }
                .onChange(of: tryoutText) { newValue in
                    if let lastCheckedText, newValue != lastCheckedText {
                        self.lastCheckedText = nil
                    }
                }

            HStack {
                Button(sampleWasChecked ? "Checked ✓" : "Run Free Check") {
                    runSampleCheck()
                }
                .buttonStyle(.borderedProminent)

                if tryoutText != Self.sampleText || sampleWasChecked {
                    Button("Reset Sample") { resetSample() }
                }

                Spacer()
                Label("Runs on this Mac", systemImage: "lock.shield")
                    .font(BeanDesign.Typography.caption())
                    .foregroundColor(.secondary)
            }

            Text(sampleGuidance)
                .font(BeanDesign.Typography.caption())
                .foregroundColor(.secondary)
        }
    }

    private var sampleGuidance: String {
        let action = settings.primaryShortcutAction
        let shortcut = settings.shortcut.displayString
        let actionGuidance = action == .quickFix
            ? "\(shortcut) runs \(action.displayName) locally on selected text or the focused field."
            : "\(shortcut) runs \(action.displayName) using your configured AI provider on selected text or the focused field."
        return permission.granted
            ? "This sample demonstrates local corrections. Return to your app to try your shortcut. \(actionGuidance)"
            : "This sample needs no permission. Allow Accessibility before using the shortcut in another app. \(actionGuidance)"
    }

    @ViewBuilder
    private var optionalAISection: some View {
        BeanCard {
            HStack(alignment: .top, spacing: BeanDesign.Spacing.md) {
                IconBadge(symbol: "sparkles", size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add AI writing tools").font(.callout.weight(.semibold))
                    Text("Optional rewrites and deeper proofreading using your own provider key.")
                        .font(BeanDesign.Typography.caption())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !showsAISetup {
                    Button("Add AI") { showsAISetup = true }
                }
            }

            if showsAISetup {
                Divider().opacity(0.4)
                ProviderSetupSection(
                    settings: settings,
                    usageLedger: usageLedger,
                    compact: true,
                    showsModelSettings: false
                )
                Button("Not Now") { showsAISetup = false }
            }
        }
    }

    @ViewBuilder
    private var optionalBrowserSection: some View {
        BeanCard {
            HStack(alignment: .top, spacing: BeanDesign.Spacing.md) {
                IconBadge(symbol: "globe", size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Bean to your browser").font(.callout.weight(.semibold))
                    Text("Live suggestions and direct Proofread or Rewrite in supported website fields.")
                        .font(BeanDesign.Typography.caption())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !showsBrowserSetup {
                    Button("Set Up Browser") { showsBrowserSetup = true }
                }
            }

            if showsBrowserSetup {
                Divider().opacity(0.4)
                BrowserExtensionSetupSection(settings: settings, onboarding: true)
                Button("Not Now") { showsBrowserSetup = false }
            }
        }
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(BeanDesign.subtleBorder))
        }
    }

    // MARK: - Footer / navigation

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
            }

            Spacer()

            if step == .ready {
                Button("Finish Setup") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            } else {
                Button(nextButtonTitle) { goNext() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func goNext() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        settings.onboardingStepRawValue = next.rawValue
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        settings.onboardingStepRawValue = previous.rawValue
    }

    private var nextButtonTitle: String {
        switch step {
        case .welcome:
            return "Continue"
        case .accessibility:
            return permission.granted ? "Continue" : "Continue for Now"
        case .ready:
            return permission.granted ? "Start using Bean" : "Use Bean Locally"
        }
    }

    private var sampleWasChecked: Bool {
        lastCheckedText == tryoutText
    }

    private func runSampleCheck() {
        let corrected = LocalQuickChecker.corrected(tryoutText, dictionary: [])
        tryoutText = corrected
        lastCheckedText = corrected
        tryoutFocused = true
    }

    private func resetSample() {
        tryoutText = Self.sampleText
        lastCheckedText = nil
        tryoutFocused = true
    }

    private func normalizePersistedStep() {
        guard OnboardingStep(rawValue: settings.onboardingStepRawValue) == nil else { return }
        settings.onboardingStepRawValue = OnboardingStep.welcome.rawValue
    }

    private var installedCopyExists: Bool {
        FileManager.default.fileExists(atPath: AppLocationAssessment.canonicalApplicationURL.path)
    }

    private func resolveAppLocation() {
        appLocationIsWorking = true
        appLocationError = nil
        let shouldOpenExistingCopy = installedCopyExists

        Task {
            do {
                let service = AppLocationService()
                if shouldOpenExistingCopy {
                    try await service.openInstalledCopy()
                } else {
                    try await service.installAndRelaunch()
                }
            } catch {
                appLocationError = error.localizedDescription
                appLocationIsWorking = false
            }
        }
    }
}
