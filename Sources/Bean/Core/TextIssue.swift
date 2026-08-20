import Foundation

// A single localized proofreading issue mapped to a range in the focused field.
// NOT persisted — issue sets live in memory only.
enum TextIssueType: String {
    case spelling, grammar, punctuation, capitalization, spacing, clarity
}

enum TextIssueSource: String {
    case local, llm, spellchecker
}

struct TextIssue: Identifiable {
    let id = UUID()
    var range: NSRange
    let original: String
    let suggestion: String
    let explanation: String?
    let type: TextIssueType
    let confidence: Double
    let source: TextIssueSource
}

// In-memory set of issues for one field snapshot. Never persisted.
struct TextIssueSet {
    let fieldFingerprint: Int
    let context: SourceAppContext
    var issues: [TextIssue]
    let generatedAt: Date
    let inputLength: Int
}

// Whether a focused field can support inline highlights.
enum FieldSupport: Equatable {
    case supported
    case degradedUsePopover(reason: String)
    case unsupported(reason: String)

    var reasonCode: String {
        switch self {
        case .supported: return "supported"
        case .degradedUsePopover(let r): return r
        case .unsupported(let r): return r
        }
    }
}
