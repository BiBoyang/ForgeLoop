import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli

@MainActor
final class SlashCommandRegistryTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    func testDefaultRegistryResolvesPrimaryCommandNames() {
        let registry = makeDefaultSlashCommandRegistry()

        XCTAssertNotNil(registry.command(named: "/model"))
        XCTAssertNotNil(registry.command(named: "/compact"))
        XCTAssertNotNil(registry.command(named: "/help"))
        XCTAssertNotNil(registry.command(named: "/exit"))
    }

    func testDefaultRegistryResolvesQuitAlias() {
        let registry = makeDefaultSlashCommandRegistry()
        let agent = Agent(initialState: AgentInitialState(model: testModel))

        let result = registry.execute(
            "/quit",
            context: SlashCommandContext(agent: agent, modelStore: nil)
        )

        XCTAssertEqual(result, .exit)
    }

    func testDefaultRegistryHelpTextListsRegisteredCommands() {
        let helpText = makeDefaultSlashCommandRegistry().helpText()

        XCTAssertTrue(helpText.contains("/model"))
        XCTAssertTrue(helpText.contains("/compact"))
        XCTAssertTrue(helpText.contains("/help"))
        XCTAssertTrue(helpText.contains("/exit, /quit"))
    }

    func testUnknownCommandUsesRegistryAvailableList() {
        let registry = makeDefaultSlashCommandRegistry()
        let agent = Agent(initialState: AgentInitialState(model: testModel))

        let result = registry.execute(
            "/unknown",
            context: SlashCommandContext(agent: agent, modelStore: nil)
        )

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Available: /model, /compact, /help, /exit"))
        } else {
            XCTFail("Expected feedback result")
        }
    }
}
