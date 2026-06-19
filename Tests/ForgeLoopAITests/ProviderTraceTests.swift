import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopTestSupport
import ForgeLoopDiagnostics

final class ProviderTraceTests: XCTestCase {
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
            messages: [.user(UserMessage(text: "hello"))]
        )
    }

    private func makeDiagnostics() -> (Diagnostics, LogCapture) {
        let capture = LogCapture()
        let sink = ConsoleLogSink { line in
            capture.append(line)
        }
        let diagnostics = Diagnostics(trace: LoggingTraceSystem(log: sink), log: sink)
        return (diagnostics, capture)
    }

    private struct SpanStartEntry {
        let spanID: String
        let parentSpanID: String
    }

    private func spanStartEntries(from capture: LogCapture) -> [SpanStartEntry] {
        capture.captured.compactMap { line in
            guard line.contains("span.start:") else { return nil }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attrs = json["attributes"] as? [String: Any],
                  let spanID = attrs["span_id"] as? String,
                  let parentSpanID = attrs["parent_span_id"] as? String else {
                return nil
            }
            return SpanStartEntry(spanID: spanID, parentSpanID: parentSpanID)
        }
    }

    func testProviderStreamEmitsSpanStartAndEnd() async throws {
        let payload = """
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Hello"}

event: response.completed
data: {"type":"response.completed"}

"""
        let (diagnostics, capture) = makeDiagnostics()

        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = OpenAIResponsesProvider(defaultAPIKey: "sk-test", httpClient: client)

        let stream = await provider.stream(
            model: testModel,
            context: testContext,
            options: StreamOptions(diagnostics: diagnostics)
        )

        for await _ in stream {}

        let hasStart = capture.captured.contains { $0.contains("span.start:") }
        let hasEnd = capture.captured.contains { $0.contains("span.end:") }

        XCTAssertTrue(hasStart, "Expected captured log to contain span.start")
        XCTAssertTrue(hasEnd, "Expected captured log to contain span.end")

        let entries = spanStartEntries(from: capture)
        let providerEntry = entries.first

        XCTAssertNotNil(providerEntry)
        XCTAssertEqual(providerEntry?.parentSpanID, "", "Provider span should be a root span")

        // Note: HTTPClient span is created inside URLSessionHTTPClient; this test uses
        // StubHTTPClient, so the HTTP span is not exercised here. See HTTPClientTraceTests
        // or end-to-end tests for HTTP span parent/child coverage.
    }

    func testAnthropicStreamEmitsSpanStartAndEnd() async throws {
        let payload = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet","usage":{}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

event: message_stop
data: {"type":"message_stop"}

"""
        let (diagnostics, capture) = makeDiagnostics()

        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = AnthropicProvider(defaultAPIKey: "sk-test", httpClient: client)
        let model = Model(
            id: "claude-sonnet",
            name: "Claude Sonnet",
            api: "anthropic",
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com"
        )

        let stream = await provider.stream(
            model: model,
            context: testContext,
            options: StreamOptions(diagnostics: diagnostics)
        )

        for await _ in stream {}

        let hasStart = capture.captured.contains { $0.contains("span.start:") }
        let hasEnd = capture.captured.contains { $0.contains("span.end:") }

        XCTAssertTrue(hasStart, "Expected captured log to contain span.start")
        XCTAssertTrue(hasEnd, "Expected captured log to contain span.end")
    }

    func testGeminiStreamEmitsSpanStartAndEnd() async throws {
        let payload = """
data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"]}},"finishReason":""}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello world"]}},"finishReason":""}]}

data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello world!"]}},"finishReason":"STOP"}]}

"""
        let (diagnostics, capture) = makeDiagnostics()

        let client = StubHTTPClient(statusCode: 200, payload: payload)
        let provider = GeminiProvider(defaultAPIKey: "gemini-test", httpClient: client)
        let model = Model(
            id: "gemini-pro",
            name: "Gemini Pro",
            api: "gemini",
            provider: "google",
            baseUrl: "https://generativelanguage.googleapis.com"
        )

        let stream = await provider.stream(
            model: model,
            context: testContext,
            options: StreamOptions(diagnostics: diagnostics)
        )

        for await _ in stream {}

        let hasStart = capture.captured.contains { $0.contains("span.start:") }
        let hasEnd = capture.captured.contains { $0.contains("span.end:") }

        XCTAssertTrue(hasStart, "Expected captured log to contain span.start")
        XCTAssertTrue(hasEnd, "Expected captured log to contain span.end")
    }

    func testProviderNotFoundEndsSpanWithError() async throws {
        let (diagnostics, capture) = makeDiagnostics()

        let model = Model(
            id: "unknown",
            name: "Unknown",
            api: "unknown",
            provider: "unknown"
        )

        do {
            _ = try await ForgeLoopAI.stream(
                model: model,
                context: testContext,
                options: StreamOptions(diagnostics: diagnostics)
            )
            XCTFail("Expected provider not found error")
        } catch {
            // expected
        }

        let endLine = capture.captured.first { $0.contains("span.end:") }
        XCTAssertNotNil(endLine, "Expected span.end to be emitted")
        XCTAssertTrue(
            endLine?.contains("\"error_type\":\"ProviderNotFound\"") == true,
            "Expected span.end to carry ProviderNotFound error"
        )
    }
}
