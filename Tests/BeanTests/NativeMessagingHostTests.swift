import XCTest
@testable import Bean

final class NativeMessagingHostTests: XCTestCase {
    private final class ReservationCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var reservations: [AutomaticCallBudgetStore.Reservation] = []
        private(set) var limitReachedCount = 0
        private(set) var unavailableCount = 0

        func append(_ result: AutomaticCallBudgetStore.ReservationResult) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .reserved(let reservation): reservations.append(reservation)
            case .limitReached: limitReachedCount += 1
            case .unavailable: unavailableCount += 1
            }
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) { self.date = date }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    private func responseObject(for request: String,
                                dailyAutomaticCallLimit: Int = 7) -> [String: Any]? {
        let suite = "NativeHostProtocolTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated native-host defaults")
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeHostProtocol-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let provider = ProviderKind.openai
        let model = provider.defaultModel
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(model, forKey: "model")
        defaults.set(Date().timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(provider.rawValue, forKey: "providerVerifiedKind")
        defaults.set(model, forKey: "providerVerifiedModel")
        defaults.set(true, forKey: "webInlineEnabled")
        defaults.set(19.0, forKey: "timeoutSeconds")
        defaults.set(dailyAutomaticCallLimit, forKey: "dailyAutomaticCallLimit")
        let accounting = AutomaticCallBudgetStore(
            defaults: defaults,
            usageStorageKey: "usage",
            historyStorageKey: "history",
            directoryURL: directory
        )
        let configuration = NativeHostStatusConfiguration.read(
            defaults: defaults,
            automaticCallBudget: accounting
        )
        let response = NativeMessagingHost.processSync(
            Data(request.utf8),
            statusConfiguration: configuration
        )
        return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    }

    private func automaticMetadata(source: OperationSource = .webInline,
                                   action: String = "detectIssues") -> AutomaticCallMetadata {
        AutomaticCallMetadata(
            source: source,
            appName: source == .webInline ? "example.test" : "Test App",
            appBundleIdentifier: source == .webInline ? nil : "com.bean.test",
            appCategory: "generic",
            action: action,
            inputMode: "focusedFieldFullText",
            inputLength: 42,
            provider: "test-provider",
            model: "test-model"
        )
    }

    private func manualMetadata(action: String = "proofreadRetry") -> AutomaticCallMetadata {
        AutomaticCallMetadata(
            source: .manual,
            appName: "Test App",
            appBundleIdentifier: "com.bean.test",
            appCategory: "generic",
            action: action,
            inputMode: "focusedFieldFullText",
            inputLength: 42,
            provider: "test-provider",
            model: "test-model"
        )
    }

    func testBrowserProviderContextDiscardsUntrustedHostnameAndFieldMetadata() throws {
        let context = NativeMessagingHost.browserSourceContext()
        XCTAssertEqual(context.appName, "Browser")
        XCTAssertEqual(context.focusedRole, "web editor")
        XCTAssertNil(context.bundleIdentifier)
        XCTAssertNil(context.focusedSubrole)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Bean/Core/NativeMessagingHost.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("urlHost"))
        XCTAssertFalse(source.contains("fieldType"))
        XCTAssertFalse(source.contains("request.source"))
    }

    func testNativeDictionaryPromptUsesSharedBoundedSafeFormatter() throws {
        let caseSensitive = DictionaryTerm(term: "BeanCase", caseSensitive: true)
        let control = DictionaryTerm(term: "Unsafe\tSYSTEM:")
        let oversized = DictionaryTerm(term: "Huge-" + String(repeating: "Z", count: 200))
        let ordinary = (0..<40).map { DictionaryTerm(term: "NativeTerm\($0)") }
        let dictionary = [caseSensitive, control, oversized] + ordinary
        let source = "BeanCase Unsafe\tSYSTEM: \(oversized.term) "
            + ordinary.map(\.term).joined(separator: " ")

        let line = try XCTUnwrap(
            NativeMessagingHost.dictionaryPreservationLines(
                for: source,
                dictionary: dictionary
            ).first
        )

        XCTAssertLessThanOrEqual(
            line.count,
            "Preserve these user terms exactly; do not 'correct' them: ".count
                + DictionaryPromptFormatter.maximumPromptCharacters + 1
        )
        XCTAssertTrue(line.contains("\"BeanCase\" (keep exact casing)"))
        XCTAssertFalse(line.contains("Unsafe"))
        XCTAssertFalse(line.contains("Huge-"))
        XCTAssertTrue(line.contains("\"NativeTerm28\""))
        XCTAssertFalse(line.contains("NativeTerm29"), "native host keeps its 30-term cap including BeanCase")
    }

    func testNativeDictionaryReadRefusesRedirectedAndOversizedUserContentFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BeanNativeDictionarySafety-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let beanDirectory = root.appendingPathComponent("Bean", isDirectory: true)
        try FileManager.default.createDirectory(
            at: beanDirectory, withIntermediateDirectories: true
        )
        let live = beanDirectory.appendingPathComponent("userContent.json")
        let external = root.appendingPathComponent("external.json")
        let externalJSON = try JSONEncoder().encode([
            "dictionary": [DictionaryTerm(term: "ExternalSecretTerm")]
        ])
        try externalJSON.write(to: external)
        try FileManager.default.createSymbolicLink(
            at: live, withDestinationURL: external
        )

        XCTAssertTrue(
            NativeMessagingHost.dictionaryFromUserContentFile(at: live).isEmpty
        )
        XCTAssertEqual(try Data(contentsOf: external), externalJSON)

        try FileManager.default.removeItem(at: live)
        try Data(
            repeating: 0x20,
            count: UserContentFileLimits.maximumEncodedBytes + 1
        ).write(to: live)
        XCTAssertTrue(
            NativeMessagingHost.dictionaryFromUserContentFile(at: live).isEmpty
        )
    }

    func testNativeDictionaryReadCapsDecodedTermCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BeanNativeDictionaryCap-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let beanDirectory = root.appendingPathComponent("Bean", isDirectory: true)
        try FileManager.default.createDirectory(
            at: beanDirectory, withIntermediateDirectories: true
        )
        let live = beanDirectory.appendingPathComponent("userContent.json")
        let terms = (0..<(UserContentFileLimits.maximumNativeDictionaryTerms + 20)).map {
            DictionaryTerm(term: "Term\($0)")
        }
        try JSONEncoder().encode(["dictionary": terms]).write(to: live)

        let loaded = NativeMessagingHost.dictionaryFromUserContentFile(at: live)

        XCTAssertEqual(loaded.count, UserContentFileLimits.maximumNativeDictionaryTerms)
        XCTAssertEqual(loaded.last?.term, "Term\(UserContentFileLimits.maximumNativeDictionaryTerms - 1)")
    }

    @MainActor
    func testPingCanCompleteWhenCalledFromMainActor() {
        let object = responseObject(for: #"{"id":"test","type":"ping"}"#)

        XCTAssertEqual(object?["id"] as? String, "test")
        XCTAssertEqual(object?["ok"] as? Bool, true)
    }

    @MainActor
    func testStatusCanCompleteWhenCalledFromMainActor() {
        let object = responseObject(for: #"""
        {
            "id":"status-test",
            "type":"getStatus",
            "protocolVersion":1,
            "extensionVersion":"0.7.0",
            "minimumAppVersion":"1.0.0"
        }
        """#)

        XCTAssertEqual(object?["id"] as? String, "status-test")
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(object?["bridgeAvailable"] as? Bool, true)
        XCTAssertEqual(object?["nativeHostConnected"] as? Bool, true)
        XCTAssertEqual(object?["protocolVersion"] as? Int, 1)
        XCTAssertEqual(object?["extensionProtocolVersion"] as? Int, 1)
        XCTAssertEqual(object?["extensionVersion"] as? String, "0.7.0")
        XCTAssertEqual(object?["minimumExtensionVersion"] as? String, "0.7.0")
        XCTAssertEqual(object?["minimumAppVersion"] as? String, "1.0.0")
        XCTAssertFalse((object?["appVersion"] as? String)?.isEmpty ?? true)
        XCTAssertFalse((object?["appBuild"] as? String)?.isEmpty ?? true)
        XCTAssertEqual(object?["compatible"] as? Bool, true)
        XCTAssertEqual(object?["compatibilityCode"] as? String, "compatible")
        let providerTimeout = (object?["providerTimeoutSeconds"] as? NSNumber)?.doubleValue
        let requestTimeout = (object?["requestTimeoutSeconds"] as? NSNumber)?.doubleValue
        XCTAssertNotNil(providerTimeout)
        XCTAssertEqual(requestTimeout, providerTimeout)
        XCTAssertEqual(providerTimeout, 19)
        XCTAssertEqual(object?["dailyAutomaticCallLimit"] as? Int, 7)
        XCTAssertEqual(object?["automaticCallsToday"] as? Int, 0)
        XCTAssertEqual(object?["automaticAccountingAvailable"] as? Bool, true)
        XCTAssertEqual(object?["providerConfigured"] as? Bool, true)
        XCTAssertEqual(object?["webInlineEnabled"] as? Bool, true)
    }

    func testStatusReportsTheSameEffectiveBoundedDailyLimitAsAccounting() {
        for (stored, expected) in [(-1, 20), (0, 20), (201, 200), (Int.max, 200)] {
            let object = responseObject(
                for: #"{"id":"bounded-limit","type":"getStatus","protocolVersion":1}"#,
                dailyAutomaticCallLimit: stored
            )
            XCTAssertEqual(
                object?["dailyAutomaticCallLimit"] as? Int,
                expected,
                "stored value: \(stored)"
            )
        }
    }

    func testStatusExplicitlyReportsUnavailableAutomaticAccounting() {
        let configuration = NativeHostStatusConfiguration(
            providerConfigured: true,
            webInlineEnabled: true,
            timeout: 30,
            dailyAutomaticCallLimit: 20,
            automaticCallsToday: nil
        )
        let response = NativeMessagingHost.processSync(
            Data(#"{"id":"accounting-unavailable","type":"getStatus","protocolVersion":1}"#.utf8),
            statusConfiguration: configuration
        )
        let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]

        XCTAssertEqual(object?["ok"] as? Bool, true,
                       "the local bridge remains connected for local-only browser behavior")
        XCTAssertEqual(object?["automaticAccountingAvailable"] as? Bool, false)
        XCTAssertNil(object?["automaticCallsToday"])
        XCTAssertEqual(object?["providerConfigured"] as? Bool, true)
        XCTAssertEqual(object?["webInlineEnabled"] as? Bool, true)
    }

    func testStatusReportsProtocolMismatchWithoutHidingLiveConnection() {
        let object = responseObject(for: #"""
        {
            "id":"protocol-mismatch",
            "type":"getStatus",
            "protocolVersion":2,
            "extensionVersion":"0.7.0",
            "minimumAppVersion":"1.0.0"
        }
        """#)

        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(object?["bridgeAvailable"] as? Bool, true)
        XCTAssertEqual(object?["nativeHostConnected"] as? Bool, true)
        XCTAssertEqual(object?["compatible"] as? Bool, false)
        XCTAssertEqual(object?["compatibilityCode"] as? String, "protocolMismatch")
        XCTAssertFalse((object?["message"] as? String)?.isEmpty ?? true)
    }

    func testStatusReportsExtensionAndAppVersionMismatchesPrecisely() {
        let oldExtension = responseObject(for: #"""
        {
            "id":"old-extension",
            "type":"getStatus",
            "protocolVersion":1,
            "extensionVersion":"0.6.9",
            "minimumAppVersion":"1.0.0"
        }
        """#)
        XCTAssertEqual(oldExtension?["compatible"] as? Bool, false)
        XCTAssertEqual(oldExtension?["compatibilityCode"] as? String, "extensionUpdateRequired")

        let oldApp = responseObject(for: #"""
        {
            "id":"old-app",
            "type":"getStatus",
            "protocolVersion":1,
            "extensionVersion":"0.7.0",
            "minimumAppVersion":"999.0.0"
        }
        """#)
        XCTAssertEqual(oldApp?["compatible"] as? Bool, false)
        XCTAssertEqual(oldApp?["compatibilityCode"] as? String, "beanUpdateRequired")

        let missingMinimum = responseObject(for: #"""
        {
            "id":"missing-app-contract",
            "type":"getStatus",
            "protocolVersion":1,
            "extensionVersion":"0.7.0"
        }
        """#)
        XCTAssertEqual(missingMinimum?["compatible"] as? Bool, false)
        XCTAssertEqual(missingMinimum?["compatibilityCode"] as? String, "beanUpdateRequired")
    }

    func testLegacyStatusRequestIsConnectedButNotProtocolCompatible() {
        let object = responseObject(for: #"{"id":"legacy","type":"getStatus"}"#)

        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(object?["nativeHostConnected"] as? Bool, true)
        XCTAssertEqual(object?["compatible"] as? Bool, false)
        XCTAssertEqual(object?["compatibilityCode"] as? String, "protocolMismatch")
    }

    func testTextRequestsRequireProtocolBeforeReadingConfigurationOrCallingProvider() {
        for type in ["detectIssues", "proofreadParagraph"] {
            let object = responseObject(for: """
            {"id":"legacy-text","type":"\(type)","text":"must not be processed"}
            """)

            XCTAssertEqual(object?["ok"] as? Bool, false)
            XCTAssertEqual(object?["errorCode"] as? String, "protocolMismatch")
        }
    }

    func testTextRequestsEnforceCallerMinimumAppVersionBeforeConfiguration() {
        for minimumAppVersion in ["999.0.0", "not-a-version"] {
            let object = responseObject(for: #"""
            {
                "id":"newer-app-required",
                "type":"detectIssues",
                "protocolVersion":1,
                "extensionVersion":"0.7.0",
                "minimumAppVersion":"\#(minimumAppVersion)",
                "text":"must not be processed"
            }
            """#)

            XCTAssertEqual(object?["ok"] as? Bool, false)
            XCTAssertEqual(object?["errorCode"] as? String, "beanUpdateRequired")
        }

        let missingMinimum = responseObject(for: #"""
        {
            "id":"missing-minimum",
            "type":"proofreadParagraph",
            "protocolVersion":1,
            "extensionVersion":"0.7.0",
            "text":"must not be processed"
        }
        """#)
        XCTAssertEqual(missingMinimum?["ok"] as? Bool, false)
        XCTAssertEqual(missingMinimum?["errorCode"] as? String, "beanUpdateRequired")
    }

    func testUnverifiedProviderBlocksNativeWorkWithoutTouchingLiveSettings() throws {
        let suite = "NativeProviderUnverifiedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ProviderKind.openai
        let model = provider.defaultModel
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(model, forKey: "model")

        var reservationOrProviderInvocations = 0
        let result: Int? = NativeProviderVerificationPolicy.performIfVerified(
            capturedProvider: provider,
            capturedModel: model,
            defaults: defaults,
            operation: {
                reservationOrProviderInvocations += 1
                return 1
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(reservationOrProviderInvocations, 0,
                       "an unverified browser request cannot reserve budget or call a provider")
    }

    func testCapturedProviderSnapshotCannotUseVerificationForAConcurrentSettingsSwitch() throws {
        let suite = "NativeProviderSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capturedProvider = ProviderKind.openai
        let capturedModel = capturedProvider.defaultModel
        defaults.set(capturedProvider.rawValue, forKey: "provider")
        defaults.set(capturedModel, forKey: "model")
        defaults.set(Date().timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(capturedProvider.rawValue, forKey: "providerVerifiedKind")
        defaults.set(capturedModel, forKey: "providerVerifiedModel")
        XCTAssertTrue(NativeProviderVerificationPolicy.isVerified(
            capturedProvider: capturedProvider,
            capturedModel: capturedModel,
            defaults: defaults
        ))

        // Model a settings change after the native request captured OpenAI but
        // before it reaches the final reservation/provider boundary. Even a
        // fully verified new pair must not authorize the stale captured pair.
        let replacementProvider = ProviderKind.anthropic
        let replacementModel = replacementProvider.defaultModel
        defaults.set(replacementProvider.rawValue, forKey: "provider")
        defaults.set(replacementModel, forKey: "model")
        defaults.set(Date().timeIntervalSince1970, forKey: "providerVerifiedAt")
        defaults.set(replacementProvider.rawValue, forKey: "providerVerifiedKind")
        defaults.set(replacementModel, forKey: "providerVerifiedModel")

        var reservationOrProviderInvocations = 0
        _ = NativeProviderVerificationPolicy.performIfVerified(
            capturedProvider: capturedProvider,
            capturedModel: capturedModel,
            defaults: defaults,
            operation: {
                reservationOrProviderInvocations += 1
            }
        )
        XCTAssertEqual(reservationOrProviderInvocations, 0,
                       "a new pair's marker cannot authorize the captured pair")
    }

    func testSeparateStoresAtomicallyEnforceLimitUnderConcurrency() throws {
        let suite = "NativeReservationConcurrency.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let collector = ReservationCollector()
        let sources: [OperationSource] = [.webInline, .passive, .nativeInline]
        let attempts = 100
        DispatchQueue.concurrentPerform(iterations: attempts) { index in
            let store = AutomaticCallBudgetStore(
                defaults: defaults,
                usageStorageKey: "usage",
                historyStorageKey: "history",
                directoryURL: directory
            )
            collector.append(store.reserve(
                dailyLimit: 3,
                leaseDuration: 60,
                metadata: automaticMetadata(source: sources[index % sources.count])
            ))
        }

        XCTAssertEqual(collector.reservations.count, 3)
        XCTAssertEqual(collector.limitReachedCount, attempts - 3)
        XCTAssertEqual(collector.unavailableCount, 0)
        collector.reservations.forEach { $0.cancel() }
    }

    func testMalformedAccountingStateFailsClosedBeforeProviderReservation() throws {
        let suite = "NativeReservationMalformedState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )
        let validEmptyArray = try JSONEncoder().encode([DailyUsageBucket]())
        let validEmptyHistory = try JSONEncoder().encode([OperationRecord]())

        func assertUnavailable(_ result: AutomaticCallBudgetStore.ReservationResult,
                               file: StaticString = #filePath, line: UInt = #line) {
            guard case .unavailable = result else {
                return XCTFail("Corrupt accounting must fail closed", file: file, line: line)
            }
        }

        defaults.set(Data("not-json".utf8), forKey: "usage")
        defaults.set(validEmptyHistory, forKey: "history")
        assertUnavailable(store.reserve(
            dailyLimit: 20, leaseDuration: 60,
            metadata: automaticMetadata(source: .webInline)
        ))

        let invalidNegativeBucket = DailyUsageBucket(
            day: Date(), source: .webInline, provider: "test", model: "test",
            inputTokens: 0, outputTokens: 0,
            operationCount: -1, estimatedOperationCount: 0
        )
        defaults.set(try JSONEncoder().encode([invalidNegativeBucket]), forKey: "usage")
        assertUnavailable(store.reserve(
            dailyLimit: 20, leaseDuration: 60,
            metadata: automaticMetadata(source: .webInline)
        ))

        defaults.set(validEmptyArray, forKey: "usage")
        defaults.set(Data("not-json".utf8), forKey: "history")
        assertUnavailable(store.reserve(
            dailyLimit: 20, leaseDuration: 60,
            metadata: automaticMetadata(source: .passive)
        ))

        defaults.set(validEmptyHistory, forKey: "history")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("automatic-call-reservations.json")
        try Data(#"{"version":999,"leases":[],"resolutions":[]}"#.utf8)
            .write(to: stateURL, options: .atomic)
        assertUnavailable(store.reserve(
            dailyLimit: 20, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ))

        try Data("truncated".utf8).write(to: stateURL, options: .atomic)
        assertUnavailable(store.reserve(
            dailyLimit: 20, leaseDuration: 60,
            metadata: automaticMetadata(source: .webInline)
        ))
    }

    @MainActor
    func testProviderFailureConsumesReservationWithoutFabricatedTokens() throws {
        let suite = "NativeReservationFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )

        guard case .reserved(let failedCall) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .webInline)
        ) else {
            return XCTFail("Expected the first call to reserve the only slot")
        }
        XCTAssertTrue(failedCall.beginProviderAttempt())
        XCTAssertTrue(failedCall.fail(outcome: "providerNetworkFailed"))

        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .passive)
        ) else {
            return XCTFail("A failed provider attempt must consume the daily slot")
        }

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        let summary = ledger.summary(days: 1)
        XCTAssertEqual(summary.automaticOperationCount, 1)
        XCTAssertEqual(summary.totalTokens, 0)
        XCTAssertEqual(summary.estimatedOperationCount, 0)
        XCTAssertEqual(history.records.first?.outcome, "providerNetworkFailed")
        XCTAssertNil(history.records.first?.inputTokens)
        XCTAssertNil(history.records.first?.outputTokens)
        XCTAssertFalse(history.records.first?.usageEstimated ?? true)
    }

    func testPreProviderCancellationReleasesReservationImmediately() throws {
        let suite = "NativeReservationPreflightCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )

        guard case .reserved(let cancelled) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata()
        ) else {
            return XCTFail("Expected a pre-provider reservation")
        }
        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .passive)
        ) else {
            return XCTFail("An in-flight call must consume the daily slot")
        }

        cancelled.cancel()
        guard case .reserved(let retry) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else {
            return XCTFail("A cancellation before provider start must release the slot")
        }
        retry.cancel()
    }

    @MainActor
    func testTimeoutConsumesCapAndPersistsContentFreeFailureMetadata() throws {
        let suite = "NativeReservationTimeout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )

        guard case .reserved(let timeout) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .passive, action: "proofread")
        ) else {
            return XCTFail("Expected the timeout attempt to reserve")
        }
        XCTAssertTrue(timeout.beginProviderAttempt())
        XCTAssertTrue(timeout.fail(outcome: automaticProviderFailureOutcome(LLMError.timeout)))

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage",
            coordinationDirectoryURL: directory
        )
        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(ledger.automaticCallsToday(), 1)
        XCTAssertEqual(ledger.summary(days: 1).totalTokens, 0)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records[0].outcome, "requestTimedOut")
        XCTAssertEqual(history.records[0].source, .passive)
        XCTAssertNil(history.records[0].inputTokens)
        XCTAssertNil(history.records[0].outputTokens)
        XCTAssertFalse(history.records[0].diagnosticsLine.contains("tokens="))
    }

    func testExpiredCrashLeaseSelfRepairs() throws {
        let suite = "NativeReservationLease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory,
            now: { clock.now() }
        )

        guard case .reserved(let crashedCall) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata()
        ) else {
            return XCTFail("Expected the first reservation")
        }
        clock.advance(by: 61)
        guard case .reserved(let recoveredCall) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .passive)
        ) else {
            return XCTFail("An expired pre-provider lease must not stay stuck")
        }

        crashedCall.cancel()
        recoveredCall.cancel()
    }

    @MainActor
    func testExpiredStartedAttemptRepairsAsFailureAndDoesNotRestoreBudget() throws {
        let suite = "NativeReservationStartedLease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory,
            now: { clock.now() }
        )

        guard case .reserved(let abandoned) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else {
            return XCTFail("Expected the first reservation")
        }
        XCTAssertTrue(abandoned.beginProviderAttempt())
        clock.advance(by: 61)

        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .webInline)
        ) else {
            return XCTFail("An expired started attempt must still consume the cap")
        }

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", calendar: Calendar.current,
            coordinationDirectoryURL: directory
        )
        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(ledger.automaticCallsToday(now: clock.now()), 1)
        XCTAssertEqual(ledger.summary(days: 1, now: clock.now()).totalTokens, 0)
        XCTAssertEqual(history.records.first?.outcome, "providerAttemptExpired")
        XCTAssertNil(history.records.first?.inputTokens)

        // A late completion/deinit sees the resolution tombstone and cannot
        // double-count the already repaired attempt.
        abandoned.cancel()
        XCTAssertEqual(ledger.automaticCallsToday(now: clock.now()), 1)
    }

    @MainActor
    func testFinalizationAtomicallyConvertsReservationToCompletedUsage() throws {
        let suite = "NativeReservationFinalization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", calendar: calendar,
            directoryURL: directory,
            now: { startedAt }
        )

        guard case .reserved(let reservation) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata()
        ) else {
            return XCTFail("Expected the first reservation")
        }
        XCTAssertTrue(reservation.beginProviderAttempt())
        let finalized = reservation.complete(
            usage: LLMUsage(inputTokens: 11, outputTokens: 2, isEstimated: false),
            outputLength: 7, safetyResult: "ok", outcome: "issuesReturned"
        )

        XCTAssertTrue(finalized)
        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", calendar: calendar,
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(ledger.automaticCallsToday(now: startedAt), 1)
        XCTAssertEqual(ledger.summary(days: 1, now: startedAt).totalTokens, 13)
        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else {
            return XCTFail("Completed usage must continue consuming the daily slot")
        }
    }

    @MainActor
    func testBrowserAccountingRedactsHostnameAndFieldSemanticsEverywhere() throws {
        let suite = "NativeReservationBrowserPrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let metadata = AutomaticCallMetadata(
            source: .webInline,
            appName: "private-health.example",
            appBundleIdentifier: "forbidden.browser.field",
            appCategory: "secret-category",
            action: "detectIssues",
            inputMode: "sensitive-contenteditable",
            inputLength: 37,
            provider: "test-provider",
            model: "test-model"
        )
        XCTAssertNil(metadata.appName)
        XCTAssertNil(metadata.appBundleIdentifier)
        XCTAssertEqual(metadata.appCategory, "browser")
        XCTAssertEqual(metadata.inputMode, "browser")

        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )
        guard case .reserved(let reservation) = store.reserve(
            dailyLimit: 5, leaseDuration: 60, metadata: metadata
        ) else { return XCTFail("Expected a browser reservation") }

        let stateURL = directory.appendingPathComponent("automatic-call-reservations.json")
        let lockURL = directory.appendingPathComponent("automatic-call-reservations.lock")
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        let stateMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        let lockMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(stateMode, 0o600)
        XCTAssertEqual(lockMode, 0o600)
        var stateJSON = try String(contentsOf: stateURL, encoding: .utf8)
        for forbidden in ["private-health.example", "forbidden.browser.field",
                          "secret-category", "sensitive-contenteditable", "appName",
                          "appBundleIdentifier", "inputMode"] {
            XCTAssertFalse(stateJSON.contains(forbidden), forbidden)
        }

        XCTAssertTrue(reservation.beginProviderAttempt())
        XCTAssertTrue(reservation.complete(
            usage: LLMUsage(inputTokens: 9, outputTokens: 2, isEstimated: false),
            outputLength: 12, safetyResult: "ok", outcome: "issuesReturned"
        ))

        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history", coordinationDirectoryURL: directory
        )
        XCTAssertNil(history.records.first?.appName)
        XCTAssertNil(history.records.first?.appBundleIdentifier)
        XCTAssertEqual(history.records.first?.appCategory, "browser")
        XCTAssertEqual(history.records.first?.inputMode, "browser")
        stateJSON = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(stateJSON.contains("private-health.example"))
        XCTAssertFalse(stateJSON.contains("sensitive-contenteditable"))
    }

    @MainActor
    func testCleanupRedactsLegacyBrowserHistoryAlreadyOnDisk() throws {
        let suite = "NativeReservationLegacyBrowserPrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let legacy = OperationRecord(
            source: .webInline,
            appName: "legacy-sensitive.example",
            appBundleIdentifier: "legacy-field-semantics",
            appCategory: "legacy-category",
            action: "detectIssues",
            inputMode: "legacy-contenteditable",
            inputLength: 20,
            provider: "test-provider",
            model: "test-model",
            outcome: "issuesReturned"
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "history")
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )

        XCTAssertTrue(store.cleanupStaleReservations())
        let data = try XCTUnwrap(defaults.data(forKey: "history"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("legacy-sensitive.example"))
        XCTAssertFalse(json.contains("legacy-field-semantics"))
        XCTAssertFalse(json.contains("legacy-contenteditable"))
        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history", coordinationDirectoryURL: directory
        )
        XCTAssertNil(history.records.first?.appName)
        XCTAssertEqual(history.records.first?.appCategory, "browser")
        XCTAssertEqual(history.records.first?.inputMode, "browser")
    }

    func testCleanupMigratesLegacyBrowserLeaseWithoutPersistingIdentity() throws {
        let suite = "NativeReservationLegacyLeasePrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let leaseID = UUID()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyState: [String: Any] = [
            "version": 2,
            "leases": [[
                "id": leaseID.uuidString,
                "startedAt": timestamp.timeIntervalSinceReferenceDate,
                "expiresAt": timestamp.addingTimeInterval(60).timeIntervalSinceReferenceDate,
                "metadata": [
                    "source": "webInline",
                    "appName": "legacy-health.example",
                    "appBundleIdentifier": "legacy-browser-field",
                    "appCategory": "legacy-private-category",
                    "action": "detectIssues",
                    "inputMode": "legacy-contenteditable",
                    "inputLength": 23,
                    "provider": "test-provider",
                    "model": "test-model"
                ]
            ]],
            "resolutions": []
        ]
        let stateURL = directory.appendingPathComponent("automatic-call-reservations.json")
        try JSONSerialization.data(withJSONObject: legacyState)
            .write(to: stateURL, options: .atomic)
        defaults.set(Data("corrupt-history".utf8), forKey: "history")
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            directoryURL: directory, now: { timestamp }
        )

        // An unrelated corrupt visible history still makes accounting fail
        // closed, but it must not prevent the legacy lease privacy scrub.
        XCTAssertFalse(store.cleanupStaleReservations())
        var migrated = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(migrated.contains("\"version\":2"))
        for forbidden in ["legacy-health.example", "legacy-browser-field",
                          "legacy-private-category", "legacy-contenteditable",
                          "appName", "appBundleIdentifier", "inputMode"] {
            XCTAssertFalse(migrated.contains(forbidden), forbidden)
        }

        defaults.set(try JSONEncoder().encode([OperationRecord]()), forKey: "history")
        XCTAssertTrue(store.cleanupStaleReservations())
        migrated = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(migrated.contains("\"version\":3"))
        XCTAssertTrue(migrated.contains(leaseID.uuidString.uppercased())
                      || migrated.contains(leaseID.uuidString.lowercased()))
    }

    @MainActor
    func testCoordinatedClearPreservesDailyCapAndLateSettlementCannotRepopulate() throws {
        let suite = "NativeReservationCoordinatedClear.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )
        guard case .reserved(let completed) = store.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: automaticMetadata(source: .nativeInline)
        ) else { return XCTFail("Expected a completed reservation") }
        XCTAssertTrue(completed.beginProviderAttempt())
        XCTAssertTrue(completed.complete(
            usage: LLMUsage(inputTokens: 7, outputTokens: 1, isEstimated: false),
            outputLength: 5, safetyResult: "ok", outcome: "issuesReturned"
        ))
        guard case .reserved(let inFlight) = store.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: automaticMetadata()
        ) else { return XCTFail("Expected a reservation") }
        XCTAssertTrue(inFlight.beginProviderAttempt())

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", coordinationDirectoryURL: directory
        )
        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history", coordinationDirectoryURL: directory
        )
        XCTAssertEqual(ledger.summary(days: 1).operationCount, 1)
        XCTAssertEqual(history.records.count, 1)

        let result = try XCTUnwrap(store.clearVisibleAccounting())
        XCTAssertEqual(result.automaticCallsToday, 2)
        XCTAssertNil(defaults.data(forKey: "usage"))
        XCTAssertNil(defaults.data(forKey: "history"))
        ledger.refresh()
        history.refresh()
        XCTAssertEqual(ledger.summary(days: 1).operationCount, 0)
        XCTAssertTrue(history.records.isEmpty)

        // The provider may finish after the user clears the dashboard. Its old
        // reservation is tombstoned, so completion is acknowledged but cannot
        // recreate either visible ledger.
        XCTAssertTrue(inFlight.complete(
            usage: LLMUsage(inputTokens: 20, outputTokens: 4, isEstimated: false),
            outputLength: 8, safetyResult: "ok", outcome: "lateResult"
        ))
        XCTAssertNil(defaults.data(forKey: "usage"))
        XCTAssertNil(defaults.data(forKey: "history"))
        XCTAssertEqual(store.automaticCallsToday(), 2)
        guard case .limitReached = store.reserve(
            dailyLimit: 2, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else {
            return XCTFail("Clearing visible data must not restore today's paid capacity")
        }
    }

    func testClearFailureDoesNotClaimCorruptReservationStateWasCleared() throws {
        let suite = "NativeReservationClearFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(try JSONEncoder().encode([DailyUsageBucket]()), forKey: "usage")
        defaults.set(try JSONEncoder().encode([OperationRecord]()), forKey: "history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("corrupt-state".utf8).write(
            to: directory.appendingPathComponent("automatic-call-reservations.json"),
            options: .atomic
        )
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )

        XCTAssertNil(store.clearVisibleAccounting())
        XCTAssertNotNil(defaults.data(forKey: "usage"))
        XCTAssertNotNil(defaults.data(forKey: "history"))
    }

    func testCoordinatedClearCanEraseCorruptVisibleLedgersOncePrivateCounterIsAuthoritative() throws {
        let suite = "NativeReservationClearCorruptVisible.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )
        guard case .reserved(let attempt) = store.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: automaticMetadata()
        ) else { return XCTFail("Expected a reservation") }
        XCTAssertTrue(attempt.beginProviderAttempt())
        XCTAssertTrue(attempt.fail(outcome: "providerNetworkFailed"))
        XCTAssertEqual(store.automaticCallsToday(), 1)

        // The private version-three state remains authoritative even if either
        // user-visible payload becomes unreadable. Clear should recover the UI
        // without restoring today's paid capacity.
        defaults.set(Data("corrupt-usage".utf8), forKey: "usage")
        defaults.set(Data("corrupt-history".utf8), forKey: "history")
        let cleared = try XCTUnwrap(store.clearVisibleAccounting())
        XCTAssertEqual(cleared.automaticCallsToday, 1)
        XCTAssertNil(defaults.data(forKey: "usage"))
        XCTAssertNil(defaults.data(forKey: "history"))
        guard case .reserved(let remaining) = store.reserve(
            dailyLimit: 2, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else { return XCTFail("Clear must preserve exactly the remaining capacity") }
        remaining.cancel()
        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else { return XCTFail("Clear must not restore the spent automatic attempt") }
    }

    @MainActor
    func testLegacyVisibleUsageMigratesBeforeClearAndStillConsumesCap() throws {
        let suite = "NativeReservationLegacyCounterMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let legacyBucket = DailyUsageBucket(
            day: calendar.startOfDay(for: timestamp), source: .webInline,
            provider: "test-provider", model: "test-model",
            inputTokens: 10, outputTokens: 2,
            operationCount: 1, estimatedOperationCount: 0
        )
        defaults.set(try JSONEncoder().encode([legacyBucket]), forKey: "usage")
        defaults.set(try JSONEncoder().encode([OperationRecord]()), forKey: "history")
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", calendar: calendar,
            directoryURL: directory, now: { timestamp }
        )

        XCTAssertEqual(store.automaticCallsToday(), 1)
        let cleared = try XCTUnwrap(store.clearVisibleAccounting())
        XCTAssertEqual(cleared.automaticCallsToday, 1)
        XCTAssertNil(defaults.data(forKey: "usage"))
        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else { return XCTFail("Migrated usage must remain authoritative after clear") }
    }

    @MainActor
    func testExplicitNativeRetryIsManualAndUncappedButStillAccounted() throws {
        let suite = "NativeReservationManualRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )

        guard case .reserved(let automatic) = store.reserve(
            dailyLimit: 1, leaseDuration: 60, metadata: automaticMetadata()
        ) else { return XCTFail("Expected automatic reservation") }
        XCTAssertTrue(automatic.beginProviderAttempt())
        XCTAssertTrue(automatic.fail(outcome: "providerNetworkFailed"))

        guard case .reserved(let manualSuccess) = store.reserveManual(
            leaseDuration: 60, metadata: manualMetadata()
        ) else { return XCTFail("The automatic cap must not block a native manual retry") }
        XCTAssertTrue(manualSuccess.beginProviderAttempt())
        XCTAssertTrue(manualSuccess.complete(
            usage: LLMUsage(inputTokens: 12, outputTokens: 3, isEstimated: false),
            outputLength: 9, safetyResult: "ok", outcome: "retryReady"
        ))

        guard case .reserved(let manualFailure) = store.reserveManual(
            leaseDuration: 60, metadata: manualMetadata(action: "proofreadRetryFailure")
        ) else { return XCTFail("Expected a second uncapped manual retry") }
        XCTAssertTrue(manualFailure.beginProviderAttempt())
        XCTAssertTrue(manualFailure.fail(outcome: "providerAuthenticationFailed"))

        let ledger = UsageLedgerStore(
            defaults: defaults, storageKey: "usage", coordinationDirectoryURL: directory
        )
        let summary = ledger.summary(days: 1)
        XCTAssertEqual(summary.automaticOperationCount, 1)
        XCTAssertEqual(ledger.summary(days: 1, source: .manual).operationCount, 2)
        XCTAssertEqual(ledger.summary(days: 1, source: .manual).totalTokens, 15)
        XCTAssertEqual(store.automaticCallsToday(), 1)

        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history", coordinationDirectoryURL: directory
        )
        XCTAssertEqual(history.records.first?.source, .manual)
        XCTAssertEqual(history.records.first?.outcome, "providerAuthenticationFailed")
        XCTAssertNil(history.records.first?.inputTokens)
        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else { return XCTFail("Manual retries must not change the automatic count") }
    }

    func testBrowserFixParagraphRemainsInsideAutomaticCap() throws {
        let suite = "NativeReservationBrowserFixCap.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory
        )
        guard case .reserved(let browserFix) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(action: "proofreadParagraph")
        ) else { return XCTFail("Expected the first browser Fix Paragraph reservation") }
        XCTAssertTrue(browserFix.beginProviderAttempt())
        XCTAssertTrue(browserFix.fail(outcome: "providerNetworkFailed"))

        guard case .limitReached = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(action: "proofreadParagraph")
        ) else {
            return XCTFail("Browser Fix Paragraph must never bypass the browser AI cap")
        }
        guard case .unavailable = store.reserveManual(
            leaseDuration: 60,
            metadata: automaticMetadata(action: "proofreadParagraph")
        ) else {
            return XCTFail("A browser request cannot be relabelled as trusted manual UI")
        }
    }

    func testAutomaticCounterResetsAtLocalDayBoundary() throws {
        let suite = "NativeReservationDayBoundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", calendar: calendar,
            directoryURL: directory, now: { clock.now() }
        )
        guard case .reserved(let firstDay) = store.reserve(
            dailyLimit: 1, leaseDuration: 60, metadata: automaticMetadata()
        ) else { return XCTFail("Expected day-one reservation") }
        XCTAssertTrue(firstDay.beginProviderAttempt())
        XCTAssertTrue(firstDay.fail(outcome: "providerNetworkFailed"))
        XCTAssertEqual(store.automaticCallsToday(), 1)

        clock.advance(by: 86_400)
        XCTAssertEqual(store.automaticCallsToday(), 0)
        guard case .reserved(let nextDay) = store.reserve(
            dailyLimit: 1, leaseDuration: 60,
            metadata: automaticMetadata(source: .nativeInline)
        ) else { return XCTFail("Yesterday's calls must not consume today's cap") }
        nextDay.cancel()
    }

    @MainActor
    func testExplicitCleanupRepairsExpiredLeaseWithoutRetainingBrowserIdentity() throws {
        let suite = "NativeReservationLaunchCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeanNativeReservationTests-\(UUID().uuidString)", isDirectory: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let metadata = AutomaticCallMetadata(
            source: .webInline, appName: "sensitive.example",
            appBundleIdentifier: nil, appCategory: "browser",
            action: "detectIssues", inputMode: "contenteditable", inputLength: 50,
            provider: "test-provider", model: "test-model"
        )
        let store = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage",
            historyStorageKey: "history", directoryURL: directory,
            now: { clock.now() }
        )
        guard case .reserved(let abandoned) = store.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: metadata
        ) else { return XCTFail("Expected a reservation") }
        XCTAssertTrue(abandoned.beginProviderAttempt())
        clock.advance(by: 61)

        XCTAssertTrue(store.cleanupStaleReservations())
        let history = OperationHistoryStore(
            defaults: defaults, storageKey: "history", coordinationDirectoryURL: directory
        )
        XCTAssertEqual(history.records.first?.outcome, "providerAttemptExpired")
        XCTAssertNil(history.records.first?.appName)
        XCTAssertEqual(history.records.first?.inputMode, "browser")
        let state = try String(
            contentsOf: directory.appendingPathComponent("automatic-call-reservations.json"),
            encoding: .utf8
        )
        XCTAssertFalse(state.contains("sensitive.example"))
        XCTAssertFalse(state.contains("contenteditable"))
        abandoned.cancel()
    }
}
