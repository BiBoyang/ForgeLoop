import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopTestSupport
import ForgeLoopDiagnostics

final class AgentTraceTests: XCTestCase {
    private var testModel: Model {
        Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
    }

    private func makeDiagnostics() -> (Diagnostics, LogCapture) {
        let capture = LogCapture()
        let sink = ConsoleLogSink { line in
            capture.append(line)
        }
        let diagnostics = Diagnostics(trace: LoggingTraceSystem(log: sink), log: sink)
        return (diagnostics, capture)
    }

    private struct SpanEntry {
        let name: String
        let spanID: String
        let parentSpanID: String
    }

    private func spanEntries(from capture: LogCapture) -> [SpanEntry] {
        capture.captured.compactMap { line in
            guard line.contains("span.start:") else { return nil }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? String,
                  let attrs = json["attributes"] as? [String: Any],
                  let spanID = attrs["span_id"] as? String,
                  let parentSpanID = attrs["parent_span_id"] as? String else {
                return nil
            }
            let name = message.replacingOccurrences(of: "span.start: ", with: "")
            return SpanEntry(name: name, spanID: spanID, parentSpanID: parentSpanID)
        }
    }

    func testAgentRunCreatesSpan() async throws {
        let (diagnostics, capture) = makeDiagnostics()

        let streamFn: StreamFn = { _, _, _ in
            let stream = AssistantMessageStream()
            let message = AssistantMessage.text("Hello!", stopReason: .endTurn)
            Task.detached {
                stream.push(.start(partial: message))
                stream.push(.done(reason: .endTurn, message: message))
                stream.end(message)
            }
            return stream
        }

        let agent = Agent(
            initialState: AgentInitialState(model: testModel),
            streamFn: streamFn,
            diagnostics: diagnostics
        )

        try await agent.prompt("hello")
        await agent.waitForIdle()
        try await Task.sleep(for: .milliseconds(50))

        let entries = spanEntries(from: capture)
        XCTAssertTrue(entries.contains { $0.name == "agent.run" })
        XCTAssertTrue(entries.contains { $0.name == "agent.turn" })

        let runEntry = entries.first { $0.name == "agent.run" }
        let turnEntry = entries.first { $0.name == "agent.turn" }
        XCTAssertNotNil(runEntry)
        XCTAssertNotNil(turnEntry)
        XCTAssertEqual(turnEntry?.parentSpanID, runEntry?.spanID)

        XCTAssertTrue(capture.captured.contains { $0.contains("span.end:") })
    }

    func testToolExecutionCreatesSpan() async throws {
        let (diagnostics, capture) = makeDiagnostics()

        struct EchoTool: Tool {
            let name = "echo"
            func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
                ToolResult(output: arguments, isError: false)
            }
        }

        let toolCall = ToolCall(
            id: "call-1",
            name: "echo",
            arguments: "\"hello world\""
        )
        let toolMessage = AssistantMessage(
            content: [.toolCall(toolCall)],
            stopReason: .toolUse
        )

        let counter = StreamCallCounter()
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
                let message = AssistantMessage.text("Done", stopReason: .endTurn)
                Task.detached {
                    stream.push(.start(partial: message))
                    stream.push(.done(reason: .endTurn, message: message))
                    stream.end(message)
                }
            }
            return stream
        }

        let toolExecutor = ToolExecutor(diagnostics: diagnostics)
        toolExecutor.register(EchoTool())

        let agent = Agent(
            initialState: AgentInitialState(model: testModel),
            streamFn: streamFn,
            toolExecutor: toolExecutor,
            diagnostics: diagnostics
        )

        try await agent.prompt("use echo tool")
        await agent.waitForIdle()
        try await Task.sleep(for: .milliseconds(50))

        let entries = spanEntries(from: capture)
        let toolEntry = entries.first { $0.name == "tool.execute" }
        XCTAssertNotNil(toolEntry)

        let turnEntry = entries.first { $0.name == "agent.turn" }
        XCTAssertNotNil(turnEntry)
        XCTAssertEqual(toolEntry?.parentSpanID, turnEntry?.spanID)
    }

    func testSubagentRunCreatesChildSpan() async throws {
        let (diagnostics, capture) = makeDiagnostics()

        let counter = StreamCallCounter()
        let parentModel = testModel

        let streamFn: StreamFn = { _, _, _ in
            let count = await counter.increment()

            if count == 1 {
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

        let agent = await makeCodingAgent(config, diagnostics: diagnostics)

        try await agent.prompt("Please delegate a greeting task to the child agent.")
        await agent.waitForIdle()
        try await Task.sleep(for: .milliseconds(50))

        let entries = spanEntries(from: capture)

        let parentRun = entries.first { $0.name == "agent.run" }
        let parentTurn = entries.first { $0.name == "agent.turn" }
        let toolExecute = entries.first { $0.name == "tool.execute" }
        let childRun = entries.last { $0.name == "agent.run" }

        XCTAssertNotNil(parentRun)
        XCTAssertNotNil(parentTurn)
        XCTAssertNotNil(toolExecute)
        XCTAssertNotNil(childRun)

        XCTAssertEqual(parentTurn?.parentSpanID, parentRun?.spanID)
        XCTAssertEqual(toolExecute?.parentSpanID, parentTurn?.spanID)
        XCTAssertEqual(childRun?.parentSpanID, toolExecute?.spanID)
    }
}
