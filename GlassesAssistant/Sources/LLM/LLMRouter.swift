import Foundation

/// What a router may look at when choosing a provider for the next reply.
struct RoutingContext: Sendable {
    let latestUserText: String
    let history: [ChatTurn]
}

/// Chooses which provider answers a turn.
///
/// Phase 1 ships `FixedRouter`. Phase 2 can add e.g. a `RuleBasedRouter` that picks between
/// Anthropic and OpenAI by keyword, latency budget, or availability (and falls back on errors),
/// without touching `AppModel`.
protocol LLMRouter: Sendable {
    func route(_ context: RoutingContext) throws -> any LLMProvider
}

/// Always uses the same provider.
struct FixedRouter: LLMRouter {
    let provider: any LLMProvider

    func route(_ context: RoutingContext) throws -> any LLMProvider { provider }
}

/// Builds providers from Keychain keys and user settings.
struct ProviderRegistry {
    let keychain: KeychainStore

    struct Options: Sendable {
        var anthropicEffort: AnthropicProvider.Effort
    }

    func makeProvider(_ id: ProviderID, options: Options) throws -> any LLMProvider {
        guard let key = try keychain.apiKey(for: id), !key.isEmpty else {
            throw LLMError.missingAPIKey(id)
        }
        switch id {
        case .anthropic:
            var configuration = AnthropicProvider.Configuration()
            configuration.effort = options.anthropicEffort
            return AnthropicProvider(apiKey: key, configuration: configuration)
        // Phase 2: case .openai: return OpenAIProvider(apiKey: key, ...)
        }
    }

    /// Phase 1: one provider. Phase 2: build every provider that has a key and hand them to a
    /// multi-provider router.
    func makeRouter(defaultProvider: ProviderID, options: Options) throws -> any LLMRouter {
        FixedRouter(provider: try makeProvider(defaultProvider, options: options))
    }
}
