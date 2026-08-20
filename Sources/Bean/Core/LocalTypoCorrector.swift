import Foundation

// Local, deterministic correction of a handful of OBVIOUS common English
// one-word typos. This lets Bean fix things like "teh" -> "the" without making
// a network call, while still NOT sending every clean single word to the LLM.
//
// Scope is intentionally tiny and offline:
//   - No LLM call.
//   - No text logging.
//   - Only exact, unambiguous misspellings (no guessing).
enum LocalTypoCorrector {

    // Misspelling (lowercased) -> correct spelling. Obvious, common typos only.
    static let dictionary: [String: String] = [
        "teh": "the",
        "recieve": "receive",
        "recieved": "received",
        "definately": "definitely",
        "seperate": "separate",
        "occured": "occurred",
        "occurence": "occurrence",
        "adress": "address",
        "tommorow": "tomorrow",
        "wierd": "weird",
        "becuase": "because",
        "thier": "their",
        "accomodate": "accommodate",
        "grammer": "grammar",
        "enviroment": "environment",
        "responsiblity": "responsibility",
        "sucess": "success",
        "sucessful": "successful",
        "calender": "calendar",
        "prefered": "preferred"
    ]

    /// Returns the corrected word with the original's capitalization pattern
    /// preserved, or nil if `word` isn't a known typo.
    static func correction(for word: String) -> String? {
        guard let replacement = dictionary[word.lowercased()] else { return nil }
        return apply(casePatternOf: word, to: replacement)
    }

    /// Preserves three capitalization patterns:
    ///   all-caps  -> all-caps   ("TEH" -> "THE")
    ///   Titlecase -> Titlecase  ("Teh" -> "The")
    ///   otherwise -> lowercase  ("teh" -> "the")
    private static func apply(casePatternOf original: String, to replacement: String) -> String {
        let hasLetters = original.contains(where: { $0.isLetter })

        // All-caps: uppercase form equals the original and it actually has
        // letters (so a non-letter token doesn't count as "all caps").
        if hasLetters, original == original.uppercased() {
            return replacement.uppercased()
        }

        if let first = original.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }

        return replacement
    }
}
