import Foundation

// Cleans the model's whole-paragraph proofread output before Bean replaces a
// paragraph in a web field. The model is asked for plain corrected text only, but
// providers occasionally wrap output in code fences / quotes or emit invisible
// zero-width characters; those must never reach the user's document.
//
// PRIVACY: operates on the output string only and returns the cleaned text plus a
// COUNT of stripped zero-width characters — never logs or returns any content for
// logging. It strips wrappers/zero-width artifacts but does NOT trim meaningful
// internal text.
enum ParagraphSanitizer {

    struct Result: Equatable {
        let text: String
        let zeroWidthStripped: Int
    }

    // Zero-width space, ZWNJ, ZWJ, and BOM — model artifacts, never user intent.
    private static let zeroWidthScalars: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]

    static func sanitize(_ raw: String) -> Result {
        var s = stripCodeFence(raw)
        s = stripWrappingQuotes(s)

        var stripped = 0
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if zeroWidthScalars.contains(u.value) { stripped += 1; continue }
            scalars.append(u)
        }
        return Result(text: String(scalars), zeroWidthStripped: stripped)
    }

    /// Removes a single surrounding ```/```lang fenced block if the whole output is
    /// fenced. Leaves un-fenced text untouched.
    private static func stripCodeFence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return s }
        var lines = t.components(separatedBy: "\n")
        guard lines.count >= 2 else { return s }
        lines.removeFirst() // opening ``` or ```lang
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Removes one pair of wrapping quotes if (and only if) the entire output is
    /// quoted and there is no interior quote of the same kind (avoids eating real
    /// quotation marks inside the paragraph).
    private static func stripWrappingQuotes(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return s }
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("‘", "’")]
        for (open, close) in pairs where t.first == open && t.last == close {
            let inner = String(t.dropFirst().dropLast())
            if !inner.contains(open) && !inner.contains(close) { return inner }
        }
        return s
    }
}
