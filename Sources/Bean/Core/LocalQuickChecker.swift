import Foundation

/// Applies only deterministic, offline issue candidates. Replacements run from
/// the end of the string and require an exact source match, so offsets cannot
/// drift and provider code is never reached.
enum LocalQuickChecker {
    static func corrected(_ text: String, dictionary: [DictionaryTerm]) -> String {
        let issues = IssueDetector().localIssues(in: text, dictionary: dictionary)
            .sorted { $0.range.location > $1.range.location }
        let result = NSMutableString(string: text)
        for issue in issues {
            guard issue.range.location != NSNotFound,
                  NSMaxRange(issue.range) <= result.length,
                  result.substring(with: issue.range) == issue.original else { continue }
            result.replaceCharacters(in: issue.range, with: issue.suggestion)
        }
        return result as String
    }
}
