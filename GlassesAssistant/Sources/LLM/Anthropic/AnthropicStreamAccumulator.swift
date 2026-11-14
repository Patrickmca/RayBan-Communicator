import Foundation

/// Rebuilds a Messages API response from its SSE events.
///
/// Pure value type (no networking) so it can be unit-tested with recorded events.
struct AnthropicStreamAccumulator {
    private(set) var blocks: [Int: [String: JSONValue]] = [:]
    private(set) var stopReason: String?
    private(set) var refusalCategory: String?
    private(set) var servedModel: String?
    private var partialJSON: [Int: String] = [:]

    /// Consumes one `data:` payload. Returns any new reply text.
    mutating func consume(_ payload: Data) throws -> String? {
        let event = try JSONDecoder().decode(JSONValue.self, from: payload)
        switch event["type"]?.stringValue {
        case "message_start":
            servedModel = event["message"]?["model"]?.stringValue

        case "content_block_start":
            guard let index = event["index"]?.intValue,
                let block = event["content_block"]?.objectValue
            else { return nil }
            blocks[index] = block
            if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue, !text.isEmpty {
                return text
            }

        case "content_block_delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"] else { return nil }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                append(text, to: "text", at: index)
                return text
            case "thinking_delta":
                append(delta["thinking"]?.stringValue ?? "", to: "thinking", at: index)
            case "signature_delta":
                blocks[index]?["signature"] = delta["signature"]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            default:
                break  // citations_delta etc. are not used by this app.
            }

        case "content_block_stop":
            if let index = event["index"]?.intValue, let json = partialJSON.removeValue(forKey: index),
                let input = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            {
                blocks[index]?["input"] = input
            }

        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue {
                stopReason = reason
            }
            if let category = (event["delta"]?["stop_details"] ?? event["stop_details"])?["category"]?.stringValue {
                refusalCategory = category
            }

        case "error":
            throw LLMError.server(
                type: event["error"]?["type"]?.stringValue,
                message: event["error"]?["message"]?.stringValue ?? "Unknown stream error"
            )

        default:
            break  // ping, message_stop
        }
        return nil
    }

    /// All reply text, in block order.
    var text: String {
        orderedBlocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
    }

    /// Content blocks to echo back as the assistant turn next time.
    ///
    /// After a mid-output server-side fallback, only `text` blocks before the last `fallback`
    /// block are echoed; the `fallback` block stays in place and everything after it is kept.
    var assistantContent: [JSONValue] {
        let ordered = orderedBlocks
        guard let boundary = ordered.lastIndex(where: { $0["type"]?.stringValue == "fallback" }) else {
            return ordered.map(JSONValue.object)
        }
        return ordered.enumerated()
            .filter { index, block in index >= boundary || block["type"]?.stringValue == "text" }
            .map { JSONValue.object($0.element) }
    }

    func makeAssistantTurn(fallbackModel: String) throws -> ChatTurn {
        guard let stopReason else { throw LLMError.incompleteStream }
        if stopReason == "refusal" { throw LLMError.refused(category: refusalCategory) }
        return ChatTurn(
            role: .assistant,
            text: text,
            native: NativeContent(
                provider: .anthropic,
                model: servedModel ?? fallbackModel,
                payload: .array(assistantContent)
            )
        )
    }

    private var orderedBlocks: [[String: JSONValue]] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    private mutating func append(_ string: String, to key: String, at index: Int) {
        let existing = blocks[index]?[key]?.stringValue ?? ""
        if blocks[index] == nil { blocks[index] = [:] }
        blocks[index]?[key] = .string(existing + string)
    }
}
