import Foundation
import CoreFoundation

/// Browser dictionary edits use the running GUI's authoritative store. A native
/// host must never load/save a competing full userContent snapshot: doing so
/// would allow a later GUI edit to overwrite a word it just learned.
@MainActor
final class DictionaryLearningService {
    nonisolated static let endpointName = "com.bean.app.dictionary-learning.v1"
    private let userContent: UserContentStore
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    init(userContent: UserContentStore, endpointName: String = DictionaryLearningService.endpointName) {
        self.userContent = userContent
        var context = CFMessagePortContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        var shouldFreeInfo: DarwinBoolean = false
        port = CFMessagePortCreateLocal(nil, endpointName as CFString, { _, messageID, data, info in
            guard messageID == 1, let data, let info else { return nil }
            // The source below is installed only on the main run loop. Store
            // mutation and its acknowledged result run on the GUI MainActor.
            let response = MainActor.assumeIsolated {
                Unmanaged<DictionaryLearningService>.fromOpaque(info).takeUnretainedValue()
                    .handle(Data(data as Data))
            }
            return Unmanaged.passRetained(response as CFData)
        }, &context, &shouldFreeInfo)
        guard let port, !shouldFreeInfo.boolValue,
              let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            self.port = nil
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil
        port = nil
    }

    /// Pure validation shared by IPC and native host. Learning accepts one
    /// spelling token, never a phrase, URL, source paragraph or command.
    nonisolated static func validatedTerm(_ raw: String) -> String? {
        guard raw.count <= 96, raw.utf8.count <= 384 else { return nil }
        let term = DictionaryTerm.normalizedDisplayTerm(raw)
        guard !term.isEmpty, term.count <= 96, term.contains(where: { $0.isLetter }),
              term.range(of: #"^[\p{L}\p{M}]+(?:['’-][\p{L}\p{M}]+)*$"#,
                         options: .regularExpression) != nil else { return nil }
        return term
    }

    private func handle(_ data: Data) -> Data {
        guard data.count <= 512, let raw = String(data: data, encoding: .utf8),
              let term = Self.validatedTerm(raw) else { return Data("invalid".utf8) }
        let candidate = DictionaryTerm(term: term)
        guard userContent.dictionary.count < UserContentFileLimits.maximumNativeDictionaryTerms
                || userContent.dictionary.contains(where: { $0.conflicts(with: candidate) }) else {
            return Data("failed".utf8)
        }
        switch userContent.upsert(candidate) {
        case .inserted, .updated, .rejectedDuplicate:
            return Data("saved".utf8)
        case .rejectedEmpty, .persistenceFailed:
            return Data("failed".utf8)
        }
    }

    nonisolated static func isAvailable(endpointName: String = endpointName) -> Bool {
        CFMessagePortCreateRemote(nil, endpointName as CFString) != nil
    }

    nonisolated static func learn(_ term: String, endpointName: String = endpointName) async -> DictionaryLearningResult {
        guard let validated = validatedTerm(term) else { return .invalid }
        // Sending waits for the GUI run loop. Never block it when called by an
        // actor-isolated native-host test or an app task.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let remote = CFMessagePortCreateRemote(nil, endpointName as CFString) else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                var response: Unmanaged<CFData>?
                let status = CFMessagePortSendRequest(remote, 1, Data(validated.utf8) as CFData,
                    1, 2, CFRunLoopMode.defaultMode.rawValue, &response)
                guard status == kCFMessagePortSuccess, let response else {
                    continuation.resume(returning: .failed)
                    return
                }
                let reply = String(data: response.takeRetainedValue() as Data, encoding: .utf8)
                continuation.resume(returning: reply == "saved" ? .saved : reply == "invalid" ? .invalid : .failed)
            }
        }
    }
}

enum DictionaryLearningResult: Sendable {
    case saved, unavailable, invalid, failed
}

struct NativeHostDictionaryConfiguration {
    var available: Bool
    var learner: (String) async -> DictionaryLearningResult
}
