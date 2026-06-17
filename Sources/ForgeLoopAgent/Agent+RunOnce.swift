import Foundation
import ForgeLoopAI

extension Agent {
    /// Run a single-shot Agent session and stream its lifecycle events.
    ///
    /// The returned `AsyncThrowingStream` yields every `AgentEvent` emitted by the
    /// temporary Agent. The stream finishes when the Agent reaches `.agentEnd`, or
    /// terminates early if the consumer cancels the iteration.
    public static func runOnce(
        prompt: String,
        model: Model,
        tools: [any Tool] = [],
        cwd: String = "",
        streamFn: StreamFn? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let state = RunOnceStreamState()

            let task = Task {
                do {
                    let toolExecutor = ToolExecutor()
                    for tool in tools {
                        toolExecutor.register(tool)
                    }

                    let agent = Agent(
                        initialState: AgentInitialState(model: model),
                        streamFn: streamFn,
                        toolExecutor: toolExecutor,
                        cwd: cwd
                    )

                    let unsubscribe = agent.subscribe { event, _ in
                        continuation.yield(event)
                        if case .agentEnd = event {
                            Task {
                                await state.finish { continuation.finish() }
                            }
                        }
                    }

                    defer { unsubscribe() }

                    do {
                        try await withTaskCancellationHandler {
                            try await agent.prompt(prompt)
                        } onCancel: {
                            agent.abort()
                        }
                        await state.finish { continuation.finish() }
                    } catch {
                        if Task.isCancelled {
                            await state.finish { continuation.finish() }
                        } else {
                            await state.finish { continuation.finish(throwing: error) }
                        }
                    }
                } catch {
                    await state.finish { continuation.finish(throwing: error) }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Clean up resources associated with this Agent session.
    ///
    /// Cancels any running background tasks managed by this Agent.
    public func closeSession() async {
        await backgroundTaskManager?.cancelAll(by: "session_close")
        backgroundTaskManager = nil
    }
}

private actor RunOnceStreamState {
    private var isFinished = false

    func finish(_ action: @Sendable () -> Void) {
        guard !isFinished else { return }
        isFinished = true
        action()
    }
}
