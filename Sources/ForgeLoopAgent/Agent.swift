import Foundation
import ForgeLoopAI

public struct AgentOptions: Sendable {
    public var initialState: AgentInitialState
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var userPromptSubmit: UserPromptSubmitHook?
    public var betweenTurns: BetweenTurnsHook?

    public init(
        initialState: AgentInitialState,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        userPromptSubmit: UserPromptSubmitHook? = nil,
        betweenTurns: BetweenTurnsHook? = nil
    ) {
        self.initialState = initialState
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.userPromptSubmit = userPromptSubmit
        self.betweenTurns = betweenTurns
    }
}

/// Thread-safe holder for Agent configuration that may be mutated after initialization.
///
/// Safety invariant: all mutable shared state is protected by `lock`. Accessors copy values
/// out of the lock, so callers receive a consistent snapshot for the duration of their use.
private final class LockedAgentConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var _apiKeyResolver: (@Sendable (String) async -> String?)?
    private var _cwd: String
    private var _toolExecutionMode: ToolExecutionMode
    private var _backgroundTaskManager: BackgroundTaskManager?

    var apiKeyResolver: (@Sendable (String) async -> String?)? {
        get { lock.withLock { _apiKeyResolver } }
        set { lock.withLock { _apiKeyResolver = newValue } }
    }

    var cwd: String {
        get { lock.withLock { _cwd } }
        set { lock.withLock { _cwd = newValue } }
    }

    var toolExecutionMode: ToolExecutionMode {
        get { lock.withLock { _toolExecutionMode } }
        set { lock.withLock { _toolExecutionMode = newValue } }
    }

    var backgroundTaskManager: BackgroundTaskManager? {
        get { lock.withLock { _backgroundTaskManager } }
        set { lock.withLock { _backgroundTaskManager = newValue } }
    }

    init(
        apiKeyResolver: (@Sendable (String) async -> String?)?,
        cwd: String,
        toolExecutionMode: ToolExecutionMode,
        backgroundTaskManager: BackgroundTaskManager? = nil
    ) {
        self._apiKeyResolver = apiKeyResolver
        self._cwd = cwd
        self._toolExecutionMode = toolExecutionMode
        self._backgroundTaskManager = backgroundTaskManager
    }

    /// Returns a consistent snapshot of the loop-relevant configuration.
    func loopSnapshot() -> (
        apiKeyResolver: (@Sendable (String) async -> String?)?,
        cwd: String,
        toolExecutionMode: ToolExecutionMode
    ) {
        lock.withLock { (_apiKeyResolver, _cwd, _toolExecutionMode) }
    }
}

public final class Agent: @unchecked Sendable {
    public let state: AgentState
    private let streamFn: StreamFn
    private let steeringQueue = PendingMessageQueue()
    private let config: LockedAgentConfig

    /// `toolExecutor` is set at init time and never reassigned, avoiding races on the executor.
    public let toolExecutor: ToolExecutor?

    public var apiKeyResolver: (@Sendable (String) async -> String?)? {
        get { config.apiKeyResolver }
        set { config.apiKeyResolver = newValue }
    }

    public var backgroundTaskManager: BackgroundTaskManager? {
        get { config.backgroundTaskManager }
        set { config.backgroundTaskManager = newValue }
    }

    public var cwd: String {
        get { config.cwd }
        set { config.cwd = newValue }
    }

    public var toolExecutionMode: ToolExecutionMode {
        get { config.toolExecutionMode }
        set { config.toolExecutionMode = newValue }
    }

    public let beforeToolCall: BeforeToolCallHook?
    public let afterToolCall: AfterToolCallHook?
    public let userPromptSubmit: UserPromptSubmitHook?
    public let betweenTurns: BetweenTurnsHook?

    private let lock = NSLock()
    private var listeners: [(id: UUID, handler: AgentListener)] = []
    private var activeCancellation: CancellationHandle?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public convenience init(
        initialState: AgentInitialState,
        streamFn: StreamFn? = nil,
        toolExecutor: ToolExecutor? = nil,
        cwd: String = ""
    ) {
        self.init(
            options: AgentOptions(initialState: initialState),
            streamFn: streamFn,
            toolExecutor: toolExecutor,
            cwd: cwd
        )
    }

    public init(
        options: AgentOptions,
        streamFn: StreamFn? = nil,
        toolExecutor: ToolExecutor? = nil,
        cwd: String = ""
    ) {
        self.state = AgentState(
            systemPrompt: options.initialState.systemPrompt,
            model: options.initialState.model,
            messages: options.initialState.messages
        )
        self.streamFn = streamFn ?? { model, context, options in
            try await ForgeLoopAI.stream(model: model, context: context, options: options)
        }
        self.toolExecutor = toolExecutor
        self.config = LockedAgentConfig(
            apiKeyResolver: nil,
            cwd: cwd,
            toolExecutionMode: .sequential
        )
        self.beforeToolCall = options.beforeToolCall
        self.afterToolCall = options.afterToolCall
        self.userPromptSubmit = options.userPromptSubmit
        self.betweenTurns = options.betweenTurns
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
        try await runLifecycle(
            makePrompts: { [self] cancellation in
                if let hook = userPromptSubmit {
                    let result = await hook(text, cancellation)
                    if result?.block == true { return nil }
                    let effectiveText = result?.modifiedText ?? text
                    return [Message.user(UserMessage(text: effectiveText))]
                }
                return [Message.user(UserMessage(text: text))]
            },
            executor: { [self] cancellation, emit, prompts in
                try await AgentLoop.run(
                    prompts: prompts,
                    context: snapshotContext(),
                    config: makeLoopConfig(cancellation: cancellation),
                    emit: emit,
                    cancellation: cancellation,
                    streamFn: streamFn
                )
            }
        )
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
                try await runLifecycle(
                    makePrompts: { [self] cancellation in
                        var effective: [Message] = []
                        for message in queued {
                            if case .user(let userMessage) = message, let hook = userPromptSubmit {
                                let result = await hook(userMessage.text, cancellation)
                                if result?.block == true { continue }
                                let effectiveText = result?.modifiedText ?? userMessage.text
                                effective.append(Message.user(UserMessage(text: effectiveText)))
                            } else {
                                effective.append(message)
                            }
                        }
                        return effective.isEmpty ? nil : effective
                    },
                    executor: { [self] cancellation, emit, prompts in
                        try await AgentLoop.run(
                            prompts: prompts,
                            context: snapshotContext(),
                            config: makeLoopConfig(cancellation: cancellation),
                            emit: emit,
                            cancellation: cancellation,
                            streamFn: streamFn
                        )
                    }
                )
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

        try await runLifecycle(
            makePrompts: { _ in [] },
            executor: { [self] cancellation, emit, prompts in
                try await AgentLoop.run(
                    prompts: prompts,
                    context: snapshotContext(),
                    config: makeLoopConfig(cancellation: cancellation),
                    emit: emit,
                    cancellation: cancellation,
                    streamFn: streamFn
                )
            }
        )
    }

    private func makeLoopConfig(cancellation: CancellationHandle?) -> AgentLoopConfig {
        let snapshot = config.loopSnapshot()
        return AgentLoopConfig(
            model: state.model,
            apiKeyResolver: snapshot.apiKeyResolver,
            toolExecutor: toolExecutor,
            cwd: snapshot.cwd,
            toolExecutionMode: snapshot.toolExecutionMode,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall,
            betweenTurns: betweenTurns
        )
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

    // MARK: - State mutation API (enforced by Agent, not written by CLI/App)

    /// Switches the agent's model. Throws if the agent is currently streaming.
    public func switchModel(to newModel: Model) async throws {
        guard !state.isStreaming else {
            throw AgentError.cannotModifyStateWhileStreaming
        }
        state.model = newModel
    }

    /// Replaces the agent's message history and optionally switches the model.
    /// Throws if the agent is currently streaming.
    public func restoreSession(messages: [Message], model: Model? = nil) async throws {
        guard !state.isStreaming else {
            throw AgentError.cannotModifyStateWhileStreaming
        }
        state.setStreamingMessage(nil)
        state.setErrorMessage(nil)
        state.messages = messages
        if let model = model {
            state.model = model
        }
    }

    /// Convenience overload that switches model only when `modelID` differs from the current one.
    /// Throws if the agent is currently streaming.
    public func restoreSession(messages: [Message], modelID: String?) async throws {
        let model: Model?
        if let modelID = modelID, modelID != state.model.id {
            model = state.model.switched(to: modelID)
        } else {
            model = nil
        }
        try await restoreSession(messages: messages, model: model)
    }

    /// Explicitly compacts the conversation context. Emits `.contextCompacted` to listeners.
    /// Throws if the agent is currently streaming.
    public func compactContext(keepLast: Int = 10) async throws {
        guard !state.isStreaming else {
            throw AgentError.cannotModifyStateWhileStreaming
        }
        let before = state.messages.count
        state.compact(keepLast: keepLast)
        let after = state.messages.count
        let event = AgentEvent.contextCompacted(
            before: before,
            after: after,
            messages: nil
        )
        for listener in snapshotListeners() {
            await listener(event, nil)
        }
    }

    private func runLifecycle(
        makePrompts: @escaping @Sendable (_ cancellation: CancellationHandle) async throws -> [Message]?,
        executor: @escaping @Sendable (_ cancellation: CancellationHandle, _ emit: @escaping AgentEventSink, _ prompts: [Message]) async throws -> Void
    ) async throws {
        try lock.withLock {
            if activeCancellation != nil { throw AgentError.alreadyRunning }
            activeCancellation = CancellationHandle()
        }

        let cancellation = lock.withLock { activeCancellation! }

        let prompts: [Message]
        do {
            guard let madePrompts = try await makePrompts(cancellation) else {
                // Hook blocked the prompt; clean up without emitting events.
                lock.withLock { activeCancellation = nil }
                return
            }
            prompts = madePrompts
        } catch {
            lock.withLock { activeCancellation = nil }
            throw error
        }

        state.setStreaming(true)
        state.setStreamingMessage(nil)
        state.setErrorMessage(nil)

        let emit: AgentEventSink = { [weak self] event in
            await self?.processEvent(event, cancellation: cancellation)
        }

        do {
            try await executor(cancellation, emit, prompts)
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

        // Auto-compact after turn completes, before notifying waiters
        if let compactResult = state.maybeAutoCompact() {
            let event = AgentEvent.contextCompacted(
                before: compactResult.before,
                after: compactResult.after,
                messages: nil
            )
            for listener in snapshotListeners() {
                await listener(event, nil)
            }
        }

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
        case .contextCompacted(_, _, let messages):
            if let messages = messages {
                state.messages = messages
            }
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
