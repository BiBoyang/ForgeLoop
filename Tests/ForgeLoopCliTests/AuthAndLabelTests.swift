import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli

@MainActor
final class AuthAndLabelTests: XCTestCase {

    // MARK: - resolveAgentAuth priority: CLI override > store > default

    func testCLIOverrideTakesPrecedence() async throws {
        let resolved = try await resolveAgentAuth(modelOverride: "gpt-4o")
        XCTAssertEqual(resolved.model.id, "gpt-4o")
        XCTAssertEqual(resolved.model.name, "gpt-4o")
    }

    func testDefaultFallbackWhenNoOverrideAndNoStore() async throws {
        let tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forgeloop-auth-test-\(UUID().uuidString)")
            .appendingPathComponent("model.json")
        let resolved = try await resolveAgentAuth(
            modelOverride: nil,
            modelStore: ModelStore(fileURL: tempPath)
        )
        XCTAssertEqual(resolved.model.id, "faux-coding-model")
    }

    // MARK: - labelForModel

    func testLabelForDefaultModel() {
        let defaultModel = Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
        let label = labelForModel(defaultModel)
        XCTAssertTrue(label.contains("faux-coding-model"))
        XCTAssertTrue(label.contains("local scaffold"))
    }

    func testLabelForCustomModel() {
        let customModel = Model(
            id: "gpt-4o",
            name: "GPT-4o",
            api: "openai",
            provider: "openai"
        )
        let label = labelForModel(customModel)
        XCTAssertTrue(label.contains("GPT-4o"))
        XCTAssertTrue(label.contains("gpt-4o"))
    }

    // MARK: - /model switches state.model dynamically

    func testModelSwitchUpdatesAgentState() async throws {
        let agent = Agent(initialState: AgentInitialState(
            model: Model(id: "old-model", name: "Old", api: "faux", provider: "faux")
        ))
        let controller = PromptController(agent: agent)

        XCTAssertEqual(agent.state.model.id, "old-model")

        _ = try await controller.submit("/model new-model")

        XCTAssertEqual(agent.state.model.id, "new-model")
        XCTAssertEqual(agent.state.model.name, "new-model")
        // api/provider preserved from original
        XCTAssertEqual(agent.state.model.api, "faux")
        XCTAssertEqual(agent.state.model.provider, "faux")
    }

    func testLabelForModelReflectsSwitch() async throws {
        let agent = Agent(initialState: AgentInitialState(
            model: Model(id: "old-model", name: "Old", api: "faux", provider: "faux")
        ))
        let controller = PromptController(agent: agent)

        let oldLabel = labelForModel(agent.state.model)
        XCTAssertTrue(oldLabel.contains("old-model"))

        _ = try await controller.submit("/model gpt-4o")

        let newLabel = labelForModel(agent.state.model)
        XCTAssertTrue(newLabel.contains("gpt-4o"))
        XCTAssertFalse(newLabel.contains("old-model"))
    }
}
