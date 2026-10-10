import AppKit
import XCTest
@testable import Bean

final class NativeLocalCheckTests: XCTestCase {
    private func response(text: String, type: String = "localCheck",
                          maximumIssues: Int = 32,
                          dictionary: [DictionaryTerm] = [],
                          systemChecker: Bool = false,
                          protocolVersion: Int = 1,
                          action: String? = nil) async throws -> [String: Any] {
        var request: [String: Any] = [
            "id": "local-spelling-test", "type": type,
            "protocolVersion": protocolVersion, "extensionVersion": "0.7.2",
            "minimumAppVersion": "1.6.0", "text": text,
            "settings": ["maxIssues": maximumIssues]
        ]
        if let action { request["action"] = action }
        let unavailableAI = NativeHostStatusConfiguration(
            providerConfigured: false, webInlineEnabled: false, timeout: 5,
            dailyAutomaticCallLimit: 1, automaticCallsToday: nil
        )
        let data = await NativeMessagingHost.processAsync(
            try JSONSerialization.data(withJSONObject: request), statusConfiguration: unavailableAI,
            localCheckConfiguration: NativeHostLocalCheckConfiguration(
                dictionary: dictionary, includeSystemChecker: systemChecker
            )
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLocalChecksWorkWithNoProviderConsentKeyOrPaidAccounting() async throws {
        let object = try await response(text: "Please fix teh  sentence.")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["id"] as? String, "local-spelling-test")
        XCTAssertEqual(object["localSpellingAvailable"] as? Bool, false)
        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        XCTAssertEqual(Set(issues.compactMap { $0["original"] as? String }), ["teh", "  "])
        XCTAssertNil(object["errorCode"])
    }

    func testLocalOffsetsPreserveRepeatedOccurrencesAndUTF16Emoji() async throws {
        let text = "👩🏽‍💻 Please fix teh and teh words."
        let object = try await response(text: text)
        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        let typos = issues.filter { $0["original"] as? String == "teh" }
        XCTAssertEqual(typos.count, 2)
        XCTAssertEqual(Set(typos.compactMap { $0["start"] as? Int }).count, 2)
        for issue in issues {
            let start = try XCTUnwrap(issue["start"] as? Int)
            let end = try XCTUnwrap(issue["end"] as? Int)
            XCTAssertEqual(issue["location"] as? Int, start)
            XCTAssertEqual(issue["length"] as? Int, end - start)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: start, length: end - start)),
                           issue["original"] as? String)
            XCTAssertEqual(issue["source"] as? String, "local")
        }
    }

    func testLocalChecksPreserveDictionaryPhrasesLinksFilesAndCode() async throws {
        let text = "We use teh Pro; https://teh.example/recieve and teh.swift and `recieve_value`. Please recieve it."
        let object = try await response(text: text, dictionary: [DictionaryTerm(term: "teh Pro")])
        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?["original"] as? String, "recieve")
        XCTAssertEqual(issues.first?["start"] as? Int, (text as NSString).range(of: "recieve", options: .backwards).location)
    }

    func testLocalChecksEnforceBoundsAndBridgeCompatibilityBeforeDictionaryRead() async throws {
        let oversized = try await response(text: String(repeating: "a", count: 8_001))
        XCTAssertEqual(oversized["ok"] as? Bool, false)
        XCTAssertEqual(oversized["errorCode"] as? String, "textTooLong")
        let unicodeOversized = try await response(text: String(repeating: "e\u{301}", count: 32_001))
        XCTAssertEqual(unicodeOversized["errorCode"] as? String, "textTooLong")
        let incompatible = try await response(text: "teh", protocolVersion: 2)
        XCTAssertEqual(incompatible["errorCode"] as? String, "protocolMismatch")
    }

    func testLocalCheckCapsRequestedIssuesWithoutHidingValidRangeMetadata() async throws {
        let object = try await response(text: "teh recieve tomorow", maximumIssues: 1)
        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.count, 1)
        XCTAssertNotNil(issues.first?["start"])
        XCTAssertNotNil(issues.first?["end"])
    }

    func testExplicitBrowserActionsCannotInvokeGenerativeRepliesOrArbitraryTasks() async throws {
        XCTAssertEqual(NativeMessagingHost.explicitBrowserAction("proofread"), .proofread)
        XCTAssertEqual(NativeMessagingHost.explicitBrowserAction("makeClearer"), .makeClearer)
        XCTAssertEqual(NativeMessagingHost.explicitBrowserAction("rewriteFriendly"), .makeCasual)
        XCTAssertEqual(NativeMessagingHost.explicitBrowserAction("rewriteProfessional"), .makeProfessional)
        XCTAssertEqual(NativeMessagingHost.explicitBrowserAction("rewriteConcise"), .makeConcise)
        XCTAssertNil(NativeMessagingHost.explicitBrowserAction("draftReply"))
        XCTAssertNil(NativeMessagingHost.explicitBrowserAction("composeMessage"))
        let unsupported = try await response(text: "A normal sentence.", type: "performAction", action: "draftReply")
        XCTAssertEqual(unsupported["errorCode"] as? String, "unsupportedAction")
        XCTAssertNil(unsupported["text"])
        let oversized = try await response(text: String(repeating: "a", count: 8_001),
                                           type: "performAction", action: "proofread")
        XCTAssertEqual(oversized["errorCode"] as? String, "textTooLong")
        let empty = try await response(text: "", type: "performAction", action: "makeClearer")
        XCTAssertEqual(empty["errorCode"] as? String, "emptyText")
    }

    func testStatusAdvertisesOfflineAndExplicitActionsWithoutRequiringAutomaticAI() async throws {
        let object = try await response(text: "", type: "getStatus")
        XCTAssertEqual(object["localCheckAvailable"] as? Bool, true)
        XCTAssertEqual(object["performActionAvailable"] as? Bool, true)
        XCTAssertEqual(object["providerConfigured"] as? Bool, false)
        XCTAssertEqual(object["webInlineEnabled"] as? Bool, false)
        XCTAssertEqual(object["automaticAccountingAvailable"] as? Bool, false)
    }

    func testOneActionBrowserTransformPreservesOriginalOuterLayoutAndQuotedText() {
        let original = " \nPlease fix teh draft.\n\n"
        XCTAssertEqual(NativeMessagingHost.sanitizedBrowserTransformation(
            "<bean_output>Please fix the draft.</bean_output>", original: original
        ), " \nPlease fix the draft.\n\n")
        XCTAssertEqual(NativeMessagingHost.sanitizedBrowserTransformation(
            "\"Please fix the draft.\"", original: "  \"Please fix teh draft.\"\n"
        ), "  \"Please fix the draft.\"\n")
    }

    @MainActor
    func testMacSpellingChecksTheActualGmailSentenceAndUnlistedMisspellings() async throws {
        guard NativeMessagingHost.localSpellingIsAvailable() else {
            throw XCTSkip("macOS spelling service is unavailable in this test environment; verify the native host in Chrome.")
        }
        XCTAssertNil(LocalTypoCorrector.correction(for: "tme"))
        XCTAssertNil(LocalTypoCorrector.correction(for: "misspeling"))
        let text = "okay lets see if it works in the email this tme. There is another misspeling."
        let object = try await response(text: text, systemChecker: true)
        XCTAssertEqual(object["localSpellingAvailable"] as? Bool, true)
        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains { $0["original"] as? String == "tme" })
        XCTAssertEqual(issues.first(where: { $0["original"] as? String == "tme" })?["suggestion"] as? String, "time")
        XCTAssertTrue(issues.contains { $0["original"] as? String == "misspeling" })
        for issue in issues {
            let start = try XCTUnwrap(issue["start"] as? Int)
            let length = try XCTUnwrap(issue["length"] as? Int)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: start, length: length)),
                           issue["original"] as? String)
        }
    }
}
