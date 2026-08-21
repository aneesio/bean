import XCTest
@testable import Bean

final class UsageAccountingTests: XCTestCase {
    private func request() -> LLMRequest {
        LLMRequest(systemPrompt: "Trusted system", userText: "User text", model: "test",
                   apiKey: "test", timeout: 10, maxOutputTokens: 100)
    }

    func testOpenAIParsesReportedUsage() throws {
        let data = Data(#"{"choices":[{"message":{"content":"Fixed."}}],"usage":{"prompt_tokens":41,"completion_tokens":7}}"#.utf8)
        let completion = try OpenAIProvider.parseCompletion(data: data, request: request())
        XCTAssertEqual(completion.text, "Fixed.")
        XCTAssertEqual(completion.usage, LLMUsage(inputTokens: 41, outputTokens: 7, isEstimated: false))
    }

    func testAnthropicParsesReportedUsage() throws {
        let data = Data(#"{"content":[{"type":"text","text":"Fixed."}],"usage":{"input_tokens":52,"output_tokens":8}}"#.utf8)
        let completion = try AnthropicProvider.parseCompletion(data: data, request: request())
        XCTAssertEqual(completion.text, "Fixed.")
        XCTAssertEqual(completion.usage, LLMUsage(inputTokens: 52, outputTokens: 8, isEstimated: false))
    }

    func testMissingProviderUsageUsesConservativeEstimate() throws {
        let data = Data(#"{"choices":[{"message":{"content":"A reasonably sized result."}}]}"#.utf8)
        let completion = try OpenAIProvider.parseCompletion(data: data, request: request())
        XCTAssertTrue(completion.usage.isEstimated)
        XCTAssertGreaterThan(completion.usage.inputTokens, 0)
        XCTAssertGreaterThan(completion.usage.outputTokens, 0)
    }

    @MainActor
    func testLedgerAggregatesSourcesAndEnforcesAutomaticLimit() throws {
        let suite = "UsageLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let ledger = UsageLedgerStore(defaults: defaults, storageKey: "usage", calendar: calendar)
        let now = Date()

        ledger.record(LLMUsage(inputTokens: 100, outputTokens: 20, isEstimated: false),
                      source: .manual, provider: "openai", model: "gpt-5-nano", at: now)
        ledger.record(LLMUsage(inputTokens: 80, outputTokens: 10, isEstimated: true),
                      source: .passive, provider: "anthropic", model: "claude-haiku-4-5", at: now)

        let summary = ledger.summary(days: 30, now: now)
        XCTAssertEqual(summary.inputTokens, 180)
        XCTAssertEqual(summary.outputTokens, 30)
        XCTAssertEqual(summary.operationCount, 2)
        XCTAssertEqual(summary.automaticOperationCount, 1)
        XCTAssertEqual(summary.estimatedOperationCount, 1)
        XCTAssertFalse(ledger.allowsAutomaticCall(dailyLimit: 1, now: now))
        XCTAssertTrue(ledger.allowsAutomaticCall(dailyLimit: 2, now: now))

        let reloaded = UsageLedgerStore(defaults: defaults, storageKey: "usage", calendar: calendar)
        XCTAssertEqual(reloaded.summary(days: 30, now: now), summary)
    }

    @MainActor
    func testClearingUsageLeavesOtherPreferencesUntouchedAndStoresNoText() throws {
        let suite = "UsageLedgerPrivacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("anthropic", forKey: "provider")
        let ledger = UsageLedgerStore(defaults: defaults, storageKey: "usage")
        ledger.record(LLMUsage(inputTokens: 12, outputTokens: 3, isEstimated: false),
                      source: .webInline, provider: "anthropic", model: "claude-haiku-4-5")

        let encoded = try XCTUnwrap(defaults.data(forKey: "usage"))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("sourceText"))
        XCTAssertFalse(json.contains("response"))
        XCTAssertFalse(json.contains("clipboard"))

        ledger.clear()
        XCTAssertEqual(defaults.string(forKey: "provider"), "anthropic")
        XCTAssertNil(defaults.data(forKey: "usage"))
    }

    @MainActor
    func testSeparateNativeHostAndAppWritersMergeBeforePersisting() throws {
        let suite = "UsageLedgerMergeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appLedger = UsageLedgerStore(defaults: defaults, storageKey: "usage")
        let hostLedger = UsageLedgerStore(defaults: defaults, storageKey: "usage")

        hostLedger.record(LLMUsage(inputTokens: 20, outputTokens: 2, isEstimated: false),
                          source: .webInline, provider: "openai", model: "gpt-5-nano")
        appLedger.record(LLMUsage(inputTokens: 30, outputTokens: 3, isEstimated: false),
                         source: .manual, provider: "openai", model: "gpt-5-nano")

        let reloaded = UsageLedgerStore(defaults: defaults, storageKey: "usage")
        XCTAssertEqual(reloaded.summary(days: 1).operationCount, 2)
        XCTAssertEqual(reloaded.summary(days: 1).totalTokens, 55)
    }

    func testKnownModelCostRatesAndUnknownModelExclusion() throws {
        let openAICost = try XCTUnwrap(UsageCostEstimator.costUSD(
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            provider: "openai", model: "gpt-5-nano"))
        let anthropicCost = try XCTUnwrap(UsageCostEstimator.costUSD(
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            provider: "anthropic", model: "claude-haiku-4-5"))
        XCTAssertEqual(openAICost, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(anthropicCost, 6.0, accuracy: 0.000_001)
        XCTAssertNil(UsageCostEstimator.costUSD(
            inputTokens: 10, outputTokens: 10, provider: "openai", model: "custom-model"))
    }
}
