import Foundation
import XCTest
@testable import ForgeLoopAI

final class OpenAIResponsesProviderTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "gpt-4.1-mini",
            name: "GPT-4.1 mini",
            api: "openai-responses",
            provider: "openai",
            baseUrl: "https://api.openai.com"
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

    func testResponsesTextDeltaThenDone() async throws {
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
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertEqual(request.headers["accept"], "text/event-stream")
        XCTAssertEqual(request.headers["authorization"], "Bearer sk-test")

        guard let body = request.body else {
            XCTFail("Expected request body")
            return
        }
        guard
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let input = object["input"] as? [[String: Any]]
        else {
            XCTFail("Expected JSON body object")
            return
        }
        XCTAssertEqual(object["model"] as? String, "gpt-4.1-mini")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(input.count, 3)
    }

    func testResponsesErrorEventEndsWithError() async throws {
        let payload = """
event: response.error
data: {"type":"response.error","error":{"message":"upstream failed"}}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let hasError = events.contains {
            if case .error(let reason, _) = $0, reason == .error { return true }
            return false
        }
        let hasDone = events.contains {
            if case .done = $0 { return true }
            return false
        }
        XCTAssertTrue(hasError)
        XCTAssertFalse(hasDone)

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertEqual(result.errorMessage, "upstream failed")
    }

    func testResponsesCancellationEndsAborted() async throws {
        let payload = """
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"a"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"b"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"c"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"d"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"e"}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload, delayNanos: 25_000_000)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)
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
        XCTAssertEqual(result.errorMessage, "Request was aborted")
    }

    func testRegisterBuiltinsRegistersOpenAIWhenApiKeyPresent() async throws {
        let sourceId = "test-builtins-openai-\(UUID().uuidString)"
        defer {
            Task { await APIRegistry.shared.unregisterSource(sourceId) }
        }

        let apis = await registerBuiltins(
            sourceId: sourceId,
            environment: ["OPENAI_API_KEY": "sk-present"]
        )

        XCTAssertTrue(apis.contains("faux"))
        XCTAssertTrue(apis.contains("openai-responses"))
        XCTAssertTrue(apis.contains("openai-chat-completions"))
        let provider = await APIRegistry.shared.provider(for: "openai-responses")
        XCTAssertNotNil(provider)
        let completionsProvider = await APIRegistry.shared.provider(for: "openai-chat-completions")
        XCTAssertNotNil(completionsProvider)
    }

    // MARK: - Tool Call Parsing

    func testResponsesToolCallSingle() async throws {
        let payload = """
event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","id":"call_r1","call_id":"call_r1","name":"read","arguments":""}}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"call_r1","delta":"{\\"path\\":\\"a.txt\\"}"}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","id":"call_r1","call_id":"call_r1","name":"read","arguments":"{\"path\":\"a.txt\"}"}}

event: response.completed
data: {"type":"response.completed"}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        let result = await stream.result()

        XCTAssertEqual(result.stopReason, .toolUse)
        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.id, "call_r1")
        XCTAssertEqual(toolCalls.first?.name, "read")
        XCTAssertEqual(toolCalls.first?.arguments, "{\"path\":\"a.txt\"}")
    }

    func testResponsesToolCallWithText() async throws {
        let payload = """
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Sure, "}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"reading now."}

event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","id":"call_r2","call_id":"call_r2","name":"read","arguments":""}}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"call_r2","delta":"{\"path\":\"b.txt\"}"}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","id":"call_r2","call_id":"call_r2","name":"read","arguments":"{\"path\":\"b.txt\"}"}}

event: response.completed
data: {"type":"response.completed"}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)

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
        XCTAssertEqual(texts, ["Sure, reading now."])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.id, "call_r2")
    }

    func testResponsesToolCallMultiple() async throws {
        let payload = """
event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","id":"call_m1","call_id":"call_m1","name":"read","arguments":""}}

event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","id":"call_m2","call_id":"call_m2","name":"write","arguments":""}}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"call_m1","delta":"{\"a\":1}"}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"call_m2","delta":"{\"b\":2}"}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","id":"call_m1","call_id":"call_m1","name":"read","arguments":"{\"a\":1}"}}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","id":"call_m2","call_id":"call_m2","name":"write","arguments":"{\"b\":2}"}}

event: response.completed
data: {"type":"response.completed"}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        let result = await stream.result()

        XCTAssertEqual(result.stopReason, .toolUse)
        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "call_m1")
        XCTAssertEqual(toolCalls[0].name, "read")
        XCTAssertEqual(toolCalls[1].id, "call_m2")
        XCTAssertEqual(toolCalls[1].name, "write")
    }

    func testResponsesToolCallOrderBySourceNotByCallId() async throws {
        // call_id 字典序与出现顺序相反，验证按源出现顺序输出
        let payload = """
event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","id":"zzz","call_id":"zzz","name":"write","arguments":""}}

event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","id":"aaa","call_id":"aaa","name":"read","arguments":""}}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"zzz","delta":"{\"b\":2}"}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"aaa","delta":"{\"a\":1}"}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","id":"zzz","call_id":"zzz","name":"write","arguments":"{\"b\":2}"}}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","id":"aaa","call_id":"aaa","name":"read","arguments":"{\"a\":1}"}}

event: response.completed
data: {"type":"response.completed"}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        let result = await stream.result()

        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        // 按源出现顺序：zzz 先出现，aaa 后出现
        XCTAssertEqual(toolCalls[0].id, "zzz")
        XCTAssertEqual(toolCalls[0].name, "write")
        XCTAssertEqual(toolCalls[1].id, "aaa")
        XCTAssertEqual(toolCalls[1].name, "read")
    }

    func testResponsesToolCallNoDoubleTerminateOnError() async throws {
        let payload = """
event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","id":"call_e1","call_id":"call_e1","name":"read","arguments":""}}

event: response.error
data: {"type":"response.error","error":{"message":"tool call failed"}}

"""
        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = provider.stream(model: testModel, context: testContext, options: nil)
        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let hasError = events.contains {
            if case .error(let reason, _) = $0, reason == .error { return true }
            return false
        }
        let hasDone = events.contains {
            if case .done = $0 { return true }
            return false
        }
        XCTAssertTrue(hasError)
        XCTAssertFalse(hasDone)

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertEqual(result.errorMessage, "tool call failed")
    }
}

private func text(from message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined()
}

private struct CapturedRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
}

private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let response: HTTPURLResponse
    private let bytes: [UInt8]
    private let delayNanos: UInt64
    private let store = CapturedRequestStore()

    init(statusCode: Int, payload: String, delayNanos: UInt64 = 0) {
        self.response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/responses")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        self.bytes = Array(payload.utf8)
        self.delayNanos = delayNanos
    }

    func capturedRequest() async -> CapturedRequest? {
        await store.get()
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        await store.set(CapturedRequest(url: url, method: method, headers: headers, body: body))

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

private actor CapturedRequestStore {
    private var request: CapturedRequest?

    func set(_ value: CapturedRequest) {
        request = value
    }

    func get() -> CapturedRequest? {
        request
    }
}
