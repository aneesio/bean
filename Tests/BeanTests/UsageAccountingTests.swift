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
        let directory = temporaryCoordinationDirectory("UsageLedgerAggregate")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", calendar: calendar,
            coordinationDirectoryURL: directory
        )
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

        let reloaded = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", calendar: calendar,
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(reloaded.summary(days: 30, now: now), summary)
    }

    @MainActor
    func testClearingUsageLeavesOtherPreferencesUntouchedAndStoresNoText() throws {
        let suite = "UsageLedgerPrivacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("UsageLedgerPrivacy")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("anthropic", forKey: "provider")
        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
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
        let directory = temporaryCoordinationDirectory("UsageLedgerMerge")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let appLedger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        let hostLedger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )

        hostLedger.record(LLMUsage(inputTokens: 20, outputTokens: 2, isEstimated: false),
                          source: .webInline, provider: "openai", model: "gpt-5-nano")
        appLedger.record(LLMUsage(inputTokens: 30, outputTokens: 3, isEstimated: false),
                         source: .manual, provider: "openai", model: "gpt-5-nano")

        let reloaded = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(reloaded.summary(days: 1).operationCount, 2)
        XCTAssertEqual(reloaded.summary(days: 1).totalTokens, 55)
    }

    @MainActor
    func testRetentionPruningIsPersistedWhileSharedLockIsHeld() throws {
        let suite = "UsageLedgerDurableRetention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("UsageLedgerDurableRetention")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let staleDay = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: -(UsageLedgerStore.retentionDays + 1),
            to: today
        ))
        let retained = DailyUsageBucket(
            day: today, source: .manual, provider: "openai", model: "gpt-5-nano",
            inputTokens: 10, outputTokens: 2,
            operationCount: 1, estimatedOperationCount: 0
        )
        let stale = DailyUsageBucket(
            day: staleDay, source: .manual, provider: "openai", model: "gpt-5-nano",
            inputTokens: 99, outputTokens: 9,
            operationCount: 1, estimatedOperationCount: 0
        )
        defaults.set(try JSONEncoder().encode([retained, stale]), forKey: "usage")

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", calendar: calendar,
            coordinationDirectoryURL: directory
        )

        XCTAssertEqual(ledger.buckets, [retained])
        let persisted = try JSONDecoder().decode(
            [DailyUsageBucket].self,
            from: XCTUnwrap(defaults.data(forKey: "usage"))
        )
        XCTAssertEqual(persisted, [retained],
                       "Pruned buckets must not return on the next process refresh")
    }

    @MainActor
    func testUnavailableSharedLockNeverRewritesRecordsOrClearsPersistedUsage() throws {
        let suite = "UsageLedgerUnavailableLock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("UsageLedgerUnavailableLock")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: Date())
        let staleDay = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: -(UsageLedgerStore.retentionDays + 1),
            to: today
        ))
        let seeded = [
            DailyUsageBucket(
                day: today, source: .manual, provider: "openai", model: "gpt-5-nano",
                inputTokens: 10, outputTokens: 2,
                operationCount: 1, estimatedOperationCount: 0
            ),
            DailyUsageBucket(
                day: staleDay, source: .manual, provider: "openai", model: "gpt-5-nano",
                inputTokens: 99, outputTokens: 9,
                operationCount: 1, estimatedOperationCount: 0
            )
        ]
        let seededData = try JSONEncoder().encode(seeded)
        defaults.set(seededData, forKey: "usage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("automatic-call-reservations.lock"),
            withIntermediateDirectories: false
        )

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", calendar: calendar,
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(ledger.buckets, [seeded[0]])
        XCTAssertEqual(defaults.data(forKey: "usage"), seededData,
                       "Read-only fallback must not persist its pruned snapshot")

        let inMemorySnapshot = ledger.buckets
        ledger.record(
            LLMUsage(inputTokens: 1, outputTokens: 1, isEstimated: false),
            source: .manual, provider: "openai", model: "gpt-5-nano"
        )
        ledger.clear()

        XCTAssertEqual(ledger.buckets, inMemorySnapshot)
        XCTAssertEqual(defaults.data(forKey: "usage"), seededData)
    }

    @MainActor
    func testCorruptLedgerIsNotSilentlyOverwrittenByRecord() throws {
        let suite = "UsageLedgerCorruptPreservation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("UsageLedgerCorruptPreservation")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "usage")
        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )

        ledger.record(
            LLMUsage(inputTokens: 1, outputTokens: 1, isEstimated: false),
            source: .manual, provider: "openai", model: "gpt-5-nano"
        )

        XCTAssertTrue(ledger.buckets.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "usage"), corrupt)
    }

    @MainActor
    func testExtremeUsageCountersSaturateWithoutCrashingOrProducingInfiniteCost() throws {
        let suite = "UsageLedgerOverflowSafety.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("UsageLedgerOverflowSafety")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let today = calendar.startOfDay(for: now)
        defaults.set(try JSONEncoder().encode([
            DailyUsageBucket(
                day: today, source: .webInline,
                provider: "openai", model: "gpt-5-nano",
                inputTokens: Int.max, outputTokens: Int.max,
                operationCount: Int.max, estimatedOperationCount: Int.max
            ),
            DailyUsageBucket(
                day: today, source: .nativeInline,
                provider: "custom", model: "unpriced",
                inputTokens: Int.max, outputTokens: Int.max,
                operationCount: Int.max, estimatedOperationCount: Int.max
            )
        ]), forKey: "usage")
        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", calendar: calendar,
            coordinationDirectoryURL: directory
        )

        var summary = ledger.summary(days: 1, now: now)
        XCTAssertEqual(summary.inputTokens, Int.max)
        XCTAssertEqual(summary.outputTokens, Int.max)
        XCTAssertEqual(summary.totalTokens, Int.max)
        XCTAssertEqual(summary.operationCount, Int.max)
        XCTAssertEqual(summary.automaticOperationCount, Int.max)
        XCTAssertEqual(summary.estimatedOperationCount, Int.max)
        XCTAssertEqual(summary.unpricedOperationCount, Int.max)
        XCTAssertEqual(summary.averageTokensPerOperation, 1)
        XCTAssertTrue(summary.estimatedCostUSD.isFinite)

        ledger.record(
            LLMUsage(inputTokens: Int.max, outputTokens: Int.max, isEstimated: true),
            source: .webInline, provider: "openai", model: "gpt-5-nano", at: now
        )
        summary = ledger.summary(days: 1, now: now)
        XCTAssertEqual(summary.totalTokens, Int.max)
        XCTAssertEqual(summary.operationCount, Int.max)
        XCTAssertEqual(summary.estimatedOperationCount, Int.max)
        XCTAssertTrue(summary.estimatedCostUSD.isFinite)
        XCTAssertEqual(ledger.automaticCallsToday(now: now), Int.max)
        XCTAssertNil(UsageCostEstimator.costUSD(
            inputTokens: -1, outputTokens: 0,
            provider: "openai", model: "gpt-5-nano"
        ))
    }

    @MainActor
    func testManualAndAutomaticConcurrentWritersCannotOverwriteEachOther() throws {
        let suite = "UsageLedgerConcurrentWriters.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanUsageConcurrency-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let manualLedger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let workerDefaults = UserDefaults(suiteName: suite)!
            let budget = AutomaticCallBudgetStore(
                defaults: workerDefaults, usageStorageKey: "usage",
                historyStorageKey: "history", directoryURL: directory
            )
            for _ in 0..<20 {
                let metadata = AutomaticCallMetadata(
                    source: .webInline,
                    appName: "example.test",
                    appBundleIdentifier: nil,
                    appCategory: "browser",
                    action: "detectIssues",
                    inputMode: "focusedFieldFullText",
                    inputLength: 20,
                    provider: "test",
                    model: "test"
                )
                guard case .reserved(let reservation) = budget.reserve(
                    dailyLimit: 100, leaseDuration: 60, metadata: metadata
                ), reservation.beginProviderAttempt() else { continue }
                _ = reservation.complete(
                    usage: LLMUsage(inputTokens: 2, outputTokens: 1, isEstimated: false),
                    outputLength: 5, safetyResult: "ok", outcome: "issuesReturned"
                )
            }
            finished.leave()
        }

        for _ in 0..<20 {
            manualLedger.record(
                LLMUsage(inputTokens: 1, outputTokens: 1, isEstimated: false),
                source: .manual, provider: "test", model: "test"
            )
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)

        let reloaded = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        let summary = reloaded.summary(days: 1)
        XCTAssertEqual(summary.operationCount, 40)
        XCTAssertEqual(summary.automaticOperationCount, 20)
        XCTAssertEqual(summary.totalTokens, 100)
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

    func testInlineProviderBudgetOnlyFillsSlotsLeftAfterLocalIssues() {
        let remaining = IssueDetector.remainingProviderIssueCapacity(
            totalLimit: 8, localIssueCount: 7
        )

        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(IssueDetector.outputTokenBudget(maximumIssues: remaining), 192)
        XCTAssertEqual(IssueDetector.remainingProviderIssueCapacity(
            totalLimit: 8, localIssueCount: 8
        ), 0)
    }

    func testEveryNativeAutomaticServiceVerifiesProviderBeforeReservation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "Sources/Bean/Core/InlineHighlightService.swift",
            "Sources/Bean/Core/PassiveSuggestionService.swift"
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let verification = try XCTUnwrap(
                source.range(of: "isProviderConnectionVerified(")?.lowerBound,
                "\(relativePath) must verify the exact provider/model pair"
            )
            let keyRead = try XCTUnwrap(
                source.range(of: "let apiKey = settings.apiKey")?.lowerBound
                    ?? source.range(of: "let apiKey = self.settings.apiKey")?.lowerBound
            )
            let reservation = try XCTUnwrap(
                source.range(of: "automaticCallBudget.reserve(")?.lowerBound
                    ?? source.range(of: "self.automaticCallBudget.reserve(")?.lowerBound
            )
            XCTAssertLessThan(verification, keyRead,
                              "\(relativePath) must verify before reading Keychain")
            XCTAssertLessThan(verification, reservation,
                              "\(relativePath) must verify before reserving automatic spend")
        }
    }

    private func temporaryCoordinationDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
