import XCTest
@testable import Bean

final class OperationHistoryStoreTests: XCTestCase {
    @MainActor
    func testHistoryIsBoundedNewestFirstAndPersists() throws {
        let suite = "OperationHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OperationHistoryStore(defaults: defaults, storageKey: "history")

        for index in 0..<(OperationHistoryStore.maximumRecords + 7) {
            store.record(makeRecord(action: "action\(index)"))
        }

        XCTAssertEqual(store.records.count, OperationHistoryStore.maximumRecords)
        XCTAssertEqual(store.records.first?.action, "action56")
        XCTAssertEqual(store.records.last?.action, "action7")

        let reloaded = OperationHistoryStore(defaults: defaults, storageKey: "history")
        XCTAssertEqual(reloaded.records, store.records)
    }

    @MainActor
    func testEncodedHistoryContainsNoUserTextFieldsOrSentinelContent() throws {
        let suite = "OperationHistoryStorePrivacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OperationHistoryStore(defaults: defaults, storageKey: "history")
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
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OperationHistoryStore(defaults: defaults, storageKey: "history")
        store.record(makeRecord(action: "proofread"))

        store.clear()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: "history"))
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
