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
