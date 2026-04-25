import Foundation
import XCTest
@testable import ForgeLoopAI

final class FauxProviderToolCallTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux",
            api: "faux",
            provider: "faux",
            baseUrl: ""
        )
    }

    private var testContext: Context {
        Context(
            systemPrompt: "You are helpful.",
            messages: [.user(UserMessage(text: "read file"))]
        )
    }

    func testToolCallModeProducesToolUse() async throws {
        let provider = FauxProvider(mode: .toolCall(name: "read", arguments: "{\"path\":\"a.txt\"}"))
        let stream = provider.stream(model: testModel, context: testContext, options: nil as StreamOptions?)

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .toolUse)
        XCTAssertNil(result.errorMessage)

        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.name, "read")
        XCTAssertEqual(toolCalls.first?.arguments, "{\"path\":\"a.txt\"}")
        XCTAssertEqual(toolCalls.first?.id, "call_faux_001")
    }

    func testTextThenToolCallModeProducesMixedContent() async throws {
        let provider = FauxProvider(
            tokenDelayNanos: 0,
            mode: .textThenToolCall(text: "OK", toolName: "write", toolArguments: "{\"path\":\"b.txt\"}")
        )
        let stream = provider.stream(model: testModel, context: testContext, options: nil as StreamOptions?)

        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let textDeltas = events.compactMap { event -> String? in
            if case .textDelta(_, let delta, _) = event { return delta }
            return nil
        }
        XCTAssertEqual(textDeltas.joined(), "OK")

        let hasDone = events.contains {
            if case .done = $0 { return true }
            return false
        }
        XCTAssertTrue(hasDone)

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
        XCTAssertEqual(texts, ["OK"])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.id, "call_faux_002")
    }

    func testMultipleToolCallsMode() async throws {
        let provider = FauxProvider(mode: .multipleToolCalls([
            (name: "read", arguments: "{\"a\":1}"),
            (name: "write", arguments: "{\"b\":2}"),
        ]))
        let stream = provider.stream(model: testModel, context: testContext, options: nil as StreamOptions?)

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .toolUse)

        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall(let tc) = block { return tc }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "call_faux_1")
        XCTAssertEqual(toolCalls[0].name, "read")
        XCTAssertEqual(toolCalls[1].id, "call_faux_2")
        XCTAssertEqual(toolCalls[1].name, "write")
    }

    func testToolCallCancellationDoesNotDoubleTerminate() async throws {
        let provider = FauxProvider(mode: .toolCall(name: "read", arguments: "{}"))
        let cancellation = CancellationHandle()

        let stream = provider.stream(
            model: testModel,
            context: testContext,
            options: StreamOptions(cancellation: cancellation)
        )

        cancellation.cancel(reason: "test abort")
        try? await Task.sleep(nanoseconds: 50_000_000)

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

    func testDefaultTextModeUnchanged() async throws {
        let provider = FauxProvider()
        let stream = provider.stream(model: testModel, context: testContext, options: nil as StreamOptions?)

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertNil(result.errorMessage)

        let toolCalls = result.content.compactMap { block -> ToolCall? in
            if case .toolCall = block { return nil }
            return nil
        }
        XCTAssertTrue(toolCalls.isEmpty)

        let text = result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined()
        XCTAssertEqual(text, "FauxProvider 收到：read file")
    }
}
