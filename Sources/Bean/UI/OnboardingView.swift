import SwiftUI

// First-run onboarding — a calm five-step flow whose verification step uses a
// disposable TextEdit file to prove the real cross-app Accessibility path.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: OperationHistoryStore
    @ObservedObject var setupStatus: SetupStatusStore

    /// Called when the user finishes or skips. The presenter marks onboarding
    /// complete and closes the window.
    let onClose: () -> Void

    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable {
        case welcome, provider, permissions, verify, done
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
        .frame(width: 540, height: 600)
        .tint(BeanDesign.accent)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    private var header: some View {
        HStack {
            HStack(spacing: BeanDesign.Spacing.sm) {
                BeanMark(size: 26)
                Text("Bean").font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            StepDots(count: Step.allCases.count, current: step.rawValue)
        }
        .padding(.horizontal, BeanDesign.Spacing.xl)
        .padding(.vertical, BeanDesign.Spacing.md)
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .provider: stepFrame("Connect AI", "Bean uses your own API key. It stays in your Mac's Keychain.") {
            ProviderSetupSection(settings: settings, compact: true)
        }
        case .permissions: stepFrame("Grant Accessibility", "Bean needs Accessibility permission to read and replace text when you ask it to.") {
            PermissionsSection(compact: true)
        }
        case .verify:
            CrossAppVerificationSection(settings: settings, history: history, setupStatus: setupStatus)
        case .done: doneStep
        }
    }

    private func stepFrame<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.lg) {
            VStack(alignment: .leading, spacing: BeanDesign.Spacing.xs) {
                Text(title).font(BeanDesign.Typography.title())
                Text(subtitle).font(BeanDesign.Typography.body()).foregroundColor(.secondary)
            }
            BeanCard { content() }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.lg) {
            VStack(alignment: .center, spacing: BeanDesign.Spacing.md) {
                BeanMark(size: 76)
                Text("Meet Bean").font(BeanDesign.Typography.largeTitle())
                Text("A small writing helper for your Mac.")
                    .font(.system(size: 15)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BeanDesign.Spacing.md)

            HStack(spacing: BeanDesign.Spacing.md) {
                BenefitCard(symbol: "checkmark.circle", title: "Proofread anywhere",
                            subtitle: "Fix grammar in most Mac apps with a shortcut.")
                BenefitCard(symbol: "sparkles", title: "Rewrite with style",
                            subtitle: "Clearer, concise, professional, or casual.")
                BenefitCard(symbol: "hand.raised", title: "Stay in control",
                            subtitle: "Review before anything is replaced.")
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: BeanDesign.Spacing.lg) {
            HStack(spacing: BeanDesign.Spacing.md) {
                IconBadge(symbol: isFullyVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                          tint: isFullyVerified ? BeanDesign.success : BeanDesign.warning, size: 40)
                Text(isFullyVerified ? "You're all set" : "Almost there")
                    .font(BeanDesign.Typography.title())
            }

            if isFullyVerified {
                Text("Bean lives in your menu bar. Use these shortcuts anywhere:")
                    .foregroundColor(.secondary)
                BeanCard {
                    shortcutRow("Quick Proofread", settings.shortcut.displayString)
                    Divider().opacity(0.4)
                    shortcutRow("Bean menu", settings.beanMenuShortcut.displayString)
                }
                Text("You can change these later in Settings.")
                    .font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
            } else {
                BeanCard {
                    if !settings.hasAPIKey {
                        Label("No API key yet — add one in Settings to enable corrections.", systemImage: "key")
                    }
                    if !PermissionService.isAccessibilityGranted {
                        Label("Accessibility permission not granted — Bean can't fix text without it.", systemImage: "lock.shield")
                    }
                    if !history.hasConfirmedExternalReplacement {
                        Label("Cross-app replacement has not been verified yet.", systemImage: "rectangle.and.pencil.and.ellipsis")
                    }
                    Text("You can finish now and complete these in Settings.")
                        .font(BeanDesign.Typography.caption()).foregroundColor(.secondary)
                }
            }
        }
    }

    private var isFullyVerified: Bool {
        settings.isSetupComplete && settings.isProviderConnectionVerified
            && history.hasConfirmedExternalReplacement
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(BeanDesign.subtleBorder))
        }
    }

    // MARK: - Footer / navigation

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
            }
            Button("Skip") { onClose() }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)

            Spacer()

            if step == .done {
                Button("Start using Bean") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { goNext() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func goNext() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }
    private func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }
}
