import SwiftUI

// Reusable SwiftUI sections shared between Onboarding and Settings so the two
// stay consistent.

// MARK: - Provider setup (provider, API key, model, test)

struct ProviderSetupSection: View {
    @ObservedObject var settings: AppSettings
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
                try await transformer.testConnection(provider: provider, model: model, apiKey: key, timeout: timeout)
                await MainActor.run { testState = .success }
            } catch let error as LLMError {
                await MainActor.run { testState = .failure(error.errorDescription ?? "Failed") }
            } catch {
                await MainActor.run { testState = .failure(error.localizedDescription) }
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

// MARK: - Local "Try Bean" test (no clipboard, no other apps)

struct TryBeanSection: View {
    @ObservedObject var settings: AppSettings

    @State private var input: String = "i has a apple"
    @State private var status: Status = .idle

    private let transformer = WritingTransformService()

    enum Status: Equatable {
        case idle, fixing, fixed, noChanges
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try Bean")
                .font(.title2).bold()
            Text("This runs the real correction on the text below. It only changes this field — your clipboard and other apps are untouched.")
                .font(.callout)
                .foregroundColor(.secondary)

            TextEditor(text: $input)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack(spacing: 10) {
                Button("Test Fix") { runFix() }
                    .disabled(status == .fixing || !settings.hasAPIKey)
                statusView
            }

            if !settings.hasAPIKey {
                Text("Add an API key first (previous step) to try this.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle: EmptyView()
        case .fixing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Fixing…").font(.caption).foregroundColor(.secondary)
            }
        case .fixed:
            Label("Fixed", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
        case .noChanges:
            Label("No changes needed", systemImage: "equal.circle.fill").font(.caption).foregroundColor(.blue)
        case .error(let message):
            Label(message, systemImage: "xmark.circle.fill").font(.caption).foregroundColor(.red).lineLimit(2)
        }
    }

    private func runFix() {
        let (leading, core, trailing) = TextNormalizer.split(input)
        guard !core.isEmpty else { return }
        status = .fixing

        // Local-only context; this never touches the clipboard or other apps.
        let context = SourceAppContext(
            appName: AppInfo.name, bundleIdentifier: nil, processIdentifier: nil,
            focusedRole: nil, focusedSubrole: nil,
            acquisitionMode: .selectedText, isSearchLikeField: false
        )
        let provider = settings.provider
        let model = settings.model
        let key = settings.apiKey
        let timeout = settings.timeoutSeconds

        Task {
            do {
                let raw = try await transformer.transform(
                    text: core, action: .proofread, context: context,
                    provider: provider, model: model, apiKey: key, timeout: timeout
                )
                let corrected = TextNormalizer.sanitizeModelOutput(raw, originalCore: core)
                await MainActor.run {
                    if corrected == core {
                        status = .noChanges
                    } else {
                        input = leading + corrected + trailing
                        status = .fixed
                    }
                }
            } catch let error as LLMError {
                await MainActor.run { status = .error(error.errorDescription ?? "Provider error") }
            } catch {
                await MainActor.run { status = .error(error.localizedDescription) }
            }
        }
    }
}
