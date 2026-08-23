import Foundation

// Errors surfaced by providers. The coordinator maps these to user-friendly
// status messages.
enum LLMError: LocalizedError {
    case missingAPIKey
    case inputTooLong(maxCharacters: Int)
    case invalidAPIKey
    case network(String)
    case timeout
    case emptyResponse
    case server(status: Int, message: String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing API key"
        case .inputTooLong(let maxCharacters):
            return "Text is longer than Bean's \(maxCharacters.formatted())-character AI limit"
        case .invalidAPIKey: return "Invalid API key"
        case .network(let detail): return "Network error: \(detail)"
        case .timeout: return "Request timed out"
        case .emptyResponse: return "The model returned an empty response"
        case .server(let status, let message): return "Provider error (\(status)): \(message)"
        case .decoding: return "Could not read the provider's response"
        }
    }
}

// Configuration passed to a provider for a single request. Keeps providers free
// of any dependency on AppSettings.
//
// SECURITY BOUNDARY: `systemPrompt` is Bean's TRUSTED instruction. `userText`
// is an UNTRUSTED user-role payload (serialized as one JSON object by Bean's
// prompt builders) and must never be merged into the system prompt. This
// separation keeps instructions embedded in text or personalization out of the
// trusted instruction channel.
struct LLMRequest {
    let systemPrompt: String
    let userText: String
    let model: String
    let apiKey: String
    let timeout: TimeInterval
    /// Hard ceiling for generated tokens. Keeping this request-specific avoids a
    /// runaway explanatory response and materially limits output-token spend.
    let maxOutputTokens: Int
}

/// Content-free provider metering attached to a completion. Provider-reported
/// counts are preferred; Bean marks its conservative byte-based fallback.
struct LLMUsage: Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let isEstimated: Bool

    init(inputTokens: Int, outputTokens: Int, isEstimated: Bool) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.isEstimated = isEstimated
    }

    static func estimated(for request: LLMRequest, output: String) -> LLMUsage {
        // Three UTF-8 bytes per token intentionally errs above the common
        // English approximation, and is safer for non-Latin input.
        let inputBytes = request.systemPrompt.utf8.count + request.userText.utf8.count
        return LLMUsage(inputTokens: max(1, (inputBytes + 2) / 3),
                        outputTokens: max(1, (output.utf8.count + 2) / 3),
                        isEstimated: true)
    }
}

struct LLMCompletion: Equatable {
    let text: String
    let usage: LLMUsage
}

// Clean abstraction over a chat/completions-style provider. New providers
// (Gemini, local models, etc.) only need to conform to this protocol.
protocol LLMProvider {
    /// Sends `request.userText` plus `request.systemPrompt` and returns the
    /// corrected text. Throws LLMError on any failure.
    func complete(_ request: LLMRequest) async throws -> LLMCompletion
}

extension LLMProvider {
    /// Shared URLSession factory honouring the per-request timeout.
    func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }

    /// Maps low-level URLSession errors onto LLMError.
    func mapTransportError(_ error: Error) -> LLMError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return .timeout
        }
        return .network(nsError.localizedDescription)
    }
}

/// Builds the right provider implementation for a given kind.
enum LLMProviderFactory {
    static func make(_ kind: ProviderKind) -> LLMProvider {
        switch kind {
        case .openai: return OpenAIProvider()
        case .anthropic: return AnthropicProvider()
        }
    }
}
