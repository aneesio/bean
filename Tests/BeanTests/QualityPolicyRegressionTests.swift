import Foundation
import XCTest
@testable import Bean

final class QualityPolicyRegressionTests: XCTestCase {
    func testAgreementIsGeneralAndPreservesCompoundAndSubjunctiveSubjects() {
        XCTAssertEqual(LocalQuickChecker.corrected(
            "I has the notes. She have the draft. They is ready.\n- You has the file.", dictionary: []),
            "I have the notes. She has the draft. They are ready.\n- You have the file.")
        let valid = "Morgan and I are ready. The team and he have the notes. If he have time, he may join."
        XCTAssertEqual(LocalQuickChecker.corrected(valid, dictionary: []), valid)
        XCTAssertEqual(LocalQuickChecker.corrected("`She have the draft` and she has it.", dictionary: []),
                       "`She have the draft` and she has it.")
    }

    func testListAndQuoteIndentationAreNotRepeatedWordSpaces() {
        let text = "-   Keep this.\n>   Keep this too.\n1.   Numbered list.\n*   Another item.\n  Keep  one prose gap.  "
        XCTAssertEqual(LocalQuickChecker.corrected(text, dictionary: []),
                       "-   Keep this.\n>   Keep this too.\n1.   Numbered list.\n*   Another item.\n  Keep one prose gap.  ")
    }

    func testModelMappingCountsWholeTokensAndUsesUniqueVerifiedContextForRepeats() throws {
        let detector = IssueDetector()
        XCTAssertEqual(detector.issues(fromModelOutput: try response([
            ["original": "is", "suggestion": "are", "type": "grammar", "confidence": 0.95]
        ]), in: "This is ready.").count, 1)
        let text = "👩🏽‍💻 Please recieve it. They recieve it too."
        let responseText = try response([
            ["original": "recieve", "suggestion": "receive", "type": "spelling", "confidence": 0.95,
             "contextBefore": "👩🏽‍💻 Please ", "contextAfter": " it. They "]
        ])
        let issues = detector.issues(fromModelOutput: responseText, in: text)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.range, (text as NSString).range(of: "recieve"))
        XCTAssertTrue(detector.issues(fromModelOutput: try response([
            ["original": "recieve", "suggestion": "receive", "type": "spelling", "confidence": 0.95,
             "contextBefore": "invented text", "start": 0, "end": 7]
        ]), in: text).isEmpty)
        XCTAssertTrue(detector.issues(fromModelOutput: try response([
            ["original": "recieve", "suggestion": "receive", "type": "spelling", "confidence": 0.95,
             "contextAfter": " it. Both "]
        ]), in: "Both recieve it. Both recieve it. Both recieve it.").isEmpty)
    }

    func testProviderContextIsAnExactUTF16ProofNotCanonicalUnicodeGuessing() throws {
        let text = "cafe\u{301} recieve it; café recieve it."
        let issues = IssueDetector().issues(fromModelOutput: try response([
            ["original": "recieve", "suggestion": "receive", "type": "spelling", "confidence": 0.95,
             "contextBefore": "cafe\u{301} ", "contextAfter": " it;"]
        ]), in: text)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.range, (text as NSString).range(of: "recieve"))
    }

    func testDialectAndContextAreFixedBoundedProviderData() throws {
        let message = IssueDetector.userMessage(text: "Please recieve it.", context: nil,
            dictionary: [], maximumIssues: 8, dialect: .canadianEnglish)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        XCTAssertEqual(payload["writingConvention"] as? String, "en_CA")
        XCTAssertFalse(IssueDetector.systemPrompt.contains("en_CA"))
        XCTAssertTrue(IssueDetector.systemPrompt.contains("contextBefore"))
    }

    func testMeaningMarkersAreEnforcedByTheProductionValidator() {
        XCTAssertEqual(OutputSafetyValidator.validate(input: "Please do not approve it.",
            output: "Please approve it.", action: .proofread), .suspicious(reason: "changedNegation"))
        XCTAssertEqual(OutputSafetyValidator.validate(input: "Quorvio is ready.", output: "Corvio is ready.",
            action: .makeClearer, protectedTerms: ["Quorvio"]), .suspicious(reason: "changedEntities"))
        XCTAssertEqual(OutputSafetyValidator.disposition(for: "changedProtectedText"), .hardBlock)
        XCTAssertEqual(OutputSafetyValidator.disposition(for: "changedNegation"), .reviewRequired)
    }

    func testStrongLanguageEvidenceDoesNotForceOtherLanguagesIntoEnglish() {
        let text = "Bonjour, je vous remercie pour votre aide et votre patience. Nous pouvons nous retrouver demain."
        let result = WritingDialect.canadianEnglish.resolveLanguage(in: text, systemLanguage: "en_US", availableLanguages: ["en_US", "fr_FR"])
        XCTAssertFalse(result.appliesEnglishRules)
        XCTAssertEqual(result.checkerLanguage, "fr_FR")
        let unavailable = WritingDialect.automatic.resolveLanguage(in: text, systemLanguage: "en_US", availableLanguages: ["en_US"])
        XCTAssertNil(unavailable.checkerLanguage)
        XCTAssertFalse(unavailable.appliesEnglishRules)
    }

    func testRepetitionDoesNotManufactureIndependentLanguageEvidence() {
        for separator in ["\n", " ", "\t"] {
            let text = Array(repeating: "teh test", count: 12).joined(separator: separator)
            let result = WritingDialect.canadianEnglish.resolveLanguage(in: text,
                systemLanguage: "en_CA", availableLanguages: ["en_CA", "id"])
            XCTAssertTrue(result.appliesEnglishRules)
            XCTAssertEqual(result.checkerLanguage, "en_CA")
            XCTAssertEqual(LocalQuickChecker.corrected(text, dictionary: []),
                           Array(repeating: "the test", count: 12).joined(separator: separator))
        }
        let french = Array(repeating: "Merci beaucoup.", count: 12).joined(separator: "\n")
        let result = WritingDialect.automatic.resolveLanguage(in: french, systemLanguage: "en_CA", availableLanguages: ["en_CA", "fr"])
        XCTAssertFalse(result.appliesEnglishRules)
        XCTAssertEqual(result.checkerLanguage, "fr")
    }

    func testAmericanDictionaryServiceAliasIsResolvedWithoutGlobalLanguageChanges() {
        let result = WritingDialect.americanEnglish.resolveLanguage(in: "Please check the spelling in this update.",
            systemLanguage: "en_CA", availableLanguages: ["en", "en_CA", "en_GB"])
        XCTAssertEqual(result.checkerLanguage, "en")
        XCTAssertTrue(result.appliesEnglishRules)
    }

    @MainActor
    func testLocalCoverageDistinguishesDisabledAndBoundedScans() {
        var detector = IssueDetector()
        detector.maxIssues = 64
        let deterministic = detector.localAnalysis(in: "Please recieve this.", dictionary: [], includeSpellChecker: false)
        XCTAssertEqual(deterministic.spellingCoverage, .notRequested)
        XCTAssertEqual(deterministic.grammarCoverage, .notRequested)
        XCTAssertTrue(deterministic.isComplete)
        let longText = Array(repeating: "qzxvbnmzz", count: 70).joined(separator: " ")
        let bounded = detector.localAnalysis(in: longText, dictionary: [])
        // On a Mac with a working service this input exceeds its finding cap;
        // an unavailable test runner must report unavailability, never complete.
        XCTAssertTrue([IssueDetector.LocalCoverage.limitReached, .unavailable].contains(bounded.spellingCoverage))
        XCTAssertFalse(bounded.isComplete)
    }

    private func response(_ values: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }
}
