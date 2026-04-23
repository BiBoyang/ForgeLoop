import Foundation
import ForgeLoopAI

public final class Agent: @unchecked Sendable {
    public let state: AgentState
    private let streamFn: StreamFn
    private let steeringQueue = PendingMessageQueue()

    private let lock = NSLock()
    private var listeners: [(id: UUID, handler: AgentListener)] = []
    private var activeCancellation: CancellationHandle?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public var apiKeyResolver: (@Sendable (String) async -> String?)?
    public var toolExecutor: ToolExecutor?
    public var backgroundTaskManager: BackgroundTaskManager?
    public var cwd: String
    public var toolExecutionMode: ToolExecutionMode = .sequential

    public init(
        initialState: AgentInitialState,
        streamFn: StreamFn? = nil,
        toolExecutor: ToolExecutor? = nil,
        cwd: String = ""
    ) {
        self.state = AgentState(
            systemPrompt: initialState.systemPrompt,
            model: initialState.model,
            messages: initialState.messages
        )
        self.streamFn = streamFn ?? { model, context, options in
            try await ForgeLoopAI.stream(model: model, context: context, options: options)
        }
        self.toolExecutor = toolExecutor
        self.cwd = cwd
    }

    public func subscribe(_ handler: @escaping AgentListener) -> Unsubscribe {
        let id = UUID()
        lock.withLock { listeners.append((id, handler)) }
        return { [weak self] in
            self?.lock.withLock {
                self?.listeners.removeAll { $0.id == id }
            }
        }
    }

    public func prompt(_ text: String) async throws {
        let user = Message.user(UserMessage(text: text))
        try await runLifecycle { [self] cancellation, emit in
            try await AgentLoop.run(
                prompts: [user],
                context: snapshotContext(),
                config: AgentLoopConfig(
                    model: state.model,
                    apiKeyResolver: apiKeyResolver,
                    toolExecutor: toolExecutor,
                    cwd: cwd,
                    toolExecutionMode: toolExecutionMode
                ),
                emit: emit,
                cancellation: cancellation,
                streamFn: streamFn
            )
        }
    }

    public func steer(_ message: Message) {
        steeringQueue.enqueue(message)
    }

    public func clearSteeringQueue() {
        steeringQueue.clear()
    }

    public func queuedSteeringMessages() -> [Message] {
        steeringQueue.snapshot()
    }

    public func `continue`() async throws {
        let queued = steeringQueue.drain()
        if !queued.isEmpty {
            do {
                try await runLifecycle { [self] cancellation, emit in
                    try await AgentLoop.run(
                        prompts: queued,
                        context: snapshotContext(),
                        config: AgentLoopConfig(
                            model: state.model,
                            apiKeyResolver: apiKeyResolver,
                            toolExecutor: toolExecutor,
                            cwd: cwd,
                            toolExecutionMode: toolExecutionMode
                        ),
                        emit: emit,
                        cancellation: cancellation,
                        streamFn: streamFn
                    )
                }
            } catch {
                if let agentError = error as? AgentError, agentError == .alreadyRunning {
                    steeringQueue.prepend(contentsOf: queued)
                }
                throw error
            }
            return
        }

        let messages = state.messages
        guard !messages.isEmpty else {
            throw AgentError.noMessagesToContinue
        }

        guard case .user = messages.last else {
            throw AgentError.cannotContinueFromAssistant
        }

        try await runLifecycle { [self] cancellation, emit in
            try await AgentLoop.run(
                prompts: [],
                context: snapshotContext(),
                config: AgentLoopConfig(
                    model: state.model,
                    apiKeyResolver: apiKeyResolver,
                    toolExecutor: toolExecutor,
                    cwd: cwd,
                    toolExecutionMode: toolExecutionMode
                ),
                emit: emit,
                cancellation: cancellation,
                streamFn: streamFn
            )
        }
    }

    public func abort() {
        let handle = lock.withLock { activeCancellation }
        handle?.cancel(reason: "aborted")
    }

    public func waitForIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResume = lock.withLock {
                if activeCancellation == nil { return true }
                idleWaiters.append(cont)
                return false
            }
            if shouldResume {
                cont.resume()
            }
        }
    }

    private func runLifecycle(
        _ executor: @escaping @Sendable (_ cancellation: CancellationHandle, _ emit: @escaping AgentEventSink) async throws -> Void
    ) async throws {
        try lock.withLock {
            if activeCancellation != nil { throw AgentError.alreadyRunning }
            activeCancellation = CancellationHandle()
        }

        let cancellation = lock.withLock { activeCancellation! }
        state.setStreaming(true)
        state.setStreamingMessage(nil)
        state.setErrorMessage(nil)

        let emit: AgentEventSink = { [weak self] event in
            await self?.processEvent(event, cancellation: cancellation)
        }

        do {
            try await executor(cancellation, emit)
        } catch {
            let failure = AssistantMessage(
                content: [.text(TextContent(text: ""))],
                stopReason: cancellation.isCancelled ? .aborted : .error,
                errorMessage: "\(error)"
            )
            state.appendMessage(.assistant(failure))
            state.setErrorMessage(failure.errorMessage)
            let failureMessage = Message.assistant(failure)
            for listener in snapshotListeners() {
                await listener(.messageStart(message: failureMessage), cancellation)
                await listener(.messageEnd(message: failureMessage), cancellation)
                await listener(.agentEnd(messages: [.assistant(failure)]), cancellation)
            }
        }

        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            activeCancellation = nil
            let drained = idleWaiters
            idleWaiters.removeAll()
            return drained
        }
        state.setStreaming(false)
        state.setStreamingMessage(nil)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func processEvent(_ event: AgentEvent, cancellation: CancellationHandle) async {
        switch event {
        case .messageStart(let message):
            state.setStreamingMessage(message)
        case .messageUpdate(let partial, _):
            state.setStreamingMessage(.assistant(partial))
        case .messageEnd(let message):
            state.setStreamingMessage(nil)
            state.appendMessage(message)
        case .turnEnd(let message):
            if case .assistant(let a) = message, a.stopReason == .error {
                state.setErrorMessage(a.errorMessage)
            }
        case .agentEnd:
            state.setStreamingMessage(nil)
            state.setStreaming(false)
        case .toolExecutionStart, .toolExecutionEnd:
            break
        default:
            break
        }

        for listener in snapshotListeners() {
            await listener(event, cancellation)
        }
    }

    private func snapshotListeners() -> [AgentListener] {
        lock.withLock { listeners.map(\.handler) }
    }

    private func snapshotContext() -> AgentContext {
        AgentContext(
            systemPrompt: state.systemPrompt,
            messages: state.messages
        )
    }
}
