import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

// MARK: - STEP-016: 发布前稳定性收尾

private actor EventCollector {
    private(set) var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
    func count(of type: String) -> Int { events.filter { $0.type == type }.count }
}

@MainActor
final class AgentStabilityTests: XCTestCase {
    private var testModel: Model {
        Model(id: "faux-coding-model", name: "Faux Coding Model", api: "faux", provider: "faux")
    }

    // MARK: - 1) Abort 与 tool 执行重叠：确保无双终止

    func testAbortDuringToolExecutionNoDoubleTermination() async throws {
        let executor = ToolExecutor()
        executor.register(SlowTool(name: "slow"))

        let toolCall = ToolCall(id: "tc-1", name: "slow", arguments: "{}")
        let message = AssistantMessage(content: [.toolCall(toolCall)], stopReason: .toolUse)
        let stream = makeStream(message)

        let collector = EventCollector()
        let emit: AgentEventSink = { event in await collector.append(event) }

        let cancellation = CancellationHandle()

        let runTask = Task {
            try? await AgentLoop.run(
                prompts: [],
                context: AgentContext(systemPrompt: "", messages: []),
                config: AgentLoopConfig(model: testModel, toolExecutor: executor, cwd: "/tmp"),
                emit: emit,
                cancellation: cancellation,
                streamFn: makeStreamFn(first: stream)
            )
        }

        // 等待 toolExecutionStart
        var attempts = 0
        while await collector.count(of: "tool_execution_start") == 0 {
            await Task.yield()
            attempts += 1
            if attempts > 2000 {
                XCTFail("Timeout waiting for tool start")
                return
            }
        }

        // 在 tool 执行期间 abort
        cancellation.cancel(reason: "test abort")

        try? await runTask.value

        let startCount = await collector.count(of: "tool_execution_start")
        let endCount = await collector.count(of: "tool_execution_end")
        let agentEndCount = await collector.count(of: "agent_end")

        // tool start 应该有，但 abort 后不应有双 termination
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(agentEndCount, 1)
    }

    // MARK: - 2) steer 队列被 continue 消费

    func testSteerMultipleMessagesConsumedByContinue() async throws {
        let provider = MutableStreamProvider()
        provider.stream = makeStream(AssistantMessage.text("resp1", stopReason: .endTurn))

        let streamFn: StreamFn = { _, _, _ in provider.stream }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)

        // 第一轮
        try await agent.prompt("init")
        XCTAssertEqual(agent.state.messages.count, 2)

        // steer 两条消息（agent idle 时入队）
        agent.steer(.user(UserMessage(text: "queued A")))
        agent.steer(.user(UserMessage(text: "queued B")))
        XCTAssertEqual(agent.queuedSteeringMessages().count, 2)

        // continue 消费 steer 队列
        provider.stream = makeStream(AssistantMessage.text("resp2", stopReason: .endTurn))
        try await agent.continue()

        XCTAssertTrue(agent.queuedSteeringMessages().isEmpty)
        XCTAssertGreaterThanOrEqual(agent.state.messages.count, 4)
    }

    // MARK: - 3) abort 终止 streaming，后续 agent 可正常 prompt

    func testPromptAbortPromptSequence() async throws {
        let msg = AssistantMessage.text("hello", stopReason: .endTurn)
        let stream = AssistantMessageStream()

        // cancel-aware stream：push start 后，检测到取消即结束
        let streamFn: StreamFn = { _, _, options in
            Task.detached {
                stream.push(.start(partial: msg))
                for _ in 0..<10_000 {
                    if options?.cancellation?.isCancelled == true {
                        stream.push(.done(reason: .endTurn, message: msg))
                        stream.end(msg)
                        return
                    }
                    await Task.yield()
                }
                stream.push(.done(reason: .endTurn, message: msg))
                stream.end(msg)
            }
            return stream
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)

        let waiter = SingleShotWaiter()
        let unsub = agent.subscribe { event, _ in
            if case .messageStart = event {
                Task { await waiter.signal() }
            }
        }
        defer { unsub() }

        let task = Task { try await agent.prompt("hello") }
        await waiter.wait()

        agent.abort()
        try? await task.value

        XCTAssertFalse(agent.state.isStreaming)

        // 重新 prompt（用新 agent 避免共享状态问题）
        let stream2 = makeStream(AssistantMessage.text("ok", stopReason: .endTurn))
        let agent2 = Agent(initialState: AgentInitialState(model: testModel), streamFn: { _, _, _ in stream2 })
        try await agent2.prompt("again")
        XCTAssertEqual(agent2.state.messages.count, 2)
    }

    // MARK: - 4) 多 toolCall 串行执行：source order 稳定

    func testMultiToolCallSourceOrderStable() async throws {
        let counter = CountingCounter()
        let executor = ToolExecutor()
        executor.register(OrderedTool(counter: counter, name: "tool_a"))
        executor.register(OrderedTool(counter: counter, name: "tool_b"))

        let tc1 = ToolCall(id: "call-a", name: "tool_a", arguments: "{}")
        let tc2 = ToolCall(id: "call-b", name: "tool_b", arguments: "{}")
        let message = AssistantMessage(content: [.toolCall(tc1), .toolCall(tc2)], stopReason: .toolUse)
        let firstStream = makeStream(message)

        let collector = EventCollector()
        let emit: AgentEventSink = { event in await collector.append(event) }

        try? await AgentLoop.run(
            prompts: [],
            context: AgentContext(systemPrompt: "", messages: []),
            config: AgentLoopConfig(model: testModel, toolExecutor: executor, cwd: "/tmp"),
            emit: emit,
            cancellation: nil,
            streamFn: makeStreamFn(first: firstStream)
        )

        let toolEvents = await collector.events.filter {
            $0.type == "tool_execution_start" || $0.type == "tool_execution_end"
        }
        XCTAssertEqual(toolEvents.count, 4)

        if case .toolExecutionStart(let id, _, _) = toolEvents[0] { XCTAssertEqual(id, "call-a") }
        else { XCTFail() }
        if case .toolExecutionStart(let id, _, _) = toolEvents[2] { XCTAssertEqual(id, "call-b") }
        else { XCTFail() }
    }

    // MARK: - 5) bg 通知在 streaming 期间到达：消息入队，不崩溃

    func testBgNotificationWhileStreamingQueuesMessage() async throws {
        let bgManager = BackgroundTaskManager()
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        agent.setupBackgroundNotifications(manager: bgManager)

        // 给 setupBackgroundNotifications 一点时间完成 handler 注册
        for _ in 0..<20 { await Task.yield() }

        let promptTask = Task {
            _ = try await agent.prompt("hello")
        }

        // 等待进入 streaming 状态
        var attempts = 0
        while !agent.state.isStreaming {
            await Task.yield()
            attempts += 1
            if attempts > 1000 {
                XCTFail("Timeout waiting for streaming state")
                stream.end(AssistantMessage.text("timeout", stopReason: .endTurn))
                return
            }
        }

        // streaming 期间启动一个快速 bg 任务
        let taskId = await bgManager.start(command: "echo bg-done", cwd: "/tmp")

        // 等待 bg 任务完成
        var bgAttempts = 0
        while true {
            let records = await bgManager.status(id: taskId)
            if let record = records.first, record.status != .running { break }
            await Task.yield()
            bgAttempts += 1
            if bgAttempts > 2000 {
                XCTFail("Timeout waiting for bg task completion")
                break
            }
        }

        // 给 completion handler 执行 steer 的时间
        for _ in 0..<100 { await Task.yield() }

        // 验证 bg 通知已入队
        XCTAssertGreaterThanOrEqual(agent.queuedSteeringMessages().count, 1)

        // 安全结束 streaming
        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value

        XCTAssertFalse(agent.state.isStreaming)
    }

    // MARK: - 6) bg 通知在 idle 期间到达：自动触发 continue，不崩溃

    func testBgNotificationWhenIdleAutoContinues() async throws {
        let provider = MutableStreamProvider()

        let stream1 = AssistantMessageStream()
        provider.stream = stream1
        let streamFn: StreamFn = { _, _, _ in provider.stream }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let bgManager = BackgroundTaskManager()
        agent.setupBackgroundNotifications(manager: bgManager)

        // 给 handler 注册时间
        for _ in 0..<20 { await Task.yield() }

        // 第一轮对话，让 agent 进入 idle
        let task1 = Task {
            _ = try await agent.prompt("init")
        }
        stream1.end(AssistantMessage.text("response1", stopReason: .endTurn))
        try await task1.value

        XCTAssertFalse(agent.state.isStreaming)
        XCTAssertEqual(agent.state.messages.count, 2)

        // 设置第二轮 stream
        let stream2 = AssistantMessageStream()
        provider.stream = stream2

        // 启动 bg 任务
        _ = await bgManager.start(command: "echo done", cwd: "/tmp")

        // 等待 bg 触发的 continue 进入 streaming
        var attempts = 0
        while !agent.state.isStreaming {
            await Task.yield()
            attempts += 1
            if attempts > 2000 {
                XCTFail("Timeout waiting for bg-triggered continue to start streaming")
                stream2.end(AssistantMessage.text("timeout", stopReason: .endTurn))
                return
            }
        }

        // 结束第二轮
        stream2.end(AssistantMessage.text("final", stopReason: .endTurn))

        // 等待完成
        var doneAttempts = 0
        while agent.state.isStreaming {
            await Task.yield()
            doneAttempts += 1
            if doneAttempts > 2000 {
                XCTFail("Timeout waiting for bg-triggered continue to finish")
                break
            }
        }

        // 验证新增了 bg 通知触发的对话
        XCTAssertGreaterThanOrEqual(agent.state.messages.count, 4)
    }

    // MARK: - 8) auto-compact: 低于阈值不触发

    func testAutoCompactBelowThresholdDoesNotTrigger() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        // 预填充 20 条消息（低于默认阈值 24）
        for i in 0..<10 {
            agent.state.messages.append(.user(UserMessage(text: "user \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("assistant \(i)", stopReason: .endTurn)))
        }
        XCTAssertEqual(agent.state.messages.count, 20)

        let result = agent.state.maybeAutoCompact()

        XCTAssertNil(result)
        XCTAssertEqual(agent.state.messages.count, 20)
    }

    // MARK: - 9) auto-compact: 超过阈值触发

    func testAutoCompactAboveThresholdTriggers() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        // 预填充 26 条消息（超过默认阈值 24）
        for i in 0..<13 {
            agent.state.messages.append(.user(UserMessage(text: "user \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("assistant \(i)", stopReason: .endTurn)))
        }
        XCTAssertEqual(agent.state.messages.count, 26)

        let result = agent.state.maybeAutoCompact()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.before, 26)
        XCTAssertEqual(result?.after, 10)
    }

    // MARK: - 10) auto-compact: 事件在 prompt 结束后发出

    func testAutoCompactEventEmittedAfterPrompt() async throws {
        _ = await registerBuiltins(sourceId: "test-builtins-auto-compact")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-builtins-auto-compact") }
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel))
        // 预填充 24 条消息，再发一条 user prompt 就会变成 26 条（超过阈值）
        for i in 0..<12 {
            agent.state.messages.append(.user(UserMessage(text: "user \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("assistant \(i)", stopReason: .endTurn)))
        }
        XCTAssertEqual(agent.state.messages.count, 24)

        let collector = EventCollector()
        _ = agent.subscribe { event, _ in
            await collector.append(event)
        }

        try await agent.prompt("trigger compact")

        let compactEvents = await collector.events.filter {
            if case .contextCompacted = $0 { return true }
            return false
        }
        XCTAssertEqual(compactEvents.count, 1)
        if case .contextCompacted(let before, let after) = compactEvents.first {
            XCTAssertEqual(before, 26) // 24 + user + assistant
            XCTAssertEqual(after, 10)
        }
    }

    // MARK: - 11) auto-compact: 阈值可配置

    func testAutoCompactThresholdIsConfigurable() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.autoCompactThreshold = 6

        for i in 0..<7 {
            agent.state.messages.append(.user(UserMessage(text: "user \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("assistant \(i)", stopReason: .endTurn)))
        }
        XCTAssertEqual(agent.state.messages.count, 14)

        let result = agent.state.maybeAutoCompact()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.before, 14)
        XCTAssertEqual(result?.after, 10)
    }

    // MARK: - 12) auto-compact: minGap 阻止频繁触发

    func testAutoCompactMinGapPreventsFrequentTrigger() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.autoCompactThreshold = 10
        agent.state.autoCompactKeepCount = 5
        agent.state.autoCompactMinGap = 10

        // 第一次：15 条消息，超过阈值 10，且 15 - 0 = 15 >= minGap 10
        for i in 0..<8 {
            agent.state.messages.append(.user(UserMessage(text: "user \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("assistant \(i)", stopReason: .endTurn)))
        }
        agent.state.messages.append(.user(UserMessage(text: "extra")))
        XCTAssertEqual(agent.state.messages.count, 17)

        let result1 = agent.state.maybeAutoCompact()
        XCTAssertNotNil(result1)
        XCTAssertEqual(result1?.after, 5)

        // 第二次：从 5 增长到 14（新增 9 条），14 > 10 但 14 - 5 = 9 < minGap 10
        for i in 0..<4 {
            agent.state.messages.append(.user(UserMessage(text: "follow-up \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("resp \(i)", stopReason: .endTurn)))
        }
        agent.state.messages.append(.user(UserMessage(text: "one more")))
        XCTAssertEqual(agent.state.messages.count, 14)

        let result2 = agent.state.maybeAutoCompact()
        XCTAssertNil(result2, "Should not trigger because minGap not satisfied: 14 - 5 = 9 < 10")

        // 第三次：再增加到 20，20 - 5 = 15 >= minGap 10
        for i in 0..<3 {
            agent.state.messages.append(.user(UserMessage(text: "final \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("final resp \(i)", stopReason: .endTurn)))
        }
        XCTAssertEqual(agent.state.messages.count, 20)

        let result3 = agent.state.maybeAutoCompact()
        XCTAssertNotNil(result3, "Should trigger because minGap is now satisfied: 20 - 5 = 15 >= 10")
        XCTAssertEqual(result3?.after, 5)
    }

    // MARK: - 13) auto-compact: keepCount 可配置

    func testAutoCompactKeepCountIsConfigurable() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.autoCompactThreshold = 10
        agent.state.autoCompactKeepCount = 5

        for i in 0..<6 {
            agent.state.messages.append(.user(UserMessage(text: "user \(i)")))
            agent.state.messages.append(.assistant(AssistantMessage.text("assistant \(i)", stopReason: .endTurn)))
        }
        XCTAssertEqual(agent.state.messages.count, 12)

        let result = agent.state.maybeAutoCompact()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.before, 12)
        XCTAssertEqual(result?.after, 5)
    }

    // MARK: - 7) 长链路：prompt → tool → bg → continue → final

    func testLongChainPromptToolBgContinueFinal() async throws {
        let executor = ToolExecutor()
        executor.register(SimpleEchoTool())

        let bgManager = BackgroundTaskManager()
        executor.register(BgTool(manager: bgManager))
        executor.register(BgStatusTool(manager: bgManager))

        let tc1 = ToolCall(id: "call-echo", name: "echo", arguments: "{\"msg\":\"hello\"}")
        let tc2 = ToolCall(id: "call-bg", name: "bg", arguments: "{\"command\":\"echo done\"}")

        let stream1 = makeStream(AssistantMessage(content: [.toolCall(tc1)], stopReason: .toolUse))
        let stream2 = makeStream(AssistantMessage(content: [.toolCall(tc2)], stopReason: .toolUse))
        let stream3 = makeStream(AssistantMessage.text("final", stopReason: .endTurn))

        let collector = EventCollector()
        let emit: AgentEventSink = { event in await collector.append(event) }

        let provider = StreamProvider(streams: [stream1, stream2, stream3])
        let streamFn: StreamFn = { _, _, _ in await provider.next() }

        try? await AgentLoop.run(
            prompts: [.user(UserMessage(text: "start"))],
            context: AgentContext(systemPrompt: "", messages: []),
            config: AgentLoopConfig(model: testModel, toolExecutor: executor, cwd: "/tmp"),
            emit: emit,
            cancellation: nil,
            streamFn: streamFn
        )

        // echo tool 执行了
        let echoEvents = await collector.events.filter {
            if case .toolExecutionEnd(_, let name, _, _) = $0 { return name == "echo" }
            return false
        }
        XCTAssertEqual(echoEvents.count, 1)

        // bg tool 执行了
        let bgEvents = await collector.events.filter {
            if case .toolExecutionEnd(_, let name, _, _) = $0 { return name == "bg" }
            return false
        }
        XCTAssertEqual(bgEvents.count, 1)

        // 最终收敛到 agent_end
        let agentEndCount = await collector.count(of: "agent_end")
        XCTAssertEqual(agentEndCount, 1)

        // 事件链路完整：agentStart -> turnStart -> messageStart/End(user) -> messageStart/End(assistant)
        // -> toolExecutionStart/End(echo) -> messageEnd(tool_result) -> turnEnd
        // -> turnStart -> messageStart/End(assistant) -> toolExecutionStart/End(bg)
        // -> messageEnd(tool_result) -> turnEnd -> turnStart -> messageStart/End(final) -> agentEnd
        let typeSequence = await collector.events.map(\.type)
        XCTAssertTrue(typeSequence.contains("agent_start"))
        XCTAssertTrue(typeSequence.contains("agent_end"))
        XCTAssertTrue(typeSequence.contains("tool_execution_start"))
        XCTAssertTrue(typeSequence.contains("tool_execution_end"))
    }

    // MARK: - Helpers

    private func makeStream(_ message: AssistantMessage) -> AssistantMessageStream {
        let stream = AssistantMessageStream()
        Task.detached {
            stream.push(.start(partial: message))
            stream.push(.done(reason: message.stopReason, message: message))
            stream.end(message)
        }
        return stream
    }

    /// 返回一个 streamFn：第一轮用给定的 stream，之后返回 endTurn stream（避免无限 tool loop）
    private func makeStreamFn(first: AssistantMessageStream) -> StreamFn {
        let endTurnMsg = AssistantMessage.text("done", stopReason: .endTurn)
        let flag = FirstFlag()
        return { _, _, _ in
            let isFirst = flag.take()
            if isFirst {
                return first
            }
            let fallback = AssistantMessageStream()
            Task.detached {
                fallback.push(.start(partial: endTurnMsg))
                fallback.push(.done(reason: .endTurn, message: endTurnMsg))
                fallback.end(endTurnMsg)
            }
            return fallback
        }
    }
}

// MARK: - Test Helpers

private actor CountingCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

/// 慢工具：先 yield 让出时间片，再检查取消状态（无固定延迟，避免测试超时）
private struct SlowTool: Tool {
    let name: String

    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        // 让出时间片，模拟异步工作
        for _ in 0..<100 {
            await Task.yield()
            if cancellation?.isCancelled == true {
                return ToolResult(output: "Cancelled", isError: true)
            }
        }
        return ToolResult(output: "Done", isError: false)
    }
}

private struct OrderedTool: Tool {
    let counter: CountingCounter
    let name: String

    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        await Task.yield()
        let count = await counter.increment()
        return ToolResult(output: "\(name) #\(count)", isError: false)
    }
}

private final class MutableStreamProvider: @unchecked Sendable {
    var stream: AssistantMessageStream!
}

private final class FirstFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let result = !value
        if result { value = true }
        return result
    }
}

private actor SingleShotWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if fired {
                cont.resume()
            } else {
                continuation = cont
            }
        }
    }

    func signal() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}

private struct SimpleEchoTool: Tool {
    let name = "echo"
    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        ToolResult(output: "echo: \(arguments)", isError: false)
    }
}

private actor StreamProvider {
    let streams: [AssistantMessageStream]
    private var index = 0

    init(streams: [AssistantMessageStream]) {
        self.streams = streams
    }

    func next() -> AssistantMessageStream {
        let s = streams[index]
        index += 1
        return s
    }
}
