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
        case .openai: return "gpt-4.1-nano"
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
        static let providerVerifiedAt = "providerVerifiedAt"
        static let providerVerifiedKind = "providerVerifiedKind"
        static let providerVerifiedModel = "providerVerifiedModel"
        static let shortcut = "globalShortcut"
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
    }

    private let defaults = UserDefaults.standard

    @Published var provider: ProviderKind {
        didSet {
            defaults.set(provider.rawValue, forKey: Keys.provider)
            // A model ID from the previous provider cannot work after a switch.
            // Preserve unknown custom IDs, but migrate recognized provider IDs.
            if model.isEmpty || oldValue.ownsModelID(model) {
                model = provider.defaultModel
            }
            invalidateProviderVerification()
        }
    }

    @Published var model: String {
        didSet {
            defaults.set(model, forKey: Keys.model)
            if model != oldValue { invalidateProviderVerification() }
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

    /// Whether first-run onboarding has been completed (or skipped). Stored in
    /// UserDefaults, never Keychain.
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
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

    // Transient (not persisted) status surfaced by the typing dispatcher.
    @Published var monitorActive: Bool = false
    @Published var lastPauseHandler: String = "none"
    @Published var lastSupportReason: String = ""

    init() {
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

        if let data = defaults.data(forKey: Keys.shortcut),
           let stored = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            self.shortcut = stored
        } else {
            self.shortcut = .default
        }

        if let data = defaults.data(forKey: Keys.beanMenuShortcut),
           let stored = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            self.beanMenuShortcut = stored
        } else {
            self.beanMenuShortcut = .beanMenuDefault
        }

        Log.diagnosticsEnabled = self.diagnosticsEnabled
    }

    /// True when the basics needed to actually fix text are configured.
    var isSetupComplete: Bool {
        hasAPIKey && PermissionService.isAccessibilityGranted
    }

    // MARK: - API key (Keychain-backed)

    /// The API key for the currently selected provider.
    var apiKey: String {
        get { KeychainService.get(account: provider.keychainAccount) ?? "" }
        set { persistAPIKey(newValue, for: provider) }
    }

    func apiKey(for provider: ProviderKind) -> String {
        KeychainService.get(account: provider.keychainAccount) ?? ""
    }

    func setAPIKey(_ value: String, for provider: ProviderKind) {
        persistAPIKey(value, for: provider)
    }

    private func persistAPIKey(_ value: String, for provider: ProviderKind) {
        let previousValue = KeychainService.get(account: provider.keychainAccount) ?? ""
        let status = KeychainService.set(value, account: provider.keychainAccount)
        if status == errSecSuccess {
            keychainError = nil
            if previousValue != value { invalidateProviderVerification() }
        } else {
            keychainError = "Couldn't save the API key: \(KeychainService.errorMessage(for: status))"
            Log.event("keychain: write failed status=\(status)")
        }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    var isProviderConnectionVerified: Bool {
        guard hasAPIKey, providerConnectionVerifiedAt != nil else { return false }
        return defaults.string(forKey: Keys.providerVerifiedKind) == provider.rawValue
            && defaults.string(forKey: Keys.providerVerifiedModel) == model
    }

    func markProviderConnectionVerified(provider: ProviderKind, model: String) {
        guard provider == self.provider, model == self.model, hasAPIKey else { return }
        let now = Date()
        providerConnectionVerifiedAt = now
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
}
