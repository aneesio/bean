import Foundation

/// Ephemeral field observations. Polling notices paste, dictation, focus moves
/// and edits from apps that omit accessibility change notifications. Content is
/// kept only while the field is focused and never written to disk or logs.
struct TypingPauseActivityTracker {
    struct Snapshot: Equatable {
        let processIdentifier: Int32
        let fieldIdentity: Int
        let value: String?
        let acceptsTextInput: Bool
    }

    enum Change: Equatable {
        case unchanged
        case focusChanged
        case textChanged
    }

    private(set) var snapshot: Snapshot?

    mutating func observe(_ next: Snapshot?) -> Change {
        defer { snapshot = next }
        guard let previous = snapshot, let next else {
            return snapshot == next ? .unchanged : .focusChanged
        }
        guard previous.processIdentifier == next.processIdentifier,
              previous.fieldIdentity == next.fieldIdentity,
              previous.acceptsTextInput == next.acceptsTextInput else { return .focusChanged }
        let sameValue: Bool
        switch (previous.value, next.value) {
        case (nil, nil): sameValue = true
        case let (before?, after?): sameValue = before.utf16.elementsEqual(after.utf16)
        default: sameValue = false
        }
        return sameValue ? .unchanged : .textChanged
    }

    mutating func reset() { snapshot = nil }
}
