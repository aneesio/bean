import XCTest
import Security
@testable import Bean

@MainActor
final class AppSettingsDefaultsTests: XCTestCase {
    func testFreshPublicBetaKeepsEveryLabFeatureOff() throws {
        let suite = "AppSettingsDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.bubbleEnabled)
        XCTAssertFalse(settings.passiveEnabled)
        XCTAssertFalse(settings.inlineHighlightsEnabled)
        XCTAssertFalse(settings.webInlineEnabled)
        XCTAssertTrue(settings.inlineLocalOnly)
        XCTAssertFalse(settings.inlineIncludeLLM)
        XCTAssertFalse(settings.inlineFallbackPassive)
        XCTAssertFalse(settings.automaticAIChecksEnabled)
        XCTAssertFalse(settings.diagnosticsEnabled)
        XCTAssertEqual(settings.primaryShortcutAction, .quickFix)
    }

    func testPrimaryShortcutActionPersistsAndUnknownValuesFailLocal() throws {
        let suite = "AppSettingsPrimaryShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.primaryShortcutAction, .quickFix,
                       "existing users retain the free local shortcut contract")
        settings.primaryShortcutAction = .aiProofread
        XCTAssertEqual(AppSettings(defaults: defaults).primaryShortcutAction, .aiProofread)

        defaults.set("future-or-corrupt-action", forKey: "primaryShortcutAction")
        XCTAssertEqual(AppSettings(defaults: defaults).primaryShortcutAction, .quickFix,
                       "unknown persisted actions must never silently spend provider tokens")
    }

    func testCostSafetyMigrationDisablesPreviouslyStoredAutomaticPathsOnce() throws {
        let suite = "AppSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "passiveEnabled")
        defaults.set(false, forKey: "inlineLocalOnly")
        defaults.set(true, forKey: "inlineIncludeLLM")
        defaults.set(true, forKey: "inlineFallbackPassive")
        defaults.set(true, forKey: "webInlineEnabled")

        let migrated = AppSettings(defaults: defaults)
        XCTAssertFalse(migrated.passiveEnabled)
        XCTAssertTrue(migrated.inlineLocalOnly)
        XCTAssertFalse(migrated.inlineIncludeLLM)
        XCTAssertFalse(migrated.inlineFallbackPassive)
        XCTAssertFalse(migrated.webInlineEnabled)

        migrated.passiveEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.passiveEnabled, "a deliberate post-migration opt-in must persist")
    }

    func testProductSimplificationDisablesHiddenPassivePathsOnce() throws {
        let suite = "AppSettingsProductSimplificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Model an install that already passed the older cost migration, then
        // deliberately enabled features that Phase 3 no longer exposes.
        defaults.set(1, forKey: "automaticAICostSafetyVersion")
        defaults.set(true, forKey: "passiveEnabled")
        defaults.set(true, forKey: "inlineFallbackPassive")

        let migrated = AppSettings(defaults: defaults)
        XCTAssertFalse(migrated.passiveEnabled)
        XCTAssertFalse(migrated.inlineFallbackPassive)

        migrated.passiveEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.passiveEnabled, "the one-time migration must not repeatedly override later internal state")
    }

    func testDisableAutomaticAIChecksPreservesOfflineAndExplicitBehavior() throws {
        let suite = "AppSettingsDisableAutomaticAITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "automaticAICostSafetyVersion")
        defaults.set(1, forKey: "liveAssistanceSimplificationVersion")
        var keychainReads = 0
        var keychainWrites = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in keychainReads += 1; return "saved-key" },
            writeKeychain: { _, _ in keychainWrites += 1; return errSecSuccess }
        )
        settings.passiveEnabled = true
        settings.inlineHighlightsEnabled = true
        settings.inlineLocalOnly = false
        settings.inlineIncludeLLM = true
        settings.inlineFallbackPassive = true
        settings.webInlineEnabled = true
        settings.bubbleEnabled = true
        settings.fixFocusedFieldWhenNoSelection = true

        let proofreadShortcut = settings.shortcut
        let menuShortcut = settings.beanMenuShortcut
        let provider = settings.provider
        let model = settings.model

        XCTAssertTrue(settings.automaticAIChecksEnabled)
        settings.disableAutomaticAIChecks()

        XCTAssertFalse(settings.automaticAIChecksEnabled)
        XCTAssertFalse(settings.passiveEnabled)
        XCTAssertTrue(settings.inlineHighlightsEnabled,
                      "offline live suggestions must remain available")
        XCTAssertTrue(settings.inlineLocalOnly)
        XCTAssertFalse(settings.inlineIncludeLLM)
        XCTAssertFalse(settings.inlineFallbackPassive)
        XCTAssertFalse(settings.webInlineEnabled)
        XCTAssertTrue(settings.bubbleEnabled,
                      "the user-invoked Bean Bubble must remain available")
        XCTAssertTrue(settings.fixFocusedFieldWhenNoSelection,
                      "manual Quick Fix must retain focused-field replacement")
        XCTAssertEqual(settings.shortcut, proofreadShortcut)
        XCTAssertEqual(settings.beanMenuShortcut, menuShortcut)
        XCTAssertEqual(settings.provider, provider)
        XCTAssertEqual(settings.model, model)
        XCTAssertEqual(keychainReads, 0)
        XCTAssertEqual(keychainWrites, 0)

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.automaticAIChecksEnabled)
        XCTAssertTrue(relaunched.inlineHighlightsEnabled)
        XCTAssertTrue(relaunched.inlineLocalOnly)
        XCTAssertTrue(relaunched.bubbleEnabled)
        XCTAssertTrue(relaunched.fixFocusedFieldWhenNoSelection)
        XCTAssertEqual(relaunched.shortcut, proofreadShortcut)
        XCTAssertEqual(relaunched.beanMenuShortcut, menuShortcut)
    }

    func testAPIKeyReadsAreCachedAndWritesAreExplicit() throws {
        let suite = "AppSettingsKeychainCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0
        var writes: [(String, String)] = []

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return "saved-key" },
            writeKeychain: { value, account in
                writes.append((value, account))
                return errSecSuccess
            }
        )

        XCTAssertFalse(settings.hasAPIKey)
        XCTAssertFalse(settings.isProviderConnectionVerified)
        XCTAssertEqual(reads, 0, "ordinary status checks must never query Keychain")

        XCTAssertEqual(settings.apiKey, "saved-key")
        XCTAssertTrue(settings.hasAPIKey)
        XCTAssertEqual(settings.apiKey(for: .openai), "saved-key")
        XCTAssertEqual(reads, 1, "SwiftUI refreshes must not repeatedly query Keychain")

        settings.apiKey = "saved-key"
        XCTAssertTrue(writes.isEmpty, "saving an unchanged key should be a no-op")

        settings.apiKey = "replacement-key"
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "replacement-key")
        XCTAssertEqual(settings.apiKey, "replacement-key")
        XCTAssertEqual(reads, 1, "a successful write should update the in-memory cache")
    }

    func testChangedKeyInvalidatesVerificationBeforeKeychainWriteEvenWhenWriteFails() throws {
        let suite = "AppSettingsKeyVerificationOrderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date().timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(ProviderKind.openai.rawValue, forKey: "providerVerifiedKind")
        defaults.set(ProviderKind.openai.defaultModel, forKey: "providerVerifiedModel")
        var markerWasAbsentDuringWrite = false

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in "old-key" },
            writeKeychain: { _, _ in
                markerWasAbsentDuringWrite = defaults.object(forKey: "providerVerifiedAt") == nil
                    && defaults.object(forKey: "providerVerifiedKind") == nil
                    && defaults.object(forKey: "providerVerifiedModel") == nil
                return errSecAuthFailed
            }
        )

        settings.apiKey = "unverified-new-key"

        XCTAssertTrue(markerWasAbsentDuringWrite,
                      "the old verification must be revoked before Keychain changes")
        XCTAssertFalse(settings.isProviderConnectionVerified)
        XCTAssertNil(defaults.object(forKey: "providerVerifiedAt"),
                     "a failed write must conservatively leave setup unverified")
        XCTAssertEqual(settings.apiKey, "old-key",
                       "a failed Keychain write must preserve the loaded secret")
    }

    func testAutomaticProviderProofIsBoundToExactCurrentPairAndInvalidatesOnChanges() throws {
        let suite = "AppSettingsAutomaticProviderProofTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "automaticAICostSafetyVersion")
        defaults.set(1, forKey: "liveAssistanceSimplificationVersion")
        // Model an upgraded install whose old automatic preferences remain on.
        defaults.set(false, forKey: "inlineLocalOnly")
        defaults.set(true, forKey: "inlineIncludeLLM")
        defaults.set(true, forKey: "passiveEnabled")

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { account in account.contains("anthropic") ? "anthropic-key" : "openai-key" },
            writeKeychain: { _, _ in errSecSuccess }
        )
        XCTAssertFalse(settings.isProviderConnectionVerified,
                       "legacy automatic toggles cannot substitute for provider verification")

        _ = settings.apiKey
        let openAI = settings.provider
        let openAIModel = settings.model
        settings.markProviderConnectionVerified(provider: openAI, model: openAIModel)
        XCTAssertTrue(settings.isProviderConnectionVerified(provider: openAI, model: openAIModel))

        settings.model = "unverified-model"
        XCTAssertFalse(settings.isProviderConnectionVerified)
        XCTAssertFalse(settings.isProviderConnectionVerified(provider: openAI, model: openAIModel),
                       "the previous pair cannot remain authorized after a model change")

        settings.model = openAIModel
        settings.markProviderConnectionVerified(provider: openAI, model: openAIModel)
        XCTAssertTrue(settings.isProviderConnectionVerified)
        settings.apiKey = "replacement-key"
        XCTAssertFalse(settings.isProviderConnectionVerified,
                       "a changed key must disable automatic provider paths until reverified")

        settings.provider = .anthropic
        _ = settings.apiKey
        let anthropicModel = settings.model
        settings.markProviderConnectionVerified(provider: .anthropic, model: anthropicModel)
        XCTAssertTrue(settings.isProviderConnectionVerified)
        XCTAssertFalse(settings.isProviderConnectionVerified(provider: openAI, model: openAIModel),
                       "verification for a new pair cannot authorize a stale captured pair")
    }

    func testInitializationAndMetadataStatusNeverReadKeychain() throws {
        let suite = "AppSettingsNoImplicitKeychainTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider")
        defaults.set(ProviderKind.anthropic.defaultModel, forKey: "model")
        defaults.set(Date().timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "providerVerifiedKind")
        defaults.set(ProviderKind.anthropic.defaultModel, forKey: "providerVerifiedModel")
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return "legacy-saved-key" }
        )

        XCTAssertEqual(reads, 0, "initialization must not touch Keychain")
        XCTAssertTrue(settings.hasAPIKey, "legacy verification metadata preserves truthful key-presence status")
        XCTAssertTrue(settings.isProviderConnectionVerified)
        XCTAssertEqual(reads, 0, "status and diagnostics metadata must remain non-interactive")
    }

    func testExplicitAPIKeyReadHappensOncePerProvider() throws {
        let suite = "AppSettingsExplicitKeychainTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var accounts: [String] = []

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                accounts.append(account)
                return account.contains("anthropic") ? "anthropic-key" : "openai-key"
            }
        )

        XCTAssertEqual(settings.apiKey(for: .openai), "openai-key")
        XCTAssertEqual(settings.apiKey(for: .openai), "openai-key")
        XCTAssertTrue(settings.hasAPIKey(for: .openai))
        XCTAssertEqual(accounts, ["apikey.openai"])

        XCTAssertEqual(settings.apiKey(for: .anthropic), "anthropic-key")
        XCTAssertEqual(settings.apiKey(for: .anthropic), "anthropic-key")
        XCTAssertTrue(settings.hasAPIKey(for: .anthropic))
        XCTAssertEqual(accounts, ["apikey.openai", "apikey.anthropic"])
    }

    func testFullResetForgetsCachedSecretsWithoutAnotherKeychainRead() throws {
        let suite = "AppSettingsFullResetCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0
        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return "cached-secret" }
        )

        XCTAssertEqual(settings.apiKey(for: .openai), "cached-secret")
        XCTAssertEqual(reads, 1)

        settings.forgetProviderCredentialsAfterResetAttempt()

        XCTAssertEqual(settings.apiKey(for: .openai), "")
        XCTAssertEqual(settings.apiKey(for: .anthropic), "")
        XCTAssertFalse(settings.hasAPIKey(for: .openai))
        XCTAssertFalse(settings.hasAPIKey(for: .anthropic))
        XCTAssertFalse(settings.isProviderConnectionVerified)
        XCTAssertEqual(reads, 1,
                       "post-reset memory cleanup must not query either Keychain item")
    }

    func testKeyPresenceMetadataSurvivesRelaunchWithoutReadingSecret() throws {
        let suite = "AppSettingsKeyPresenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var initialReads = 0
        let firstLaunch = AppSettings(
            defaults: defaults,
            readKeychain: { _ in initialReads += 1; return "saved-key" }
        )

        XCTAssertEqual(firstLaunch.apiKey, "saved-key")
        XCTAssertEqual(initialReads, 1)

        var relaunchReads = 0
        let relaunched = AppSettings(
            defaults: defaults,
            readKeychain: { _ in relaunchReads += 1; return "saved-key" }
        )
        XCTAssertTrue(relaunched.hasAPIKey)
        XCTAssertFalse(relaunched.isProviderConnectionVerified)
        XCTAssertEqual(relaunchReads, 0, "presence metadata must not unlock Keychain on relaunch")
    }

    func testMarkingProviderVerificationUsesOnlyLoadedProof() throws {
        let suite = "AppSettingsVerificationProofTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0
        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return "tested-key" }
        )

        settings.markProviderConnectionVerified(provider: settings.provider, model: settings.model)
        XCTAssertFalse(settings.isProviderConnectionVerified,
                       "verification cannot be recorded without an explicitly loaded or saved key")
        XCTAssertEqual(reads, 0, "marking status must never cause an implicit Keychain read")

        _ = settings.apiKey
        XCTAssertEqual(reads, 1)
        settings.markProviderConnectionVerified(provider: settings.provider, model: settings.model)
        XCTAssertTrue(settings.isProviderConnectionVerified)
        XCTAssertEqual(reads, 1, "marking status must use the already-loaded proof")
    }

    func testOnboardingStepPersistsAndClampsToThreeStepFlow() throws {
        let suite = "AppSettingsOnboardingStepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.onboardingStepRawValue, 0)

        settings.onboardingStepRawValue = 1
        XCTAssertEqual(AppSettings(defaults: defaults).onboardingStepRawValue, 1)

        settings.onboardingStepRawValue = 99
        XCTAssertEqual(settings.onboardingStepRawValue, 2)
        XCTAssertEqual(AppSettings(defaults: defaults).onboardingStepRawValue, 2)

        settings.onboardingStepRawValue = -10
        XCTAssertEqual(settings.onboardingStepRawValue, 0)
        XCTAssertEqual(AppSettings(defaults: defaults).onboardingStepRawValue, 0)
    }

    func testDefaultProfilesUseProductWideCasualName() {
        let profiles = StyleProfile.builtIns()
        XCTAssertTrue(profiles.contains { $0.name == "Casual" && $0.isBuiltIn })
        XCTAssertFalse(profiles.contains { $0.name == "Slack Casual" })
    }
}
