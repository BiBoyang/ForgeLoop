import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

private actor EventCollector {
    private(set) var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
}

private actor StreamCallCounter {
    var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private struct EchoTool: Tool {
    let name = "echo"
    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        ToolResult(output: "echo: \(arguments)", isError: false)
    }
}

final class AgentHooksTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    /// beforeToolCall can block a tool and skip execution.
    func testBeforeToolCallBlocksTool() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())

        let counter = StreamCallCounter()
        let streamFn: StreamFn = { _, _, _ in
            let count = await counter.increment()
            let stream = AssistantMessageStream()
            if count == 1 {
                let toolCall = ToolCall(id: "call-1", name: "echo", arguments: "{}")
                let message = AssistantMessage(content: [.toolCall(toolCall)], stopReason: .toolUse)
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.done(reason: .toolUse, message: message))
                    stream.end(message)
                }
            } else {
                let message = AssistantMessage.text("done", stopReason: .endTurn)
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.done(reason: .endTurn, message: message))
                    stream.end(message)
                }
            }
            return stream
        }

        let agent = Agent(
            options: AgentOptions(
                initialState: AgentInitialState(model: testModel),
                beforeToolCall: { toolName, _, _ in
                    if toolName == "echo" {
                        return BeforeToolCallResult(block: true, reason: "blocked by hook")
                    }
                    return nil
                }
            ),
            streamFn: streamFn,
            toolExecutor: executor,
            cwd: "/tmp"
        )

        let collector = EventCollector()
        _ = agent.subscribe { event, _ in
            await collector.append(event)
        }

        try await agent.prompt("run")
        await agent.waitForIdle()

        let events = await collector.events
        let toolEndEvents = events.compactMap { event -> (String, Bool, String?)? in
            if case .toolExecutionEnd(_, let name, let isError, let summary) = event {
                return (name, isError, summary)
            }
            return nil
        }
        XCTAssertEqual(toolEndEvents.count, 1)
        XCTAssertEqual(toolEndEvents[0].0, "echo")
        XCTAssertTrue(toolEndEvents[0].1)
        XCTAssertTrue(toolEndEvents[0].2?.contains("blocked by hook") ?? false)

        let toolResultMessages = agent.state.messages.compactMap { message -> ToolResultMessage? in
            if case .tool(let toolResult) = message { return toolResult }
            return nil
        }
        XCTAssertEqual(toolResultMessages.count, 1)
        XCTAssertTrue(toolResultMessages[0].isError)
        XCTAssertTrue(toolResultMessages[0].output.contains("blocked by hook"))
    }

    /// afterToolCall can modify the tool result.
    func testAfterToolCallModifiesResult() async throws {
        let executor = ToolExecutor()
        executor.register(EchoTool())

        let counter = StreamCallCounter()
        let streamFn: StreamFn = { _, _, _ in
            let count = await counter.increment()
            let stream = AssistantMessageStream()
            if count == 1 {
                let toolCall = ToolCall(id: "call-1", name: "echo", arguments: "{}")
                let message = AssistantMessage(content: [.toolCall(toolCall)], stopReason: .toolUse)
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.done(reason: .toolUse, message: message))
                    stream.end(message)
                }
            } else {
                let message = AssistantMessage.text("done", stopReason: .endTurn)
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.done(reason: .endTurn, message: message))
                    stream.end(message)
                }
            }
            return stream
        }

        let agent = Agent(
            options: AgentOptions(
                initialState: AgentInitialState(model: testModel),
                afterToolCall: { _, _, result, _ in
                    let truncated = String(result.output.prefix(5))
                    return AfterToolCallResult(modifiedResult: ToolResult(output: truncated, isError: result.isError))
                }
            ),
            streamFn: streamFn,
            toolExecutor: executor,
            cwd: "/tmp"
        )

        try await agent.prompt("run")
        await agent.waitForIdle()

        let toolResultMessages = agent.state.messages.compactMap { message -> ToolResultMessage? in
            if case .tool(let toolResult) = message { return toolResult }
            return nil
        }
        XCTAssertEqual(toolResultMessages.count, 1)
        XCTAssertEqual(toolResultMessages[0].output, "echo:")
        XCTAssertFalse(toolResultMessages[0].isError)
    }

    /// userPromptSubmit can block user input before it enters the lifecycle.
    func testUserPromptSubmitBlocksInput() async throws {
        let agent = Agent(
            options: AgentOptions(
                initialState: AgentInitialState(model: testModel),
                userPromptSubmit: { text, _ in
                    if text.contains("blocked") {
                        return UserPromptSubmitResult(block: true, reason: "blocked by hook")
                    }
                    return nil
                }
            ),
            cwd: "/tmp"
        )

        try await agent.prompt("this is blocked")
        await agent.waitForIdle()

        XCTAssertTrue(agent.state.messages.isEmpty)
        XCTAssertFalse(agent.state.isStreaming)
    }

    /// userPromptSubmit can modify user input text.
    func testUserPromptSubmitModifiesInput() async throws {
        let collector = EventCollector()
        let counter = StreamCallCounter()
        let streamFn: StreamFn = { _, context, _ in
            _ = await counter.increment()
            let stream = AssistantMessageStream()
            let text = context.messages.compactMap { message -> String? in
                if case .user(let user) = message { return user.text }
                return nil
            }.last ?? ""
            let message = AssistantMessage.text("received: \(text)", stopReason: .endTurn)
            Task.detached {
                stream.push(.start(partial: message))
                stream.push(.done(reason: .endTurn, message: message))
                stream.end(message)
            }
            return stream
        }

        let agent = Agent(
            options: AgentOptions(
                initialState: AgentInitialState(model: testModel),
                userPromptSubmit: { text, _ in
                    return UserPromptSubmitResult(modifiedText: text.uppercased())
                }
            ),
            streamFn: streamFn,
            cwd: "/tmp"
        )

        _ = agent.subscribe { event, _ in
            await collector.append(event)
        }

        try await agent.prompt("hello")
        await agent.waitForIdle()

        let userMessages = agent.state.messages.compactMap { message -> String? in
            if case .user(let user) = message { return user.text }
            return nil
        }
        XCTAssertEqual(userMessages, ["HELLO"])
    }

    /// betweenTurns can compact messages between turns.
    func testBetweenTurnsCompactsMessages() async throws {
        let collector = EventCollector()
        let streamFn: StreamFn = { _, _, _ in
            let stream = AssistantMessageStream()
            let message = AssistantMessage.text("ok", stopReason: .endTurn)
            Task.detached {
                stream.push(.start(partial: message))
                stream.push(.done(reason: .endTurn, message: message))
                stream.end(message)
            }
            return stream
        }

        let agent = Agent(
            options: AgentOptions(
                initialState: AgentInitialState(model: testModel),
                betweenTurns: { messages, _ in
                    // Keep only the last message (assistant reply).
                    return BetweenTurnsResult(compactedMessages: Array(messages.suffix(1)))
                }
            ),
            streamFn: streamFn,
            cwd: "/tmp"
        )

        _ = agent.subscribe { event, _ in
            await collector.append(event)
        }

        try await agent.prompt("hello")
        await agent.waitForIdle()

        let compactEvents = await collector.events.filter {
            if case .contextCompacted = $0 { return true }
            return false
        }
        XCTAssertEqual(compactEvents.count, 1)

        if case .contextCompacted(let before, let after, _) = compactEvents.first {
            XCTAssertEqual(before, 2)
            XCTAssertEqual(after, 1)
        } else {
            XCTFail("Expected contextCompacted event")
        }

        XCTAssertEqual(agent.state.messages.count, 1)
        XCTAssertEqual(agent.state.messages.first?.role, "assistant")
    }
}
