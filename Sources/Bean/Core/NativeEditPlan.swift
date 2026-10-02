import Foundation

struct NativeTextEdit: Equatable {
    let range: NSRange
    let original: String
    let replacement: String
}

/// Exact, bounded changes to a readable native editor. Ranges always refer to
/// the original UTF-16 snapshot. Application proceeds backwards, so one edit
/// cannot move the ranges of the remaining edits.
struct NativeEditPlan: Equatable {
    let original: String
    let replacement: String
    let edits: [NativeTextEdit]

    static let maximumEdits = 64
    private static let maximumDiffCells = 2_000_000

    static func validated(original: String, edits: [NativeTextEdit]) -> Self? {
        guard edits.count <= maximumEdits else { return nil }
        let ascending = edits.sorted { $0.range.location < $1.range.location }
        var previous: NSRange?
        let source = original as NSString
        for edit in ascending {
            let range = edit.range
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
                  range.location <= source.length, range.length <= source.length - range.location,
                  isCharacterAligned(range, in: original),
                  source.substring(with: range).utf16.elementsEqual(edit.original.utf16),
                  !edit.original.utf16.elementsEqual(edit.replacement.utf16),
                  !containsProtectedStructure(edit.original), !containsProtectedStructure(edit.replacement)
            else { return nil }
            if let previous {
                guard NSMaxRange(previous) <= range.location,
                      previous.location != range.location else { return nil }
            }
            previous = range
        }
        let result = NSMutableString(string: original)
        for edit in ascending.reversed() { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return Self(original: original, replacement: result as String, edits: ascending)
    }

    /// Token anchors preserve unchanged words/whitespace; each changed run is
    /// then trimmed to its smallest Character-aligned span. Complex transforms
    /// exceed a hard work bound and are refused rather than becoming one large
    /// plain-text paste over a rich document.
    static func proofread(original: String, corrected: String) -> Self? {
        if original.utf16.elementsEqual(corrected.utf16) { return validated(original: original, edits: []) }
        guard original.count <= 50_000, corrected.count <= 50_000 else { return nil }
        let before = tokens(original), after = tokens(corrected)
        var prefix = 0
        while prefix < min(before.count, after.count), equal(before[prefix], after[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              equal(before[before.count - suffix - 1], after[after.count - suffix - 1]) { suffix += 1 }
        let left = Array(before[prefix..<(before.count - suffix)])
        let right = Array(after[prefix..<(after.count - suffix)])
        let columns = right.count + 1
        let cells = (left.count + 1).multipliedReportingOverflow(by: columns)
        guard !cells.overflow, cells.partialValue <= maximumDiffCells else { return nil }
        var lcs = [Int32](repeating: 0, count: cells.partialValue)
        if !left.isEmpty, !right.isEmpty {
            for i in stride(from: left.count - 1, through: 0, by: -1) {
                for j in stride(from: right.count - 1, through: 0, by: -1) {
                    lcs[i * columns + j] = equal(left[i], right[j])
                        ? 1 + lcs[(i + 1) * columns + j + 1]
                        : max(lcs[(i + 1) * columns + j], lcs[i * columns + j + 1])
                }
            }
        }
        var offset = before.prefix(prefix).reduce(0) { $0 + ($1 as NSString).length }
        var i = 0, j = 0, edits: [NativeTextEdit] = []
        while i < left.count || j < right.count {
            if i < left.count, j < right.count, equal(left[i], right[j]) {
                offset += (left[i] as NSString).length; i += 1; j += 1
                continue
            }
            let start = offset
            var removed = "", inserted = ""
            while i < left.count || j < right.count {
                if i < left.count, j < right.count, equal(left[i], right[j]) { break }
                if i < left.count,
                   j == right.count || lcs[(i + 1) * columns + j] >= lcs[i * columns + j + 1] {
                    removed += left[i]; offset += (left[i] as NSString).length; i += 1
                } else { inserted += right[j]; j += 1 }
            }
            let old = Array(removed), new = Array(inserted)
            var commonStart = 0
            while commonStart < min(old.count, new.count),
                  equal(String(old[commonStart]), String(new[commonStart])) { commonStart += 1 }
            var commonEnd = 0
            while commonEnd < min(old.count, new.count) - commonStart,
                  equal(String(old[old.count - commonEnd - 1]), String(new[new.count - commonEnd - 1])) { commonEnd += 1 }
            let trimmedOld = String(old[commonStart..<(old.count - commonEnd)])
            let trimmedNew = String(new[commonStart..<(new.count - commonEnd)])
            let startDelta = (String(old.prefix(commonStart)) as NSString).length
            edits.append(NativeTextEdit(range: NSRange(location: start + startDelta, length: (trimmedOld as NSString).length),
                                        original: trimmedOld, replacement: trimmedNew))
            guard edits.count <= maximumEdits else { return nil }
        }
        guard let plan = validated(original: original, edits: edits),
              plan.replacement.utf16.elementsEqual(corrected.utf16) else { return nil }
        return plan
    }

    /// The inverse ranges account for every earlier insertion/deletion. Undo
    /// uses these spans, never a plain-text replacement of the entire document.
    var inverseEdits: [NativeTextEdit] {
        var delta = 0
        var result: [NativeTextEdit] = []
        for edit in edits {
            let length = (edit.replacement as NSString).length
            let inverse = NativeTextEdit(range: NSRange(location: edit.range.location + delta, length: length),
                                         original: edit.replacement, replacement: edit.original)
            delta += length - edit.range.length
            // Adjacent deletions share the same post-edit insertion caret.
            // Collapse only that exact boundary, in original source order.
            if let previous = result.last, previous.range.location == inverse.range.location {
                result.removeLast()
                result.append(NativeTextEdit(range: NSRange(location: inverse.range.location,
                                                            length: previous.range.length + inverse.range.length),
                                              original: previous.original + inverse.original,
                                              replacement: previous.replacement + inverse.replacement))
            } else { result.append(inverse) }
        }
        return result
    }

    func selectionAfterEdits(_ selection: NSRange) -> NSRange? {
        var selection = selection, length = (original as NSString).length
        for edit in edits.reversed() {
            if selection.length == 0, edit.range.length == 0, selection.location == edit.range.location {
                // A caret immediately after the proofread passage remains
                // after punctuation inserted at that boundary.
                selection.location += (edit.replacement as NSString).length
                length += (edit.replacement as NSString).length
                continue
            }
            guard let mapped = InlineIssueMapping.selectionAfterReplacing(edit.range,
                replacementLength: (edit.replacement as NSString).length, selection: selection, originalLength: length)
            else { return nil }
            selection = mapped
            length += (edit.replacement as NSString).length - edit.range.length
        }
        return selection
    }

    private static func equal(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
    static func sourceText(in text: String, range: NSRange) -> String? {
        let value = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= value.length,
              range.length <= value.length - range.location, isCharacterAligned(range, in: text) else { return nil }
        return value.substring(with: range)
    }
    static func isCharacterAligned(_ range: NSRange, in text: String) -> Bool {
        guard let indices = Range(range, in: text) else { return false }
        return (indices.lowerBound == text.endIndex || text.indices.contains(indices.lowerBound))
            && (indices.upperBound == text.endIndex || text.indices.contains(indices.upperBound))
    }
    private static func containsProtectedStructure(_ text: String) -> Bool {
        text.contains { $0.isNewline || $0 == "\u{fffc}" }
    }
    private static func tokens(_ text: String) -> [String] {
        var result: [String] = [], current = "", category: Int?
        for character in text {
            let next = character.isNewline ? 3 : character.isLetter || character.isNumber ? 0 : character.isWhitespace ? 1 : 2
            if category != next || next >= 2 {
                if !current.isEmpty { result.append(current) }
                current = ""
            }
            current.append(character); category = next
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum NativeActionScope {
    /// A numeric caret is the only authority for paragraph scope. Trim just
    /// its separator; never infer a position from repeated strings or markers.
    static func paragraphRange(in text: String, caret: NSRange) -> NSRange? {
        let source = text as NSString
        guard caret.location >= 0, caret.length == 0, caret.location <= source.length,
              NativeEditPlan.isCharacterAligned(caret, in: text) else { return nil }
        var range = source.paragraphRange(for: caret)
        while range.length > 0,
              let character = UnicodeScalar(source.character(at: NSMaxRange(range) - 1)),
              CharacterSet.newlines.contains(character) { range.length -= 1 }
        guard range.length > 0, NativeEditPlan.isCharacterAligned(range, in: text),
              !source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return range
    }
}
