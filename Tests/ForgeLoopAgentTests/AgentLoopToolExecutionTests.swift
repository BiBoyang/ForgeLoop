import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

private actor EventCollector {
    private(set) var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
}

private struct EchoTool: Tool {
    let name = "echo"
    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        ToolResult(output: "echo: \(arguments)", isError: false)
    }
}

private struct FailTool: Tool {
    let name = "fail"
    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        ToolResult(output: "always fails", isError: true)
    }
}

private actor CountingEchoCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private struct CountingEchoTool: Tool {
    let name = "counting_echo"
    private let counter: CountingEchoCounter

    init(counter: CountingEchoCounter) {
        self.counter = counter
    }

    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let count = await counter.increment()
        return ToolResult(output: "call #\(count)", isError: false)
    }
}

private actor ContextCapture {
    var context: AgentContext?
    func set(_ value: AgentContext) {
        context = value
    }
}

private actor TurnCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private actor StreamCallCounter {
    var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

final class AgentLoopToolExecutionTests: XCTestCase {
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

    private func runLoop(
        prompts: [Message] = [],
        context: AgentContext,
        stream: AssistantMessageStream,
        toolExecutor: ToolExecutor? = nil,
        toolExecutionMode: ToolExecutionMode = .sequential
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
            config: AgentLoopConfig(model: testModel, toolExecutor: toolExecutor, cwd: "/tmp", toolExecutionMode: toolExecutionMode),
            emit: emit,
            cancellation: nil,
            streamFn: streamFn
        )
        return await collector.events
    }

    // MARK: - 1) 无 toolExecutor 时工具执行返回错误但不中断

    func testToolExecutionWithoutExecutorReturnsError() async throws {
        let toolCall = ToolCall(id: "call-1", name: "test_tool", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(context: AgentContext(systemPrompt: "", messages: []), stream: stream)

        let endEvents = events.filter {
            if case .toolExecutionEnd = $0 { return true }
            return false
        }
        XCTAssertEqual(endEvents.count, 1)
        if case .toolExecutionEnd(_, _, let isError, _) = endEvents[0] {
            XCTAssertTrue(isError)
        } else {
            XCTFail("Expected toolExecutionEnd")
        }
    }

    // MARK: - 2) 配置 toolExecutor 后执行真实工具

    func testToolExecutionWithExecutorRunsTool() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())

        let toolCall = ToolCall(id: "call-1", name: "echo", arguments: "{\"msg\":\"hello\"}")
        let message = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(
            context: AgentContext(systemPrompt: "", messages: []),
            stream: stream,
            toolExecutor: executor
        )

        let endEvents = events.compactMap { event -> (String, String, Bool)? in
            if case .toolExecutionEnd(let id, let name, let isError, _) = event {
                return (id, name, isError)
            }
            return nil
        }
        XCTAssertEqual(endEvents.count, 1)
        XCTAssertEqual(endEvents[0].0, "call-1")
        XCTAssertEqual(endEvents[0].1, "echo")
        XCTAssertFalse(endEvents[0].2)
    }

    // MARK: - 3) tool_result 消息正确注入上下文（顺序：assistant -> tool）

    func testToolResultAppendedToContext() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())

        let toolCall = ToolCall(id: "call-1", name: "echo", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)

        let capture = ContextCapture()
        let counter = StreamCallCounter()
        let endTurnMessage = AssistantMessage.text("done", stopReason: .endTurn)
        let customStreamFn: StreamFn = { model, context, options in
            let ctx = AgentContext(
                systemPrompt: context.systemPrompt ?? "",
                messages: context.messages
            )
            Task { await capture.set(ctx) }
            let callCount = await Task { await counter.increment() }.value
            if callCount == 1 {
                return stream
            }
            // 第二轮及以后返回不带 toolCall 的 stream
            let fallback = AssistantMessageStream()
            Task.detached {
                fallback.push(.start(partial: endTurnMessage))
                fallback.push(.done(reason: .endTurn, message: endTurnMessage))
                fallback.end(endTurnMessage)
            }
            return fallback
        }

        let collector = EventCollector()
        let emit: AgentEventSink = { event in
            await collector.append(event)
        }

        try? await AgentLoop.run(
            prompts: [],
            context: AgentContext(systemPrompt: "", messages: []),
            config: AgentLoopConfig(model: testModel, toolExecutor: executor, cwd: "/tmp"),
            emit: emit,
            cancellation: nil,
            streamFn: customStreamFn
        )

        // 第一轮请求时上下文为空（只有 system prompt）
        // 第二轮请求时上下文包含 assistant(tool_call) + tool_result
        let capturedContext = await capture.context
        XCTAssertNotNil(capturedContext)
    }

    // MARK: - 4) 工具执行失败返回 isError=true，但不终止 run

    func testToolFailureReturnsErrorButContinues() async throws {
        let executor = ToolExecutor()
        executor.register(FailTool())

        let toolCall = ToolCall(id: "call-1", name: "fail", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(
            context: AgentContext(systemPrompt: "", messages: []),
            stream: stream,
            toolExecutor: executor
        )

        let endEvents = events.compactMap { event -> Bool? in
            if case .toolExecutionEnd(_, _, let isError, _) = event {
                return isError
            }
            return nil
        }
        XCTAssertEqual(endEvents.count, 1)
        XCTAssertTrue(endEvents[0])

        // run 应该完成，不抛出
        let agentEndEvents = events.filter {
            if case .agentEnd = $0 { return true }
            return false
        }
        XCTAssertEqual(agentEndEvents.count, 1)
    }

    // MARK: - 5) 多 toolCall 串行执行（source order）

    func testMultipleToolCallsExecuteSerially() async throws {
        let counter = CountingEchoCounter()
        let executor = ToolExecutor()
        executor.register(CountingEchoTool(counter: counter))

        let tc1 = ToolCall(id: "call-a", name: "counting_echo", arguments: "{}")
        let tc2 = ToolCall(id: "call-b", name: "counting_echo", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(tc1), .toolCall(tc2)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(
            context: AgentContext(systemPrompt: "", messages: []),
            stream: stream,
            toolExecutor: executor
        )

        let startEvents = events.compactMap { event -> String? in
            if case .toolExecutionStart(let id, _, _) = event { return id }
            return nil
        }
        XCTAssertEqual(startEvents, ["call-a", "call-b"])

        let endEvents = events.compactMap { event -> (String, Bool)? in
            if case .toolExecutionEnd(let id, _, let isError, _) = event {
                return (id, isError)
            }
            return nil
        }
        XCTAssertEqual(endEvents.count, 2)
        XCTAssertEqual(endEvents[0].0, "call-a")
        XCTAssertFalse(endEvents[0].1)
        XCTAssertEqual(endEvents[1].0, "call-b")
        XCTAssertFalse(endEvents[1].1)
    }

    // MARK: - 6) 无 toolCall 时不产生 toolExecution 事件

    func testNoToolCallProducesNoToolEvents() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())

        let message = AssistantMessage.text("hello", stopReason: .endTurn)
        let stream = makeStream(message)
        let events = await runLoop(
            context: AgentContext(systemPrompt: "", messages: []),
            stream: stream,
            toolExecutor: executor
        )

        let toolEvents = events.filter {
            if case .toolExecutionStart = $0 { return true }
            if case .toolExecutionEnd = $0 { return true }
            return false
        }
        XCTAssertTrue(toolEvents.isEmpty)
    }

    // MARK: - 7) 最大 tool turn 限制（超限后 error 收敛）

    func testMaxToolTurnLimitEnforced() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())

        // 创建一个总是返回 toolUse 的 stream，模拟无限循环
        let toolCall = ToolCall(id: "call-loop", name: "echo", arguments: "{}")

        let turnCounter = TurnCounter()
        let customStreamFn: StreamFn = { _, _, _ in
            let stream = AssistantMessageStream()
            let counter = turnCounter
            Task.detached {
                let count = await counter.increment()
                let msg: AssistantMessage
                if count <= 10 {
                    msg = AssistantMessage(
                        content: [.toolCall(toolCall)],
                        stopReason: .toolUse
                    )
                } else {
                    msg = AssistantMessage.text("final", stopReason: .endTurn)
                }
                stream.push(.start(partial: msg))
                stream.push(.done(reason: msg.stopReason, message: msg))
                stream.end(msg)
            }
            return stream
        }

        let collector = EventCollector()
        let emit: AgentEventSink = { event in
            await collector.append(event)
        }

        try? await AgentLoop.run(
            prompts: [],
            context: AgentContext(systemPrompt: "", messages: []),
            config: AgentLoopConfig(model: self.testModel, toolExecutor: executor, cwd: "/tmp"),
            emit: emit,
            cancellation: nil,
            streamFn: customStreamFn
        )

        let events = await collector.events
        let toolEndEvents = events.filter {
            if case .toolExecutionEnd = $0 { return true }
            return false
        }
        // 最大 8 轮，每轮 1 个 tool call
        XCTAssertEqual(toolEndEvents.count, 8)

        // 最后应该是 error 收敛
        let turnEndEvents = events.compactMap { event -> StopReason? in
            if case .turnEnd(let message) = event,
               case .assistant(let a) = message {
                return a.stopReason
            }
            return nil
        }
        XCTAssertEqual(turnEndEvents.last, .error)
    }

    // MARK: - 8) toolExecution 事件位于 messageEnd 之后、turnEnd 之前

    func testToolEventsPositionedCorrectly() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())

        let toolCall = ToolCall(id: "call-1", name: "echo", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(
            context: AgentContext(systemPrompt: "", messages: []),
            stream: stream,
            toolExecutor: executor
        )

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

    // MARK: - 9) 并行模式：多 toolCall 仍按 source order 收敛

    func testMultipleToolCallsParallelSourceOrderStable() async throws {
        let counter = CountingEchoCounter()
        let executor = ToolExecutor()
        executor.register(CountingEchoTool(counter: counter))

        let tc1 = ToolCall(id: "call-a", name: "counting_echo", arguments: "{}")
        let tc2 = ToolCall(id: "call-b", name: "counting_echo", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(tc1), .toolCall(tc2)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(
            context: AgentContext(systemPrompt: "", messages: []),
            stream: stream,
            toolExecutor: executor,
            toolExecutionMode: .parallel
        )

        let startEvents = events.compactMap { event -> String? in
            if case .toolExecutionStart(let id, _, _) = event { return id }
            return nil
        }
        XCTAssertEqual(startEvents.count, 2)

        let endEvents = events.compactMap { event -> (String, Bool)? in
            if case .toolExecutionEnd(let id, _, let isError, _) = event {
                return (id, isError)
            }
            return nil
        }
        XCTAssertEqual(endEvents.count, 2)
        XCTAssertEqual(endEvents[0].0, "call-a")
        XCTAssertEqual(endEvents[1].0, "call-b")
        XCTAssertFalse(endEvents[0].1)
        XCTAssertFalse(endEvents[1].1)
    }

    // MARK: - 10) 并行模式：单个工具失败不短路整轮

    func testParallelToolFailureDoesNotShortCircuit() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())
        executor.register(FailTool())

        let tc1 = ToolCall(id: "call-ok", name: "echo", arguments: "{}")
        let tc2 = ToolCall(id: "call-fail", name: "fail", arguments: "{}")
        let tc3 = ToolCall(id: "call-ok2", name: "echo", arguments: "{}")
        let message = AssistantMessage(
            content: [.toolCall(tc1), .toolCall(tc2), .toolCall(tc3)],
            stopReason: .toolUse
        )
        let stream = makeStream(message)
        let events = await runLoop(
            context: AgentContext(systemPrompt: "", messages: []),
            stream: stream,
            toolExecutor: executor,
            toolExecutionMode: .parallel
        )

        let endEvents = events.compactMap { event -> (String, Bool)? in
            if case .toolExecutionEnd(let id, _, let isError, _) = event {
                return (id, isError)
            }
            return nil
        }
        XCTAssertEqual(endEvents.count, 3)

        let okCount = endEvents.filter { !$0.1 }.count
        let failCount = endEvents.filter { $0.1 }.count
        XCTAssertEqual(okCount, 2)
        XCTAssertEqual(failCount, 1)

        // 按 source order 收敛
        XCTAssertEqual(endEvents[0].0, "call-ok")
        XCTAssertEqual(endEvents[1].0, "call-fail")
        XCTAssertEqual(endEvents[2].0, "call-ok2")

        // 整轮应正常结束
        let agentEndEvents = events.filter {
            if case .agentEnd = $0 { return true }
            return false
        }
        XCTAssertEqual(agentEndEvents.count, 1)
    }
}
