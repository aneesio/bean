import Foundation

// Chrome Native Messaging host mode. When Chrome launches the Bean binary as a
// native messaging host (it passes the calling extension's chrome-extension://
// origin as an argument), `BeanApp.main` routes here INSTEAD of starting the
// GUI. We read 4-byte-length-prefixed JSON requests on stdin and write framed
// responses on stdout.
//
// Because this is the SAME signed Bean binary, it shares the GUI app's Keychain
// (API key), UserDefaults (provider/model/timeout/web-inline), and Application
// Support (personal dictionary) by identity — no IPC, no duplicated secrets.
//
// SECURITY/PRIVACY: only known message types, capped sizes, no command/file
// execution from messages, and NO logging or persistence of request text.
enum NativeMessagingHost {

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static let maxMessageBytes = 1_000_000   // 1 MB frame cap
    private static let maxTextChars = 8_000
    private static let maxIssuesCap = 8
    private static let maxParagraphChars = 2_000      // a single paragraph, not a doc

    static func run() {
        while let payload = readMessage() {
            let response = processSync(payload)
            writeMessage(response)
        }
    }

    // MARK: - Framing

    private static func readMessage() -> Data? {
        let input = FileHandle.standardInput
        guard let lengthData = readExactly(4, from: input) else { return nil }
        let bytes = [UInt8](lengthData)
        let length = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        guard length > 0, length <= maxMessageBytes else { return nil }
        return readExactly(Int(length), from: input)
    }

    /// Pipe reads are allowed to return fewer bytes than requested. Accumulate
    /// until the complete native-messaging frame arrives or stdin reaches EOF.
    private static func readExactly(_ count: Int, from input: FileHandle) -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try? input.read(upToCount: count - data.count),
                  !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func writeMessage(_ data: Data) {
        var length = UInt32(data.count).littleEndian
        let header = Data(bytes: &length, count: 4)
        let out = FileHandle.standardOutput
        try? out.write(contentsOf: header)
        try? out.write(contentsOf: data)
    }

    // MARK: - Dispatch (async bridged to the serial loop)

    static func processSync(_ payload: Data) -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        // Never inherit a caller's actor here. The native host is a synchronous
        // pipe protocol, while parts of status/usage storage are MainActor
        // isolated. Inheriting MainActor and then waiting caused the bridge to
        // remain stuck at “Checking…” forever.
        Task.detached {
            result.store(await process(payload))
            semaphore.signal()
        }
        semaphore.wait()
        return result.load()
    }

    private static func process(_ payload: Data) async -> Data {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: payload) else {
            return encode(HostResponse.error(id: nil, code: "badRequest", message: "Malformed request."))
        }
        switch request.type {
        case "ping":
            return encode(HostResponse(id: request.id, ok: true))
        case "getStatus":
            return encode(await HostResponse.status(id: request.id))
        case "detectIssues":
            return await detect(request)
        case "proofreadParagraph":
            return await proofreadParagraph(request)
        default:
            return encode(HostResponse.error(id: request.id, code: "unknownType", message: "Unsupported request type."))
        }
    }

    private static func detect(_ request: HostRequest) async -> Data {
        guard HostConfig.webInlineEnabled else {
            return encode(HostResponse.error(id: request.id, code: "webInlineDisabled",
                                             message: "Enable Web Inline Support in Bean Settings."))
        }
        let text = request.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encode(HostResponse(id: request.id, ok: true, issues: []))
        }
        guard text.count <= maxTextChars else {
            return encode(HostResponse.error(id: request.id, code: "textTooLong", message: "Text is too long to check."))
        }
        guard !HostConfig.apiKey.isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "missingApiKey", message: "Add an API key in Bean Settings."))
        }
        guard await HostConfig.automaticCallAllowed() else {
            return encode(HostResponse.error(id: request.id, code: "automaticDailyLimit",
                                             message: "Today's automatic AI limit has been reached."))
        }

        var detector = IssueDetector()
        detector.maxIssues = min(request.settings?.maxIssues ?? maxIssuesCap, maxIssuesCap)

        let context = SourceAppContext(
            appName: request.source?.urlHost,
            bundleIdentifier: nil, processIdentifier: nil,
            focusedRole: request.source?.fieldType,
            focusedSubrole: nil,
            acquisitionMode: .focusedFieldFullText,
            isSearchLikeField: false
        )

        let detection = await detector.llmIssues(
            in: text, context: context, dictionary: HostConfig.dictionary,
            provider: HostConfig.provider, model: HostConfig.model,
            apiKey: HostConfig.apiKey, timeout: HostConfig.timeout
        )

        if let usage = detection.usage {
            await HostConfig.recordUsage(usage, source: .webInline, context: context,
                                         action: "detectIssues", inputLength: text.count,
                                         outputLength: detection.issues.reduce(0) { $0 + $1.suggestion.count },
                                         outcome: detection.issues.isEmpty ? "noIssues" : "issuesReturned")
        }
        let mapped = detection.issues.map { issue in
            HostResponse.Issue(original: issue.original, suggestion: issue.suggestion,
                               type: issue.type.rawValue, explanation: issue.explanation,
                               confidence: issue.confidence)
        }
        return encode(HostResponse(id: request.id, ok: true, issues: mapped))
    }

    // Whole-paragraph proofread for the extension's "Fix Paragraph" action.
    // Uses Bean's strict proofread (same prompt-injection hardening + output
    // safety as the desktop app), then strips wrappers/zero-width artifacts.
    // Returns ONLY corrected paragraph text. Never logs request/response text.
    private static func proofreadParagraph(_ request: HostRequest) async -> Data {
        guard HostConfig.webInlineEnabled else {
            return encode(HostResponse.error(id: request.id, code: "webInlineDisabled",
                                             message: "Enable Web Inline Support in Bean Settings."))
        }
        let text = request.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "emptyText", message: "Nothing to fix."))
        }
        guard text.count <= maxParagraphChars else {
            return encode(HostResponse.error(id: request.id, code: "textTooLong", message: "Paragraph is too long to fix."))
        }
        guard !HostConfig.apiKey.isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "missingApiKey", message: "Add an API key in Bean Settings."))
        }
        guard await HostConfig.automaticCallAllowed() else {
            return encode(HostResponse.error(id: request.id, code: "automaticDailyLimit",
                                             message: "Today's automatic AI limit has been reached."))
        }

        let context = SourceAppContext(
            appName: request.source?.urlHost,
            bundleIdentifier: nil, processIdentifier: nil,
            focusedRole: request.source?.fieldType,
            focusedSubrole: nil,
            acquisitionMode: .focusedFieldFullText,
            isSearchLikeField: false
        )

        let service = WritingTransformService()
        let completion: LLMCompletion
        do {
            completion = try await service.transform(
                text: text, action: .proofread, context: context,
                personalization: nil, extraContextLines: HostConfig.dictionaryPreservationLines(for: text),
                provider: HostConfig.provider, model: HostConfig.model,
                apiKey: HostConfig.apiKey, timeout: HostConfig.timeout
            )
        } catch {
            return encode(HostResponse.error(id: request.id, code: "providerError", message: "Couldn't reach the provider."))
        }

        let corrected = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: text)

        // Last-line safety runs on the exact text that would be returned, after
        // harmless provider wrappers/commentary have been removed.
        if case let .suspicious(reason) = OutputSafetyValidator.validate(input: text, output: corrected, action: .proofread) {
            await HostConfig.recordUsage(completion.usage, source: .webInline, context: context,
                                         action: "proofreadParagraph", inputLength: text.count,
                                         outputLength: corrected.count, safety: reason,
                                         outcome: OutputSafetyValidator.disposition(for: reason) == .hardBlock
                                            ? "blocked" : "reviewRequired")
            if OutputSafetyValidator.disposition(for: reason) == .reviewRequired {
                return encode(HostResponse(id: request.id, ok: true, text: corrected,
                                           reviewRequired: true,
                                           message: OutputSafetyValidator.reviewMessage(for: reason)))
            }
            return encode(HostResponse.error(id: request.id, code: "unsafeOutput", message: "The correction contained unsafe model output."))
        }

        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "unsafeOutput", message: "The correction was empty."))
        }
        await HostConfig.recordUsage(completion.usage, source: .webInline, context: context,
                                     action: "proofreadParagraph", inputLength: text.count,
                                     outputLength: corrected.count, outcome: "returned")
        return encode(HostResponse(id: request.id, ok: true, text: corrected))
    }

    private static func encode(_ response: HostResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
    }
}

// MARK: - Config reader (shares the GUI app's Keychain / UserDefaults / files)

private enum HostConfig {
    private static let defaults = UserDefaults.standard

    static var provider: ProviderKind {
        ProviderKind(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openai
    }
    static var model: String { provider.migratedModel(defaults.string(forKey: "model")) }
    static var apiKey: String { KeychainService.get(account: provider.keychainAccount) ?? "" }
    static var timeout: TimeInterval { let t = defaults.double(forKey: "timeoutSeconds"); return t > 0 ? t : 30 }
    static var webInlineEnabled: Bool { defaults.bool(forKey: "webInlineEnabled") }
    static var dailyAutomaticCallLimit: Int {
        let value = defaults.integer(forKey: "dailyAutomaticCallLimit")
        return value > 0 ? value : 20
    }

    static func automaticCallAllowed() async -> Bool {
        await MainActor.run {
            UsageLedgerStore().allowsAutomaticCall(dailyLimit: dailyAutomaticCallLimit)
        }
    }

    static func recordUsage(_ usage: LLMUsage, source: OperationSource,
                            context: SourceAppContext, action: String,
                            inputLength: Int, outputLength: Int,
                            safety: String = "ok", outcome: String) async {
        await MainActor.run {
            UsageLedgerStore().record(usage, source: source,
                                      provider: provider.rawValue, model: model)
            OperationHistoryStore().record(OperationRecord(
                source: source,
                appName: context.appName,
                appBundleIdentifier: context.bundleIdentifier,
                appCategory: AppCategory.from(bundleIdentifier: context.bundleIdentifier).rawValue,
                action: action,
                inputMode: context.acquisitionMode.rawLabel,
                inputLength: inputLength,
                outputLength: outputLength,
                provider: provider.rawValue,
                model: model,
                safetyResult: safety,
                outcome: outcome,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                usageEstimated: usage.isEstimated
            ))
        }
    }

    /// Dictionary terms loaded directly from the same JSON the app writes.
    static var dictionary: [DictionaryTerm] {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let url = dir.appendingPathComponent("Bean/userContent.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(DictFile.self, from: data) else { return [] }
        return file.dictionary ?? []
    }
    private struct DictFile: Decodable { var dictionary: [DictionaryTerm]? }

    /// A single trusted <context> line asking the proofread to preserve the
    /// user's dictionary terms (preserve-only; never inserted). Capped.
    static func dictionaryPreservationLines(for text: String) -> [String] {
        let terms = dictionary.filter { term in
            let options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive]
            return text.range(of: term.term, options: options) != nil
        }
        guard !terms.isEmpty else { return [] }
        let list = terms.prefix(30)
            .map { $0.caseSensitive ? "\"\($0.term)\" (keep exact casing)" : "\"\($0.term)\"" }
            .joined(separator: ", ")
        return ["Preserve these user terms exactly; do not 'correct' them: \(list)."]
    }
}

// MARK: - Protocol DTOs

private struct HostRequest: Decodable {
    let id: String?
    let type: String
    let text: String?
    let source: Source?
    let settings: Settings?

    struct Source: Decodable { let surface: String?; let browser: String?; let urlHost: String?; let fieldType: String? }
    struct Settings: Decodable { let maxIssues: Int? }
}

private struct HostResponse: Encodable {
    var id: String?
    var ok: Bool
    var issues: [Issue]? = nil
    var text: String? = nil            // proofreadParagraph: corrected paragraph
    var reviewRequired: Bool? = nil
    var errorCode: String? = nil
    var message: String? = nil
    // status-only fields
    var bridgeAvailable: Bool? = nil
    var providerConfigured: Bool? = nil
    var webInlineEnabled: Bool? = nil
    var appVersion: String? = nil
    var dailyAutomaticCallLimit: Int? = nil
    var automaticCallsToday: Int? = nil
    var referenceSites: [String]? = nil

    struct Issue: Encodable {
        let original: String
        let suggestion: String
        let type: String
        let explanation: String?
        let confidence: Double
    }

    static func error(id: String?, code: String, message: String) -> HostResponse {
        HostResponse(id: id, ok: false, errorCode: code, message: message)
    }

    static func status(id: String?) async -> HostResponse {
        let calls = await MainActor.run { UsageLedgerStore().automaticCallsToday() }
        return HostResponse(id: id, ok: true,
                     bridgeAvailable: true,
                     providerConfigured: !HostConfig.apiKey.isEmpty,
                     webInlineEnabled: HostConfig.webInlineEnabled,
                     appVersion: AppInfo.version,
                     dailyAutomaticCallLimit: HostConfig.dailyAutomaticCallLimit,
                     automaticCallsToday: calls,
                     referenceSites: ["mail.google.com", "app.slack.com"])
    }
}
