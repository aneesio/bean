import AppKit
import SwiftUI

// Reusable SwiftUI sections shared between Onboarding and Settings so the two
// stay consistent.

// MARK: - Provider setup (provider, API key, model, test)

/// Owns the API-key editor's transient state and keeps its Keychain boundary
/// explicit. Constructing this model, rendering the provider page, and moving
/// between providers use only `hasAPIKey(for:)` metadata. This setup UI fetches
/// the stored secret only after the user chooses Edit Key, Test Connection, or
/// the legacy-recovery action for a credential whose presence is still unknown.
@MainActor
final class ProviderKeyEditorModel: ObservableObject {
    struct ConnectionTestToken: Equatable {
        fileprivate let generation: UInt64
        let provider: ProviderKind
        let model: String
    }

    @Published var draft: String = ""
    @Published private(set) var isEditing: Bool
    @Published private(set) var loadedSavedKey: String = ""

    private let settings: AppSettings
    private(set) var provider: ProviderKind
    private(set) var hasLoadedSavedKey = false
    private var connectionTestGeneration: UInt64 = 0
    private var activeConnectionTest: ConnectionTestToken?

    init(settings: AppSettings) {
        self.settings = settings
        self.provider = settings.provider
        self.isEditing = !settings.hasAPIKey(for: settings.provider)
    }

    var hasSavedKey: Bool {
        settings.hasAPIKey(for: provider)
    }

    /// Older Bean releases could save a Keychain item without separate presence
    /// metadata. Showing this recovery choice is metadata-only; the Keychain is
    /// not queried until the user chooses it.
    var canRecoverExistingKey: Bool {
        settings.apiKeyPresenceState(for: provider) == .unknown
    }

    var draftMatchesLoadedKey: Bool {
        hasLoadedSavedKey && draft == loadedSavedKey
    }

    /// Resets only transient presentation state. This method is safe to call
    /// from SwiftUI lifecycle/navigation callbacks because it never reads the
    /// Keychain.
    func synchronizeProvider(_ provider: ProviderKind) {
        guard provider != self.provider else { return }
        invalidateConnectionTest()
        self.provider = provider
        settings.clearKeychainError()
        draft = ""
        loadedSavedKey = ""
        hasLoadedSavedKey = false
        isEditing = !settings.hasAPIKey(for: provider)
    }

    /// Deliberate secret boundary for the Edit Key button.
    func beginEditingStoredKey() {
        loadStoredKeyForExplicitAction()
        isEditing = true
    }

    /// Deliberate legacy-recovery boundary. This only loads the Keychain value
    /// into the editor; testing remains a separate explicit button action.
    @discardableResult
    func recoverExistingKeyForExplicitAction() -> Bool {
        invalidateConnectionTest()
        loadStoredKeyForExplicitAction()
        isEditing = true
        return !draft.isEmpty
    }

    /// Deliberate secret boundary for the Test Connection button. A newly
    /// typed draft needs no Keychain read; a saved credential is loaded only
    /// because the user explicitly requested a provider call.
    func keyForExplicitConnectionTest() -> String {
        if !draft.isEmpty { return draft }
        guard hasSavedKey else {
            isEditing = true
            return ""
        }
        loadStoredKeyForExplicitAction()
        isEditing = true
        return draft
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard !draft.isEmpty else { return false }
        settings.setAPIKey(draft, for: provider)
        guard settings.keychainError == nil else { return false }
        loadedSavedKey = draft
        hasLoadedSavedKey = true
        return true
    }

    @discardableResult
    func removeStoredKey() -> Bool {
        settings.setAPIKey("", for: provider)
        guard settings.keychainError == nil else { return false }
        draft = ""
        loadedSavedKey = ""
        hasLoadedSavedKey = true
        isEditing = true
        return true
    }

    func cancelEditing() {
        draft = ""
        loadedSavedKey = ""
        hasLoadedSavedKey = false
        isEditing = !settings.hasAPIKey(for: provider)
    }

    /// Gives each asynchronous connection check an identity bound to the exact
    /// provider/model pair it is testing. A later check or configuration change
    /// makes an older completion stale without affecting its usage accounting.
    func beginConnectionTest(
        provider: ProviderKind,
        model: String
    ) -> ConnectionTestToken {
        connectionTestGeneration &+= 1
        let token = ConnectionTestToken(
            generation: connectionTestGeneration,
            provider: provider,
            model: model
        )
        activeConnectionTest = token
        return token
    }

    /// Consumes only the current token and only for the still-selected pair.
    /// Stale tasks cannot overwrite a newer test result or verification state.
    func acceptConnectionTestCompletion(
        _ token: ConnectionTestToken,
        currentProvider: ProviderKind,
        currentModel: String
    ) -> Bool {
        guard activeConnectionTest == token else { return false }
        activeConnectionTest = nil
        return token.provider == currentProvider && token.model == currentModel
    }

    func invalidateConnectionTest() {
        activeConnectionTest = nil
    }

    private func loadStoredKeyForExplicitAction() {
        guard !hasLoadedSavedKey else {
            draft = loadedSavedKey
            return
        }
        let storedKey = settings.apiKey(for: provider)
        guard settings.hasLoadedAPIKey(for: provider) else {
            // A canceled/blocked/transient Keychain read stays retryable. Do
            // not turn the empty fallback into loaded state.
            draft = ""
            return
        }
        loadedSavedKey = storedKey
        draft = storedKey
        hasLoadedSavedKey = true
    }
}

struct ProviderSetupSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usageLedger: UsageLedgerStore
    /// When true, renders a compact heading (used inside Settings forms).
    var compact: Bool = false
    /// Onboarding uses the provider's safe default model and keeps technical
    /// model IDs out of the primary flow.
    var showsModelSettings: Bool = true

    @State private var testState: TestState = .idle
    @State private var keyRecoveryNotice: String?
    @StateObject private var keyEditor: ProviderKeyEditorModel

    private let transformer = WritingTransformService()

    enum TestState: Equatable {
        case idle, saved, running, success
        case failure(String)
    }

    init(
        settings: AppSettings,
        usageLedger: UsageLedgerStore,
        compact: Bool = false,
        showsModelSettings: Bool = true
    ) {
        self.settings = settings
        self.usageLedger = usageLedger
        self.compact = compact
        self.showsModelSettings = showsModelSettings
        _keyEditor = StateObject(
            wrappedValue: ProviderKeyEditorModel(settings: settings)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                Text("Connect a provider")
                    .font(.title2).bold()
                Text("Bean uses your own API key. It's stored in the macOS Keychain.")
                    .font(.callout)
                    .foregroundColor(BeanDesign.secondaryText)
            }

            Picker("Provider", selection: $settings.provider) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(testState == .running)
            .accessibilityLabel("AI provider")
            .accessibilityHint("Choose which provider Bean uses for optional AI actions")

            Text("API key").font(.subheadline)
            if keyEditor.isEditing {
                SecureField(
                    "Enter your \(settings.provider.displayName) API key",
                    text: $keyEditor.draft
                )
                    .textFieldStyle(.roundedBorder)
                    .disabled(testState == .running)
                    .accessibilityLabel("\(settings.provider.displayName) API key")
                    .accessibilityHint("Stored securely in your macOS Keychain")
                    .onChange(of: keyEditor.draft) { _ in
                        // Loading a saved key is part of starting a test and can
                        // publish after `running`; do not erase that live state.
                        if testState != .running { testState = .idle }
                    }
                    .onSubmit { saveKey() }
                if keyEditor.canRecoverExistingKey {
                    Button("Use Existing Keychain Key…") { recoverExistingKey() }
                        .disabled(testState == .running)
                        .accessibilityHint("Reads the selected provider's saved key from macOS Keychain only after you choose this button")
                    Text("Upgraded from an earlier Bean release? Load a key that may already be in Keychain. This only loads it for editing; Bean does not test it here. Choose Test Connection or Connect Bean separately.")
                        .font(.caption)
                        .foregroundColor(BeanDesign.secondaryText)
                }
            } else {
                HStack(spacing: 10) {
                    Label("Key saved in macOS Keychain", systemImage: "key.fill")
                        .font(.callout)
                        .foregroundColor(BeanDesign.secondaryText)
                    Spacer()
                    Button("Edit Key…") { beginEditingKey() }
                        .accessibilityHint("Loads the saved key from macOS Keychain for editing")
                }
                Text("Settings reads this saved key only when you choose Edit Key or Test Connection. Bean accesses it only when an AI writing action needs it.")
                    .font(.caption)
                    .foregroundColor(BeanDesign.secondaryText)
            }
            if let keyRecoveryNotice {
                Label(keyRecoveryNotice, systemImage: "key.horizontal")
                    .font(.caption)
                    .foregroundColor(BeanDesign.secondaryText)
            }
            if let keychainError = settings.keychainError {
                Label(keychainError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(BeanDesign.danger)
                    .accessibilityLabel("Keychain error: \(keychainError)")
            }

            if showsModelSettings {
                Text("Model").font(.subheadline)
                HStack {
                    TextField("Model", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                        .disabled(testState == .running)
                        .accessibilityLabel("AI model")
                    Button("Default") { settings.model = settings.provider.defaultModel }
                        .disabled(testState == .running)
                        .accessibilityHint("Restores \(settings.provider.displayName)'s default model")
                }
                Text("Default for \(settings.provider.displayName): \(settings.provider.defaultModel)")
                    .font(.caption)
                    .foregroundColor(BeanDesign.secondaryText)
            }

            HStack(spacing: 10) {
                if showsModelSettings {
                    Button("Save Key") { saveKey() }
                        .disabled(
                            !keyEditor.isEditing
                                || keyEditor.draft.isEmpty
                                || keyEditor.draftMatchesLoadedKey
                                || testState == .running
                        )
                    Button("Test Connection") { runTest() }
                        .disabled(
                            (keyEditor.draft.isEmpty && !keyEditor.hasSavedKey)
                                || testState == .running
                        )
                    if keyEditor.isEditing && keyEditor.hasSavedKey {
                        Button("Cancel") { cancelEditingKey() }
                            .disabled(testState == .running)
                    }
                    if keyEditor.hasSavedKey {
                        Button("Remove Key", role: .destructive) { removeKey() }
                            .disabled(testState == .running)
                    }
                } else {
                    Button("Connect Bean") { runTest() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            (keyEditor.draft.isEmpty && !keyEditor.hasSavedKey)
                                || testState == .running
                        )
                    if keyEditor.isEditing && keyEditor.hasSavedKey {
                        Button("Cancel") { cancelEditingKey() }
                        .disabled(testState == .running)
                    }
                }
            }
            .controlSize(.large)

            // Connection feedback needs the full card width. Keeping it out of
            // the button row prevents long, actionable provider errors from
            // being compressed or hidden behind the controls that retry them.
            testStatusView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: settings.provider) { provider in
            keyEditor.synchronizeProvider(provider)
            keyRecoveryNotice = nil
            testState = .idle
        }
        .onChange(of: settings.model) { _ in
            keyEditor.invalidateConnectionTest()
            testState = .idle
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle: EmptyView()
        case .saved:
            Label("Saved securely", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(BeanDesign.success)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundColor(BeanDesign.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Testing AI connection")
        case .success:
            Label("Connection OK", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(BeanDesign.success)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(BeanDesign.danger)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Connection failed: \(message)")
        }
    }

    private func runTest() {
        keyRecoveryNotice = nil
        let provider = settings.provider
        let model = settings.model
        // Close the tiny gap between a binding update and SwiftUI's on-change
        // delivery so a key can never be tested against a different provider.
        keyEditor.synchronizeProvider(provider)
        let key = keyEditor.keyForExplicitConnectionTest()
        guard !key.isEmpty else {
            // A failed saved-key read already has specific, retryable Keychain
            // copy below the field; do not misreport it as a missing key.
            testState = settings.keychainError == nil
                ? .failure("Enter an API key first.")
                : .idle
            return
        }
        guard keyEditor.saveDraft() else {
            testState = .failure("The API key could not be saved.")
            return
        }
        testState = .running
        let testToken = keyEditor.beginConnectionTest(
            provider: provider,
            model: model
        )
        let timeout = settings.timeoutSeconds
        Task {
            do {
                let usage = try await transformer.testConnection(
                    provider: provider, model: model, apiKey: key, timeout: timeout)
                await MainActor.run {
                    usageLedger.record(usage, source: .manual,
                                       provider: provider.rawValue, model: model)
                    guard keyEditor.acceptConnectionTestCompletion(
                        testToken,
                        currentProvider: settings.provider,
                        currentModel: settings.model
                    ) else { return }
                    settings.markProviderConnectionVerified(provider: provider, model: model)
                    testState = .success
                }
            } catch let error as LLMError {
                await MainActor.run {
                    guard keyEditor.acceptConnectionTestCompletion(
                        testToken,
                        currentProvider: settings.provider,
                        currentModel: settings.model
                    ) else { return }
                    settings.invalidateProviderVerification()
                    testState = .failure(error.errorDescription ?? "Failed")
                }
            } catch {
                await MainActor.run {
                    guard keyEditor.acceptConnectionTestCompletion(
                        testToken,
                        currentProvider: settings.provider,
                        currentModel: settings.model
                    ) else { return }
                    settings.invalidateProviderVerification()
                    testState = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func beginEditingKey() {
        keyEditor.beginEditingStoredKey()
        keyRecoveryNotice = nil
        testState = .idle
    }

    private func recoverExistingKey() {
        if keyEditor.recoverExistingKeyForExplicitAction() {
            keyRecoveryNotice = "Existing key loaded for editing. It has not been tested."
        } else if settings.keychainError != nil {
            // AppSettings surfaces safe, actionable copy and deliberately
            // leaves legacy presence unknown so this button remains retryable.
            keyRecoveryNotice = nil
        } else {
            keyRecoveryNotice = "No existing key was found. Enter a key to continue."
        }
        testState = .idle
    }

    private func saveKey() {
        if keyEditor.saveDraft() {
            keyRecoveryNotice = nil
            testState = .saved
        }
    }

    private func removeKey() {
        if keyEditor.removeStoredKey() {
            keyRecoveryNotice = nil
            testState = .saved
        }
    }

    private func cancelEditingKey() {
        keyEditor.cancelEditing()
        keyRecoveryNotice = nil
        testState = .idle
    }
}

// MARK: - Accessibility permission

/// Keeps Accessibility status reactive without continuously polling macOS.
/// System Settings can take a moment to publish a newly granted permission, so
/// the model performs a short, cancellable check window after the user opens or
/// returns from that pane.
@MainActor
final class AccessibilityPermissionModel: ObservableObject {
    @Published private(set) var granted: Bool

    private let check: () -> Bool
    private let pollIntervalNanoseconds: UInt64
    private let maximumPollCount: Int
    private var pollingTask: Task<Void, Never>?

    init(
        check: @escaping () -> Bool = { PermissionService.isAccessibilityGranted },
        pollIntervalNanoseconds: UInt64 = 500_000_000,
        maximumPollCount: Int = 24
    ) {
        self.check = check
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maximumPollCount = maximumPollCount
        self.granted = check()
    }

    func refresh() {
        granted = check()
        if granted { stopPolling() }
    }

    func beginBriefPolling() {
        stopPolling()
        guard !granted else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<maximumPollCount {
                do {
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                refresh()
                if granted { return }
            }
            pollingTask = nil
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}

struct PermissionsSection: View {
    var compact: Bool = false
    @ObservedObject var permission: AccessibilityPermissionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                Text("Grant Accessibility")
                    .font(.title2).bold()
                Text("Bean needs Accessibility access to copy, paste, and replace text in other apps. It can't read or change anything until you act.")
                    .font(.callout)
                    .foregroundColor(BeanDesign.secondaryText)
            }

            StatusPill(text: permission.granted ? "Allowed" : "Permission required",
                       kind: permission.granted ? .success : .warning)

            HStack {
                Button("Open Accessibility Settings") {
                    PermissionService.requestAccessibility()
                    PermissionService.openAccessibilitySettings()
                    permission.beginBriefPolling()
                }
                .accessibilityHint("Opens the macOS Accessibility permission list")
                Button("Re-check") { permission.refresh() }
                    .accessibilityHint("Checks whether Accessibility permission is now allowed")
            }
            .controlSize(.large)

            if !permission.granted {
                Text("Enable Bean in the list, then return here. This status updates automatically; Re-check is available if macOS takes longer.")
                    .font(.caption)
                    .foregroundColor(BeanDesign.secondaryText)
            }
        }
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
            if !permission.granted { permission.beginBriefPolling() }
        }
        .onDisappear { permission.stopPolling() }
        .controlSize(.large)
    }
}
