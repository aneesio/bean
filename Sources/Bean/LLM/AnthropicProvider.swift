import Foundation

// Anthropic Messages API implementation.
// Endpoint: POST https://api.anthropic.com/v1/messages
struct AnthropicProvider: LLMProvider {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"

    func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        guard !request.apiKey.isEmpty else { throw LLMError.missingAPIKey }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        // Anthropic takes the TRUSTED instruction as the top-level `system`
        // field and the UNTRUSTED, delimited user content as the sole user
        // message. They are never merged, so instructions embedded in the
        // user's text are not treated as commands.
        let body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxOutputTokens,
            "temperature": 0,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userText]
            ]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    static func parseCompletion(data: Data, request: LLMRequest) throws -> LLMCompletion {
        // Response shape: { "content": [ { "type": "text", "text": "..." } ] }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw LLMError.decoding
        }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        let usage: LLMUsage
        if let rawUsage = json["usage"] as? [String: Any],
           let input = rawUsage["input_tokens"] as? Int,
           let output = rawUsage["output_tokens"] as? Int {
            usage = LLMUsage(inputTokens: input, outputTokens: output, isEstimated: false)
        } else {
            usage = .estimated(for: request, output: text)
        }
        return LLMCompletion(text: text, usage: usage)
    }

    private static func extractError(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
