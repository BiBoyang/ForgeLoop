import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

private struct EchoTool: Tool {
    let name = "echo"
    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        ToolResult(output: "echo: \(arguments)", isError: false)
    }
}

final class AgentRunOnceTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    /// runOnce yields the full lifecycle events for a text response.
    func testRunOnceYieldsEventsAndTextResponse() async throws {
        let streamFn: StreamFn = { _, context, _ in
            let text = context.messages.compactMap { message -> String? in
                if case .user(let user) = message { return user.text }
                return nil
            }.last ?? ""
            let message = AssistantMessage.text("reply to: \(text)", stopReason: .endTurn)
            let stream = AssistantMessageStream()
            Task.detached {
                stream.push(.start(partial: message))
                stream.push(.done(reason: .endTurn, message: message))
                stream.end(message)
            }
            return stream
        }

        let stream = Agent.runOnce(
            prompt: "hello",
            model: testModel,
            streamFn: streamFn
        )

        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
        }

        let typeSequence = events.map(\.type)
        XCTAssertTrue(typeSequence.contains("agent_start"))
        XCTAssertTrue(typeSequence.contains("agent_end"))
        XCTAssertTrue(typeSequence.contains("message_start"))
        XCTAssertTrue(typeSequence.contains("message_end"))

        let finalTexts = events.compactMap { event -> String? in
            if case .messageEnd(let message) = event,
               case .assistant(let assistant) = message,
               assistant.stopReason == .endTurn {
                return assistant.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text }
                    return nil
                }.joined()
            }
            return nil
        }
        XCTAssertTrue(finalTexts.contains("reply to: hello"))
    }

    /// runOnce executes tools and yields tool execution events.
    func testRunOnceWithTool() async throws {
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

        let toolExecutor = ToolExecutor()
        toolExecutor.register(EchoTool())

        let stream = Agent.runOnce(
            prompt: "run",
            model: testModel,
            tools: [EchoTool()],
            streamFn: streamFn
        )

        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
        }

        let toolStartEvents = events.compactMap { event -> String? in
            if case .toolExecutionStart(_, let name, _) = event { return name }
            return nil
        }
        XCTAssertTrue(toolStartEvents.contains("echo"))

        let toolResultMessages = events.compactMap { event -> ToolResultMessage? in
            if case .messageEnd(let message) = event,
               case .tool(let result) = message {
                return result
            }
            return nil
        }
        XCTAssertTrue(toolResultMessages.contains { $0.output.hasPrefix("echo:") })
    }

    /// Cancelling the consumer task aborts the runOnce stream.
    func testRunOnceCancellation() async throws {
        let streamFn: StreamFn = { _, _, _ in
            // A stream that never completes on its own.
            let stream = AssistantMessageStream()
            let message = AssistantMessage.text("streaming", stopReason: .endTurn)
            Task.detached {
                stream.push(.start(partial: message))
                try? await Task.sleep(nanoseconds: 1_000_000_000_000)
                stream.push(.done(reason: .endTurn, message: message))
                stream.end(message)
            }
            return stream
        }

        let stream = Agent.runOnce(
            prompt: "block",
            model: testModel,
            streamFn: streamFn
        )

        let consumeTask = Task {
            var count = 0
            for try await _ in stream {
                count += 1
                if count >= 1 { break }
            }
            return count
        }

        // Allow the stream to start.
        try? await Task.sleep(nanoseconds: 50_000_000)
        consumeTask.cancel()

        let count = try? await consumeTask.value
        XCTAssertEqual(count, 1)
    }

    /// closeSession cancels background tasks managed by the Agent.
    func testCloseSessionCancelsBackgroundTasks() async throws {
        let manager = BackgroundTaskManager()
        let agent = Agent(initialState: AgentInitialState(model: testModel))
        agent.backgroundTaskManager = manager

        let id = try await manager.start(command: "sleep 60", cwd: "/tmp")
        let before = await manager.status(id: id)
        XCTAssertEqual(before.first?.status, .running)

        await agent.closeSession()

        let after = await manager.status(id: id)
        XCTAssertEqual(after.first?.status, .cancelled)
    }
}

private actor StreamCallCounter {
    var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}
