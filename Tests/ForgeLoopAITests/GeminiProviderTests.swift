import Foundation
import XCTest
@testable import ForgeLoopAI

final class GeminiProviderTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "gemini-2.0-flash",
            name: "Gemini 2.0 Flash",
            api: "gemini",
            provider: "google"
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
data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]}}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello world"}]}}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello world!"}]},"finishReason":"STOP"}]}

"""
        let client = StubGeminiHTTPClient(statusCode: 200, payload: payload)
        let provider = GeminiProvider(defaultAPIKey: "gemini-test", httpClient: client)

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
        XCTAssertEqual(deltaText, "Hello world!")

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(text(from: result), "Hello world!")

        guard let request = await client.capturedRequest() else {
            XCTFail("Expected captured request")
            return
        }
        XCTAssertEqual(request.url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["x-goog-api-key"], "gemini-test")
        XCTAssertEqual(request.headers["content-type"], "application/json")
    }

    func testToolUseDetected() async throws {
        let payload = """
data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Let me read"}]}}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"read","args":{"path":"file.txt"}}}]},"finishReason":"TOOL_CALLS"}]}

"""
        let client = StubGeminiHTTPClient(statusCode: 200, payload: payload)
        let provider = GeminiProvider(defaultAPIKey: "gemini-test", httpClient: client)

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
        XCTAssertEqual(toolCalls.first?.name, "read")
        XCTAssertEqual(toolCalls.first?.arguments, "{\"path\":\"file.txt\"}")
    }

    func testCancelDoesNotDoubleTerminate() async throws {
        let payload = """
data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]}}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello world"}]},"finishReason":"STOP"}]}

"""
        let client = StubGeminiHTTPClient(statusCode: 200, payload: payload, delayNanos: 25_000_000)
        let provider = GeminiProvider(defaultAPIKey: "gemini-test", httpClient: client)
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
data: {"candidates":[{"content":{"role":"model","parts":[{"text":"done"}]},"finishReason":"STOP"}]}

"""
        let client = StubGeminiHTTPClient(statusCode: 200, payload: payload)
        let provider = GeminiProvider(defaultAPIKey: "gemini-test", httpClient: client)

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
                        .toolCall(ToolCall(id: "call-1", name: "read", arguments: "{\"path\":\"a.txt\"}"))
                    ],
                    stopReason: .toolUse
                )),
                .tool(ToolResultMessage(toolCallId: "read", output: "content", isError: false)),
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

        XCTAssertNotNil(object["systemInstruction"] as? [String: Any])
        XCTAssertNotNil(object["generationConfig"] as? [String: Any])

        guard let tools = object["tools"] as? [[String: Any]] else {
            XCTFail("Expected tools array")
            return
        }
        XCTAssertEqual(tools.count, 1)
        guard let declarations = tools[0]["functionDeclarations"] as? [[String: Any]] else {
            XCTFail("Expected functionDeclarations")
            return
        }
        XCTAssertEqual(declarations.count, 1)
        XCTAssertEqual(declarations[0]["name"] as? String, "read")
        XCTAssertEqual(declarations[0]["description"] as? String, "Read a file")
        XCTAssertNotNil(declarations[0]["parameters"])

        guard let contents = object["contents"] as? [[String: Any]] else {
            XCTFail("Expected contents array")
            return
        }
        XCTAssertEqual(contents.count, 2)

        let assistantContent = contents[0]
        XCTAssertEqual(assistantContent["role"] as? String, "model")
        guard let assistantParts = assistantContent["parts"] as? [[String: Any]] else {
            XCTFail("Expected assistant parts")
            return
        }
        XCTAssertEqual(assistantParts.count, 2)
        XCTAssertEqual(assistantParts[0]["text"] as? String, "Let me read")
        XCTAssertEqual(assistantParts[1]["functionCall"] as? [String: Any]? != nil, true)

        let toolContent = contents[1]
        XCTAssertEqual(toolContent["role"] as? String, "user")
        guard let toolParts = toolContent["parts"] as? [[String: Any]] else {
            XCTFail("Expected tool parts")
            return
        }
        XCTAssertEqual(toolParts.count, 1)
        XCTAssertEqual(toolParts[0]["functionResponse"] as? [String: Any]? != nil, true)
    }

    func testRegisterBuiltinsUsesGeminiEnvKey() async throws {
        let sourceId = "test-builtins-gemini-\(UUID().uuidString)"
        defer {
            Task { await APIRegistry.shared.unregisterSource(sourceId) }
        }

        let apis = await registerBuiltins(
            sourceId: sourceId,
            environment: ["GEMINI_API_KEY": "gemini-env-test"]
        )

        XCTAssertTrue(apis.contains("faux"))
        XCTAssertTrue(apis.contains("gemini"))
    }
}

private func text(from message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined()
}

private struct CapturedGeminiRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
}

private final class StubGeminiHTTPClient: HTTPClient, @unchecked Sendable {
    private let response: HTTPURLResponse
    private let bytes: [UInt8]
    private let delayNanos: UInt64
    private let store = CapturedGeminiRequestStore()

    init(statusCode: Int, payload: String, delayNanos: UInt64 = 0) {
        self.response = HTTPURLResponse(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        self.bytes = Array(payload.utf8)
        self.delayNanos = delayNanos
    }

    func capturedRequest() async -> CapturedGeminiRequest? {
        await store.get()
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
        await store.set(CapturedGeminiRequest(url: url, method: method, headers: headers, body: body))

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

private actor CapturedGeminiRequestStore {
    private var request: CapturedGeminiRequest?

    func set(_ value: CapturedGeminiRequest) {
        request = value
    }

    func get() -> CapturedGeminiRequest? {
        request
    }
}
