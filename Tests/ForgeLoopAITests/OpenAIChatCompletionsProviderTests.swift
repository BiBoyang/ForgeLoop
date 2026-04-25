import Foundation
import XCTest
@testable import ForgeLoopAI

final class OpenAIChatCompletionsProviderTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "deepseek-chat",
            name: "deepseek-chat",
            api: "openai-chat-completions",
            provider: "openai",
            baseUrl: "https://api.deepseek.com"
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

    func testChatCompletionsDeltaThenDone() async throws {
        let payload = """
data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-1","choices":[{"delta":{"content":" world"},"finish_reason":null}]}

data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

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
        XCTAssertEqual(request.url.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertEqual(request.headers["accept"], "text/event-stream")
        XCTAssertEqual(request.headers["authorization"], "Bearer sk-test")
    }

    func testChatCompletionsHTTPErrorEndsWithError() async throws {
        let payload = "{\"error\":{\"message\":\"invalid key\"}}"
        let client = StubChatHTTPClient(statusCode: 401, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let hasError = events.contains {
            if case .error(let reason, _) = $0, reason == .error { return true }
            return false
        }
        XCTAssertTrue(hasError)

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue((result.errorMessage ?? "").contains("HTTP 401"))
    }

    func testChatCompletionsNonStreamingJSONFallback() async throws {
        let payload = """
{"id":"chatcmpl-x","choices":[{"message":{"role":"assistant","content":"你好！我是 DeepSeek。"},"finish_reason":"stop"}]}
"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertEqual(text(from: result), "你好！我是 DeepSeek。")

        let hasDone = events.contains {
            if case .done = $0 { return true }
            return false
        }
        XCTAssertTrue(hasDone)
    }

    func testRegisterBuiltinsUsesDeepSeekEnvKey() async throws {
        let sourceId = "test-builtins-deepseek-\(UUID().uuidString)"
        defer {
            Task { await APIRegistry.shared.unregisterSource(sourceId) }
        }

        let apis = await registerBuiltins(
            sourceId: sourceId,
            environment: ["DEEPSEEK_API_KEY": "sk-deepseek"]
        )

        XCTAssertTrue(apis.contains("faux"))
        XCTAssertTrue(apis.contains("openai-chat-completions"))
        XCTAssertTrue(apis.contains("openai-responses"))
    }

    // MARK: - Tool Call Parsing

    func testToolCallSingle() async throws {
        let payload = """
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\"file.txt\\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .toolUse)
        XCTAssertNil(result.errorMessage)

        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.id, "call_abc")
        XCTAssertEqual(toolCalls.first?.name, "read")
        XCTAssertEqual(toolCalls.first?.arguments, "{\"path\":\"file.txt\"}")
    }

    func testToolCallArgumentsChunked() async throws {
        let payload = """
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_xyz","function":{"name":"write","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\""}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"a.txt\\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        let result = await stream.result()

        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.arguments, "{\"path\":\"a.txt\"}")
    }

    func testToolCallWithText() async throws {
        let payload = """
data: {"choices":[{"delta":{"content":"Let me read"},"finish_reason":null}]}

data: {"choices":[{"delta":{"content":" that file."},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_mix","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"x.txt\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        let result = await stream.result()

        XCTAssertEqual(result.stopReason, .toolUse)

        let texts = result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }
        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(texts, ["Let me read that file."])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.name, "read")
    }

    func testToolCallMultiple() async throws {
        let payload = """
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"write","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":1}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"b\":2}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        let result = await stream.result()

        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "call_1")
        XCTAssertEqual(toolCalls[0].name, "read")
        XCTAssertEqual(toolCalls[1].id, "call_2")
        XCTAssertEqual(toolCalls[1].name, "write")
    }

    func testToolCallCancelledDoesNotDoubleTerminate() async throws {
        let payload = """
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_c","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"y.txt\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload, delayNanos: 25_000_000)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)
        let cancellation = CancellationHandle()

        let stream = provider.stream(
            model: testModel,
            context: testContext,
            options: StreamOptions(apiKey: nil, cancellation: cancellation)
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

    func testStructuredToolMessagesInRequestBody() async throws {
        let payload = """
data: {"choices":[{"delta":{"content":"done"},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

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
                        .toolCall(ToolCall(id: "call_1", name: "read", arguments: "{\"path\":\"a.txt\"}"))
                    ],
                    stopReason: .toolUse
                )),
                .tool(ToolResultMessage(toolCallId: "call_1", output: "content", isError: false)),
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

        // Verify tools declaration
        guard let tools = object["tools"] as? [[String: Any]] else {
            XCTFail("Expected tools array in request body")
            return
        }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        guard let function = tools[0]["function"] as? [String: Any] else {
            XCTFail("Expected function object")
            return
        }
        XCTAssertEqual(function["name"] as? String, "read")
        XCTAssertEqual(function["description"] as? String, "Read a file")
        XCTAssertEqual(object["tool_choice"] as? String, "auto")

        // Verify structured messages
        guard let messages = object["messages"] as? [[String: Any]] else {
            XCTFail("Expected messages array")
            return
        }

        // First message should be system
        XCTAssertEqual(messages[0]["role"] as? String, "system")

        // Second message: assistant with tool_calls
        let assistantMsg = messages[1]
        XCTAssertEqual(assistantMsg["role"] as? String, "assistant")
        XCTAssertEqual(assistantMsg["content"] as? String, "Let me read")
        guard let toolCalls = assistantMsg["tool_calls"] as? [[String: Any]] else {
            XCTFail("Expected tool_calls in assistant message")
            return
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0]["id"] as? String, "call_1")
        XCTAssertEqual(toolCalls[0]["type"] as? String, "function")
        guard let tcFunction = toolCalls[0]["function"] as? [String: Any] else {
            XCTFail("Expected function in tool_call")
            return
        }
        XCTAssertEqual(tcFunction["name"] as? String, "read")
        XCTAssertEqual(tcFunction["arguments"] as? String, "{\"path\":\"a.txt\"}")

        // Third message: tool result
        let toolMsg = messages[2]
        XCTAssertEqual(toolMsg["role"] as? String, "tool")
        XCTAssertEqual(toolMsg["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(toolMsg["content"] as? String, "content")
    }

    func testToolCallLegacyFunctionCall() async throws {
        let payload = """
data: {"choices":[{"delta":{"function_call":{"name":"read","arguments":"{\\"path\\":\\"z.txt\\"}"}},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"function_call"}]}

data: [DONE]

"""
        let client = StubChatHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIChatCompletionsProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil as StreamOptions?)
        let result = await stream.result()

        XCTAssertEqual(result.stopReason, .toolUse)
        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.name, "read")
        XCTAssertEqual(toolCalls.first?.arguments, "{\"path\":\"z.txt\"}")
    }
}

private func text(from message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined()
}

private struct CapturedChatRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
}

private final class StubChatHTTPClient: HTTPClient, @unchecked Sendable {
    private let response: HTTPURLResponse
    private let bytes: [UInt8]
    private let delayNanos: UInt64
    private let store = CapturedChatRequestStore()

    init(statusCode: Int, payload: String, delayNanos: UInt64 = 0) {
        self.response = HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        self.bytes = Array(payload.utf8)
        self.delayNanos = delayNanos
    }

    func capturedRequest() async -> CapturedChatRequest? {
        await store.get()
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        await store.set(CapturedChatRequest(url: url, method: method, headers: headers, body: body))

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

private actor CapturedChatRequestStore {
    private var request: CapturedChatRequest?

    func set(_ value: CapturedChatRequest) {
        request = value
    }

    func get() -> CapturedChatRequest? {
        request
    }
}
