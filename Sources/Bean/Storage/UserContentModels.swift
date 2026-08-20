import Foundation

// Phase 3 user-created content. All Codable, all stored locally as JSON. None of
// this is API keys or user text history — only explicit configuration the user
// creates to steer Bean's output.

// A reusable writing style. Scales are 1...5 (3 = neutral).
struct StyleProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var detail: String = ""
    var formality: Int = 3
    var warmth: Int = 3
    var conciseness: Int = 3
    var directness: Int = 3
    var preferredInstructions: String = ""
    var bannedPhrases: [String] = []
    var exampleSnippets: [String] = []
    var isBuiltIn: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// Background reference the user can attach (company info, vocabulary, rules…).
struct ContextCard: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var tags: [String] = []
    var isEnabledByDefault: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// A term Bean must preserve rather than "correct" (product names, acronyms…).
struct DictionaryTerm: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var term: String
    var note: String? = nil
    var caseSensitive: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// Per app-category defaults.
struct AppRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var category: AppCategory
    var defaultStyleProfileID: UUID?
    var allowFocusedFieldFix: Bool = true
    var notes: String = ""
}

// MARK: - Built-in seeds

extension StyleProfile {
    static func builtIns() -> [StyleProfile] {
        [
            StyleProfile(name: "Default", detail: "Balanced, clear, and natural.",
                         formality: 3, warmth: 3, conciseness: 3, directness: 3,
                         preferredInstructions: "Keep it clear and natural.",
                         isBuiltIn: true),
            StyleProfile(name: "Slack Casual", detail: "Short, casual, friendly.",
                         formality: 2, warmth: 4, conciseness: 4, directness: 3,
                         preferredInstructions: "Keep it casual and friendly; contractions are fine; do not over-formalize.",
                         isBuiltIn: true),
            StyleProfile(name: "Professional", detail: "Polished and business-appropriate.",
                         formality: 4, warmth: 3, conciseness: 3, directness: 3,
                         preferredInstructions: "Polished and professional, but not stiff.",
                         isBuiltIn: true),
            StyleProfile(name: "Executive", detail: "Concise, direct, outcome-focused.",
                         formality: 4, warmth: 2, conciseness: 5, directness: 5,
                         preferredInstructions: "Be concise and direct; lead with the outcome.",
                         isBuiltIn: true),
            StyleProfile(name: "Customer-Facing", detail: "Clear, respectful, helpful.",
                         formality: 4, warmth: 4, conciseness: 3, directness: 3,
                         preferredInstructions: "Clear, respectful, and helpful; warm but professional.",
                         isBuiltIn: true)
        ]
    }
}

// MARK: - Import/export envelope (excludes API keys / logs / text history)

struct BeanPreferencesBackup: Codable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var styleProfiles: [StyleProfile]
    var contextCards: [ContextCard]
    var dictionary: [DictionaryTerm]
    var appRules: [AppRule]
    var defaultProfileID: UUID?
}

// Tolerant decoding: a backup missing a whole section decodes to an empty list
// rather than failing (and the memberwise init is preserved for export).
extension BeanPreferencesBackup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        styleProfiles = try c.decodeIfPresent([StyleProfile].self, forKey: .styleProfiles) ?? []
        contextCards = try c.decodeIfPresent([ContextCard].self, forKey: .contextCards) ?? []
        dictionary = try c.decodeIfPresent([DictionaryTerm].self, forKey: .dictionary) ?? []
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
        defaultProfileID = try c.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
    }
}
