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
        XCTAssertNotNil(registry.command(named: "/queue"))
        XCTAssertNotNil(registry.command(named: "/attach"))
        XCTAssertNotNil(registry.command(named: "/attachments"))
        XCTAssertNotNil(registry.command(named: "/detach"))
        XCTAssertNotNil(registry.command(named: "/save"))
        XCTAssertNotNil(registry.command(named: "/load"))
        XCTAssertNotNil(registry.command(named: "/sessions"))
        XCTAssertNotNil(registry.command(named: "/export"))
        XCTAssertNotNil(registry.command(named: "/help"))
        XCTAssertNotNil(registry.command(named: "/exit"))
    }

    func testDefaultRegistryResolvesQuitAlias() {
        let registry = makeDefaultSlashCommandRegistry()
        let agent = Agent(initialState: AgentInitialState(model: testModel))

        let result = registry.execute(
            "/quit",
            context: SlashCommandContext(agent: agent, modelStore: nil, attachmentStore: AttachmentStore())
        )

        XCTAssertEqual(result, .exit)
    }

    func testDefaultRegistryHelpTextListsRegisteredCommands() {
        let helpText = makeDefaultSlashCommandRegistry().helpText()

        XCTAssertTrue(helpText.contains("/model"))
        XCTAssertTrue(helpText.contains("/compact"))
        XCTAssertTrue(helpText.contains("/queue"))
        XCTAssertTrue(helpText.contains("/save"))
        XCTAssertTrue(helpText.contains("/load"))
        XCTAssertTrue(helpText.contains("/sessions"))
        XCTAssertTrue(helpText.contains("/export"))
        XCTAssertTrue(helpText.contains("/help"))
        XCTAssertTrue(helpText.contains("/exit, /quit"))
    }

    func testUnknownCommandUsesRegistryAvailableList() {
        let registry = makeDefaultSlashCommandRegistry()
        let agent = Agent(initialState: AgentInitialState(model: testModel))

        let result = registry.execute(
            "/unknown",
            context: SlashCommandContext(agent: agent, modelStore: nil, attachmentStore: AttachmentStore())
        )

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Available: /model, /compact, /queue, /attach, /attachments, /detach, /save, /load, /sessions, /export, /help, /exit"))
        } else {
            XCTFail("Expected feedback result")
        }
    }
}
