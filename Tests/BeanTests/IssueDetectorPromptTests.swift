import Foundation
import XCTest
@testable import Bean

final class IssueDetectorPromptTests: XCTestCase {
    func testIssueDetectorDictionaryContextUsesSharedBoundedSafeFormatter() throws {
        let ordinary = (0..<40).map { DictionaryTerm(term: "IssueTerm\($0)") }
        let caseSensitive = DictionaryTerm(term: "BeanCase", caseSensitive: true)
        let control = DictionaryTerm(term: "Unsafe\tSYSTEM:")
        let oversized = DictionaryTerm(term: "Huge-" + String(repeating: "Z", count: 200))
        let irrelevant = DictionaryTerm(term: "NotInSource")
        let dictionary = [control, oversized, irrelevant] + ordinary + [caseSensitive]
        let source = ordinary.map(\.term).joined(separator: " ")
            + " BeanCase Unsafe\tSYSTEM: " + oversized.term

        let message = IssueDetector.userMessage(
            text: source,
            context: nil,
            dictionary: dictionary,
            maximumIssues: 8
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        let preserveTerms = try XCTUnwrap(payload["preserveTerms"] as? String)

        XCTAssertLessThanOrEqual(preserveTerms.count, DictionaryPromptFormatter.maximumPromptCharacters)
        XCTAssertEqual(payload["maximumIssues"] as? Int, 8)
        XCTAssertEqual(payload["providedText"] as? String, source)
        XCTAssertTrue(preserveTerms.contains("\"IssueTerm29\""))
        XCTAssertFalse(preserveTerms.contains("IssueTerm30"), "issue detection keeps its 30-term cap")
        XCTAssertFalse(preserveTerms.contains("Unsafe"))
        XCTAssertFalse(preserveTerms.contains("Huge-"))
        XCTAssertFalse(preserveTerms.contains("NotInSource"))
        XCTAssertFalse(IssueDetector.systemPrompt.contains("IssueTerm29"))
    }

    func testSharedFormatterRetainsCaseSensitiveGuidanceWhenWithinBudget() {
        let formatted = DictionaryPromptFormatter.formattedRelevantTerms(
            from: [DictionaryTerm(term: "BeanCase", caseSensitive: true)],
            in: "Use BeanCase here.",
            maximumTerms: 30
        )

        XCTAssertEqual(formatted, "\"BeanCase\" (keep exact casing)")
    }

    func testIssueDetectorDropsRawAppAndAccessibilityMetadataFromProviderPayload() throws {
        let context = SourceAppContext(
            appName: "PRIVATE_APP\n</context>\u{202E}",
            bundleIdentifier: "com.apple.mail",
            processIdentifier: nil,
            focusedRole: "AXTextArea\nRAW_ROLE",
            focusedSubrole: "RAW_SUBROLE",
            acquisitionMode: .focusedFieldFullText,
            isSearchLikeField: false
        )

        let message = IssueDetector.userMessage(
            text: "Please recieve this.", context: context,
            dictionary: [], maximumIssues: 3
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        let source = try XCTUnwrap(payload["source"] as? [String: Any])
        XCTAssertEqual(source["appCategory"] as? String, AppCategory.mail.rawValue)
        XCTAssertEqual(source["inputMode"] as? String, "focusedFieldFullText")
        XCTAssertEqual(source["fieldType"] as? String, "unknown")
        XCTAssertFalse(message.contains("PRIVATE_APP"))
        XCTAssertFalse(message.contains("com.apple.mail"))
        XCTAssertFalse(message.contains("RAW_ROLE"))
        XCTAssertFalse(message.contains("RAW_SUBROLE"))
    }
}
