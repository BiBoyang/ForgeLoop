import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli

@MainActor
final class PromptControllerTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    // MARK: - 1) idle 时 submit 走 prompt 路径

    func testIdleSubmitCallsPromptPath() async throws {
        _ = await registerBuiltins(sourceId: "test-builtins")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-builtins") }
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        XCTAssertFalse(agent.state.isStreaming)
        let result = try await controller.submit("hello")
        XCTAssertEqual(result, .submitted)

        XCTAssertEqual(agent.state.messages.count, 2)
        XCTAssertEqual(agent.state.messages[0].role, "user")
        XCTAssertEqual(agent.state.messages[1].role, "assistant")
    }

    // MARK: - 2) streaming 时 submit 走 steer 路径

    func testStreamingSubmitQueuesSteerPath() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let controller = PromptController(agent: agent)

        // 后台启动 prompt，stream 会挂起
        let promptTask = Task {
            _ = try await controller.submit("hello")
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

        // streaming 期间再次 submit，应走 steer 路径
        _ = try? await controller.submit("follow-up")

        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value
    }

    // MARK: - 3) streaming 时不会触发 alreadyRunning

    func testStreamingSubmitDoesNotTriggerAlreadyRunning() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let controller = PromptController(agent: agent)

        let promptTask = Task {
            _ = try await controller.submit("hello")
        }

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

        // streaming 期间多次 submit，都不应抛 alreadyRunning
        _ = try? await controller.submit("msg1")
        _ = try? await controller.submit("msg2")

        XCTAssertEqual(agent.queuedSteeringMessages().count, 2)

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value
    }

    // MARK: - 4) streaming 期间 steer 后 slash 命令不丢队列

    func testSlashCommandDoesNotAffectSteerQueue() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let controller = PromptController(agent: agent)

        let promptTask = Task {
            _ = try await controller.submit("hello")
        }

        // 等待 streaming
        var attempts = 0
        while !agent.state.isStreaming {
            await Task.yield()
            attempts += 1
            if attempts > 1000 {
                XCTFail("Timeout waiting for streaming")
                stream.end(AssistantMessage.text("timeout", stopReason: .endTurn))
                return
            }
        }

        // streaming 期间先 steer 一条普通消息
        _ = try? await controller.submit("steer message")
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        // 再发 slash 命令，应返回 feedback 且不丢 steer 队列
        let result = try? await controller.submit("/model")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("faux-coding-model"))
        } else {
            XCTFail("Expected feedback during streaming, got \(String(describing: result))")
        }

        // steer 队列应保持不变
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value
    }

    // MARK: - 5) streaming 期间多条 slash 命令都能正常返回 feedback

    func testMultipleSlashCommandsDuringStreaming() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let controller = PromptController(agent: agent)

        let promptTask = Task {
            _ = try await controller.submit("hello")
        }

        // 等待 streaming
        var attempts = 0
        while !agent.state.isStreaming {
            await Task.yield()
            attempts += 1
            if attempts > 1000 {
                XCTFail("Timeout waiting for streaming")
                stream.end(AssistantMessage.text("timeout", stopReason: .endTurn))
                return
            }
        }

        // streaming 期间多次 slash 命令
        let result1 = try? await controller.submit("/model")
        let result2 = try? await controller.submit("/compact")
        let result3 = try? await controller.submit("/unknown")

        // 都应返回 feedback（不是 .submitted 也不是 .exit）
        if case .feedback = result1 {} else { XCTFail("Expected feedback for /model") }
        if case .feedback = result2 {} else { XCTFail("Expected feedback for /compact") }
        if case .feedback = result3 {} else { XCTFail("Expected feedback for /unknown") }

        // agent 不应因 slash 命令而异常
        XCTAssertTrue(agent.state.isStreaming)

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value

        XCTAssertFalse(agent.state.isStreaming)
    }

    // MARK: - 6) idle 期间先 steer 再 slash 命令，队列不受影响

    func testSlashCommandInterleavedWithSteerMessages() async throws {
        _ = await registerBuiltins(sourceId: "test-builtins")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-builtins") }
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        // idle 状态下 prompt
        try await controller.submit("hello")
        XCTAssertEqual(agent.state.messages.count, 2)

        // steer 一条消息（此时 agent idle，入队但不消费）
        agent.steer(.user(UserMessage(text: "queued")))
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        // slash 命令应该正常执行，不影响 steer 队列
        let result = try await controller.submit("/model")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("faux-coding-model"))
        } else {
            XCTFail("Expected feedback")
        }

        // steer 队列应保持不变
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)
    }

    // MARK: - 7) 队列消息可被 continue 消费

    func testQueuedPromptCanBeConsumedByContinue() async throws {
        let provider = MutableStreamProvider()

        let stream1 = AssistantMessageStream()
        provider.stream = stream1

        let streamFn: StreamFn = { _, _, _ in provider.stream }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let controller = PromptController(agent: agent)

        // 第一轮
        let task1 = Task {
            _ = try await controller.submit("init")
        }
        stream1.end(AssistantMessage.text("response", stopReason: .endTurn))
        try await task1.value

        XCTAssertEqual(agent.state.messages.count, 2)

        // 第二轮：换 stream
        let stream2 = AssistantMessageStream()
        provider.stream = stream2

        let task2 = Task {
            _ = try await controller.submit("next")
        }

        var a2 = 0
        while !agent.state.isStreaming {
            await Task.yield()
            a2 += 1
            if a2 > 1000 {
                XCTFail("Timeout")
                stream2.end(AssistantMessage.text("timeout", stopReason: .endTurn))
                return
            }
        }

        _ = try? await controller.submit("queued message")
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        stream2.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await task2.value

        XCTAssertEqual(agent.state.messages.count, 4)
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        // 第三轮：continue 消费队列
        let stream3 = AssistantMessageStream()
        provider.stream = stream3

        let task3 = Task {
            try await agent.continue()
        }
        stream3.end(AssistantMessage.text("final", stopReason: .endTurn))
        try await task3.value

        XCTAssertTrue(agent.queuedSteeringMessages().isEmpty)
        XCTAssertEqual(agent.state.messages.count, 6)
        XCTAssertEqual(agent.state.messages[4].role, "user")
        XCTAssertEqual(agent.state.messages[5].role, "assistant")
    }
}

private final class MutableStreamProvider: @unchecked Sendable {
    var stream: AssistantMessageStream!
}
