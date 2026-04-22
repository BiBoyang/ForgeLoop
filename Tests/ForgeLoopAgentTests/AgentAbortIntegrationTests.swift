import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

@MainActor
final class AgentAbortIntegrationTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    // MARK: - 1) agent.abort() 触发后产生 aborted assistant 消息

    func testAgentAbortWithFauxProviderProducesAbortedAssistant() async throws {
        let streamFn: StreamFn = { model, context, options in
            let provider = FauxProvider(tokenDelayNanos: 100_000_000)
            return provider.stream(model: model, context: context, options: options)
        }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)

        let promptTask = Task {
            try await agent.prompt("hello")
        }

        // 等待进入 streaming 状态
        var attempts = 0
        while !agent.state.isStreaming {
            await Task.yield()
            attempts += 1
            if attempts > 1000 {
                XCTFail("Timeout waiting for streaming state")
                return
            }
        }

        // abort
        agent.abort()

        // 等待 prompt 完成（可能会抛出，但不应悬挂）
        do {
            try await promptTask.value
        } catch {
            // abort 场景下可能抛 error，这是可接受的
        }

        // 验证 isStreaming 归零
        XCTAssertFalse(agent.state.isStreaming)

        // 验证最终消息是 aborted
        guard let last = agent.state.messages.last else {
            XCTFail("Expected at least one message")
            return
        }
        guard case .assistant(let assistant) = last else {
            XCTFail("Expected assistant message")
            return
        }
        XCTAssertEqual(assistant.stopReason, .aborted)
    }
}
