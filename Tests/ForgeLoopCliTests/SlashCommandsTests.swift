import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli

@MainActor
final class SlashCommandsTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    // MARK: - /help 命令

    func testHelpCommandReturnsAvailableCommands() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/help")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("/model"), "help should mention /model")
            XCTAssertTrue(text.contains("/compact"), "help should mention /compact")
            XCTAssertTrue(text.contains("/help"), "help should mention /help")
            XCTAssertTrue(text.contains("/exit"), "help should mention /exit")
            XCTAssertTrue(text.contains("/quit"), "help should mention /quit")
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    // MARK: - /model 无参数：显示当前模型

    func testModelCommandShowsCurrentModel() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/model")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("faux-coding-model"))
            XCTAssertTrue(text.contains("Faux Coding Model"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    // MARK: - /model 有参数：切换模型

    func testModelCommandSwitchesModel() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/model gpt-4")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Switched to model: gpt-4"))
        } else {
            XCTFail("Expected feedback result")
        }
        XCTAssertEqual(agent.state.model.id, "gpt-4")
        XCTAssertEqual(agent.state.model.name, "gpt-4")
        // api/provider should be preserved
        XCTAssertEqual(agent.state.model.api, "faux")
        XCTAssertEqual(agent.state.model.provider, "faux")
    }

    // MARK: - /model 切换后写入 store

    func testModelCommandSavesToStore() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("model.json")
        let store = ModelStore(fileURL: fileURL)
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent, modelStore: store)

        _ = try await controller.submit("/model gpt-4")

        let loaded = store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "gpt-4")
        XCTAssertEqual(loaded?.api, "faux")
        XCTAssertEqual(loaded?.provider, "faux")
    }

    // MARK: - /model 无参数：显示当前模型（含尾随空格也视为无参数）

    func testModelCommandTrailingSpacesShowsCurrentModel() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/model   ")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("faux-coding-model"))
        } else {
            XCTFail("Expected current model feedback")
        }
    }

    // MARK: - /compact：压缩上下文

    func testCompactCommandReducesMessages() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        // Add some dummy messages
        agent.state.messages = [
            .user(UserMessage(text: "msg1")),
            .assistant(AssistantMessage.text("resp1")),
            .user(UserMessage(text: "msg2")),
            .assistant(AssistantMessage.text("resp2")),
            .user(UserMessage(text: "msg3")),
            .assistant(AssistantMessage.text("resp3")),
        ]

        let controller = PromptController(agent: agent)
        let result = try await controller.submit("/compact")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Compacted"))
            XCTAssertTrue(text.contains("6 →"))
        } else {
            XCTFail("Expected feedback result")
        }
    }

    // MARK: - /compact：少于阈值时不丢失消息

    func testCompactCommandNoOpWhenBelowThreshold() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.state.messages = [
            .user(UserMessage(text: "msg1")),
            .assistant(AssistantMessage.text("resp1")),
        ]

        let controller = PromptController(agent: agent)
        let result = try await controller.submit("/compact")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("2 → 2"))
        } else {
            XCTFail("Expected feedback result")
        }
        XCTAssertEqual(agent.state.messages.count, 2)
    }

    // MARK: - 未知命令：返回错误提示

    func testUnknownCommandReturnsError() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/unknown")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Unknown command"))
            XCTAssertTrue(text.contains("/model"))
            XCTAssertTrue(text.contains("/compact"))
        } else {
            XCTFail("Expected feedback result")
        }
    }

    // MARK: - /exit：返回 exit 结果

    func testExitCommandReturnsExit() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/exit")
        XCTAssertEqual(result, .exit)
    }

    func testQuitCommandReturnsExit() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/quit")
        XCTAssertEqual(result, .exit)
    }

    // MARK: - streaming 期间 slash 命令不触发 run

    func testSlashCommandDuringStreamingDoesNotInterrupt() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let controller = PromptController(agent: agent)

        let promptTask = Task {
            _ = try await controller.submit("hello")
        }

        var attempts = 0
        while !agent.state.isStreaming {
            await Task.yield()
            attempts += 1
            if attempts > 1000 {
                XCTFail("Timeout")
                stream.end(AssistantMessage.text("timeout", stopReason: .endTurn))
                return
            }
        }

        // streaming 期间发 slash 命令，应返回 feedback 而不抛 alreadyRunning
        let result = try? await controller.submit("/model")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("faux-coding-model"))
        } else {
            XCTFail("Expected feedback during streaming, got \(String(describing: result))")
        }

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value
    }
}
