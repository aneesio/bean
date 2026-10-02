import Foundation

/// Bounded local checks for concrete, detectable changes. These are not a
/// semantic equivalence model: equivalent paraphrases can require review, and
/// a text can retain every marker below while still changing its meaning.
/// No source or output strings are stored or returned in diagnostics.
enum TextMeaningPreservation {
    static func failure(input: String, output: String, action: WritingAction,
                        protectedTerms: [String] = []) -> String? {
        guard action.category == .proofread || action.category == .rewrite else { return nil }
        if literalFacts(input) != literalFacts(output) { return "changedProtectedText" }

        // Find relevant terms across the bounded dictionary before limiting
        // included terms; unrelated early entries must not hide a later saved
        // name that the user actually wrote.
        let terms = protectedTerms.prefix(UserContentFileLimits.maximumNativeDictionaryTerms).lazy.filter {
            !$0.isEmpty && $0.count <= 128 && containsToken($0, in: input)
        }.prefix(200)
        let names = concreteNames(input)
        if (Array(terms) + names).contains(where: { !containsToken($0, in: output) }) {
            return "changedEntities"
        }
        if temporalFacts(input) != temporalFacts(output) { return "changedTemporalFacts" }

        let inputPolarity = negativeMarkers(input)
        let outputPolarity = negativeMarkers(output)
        if action.category == .proofread {
            if inputPolarity.count != outputPolarity.count { return "changedNegation" }
            // Equal totals can hide a reversal when negation moves between
            // statements. Mechanical proofreading preserves statement order;
            // compare aligned boundaries only, without claiming equivalence
            // when a rewrite changes/reorders the sentence structure.
            let beforeStatements = alignedStatementPolarities(input)
            let afterStatements = alignedStatementPolarities(output)
            if beforeStatements.count > 1, beforeStatements.count == afterStatements.count,
               beforeStatements != afterStatements { return "changedNegation" }
        } else if inputPolarity.isEmpty != outputPolarity.isEmpty {
            return "changedNegation"
        }

        let before = commitments(input)
        let after = commitments(output)
        // An uncertain draft must not become a promise. Obligation and explicit
        // guarantees also survive wording changes in either direction.
        if (before.uncertain && !after.uncertain && after.firm)
            || before.obligation != after.obligation
            || before.guarantee != after.guarantee {
            return "changedCommitment"
        }
        // Proofreading is mechanical; tone rewrites can replace "will" with
        // equivalent intent language without manufacturing a new guarantee.
        if action.category == .proofread,
           before.uncertain != after.uncertain || before.firm != after.firm {
            return "changedCommitment"
        }
        return nil
    }

    private static func alignedStatementPolarities(_ text: String) -> [Int] {
        guard let boundary = try? NSRegularExpression(pattern: #"[.!?;](?=\s|$)|[\r\n]+"#) else { return [] }
        let source = text as NSString
        let matches = boundary.matches(in: text, range: NSRange(location: 0, length: source.length))
        var start = 0
        var statements: [Int] = []
        for match in matches {
            let statement = source.substring(with: NSRange(location: start, length: match.range.location - start))
            if statement.contains(where: { $0.isLetter }) { statements.append(negativeMarkers(statement).count) }
            start = NSMaxRange(match.range)
        }
        let remainder = source.substring(from: start)
        if remainder.contains(where: { $0.isLetter }) { statements.append(negativeMarkers(remainder).count) }
        return statements
    }

    private static let literalPatterns = [
        #"(?i)\b(?:[A-Z][A-Z0-9+.-]*://|www\.)[^\s<>"“”]+"#,
        #"[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}"#,
        #"(?<![\p{L}\p{N}._%+-])[@#][\p{L}\p{N}_]+"#,
        #"(?s)```.*?(?:```|\z)|~~~.*?(?:~~~|\z)"#,
        #"`[^`\r\n]+`"#,
        #"(?<![\p{L}\p{N}])(?:[A-Za-z]:\\|[./~]*[/\\])[^\s]+"#
    ]

    private static let literalExpressions = literalPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static func literalFacts(_ text: String) -> [String] {
        let ns = text as NSString
        return literalExpressions.flatMap { expression in
            expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                trimSentencePunctuation(ns.substring(with: $0.range))
            }
        }.sorted()
    }

    private static func trimSentencePunctuation(_ text: String) -> String {
        // Preserve parentheses that are part of a URL while excluding the
        // surrounding sentence's closing delimiter and final period/comma.
        var value = text
        while let last = value.last {
            if ".,;!".contains(last) { value.removeLast(); continue }
            let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
            if let opener = pairs[last], value.filter({ $0 == last }).count > value.filter({ $0 == opener }).count {
                value.removeLast(); continue
            }
            break
        }
        return value
    }

    /// Positive user terminology is authoritative. Automatic name evidence is
    /// intentionally narrow: a multiword capitalized name or a greeting's
    /// addressee. Sentence capitalization alone never establishes an entity.
    private static func concreteNames(_ text: String) -> [String] {
        var names: [String] = []
        let namePattern = #"(?<![\p{L}\p{N}])[A-Z][\p{Ll}\p{M}]+(?:[ -][A-Z][\p{Ll}\p{M}]+){1,3}(?![\p{L}\p{N}])"#
        for name in matches(namePattern, in: text) {
            let words = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            if words.allSatisfy({ !ordinaryTitleWords.contains($0) }) { names.append(name) }
        }
        let greetingPattern = #"(?im)^(?:hi|hello|dear)[ \t]+([\p{Lu}][\p{L}\p{M}'’-]*(?:[ \t]+[\p{Lu}][\p{L}\p{M}'’-]*){0,3})(?=\s*[,!:]|\s*$)"#
        guard let expression = try? NSRegularExpression(pattern: greetingPattern) else { return names }
        let ns = text as NSString
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            if !["team", "everyone", "all", "there", "folks"].contains(name.lowercased()) { names.append(name) }
        }
        return Array(Set(names))
    }

    private static let ordinaryTitleWords: Set<String> = Set("""
        a an the this that these those we you i he she it they our your their my
        please thanks thank hello hi dear best kind regards sincerely welcome
        are is was were be been have has had do does did and or but if then
        report reports update updates project projects manager management team
        meeting meetings review reviews release notes note status summary draft
        ready available complete completed final first next last quarterly annual
        monday tuesday wednesday thursday friday saturday sunday morning afternoon
        january february march april may june july august september october november december
        send read check attend join approve deliver plan action items more less
        make clear concise professional casual all good no new original corrected
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    private static func containsToken(_ token: String, in text: String) -> Bool {
        let source = text as NSString
        var start = 0
        while start < source.length {
            let found = source.range(of: token, options: [.caseInsensitive],
                range: NSRange(location: start, length: source.length - start))
            guard found.location != NSNotFound, found.length > 0 else { return false }
            if let range = Range(found, in: text) {
                let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
                let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
                let isToken: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
                if !isToken(before), !isToken(after) { return true }
            }
            start = NSMaxRange(found)
        }
        return false
    }

    private static func temporalFacts(_ text: String) -> [String] {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "the following day", with: "tomorrow")
            .replacingOccurrences(of: "the next day", with: "tomorrow")
        let days = matches(#"\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|yesterday)\b"#,
                           in: normalized)
        // Context excludes the modal "may" and ordinary uses of "march".
        let months = matches(#"\b(?:on|by|until|before|after|from|in|next|this|last)\s+(?:january|february|march|april|may|june|july|august|september|october|november|december)\b"#,
                             in: normalized).compactMap { $0.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) }
        return (days + months).sorted()
    }

    private static func negativeMarkers(_ text: String) -> [String] {
        var normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        // Conventional positive idioms can be reworded naturally. They are
        // outside this narrow negative-polarity safeguard.
        for idiom in ["no problem", "no worries", "no doubt", "no wonder", "no objections",
                      "no concerns", "no reservations", "not only", "not to mention",
                      "without a doubt", "without delay", "can't wait", "cannot wait"] {
            normalized = normalized.replacingOccurrences(of: idiom, with: " ")
        }
        return matches(#"\b(?:not|never|no|neither|nor|without|nothing|nobody|none|cannot|unable|unavailable|impossible|unlikely|refuse|decline|reject|disallow|won'?t|can'?t|don'?t|doesn'?t|didn'?t|isn'?t|aren'?t|wasn'?t|weren'?t|haven'?t|hasn'?t|hadn'?t|shouldn'?t|wouldn'?t|couldn'?t|mustn'?t)\b"#,
                       in: normalized)
    }

    private struct Commitments {
        let uncertain: Bool
        let firm: Bool
        let obligation: Bool
        let guarantee: Bool
    }

    private static func commitments(_ text: String) -> Commitments {
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let guarantee = !matches(#"\b(?:promise|promised|guarantee|guaranteed|commit|committed|pledge|pledged)\b"#,
                                 in: normalized).isEmpty
        return Commitments(
            uncertain: !matches(#"\b(?:may|might|could|perhaps|possibly|probably|maybe|hope|hoping)\b"#,
                                in: normalized).isEmpty,
            firm: guarantee || !matches(#"\b(?:will|shall)\b|\b(?:i|you|we|he|she|it|they)'ll\b"#,
                                        in: normalized).isEmpty,
            obligation: !matches(#"\b(?:must|required|mandatory)\b|\b(?:have|has|need|needs)\s+to\b"#,
                                  in: normalized).isEmpty,
            guarantee: guarantee)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
