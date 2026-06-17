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

    func testDefaultRegistryResolvesQuitAlias() async {
        let registry = makeDefaultSlashCommandRegistry()
        let agent = Agent(initialState: AgentInitialState(model: testModel))

        let result = await registry.execute(
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

    func testUnknownCommandUsesRegistryAvailableList() async {
        let registry = makeDefaultSlashCommandRegistry()
        let agent = Agent(initialState: AgentInitialState(model: testModel))

        let result = await registry.execute(
            "/unknown",
            context: SlashCommandContext(agent: agent, modelStore: nil, attachmentStore: AttachmentStore())
        )

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Available: /model, /compact, /queue, /attach, /attachments, /detach, /save, /load, /sessions, /export, /help, /exit"))
        } else {
            XCTFail("Expected feedback result")
        }
    }

    /// Regression test for P0-7: AppKit used to create a new empty AttachmentStore()
    /// for every slash command invocation, so /attach appeared to work but did not
    /// persist attachments. The registry must modify the store provided in the context.
    func testAttachCommandModifiesProvidedAttachmentStore() async {
        let registry = makeDefaultSlashCommandRegistry()
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let sharedStore = AttachmentStore()

        _ = await registry.execute(
            "/attach text hello",
            context: SlashCommandContext(
                agent: agent,
                modelStore: nil,
                attachmentStore: sharedStore,
                sessionStore: SessionStore()
            )
        )

        XCTAssertEqual(sharedStore.count, 1)
        XCTAssertEqual(sharedStore.list().first?.kind, .text("hello"))
    }
}
