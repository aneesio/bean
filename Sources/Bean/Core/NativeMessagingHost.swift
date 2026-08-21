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

    private static func processSync(_ payload: Data) -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result = Data()
        Task {
            result = await process(payload)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private static func process(_ payload: Data) async -> Data {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: payload) else {
            return encode(HostResponse.error(id: nil, code: "badRequest", message: "Malformed request."))
        }
        switch request.type {
        case "ping":
            return encode(HostResponse(id: request.id, ok: true))
        case "getStatus":
            return encode(HostResponse.status(id: request.id))
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

        let issues = await detector.llmIssues(
            in: text, context: context, dictionary: HostConfig.dictionary,
            provider: HostConfig.provider, model: HostConfig.model,
            apiKey: HostConfig.apiKey, timeout: HostConfig.timeout
        )

        let mapped = issues.map { issue in
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

        let context = SourceAppContext(
            appName: request.source?.urlHost,
            bundleIdentifier: nil, processIdentifier: nil,
            focusedRole: request.source?.fieldType,
            focusedSubrole: nil,
            acquisitionMode: .focusedFieldFullText,
            isSearchLikeField: false
        )

        let service = WritingTransformService()
        let raw: String
        do {
            raw = try await service.transform(
                text: text, action: .proofread, context: context,
                personalization: nil, extraContextLines: HostConfig.dictionaryPreservationLines(for: text),
                provider: HostConfig.provider, model: HostConfig.model,
                apiKey: HostConfig.apiKey, timeout: HostConfig.timeout
            )
        } catch {
            return encode(HostResponse.error(id: request.id, code: "providerError", message: "Couldn't reach the provider."))
        }

        let corrected = TextNormalizer.sanitizeModelOutput(raw, originalCore: text)

        // Last-line safety runs on the exact text that would be returned, after
        // harmless provider wrappers/commentary have been removed.
        if case .suspicious = OutputSafetyValidator.validate(input: text, output: corrected, action: .proofread) {
            return encode(HostResponse.error(id: request.id, code: "unsafeOutput", message: "The correction looked unsafe."))
        }

        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "unsafeOutput", message: "The correction was empty."))
        }
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
    var errorCode: String? = nil
    var message: String? = nil
    // status-only fields
    var bridgeAvailable: Bool? = nil
    var providerConfigured: Bool? = nil
    var webInlineEnabled: Bool? = nil
    var appVersion: String? = nil

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

    static func status(id: String?) -> HostResponse {
        HostResponse(id: id, ok: true,
                     bridgeAvailable: true,
                     providerConfigured: !HostConfig.apiKey.isEmpty,
                     webInlineEnabled: HostConfig.webInlineEnabled,
                     appVersion: AppInfo.version)
    }
}
