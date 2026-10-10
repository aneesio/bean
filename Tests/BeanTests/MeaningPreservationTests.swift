import XCTest
@testable import Bean

final class MeaningPreservationTests: XCTestCase {
    func testConcreteFactsRejectRenamedRecipientsLinksAndDates() {
        let cases: [(String, String, String)] = [
            ("Send this to Taylor Nguyen.", "Send this to Morgan Patel.", "changedEntities"),
            ("Hello Anees,\nPlease review it.", "Hello Alex,\nPlease review it.", "changedEntities"),
            ("Review https://example.org/a?item=12.", "Review https://example.org/b?item=12.", "changedProtectedText"),
            ("Email jamie@example.org.", "Email morgan@example.org.", "changedProtectedText"),
            ("Mention @Jamie and #release.", "Mention @Morgan and #release.", "changedProtectedText"),
            ("Run `deploy --dry-run` tomorrow.", "Run `deploy` tomorrow.", "changedProtectedText"),
            ("We will meet on Friday.", "We will meet on Monday.", "changedTemporalFacts"),
            ("We will meet in May.", "We will meet in June.", "changedTemporalFacts")
        ]
        for (input, output, reason) in cases {
            XCTAssertEqual(TextMeaningPreservation.failure(input: input, output: output, action: .makeClearer), reason)
        }
    }

    func testTerminologyUsesOnlySourceTermsAndWholeTokenIdentity() {
        XCTAssertEqual(TextMeaningPreservation.failure(input: "Quorvio is ready.", output: "Corvio is ready.",
            action: .proofread, protectedTerms: ["Quorvio", "NotInSource"]), "changedEntities")
        XCTAssertNil(TextMeaningPreservation.failure(input: "The showcase is ready.", output: "The showcase is ready.",
            action: .proofread, protectedTerms: ["case", "NotInSource"]))
    }

    func testRelevantSavedTermAfterUnrelatedEarlyEntriesStillProtectsTheOutput() {
        let terms = (0..<300).map { "UnrelatedTerm\($0)" } + ["Quorvio"]
        XCTAssertEqual(OutputSafetyValidator.validate(input: "Quorvio is ready.",
            output: "Corvio is ready.", action: .makeClearer, protectedTerms: terms),
            .suspicious(reason: "changedEntities"))
        XCTAssertNil(TextMeaningPreservation.failure(input: "cafe\u{301} is ready.", output: "café is ready.",
            action: .proofread, protectedTerms: ["café"]))
        XCTAssertNil(TextMeaningPreservation.failure(input: "The showcase is ready.", output: "The showcase is ready.",
            action: .proofread, protectedTerms: terms + ["case"]))
    }

    func testNegationAndCommitmentStrengthSurviveMechanicalEdits() {
        for (input, output) in [
            ("I cannot approve this.", "I can approve this."),
            ("Please do not send it.", "Please send it."),
            ("We won't publish it.", "We will publish it."),
            ("I can approve this.", "I cannot approve this.")
        ] {
            XCTAssertEqual(TextMeaningPreservation.failure(input: input, output: output, action: .proofread), "changedNegation")
        }
        for (input, output) in [
            ("We might finish on Friday.", "We will finish on Friday."),
            ("Please review the draft.", "I guarantee the draft will succeed."),
            ("You must review it.", "You may review it.")
        ] {
            XCTAssertEqual(TextMeaningPreservation.failure(input: input, output: output, action: .makeProfessional), "changedCommitment")
        }
    }

    func testNegationCannotMoveBetweenAlignedProofreadStatements() {
        XCTAssertEqual(OutputSafetyValidator.validate(
            input: "I do not want delays. We can ship today.",
            output: "I do want delays. We cannot ship today.", action: .proofread),
            .suspicious(reason: "changedNegation"))
        XCTAssertEqual(TextMeaningPreservation.failure(input: "Please don't send it; I approve the draft.",
            output: "Please send it; I don't approve the draft.", action: .proofread), "changedNegation")
        XCTAssertNil(TextMeaningPreservation.failure(input: "I cannot attend. We can ship today.",
            output: "I can't attend. We can ship today.", action: .proofread))
        XCTAssertNil(TextMeaningPreservation.failure(input: "I cannot attend. The draft is ready.",
            output: "The draft is ready. I cannot attend.", action: .makeClearer))
    }

    func testEquivalentContractionsIdiomsAndOrdinaryTitlesAreAllowed() {
        let cases: [(String, String, WritingAction)] = [
            ("I can't attend.", "I cannot attend.", .proofread),
            ("I dont approve it.", "I don't approve it.", .proofread),
            ("I'm not available.", "I am unavailable.", .makeClearer),
            ("No worries!", "Happy to help!", .makeProfessional),
            ("I can't wait to see it.", "I'm excited to see it.", .makeClearer),
            ("Quarterly Report\nWe are ready.", "Quarterly update\nWe are ready.", .makeClearer),
            ("We Are Ready", "We're ready.", .makeCasual),
            ("Will Smith is currently here.", "Will Smith is here.", .makeConcise),
            ("May I join?", "May I join you?", .makeClearer),
            ("We will meet tomorrow.", "We will meet the following day.", .makeClearer),
            ("See https://example.org/a.", "See https://example.org/a!", .proofread),
            ("See https://example.org/a_(b).", "See https://example.org/a_(b).", .proofread)
        ]
        for (input, output, action) in cases {
            XCTAssertNil(TextMeaningPreservation.failure(input: input, output: output, action: action), "\(input) → \(output)")
        }
    }

    func testGenerativeActionsHaveTheirOwnContract() {
        XCTAssertNil(TextMeaningPreservation.failure(input: "Can we meet Friday?", output: "Monday works for me.", action: .draftReply))
    }

    func testDialectDoesNotChangeTheSystemPreference() {
        XCTAssertEqual(WritingDialect.automatic.checkerLanguage(systemLanguage: "fr_FR"), "fr_FR")
        XCTAssertEqual(WritingDialect.canadianEnglish.checkerLanguage(systemLanguage: "en_US"), "en_CA")
        XCTAssertEqual(WritingDialect.britishEnglish.checkerLanguage(systemLanguage: "en_CA"), "en_GB")
        XCTAssertNil(WritingDialect.automatic.promptInstruction)
        XCTAssertTrue(WritingDialect.canadianEnglish.promptInstruction?.contains("already-valid") == true)
    }
}
