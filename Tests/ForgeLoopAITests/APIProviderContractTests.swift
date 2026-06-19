import Foundation
import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopTestSupport

/// Cross-provider contract tests.
///
/// Every supported provider must, given a simple text SSE response, emit:
/// - at least one `.start` event
/// - `.textDelta` events whose joined text equals the expected assistant text
/// - a final `.done` event
/// - a `stream.result()` with `.endTurn` stop reason and no error
final class APIProviderContractTests: XCTestCase {
    private let context = Context(
        systemPrompt: "You are helpful.",
        messages: [
            .user(UserMessage(text: "hello"))
        ]
    )

    // MARK: - OpenAI Responses

    func testOpenAIResponsesProviderTextContract() async throws {
        let payload = """
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Hello"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":" world"}

event: response.completed
data: {"type":"response.completed"}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)
        let model = Model(id: "gpt-4.1-mini", name: "GPT-4.1 mini", api: "openai-responses", provider: "openai")

        try await assertTextContract(provider: provider, model: model, expectedText: "Hello world")
    }

    // MARK: - OpenAI Chat Completions

    func testOpenAIChatCompletionsProviderTextContract() async throws {
        let payload = """
data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-1","choices":[{"delta":{"content":" world"},"finish_reason":null}]}

data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)
        let model = Model(id: "deepseek-chat", name: "DeepSeek Chat", api: "openai-chat", provider: "deepseek", baseUrl: "https://api.deepseek.com")

        try await assertTextContract(provider: provider, model: model, expectedText: "Hello world")
    }

    // MARK: - Anthropic

    func testAnthropicProviderTextContract() async throws {
        let payload = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-4-5","usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

event: message_stop
data: {"type":"message_stop"}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = AnthropicProvider(defaultAPIKey: "sk-test", httpClient: client)
        let model = Model(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", api: "anthropic", provider: "anthropic")

        try await assertTextContract(provider: provider, model: model, expectedText: "Hello world")
    }

    // MARK: - Gemini

    func testGeminiProviderTextContract() async throws {
        let payload = """
data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]}}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello world"}]}}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello world!"}]},"finishReason":"STOP"}]}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = GeminiProvider(defaultAPIKey: "gemini-test", httpClient: client)
        let model = Model(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", api: "gemini", provider: "google")

        try await assertTextContract(provider: provider, model: model, expectedText: "Hello world!")
    }

    // MARK: - Contract assertion

    private func assertTextContract(
        provider: any APIProvider,
        model: Model,
        expectedText: String
    ) async throws {
        let stream = provider.stream(model: model, context: context, options: nil)

        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains {
            if case .start = $0 { return true }
            return false
        }, "Provider \(type(of: provider)) did not emit .start")

        XCTAssertTrue(events.contains {
            if case .done = $0 { return true }
            return false
        }, "Provider \(type(of: provider)) did not emit .done")

        let deltaText = events.compactMap { event -> String? in
            if case .textDelta(_, let delta, _) = event { return delta }
            return nil
        }.joined()
        XCTAssertEqual(deltaText, expectedText, "Provider \(type(of: provider)) text deltas mismatch")

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .endTurn, "Provider \(type(of: provider)) stop reason mismatch")
        XCTAssertNil(result.errorMessage, "Provider \(type(of: provider)) emitted an error")
        XCTAssertEqual(text(from: result), expectedText, "Provider \(type(of: provider)) result text mismatch")
    }
}
