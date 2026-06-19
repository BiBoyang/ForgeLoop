import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli
@testable import ForgeLoopTestSupport
import ForgeLoopDiagnostics

final class CliTraceTests: XCTestCase {
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

    @MainActor
    func testSessionCoordinatorCreatesSubmitSpan() async throws {
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
        let coordinator = SessionCoordinator(agent: agent, diagnostics: diagnostics)

        _ = try await coordinator.submit("hello")
        await agent.waitForIdle()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(
            capture.captured.contains { $0.contains("span.start: session.submit") },
            "Expected session.submit span start"
        )
        XCTAssertTrue(
            capture.captured.contains { $0.contains("span.end:") },
            "Expected session.submit span end"
        )
    }

    @MainActor
    func testSessionCoordinatorSubmitLogsMaskedInputPreview() async throws {
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
        let coordinator = SessionCoordinator(agent: agent, diagnostics: diagnostics)

        _ = try await coordinator.submit("this is a long user prompt with possible secret sk-abcdefghijklmnopqrstuvwxyz")
        await agent.waitForIdle()
        try await Task.sleep(for: .milliseconds(50))

        let startLog = capture.captured.first { $0.contains("session.submit.start") }
        XCTAssertNotNil(startLog)
        XCTAssertFalse(
            startLog?.contains("sk-abcdefghijklmnopqrstuvwxyz") == true,
            "Expected API key to be masked in log"
        )
    }

    @MainActor
    func testSessionCoordinatorSwitchModelLogsInfo() async throws {
        let (diagnostics, capture) = makeDiagnostics()

        let agent = Agent(initialState: AgentInitialState(model: testModel))
        let coordinator = SessionCoordinator(agent: agent, diagnostics: diagnostics)

        try? await coordinator.switchModel(to: "gpt-4o")

        XCTAssertTrue(
            capture.captured.contains { $0.contains("session.switch_model") },
            "Expected switch_model log"
        )
    }
}
