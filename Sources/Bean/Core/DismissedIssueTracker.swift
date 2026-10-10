import Foundation

/// Dismissal belongs to an occurrence, rather than every matching word or a
/// whole-document fingerprint. Unrelated edits move the occurrence; edits
/// through it make it eligible for checking again.
struct DismissedIssueTracker {
    private struct Occurrence {
        var range: NSRange
        let original: String
        let type: TextIssueType
    }
    private var value = ""
    private var occurrences: [Occurrence] = []
    private let maximumOccurrences = 2_000

    mutating func reset(to text: String) {
        value = text
        occurrences.removeAll()
    }

    mutating func dismiss(_ issue: TextIssue) {
        guard Self.matches(issue.original, range: issue.range, in: value) else { return }
        if !contains(issue) {
            occurrences.append(.init(range: issue.range, original: issue.original, type: issue.type))
            if occurrences.count > maximumOccurrences { occurrences.removeFirst() }
        }
    }

    func contains(_ issue: TextIssue) -> Bool {
        occurrences.contains { $0.range == issue.range && $0.original == issue.original && $0.type == issue.type }
    }

    mutating func update(to text: String) {
        guard !text.utf16.elementsEqual(value.utf16) else { return }
        // A paste before and after the draft can happen within one polling
        // interval. If the entire old draft is still present exactly once,
        // all of its occurrences have an unambiguous new offset.
        if !value.isEmpty, let offset = Self.uniqueOffset(of: value, in: text) {
            occurrences = occurrences.compactMap { occurrence in
                var moved = occurrence
                moved.range.location += offset
                return Self.matches(moved.original, range: moved.range, in: text) ? moved : nil
            }
            value = text
            return
        }
        let old = Array(value), new = Array(text)
        var prefix = 0
        while prefix < min(old.count, new.count),
              String(old[prefix]).utf16.elementsEqual(String(new[prefix]).utf16) { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              String(old[old.count - suffix - 1]).utf16.elementsEqual(String(new[new.count - suffix - 1]).utf16) { suffix += 1 }
        let start = (String(old.prefix(prefix)) as NSString).length
        let removed = (String(old[prefix..<(old.count - suffix)]) as NSString).length
        let inserted = (String(new[prefix..<(new.count - suffix)]) as NSString).length
        let edit = NSRange(location: start, length: removed)
        occurrences = occurrences.compactMap { occurrence in
            var moved = occurrence
            if NSMaxRange(edit) <= occurrence.range.location {
                moved.range.location += inserted - removed
            } else if edit.location < NSMaxRange(occurrence.range) {
                return nil
            }
            return Self.matches(moved.original, range: moved.range, in: text) ? moved : nil
        }
        value = text
    }

    private static func matches(_ original: String, range: NSRange, in text: String) -> Bool {
        let value = text as NSString
        guard range.location >= 0, range.location != NSNotFound, range.length > 0,
              range.location <= value.length, range.length <= value.length - range.location else { return false }
        guard value.substring(with: range).utf16.elementsEqual(original.utf16),
              let textRange = Range(range, in: text) else { return false }
        // Appending a letter to a dismissed word edits that occurrence, even
        // though its old substring still exists at the same exact range.
        if original.first.map(isWordCharacter) == true, textRange.lowerBound > text.startIndex,
           isWordCharacter(text[text.index(before: textRange.lowerBound)]) { return false }
        if original.last.map(isWordCharacter) == true, textRange.upperBound < text.endIndex,
           isWordCharacter(text[textRange.upperBound]) { return false }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func uniqueOffset(of old: String, in text: String) -> Int? {
        let value = text as NSString
        let found = value.range(of: old, options: .literal)
        guard found.location != NSNotFound else { return nil }
        let remaining = NSRange(location: NSMaxRange(found), length: value.length - NSMaxRange(found))
        guard value.range(of: old, options: .literal, range: remaining).location == NSNotFound else { return nil }
        return found.location
    }
}
