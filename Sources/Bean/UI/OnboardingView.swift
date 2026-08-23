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
                    symbol: "checkmark.circle",
                    title: "Fix it in place",
                    subtitle: "Clean up writing without moving it between apps."
                )
                BenefitCard(
                    symbol: "laptopcomputer",
                    title: "Free by default",
                    subtitle: "Quick Fix runs privately on your Mac."
                )
                BenefitCard(
                    symbol: "hand.raised",
                    title: "You stay in control",
                    subtitle: "AI and browser help are always optional."
                )
            }

            Text("You can be ready in under a minute. Bean asks for one macOS permission, then lets you try it here.")
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
            "macOS requires Accessibility permission before Bean can read or replace text in another app. Bean never replaces text until you approve it."
        ) {
            PermissionsSection(compact: true, permission: permission)

            if !permission.granted {
                Divider().opacity(0.4)
                Label(
                    "You can continue and try Bean's local checker here. Cross-app shortcuts will wait until this permission is allowed.",
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
                    Text(permission.granted ? "Bean is ready" : "Bean's free checker is ready")
                        .font(BeanDesign.Typography.title())
                    Text(permission.granted
                         ? "Quick Fix is available here and in your other apps."
                         : "Try it below now. Allow Accessibility later to use it in other apps.")
                        .font(BeanDesign.Typography.caption())
                        .foregroundColor(.secondary)
                }
            }

            tryoutCard

            Text("Use Bean anywhere")
                .font(.headline)
            BeanCard {
                shortcutRow("Quick Fix · Free & private", settings.shortcut.displayString)
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
            Text("Try Quick Fix").font(.headline)
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
                .accessibilityLabel("Quick Fix sample text")
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

            Text(permission.granted
                 ? "This button demonstrates Quick Fix. The same action is available with \(settings.shortcut.displayString) in supported text fields."
                 : "This sample needs no permission. Allow Accessibility before using \(settings.shortcut.displayString) in another app.")
                .font(BeanDesign.Typography.caption())
                .foregroundColor(.secondary)
        }
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
                    Text("Optional inline help for ordinary writing fields on websites.")
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
                Button(permission.granted ? "Start using Bean" : "Use Bean Locally") {
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
