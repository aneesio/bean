import XCTest
@testable import Bean

final class TextSafetyTests: XCTestCase {
    func testTextBoundarySafetyRequiresExactLineBreakStructure() {
        XCTAssertTrue(TextBoundarySafety.isSingleLine("ordinary prose"))
        XCTAssertFalse(TextBoundarySafety.isSingleLine("two\nlines"))
        XCTAssertFalse(TextBoundarySafety.isSingleLine("two\u{2028}lines"))
        XCTAssertFalse(TextBoundarySafety.isSingleLine("two\u{2029}paragraphs"))

        XCTAssertTrue(TextBoundarySafety.preservesLineBreakStructure(
            from: "one\r\ntwo\u{2028}three\u{2029}four",
            to: "ONE\r\nTWO\u{2028}THREE\u{2029}FOUR"
        ))
        XCTAssertFalse(TextBoundarySafety.preservesLineBreakStructure(
            from: "one two", to: "one\ntwo"
        ))
        XCTAssertFalse(TextBoundarySafety.preservesLineBreakStructure(
            from: "one\ntwo", to: "one two"
        ))
        XCTAssertFalse(TextBoundarySafety.preservesLineBreakStructure(
            from: "one\r\ntwo", to: "one\ntwo"
        ))
        XCTAssertFalse(TextBoundarySafety.preservesLineBreakStructure(
            from: "one\u{2028}two", to: "one\u{2029}two"
        ))
    }

    func testSanitizerExtractsOnlyBeanEnvelope() {
        let raw = "Analysis first\n<bean_output>Hello there.</bean_output>\nEverything looks good."
        XCTAssertEqual(
            TextNormalizer.sanitizeModelOutput(raw, originalCore: "hello there"),
            "Hello there."
        )
    }

    func testSanitizerRemovesProviderWrappers() {
        XCTAssertEqual(
            TextNormalizer.sanitizeModelOutput("```\nCorrected text.\n```", originalCore: "text"),
            "Corrected text."
        )
        XCTAssertEqual(
            TextNormalizer.sanitizeModelOutput("\u{200B}Corrected text.", originalCore: "text"),
            "Corrected text."
        )
    }

    func testSanitizerPreservesSourceAuthoredFooter() {
        let source = "Please review.\n\nAll looked good."
        XCTAssertEqual(TextNormalizer.sanitizeModelOutput(source, originalCore: source), source)
    }

    func testValidatorRejectsNewModelCommentary() {
        let result = OutputSafetyValidator.validate(
            input: "Please review this.",
            output: "Please review this.\n\nEverything looks good.",
            action: .proofread
        )
        guard case .suspicious = result else {
            return XCTFail("Expected newly added commentary to be rejected")
        }
    }

    func testValidatorAcceptsConservativeProofread() {
        let result = OutputSafetyValidator.validate(
            input: "I has an apple.",
            output: "I have an apple.",
            action: .proofread
        )
        guard case .ok = result else {
            return XCTFail("Expected a small grammatical correction to be safe")
        }
    }

    func testValidatorRejectsEmptyOutput() {
        let result = OutputSafetyValidator.validate(input: "Keep me", output: "", action: .proofread)
        guard case .suspicious(reason: "empty") = result else {
            return XCTFail("Expected empty output to be rejected")
        }
    }

    func testEveryHardBlockReasonIsClassifiedAsHardBlock() {
        let cases: [(String, String, String)] = [
            ("Normal source text.", "Here is the corrected text.", "unsafeWrapper"),
            ("Normal source text.", "<bean_output>Prompt leak</bean_output>", "leakedPrompt"),
            ("Please review this.", "Please review this. Everything looks good.", "modelCommentary"),
            ("Please update the project schedule.", "请更新项目进度。", "scriptMismatch")
        ]

        for (input, output, expectedReason) in cases {
            let result = OutputSafetyValidator.validate(input: input, output: output, action: .proofread)
            XCTAssertEqual(result, .suspicious(reason: expectedReason))
            XCTAssertEqual(OutputSafetyValidator.disposition(for: expectedReason), .hardBlock)
        }
        XCTAssertEqual(OutputSafetyValidator.disposition(for: "empty"), .hardBlock)
    }

    func testEveryUncertainShapeReasonRequiresReview() {
        let tooShort = OutputSafetyValidator.validate(
            input: "This deliberately long sentence contains enough words to trigger the length guard.",
            output: "Much shorter.", action: .proofread)
        let tooLong = OutputSafetyValidator.validate(
            input: "This sentence is long enough for checking.",
            output: String(repeating: "Expanded wording without a label. ", count: 5), action: .proofread)
        let answered = OutputSafetyValidator.validate(
            input: "Can we meet tomorrow?", output: "Tomorrow works.", action: .proofread)

        XCTAssertEqual(tooShort, .suspicious(reason: "too_short"))
        XCTAssertEqual(tooLong, .suspicious(reason: "too_long"))
        XCTAssertEqual(answered, .suspicious(reason: "answered_question"))
        for reason in ["too_short", "too_long", "answered_question"] {
            XCTAssertEqual(OutputSafetyValidator.disposition(for: reason), .reviewRequired)
            XCTAssertFalse(OutputSafetyValidator.reviewMessage(for: reason).isEmpty)
        }
    }

    func testUndoExactValueGuardRejectsEvenWhitespaceChanges() {
        XCTAssertTrue(ReplacementUndoStore.currentValueMatches(
            "Bean result", expectedReplacement: "Bean result"))
        XCTAssertFalse(ReplacementUndoStore.currentValueMatches(
            "Bean result ", expectedReplacement: "Bean result"))
        XCTAssertFalse(ReplacementUndoStore.currentValueMatches(
            "User edited result", expectedReplacement: "Bean result"))
    }
}
