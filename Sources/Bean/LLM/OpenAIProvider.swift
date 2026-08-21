import Foundation

// OpenAI Chat Completions implementation.
// Endpoint: POST https://api.openai.com/v1/chat/completions
struct OpenAIProvider: LLMProvider {
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        guard !request.apiKey.isEmpty else { throw LLMError.missingAPIKey }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
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
        if Self.usesModernCompletionLimit(request.model) {
            body["max_completion_tokens"] = request.maxOutputTokens
            // GPT-5 family models reject arbitrary temperature values. Minimal
            // reasoning and low verbosity fit Bean's short transformation task.
            if request.model.lowercased().hasPrefix("gpt-5") {
                body["reasoning_effort"] = "minimal"
                body["verbosity"] = "low"
            }
        } else {
            body["max_tokens"] = request.maxOutputTokens
            body["temperature"] = 0
        }
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

    private static func usesModernCompletionLimit(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.hasPrefix("gpt-5")
            || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4")
    }
}
