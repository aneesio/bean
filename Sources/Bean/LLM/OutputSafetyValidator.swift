import Foundation

// Conservative, last-line-of-defence check on the model's output before Bean
// replaces anything. It catches outputs that clearly aren't the requested
// transformation — translation, answering a question, summarizing — the
// tell-tales of prompt injection slipping through.
//
// Length expectations vary by action (Make Concise may be much shorter; Make
// Clearer / Make Professional may be longer), so the bounds are action-aware.
//
// PRIVACY: checks shape and bounded concrete markers, returns a fixed reason CODE
// (never the text) for logging.
enum OutputSafetyValidator {

    /// Hard blocks indicate output that must never be offered as replacement.
    /// Review-required results are plausible transformations whose shape is
    /// unusual enough that the user should make the final decision in Preview.
    enum Disposition: Equatable {
        case hardBlock
        case reviewRequired
    }

    enum Result: Equatable {
        case ok
        case suspicious(reason: String)
    }

    static func disposition(for reason: String) -> Disposition {
        switch reason {
        case "too_short", "too_long", "answered_question", "changedNumbers",
             "changedEntities", "changedTemporalFacts", "changedNegation", "changedCommitment":
            return .reviewRequired
        default:
            return .hardBlock
        }
    }

    static func reviewMessage(for reason: String) -> String {
        switch reason {
        case "too_short":
            return "This result is much shorter than the original. Review it before replacing."
        case "too_long":
            return "This result is much longer than the original. Review it before replacing."
        case "answered_question":
            return "This may answer the text instead of editing it. Review it before replacing."
        case "changedNumbers":
            return "This result changes a number, date, or amount. Check those details before replacing."
        case "changedEntities":
            return "This result changes a name or saved term. Check those details before replacing."
        case "changedTemporalFacts":
            return "This result changes a day or date reference. Check those details before replacing."
        case "changedNegation":
            return "This result may reverse a negative statement. Check the meaning before replacing."
        case "changedCommitment":
            return "This result may change a promise, requirement, or uncertainty. Check the meaning before replacing."
        default:
            return "This result is unusual. Review it carefully before replacing."
        }
    }

    static func validate(input: String, output: String, action: WritingAction,
                         protectedTerms: [String] = []) -> Result {
        let inText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let outText = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !outText.isEmpty else { return .suspicious(reason: "empty") }

        // Applies to every action: leaked prompt/wrapper labels.
        if startsWithLabel(outText), !startsWithLabel(inText) {
            return .suspicious(reason: "unsafeWrapper")
        }
        if leaksPrompt(outText, comparedTo: inText) {
            return .suspicious(reason: "leakedPrompt")
        }
        if addsMetaCommentary(outText, comparedTo: inText) {
            return .suspicious(reason: "modelCommentary")
        }

        // Script flip: Latin in, mostly non-Latin out (e.g. translated). Applies
        // to all actions — output should stay in the source language.
        if (isMostlyLatin(inText) && isMostlyNonLatin(outText))
            || (isMostlyNonLatin(inText) && isMostlyLatin(outText)) {
            return .suspicious(reason: "scriptMismatch")
        }

        // Reply/compose are generative — their length and "question vs answer"
        // shape legitimately differs from the source, so skip those heuristics.
        let isGenerative = action.category == .reply || action.category == .compose
        guard !isGenerative else { return .ok }

        // Length bounds, action-aware (proofread/rewrite). Skipped for short input.
        if inText.count >= 25 {
            if !action.allowsShorterOutput, outText.count < (inText.count * 4) / 10 {
                return .suspicious(reason: "too_short")
            }
            if !action.allowsLongerOutput, outText.count > inText.count * 5 / 2 {
                return .suspicious(reason: "too_long")
            }
        }

        // Answered a question instead of transforming it.
        if looksLikeQuestion(inText), !looksLikeQuestion(outText), outText.count < inText.count {
            return .suspicious(reason: "answered_question")
        }

        // An edit should retain concrete facts. Changed numbers can be a
        // legitimate formatting choice, so require review instead of discarding
        // the result. Generative actions already returned above.
        if numericFacts(inText) != numericFacts(outText) {
            return .suspicious(reason: "changedNumbers")
        }

        if let reason = TextMeaningPreservation.failure(input: inText, output: outText,
                                                        action: action, protectedTerms: protectedTerms) {
            return .suspicious(reason: reason)
        }

        return .ok
    }

    // MARK: - Heuristics

    private static func latinLetterFraction(_ text: String) -> Double? {
        var letters = 0, latin = 0
        for char in text where char.isLetter {
            letters += 1
            if let scalar = char.unicodeScalars.first, scalar.value <= 0x024F { latin += 1 }
        }
        guard letters > 0 else { return nil }
        return Double(latin) / Double(letters)
    }

    private static func isMostlyLatin(_ text: String) -> Bool {
        guard let f = latinLetterFraction(text) else { return true }
        return f >= 0.7
    }

    private static func isMostlyNonLatin(_ text: String) -> Bool {
        guard let f = latinLetterFraction(text) else { return false }
        return f < 0.3
    }

    private static func looksLikeQuestion(_ text: String) -> Bool {
        text.contains("?") || text.contains("？") || text.contains("؟")
    }

    private static func startsWithLabel(_ text: String) -> Bool {
        let lower = text.lowercased()
        let labels = ["rewritten text:", "transformed text:", "corrected text:",
                      "edited text:", "revised text:"]
        if labels.contains(where: { lower.hasPrefix($0) }) { return true }
        // "Here is my availability" and "Certainly, I can help" are normal
        // writing, particularly in reply drafts. Reject editing wrappers only.
        let pattern = "^(?:(?:sure[,!]|certainly[,!]|of course[,!])\\s*)?(?:here is|here's|here are)\\s+(?:the |your |a )?(?:corrected|rewritten|transformed|edited|proofread|revised)\\b"
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    // Phrases that suggest the model echoed the prompt/system framing.
    private static let promptLeakMarkers = [
        "<text_to_correct>", "<provided_text>", "<context>", "system:",
        "<bean_output>", "</bean_output>", "your task:", "as an ai"
    ]

    private static func leaksPrompt(_ text: String, comparedTo input: String) -> Bool {
        let lower = text.lowercased()
        let inputLower = input.lowercased()
        return promptLeakMarkers.contains { lower.contains($0) && !inputLower.contains($0) }
    }

    private static let commentaryMarkers = [
        "all looked good", "everything looks good", "no changes needed",
        "no corrections needed", "no edits needed", "i made no changes",
        "the text is already correct", "the original text is already correct"
    ]

    private static func addsMetaCommentary(_ output: String, comparedTo input: String) -> Bool {
        let lower = output.lowercased()
        let inputLower = input.lowercased()
        return commentaryMarkers.contains { lower.contains($0) && !inputLower.contains($0) }
    }

    private static func numericFacts(_ text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "[+-]?\\p{N}+(?:[.,:/-]\\p{N}+)*") else { return [] }
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
