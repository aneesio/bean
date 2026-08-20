import Foundation

// OpenAI Chat Completions implementation.
// Endpoint: POST https://api.openai.com/v1/chat/completions
struct OpenAIProvider: LLMProvider {
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func complete(_ request: LLMRequest) async throws -> String {
        guard !request.apiKey.isEmpty else { throw LLMError.missingAPIKey }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")

        // Trusted instructions go in the system message; the user's (untrusted,
        // delimited) content goes in the user message. Never merge them.
        let body: [String: Any] = [
            "model": request.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
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

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMError.decoding
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return content
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
