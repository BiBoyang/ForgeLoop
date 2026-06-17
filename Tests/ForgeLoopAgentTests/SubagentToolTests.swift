import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

private actor StreamCallCounter {
    var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private actor EventCollector {
    private(set) var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
}

private actor SubagentSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func signal() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if fired {
                cont.resume()
            } else {
                continuation = cont
            }
        }
    }
}

final class SubagentToolTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    /// Parent delegates to a general subagent; the child returns text,
    /// and the parent includes that result in its final answer.
    func testSubagentToolEndToEnd() async throws {
        let counter = StreamCallCounter()
        let parentModel = testModel

        let streamFn: StreamFn = { model, context, options in
            let count = await counter.increment()

            if count == 1 {
                // Parent turn 1: delegate to agent tool.
                let toolCall = ToolCall(
                    id: "call-parent-1",
                    name: "agent",
                    arguments: """
                    {
                        "description": "delegate to child",
                        "prompt": "Please say hello from the child agent.",
                        "subagent_type": "general"
                    }
                    """
                )
                let message = AssistantMessage(
                    content: [.toolCall(toolCall)],
                    stopReason: .toolUse
                )
                let stream = AssistantMessageStream()
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.done(reason: .toolUse, message: message))
                    stream.end(message)
                }
                return stream
            } else if count == 2 {
                // Child turn 1: return text result.
                let message = AssistantMessage.text("Hello from the child agent!", stopReason: .endTurn)
                let stream = AssistantMessageStream()
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.textStart(contentIndex: 0, partial: message))
                    stream.push(.textEnd(contentIndex: 0, content: "Hello from the child agent!", partial: message))
                    stream.push(.done(reason: .endTurn, message: message))
                    stream.end(message)
                }
                return stream
            } else {
                // Parent turn 2: summarize and finish.
                let message = AssistantMessage.text("Parent received: Hello from the child agent!", stopReason: .endTurn)
                let stream = AssistantMessageStream()
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.done(reason: .endTurn, message: message))
                    stream.end(message)
                }
                return stream
            }
        }

        let config = CodingAgentConfig(
            model: parentModel,
            cwd: "/tmp",
            subagents: [.general],
            streamFn: streamFn
        )

        let agent = await makeCodingAgent(config)
        let collector = EventCollector()
        _ = agent.subscribe { event, _ in
            await collector.append(event)
        }

        try await agent.prompt("Please delegate a greeting task to the child agent.")
        await agent.waitForIdle()

        let events = await collector.events
        let typeSequence = events.map(\.type)

        // Verify the agent tool was executed.
        let toolExecutionStarts = events.compactMap { event -> String? in
            if case .toolExecutionStart(_, let name, _) = event { return name }
            return nil
        }
        XCTAssertTrue(toolExecutionStarts.contains("agent"))

        // Verify final assistant message exists.
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
        XCTAssertTrue(finalTexts.contains { $0.contains("Parent received") })

        // Verify the run completed.
        XCTAssertTrue(typeSequence.contains("agent_end"))
    }

    /// Unknown subagent type produces a clean tool error.
    func testSubagentToolUnknownTypeReturnsError() async throws {
        let counter = StreamCallCounter()
        let toolCall = ToolCall(
            id: "call-1",
            name: "agent",
            arguments: """
            {
                "description": "unknown delegate",
                "prompt": "Do something.",
                "subagent_type": "nonexistent"
            }
            """
        )
        let toolMessage = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )

        let streamFn: StreamFn = { _, _, _ in
            let count = await counter.increment()
            let stream = AssistantMessageStream()
            if count == 1 {
                Task.detached {
                    stream.push(.start(partial: toolMessage))
                    stream.push(.done(reason: .toolUse, message: toolMessage))
                    stream.end(toolMessage)
                }
            } else {
                let endMessage = AssistantMessage.text("done", stopReason: .endTurn)
                Task.detached {
                    stream.push(.start(partial: endMessage))
                    stream.push(.done(reason: .endTurn, message: endMessage))
                    stream.end(endMessage)
                }
            }
            return stream
        }

        let config = CodingAgentConfig(
            model: testModel,
            cwd: "/tmp",
            subagents: [.general],
            streamFn: streamFn
        )

        let agent = await makeCodingAgent(config)
        let collector = EventCollector()
        _ = agent.subscribe { event, _ in
            await collector.append(event)
        }

        try await agent.prompt("delegate")
        await agent.waitForIdle()

        let errorEnds = await collector.events.compactMap { event -> Bool? in
            if case .toolExecutionEnd(_, let name, let isError, _) = event, name == "agent" {
                return isError
            }
            return nil
        }
        XCTAssertEqual(errorEnds.count, 1)
        XCTAssertTrue(errorEnds[0])
    }

    /// Cancellation of the parent task/handle propagates into the child agent,
    /// aborting an in-progress tool execution promptly instead of waiting for it to finish.
    func testSubagentCancellationPropagates() async throws {
        let counter = StreamCallCounter()
        let childStarted = SubagentSignal()
        let bashCall = ToolCall(
            id: "call-child-1",
            name: "bash",
            arguments: #"{"command":"sleep 10"}"#
        )
        let toolMessage = AssistantMessage(
            content: [.toolCall(bashCall)],
            stopReason: .toolUse
        )

        let streamFn: StreamFn = { _, _, _ in
            await childStarted.signal()
            let count = await counter.increment()
            let stream = AssistantMessageStream()
            if count == 1 {
                Task.detached {
                    stream.push(.start(partial: toolMessage))
                    stream.push(.done(reason: .toolUse, message: toolMessage))
                    stream.end(toolMessage)
                }
            } else {
                let endMessage = AssistantMessage.text("finished", stopReason: .endTurn)
                Task.detached {
                    stream.push(.start(partial: endMessage))
                    stream.push(.done(reason: .endTurn, message: endMessage))
                    stream.end(endMessage)
                }
            }
            return stream
        }

        let config = CodingAgentConfig(
            model: testModel,
            cwd: "/tmp",
            subagents: [.general],
            streamFn: streamFn
        )

        let tool = createAgentTool(subagents: [SubagentDefinition.general], config: config)
        let cancellation = CancellationHandle()
        let start = Date()
        let task = Task {
            await tool.execute(
                arguments: #"{"description":"long running","prompt":"Run a long bash command","subagent_type":"general"}"#,
                cwd: "/tmp",
                cancellation: cancellation
            )
        }

        // Wait until the child agent has actually started running (its streamFn was called),
        // then cancel the parent handle. This guarantees abort() targets the active run.
        await childStarted.wait()
        cancellation.cancel()

        let result = await task.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.isError, "Cancelled subagent run should report an error")
        XCTAssertLessThan(elapsed, 3.0, "Cancellation should abort the sleep command promptly")
    }

    /// Read-only subagent does not expose write/edit/bash tools.
    func testReadOnlySubagentFiltersTools() async throws {
        let counter = StreamCallCounter()
        let writeToolCall = ToolCall(
            id: "call-child-1",
            name: "write",
            arguments: """
            {
                "path": "forbidden.txt",
                "content": "should not happen"
            }
            """
        )
        let toolMessage = AssistantMessage(
            content: [.toolCall(writeToolCall)],
            stopReason: .toolUse
        )

        let streamFn: StreamFn = { _, _, _ in
            let count = await counter.increment()
            let stream = AssistantMessageStream()
            if count == 1 {
                Task.detached {
                    stream.push(.start(partial: toolMessage))
                    stream.push(.done(reason: .toolUse, message: toolMessage))
                    stream.end(toolMessage)
                }
            } else {
                let endMessage = AssistantMessage.text("finished", stopReason: .endTurn)
                Task.detached {
                    stream.push(.start(partial: endMessage))
                    stream.push(.done(reason: .endTurn, message: endMessage))
                    stream.end(endMessage)
                }
            }
            return stream
        }

        let result = try await runSubagent(
            definition: .explore,
            taskPrompt: "Try to write a file.",
            parentConfig: CodingAgentConfig(
                model: testModel,
                cwd: "/tmp",
                streamFn: streamFn
            ),
            parentSessionId: "test-session"
        )

        // The child should have attempted one tool call, but it should resolve as an error.
        XCTAssertEqual(result.toolCalls, 1)
        let toolResults = result.messages.compactMap { message -> ToolResultMessage? in
            if case .tool(let toolResult) = message { return toolResult }
            return nil
        }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertTrue(toolResults[0].isError)
        XCTAssertTrue(toolResults[0].output.contains("unknownTool") || toolResults[0].output.contains("Unknown tool"))
    }
}
