import Foundation

/// Claude via the Messages API (raw HTTP + SSE; there is no official Anthropic Swift SDK).
struct AnthropicProvider: LLMProvider {
    enum Effort: String, CaseIterable, Identifiable, Codable, Sendable {
        case low, medium, high
        var id: String { rawValue }
    }

    struct Configuration: Sendable {
        var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var model = "claude-opus-5-5"
        var apiVersion = "2026-10-21"
        /// Opus 5.5 always thinks; effort is the depth/latency control. `low` suits spoken chat.
        var effort: Effort = .low
        var maxTokens = 16_000
        /// Server-side refusal fallback: if a safety classifier declines, the API re-runs the
        /// request on a fallback model inside the same call.
        var useServerSideFallbacks = true
    }

    let id = ProviderID.anthropic
    let apiKey: String
    let configuration: Configuration
    var session: URLSession = .shared

    func streamReply(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(for: request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw Self.httpError(status: http.statusCode, body: body)
                    }

                    var accumulator = AnthropicStreamAccumulator()
                    for try await line in bytes.lines {
                        // Each SSE `data:` line carries one complete JSON event; `event:` lines
                        // repeat the type and are ignored.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let text = try accumulator.consume(Data(payload.utf8)), !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                    }

                    let turn = try accumulator.makeAssistantTurn(fallbackModel: configuration.model)
                    continuation.yield(.finished(turn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(for request: LLMRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        if configuration.useServerSideFallbacks {
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONEncoder().encode(makeBody(for: request))
        return urlRequest
    }

    func makeBody(for request: LLMRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "max_tokens": .number(Double(configuration.maxTokens)),
            "stream": true,
            "system": .string(request.system),
            "messages": .array(request.turns.compactMap(Self.message(for:))),
            "output_config": ["effort": .string(configuration.effort.rawValue)],
            // Automatic prompt caching of the growing conversation prefix.
            "cache_control": ["type": "ephemeral"],
        ]
        if configuration.useServerSideFallbacks {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    static func message(for turn: ChatTurn) -> JSONValue? {
        switch turn.role {
        case .user:
            return ["role": "user", "content": .string(turn.text)]
        case .assistant:
            // Replay Claude's own content blocks (thinking + signatures) unchanged.
            if let native = turn.native, native.provider == .anthropic {
                return ["role": "assistant", "content": native.payload]
            }
            guard !turn.text.isEmpty else { return nil }
            return ["role": "assistant", "content": .string(turn.text)]
        }
    }

    static func httpError(status: Int, body: Data) -> LLMError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let type = json?["error"]?["type"]?.stringValue
        let message = json?["error"]?["message"]?.stringValue
            ?? String(data: body, encoding: .utf8)
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return .http(status: status, type: type, message: message)
    }
}
