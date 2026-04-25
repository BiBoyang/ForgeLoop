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

    // MARK: - /model 无参数：打开 picker

    func testModelCommandShowsPickerWhenIdle() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/model")

        if case .showModelPicker(let state) = result {
            XCTAssertEqual(state.title, "Select model")
            XCTAssertEqual(state.selectedItem?.id, "faux-coding-model")
            XCTAssertTrue(state.items.contains(where: { $0.id == "gpt-4.1-mini" }))
        } else {
            XCTFail("Expected picker result, got \(result)")
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

    // MARK: - /model 无参数：含尾随空格也打开 picker

    func testModelCommandTrailingSpacesShowsPicker() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/model   ")

        if case .showModelPicker(let state) = result {
            XCTAssertEqual(state.selectedItem?.id, "faux-coding-model")
        } else {
            XCTFail("Expected picker result")
        }
    }

    func testModelPickerKeepsDeepSeekOptionsWhenUsingDeepSeekBaseURL() async throws {
        let deepSeekModel = Model(
            id: "gpt-4o",
            name: "gpt-4o",
            api: "openai-chat-completions",
            provider: "openai",
            baseUrl: "https://api.deepseek.com"
        )
        let agent = Agent(initialState: AgentInitialState(model: deepSeekModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/model")

        if case .showModelPicker(let state) = result {
            let ids = state.items.map(\.id)
            XCTAssertTrue(ids.contains("gpt-4o"))
            XCTAssertTrue(ids.contains("deepseek-chat"))
            XCTAssertTrue(ids.contains("deepseek-reasoner"))
        } else {
            XCTFail("Expected picker result")
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

    // MARK: - /queue 命令

    func testQueueCommandEmpty() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue")

        if case .feedback(let text) = result {
            XCTAssertEqual(text, "Queue is empty")
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testQueueCommandOneItem() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.steer(.user(UserMessage(text: "hello world")))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Queue (1)"), text)
            XCTAssertTrue(text.contains("1. hello world"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testQueueCommandMultipleItems() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.steer(.user(UserMessage(text: "first message")))
        agent.steer(.user(UserMessage(text: "second message")))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Queue (2)"), text)
            XCTAssertTrue(text.contains("1. first message"), text)
            XCTAssertTrue(text.contains("2. second message"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testQueueCommandTruncatesLongText() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let longText = String(repeating: "a", count: 100)
        agent.steer(.user(UserMessage(text: longText)))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Queue (1)"), text)
            XCTAssertTrue(text.contains("aaa..."), text)
            XCTAssertFalse(text.contains(String(repeating: "a", count: 61)), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testQueueCommandDuringStreaming() async throws {
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

        _ = try? await controller.submit("follow-up 1")
        _ = try? await controller.submit("follow-up 2")

        let result = try? await controller.submit("/queue")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Queue (2)"), text)
            XCTAssertTrue(text.contains("1. follow-up 1"), text)
            XCTAssertTrue(text.contains("2. follow-up 2"), text)
        } else {
            XCTFail("Expected feedback during streaming, got \(String(describing: result))")
        }

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value
    }

    func testQueueCommandNormalizesMultilineText() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.steer(.user(UserMessage(text: "line one\nline two\rline three")))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Queue (1)"), text)
            XCTAssertTrue(text.contains("line one line two line three"), text)
            XCTAssertFalse(text.contains("\nline"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testQueueCommandLimitsToFiveItems() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        for i in 1...7 {
            agent.steer(.user(UserMessage(text: "msg \(i)")))
        }
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Queue (7)"), text)
            XCTAssertTrue(text.contains("1. msg 1"), text)
            XCTAssertTrue(text.contains("5. msg 5"), text)
            XCTAssertFalse(text.contains("6. msg 6"), text)
            XCTAssertTrue(text.contains("... and 2 more"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testQueueClearRemovesAllMessages() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.steer(.user(UserMessage(text: "queued A")))
        agent.steer(.user(UserMessage(text: "queued B")))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue clear")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Cleared 2 queued messages"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
        XCTAssertTrue(agent.queuedSteeringMessages().isEmpty)
    }

    func testQueueClearOnEmptyQueue() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/queue clear")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Cleared 0 queued messages"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    // MARK: - /attach 命令

    func testAttachTextAddsTextAttachment() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        let controller = PromptController(agent: agent, attachmentStore: store)

        let result = try await controller.submit("/attach text hello world")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Attached text"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.list()[0].kind, .text("hello world"))
    }

    func testAttachPathAddsPathAttachment() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        let controller = PromptController(agent: agent, attachmentStore: store)

        let result = try await controller.submit("/attach path /tmp/test.swift")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Attached path"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.list()[0].kind, .filePath("/tmp/test.swift"))
    }

    func testAttachWithoutArgsReturnsUsage() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/attach")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Usage"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    // MARK: - /attachments 命令

    func testAttachmentsListEmpty() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/attachments")

        if case .feedback(let text) = result {
            XCTAssertEqual(text, "No attachments")
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testAttachmentsListShowsItems() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        store.addText("content A")
        store.addFilePath("/tmp/file.swift")
        let controller = PromptController(agent: agent, attachmentStore: store)

        let result = try await controller.submit("/attachments")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Attachments (2)"))
            XCTAssertTrue(text.contains("1. [text] content A"))
            XCTAssertTrue(text.contains("2. [file] /tmp/file.swift"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    func testAttachmentsClearRemovesAll() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        store.addText("one")
        store.addFilePath("/tmp")
        let controller = PromptController(agent: agent, attachmentStore: store)

        let result = try await controller.submit("/attachments clear")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Cleared 2 attachments"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
        XCTAssertTrue(store.isEmpty)
    }

    func testAttachmentsClearOnEmptyStore() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/attachments clear")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Cleared 0 attachments"), text)
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }

    // MARK: - /detach 命令

    func testDetachByIndexRemovesAttachment() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        store.addText("first")
        store.addText("second")
        let controller = PromptController(agent: agent, attachmentStore: store)

        let result = try await controller.submit("/detach 1")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Removed attachment #1"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.list()[0].kind, .text("second"))
    }

    func testDetachAllClearsAttachments() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        store.addText("one")
        store.addFilePath("/tmp")
        let controller = PromptController(agent: agent, attachmentStore: store)

        let result = try await controller.submit("/detach all")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("Cleared 2 attachments"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
        XCTAssertTrue(store.isEmpty)
    }

    func testDetachInvalidIndexReturnsError() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let store = AttachmentStore()
        store.addText("only")
        let controller = PromptController(agent: agent, attachmentStore: store)

        let result = try await controller.submit("/detach 5")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("No attachment at index 5"))
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
        XCTAssertEqual(store.count, 1)
    }

    // MARK: - /help 包含所有命令

    func testHelpCommandIncludesAttachmentCommands() async throws {
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let controller = PromptController(agent: agent)

        let result = try await controller.submit("/help")

        if case .feedback(let text) = result {
            XCTAssertTrue(text.contains("/attach"), "help should mention /attach")
            XCTAssertTrue(text.contains("/attachments"), "help should mention /attachments")
            XCTAssertTrue(text.contains("/detach"), "help should mention /detach")
        } else {
            XCTFail("Expected feedback result, got \(result)")
        }
    }
}
