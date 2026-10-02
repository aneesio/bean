import Foundation

/// macOS supplies plausible spellings, not a reliable preferred correction.
/// Rank only those supplied candidates; contextual guesses always require the
/// writer's acceptance and never enter the deterministic Quick Fix path.
enum SpellingSuggestionRanker {
    struct Result {
        let suggestion: String
        let alternatives: [String]
        let confidence: Double
    }

    static func rank(word: String, guesses: [String], correction: String?,
                     text: String, range: NSRange) -> Result? {
        guard !word.isEmpty, word.count <= 128, word.allSatisfy({ $0.isLetter }),
              let sourceRange = Range(range, in: text), String(text[sourceRange]) == word else { return nil }
        let original = word.lowercased()
        let previous = phraseWord(in: String(text[..<sourceRange.lowerBound].suffix(128)),
                                  pattern: "([\\p{L}]+)[ \\t]+$")
        let following = phraseWord(in: String(text[sourceRange.upperBound...].prefix(128)),
                                   pattern: "^[ \\t]+([\\p{L}]+)")
        var seen = Set<String>()
        let supplied = Array(guesses.prefix(correction == nil ? 40 : 39)) + (correction.map { [$0] } ?? [])
        let candidates = supplied.enumerated().compactMap {
            index, candidate -> (word: String, score: Double, contextual: Bool)? in
            let lower = candidate.lowercased()
            guard lower != original, !candidate.isEmpty, candidate.count <= 128,
                  candidate.allSatisfy({ $0.isLetter }), seen.insert(lower).inserted else { return nil }
            let distance = editCost(original, lower)
            // Avoid offering a remotely related word for an unfamiliar name.
            guard distance <= max(1.5, Double(original.count) * 0.4) else { return nil }
            let contextual = previous.flatMap { contextualFollowers[$0] }?.contains(lower) == true
                && (following == nil || phraseContinuations.contains(following!))
            let score = distance - (commonWords.contains(lower) ? 0.18 : 0)
                - (correction?.lowercased() == lower ? 0.08 : 0)
                - (contextual ? 0.75 : 0) + Double(index) * 0.002
            return (candidate, score, contextual)
        }.sorted { $0.score < $1.score }
        guard let best = candidates.first else { return nil }
        let gap = candidates.dropFirst().first.map { $0.score - best.score } ?? 1
        let confidence = best.contextual && gap > 0.5 ? 0.9 : (gap > 0.3 ? 0.8 : 0.65)
        let alternatives = candidates.dropFirst().filter { $0.score - best.score < 0.7 }
            .prefix(3).map(\.word)
        return Result(suggestion: best.word, alternatives: alternatives, confidence: confidence)
    }

    private static func phraseWord(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].lowercased()
    }

    /// Missing letters and accidental duplicate letters are more likely than
    /// substitutions. Adjacent transpositions cover received/recieved, etc.
    private static func editCost(_ original: String, _ candidate: String) -> Double {
        let a = Array(original), b = Array(candidate)
        var costs = Array(repeating: Array(repeating: 0.0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { costs[i][0] = Double(i) * 0.7 }
        for j in 0...b.count { costs[0][j] = Double(j) * 0.7 }
        guard !a.isEmpty, !b.isEmpty else { return costs[a.count][b.count] }
        for i in 1...a.count {
            for j in 1...b.count {
                let deletion = i > 1 && a[i - 1] == a[i - 2] ? 0.45 : 0.7
                costs[i][j] = min(costs[i - 1][j] + deletion,
                                  costs[i][j - 1] + 0.7,
                                  costs[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    costs[i][j] = min(costs[i][j], costs[i - 2][j - 2] + 0.65)
                }
            }
        }
        return costs[a.count][b.count]
    }

    // Small, transparent prose priors. This is not a replacement dictionary;
    // every offered spelling must still be supplied by the operating system.
    private static let commonWords: Set<String> = Set("""
    the a an and or but if then that this these those it its is are was were be been being
    to of for from in on at by with without as into about after before during between
    I you he she we they me him her us them my your our their have has had do does did
    can could will would should may might must not no yes all any each every some many
    more most other only just also very so than too up down out over under again
    time times thing things today tomorrow yesterday day days week month year work works
    write writing written read reading receive received send sent email message check
    see know think want need make made take get good great new next last first same
    please thanks thank help use used using people one two much well way right now
    clear correct spelling meeting report project update test testing working reply
    """.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() })

    private static let contextualFollowers: [String: Set<String>] = [
        "this": ["time", "thing", "week", "month", "year"],
        "same": ["time", "thing", "day", "week", "month", "year"],
        "next": ["time", "day", "week", "month", "year"],
        "last": ["time", "day", "week", "month", "year"],
        "every": ["time", "day", "week", "month", "year"],
        "first": ["time", "day", "week"],
        "good": ["time", "day", "morning", "evening"],
        "thank": ["you"],
        "looking": ["forward"],
        "best": ["regards", "wishes"]
    ]

    // A following content word may favor another spelling ("this tame frog").
    // Keep those choices uncertain rather than applying the phrase prior.
    private static let phraseContinuations: Set<String> = [
        "around", "we", "i", "you", "he", "she", "they", "it", "is", "was",
        "will", "could", "should", "would", "can", "to", "in", "on", "at",
        "with", "for", "and", "but", "of", "when", "while", "that"
    ]
}
