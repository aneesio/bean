import Security
import XCTest
@testable import Bean

@MainActor
final class ProviderKeyEditorTests: XCTestCase {
    func testPageConstructionAndSettingsNavigationUseOnlyPresenceMetadata() throws {
        let suite = "ProviderKeyEditorNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "apiKeyPresent.openai")
        defaults.set(true, forKey: "apiKeyPresent.anthropic")

        var reads: [String] = []
        var writes: [(String, String)] = []
        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                reads.append(account)
                return "stored-secret"
            },
            writeKeychain: { value, account in
                writes.append((value, account))
                return errSecSuccess
            }
        )

        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.selection, .general)
        XCTAssertTrue(settings.hasAPIKey)

        let lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderKeyEditorNavigationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        let usageLedger = UsageLedgerStore(
            defaults: defaults,
            storageKey: "provider-key-editor-navigation",
            coordinationDirectoryURL: lockDirectory
        )
        _ = ProviderSetupSection(settings: settings, usageLedger: usageLedger, compact: true)
        _ = ProviderSetupSection(
            settings: settings,
            usageLedger: usageLedger,
            compact: true,
            showsModelSettings: false
        )

        let editor = ProviderKeyEditorModel(settings: settings)
        navigation.selection = .provider
        XCTAssertFalse(editor.isEditing)
        XCTAssertTrue(editor.hasSavedKey)

        settings.provider = .anthropic
        editor.synchronizeProvider(.anthropic)
        XCTAssertFalse(editor.isEditing)
        XCTAssertTrue(editor.hasSavedKey)
        XCTAssertTrue(reads.isEmpty,
                      "constructing and navigating ordinary UI must not query Keychain")
        XCTAssertTrue(writes.isEmpty,
                      "ordinary navigation must preserve the stored key without rewriting it")
    }

    func testProviderSetupSourceHasNoLifecycleSecretRead() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SharedSections.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/SettingsView.swift"),
            encoding: .utf8
        )
        let onboardingSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/UI/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".onAppear { loadKeyField() }"))
        XCTAssertFalse(source.contains(".onChange(of: settings.provider) { _ in\n            loadKeyField()"))
        XCTAssertTrue(source.contains("keyEditor.synchronizeProvider(provider)"))
        XCTAssertTrue(source.contains("Button(\"Edit Key…\")"))
        XCTAssertTrue(source.contains("Button(\"Use Existing Keychain Key…\")"))
        XCTAssertTrue(source.contains("keyEditor.recoverExistingKeyForExplicitAction()"))
        XCTAssertTrue(source.contains("This only loads it for editing; Bean does not test it here."))
        XCTAssertTrue(source.contains("Choose Test Connection or Connect Bean separately."))
        XCTAssertTrue(source.contains("Existing key loaded for editing. It has not been tested."))
        XCTAssertTrue(source.contains("keyEditor.keyForExplicitConnectionTest()"))
        XCTAssertTrue(source.contains("testState = settings.keychainError == nil"))
        XCTAssertEqual(
            source.components(separatedBy: "settings.apiKey(for:").count - 1,
            1,
            "the shared setup UI must have one auditable secret-read boundary"
        )
        XCTAssertTrue(source.contains("private func loadStoredKeyForExplicitAction()"))
        XCTAssertTrue(source.contains("keyEditor.acceptConnectionTestCompletion("))
        XCTAssertTrue(source.contains("Settings reads this saved key only when you choose Edit Key or Test Connection."))
        XCTAssertFalse(source.contains("Bean leaves the saved key locked"))
        XCTAssertFalse(settingsSource.contains("settings.apiKey(for:"))
        XCTAssertFalse(onboardingSource.contains("settings.apiKey(for:"))

        let recoveryStart = try XCTUnwrap(source.range(of: "private func recoverExistingKey()"))
        let recoveryEnd = try XCTUnwrap(
            source.range(of: "private func saveKey()", range: recoveryStart.upperBound..<source.endIndex)
        )
        let recoverySource = String(source[recoveryStart.lowerBound..<recoveryEnd.lowerBound])
        XCTAssertFalse(recoverySource.contains("runTest()"),
                       "loading a legacy Keychain item must not start provider verification")
        XCTAssertFalse(recoverySource.contains("transformer."),
                       "the recovery action must remain content-local and provider-free")
        XCTAssertFalse(recoverySource.contains("saveDraft()"),
                       "loading a legacy key must not write it back to Keychain")

        let runTestStart = try XCTUnwrap(source.range(of: "private func runTest()"))
        let runTestEnd = try XCTUnwrap(
            source.range(
                of: "private func beginEditingKey()",
                range: runTestStart.upperBound..<source.endIndex
            )
        )
        let runTestSource = String(source[runTestStart.lowerBound..<runTestEnd.lowerBound])
        let emptyKeyGuard = try XCTUnwrap(runTestSource.range(of: "guard !key.isEmpty else"))
        let providerCall = try XCTUnwrap(runTestSource.range(of: "transformer.testConnection"))
        XCTAssertLessThan(emptyKeyGuard.lowerBound, providerCall.lowerBound,
                          "a failed Keychain read must return before any provider boundary")
    }

    func testProviderPageConstructionForAKeylessInstallDoesNotReadKeychain() throws {
        let suite = "ProviderKeyEditorKeylessConstructionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychainResult: { _ in reads += 1; return .notFound }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertTrue(editor.isEditing)
        XCTAssertFalse(editor.hasSavedKey)
        XCTAssertFalse(editor.canRecoverExistingKey,
                       "first-run onboarding should not show legacy recovery")
        XCTAssertEqual(editor.draft, "")
        XCTAssertEqual(reads, 0)
    }

    func testFreshInstallThatSkipsAIRemainsKnownKeylessAfterOnboarding() throws {
        let suite = "ProviderKeyEditorFreshSkipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return nil }
        )

        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .absent)
        XCTAssertEqual(settings.apiKeyPresenceState(for: .anthropic), .absent)
        XCTAssertEqual(defaults.object(forKey: "apiKeyPresent.openai") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "apiKeyPresent.anthropic") as? Bool, false)
        XCTAssertEqual(reads, 0, "the fresh-install discriminator is metadata-only")

        settings.onboardingComplete = true
        let editor = ProviderKeyEditorModel(settings: settings)
        XCTAssertFalse(editor.canRecoverExistingKey,
                       "skipping optional AI must not create a permanent legacy-key prompt")
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(reads, 0)
    }

    func testCompletedPriorInstallPreservesUnknownForLegacyRecovery() throws {
        let suite = "ProviderKeyEditorCompletedUpgradeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboardingComplete")
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return "legacy-key" }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.openai"))
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertEqual(reads, 0,
                       "the upgrade discriminator must preserve lazy Keychain access")
    }

    func testFirstPresenceMigrationRepairsPriorFalseButPreservesTrueMarker() throws {
        let suite = "ProviderKeyEditorPriorFalseMarkerMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "automaticAICostSafetyVersion")
        defaults.set(false, forKey: "apiKeyPresent.openai")
        defaults.set(true, forKey: "apiKeyPresent.anthropic")
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return nil }
        )

        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.openai"),
                     "a prior build's false marker must become recoverable once")
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertTrue(ProviderKeyEditorModel(settings: settings).canRecoverExistingKey)
        XCTAssertEqual(defaults.object(forKey: "apiKeyPresent.anthropic") as? Bool, true)
        XCTAssertEqual(settings.apiKeyPresenceState(for: .anthropic), .present)
        XCTAssertEqual(reads, 0, "presence repair must remain metadata-only")
    }

    func testConfirmedNotFoundAfterMigrationPersistsAcrossRelaunch() throws {
        let suite = "ProviderKeyEditorPostMigrationNotFoundTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "automaticAICostSafetyVersion")
        defaults.set(false, forKey: "apiKeyPresent.openai")
        var reads = 0

        let firstLaunch = AppSettings(
            defaults: defaults,
            readKeychainResult: { _ in reads += 1; return .notFound }
        )
        let firstEditor = ProviderKeyEditorModel(settings: firstLaunch)
        XCTAssertEqual(firstLaunch.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertTrue(firstEditor.canRecoverExistingKey)

        XCTAssertFalse(firstEditor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(defaults.object(forKey: "apiKeyPresent.openai") as? Bool, false)
        XCTAssertEqual(firstLaunch.apiKeyPresenceState(for: .openai), .absent)

        let relaunched = AppSettings(
            defaults: defaults,
            readKeychainResult: { _ in reads += 1; return .value("unexpected") }
        )
        let relaunchedEditor = ProviderKeyEditorModel(settings: relaunched)
        XCTAssertEqual(relaunched.apiKeyPresenceState(for: .openai), .absent)
        XCTAssertFalse(relaunchedEditor.canRecoverExistingKey)
        XCTAssertEqual(defaults.object(forKey: "apiKeyPresent.openai") as? Bool, false)
        XCTAssertEqual(reads, 1,
                       "a confirmed absence must not be reopened or reread on relaunch")
    }

    func testV140UnverifiedKeyIsRecoveredOnlyAfterExplicitUserAction() throws {
        let suite = "ProviderKeyEditorV140RecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider")
        defaults.set(ProviderKind.anthropic.defaultModel, forKey: "model")
        defaults.set(true, forKey: "onboardingComplete")
        // Exact v1.4 gap: Keychain contains a value, but no apiKeyPresent.* or
        // providerVerifiedAt metadata was persisted.
        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.anthropic"))
        XCTAssertNil(defaults.object(forKey: "providerVerifiedAt"))

        var reads: [String] = []
        var writes: [(String, String)] = []
        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                reads.append(account)
                return account == ProviderKind.anthropic.keychainAccount
                    ? "v140-unverified-secret" : nil
            },
            writeKeychain: { value, account in
                writes.append((value, account))
                return errSecSuccess
            }
        )
        let editor = ProviderKeyEditorModel(settings: settings)
        let lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderKeyEditorV140RecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        _ = ProviderSetupSection(
            settings: settings,
            usageLedger: UsageLedgerStore(
                defaults: defaults,
                storageKey: "v140-recovery-ui",
                coordinationDirectoryURL: lockDirectory
            ),
            compact: true
        )

        XCTAssertEqual(settings.apiKeyPresenceState(for: .anthropic), .unknown)
        XCTAssertFalse(settings.hasAPIKey)
        XCTAssertFalse(settings.isProviderConnectionVerified)
        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.draft, "")
        XCTAssertTrue(reads.isEmpty,
                      "launch, model construction, and setup rendering must stay metadata-only")
        XCTAssertTrue(writes.isEmpty)

        XCTAssertTrue(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, [ProviderKind.anthropic.keychainAccount])
        XCTAssertEqual(editor.draft, "v140-unverified-secret")
        XCTAssertTrue(editor.hasSavedKey)
        XCTAssertEqual(settings.apiKeyPresenceState(for: .anthropic), .present)
        XCTAssertFalse(editor.canRecoverExistingKey)
        XCTAssertFalse(settings.isProviderConnectionVerified,
                       "loading the old key must not silently verify it")
        XCTAssertNil(defaults.object(forKey: "providerVerifiedAt"))
        XCTAssertTrue(writes.isEmpty,
                      "recovering an existing Keychain item must never rewrite it")
    }

    func testExplicitLegacyRecoveryRecordsKnownAbsenceWithoutRepeatedReads() throws {
        let suite = "ProviderKeyEditorLegacyMissingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboardingComplete")
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return nil }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertFalse(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .absent)
        XCTAssertFalse(editor.canRecoverExistingKey)
        XCTAssertFalse(editor.hasSavedKey)
        XCTAssertFalse(settings.isProviderConnectionVerified)

        XCTAssertFalse(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, 1,
                       "an explicit retry uses the process cache instead of prompting again")
    }

    func testCanceledLegacyRecoveryStaysUnknownAndCanRetryInProcess() throws {
        let suite = "ProviderKeyEditorLegacyCanceledTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboardingComplete")
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychainResult: { _ in
                reads += 1
                return reads == 1 ? .failure(errSecUserCanceled) : .value("recovered-key")
            }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertFalse(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.openai"))
        XCTAssertFalse(settings.hasLoadedAPIKey(for: .openai))
        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertEqual(settings.keychainError,
                       "Keychain access was canceled. Try again when you're ready.")

        XCTAssertTrue(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, 2, "a canceled prompt must remain retryable in-process")
        XCTAssertEqual(editor.draft, "recovered-key")
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .present)
        XCTAssertNil(settings.keychainError)
    }

    func testInteractionNotAllowedLegacyRecoveryStaysUnknownAndCanRetry() throws {
        let suite = "ProviderKeyEditorLegacyUnavailableTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboardingComplete")
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychainResult: { _ in
                reads += 1
                return reads == 1
                    ? .failure(errSecInteractionNotAllowed)
                    : .notFound
            }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertFalse(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.openai"))
        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertEqual(settings.keychainError,
                       "Keychain access isn't available right now. Unlock your Mac and try again.")

        XCTAssertFalse(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .absent)
        XCTAssertFalse(editor.canRecoverExistingKey)
        XCTAssertNil(settings.keychainError)
    }

    func testOtherKeychainReadFailureUsesSafeCopyAndRemainsRetryable() throws {
        let suite = "ProviderKeyEditorLegacyTransientFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboardingComplete")
        var reads = 0
        var writes = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychainResult: { _ in
                reads += 1
                return .failure(errSecNotAvailable)
            },
            writeKeychain: { _, _ in
                writes += 1
                return errSecSuccess
            }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertFalse(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertNil(defaults.object(forKey: "apiKeyPresent.openai"))
        XCTAssertFalse(settings.hasLoadedAPIKey(for: .openai))
        XCTAssertTrue(editor.canRecoverExistingKey)
        XCTAssertEqual(settings.keychainError,
                       "Bean couldn't read the saved API key. Try again.")
        XCTAssertFalse(settings.keychainError?.contains("\(errSecNotAvailable)") == true)
        XCTAssertEqual(writes, 0)

        XCTAssertFalse(editor.recoverExistingKeyForExplicitAction())
        XCTAssertEqual(reads, 2, "transient failures must never poison the process cache")
        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .unknown)
        XCTAssertEqual(writes, 0)
    }

    func testFalseLegacyPresenceMarkerCannotMaskMatchingVerification() throws {
        let suite = "ProviderKeyEditorFalseMarkerVerificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(false, forKey: "apiKeyPresent.openai")
        defaults.set(1, forKey: "apiKeyPresenceMetadataMigrationVersion")
        defaults.set(Date().timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(ProviderKind.openai.rawValue, forKey: "providerVerifiedKind")
        defaults.set(ProviderKind.openai.defaultModel, forKey: "providerVerifiedModel")
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return "verified-key" }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertEqual(settings.apiKeyPresenceState(for: .openai), .present)
        XCTAssertTrue(settings.hasAPIKey)
        XCTAssertTrue(settings.isProviderConnectionVerified)
        XCTAssertTrue(editor.hasSavedKey)
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(reads, 0,
                       "repairing contradictory legacy metadata must not read Keychain")
    }

    func testEditKeyIsAnExplicitCachedKeychainBoundary() throws {
        let suite = "ProviderKeyEditorExplicitEditTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "apiKeyPresent.openai")
        var reads: [String] = []

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                reads.append(account)
                return "stored-secret"
            }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertTrue(reads.isEmpty)
        editor.beginEditingStoredKey()
        XCTAssertEqual(editor.draft, "stored-secret")
        XCTAssertEqual(reads, [ProviderKind.openai.keychainAccount])

        editor.beginEditingStoredKey()
        XCTAssertEqual(reads.count, 1,
                       "repeated SwiftUI actions must use the process-local credential cache")
    }

    func testConnectionTestLoadsSavedKeyOnlyAfterTheButtonAction() throws {
        let suite = "ProviderKeyEditorExplicitTestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "apiKeyPresent.anthropic")
        defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider")
        var reads = 0
        var writes = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { account in
                reads += 1
                XCTAssertEqual(account, ProviderKind.anthropic.keychainAccount)
                return "anthropic-secret"
            },
            writeKeychain: { _, _ in
                writes += 1
                return errSecSuccess
            }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertEqual(reads, 0)
        XCTAssertEqual(editor.keyForExplicitConnectionTest(), "anthropic-secret")
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(editor.isEditing)
        XCTAssertTrue(editor.saveDraft())
        XCTAssertEqual(writes, 0,
                       "testing with an unchanged saved key must not rewrite the Keychain item")
    }

    func testSavedKeyTestReadFailureIsRetryableAndClearsAcrossProviders() throws {
        let suite = "ProviderKeyEditorSavedKeyReadFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(true, forKey: "apiKeyPresent.openai")
        defaults.set(true, forKey: "apiKeyPresent.anthropic")
        var reads = 0
        var writes = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychainResult: { _ in
                reads += 1
                return reads == 1 ? .failure(errSecUserCanceled) : .value("saved-key")
            },
            writeKeychain: { _, _ in
                writes += 1
                return errSecSuccess
            }
        )
        let editor = ProviderKeyEditorModel(settings: settings)

        XCTAssertEqual(editor.keyForExplicitConnectionTest(), "")
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(settings.hasLoadedAPIKey(for: .openai))
        XCTAssertNotNil(settings.keychainError)
        XCTAssertEqual(writes, 0)

        settings.provider = .anthropic
        editor.synchronizeProvider(.anthropic)
        XCTAssertNil(settings.keychainError,
                     "an OpenAI read error must not remain visible under Anthropic")
        XCTAssertEqual(reads, 1, "provider navigation must remain metadata-only")

        settings.provider = .openai
        editor.synchronizeProvider(.openai)
        XCTAssertEqual(editor.keyForExplicitConnectionTest(), "saved-key")
        XCTAssertEqual(reads, 2, "the canceled saved-key read must remain retryable")
        XCTAssertEqual(writes, 0)
    }

    func testTypedDraftConnectionTestDoesNotNeedAKeychainReadBeforeSaving() throws {
        let suite = "ProviderKeyEditorDraftTestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0

        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in reads += 1; return nil }
        )
        let editor = ProviderKeyEditorModel(settings: settings)
        editor.draft = "new-user-secret"

        XCTAssertEqual(editor.keyForExplicitConnectionTest(), "new-user-secret")
        XCTAssertEqual(reads, 0,
                       "a newly typed value is already available for the explicit test action")
    }

    func testConnectionTestIdentityRejectsChangedConfigurationAndOlderCompletions() throws {
        let suite = "ProviderKeyEditorConnectionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProviderKeyEditorModel(settings: settings)

        let completed = editor.beginConnectionTest(
            provider: .openai,
            model: "openai-model"
        )
        XCTAssertTrue(editor.acceptConnectionTestCompletion(
            completed,
            currentProvider: .openai,
            currentModel: "openai-model"
        ))
        XCTAssertFalse(editor.acceptConnectionTestCompletion(
            completed,
            currentProvider: .openai,
            currentModel: "openai-model"
        ), "one asynchronous completion can be consumed only once")

        let providerStale = editor.beginConnectionTest(
            provider: .openai,
            model: "openai-model"
        )
        editor.synchronizeProvider(.anthropic)
        XCTAssertFalse(editor.acceptConnectionTestCompletion(
            providerStale,
            currentProvider: .anthropic,
            currentModel: "anthropic-model"
        ), "changing providers must invalidate the in-flight result")

        let modelStale = editor.beginConnectionTest(
            provider: .anthropic,
            model: "anthropic-model-a"
        )
        XCTAssertFalse(editor.acceptConnectionTestCompletion(
            modelStale,
            currentProvider: .anthropic,
            currentModel: "anthropic-model-b"
        ), "a result for one model cannot verify another model")
        XCTAssertFalse(editor.acceptConnectionTestCompletion(
            modelStale,
            currentProvider: .anthropic,
            currentModel: "anthropic-model-a"
        ), "a configuration-mismatched completion stays consumed")

        let older = editor.beginConnectionTest(
            provider: .anthropic,
            model: "anthropic-model"
        )
        let newer = editor.beginConnectionTest(
            provider: .anthropic,
            model: "anthropic-model"
        )
        XCTAssertFalse(editor.acceptConnectionTestCompletion(
            older,
            currentProvider: .anthropic,
            currentModel: "anthropic-model"
        ), "starting a newer test must make an older task stale")
        XCTAssertTrue(editor.acceptConnectionTestCompletion(
            newer,
            currentProvider: .anthropic,
            currentModel: "anthropic-model"
        ))
    }
}
