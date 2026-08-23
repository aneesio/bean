import Foundation

private enum NativeBridgeContract {
    static let protocolVersion = 1
    static let minimumExtensionVersion = "0.7.0"

    static func version(_ candidate: String?, isAtLeast minimum: String) -> Bool {
        func components(_ rawValue: String?) -> [Int]? {
            guard let rawValue else { return nil }
            let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 4,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
                return nil
            }
            let values = parts.compactMap { Int($0) }
            return values.count == parts.count ? values : nil
        }

        guard let candidate = components(candidate),
              let minimum = components(minimum) else { return false }
        let count = max(candidate.count, minimum.count)
        for index in 0..<count {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < minimum.count ? minimum[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}

/// Verifies one provider/model snapshot against both the current selection and
/// the content-free marker written only after a successful connection test.
/// Keeping this pure and testable makes the cross-process TOCTOU boundary
/// explicit: a marker for a newly selected pair can never authorize a pair the
/// native request captured earlier.
enum NativeProviderVerificationPolicy {
    static func isVerified(capturedProvider: ProviderKind,
                           capturedModel: String,
                           defaults: UserDefaults) -> Bool {
        let selectedProvider = ProviderKind(
            rawValue: defaults.string(forKey: "provider") ?? ""
        ) ?? .openai
        let selectedModel = selectedProvider.migratedModel(defaults.string(forKey: "model"))
        return selectedProvider == capturedProvider
            && selectedModel == capturedModel
            && defaults.double(forKey: "providerVerifiedAt") > 0
            && defaults.string(forKey: "providerVerifiedKind") == capturedProvider.rawValue
            && defaults.string(forKey: "providerVerifiedModel") == capturedModel
    }

    static func performIfVerified<Result>(
        capturedProvider: ProviderKind,
        capturedModel: String,
        defaults: UserDefaults,
        operation: () -> Result
    ) -> Result? {
        guard isVerified(
            capturedProvider: capturedProvider,
            capturedModel: capturedModel,
            defaults: defaults
        ) else { return nil }
        return operation()
    }
}

/// Immutable, content-free status snapshot used by the native protocol. Tests
/// build this from an isolated defaults suite and accounting directory, so a
/// status request can never read or repair the user's live Bean stores.
struct NativeHostStatusConfiguration: Sendable {
    let providerConfigured: Bool
    let webInlineEnabled: Bool
    let timeout: TimeInterval
    let dailyAutomaticCallLimit: Int
    let automaticCallsToday: Int?

    var automaticAccountingAvailable: Bool { automaticCallsToday != nil }

    static func read(defaults: UserDefaults,
                     automaticCallBudget: AutomaticCallBudgetStore) -> Self {
        let provider = ProviderKind(
            rawValue: defaults.string(forKey: "provider") ?? ""
        ) ?? .openai
        let model = provider.migratedModel(defaults.string(forKey: "model"))
        let storedTimeout = defaults.double(forKey: "timeoutSeconds")
        let timeout = min(max(storedTimeout > 0 ? storedTimeout : 30, 5), 120)
        let storedLimit = defaults.integer(forKey: "dailyAutomaticCallLimit")
        return Self(
            providerConfigured: NativeProviderVerificationPolicy.isVerified(
                capturedProvider: provider,
                capturedModel: model,
                defaults: defaults
            ),
            webInlineEnabled: defaults.bool(forKey: "webInlineEnabled"),
            timeout: timeout,
            dailyAutomaticCallLimit: AutomaticCallBudgetPolicy.persistedDailyLimit(storedLimit),
            automaticCallsToday: automaticCallBudget.automaticCallsToday()
        )
    }
}

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
    private static let maxTextChars = EngineConfig.maxProviderInputCharacters
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

    static func processSync(
        _ payload: Data,
        statusConfiguration: NativeHostStatusConfiguration? = nil
    ) -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        // Never inherit a caller's actor here. The native host is a synchronous
        // pipe protocol, while parts of status/usage storage are MainActor
        // isolated. Inheriting MainActor and then waiting caused the bridge to
        // remain stuck at “Checking…” forever.
        Task.detached {
            result.store(await process(payload, statusConfiguration: statusConfiguration))
            semaphore.signal()
        }
        semaphore.wait()
        return result.load()
    }

    private static func process(
        _ payload: Data,
        statusConfiguration: NativeHostStatusConfiguration?
    ) async -> Data {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: payload) else {
            return encode(HostResponse.error(id: nil, code: "badRequest", message: "Malformed request."))
        }
        switch request.type {
        case "ping":
            return encode(HostResponse(id: request.id, ok: true))
        case "getStatus":
            return encode(HostResponse.status(
                for: request,
                configuration: statusConfiguration ?? HostConfig.statusConfiguration
            ))
        case "detectIssues":
            if let error = textRequestCompatibilityError(for: request) { return encode(error) }
            return await detect(request)
        case "proofreadParagraph":
            if let error = textRequestCompatibilityError(for: request) { return encode(error) }
            return await proofreadParagraph(request)
        default:
            return encode(HostResponse.error(id: request.id, code: "unknownType", message: "Unsupported request type."))
        }
    }

    /// Text-bearing requests fail closed before configuration or provider work.
    /// Status remains open to legacy callers so it can explain the mismatch.
    private static func textRequestCompatibilityError(for request: HostRequest) -> HostResponse? {
        guard request.protocolVersion == NativeBridgeContract.protocolVersion else {
            return .error(
                id: request.id,
                code: "protocolMismatch",
                message: "Update Bean and the browser extension before using web AI."
            )
        }
        guard NativeBridgeContract.version(
            request.extensionVersion,
            isAtLeast: NativeBridgeContract.minimumExtensionVersion
        ) else {
            return .error(
                id: request.id,
                code: "extensionUpdateRequired",
                message: "Update the Bean browser extension before using web AI."
            )
        }
        guard let minimumAppVersion = request.minimumAppVersion,
              NativeBridgeContract.version(AppInfo.version, isAtLeast: minimumAppVersion) else {
            return .error(
                id: request.id,
                code: "beanUpdateRequired",
                message: "Update Bean before using web AI."
            )
        }
        return nil
    }

    private static func detect(_ request: HostRequest) async -> Data {
        guard HostConfig.webInlineEnabled else {
            return encode(HostResponse.error(id: request.id, code: "webInlineDisabled",
                                             message: "Allow deeper AI checks from the browser in Bean Settings → Browser."))
        }
        let text = request.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encode(HostResponse(id: request.id, ok: true, issues: []))
        }
        guard EngineConfig.providerInputIsWithinLimit(
            text,
            maximumCharacters: maxTextChars
        ) else {
            return encode(HostResponse.error(id: request.id, code: "textTooLong", message: "Text is too long to check."))
        }
        let provider = HostConfig.provider
        let model = HostConfig.model(for: provider)
        // The content-free status handshake may be reused briefly by the
        // extension. Re-check the exact provider/model verification marker at
        // the text boundary so changing either setting cannot use that cached
        // readiness to send text through an unverified configuration.
        guard HostConfig.isProviderConfigurationVerified(provider: provider, model: model) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "providerNotVerified",
                message: "Verify the selected AI provider and model in Bean Settings."
            ))
        }
        let apiKey = HostConfig.apiKey(for: provider)
        let timeout = HostConfig.timeout
        guard !apiKey.isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "missingApiKey", message: "Add an API key in Bean Settings."))
        }
        let dictionary = HostConfig.dictionary
        let context = browserSourceContext()
        let maximumIssues = max(1, min(
            request.settings?.maxIssues ?? maxIssuesCap,
            maxIssuesCap
        ))
        guard IssueDetector.providerPayloadIsWithinLimit(
            text: text,
            context: context,
            dictionary: dictionary,
            maximumIssues: maximumIssues
        ) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "textTooLong",
                message: "Text is too long to check."
            ))
        }
        let metadata = HostConfig.automaticMetadata(
            source: .webInline, context: context,
            action: "detectIssues", inputLength: text.count,
            provider: provider, model: model
        )
        // Keychain and preferences are separate stores. Revalidate the exact
        // captured pair after reading the key/dictionary and immediately before
        // reservation, so a concurrent settings/key change cannot authorize a
        // stale snapshot or consume budget.
        guard HostConfig.webInlineEnabled else {
            return encode(HostResponse.error(id: request.id, code: "webInlineDisabled",
                                             message: "Allow deeper AI checks from the browser in Bean Settings → Browser."))
        }
        guard let reservationResult = HostConfig.reserveAutomaticCallIfConfigurationVerified(
            provider: provider, model: model, metadata: metadata, timeout: timeout
        ) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "providerNotVerified",
                message: "Verify the selected AI provider and model in Bean Settings."
            ))
        }
        let reservation: AutomaticCallBudgetStore.Reservation
        switch reservationResult {
        case .reserved(let value):
            reservation = value
        case .limitReached:
            return encode(HostResponse.error(id: request.id, code: "automaticDailyLimit",
                                             message: "Today's automatic AI limit has been reached."))
        case .unavailable:
            return encode(HostResponse.error(id: request.id, code: "usageReservationUnavailable",
                                             message: "Bean couldn't safely reserve this AI check. Try again."))
        }
        defer { reservation.cancel() }
        // A change between reservation and the provider boundary releases this
        // still-pending lease through `defer`; no call or daily capacity is spent.
        guard HostConfig.webInlineEnabled else {
            return encode(HostResponse.error(id: request.id, code: "webInlineDisabled",
                                             message: "Allow deeper AI checks from the browser in Bean Settings → Browser."))
        }
        guard HostConfig.isProviderConfigurationVerified(provider: provider, model: model) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "providerNotVerified",
                message: "Verify the selected AI provider and model in Bean Settings."
            ))
        }
        guard reservation.beginProviderAttempt() else {
            return encode(HostResponse.error(id: request.id, code: "usageReservationUnavailable",
                                             message: "Bean couldn't safely start this AI check. Try again."))
        }

        var detector = IssueDetector()
        detector.maxIssues = maximumIssues

        let detection = await detector.llmIssues(
            in: text, context: context, dictionary: dictionary,
            provider: provider, model: model,
            apiKey: apiKey, timeout: timeout
        )

        if let usage = detection.usage {
            _ = reservation.complete(
                usage: usage,
                outputLength: detection.issues.reduce(0) { $0 + $1.suggestion.count },
                safetyResult: "structuredIssueMapping",
                outcome: detection.issues.isEmpty ? "noIssues" : "issuesReturned"
            )
        } else {
            _ = reservation.fail(outcome: detection.failureOutcome ?? "providerFailed")
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
                                             message: "Allow deeper AI checks from the browser in Bean Settings → Browser."))
        }
        let text = request.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "emptyText", message: "Nothing to fix."))
        }
        guard EngineConfig.providerInputIsWithinLimit(
            text,
            maximumCharacters: maxParagraphChars
        ) else {
            return encode(HostResponse.error(id: request.id, code: "textTooLong", message: "Paragraph is too long to fix."))
        }
        let provider = HostConfig.provider
        let model = HostConfig.model(for: provider)
        guard HostConfig.isProviderConfigurationVerified(provider: provider, model: model) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "providerNotVerified",
                message: "Verify the selected AI provider and model in Bean Settings."
            ))
        }
        let apiKey = HostConfig.apiKey(for: provider)
        let timeout = HostConfig.timeout
        guard !apiKey.isEmpty else {
            return encode(HostResponse.error(id: request.id, code: "missingApiKey", message: "Add an API key in Bean Settings."))
        }
        let dictionaryLines = HostConfig.dictionaryPreservationLines(for: text)
        let context = browserSourceContext()
        guard WritingTransformService.providerPayloadIsWithinLimit(
            text: text,
            action: .proofread,
            context: context,
            userContextLines: dictionaryLines
        ) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "textTooLong",
                message: "Paragraph is too long to fix."
            ))
        }
        let metadata = HostConfig.automaticMetadata(
            source: .webInline, context: context,
            action: "proofreadParagraph", inputLength: text.count,
            provider: provider, model: model
        )
        guard HostConfig.webInlineEnabled else {
            return encode(HostResponse.error(id: request.id, code: "webInlineDisabled",
                                             message: "Allow deeper AI checks from the browser in Bean Settings → Browser."))
        }
        guard let reservationResult = HostConfig.reserveAutomaticCallIfConfigurationVerified(
            provider: provider, model: model, metadata: metadata, timeout: timeout
        ) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "providerNotVerified",
                message: "Verify the selected AI provider and model in Bean Settings."
            ))
        }
        let reservation: AutomaticCallBudgetStore.Reservation
        switch reservationResult {
        case .reserved(let value):
            reservation = value
        case .limitReached:
            return encode(HostResponse.error(id: request.id, code: "automaticDailyLimit",
                                             message: "Today's automatic AI limit has been reached."))
        case .unavailable:
            return encode(HostResponse.error(id: request.id, code: "usageReservationUnavailable",
                                             message: "Bean couldn't safely reserve this AI check. Try again."))
        }
        defer { reservation.cancel() }
        guard HostConfig.webInlineEnabled else {
            return encode(HostResponse.error(id: request.id, code: "webInlineDisabled",
                                             message: "Allow deeper AI checks from the browser in Bean Settings → Browser."))
        }
        guard HostConfig.isProviderConfigurationVerified(provider: provider, model: model) else {
            return encode(HostResponse.error(
                id: request.id,
                code: "providerNotVerified",
                message: "Verify the selected AI provider and model in Bean Settings."
            ))
        }
        guard reservation.beginProviderAttempt() else {
            return encode(HostResponse.error(id: request.id, code: "usageReservationUnavailable",
                                             message: "Bean couldn't safely start this AI check. Try again."))
        }

        let service = WritingTransformService()
        let completion: LLMCompletion
        do {
            completion = try await service.transform(
                text: text, action: .proofread, context: context,
                userContextLines: dictionaryLines,
                provider: provider, model: model,
                apiKey: apiKey, timeout: timeout
            )
        } catch {
            _ = reservation.fail(outcome: automaticProviderFailureOutcome(error))
            return encode(HostResponse.error(id: request.id, code: "providerError", message: "Couldn't reach the provider."))
        }

        let corrected = TextNormalizer.sanitizeModelOutput(completion.text, originalCore: text)

        // Last-line safety runs on the exact text that would be returned, after
        // harmless provider wrappers/commentary have been removed.
        if case let .suspicious(reason) = OutputSafetyValidator.validate(input: text, output: corrected, action: .proofread) {
            _ = reservation.complete(
                usage: completion.usage,
                outputLength: corrected.count,
                safetyResult: reason,
                outcome: OutputSafetyValidator.disposition(for: reason) == .hardBlock
                    ? "blocked" : "reviewRequired"
            )
            if OutputSafetyValidator.disposition(for: reason) == .reviewRequired {
                return encode(HostResponse(id: request.id, ok: true, text: corrected,
                                           reviewRequired: true,
                                           message: OutputSafetyValidator.reviewMessage(for: reason)))
            }
            return encode(HostResponse.error(id: request.id, code: "unsafeOutput", message: "The correction contained unsafe model output."))
        }

        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = reservation.complete(
                usage: completion.usage, outputLength: 0,
                safetyResult: "emptyOutput", outcome: "blocked"
            )
            return encode(HostResponse.error(id: request.id, code: "unsafeOutput", message: "The correction was empty."))
        }
        _ = reservation.complete(
            usage: completion.usage, outputLength: corrected.count,
            safetyResult: "ok", outcome: "returned"
        )
        return encode(HostResponse(id: request.id, ok: true, text: corrected))
    }

    /// Testable prompt boundary shared by native-host paragraph proofreading.
    /// The host loads terms separately from the GUI process, but must apply the
    /// exact same relevance, casing, control-character, and cost policy.
    static func dictionaryPreservationLines(
        for text: String,
        dictionary: [DictionaryTerm]
    ) -> [String] {
        let list = DictionaryPromptFormatter.formattedRelevantTerms(
            from: dictionary,
            in: text,
            maximumTerms: 30
        )
        guard !list.isEmpty else { return [] }
        return ["Preserve these user terms exactly; do not 'correct' them: \(list)."]
    }

    /// Reads only Bean's exact app-owned user-content file. A redirected,
    /// hardlinked, non-regular, or oversized file fails closed before JSON
    /// decoding, so native-host dictionary loading is not an arbitrary read.
    static func dictionaryFromUserContentFile(at url: URL) -> [DictionaryTerm] {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        do {
            try ExactFileSystem.requireRealDirectoryChain(
                from: directory.deletingLastPathComponent(),
                through: directory
            )
            let data = try ExactFileSystem.readRegularFile(
                at: url,
                maximumBytes: UserContentFileLimits.maximumEncodedBytes
            ).data
            let file = try JSONDecoder().decode(NativeDictionaryFile.self, from: data)
            return Array(
                (file.dictionary ?? []).prefix(
                    UserContentFileLimits.maximumNativeDictionaryTerms
                )
            )
        } catch {
            return []
        }
    }

    /// The native boundary deliberately discards all page-supplied identity and
    /// field metadata. An unpacked extension can be modified, and a webpage can
    /// influence its messages, so neither a hostname nor an arbitrary field
    /// label is allowed to shape a provider prompt.
    static func browserSourceContext() -> SourceAppContext {
        SourceAppContext(
            appName: "Browser",
            bundleIdentifier: nil,
            processIdentifier: nil,
            focusedRole: "web editor",
            focusedSubrole: nil,
            acquisitionMode: .focusedFieldFullText,
            isSearchLikeField: false
        )
    }

    private struct NativeDictionaryFile: Decodable {
        let dictionary: [DictionaryTerm]?
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
    static var model: String { model(for: provider) }
    static func model(for provider: ProviderKind) -> String {
        provider.migratedModel(defaults.string(forKey: "model"))
    }
    static var apiKey: String { apiKey(for: provider) }
    static func apiKey(for provider: ProviderKind) -> String {
        guard case .value(let value) = KeychainService.get(
            account: provider.keychainAccount
        ) else { return "" }
        return value
    }
    static var timeout: TimeInterval {
        let stored = defaults.double(forKey: "timeoutSeconds")
        return min(max(stored > 0 ? stored : 30, 5), 120)
    }
    static var webInlineEnabled: Bool { defaults.bool(forKey: "webInlineEnabled") }
    static var dailyAutomaticCallLimit: Int {
        AutomaticCallBudgetPolicy.persistedDailyLimit(
            defaults.integer(forKey: "dailyAutomaticCallLimit")
        )
    }

    /// Status checks must be fast and non-interactive. The provider verification
    /// marker is content-free and is invalidated whenever the app changes or
    /// clears its API key, so status does not need to query Keychain.
    static var providerConfigured: Bool {
        isProviderConfigurationVerified(provider: provider, model: model)
    }

    static var statusConfiguration: NativeHostStatusConfiguration {
        NativeHostStatusConfiguration.read(
            defaults: defaults,
            automaticCallBudget: AutomaticCallBudgetStore()
        )
    }

    static func isProviderConfigurationVerified(provider: ProviderKind,
                                                model: String) -> Bool {
        NativeProviderVerificationPolicy.isVerified(
            capturedProvider: provider,
            capturedModel: model,
            defaults: defaults
        )
    }

    static func automaticMetadata(source: OperationSource, context: SourceAppContext,
                                  action: String, inputLength: Int,
                                  provider: ProviderKind, model: String) -> AutomaticCallMetadata {
        AutomaticCallMetadata(
            source: source, context: context, action: action,
            inputLength: inputLength, provider: provider.rawValue, model: model
        )
    }

    static func reserveAutomaticCall(
        metadata: AutomaticCallMetadata, timeout: TimeInterval
    ) -> AutomaticCallBudgetStore.ReservationResult {
        // The lease exceeds the effective provider timeout so an ordinary slow
        // request cannot lose its reservation, while a crashed process repairs
        // itself without user intervention.
        return AutomaticCallBudgetStore().reserve(
            dailyLimit: dailyAutomaticCallLimit,
            leaseDuration: max(timeout + 30, 60),
            metadata: metadata
        )
    }

    static func reserveAutomaticCallIfConfigurationVerified(
        provider: ProviderKind,
        model: String,
        metadata: AutomaticCallMetadata,
        timeout: TimeInterval
    ) -> AutomaticCallBudgetStore.ReservationResult? {
        NativeProviderVerificationPolicy.performIfVerified(
            capturedProvider: provider,
            capturedModel: model,
            defaults: defaults
        ) {
            reserveAutomaticCall(metadata: metadata, timeout: timeout)
        }
    }

    /// Dictionary terms loaded directly from the same JSON the app writes.
    static var dictionary: [DictionaryTerm] {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let url = dir.appendingPathComponent("Bean/userContent.json")
        return NativeMessagingHost.dictionaryFromUserContentFile(at: url)
    }

    /// One bounded user-role JSON value asking the proofread to preserve the
    /// user's relevant dictionary terms (preserve-only; never inserted).
    static func dictionaryPreservationLines(for text: String) -> [String] {
        NativeMessagingHost.dictionaryPreservationLines(for: text, dictionary: dictionary)
    }
}

// MARK: - Protocol DTOs

private struct HostRequest: Decodable {
    let id: String?
    let type: String
    let protocolVersion: Int?
    let extensionVersion: String?
    let minimumAppVersion: String?
    let text: String?
    let settings: Settings?

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
    var nativeHostConnected: Bool? = nil
    var providerConfigured: Bool? = nil
    var webInlineEnabled: Bool? = nil
    var protocolVersion: Int? = nil
    var extensionProtocolVersion: Int? = nil
    var appVersion: String? = nil
    var appBuild: String? = nil
    var extensionVersion: String? = nil
    var minimumExtensionVersion: String? = nil
    var minimumAppVersion: String? = nil
    var compatible: Bool? = nil
    var compatibilityCode: String? = nil
    var providerTimeoutSeconds: Double? = nil
    var requestTimeoutSeconds: Double? = nil
    var dailyAutomaticCallLimit: Int? = nil
    var automaticCallsToday: Int? = nil
    var automaticAccountingAvailable: Bool? = nil

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

    static func status(for request: HostRequest,
                       configuration: NativeHostStatusConfiguration) -> HostResponse {
        let compatibility = compatibility(for: request)
        return HostResponse(
            id: request.id,
            ok: true,
            message: compatibility.message,
            bridgeAvailable: true,
            nativeHostConnected: true,
            providerConfigured: configuration.providerConfigured,
            webInlineEnabled: configuration.webInlineEnabled,
            protocolVersion: NativeBridgeContract.protocolVersion,
            extensionProtocolVersion: request.protocolVersion,
            appVersion: AppInfo.version,
            appBuild: AppInfo.build,
            extensionVersion: request.extensionVersion,
            minimumExtensionVersion: NativeBridgeContract.minimumExtensionVersion,
            minimumAppVersion: request.minimumAppVersion,
            compatible: compatibility.isCompatible,
            compatibilityCode: compatibility.code,
            providerTimeoutSeconds: configuration.timeout,
            requestTimeoutSeconds: configuration.timeout,
            dailyAutomaticCallLimit: configuration.dailyAutomaticCallLimit,
            automaticCallsToday: configuration.automaticCallsToday,
            automaticAccountingAvailable: configuration.automaticAccountingAvailable
        )
    }

    private static func compatibility(for request: HostRequest) -> (
        isCompatible: Bool,
        code: String,
        message: String?
    ) {
        guard request.protocolVersion == NativeBridgeContract.protocolVersion else {
            return (
                false,
                "protocolMismatch",
                "Bean and the browser extension use different connection protocols. Update both, then try again."
            )
        }
        guard NativeBridgeContract.version(
            request.extensionVersion,
            isAtLeast: NativeBridgeContract.minimumExtensionVersion
        ) else {
            return (false, "extensionUpdateRequired", "This Bean app needs a newer browser extension.")
        }
        guard let minimumAppVersion = request.minimumAppVersion,
              NativeBridgeContract.version(AppInfo.version, isAtLeast: minimumAppVersion) else {
            return (false, "beanUpdateRequired", "This browser extension needs a newer Bean app.")
        }
        return (true, "compatible", nil)
    }
}
