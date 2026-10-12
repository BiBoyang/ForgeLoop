import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli

/// TASK-submit-nonblocking：非 streaming 提交必须立即返回，事件循环不被 run 占死。
@MainActor
final class SessionCoordinatorNonblockingTests: XCTestCase {
    private let testModel = Model(
        id: "test-model",
        name: "Test Model",
        api: "faux",
        provider: "faux"
    )

    // MARK: - DoD#2：慢 run 期间 submit 立即返回

    func testSubmitReturnsBeforeRunCompletes() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let coordinator = SessionCoordinator(agent: agent)

        let result = try await coordinator.submit("hello")

        // stream 挂起、run 未结束，但 submit 已经返回
        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(agent.state.messages.allSatisfy { $0.role != "assistant" })

        // 收尾：结束 run，验证事件闭环后消息完整
        let reached = await waitUntilTrue { agent.state.isStreaming }
        XCTAssertTrue(reached)
        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        await waitForRunSettled(coordinator: coordinator, agent: agent)
        XCTAssertEqual(agent.state.messages.map(\.role), ["user", "assistant"])
    }

    // MARK: - DoD#2：run 期间第二次提交走 steer 分支

    func testSubmitDuringActiveRunSteers() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let coordinator = SessionCoordinator(agent: agent)

        _ = try await coordinator.submit("hello")
        let reached = await waitUntilTrue { agent.state.isStreaming }
        XCTAssertTrue(reached)

        let result = try await coordinator.submit("follow-up")

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        await waitForRunSettled(coordinator: coordinator, agent: agent)
    }

    // MARK: - 竞态窗口：run 已认领（activeRunTask）但 isStreaming 尚未置位时也走 steer

    func testSubmitBeforeRunStartsSteers() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let coordinator = SessionCoordinator(agent: agent)

        _ = try await coordinator.submit("first")
        // 不等待 isStreaming：第二次提交落在「run 已 spawn 但未开始」窗口
        _ = try await coordinator.submit("second")

        XCTAssertEqual(agent.queuedSteeringMessages().count, 1)

        let reached = await waitUntilTrue { agent.state.isStreaming }
        XCTAssertTrue(reached)
        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        await waitForRunSettled(coordinator: coordinator, agent: agent)
        XCTAssertEqual(agent.state.messages.map(\.role), ["user", "assistant"])
    }

    // MARK: - DoD#3：run 失败经事件流可见，不经 throw 上抛、不静默

    func testRunFailureSurfacesViaEventStream() async throws {
        struct StubError: Error {}
        let streamFn: StreamFn = { _, _, _ in throw StubError() }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)

        var sawFailureMessageEnd = false
        var sawAgentEnd = false
        let unsubscribe = agent.subscribe { @MainActor event, _ in
            if case .messageEnd(let message) = event,
               case .assistant(let assistant) = message,
               assistant.stopReason == .error {
                sawFailureMessageEnd = true
            }
            if case .agentEnd = event {
                sawAgentEnd = true
            }
        }
        defer { unsubscribe() }

        let coordinator = SessionCoordinator(agent: agent)

        let result = try await coordinator.submit("boom")
        XCTAssertEqual(result, .submitted)

        await waitForRunSettled(coordinator: coordinator, agent: agent)

        XCTAssertNotNil(agent.state.errorMessage)
        guard case .assistant(let failure) = agent.state.messages.last else {
            XCTFail("Expected failure assistant message")
            return
        }
        XCTAssertEqual(failure.stopReason, .error)
        XCTAssertTrue(sawFailureMessageEnd, "failure messageEnd must be visible in event stream")
        XCTAssertTrue(sawAgentEnd, "agentEnd must close the failure run")
    }

    // MARK: - DoD#4：事件循环解放后 Esc（agent.abort）中断路径可用，且之后可发起新 run

    func testAbortDuringBackgroundedRunThenNewRun() async throws {
        let delayBox = TokenDelayBox()
        let streamFn: StreamFn = { model, context, options in
            await FauxProvider(tokenDelayNanos: delayBox.nanos)
                .stream(model: model, context: context, options: options)
        }
        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let coordinator = SessionCoordinator(agent: agent)

        _ = try await coordinator.submit("hello")
        let reached = await waitUntilTrue { agent.state.isStreaming }
        XCTAssertTrue(reached)

        // Esc 路径调用的就是 agent.abort()
        agent.abort()
        await waitForRunSettled(coordinator: coordinator, agent: agent)

        XCTAssertFalse(agent.state.isStreaming)
        guard case .assistant(let aborted) = agent.state.messages.last else {
            XCTFail("Expected aborted assistant message")
            return
        }
        XCTAssertEqual(aborted.stopReason, .aborted)

        // abort 后无残留占用：新提交能启动新 run 并正常闭环（无双终止）
        delayBox.nanos = 0
        _ = try await coordinator.submit("again")
        await waitForRunSettled(coordinator: coordinator, agent: agent)

        XCTAssertEqual(agent.state.messages.map(\.role), ["user", "assistant", "user", "assistant"])
        guard case .assistant(let completed) = agent.state.messages.last else {
            XCTFail("Expected completed assistant message")
            return
        }
        XCTAssertEqual(completed.stopReason, .endTurn)
    }

    // MARK: - helpers

    /// 等待 run 完全 settle：streaming 结束且后台任务已清理（activeRunTask 归零），
    /// 避免「isStreaming 已 false 但 defer 尚未清 task」的竞态窗口。
    private func waitForRunSettled(
        coordinator: SessionCoordinator,
        agent: Agent,
        timeoutSeconds: Double = 10
    ) async {
        let settled = await waitUntilTrue(timeoutSeconds: timeoutSeconds) {
            !agent.state.isStreaming && coordinator.activeRunTask == nil
        }
        XCTAssertTrue(settled, "Timeout waiting for run to settle")
    }

    private func waitUntilTrue(
        timeoutSeconds: Double = 10,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

/// 可调 token 延迟的 FauxProvider 参数盒（跨任务共享，需 Sendable）。
private final class TokenDelayBox: @unchecked Sendable {
    var nanos: UInt64 = 100_000_000
}
