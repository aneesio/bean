import Foundation

/// Curated text models and the request settings Bean has verified for them.
/// Keep selection and payload construction on the same catalog: model families
/// do not necessarily accept the same sampling or reasoning parameters.
struct ProviderModel: Identifiable, Equatable {
    struct RequestOptions: Equatable {
        var temperature: Double? = nil
        var openAIReasoningEffort: String? = nil
        var openAIVerbosity: String? = nil
        var openAIUsesCompletionTokenLimit = false
        var anthropicThinkingDisabled = false
    }

    let id: String
    let displayName: String
    let detail: String
    var aliases: [String] = []
    let requestOptions: RequestOptions
}

extension ProviderKind {
    /// Only models compatible with Bean's bounded, text-only writing requests.
    /// Sources: developers.openai.com/api/docs/guides/latest-model and
    /// platform.claude.com/docs/en/models/haiku-5-5/migration-guide.
    var supportedModels: [ProviderModel] {
        switch self {
        case .openai:
            let gpt5 = ProviderModel.RequestOptions(
                openAIReasoningEffort: "minimal",
                openAIVerbosity: "low",
                openAIUsesCompletionTokenLimit: true
            )
            let standard = ProviderModel.RequestOptions(temperature: 0)
            return [
                ProviderModel(id: "gpt-5-nano", displayName: "GPT-5 nano",
                              detail: "Bean's default OpenAI model for short writing tasks.",
                              aliases: ["gpt-5-nano-2025-08-07"], requestOptions: gpt5),
                ProviderModel(id: "gpt-6-luna", displayName: "GPT-6 Luna",
                              detail: "An efficient model for focused writing tasks.",
                              requestOptions: .init(openAIReasoningEffort: "none",
                                                    openAIVerbosity: "low",
                                                    openAIUsesCompletionTokenLimit: true)),
                ProviderModel(id: "gpt-5-mini", displayName: "GPT-5 mini",
                              detail: "A smaller GPT-5 model for proofreading and rewrites.",
                              aliases: ["gpt-5-mini-2025-08-07"], requestOptions: gpt5),
                ProviderModel(id: "gpt-5", displayName: "GPT-5",
                              detail: "A larger GPT-5 model for writing tasks.",
                              aliases: ["gpt-5-2025-08-07"], requestOptions: gpt5),
                ProviderModel(id: "gpt-4.1-nano", displayName: "GPT-4.1 nano",
                              detail: "A small model for straightforward writing tasks.",
                              aliases: ["gpt-4.1-nano-2025-04-14"], requestOptions: standard),
                ProviderModel(id: "gpt-4.1-mini", displayName: "GPT-4.1 mini",
                              detail: "A smaller GPT-4.1 model for proofreading and rewrites.",
                              aliases: ["gpt-4.1-mini-2025-04-14"], requestOptions: standard),
                ProviderModel(id: "gpt-4.1", displayName: "GPT-4.1",
                              detail: "A larger GPT-4.1 model for writing tasks.",
                              aliases: ["gpt-4.1-2025-04-14"], requestOptions: standard),
                ProviderModel(id: "gpt-4o-mini", displayName: "GPT-4o mini",
                              detail: "A smaller GPT-4o model for writing tasks.",
                              requestOptions: standard),
                ProviderModel(id: "gpt-4o", displayName: "GPT-4o",
                              detail: "A GPT-4o model for proofreading and rewrites.",
                              requestOptions: standard)
            ]
        case .anthropic:
            let standard = ProviderModel.RequestOptions(temperature: 0)
            return [
                ProviderModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
                              detail: "The latest Haiku model for quick proofreading and rewrites.",
                              requestOptions: .init(anthropicThinkingDisabled: true)),
                ProviderModel(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5",
                              detail: "Bean's default Anthropic model for short writing tasks.",
                              aliases: ["claude-haiku-4-5-20251001"], requestOptions: standard),
                ProviderModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6",
                              detail: "A Sonnet model for proofreading and rewrites.",
                              requestOptions: standard),
                ProviderModel(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5",
                              detail: "A previous Sonnet model for writing tasks.",
                              aliases: ["claude-sonnet-4-5-20250929"], requestOptions: standard),
                ProviderModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6",
                              detail: "A larger Claude model for writing tasks.",
                              requestOptions: standard),
                ProviderModel(id: "claude-opus-4-5", displayName: "Claude Opus 4.5",
                              detail: "A previous Opus model for writing tasks.",
                              aliases: ["claude-opus-4-5-20251101"], requestOptions: standard)
            ]
        }
    }

    func modelDefinition(for modelID: String) -> ProviderModel? {
        supportedModels.first { $0.id == modelID || $0.aliases.contains(modelID) }
    }

    /// Preserve the user's saved ID during an upgrade, including a pinned
    /// version or custom model. The UI offers only curated new selections.
    func modelChoices(including savedModelID: String) -> [ProviderModel] {
        let models = supportedModels
        guard !savedModelID.isEmpty, !models.contains(where: { $0.id == savedModelID }) else {
            return models
        }
        let definition = modelDefinition(for: savedModelID)
        let savedModel = ProviderModel(
            id: savedModelID,
            displayName: "\(savedModelID) (\(definition == nil ? "saved model" : "saved version"))",
            detail: definition?.detail
                ?? "Your saved model is retained. Choose a listed model for settings verified by Bean.",
            requestOptions: definition?.requestOptions ?? .init()
        )
        return models + [savedModel]
    }
}
