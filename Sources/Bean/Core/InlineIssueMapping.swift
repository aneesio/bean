import Foundation

/// Pure range decisions shared by the native writing loop. AX and NSString
/// ranges use UTF-16; the same misspelling can occur more than once in a draft.
enum InlineIssueMapping {
    static func resolvedRange(for issue: TextIssue, in value: String) -> NSRange? {
        guard !issue.original.isEmpty, issue.original != issue.suggestion,
              TextBoundarySafety.isSingleLine(issue.original),
              TextBoundarySafety.preservesLineBreakStructure(from: issue.original, to: issue.suggestion)
        else { return nil }
        if matches(issue.original, at: issue.range, in: value) { return issue.range }

        let text = value as NSString
        let first = text.range(of: issue.original)
        guard first.location != NSNotFound,
              Range(first, in: value) != nil else { return nil }
        let nextStart = NSMaxRange(first)
        let next = text.range(of: issue.original, options: [],
                              range: NSRange(location: nextStart, length: text.length - nextStart))
        return next.location == NSNotFound ? first : nil
    }

    static func expectedValue(afterApplying issue: TextIssue, to value: String) -> String? {
        guard matches(issue.original, at: issue.range, in: value),
              TextBoundarySafety.isSingleLine(issue.original),
              TextBoundarySafety.preservesLineBreakStructure(from: issue.original, to: issue.suggestion)
        else { return nil }
        return (value as NSString).replacingCharacters(in: issue.range, with: issue.suggestion)
    }

    /// Only a confirmed exact edit permits deterministic offset shifting.
    /// Overlapping suggestions disappear because their original proof is gone.
    static func issuesAfterApplying(_ applied: TextIssue, to issues: [TextIssue],
                                   valueBefore: String, valueAfter: String) -> [TextIssue] {
        guard expectedValue(afterApplying: applied, to: valueBefore) == valueAfter else { return [] }
        let delta = (applied.suggestion as NSString).length - applied.range.length
        return issues.compactMap { issue in
            guard issue.id != applied.id,
                  matches(issue.original, at: issue.range, in: valueBefore) else { return nil }
            var updated = issue
            if issue.range.location >= NSMaxRange(applied.range) {
                updated.range.location += delta
            } else if NSMaxRange(issue.range) > applied.range.location {
                return nil
            }
            return matches(updated.original, at: updated.range, in: valueAfter) ? updated : nil
        }
    }

    static func selectionAfterReplacing(_ editedRange: NSRange, replacementLength: Int,
                                        selection: NSRange, originalLength: Int) -> NSRange? {
        guard editedRange.location >= 0, editedRange.length >= 0,
              editedRange.location <= originalLength,
              editedRange.length <= originalLength - editedRange.location,
              selection.location >= 0, selection.length >= 0,
              selection.location <= originalLength,
              selection.length <= originalLength - selection.location,
              replacementLength >= 0 else { return nil }
        let delta = replacementLength - editedRange.length
        func shifted(_ position: Int) -> Int {
            if position <= editedRange.location { return position }
            if position >= NSMaxRange(editedRange) { return position + delta }
            return editedRange.location + replacementLength
        }
        let start = shifted(selection.location)
        let end = shifted(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func matches(_ original: String, at range: NSRange, in value: String) -> Bool {
        guard range.location >= 0, range.length > 0,
              Range(range, in: value) != nil else { return false }
        return (value as NSString).substring(with: range) == original
    }
}
