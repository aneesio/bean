import XCTest
@testable import Bean

final class SpellingSuggestionRankerTests: XCTestCase {
    private func rank(_ word: String, in text: String, guesses: [String], correction: String? = nil)
        -> SpellingSuggestionRanker.Result? {
        SpellingSuggestionRanker.rank(word: word, guesses: guesses, correction: correction,
                                     text: text, range: (text as NSString).range(of: word))
    }

    func testContextOverridesIncorrectMacFirstGuessAndCorrection() {
        let guesses = ["tae", "tee", "toe", "tie", "tmp", "the", "Mt", "tame", "time", "tome"]
        let result = rank("tme", in: "okay lets see if it works in the email this tme", guesses: guesses, correction: "the")
        XCTAssertEqual(result?.suggestion, "time")
        XCTAssertEqual(result?.confidence, 0.9)
        XCTAssertTrue(result?.alternatives.isEmpty == true)
    }

    func testLetterPreservationAndTranspositions() {
        XCTAssertEqual(rank("writting", in: "I am writting a message", guesses: ["fritting", "writing", "gritting"])?.suggestion, "writing")
        XCTAssertEqual(rank("recieved", in: "I recieved it", guesses: ["relieved", "received"])?.suggestion, "received")
    }

    func testPhraseContextDoesNotCrossSentenceOrHidePlausibleAdjective() {
        let disconnected = rank("tme", in: "this.\ntme", guesses: ["time", "tame"])
        XCTAssertEqual(disconnected?.confidence, 0.65)
        XCTAssertTrue(disconnected?.alternatives.contains("tame") == true)
        let adjective = rank("tme", in: "this tme frog", guesses: ["time", "tame"])
        XCTAssertEqual(adjective?.confidence, 0.65)
        XCTAssertTrue(adjective?.alternatives.contains("tame") == true)
    }

    func testPreferredOSCorrectionSurvivesLargeCandidateList() {
        let result = rank("recieved", in: "I recieved it", guesses: Array(repeating: "unrelated", count: 40), correction: "received")
        XCTAssertEqual(result?.suggestion, "received")
    }

    func testAmbiguousWordsOfferDistinctChoicesWithoutClaimingCertainty() {
        let result = rank("cotx", in: "cotx", guesses: ["cots", "cots", "cote", "coat"])
        XCTAssertEqual(result?.confidence, 0.65)
        XCTAssertFalse(result?.alternatives.isEmpty == true)
        XCTAssertEqual(Set(result?.alternatives ?? []).count, result?.alternatives.count)
        XCTAssertFalse(result?.alternatives.contains(result!.suggestion) == true)
    }

    func testNeverInventsCandidateAndRejectsDistantOrUnsafeGuesses() {
        XCTAssertNil(rank("tme", in: "this tme", guesses: []))
        XCTAssertNil(rank("xyz", in: "xyz", guesses: ["completely", "two words", "x\ny", "<b>word</b>"]))
    }

    func testUTF16ContextAndExactSourceValidation() {
        let text = "👩🏽‍💻 this tme"
        XCTAssertEqual(rank("tme", in: text, guesses: ["the", "time"])?.suggestion, "time")
        XCTAssertNil(SpellingSuggestionRanker.rank(word: "tme", guesses: ["time"], correction: nil,
                     text: text, range: NSRange(location: 1, length: 3)))
    }

    func testAlternativeKeepsIdentityAndRangeForVerifiedReplacement() {
        let issue = TextIssue(range: NSRange(location: 0, length: 4), original: "cotx",
                              suggestion: "cots", explanation: nil, type: .spelling,
                              confidence: 0.65, source: .spellchecker, alternatives: ["cote"])
        let selected = issue.choosingSuggestion("cote")
        XCTAssertEqual(selected?.id, issue.id)
        XCTAssertEqual(selected?.range, issue.range)
        XCTAssertEqual(selected.flatMap { InlineIssueMapping.expectedValue(afterApplying: $0, to: "cotx now") }, "cote now")
        XCTAssertNil(issue.choosingSuggestion("arbitrary text"))
    }
}
