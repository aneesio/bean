import Foundation

// Conservative, last-line-of-defence check on the model's output before Bean
// replaces anything. It catches outputs that clearly aren't the requested
// transformation — translation, answering a question, summarizing — the
// tell-tales of prompt injection slipping through.
//
// Length expectations vary by action (Make Concise may be much shorter; Make
// Clearer / Make Professional may be longer), so the bounds are action-aware.
//
// PRIVACY: works on lengths/scripts/shape only and returns a fixed reason CODE
// (never the text) for logging.
enum OutputSafetyValidator {

    enum Result: Equatable {
        case ok
        case suspicious(reason: String)
    }

    static func validate(input: String, output: String, action: WritingAction) -> Result {
        let inText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let outText = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !outText.isEmpty else { return .suspicious(reason: "empty") }

        // Applies to every action: leaked prompt/wrapper labels.
        if startsWithLabel(outText) {
            return .suspicious(reason: "unsafeWrapper")
        }
        if leaksPrompt(outText) {
            return .suspicious(reason: "leakedPrompt")
        }

        // Script flip: Latin in, mostly non-Latin out (e.g. translated). Applies
        // to all actions — output should stay in the source language.
        if isMostlyLatin(inText), isMostlyNonLatin(outText) {
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
        if looksLikeQuestion(inText), !outText.contains("?"), outText.count < inText.count {
            return .suspicious(reason: "answered_question")
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

    private static let questionWords: Set<String> = [
        "what", "why", "how", "who", "when", "where", "which", "whose", "whom",
        "is", "are", "am", "do", "does", "did", "can", "could", "would",
        "should", "will", "was", "were", "has", "have", "had"
    ]

    private static func looksLikeQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let first = text.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return questionWords.contains(first)
    }

    private static let labelPrefixes = [
        "here is", "here's", "sure,", "sure!", "certainly", "of course",
        "rewritten text:", "transformed text:", "corrected text:"
    ]

    private static func startsWithLabel(_ text: String) -> Bool {
        let lower = text.lowercased()
        return labelPrefixes.contains { lower.hasPrefix($0) }
    }

    // Phrases that suggest the model echoed the prompt/system framing.
    private static let promptLeakMarkers = [
        "<text_to_correct>", "<provided_text>", "<context>", "system:",
        "your task:", "as an ai", "i cannot ", "i can't fulfill"
    ]

    private static func leaksPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return promptLeakMarkers.contains { lower.contains($0) }
    }
}
