import Foundation
import Combine

/// The editor's review state is tied to an exact draft revision. Neither a
/// delayed check nor a suggestion from an older draft may overwrite typing.
@MainActor
final class WritingWorkspaceModel: ObservableObject {
    struct ReviewRequest: Equatable {
        let id: UUID
        let revision: Int
        let text: String
    }

    struct RewritePreview {
        let request: ReviewRequest
        let action: WritingAction
        let text: String
        let warning: String?
    }

    private struct Change {
        let before: String
        let after: String
    }

    @Published private(set) var text = ""
    @Published private(set) var issues: [TextIssue] = []
    @Published var selectedIssueID: UUID?
    @Published private(set) var isChecking = false
    @Published private(set) var hasAIReview = false
    @Published private(set) var notice: String?
    @Published private(set) var preview: RewritePreview?
    @Published private(set) var documentName = "Untitled draft"
    @Published private(set) var documentID = UUID()
    @Published private(set) var isDirty = false
    @Published private(set) var canUndoSuggestion = false

    static let sample = "Hi team,\n\nI recieved your feedback on teh proposal. Thanks for taking the time to review it. I will send the updated version tomorow.\n\nBest,\nAlex"
    static let maximumLocalCharacters = 50_000

    private let dictionary: () -> [DictionaryTerm]
    private var localTask: Task<Void, Never>?
    private var activeRequest: ReviewRequest?
    private var revision = 0
    private var savedText = ""
    private var aiIssues: [TextIssue] = []
    private var dismissed: [TextIssue] = []
    private var changes: [Change] = []

    init(dictionary: @escaping () -> [DictionaryTerm] = { [] }) {
        self.dictionary = dictionary
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var readingTime: String {
        let minutes = max(1, Int(ceil(Double(wordCount) / 200)))
        return wordCount == 0 ? "" : "\(minutes) min read"
    }

    var selectedIssue: TextIssue? {
        issues.first { $0.id == selectedIssueID }
    }

    var localCheckingAvailable: Bool { text.count <= Self.maximumLocalCharacters }
    var hasDismissedSuggestions: Bool { !dismissed.isEmpty }

    func edit(_ value: String) {
        guard value != text else { return }
        dismissed = Self.adjustedDismissals(dismissed, from: text, to: value)
        text = value
        revision += 1
        isDirty = text != savedText
        canUndoSuggestion = changes.last?.after == text
        hasAIReview = false
        aiIssues = []
        issues = []
        selectedIssueID = nil
        notice = nil
        // A rewrite can remain visible for comparison, but applying it is
        // guarded by its revision, including an edit followed by manual undo.
        scheduleLocalCheck()
    }

    func checkLocally() {
        localTask?.cancel()
        guard text.count <= Self.maximumLocalCharacters else {
            issues = []
            notice = "This draft is too long for live checking. Open a section of up to 50,000 characters."
            return
        }
        var detector = IssueDetector()
        detector.maxIssues = 100
        let candidates = detector.localIssues(in: text, dictionary: dictionary()) + aiIssues
        // Exact ranges are supplied by the detectors; re-searching the whole
        // draft would make repeated misspellings disappear.
        issues = IssueDetector.nonOverlappingIssues(candidates.filter { issue in
            Self.matches(issue, in: text) && !dismissed.contains(where: { ignored in
                ignored.range == issue.range && ignored.original == issue.original && ignored.suggestion == issue.suggestion
            })
        }, limit: 100)
        if !issues.contains(where: { $0.id == selectedIssueID }) {
            selectedIssueID = issues.first?.id
        }
    }

    func accept(_ issue: TextIssue) {
        guard issues.contains(where: { $0.id == issue.id }), Self.matches(issue, in: text) else {
            notice = "That suggestion changed. Check the current draft again."
            checkLocally()
            return
        }
        let before = text
        let next = (text as NSString).replacingCharacters(in: issue.range, with: issue.suggestion)
        let delta = (issue.suggestion as NSString).length - issue.range.length
        let remainingAI = aiIssues.compactMap { other -> TextIssue? in
            guard other.id != issue.id,
                  NSIntersectionRange(other.range, issue.range).length == 0 else { return nil }
            var adjusted = other
            if other.range.location >= NSMaxRange(issue.range) {
                adjusted.range.location += delta
            }
            return Self.matches(adjusted, in: next) ? adjusted : nil
        }
        let reviewed = hasAIReview
        edit(next)
        aiIssues = remainingAI
        hasAIReview = reviewed
        rememberChange(before: before)
        checkLocally()
    }

    func dismiss(_ issue: TextIssue) {
        dismissed.append(issue)
        if dismissed.count > 500 { dismissed.removeFirst() }
        issues.removeAll { $0.id == issue.id }
        if selectedIssueID == issue.id { selectedIssueID = issues.first?.id }
    }

    func restoreDismissed() {
        dismissed = []
        checkLocally()
    }

    func undoSuggestion() {
        guard let change = changes.last, text == change.after else { return }
        changes.removeLast()
        edit(change.before)
        checkLocally()
    }

    func beginReview() -> ReviewRequest? {
        guard !isChecking, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard EngineConfig.providerInputIsWithinLimit(text) else {
            notice = "AI checks support up to 8,000 characters. Shorten this draft or check a smaller section."
            return nil
        }
        let request = ReviewRequest(id: UUID(), revision: revision, text: text)
        activeRequest = request
        isChecking = true
        notice = nil
        preview = nil
        return request
    }

    func completeReview(_ request: ReviewRequest, issues: [TextIssue], failure: String?) {
        guard finishRequest(request) else { return }
        guard failure == nil else {
            notice = Self.failureMessage(failure)
            return
        }
        aiIssues = issues.filter { Self.matches($0, in: text) }
        hasAIReview = true
        checkLocally()
        if self.issues.isEmpty { notice = "AI review complete. No suggestions found." }
    }

    func completeRewrite(_ request: ReviewRequest, action: WritingAction, output: String) {
        guard finishRequest(request) else { return }
        let output = TextNormalizer.sanitizeModelOutput(output, originalCore: request.text)
        var warning: String?
        if case let .suspicious(reason) = OutputSafetyValidator.validate(input: request.text, output: output, action: action) {
            guard OutputSafetyValidator.disposition(for: reason) == .reviewRequired else {
                notice = "Bean couldn't safely use that result. Your draft is unchanged. Try again."
                return
            }
            warning = OutputSafetyValidator.reviewMessage(for: reason)
        }
        guard output != request.text else {
            notice = "No changes suggested. Your draft is unchanged."
            return
        }
        preview = RewritePreview(request: request, action: action, text: output, warning: warning)
    }

    func failReview(_ request: ReviewRequest, message: String) {
        guard finishRequest(request) else { return }
        notice = message
    }

    func cancelReview() {
        activeRequest = nil
        isChecking = false
        notice = "Review cancelled. Your draft is unchanged."
    }

    var canApplyPreview: Bool {
        guard let preview else { return false }
        return preview.request.revision == revision && preview.request.text == text
    }

    func applyPreview() {
        guard let preview, canApplyPreview else {
            notice = "Your draft changed. Generate a new rewrite before applying it."
            return
        }
        let before = text
        edit(preview.text)
        self.preview = nil
        rememberChange(before: before)
        checkLocally()
    }

    func discardPreview() { preview = nil }

    func load(_ value: String, name: String, saved: Bool) {
        cancelReview()
        preview = nil
        dismissed = []
        changes = []
        documentID = UUID()
        edit(value)
        documentName = name
        savedText = saved ? value : ""
        isDirty = text != savedText
        canUndoSuggestion = false
        notice = nil
        checkLocally()
    }

    func markSaved(name: String) {
        documentName = name
        savedText = text
        isDirty = false
        notice = "Draft saved."
    }

    func showNotice(_ message: String) { notice = message }

    private func scheduleLocalCheck() {
        localTask?.cancel()
        localTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.checkLocally()
        }
    }

    private func finishRequest(_ request: ReviewRequest) -> Bool {
        guard activeRequest?.id == request.id else { return false }
        activeRequest = nil
        isChecking = false
        guard request.revision == revision, request.text == text else {
            notice = "Your draft changed during the AI check. Check again to review the current version."
            return false
        }
        return true
    }

    private func rememberChange(before: String) {
        changes.append(Change(before: before, after: text))
        if changes.count > 50 { changes.removeFirst() }
        canUndoSuggestion = true
    }

    private static func adjustedDismissals(_ issues: [TextIssue], from old: String, to new: String) -> [TextIssue] {
        guard !issues.isEmpty else { return [] }
        let before = Array(old.utf16)
        let after = Array(new.utf16)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let changed = NSRange(location: prefix, length: before.count - prefix - suffix)
        let delta = after.count - before.count
        return issues.compactMap { issue in
            var shifted = issue
            if NSMaxRange(issue.range) <= changed.location {
                // The occurrence is before the edit.
            } else if issue.range.location >= NSMaxRange(changed) {
                shifted.range.location += delta
            } else {
                return nil
            }
            return Self.matches(shifted, in: new) ? shifted : nil
        }
    }

    static func matches(_ issue: TextIssue, in text: String) -> Bool {
        let source = text as NSString
        guard issue.range.location >= 0, issue.range.location != NSNotFound,
              issue.range.length > 0, issue.range.location <= source.length,
              issue.range.length <= source.length - issue.range.location else { return false }
        return source.substring(with: issue.range) == issue.original
    }

    private static func failureMessage(_ code: String?) -> String {
        switch code {
        case "invalidAPIKey", "providerAuthenticationFailed": return "Your provider rejected the API key. Reconnect AI in Settings."
        case "timeout", "requestTimedOut": return "The AI check timed out. Your local suggestions are still available. Try again."
        case "providerInputTooLong": return "This draft exceeds the AI input limit. Check a smaller section."
        default: return "The AI check couldn't finish. Your local suggestions are still available. Check your connection and AI settings, then try again."
        }
    }
}
