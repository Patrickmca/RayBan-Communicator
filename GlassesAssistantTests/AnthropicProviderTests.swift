import XCTest

@testable import GlassesAssistant

final class AnthropicStreamAccumulatorTests: XCTestCase {
    private func feed(_ events: [String]) throws -> (AnthropicStreamAccumulator, [String]) {
        var accumulator = AnthropicStreamAccumulator()
        var texts: [String] = []
        for event in events {
            if let text = try accumulator.consume(Data(event.utf8)) { texts.append(text) }
        }
        return (accumulator, texts)
    }

    func testRebuildsThinkingAndTextBlocks() throws {
        let (accumulator, texts) = try feed([
            #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","content":[]}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_details":null},"usage":{"output_tokens":9}}"#,
            #"{"type":"message_stop"}"#,
        ])

        XCTAssertEqual(texts, ["Hello", " there."])
        let turn = try accumulator.makeAssistantTurn(fallbackModel: "x")
        XCTAssertEqual(turn.text, "Hello there.")
        XCTAssertEqual(turn.native?.model, "claude-opus-5-5")
        XCTAssertEqual(
            turn.native?.payload,
            [
                ["type": "thinking", "thinking": "", "signature": "sig123"],
                ["type": "text", "text": "Hello there."],
            ]
        )
    }

    func testRefusalThrows() throws {
        let (accumulator, _) = try feed([
            #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}}"#,
        ])
        XCTAssertThrowsError(try accumulator.makeAssistantTurn(fallbackModel: "x")) { error in
            XCTAssertEqual(error as? LLMError, .refused(category: "cyber"))
        }
    }

    func testStreamErrorEventThrows() {
        var accumulator = AnthropicStreamAccumulator()
        let event = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertThrowsError(try accumulator.consume(Data(event.utf8))) { error in
            XCTAssertEqual(error as? LLMError, .server(type: "overloaded_error", message: "Overloaded"))
        }
    }

    func testMissingStopReasonIsIncomplete() throws {
        let (accumulator, _) = try feed([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hi"}}"#
        ])
        XCTAssertThrowsError(try accumulator.makeAssistantTurn(fallbackModel: "x")) { error in
            XCTAssertEqual(error as? LLMError, .incompleteStream)
        }
    }

    func testMidOutputFallbackEchoesOnlyTextBeforeBoundary() throws {
        let (accumulator, _) = try feed([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":"a"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Part one. "}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":"Part two."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ])
        let types = accumulator.assistantContent.compactMap { $0["type"]?.stringValue }
        XCTAssertEqual(types, ["text", "fallback", "text"])
    }
}

final class AnthropicProviderTests: XCTestCase {
    func testRequestShape() throws {
        let provider = AnthropicProvider(apiKey: "test-key", configuration: .init())
        let previous = ChatTurn(
            role: .assistant,
            text: "Hi.",
            native: NativeContent(
                provider: .anthropic,
                model: "claude-opus-5-5",
                payload: [["type": "thinking", "thinking": "", "signature": "s"], ["type": "text", "text": "Hi."]]
            )
        )
        let request = LLMRequest(
            system: "Be brief.",
            turns: [ChatTurn(role: .user, text: "Hello"), previous, ChatTurn(role: .user, text: "Weather?")]
        )

        let urlRequest = try provider.makeURLRequest(for: request)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(urlRequest.httpBody))
        XCTAssertEqual(body["model"], "claude-opus-5-5")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["fallbacks"], "default")
        XCTAssertEqual(body["output_config"]?["effort"], "low")
        XCTAssertNil(body["thinking"])
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 3)
        // Claude's own blocks (with the thinking signature) are replayed unchanged.
        XCTAssertEqual(messages[1]["content"], previous.native?.payload)
    }

    func testHTTPErrorParsing() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertEqual(
            AnthropicProvider.httpError(status: 401, body: body),
            .http(status: 401, type: "authentication_error", message: "invalid x-api-key")
        )
    }
}
