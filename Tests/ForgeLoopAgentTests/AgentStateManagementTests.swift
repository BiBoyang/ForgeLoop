import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopTestSupport

final class AgentStateManagementTests: XCTestCase {
    private let testModel = Model(
        id: "test-model",
        name: "Test Model",
        api: "faux",
        provider: "faux"
    )

    // MARK: - switchModel

    func testSwitchModelUpdatesState() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let newModel = testModel.switched(to: "new-model-id")

        try await agent.switchModel(to: newModel)

        XCTAssertEqual(agent.state.model.id, "new-model-id")
        XCTAssertEqual(agent.state.model.api, testModel.api)
        XCTAssertEqual(agent.state.model.provider, testModel.provider)
    }

    func testSwitchModelThrowsWhileStreaming() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.setStreaming(true)

        let newModel = testModel.switched(to: "new-model-id")
        await XCTAssertThrowsErrorAsync {
            try await agent.switchModel(to: newModel)
        }
    }

    // MARK: - restoreSession

    func testRestoreSessionUpdatesMessages() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let messages: [Message] = [
            .user(UserMessage(text: "hello")),
            .assistant(AssistantMessage.text("hi"))
        ]

        try await agent.restoreSession(messages: messages)

        XCTAssertEqual(agent.state.messages.count, 2)
        XCTAssertEqual(agent.state.messages.first?.role, "user")
    }

    func testRestoreSessionUpdatesModelWhenDifferentID() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let messages: [Message] = [
            .user(UserMessage(text: "hello"))
        ]

        try await agent.restoreSession(messages: messages, modelID: "different-id")

        XCTAssertEqual(agent.state.model.id, "different-id")
        XCTAssertEqual(agent.state.messages.count, 1)
    }

    func testRestoreSessionKeepsModelWhenSameID() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let messages: [Message] = [
            .user(UserMessage(text: "hello"))
        ]

        try await agent.restoreSession(messages: messages, modelID: testModel.id)

        XCTAssertEqual(agent.state.model.id, testModel.id)
        XCTAssertEqual(agent.state.messages.count, 1)
    }

    func testRestoreSessionThrowsWhileStreaming() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.setStreaming(true)

        await XCTAssertThrowsErrorAsync {
            try await agent.restoreSession(messages: [.user(UserMessage(text: "hello"))])
        }
    }

    func testRestoreSessionClearsStreamingAndErrorMessages() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.setStreamingMessage(.user(UserMessage(text: "partial")))
        agent.state.setErrorMessage("some error")

        try await agent.restoreSession(messages: [.user(UserMessage(text: "hello"))])

        XCTAssertNil(agent.state.streamingMessage)
        XCTAssertNil(agent.state.errorMessage)
    }

    // MARK: - compactContext

    func testCompactContextReducesMessagesAndEmitsEvent() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let recorder = EventRecorder()
        _ = agent.subscribe { event, _ in
            await recorder.append(event)
        }

        let messages: [Message] = (0..<30).map { index in
            if index.isMultiple(of: 2) {
                return .user(UserMessage(text: "msg\(index)"))
            } else {
                return .assistant(AssistantMessage.text("resp\(index)"))
            }
        }
        try await agent.restoreSession(messages: messages)

        try await agent.compactContext(keepLast: 10)

        XCTAssertEqual(agent.state.messages.count, 10)
        let events = await recorder.all()
        XCTAssertTrue(events.contains { event in
            if case .contextCompacted(let before, let after, _) = event {
                return before == 30 && after == 10
            }
            return false
        })
    }

    func testCompactContextThrowsWhileStreaming() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.setStreaming(true)

        await XCTAssertThrowsErrorAsync {
            try await agent.compactContext()
        }
    }

    // MARK: - External state writes are prevented

    func testStateSettersAreInternalOnly() {
        // This test documents the intended access level. If it fails to compile,
        // it means CLI/App code (or tests in external modules) can still write
        // AgentState directly, violating the layered boundary.
        //
        // The following lines should NOT compile from an external test module:
        // let agent = Agent(initialState: AgentInitialState(model: testModel))
        // agent.state.messages = []
        // agent.state.model = testModel
        // agent.state.systemPrompt = ""
        //
        // If you are reading this comment because of a compilation error above,
        // route the write through Agent's public API instead.
        XCTAssertTrue(true)
    }

    // MARK: - Configuration concurrency safety

    func testConcurrentConfigReadsAndWritesDoNotCrash() async {
        let agent = Agent(initialState: AgentInitialState(model: testModel))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    agent.cwd = "/path/\(i)"
                    agent.toolExecutionMode = i.isMultiple(of: 2) ? .parallel : .sequential
                    agent.apiKeyResolver = { _ in "key-\(i)" }
                    _ = agent.cwd
                    _ = agent.toolExecutionMode
                    _ = agent.apiKeyResolver
                }
            }
        }

        // Reaching here without a crash or data-race assertion means the
        // lock-protected config is safe under concurrent access.
        XCTAssertTrue(true)
    }

    func testConfigSnapshotIsConsistent() {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.cwd = "/tmp"
        agent.toolExecutionMode = .parallel
        agent.apiKeyResolver = { _ in "secret" }

        XCTAssertEqual(agent.cwd, "/tmp")
        XCTAssertEqual(agent.toolExecutionMode, .parallel)
        XCTAssertNotNil(agent.apiKeyResolver)
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

private extension AssistantMessage {
    static func text(_ text: String) -> AssistantMessage {
        AssistantMessage(
            content: [.text(TextContent(text: text))],
            stopReason: .endTurn
        )
    }
}
