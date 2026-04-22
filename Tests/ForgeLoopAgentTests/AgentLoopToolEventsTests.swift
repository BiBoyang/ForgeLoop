import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

private actor EventCollector {
    private(set) var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
}

final class AgentLoopToolEventsTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    private func makeStream(_ message: AssistantMessage) -> AssistantMessageStream {
        let stream = AssistantMessageStream()
        Task.detached {
            stream.push(.start(partial: message))
            stream.push(.done(reason: message.stopReason, message: message))
            stream.end(message)
        }
        return stream
    }

    private actor StreamCallCounter {
        var count = 0
        func increment() -> Int {
            count += 1
            return count
        }
    }

    private func runLoop(
        prompts: [Message] = [],
        context: AgentContext,
        stream: AssistantMessageStream
    ) async -> [AgentEvent] {
        let collector = EventCollector()
        let emit: AgentEventSink = { event in
            await collector.append(event)
        }
        let counter = StreamCallCounter()
        let endTurnMessage = AssistantMessage.text("done", stopReason: .endTurn)
        let streamFn: StreamFn = { _, _, _ in
            let callCount = await Task { await counter.increment() }.value
            if callCount == 1 {
                return stream
            }
            // 第二轮及以后返回不带 toolCall 的 stream，避免无限循环
            let fallback = AssistantMessageStream()
            Task.detached {
                fallback.push(.start(partial: endTurnMessage))
                fallback.push(.done(reason: .endTurn, message: endTurnMessage))
                fallback.end(endTurnMessage)
            }
            return fallback
        }
        try? await AgentLoop.run(
            prompts: prompts,
            context: context,
            config: AgentLoopConfig(model: testModel),
            emit: emit,
            cancellation: nil,
            streamFn: streamFn
        )
        return await collector.events
    }

    // MARK: - 1) 单个 toolCall：断言 start/end 各 1 次，且顺序正确

    func testSingleToolCallEmitsStartThenEnd() async throws {
        let toolCall = ToolCall(id: "call-1", name: "test_tool", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(context: AgentContext(systemPrompt: "", messages: []), stream: stream)

        let toolEvents = events.filter {
            if case .toolExecutionStart = $0 { return true }
            if case .toolExecutionEnd = $0 { return true }
            return false
        }
        XCTAssertEqual(toolEvents.count, 2)

        if case .toolExecutionStart(let id, let name, let args) = toolEvents[0] {
            XCTAssertEqual(id, "call-1")
            XCTAssertEqual(name, "test_tool")
            XCTAssertEqual(args, "{}")
        } else {
            XCTFail("Expected toolExecutionStart first")
        }

        if case .toolExecutionEnd(let id, let name, let isError, _) = toolEvents[1] {
            XCTAssertEqual(id, "call-1")
            XCTAssertEqual(name, "test_tool")
            XCTAssertTrue(isError)
        } else {
            XCTFail("Expected toolExecutionEnd second")
        }
    }

    // MARK: - 2) 多个 toolCall：断言事件数量与顺序按 source order

    func testMultipleToolCallsInOrder() async throws {
        let tc1 = ToolCall(id: "call-a", name: "tool_a", arguments: "{\"x\":1}")
        let tc2 = ToolCall(id: "call-b", name: "tool_b", arguments: "{\"y\":2}")
        let message = AssistantMessage(
            content: [.toolCall(tc1), .toolCall(tc2)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(context: AgentContext(systemPrompt: "", messages: []), stream: stream)

        let toolEvents = events.filter {
            if case .toolExecutionStart = $0 { return true }
            if case .toolExecutionEnd = $0 { return true }
            return false
        }
        XCTAssertEqual(toolEvents.count, 4)

        if case .toolExecutionStart(let id, _, _) = toolEvents[0] { XCTAssertEqual(id, "call-a") } else { XCTFail() }
        if case .toolExecutionEnd(let id, _, _, _) = toolEvents[1] { XCTAssertEqual(id, "call-a") } else { XCTFail() }
        if case .toolExecutionStart(let id, _, _) = toolEvents[2] { XCTAssertEqual(id, "call-b") } else { XCTFail() }
        if case .toolExecutionEnd(let id, _, _, _) = toolEvents[3] { XCTAssertEqual(id, "call-b") } else { XCTFail() }
    }

    // MARK: - 3) 无 toolCall：断言无 toolExecution 事件

    func testNoToolCallEmitsNoToolEvents() async throws {
        let message = AssistantMessage.text("hello", stopReason: .endTurn)
        let stream = makeStream(message)
        let events = await runLoop(context: AgentContext(systemPrompt: "", messages: []), stream: stream)

        let toolEvents = events.filter {
            if case .toolExecutionStart = $0 { return true }
            if case .toolExecutionEnd = $0 { return true }
            return false
        }
        XCTAssertTrue(toolEvents.isEmpty)
    }

    // MARK: - 4) toolExecution 事件位于 messageEnd 之后、turnEnd 之前

    func testToolEventsPositionedBetweenMessageEndAndTurnEnd() async throws {
        let toolCall = ToolCall(id: "call-1", name: "test_tool", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(context: AgentContext(systemPrompt: "", messages: []), stream: stream)

        let typeSequence = events.map(\.type)
        let msgEndIdx = typeSequence.firstIndex(of: "message_end")
        let turnEndIdx = typeSequence.firstIndex(of: "turn_end")
        let startIdx = typeSequence.firstIndex(of: "tool_execution_start")
        let endIdx = typeSequence.firstIndex(of: "tool_execution_end")

        XCTAssertNotNil(msgEndIdx)
        XCTAssertNotNil(turnEndIdx)
        XCTAssertNotNil(startIdx)
        XCTAssertNotNil(endIdx)
        XCTAssertLessThan(msgEndIdx!, startIdx!)
        XCTAssertLessThan(startIdx!, endIdx!)
        XCTAssertLessThan(endIdx!, turnEndIdx!)
    }
}
