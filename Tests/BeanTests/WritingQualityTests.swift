import Foundation
import XCTest
@testable import Bean

final class WritingQualityTests: XCTestCase {
    func testQuickFixCorrectsAllKnownTyposWithoutTheInlineEightIssueLimit() {
        let source = Array(repeating: "teh test", count: 12).joined(separator: "\n")
        let expected = Array(repeating: "the test", count: 12).joined(separator: "\n")
        XCTAssertEqual(LocalQuickChecker.corrected(source, dictionary: []), expected)
    }

    func testQuickFixNeverAppliesSpeculativeSystemSpellingGuesses() {
        let source = "Meet Anvika at Quorvio for the Kubernetes sync."
        XCTAssertEqual(LocalQuickChecker.corrected(source, dictionary: []), source)
        XCTAssertEqual(LocalQuickChecker.corrected("teh wierd enviroment", dictionary: []),
                       "the weird environment")
    }

    func testQuickFixPreservesStructuredTextAndOnlyCorrectsSurroundingProse() {
        let source = """
        Visit https://teh.example.com/path,Next or email teh@example.com.
        Use teh_file, tehFile, teh2, @teh and #teh; read teh.md.
        `teh  code` and /tmp/teh/file stay as written.
        ```swift
        let teh = "recieve"
        ```
        | teh | adress |
          teh  sentence  here.  
        """
        let expected = source.replacingOccurrences(of: "  teh  sentence  here.  ",
                                                   with: "  the sentence here.  ")
        XCTAssertEqual(LocalQuickChecker.corrected(source, dictionary: []), expected)
    }

    func testSpacingPreservesIndentationTrailingSpacesAndLineBoundaries() {
        let source = "  teh  test  \r\n\tteh  note\u{2028}teh  line\u{2029}last  line"
        let expected = "  the test  \r\n\tthe note\u{2028}the line\u{2029}last line"
        XCTAssertEqual(LocalQuickChecker.corrected(source, dictionary: []), expected)
        XCTAssertTrue(TextBoundarySafety.preservesLineBreakStructure(from: source, to: expected))
    }

    func testSavedPhrasesAndCaseSensitiveTermsAreHonoredLocally() {
        let dictionary = [DictionaryTerm(term: "teh Company"),
                          DictionaryTerm(term: "Teh", caseSensitive: true)]
        XCTAssertEqual(LocalQuickChecker.corrected("TEH COMPANY uses Teh and teh.", dictionary: dictionary),
                       "TEH COMPANY uses Teh and the.")
        XCTAssertEqual(LocalQuickChecker.corrected("teh", dictionary: [DictionaryTerm(term: "he")]), "the")
    }

    func testKnownTyposPreserveConventionalCasingAndSkipMixedCaseNames() {
        XCTAssertEqual(LocalTypoCorrector.correction(for: "TEH"), "THE")
        XCTAssertEqual(LocalTypoCorrector.correction(for: "Teh"), "The")
        XCTAssertNil(LocalTypoCorrector.correction(for: "tEh"))
        XCTAssertNil(LocalTypoCorrector.correction(for: "teH"))
        XCTAssertNil(LocalTypoCorrector.correction(for: "dont"), "French vocabulary is not an obvious English typo")
    }

    func testPunctuationRulesSkipAddressesFilesDecimalsAndAbbreviations() {
        XCTAssertEqual(LocalQuickChecker.corrected(
            "Hello,friend!Next sentence.Next one;then another:yes", dictionary: []),
            "Hello, friend! Next sentence. Next one; then another: yes")
        XCTAssertEqual(LocalQuickChecker.corrected("Recieve,teh message.Teh note", dictionary: []),
                       "Receive, the message. The note")
        XCTAssertEqual(LocalQuickChecker.corrected("你好,朋友。", dictionary: []), "你好,朋友。")
        let source = "Read teh.txt at example.COM. It costs 1.50. Ask J.Smith or visit https://a.dev/x:y."
        XCTAssertEqual(LocalQuickChecker.corrected(source, dictionary: []), source)
    }

    func testLLMCandidatesMustBeUniqueWholeTokensAndPreserveFacts() throws {
        let detector = IssueDetector()
        let source = "The showcase has 12 items."
        let raw = try response([
            candidate("case", "cases"),
            candidate("12", "13"),
            candidate("has", "have", confidence: 0.4),
            candidate("items", "products", type: "clarity"),
            candidate("showcase", "showcases", confidence: 1.1),
            candidate("has 12 items", "has\n12 items"),
            candidate("The", "<bean_output>The</bean_output>"),
            candidate("items.", "items!", type: "punctuation")
        ])
        let mapped = detector.issues(fromModelOutput: raw, in: source)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped.first?.original, "items.")
        XCTAssertTrue(detector.issues(fromModelOutput: try response([candidate("teh", "the")]),
                                      in: "teh and teh").isEmpty)
    }

    func testLLMCandidatesCannotChangeProtectedTermsOrTechnicalTokens() throws {
        let source = "teh Company uses teh_file at https://teh.dev. Please recieve it."
        let raw = try response([candidate("teh Company", "the Company"),
                                candidate("teh_file", "the_file"),
                                candidate("https://teh.dev", "https://the.dev"),
                                candidate("recieve", "receive", type: "spelling")])
        let issues = IssueDetector().issues(fromModelOutput: raw, in: source,
                                            dictionary: [DictionaryTerm(term: "teh Company")])
        XCTAssertEqual(issues.map(\.original), ["recieve"])
    }

    func testStructuredTypesCannotRewriteWordsAndPunctuationMayBeDeleted() throws {
        let raw = try response([candidate("send this", "cancel that", type: "spacing"),
                                candidate("!", "", type: "punctuation")])
        let issues = IssueDetector().issues(fromModelOutput: raw, in: "send this!")
        XCTAssertEqual(issues.map(\.original), ["!"])
        XCTAssertEqual(issues.first?.suggestion, "")
        XCTAssertTrue(IssueDetector().issues(fromModelOutput: try response([candidate(" ", "", type: "spacing")]),
                                             in: "12 34").isEmpty)
        XCTAssertTrue(IssueDetector().issues(fromModelOutput: try response([candidate("-", "", type: "punctuation")]),
                                             in: "12-34").isEmpty)
    }

    func testMalformedResponsesAreNotPartiallyRecoveredAndFencesKeepJSONIntact() throws {
        let detector = IssueDetector()
        let valid = try response([candidate("recieve", "receive", type: "spelling")])
        XCTAssertEqual(detector.issues(fromModelOutput: "```JSON\r\n\(valid)\r\n```", in: "recieve").count, 1)
        for malformed in ["Here are the issues: " + valid, String(valid.dropLast()), "{\"issues\":\(valid)}"] {
            XCTAssertTrue(detector.issues(fromModelOutput: malformed, in: "recieve").isEmpty)
        }
        XCTAssertGreaterThanOrEqual(IssueDetector.outputTokenBudget(maximumIssues: 12), 1_500)
        XCTAssertLessThanOrEqual(IssueDetector.outputTokenBudget(maximumIssues: Int.max), 2_048)
    }

    func testSuggestionMergePrefersDeterministicFixesAndNeverReturnsOverlaps() {
        let local = issue(location: 4, length: 3, source: .local, confidence: 1)
        let guess = issue(location: 4, length: 3, source: .spellchecker, confidence: 0.7)
        let model = issue(location: 0, length: 12, source: .llm, confidence: 0.99)
        let later = issue(location: 20, length: 3, source: .llm, confidence: 0.9)
        let invalid = issue(location: Int.max - 1, length: 3, source: .local, confidence: 1)
        let merged = IssueDetector.nonOverlappingIssues([model, guess, later, local, invalid], limit: 8)
        XCTAssertEqual(merged.map(\.id), [local.id, later.id])
        XCTAssertTrue(IssueDetector.nonOverlappingIssues([local], limit: 0).isEmpty)
    }

    func testConventionalReplyOpeningsAndDeclinesAreAccepted() {
        for output in ["Here is my availability for next week.", "Certainly, I can help.",
                       "Of course, Tuesday works for me.", "I cannot attend tomorrow."] {
            XCTAssertEqual(OutputSafetyValidator.validate(input: "Are you available?", output: output,
                                                           action: .draftReply), .ok)
        }
        XCTAssertEqual(OutputSafetyValidator.validate(input: "Will Smith is currently here.",
                                                       output: "Will Smith is here.", action: .makeConcise), .ok)
    }

    func testChangedNumbersRequireReviewAndTranslationIsBlockedInBothDirections() {
        let result = OutputSafetyValidator.validate(input: "Send 12 items on 10/02.",
                                                    output: "Send 13 items on 10/02.", action: .proofread)
        XCTAssertEqual(result, .suspicious(reason: "changedNumbers"))
        XCTAssertEqual(OutputSafetyValidator.disposition(for: "changedNumbers"), .reviewRequired)
        XCTAssertEqual(OutputSafetyValidator.validate(input: "请更新项目进度。", output: "Please update the project schedule.",
                                                       action: .proofread), .suspicious(reason: "scriptMismatch"))
    }

    private func candidate(_ original: String, _ suggestion: String,
                           type: String = "grammar", confidence: Double = 0.95) -> [String: Any] {
        ["original": original, "suggestion": suggestion, "type": type, "confidence": confidence]
    }

    private func response(_ candidates: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: candidates), as: UTF8.self)
    }

    private func issue(location: Int, length: Int, source: TextIssueSource, confidence: Double) -> TextIssue {
        TextIssue(range: NSRange(location: location, length: length), original: "teh", suggestion: "the",
                  explanation: nil, type: .spelling, confidence: confidence, source: source)
    }
}
