import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

final class AgentContinueTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    // MARK: - 1) continue on empty transcript -> throws noMessagesToContinue

    func testContinueOnEmptyTranscriptThrows() async throws {
        _ = await registerBuiltins(sourceId: "test-builtins")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-builtins") }
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel))
        XCTAssertTrue(agent.state.messages.isEmpty)

        do {
            try await agent.continue()
            XCTFail("Expected noMessagesToContinue error")
        } catch let error as AgentError {
            XCTAssertEqual(error, .noMessagesToContinue)
        }
    }

    // MARK: - 2) queued steering is consumed by continue() and appended

    func testContinueConsumesSteeringQueue() async throws {
        _ = await registerBuiltins(sourceId: "test-builtins")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-builtins") }
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel))
        try await agent.prompt("hello")
        XCTAssertEqual(agent.state.messages.count, 2)

        agent.steer(.user(UserMessage(text: "follow-up")))
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        try await agent.continue()

        XCTAssertEqual(agent.state.messages.count, 4)
        XCTAssertEqual(agent.state.messages[2].role, "user")
        XCTAssertEqual(agent.state.messages[3].role, "assistant")
        XCTAssertTrue(agent.queuedSteeringMessages().isEmpty)
    }

    // MARK: - 3) last message is assistant and queue empty -> throws cannotContinueFromAssistant

    func testContinueFromAssistantThrows() async throws {
        _ = await registerBuiltins(sourceId: "test-builtins")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-builtins") }
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel))
        try await agent.prompt("hello")
        XCTAssertEqual(agent.state.messages.last?.role, "assistant")

        do {
            try await agent.continue()
            XCTFail("Expected cannotContinueFromAssistant error")
        } catch let error as AgentError {
            XCTAssertEqual(error, .cannotContinueFromAssistant)
        }
    }

    // MARK: - 4) queue APIs

    func testSteerSnapshotAndClear() {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        XCTAssertTrue(agent.queuedSteeringMessages().isEmpty)

        agent.steer(.user(UserMessage(text: "A")))
        agent.steer(.user(UserMessage(text: "B")))
        XCTAssertEqual(agent.queuedSteeringMessages().count, 2)

        agent.clearSteeringQueue()
        XCTAssertTrue(agent.queuedSteeringMessages().isEmpty)
    }

    // MARK: - 5) real concurrency: steer during streaming + continue() -> alreadyRunning, queue not lost

    func testSteerDuringStreamingDoesNotLoseQueue() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)

        // 后台启动 prompt，stream 会挂起在 for-await 上
        let promptTask = Task {
            try await agent.prompt("hello")
        }

        // 等待 prompt 进入 streaming 状态（最多 1 秒）
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

        // streaming 期间 steer 入队
        agent.steer(.user(UserMessage(text: "steered")))
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        // 尝试 continue，期望 alreadyRunning
        do {
            try await agent.continue()
            XCTFail("Expected alreadyRunning error")
        } catch let error as AgentError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        // 断言队列未丢失
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        // 结束流，让 prompt 完成
        let final = AssistantMessage.text("assistant response", stopReason: .endTurn)
        stream.end(final)

        // 等待 prompt 完成
        try await promptTask.value
        XCTAssertFalse(agent.state.isStreaming)

        // 此时继续应该成功消费队列
        try await agent.continue()
        XCTAssertTrue(agent.queuedSteeringMessages().isEmpty)
        XCTAssertEqual(agent.state.messages.count, 4)
        XCTAssertEqual(agent.state.messages[2].role, "user")
        XCTAssertEqual(agent.state.messages[3].role, "assistant")
    }
}
