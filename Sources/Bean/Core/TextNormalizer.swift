import Foundation

// Local, deterministic pre/post processing around the LLM call. None of this
// talks to the network or logs text; it just keeps Bean from altering
// whitespace shape and from pasting stray artifacts the model sometimes adds.
enum TextNormalizer {

    /// Splits text into (leading whitespace, trimmed core, trailing whitespace)
    /// so the core can be corrected while the original outer whitespace —
    /// including a final newline — is reapplied verbatim.
    static func split(_ text: String) -> (leading: String, core: String, trailing: String) {
        let scalars = Array(text)
        var start = 0
        var end = scalars.count
        while start < end, scalars[start].isWhitespace { start += 1 }
        while end > start, scalars[end - 1].isWhitespace { end -= 1 }
        let leading = String(scalars[0..<start])
        let core = String(scalars[start..<end])
        let trailing = String(scalars[end..<scalars.count])
        return (leading, core, trailing)
    }

    /// True if the core is a single token (no internal whitespace).
    static func isSingleWord(_ core: String) -> Bool {
        !core.contains(where: { $0.isWhitespace })
    }

    /// A single word made purely of letters has no locally-fixable
    /// punctuation/casing issue, so it shouldn't be sent to the LLM (we don't
    /// guess proper-noun capitalization or invent typo fixes).
    static func isCleanSingleWord(_ core: String) -> Bool {
        isSingleWord(core) && !core.isEmpty && core.allSatisfy { $0.isLetter }
    }

    // Quote characters the model sometimes wraps a whole response in.
    private static let openingQuotes: Set<Character> = ["\"", "'", "“", "‘", "«"]
    private static let closingQuotes: Set<Character> = ["\"", "'", "”", "’", "»"]

    // Labels the model occasionally prepends. Compared case-insensitively.
    private static let labelPrefixes = [
        "corrected text:", "corrected:", "here is the corrected text:",
        "here's the corrected text:", "correction:"
    ]

    /// Conservatively strips accidental wrapping quotes and leading labels the
    /// model may add — but only when the ORIGINAL text didn't have them, so we
    /// never remove legitimate quotes/labels that are part of the user's text.
    static func stripArtifacts(_ output: String, originalCore: String) -> String {
        var result = output

        // 1. Leading label like "Corrected text:" (only if the original didn't
        //    start with that label).
        let lowerOriginal = originalCore.lowercased()
        for label in labelPrefixes where result.lowercased().hasPrefix(label) && !lowerOriginal.hasPrefix(label) {
            result = String(result.dropFirst(label.count))
            // Drop the whitespace/newline that usually follows the label.
            result = String(result.drop(while: { $0.isWhitespace }))
            break
        }

        // 2. Whole-string wrapping quotes (only if the original wasn't quoted).
        if let first = result.first, let last = result.last,
           openingQuotes.contains(first), closingQuotes.contains(last),
           result.count >= 2,
           let originalFirst = originalCore.first, !openingQuotes.contains(originalFirst) {
            let inner = result.dropFirst().dropLast()
            // Only strip if the inner text has no further unescaped wrapping
            // quote of the same family — i.e. the quotes really did wrap the
            // entire output rather than being legitimate inner quotes.
            if !inner.contains(where: { openingQuotes.contains($0) || closingQuotes.contains($0) }) {
                result = String(inner)
            }
        }

        return result
    }
}
