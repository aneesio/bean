import Foundation

// Errors surfaced by providers. The coordinator maps these to user-friendly
// status messages.
enum LLMError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case network(String)
    case timeout
    case emptyResponse
    case server(status: Int, message: String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing API key"
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
// is the UNTRUSTED user content (wrapped in delimiters by WritingTransformService)
// and must be sent strictly as the user-role message — never merged into the
// system prompt. This separation is what stops instructions embedded in the
// user's text from being obeyed.
struct LLMRequest {
    let systemPrompt: String
    let userText: String
    let model: String
    let apiKey: String
    let timeout: TimeInterval
}

// Clean abstraction over a chat/completions-style provider. New providers
// (Gemini, local models, etc.) only need to conform to this protocol.
protocol LLMProvider {
    /// Sends `request.userText` plus `request.systemPrompt` and returns the
    /// corrected text. Throws LLMError on any failure.
    func complete(_ request: LLMRequest) async throws -> String
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
