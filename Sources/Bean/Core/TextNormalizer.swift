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
        "here's the corrected text:", "rewritten text:", "transformed text:",
        "here is the rewritten text:", "here's the rewritten text:", "correction:"
    ]

    private static let outputOpenTag = "<bean_output>"
    private static let outputCloseTag = "</bean_output>"

    // Common model status notes. These are removed only when they appear as a
    // newly-added final line/paragraph, never when the user's source ended with
    // the same words.
    private static let commentaryPrefixes = [
        "all looked good", "everything looks good", "looks good", "this looks good",
        "the text looks good", "no changes needed", "no corrections needed",
        "no edits needed", "i made no changes", "i didn't make any changes",
        "the original text is already", "your text is already", "the text was already"
    ]

    /// Conservatively strips accidental wrapping quotes and leading labels the
    /// model may add — but only when the ORIGINAL text didn't have them, so we
    /// never remove legitimate quotes/labels that are part of the user's text.
    static func stripArtifacts(_ output: String, originalCore: String) -> String {
        var result = output

        // 0. Prefer the explicit response envelope. Any analysis or status text
        // outside it is discarded. An incomplete/malformed envelope is left in
        // place so OutputSafetyValidator can block it instead of guessing.
        if let enclosed = extractOutputEnvelope(from: result, originalCore: originalCore) {
            result = enclosed
        }

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

        result = stripTrailingCommentary(from: result, originalCore: originalCore)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Full provider-output cleanup used by every desktop/web-host transform.
    /// ParagraphSanitizer handles code fences, wrapping quotes, and zero-width
    /// artifacts; the logic above then handles Bean's envelope and model prose.
    static func sanitizeModelOutput(_ output: String, originalCore: String) -> String {
        let cleaned = ParagraphSanitizer.sanitize(output).text
        return stripArtifacts(cleaned, originalCore: originalCore)
    }

    private static func extractOutputEnvelope(from text: String, originalCore: String) -> String? {
        let sourceTagCount = occurrenceCount(of: outputOpenTag, in: originalCore)
        let outputTagCount = occurrenceCount(of: outputOpenTag, in: text)
        // If the source itself contains this literal tag and the model did not
        // add an outer one, it is source content—not Bean's response envelope.
        guard sourceTagCount == 0 || outputTagCount > sourceTagCount,
              let open = text.range(of: outputOpenTag, options: [.caseInsensitive]),
              let close = text.range(of: outputCloseTag, options: [.caseInsensitive, .backwards]),
              open.upperBound <= close.lowerBound else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func occurrenceCount(of needle: String, in text: String) -> Int {
        var count = 0
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive],
                                     range: start..<text.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    private static func stripTrailingCommentary(from text: String, originalCore: String) -> String {
        let originalLower = originalCore.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A footer is only considered commentary when separated from the result
        // by a line break. This avoids deleting a legitimate sentence in prose.
        while let newline = result.lastIndex(of: "\n") {
            let footer = String(result[result.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let footerLower = footer.lowercased()
            guard isCommentary(footerLower), !originalLower.hasSuffix(footerLower) else { break }
            result = String(result[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func isCommentary(_ lower: String) -> Bool {
        let normalized = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return commentaryPrefixes.contains { normalized.hasPrefix($0) }
    }
}
