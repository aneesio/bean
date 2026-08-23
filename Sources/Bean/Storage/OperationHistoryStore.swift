import Foundation

/// How an operation began. This is metadata only and never contains user text.
enum OperationSource: String, Codable, CaseIterable {
    case manual
    case passive
    case nativeInline
    case webInline
    case local
    case setup

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .passive: return "Passive"
        case .nativeInline: return "Native inline"
        case .webInline: return "Web inline"
        case .local: return "Local"
        case .setup: return "Setup"
        }
    }

    var isAutomaticProviderPath: Bool {
        self == .passive || self == .nativeInline || self == .webInline
    }
}

/// One content-free operation outcome. There are deliberately no fields for
/// source text, transformed text, prompts, responses, clipboard contents,
/// window titles, field labels, or accessibility values.
struct OperationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let source: OperationSource
    let appName: String?
    let appBundleIdentifier: String?
    let appCategory: String
    let action: String
    let inputMode: String
    let inputLength: Int
    let outputLength: Int?
    let provider: String?
    let model: String?
    let durationMilliseconds: Int?
    let safetyResult: String
    let outcome: String
    let inputTokens: Int?
    let outputTokens: Int?
    let usageEstimated: Bool

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, source, appName, appBundleIdentifier, appCategory
        case action, inputMode, inputLength, outputLength, provider, model
        case durationMilliseconds, safetyResult, outcome, inputTokens, outputTokens
        case usageEstimated
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: OperationSource,
        appName: String?,
        appBundleIdentifier: String?,
        appCategory: String,
        action: String,
        inputMode: String,
        inputLength: Int,
        outputLength: Int? = nil,
        provider: String? = nil,
        model: String? = nil,
        durationMilliseconds: Int? = nil,
        safetyResult: String = "notRun",
        outcome: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        usageEstimated: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.appName = OperationalMetadataSanitizer.optional(
            appName,
            maximumScalars: OperationalMetadataSanitizer.appNameMaximumScalars
        )
        self.appBundleIdentifier = OperationalMetadataSanitizer.optional(
            appBundleIdentifier,
            maximumScalars: OperationalMetadataSanitizer.bundleIdentifierMaximumScalars
        )
        self.appCategory = OperationalMetadataSanitizer.required(
            appCategory,
            maximumScalars: OperationalMetadataSanitizer.categoryMaximumScalars
        )
        self.action = OperationalMetadataSanitizer.required(
            action,
            maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        self.inputMode = OperationalMetadataSanitizer.required(
            inputMode,
            maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        self.inputLength = max(0, inputLength)
        self.outputLength = outputLength.map { max(0, $0) }
        self.provider = OperationalMetadataSanitizer.optional(
            provider,
            maximumScalars: OperationalMetadataSanitizer.providerMaximumScalars
        )
        self.model = OperationalMetadataSanitizer.optional(
            model,
            maximumScalars: OperationalMetadataSanitizer.modelMaximumScalars
        )
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.safetyResult = OperationalMetadataSanitizer.required(
            safetyResult,
            maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        self.outcome = OperationalMetadataSanitizer.required(
            outcome,
            maximumScalars: OperationalMetadataSanitizer.operationLabelMaximumScalars
        )
        self.inputTokens = inputTokens.map { max(0, $0) }
        self.outputTokens = outputTokens.map { max(0, $0) }
        self.usageEstimated = usageEstimated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            source: try container.decode(OperationSource.self, forKey: .source),
            appName: try container.decodeIfPresent(String.self, forKey: .appName),
            appBundleIdentifier: try container.decodeIfPresent(
                String.self, forKey: .appBundleIdentifier
            ),
            appCategory: try container.decode(String.self, forKey: .appCategory),
            action: try container.decode(String.self, forKey: .action),
            inputMode: try container.decode(String.self, forKey: .inputMode),
            inputLength: try container.decode(Int.self, forKey: .inputLength),
            outputLength: try container.decodeIfPresent(Int.self, forKey: .outputLength),
            provider: try container.decodeIfPresent(String.self, forKey: .provider),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            durationMilliseconds: try container.decodeIfPresent(
                Int.self, forKey: .durationMilliseconds
            ),
            safetyResult: try container.decode(String.self, forKey: .safetyResult),
            outcome: try container.decode(String.self, forKey: .outcome),
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens),
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens),
            usageEstimated: try container.decodeIfPresent(
                Bool.self, forKey: .usageEstimated
            ) ?? false
        )
    }

    var isConfirmedExternalReplacement: Bool {
        outcome == "replacedConfirmed" && appBundleIdentifier != "com.bean.app"
    }

    /// Browser hostnames and field semantics are useful only in memory while a
    /// request is being built. Persisted browser accounting is intentionally
    /// generic so diagnostics cannot reveal a sensitive website after the fact.
    var persistenceSanitized: OperationRecord {
        return OperationRecord(
            id: id,
            timestamp: timestamp,
            source: source,
            appName: source == .webInline ? nil : appName,
            appBundleIdentifier: source == .webInline ? nil : appBundleIdentifier,
            appCategory: source == .webInline ? "browser" : appCategory,
            action: action,
            inputMode: source == .webInline ? "browser" : inputMode,
            inputLength: inputLength,
            outputLength: outputLength,
            provider: provider,
            model: model,
            durationMilliseconds: durationMilliseconds,
            safetyResult: safetyResult,
            outcome: outcome,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            usageEstimated: usageEstimated
        )
    }

    var diagnosticsLine: String {
        // Re-sanitize at the rendering boundary as defense in depth for any
        // record supplied outside the normal stores.
        let safe = persistenceSanitized
        let date = ISO8601DateFormatter().string(from: timestamp)
        let app = safe.appName ?? safe.appCategory
        let duration = safe.durationMilliseconds.map { " durationMs=\($0)" } ?? ""
        let usage: String
        if let inputTokens = safe.inputTokens, let outputTokens = safe.outputTokens {
            usage = " tokens=\(inputTokens)+\(outputTokens)\(safe.usageEstimated ? "(estimated)" : "")"
        } else {
            usage = ""
        }
        return "\(date) source=\(safe.source.rawValue) app=\(app) action=\(safe.action) "
            + "mode=\(safe.inputMode) lengths=\(safe.inputLength)/\(safe.outputLength ?? 0) "
            + "safety=\(safe.safetyResult) outcome=\(safe.outcome)\(duration)\(usage)"
    }
}

/// A bounded, local, content-free operation ledger. UserDefaults is appropriate
/// here because the payload is small configuration/operational metadata, not
/// user content. Users can inspect and erase it from Settings.
@MainActor
final class OperationHistoryStore: ObservableObject {
    static let maximumRecords = 50

    @Published private(set) var records: [OperationRecord]

    private let defaults: UserDefaults
    private let storageKey: String
    private let crossProcessLock: BeanCrossProcessStoreLock

    init(defaults: UserDefaults = .standard, storageKey: String = "operationHistoryV1",
         coordinationDirectoryURL: URL = BeanCrossProcessStoreLock.defaultDirectoryURL) {
        self.defaults = defaults
        self.storageKey = storageKey
        let lock = BeanCrossProcessStoreLock(directoryURL: coordinationDirectoryURL)
        self.crossProcessLock = lock

        var loaded: [OperationRecord] = []
        var enteredLock = false
        _ = lock.withExclusiveLock {
            enteredLock = true
            loaded = Self.loadRecords(
                defaults: defaults,
                storageKey: storageKey,
                persistSanitizedForm: true
            ) ?? []
            return true
        }
        if !enteredLock {
            // A read-only fallback keeps the local UI useful in a restricted
            // environment, but it must never rewrite a stale snapshot without
            // the same lock used by the browser native-host process.
            loaded = Self.loadRecords(
                defaults: defaults,
                storageKey: storageKey,
                persistSanitizedForm: false
            ) ?? []
        }
        self.records = loaded
    }

    func record(_ record: OperationRecord) {
        let safeRecord = record.persistenceSanitized
        _ = crossProcessLock.withExclusiveLock {
            guard self.refreshAssumingLock() else { return false }
            self.records.insert(safeRecord, at: 0)
            if self.records.count > Self.maximumRecords {
                self.records.removeLast(self.records.count - Self.maximumRecords)
            }
            return self.persistAssumingLock()
        }
    }

    func clear() {
        _ = crossProcessLock.withExclusiveLock {
            self.records = []
            self.defaults.removeObject(forKey: self.storageKey)
            self.defaults.synchronize()
            return true
        }
    }

    /// Refreshes metadata written by the separate Chrome native-host process.
    func refresh() {
        var enteredLock = false
        _ = crossProcessLock.withExclusiveLock {
            enteredLock = true
            return self.refreshAssumingLock()
        }
        if !enteredLock, let decoded = Self.loadRecords(
            defaults: defaults,
            storageKey: storageKey,
            persistSanitizedForm: false
        ), decoded != records {
            records = decoded
        }
    }

    var hasConfirmedExternalReplacement: Bool {
        records.contains(where: \.isConfirmedExternalReplacement)
    }

    var recentDiagnosticsLines: [String] {
        records.prefix(10).map(\.diagnosticsLine)
    }

    private func refreshAssumingLock() -> Bool {
        guard let decoded = Self.loadRecords(
            defaults: defaults,
            storageKey: storageKey,
            persistSanitizedForm: true
        ) else { return false }
        if decoded != records { records = decoded }
        return true
    }

    private static func loadRecords(
        defaults: UserDefaults,
        storageKey: String,
        persistSanitizedForm: Bool
    ) -> [OperationRecord]? {
        defaults.synchronize()
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([OperationRecord].self, from: data) else {
            return nil
        }
        let sanitized = Array(
            decoded.lazy.map(\.persistenceSanitized).prefix(Self.maximumRecords)
        )
        if persistSanitizedForm,
           let encoded = try? JSONEncoder().encode(sanitized),
           encoded != data {
            defaults.set(encoded, forKey: storageKey)
            defaults.synchronize()
        }
        return sanitized
    }

    /// Call only while `crossProcessLock` is held.
    private func persistAssumingLock() -> Bool {
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
        return true
    }
}
