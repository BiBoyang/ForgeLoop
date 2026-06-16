import Foundation
import XCTest
@testable import ForgeLoopAI

final class AnthropicProviderTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "claude-sonnet-4-5",
            name: "Claude Sonnet 4.5",
            api: "anthropic",
            provider: "anthropic"
        )
    }

    private var testContext: Context {
        Context(
            systemPrompt: "You are helpful.",
            messages: [
                .user(UserMessage(text: "hello")),
                .assistant(AssistantMessage.text("hi")),
            ]
        )
    }

    func testTextStreamProducesTextDeltaAndDone() async throws {
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
        let client = StubAnthropicHTTPClient(statusCode: 200, payload: payload)
        let provider = AnthropicProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains {
            if case .start = $0 { return true }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .done = $0 { return true }
            return false
        })

        let deltaText = events.compactMap { event -> String? in
            if case .textDelta(_, let delta, _) = event { return delta }
            return nil
        }.joined()
        XCTAssertEqual(deltaText, "Hello world")

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(text(from: result), "Hello world")

        guard let request = await client.capturedRequest() else {
            XCTFail("Expected captured request")
            return
        }
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.headers["content-type"], "application/json")
    }

    func testToolUseDetected() async throws {
        let payload = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_2","model":"claude-sonnet-4-5","usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me read"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"file.txt\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":10}}

event: message_stop
data: {"type":"message_stop"}

"""
        let client = StubAnthropicHTTPClient(statusCode: 200, payload: payload)
        let provider = AnthropicProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        let result = await stream.result()

        XCTAssertEqual(result.stopReason, .toolUse)
        XCTAssertNil(result.errorMessage)

        let texts = result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }
        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(texts, ["Let me read"])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.id, "toolu_1")
        XCTAssertEqual(toolCalls.first?.name, "read")
        XCTAssertEqual(toolCalls.first?.arguments, "{\"path\":\"file.txt\"}")
    }

    func testCancelDoesNotDoubleTerminate() async throws {
        let payload = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_3","model":"claude-sonnet-4-5","usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}

"""
        let client = StubAnthropicHTTPClient(statusCode: 200, payload: payload, delayNanos: 25_000_000)
        let provider = AnthropicProvider(defaultAPIKey: "sk-test", httpClient: client)
        let cancellation = CancellationHandle()

        let stream = provider.stream(
            model: testModel,
            context: testContext,
            options: StreamOptions(cancellation: cancellation)
        )

        try await Task.sleep(nanoseconds: 120_000_000)
        cancellation.cancel(reason: "test abort")

        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let hasAbortedError = events.contains {
            if case .error(let reason, _) = $0, reason == .aborted { return true }
            return false
        }
        let hasDone = events.contains {
            if case .done = $0 { return true }
            return false
        }
        XCTAssertTrue(hasAbortedError)
        XCTAssertFalse(hasDone)

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .aborted)
    }

    func testMessageConversion() async throws {
        let payload = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_4","model":"claude-sonnet-4-5","usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}

"""
        let client = StubAnthropicHTTPClient(statusCode: 200, payload: payload)
        let provider = AnthropicProvider(defaultAPIKey: "sk-test", httpClient: client)

        let toolDef = try ToolDefinition(
            name: "read",
            description: "Read a file",
            parameters: ["type": "object", "properties": [:]]
        )

        let context = Context(
            systemPrompt: "You are helpful.",
            messages: [
                .assistant(AssistantMessage(
                    content: [
                        .text(TextContent(text: "Let me read")),
                        .toolCall(ToolCall(id: "toolu_1", name: "read", arguments: "{\"path\":\"a.txt\"}"))
                    ],
                    stopReason: .toolUse
                )),
                .tool(ToolResultMessage(toolCallId: "toolu_1", output: "content", isError: false)),
            ]
        )

        let stream = provider.stream(
            model: testModel,
            context: context,
            options: StreamOptions(tools: [toolDef], toolChoice: "auto")
        )
        _ = await stream.result()

        guard let request = await client.capturedRequest(), let body = request.body else {
            XCTFail("Expected captured request with body")
            return
        }

        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("Expected JSON body object")
            return
        }

        XCTAssertEqual(object["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(object["system"] as? String, "You are helpful.")
        XCTAssertEqual(object["max_tokens"] as? Int, 16000)
        XCTAssertEqual(object["stream"] as? Bool, true)

        guard let tools = object["tools"] as? [[String: Any]] else {
            XCTFail("Expected tools array")
            return
        }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "read")
        XCTAssertEqual(tools[0]["description"] as? String, "Read a file")
        XCTAssertNotNil(tools[0]["input_schema"])

        guard let toolChoice = object["tool_choice"] as? [String: Any] else {
            XCTFail("Expected tool_choice object")
            return
        }
        XCTAssertEqual(toolChoice["type"] as? String, "auto")

        guard let messages = object["messages"] as? [[String: Any]] else {
            XCTFail("Expected messages array")
            return
        }
        XCTAssertEqual(messages.count, 2)

        let assistantMsg = messages[0]
        XCTAssertEqual(assistantMsg["role"] as? String, "assistant")
        guard let assistantContent = assistantMsg["content"] as? [[String: Any]] else {
            XCTFail("Expected assistant content array")
            return
        }
        XCTAssertEqual(assistantContent.count, 2)
        XCTAssertEqual(assistantContent[0]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[0]["text"] as? String, "Let me read")
        XCTAssertEqual(assistantContent[1]["type"] as? String, "tool_use")
        XCTAssertEqual(assistantContent[1]["id"] as? String, "toolu_1")
        XCTAssertEqual(assistantContent[1]["name"] as? String, "read")

        let toolMsg = messages[1]
        XCTAssertEqual(toolMsg["role"] as? String, "user")
        guard let toolContent = toolMsg["content"] as? [[String: Any]] else {
            XCTFail("Expected tool content array")
            return
        }
        XCTAssertEqual(toolContent.count, 1)
        XCTAssertEqual(toolContent[0]["type"] as? String, "tool_result")
        XCTAssertEqual(toolContent[0]["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(toolContent[0]["content"] as? String, "content")
    }

    func testRegisterBuiltinsUsesAnthropicEnvKey() async throws {
        let sourceId = "test-builtins-anthropic-\(UUID().uuidString)"
        defer {
            Task { await APIRegistry.shared.unregisterSource(sourceId) }
        }

        let apis = await registerBuiltins(
            sourceId: sourceId,
            environment: ["ANTHROPIC_API_KEY": "sk-ant-test"]
        )

        XCTAssertTrue(apis.contains("faux"))
        XCTAssertTrue(apis.contains("anthropic"))
    }
}

private func text(from message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined()
}

private struct CapturedAnthropicRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
}

private final class StubAnthropicHTTPClient: HTTPClient, @unchecked Sendable {
    private let response: HTTPURLResponse
    private let bytes: [UInt8]
    private let delayNanos: UInt64
    private let store = CapturedAnthropicRequestStore()

    init(statusCode: Int, payload: String, delayNanos: UInt64 = 0) {
        self.response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        self.bytes = Array(payload.utf8)
        self.delayNanos = delayNanos
    }

    func capturedRequest() async -> CapturedAnthropicRequest? {
        await store.get()
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        await store.set(CapturedAnthropicRequest(url: url, method: method, headers: headers, body: body))

        let response = self.response
        let bytes = self.bytes
        let delayNanos = self.delayNanos
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            let task = Task {
                do {
                    for byte in bytes {
                        if delayNanos > 0 {
                            try await Task.sleep(nanoseconds: delayNanos)
                        }
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (response, stream)
    }
}

private actor CapturedAnthropicRequestStore {
    private var request: CapturedAnthropicRequest?

    func set(_ value: CapturedAnthropicRequest) {
        request = value
    }

    func get() -> CapturedAnthropicRequest? {
        request
    }
}
