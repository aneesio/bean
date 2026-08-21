import XCTest
@testable import Bean

final class TextSafetyTests: XCTestCase {
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
        guard case .suspicious = result else {
            return XCTFail("Expected empty output to be rejected")
        }
    }
}
