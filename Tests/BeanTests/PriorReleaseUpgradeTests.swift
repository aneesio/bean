import XCTest
import Carbon.HIToolbox
import Security
@testable import Bean

/// Exercises UPG-01 as one realistic prior-release profile instead of as a
/// collection of independent defaults tests. All state is isolated from the
/// signed app's preferences, Application Support directory, and Keychain.
@MainActor
final class PriorReleaseUpgradeTests: XCTestCase {
    private struct LegacyUserContent: Encodable {
        var version = 1
        var profiles: [StyleProfile]
        var cards: [WritingContext]
        var dictionary: [DictionaryTerm]
        var appRules: [AppRule]
        var defaultProfileID: UUID?
    }

    // Exact stored Codable shapes from v1.4.0. These deliberately do not use
    // current model types, so the regression fails if a future encoder drops a
    // field that an actual preserved rollback build still requires.
    private struct V140StyleProfile: Decodable {
        var id: UUID
        var name: String
        var detail: String
        var formality: Int
        var warmth: Int
        var conciseness: Int
        var directness: Int
        var preferredInstructions: String
        var bannedPhrases: [String]
        var exampleSnippets: [String]
        var isBuiltIn: Bool
        var createdAt: Date
        var updatedAt: Date
    }

    private struct V140ContextCard: Decodable {
        var id: UUID
        var title: String
        var content: String
        var tags: [String]
        var isEnabledByDefault: Bool
        var createdAt: Date
        var updatedAt: Date
    }

    private struct V140DictionaryTerm: Decodable {
        var id: UUID
        var term: String
        var note: String?
        var caseSensitive: Bool
        var createdAt: Date
        var updatedAt: Date
    }

    private struct V140AppRule: Decodable {
        var id: UUID
        var category: AppCategory
        var defaultStyleProfileID: UUID?
        var allowFocusedFieldFix: Bool
        var notes: String
    }

    private struct V140Persisted: Decodable {
        var version: Int
        var profiles: [V140StyleProfile]
        var cards: [V140ContextCard]
        var dictionary: [V140DictionaryTerm]
        var appRules: [V140AppRule]
        var defaultProfileID: UUID?
    }

    func testCurrentUserContentEnvelopeRemainsReadableByExactV140Shape() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanV140Rollback-\(UUID().uuidString)", isDirectory: true)
        let contentURL = fixtureRoot.appendingPathComponent("userContent.json")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let fixedDate = Date(timeIntervalSince1970: 1_740_000_000)
        let context = WritingContext(
            id: UUID(),
            title: "Rollback context",
            content: "Preserve this writing context.",
            isEnabledByDefault: true,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let store = UserContentStore(fileURL: contentURL)
        XCTAssertTrue(store.upsert(context))

        let encoded = try Data(contentsOf: contentURL)
        let rollback = try JSONDecoder().decode(V140Persisted.self, from: encoded)

        XCTAssertEqual(rollback.version, BeanPreferencesBackup.currentVersion)
        XCTAssertFalse(rollback.profiles.isEmpty)
        XCTAssertEqual(rollback.cards.count, 1)
        XCTAssertEqual(rollback.cards.first?.id, context.id)
        XCTAssertEqual(rollback.cards.first?.title, context.title)
        XCTAssertEqual(rollback.cards.first?.content, context.content)
        XCTAssertEqual(rollback.cards.first?.tags, [])
        XCTAssertTrue(rollback.cards.first?.isEnabledByDefault == true)
        XCTAssertFalse(rollback.appRules.isEmpty)
        XCTAssertNotNil(rollback.defaultProfileID)
    }

    func testV140UnverifiedKeyUpgradeRequiresExplicitRecoveryBeforeKeychainRead() throws {
        let suite = "PriorReleaseV140UnverifiedKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // v1.4 could persist this selected provider and a Keychain item without
        // either of the content-free metadata records introduced later.
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider")
        defaults.set(ProviderKind.anthropic.defaultModel, forKey: "model")
        defaults.set(true, forKey: "onboardingComplete")
        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.anthropic"))
        XCTAssertNil(defaults.object(forKey: "providerVerifiedAt"))

        var reads: [String] = []
        var writes: [(String, String)] = []
        let upgraded = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                reads.append(account)
                return account == ProviderKind.anthropic.keychainAccount
                    ? "exact-v140-unverified-key" : nil
            },
            writeKeychain: { value, account in
                writes.append((value, account))
                return errSecSuccess
            }
        )
        let editor = ProviderKeyEditorModel(settings: upgraded)

        XCTAssertEqual(upgraded.apiKeyPresenceState(for: .anthropic), .unknown)
        XCTAssertFalse(upgraded.hasAPIKey)
        XCTAssertFalse(upgraded.isProviderConnectionVerified)
        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertTrue(reads.isEmpty,
                      "an in-place upgrade and its setup model must never probe Keychain")
        XCTAssertTrue(writes.isEmpty)

        XCTAssertTrue(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, [ProviderKind.anthropic.keychainAccount])
        XCTAssertEqual(editor.draft, "exact-v140-unverified-key")
        XCTAssertEqual(upgraded.apiKeyPresenceState(for: .anthropic), .present)
        XCTAssertFalse(upgraded.isProviderConnectionVerified,
                       "recovery only loads the editor; Test remains a separate action")
        XCTAssertNil(defaults.object(forKey: "providerVerifiedAt"))
        XCTAssertTrue(writes.isEmpty)
    }

    func testInterruptedV140OnboardingPreservesSavedKeyForExplicitRecovery() throws {
        let suite = "PriorReleaseInterruptedV140KeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider")
        defaults.set(ProviderKind.anthropic.defaultModel, forKey: "model")
        defaults.set(false, forKey: "onboardingComplete")
        defaults.set(1, forKey: "automaticAICostSafetyVersion")
        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.anthropic"))
        XCTAssertNil(defaults.object(forKey: "providerVerifiedAt"))

        var reads: [String] = []
        var writes = 0
        let upgraded = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                reads.append(account)
                return account == ProviderKind.anthropic.keychainAccount
                    ? "interrupted-v140-key" : nil
            },
            writeKeychain: { _, _ in
                writes += 1
                return errSecSuccess
            }
        )
        let navigation = SettingsNavigation()
        let editor = ProviderKeyEditorModel(settings: upgraded)
        navigation.selection = .provider

        XCTAssertFalse(upgraded.onboardingComplete)
        XCTAssertEqual(upgraded.apiKeyPresenceState(for: .anthropic), .unknown)
        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertTrue(reads.isEmpty,
                      "interrupted-upgrade construction and navigation must not read Keychain")
        XCTAssertEqual(writes, 0)

        XCTAssertTrue(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, [ProviderKind.anthropic.keychainAccount])
        XCTAssertEqual(editor.draft, "interrupted-v140-key")
        XCTAssertEqual(upgraded.apiKeyPresenceState(for: .anthropic), .present)
        XCTAssertFalse(upgraded.isProviderConnectionVerified)
        XCTAssertNil(defaults.object(forKey: "providerVerifiedAt"))
        XCTAssertEqual(writes, 0)
    }

    func testPriorReleaseProfileMigratesAndRelaunchesWithoutLosingUserState() throws {
        let suite = "PriorReleaseUpgradeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanPriorReleaseUpgrade-\(UUID().uuidString)", isDirectory: true)
        let contentDirectory = fixtureRoot.appendingPathComponent("Bean", isDirectory: true)
        let contentURL = contentDirectory.appendingPathComponent("userContent.json")
        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        let quickFixShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            carbonModifiers: UInt32(cmdKey | optionKey)
        )
        let menuShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(controlKey | shiftKey)
        )
        let verifiedAt = Date(timeIntervalSince1970: 1_776_000_000)
        seedLegacyDefaults(
            defaults,
            quickFixShortcut: quickFixShortcut,
            menuShortcut: menuShortcut,
            verifiedAt: verifiedAt
        )

        let legacyCasualID = UUID()
        let customProfileID = UUID()
        let contextID = UUID()
        let dictionaryID = UUID()
        try seedLegacyPersonalization(
            at: contentURL,
            legacyCasualID: legacyCasualID,
            customProfileID: customProfileID,
            contextID: contextID,
            dictionaryID: dictionaryID
        )

        let legacySecret = "synthetic-prior-release-key"
        var firstLaunchReads: [String] = []
        var writes: [(value: String, account: String)] = []
        let firstLaunch = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                firstLaunchReads.append(account)
                return account == ProviderKind.anthropic.keychainAccount ? legacySecret : nil
            },
            writeKeychain: { value, account in
                writes.append((value, account))
                return errSecSuccess
            }
        )
        let firstContentLoad = UserContentStore(fileURL: contentURL)

        // Completed onboarding and customized, safe preferences survive intact.
        XCTAssertTrue(firstLaunch.onboardingComplete, "an upgrade must not reopen onboarding")
        XCTAssertEqual(firstLaunch.onboardingStepRawValue, 2)
        XCTAssertEqual(firstLaunch.shortcut, quickFixShortcut)
        XCTAssertEqual(firstLaunch.beanMenuShortcut, menuShortcut)
        XCTAssertEqual(firstLaunch.provider, .anthropic)
        XCTAssertEqual(firstLaunch.model, ProviderKind.anthropic.defaultModel)
        XCTAssertEqual(firstLaunch.timeoutSeconds, 45)
        XCTAssertFalse(firstLaunch.fixFocusedFieldWhenNoSelection)
        XCTAssertTrue(firstLaunch.diagnosticsEnabled)
        XCTAssertTrue(firstLaunch.inlineHighlightsEnabled)
        XCTAssertTrue(firstLaunch.bubbleEnabled)
        XCTAssertFalse(firstLaunch.bubbleOnSelection)
        XCTAssertEqual(firstLaunch.dailyAutomaticCallLimit, 7)
        XCTAssertEqual(firstLaunch.monthlyTokenWarningThreshold, 180_000)

        // Old automatic-AI flags are the only settings intentionally made safer.
        XCTAssertFalse(firstLaunch.passiveEnabled)
        XCTAssertTrue(firstLaunch.inlineLocalOnly)
        XCTAssertFalse(firstLaunch.inlineIncludeLLM)
        XCTAssertFalse(firstLaunch.inlineFallbackPassive)
        XCTAssertFalse(firstLaunch.webInlineEnabled)
        XCTAssertFalse(firstLaunch.automaticAIChecksEnabled)
        XCTAssertEqual(defaults.integer(forKey: "automaticAICostSafetyVersion"), 1)
        XCTAssertEqual(defaults.integer(forKey: "liveAssistanceSimplificationVersion"), 1)

        // Presence and verification metadata keep ordinary launch/status UI
        // truthful without touching the real (or injected) Keychain.
        XCTAssertTrue(firstLaunch.hasAPIKey)
        XCTAssertTrue(firstLaunch.isProviderConnectionVerified)
        XCTAssertEqual(firstLaunch.providerConnectionVerifiedAt, verifiedAt)
        XCTAssertTrue(firstLaunchReads.isEmpty)
        XCTAssertTrue(writes.isEmpty)

        // The legacy built-in ID and name are canonicalized, and every saved
        // reference follows it. Unrelated custom content remains addressable.
        assertMigratedPersonalization(
            firstContentLoad,
            legacyCasualID: legacyCasualID,
            customProfileID: customProfileID,
            contextID: contextID,
            dictionaryID: dictionaryID
        )
        let migratedJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: contentURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedJSON["version"] as? Int, BeanPreferencesBackup.currentVersion)
        let migratedText = try XCTUnwrap(String(data: Data(contentsOf: contentURL), encoding: .utf8))
        XCTAssertFalse(migratedText.contains("Slack Casual"))
        XCTAssertFalse(migratedText.contains(legacyCasualID.uuidString))

        // Loading the key is still an explicit operation, and repeated reads in
        // one process are served by the cache instead of prompting repeatedly.
        XCTAssertEqual(firstLaunch.apiKey, legacySecret)
        XCTAssertEqual(firstLaunch.apiKey, legacySecret)
        XCTAssertEqual(firstLaunchReads, [ProviderKind.anthropic.keychainAccount])
        XCTAssertTrue(writes.isEmpty, "an upgrade must never rewrite an existing API key")
        XCTAssertFalse(
            String(describing: defaults.persistentDomain(forName: suite)).contains(legacySecret),
            "the compatibility fixture must not move a secret into UserDefaults"
        )

        // Simulate a normal second launch from the exact migrated stores.
        var relaunchReads: [String] = []
        let relaunched = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                relaunchReads.append(account)
                return account == ProviderKind.anthropic.keychainAccount ? legacySecret : nil
            },
            writeKeychain: { value, account in
                writes.append((value, account))
                return errSecSuccess
            }
        )
        let reloadedContent = UserContentStore(fileURL: contentURL)

        XCTAssertTrue(relaunched.onboardingComplete)
        XCTAssertEqual(relaunched.shortcut, quickFixShortcut)
        XCTAssertEqual(relaunched.beanMenuShortcut, menuShortcut)
        XCTAssertTrue(relaunched.hasAPIKey)
        XCTAssertTrue(relaunched.isProviderConnectionVerified)
        XCTAssertTrue(relaunchReads.isEmpty, "relaunch/status must not produce a Keychain prompt")
        XCTAssertTrue(writes.isEmpty)
        assertMigratedPersonalization(
            reloadedContent,
            legacyCasualID: legacyCasualID,
            customProfileID: customProfileID,
            contextID: contextID,
            dictionaryID: dictionaryID
        )

        XCTAssertEqual(relaunched.apiKey, legacySecret)
        XCTAssertEqual(relaunched.apiKey, legacySecret)
        XCTAssertEqual(relaunchReads, [ProviderKind.anthropic.keychainAccount])
        XCTAssertTrue(writes.isEmpty)
    }

    private func seedLegacyDefaults(
        _ defaults: UserDefaults,
        quickFixShortcut: GlobalShortcut,
        menuShortcut: GlobalShortcut,
        verifiedAt: Date
    ) {
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider")
        defaults.set(ProviderKind.anthropic.defaultModel, forKey: "model")
        defaults.set(45.0, forKey: "timeoutSeconds")
        defaults.set(false, forKey: "fixFocusedFieldWhenNoSelection")
        defaults.set(true, forKey: "diagnosticsEnabled")
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(2, forKey: "onboardingStepRawValue")
        defaults.set(try? JSONEncoder().encode(quickFixShortcut), forKey: "globalShortcut")
        defaults.set(try? JSONEncoder().encode(menuShortcut), forKey: "beanMenuShortcut")

        defaults.set(verifiedAt.timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "providerVerifiedKind")
        defaults.set(ProviderKind.anthropic.defaultModel, forKey: "providerVerifiedModel")
        defaults.set(true, forKey: "apiKeyPresent.anthropic")

        defaults.set(true, forKey: "inlineHighlightsEnabled")
        defaults.set(true, forKey: "bubbleEnabled")
        defaults.set(false, forKey: "bubbleOnSelection")
        defaults.set(7, forKey: "dailyAutomaticCallLimit")
        defaults.set(180_000, forKey: "monthlyTokenWarningThreshold")

        // These prior-release values are deliberately unsafe after the public
        // product removed background AI. Leave both migration markers absent.
        defaults.set(true, forKey: "passiveEnabled")
        defaults.set(false, forKey: "inlineLocalOnly")
        defaults.set(true, forKey: "inlineIncludeLLM")
        defaults.set(true, forKey: "inlineFallbackPassive")
        defaults.set(true, forKey: "webInlineEnabled")
    }

    private func seedLegacyPersonalization(
        at contentURL: URL,
        legacyCasualID: UUID,
        customProfileID: UUID,
        contextID: UUID,
        dictionaryID: UUID
    ) throws {
        let fixedDate = Date(timeIntervalSince1970: 1_740_000_000)
        let legacyCasual = StyleProfile(
            id: legacyCasualID,
            name: "Slack Casual",
            detail: "Legacy built-in",
            formality: 2,
            warmth: 4,
            conciseness: 4,
            directness: 3,
            preferredInstructions: "Keep it friendly.",
            isBuiltIn: true,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let customProfile = StyleProfile(
            id: customProfileID,
            name: "My concise voice",
            detail: "Preserve this profile",
            formality: 4,
            warmth: 3,
            conciseness: 5,
            directness: 5,
            preferredInstructions: "Lead with the decision.",
            bannedPhrases: ["circle back"],
            exampleSnippets: ["Decision: ship Friday."],
            isBuiltIn: false,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let context = WritingContext(
            id: contextID,
            title: "Product language",
            content: "Call the product Bean.",
            isEnabledByDefault: true,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let term = DictionaryTerm(
            id: dictionaryID,
            term: "BeanOS",
            note: "Product name",
            caseSensitive: true,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let payload = LegacyUserContent(
            profiles: [legacyCasual, customProfile],
            cards: [context],
            dictionary: [term],
            appRules: [
                AppRule(category: .chat, defaultStyleProfileID: legacyCasualID),
                AppRule(category: .mail, defaultStyleProfileID: customProfileID)
            ],
            defaultProfileID: legacyCasualID
        )
        try JSONEncoder().encode(payload).write(to: contentURL, options: .atomic)
    }

    private func assertMigratedPersonalization(
        _ store: UserContentStore,
        legacyCasualID: UUID,
        customProfileID: UUID,
        contextID: UUID,
        dictionaryID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(store.persistenceError, file: file, line: line)
        XCTAssertEqual(store.defaultProfileID, StyleProfile.casualBuiltInID, file: file, line: line)
        XCTAssertEqual(store.appRuleStyle(category: .chat), StyleProfile.casualBuiltInID, file: file, line: line)
        XCTAssertEqual(store.appRuleStyle(category: .mail), customProfileID, file: file, line: line)
        XCTAssertNil(store.profile(legacyCasualID), file: file, line: line)
        XCTAssertEqual(store.profile(StyleProfile.casualBuiltInID)?.name, "Casual", file: file, line: line)
        XCTAssertEqual(store.profile(customProfileID)?.preferredInstructions, "Lead with the decision.", file: file, line: line)
        XCTAssertEqual(store.cards.first(where: { $0.id == contextID })?.content, "Call the product Bean.", file: file, line: line)
        XCTAssertTrue(store.cards.first(where: { $0.id == contextID })?.isEnabledByDefault == true, file: file, line: line)
        XCTAssertEqual(store.dictionary.first(where: { $0.id == dictionaryID })?.term, "BeanOS", file: file, line: line)
        XCTAssertTrue(store.dictionary.first(where: { $0.id == dictionaryID })?.caseSensitive == true, file: file, line: line)
    }
}
