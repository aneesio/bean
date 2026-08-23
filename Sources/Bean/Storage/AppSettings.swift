import Foundation
import Combine
import Security

// The set of LLM providers Bean supports. Adding a new provider is a matter of
// adding a case here and a corresponding LLMProvider implementation.
enum ProviderKind: String, CaseIterable, Identifiable {
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        }
    }

    /// A sensible default model for each provider.
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5-nano"
        case .anthropic: return "claude-haiku-4-5"
        }
    }

    /// Replaces provider model IDs that have been retired and now fail every
    /// request. Custom/active model IDs are left untouched.
    func migratedModel(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return defaultModel }
        if ProviderKind.allCases.contains(where: { $0 != self && $0.ownsModelID(stored) }) {
            return defaultModel
        }
        if self == .anthropic {
            let retired = ["claude-3-5-haiku-latest", "claude-3-5-haiku-20241022", "claude-3-haiku-20240307"]
            if retired.contains(stored) { return defaultModel }
        }
        return stored
    }

    fileprivate func ownsModelID(_ model: String) -> Bool {
        let lower = model.lowercased()
        switch self {
        case .openai:
            return lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt-")
                || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4")
                || lower.hasPrefix("ft:gpt-")
        case .anthropic:
            return lower.hasPrefix("claude-")
        }
    }

    /// Keychain account used to store this provider's API key.
    var keychainAccount: String { "apikey.\(rawValue)" }
}

/// Content-free knowledge about a provider credential. `unknown` is important
/// for upgrades from releases that wrote Keychain data before Bean persisted a
/// separate presence marker; resolving it must remain an explicit user action.
enum APIKeyPresenceState: Equatable {
    case present
    case absent
    case unknown
}

// User-facing configuration. Non-secret values live in UserDefaults; API keys
// live in the Keychain (see KeychainService). Marked @MainActor because it
// drives SwiftUI views and is read on the main thread during the fix flow.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let provider = "provider"
        static let model = "model"
        static let timeout = "timeoutSeconds"
        static let fixFocusedField = "fixFocusedFieldWhenNoSelection"
        static let diagnostics = "diagnosticsEnabled"
        static let onboardingComplete = "onboardingComplete"
        static let onboardingStep = "onboardingStepRawValue"
        static let providerVerifiedAt = "providerVerifiedAt"
        static let providerVerifiedKind = "providerVerifiedKind"
        static let providerVerifiedModel = "providerVerifiedModel"
        static func apiKeyPresent(_ provider: ProviderKind) -> String {
            "apiKeyPresent.\(provider.rawValue)"
        }
        static let apiKeyPresenceMetadataMigrationVersion = "apiKeyPresenceMetadataMigrationVersion"
        static let shortcut = "globalShortcut"
        static let primaryShortcutAction = "primaryShortcutAction"
        static let beanMenuShortcut = "beanMenuShortcut"
        // Phase 5 — Passive Suggestions
        static let passiveEnabled = "passiveEnabled"
        static let passiveDelay = "passiveDelaySeconds"
        static let passiveMin = "passiveMinLength"
        static let passiveMax = "passiveMaxLength"
        static let passiveChat = "passiveInChat"
        static let passiveMailBrowser = "passiveInMailBrowser"
        static let passiveCode = "passiveInCode"
        static let passiveSearch = "passiveInSearch"
        static let passiveOnlyWhenLikely = "passiveOnlyWhenLikely"
        static let passiveRequirePreview = "passiveRequirePreview"
        static let passivePausedUntil = "passivePausedUntil"
        // Phase 6 — Inline Highlights
        static let inlineEnabled = "inlineHighlightsEnabled"
        static let inlineMaxIssues = "inlineMaxIssues"
        static let inlineLocalOnly = "inlineLocalOnly"
        static let inlineIncludeLLM = "inlineIncludeLLM"
        static let inlineShowExplanation = "inlineShowExplanation"
        static let inlineFallbackPassive = "inlineFallbackPassive"
        // Phase 6.5 — Bean Bubble
        static let bubbleEnabled = "bubbleEnabled"
        static let bubbleOnFocus = "bubbleOnFocus"
        static let bubbleOnSelection = "bubbleOnSelection"
        static let bubbleInChat = "bubbleInChat"
        static let bubbleInMailBrowser = "bubbleInMailBrowser"
        static let bubbleInCode = "bubbleInCode"
        static let bubbleInSearch = "bubbleInSearch"
        static let bubbleDelay = "bubbleDelaySeconds"
        static let bubbleOpenOnHover = "bubbleOpenOnHover"
        static let webInlineEnabled = "webInlineEnabled"
        // One-time migrations for settings whose old defaults could spend API
        // tokens after a typing pause. Explicit actions are never affected.
        static let automaticAICostSafetyVersion = "automaticAICostSafetyVersion"
        // Phase 3 removes Passive Suggestions as a public product. Disable any
        // previously stored hidden background path once on upgrade so an old
        // preference cannot keep spending tokens after its controls disappear.
        static let liveAssistanceSimplificationVersion = "liveAssistanceSimplificationVersion"
        static let dailyAutomaticCallLimit = "dailyAutomaticCallLimit"
        static let monthlyTokenWarningThreshold = "monthlyTokenWarningThreshold"
    }

    private let defaults: UserDefaults
    private let readKeychain: (String) -> KeychainReadResult
    private let writeKeychain: (String, String) -> OSStatus
    /// Keychain access can show a macOS authorization prompt, especially after
    /// an ad-hoc development build is replaced. Cache each provider's value
    /// after the first read so ordinary SwiftUI refreshes never ask repeatedly.
    private var apiKeyCache: [ProviderKind: String] = [:]
    private var loadedAPIKeyProviders: Set<ProviderKind> = []

    @Published var provider: ProviderKind {
        willSet {
            // Revoke the old proof before publishing/persisting a different
            // provider. The native host is a separate process and may observe
            // each defaults write independently; invalidating first keeps every
            // intermediate state fail-closed.
            if newValue != provider {
                invalidateProviderVerification()
                keychainError = nil
            }
        }
        didSet {
            defaults.set(provider.rawValue, forKey: Keys.provider)
            // A model ID from the previous provider cannot work after a switch.
            // Preserve unknown custom IDs, but migrate recognized provider IDs.
            if model.isEmpty || oldValue.ownsModelID(model) {
                model = provider.defaultModel
            }
        }
    }

    @Published var model: String {
        willSet {
            // As with provider changes, clear verification before the new model
            // becomes visible to the native-host process.
            if newValue != model { invalidateProviderVerification() }
        }
        didSet {
            defaults.set(model, forKey: Keys.model)
        }
    }

    @Published var timeoutSeconds: Double {
        didSet { defaults.set(timeoutSeconds, forKey: Keys.timeout) }
    }

    /// When enabled and there is no selection, Bean fixes the focused field's
    /// full contents. Default on.
    @Published var fixFocusedFieldWhenNoSelection: Bool {
        didSet { defaults.set(fixFocusedFieldWhenNoSelection, forKey: Keys.fixFocusedField) }
    }

    /// Development-safe diagnostics: emits operational metrics only (lengths,
    /// result codes, provider/app names) — never user text. Default off.
    @Published var diagnosticsEnabled: Bool {
        didSet {
            defaults.set(diagnosticsEnabled, forKey: Keys.diagnostics)
            Log.diagnosticsEnabled = diagnosticsEnabled
        }
    }

    /// Whether first-run onboarding has been explicitly completed. Stored in
    /// UserDefaults, never Keychain.
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
    }

    /// The last page reached in the three-step first-run guide. Keeping the
    /// persisted value as an integer avoids coupling settings storage to a UI
    /// enum while still making an interrupted guide resumable.
    @Published var onboardingStepRawValue: Int {
        didSet {
            let clamped = min(max(onboardingStepRawValue, 0), 2)
            if onboardingStepRawValue != clamped {
                onboardingStepRawValue = clamped
            }
            defaults.set(clamped, forKey: Keys.onboardingStep)
        }
    }

    @Published private(set) var providerConnectionVerifiedAt: Date?

    /// A content-free persistence error shown beside the API-key field.
    @Published private(set) var keychainError: String?

    /// The global shortcut that triggers a fix. Persisted as JSON in
    /// UserDefaults. Defaults to ⌘⇧G.
    @Published var shortcut: GlobalShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: Keys.shortcut)
            }
        }
    }

    /// What the direct writing shortcut runs. Existing users migrate to the
    /// historical local Quick Fix behavior; unknown values also fail local.
    @Published var primaryShortcutAction: PrimaryShortcutAction {
        didSet { defaults.set(primaryShortcutAction.rawValue, forKey: Keys.primaryShortcutAction) }
    }

    /// The global shortcut that opens the Bean action menu. Defaults to ⌃⌥B.
    @Published var beanMenuShortcut: GlobalShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(beanMenuShortcut) {
                defaults.set(data, forKey: Keys.beanMenuShortcut)
            }
        }
    }

    // MARK: - Passive Suggestions (Phase 5)

    @Published var passiveEnabled: Bool { didSet { defaults.set(passiveEnabled, forKey: Keys.passiveEnabled); onPassiveChanged?() } }
    @Published var passiveDelay: Double { didSet { defaults.set(passiveDelay, forKey: Keys.passiveDelay) } }
    @Published var passiveMinLength: Int { didSet { defaults.set(passiveMinLength, forKey: Keys.passiveMin) } }
    @Published var passiveMaxLength: Int { didSet { defaults.set(passiveMaxLength, forKey: Keys.passiveMax) } }
    @Published var passiveInChat: Bool { didSet { defaults.set(passiveInChat, forKey: Keys.passiveChat) } }
    @Published var passiveInMailBrowser: Bool { didSet { defaults.set(passiveInMailBrowser, forKey: Keys.passiveMailBrowser) } }
    @Published var passiveInCode: Bool { didSet { defaults.set(passiveInCode, forKey: Keys.passiveCode) } }
    @Published var passiveInSearch: Bool { didSet { defaults.set(passiveInSearch, forKey: Keys.passiveSearch) } }
    @Published var passiveOnlyWhenLikely: Bool { didSet { defaults.set(passiveOnlyWhenLikely, forKey: Keys.passiveOnlyWhenLikely) } }
    @Published var passiveRequirePreview: Bool { didSet { defaults.set(passiveRequirePreview, forKey: Keys.passiveRequirePreview) } }
    @Published var passivePausedUntil: Date? {
        didSet {
            defaults.set(passivePausedUntil?.timeIntervalSince1970 ?? 0, forKey: Keys.passivePausedUntil)
            onPassiveChanged?()
        }
    }

    /// Invoked when a passive setting that affects monitoring changes (so the
    /// service can start/stop). Set by AppDelegate.
    var onPassiveChanged: (() -> Void)?

    /// True if passive monitoring should currently run.
    var passiveActive: Bool {
        guard passiveEnabled else { return false }
        if let until = passivePausedUntil, until > Date() { return false }
        return true
    }

    func pausePassive(forHours hours: Double) { passivePausedUntil = Date().addingTimeInterval(hours * 3600) }
    func resumePassive() { passivePausedUntil = nil }

    // MARK: - Inline Highlights (Phase 6)

    @Published var inlineHighlightsEnabled: Bool { didSet { defaults.set(inlineHighlightsEnabled, forKey: Keys.inlineEnabled); onInlineChanged?() } }
    @Published var inlineMaxIssues: Int { didSet { defaults.set(inlineMaxIssues, forKey: Keys.inlineMaxIssues) } }
    @Published var inlineLocalOnly: Bool { didSet { defaults.set(inlineLocalOnly, forKey: Keys.inlineLocalOnly) } }
    @Published var inlineIncludeLLM: Bool { didSet { defaults.set(inlineIncludeLLM, forKey: Keys.inlineIncludeLLM) } }
    @Published var inlineShowExplanation: Bool { didSet { defaults.set(inlineShowExplanation, forKey: Keys.inlineShowExplanation) } }
    @Published var inlineFallbackPassive: Bool { didSet { defaults.set(inlineFallbackPassive, forKey: Keys.inlineFallbackPassive) } }

    /// Invoked when an inline-highlights setting affecting monitoring changes.
    var onInlineChanged: (() -> Void)?

    // MARK: - Bean Bubble (Phase 6.5)

    @Published var bubbleEnabled: Bool { didSet { defaults.set(bubbleEnabled, forKey: Keys.bubbleEnabled); onBubbleChanged?() } }
    @Published var bubbleOnFocus: Bool { didSet { defaults.set(bubbleOnFocus, forKey: Keys.bubbleOnFocus) } }
    @Published var bubbleOnSelection: Bool { didSet { defaults.set(bubbleOnSelection, forKey: Keys.bubbleOnSelection) } }
    @Published var bubbleInChat: Bool { didSet { defaults.set(bubbleInChat, forKey: Keys.bubbleInChat) } }
    @Published var bubbleInMailBrowser: Bool { didSet { defaults.set(bubbleInMailBrowser, forKey: Keys.bubbleInMailBrowser) } }
    @Published var bubbleInCode: Bool { didSet { defaults.set(bubbleInCode, forKey: Keys.bubbleInCode) } }
    @Published var bubbleInSearch: Bool { didSet { defaults.set(bubbleInSearch, forKey: Keys.bubbleInSearch) } }
    @Published var bubbleDelay: Double { didSet { defaults.set(bubbleDelay, forKey: Keys.bubbleDelay) } }
    @Published var bubbleOpenOnHover: Bool { didSet { defaults.set(bubbleOpenOnHover, forKey: Keys.bubbleOpenOnHover) } }

    /// Invoked when a Bean Bubble setting affecting monitoring changes.
    var onBubbleChanged: (() -> Void)?

    /// Whether the user has opted into web inline support (the browser
    /// extension). Stored only; the Mac app doesn't act on web fields itself.
    @Published var webInlineEnabled: Bool { didSet { defaults.set(webInlineEnabled, forKey: Keys.webInlineEnabled) } }

    /// Local guardrails for provider-backed automatic features. Manual actions
    /// and offline checks remain available when either threshold is reached.
    @Published var dailyAutomaticCallLimit: Int {
        didSet {
            let bounded = AutomaticCallBudgetPolicy.requestedDailyLimit(
                dailyAutomaticCallLimit
            )
            if dailyAutomaticCallLimit != bounded {
                dailyAutomaticCallLimit = bounded
            }
            defaults.set(bounded, forKey: Keys.dailyAutomaticCallLimit)
        }
    }
    @Published var monthlyTokenWarningThreshold: Int {
        didSet { defaults.set(monthlyTokenWarningThreshold, forKey: Keys.monthlyTokenWarningThreshold) }
    }

    // Transient (not persisted) status surfaced by the typing dispatcher.
    @Published var monitorActive: Bool = false
    @Published var lastPauseHandler: String = "none"
    @Published var lastSupportReason: String = ""

    init(
        defaults: UserDefaults = .standard,
        readKeychain: ((String) -> String?)? = nil,
        readKeychainResult: ((String) -> KeychainReadResult)? = nil,
        writeKeychain: @escaping (String, String) -> OSStatus = { value, account in
            KeychainService.set(value, account: account)
        }
    ) {
        self.defaults = defaults
        if let readKeychainResult {
            self.readKeychain = readKeychainResult
        } else if let readKeychain {
            // Keep the existing test/dependency-injection surface compatible:
            // an optional-only reader can express value vs confirmed absence.
            self.readKeychain = { account in
                readKeychain(account).map(KeychainReadResult.value) ?? .notFound
            }
        } else {
            self.readKeychain = { KeychainService.get(account: $0) }
        }
        self.writeKeychain = writeKeychain
        // Capture upgrade evidence before any current migration writes its own
        // marker. v1.4 stored this cost-safety version even when onboarding was
        // interrupted after saving a Keychain credential.
        let isPriorInstall = defaults.bool(forKey: Keys.onboardingComplete)
            || defaults.object(forKey: Keys.automaticAICostSafetyVersion) != nil
        // Distinguish a genuinely fresh, not-yet-onboarded install from an
        // upgrade whose Keychain item predates content-free presence metadata.
        // This migration is metadata-only and never probes Keychain.
        if defaults.integer(forKey: Keys.apiKeyPresenceMetadataMigrationVersion) < 1 {
            for provider in ProviderKind.allCases {
                let presenceKey = Keys.apiKeyPresent(provider)
                if isPriorInstall {
                    // Buggy intermediate builds could persist false after a
                    // canceled read. Preserve true, but make false/missing
                    // recoverable exactly once for an identified prior install.
                    if defaults.object(forKey: presenceKey) != nil,
                       !defaults.bool(forKey: presenceKey) {
                        defaults.removeObject(forKey: presenceKey)
                    }
                } else {
                    if defaults.object(forKey: presenceKey) == nil {
                        defaults.set(false, forKey: presenceKey)
                    }
                }
            }
            defaults.set(1, forKey: Keys.apiKeyPresenceMetadataMigrationVersion)
        }
        // Versions before this migration allowed previously stored automatic-AI
        // settings to survive the new cost-safe defaults. Reset those paid
        // background paths once on upgrade; users can deliberately re-enable
        // individual features afterward. Local inline detection remains on.
        if defaults.integer(forKey: Keys.automaticAICostSafetyVersion) < 1 {
            defaults.set(false, forKey: Keys.passiveEnabled)
            defaults.set(true, forKey: Keys.inlineLocalOnly)
            defaults.set(false, forKey: Keys.inlineIncludeLLM)
            defaults.set(false, forKey: Keys.inlineFallbackPassive)
            defaults.set(false, forKey: Keys.webInlineEnabled)
            defaults.set(1, forKey: Keys.automaticAICostSafetyVersion)
        }
        if defaults.integer(forKey: Keys.liveAssistanceSimplificationVersion) < 1 {
            defaults.set(false, forKey: Keys.passiveEnabled)
            defaults.set(false, forKey: Keys.inlineFallbackPassive)
            defaults.set(1, forKey: Keys.liveAssistanceSimplificationVersion)
        }

        let providerRaw = defaults.string(forKey: Keys.provider) ?? ProviderKind.openai.rawValue
        let resolvedProvider = ProviderKind(rawValue: providerRaw) ?? .openai
        self.provider = resolvedProvider
        self.model = resolvedProvider.migratedModel(defaults.string(forKey: Keys.model))

        let storedTimeout = defaults.double(forKey: Keys.timeout)
        self.timeoutSeconds = storedTimeout > 0 ? storedTimeout : 30

        // Default to enabled when no value has been stored yet.
        if defaults.object(forKey: Keys.fixFocusedField) == nil {
            self.fixFocusedFieldWhenNoSelection = true
        } else {
            self.fixFocusedFieldWhenNoSelection = defaults.bool(forKey: Keys.fixFocusedField)
        }

        self.diagnosticsEnabled = defaults.bool(forKey: Keys.diagnostics) // default false
        self.onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete) // default false
        self.onboardingStepRawValue = min(max(defaults.integer(forKey: Keys.onboardingStep), 0), 2)
        let verifiedTimestamp = defaults.double(forKey: Keys.providerVerifiedAt)
        self.providerConnectionVerifiedAt = verifiedTimestamp > 0
            ? Date(timeIntervalSince1970: verifiedTimestamp) : nil
        self.keychainError = nil

        // Passive Suggestions — off by default; sensible defaults otherwise.
        self.passiveEnabled = defaults.bool(forKey: Keys.passiveEnabled)
        let d = defaults.double(forKey: Keys.passiveDelay); self.passiveDelay = d > 0 ? d : 1.2
        let mn = defaults.integer(forKey: Keys.passiveMin); self.passiveMinLength = mn > 0 ? mn : 20
        let mx = defaults.integer(forKey: Keys.passiveMax); self.passiveMaxLength = mx > 0 ? mx : 2000
        self.passiveInChat = defaults.object(forKey: Keys.passiveChat) == nil ? true : defaults.bool(forKey: Keys.passiveChat)
        self.passiveInMailBrowser = defaults.object(forKey: Keys.passiveMailBrowser) == nil ? true : defaults.bool(forKey: Keys.passiveMailBrowser)
        self.passiveInCode = defaults.bool(forKey: Keys.passiveCode) // default false
        self.passiveInSearch = defaults.bool(forKey: Keys.passiveSearch) // default false
        self.passiveOnlyWhenLikely = defaults.object(forKey: Keys.passiveOnlyWhenLikely) == nil ? true : defaults.bool(forKey: Keys.passiveOnlyWhenLikely)
        self.passiveRequirePreview = defaults.object(forKey: Keys.passiveRequirePreview) == nil ? true : defaults.bool(forKey: Keys.passiveRequirePreview)
        let pausedTS = defaults.double(forKey: Keys.passivePausedUntil)
        self.passivePausedUntil = pausedTS > 0 ? Date(timeIntervalSince1970: pausedTS) : nil

        // Inline Highlights — off by default.
        self.inlineHighlightsEnabled = defaults.bool(forKey: Keys.inlineEnabled)
        let im = defaults.integer(forKey: Keys.inlineMaxIssues); self.inlineMaxIssues = im > 0 ? im : 5
        self.inlineLocalOnly = defaults.object(forKey: Keys.inlineLocalOnly) == nil ? true : defaults.bool(forKey: Keys.inlineLocalOnly)
        self.inlineIncludeLLM = defaults.bool(forKey: Keys.inlineIncludeLLM) // default false
        self.inlineShowExplanation = defaults.object(forKey: Keys.inlineShowExplanation) == nil ? true : defaults.bool(forKey: Keys.inlineShowExplanation)
        self.inlineFallbackPassive = defaults.bool(forKey: Keys.inlineFallbackPassive) // default false

        // Bean Bubble — off by default; sensible defaults otherwise.
        self.bubbleEnabled = defaults.bool(forKey: Keys.bubbleEnabled)
        self.bubbleOnFocus = defaults.object(forKey: Keys.bubbleOnFocus) == nil ? true : defaults.bool(forKey: Keys.bubbleOnFocus)
        self.bubbleOnSelection = defaults.object(forKey: Keys.bubbleOnSelection) == nil ? true : defaults.bool(forKey: Keys.bubbleOnSelection)
        self.bubbleInChat = defaults.object(forKey: Keys.bubbleInChat) == nil ? true : defaults.bool(forKey: Keys.bubbleInChat)
        self.bubbleInMailBrowser = defaults.object(forKey: Keys.bubbleInMailBrowser) == nil ? true : defaults.bool(forKey: Keys.bubbleInMailBrowser)
        self.bubbleInCode = defaults.bool(forKey: Keys.bubbleInCode) // default false
        self.bubbleInSearch = defaults.bool(forKey: Keys.bubbleInSearch) // default false
        let bd = defaults.double(forKey: Keys.bubbleDelay); self.bubbleDelay = bd > 0 ? bd : 0.6
        self.bubbleOpenOnHover = defaults.bool(forKey: Keys.bubbleOpenOnHover) // default false
        self.webInlineEnabled = defaults.bool(forKey: Keys.webInlineEnabled) // default false
        let dailyLimit = defaults.integer(forKey: Keys.dailyAutomaticCallLimit)
        self.dailyAutomaticCallLimit = AutomaticCallBudgetPolicy.persistedDailyLimit(dailyLimit)
        let monthlyWarning = defaults.integer(forKey: Keys.monthlyTokenWarningThreshold)
        self.monthlyTokenWarningThreshold = monthlyWarning > 0 ? monthlyWarning : 250_000

        if let data = defaults.data(forKey: Keys.shortcut),
           let stored = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            self.shortcut = stored
        } else {
            self.shortcut = .default
        }

        self.primaryShortcutAction = PrimaryShortcutAction(
            rawValue: defaults.string(forKey: Keys.primaryShortcutAction) ?? ""
        ) ?? .quickFix

        if let data = defaults.data(forKey: Keys.beanMenuShortcut),
           let stored = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            self.beanMenuShortcut = stored
        } else {
            self.beanMenuShortcut = .beanMenuDefault
        }

        Log.diagnosticsEnabled = self.diagnosticsEnabled
    }

    /// True when Bean can work in other apps. AI is an optional enhancement;
    /// the deterministic Local Quick Check works without a provider key.
    var isSetupComplete: Bool {
        PermissionService.isAccessibilityGranted
    }

    // MARK: - API key (Keychain-backed)

    /// The API key for the currently selected provider.
    var apiKey: String {
        get { apiKey(for: provider) }
        set { persistAPIKey(newValue, for: provider) }
    }

    func apiKey(for provider: ProviderKind) -> String {
        if !loadedAPIKeyProviders.contains(provider) {
            switch readKeychain(provider.keychainAccount) {
            case .value(let value) where !value.isEmpty:
                apiKeyCache[provider] = value
                loadedAPIKeyProviders.insert(provider)
                defaults.set(true, forKey: Keys.apiKeyPresent(provider))
                keychainError = nil
            case .value:
                // KeychainService never emits an empty value, but keep an
                // injected or malformed result from becoming false absence.
                keychainError = KeychainService.readErrorMessage(for: errSecDecode)
                Log.event("keychain: read failed status=\(errSecDecode)")
            case .notFound:
                apiKeyCache[provider] = ""
                loadedAPIKeyProviders.insert(provider)
                // Only a confirmed errSecItemNotFound becomes known absence.
                defaults.set(false, forKey: Keys.apiKeyPresent(provider))
                keychainError = nil
            case .failure(let status):
                // Do not cache or persist a false absence: cancellation, a
                // locked Keychain, and transient errors must remain retryable.
                keychainError = KeychainService.readErrorMessage(for: status)
                Log.event("keychain: read failed status=\(status)")
            }
        }
        return apiKeyCache[provider] ?? ""
    }

    /// Process-local load state used by explicit credential UI. This does not
    /// query Keychain and lets callers distinguish a loaded empty result from
    /// a read that was canceled or otherwise failed.
    func hasLoadedAPIKey(for provider: ProviderKind) -> Bool {
        loadedAPIKeyProviders.contains(provider)
    }

    /// Clears only transient, content-free UI state. Provider navigation uses
    /// this so an error for one credential is never shown under another.
    func clearKeychainError() {
        keychainError = nil
    }

    func setAPIKey(_ value: String, for provider: ProviderKind) {
        persistAPIKey(value, for: provider)
    }

    private func persistAPIKey(_ value: String, for provider: ProviderKind) {
        let previousValue = apiKey(for: provider)
        // A failed read intentionally leaves this provider unloaded. Do not
        // treat its empty fallback as equality or persist false absence.
        if loadedAPIKeyProviders.contains(provider), previousValue == value {
            defaults.set(!value.isEmpty, forKey: Keys.apiKeyPresent(provider))
            keychainError = nil
            return
        }
        // Keychain and UserDefaults are separate cross-process stores. Revoke
        // the old verification marker before changing (or clearing) the secret,
        // so a native-host request can never validate the old marker and then
        // read a newly written, unverified key. A failed write intentionally
        // leaves setup unverified until the user retries verification.
        invalidateProviderVerification()
        let status = writeKeychain(value, provider.keychainAccount)
        if status == errSecSuccess {
            apiKeyCache[provider] = value
            loadedAPIKeyProviders.insert(provider)
            defaults.set(!value.isEmpty, forKey: Keys.apiKeyPresent(provider))
            keychainError = nil
        } else {
            keychainError = "Couldn't save the API key: \(KeychainService.errorMessage(for: status))"
            Log.event("keychain: write failed status=\(status)")
        }
    }

    /// Content-free key-presence state for status UI. This intentionally never
    /// queries Keychain: merely launching Bean, opening General, or copying
    /// diagnostics must not trigger a password prompt. `apiKey(for:)` remains
    /// the explicit secret-loading API.
    var hasAPIKey: Bool { hasAPIKey(for: provider) }

    func hasAPIKey(for provider: ProviderKind) -> Bool {
        apiKeyPresenceState(for: provider) == .present
    }

    /// Returns only process-local or UserDefaults metadata. It never queries
    /// Keychain, so Settings and onboarding can distinguish a known-empty key
    /// from a legacy credential whose presence has not yet been resolved.
    func apiKeyPresenceState(for provider: ProviderKind) -> APIKeyPresenceState {
        if loadedAPIKeyProviders.contains(provider) {
            return (apiKeyCache[provider] ?? "").isEmpty ? .absent : .present
        }
        // Some earlier builds could persist a false presence marker after a
        // canceled read. A matching successful verification is stronger
        // evidence of a saved key. A deliberate removal invalidates this
        // verification before persisting known absence.
        if providerConnectionVerifiedAt != nil,
           defaults.string(forKey: Keys.providerVerifiedKind) == provider.rawValue {
            return .present
        }
        let presenceKey = Keys.apiKeyPresent(provider)
        if defaults.object(forKey: presenceKey) != nil {
            return defaults.bool(forKey: presenceKey) ? .present : .absent
        }
        return .unknown
    }

    var isProviderConnectionVerified: Bool {
        isProviderConnectionVerified(provider: provider, model: model)
    }

    /// Checks one captured provider/model pair against the current selection and
    /// verification marker without reading Keychain. Automatic services call
    /// this immediately before their synchronous reservation/provider boundary.
    func isProviderConnectionVerified(provider: ProviderKind, model: String) -> Bool {
        guard provider == self.provider, model == self.model else { return false }
        guard providerConnectionVerifiedAt != nil else { return false }
        return hasAPIKey(for: provider)
            && defaults.string(forKey: Keys.providerVerifiedKind) == provider.rawValue
            && defaults.string(forKey: Keys.providerVerifiedModel) == model
    }

    func markProviderConnectionVerified(provider: ProviderKind, model: String) {
        // A successful setup flow has already loaded or saved this key. Never
        // perform a surprise Keychain read just to update status metadata.
        guard provider == self.provider,
              model == self.model,
              loadedAPIKeyProviders.contains(provider),
              !(apiKeyCache[provider] ?? "").isEmpty else { return }
        let now = Date()
        providerConnectionVerifiedAt = now
        defaults.set(true, forKey: Keys.apiKeyPresent(provider))
        defaults.set(now.timeIntervalSince1970, forKey: Keys.providerVerifiedAt)
        defaults.set(provider.rawValue, forKey: Keys.providerVerifiedKind)
        defaults.set(model, forKey: Keys.providerVerifiedModel)
    }

    func invalidateProviderVerification() {
        providerConnectionVerifiedAt = nil
        defaults.removeObject(forKey: Keys.providerVerifiedAt)
        defaults.removeObject(forKey: Keys.providerVerifiedKind)
        defaults.removeObject(forKey: Keys.providerVerifiedModel)
    }

    /// Full Reset deletes Keychain entries directly so it never has to read a
    /// secret merely to remove it. Forget any process-local cached values after
    /// that attempt and fail closed until a future setup explicitly saves and
    /// verifies a new credential.
    func forgetProviderCredentialsAfterResetAttempt() {
        invalidateProviderVerification()
        apiKeyCache.removeAll()
        loadedAPIKeyProviders = Set(ProviderKind.allCases)
        for provider in ProviderKind.allCases {
            defaults.set(false, forKey: Keys.apiKeyPresent(provider))
        }
    }

    /// True when merely pausing after typing can spend provider tokens. The Bean
    /// Bubble and explicit shortcuts are intentionally not included.
    var automaticAIChecksEnabled: Bool {
        passiveEnabled
            || (inlineHighlightsEnabled && ((!inlineLocalOnly && inlineIncludeLLM) || inlineFallbackPassive))
            || webInlineEnabled
    }

    /// One-click cost guard. Explicit shortcuts/actions keep using the provider;
    /// native inline checks remain available through the offline local detector.
    func disableAutomaticAIChecks() {
        passiveEnabled = false
        inlineLocalOnly = true
        inlineIncludeLLM = false
        inlineFallbackPassive = false
        webInlineEnabled = false
    }

    var capabilityPreferences: CapabilityPreferences {
        CapabilityPreferences(
            accessibilityGranted: PermissionService.isAccessibilityGranted,
            focusedFieldFallbackEnabled: fixFocusedFieldWhenNoSelection,
            bubbleEnabled: bubbleEnabled,
            bubbleInChat: bubbleInChat,
            bubbleInMailBrowser: bubbleInMailBrowser,
            bubbleInCode: bubbleInCode,
            bubbleInSearch: bubbleInSearch,
            inlineEnabled: inlineHighlightsEnabled,
            webInlineEnabled: webInlineEnabled
        )
    }
}
