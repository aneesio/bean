import Foundation
import XCTest
@testable import Bean

@MainActor
final class DictionaryLearningServiceTests: XCTestCase {
    func testTermValidationIsBoundedToOneSpellingToken() {
        for term in ["Quorvio", "O’Keefe", "check-in", "cafe\u{301}", "réunion"] {
            XCTAssertNotNil(DictionaryLearningService.validatedTerm(term), term)
        }
        for term in ["", "two words", "https://example.org", "term\nparagraph", "--flag", "#name",
                     "$(command)", "word123", String(repeating: "x", count: 97)] {
            XCTAssertNil(DictionaryLearningService.validatedTerm(term), term)
        }
    }

    func testUnavailableGUIHasNoFileFallback() async {
        let endpoint = "com.bean.tests.dictionary.absent.\(UUID().uuidString)"
        XCTAssertFalse(DictionaryLearningService.isAvailable(endpointName: endpoint))
        let result = await DictionaryLearningService.learn("Quorvio", endpointName: endpoint)
        XCTAssertEqual(result, .unavailable)
    }

    func testGUIAcknowledgesSavedTermAndProtectsLiveStoreDuringLaterEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bean-dictionary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UserContentStore(fileURL: folder.appendingPathComponent("userContent.json"))
        let endpoint = "com.bean.tests.dictionary.\(UUID().uuidString)"
        let service = DictionaryLearningService(userContent: store, endpointName: endpoint)
        defer { service.stop() }
        XCTAssertTrue(DictionaryLearningService.isAvailable(endpointName: endpoint))
        let learned = await DictionaryLearningService.learn("Quorvio", endpointName: endpoint)
        XCTAssertEqual(learned, .saved)
        let repeated = await DictionaryLearningService.learn("Quorvio", endpointName: endpoint)
        XCTAssertEqual(repeated, .saved)
        XCTAssertEqual(store.dictionary.map(\.term), ["Quorvio"])
        // A subsequent GUI mutation must retain the same authoritative delta.
        _ = store.upsert(DictionaryTerm(term: "Anotherword"))
        let reopened = UserContentStore(fileURL: folder.appendingPathComponent("userContent.json"))
        XCTAssertEqual(Set(reopened.dictionary.map(\.term)), ["Quorvio", "Anotherword"])
    }

    func testGUIDoesNotCelebrateAFailedPersistenceWrite() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bean-dictionary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UserContentStore(fileURL: folder.appendingPathComponent("userContent.json"), atomicWrite: { _,_ in
            throw NSError(domain: "DictionaryLearningTest", code: 1)
        })
        let endpoint = "com.bean.tests.dictionary.failure.\(UUID().uuidString)"
        let service = DictionaryLearningService(userContent: store, endpointName: endpoint)
        defer { service.stop() }
        let result = await DictionaryLearningService.learn("Quorvio", endpointName: endpoint)
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(store.dictionary.isEmpty)
    }
}

@MainActor
final class NativeDictionaryProtocolTests: XCTestCase {
    private let status = NativeHostStatusConfiguration(providerConfigured: false, webInlineEnabled: false,
        timeout: 5, dailyAutomaticCallLimit: 1, automaticCallsToday: nil)

    private func response(type: String, text: String? = nil, status: NativeHostStatusConfiguration? = nil,
                          dictionary: NativeHostDictionaryConfiguration? = nil,
                          local: NativeHostLocalCheckConfiguration? = nil) async throws -> [String: Any] {
        var request: [String: Any] = ["id": "dictionary-protocol-test", "type": type,
            "protocolVersion": 1, "extensionVersion": "0.8.0", "minimumAppVersion": "1.6.0"]
        if let text { request["text"] = text }
        let result = await NativeMessagingHost.processAsync(try JSONSerialization.data(withJSONObject: request),
            statusConfiguration: status ?? self.status, localCheckConfiguration: local,
            dictionaryConfiguration: dictionary)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
    }

    func testLearnAcknowledgesOnlyPersistedOrAlreadySavedWords() async throws {
        var calls = 0
        let available = NativeHostDictionaryConfiguration(available: true, learner: { term in
            XCTAssertEqual(term, "Quorvio")
            calls += 1
            return .saved
        })
        let saved = try await response(type: "learnDictionaryTerm", text: "Quorvio", dictionary: available)
        XCTAssertEqual(saved["ok"] as? Bool, true)
        XCTAssertEqual(saved["learnedTerm"] as? String, "Quorvio")
        XCTAssertEqual(calls, 1)
        let invalid = try await response(type: "learnDictionaryTerm", text: "two words", dictionary: available)
        XCTAssertEqual(invalid["errorCode"] as? String, "invalidDictionaryTerm")
        XCTAssertEqual(calls, 1)
        let unavailable = try await response(type: "learnDictionaryTerm", text: "Quorvio",
            dictionary: .init(available: false, learner: { _ in XCTFail("Unavailable writer must not run"); return .saved }))
        XCTAssertEqual(unavailable["errorCode"] as? String, "dictionaryUnavailable")
        let failed = try await response(type: "learnDictionaryTerm", text: "Quorvio",
            dictionary: .init(available: true, learner: { _ in .failed }))
        XCTAssertEqual(failed["errorCode"] as? String, "dictionarySaveFailed")
    }

    func testStatusUsesInjectedCapabilitiesWithoutReadingLiveWriter() async throws {
        let object = try await response(type: "getStatus", dictionary: .init(available: false, learner: { _ in .saved }))
        XCTAssertEqual(object["learnWordAvailable"] as? Bool, false)
        XCTAssertEqual(object["appAssistancePaused"] as? Bool, false)
    }

    func testPausedAppRejectsAutomaticLocalAndProviderMessagesBeforeChecking() async throws {
        var paused = status
        paused.appAssistancePaused = true
        for type in ["localCheck", "detectIssues", "proofreadParagraph"] {
            let object = try await response(type: type, text: "Please recieve it.", status: paused,
                local: .init(dictionary: [], includeSystemChecker: false))
            XCTAssertEqual(object["errorCode"] as? String, "appPaused", type)
            XCTAssertNil(object["issues"])
        }
        let object = try await response(type: "getStatus", status: paused,
            dictionary: .init(available: false, learner: { _ in .saved }))
        XCTAssertEqual(object["appAssistancePaused"] as? Bool, true)
    }

    func testCoverageAndProtectedRangesAreBoundToExactSubmittedText() async throws {
        let text = "👩🏽‍💻 Quorvio and teh. https://example.org/teh"
        let object = try await response(type: "localCheck", text: text,
            local: .init(dictionary: [DictionaryTerm(term: "Quorvio")], includeSystemChecker: false))
        XCTAssertEqual(object["localCheckComplete"] as? Bool, true)
        XCTAssertEqual(object["spellingCoverage"] as? String, "notRequested")
        let ranges = try XCTUnwrap(object["protectedRanges"] as? [[String: Int]])
        let fragments = ranges.compactMap { range -> String? in
            guard let start=range["start"], let end=range["end"] else { return nil }
            return (text as NSString).substring(with: NSRange(location: start, length: end-start))
        }
        XCTAssertTrue(fragments.contains("Quorvio"))
        XCTAssertTrue(fragments.contains("https://example.org/teh"))
        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.compactMap { $0["original"] as? String }, ["teh"])
    }

    func testProtectionUnionIncludesDictionaryTermsAfterHundredsOfProtectedSpans() async throws {
        let text = (0..<300).map { "`code\($0)`" }.joined(separator: " ") + " teh Quorvio"
        let object = try await response(type: "localCheck", text: text,
            local: .init(dictionary: [DictionaryTerm(term: "teh"), DictionaryTerm(term: "Quorvio")], includeSystemChecker: false))
        let ranges = try XCTUnwrap(object["protectedRanges"] as? [[String: Int]])
        XCTAssertGreaterThan(ranges.count, 256)
        let expected = (text as NSString).range(of: "teh", options: .backwards)
        XCTAssertTrue(ranges.contains { $0["start"] == expected.location && $0["end"] == NSMaxRange(expected) })
        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        XCTAssertTrue(issues.isEmpty)
    }

    func testProtectionUnionMergesOverlapsAndRejectsInvalidRanges() {
        XCTAssertEqual(NativeMessagingHost.mergedProtectedRanges([
            NSRange(location: 8, length: 2), NSRange(location: 2, length: 4),
            NSRange(location: 4, length: 4), NSRange(location: 0, length: 1),
            NSRange(location: NSNotFound, length: 1), NSRange(location: 5, length: 100)
        ], sourceLength: 10), [NSRange(location: 0, length: 1), NSRange(location: 2, length: 8)])
    }

    func testPauseTimestampsRespectResumeAndExpiryInIsolatedDefaults() {
        let suite = "bean.dictionary-pause-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now=Date(timeIntervalSince1970: 1_000)
        defaults.set(["com.google.Chrome": 1_001.0, "com.apple.Safari": -1.0], forKey: "assistancePausedApps")
        XCTAssertTrue(NativeMessagingHost.assistancePaused(defaults: defaults, bundleIdentifier: "com.google.Chrome", now: now))
        XCTAssertFalse(NativeMessagingHost.assistancePaused(defaults: defaults, bundleIdentifier: "com.google.Chrome", now: now.addingTimeInterval(2)))
        XCTAssertTrue(NativeMessagingHost.assistancePaused(defaults: defaults, bundleIdentifier: "com.apple.Safari", now: now))
        XCTAssertFalse(NativeMessagingHost.assistancePaused(defaults: defaults, bundleIdentifier: "unknown", now: now))
    }
}
