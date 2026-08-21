import SwiftUI

// Reusable SwiftUI sections shared between Onboarding and Settings so the two
// stay consistent.

// MARK: - Provider setup (provider, API key, model, test)

struct ProviderSetupSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usageLedger: UsageLedgerStore
    /// When true, renders a compact heading (used inside Settings forms).
    var compact: Bool = false

    @State private var apiKeyField: String = ""
    @State private var testState: TestState = .idle

    private let transformer = WritingTransformService()

    enum TestState: Equatable {
        case idle, running, success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                Text("Connect a provider")
                    .font(.title2).bold()
                Text("Bean uses your own API key. It's stored in the macOS Keychain.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Picker("Provider", selection: $settings.provider) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("API key").font(.subheadline)
            SecureField("Enter your \(settings.provider.displayName) API key", text: $apiKeyField)
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKeyField) { _ in
                    settings.apiKey = apiKeyField
                    testState = .idle
                }
            if let keychainError = settings.keychainError {
                Label(keychainError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("Model").font(.subheadline)
            HStack {
                TextField("Model", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                Button("Default") { settings.model = settings.provider.defaultModel }
            }
            Text("Default for \(settings.provider.displayName): \(settings.provider.defaultModel)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button("Test API key") { runTest() }
                    .disabled(apiKeyField.isEmpty || testState == .running)
                testStatusView
            }
        }
        .onAppear { apiKeyField = settings.apiKey }
        .onChange(of: settings.provider) { _ in
            apiKeyField = settings.apiKey
            testState = .idle
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle: EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundColor(.secondary)
            }
        case .success:
            Label("Connection OK", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red).lineLimit(2)
        }
    }

    private func runTest() {
        settings.apiKey = apiKeyField
        testState = .running
        let provider = settings.provider
        let model = settings.model
        let key = settings.apiKey
        let timeout = settings.timeoutSeconds
        Task {
            do {
                let usage = try await transformer.testConnection(
                    provider: provider, model: model, apiKey: key, timeout: timeout)
                await MainActor.run {
                    usageLedger.record(usage, source: .manual,
                                       provider: provider.rawValue, model: model)
                    settings.markProviderConnectionVerified(provider: provider, model: model)
                    testState = .success
                }
            } catch let error as LLMError {
                await MainActor.run {
                    settings.invalidateProviderVerification()
                    testState = .failure(error.errorDescription ?? "Failed")
                }
            } catch {
                await MainActor.run {
                    settings.invalidateProviderVerification()
                    testState = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Accessibility permission

struct PermissionsSection: View {
    var compact: Bool = false
    @State private var granted: Bool = PermissionService.isAccessibilityGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                Text("Grant Accessibility")
                    .font(.title2).bold()
                Text("Bean needs Accessibility access to copy, paste, and replace text in other apps. It can't read or change anything until you act.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            StatusPill(text: granted ? "Allowed" : "Permission required",
                       kind: granted ? .success : .warning)

            HStack {
                Button("Open Accessibility Settings") {
                    PermissionService.requestAccessibility()
                    PermissionService.openAccessibilitySettings()
                }
                Button("Re-check") { granted = PermissionService.isAccessibilityGranted }
            }

            if !granted {
                Text("After enabling Bean in the list, come back and press Re-check. You may need to relaunch Bean.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Real cross-app verification

struct CrossAppVerificationSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: OperationHistoryStore
    @ObservedObject var setupStatus: SetupStatusStore
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verify Bean in another app")
                .font(.title2).bold()
            Text("This checks the part that matters: Accessibility, the global shortcut, focus restoration, and replacement in another app.")
                .font(.callout)
                .foregroundColor(.secondary)

            if history.hasConfirmedExternalReplacement {
                Label("Cross-app replacement verified", systemImage: "checkmark.seal.fill")
                    .foregroundColor(BeanDesign.success)
            } else {
                Label("Cross-app replacement not verified yet", systemImage: "circle.dashed")
                    .foregroundColor(.secondary)
            }

            BeanCard {
                Text("1. Open the synthetic TextEdit test file.")
                Text("2. Click in the sentence and press \(settings.shortcut.displayString).")
                Text("3. Return here after Bean reports Field fixed or Text fixed.")
            }
            .font(BeanDesign.Typography.caption())

            Button("Open TextEdit verification") {
                do {
                    try setupStatus.openTextEditVerificationFile()
                    openError = nil
                } catch {
                    openError = "Couldn't open the TextEdit test: \(error.localizedDescription)"
                }
            }
            .disabled(!settings.hasAPIKey || !PermissionService.isAccessibilityGranted)

            if let openError {
                Label(openError, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundColor(.red)
            }

            if !settings.hasAPIKey || !PermissionService.isAccessibilityGranted {
                Text("Complete the provider and Accessibility steps first.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
