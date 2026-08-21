import XCTest
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
}
