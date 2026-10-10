import XCTest
import AppKit
@testable import Bean

@MainActor
final class SystemWideWritingTests: XCTestCase {
    func testLocalAssistanceMigrationRepairsDisabledLabDefaultsOnlyOnce() throws {
        let suite = "SystemWideWritingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "inlineHighlightsEnabled")
        defaults.set(false, forKey: "bubbleEnabled")
        var reads = 0
        let settings = AppSettings(defaults: defaults, readKeychain: { _ in reads += 1; return nil })
        XCTAssertTrue(settings.inlineHighlightsEnabled)
        XCTAssertTrue(settings.bubbleEnabled)
        XCTAssertTrue(settings.bubbleInSearch)
        XCTAssertTrue(settings.bubbleInCode)
        XCTAssertFalse(settings.automaticAIChecksEnabled)
        XCTAssertEqual(reads, 0)
        settings.inlineHighlightsEnabled = false
        settings.bubbleEnabled = false
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.inlineHighlightsEnabled)
        XCTAssertFalse(relaunched.bubbleEnabled)
    }

    func testProseGrammarWorksWithoutASpellingServerAndPreservesLegitimateRepetition() {
        let source = "i think the the update is ready. I had had enough. He said that that works. no no. `i think the the`"
        XCTAssertEqual(LocalQuickChecker.corrected(source, dictionary: []),
                       "I think the update is ready. I had had enough. He said that that works. no no. `i think the the`")
        XCTAssertEqual(LocalQuickChecker.corrected("i’m ready and and i will send it.", dictionary: []),
                       "I’m ready and I will send it.")
    }

    func testNativeGrammarRangesAreRelativeToSentenceAndUseUTF16() throws {
        let source = "🙂 Intro. He are ready."
        let sentence = (source as NSString).range(of: "He are ready.")
        let details: [[String: Any]] = [[NSGrammarRange: NSValue(range: NSRange(location: 3, length: 3)),
                                        NSGrammarCorrections: ["is"], NSGrammarUserDescription: "Verb agreement"]]
        let issue = try XCTUnwrap(IssueDetector.grammarIssues(in: source, sentence: sentence, details: details).first)
        XCTAssertEqual((source as NSString).substring(with: issue.range), "are")
        XCTAssertEqual(issue.suggestion, "is")
        XCTAssertEqual(issue.explanation, "Verb agreement")
        XCTAssertTrue(IssueDetector.grammarIssues(in: source, sentence: sentence, details: details,
                                                protectedRanges: [issue.range]).isEmpty)
    }

    func testGrammarRejectsInvalidRangesChangedFactsAndMissingCorrection() {
        let source = "It has 12 items."
        let sentence = NSRange(location: 0, length: (source as NSString).length)
        let details: [[String: Any]] = [
            [NSGrammarRange: NSValue(range: NSRange(location: 999, length: 1)), NSGrammarCorrections: ["x"]],
            [NSGrammarRange: NSValue(range: NSRange(location: 7, length: 2)), NSGrammarCorrections: ["13"]],
            [NSGrammarRange: NSValue(range: NSRange(location: 3, length: 3)), NSGrammarUserDescription: "Check verb"]
        ]
        XCTAssertTrue(IssueDetector.grammarIssues(in: source, sentence: sentence, details: details).isEmpty)
        XCTAssertTrue(IssueDetector.grammarIssues(in: source, sentence: NSRange(location: NSNotFound, length: 1), details: details).isEmpty)
    }
}
