import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private let testModel = Model(
        id: "test-model",
        name: "Test Model",
        api: "faux",
        provider: "faux"
    )

    func testSubmitInjectsAttachments() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        store.addText("context")
        let coordinator = SessionCoordinator(agent: agent, attachmentStore: store)

        let result = try await coordinator.submit("hello")

        XCTAssertEqual(result, .submitted)
        let userMessages = agent.state.messages.compactMap { msg -> UserMessage? in
            if case .user(let userMsg) = msg { return userMsg }
            return nil
        }
        XCTAssertFalse(userMessages.isEmpty)
        let combined = userMessages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(combined.contains("hello"))
        XCTAssertTrue(combined.contains("context"))
    }

    func testSwitchModelUpdatesAgentAndStore() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let modelStore = ModelStore()
        let coordinator = SessionCoordinator(agent: agent, modelStore: modelStore)

        try await coordinator.switchModel(to: "new-model-id")

        XCTAssertEqual(agent.state.model.id, "new-model-id")
        XCTAssertEqual(modelStore.load()?.id, "new-model-id")
    }

    func testHandleSlashCommandAttachModifiesSharedStore() async {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        let coordinator = SessionCoordinator(agent: agent, attachmentStore: store)

        let result = await coordinator.handleSlashCommand("/attach text hello")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("hello"))
        } else {
            XCTFail("Expected feedback result")
        }
        XCTAssertEqual(store.count, 1)
    }
}
