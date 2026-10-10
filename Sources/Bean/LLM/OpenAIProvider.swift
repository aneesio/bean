import Foundation

// OpenAI Chat Completions implementation.
// Endpoint: POST https://api.openai.com/v1/chat/completions
struct OpenAIProvider: LLMProvider {
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        let urlRequest = try Self.buildRequest(request)

        let session = makeSession(timeout: request.timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw mapTransportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("No HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw LLMError.invalidAPIKey }
            throw LLMError.server(status: http.statusCode, message: Self.extractError(data))
        }

        let completion = try Self.parseCompletion(data: data, request: request)
        let trimmed = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return completion
    }

    /// Uses the selected model's documented parameters rather than inferring
    /// capabilities from a family prefix, which can change between versions.
    static func buildRequest(_ request: LLMRequest) throws -> URLRequest {
        guard !request.apiKey.isEmpty else { throw LLMError.missingAPIKey }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")

        // Trusted instructions go in the system message; the user's (untrusted,
        // delimited) content goes in the user message. Never merge them.
        var body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userText]
            ]
        ]
        let options = ProviderKind.openai.modelDefinition(for: request.model)?.requestOptions
        // Legacy saved IDs retain a bounded request without speculative sampling
        // or reasoning settings. The replacement for deprecated max_tokens also
        // supports standard chat models and is required by reasoning models.
        let usesCompletionTokenLimit = options?.openAIUsesCompletionTokenLimit ?? true
        let tokenLimitKey = usesCompletionTokenLimit ? "max_completion_tokens" : "max_tokens"
        body[tokenLimitKey] = request.maxOutputTokens
        if let temperature = options?.temperature {
            body["temperature"] = temperature
        }
        if let effort = options?.openAIReasoningEffort {
            body["reasoning_effort"] = effort
        }
        if let verbosity = options?.openAIVerbosity {
            body["verbosity"] = verbosity
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func parseCompletion(data: Data, request: LLMRequest) throws -> LLMCompletion {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMError.decoding
        }
        let usage: LLMUsage
        if let rawUsage = json["usage"] as? [String: Any],
           let input = rawUsage["prompt_tokens"] as? Int,
           let output = rawUsage["completion_tokens"] as? Int {
            usage = LLMUsage(inputTokens: input, outputTokens: output, isEstimated: false)
        } else {
            usage = .estimated(for: request, output: content)
        }
        return LLMCompletion(text: content, usage: usage)
    }

    /// Pulls a human-readable message out of an OpenAI error payload.
    private static func extractError(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
