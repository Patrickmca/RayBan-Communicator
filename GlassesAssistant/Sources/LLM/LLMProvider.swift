import Foundation

// Provider-neutral types. Everything above this layer (AppModel, UI) talks only to these, so a
// second provider (OpenAI, Phase 2) is a new `LLMProvider` conformance plus a `ProviderID` case.

/// Identifies an LLM backend. Phase 2: add `case openai` and handle it in `ProviderRegistry`.
enum ProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        }
    }
}

/// One turn of the conversation.
struct ChatTurn: Identifiable, Sendable, Equatable {
    enum Role: String, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    /// Plain text, used for display and for replaying the turn to a *different* provider.
    let text: String
    /// Provider-native content, replayed verbatim when the same provider handles the next turn
    /// (Anthropic requires its thinking blocks to be sent back unchanged).
    let native: NativeContent?

    init(id: UUID = UUID(), role: Role, text: String, native: NativeContent? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.native = native
    }
}

struct NativeContent: Sendable, Equatable {
    let provider: ProviderID
    let model: String
    let payload: JSONValue
}

struct LLMRequest: Sendable {
    var system: String
    var turns: [ChatTurn]
}

enum LLMEvent: Sendable {
    /// Incremental reply text, suitable for speaking as it arrives.
    case textDelta(String)
    /// The complete assistant turn, to append to the conversation.
    case finished(ChatTurn)
}

protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    /// Streams the reply. Cancelling the consuming task cancels the network request.
    func streamReply(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

enum LLMError: LocalizedError, Equatable {
    case missingAPIKey(ProviderID)
    case http(status: Int, type: String?, message: String)
    case server(type: String?, message: String)
    case refused(category: String?)
    case incompleteStream
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "Add your \(provider.displayName) API key in Settings."
        case .http(401, _, _):
            "The API key was rejected (401). Check it in Settings."
        case .http(429, _, let message):
            "Rate limited (429): \(message)"
        case .http(let status, let type, let message):
            "API error \(status)\(type.map { " \($0)" } ?? ""): \(message)"
        case .server(let type, let message):
            "Stream error\(type.map { " \($0)" } ?? ""): \(message)"
        case .refused(let category):
            "The model declined this request\(category.map { " (\($0))" } ?? "")."
        case .incompleteStream:
            "The response ended unexpectedly."
        case .invalidResponse:
            "Unexpected response from the server."
        }
    }

    /// Short line for the glasses speaker.
    var spokenDescription: String {
        switch self {
        case .missingAPIKey: "I need an API key. Add one in the app's settings."
        case .http(401, _, _): "The API key was rejected."
        case .http(429, _, _): "I'm being rate limited. Try again in a moment."
        case .refused: "Sorry, I can't help with that."
        default: "Sorry, something went wrong reaching the assistant."
        }
    }
}
