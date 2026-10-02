import XCTest
@testable import Bean

final class UnicodeOutputPreservationTests: XCTestCase {
    func testEmojiAndLanguageJoinersSurviveEveryCleanupLayer() {
        let source = "👩🏽‍💻 می‌نویسد — a‍b"
        XCTAssertEqual(ParagraphSanitizer.sanitize(source).text, source)
        XCTAssertEqual(TextNormalizer.sanitizeModelOutput("<bean_output>\(source)</bean_output>", originalCore: source), source)
    }

    func testExistingSeparatorsSurviveButNewArtifactsAreRemoved() {
        let source = "keep\u{200b}this\u{feff}here"
        XCTAssertEqual(TextNormalizer.sanitizeModelOutput(source, originalCore: source), source)
        let cleaned = ParagraphSanitizer.sanitize("\u{200b}Corrected.\u{feff}", original: "Original.")
        XCTAssertEqual(cleaned.text, "Corrected.")
        XCTAssertEqual(cleaned.zeroWidthStripped, 2)
    }

    func testSourceFencesAndQuotesArePreserved() {
        let source = "```\nkeep this literal block\n```"
        XCTAssertEqual(TextNormalizer.sanitizeModelOutput(source, originalCore: source), source)
        XCTAssertEqual(TextNormalizer.sanitizeModelOutput("\"Please fix the.\"", originalCore: "\"Please fix teh.\""), "\"Please fix the.\"")
    }
}
