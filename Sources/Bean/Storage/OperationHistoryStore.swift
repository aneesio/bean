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
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.appCategory = appCategory
        self.action = action
        self.inputMode = inputMode
        self.inputLength = max(0, inputLength)
        self.outputLength = outputLength.map { max(0, $0) }
        self.provider = provider
        self.model = model
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.safetyResult = safetyResult
        self.outcome = outcome
        self.inputTokens = inputTokens.map { max(0, $0) }
        self.outputTokens = outputTokens.map { max(0, $0) }
        self.usageEstimated = usageEstimated
    }

    var isConfirmedExternalReplacement: Bool {
        outcome == "replacedConfirmed" && appBundleIdentifier != "com.bean.app"
    }

    var diagnosticsLine: String {
        let date = ISO8601DateFormatter().string(from: timestamp)
        let app = appName ?? appCategory
        let duration = durationMilliseconds.map { " durationMs=\($0)" } ?? ""
        let usage: String
        if let inputTokens, let outputTokens {
            usage = " tokens=\(inputTokens)+\(outputTokens)\(usageEstimated ? "(estimated)" : "")"
        } else {
            usage = ""
        }
        return "\(date) source=\(source.rawValue) app=\(app) action=\(action) "
            + "mode=\(inputMode) lengths=\(inputLength)/\(outputLength ?? 0) "
            + "safety=\(safetyResult) outcome=\(outcome)\(duration)\(usage)"
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

    init(defaults: UserDefaults = .standard, storageKey: String = "operationHistoryV1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([OperationRecord].self, from: data) {
            self.records = Array(decoded.prefix(Self.maximumRecords))
        } else {
            self.records = []
        }
    }

    func record(_ record: OperationRecord) {
        refresh()
        records.insert(record, at: 0)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
        persist()
    }

    func clear() {
        records = []
        defaults.removeObject(forKey: storageKey)
        defaults.synchronize()
    }

    /// Refreshes metadata written by the separate Chrome native-host process.
    func refresh() {
        defaults.synchronize()
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([OperationRecord].self, from: data),
              decoded != records else { return }
        records = Array(decoded.prefix(Self.maximumRecords))
    }

    var hasConfirmedExternalReplacement: Bool {
        records.contains(where: \.isConfirmedExternalReplacement)
    }

    var recentDiagnosticsLines: [String] {
        records.prefix(10).map(\.diagnosticsLine)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
    }
}
