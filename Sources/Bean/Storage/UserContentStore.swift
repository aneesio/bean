import Foundation
import Combine

enum UserContentFileLimits {
    /// Bounds both app imports/loads and the native host's dictionary-only read.
    /// Two megabytes is ample for text preferences while preventing a crafted
    /// JSON file from causing unbounded allocation or decode work.
    static let maximumEncodedBytes = 2_000_000
    static let maximumNativeDictionaryTerms = 5_000
}

// The result of resolving style + Writing Context + dictionary into prompt material.
struct Personalization {
    /// Bounded user-authored preferences for the JSON user-role payload. These
    /// values are never eligible for the provider's system-role message.
    var userContextLines: [String]
    /// Name of the style profile actually used (for the menu/preview).
    var styleName: String?
    /// Whether any Writing Context item was applied.
    var usedContext: Bool
}

// Owns all Phase 3 user content and persists it as JSON in Application Support.
// Recovers gracefully from missing/corrupt files (never crashes).
@MainActor
final class UserContentStore: ObservableObject {
    @Published private(set) var profiles: [StyleProfile]
    @Published private(set) var cards: [WritingContext]
    @Published private(set) var dictionary: [DictionaryTerm]
    @Published private(set) var appRules: [AppRule]
    @Published private(set) var defaultProfileID: UUID?
    @Published private(set) var persistenceError: String?
    @Published private(set) var preservedUnreadableFileURL: URL?

    private let fileURL: URL
    private let fileManager: FileManager
    private let atomicWrite: (Data, URL) throws -> Void
    private let setPrivateFilePermissions: (URL) throws -> Void
    private var loading = false
    private var savingBlockedToProtectUnreadableSource = false

    /// Hard prompt-only ceilings. Stored personalization remains untouched; the
    /// provider receives a deterministic bounded view so one oversized profile
    /// or dictionary cannot create an unexpectedly expensive request.
    private enum PromptLimit {
        static let styleUserText = 640
        static let styleName = 80
        static let preferredInstructions = 400
        static let bannedPhrase = 80
        static let bannedPhraseCount = 20
        static let contextText = 1_500
        static let contextLine = 500
        static let contextTitle = 80
        static let contextItemCount = 20
    }

    /// Passing an explicit file URL keeps persistence deterministic in tests and
    /// lets repair/import behavior be verified without touching live user data.
    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        atomicWrite: ((Data, URL) throws -> Void)? = nil,
        setPrivateFilePermissions: ((URL) throws -> Void)? = nil
    ) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultDirectory = support.appendingPathComponent("Bean", isDirectory: true)
        self.fileURL = fileURL ?? defaultDirectory.appendingPathComponent("userContent.json")
        self.fileManager = fileManager
        self.atomicWrite = atomicWrite ?? { data, destination in
            try ExactFileSystem.writeAtomically(
                data, to: destination, permissions: 0o600
            )
        }
        self.setPrivateFilePermissions = setPrivateFilePermissions ?? { destination in
            try ExactFileSystem.enforceRegularFilePermissions(
                destination, permissions: 0o600
            )
        }

        // Seed defaults first, then overlay any saved data.
        let builtIns = StyleProfile.builtIns()
        self.profiles = builtIns
        self.cards = []
        self.dictionary = []
        self.appRules = Self.builtInAppRules(profiles: builtIns)
        self.defaultProfileID = builtIns.first?.id
        self.persistenceError = nil
        self.preservedUnreadableFileURL = nil

        let contentDirectory = self.fileURL.deletingLastPathComponent()
        let contentAnchor = contentDirectory.deletingLastPathComponent()
        do {
            try ExactFileSystem.preparePrivateDirectory(
                contentDirectory, within: contentAnchor
            )
            switch try ExactFileSystem.entryKind(at: self.fileURL) {
            case .missing, .regularFile:
                break
            case .directory, .symbolicLink, .other:
                throw UserContentStoreError.unableToPreserveExistingData
            }
        } catch {
            self.persistenceError = "Bean couldn't prepare its private data folder. Changes may not be saved."
            self.savingBlockedToProtectUnreadableSource = true
            Log.event("userContent: data directory unavailable")
        }

        if !savingBlockedToProtectUnreadableSource { load() }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var version: Int = BeanPreferencesBackup.currentVersion
        var profiles: [StyleProfile]
        var cards: [WritingContext]
        var dictionary: [DictionaryTerm]
        var appRules: [AppRule]
        var defaultProfileID: UUID?

        init(
            version: Int = BeanPreferencesBackup.currentVersion,
            profiles: [StyleProfile],
            cards: [WritingContext],
            dictionary: [DictionaryTerm],
            appRules: [AppRule],
            defaultProfileID: UUID?
        ) {
            self.version = version
            self.profiles = profiles
            self.cards = cards
            self.dictionary = dictionary
            self.appRules = appRules
            self.defaultProfileID = defaultProfileID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            profiles = try container.decodeIfPresent([StyleProfile].self, forKey: .profiles) ?? []
            cards = try container.decodeIfPresent([WritingContext].self, forKey: .cards) ?? []
            dictionary = try container.decodeIfPresent([DictionaryTerm].self, forKey: .dictionary) ?? []
            appRules = try container.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
            defaultProfileID = try container.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
        }
    }

    private func load() {
        let data: Data
        do {
            try requireSafeContentDirectory()
            switch try ExactFileSystem.entryKind(at: fileURL) {
            case .missing:
                return // first run
            case .regularFile:
                data = try ExactFileSystem.readRegularFile(
                    at: fileURL,
                    maximumBytes: UserContentFileLimits.maximumEncodedBytes
                ).data
            case .directory, .symbolicLink, .other:
                throw UserContentStoreError.unableToSave
            }
        } catch {
            savingBlockedToProtectUnreadableSource = true
            persistenceError = "Bean couldn't read its saved personalization data. The original file is protected from being overwritten."
            Log.event("userContent: stored file inaccessible; saving blocked")
            return
        }

        do {
            let decoded = try JSONDecoder().decode(Persisted.self, from: data)
            guard decoded.version <= BeanPreferencesBackup.currentVersion else {
                throw UserContentStoreError.unsupportedBackupVersion(decoded.version)
            }
            let normalized = try Self.normalizedState(
                profiles: decoded.profiles,
                writingContexts: decoded.cards,
                dictionary: decoded.dictionary,
                appRules: decoded.appRules,
                defaultProfileID: decoded.defaultProfileID
            )
            apply(normalized.state)
            if normalized.changed || decoded.version != BeanPreferencesBackup.currentVersion { _ = save() }
        } catch {
            preserveUnreadableSource(data)
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !loading else { return true }
        guard !savingBlockedToProtectUnreadableSource else {
            persistenceError = "Bean is protecting an unreadable personalization file. Move or restore that file before saving new changes."
            return false
        }
        let diskSnapshot: PersistenceDiskSnapshot
        do {
            diskSnapshot = try capturePersistenceDiskSnapshot()
        } catch {
            persistenceError = "Bean couldn't safely access its personalization file. Changes were not saved."
            return false
        }
        do {
            try persist(currentState)
            persistenceError = nil
            return true
        } catch {
            do {
                try restorePersistenceDiskSnapshot(diskSnapshot)
                persistenceError = "Bean couldn't save personalization data. Your latest changes may be temporary."
            } catch {
                persistenceError = "Bean couldn't save or fully restore personalization data. Stop editing and restore a backup before continuing."
                savingBlockedToProtectUnreadableSource = true
            }
            Log.event("userContent: save failed")
            return false
        }
    }

    var writingContexts: [WritingContext] {
        cards
    }

    private func preserveUnreadableSource(_ data: Data) {
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        var recoveryURL = directory.appendingPathComponent("\(stem)-unreadable.\(ext)")
        var suffix = 2
        do {
            while try ExactFileSystem.entryKind(at: recoveryURL) != .missing {
                recoveryURL = directory.appendingPathComponent("\(stem)-unreadable-\(suffix).\(ext)")
                suffix += 1
            }
            try writePrivateData(
                data,
                to: recoveryURL,
                allowReplacingRegularFile: false
            )
            preservedUnreadableFileURL = recoveryURL
            savingBlockedToProtectUnreadableSource = false
            persistenceError = "Bean couldn't read its saved personalization data. Defaults are in use, and the original data was preserved for recovery."
            Log.event("userContent: stored file unreadable; recovery copy created")
        } catch {
            savingBlockedToProtectUnreadableSource = true
            persistenceError = "Bean couldn't read or safely preserve its saved personalization data. Saving is blocked so the original is not overwritten."
            Log.event("userContent: unreadable file could not be preserved; saving blocked")
        }
    }

    // MARK: - CRUD

    func profile(_ id: UUID?) -> StyleProfile? { profiles.first { $0.id == id } }

    @discardableResult
    func upsert(_ profile: StyleProfile) -> Bool {
        // Built-in profiles are read-only; edits are ignored (duplicate instead).
        if let existing = self.profile(profile.id), existing.isBuiltIn { return false }
        var updated = profile
        updated.isBuiltIn = false
        updated.updatedAt = Date()
        return commitMutation {
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = updated
            } else {
                profiles.append(updated)
            }
        }
    }

    /// Restores the five built-in profiles to their shipped state, keeping any
    /// custom profiles intact.
    @discardableResult
    func resetBuiltIns() -> Bool {
        let oldBuiltIns = profiles.filter(\.isBuiltIn)
        var remapping: [UUID: UUID] = [:]
        for old in oldBuiltIns {
            if let replacement = StyleProfile.builtInID(named: old.name) {
                remapping[old.id] = replacement
            }
        }
        let customProfiles = profiles.filter { !$0.isBuiltIn }
        return commitMutation {
            profiles = StyleProfile.builtIns() + customProfiles

            if let currentDefault = defaultProfileID, let replacement = remapping[currentDefault] {
                defaultProfileID = replacement
            }
            for index in appRules.indices {
                guard let selected = appRules[index].defaultStyleProfileID,
                      let replacement = remapping[selected] else { continue }
                appRules[index].defaultStyleProfileID = replacement
            }
            repairProfileReferences()
        }
    }

    @discardableResult
    func deleteProfile(_ id: UUID) -> Bool {
        guard let p = profile(id), !p.isBuiltIn else { return false } // built-ins protected
        return commitMutation {
            profiles.removeAll { $0.id == id }
            repairProfileReferences()
        }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Bool {
        guard let p = profile(id) else { return false }
        var copy = p
        copy.id = UUID(); copy.name = p.name + " Copy"; copy.isBuiltIn = false
        copy.createdAt = Date(); copy.updatedAt = Date()
        return commitMutation { profiles.append(copy) }
    }

    @discardableResult
    func setDefaultProfile(_ id: UUID) -> Bool {
        guard profile(id) != nil else { return false }
        return commitMutation { defaultProfileID = id }
    }

    @discardableResult
    func upsert(_ writingContext: WritingContext) -> Bool {
        var updated = writingContext
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty else { return false }
        updated.updatedAt = Date()
        return commitMutation {
            if let idx = cards.firstIndex(where: { $0.id == writingContext.id }) {
                cards[idx] = updated
            } else {
                cards.append(updated)
            }
        }
    }

    @discardableResult
    func deleteWritingContext(_ id: UUID) -> Bool {
        guard cards.contains(where: { $0.id == id }) else { return false }
        return commitMutation { cards.removeAll { $0.id == id } }
    }

    @available(*, deprecated, renamed: "deleteWritingContext")
    @discardableResult
    func deleteCard(_ id: UUID) -> Bool {
        deleteWritingContext(id)
    }

    @discardableResult
    func upsert(_ term: DictionaryTerm) -> DictionaryMutationResult {
        var updated = term
        updated.term = DictionaryTerm.normalizedDisplayTerm(term.term)
        updated.note = term.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.note?.isEmpty == true { updated.note = nil }
        guard !updated.term.isEmpty else { return .rejectedEmpty }
        if let duplicate = dictionary.first(where: { $0.id != updated.id && $0.conflicts(with: updated) }) {
            return .rejectedDuplicate(existingID: duplicate.id)
        }

        updated.updatedAt = Date()
        if let idx = dictionary.firstIndex(where: { $0.id == updated.id }) {
            return commitMutation({ dictionary[idx] = updated })
                ? .updated(updated)
                : .persistenceFailed
        }
        return commitMutation({ dictionary.append(updated) })
            ? .inserted(updated)
            : .persistenceFailed
    }

    @discardableResult
    func deleteTerm(_ id: UUID) -> Bool {
        guard dictionary.contains(where: { $0.id == id }) else { return false }
        return commitMutation { dictionary.removeAll { $0.id == id } }
    }

    func previewTermImport(newlineSeparated text: String) -> DictionaryImportPreview {
        let normalizedNewlines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalizedNewlines.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() } // a normal final newline is not an extra entry

        var candidates = dictionary
        var accepted: [DictionaryTerm] = []
        var duplicates: [String] = []
        var emptyCount = 0
        for rawLine in lines {
            let display = DictionaryTerm.normalizedDisplayTerm(rawLine)
            guard !display.isEmpty else {
                emptyCount += 1
                continue
            }
            let candidate = DictionaryTerm(term: display)
            guard !candidates.contains(where: { $0.conflicts(with: candidate) }) else {
                duplicates.append(display)
                continue
            }
            candidates.append(candidate)
            accepted.append(candidate)
        }
        return DictionaryImportPreview(
            acceptedTerms: accepted,
            duplicateTerms: duplicates,
            emptyLineCount: emptyCount,
            totalLineCount: lines.count
        )
    }

    @discardableResult
    func importTerms(newlineSeparated text: String) -> DictionaryImportReport {
        let preview = previewTermImport(newlineSeparated: text)
        let persisted = preview.acceptedTerms.isEmpty
            || commitMutation { dictionary.append(contentsOf: preview.acceptedTerms) }
        return DictionaryImportReport(
            addedCount: persisted ? preview.addedCount : 0,
            duplicateCount: preview.duplicateTerms.count,
            emptyLineCount: preview.emptyLineCount,
            persistenceSucceeded: persisted
        )
    }
    var dictionaryExport: String { dictionary.map(\.term).joined(separator: "\n") }

    func dictionaryExportData() -> Data {
        Data(dictionaryExport.utf8)
    }

    func exportDictionary(to destination: URL) throws {
        try dictionaryExportData().write(to: destination, options: [.atomic])
    }

    @discardableResult
    func setAppRuleStyle(category: AppCategory, profileID: UUID?) -> Bool {
        // nil is an explicit selection: inherit the General default. Rejecting
        // unknown IDs here prevents callers from creating a dangling rule.
        if let profileID, profile(profileID) == nil { return false }
        return commitMutation {
            if let idx = appRules.firstIndex(where: { $0.category == category }) {
                appRules[idx].defaultStyleProfileID = profileID
            } else {
                appRules.append(AppRule(category: category, defaultStyleProfileID: profileID))
            }
        }
    }

    /// nil means “Use General Default,” including when no category rule exists.
    func appRuleStyle(category: AppCategory) -> UUID? {
        appRules.first { $0.category == category }?.defaultStyleProfileID
    }

    // MARK: - Import / export

    func exportBackup() -> BeanPreferencesBackup {
        BeanPreferencesBackup(styleProfiles: profiles, contextCards: cards,
                              dictionary: dictionary, appRules: appRules,
                              defaultProfileID: defaultProfileID)
    }

    func encodedBackup(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(exportBackup())
    }

    func previewBackupImport(data: Data) throws -> PreferencesImportPreview {
        try Self.decodeAndNormalizeBackup(data).preview
    }

    func suggestedPreImportBackupURL(now: Date = Date()) throws -> URL {
        try requireSafeContentDirectory()
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let stamp = Int(now.timeIntervalSince1970)
        var candidate = directory.appendingPathComponent("Bean-before-import-\(stamp).json")
        var suffix = 2
        while try ExactFileSystem.entryKind(at: candidate) != .missing {
            candidate = directory.appendingPathComponent("Bean-before-import-\(stamp)-\(suffix).json")
            suffix += 1
        }
        return candidate
    }

    /// Decodes and validates the complete candidate before doing any writes,
    /// then creates an atomic safety backup before replacing live preferences.
    /// A persistence failure restores the in-memory state; the atomic file write
    /// leaves the previous on-disk state intact.
    @discardableResult
    func importBackup(data: Data, preImportBackupURL: URL? = nil) throws -> PreferencesImportReport {
        guard !savingBlockedToProtectUnreadableSource else {
            throw UserContentStoreError.unableToPreserveExistingData
        }
        let normalized = try Self.decodeAndNormalizeBackup(data)
        let contentDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
        let safetyURL: URL
        let safetyData: Data
        do {
            try requireSafeContentDirectory()
            let backupDirectory: URL
            if let preImportBackupURL {
                safetyURL = preImportBackupURL.standardizedFileURL
                backupDirectory = safetyURL.deletingLastPathComponent()
            } else {
                backupDirectory = contentDirectory.appendingPathComponent(
                    "Backups", isDirectory: true
                )
                try ExactFileSystem.preparePrivateDirectory(
                    backupDirectory, within: contentDirectory
                )
                safetyURL = try suggestedPreImportBackupURL()
            }
            let rootPrefix = contentDirectory.path.hasSuffix("/")
                ? contentDirectory.path : contentDirectory.path + "/"
            guard safetyURL.path.hasPrefix(rootPrefix),
                  safetyURL.deletingLastPathComponent().path.hasPrefix(rootPrefix)
                    || safetyURL.deletingLastPathComponent() == contentDirectory else {
                throw UserContentStoreError.unableToPreserveExistingData
            }
            try ExactFileSystem.preparePrivateDirectory(
                backupDirectory, within: contentDirectory
            )
            guard try ExactFileSystem.entryKind(at: safetyURL) == .missing else {
                throw UserContentStoreError.unableToPreserveExistingData
            }
            safetyData = try encodedBackup(prettyPrinted: true)
            try writePrivateData(
                safetyData,
                to: safetyURL,
                allowReplacingRegularFile: false
            )
        } catch {
            throw UserContentStoreError.unableToPreserveExistingData
        }

        let previous = currentState
        let diskSnapshot: PersistenceDiskSnapshot
        do {
            diskSnapshot = try capturePersistenceDiskSnapshot()
        } catch {
            throw UserContentStoreError.unableToSave
        }
        apply(normalized.state)
        do {
            try persist(normalized.state)
            persistenceError = nil
        } catch {
            apply(previous)
            do {
                try restorePersistenceDiskSnapshot(diskSnapshot)
            } catch {
                persistenceError = UserContentStoreError.unableToRollbackImport.localizedDescription
                savingBlockedToProtectUnreadableSource = true
                throw UserContentStoreError.unableToRollbackImport
            }
            persistenceError = UserContentStoreError.unableToSave.localizedDescription
            throw UserContentStoreError.unableToSave
        }
        return PreferencesImportReport(preview: normalized.preview, safetyBackupURL: safetyURL)
    }

    /// Compatibility path for older callers. New UI should preview the encoded
    /// data first, then call the throwing transaction above and show its result.
    func importBackup(_ backup: BeanPreferencesBackup) {
        do {
            let data = try JSONEncoder().encode(backup)
            _ = try importBackup(data: data)
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    @discardableResult
    func resetToDefaults() -> Bool {
        commitMutation {
            profiles = StyleProfile.builtIns()
            cards = []
            dictionary = []
            appRules = Self.builtInAppRules(profiles: profiles)
            defaultProfileID = StyleProfile.defaultBuiltInID
        }
    }

    /// Removes only the artifacts this store owns: its exact JSON file,
    /// unreadable recovery copies with Bean's generated naming scheme, and
    /// automatic pre-import backups. It never recursively removes the content
    /// root, and it leaves unrelated sibling files untouched.
    @discardableResult
    func eraseAllUserContentArtifacts() throws -> UserContentResetReport {
        let root = fileURL.deletingLastPathComponent().standardizedFileURL
        guard root.path != "/" else { throw UserContentStoreError.unableToErase }
        do {
            try requireSafeContentDirectory()
        } catch {
            throw UserContentStoreError.unableToErase
        }

        var targets: [URL] = []
        do {
            switch try ExactFileSystem.entryKind(at: fileURL) {
            case .missing:
                break
            case .regularFile:
                targets.append(fileURL)
            case .directory, .symbolicLink, .other:
                throw UserContentStoreError.unableToErase
            }
        } catch {
            throw UserContentStoreError.unableToErase
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        let rootItems: [URL]
        do {
            rootItems = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw UserContentStoreError.unableToErase
        }
        targets.append(contentsOf: rootItems.filter {
            Self.isGeneratedRecoveryFile($0.lastPathComponent, stem: stem, extension: ext)
        })

        let backupsDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        var removeBackupsDirectoryWhenEmpty = false
        do {
            switch try ExactFileSystem.entryKind(at: backupsDirectory) {
            case .missing:
                break
            case .directory:
                try ExactFileSystem.requireRealDirectoryChain(
                    from: root, through: backupsDirectory
                )
                let backupItems = try fileManager.contentsOfDirectory(
                    at: backupsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                targets.append(contentsOf: backupItems.filter {
                    Self.isGeneratedImportBackup($0.lastPathComponent)
                })
                removeBackupsDirectoryWhenEmpty = true
            case .regularFile, .symbolicLink, .other:
                throw UserContentStoreError.unableToErase
            }
        } catch {
            throw UserContentStoreError.unableToErase
        }

        // Preflight every candidate before the first deletion. A generated file
        // name that is actually a directory is not recursively removed.
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for target in targets {
            let standardized = target.standardizedFileURL
            guard standardized.path.hasPrefix(rootPrefix) else {
                throw UserContentStoreError.unableToErase
            }
            guard try ExactFileSystem.entryKind(at: target) == .regularFile else {
                throw UserContentStoreError.unableToErase
            }
        }

        var removed = 0
        do {
            for target in targets {
                try ExactFileSystem.unlinkRegularFile(at: target)
                removed += 1
            }
            if removeBackupsDirectoryWhenEmpty,
               let remaining = try? fileManager.contentsOfDirectory(atPath: backupsDirectory.path),
               remaining.isEmpty {
                try ExactFileSystem.removeEmptyDirectory(at: backupsDirectory)
                removed += 1
            }
        } catch {
            throw UserContentStoreError.unableToErase
        }

        apply(ContentState(
            profiles: StyleProfile.builtIns(),
            writingContexts: [],
            dictionary: [],
            appRules: Self.builtInAppRules(profiles: StyleProfile.builtIns()),
            defaultProfileID: StyleProfile.defaultBuiltInID
        ))
        persistenceError = nil
        preservedUnreadableFileURL = nil
        savingBlockedToProtectUnreadableSource = false
        return UserContentResetReport(removedArtifactCount: removed)
    }

    // MARK: - Resolution

    /// The profile that applies for an action in a given app context:
    /// explicit selection → app-category default → global default → first.
    func effectiveProfile(explicit: UUID?, context: SourceAppContext?) -> StyleProfile {
        if let explicit, let p = profile(explicit) { return p }
        if let context, let rule = appRules.first(where: { $0.category == AppCategory.from(bundleIdentifier: context.bundleIdentifier) }),
           let p = profile(rule.defaultStyleProfileID) {
            return p
        }
        if let p = profile(defaultProfileID) { return p }
        return profiles.first ?? StyleProfile(name: "Default", isBuiltIn: true)
    }

    // MARK: - Prompt material

    func personalization(action: WritingAction, context: SourceAppContext?, explicitProfile: UUID?,
                         sourceText: String? = nil) -> Personalization {
        let profile = effectiveProfile(explicit: explicitProfile, context: context)
        let isProofread = action == .proofread

        var preferenceLines: [String] = []
        if !isProofread {
            var styleBudget = PromptLimit.styleUserText
            let boundedName = consumePromptText(
                profile.name,
                maximum: min(PromptLimit.styleName, styleBudget),
                remainingBudget: &styleBudget
            )
            let promptName = boundedName.isEmpty ? "Default" : boundedName
            let instructions = consumePromptText(
                profile.preferredInstructions,
                maximum: min(PromptLimit.preferredInstructions, styleBudget),
                remainingBudget: &styleBudget
            )
            let banned = boundedPromptList(
                profile.bannedPhrases.prefix(PromptLimit.bannedPhraseCount),
                perItemLimit: PromptLimit.bannedPhrase,
                remainingBudget: &styleBudget
            )
            let instructionSuffix = instructions.isEmpty ? "" : " \(instructions)"
            preferenceLines.append("Target style \"\(promptName)\": formality \(scale(profile.formality)), warmth \(scale(profile.warmth)), conciseness \(scale(profile.conciseness)), directness \(scale(profile.directness)).\(instructionSuffix)")
            if !banned.isEmpty {
                preferenceLines.append("Avoid these phrases: \(banned).")
            }
        }

        // Send only dictionary terms that actually occur in this request. Large
        // dictionaries previously went into every prompt even when irrelevant.
        let terms = DictionaryPromptFormatter.formattedRelevantTerms(
            from: dictionary,
            in: sourceText
        )
        if !terms.isEmpty {
            preferenceLines.append("Preserve terms: \(terms)")
        }

        // Mechanical proofreading does not need style profiles, examples, or
        // Writing Context. Omitting it reduces both cost and unwanted rewrites.
        if isProofread {
            return Personalization(
                userContextLines: preferenceLines,
                styleName: nil, usedContext: false
            )
        }

        // Writing Context and style examples remain untrusted user-role data.
        let enabledCards = cards.filter { $0.isEnabledByDefault }

        // Build context lines within the char budget.
        var contextLines: [String] = []
        var budget = PromptLimit.contextText
        var usedContext = false
        let contextStyleName = boundedSingleLine(profile.name, maximum: PromptLimit.styleName)
        appendContextLine(
            "style: \(contextStyleName.isEmpty ? "Default" : contextStyleName)",
            to: &contextLines,
            remainingBudget: &budget
        )
        for snippet in profile.exampleSnippets.prefix(PromptLimit.contextItemCount) {
            let available = max(0, PromptLimit.contextLine - "styleExample: ".count)
            let bounded = boundedSingleLine(snippet, maximum: available)
            guard !bounded.isEmpty else { continue }
            appendContextLine(
                "styleExample: \(bounded)",
                to: &contextLines,
                remainingBudget: &budget
            )
            if budget == 0 { break }
        }
        for card in enabledCards.prefix(PromptLimit.contextItemCount) {
            let title = boundedSingleLine(card.title, maximum: PromptLimit.contextTitle)
            let prefix = "writingContext[\(title.isEmpty ? "Untitled" : title)]: "
            let available = max(0, PromptLimit.contextLine - prefix.count)
            let content = boundedSingleLine(card.content, maximum: available)
            guard !content.isEmpty else { continue }
            let countBeforeAppend = contextLines.count
            appendContextLine(
                prefix + content,
                to: &contextLines,
                remainingBudget: &budget
            )
            if contextLines.count > countBeforeAppend { usedContext = true }
            if budget == 0 { break }
        }

        return Personalization(
            userContextLines: preferenceLines + contextLines,
            styleName: profile.name,
            usedContext: usedContext
        )
    }

    private func boundedSingleLine(_ value: String, maximum: Int) -> String {
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
            // Skip non-whitespace control characters instead of allowing them
            // to create hidden prompt structure.
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

    private func consumePromptText(
        _ value: String,
        maximum: Int,
        remainingBudget: inout Int
    ) -> String {
        let bounded = boundedSingleLine(value, maximum: max(0, min(maximum, remainingBudget)))
        remainingBudget -= bounded.count
        return bounded
    }

    private func boundedPromptList<S: Sequence>(
        _ values: S,
        perItemLimit: Int,
        remainingBudget: inout Int
    ) -> String where S.Element == String {
        var result = ""
        for value in values where remainingBudget > 0 {
            let separator = result.isEmpty ? "" : "; "
            guard separator.count < remainingBudget else { break }
            let itemBudget = min(perItemLimit, remainingBudget - separator.count)
            let item = boundedSingleLine(value, maximum: itemBudget)
            guard !item.isEmpty else { continue }
            result += separator + item
            remainingBudget -= separator.count + item.count
        }
        return result
    }

    private func appendContextLine(
        _ line: String,
        to lines: inout [String],
        remainingBudget: inout Int
    ) {
        guard !line.isEmpty, line.count <= PromptLimit.contextLine else { return }
        let newlineCost = lines.isEmpty ? 0 : 1
        let totalCost = newlineCost + line.count
        guard totalCost <= remainingBudget else { return }
        lines.append(line)
        remainingBudget -= totalCost
    }

    private func scale(_ value: Int) -> String {
        switch value {
        case ...1: return "very low"
        case 2: return "low"
        case 3: return "medium"
        case 4: return "high"
        default: return "very high"
        }
    }

    // MARK: - State validation and repair

    private struct ContentState: Equatable {
        var profiles: [StyleProfile]
        var writingContexts: [WritingContext]
        var dictionary: [DictionaryTerm]
        var appRules: [AppRule]
        var defaultProfileID: UUID?
    }

    private enum PersistenceDiskSnapshot: Equatable {
        case absent
        case file(data: Data)
    }

    private struct NormalizedState {
        var state: ContentState
        var changed: Bool
        var repairedProfileReferenceCount: Int
        var skippedDictionaryDuplicateCount: Int
    }

    private struct NormalizedImport {
        var state: ContentState
        var preview: PreferencesImportPreview
    }

    private var currentState: ContentState {
        ContentState(
            profiles: profiles,
            writingContexts: cards,
            dictionary: dictionary,
            appRules: appRules,
            defaultProfileID: defaultProfileID
        )
    }

    /// Executes every user-content edit as one memory+disk transaction. The
    /// previous published state is restored before returning false, so the UI
    /// never celebrates a change that will disappear on relaunch.
    private func commitMutation(_ mutation: () -> Void) -> Bool {
        guard !savingBlockedToProtectUnreadableSource else {
            persistenceError = "Bean is protecting an unreadable personalization file. Changes were not made."
            return false
        }
        let previous = currentState
        let diskSnapshot: PersistenceDiskSnapshot
        do {
            diskSnapshot = try capturePersistenceDiskSnapshot()
        } catch {
            persistenceError = "Bean couldn't safely access its personalization file. Changes were not made."
            return false
        }

        mutation()
        do {
            try persist(currentState)
            persistenceError = nil
            return true
        } catch {
            apply(previous)
            do {
                try restorePersistenceDiskSnapshot(diskSnapshot)
                persistenceError = "Bean couldn't save that change. Your previous personalization is unchanged."
            } catch {
                persistenceError = "Bean couldn't save or fully restore personalization data. Stop editing and restore a backup before continuing."
                savingBlockedToProtectUnreadableSource = true
            }
            Log.event("userContent: mutation persistence failed; state restored")
            return false
        }
    }

    private func apply(_ state: ContentState) {
        let wasLoading = loading
        loading = true
        profiles = state.profiles
        cards = state.writingContexts
        dictionary = state.dictionary
        appRules = state.appRules
        defaultProfileID = state.defaultProfileID
        loading = wasLoading
    }

    private func persist(_ state: ContentState) throws {
        guard !savingBlockedToProtectUnreadableSource else {
            throw UserContentStoreError.unableToPreserveExistingData
        }
        let persisted = Persisted(
            profiles: state.profiles,
            cards: state.writingContexts,
            dictionary: state.dictionary,
            appRules: state.appRules,
            defaultProfileID: state.defaultProfileID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(persisted)
        guard data.count <= UserContentFileLimits.maximumEncodedBytes else {
            throw UserContentStoreError.unableToSave
        }
        try writePrivateData(data, to: fileURL, allowReplacingRegularFile: true)
    }

    private func capturePersistenceDiskSnapshot() throws -> PersistenceDiskSnapshot {
        try requireSafeContentDirectory()
        switch try ExactFileSystem.entryKind(at: fileURL) {
        case .missing:
            return .absent
        case .regularFile:
            let snapshot = try ExactFileSystem.readRegularFile(
                at: fileURL,
                maximumBytes: UserContentFileLimits.maximumEncodedBytes
            )
            return .file(data: snapshot.data)
        case .directory, .symbolicLink, .other:
            throw UserContentStoreError.unableToSave
        }
    }

    private func restorePersistenceDiskSnapshot(_ snapshot: PersistenceDiskSnapshot) throws {
        try requireSafeContentDirectory()
        switch snapshot {
        case .absent:
            switch try ExactFileSystem.entryKind(at: fileURL) {
            case .missing:
                return
            case .regularFile:
                try ExactFileSystem.unlinkRegularFile(at: fileURL)
            case .directory, .symbolicLink, .other:
                throw UserContentStoreError.unableToRollbackImport
            }
        case .file(let data):
            switch try ExactFileSystem.entryKind(at: fileURL) {
            case .missing, .regularFile:
                try writePrivateData(data, to: fileURL, allowReplacingRegularFile: true)
            case .directory, .symbolicLink, .other:
                throw UserContentStoreError.unableToRollbackImport
            }
        }
    }

    /// All app-owned writes share one exact-file pre/postflight. The injected
    /// writer and permission seams remain available for transactional tests,
    /// while production defaults use O_NOFOLLOW + a 0600 temp-file rename.
    private func writePrivateData(
        _ data: Data,
        to destination: URL,
        allowReplacingRegularFile: Bool
    ) throws {
        let contentDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
        let contentAnchor = contentDirectory.deletingLastPathComponent()
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        try ExactFileSystem.requireRealDirectoryChain(
            from: contentAnchor,
            through: parent
        )
        let contentPrefix = contentDirectory.path.hasSuffix("/")
            ? contentDirectory.path : contentDirectory.path + "/"
        guard parent == contentDirectory || parent.path.hasPrefix(contentPrefix) else {
            throw UserContentStoreError.unableToPreserveExistingData
        }
        let initialKind = try ExactFileSystem.entryKind(at: destination)
        guard initialKind == .missing
                || (allowReplacingRegularFile && initialKind == .regularFile) else {
            throw UserContentStoreError.unableToPreserveExistingData
        }
        try atomicWrite(data, destination)
        guard try ExactFileSystem.entryKind(at: destination) == .regularFile else {
            throw UserContentStoreError.unableToPreserveExistingData
        }
        try setPrivateFilePermissions(destination)
        guard try ExactFileSystem.entryKind(at: destination) == .regularFile else {
            throw UserContentStoreError.unableToPreserveExistingData
        }
    }

    private func requireSafeContentDirectory() throws {
        let contentDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
        try ExactFileSystem.requireRealDirectoryChain(
            from: contentDirectory.deletingLastPathComponent(),
            through: contentDirectory
        )
    }

    private func repairProfileReferences() {
        let validIDs = Set(profiles.map(\.id))
        if defaultProfileID.flatMap({ validIDs.contains($0) ? $0 : nil }) == nil {
            defaultProfileID = validIDs.contains(StyleProfile.defaultBuiltInID)
                ? StyleProfile.defaultBuiltInID
                : profiles.first?.id
        }
        for index in appRules.indices {
            if let selected = appRules[index].defaultStyleProfileID,
               !validIDs.contains(selected) {
                appRules[index].defaultStyleProfileID = nil
            }
        }
    }

    private static func decodeAndNormalizeBackup(_ data: Data) throws -> NormalizedImport {
        guard data.count <= UserContentFileLimits.maximumEncodedBytes else {
            throw UserContentStoreError.unreadableBackup
        }
        let backup: BeanPreferencesBackup
        do {
            backup = try JSONDecoder().decode(BeanPreferencesBackup.self, from: data)
        } catch {
            throw UserContentStoreError.unreadableBackup
        }
        guard backup.version <= BeanPreferencesBackup.currentVersion else {
            throw UserContentStoreError.unsupportedBackupVersion(backup.version)
        }
        let normalized = try normalizedState(
            profiles: backup.styleProfiles,
            writingContexts: backup.contextCards,
            dictionary: backup.dictionary,
            appRules: backup.appRules,
            defaultProfileID: backup.defaultProfileID
        )
        let defaultName = normalized.state.profiles.first {
            $0.id == normalized.state.defaultProfileID
        }?.name ?? "Default"
        return NormalizedImport(
            state: normalized.state,
            preview: PreferencesImportPreview(
                profileCount: normalized.state.profiles.count,
                writingContextCount: normalized.state.writingContexts.count,
                dictionaryCount: normalized.state.dictionary.count,
                appRuleCount: normalized.state.appRules.count,
                repairedProfileReferenceCount: normalized.repairedProfileReferenceCount,
                skippedDictionaryDuplicateCount: normalized.skippedDictionaryDuplicateCount,
                generalDefaultName: defaultName
            )
        )
    }

    private static func isGeneratedRecoveryFile(
        _ filename: String,
        stem: String,
        extension fileExtension: String
    ) -> Bool {
        let exact = "\(stem)-unreadable.\(fileExtension)"
        if filename == exact { return true }
        let prefix = "\(stem)-unreadable-"
        let suffix = ".\(fileExtension)"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return false }
        let numberStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let numberEnd = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let number = filename[numberStart..<numberEnd]
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    private static func isGeneratedImportBackup(_ filename: String) -> Bool {
        let prefix = "Bean-before-import-"
        let suffix = ".json"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return false }
        let bodyStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let bodyEnd = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let pieces = filename[bodyStart..<bodyEnd].split(separator: "-", omittingEmptySubsequences: false)
        return (pieces.count == 1 || pieces.count == 2)
            && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func normalizedState(
        profiles inputProfiles: [StyleProfile],
        writingContexts inputContexts: [WritingContext],
        dictionary inputDictionary: [DictionaryTerm],
        appRules inputRules: [AppRule],
        defaultProfileID inputDefaultProfileID: UUID?
    ) throws -> NormalizedState {
        let original = ContentState(
            profiles: inputProfiles,
            writingContexts: inputContexts,
            dictionary: inputDictionary,
            appRules: inputRules,
            defaultProfileID: inputDefaultProfileID
        )

        var seenInputProfileIDs = Set<UUID>()
        for profile in inputProfiles where !seenInputProfileIDs.insert(profile.id).inserted {
            throw UserContentStoreError.duplicateProfileIdentifier(profile.id)
        }

        let shipped = StyleProfile.builtIns()
        var customProfiles: [StyleProfile] = []
        var idRemapping: [UUID: UUID] = [:]
        var seenOutputIDs = Set<UUID>()

        for originalProfile in inputProfiles {
            var profile = originalProfile
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.name.isEmpty else { throw UserContentStoreError.invalidProfileName }

            if profile.isBuiltIn, let stableID = StyleProfile.builtInID(named: profile.name) {
                profile.name = StyleProfile.canonicalBuiltInName(profile.name)
                idRemapping[profile.id] = stableID
                profile.id = stableID
                guard seenOutputIDs.insert(stableID).inserted else {
                    throw UserContentStoreError.duplicateProfileIdentifier(stableID)
                }
            } else {
                // An obsolete built-in is preserved as editable user content
                // instead of being silently deleted during an upgrade.
                if profile.isBuiltIn { profile.isBuiltIn = false }
                guard seenOutputIDs.insert(profile.id).inserted,
                      !shipped.contains(where: { $0.id == profile.id }) else {
                    throw UserContentStoreError.duplicateProfileIdentifier(profile.id)
                }
                customProfiles.append(profile)
            }
        }

        var normalizedProfiles: [StyleProfile] = []
        for shippedProfile in shipped {
            if !seenOutputIDs.contains(shippedProfile.id) { _ = seenOutputIDs.insert(shippedProfile.id) }
            // Always trust current shipped values. Persisted built-in fields are
            // read-only and may be stale or malicious; only their IDs/names are
            // used above to remap references.
            normalizedProfiles.append(shippedProfile)
        }
        normalizedProfiles.append(contentsOf: customProfiles)
        let validProfileIDs = Set(normalizedProfiles.map(\.id))

        var repairedReferences = 0
        let remappedDefault = inputDefaultProfileID.flatMap { idRemapping[$0] ?? $0 }
        let normalizedDefault: UUID
        if let remappedDefault, validProfileIDs.contains(remappedDefault) {
            normalizedDefault = remappedDefault
            if remappedDefault != inputDefaultProfileID { repairedReferences += 1 }
        } else {
            normalizedDefault = validProfileIDs.contains(StyleProfile.defaultBuiltInID)
                ? StyleProfile.defaultBuiltInID
                : normalizedProfiles[0].id
            if inputDefaultProfileID != normalizedDefault { repairedReferences += 1 }
        }

        var seenAppRuleIDs = Set<UUID>()
        for rule in inputRules where !seenAppRuleIDs.insert(rule.id).inserted {
            throw UserContentStoreError.duplicateAppRuleIdentifier(rule.id)
        }

        var normalizedRules: [AppRule]
        if inputRules.isEmpty {
            normalizedRules = builtInAppRules(profiles: normalizedProfiles)
        } else {
            normalizedRules = []
            var seenCategories = Set<AppCategory>()
            for var rule in inputRules where seenCategories.insert(rule.category).inserted {
                if let selected = rule.defaultStyleProfileID {
                    let remapped = idRemapping[selected] ?? selected
                    if validProfileIDs.contains(remapped) {
                        if remapped != selected { repairedReferences += 1 }
                        rule.defaultStyleProfileID = remapped
                    } else {
                        // nil explicitly inherits the General default.
                        rule.defaultStyleProfileID = nil
                        repairedReferences += 1
                    }
                }
                normalizedRules.append(rule)
            }
        }

        var seenContextIDs = Set<UUID>()
        var normalizedContexts: [WritingContext] = []
        for var context in inputContexts {
            guard seenContextIDs.insert(context.id).inserted else {
                throw UserContentStoreError.duplicateWritingContextIdentifier(context.id)
            }
            context.title = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !context.title.isEmpty else { throw UserContentStoreError.invalidWritingContextTitle }
            normalizedContexts.append(context)
        }

        var seenDictionaryIDs = Set<UUID>()
        for term in inputDictionary where !seenDictionaryIDs.insert(term.id).inserted {
            throw UserContentStoreError.duplicateDictionaryIdentifier(term.id)
        }

        var normalizedDictionary: [DictionaryTerm] = []
        var skippedDictionaryDuplicates = 0
        for var term in inputDictionary {
            term.term = DictionaryTerm.normalizedDisplayTerm(term.term)
            term.note = term.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if term.note?.isEmpty == true { term.note = nil }
            guard !term.term.isEmpty else {
                skippedDictionaryDuplicates += 1
                continue
            }
            guard !normalizedDictionary.contains(where: { $0.conflicts(with: term) }) else {
                skippedDictionaryDuplicates += 1
                continue
            }
            normalizedDictionary.append(term)
        }

        let state = ContentState(
            profiles: normalizedProfiles,
            writingContexts: normalizedContexts,
            dictionary: normalizedDictionary,
            appRules: normalizedRules,
            defaultProfileID: normalizedDefault
        )
        return NormalizedState(
            state: state,
            changed: state != original,
            repairedProfileReferenceCount: repairedReferences,
            skippedDictionaryDuplicateCount: skippedDictionaryDuplicates
        )
    }

    // MARK: - Built-in app rules

    private static func builtInAppRules(profiles: [StyleProfile]) -> [AppRule] {
        func id(_ name: String) -> UUID? { profiles.first { $0.name == name }?.id }
        return [
            AppRule(category: .chat, defaultStyleProfileID: id("Casual")),
            AppRule(category: .mail, defaultStyleProfileID: id("Professional")),
            AppRule(category: .docs, defaultStyleProfileID: id("Professional")),
            AppRule(category: .codeEditor, defaultStyleProfileID: id("Default"), allowFocusedFieldFix: false,
                    notes: "Selected text only; preserve code.")
        ]
    }

}
