import Foundation

/// One field control communicates progress without opening a card while the
/// user writes. Details appear only after explicit activation.
struct NativeAssistantState: Equatable {
    enum Phase: Equatable {
        case ready, waiting, checkingLocal, checkingAI, complete
        case unavailable(String)
    }

    var phase: Phase = .ready
    var issueCount = 0
    var scope = "draft"
    var aiAvailable = false
    var safeFixCount = 0
    var canUndo = false
    var canPauseApp = false
    var canChooseParagraph = false
    var localLimitation: String?
    var limitation: String?

    var title: String {
        switch phase {
        case .ready: return "Ready when you start writing"
        case .waiting: return "Checks update when you pause typing"
        case .checkingLocal: return "Checking spelling and basic grammar…"
        case .checkingAI: return "Checking with AI…"
        case .unavailable: return "Live checking unavailable in this editor"
        case .complete:
            return issueCount == 0 ? localLimitation == nil ? "No spelling or basic grammar suggestions" : "No suggestions in checked text"
                : "\(issueCount) writing suggestion\(issueCount == 1 ? "" : "s")"
        }
    }

    var detail: String {
        switch phase {
        case .unavailable(let reason):
            switch reason {
            case "textTooLong": return "Select a smaller section to proofread or rewrite."
            case "cannotReadText": return "This editor does not expose readable text. Select a passage and use Bean’s writing shortcut."
            case "cannotLocateRanges": return "Bean found possible corrections but could not verify their exact editing ranges. Select a passage to proofread."
            case "providerFailed", "providerNotVerified": return "Local checks are available. Connect and verify AI in Bean Settings for deeper suggestions."
            default: return "Bean cannot check this field safely. Your writing remains unchanged."
            }
        default:
            switch localLimitation {
            case "limitReached": return "Checked part of this draft. Select a shorter passage for a complete local check. Local results do not mean the text is error-free."
            case "unavailable": return "Basic checks only. Full local spelling is unavailable for this language. Local results do not mean the text is error-free."
            case "invalidResponse": return "Some local checks couldn’t finish. Check again to retry."
            default: break
            }
            if limitation != nil { return "Basic checks completed on your Mac. Deeper AI checking is temporarily unavailable; use Proofread to request a deliberate review." }
            return "Spelling and basic grammar checks run on your Mac. Local results do not mean the text is error-free."
        }
    }

    var hasSuggestions: Bool { issueCount > 0 }

    var isBusy: Bool { phase == .checkingLocal || phase == .checkingAI }
    var proofreadLabel: String { "Proofread \(scope)" }
    var rewriteLabel: String { "Rewrite \(scope)" }
}
