import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

final class AgentSmokeTests: XCTestCase {
    func testPromptAppendsMessages() async throws {
        _ = await registerBuiltins(sourceId: "test-builtins")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-builtins") }
        }

        let model = Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
        let agent = Agent(initialState: AgentInitialState(model: model))
        try await agent.prompt("hello")

        XCTAssertEqual(agent.state.messages.count, 2)
        XCTAssertEqual(agent.state.messages.first?.role, "user")
        XCTAssertEqual(agent.state.messages.last?.role, "assistant")
        XCTAssertFalse(agent.state.isStreaming)
    }

    func testPromptFailureEmitsAssistantErrorMessageEnd() async throws {
        let model = Model(
            id: "missing-provider-model",
            name: "Missing Provider",
            api: "not-registered-api",
            provider: "not-registered-provider"
        )
        let agent = Agent(initialState: AgentInitialState(model: model))

        let recorder = EventRecorder()
        _ = agent.subscribe { event, _ in
            await recorder.append(event)
        }

        try await agent.prompt("hello")

        let events = await recorder.all()
        let hasMessageEndError = events.contains { event in
            if case .messageEnd(let message) = event, case .assistant(let assistant) = message {
                return assistant.stopReason == .error && (assistant.errorMessage?.isEmpty == false)
            }
            return false
        }
        XCTAssertTrue(hasMessageEndError)
    }
}

private actor EventRecorder {
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        events.append(event)
    }

    func all() -> [AgentEvent] {
        events
    }
}
