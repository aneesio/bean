import XCTest
import Security
@testable import Bean

@MainActor
final class ProviderModelTests: XCTestCase {
    func testCatalogsHaveUniqueIDsAndContainEachProvidersDefault() {
        var allIDs = Set<String>()
        for provider in ProviderKind.allCases {
            let models = provider.supportedModels
            XCTAssertGreaterThan(models.count, 1)
            XCTAssertTrue(models.contains(where: { $0.id == provider.defaultModel }))
            for model in models {
                XCTAssertTrue(allIDs.insert(model.id).inserted, "Duplicate ID: \(model.id)")
                XCTAssertFalse(model.displayName.isEmpty)
                XCTAssertFalse(model.detail.isEmpty)
                XCTAssertEqual(provider.modelDefinition(for: model.id), model)
                for other in ProviderKind.allCases where other != provider {
                    XCTAssertNil(other.modelDefinition(for: model.id))
                }
            }
        }
    }

    func testKnownSnapshotsUseTheCanonicalRequestSettingsWithoutPrefixGuesses() throws {
        for provider in ProviderKind.allCases {
            for model in provider.supportedModels {
                for alias in model.aliases {
                    let definition = try XCTUnwrap(provider.modelDefinition(for: alias))
                    XCTAssertEqual(definition.requestOptions, model.requestOptions)
                    let choices = provider.modelChoices(including: alias)
                    XCTAssertEqual(choices.last?.id, alias)
                    XCTAssertEqual(choices.last?.requestOptions, model.requestOptions)
                }
                XCTAssertNil(provider.modelDefinition(for: model.id + "-unknown"))
            }
        }
        XCTAssertNil(ProviderKind.anthropic.modelDefinition(for: "claude-haiku-5-50"))
    }

    func testHaiku55StoredFromTheOldTextFieldRemainsSelectedAndUsesItsProfile() throws {
        try withSettings(provider: .anthropic, model: "claude-haiku-5-5") { settings, defaults in
            XCTAssertEqual(settings.model, "claude-haiku-5-5")
            let choice = try XCTUnwrap(settings.modelChoices.first(where: { $0.id == settings.model }))
            XCTAssertNil(choice.requestOptions.temperature)
            XCTAssertTrue(choice.requestOptions.anthropicThinkingDisabled)
            XCTAssertEqual(settings.modelChoices.filter { $0.id == settings.model }.count, 1)
            XCTAssertEqual(defaults.string(forKey: "model"), "claude-haiku-5-5")
        }
    }

    func testDropdownPreservesSavedModelsAndVersionsWithoutTouchingCredentials() throws {
        let savedIDs: [(ProviderKind, String)] = [
            (.openai, "ft:gpt-4.1-mini:example:custom:version"),
            (.openai, "gpt-5-nano-2025-08-07"),
            (.anthropic, "claude-haiku-4-5-20251001"),
            (.anthropic, "claude-custom-model")
        ]
        for (provider, model) in savedIDs {
            try withSettings(provider: provider, model: model) { settings, defaults in
                let choices = settings.modelChoices
                XCTAssertEqual(settings.model, model)
                XCTAssertEqual(choices.filter { $0.id == model }.count, 1)
                XCTAssertEqual(defaults.string(forKey: "model"), model)
                XCTAssertTrue(settings.isProviderConnectionVerified)
            }
        }
    }

    func testChangingProviderResetsEvenAnUnknownSavedModelAndClearsVerification() throws {
        try withSettings(provider: .openai, model: "custom-model") { settings, defaults in
            XCTAssertTrue(settings.isProviderConnectionVerified)

            settings.provider = .anthropic

            XCTAssertEqual(settings.model, ProviderKind.anthropic.defaultModel)
            XCTAssertEqual(settings.modelChoices, ProviderKind.anthropic.supportedModels)
            XCTAssertFalse(settings.isProviderConnectionVerified)
            XCTAssertNil(defaults.object(forKey: "providerVerifiedModel"))
            XCTAssertFalse(settings.modelChoices.contains(where: { $0.id == "custom-model" }))

            settings.model = "claude-haiku-5-5"
            settings.provider = .anthropic
            XCTAssertEqual(settings.model, "claude-haiku-5-5", "Reassigning the same provider preserves selection")
            XCTAssertEqual(AppSettings(defaults: defaults).model, "claude-haiku-5-5")
        }
    }

    func testSupportedModelChangePersistsAndClearsPreviousConnectionProof() throws {
        try withSettings(provider: .anthropic, model: "claude-haiku-4-5") { settings, defaults in
            settings.model = "claude-haiku-5-5"

            XCTAssertFalse(settings.isProviderConnectionVerified)
            XCTAssertEqual(defaults.string(forKey: "model"), "claude-haiku-5-5")
            XCTAssertEqual(AppSettings(defaults: defaults).model, "claude-haiku-5-5")
        }
    }

    func testExistingRetiredAndWrongProviderMigrationsStillResolveToDropdownChoices() {
        XCTAssertEqual(ProviderKind.anthropic.migratedModel("claude-3-5-haiku-latest"),
                       ProviderKind.anthropic.defaultModel)
        XCTAssertEqual(ProviderKind.anthropic.migratedModel("gpt-5-nano"),
                       ProviderKind.anthropic.defaultModel)
        XCTAssertEqual(ProviderKind.openai.migratedModel("claude-haiku-5-5"),
                       ProviderKind.openai.defaultModel)
        XCTAssertEqual(ProviderKind.openai.migratedModel("custom-model"), "custom-model")
    }

    private func withSettings(
        provider: ProviderKind,
        model: String,
        body: (AppSettings, UserDefaults) throws -> Void
    ) throws {
        let suite = "ProviderModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(model, forKey: "model")
        defaults.set(true, forKey: "apiKeyPresent.\(provider.rawValue)")
        defaults.set(Date().timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(provider.rawValue, forKey: "providerVerifiedKind")
        defaults.set(model, forKey: "providerVerifiedModel")
        let settings = AppSettings(
            defaults: defaults,
            readKeychain: { _ in XCTFail("Model selection must not read Keychain"); return nil },
            writeKeychain: { _, _ in XCTFail("Model selection must not write Keychain"); return errSecSuccess }
        )
        try body(settings, defaults)
    }
}
