import XCTest
@testable import Bean

@MainActor
final class AssistanceSettingsTests: XCTestCase {
    func testAppPauseExpiryResumeAndPersistenceDoNotReadKeysOrDisableManualActions() throws {
        let suite = "AssistanceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, readKeychain: { _ in XCTFail("Pause must not read keys"); return nil })
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        settings.pauseAssistance(in: "com.example.Editor", now: now)
        XCTAssertTrue(settings.isAssistancePaused(for: "com.example.Editor", now: now.addingTimeInterval(3_599)))
        XCTAssertFalse(settings.isAssistancePaused(for: "com.example.Editor", now: now.addingTimeInterval(3_600)))
        XCTAssertFalse(settings.isAssistancePaused(for: "com.example.Other", now: now))
        XCTAssertTrue(settings.fixFocusedFieldWhenNoSelection)
        settings.pauseAssistance(in: "com.example.Editor", for: nil)
        let restored = AppSettings(defaults: defaults, readKeychain: { _ in nil })
        XCTAssertTrue(restored.isAssistancePaused(for: "com.example.Editor", now: now.addingTimeInterval(100_000)))
        restored.resumeAssistance(in: "com.example.Editor")
        XCTAssertFalse(restored.isAssistancePaused(for: "com.example.Editor", now: now))
    }

    func testPauseRejectsMalformedMetadataAndInvalidDuration() throws {
        let suite = "AssistanceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["private writing": -1.0, "com.example.Valid": -1.0, "com.example.Bad": Double.infinity], forKey: "assistancePausedApps")
        let settings = AppSettings(defaults: defaults, readKeychain: { _ in nil })
        XCTAssertEqual(settings.assistancePausedApps, ["com.example.Valid": -1])
        settings.pauseAssistance(in: "com.example.Invalid", for: -1)
        settings.pauseAssistance(in: "writing without identifier", for: nil)
        XCTAssertEqual(settings.assistancePausedApps.count, 1)
    }

    func testMetricsAreBoundedAndCannotStoreArbitraryOutcomeText() {
        let metrics = AssistanceMetrics()
        for _ in 0..<700 { metrics.record(kind: .nativeAnalysis, inputLength: Int.max, elapsedMilliseconds: -1, outcome: "private writing") }
        XCTAssertEqual(metrics.samples.count, 500)
        XCTAssertEqual(metrics.samples.last?.outcome, "unknown")
        XCTAssertEqual(metrics.samples.last?.inputLength, 200_000)
        XCTAssertFalse(metrics.summary.contains("private writing"))
        XCTAssertEqual(AssistanceMetrics.percentile([1, 4, 3, 2], fraction: 0.95), 4)
        metrics.clear()
        XCTAssertTrue(metrics.samples.isEmpty)
    }
}
