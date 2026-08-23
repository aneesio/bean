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
//
// `ContextCard` was the original product/model name. Writing Context is the
// public name now; the typealias below keeps older call sites and persisted
// payloads source-compatible while the product migrates.
struct WritingContext: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var isEnabledByDefault: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        isEnabledByDefault: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isEnabledByDefault = isEnabledByDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, tags, isEnabledByDefault, createdAt, updatedAt
        // `tags` is no longer part of Bean's current model, but 1.4 and older
        // require that key when decoding a ContextCard. Encoding an empty array
        // keeps a preserved rollback copy able to read the rest of the record
        // without reviving obsolete tag data in the current app.
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        isEnabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .isEnabledByDefault) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode([String](), forKey: .tags)
        try container.encode(isEnabledByDefault, forKey: .isEnabledByDefault)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

@available(*, deprecated, renamed: "WritingContext")
typealias ContextCard = WritingContext

// A term Bean must preserve rather than "correct" (product names, acronyms…).
struct DictionaryTerm: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var term: String
    var note: String? = nil
    var caseSensitive: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

extension DictionaryTerm {
    /// User-visible normalization. It removes accidental edge whitespace and
    /// canonicalizes equivalent Unicode spellings without changing casing.
    static func normalizedDisplayTerm(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    static func foldedDuplicateKey(_ value: String) -> String {
        normalizedDisplayTerm(value).folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Two entries conflict when they are exact spelling duplicates, or when
    /// either entry asks Bean to match without regard to case. Differently
    /// cased variants can coexist only when both entries are case-sensitive.
    func conflicts(with other: DictionaryTerm) -> Bool {
        let own = Self.normalizedDisplayTerm(term)
        let theirs = Self.normalizedDisplayTerm(other.term)
        if own == theirs { return true }
        return (!caseSensitive || !other.caseSensitive)
            && Self.foldedDuplicateKey(own) == Self.foldedDuplicateKey(theirs)
    }
}

/// One cost/safety boundary shared by every provider prompt path. Callers can
/// request fewer terms, but cannot raise the shipped per-term or total ceiling.
enum DictionaryPromptFormatter {
    static let maximumTermCharacters = 80
    static let maximumPromptCharacters = 800
    static let maximumPromptUTF8Bytes = maximumPromptCharacters * 4
    static let maximumIncludedTerms = 50
    static let maximumScannedTerms = 200

    static func formattedRelevantTerms(
        from dictionary: [DictionaryTerm],
        in sourceText: String?,
        maximumTerms requestedMaximum: Int = maximumIncludedTerms
    ) -> String {
        let termLimit = min(max(0, requestedMaximum), maximumIncludedTerms)
        guard termLimit > 0 else { return "" }
        var result = ""
        var resultBytes = 0
        var included = 0

        for term in dictionary.prefix(maximumScannedTerms) where included < termLimit {
            let normalized = DictionaryTerm.normalizedDisplayTerm(term.term)
            let promptTerm = boundedSingleLine(normalized, maximum: maximumTermCharacters)
            // Reject rather than alter a preservation term. Tabs, line breaks,
            // repeated whitespace, controls, or truncation would change what
            // Bean is asking the provider to preserve.
            guard !normalized.isEmpty, promptTerm == normalized else { continue }
            if let sourceText {
                let options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive]
                guard sourceText.range(of: normalized, options: options) != nil else { continue }
            }

            let escaped = promptTerm.replacingOccurrences(of: "\"", with: "\\\"")
            let item = term.caseSensitive
                ? "\"\(escaped)\" (keep exact casing)"
                : "\"\(escaped)\""
            let separator = result.isEmpty ? "" : ", "
            guard result.count + separator.count + item.count <= maximumPromptCharacters else {
                continue
            }
            let addedBytes = separator.utf8.count + item.utf8.count
            guard addedBytes <= maximumPromptUTF8Bytes - resultBytes else { continue }
            result += separator + item
            resultBytes += addedBytes
            included += 1
        }
        return result
    }

    private static func boundedSingleLine(_ value: String, maximum: Int) -> String {
        guard maximum > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(maximum, 128))
        var needsSpace = false
        var count = 0
        var byteCount = 0
        let maximumBytes = EngineConfig.utf8ByteLimit(maximumCharacters: maximum)
        for character in value {
            if character.isWhitespace {
                needsSpace = !result.isEmpty
                continue
            }
            if needsSpace {
                guard count < maximum, byteCount < maximumBytes else { break }
                result.append(" ")
                count += 1
                byteCount += 1
                needsSpace = false
            }
            guard count < maximum else { break }
            if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                continue
            }
            let characterBytes = String(character).utf8.count
            guard characterBytes <= maximumBytes - byteCount else { break }
            result.append(character)
            count += 1
            byteCount += characterBytes
        }
        return result
    }
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
    // Stable IDs keep defaults and app rules intact across resets, imports, and
    // app upgrades. Older random built-in IDs are remapped by UserContentStore.
    static let defaultBuiltInID = UUID(uuidString: "BEA00001-0000-4000-8000-000000000001")!
    static let casualBuiltInID = UUID(uuidString: "BEA00002-0000-4000-8000-000000000002")!
    static let professionalBuiltInID = UUID(uuidString: "BEA00003-0000-4000-8000-000000000003")!
    static let executiveBuiltInID = UUID(uuidString: "BEA00004-0000-4000-8000-000000000004")!
    static let customerFacingBuiltInID = UUID(uuidString: "BEA00005-0000-4000-8000-000000000005")!
    private static let builtInCreatedAt = Date(timeIntervalSince1970: 1_787_356_800)

    static func canonicalBuiltInName(_ name: String) -> String {
        name == "Slack Casual" ? "Casual" : name
    }

    static func builtInID(named name: String) -> UUID? {
        switch canonicalBuiltInName(name) {
        case "Default": return defaultBuiltInID
        case "Casual": return casualBuiltInID
        case "Professional": return professionalBuiltInID
        case "Executive": return executiveBuiltInID
        case "Customer-Facing": return customerFacingBuiltInID
        default: return nil
        }
    }

    static func builtIns() -> [StyleProfile] {
        [
            StyleProfile(id: defaultBuiltInID, name: "Default", detail: "Balanced, clear, and natural.",
                         formality: 3, warmth: 3, conciseness: 3, directness: 3,
                         preferredInstructions: "Keep it clear and natural.",
                         isBuiltIn: true, createdAt: builtInCreatedAt, updatedAt: builtInCreatedAt),
            StyleProfile(id: casualBuiltInID, name: "Casual", detail: "Short, casual, friendly.",
                         formality: 2, warmth: 4, conciseness: 4, directness: 3,
                         preferredInstructions: "Keep it casual and friendly; contractions are fine; do not over-formalize.",
                         isBuiltIn: true, createdAt: builtInCreatedAt, updatedAt: builtInCreatedAt),
            StyleProfile(id: professionalBuiltInID, name: "Professional", detail: "Polished and business-appropriate.",
                         formality: 4, warmth: 3, conciseness: 3, directness: 3,
                         preferredInstructions: "Polished and professional, but not stiff.",
                         isBuiltIn: true, createdAt: builtInCreatedAt, updatedAt: builtInCreatedAt),
            StyleProfile(id: executiveBuiltInID, name: "Executive", detail: "Concise, direct, outcome-focused.",
                         formality: 4, warmth: 2, conciseness: 5, directness: 5,
                         preferredInstructions: "Be concise and direct; lead with the outcome.",
                         isBuiltIn: true, createdAt: builtInCreatedAt, updatedAt: builtInCreatedAt),
            StyleProfile(id: customerFacingBuiltInID, name: "Customer-Facing", detail: "Clear, respectful, helpful.",
                         formality: 4, warmth: 4, conciseness: 3, directness: 3,
                         preferredInstructions: "Clear, respectful, and helpful; warm but professional.",
                         isBuiltIn: true, createdAt: builtInCreatedAt, updatedAt: builtInCreatedAt)
        ]
    }
}

// MARK: - Import/export envelope (excludes API keys / logs / text history)

struct BeanPreferencesBackup: Codable, Equatable {
    static let currentVersion = 2
    var version: Int = currentVersion
    var styleProfiles: [StyleProfile]
    var contextCards: [WritingContext]
    var dictionary: [DictionaryTerm]
    var appRules: [AppRule]
    var defaultProfileID: UUID?
}

// MARK: - UI-friendly mutation and import results

enum DictionaryMutationResult: Equatable {
    case inserted(DictionaryTerm)
    case updated(DictionaryTerm)
    case rejectedEmpty
    case rejectedDuplicate(existingID: UUID)
    case persistenceFailed

    var succeeded: Bool {
        switch self {
        case .inserted, .updated: return true
        case .rejectedEmpty, .rejectedDuplicate, .persistenceFailed: return false
        }
    }
}

struct DictionaryImportPreview: Equatable {
    var acceptedTerms: [DictionaryTerm]
    var duplicateTerms: [String]
    var emptyLineCount: Int
    var totalLineCount: Int

    var addedCount: Int { acceptedTerms.count }
    var skippedCount: Int { duplicateTerms.count + emptyLineCount }

    static func == (lhs: DictionaryImportPreview, rhs: DictionaryImportPreview) -> Bool {
        guard lhs.duplicateTerms == rhs.duplicateTerms,
              lhs.emptyLineCount == rhs.emptyLineCount,
              lhs.totalLineCount == rhs.totalLineCount,
              lhs.acceptedTerms.count == rhs.acceptedTerms.count else { return false }
        return zip(lhs.acceptedTerms, rhs.acceptedTerms).allSatisfy { left, right in
            left.term == right.term
                && left.note == right.note
                && left.caseSensitive == right.caseSensitive
        }
    }
}

struct DictionaryImportReport: Equatable {
    var addedCount: Int
    var duplicateCount: Int
    var emptyLineCount: Int
    var persistenceSucceeded: Bool = true
}

struct PreferencesImportPreview: Equatable {
    var profileCount: Int
    var writingContextCount: Int
    var dictionaryCount: Int
    var appRuleCount: Int
    var repairedProfileReferenceCount: Int
    var skippedDictionaryDuplicateCount: Int
    var generalDefaultName: String
}

struct PreferencesImportReport: Equatable {
    var preview: PreferencesImportPreview
    var safetyBackupURL: URL
}

struct UserContentResetReport: Equatable {
    var removedArtifactCount: Int
}

enum UserContentStoreError: LocalizedError, Equatable {
    case unsupportedBackupVersion(Int)
    case invalidProfileName
    case duplicateProfileIdentifier(UUID)
    case invalidWritingContextTitle
    case duplicateWritingContextIdentifier(UUID)
    case duplicateDictionaryIdentifier(UUID)
    case duplicateAppRuleIdentifier(UUID)
    case unreadableBackup
    case unableToPreserveExistingData
    case unableToSave
    case unableToRollbackImport
    case unableToErase

    var errorDescription: String? {
        switch self {
        case .unsupportedBackupVersion(let version):
            return "This backup was created by a newer version of Bean (format \(version))."
        case .invalidProfileName:
            return "A writing profile in this backup has no name."
        case .duplicateProfileIdentifier:
            return "This backup contains duplicate writing-profile identifiers."
        case .invalidWritingContextTitle:
            return "A Writing Context item in this backup has no title."
        case .duplicateWritingContextIdentifier:
            return "This backup contains duplicate Writing Context identifiers."
        case .duplicateDictionaryIdentifier:
            return "This backup contains duplicate dictionary identifiers."
        case .duplicateAppRuleIdentifier:
            return "This backup contains duplicate app-default identifiers."
        case .unreadableBackup:
            return "Bean couldn't read this backup file."
        case .unableToPreserveExistingData:
            return "Bean couldn't create a safety copy of your current preferences."
        case .unableToSave:
            return "Bean couldn't save the imported preferences. Your existing preferences are unchanged."
        case .unableToRollbackImport:
            return "Bean couldn't finish or fully roll back this import. Stop editing and restore the safety backup before continuing."
        case .unableToErase:
            return "Bean couldn't remove every personalization file. Some Bean files may already be gone; unrelated files were left alone."
        }
    }
}

// Tolerant decoding: a backup missing a whole section decodes to an empty list
// rather than failing (and the memberwise init is preserved for export).
extension BeanPreferencesBackup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        styleProfiles = try c.decodeIfPresent([StyleProfile].self, forKey: .styleProfiles) ?? []
        contextCards = try c.decodeIfPresent([WritingContext].self, forKey: .contextCards) ?? []
        dictionary = try c.decodeIfPresent([DictionaryTerm].self, forKey: .dictionary) ?? []
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
        defaultProfileID = try c.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
    }
}
