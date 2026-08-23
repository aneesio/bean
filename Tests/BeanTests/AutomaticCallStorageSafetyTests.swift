import Foundation
import XCTest
@testable import Bean

final class AutomaticCallStorageSafetyTests: XCTestCase {
    private func metadata() -> AutomaticCallMetadata {
        AutomaticCallMetadata(
            source: .nativeInline,
            appName: "Test App",
            appBundleIdentifier: "com.bean.test",
            appCategory: "docs",
            action: "detectIssues",
            inputMode: "focusedFieldFullText",
            inputLength: 12,
            provider: "test-provider",
            model: "test-model"
        )
    }

    func testLockDirectoryAndStateSymlinksNeverReachExternalSentinels() throws {
        let suite = "AutomaticCallSymlinkSafety.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticCallSymlinkSafety-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(try JSONEncoder().encode([DailyUsageBucket]()), forKey: "usage")
        defaults.set(try JSONEncoder().encode([OperationRecord]()), forKey: "history")

        let externalLock = root.appendingPathComponent("external-lock-sentinel")
        try Data("LOCK-SENTINEL".utf8).write(to: externalLock)
        let lockDirectory = root.appendingPathComponent("lock-case", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: lockDirectory.appendingPathComponent("automatic-call-reservations.lock"),
            withDestinationURL: externalLock
        )
        let lockStore = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            directoryURL: lockDirectory
        )
        guard case .unavailable = lockStore.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: metadata()
        ) else { return XCTFail("A symlinked lock must fail closed") }
        XCTAssertEqual(try String(contentsOf: externalLock, encoding: .utf8), "LOCK-SENTINEL")

        let externalState = root.appendingPathComponent("external-state-sentinel")
        try Data("STATE-SENTINEL".utf8).write(to: externalState)
        let stateDirectory = root.appendingPathComponent("state-case", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let stateURL = stateDirectory.appendingPathComponent("automatic-call-reservations.json")
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: externalState)
        let stateStore = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            directoryURL: stateDirectory
        )
        XCTAssertNil(stateStore.automaticCallsToday())
        let reset = stateStore.resetAllAccounting()
        XCTAssertFalse(reset.privateStateRemoved)
        XCTAssertTrue(reset.visibleUsageRemoved)
        XCTAssertTrue(reset.visibleHistoryRemoved)
        XCTAssertEqual(try String(contentsOf: externalState, encoding: .utf8), "STATE-SENTINEL")
        let stateAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        XCTAssertEqual(stateAttributes[.type] as? FileAttributeType, .typeSymbolicLink)

        let externalDirectory = root.appendingPathComponent("external-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let externalDirectorySentinel = externalDirectory.appendingPathComponent("keep.txt")
        try Data("DIRECTORY-SENTINEL".utf8).write(to: externalDirectorySentinel)
        let redirectedDirectory = root.appendingPathComponent("redirected-store", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: redirectedDirectory,
            withDestinationURL: externalDirectory
        )
        let redirectedStore = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            directoryURL: redirectedDirectory
        )
        guard case .unavailable = redirectedStore.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: metadata()
        ) else { return XCTFail("A symlinked storage directory must fail closed") }
        XCTAssertEqual(
            try String(contentsOf: externalDirectorySentinel, encoding: .utf8),
            "DIRECTORY-SENTINEL"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: externalDirectory.appendingPathComponent(
                "automatic-call-reservations.lock"
            ).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: externalDirectory.appendingPathComponent(
                "automatic-call-reservations.json"
            ).path
        ))
    }

    func testNonRegularLockAndStateTargetsFailClosed() throws {
        let suite = "AutomaticCallNonRegularSafety.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticCallNonRegularSafety-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let lockDirectory = root.appendingPathComponent("lock", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockDirectory.appendingPathComponent("automatic-call-reservations.lock"),
            withIntermediateDirectories: true
        )
        let lockStore = AutomaticCallBudgetStore(defaults: defaults, directoryURL: lockDirectory)
        guard case .unavailable = lockStore.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: metadata()
        ) else { return XCTFail("A directory at the lock filename must fail closed") }

        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("automatic-call-reservations.json"),
            withIntermediateDirectories: true
        )
        let stateStore = AutomaticCallBudgetStore(defaults: defaults, directoryURL: stateDirectory)
        XCTAssertNil(stateStore.automaticCallsToday())
        XCTAssertFalse(stateStore.resetAllAccounting().privateStateRemoved)
    }

    func testHardLinkedLockAndStateTargetsFailClosedWithoutChangingExternalFiles() throws {
        let suite = "AutomaticCallHardLinkSafety.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AutomaticCallHardLinkSafety-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let externalLock = root.appendingPathComponent("external-lock-sentinel")
        try Data("LOCK-HARDLINK-SENTINEL".utf8).write(to: externalLock)
        let lockDirectory = root.appendingPathComponent("lock-case", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: externalLock,
            to: lockDirectory.appendingPathComponent("automatic-call-reservations.lock")
        )
        let lockStore = AutomaticCallBudgetStore(defaults: defaults, directoryURL: lockDirectory)
        guard case .unavailable = lockStore.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: metadata()
        ) else { return XCTFail("A hard-linked lock must fail closed") }
        XCTAssertEqual(
            try String(contentsOf: externalLock, encoding: .utf8),
            "LOCK-HARDLINK-SENTINEL"
        )

        let externalState = root.appendingPathComponent("external-state-sentinel")
        try Data("STATE-HARDLINK-SENTINEL".utf8).write(to: externalState)
        let stateDirectory = root.appendingPathComponent("state-case", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: externalState,
            to: stateDirectory.appendingPathComponent("automatic-call-reservations.json")
        )
        let stateStore = AutomaticCallBudgetStore(defaults: defaults, directoryURL: stateDirectory)
        XCTAssertNil(stateStore.automaticCallsToday())
        XCTAssertFalse(stateStore.resetAllAccounting().privateStateRemoved)
        XCTAssertEqual(
            try String(contentsOf: externalState, encoding: .utf8),
            "STATE-HARDLINK-SENTINEL"
        )
    }

    func testStructuredResetReportsPrivateRemovalBeforeVisibleDefaultsFailure() throws {
        let suite = "AutomaticCallPartialReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticCallPartialReset-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let initialStore = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            directoryURL: directory
        )
        XCTAssertTrue(
            BeanCrossProcessStoreLock(directoryURL: directory).withExclusiveLock { true },
            "a normal isolated directory must support the no-follow lock"
        )
        guard case .reserved(let reservation) = initialStore.reserve(
            dailyLimit: 2, leaseDuration: 60, metadata: metadata()
        ) else { return XCTFail("Expected state creation") }
        defaults.set(Data("usage-must-remain".utf8), forKey: "usage")
        defaults.set(Data("history-must-clear".utf8), forKey: "history")
        defaults.set("keep", forKey: "unrelated")

        let partialStore = AutomaticCallBudgetStore(
            defaults: defaults, usageStorageKey: "usage", historyStorageKey: "history",
            directoryURL: directory,
            removeDefaultsValue: { key in
                if key == "history" { defaults.removeObject(forKey: key) }
            }
        )
        let result = partialStore.resetAllAccounting()

        XCTAssertTrue(result.privateStateRemoved)
        XCTAssertFalse(result.visibleUsageRemoved)
        XCTAssertTrue(result.visibleHistoryRemoved)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(defaults.data(forKey: "usage"), Data("usage-must-remain".utf8))
        XCTAssertNil(defaults.object(forKey: "history"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "automatic-call-reservations.json"
            ).path
        ))
        reservation.cancel()
    }

    func testNormalReservationPersistsAcrossFreshStoresAndSystemTempAliases() throws {
        let suite = "AutomaticCallPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AutomaticCallPersistence-\(UUID().uuidString)",
                isDirectory: true
            )
        let originalPath = originalDirectory.standardizedFileURL.path
        let canonicalDirectory: URL
        if originalPath == "/var" || originalPath.hasPrefix("/var/") {
            canonicalDirectory = URL(
                fileURLWithPath: "/private" + originalPath,
                isDirectory: true
            )
        } else if originalPath == "/tmp" || originalPath.hasPrefix("/tmp/") {
            canonicalDirectory = URL(
                fileURLWithPath: "/private/tmp" + String(originalPath.dropFirst(4)),
                isDirectory: true
            )
        } else {
            canonicalDirectory = originalDirectory
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: canonicalDirectory)
        }

        let firstStore = AutomaticCallBudgetStore(
            defaults: defaults,
            usageStorageKey: "usage",
            historyStorageKey: "history",
            directoryURL: originalDirectory
        )
        guard case .reserved(let reservation) = firstStore.reserve(
            dailyLimit: 1,
            leaseDuration: 60,
            metadata: metadata()
        ) else { return XCTFail("Expected the first isolated reservation to succeed") }
        XCTAssertTrue(reservation.beginProviderAttempt())

        // A new store using the canonical spelling must read the durable state
        // written through Foundation's `/var` or `/tmp` spelling.
        let secondStore = AutomaticCallBudgetStore(
            defaults: defaults,
            usageStorageKey: "usage",
            historyStorageKey: "history",
            directoryURL: canonicalDirectory
        )
        XCTAssertEqual(secondStore.automaticCallsToday(), 1)
        guard case .limitReached = secondStore.reserve(
            dailyLimit: 1,
            leaseDuration: 60,
            metadata: metadata()
        ) else { return XCTFail("A fresh store must honor the persisted spent count") }

        XCTAssertTrue(reservation.fail(outcome: "testFailure"))
    }

    @MainActor
    func testDailyLimitPolicyClampsPersistedAndDirectBoundaryValues() throws {
        XCTAssertEqual(AutomaticCallBudgetPolicy.persistedDailyLimit(-1), 20)
        XCTAssertEqual(AutomaticCallBudgetPolicy.persistedDailyLimit(0), 20)
        XCTAssertEqual(AutomaticCallBudgetPolicy.persistedDailyLimit(1), 1)
        XCTAssertEqual(AutomaticCallBudgetPolicy.persistedDailyLimit(201), 200)
        XCTAssertEqual(AutomaticCallBudgetPolicy.persistedDailyLimit(Int.max), 200)
        XCTAssertEqual(AutomaticCallBudgetPolicy.requestedDailyLimit(Int.min), 1)
        XCTAssertEqual(AutomaticCallBudgetPolicy.requestedDailyLimit(Int.max), 200)

        let suite = "AutomaticCallLimitPolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AutomaticCallLimitPolicy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(Int.max, forKey: "dailyAutomaticCallLimit")
        let settings = AppSettings(defaults: defaults, readKeychain: { _ in nil })
        XCTAssertEqual(settings.dailyAutomaticCallLimit, 200)
        settings.dailyAutomaticCallLimit = Int.max
        XCTAssertEqual(settings.dailyAutomaticCallLimit, 200)
        XCTAssertEqual(defaults.integer(forKey: "dailyAutomaticCallLimit"), 200)
        settings.dailyAutomaticCallLimit = Int.min
        XCTAssertEqual(settings.dailyAutomaticCallLimit, 1)
        XCTAssertEqual(defaults.integer(forKey: "dailyAutomaticCallLimit"), 1)

        defaults.set(try JSONEncoder().encode([
            DailyUsageBucket(
                day: Date(), source: .nativeInline,
                provider: "test-provider", model: "test-model",
                inputTokens: 0, outputTokens: 0,
                operationCount: 200, estimatedOperationCount: 0
            )
        ]), forKey: "usage")
        defaults.set(try JSONEncoder().encode([OperationRecord]()), forKey: "history")
        let store = AutomaticCallBudgetStore(
            defaults: defaults,
            usageStorageKey: "usage",
            historyStorageKey: "history",
            directoryURL: directory
        )
        guard case .limitReached = store.reserve(
            dailyLimit: Int.max,
            leaseDuration: 60,
            metadata: metadata()
        ) else { return XCTFail("The store must enforce the 200-call ceiling") }
    }

    func testAutomaticCleanupPrunesExpiredVisibleUsageFromPersistence() throws {
        let suite = "AutomaticCallUsageRetention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AutomaticCallUsageRetention-\(UUID().uuidString)",
            isDirectory: true
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -121, to: now))
        let boundaryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -120, to: now))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        defaults.set(try JSONEncoder().encode([
            DailyUsageBucket(
                day: oldDay, source: .manual, provider: "old", model: "old",
                inputTokens: 1, outputTokens: 1, operationCount: 1,
                estimatedOperationCount: 0
            ),
            DailyUsageBucket(
                day: boundaryDay, source: .manual, provider: "keep", model: "keep",
                inputTokens: 2, outputTokens: 2, operationCount: 1,
                estimatedOperationCount: 0
            )
        ]), forKey: "usage")
        defaults.set(try JSONEncoder().encode([OperationRecord]()), forKey: "history")
        let store = AutomaticCallBudgetStore(
            defaults: defaults,
            usageStorageKey: "usage",
            historyStorageKey: "history",
            calendar: calendar,
            directoryURL: directory,
            now: { now }
        )

        XCTAssertTrue(store.cleanupStaleReservations())
        let persisted = try JSONDecoder().decode(
            [DailyUsageBucket].self,
            from: try XCTUnwrap(defaults.data(forKey: "usage"))
        )
        XCTAssertEqual(persisted.map(\.provider), ["keep"])
    }
}
