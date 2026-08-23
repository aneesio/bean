import XCTest
@testable import Bean

final class OperationHistoryStoreTests: XCTestCase {
    @MainActor
    func testHistoryIsBoundedNewestFirstAndPersists() throws {
        let suite = "OperationHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("OperationHistoryBounded")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )

        for index in 0..<(OperationHistoryStore.maximumRecords + 7) {
            store.record(makeRecord(action: "action\(index)"))
        }

        XCTAssertEqual(store.records.count, OperationHistoryStore.maximumRecords)
        XCTAssertEqual(store.records.first?.action, "action56")
        XCTAssertEqual(store.records.last?.action, "action7")

        let reloaded = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(reloaded.records, store.records)
    }

    @MainActor
    func testEncodedHistoryContainsNoUserTextFieldsOrSentinelContent() throws {
        let suite = "OperationHistoryStorePrivacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("OperationHistoryPrivacy")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        store.record(makeRecord(action: "proofread"))

        let data = try XCTUnwrap(defaults.data(forKey: "history"))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("sourceText"))
        XCTAssertFalse(encoded.contains("transformedText"))
        XCTAssertFalse(encoded.contains("prompt"))
        XCTAssertFalse(encoded.contains("clipboard"))
        XCTAssertFalse(encoded.contains("PRIVATE_SENTINEL"))
    }

    @MainActor
    func testClearRemovesPersistedHistory() throws {
        let suite = "OperationHistoryStoreClearTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("OperationHistoryClear")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        store.record(makeRecord(action: "proofread"))

        store.clear()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: "history"))
    }

    @MainActor
    func testBrowserRecordsNeverPersistHostnameOrFieldSemantics() throws {
        let suite = "OperationHistoryStoreBrowserPrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("OperationHistoryBrowserPrivacy")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        store.record(OperationRecord(
            source: .webInline,
            appName: "sensitive.example",
            appBundleIdentifier: "forbidden.field",
            appCategory: "private-category",
            action: "detectIssues",
            inputMode: "contenteditable-secret",
            inputLength: 12,
            provider: "openai",
            model: "test-model",
            outcome: "issuesReturned"
        ))

        XCTAssertNil(store.records.first?.appName)
        XCTAssertNil(store.records.first?.appBundleIdentifier)
        XCTAssertEqual(store.records.first?.appCategory, "browser")
        XCTAssertEqual(store.records.first?.inputMode, "browser")
        let data = try XCTUnwrap(defaults.data(forKey: "history"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("sensitive.example"))
        XCTAssertFalse(json.contains("forbidden.field"))
        XCTAssertFalse(json.contains("contenteditable-secret"))
    }

    @MainActor
    func testUnavailableSharedLockNeverRewritesRecordsOrClearsPersistedHistory() throws {
        let suite = "OperationHistoryStoreUnavailableLock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = temporaryCoordinationDirectory("OperationHistoryUnavailableLock")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let seeded = (0...OperationHistoryStore.maximumRecords).map {
            makeRecord(action: "seed\($0)")
        }
        let seededData = try JSONEncoder().encode(seeded)
        defaults.set(seededData, forKey: "history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("automatic-call-reservations.lock"),
            withIntermediateDirectories: false
        )

        let store = OperationHistoryStore(
            defaults: defaults, storageKey: "history",
            coordinationDirectoryURL: directory
        )
        XCTAssertEqual(store.records.count, OperationHistoryStore.maximumRecords)
        XCTAssertEqual(defaults.data(forKey: "history"), seededData,
                       "Read-only fallback must not persist its bounded snapshot")

        let inMemorySnapshot = store.records
        store.record(makeRecord(action: "must-not-persist"))
        store.clear()

        XCTAssertEqual(store.records, inMemorySnapshot)
        XCTAssertEqual(defaults.data(forKey: "history"), seededData)
    }

    private func temporaryCoordinationDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeRecord(action: String) -> OperationRecord {
        OperationRecord(
            source: .manual,
            appName: "TextEdit",
            appBundleIdentifier: "com.apple.TextEdit",
            appCategory: "unknown",
            action: action,
            inputMode: "selectedText",
            inputLength: 12,
            outputLength: 13,
            provider: "openai",
            model: "test-model",
            durationMilliseconds: 50,
            safetyResult: "ok",
            outcome: "replacedConfirmed"
        )
    }
}
